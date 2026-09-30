package servergo

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// bufCurlResult is one `buf curl` run: stdout carries the responses,
// stderr the errors; code is the exit status.
type bufCurlResult struct {
	stdout string
	stderr string
	code   int
}

func (r bufCurlResult) String() string {
	return fmt.Sprintf("exit %d; stdout: %s; stderr: %s", r.code, r.stdout, r.stderr)
}

// runBufCurl runs `buf curl` from the repository root. The test skips
// when buf is not on PATH; it is not built here, unlike grpcurl.
func runBufCurl(t *testing.T, args ...string) bufCurlResult {
	t.Helper()
	bin, err := exec.LookPath("buf")
	if err != nil {
		t.Skip("buf is not on PATH (https://buf.build/docs/installation): " + err.Error())
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, append([]string{"curl"}, args...)...)
	cmd.Dir = repoRoot()
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err = cmd.Run()
	res := bufCurlResult{stdout: stdout.String(), stderr: stderr.String()}
	var exit *exec.ExitError
	switch {
	case err == nil:
	case errors.As(err, &exit):
		res.code = exit.ExitCode()
	default:
		require.NoError(t, err, "buf curl %s: %s", strings.Join(args, " "), stderr.String())
	}
	return res
}

// bufGRPC runs `buf curl` over gRPC with h2c prior knowledge, the flags
// pb.server needs: the default protocol is Connect, and reflection over
// plain http:// needs --http2-prior-knowledge.
func bufGRPC(t *testing.T, args ...string) bufCurlResult {
	t.Helper()
	return runBufCurl(t, append([]string{"--protocol", "grpc", "--http2-prior-knowledge"}, args...)...)
}

// decodeJSONStream decodes the JSON objects buf curl prints one after
// another (one per response message).
func decodeJSONStream(t *testing.T, s string) []map[string]any {
	t.Helper()
	dec := json.NewDecoder(strings.NewReader(s))
	var out []map[string]any
	for {
		var m map[string]any
		err := dec.Decode(&m)
		if errors.Is(err, io.EOF) {
			return out
		}
		require.NoError(t, err, s)
		out = append(out, m)
	}
}

// TestBufCurl drives the server with `buf curl` and server reflection
// alone, as docs/howto/16-network-server.md shows.
func TestBufCurl(t *testing.T) {
	s := srv(t)
	base := "http://" + s.addr

	t.Run("list-services", func(t *testing.T) {
		r := bufGRPC(t, "--list-services", base)
		require.Equal(t, 0, r.code, r)
		assert.ElementsMatch(t, []string{
			"grpc.health.v1.Health",
			"grpc.reflection.v1.ServerReflection",
			"grpc.reflection.v1alpha.ServerReflection",
			"hello.Greeter",
			"library.Library",
		}, strings.Fields(r.stdout), r)
	})

	t.Run("list-methods", func(t *testing.T) {
		r := bufGRPC(t, "--list-methods", base)
		require.Equal(t, 0, r.code, r)
		methods := strings.Fields(r.stdout)
		for _, m := range []string{
			"grpc.health.v1.Health/Check",
			"hello.Greeter/SayHello",
			"hello.Greeter/StreamHellos",
			"hello.Greeter/CollectHellos",
			"hello.Greeter/Chat",
			"library.Library/GetBook",
		} {
			assert.Contains(t, methods, m, r)
		}
	})

	t.Run("unary", func(t *testing.T) {
		r := bufGRPC(t, "-d", `{"name": "Dave"}`, base+"/hello.Greeter/SayHello")
		require.Equal(t, 0, r.code, r)
		assert.Equal(t, []map[string]any{{"greeting": "Hello, Dave"}},
			decodeJSONStream(t, r.stdout))
	})

	t.Run("server-streaming", func(t *testing.T) {
		r := bufGRPC(t, "-d", `{"name": "Eve"}`, base+"/hello.Greeter/StreamHellos")
		require.Equal(t, 0, r.code, r)
		assert.Equal(t, []map[string]any{
			{"greeting": "Hello #1, Eve"},
			{"greeting": "Hello #2, Eve"},
			{"greeting": "Hello #3, Eve"},
		}, decodeJSONStream(t, r.stdout))
	})

	t.Run("health", func(t *testing.T) {
		r := bufGRPC(t, "-d", `{"service": "hello.Greeter"}`, base+"/grpc.health.v1.Health/Check")
		require.Equal(t, 0, r.code, r)
		assert.Equal(t, []map[string]any{{"status": "SERVING"}}, decodeJSONStream(t, r.stdout))
	})

	t.Run("not-found", func(t *testing.T) {
		r := bufGRPC(t, "-d", `{"name": "shelves/1/books/9"}`, base+"/library.Library/GetBook")
		// buf curl exits with 8 times the numeric status code:
		// NOT_FOUND is 5.
		assert.Equal(t, 40, r.code, r)
		assert.Empty(t, r.stdout)
		var st map[string]any
		require.NoError(t, json.Unmarshal([]byte(r.stderr), &st), r)
		assert.Equal(t, "not_found", st["code"], r)
		assert.Equal(t, "no book shelves/1/books/9", st["message"], r)
	})
}

