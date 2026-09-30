package servergo

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/binary"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/url"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"golang.org/x/net/http2"
	"google.golang.org/grpc/codes"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

// setServing flips a health status through the server's HTTP fallback
// handler (test/server-go/server.lua), which calls
// server:set_serving_status.
func setServing(t *testing.T, s *server, service, st string) {
	t.Helper()
	u := "http://" + s.addr + "/control/serving?service=" + url.QueryEscape(service) + "&status=" + st
	resp, err := http.Post(u, "text/plain", nil)
	require.NoError(t, err)
	defer resp.Body.Close()
	require.Equal(t, http.StatusOK, resp.StatusCode)
}

func TestHealthCheck(t *testing.T) {
	s := srv(t)
	hc := healthpb.NewHealthClient(s.conn)
	for _, svc := range []string{"", "hello.Greeter", "library.Library"} {
		resp, err := hc.Check(ctxT(t, 5*time.Second), &healthpb.HealthCheckRequest{Service: svc})
		require.NoError(t, err, "%q", svc)
		assert.Equal(t, healthpb.HealthCheckResponse_SERVING, resp.GetStatus(), "%q", svc)
	}
	_, err := hc.Check(ctxT(t, 5*time.Second), &healthpb.HealthCheckRequest{Service: "no.Such"})
	assert.Equal(t, codes.NotFound, status.Code(err), "%v", err)
}

func TestHealthWatch(t *testing.T) {
	s := srv(t)
	const svc = "library.Library"
	t.Cleanup(func() { setServing(t, s, svc, "SERVING") })

	hc := healthpb.NewHealthClient(s.conn)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	watch, err := hc.Watch(ctx, &healthpb.HealthCheckRequest{Service: svc})
	require.NoError(t, err)
	resp, err := watch.Recv()
	require.NoError(t, err)
	assert.Equal(t, healthpb.HealthCheckResponse_SERVING, resp.GetStatus())

	setServing(t, s, svc, "NOT_SERVING")
	resp, err = watch.Recv()
	require.NoError(t, err)
	assert.Equal(t, healthpb.HealthCheckResponse_NOT_SERVING, resp.GetStatus())

	check, err := hc.Check(ctxT(t, 5*time.Second), &healthpb.HealthCheckRequest{Service: svc})
	require.NoError(t, err)
	assert.Equal(t, healthpb.HealthCheckResponse_NOT_SERVING, check.GetStatus())

	setServing(t, s, svc, "SERVING")
	resp, err = watch.Recv()
	require.NoError(t, err)
	assert.Equal(t, healthpb.HealthCheckResponse_SERVING, resp.GetStatus())
}

// h2cClient speaks HTTP/2 with prior knowledge over plain TCP.
func h2cClient() *http.Client {
	return &http.Client{
		Timeout: 10 * time.Second,
		Transport: &http2.Transport{
			AllowHTTP: true,
			DialTLSContext: func(ctx context.Context, network, addr string, _ *tls.Config) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, network, addr)
			},
		},
	}
}

type httpResult struct {
	status int
	proto  int
	ctype  string
	body   map[string]any
}

func do(t *testing.T, c *http.Client, method, u, body string) httpResult {
	t.Helper()
	var rd io.Reader
	if body != "" {
		rd = bytes.NewBufferString(body)
	}
	req, err := http.NewRequest(method, u, rd)
	require.NoError(t, err)
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.Do(req)
	require.NoError(t, err)
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	require.NoError(t, err)
	r := httpResult{status: resp.StatusCode, proto: resp.ProtoMajor, ctype: resp.Header.Get("Content-Type")}
	require.NoError(t, json.Unmarshal(raw, &r.body), "%s %s: %s", method, u, raw)
	return r
}

