package servergo

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// envelope frames one Connect streaming message.
func envelope(flags byte, payload string) []byte {
	out := make([]byte, 5+len(payload))
	out[0] = flags
	binary.BigEndian.PutUint32(out[1:], uint32(len(payload)))
	copy(out[5:], payload)
	return out
}

// readEnvelope reads one envelope from a response body.
func readEnvelope(t *testing.T, r *bufio.Reader) (byte, string) {
	t.Helper()
	head := make([]byte, 5)
	_, err := io.ReadFull(r, head)
	require.NoError(t, err)
	payload := make([]byte, binary.BigEndian.Uint32(head[1:]))
	_, err = io.ReadFull(r, payload)
	require.NoError(t, err)
	return head[0], string(payload)
}

// connectStream starts a Connect streaming call with the JSON codec.
func connectStream(t *testing.T, ctx context.Context, c *http.Client, path string,
	body io.Reader, headers map[string]string) (*http.Response, *bufio.Reader) {
	t.Helper()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "http://"+srv(t).addr+path, body)
	require.NoError(t, err)
	req.Header.Set("Content-Type", "application/connect+json")
	req.Header.Set("Connect-Protocol-Version", "1")
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := c.Do(req)
	require.NoError(t, err)
	t.Cleanup(func() { _ = resp.Body.Close() })
	require.Equal(t, http.StatusOK, resp.StatusCode)
	assert.Equal(t, "application/connect+json", resp.Header.Get("Content-Type"))
	return resp, bufio.NewReader(resp.Body)
}

func clients() map[string]*http.Client {
	return map[string]*http.Client{
		"http1": {Timeout: 10 * time.Second, Transport: &http.Transport{}},
		"h2c":   h2cClient(),
	}
}

// TestConnectServerStreamIncremental: each message reaches the client
// as the handler sends it, not with the end of the stream.
func TestConnectServerStreamIncremental(t *testing.T) {
	for name, c := range clients() {
		t.Run(name, func(t *testing.T) {
			start := time.Now()
			_, body := connectStream(t, ctxT(t, 10*time.Second), c, "/hello.Greeter/StreamHellos",
				strings.NewReader(string(envelope(0, `{"name": "slow"}`))), nil)
			flags, msg := readEnvelope(t, body)
			first := time.Since(start)
			assert.Equal(t, byte(0), flags)
			assert.JSONEq(t, `{"greeting": "first"}`, msg)
			assert.Less(t, first, 700*time.Millisecond, "the first message waited for the second")
			_, msg = readEnvelope(t, body)
			assert.JSONEq(t, `{"greeting": "second"}`, msg)
			flags, msg = readEnvelope(t, body)
			assert.Equal(t, byte(2), flags)
			assert.JSONEq(t, `{}`, msg)
			assert.GreaterOrEqual(t, time.Since(start), time.Second)
		})
	}
}

// TestConnectFullDuplex: over HTTP/2 the client reads each reply before
// it sends the next message, and ends its request last.
func TestConnectFullDuplex(t *testing.T) {
	pr, pw := io.Pipe()
	t.Cleanup(func() { _ = pw.Close() })
	send := func(name string) {
		go func() { _, _ = pw.Write(envelope(0, `{"name": "`+name+`"}`)) }()
	}
	send("a")
	_, body := connectStream(t, ctxT(t, 10*time.Second), h2cClient(), "/hello.Greeter/Chat", pr, nil)
	_, msg := readEnvelope(t, body)
	assert.JSONEq(t, `{"greeting": "Echo a"}`, msg)
	send("b")
	_, msg = readEnvelope(t, body)
	assert.JSONEq(t, `{"greeting": "Echo b"}`, msg)
	require.NoError(t, pw.Close())
	flags, msg := readEnvelope(t, body)
	assert.Equal(t, byte(2), flags)
	assert.JSONEq(t, `{}`, msg)
}

// TestConnectHalfDuplexHTTP1: a bidi call over HTTP/1.1 whose client
// sends everything first.
func TestConnectHalfDuplexHTTP1(t *testing.T) {
	reqBody := string(envelope(0, `{"name": "x"}`)) + string(envelope(0, `{"name": "y"}`))
	_, body := connectStream(t, ctxT(t, 10*time.Second), clients()["http1"], "/hello.Greeter/Chat",
		strings.NewReader(reqBody), nil)
	for _, want := range []string{"Echo x", "Echo y"} {
		flags, msg := readEnvelope(t, body)
		assert.Equal(t, byte(0), flags)
		assert.JSONEq(t, `{"greeting": "`+want+`"}`, msg)
	}
	flags, msg := readEnvelope(t, body)
	assert.Equal(t, byte(2), flags)
	assert.JSONEq(t, `{}`, msg)
}

// streamEnd asks the test server how the last 'until-cancel' stream
// ended, waiting until it has.
func streamEnd(t *testing.T) string {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		resp, err := http.Get("http://" + srv(t).addr + "/control/stream-end")
		require.NoError(t, err)
		raw, err := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		require.NoError(t, err)
		if string(raw) != "running" || time.Now().After(deadline) {
			return string(raw)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// TestConnectStreamClientCancel: the client going away mid-stream ends
// the handler (ctx:is_cancelled() or a failing send).
func TestConnectStreamClientCancel(t *testing.T) {
	for name, c := range clients() {
		t.Run(name, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			_, body := connectStream(t, ctx, c, "/hello.Greeter/StreamHellos",
				strings.NewReader(string(envelope(0, `{"name": "until-cancel"}`))), nil)
			_, msg := readEnvelope(t, body)
			assert.JSONEq(t, `{"greeting": "tick 1"}`, msg)
			cancel()
			end := streamEnd(t)
			if name == "h2c" {
				// RST_STREAM reaches the server at once.
				assert.Equal(t, "cancelled", end)
			} else {
				// HTTP/1.1 notices at the next write.
				assert.Contains(t, []string{"cancelled", "send failed"}, end)
			}
		})
	}
}

// TestConnectStreamDeadline: Connect-Timeout-Ms ends a stream that is
// still sending, with deadline_exceeded in the EndStreamResponse.
func TestConnectStreamDeadline(t *testing.T) {
	start := time.Now()
	_, body := connectStream(t, ctxT(t, 10*time.Second), h2cClient(), "/hello.Greeter/StreamHellos",
		strings.NewReader(string(envelope(0, `{"name": "until-cancel"}`))),
		map[string]string{"Connect-Timeout-Ms": "300"})
	ticks := 0
	for {
		flags, msg := readEnvelope(t, body)
		if flags == 0 {
			ticks++
			continue
		}
		assert.Equal(t, byte(2), flags)
		var end struct {
			Error struct {
				Code string `json:"code"`
			} `json:"error"`
		}
		require.NoError(t, json.Unmarshal([]byte(msg), &end), msg)
		assert.Equal(t, "deadline_exceeded", end.Error.Code, msg)
		break
	}
	elapsed := time.Since(start)
	assert.Greater(t, ticks, 1)
	assert.GreaterOrEqual(t, elapsed, 300*time.Millisecond)
	assert.Less(t, elapsed, 2*time.Second)
	assert.Equal(t, "cancelled", streamEnd(t))
}
