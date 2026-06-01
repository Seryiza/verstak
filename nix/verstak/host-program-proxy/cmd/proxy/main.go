package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/seryiza/verstak/nix/verstak/host-program-proxy/internal/protocol"
)

const (
	policyDeniedExit = 126
	startFailedExit  = 127
	usageExit        = 2
)

var programNamePattern = regexp.MustCompile(`^[A-Za-z0-9._+-]+$`)

type rawPolicy struct {
	Allow        []string `json:"allow"`
	Forbid       []string `json:"forbid"`
	ProjectRoot  string   `json:"projectRoot"`
	ProjectMount string   `json:"projectMount"`
	AuditLog     string   `json:"auditLog"`
}

type rule struct {
	Program    string
	ArgvPrefix []string
}

func parseRuleString(value string) (rule, error) {
	tokens := strings.Fields(value)
	if len(tokens) == 0 {
		return rule{}, errors.New("rule string must not be empty")
	}
	return rule{Program: tokens[0], ArgvPrefix: append([]string(nil), tokens[1:]...)}, nil
}

func parseRuleStrings(kind string, values []string) ([]rule, error) {
	rules := make([]rule, 0, len(values))
	for i, value := range values {
		r, err := parseRuleString(value)
		if err != nil {
			return nil, fmt.Errorf("%s[%d]: %w", kind, i, err)
		}
		rules = append(rules, r)
	}
	return rules, nil
}

type policy struct {
	allow        []rule
	forbid       []rule
	projectRoot  string
	projectMount string
	auditLog     string
}

type decision struct {
	allowed bool
	reason  string
}

type auditEvent struct {
	Time       string   `json:"time"`
	Program    string   `json:"program"`
	Argv       []string `json:"argv"`
	GuestCwd   string   `json:"guestCwd"`
	HostCwd    string   `json:"hostCwd,omitempty"`
	Decision   string   `json:"decision"`
	Reason     string   `json:"reason,omitempty"`
	ExitStatus *int     `json:"exitStatus,omitempty"`
}

type proxyDeps struct {
	lookPath   func(string) (string, error)
	runCommand func(exe string, argv []string, dir string, stdin io.Reader, stdout io.Writer, stderr io.Writer) (int, error)
	now        func() time.Time
}

func main() {
	os.Exit(runWithDeps(os.Args, os.Stdin, os.Stdout, defaultProxyDeps()))
}

func defaultProxyDeps() proxyDeps {
	return proxyDeps{
		lookPath:   exec.LookPath,
		runCommand: runHostCommand,
		now:        time.Now,
	}
}

