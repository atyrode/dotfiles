package clikit

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
)

// DefaultLocalModel is the model an OllamaCommander uses unless overridden. A 3B
// instruct model is the sweet spot for facet classification: 0.5–1.5B models are
// too weak (they return uniform, undifferentiated picks), while 3B differentiates
// well and stays small enough for the nix-managed daemon to hold resident cheaply.
// Warm latency on a short prompt is ~1–2s CPU-only, sub-second on a GPU; keep the
// classifier's output terse, since on CPU each generated token costs ~60ms.
// Configure per host via OllamaCommander.Model.
const DefaultLocalModel = "qwen2.5:3b"

// DefaultOllamaEndpoint is the local ollama HTTP API. The daemon is nix-managed
// and loopback-only; nothing here reaches the network.
const DefaultOllamaEndpoint = "http://127.0.0.1:11434"

// OllamaCommander is a local-model Act backend: it POSTs to a resident ollama
// daemon and streams the model's output so the box shows it working, then Parse
// turns the completed output into a validated Action set. Unlike OmpCommander it
// makes no subprocess and needs no auth — the model runs locally and stays warm,
// so there is no process-spawn or auth latency per call. It depends only on
// net/http.
//
// The classification prompt is neutral by design: it scopes a task to what the
// task objectively needs, never to any one operator's habits. Deliberate
// over-provisioning ("max everything for this one") stays a manual pick in the
// generator, so the model's suggestion is always a sensible baseline.
type OllamaCommander struct {
	Endpoint string    // ollama base URL; defaults to DefaultOllamaEndpoint
	Model    string    // local model tag; defaults to DefaultLocalModel
	System   DocCorpus // system prompt: the classifier's role/identity
	// KeepAlive controls how long ollama holds the model resident after this
	// call (e.g. "30m", or "-1" to never unload). Empty uses the daemon default.
	KeepAlive string
	// Wrap, if set, turns the raw user prompt into the message actually sent —
	// hosts use it to frame the task as classification and embed the prompt as
	// inert data (see OmpCommander.Wrap).
	Wrap func(prompt string) string
	// Client, if set, is used for the HTTP call (tests inject a stub); otherwise
	// http.DefaultClient. The request carries the Propose context, so cancelling
	// it aborts the call.
	Client *http.Client
	// loaded is the shared user-controlled residency intent (see Loadable): true
	// after Load, false after Unload. It is a pointer so copies of the value-type
	// commander share one flag. When set, Propose pins the model (keep_alive -1)
	// while loaded and runs it transiently (keep_alive 0 — evict after) while not,
	// so the model only lingers in RAM when the user has chosen to load it.
	loaded *bool
}

// NewOllamaCommander builds an OllamaCommander with the default endpoint, local
// model, and the given system prompt (which must instruct the model to answer
// with a JSON object of settings). The model starts unloaded — the user loads it
// explicitly (see Loadable).
func NewOllamaCommander(system DocCorpus) OllamaCommander {
	unloaded := false
	return OllamaCommander{Endpoint: DefaultOllamaEndpoint, Model: DefaultLocalModel, System: system, loaded: &unloaded}
}

// ollamaChatReq is the subset of ollama's /api/chat request we use.
type ollamaChatReq struct {
	Model    string          `json:"model"`
	Messages []ollamaMessage `json:"messages"`
	Stream   bool            `json:"stream"`
	// KeepAlive is any so it serialises correctly for both forms ollama accepts:
	// a duration string ("30m") OR a bare number (-1 = never unload). Sending -1
	// as the string "-1" fails ollama's duration parser ("missing unit"), so the
	// pin-forever case must go on the wire as a JSON number.
	KeepAlive any           `json:"keep_alive,omitempty"`
	Options   ollamaOptions `json:"options"`
}

type ollamaMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// ollamaOptions pins temperature to 0 so the same prompt yields the same
// settings — a classifier should be deterministic, not creative.
type ollamaOptions struct {
	Temperature float64 `json:"temperature"`
}

// ollamaChatChunk is one streamed NDJSON frame from /api/chat.
type ollamaChatChunk struct {
	Message ollamaMessage `json:"message"`
	Done    bool          `json:"done"`
	Error   string        `json:"error"`
}

// Propose POSTs the (wrapped) prompt to ollama and streams the model's output as
// it arrives. The channel closes when the model is done or the context is
// cancelled (which aborts the HTTP request).
func (o OllamaCommander) Propose(ctx context.Context, prompt string) (<-chan string, error) {
	endpoint := o.Endpoint
	if endpoint == "" {
		endpoint = DefaultOllamaEndpoint
	}
	model := o.Model
	if model == "" {
		model = DefaultLocalModel
	}
	msg := prompt
	if o.Wrap != nil {
		msg = o.Wrap(prompt)
	}
	msgs := make([]ollamaMessage, 0, 2)
	if o.System != "" {
		msgs = append(msgs, ollamaMessage{Role: "system", Content: string(o.System)})
	}
	msgs = append(msgs, ollamaMessage{Role: "user", Content: msg})

	body, err := json.Marshal(ollamaChatReq{
		Model:     model,
		Messages:  msgs,
		Stream:    true,
		KeepAlive: o.proposeKeepAlive(),
	})
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint+"/api/chat", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")

	client := o.Client
	if client == nil {
		client = http.DefaultClient
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("reaching ollama at %s (is the daemon running?): %w", endpoint, err)
	}
	if resp.StatusCode != http.StatusOK {
		defer resp.Body.Close()
		return nil, fmt.Errorf("ollama returned %s", resp.Status)
	}
	return streamOllama(ctx, resp.Body), nil
}

