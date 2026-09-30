// Package servergo checks pb.server against independent clients: grpc-go
// with dynamicpb messages built from descriptors fetched only through
// server reflection, grpc-go's health client, net/http over HTTP/1.1 and
// HTTP/2 (h2c), and grpcurl. The server is test/server-go/server.lua,
// started once per test binary on a free port.
package servergo

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
)

// lockedBuffer collects the server's stderr for failure reports.
type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

type server struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	stderr *lockedBuffer
	addr   string
	conn   *grpc.ClientConn
	// skip is set when the server cannot run on this machine (no http2
	// rock); every test skips with it.
	skip string
	err  error
}

var (
	shared     *server
	sharedOnce sync.Once
)

func TestMain(m *testing.M) {
	code := m.Run()
	if shared != nil {
		shared.shutdown()
	}
	if grpcurlDir != "" {
		_ = os.RemoveAll(grpcurlDir)
	}
	os.Exit(code)
}

// repoRoot is the repository root, two levels up from this directory.
func repoRoot() string {
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		panic(err)
	}
	return root
}

// luaPath reaches runtime/, the generated examples and, when
// TARANTOOL_HTTP2_RUNTIME names it, the http2 rock's runtime directory.
func luaPath() string {
	p := "./runtime/?/init.lua;./runtime/?.lua;./examples/expected/?.lua;./examples/expected/?/init.lua;"
	if dir := os.Getenv("TARANTOOL_HTTP2_RUNTIME"); dir != "" {
		p += dir + "/?.lua;" + dir + "/?/init.lua;"
	}
	return p + ";"
}

func tarantoolBin() string {
	if bin := os.Getenv("TARANTOOL"); bin != "" {
		return bin
	}
	return "tarantool"
}

func startServer() *server {
	s := &server{stderr: &lockedBuffer{}}
	cmd := exec.Command(tarantoolBin(), filepath.Join("test", "server-go", "server.lua"))
	cmd.Dir = repoRoot()
	cmd.Env = append(os.Environ(), "LUA_PATH="+luaPath())
	cmd.Stderr = s.stderr
	stdin, err := cmd.StdinPipe()
	if err != nil {
		s.err = err
		return s
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		s.err = err
		return s
	}
	if err := cmd.Start(); err != nil {
		s.err = err
		return s
	}
	s.cmd, s.stdin = cmd, stdin

	// The port comes from the process: it prints `LISTENING <port>`
	// once the listener is bound.
	lines := make(chan string, 1)
	go func() {
		sc := bufio.NewScanner(stdout)
		for sc.Scan() {
			if strings.HasPrefix(sc.Text(), "LISTENING ") {
				lines <- sc.Text()
				break
			}
		}
		close(lines)
		_, _ = io.Copy(io.Discard, stdout)
	}()
	select {
	case line, ok := <-lines:
		if !ok {
			_ = cmd.Wait()
			if strings.Contains(s.stderr.String(), "tarantool-http2 rock is required") {
				s.skip = "the http2 rock is not available (set TARANTOOL_HTTP2_RUNTIME): " +
					lastLine(s.stderr.String())
				return s
			}
			s.err = fmt.Errorf("server exited before listening: %s", s.stderr.String())
			return s
		}
		s.addr = "127.0.0.1:" + strings.TrimPrefix(line, "LISTENING ")
	case <-time.After(30 * time.Second):
		s.err = fmt.Errorf("server did not report a port in 30s: %s", s.stderr.String())
		return s
	}

	s.conn, err = grpc.NewClient(s.addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		s.err = err
		return s
	}
	// Ready means a real RPC answers, not that the port accepts.
	hc := healthpb.NewHealthClient(s.conn)
	deadline := time.Now().Add(15 * time.Second)
	for {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		resp, err := hc.Check(ctx, &healthpb.HealthCheckRequest{})
		cancel()
		if err == nil && resp.GetStatus() == healthpb.HealthCheckResponse_SERVING {
			return s
		}
		if time.Now().After(deadline) {
			s.err = fmt.Errorf("server not ready: %v (%v); stderr: %s", err, resp, s.stderr.String())
			return s
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func lastLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	return lines[len(lines)-1]
}

func (s *server) shutdown() {
	if s.conn != nil {
		_ = s.conn.Close()
	}
	if s.cmd == nil || s.cmd.ProcessState != nil {
		return
	}
	_ = s.stdin.Close()
	done := make(chan struct{})
	go func() {
		_ = s.cmd.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		_ = s.cmd.Process.Kill()
		<-done
	}
}

// srv returns the shared server, starting it on first use.
func srv(t *testing.T) *server {
	t.Helper()
	sharedOnce.Do(func() { shared = startServer() })
	if shared.skip != "" {
		t.Skip(shared.skip)
	}
	require.NoError(t, shared.err)
	return shared
}

// ctxT is a context bounded well below the test timeout, so a hang
// fails the test instead of the whole binary.
func ctxT(t *testing.T, d time.Duration) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), d)
	t.Cleanup(cancel)
	return ctx
}