func runWithDeps(args []string, stdin io.Reader, framedOut io.Writer, deps proxyDeps) int {
	if deps.lookPath == nil {
		deps.lookPath = exec.LookPath
	}
	if deps.runCommand == nil {
		deps.runCommand = runHostCommand
	}
	if deps.now == nil {
		deps.now = time.Now
	}

	if len(args) != 2 {
		return writeFailure(framedOut, fmt.Sprintf("usage: %s <policy-json>", programName(args)), usageExit)
	}

	pol, err := loadPolicy(args[1])
	if err != nil {
		return writeFailure(framedOut, "failed to load host-program policy: "+err.Error(), usageExit)
	}

	req, err := protocol.ReadRequest(stdin)
	if err != nil {
		return writeFailure(framedOut, "malformed host-program request: "+err.Error(), usageExit)
	}
	if err := validateProgram(req.Program); err != nil {
		return deny(pol, framedOut, deps, req, "invalid requested program: "+err.Error(), "", policyDeniedExit)
	}

	hostCwd, err := mapGuestCwd(req.GuestCwd, pol.projectMount, pol.projectRoot)
	if err != nil {
		return deny(pol, framedOut, deps, req, err.Error(), "", policyDeniedExit)
	}

	dec := pol.decide(req)
	if !dec.allowed {
		return deny(pol, framedOut, deps, req, dec.reason, hostCwd, policyDeniedExit)
	}

	if err := ensureAuditWritable(pol.auditLog); err != nil {
		return writeFailure(framedOut, "host-program audit log unavailable: "+err.Error(), startFailedExit)
	}

	exe, err := deps.lookPath(req.Program)
	if err != nil {
		code := startFailedExit
		_ = writeAudit(pol.auditLog, deps.now(), auditEvent{
			Program: req.Program, Argv: req.Argv, GuestCwd: req.GuestCwd, HostCwd: hostCwd,
			Decision: "allowed", Reason: "executable lookup failed: " + err.Error(), ExitStatus: &code,
		})
		return writeFailure(framedOut, fmt.Sprintf("host program %q not found on host PATH", req.Program), code)
	}

	var mu sync.Mutex
	stdout := frameWriter{w: framedOut, stream: protocol.StreamStdout, mu: &mu}
	stderr := frameWriter{w: framedOut, stream: protocol.StreamStderr, mu: &mu}
	code, runErr := deps.runCommand(exe, req.Argv, hostCwd, stdin, stdout, stderr)
	if runErr != nil {
		_, _ = stderr.Write([]byte("failed to run host program: " + runErr.Error() + "\n"))
	}
	_ = writeAudit(pol.auditLog, deps.now(), auditEvent{
		Program: req.Program, Argv: req.Argv, GuestCwd: req.GuestCwd, HostCwd: hostCwd,
		Decision: "allowed", Reason: dec.reason, ExitStatus: &code,
	})
	mu.Lock()
	defer mu.Unlock()
	if err := protocol.WriteExitFrame(framedOut, code); err != nil {
		return startFailedExit
	}
	return code
}

func loadPolicy(path string) (*policy, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	var raw rawPolicy
	if err := dec.Decode(&raw); err != nil {
		if strings.Contains(err.Error(), "rawPolicy.allow") || strings.Contains(err.Error(), "rawPolicy.forbid") {
			return nil, fmt.Errorf("parse %s: allow/forbid entries must be string token-prefix rules: %w", path, err)
		}
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	if err := dec.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return nil, fmt.Errorf("parse %s: trailing JSON data", path)
	}
	allow, err := parseRuleStrings("allow", raw.Allow)
	if err != nil {
		return nil, err
	}
	forbid, err := parseRuleStrings("forbid", raw.Forbid)
	if err != nil {
		return nil, err
	}
	pol := &policy{
		allow:        allow,
		forbid:       forbid,
		projectRoot:  filepath.Clean(raw.ProjectRoot),
		projectMount: filepath.Clean(raw.ProjectMount),
		auditLog:     raw.AuditLog,
	}
	if err := pol.validate(); err != nil {
		return nil, err
	}
	return pol, nil
}

func (p *policy) validate() error {
	if len(p.allow) == 0 {
		return errors.New("policy has no allow rules")
	}
	if p.projectRoot == "." || !filepath.IsAbs(p.projectRoot) {
		return fmt.Errorf("projectRoot must be absolute, got %q", p.projectRoot)
	}
	if p.projectMount == "." || !filepath.IsAbs(p.projectMount) {
		return fmt.Errorf("projectMount must be absolute, got %q", p.projectMount)
	}
	if strings.TrimSpace(p.auditLog) == "" {
		return errors.New("auditLog is required")
	}
	for i, r := range p.allow {
		if err := validateRule(r); err != nil {
			return fmt.Errorf("allow[%d]: %w", i, err)
		}
	}
	for i, r := range p.forbid {
		if err := validateRule(r); err != nil {
			return fmt.Errorf("forbid[%d]: %w", i, err)
		}
	}
	return nil
}

func validateRule(r rule) error {
	if err := validateProgram(r.Program); err != nil {
		return err
	}
	for i, token := range r.ArgvPrefix {
		if strings.ContainsRune(token, '\x00') {
			return fmt.Errorf("argument prefix token %d contains NUL", i)
		}
	}
	return nil
}

func validateProgram(program string) error {
	if program == "" {
		return errors.New("program is required")
	}
	if program == "." || program == ".." {
		return errors.New("program cannot be . or ..")
	}
	if strings.Contains(program, "/") || !programNamePattern.MatchString(program) {
		return fmt.Errorf("program %q is not a simple host PATH name", program)
	}
	return nil
}