// bufConnect runs `buf curl` with its default protocol, Connect (with
// the proto codec), and the schema from a local file instead of server
// reflection. h2 adds --http2-prior-knowledge; without it buf curl
// speaks HTTP/1.1.
func bufConnect(t *testing.T, h2 bool, args ...string) bufCurlResult {
	t.Helper()
	pre := []string{"--schema", "examples/proto/hello.proto"}
	if h2 {
		pre = append(pre, "--http2-prior-knowledge")
	}
	return runBufCurl(t, append(pre, args...)...)
}

// TestBufCurlConnect drives the Connect protocol with buf curl's
// defaults and a local schema, over HTTP/1.1 and h2c.
func TestBufCurlConnect(t *testing.T) {
	s := srv(t)
	base := "http://" + s.addr
	for _, h2 := range []bool{false, true} {
		name := "http1"
		if h2 {
			name = "h2c"
		}
		t.Run(name, func(t *testing.T) {
			t.Run("unary", func(t *testing.T) {
				r := bufConnect(t, h2, "-d", `{"name": "Dave"}`, base+"/hello.Greeter/SayHello")
				require.Equal(t, 0, r.code, r)
				assert.Equal(t, []map[string]any{{"greeting": "Hello, Dave"}},
					decodeJSONStream(t, r.stdout))
			})

			t.Run("server-streaming", func(t *testing.T) {
				r := bufConnect(t, h2, "-d", `{"name": "Eve"}`, base+"/hello.Greeter/StreamHellos")
				require.Equal(t, 0, r.code, r)
				assert.Equal(t, []map[string]any{
					{"greeting": "Hello #1, Eve"},
					{"greeting": "Hello #2, Eve"},
					{"greeting": "Hello #3, Eve"},
				}, decodeJSONStream(t, r.stdout))
			})

			t.Run("client-streaming", func(t *testing.T) {
				r := bufConnect(t, h2, "-d", `{"name": "a"} {"name": "b"}`,
					base+"/hello.Greeter/CollectHellos")
				require.Equal(t, 0, r.code, r)
				assert.Equal(t, []map[string]any{{"greeting": "Hello, a, b"}},
					decodeJSONStream(t, r.stdout))
			})

			t.Run("error-with-details", func(t *testing.T) {
				r := bufConnect(t, h2, "-d", `{"name": "missing"}`, base+"/hello.Greeter/SayHello")
				// buf curl exits with 8 times the numeric code: NOT_FOUND is 5.
				assert.Equal(t, 40, r.code, r)
				assert.Empty(t, r.stdout)
				var st struct {
					Code    string `json:"code"`
					Message string `json:"message"`
					Details []struct {
						Type  string `json:"type"`
						Value string `json:"value"`
					} `json:"details"`
				}
				require.NoError(t, json.Unmarshal([]byte(r.stderr), &st), r)
				assert.Equal(t, "not_found", st.Code, r)
				assert.Equal(t, "no such person: missing", st.Message, r)
				require.Len(t, st.Details, 1, r)
				assert.Equal(t, "hello.HelloReply", st.Details[0].Type, r)
				// HelloReply{greeting: "try someone else"} in unpadded
				// base64, as the protocol asks servers to emit it.
				want := base64.RawStdEncoding.EncodeToString([]byte("\x0a\x10try someone else"))
				assert.Equal(t, want, st.Details[0].Value, r)
			})
		})
	}

	// A half-duplex bidi call: buf curl sends every message, then ends
	// its request, so the buffered request reaches the handler whole.
	t.Run("bidi-half-duplex", func(t *testing.T) {
		r := bufConnect(t, true, "-d", `{"name": "x"} {"name": "y"}`, base+"/hello.Greeter/Chat")
		require.Equal(t, 0, r.code, r)
		assert.Equal(t, []map[string]any{{"greeting": "Echo x"}, {"greeting": "Echo y"}},
			decodeJSONStream(t, r.stdout))
	})
}

