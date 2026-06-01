package main

import (
	"bytes"
	"io"
	"strings"
	"sync"
	"testing"

	"github.com/seryiza/verstak/nix/verstak/host-program-proxy/internal/protocol"
)

func TestRunWithDepsSendsRequestStreamsInputAndDemuxesFrames(t *testing.T) {
	conn := newScriptedConn(t, func(w io.Writer) {
		_ = protocol.WriteDataFrame(w, protocol.StreamStdout, []byte("out"))
		_ = protocol.WriteDataFrame(w, protocol.StreamStderr, []byte("err"))
		_ = protocol.WriteExitFrame(w, 7)
	})
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := runWithDeps(
		[]string{"client", "--program", "git", "--addr", "10.0.2.101:22022", "--", "status"},
		strings.NewReader("stdin data"),
		&stdout,
		&stderr,
		clientDeps{
			dial: func(network string, address string) (streamConn, error) {
				if network != "tcp" || address != "10.0.2.101:22022" {
					t.Fatalf("dial(%q, %q)", network, address)
				}
				return conn, nil
			},
			getwd: func() (string, error) { return "/workspace/project/sub", nil },
		},
	)
	if code != 7 {
		t.Fatalf("runWithDeps() = %d, want 7", code)
	}
	if stdout.String() != "out" || stderr.String() != "err" {
		t.Fatalf("stdout=%q stderr=%q", stdout.String(), stderr.String())
	}
	written := bytes.NewBuffer(conn.writes.Bytes())
	req, err := protocol.ReadRequest(written)
	if err != nil {
		t.Fatalf("ReadRequest() error = %v", err)
	}
	if req.Program != "git" || req.GuestCwd != "/workspace/project/sub" || strings.Join(req.Argv, " ") != "status" {
		t.Fatalf("request = %#v", req)
	}
	remaining, err := io.ReadAll(written)
	if err != nil {
		t.Fatalf("ReadAll() error = %v", err)
	}
	if string(remaining) != "stdin data" {
		t.Fatalf("raw stdin = %q", string(remaining))
	}
	if !conn.closeWriteCalled {
		t.Fatalf("CloseWrite was not called after stdin copy")
	}
}

func TestRunWithDepsPropagatesDeniedExit(t *testing.T) {
	conn := newScriptedConn(t, func(w io.Writer) {
		_ = protocol.WriteDataFrame(w, protocol.StreamStderr, []byte("host program denied\n"))
		_ = protocol.WriteExitFrame(w, 126)
	})
	var stderr bytes.Buffer
	code := runWithDeps(
		[]string{"client", "--program", "git", "--addr", "proxy", "--", "push"},
		strings.NewReader(""),
		io.Discard,
		&stderr,
		clientDeps{dial: func(string, string) (streamConn, error) { return conn, nil }, getwd: func() (string, error) { return "/workspace/project", nil }},
	)
	if code != 126 || !strings.Contains(stderr.String(), "host program denied") {
		t.Fatalf("code=%d stderr=%q", code, stderr.String())
	}
}

func TestRunWithDepsRequiresProgram(t *testing.T) {
	var stderr bytes.Buffer
	code := runWithDeps([]string{"client", "--addr", "proxy"}, strings.NewReader(""), io.Discard, &stderr, clientDeps{})
	if code != usageExit || !strings.Contains(stderr.String(), "--program is required") {
		t.Fatalf("code=%d stderr=%q", code, stderr.String())
	}
}

func TestRunWithDepsDetectsMissingExitFrame(t *testing.T) {
	conn := newScriptedConn(t, func(w io.Writer) {
		_ = protocol.WriteDataFrame(w, protocol.StreamStdout, []byte("out"))
	})
	var stderr bytes.Buffer
	code := runWithDeps(
		[]string{"client", "--program", "git", "--addr", "proxy"},
		strings.NewReader(""),
		io.Discard,
		&stderr,
		clientDeps{dial: func(string, string) (streamConn, error) { return conn, nil }, getwd: func() (string, error) { return "/workspace/project", nil }},
	)
	if code != 1 || !strings.Contains(stderr.String(), "ended before exit status") {
		t.Fatalf("code=%d stderr=%q", code, stderr.String())
	}
}

type scriptedConn struct {
	reads            *bytes.Reader
	writes           bytes.Buffer
	ready            chan struct{}
	once             sync.Once
	closeWriteCalled bool
}

func newScriptedConn(t *testing.T, writeFrames func(io.Writer)) *scriptedConn {
	t.Helper()
	var frames bytes.Buffer
	writeFrames(&frames)
	return &scriptedConn{reads: bytes.NewReader(frames.Bytes()), ready: make(chan struct{})}
}

func (c *scriptedConn) Read(p []byte) (int, error) {
	<-c.ready
	return c.reads.Read(p)
}
func (c *scriptedConn) Write(p []byte) (int, error) { return c.writes.Write(p) }
func (c *scriptedConn) Close() error {
	c.once.Do(func() { close(c.ready) })
	return nil
}
func (c *scriptedConn) CloseWrite() error {
	c.closeWriteCalled = true
	c.once.Do(func() { close(c.ready) })
	return nil
}
