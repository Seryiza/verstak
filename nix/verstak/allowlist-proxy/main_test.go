package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

func TestLoadPolicyNormalizesDomains(t *testing.T) {
	policyPath := writePolicyFile(t, `{
		"allowedDomains": [" API.OpenAI.Com. "],
		"allowedTCPPorts": [443],
		"blockedIPv4Ranges": ["192.168.0.0/16"],
		"blockedIPv6Ranges": []
	}`)
	pol, err := loadPolicy(policyPath)
	if err != nil {
		t.Fatalf("loadPolicy() returned error: %v", err)
	}
	if len(pol.allowedDomains) != 1 || pol.allowedDomains[0] != "api.openai.com" {
		t.Fatalf("allowedDomains = %#v, want [api.openai.com]", pol.allowedDomains)
	}
}

func TestPolicyDoesNotBlockPublic192(t *testing.T) {
	pol := &policy{blockedRanges: []netip.Prefix{
		netip.MustParsePrefix("192.0.0.0/24"),
		netip.MustParsePrefix("192.0.2.0/24"),
		netip.MustParsePrefix("192.88.99.0/24"),
		netip.MustParsePrefix("192.168.0.0/16"),
	}}
	if pol.isBlockedAddr(netip.MustParseAddr("192.34.56.78")) {
		t.Fatalf("expected public 192.34.56.78 to be allowed")
	}
	for _, raw := range []string{"192.0.0.1", "192.0.2.1", "192.88.99.1", "192.168.1.1"} {
		if !pol.isBlockedAddr(netip.MustParseAddr(raw)) {
			t.Fatalf("expected %s to be blocked", raw)
		}
	}
}

func TestRunWithDepsReturnsInitialByteError(t *testing.T) {
	policyPath := writePolicyFile(t, validPolicyJSON())
	stdin := emptyPipe(t)
	err := runWithDeps([]string{"proxy", policyPath, "443"}, stdin, io.Discard, proxyDeps{
		lookupIP: func(context.Context, string) ([]netip.Addr, error) {
			t.Fatalf("lookupIP should not be called")
			return nil, nil
		},
	})
	if err == nil || !strings.Contains(err.Error(), "empty connection") {
		t.Fatalf("runWithDeps() error = %v, want empty connection", err)
	}
}

func TestRunWithDepsRejectsBlockedResolvedAddress(t *testing.T) {
	policyPath := writePolicyFile(t, validPolicyJSON())
	stdin := pipeWithBytes(t, []byte("GET / HTTP/1.1\r\nHost: api.openai.com\r\n\r\n"))
	err := runWithDeps([]string{"proxy", policyPath, "443"}, stdin, io.Discard, proxyDeps{
		lookupIP: func(context.Context, string) ([]netip.Addr, error) {
			return []netip.Addr{netip.MustParseAddr("10.0.0.1")}, nil
		},
		dial: func(context.Context, *net.Dialer, string, int, []netip.Addr) (net.Conn, netip.Addr, error) {
			t.Fatalf("dial should not be called")
			return nil, netip.Addr{}, nil
		},
	})
	if err == nil || !strings.Contains(err.Error(), "blocked resolved address") {
		t.Fatalf("runWithDeps() error = %v, want blocked resolved address", err)
	}
}

func TestRunWithDepsReportsDialFailure(t *testing.T) {
	policyPath := writePolicyFile(t, validPolicyJSON())
	stdin := pipeWithBytes(t, []byte("GET / HTTP/1.1\r\nHost: api.openai.com\r\n\r\n"))
	wantErr := errors.New("dial failed")
	err := runWithDeps([]string{"proxy", policyPath, "443"}, stdin, io.Discard, proxyDeps{
		lookupIP: func(context.Context, string) ([]netip.Addr, error) {
			return []netip.Addr{netip.MustParseAddr("8.8.8.8")}, nil
		},
		dial: func(context.Context, *net.Dialer, string, int, []netip.Addr) (net.Conn, netip.Addr, error) {
			return nil, netip.Addr{}, wantErr
		},
	})
	if !errors.Is(err, wantErr) {
		t.Fatalf("runWithDeps() error = %v, want %v", err, wantErr)
	}
}

func TestProxyCopyDrainsBothDirectionsAfterWriteError(t *testing.T) {
	wantErr := errors.New("client write failed")
	conn := &copyFailureConn{writeErr: wantErr}
	err := proxyCopy(conn, io.NopCloser(strings.NewReader("request body")), io.Discard)
	if !errors.Is(err, wantErr) {
		t.Fatalf("proxyCopy() error = %v, want %v", err, wantErr)
	}
	if conn.closeCount < 1 {
		t.Fatalf("proxyCopy() did not close upstream")
	}
}

func TestProxyCopyCleanClientThenUpstreamCompletion(t *testing.T) {
	conn := &scriptedConn{readChunks: [][]byte{[]byte("response")}}
	var stdout bytes.Buffer
	if err := proxyCopy(conn, io.NopCloser(strings.NewReader("request")), &stdout); err != nil {
		t.Fatalf("proxyCopy() returned error: %v", err)
	}
	if stdout.String() != "response" {
		t.Fatalf("stdout = %q, want response", stdout.String())
	}
	if got := conn.writes.String(); got != "request" {
		t.Fatalf("upstream writes = %q, want request", got)
	}
}

