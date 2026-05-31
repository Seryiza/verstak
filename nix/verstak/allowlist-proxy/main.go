package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	maxInitial       = 64 * 1024
	initialTimeout   = 5 * time.Second
	continueTimeout  = 250 * time.Millisecond
	connectTimeout   = 10 * time.Second
	copyBufferLength = 64 * 1024
)

var errClientHelloCaptured = errors.New("client hello captured")

type policyFile struct {
	AllowedDomains    []string `json:"allowedDomains"`
	AllowedTCPPorts   []int    `json:"allowedTCPPorts"`
	BlockedIPv4Ranges []string `json:"blockedIPv4Ranges"`
	BlockedIPv6Ranges []string `json:"blockedIPv6Ranges"`
}

type policy struct {
	allowedDomains []string
	allowedPorts   map[int]struct{}
	blockedRanges  []netip.Prefix
}

type proxyDeps struct {
	lookupIP func(context.Context, string) ([]netip.Addr, error)
	dial     func(context.Context, *net.Dialer, string, int, []netip.Addr) (net.Conn, netip.Addr, error)
}

var defaultProxyDeps = proxyDeps{
	lookupIP: func(ctx context.Context, host string) ([]netip.Addr, error) {
		return net.DefaultResolver.LookupNetIP(ctx, "ip", host)
	},
	dial: dialAllowedAddr,
}

func main() {
	if err := run(os.Args, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "verstak allowlist proxy: "+err.Error())
		os.Exit(1)
	}
}

func run(args []string, stdin *os.File, stdout io.Writer) error {
	return runWithDeps(args, stdin, stdout, defaultProxyDeps)
}

func runWithDeps(args []string, stdin *os.File, stdout io.Writer, deps proxyDeps) error {
	if len(args) != 3 {
		return fmt.Errorf("usage: %s <policy-json> <target-port>", args[0])
	}
	targetPort, err := strconv.Atoi(args[2])
	if err != nil || targetPort < 1 || targetPort > 65535 {
		return fmt.Errorf("invalid target port %q", args[2])
	}
	pol, err := loadPolicy(args[1])
	if err != nil {
		return err
	}
	if err := pol.validatePort(targetPort); err != nil {
		return err
	}

	initial, err := readInitial(stdin)
	if err != nil {
		return err
	}
	if len(initial) == 0 {
		return errors.New("empty connection")
	}
	host := extractHost(initial)
	if host == "" {
		return errors.New("could not determine requested host")
	}
	if !pol.isAllowedHost(host) {
		return fmt.Errorf("blocked host %s", host)
	}

	ctx, cancel := context.WithTimeout(context.Background(), connectTimeout)
	defer cancel()
	addrs, err := pol.resolveAllowedAddrs(ctx, host, deps.lookupIP)
	if err != nil {
		return err
	}

	dial := deps.dial
	if dial == nil {
		dial = defaultProxyDeps.dial
	}
	dialer := &net.Dialer{Timeout: connectTimeout}
	upstream, _, err := dial(ctx, dialer, host, targetPort, addrs)
	if err != nil {
		return err
	}
	defer upstream.Close()

	if _, err := upstream.Write(initial); err != nil {
		return fmt.Errorf("failed to send initial bytes to %s:%d: %w", host, targetPort, err)
	}

	return proxyCopy(upstream, stdin, stdout)
}

func proxyCopy(upstream net.Conn, stdin io.ReadCloser, stdout io.Writer) error {
	type copyResult struct {
		direction string
		err       error
	}
	results := make(chan copyResult, 2)

	go func() {
		_, err := io.CopyBuffer(upstream, stdin, make([]byte, copyBufferLength))
		if tcp, ok := upstream.(*net.TCPConn); ok {
			_ = tcp.CloseWrite()
		}
		results <- copyResult{direction: "client-to-upstream", err: err}
	}()

	go func() {
		_, err := io.CopyBuffer(stdout, upstream, make([]byte, copyBufferLength))
		results <- copyResult{direction: "upstream-to-client", err: err}
	}()

	var firstErr error
	stdinDone := false
	stdoutDone := false
	for !stdinDone || !stdoutDone {
		result := <-results
		if result.err != nil && !isIgnorableCopyError(result.err) && firstErr == nil {
			firstErr = fmt.Errorf("%s copy failed: %w", result.direction, result.err)
		}
		if result.direction == "client-to-upstream" && result.err != nil {
			_ = upstream.Close()
		}
		switch result.direction {
		case "client-to-upstream":
			stdinDone = true
		case "upstream-to-client":
			stdoutDone = true
			if !stdinDone {
				_ = upstream.Close()
				_ = stdin.Close()
			}
		}
	}
	_ = upstream.Close()
	return firstErr
}

