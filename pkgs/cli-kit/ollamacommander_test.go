package clikit

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
)

// roundTripFunc lets a test stand in for ollama's HTTP endpoint.
type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestOllamaCommanderProposeParse(t *testing.T) {
	// A realistic NDJSON stream: a rationale sentence in one frame, the JSON in
	// the next, then a done frame — Propose should surface every content chunk and
	// Parse should recover the object despite the surrounding prose.
	stream := `{"message":{"role":"assistant","content":"A security audit needs depth. "},"done":false}
{"message":{"role":"assistant","content":"{\"model\":\"smart\",\"thinking\":\"high\"}"},"done":false}
{"message":{"role":"assistant","content":""},"done":true}
`
	var gotBody string
	c := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/api/chat" {
			t.Errorf("path = %q, want /api/chat", r.URL.Path)
		}
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		return &http.Response{
			StatusCode: http.StatusOK,
			Body:       io.NopCloser(strings.NewReader(stream)),
			Header:     make(http.Header),
		}, nil
	})}

	o := OllamaCommander{Model: "qwen2.5:3b", System: "be a selector", Client: c}
	o.Wrap = func(p string) string { return "classify: " + p }

	ch, err := o.Propose(context.Background(), "audit the repo")
	if err != nil {
		t.Fatalf("Propose: %v", err)
	}
	var out strings.Builder
	for s := range ch {
		out.WriteString(s)
	}
	if !strings.Contains(out.String(), "security audit needs depth") {
		t.Errorf("stream missing rationale, got: %q", out.String())
	}

	// The wrapped prompt and system prompt must reach the request body.
	if !strings.Contains(gotBody, "classify: audit the repo") {
		t.Errorf("request body missing wrapped prompt: %s", gotBody)
	}
	if !strings.Contains(gotBody, "be a selector") {
		t.Errorf("request body missing system prompt: %s", gotBody)
	}

	got, err := o.Parse(out.String())
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(got) != 2 || got[0] != (Action{"model", "smart"}) || got[1] != (Action{"thinking", "high"}) {
		t.Errorf("proposal = %v, want [{model smart} {thinking high}]", got)
	}
}

func TestKeepAliveValue(t *testing.T) {
	// -1 (pin forever) must go on the wire as a NUMBER, not the string "-1"
	// (which ollama's duration parser rejects with "missing unit").
	if v := keepAliveValue("-1"); v != -1 {
		t.Errorf(`keepAliveValue("-1") = %#v, want int -1`, v)
	}
	// A duration stays a string.
	if v := keepAliveValue("30m"); v != "30m" {
		t.Errorf(`keepAliveValue("30m") = %#v, want "30m"`, v)
	}
	// Empty is omitted so the daemon default governs.
	if v := keepAliveValue(""); v != nil {
		t.Errorf(`keepAliveValue("") = %#v, want nil`, v)
	}
}

func TestOllamaCommanderPinsForeverAsNumber(t *testing.T) {
	var gotBody string
	c := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(`{"done":true}`)), Header: make(http.Header)}, nil
	})}
	o := OllamaCommander{Model: "m", KeepAlive: "-1", Client: c}
	ch, err := o.Propose(context.Background(), "x")
	if err != nil {
		t.Fatalf("Propose: %v", err)
	}
	for range ch {
	}
	if !strings.Contains(gotBody, `"keep_alive":-1`) {
		t.Errorf("keep_alive must serialise as the number -1, got body: %s", gotBody)
	}
}

func TestOllamaResidencyToggle(t *testing.T) {
	var lastPath, lastBody string
	stub := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		lastPath = r.URL.Path
		if r.Body != nil {
			b, _ := io.ReadAll(r.Body)
			lastBody = string(b)
		}
		body := "{}"
		if r.URL.Path == "/api/ps" {
			body = `{"models":[{"name":"m","model":"m"}]}`
		}
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
	})}
	o := NewOllamaCommander("sys")
	o.Model, o.Client = "m", stub

	// Default: unloaded → a Propose runs transiently (keep_alive 0, evict after).
	if got := o.proposeKeepAlive(); got != 0 {
		t.Errorf("default proposeKeepAlive = %v, want 0 (transient)", got)
	}

	// Load pins it: /api/generate with keep_alive -1, and Propose now pins too.
	if err := o.Load(context.Background()); err != nil {
		t.Fatalf("Load: %v", err)
	}
	if lastPath != "/api/generate" || !strings.Contains(lastBody, `"keep_alive":-1`) {
		t.Errorf("Load should POST /api/generate keep_alive -1; got %s %s", lastPath, lastBody)
	}
	if got := o.proposeKeepAlive(); got != -1 {
		t.Errorf("loaded proposeKeepAlive = %v, want -1 (pinned)", got)
	}

	// Loaded reads /api/ps and finds the model.
	if ok, err := o.Loaded(context.Background()); err != nil || !ok {
		t.Errorf("Loaded = %v,%v want true,nil", ok, err)
	}

	// Unload evicts: keep_alive 0, and Propose goes transient again.
	if err := o.Unload(context.Background()); err != nil {
		t.Fatalf("Unload: %v", err)
	}
	if !strings.Contains(lastBody, `"keep_alive":0`) {
		t.Errorf("Unload should POST keep_alive 0; got %s", lastBody)
	}
	if got := o.proposeKeepAlive(); got != 0 {
		t.Errorf("unloaded proposeKeepAlive = %v, want 0", got)
	}
}

func TestOllamaCommanderDaemonDown(t *testing.T) {
	// A connection failure must surface a clear, actionable error, not a panic.
	c := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return nil, io.ErrUnexpectedEOF
	})}
	o := OllamaCommander{Client: c}
	if _, err := o.Propose(context.Background(), "x"); err == nil {
		t.Error("expected an error when the daemon is unreachable")
	} else if !strings.Contains(err.Error(), "daemon") {
		t.Errorf("error should hint at the daemon, got: %v", err)
	}
}
