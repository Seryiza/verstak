package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"

	"github.com/seryiza/verstak/nix/verstak/host-program-proxy/internal/protocol"
)

const usageExit = 2

type clientConfig struct {
	program string
	addr    string
	argv    []string
}

type streamConn interface {
	io.ReadWriteCloser
}

type closeWriter interface {
	CloseWrite() error
}

type clientDeps struct {
	dial  func(network string, address string) (streamConn, error)
	getwd func() (string, error)
}

func main() {
	os.Exit(runWithDeps(os.Args, os.Stdin, os.Stdout, os.Stderr, defaultClientDeps()))
}

func defaultClientDeps() clientDeps {
	return clientDeps{
		dial: func(network string, address string) (streamConn, error) {
			return net.Dial(network, address)
		},
		getwd: os.Getwd,
	}
}

func runWithDeps(args []string, stdin io.Reader, stdout io.Writer, stderr io.Writer, deps clientDeps) int {
	if deps.dial == nil {
		deps.dial = defaultClientDeps().dial
	}
	if deps.getwd == nil {
		deps.getwd = os.Getwd
	}
	cfg, err := parseArgs(args)
	if err != nil {
		fmt.Fprintln(stderr, "verstak host-program client: "+err.Error())
		return usageExit
	}
	cwd, err := deps.getwd()
	if err != nil {
		fmt.Fprintln(stderr, "verstak host-program client: failed to determine cwd: "+err.Error())
		return usageExit
	}
	conn, err := deps.dial("tcp", cfg.addr)
	if err != nil {
		fmt.Fprintf(stderr, "verstak host-program client: failed to connect to host proxy at %s: %v\n", cfg.addr, err)
		return 127
	}
	defer conn.Close()

	if err := protocol.WriteRequest(conn, protocol.Request{Program: cfg.program, Argv: cfg.argv, GuestCwd: cwd}); err != nil {
		fmt.Fprintln(stderr, "verstak host-program client: failed to send request: "+err.Error())
		return 1
	}

	stdinDone := make(chan error, 1)
	go func() {
		_, err := io.CopyBuffer(conn, stdin, make([]byte, protocol.CopyBufferSize))
		if cw, ok := conn.(closeWriter); ok {
			_ = cw.CloseWrite()
		}
		stdinDone <- err
	}()

	for {
		frame, err := protocol.ReadFrame(conn)
		if err != nil {
			select {
			case copyErr := <-stdinDone:
				if copyErr != nil {
					fmt.Fprintln(stderr, "verstak host-program client: stdin copy failed: "+copyErr.Error())
				}
			default:
			}
			fmt.Fprintln(stderr, "verstak host-program client: host proxy ended before exit status: "+err.Error())
			return 1
		}
		switch frame.Stream {
		case protocol.StreamStdout:
			if _, err := stdout.Write(frame.Data); err != nil {
				fmt.Fprintln(stderr, "verstak host-program client: stdout write failed: "+err.Error())
				return 1
			}
		case protocol.StreamStderr:
			if _, err := stderr.Write(frame.Data); err != nil {
				return 1
			}
		case protocol.StreamExit:
			code, err := frame.ExitCode()
			if err != nil {
				fmt.Fprintln(stderr, "verstak host-program client: invalid exit frame: "+err.Error())
				return 1
			}
			return code
		}
	}
}

func parseArgs(args []string) (clientConfig, error) {
	programName := "verstak-host-program-client"
	parseArgs := []string{}
	if len(args) > 0 {
		parseArgs = args[1:]
		if args[0] != "" {
			programName = args[0]
		}
	}
	fs := flag.NewFlagSet(programName, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	program := fs.String("program", "", "host program name")
	addr := fs.String("addr", os.Getenv("VERSTAK_HOST_PROGRAM_PROXY_ADDR"), "host-program proxy guestfwd address")
	if err := fs.Parse(parseArgs); err != nil {
		return clientConfig{}, err
	}
	if *program == "" {
		return clientConfig{}, errors.New("--program is required")
	}
	if *addr == "" {
		return clientConfig{}, errors.New("--addr is required or VERSTAK_HOST_PROGRAM_PROXY_ADDR must be set")
	}
	return clientConfig{program: *program, addr: *addr, argv: fs.Args()}, nil
}
