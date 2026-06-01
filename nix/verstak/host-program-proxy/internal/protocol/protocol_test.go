package protocol

import (
	"bytes"
	"encoding/binary"
	"io"
	"strings"
	"testing"
)

func TestRequestRoundTrip(t *testing.T) {
	var buf bytes.Buffer
	want := Request{Program: "git", Argv: []string{"status", "--short"}, GuestCwd: "/workspace/project/sub"}
	if err := WriteRequest(&buf, want); err != nil {
		t.Fatalf("WriteRequest() error = %v", err)
	}
	got, err := ReadRequest(&buf)
	if err != nil {
		t.Fatalf("ReadRequest() error = %v", err)
	}
	if got.Program != want.Program || got.GuestCwd != want.GuestCwd || strings.Join(got.Argv, "\x00") != strings.Join(want.Argv, "\x00") {
		t.Fatalf("ReadRequest() = %#v, want %#v", got, want)
	}
}

func TestReadRequestLeavesRawStdinBytes(t *testing.T) {
	var buf bytes.Buffer
	if err := WriteRequest(&buf, Request{Program: "git", GuestCwd: "/workspace/project"}); err != nil {
		t.Fatalf("WriteRequest() error = %v", err)
	}
	buf.WriteString("raw stdin")
	if _, err := ReadRequest(&buf); err != nil {
		t.Fatalf("ReadRequest() error = %v", err)
	}
	remaining, err := io.ReadAll(&buf)
	if err != nil {
		t.Fatalf("ReadAll() error = %v", err)
	}
	if string(remaining) != "raw stdin" {
		t.Fatalf("remaining bytes = %q, want raw stdin", string(remaining))
	}
}

func TestReadRequestRejectsOversizedHeader(t *testing.T) {
	var buf bytes.Buffer
	var raw [4]byte
	binary.BigEndian.PutUint32(raw[:], MaxRequestBytes+1)
	buf.Write(raw[:])
	if _, err := ReadRequest(&buf); err == nil || !strings.Contains(err.Error(), "exceeds limit") {
		t.Fatalf("ReadRequest() error = %v, want exceeds limit", err)
	}
}

func TestFrameRoundTripSeparatesStreams(t *testing.T) {
	var buf bytes.Buffer
	if err := WriteDataFrame(&buf, StreamStdout, []byte("out")); err != nil {
		t.Fatalf("WriteDataFrame(stdout) error = %v", err)
	}
	if err := WriteDataFrame(&buf, StreamStderr, []byte("err")); err != nil {
		t.Fatalf("WriteDataFrame(stderr) error = %v", err)
	}
	if err := WriteExitFrame(&buf, 17); err != nil {
		t.Fatalf("WriteExitFrame() error = %v", err)
	}

	stdout, err := ReadFrame(&buf)
	if err != nil || stdout.Stream != StreamStdout || string(stdout.Data) != "out" {
		t.Fatalf("stdout frame = %#v, err = %v", stdout, err)
	}
	stderr, err := ReadFrame(&buf)
	if err != nil || stderr.Stream != StreamStderr || string(stderr.Data) != "err" {
		t.Fatalf("stderr frame = %#v, err = %v", stderr, err)
	}
	exit, err := ReadFrame(&buf)
	if err != nil || exit.Stream != StreamExit {
		t.Fatalf("exit frame = %#v, err = %v", exit, err)
	}
	code, err := exit.ExitCode()
	if err != nil || code != 17 {
		t.Fatalf("ExitCode() = %d, %v; want 17, nil", code, err)
	}
}

func TestWriteDataFrameRejectsInvalidStream(t *testing.T) {
	var buf bytes.Buffer
	if err := WriteDataFrame(&buf, StreamExit, []byte("not data")); err == nil {
		t.Fatalf("WriteDataFrame(StreamExit) returned nil error")
	}
}

func TestReadFrameRejectsUnknownStream(t *testing.T) {
	buf := bytes.NewBuffer([]byte{99, 0, 0, 0, 0})
	if _, err := ReadFrame(buf); err == nil || !strings.Contains(err.Error(), "unknown frame stream") {
		t.Fatalf("ReadFrame() error = %v, want unknown stream", err)
	}
}

func TestExitCodeRejectsInvalidPayload(t *testing.T) {
	frame := Frame{Stream: StreamExit, Data: []byte(`{"code":300}`)}
	if _, err := frame.ExitCode(); err == nil || !strings.Contains(err.Error(), "outside 0..255") {
		t.Fatalf("ExitCode() error = %v, want outside range", err)
	}
	frame = Frame{Stream: StreamStdout, Data: []byte("x")}
	if _, err := frame.ExitCode(); err == nil {
		t.Fatalf("ExitCode() on stdout frame returned nil error")
	}
}

func TestReadFrameReturnsEOF(t *testing.T) {
	if _, err := ReadFrame(bytes.NewReader(nil)); err != io.EOF {
		t.Fatalf("ReadFrame(empty) error = %v, want io.EOF", err)
	}
}