func isIgnorableCopyError(err error) bool {
	return errors.Is(err, net.ErrClosed) || errors.Is(err, os.ErrClosed) || errors.Is(err, io.ErrClosedPipe)
}

func loadPolicy(path string) (*policy, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read policy %s: %w", path, err)
	}
	var raw policyFile
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("failed to parse policy %s: %w", path, err)
	}
	pol := &policy{
		allowedDomains: make([]string, 0, len(raw.AllowedDomains)),
		allowedPorts:   make(map[int]struct{}, len(raw.AllowedTCPPorts)),
		blockedRanges:  make([]netip.Prefix, 0, len(raw.BlockedIPv4Ranges)+len(raw.BlockedIPv6Ranges)),
	}
	for _, domain := range raw.AllowedDomains {
		normalized := normalizeHost(domain)
		if normalized != "" {
			pol.allowedDomains = append(pol.allowedDomains, normalized)
		}
	}
	for _, port := range raw.AllowedTCPPorts {
		if port < 1 || port > 65535 {
			return nil, fmt.Errorf("invalid allowed TCP port %d", port)
		}
		pol.allowedPorts[port] = struct{}{}
	}
	for _, cidr := range append(raw.BlockedIPv4Ranges, raw.BlockedIPv6Ranges...) {
		prefix, err := netip.ParsePrefix(cidr)
		if err != nil {
			return nil, fmt.Errorf("invalid blocked range %q: %w", cidr, err)
		}
		pol.blockedRanges = append(pol.blockedRanges, prefix)
	}
	if len(pol.allowedDomains) == 0 {
		return nil, errors.New("policy has no allowed domains")
	}
	if len(pol.allowedPorts) == 0 {
		return nil, errors.New("policy has no allowed TCP ports")
	}
	return pol, nil
}

func (p *policy) validatePort(port int) error {
	if _, ok := p.allowedPorts[port]; !ok {
		return fmt.Errorf("target port %d is not in policy", port)
	}
	return nil
}

func (p *policy) isAllowedHost(host string) bool {
	host = normalizeHost(host)
	if host == "" {
		return false
	}
	for _, domain := range p.allowedDomains {
		if host == domain || strings.HasSuffix(host, "."+domain) {
			return true
		}
	}
	return false
}

func (p *policy) resolveAllowedAddrs(ctx context.Context, host string, lookupIP func(context.Context, string) ([]netip.Addr, error)) ([]netip.Addr, error) {
	if lookupIP == nil {
		lookupIP = defaultProxyDeps.lookupIP
	}
	resolved, err := lookupIP(ctx, host)
	if err != nil {
		return nil, fmt.Errorf("failed to resolve %s: %w", host, err)
	}
	if len(resolved) == 0 {
		return nil, fmt.Errorf("failed to resolve %s: no addresses", host)
	}
	addrs := make([]netip.Addr, 0, len(resolved))
	for _, addr := range resolved {
		if p.isBlockedAddr(addr) {
			return nil, fmt.Errorf("blocked resolved address %s for %s", addr, host)
		}
		addrs = append(addrs, addr.Unmap())
	}
	return addrs, nil
}

func dialAllowedAddr(ctx context.Context, dialer *net.Dialer, host string, targetPort int, addrs []netip.Addr) (net.Conn, netip.Addr, error) {
	failures := make([]string, 0, len(addrs))
	for _, addr := range addrs {
		upstream, err := dialer.DialContext(ctx, "tcp", net.JoinHostPort(addr.String(), strconv.Itoa(targetPort)))
		if err == nil {
			return upstream, addr, nil
		}
		failures = append(failures, fmt.Sprintf("%s: %v", addr, err))
	}
	return nil, netip.Addr{}, fmt.Errorf("failed to connect to %s:%d via resolved addresses: %s", host, targetPort, strings.Join(failures, "; "))
}

func (p *policy) isBlockedAddr(addr netip.Addr) bool {
	addr = addr.Unmap()
	if !addr.IsValid() || addr.IsUnspecified() || addr.IsLoopback() || addr.IsPrivate() || addr.IsLinkLocalUnicast() || addr.IsLinkLocalMulticast() || addr.IsMulticast() {
		return true
	}
	for _, prefix := range p.blockedRanges {
		if prefix.Contains(addr) {
			return true
		}
	}
	return false
}