func (p *policy) decide(req protocol.Request) decision {
	for _, r := range p.forbid {
		if r.matches(req) {
			return decision{allowed: false, reason: fmt.Sprintf("forbid rule matched %s", describeRule(r))}
		}
	}
	for _, r := range p.allow {
		if r.matches(req) {
			return decision{allowed: true, reason: fmt.Sprintf("allow rule matched %s", describeRule(r))}
		}
	}
	return decision{allowed: false, reason: "no allow rule matched"}
}

func (r rule) matches(req protocol.Request) bool {
	if r.Program != req.Program || len(r.ArgvPrefix) > len(req.Argv) {
		return false
	}
	for i, token := range r.ArgvPrefix {
		if req.Argv[i] != token {
			return false
		}
	}
	return true
}

func describeRule(r rule) string {
	if len(r.ArgvPrefix) == 0 {
		return r.Program
	}
	return r.Program + " " + strings.Join(r.ArgvPrefix, " ")
}

func mapGuestCwd(guestCwd, guestRoot, hostRoot string) (string, error) {
	guestCwd = filepath.Clean(guestCwd)
	guestRoot = filepath.Clean(guestRoot)
	hostRoot = filepath.Clean(hostRoot)
	if !filepath.IsAbs(guestCwd) {
		return "", fmt.Errorf("guest cwd %q is not absolute", guestCwd)
	}
	if guestCwd == guestRoot {
		return hostRoot, nil
	}
	prefix := guestRoot + string(os.PathSeparator)
	if !strings.HasPrefix(guestCwd, prefix) {
		return "", fmt.Errorf("guest cwd %q is outside project mount %q", guestCwd, guestRoot)
	}
	rel := strings.TrimPrefix(guestCwd, prefix)
	return filepath.Join(hostRoot, rel), nil
}

func deny(pol *policy, framedOut io.Writer, deps proxyDeps, req protocol.Request, reason string, hostCwd string, code int) int {
	_ = writeAudit(pol.auditLog, deps.now(), auditEvent{
		Program: req.Program, Argv: req.Argv, GuestCwd: req.GuestCwd, HostCwd: hostCwd,
		Decision: "denied", Reason: reason, ExitStatus: &code,
	})
	return writeFailure(framedOut, "host program denied: "+reason, code)
}

func writeFailure(framedOut io.Writer, message string, code int) int {
	_ = protocol.WriteDataFrame(framedOut, protocol.StreamStderr, []byte(message+"\n"))
	_ = protocol.WriteExitFrame(framedOut, code)
	return code
}

func runHostCommand(exe string, argv []string, dir string, stdin io.Reader, stdout io.Writer, stderr io.Writer) (int, error) {
	cmd := exec.Command(exe, argv...)
	cmd.Dir = dir
	cmd.Stdin = stdin
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	err := cmd.Run()
	if err == nil {
		return 0, nil
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return normalizeExitCode(exitErr), nil
	}
	return startFailedExit, err
}

func normalizeExitCode(exitErr *exec.ExitError) int {
	code := exitErr.ExitCode()
	if code >= 0 {
		return code
	}
	if status, ok := exitErr.Sys().(syscall.WaitStatus); ok && status.Signaled() {
		return 128 + int(status.Signal())
	}
	return 128
}

type frameWriter struct {
	w      io.Writer
	stream protocol.Stream
	mu     *sync.Mutex
}

func (w frameWriter) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if err := protocol.WriteDataFrame(w.w, w.stream, p); err != nil {
		return 0, err
	}
	return len(p), nil
}

func ensureAuditWritable(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	return f.Close()
}

func writeAudit(path string, now time.Time, ev auditEvent) error {
	ev.Time = now.UTC().Format(time.RFC3339Nano)
	if err := ensureAuditWritable(path); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	return json.NewEncoder(f).Encode(ev)
}

func programName(args []string) string {
	if len(args) == 0 || args[0] == "" {
		return "verstak-host-program-proxy"
	}
	return args[0]
}
