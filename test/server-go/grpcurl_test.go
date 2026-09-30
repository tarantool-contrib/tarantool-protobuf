package servergo

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// grpcurlVersion is built into a temporary GOBIN, so nothing is
// installed globally. GRPCURL=<path> uses an existing binary instead.
const grpcurlVersion = "v1.9.3"

var (
	grpcurlOnce sync.Once
	grpcurlBin  string
	grpcurlSkip string
	// grpcurlDir is the temporary GOBIN; TestMain removes it.
	grpcurlDir string
)

func grpcurl(t *testing.T) string {
	t.Helper()
	grpcurlOnce.Do(func() {
		if bin := os.Getenv("GRPCURL"); bin != "" {
			grpcurlBin = bin
			return
		}
		dir, err := os.MkdirTemp("", "pb-server-grpcurl-")
		if err != nil {
			grpcurlSkip = err.Error()
			return
		}
		grpcurlDir = dir
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
		defer cancel()
		cmd := exec.CommandContext(ctx, "go", "install",
			"github.com/fullstorydev/grpcurl/cmd/grpcurl@"+grpcurlVersion)
		cmd.Env = append(os.Environ(), "GOBIN="+dir, "GOFLAGS=")
		if out, err := cmd.CombinedOutput(); err != nil {
			grpcurlSkip = "cannot build grpcurl " + grpcurlVersion + " (offline?): " +
				err.Error() + ": " + lastLine(string(out))
			return
		}
		grpcurlBin = filepath.Join(dir, "grpcurl")
	})
	if grpcurlSkip != "" {
		t.Skip(grpcurlSkip)
	}
	return grpcurlBin
}

func runGrpcurl(t *testing.T, args ...string) string {
	t.Helper()
	bin := grpcurl(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, bin, args...).CombinedOutput()
	require.NoError(t, err, "grpcurl %s: %s", strings.Join(args, " "), out)
	return string(out)
}

// TestGrpcurl drives the server with grpcurl and reflection alone: no
// .proto files, no protoset.
func TestGrpcurl(t *testing.T) {
	s := srv(t)

	out := runGrpcurl(t, "-plaintext", s.addr, "list")
	services := strings.Fields(out)
	assert.ElementsMatch(t, []string{
		"grpc.health.v1.Health",
		"grpc.reflection.v1.ServerReflection",
		"grpc.reflection.v1alpha.ServerReflection",
		"hello.Greeter",
		"library.Library",
	}, services, out)

	out = runGrpcurl(t, "-plaintext", s.addr, "list", "hello.Greeter")
	assert.Contains(t, out, "hello.Greeter.SayHello")
	assert.Contains(t, out, "hello.Greeter.Chat")

	out = runGrpcurl(t, "-plaintext", s.addr, "describe", "hello.Greeter")
	assert.Contains(t, out, "service Greeter {")
	assert.Contains(t, out, "rpc SayHello ( .hello.HelloRequest ) returns ( .hello.HelloReply );")
	assert.Contains(t, out, "rpc Chat ( stream .hello.HelloRequest ) returns ( stream .hello.HelloReply );")

	out = runGrpcurl(t, "-plaintext", s.addr, "describe", "library.Library.GetBook")
	assert.Contains(t, out, "rpc GetBook ( .library.GetBookRequest ) returns ( .library.Book )")
	assert.Contains(t, out, "/v1/{name=shelves/*/books/*}", "google.api.http options resolve too")

	out = runGrpcurl(t, "-plaintext", "-d", `{"name": "Dave"}`, s.addr, "hello.Greeter/SayHello")
	var reply map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &reply), out)
	assert.Equal(t, map[string]any{"greeting": "Hello, Dave"}, reply)

	out = runGrpcurl(t, "-plaintext", "-d", `{"name": "Eve"}`, s.addr, "hello.Greeter/StreamHellos")
	assert.Equal(t, 3, strings.Count(out, `"greeting"`), out)
}