func TestProxyCopyClosesClientReaderAfterUpstreamCompletion(t *testing.T) {
	conn := &scriptedConn{readChunks: [][]byte{[]byte("response")}}
	stdin := newBlockingReadCloser()
	var stdout bytes.Buffer
	errCh := make(chan error, 1)
	go func() {
		errCh <- proxyCopy(conn, stdin, &stdout)
	}()

	select {
	case err := <-errCh:
		if err != nil {
			t.Fatalf("proxyCopy() returned error: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("proxyCopy() did not return after upstream completion")
	}
	if !stdin.isClosed() {
		t.Fatalf("proxyCopy() did not close client reader")
	}
}

func TestFdSetRejectsUnrepresentableDescriptors(t *testing.T) {
	var set syscall.FdSet
	if err := fdSet(-1, &set); err == nil {
		t.Fatalf("fdSet(-1) returned nil error")
	}
	if err := fdSet(len(set.Bits)*64, &set); err == nil {
		t.Fatalf("fdSet(out-of-range) returned nil error")
	}
	if err := fdSet(0, &set); err != nil {
		t.Fatalf("fdSet(0) returned error: %v", err)
	}
}

func TestExtractHostParsesHTTPHostOnCustomPort(t *testing.T) {
	data := []byte("GET /v1/models HTTP/1.1\r\nHost: api.openai.com:8080\r\nUser-Agent: test\r\n\r\n")
	if got := extractHost(data); got != "api.openai.com" {
		t.Fatalf("extractHost() = %q, want api.openai.com", got)
	}
}

func TestExtractHostFallsBackToTLSSNI(t *testing.T) {
	data := clientHelloBytes(t, "chatgpt.com")
	if got := extractHost(data); got != "chatgpt.com" {
		t.Fatalf("extractHost() = %q, want chatgpt.com", got)
	}
}

func TestExtractHostParsesFragmentedTLSClientHello(t *testing.T) {
	data := fragmentTLSHandshakeRecord(t, clientHelloBytes(t, "api.openai.com"), 12)
	firstRecordLen := 5 + (int(data[3])<<8 | int(data[4]))
	if got := parseTLSSNI(data[:firstRecordLen]); got != "" {
		t.Fatalf("parseTLSSNI(first record) = %q, want empty host", got)
	}
	if got := extractHost(data); got != "api.openai.com" {
		t.Fatalf("extractHost(fragmented TLS) = %q, want api.openai.com", got)
	}
}

func TestPolicyAllowsExactAndSubdomain(t *testing.T) {
	pol := &policy{allowedDomains: []string{"openai.com"}}
	for _, host := range []string{"openai.com", "api.openai.com"} {
		if !pol.isAllowedHost(host) {
			t.Fatalf("expected %s to be allowed", host)
		}
	}
	for _, host := range []string{"evilopenai.com", "openai.com.evil.test"} {
		if pol.isAllowedHost(host) {
			t.Fatalf("expected %s to be blocked", host)
		}
	}
}

func TestPolicyRejectsBlockedRangesAndSpecialAddresses(t *testing.T) {
	pol := &policy{blockedRanges: []netip.Prefix{netip.MustParsePrefix("198.51.100.0/24")}}
	blocked := []string{
		"127.0.0.1",
		"10.0.0.1",
		"169.254.1.1",
		"224.0.0.1",
		"198.51.100.12",
		"fc00::1",
		"fe80::1",
	}
	for _, raw := range blocked {
		if !pol.isBlockedAddr(netip.MustParseAddr(raw)) {
			t.Fatalf("expected %s to be blocked", raw)
		}
	}
	if pol.isBlockedAddr(netip.MustParseAddr("8.8.8.8")) {
		t.Fatalf("expected 8.8.8.8 to be allowed")
	}
}

func TestValidatePortUsesPolicy(t *testing.T) {
	pol := &policy{allowedPorts: map[int]struct{}{80: {}, 443: {}, 8080: {}}}
	if err := pol.validatePort(8080); err != nil {
		t.Fatalf("validatePort(8080) returned error: %v", err)
	}
	if err := pol.validatePort(22); err == nil {
		t.Fatalf("validatePort(22) returned nil error")
	}
}

func TestNormalizeHost(t *testing.T) {
	cases := map[string]string{
		" API.OpenAI.Com. ":  "api.openai.com",
		"api.openai.com:443": "api.openai.com",
		"[2001:db8::1]:443":  "2001:db8::1",
		"2001:db8::1":        "2001:db8::1",
	}
	for input, want := range cases {
		if got := normalizeHost(input); got != want {
			t.Fatalf("normalizeHost(%q) = %q, want %q", input, got, want)
		}
	}
}

func validPolicyJSON() string {
	return `{
		"allowedDomains": ["openai.com"],
		"allowedTCPPorts": [443],
		"blockedIPv4Ranges": ["10.0.0.0/8", "192.168.0.0/16"],
		"blockedIPv6Ranges": ["fc00::/7"]
	}`
}

func writePolicyFile(t *testing.T, contents string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "policy.json")
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatalf("failed writing policy: %v", err)
	}
	return path
}