func transcoding(t *testing.T, c *http.Client, wantProto int) {
	s := srv(t)
	base := "http://" + s.addr

	// Path variable binding: name=shelves/*/books/*.
	r := do(t, c, "GET", base+"/v1/shelves/1/books/1", "")
	assert.Equal(t, wantProto, r.proto)
	assert.Equal(t, http.StatusOK, r.status)
	assert.Equal(t, "application/json", r.ctype)
	assert.Equal(t, "shelves/1/books/1", r.body["name"])
	assert.Equal(t, "Dune", r.body["title"])

	// POST with a body bound to a field (body: "book"), the path
	// binding parent.
	r = do(t, c, "POST", base+"/v1/shelves/7/books", `{"title": "Hyperion", "author": "Simmons"}`)
	require.Equal(t, http.StatusOK, r.status, "%v", r.body)
	name, _ := r.body["name"].(string)
	assert.Regexp(t, `^shelves/7/books/\d+$`, name)
	assert.Equal(t, "Hyperion", r.body["title"])

	// Path + query binding: parent from the path, pageSize from the query.
	do(t, c, "POST", base+"/v1/shelves/7/books", `{"title": "Endymion"}`)
	r = do(t, c, "GET", base+"/v1/shelves/7/books?pageSize=1", "")
	require.Equal(t, http.StatusOK, r.status, "%v", r.body)
	books, _ := r.body["books"].([]any)
	assert.Len(t, books, 1, "pageSize=1 limits the list: %v", r.body)
	r = do(t, c, "GET", base+"/v1/shelves/7/books", "")
	books, _ = r.body["books"].([]any)
	assert.GreaterOrEqual(t, len(books), 2, "%v", r.body)

	// A status raised by the handler: HTTP code and google.rpc.Status JSON.
	r = do(t, c, "GET", base+"/v1/shelves/1/books/404", "")
	assert.Equal(t, http.StatusNotFound, r.status)
	assert.Equal(t, "application/json", r.ctype)
	assert.EqualValues(t, codes.NotFound, r.body["code"])
	assert.Equal(t, "no book shelves/1/books/404", r.body["message"])

	// Malformed JSON: 400 INVALID_ARGUMENT.
	r = do(t, c, "POST", base+"/v1/shelves/7/books", `{"title": `)
	assert.Equal(t, http.StatusBadRequest, r.status)
	assert.EqualValues(t, codes.InvalidArgument, r.body["code"])

	// Nothing routed: the 404 of pb.server in the same shape.
	r = do(t, c, "GET", base+"/v2/nothing", "")
	assert.Equal(t, http.StatusNotFound, r.status)
	assert.EqualValues(t, codes.NotFound, r.body["code"])
}

func TestTranscodingHTTP1(t *testing.T) {
	c := &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{}}
	transcoding(t, c, 1)
}

func TestTranscodingH2C(t *testing.T) {
	transcoding(t, h2cClient(), 2)
}

// grpcFrame is one length-prefixed gRPC message.
func grpcFrame(msg []byte) []byte {
	out := make([]byte, 5+len(msg))
	binary.BigEndian.PutUint32(out[1:], uint32(len(msg)))
	copy(out[5:], msg)
	return out
}

// TestServerEnforcesDeadline sends grpc-timeout without a client-side
// timer (a raw HTTP/2 request), so a DEADLINE_EXCEEDED can come only
// from the server.
func TestServerEnforcesDeadline(t *testing.T) {
	s := srv(t)
	md := method(t, "hello.Greeter.SayHello")
	msg, err := proto.Marshal(newMsg(md.Input(), map[string]any{"name": "sleep:3"}))
	require.NoError(t, err)
	req, err := http.NewRequest("POST", "http://"+s.addr+methodPath(md), bytes.NewReader(grpcFrame(msg)))
	require.NoError(t, err)
	req.Header.Set("Content-Type", "application/grpc")
	req.Header.Set("TE", "trailers")
	req.Header.Set("grpc-timeout", "200m")
	start := time.Now()
	resp, err := h2cClient().Do(req)
	require.NoError(t, err)
	defer resp.Body.Close()
	_, err = io.ReadAll(resp.Body)
	require.NoError(t, err)
	assert.Less(t, time.Since(start), 2*time.Second)
	grpcStatus := resp.Trailer.Get("grpc-status")
	if grpcStatus == "" {
		grpcStatus = resp.Header.Get("grpc-status") // trailers-only response
	}
	assert.Equal(t, "4", grpcStatus, "DEADLINE_EXCEEDED")
}
