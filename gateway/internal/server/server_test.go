package server

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestHealthz(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()

	h, err := New("")
	if err != nil {
		t.Fatalf("New err = %v", err)
	}
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	if !strings.Contains(rec.Body.String(), `"status":"ok"`) {
		t.Fatalf("body = %s", rec.Body.String())
	}
}

func TestModels(t *testing.T) {
	cfgPath := filepath.Join("..", "..", "..", "examples", "providers.example.json")
	h, err := New(cfgPath)
	if err != nil {
		t.Fatalf("New err = %v", err)
	}
	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	rec := httptest.NewRecorder()

	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	var body struct {
		Data []struct {
			ID      string `json:"id"`
			Object  string `json:"object"`
			OwnedBy string `json:"owned_by"`
		} `json:"data"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode err = %v; body=%s", err, rec.Body.String())
	}
	found := false
	for _, m := range body.Data {
		if m.ID == "qwen3-coder" && m.OwnedBy == "local-openai-compatible" && m.Object == "model" {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("body = %s", rec.Body.String())
	}
}

func TestResponsesRequiresContentType(t *testing.T) {
	h, err := New(filepath.Join("..", "..", "..", "examples", "providers.example.json"))
	if err != nil {
		t.Fatalf("New err = %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(`{}`))
	rec := httptest.NewRecorder()

	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusBadRequest)
	}
}

func TestResponsesProxiesToFakeOpenAIChat(t *testing.T) {
	// Fake upstream OpenAI Chat-compatible server.
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/chat/completions" {
			t.Fatalf("upstream path = %s", r.URL.Path)
		}
		if ct := r.Header.Get("Content-Type"); ct != "application/json" {
			t.Fatalf("upstream content-type = %q", ct)
		}
		var req struct {
			Model    string `json:"model"`
			Messages []struct {
				Role    string `json:"role"`
				Content string `json:"content"`
			} `json:"messages"`
			Stream bool `json:"stream"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("decode upstream err = %v", err)
		}
		if req.Model != "qwen3-coder" {
			t.Fatalf("upstream model = %q", req.Model)
		}
		if req.Stream {
			t.Fatal("stream must be false in phase 1")
		}
		if len(req.Messages) != 1 || req.Messages[0].Role != "user" || req.Messages[0].Content != "Say hi" {
			t.Fatalf("messages = %+v", req.Messages)
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(map[string]any{
			"id":    "chatcmpl-test",
			"model": "qwen3-coder",
			"choices": []map[string]any{
				{
					"index": 0,
					"message": map[string]string{
						"role":    "assistant",
						"content": "hi",
					},
					"finish_reason": "stop",
				},
			},
			"usage": map[string]int{"prompt_tokens": 4, "completion_tokens": 1, "total_tokens": 5},
		}); err != nil {
			t.Fatalf("encode upstream response err = %v", err)
		}
	}))
	defer upstream.Close()

	// Build a one-provider config that points at the fake upstream.
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "providers.json")
	cfgJSON := `{"providers":[{"id":"test","name":"Test","base_url":"` + upstream.URL + `","api_format":"openai_chat","models":[{"id":"qwen3-coder"}]}]}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
		t.Fatal(err)
	}

	h, err := New(cfgPath)
	if err != nil {
		t.Fatalf("New err = %v", err)
	}

	body := strings.NewReader(`{"model":"qwen3-coder","input":"Say hi"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", body)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	var resp struct {
		ID     string `json:"id"`
		Model  string `json:"model"`
		Status string `json:"status"`
		Output []struct {
			Type    string `json:"type"`
			Role    string `json:"role"`
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
		} `json:"output"`
		Usage map[string]int `json:"usage"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response err = %v; body=%s", err, rec.Body.String())
	}
	if resp.Model != "qwen3-coder" {
		t.Fatalf("resp model = %q", resp.Model)
	}
	if resp.Status != "completed" {
		t.Fatalf("status = %q", resp.Status)
	}
	if len(resp.Output) != 1 || len(resp.Output[0].Content) != 1 || resp.Output[0].Content[0].Text != "hi" {
		t.Fatalf("output = %+v", resp.Output)
	}
	if resp.Usage == nil || resp.Usage["total_tokens"] != 5 {
		t.Fatalf("usage = %+v", resp.Usage)
	}
}

func TestUsageJSONLOmitsBodiesHeadersAndURLs(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(map[string]any{
			"id":    "chatcmpl-usage",
			"model": "qwen3-coder",
			"choices": []map[string]any{{
				"message":       map[string]string{"role": "assistant", "content": "secret-response-body"},
				"finish_reason": "stop",
			}},
			"usage": map[string]int{"prompt_tokens": 7, "completion_tokens": 3, "total_tokens": 10},
		}); err != nil {
			t.Fatalf("encode upstream response err = %v", err)
		}
	}))
	defer upstream.Close()

	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "providers.json")
	cfgJSON := `{"providers":[{"id":"test","name":"Test","base_url":"` + upstream.URL + `","api_format":"openai_chat","auth_env":"RELAYKIT_TEST_API_KEY","models":[{"id":"qwen3-coder"}]}]}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("RELAYKIT_TEST_API_KEY", "secret-env-token")

	usagePath := filepath.Join(dir, "usage.jsonl")
	h, err := NewWithUsageLog(cfgPath, usagePath)
	if err != nil {
		t.Fatalf("New err = %v", err)
	}

	body := strings.NewReader(`{"model":"qwen3-coder","input":"prompt-secret-value api_key=secret"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", body)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer request-header-secret")
	req.Header.Set("Cookie", "session=request-cookie-secret")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}

	raw, err := os.ReadFile(usagePath)
	if err != nil {
		t.Fatalf("read usage log err = %v", err)
	}
	line := string(raw)
	for _, forbidden := range []string{
		"prompt-secret-value",
		"api_key",
		"secret-response-body",
		"request-header-secret",
		"request-cookie-secret",
		"secret-env-token",
		upstream.URL,
		"Authorization",
		"headers",
		"body",
	} {
		if strings.Contains(line, forbidden) {
			t.Fatalf("usage log leaked %q in %s", forbidden, line)
		}
	}
	var event struct {
		ProviderID   string `json:"provider_id"`
		Model        string `json:"model"`
		Route        string `json:"route"`
		Status       string `json:"status"`
		HTTPStatus   int    `json:"http_status"`
		InputTokens  int    `json:"input_tokens"`
		OutputTokens int    `json:"output_tokens"`
		TotalTokens  int    `json:"total_tokens"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(raw), &event); err != nil {
		t.Fatalf("decode usage log err = %v; raw=%s", err, raw)
	}
	if event.ProviderID != "test" || event.Model != "qwen3-coder" || event.Route != "/v1/responses" || event.Status != "completed" || event.HTTPStatus != http.StatusOK {
		t.Fatalf("event = %+v", event)
	}
	if event.InputTokens != 7 || event.OutputTokens != 3 || event.TotalTokens != 10 {
		t.Fatalf("tokens = %+v", event)
	}
}