// Parse turns the model's completed output into proposed changes, reusing the
// same tolerant JSON extraction as the omp backend.
func (o OllamaCommander) Parse(output string) ([]Action, error) {
	return parseActions([]byte(output))
}

// proposeKeepAlive is the keep_alive a Propose call carries: when the user has
// loaded the model, pin it (-1) so it stays; otherwise run it transiently (0 —
// evict right after) so a suggestion never silently leaves the model resident.
// With no residency flag (a hand-built commander) fall back to the KeepAlive
// field / daemon default.
func (o OllamaCommander) proposeKeepAlive() any {
	if o.loaded == nil {
		return keepAliveValue(o.KeepAlive)
	}
	if *o.loaded {
		return -1
	}
	return 0
}

// Load pins the model resident (keep_alive -1) so subsequent suggestions are
// warm; the first load pulls the weights into RAM and can take a while on CPU.
func (o OllamaCommander) Load(ctx context.Context) error {
	if o.loaded != nil {
		*o.loaded = true
	}
	return o.setResidency(ctx, -1)
}

// Unload evicts the model from memory (keep_alive 0), freeing its RAM.
func (o OllamaCommander) Unload(ctx context.Context) error {
	if o.loaded != nil {
		*o.loaded = false
	}
	return o.setResidency(ctx, 0)
}

// Loaded reports whether the model is resident right now, per the daemon's live
// process list (/api/ps) — the source of truth, independent of the intent flag.
func (o OllamaCommander) Loaded(ctx context.Context) (bool, error) {
	endpoint := o.endpoint()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint+"/api/ps", nil)
	if err != nil {
		return false, err
	}
	resp, err := o.client().Do(req)
	if err != nil {
		return false, fmt.Errorf("reaching ollama at %s (is the daemon running?): %w", endpoint, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return false, fmt.Errorf("ollama returned %s", resp.Status)
	}
	var ps struct {
		Models []struct {
			Name  string `json:"name"`
			Model string `json:"model"`
		} `json:"models"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&ps); err != nil {
		return false, err
	}
	model := o.model()
	for _, m := range ps.Models {
		if m.Name == model || m.Model == model {
			return true, nil
		}
	}
	return false, nil
}

// setResidency asks the daemon to hold (keepAlive -1) or drop (keepAlive 0) the
// model without generating: an empty-prompt /api/generate carrying only the
// keep_alive is ollama's idiom for load/unload.
func (o OllamaCommander) setResidency(ctx context.Context, keepAlive int) error {
	body, err := json.Marshal(map[string]any{"model": o.model(), "keep_alive": keepAlive})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, o.endpoint()+"/api/generate", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := o.client().Do(req)
	if err != nil {
		return fmt.Errorf("reaching ollama at %s (is the daemon running?): %w", o.endpoint(), err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("ollama returned %s", resp.Status)
	}
	return nil
}

// endpoint, model, and client resolve the configured values with their defaults.
func (o OllamaCommander) endpoint() string {
	if o.Endpoint == "" {
		return DefaultOllamaEndpoint
	}
	return o.Endpoint
}

func (o OllamaCommander) model() string {
	if o.Model == "" {
		return DefaultLocalModel
	}
	return o.Model
}

func (o OllamaCommander) client() *http.Client {
	if o.Client == nil {
		return http.DefaultClient
	}
	return o.Client
}

// keepAliveValue renders the configured keep-alive for the wire. Empty → omitted
// (daemon default governs). An integer string → a JSON number (ollama's only
// accepted form for -1 = never unload). Anything else → the string as-is (a Go
// duration like "30m").
func keepAliveValue(s string) any {
	if s == "" {
		return nil
	}
	if n, err := strconv.Atoi(s); err == nil {
		return n
	}
	return s
}

// streamOllama decodes the NDJSON stream, emitting each frame's content chunk on
// the returned channel and closing it when the stream ends or ctx is cancelled.
// It owns rc and closes it. An error frame is surfaced as text so the box can
// show what went wrong, mirroring streamCmd's stderr merge.
func streamOllama(ctx context.Context, rc io.ReadCloser) <-chan string {
	ch := make(chan string)
	go func() {
		defer close(ch)
		defer rc.Close()
		sc := bufio.NewScanner(rc)
		sc.Buffer(make([]byte, 0, 8192), 1<<20)
		for sc.Scan() {
			line := bytes.TrimSpace(sc.Bytes())
			if len(line) == 0 {
				continue
			}
			var chunk ollamaChatChunk
			if err := json.Unmarshal(line, &chunk); err != nil {
				continue // skip a malformed frame rather than abort the whole stream
			}
			out := chunk.Message.Content
			if chunk.Error != "" {
				out += chunk.Error
			}
			if out != "" {
				select {
				case ch <- out:
				case <-ctx.Done():
					return
				}
			}
			if chunk.Done {
				return
			}
		}
	}()
	return ch
}
