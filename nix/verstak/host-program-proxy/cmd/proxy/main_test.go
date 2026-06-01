package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/seryiza/verstak/nix/verstak/host-program-proxy/internal/protocol"
)

func TestRunWithDepsAllowsAndStreamsExitStatus(t *testing.T) {
	policyPath, _ := writePolicy(t, `{
		"allow": ["git"],
		"forbid": ["git push"],
		"projectRoot": "`+escapeJSON(t.TempDir())+`",
		"projectMount": "/workspace/project",
		"auditLog": "`+escapeJSON(filepath.Join(t.TempDir(), "audit.jsonl"))+`"
	}`)

	var input bytes.Buffer
	if err := protocol.WriteRequest(&input, protocol.Request{Program: "git", Argv: []string{"status"}, GuestCwd: "/workspace/project/sub"}); err != nil {
		t.Fatalf("WriteRequest() error = %v", err)
	}
	input.WriteString("stdin data")

	var out bytes.Buffer
	code := runWithDeps([]string{"proxy", policyPath}, &input, &out, proxyDeps{
		lookPath: func(program string) (string, error) {
			if program != "git" {
				t.Fatalf("lookPath program = %q, want git", program)
			}
			return "/usr/bin/git", nil
		},
		runCommand: func(exe string, argv []string, dir string, stdin io.Reader, stdout io.Writer, stderr io.Writer) (int, error) {
			if exe != "/usr/bin/git" {
				t.Fatalf("exe = %q", exe)
			}
			if strings.Join(argv, " ") != "status" {
				t.Fatalf("argv = %#v", argv)
			}
			if !strings.HasSuffix(dir, "/sub") {
				t.Fatalf("dir = %q, want mapped subdir", dir)
			}
			data, err := io.ReadAll(stdin)
			if err != nil || string(data) != "stdin data" {
				t.Fatalf("stdin = %q, %v", string(data), err)
			}
			_, _ = stdout.Write([]byte("out"))
			_, _ = stderr.Write([]byte("err"))
			return 7, nil
		},
		now: fixedNow,
	})
	if code != 7 {
		t.Fatalf("runWithDeps() = %d, want 7", code)
	}
	stdout, stderr, exit := collectFrames(t, &out)
	if stdout != "out" || stderr != "err" || exit != 7 {
		t.Fatalf("frames stdout=%q stderr=%q exit=%d", stdout, stderr, exit)
	}
}

func TestRunWithDepsForbidWinsBeforeExec(t *testing.T) {
	policyPath, auditPath := writePolicy(t, validPolicy(t.TempDir(), t.TempDir()))
	var input bytes.Buffer
	if err := protocol.WriteRequest(&input, protocol.Request{Program: "git", Argv: []string{"push", "origin"}, GuestCwd: "/workspace/project"}); err != nil {
		t.Fatalf("WriteRequest() error = %v", err)
	}
	var out bytes.Buffer
	code := runWithDeps([]string{"proxy", policyPath}, &input, &out, proxyDeps{
		lookPath: func(string) (string, error) {
			t.Fatalf("lookPath should not run for denied request")
			return "", nil
		},
		runCommand: func(string, []string, string, io.Reader, io.Writer, io.Writer) (int, error) {
			t.Fatalf("runCommand should not run for denied request")
			return 0, nil
		},
		now: fixedNow,
	})
	if code != policyDeniedExit {
		t.Fatalf("runWithDeps() = %d, want %d", code, policyDeniedExit)
	}
	_, stderr, exit := collectFrames(t, &out)
	if exit != policyDeniedExit || !strings.Contains(stderr, "forbid rule matched git push") {
		t.Fatalf("stderr=%q exit=%d", stderr, exit)
	}
	events := readAuditEvents(t, auditPath)
	if len(events) != 1 || events[0].Decision != "denied" || !strings.Contains(events[0].Reason, "forbid rule") {
		t.Fatalf("audit events = %#v", events)
	}
}

func TestRunWithDepsRejectsCwdOutsideProject(t *testing.T) {
	policyPath, _ := writePolicy(t, validPolicy(t.TempDir(), t.TempDir()))
	var input bytes.Buffer
	if err := protocol.WriteRequest(&input, protocol.Request{Program: "git", Argv: []string{"status"}, GuestCwd: "/tmp"}); err != nil {
		t.Fatalf("WriteRequest() error = %v", err)
	}
	var out bytes.Buffer
	code := runWithDeps([]string{"proxy", policyPath}, &input, &out, proxyDeps{now: fixedNow})
	_, stderr, exit := collectFrames(t, &out)
	if code != policyDeniedExit || exit != policyDeniedExit || !strings.Contains(stderr, "outside project mount") {
		t.Fatalf("code=%d stderr=%q exit=%d", code, stderr, exit)
	}
}

func TestRunWithDepsMissingExecutableReturns127(t *testing.T) {
	policyPath, auditPath := writePolicy(t, validPolicy(t.TempDir(), t.TempDir()))
	var input bytes.Buffer
	if err := protocol.WriteRequest(&input, protocol.Request{Program: "git", Argv: []string{"status"}, GuestCwd: "/workspace/project"}); err != nil {
		t.Fatalf("WriteRequest() error = %v", err)
	}
	var out bytes.Buffer
	code := runWithDeps([]string{"proxy", policyPath}, &input, &out, proxyDeps{
		lookPath: func(string) (string, error) { return "", errors.New("missing") },
		now:      fixedNow,
	})
	_, stderr, exit := collectFrames(t, &out)
	if code != startFailedExit || exit != startFailedExit || !strings.Contains(stderr, "not found") {
		t.Fatalf("code=%d stderr=%q exit=%d", code, stderr, exit)
	}
	events := readAuditEvents(t, auditPath)
	if len(events) != 1 || events[0].Decision != "allowed" || events[0].ExitStatus == nil || *events[0].ExitStatus != startFailedExit {
		t.Fatalf("audit events = %#v", events)
	}
}