func TestResponsesStreamsFakeOpenAIChatSSE(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Model    string `json:"model"`
			Messages []struct {
				Role    string `json:"role"`
				Content string `json:"content"`
			} `json:"messages"`
			Stream bool `json:"stream"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("decode upstream err = %v", err)
		}
		if req.Model != "qwen3-coder" || !req.Stream {
			t.Fatalf("upstream request = %+v", req)
		}
		w.Header().Set("Content-Type", "text/event-stream")
		chunks := []string{
			`data: {"id":"chatcmpl-stream","model":"qwen3-coder","choices":[{"delta":{"role":"assistant"}}]}`,
			`data: {"id":"chatcmpl-stream","model":"qwen3-coder","choices":[{"delta":{"content":"he"}}]}`,
			`data: {"id":"chatcmpl-stream","model":"qwen3-coder","choices":[{"delta":{"content":"llo"},"finish_reason":"stop"}],"usage":{"total_tokens":5}}`,
			`data: [DONE]`,
		}
		for _, chunk := range chunks {
			if _, err := w.Write([]byte(chunk + "\n\n")); err != nil {
				t.Fatalf("write upstream chunk err = %v", err)
			}
		}
	}))
	defer upstream.Close()

	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "providers.json")
	cfgJSON := `{"providers":[{"id":"test","name":"Test","base_url":"` + upstream.URL + `","api_format":"openai_chat","models":[{"id":"qwen3-coder"}]}]}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
		t.Fatal(err)
	}

	h, err := New(cfgPath)
	if err != nil {
		t.Fatalf("New err = %v", err)
	}

	body := strings.NewReader(`{"model":"qwen3-coder","input":"Say hi","stream":true}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", body)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/event-stream") {
		t.Fatalf("content-type = %q", ct)
	}
	got := rec.Body.String()
	for _, want := range []string{
		"event: response.created",
		`"type":"response.created"`,
		"event: response.output_text.delta",
		`"delta":"he"`,
		`"delta":"llo"`,
		"event: response.completed",
		`"finish_reason":"stop"`,
		`"total_tokens":5`,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("stream missing %q in:\n%s", want, got)
		}
	}
}

func TestResponsesStreamMalformedChunkEmitsError(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		if _, err := w.Write([]byte("data: {not json}\n\n")); err != nil {
			t.Fatalf("write upstream chunk err = %v", err)
		}
	}))
	defer upstream.Close()

	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "providers.json")
	cfgJSON := `{"providers":[{"id":"test","name":"Test","base_url":"` + upstream.URL + `","api_format":"openai_chat","models":[{"id":"qwen3-coder"}]}]}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
		t.Fatal(err)
	}

	h, err := New(cfgPath)
	if err != nil {
		t.Fatalf("New err = %v", err)
	}

	body := strings.NewReader(`{"model":"qwen3-coder","input":"Say hi","stream":true}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", body)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	got := rec.Body.String()
	if !strings.Contains(got, "event: response.error") || !strings.Contains(got, `"type":"response.error"`) {
		t.Fatalf("stream did not emit error frame:\n%s", got)
	}
}

func TestResponsesStreamTruncationEmitsError(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		if _, err := w.Write([]byte(`data: {"id":"chatcmpl-stream","model":"qwen3-coder","choices":[{"delta":{"content":"hi"}}]}` + "\n\n")); err != nil {
			t.Fatalf("write upstream chunk err = %v", err)
		}
	}))
	defer upstream.Close()

	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "providers.json")
	cfgJSON := `{"providers":[{"id":"test","name":"Test","base_url":"` + upstream.URL + `","api_format":"openai_chat","models":[{"id":"qwen3-coder"}]}]}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
		t.Fatal(err)
	}

	h, err := New(cfgPath)
	if err != nil {
		t.Fatalf("New err = %v", err)
	}

	body := strings.NewReader(`{"model":"qwen3-coder","input":"Say hi","stream":true}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", body)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	got := rec.Body.String()
	if !strings.Contains(got, `"delta":"hi"`) || !strings.Contains(got, "event: response.error") {
		t.Fatalf("stream did not preserve delta and emit truncation error:\n%s", got)
	}
}

func TestResponsesProxiesToFakeAnthropicMessages(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/messages" {
			t.Fatalf("upstream path = %s", r.URL.Path)
		}
		var req struct {
			Model     string `json:"model"`
			MaxTokens int    `json:"max_tokens"`
			Messages  []struct {
				Role    string `json:"role"`
				Content string `json:"content"`
			} `json:"messages"`
			Stream bool `json:"stream"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("decode upstream err = %v", err)
		}
		if req.Model != "claude-example" || req.MaxTokens == 0 || req.Stream {
			t.Fatalf("upstream request = %+v", req)
		}
		if len(req.Messages) != 1 || req.Messages[0].Role != "user" || req.Messages[0].Content != "Say hi" {
			t.Fatalf("messages = %+v", req.Messages)
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(map[string]any{
			"id":          "msg-test",
			"model":       "claude-example",
			"stop_reason": "end_turn",
			"content":     []map[string]string{{"type": "text", "text": "hi"}},
			"usage":       map[string]int{"input_tokens": 4, "output_tokens": 1},
		}); err != nil {
			t.Fatalf("encode upstream response err = %v", err)
		}
	}))
	defer upstream.Close()

	h, err := New(writeTestProviderConfig(t, upstream.URL, "anthropic_messages", "claude-example"))
	if err != nil {
		t.Fatalf("New err = %v", err)
	}

	body := strings.NewReader(`{"model":"claude-example","input":"Say hi"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", body)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), `"text":"hi"`) || !strings.Contains(rec.Body.String(), `"status":"completed"`) {
		t.Fatalf("body = %s", rec.Body.String())
	}
}

func TestResponsesStreamsFakeAnthropicMessages(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Model  string `json:"model"`
			Stream bool   `json:"stream"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("decode upstream err = %v", err)
		}
		if req.Model != "claude-example" || !req.Stream {
			t.Fatalf("upstream request = %+v", req)
		}
		w.Header().Set("Content-Type", "text/event-stream")
		chunks := []string{
			`event: message_start` + "\n" + `data: {"message":{"id":"msg-stream","model":"claude-example"}}`,
			`event: content_block_delta` + "\n" + `data: {"delta":{"type":"text_delta","text":"he"}}`,
			`event: content_block_delta` + "\n" + `data: {"delta":{"type":"text_delta","text":"llo"}}`,
			`event: message_delta` + "\n" + `data: {"delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}`,
			`event: message_stop` + "\n" + `data: {}`,
		}
		for _, chunk := range chunks {
			if _, err := w.Write([]byte(chunk + "\n\n")); err != nil {
				t.Fatalf("write upstream chunk err = %v", err)
			}
		}
	}))
	defer upstream.Close()

	h, err := New(writeTestProviderConfig(t, upstream.URL, "anthropic_messages", "claude-example"))
	if err != nil {
		t.Fatalf("New err = %v", err)
	}

	body := strings.NewReader(`{"model":"claude-example","input":"Say hi","stream":true}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", body)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	got := rec.Body.String()
	for _, want := range []string{
		"event: response.created",
		`"model":"claude-example"`,
		`"delta":"he"`,
		`"delta":"llo"`,
		"event: response.completed",
		`"finish_reason":"end_turn"`,
		`"output_tokens":1`,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("stream missing %q in:\n%s", want, got)
		}
	}
}

func writeTestProviderConfig(t *testing.T, baseURL, apiFormat, model string) string {
	t.Helper()
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "providers.json")
	cfgJSON := `{"providers":[{"id":"test","name":"Test","base_url":"` + baseURL + `","api_format":"` + apiFormat + `","models":[{"id":"` + model + `"}]}]}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
		t.Fatal(err)
	}
	return cfgPath
}
