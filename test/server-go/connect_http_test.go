package servergo

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

type connectResult struct {
	status int
	proto  int
	header http.Header
	body   map[string]any
}

// connectDo sends one Connect unary call with net/http: a POST with a
// JSON body when body is set, a GET otherwise.
func connectDo(t *testing.T, c *http.Client, u, body string) connectResult {
	t.Helper()
	method := http.MethodGet
	var rd io.Reader
	if body != "" {
		method = http.MethodPost
		rd = bytes.NewBufferString(body)
	}
	req, err := http.NewRequest(method, u, rd)
	require.NoError(t, err)
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Connect-Protocol-Version", "1")
	}
	req.Header.Set("X-Request-Id", "r-7")
	resp, err := c.Do(req)
	require.NoError(t, err)
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	require.NoError(t, err)
	r := connectResult{status: resp.StatusCode, proto: resp.ProtoMajor, header: resp.Header}
	require.NoError(t, json.Unmarshal(raw, &r.body), "%s %s: %s", method, u, raw)
	return r
}

// connectUnary checks Connect's unary JSON calls with a plain HTTP
// client: POST, GET (library.Library/GetBook is NO_SIDE_EFFECTS), and
// an error in the Connect error shape.
func connectUnary(t *testing.T, c *http.Client, wantProto int) {
	s := srv(t)
	base := "http://" + s.addr

	r := connectDo(t, c, base+"/hello.Greeter/SayHello", `{"name": "Dave"}`)
	assert.Equal(t, wantProto, r.proto)
	require.Equal(t, http.StatusOK, r.status, "%v", r.body)
	assert.Equal(t, "application/json", r.header.Get("Content-Type"))
	assert.Equal(t, map[string]any{"greeting": "Hello, Dave"}, r.body)
	// Response metadata as headers, trailing metadata as trailer- headers.
	assert.Equal(t, "r-7", r.header.Get("X-Response-Id"))
	assert.Equal(t, "r-7", r.header.Get("Trailer-X-Trailer-Id"))

	msg := url.QueryEscape(`{"name": "shelves/1/books/1"}`)
	r = connectDo(t, c, base+"/library.Library/GetBook?connect=v1&encoding=json&message="+msg, "")
	require.Equal(t, http.StatusOK, r.status, "%v", r.body)
	assert.Equal(t, "Dune", r.body["title"])

	r = connectDo(t, c, base+"/library.Library/GetBook?connect=v1&encoding=json&message="+
		url.QueryEscape(`{"name": "shelves/1/books/404"}`), "")
	assert.Equal(t, http.StatusNotFound, r.status)
	assert.Equal(t, map[string]any{"code": "not_found", "message": "no book shelves/1/books/404"}, r.body)

	// A method with side effects is not served over GET.
	req, err := http.NewRequest(http.MethodGet, base+"/hello.Greeter/SayHello?connect=v1&encoding=json", nil)
	require.NoError(t, err)
	resp, err := c.Do(req)
	require.NoError(t, err)
	_ = resp.Body.Close()
	assert.Equal(t, http.StatusMethodNotAllowed, resp.StatusCode)
}

func TestConnectHTTP1(t *testing.T) {
	connectUnary(t, &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{}}, 1)
}

func TestConnectH2C(t *testing.T) {
	connectUnary(t, h2cClient(), 2)
}