func emptyPipe(t *testing.T) *os.File {
	t.Helper()
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe() error: %v", err)
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("closing writer: %v", err)
	}
	t.Cleanup(func() { _ = reader.Close() })
	return reader
}

func pipeWithBytes(t *testing.T, data []byte) *os.File {
	t.Helper()
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe() error: %v", err)
	}
	if _, err := writer.Write(data); err != nil {
		t.Fatalf("writing pipe: %v", err)
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("closing writer: %v", err)
	}
	t.Cleanup(func() { _ = reader.Close() })
	return reader
}

type blockingReadCloser struct {
	closed chan struct{}
	once   sync.Once
}

func newBlockingReadCloser() *blockingReadCloser {
	return &blockingReadCloser{closed: make(chan struct{})}
}

func (r *blockingReadCloser) Read([]byte) (int, error) {
	<-r.closed
	return 0, io.ErrClosedPipe
}

func (r *blockingReadCloser) Close() error {
	r.once.Do(func() { close(r.closed) })
	return nil
}

func (r *blockingReadCloser) isClosed() bool {
	select {
	case <-r.closed:
		return true
	default:
		return false
	}
}

type copyFailureConn struct {
	writeErr   error
	closeCount int
}

func (c *copyFailureConn) Read([]byte) (int, error)         { return 0, io.EOF }
func (c *copyFailureConn) Write([]byte) (int, error)        { return 0, c.writeErr }
func (c *copyFailureConn) Close() error                     { c.closeCount++; return nil }
func (c *copyFailureConn) LocalAddr() net.Addr              { return dummyAddr("local") }
func (c *copyFailureConn) RemoteAddr() net.Addr             { return dummyAddr("remote") }
func (c *copyFailureConn) SetDeadline(time.Time) error      { return nil }
func (c *copyFailureConn) SetReadDeadline(time.Time) error  { return nil }
func (c *copyFailureConn) SetWriteDeadline(time.Time) error { return nil }

type scriptedConn struct {
	readChunks [][]byte
	writes     bytes.Buffer
}

func (c *scriptedConn) Read(p []byte) (int, error) {
	if len(c.readChunks) == 0 {
		return 0, io.EOF
	}
	n := copy(p, c.readChunks[0])
	c.readChunks = c.readChunks[1:]
	return n, nil
}
func (c *scriptedConn) Write(p []byte) (int, error)      { return c.writes.Write(p) }
func (c *scriptedConn) Close() error                     { return nil }
func (c *scriptedConn) LocalAddr() net.Addr              { return dummyAddr("local") }
func (c *scriptedConn) RemoteAddr() net.Addr             { return dummyAddr("remote") }
func (c *scriptedConn) SetDeadline(time.Time) error      { return nil }
func (c *scriptedConn) SetReadDeadline(time.Time) error  { return nil }
func (c *scriptedConn) SetWriteDeadline(time.Time) error { return nil }

func fragmentTLSHandshakeRecord(t *testing.T, record []byte, firstPayloadLen int) []byte {
	t.Helper()
	if len(record) < 5 || record[0] != 0x16 {
		t.Fatalf("not a TLS handshake record")
	}
	payloadLen := int(record[3])<<8 | int(record[4])
	if len(record) != 5+payloadLen {
		t.Fatalf("record length = %d, want %d", len(record), 5+payloadLen)
	}
	payload := record[5:]
	if firstPayloadLen <= 0 || firstPayloadLen >= len(payload) {
		t.Fatalf("invalid first payload length %d", firstPayloadLen)
	}

	out := make([]byte, 0, len(record)+5)
	appendRecord := func(payload []byte) {
		out = append(out, record[0], record[1], record[2], byte(len(payload)>>8), byte(len(payload)))
		out = append(out, payload...)
	}
	appendRecord(payload[:firstPayloadLen])
	appendRecord(payload[firstPayloadLen:])
	return out
}

func clientHelloBytes(t *testing.T, serverName string) []byte {
	t.Helper()
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()

	result := make(chan []byte, 1)
	errCh := make(chan error, 1)
	go func() {
		defer server.Close()
		_ = server.SetReadDeadline(time.Now().Add(2 * time.Second))
		buf := make([]byte, 4096)
		var data []byte
		for {
			n, err := server.Read(buf)
			if n > 0 {
				data = append(data, buf[:n]...)
				if parseTLSSNI(data) == serverName {
					result <- data
					return
				}
			}
			if err != nil {
				errCh <- err
				return
			}
		}
	}()

	go func() {
		_ = tls.Client(client, &tls.Config{ServerName: serverName, InsecureSkipVerify: true}).Handshake()
	}()

	select {
	case data := <-result:
		return data
	case err := <-errCh:
		t.Fatalf("failed reading client hello: %v", err)
	case <-time.After(2 * time.Second):
		t.Fatalf("timed out reading client hello")
	}
	return nil
}