func readInitial(stdin *os.File) ([]byte, error) {
	fd := int(stdin.Fd())
	data := make([]byte, 0, 4096)
	buf := make([]byte, 4096)
	for len(data) < maxInitial {
		timeout := initialTimeout
		if len(data) > 0 {
			timeout = continueTimeout
		}
		ready, err := waitReadable(fd, timeout)
		if err != nil {
			return nil, err
		}
		if !ready {
			break
		}
		limit := len(buf)
		if remaining := maxInitial - len(data); remaining < limit {
			limit = remaining
		}
		n, err := stdin.Read(buf[:limit])
		if n > 0 {
			data = append(data, buf[:n]...)
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return nil, fmt.Errorf("failed to read initial bytes: %w", err)
		}
		if hasHTTPHeaderEnd(data) {
			break
		}
		if parseTLSSNI(data) != "" {
			break
		}
	}
	return data, nil
}

func waitReadable(fd int, timeout time.Duration) (bool, error) {
	var readfds syscall.FdSet
	if err := fdSet(fd, &readfds); err != nil {
		return false, err
	}
	tv := syscall.NsecToTimeval(timeout.Nanoseconds())
	n, err := syscall.Select(fd+1, &readfds, nil, nil, &tv)
	if err != nil {
		return false, fmt.Errorf("failed waiting for client bytes: %w", err)
	}
	return n > 0, nil
}

func fdSet(fd int, set *syscall.FdSet) error {
	if fd < 0 {
		return fmt.Errorf("file descriptor %d cannot be represented in syscall.FdSet", fd)
	}
	word := fd / 64
	if word >= len(set.Bits) {
		return fmt.Errorf("file descriptor %d cannot be represented in syscall.FdSet", fd)
	}
	set.Bits[word] |= int64(1) << (uint(fd) % 64)
	return nil
}

func hasHTTPHeaderEnd(data []byte) bool {
	return bytes.Contains(data, []byte("\r\n\r\n"))
}

func hasTLSRecord(data []byte) bool {
	if len(data) < 5 || data[0] != 0x16 {
		return false
	}
	recordLen := int(data[3])<<8 | int(data[4])
	return len(data) >= 5+recordLen
}

func extractHost(data []byte) string {
	if host := parseHTTPHost(data); host != "" {
		return host
	}
	return parseTLSSNI(data)
}

func parseHTTPHost(data []byte) string {
	if !hasHTTPHeaderEnd(data) {
		return ""
	}
	req, err := http.ReadRequest(bufio.NewReader(bytes.NewReader(data)))
	if err != nil {
		return ""
	}
	return normalizeHost(req.Host)
}

func parseTLSSNI(data []byte) string {
	if !hasTLSRecord(data) {
		return ""
	}
	conn := &replayConn{reader: bytes.NewReader(data)}
	var serverName string
	server := tls.Server(conn, &tls.Config{
		GetConfigForClient: func(hello *tls.ClientHelloInfo) (*tls.Config, error) {
			serverName = hello.ServerName
			return nil, errClientHelloCaptured
		},
	})
	err := server.Handshake()
	if err != nil && !errors.Is(err, errClientHelloCaptured) {
		return ""
	}
	return normalizeHost(serverName)
}

func normalizeHost(host string) string {
	host = strings.TrimSpace(host)
	if host == "" {
		return ""
	}
	if strings.HasPrefix(host, "[") {
		if end := strings.Index(host, "]"); end >= 0 {
			host = host[1:end]
		}
	} else if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	} else if strings.Count(host, ":") == 1 {
		before, after, found := strings.Cut(host, ":")
		if found {
			if _, err := strconv.Atoi(after); err == nil {
				host = before
			}
		}
	}
	host = strings.Trim(strings.TrimSpace(host), ".")
	return strings.ToLower(host)
}

type replayConn struct {
	reader *bytes.Reader
}

func (c *replayConn) Read(p []byte) (int, error)       { return c.reader.Read(p) }
func (c *replayConn) Write(p []byte) (int, error)      { return len(p), nil }
func (c *replayConn) Close() error                     { return nil }
func (c *replayConn) LocalAddr() net.Addr              { return dummyAddr("local") }
func (c *replayConn) RemoteAddr() net.Addr             { return dummyAddr("remote") }
func (c *replayConn) SetDeadline(time.Time) error      { return nil }
func (c *replayConn) SetReadDeadline(time.Time) error  { return nil }
func (c *replayConn) SetWriteDeadline(time.Time) error { return nil }

type dummyAddr string

func (a dummyAddr) Network() string { return string(a) }
func (a dummyAddr) String() string  { return string(a) }