func TestLoadPolicyAcceptsStringRules(t *testing.T) {
	path, _ := writePolicy(t, `{
		"allow": ["git"],
		"forbid": ["git push"],
		"projectRoot": "/tmp/project",
		"projectMount": "/workspace/project",
		"auditLog": "/tmp/audit.jsonl"
	}`)
	pol, err := loadPolicy(path)
	if err != nil {
		t.Fatalf("loadPolicy() error = %v", err)
	}
	if len(pol.allow) != 1 || pol.allow[0].Program != "git" || len(pol.allow[0].ArgvPrefix) != 0 {
		t.Fatalf("allow = %#v, want git with empty prefix", pol.allow)
	}
	if len(pol.forbid) != 1 || pol.forbid[0].Program != "git" || strings.Join(pol.forbid[0].ArgvPrefix, " ") != "push" {
		t.Fatalf("forbid = %#v, want git push", pol.forbid)
	}
}

func TestLoadPolicyRejectsEmptyStringRule(t *testing.T) {
	path, _ := writePolicy(t, `{
		"allow": ["   "],
		"forbid": [],
		"projectRoot": "/tmp/project",
		"projectMount": "/workspace/project",
		"auditLog": "/tmp/audit.jsonl"
	}`)
	if _, err := loadPolicy(path); err == nil || !strings.Contains(err.Error(), "rule string must not be empty") {
		t.Fatalf("loadPolicy() error = %v, want empty string rule", err)
	}
}

func TestLoadPolicyRejectsStructuredRule(t *testing.T) {
	path, _ := writePolicy(t, `{
		"allow": [{"program": "git", "argvPrefix": []}],
		"forbid": [],
		"projectRoot": "/tmp/project",
		"projectMount": "/workspace/project",
		"auditLog": "/tmp/audit.jsonl"
	}`)
	if _, err := loadPolicy(path); err == nil || !strings.Contains(err.Error(), "cannot unmarshal object") {
		t.Fatalf("loadPolicy() error = %v, want object rule rejection", err)
	}
}

func TestLoadPolicyRejectsUnknownFields(t *testing.T) {
	path := filepath.Join(t.TempDir(), "policy.json")
	if err := os.WriteFile(path, []byte(`{
		"allow": ["git"],
		"forbid": [],
		"projectRoot": "/tmp/project",
		"projectMount": "/workspace/project",
		"auditLog": "/tmp/audit.jsonl",
		"unexpected": true
	}`), 0o600); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}
	if _, err := loadPolicy(path); err == nil || !strings.Contains(err.Error(), "unknown field") {
		t.Fatalf("loadPolicy() error = %v, want unknown field", err)
	}
}

func TestMapGuestCwd(t *testing.T) {
	host, err := mapGuestCwd("/workspace/project/sub", "/workspace/project", "/host/project")
	if err != nil || host != "/host/project/sub" {
		t.Fatalf("mapGuestCwd() = %q, %v", host, err)
	}
	if _, err := mapGuestCwd("/workspace/other", "/workspace/project", "/host/project"); err == nil {
		t.Fatalf("mapGuestCwd(outside) returned nil error")
	}
}

func validPolicy(projectRoot string, auditDir string) string {
	return `{
		"allow": ["git"],
		"forbid": ["git push"],
		"projectRoot": "` + escapeJSON(projectRoot) + `",
		"projectMount": "/workspace/project",
		"auditLog": "` + escapeJSON(filepath.Join(auditDir, "audit.jsonl")) + `"
	}`
}

func writePolicy(t *testing.T, contents string) (string, string) {
	t.Helper()
	var raw struct {
		AuditLog string `json:"auditLog"`
	}
	_ = json.Unmarshal([]byte(contents), &raw)
	path := filepath.Join(t.TempDir(), "policy.json")
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}
	return path, raw.AuditLog
}

func collectFrames(t *testing.T, r io.Reader) (string, string, int) {
	t.Helper()
	var stdout strings.Builder
	var stderr strings.Builder
	for {
		frame, err := protocol.ReadFrame(r)
		if err != nil {
			t.Fatalf("ReadFrame() error = %v", err)
		}
		switch frame.Stream {
		case protocol.StreamStdout:
			stdout.Write(frame.Data)
		case protocol.StreamStderr:
			stderr.Write(frame.Data)
		case protocol.StreamExit:
			code, err := frame.ExitCode()
			if err != nil {
				t.Fatalf("ExitCode() error = %v", err)
			}
			return stdout.String(), stderr.String(), code
		}
	}
}

func readAuditEvents(t *testing.T, path string) []auditEvent {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile(audit) error = %v", err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	events := make([]auditEvent, 0, len(lines))
	for _, line := range lines {
		var ev auditEvent
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			t.Fatalf("audit JSON %q: %v", line, err)
		}
		events = append(events, ev)
	}
	return events
}

func escapeJSON(s string) string {
	data, _ := json.Marshal(s)
	return strings.Trim(string(data), "\"")
}

func fixedNow() time.Time {
	return time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
}
