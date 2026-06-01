package protocol

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

const (
	MaxRequestBytes = 64 * 1024
	MaxFrameBytes   = 16 * 1024 * 1024
	CopyBufferSize  = 64 * 1024
)

// Client-to-proxy traffic begins with one length-prefixed JSON Request. Any
// bytes after that request are the child's stdin stream and remain raw until
// EOF or TCP half-close. Proxy-to-client traffic is framed so stdout, stderr,
// and final exit status stay separate over QEMU guestfwd's single byte stream.
type Stream byte

const (
	StreamStdout Stream = 1
	StreamStderr Stream = 2
	StreamExit   Stream = 3
)

type Request struct {
	Program  string   `json:"program"`
	Argv     []string `json:"argv"`
	GuestCwd string   `json:"guestCwd"`
}

type ExitStatus struct {
	Code int `json:"code"`
}

type Frame struct {
	Stream Stream
	Data   []byte
}

func WriteRequest(w io.Writer, req Request) error {
	data, err := json.Marshal(req)
	if err != nil {
		return fmt.Errorf("marshal request: %w", err)
	}
	if len(data) == 0 || len(data) > MaxRequestBytes {
		return fmt.Errorf("request length %d exceeds limit %d", len(data), MaxRequestBytes)
	}
	if err := writeLength(w, uint32(len(data))); err != nil {
		return err
	}
	_, err = w.Write(data)
	return err
}

// ReadRequest consumes only the request prefix. Callers should pass the same
// reader to the child stdin copier afterward so remaining bytes are streamed as
// raw stdin.
func ReadRequest(r io.Reader) (Request, error) {
	length, err := readLength(r)
	if err != nil {
		return Request{}, err
	}
	if length == 0 || length > MaxRequestBytes {
		return Request{}, fmt.Errorf("request length %d exceeds limit %d", length, MaxRequestBytes)
	}
	data := make([]byte, length)
	if _, err := io.ReadFull(r, data); err != nil {
		return Request{}, fmt.Errorf("read request: %w", err)
	}
	var req Request
	if err := json.Unmarshal(data, &req); err != nil {
		return Request{}, fmt.Errorf("decode request: %w", err)
	}
	return req, nil
}

func WriteDataFrame(w io.Writer, stream Stream, data []byte) error {
	if stream != StreamStdout && stream != StreamStderr {
		return fmt.Errorf("invalid data stream %d", stream)
	}
	return writeFrame(w, stream, data)
}

func WriteExitFrame(w io.Writer, code int) error {
	data, err := json.Marshal(ExitStatus{Code: code})
	if err != nil {
		return fmt.Errorf("marshal exit status: %w", err)
	}
	return writeFrame(w, StreamExit, data)
}

func ReadFrame(r io.Reader) (Frame, error) {
	var typ [1]byte
	if _, err := io.ReadFull(r, typ[:]); err != nil {
		return Frame{}, err
	}
	length, err := readLength(r)
	if err != nil {
		return Frame{}, err
	}
	if length > MaxFrameBytes {
		return Frame{}, fmt.Errorf("frame length %d exceeds limit %d", length, MaxFrameBytes)
	}
	frame := Frame{Stream: Stream(typ[0]), Data: make([]byte, length)}
	if _, err := io.ReadFull(r, frame.Data); err != nil {
		return Frame{}, fmt.Errorf("read frame payload: %w", err)
	}
	switch frame.Stream {
	case StreamStdout, StreamStderr, StreamExit:
		return frame, nil
	default:
		return Frame{}, fmt.Errorf("unknown frame stream %d", frame.Stream)
	}
}

func (f Frame) ExitCode() (int, error) {
	if f.Stream != StreamExit {
		return 0, errors.New("frame is not an exit frame")
	}
	var status ExitStatus
	if err := json.Unmarshal(f.Data, &status); err != nil {
		return 0, fmt.Errorf("decode exit status: %w", err)
	}
	if status.Code < 0 || status.Code > 255 {
		return 0, fmt.Errorf("exit code %d outside 0..255", status.Code)
	}
	return status.Code, nil
}

func writeFrame(w io.Writer, stream Stream, data []byte) error {
	if len(data) > MaxFrameBytes {
		return fmt.Errorf("frame length %d exceeds limit %d", len(data), MaxFrameBytes)
	}
	if _, err := w.Write([]byte{byte(stream)}); err != nil {
		return err
	}
	if err := writeLength(w, uint32(len(data))); err != nil {
		return err
	}
	_, err := w.Write(data)
	return err
}

func writeLength(w io.Writer, length uint32) error {
	var buf [4]byte
	binary.BigEndian.PutUint32(buf[:], length)
	_, err := w.Write(buf[:])
	return err
}

func readLength(r io.Reader) (uint32, error) {
	var buf [4]byte
	if _, err := io.ReadFull(r, buf[:]); err != nil {
		return 0, err
	}
	return binary.BigEndian.Uint32(buf[:]), nil
}