// TestBufCurlConnectReflection drives buf curl with its defaults and
// server reflection alone, no local schema: reflection
// (grpc.reflection ServerReflectionInfo) is a bidi stream that buf curl
// runs full duplex, one request and its answer at a time, so it works
// over Connect on HTTP/2, where the Connect streaming handler reads
// messages as they arrive. The timeout keeps a regression (the call
// hanging until the request ends) from stalling the suite.
func TestBufCurlConnectReflection(t *testing.T) {
	s := srv(t)
	base := "http://" + s.addr
	reflect := func(t *testing.T, args ...string) bufCurlResult {
		t.Helper()
		return runBufCurl(t, append([]string{"--http2-prior-knowledge", "--timeout", "10s"}, args...)...)
	}

	t.Run("list-services", func(t *testing.T) {
		r := reflect(t, "--list-services", base)
		require.Equal(t, 0, r.code, r)
		assert.ElementsMatch(t, []string{
			"grpc.health.v1.Health",
			"grpc.reflection.v1.ServerReflection",
			"grpc.reflection.v1alpha.ServerReflection",
			"hello.Greeter",
			"library.Library",
		}, strings.Fields(r.stdout), r)
	})

	t.Run("list-methods", func(t *testing.T) {
		r := reflect(t, "--list-methods", base)
		require.Equal(t, 0, r.code, r)
		methods := strings.Fields(r.stdout)
		for _, m := range []string{"hello.Greeter/SayHello", "hello.Greeter/Chat", "library.Library/GetBook"} {
			assert.Contains(t, methods, m, r)
		}
	})

	t.Run("unary", func(t *testing.T) {
		r := reflect(t, "-d", `{"name": "Dave"}`, base+"/hello.Greeter/SayHello")
		require.Equal(t, 0, r.code, r)
		assert.Equal(t, []map[string]any{{"greeting": "Hello, Dave"}}, decodeJSONStream(t, r.stdout))
	})

	t.Run("server-streaming", func(t *testing.T) {
		r := reflect(t, "-d", `{"name": "Eve"}`, base+"/hello.Greeter/StreamHellos")
		require.Equal(t, 0, r.code, r)
		assert.Equal(t, []map[string]any{
			{"greeting": "Hello #1, Eve"},
			{"greeting": "Hello #2, Eve"},
			{"greeting": "Hello #3, Eve"},
		}, decodeJSONStream(t, r.stdout))
	})

	t.Run("bidi", func(t *testing.T) {
		r := reflect(t, "-d", `{"name": "x"} {"name": "y"}`, base+"/hello.Greeter/Chat")
		require.Equal(t, 0, r.code, r)
		assert.Equal(t, []map[string]any{{"greeting": "Echo x"}, {"greeting": "Echo y"}},
			decodeJSONStream(t, r.stdout))
	})
}
