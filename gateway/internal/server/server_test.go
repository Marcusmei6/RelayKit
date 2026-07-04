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

	"github.com/klauspost/compress/zstd"
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
	if !strings.Contains(rec.Body.String(), `"service":"relaykit"`) {
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
		Models []struct {
			ID string `json:"id"`
		} `json:"models"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode err = %v; body=%s", err, rec.Body.String())
	}
	if len(body.Models) != len(body.Data) {
		t.Fatalf("models field must mirror data field: %+v", body)
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

func TestModelsProbesKeyFileProvidersAndHidesUnhealthyModels(t *testing.T) {
	healthyUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Model string `json:"model"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("decode healthy probe err = %v", err)
		}
		if req.Model != "healthy-upstream" {
			t.Fatalf("healthy probe model = %q", req.Model)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}`))
	}))
	defer healthyUpstream.Close()
	slowUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "not ready", http.StatusGatewayTimeout)
	}))
	defer slowUpstream.Close()

	dir := t.TempDir()
	keyPath := filepath.Join(dir, "provider.key")
	if err := os.WriteFile(keyPath, []byte("file-token\n"), 0600); err != nil {
		t.Fatal(err)
	}
	cfgPath := filepath.Join(dir, "providers.json")
	cfgJSON := `{"providers":[` +
		`{"id":"healthy","name":"Healthy","base_url":"` + healthyUpstream.URL + `","api_format":"openai_chat","credential_ref":{"kind":"key_file","value":"` + keyPath + `"},"models":[{"id":"public/healthy","upstream_model":"healthy-upstream"}]},` +
		`{"id":"slow","name":"Slow","base_url":"` + slowUpstream.URL + `","api_format":"openai_chat","credential_ref":{"kind":"key_file","value":"` + keyPath + `"},"models":[{"id":"public/slow","upstream_model":"slow-upstream"}]}` +
		`]}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
		t.Fatal(err)
	}
	h, err := New(cfgPath)
	if err != nil {
		t.Fatalf("New err = %v", err)
	}
	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	got := rec.Body.String()
	if !strings.Contains(got, "public/healthy") {
		t.Fatalf("healthy model missing: %s", got)
	}
	if strings.Contains(got, "public/slow") {
		t.Fatalf("slow model should be hidden: %s", got)
	}
	if !strings.Contains(got, `"probed":true`) || !strings.Contains(got, `"unhealthy":1`) {
		t.Fatalf("redacted health counts missing: %s", got)
	}
}

func TestModelsHidesDisabledProviders(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "providers.json")
	cfgJSON := `{"providers":[{"id":"disabled","name":"Disabled","base_url":"http://127.0.0.1:11434/v1","api_format":"openai_chat","routing":{"status":"disabled"},"models":[{"id":"hidden-model"}]},{"id":"enabled","name":"Enabled","base_url":"http://127.0.0.1:11434/v1","api_format":"openai_chat","models":[{"id":"visible-model"}]}]}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
		t.Fatal(err)
	}
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
	got := rec.Body.String()
	if strings.Contains(got, "hidden-model") {
		t.Fatalf("disabled model was listed: %s", got)
	}
	if !strings.Contains(got, "visible-model") {
		t.Fatalf("enabled model missing: %s", got)
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

func TestResponsesUsesUpstreamModelMapping(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Model string `json:"model"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("decode upstream request err = %v", err)
		}
		if req.Model != "upstream-coder" {
			t.Fatalf("upstream model = %q, want upstream-coder", req.Model)
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(map[string]any{
			"id":    "chatcmpl-upstream-map",
			"model": req.Model,
			"choices": []map[string]any{{
				"message":       map[string]string{"role": "assistant", "content": "OK"},
				"finish_reason": "stop",
			}},
		}); err != nil {
			t.Fatalf("encode upstream response err = %v", err)
		}
	}))
	defer upstream.Close()

	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "providers.json")
	cfgJSON := `{"providers":[{"id":"test","name":"Test","base_url":"` + upstream.URL + `","api_format":"openai_chat","models":[{"id":"public/coder","upstream_model":"upstream-coder"}]}]}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
		t.Fatal(err)
	}
	h, err := New(cfgPath)
	if err != nil {
		t.Fatalf("New err = %v", err)
	}
	body := strings.NewReader(`{"model":"public/coder","input":"reply OK"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", body)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), `"model":"public/coder"`) {
		t.Fatalf("RelayKit response did not preserve public model id: %s", rec.Body.String())
	}
}

func TestResponsesRejectsDisabledProviderModel(t *testing.T) {
	cfgPath := writeTestProviderConfigWithRouting(t, "http://127.0.0.1:11434", "openai_chat", "hidden-model", `"status":"disabled"`)
	h, err := New(cfgPath)
	if err != nil {
		t.Fatalf("New err = %v", err)
	}
	body := strings.NewReader(`{"model":"hidden-model","input":"reply OK"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", body)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "unknown model") {
		t.Fatalf("body = %s", rec.Body.String())
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
			"usage": map[string]int{"prompt_tokens": 4, "completion_tokens": 1},
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
		ID         string `json:"id"`
		Model      string `json:"model"`
		Status     string `json:"status"`
		OutputText string `json:"output_text"`
		Output     []struct {
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
	if resp.OutputText != "hi" {
		t.Fatalf("output_text = %q", resp.OutputText)
	}
	if len(resp.Output) != 1 || len(resp.Output[0].Content) != 1 || resp.Output[0].Content[0].Text != "hi" {
		t.Fatalf("output = %+v", resp.Output)
	}
	if resp.Usage == nil || resp.Usage["total_tokens"] != 5 {
		t.Fatalf("usage = %+v", resp.Usage)
	}
}

func TestResponsesAcceptsCodexInputMessageParts(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Messages []struct {
				Role    string `json:"role"`
				Content string `json:"content"`
			} `json:"messages"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("decode upstream err = %v", err)
		}
		if len(req.Messages) != 1 || req.Messages[0].Role != "user" || req.Messages[0].Content != "Reply exactly OK." {
			t.Fatalf("messages = %+v", req.Messages)
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(map[string]any{
			"id": "chatcmpl-codex-input",
			"choices": []map[string]any{{
				"message":       map[string]string{"role": "assistant", "content": "OK"},
				"finish_reason": "stop",
			}},
		}); err != nil {
			t.Fatalf("encode upstream response err = %v", err)
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

	body := strings.NewReader(`{"model":"qwen3-coder","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"Reply exactly OK."}]}]}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", body)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
}

func TestResponsesDoesNotLeakUpstreamErrorBody(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "upstream failed for upstream-coder api_key=secret", http.StatusInternalServerError)
	}))
	defer upstream.Close()

	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "providers.json")
	cfgJSON := `{"providers":[{"id":"test","name":"Test","base_url":"` + upstream.URL + `","api_format":"openai_chat","models":[{"id":"public/coder","upstream_model":"upstream-coder"}]}]}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
		t.Fatal(err)
	}
	h, err := New(cfgPath)
	if err != nil {
		t.Fatalf("New err = %v", err)
	}
	body := strings.NewReader(`{"model":"public/coder","input":"reply OK"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", body)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	for _, forbidden := range []string{"upstream-coder", "api_key", "secret"} {
		if strings.Contains(rec.Body.String(), forbidden) {
			t.Fatalf("upstream error leaked %q in body: %s", forbidden, rec.Body.String())
		}
	}
	if !strings.Contains(rec.Body.String(), "upstream returned non-success status") {
		t.Fatalf("body = %s", rec.Body.String())
	}
}

func TestResponsesDoesNotLeakUpstreamTransportError(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "providers.json")
	cfgJSON := `{"providers":[{"id":"test","name":"Test","base_url":"http://sentinel-redacted-host.invalid/v1","api_format":"openai_chat","models":[{"id":"public/coder"}]}]}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
		t.Fatal(err)
	}
	h, err := New(cfgPath)
	if err != nil {
		t.Fatalf("New err = %v", err)
	}
	body := strings.NewReader(`{"model":"public/coder","input":"reply OK"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", body)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	for _, forbidden := range []string{"sentinel-redacted-host", "invalid", "/v1", "chat/completions"} {
		if strings.Contains(rec.Body.String(), forbidden) {
			t.Fatalf("transport error leaked %q in body: %s", forbidden, rec.Body.String())
		}
	}
	if !strings.Contains(rec.Body.String(), "upstream request failed") {
		t.Fatalf("body = %s", rec.Body.String())
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
			"usage": map[string]int{"prompt_tokens": 7, "completion_tokens": 3},
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

func TestCredentialRefEnvSetsOpenAIChatAuthorization(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "Bearer fake-token" {
			t.Fatalf("Authorization = %q", got)
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(map[string]any{
			"id":    "chatcmpl-credential-ref",
			"model": "qwen3-coder",
			"choices": []map[string]any{{
				"message":       map[string]string{"role": "assistant", "content": "OK"},
				"finish_reason": "stop",
			}},
		}); err != nil {
			t.Fatalf("encode upstream response err = %v", err)
		}
	}))
	defer upstream.Close()

	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "providers.json")
	cfgJSON := `{"providers":[{"id":"test","name":"Test","base_url":"` + upstream.URL + `","api_format":"openai_chat","credential_ref":{"kind":"env","value":"RELAYKIT_TEST_PROVIDER_TOKEN"},"models":[{"id":"qwen3-coder"}]}]}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("RELAYKIT_TEST_PROVIDER_TOKEN", "fake-token")

	h, err := New(cfgPath)
	if err != nil {
		t.Fatalf("New err = %v", err)
	}
	body := strings.NewReader(`{"model":"qwen3-coder","input":"reply OK"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", body)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
}

func TestCredentialRefKeyFileSetsCustomAuthorizationHeader(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("x-relay-api-key"); got != "file-token" {
			t.Fatalf("x-relay-api-key = %q", got)
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(map[string]any{
			"id":    "chatcmpl-key-file",
			"model": "qwen3-coder",
			"choices": []map[string]any{{
				"message":       map[string]string{"role": "assistant", "content": "OK"},
				"finish_reason": "stop",
			}},
		}); err != nil {
			t.Fatalf("encode upstream response err = %v", err)
		}
	}))
	defer upstream.Close()

	dir := t.TempDir()
	keyPath := filepath.Join(dir, "provider.key")
	if err := os.WriteFile(keyPath, []byte("file-token\n"), 0600); err != nil {
		t.Fatal(err)
	}
	cfgPath := filepath.Join(dir, "providers.json")
	cfgJSON := `{"providers":[{"id":"test","name":"Test","base_url":"` + upstream.URL + `","api_format":"openai_chat","credential_ref":{"kind":"key_file","value":"` + keyPath + `","header":"x-relay-api-key"},"models":[{"id":"qwen3-coder"}]}]}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
		t.Fatal(err)
	}

	h, err := New(cfgPath)
	if err != nil {
		t.Fatalf("New err = %v", err)
	}
	body := strings.NewReader(`{"model":"qwen3-coder","input":"reply OK"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", body)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
}

func TestResponsesAcceptsZstdEncodedRequest(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(map[string]any{
			"id": "chatcmpl-zstd",
			"choices": []map[string]any{{
				"message":       map[string]string{"role": "assistant", "content": "OK"},
				"finish_reason": "stop",
			}},
		}); err != nil {
			t.Fatalf("encode upstream response err = %v", err)
		}
	}))
	defer upstream.Close()

	h, err := New(writeTestProviderConfig(t, upstream.URL, "openai_chat", "qwen3-coder"))
	if err != nil {
		t.Fatalf("New err = %v", err)
	}
	var body bytes.Buffer
	encoder, err := zstd.NewWriter(&body)
	if err != nil {
		t.Fatalf("zstd writer err = %v", err)
	}
	if _, err := encoder.Write([]byte(`{"model":"qwen3-coder","input":"reply OK"}`)); err != nil {
		t.Fatalf("zstd write err = %v", err)
	}
	if err := encoder.Close(); err != nil {
		t.Fatalf("zstd close err = %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", &body)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Content-Encoding", "zstd")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
}

func TestAnthropicRequestNormalizesUnsupportedRoles(t *testing.T) {
	req := upstreamRequest("anthropic_messages", "m", []chatMessage{
		{Role: "system", Content: "system"},
		{Role: "developer", Content: "developer"},
		{Role: "assistant", Content: "assistant"},
	}, false)
	messages := req["messages"].([]chatMessage)
	if messages[0].Role != "user" || messages[1].Role != "user" || messages[2].Role != "assistant" {
		t.Fatalf("messages = %+v", messages)
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
		if req.Model != "upstream-coder" || !req.Stream {
			t.Fatalf("upstream request = %+v", req)
		}
		w.Header().Set("Content-Type", "text/event-stream")
		chunks := []string{
			`data: {"id":"chatcmpl-stream","model":"upstream-coder","choices":[{"delta":{"role":"assistant"}}]}`,
			`data: {"id":"chatcmpl-stream","model":"upstream-coder","choices":[{"delta":{"content":"he"}}]}`,
			`data: {"id":"chatcmpl-stream","model":"upstream-coder","choices":[{"delta":{"content":"llo"},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":3}}`,
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
	cfgJSON := `{"providers":[{"id":"test","name":"Test","base_url":"` + upstream.URL + `","api_format":"openai_chat","models":[{"id":"public/coder","upstream_model":"upstream-coder"}]}]}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
		t.Fatal(err)
	}

	h, err := New(cfgPath)
	if err != nil {
		t.Fatalf("New err = %v", err)
	}

	body := strings.NewReader(`{"model":"public/coder","input":"Say hi","stream":true}`)
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
		`"model":"public/coder"`,
		"event: response.output_item.added",
		"event: response.content_part.added",
		"event: response.output_text.delta",
		`"delta":"he"`,
		`"delta":"llo"`,
		"event: response.content_part.done",
		"event: response.output_item.done",
		"event: response.completed",
		`"finish_reason":"stop"`,
		`"total_tokens":5`,
		`"input_tokens"`,
		`"output_text":"hello"`,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("stream missing %q in:\n%s", want, got)
		}
	}
	if strings.Index(got, "event: response.output_item.added") > strings.Index(got, "event: response.output_text.delta") {
		t.Fatalf("output item must be added before text delta:\n%s", got)
	}
	if strings.Index(got, "event: response.content_part.added") > strings.Index(got, "event: response.output_text.delta") {
		t.Fatalf("content part must be added before text delta:\n%s", got)
	}
	if strings.Contains(got, "upstream-coder") {
		t.Fatalf("stream leaked upstream model id:\n%s", got)
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

func TestResponsesAnthropicUsesUpstreamModelMapping(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Model string `json:"model"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("decode upstream request err = %v", err)
		}
		if req.Model != "upstream-claude" {
			t.Fatalf("upstream model = %q, want upstream-claude", req.Model)
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(map[string]any{
			"id":          "msg-upstream-map",
			"model":       req.Model,
			"stop_reason": "end_turn",
			"content":     []map[string]string{{"type": "text", "text": "hi"}},
		}); err != nil {
			t.Fatalf("encode upstream response err = %v", err)
		}
	}))
	defer upstream.Close()

	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "providers.json")
	cfgJSON := `{"providers":[{"id":"test","name":"Test","base_url":"` + upstream.URL + `","api_format":"anthropic_messages","models":[{"id":"public/claude","upstream_model":"upstream-claude"}]}]}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
		t.Fatal(err)
	}
	h, err := New(cfgPath)
	if err != nil {
		t.Fatalf("New err = %v", err)
	}

	body := strings.NewReader(`{"model":"public/claude","input":"Say hi"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", body)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), `"model":"public/claude"`) {
		t.Fatalf("RelayKit response did not preserve public model id: %s", rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), "upstream-claude") {
		t.Fatalf("RelayKit response leaked upstream model id: %s", rec.Body.String())
	}
}

func TestResponsesMapsAnthropicToolUse(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/messages" {
			t.Fatalf("upstream path = %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(map[string]any{
			"id":          "msg-tool",
			"model":       "claude-example",
			"stop_reason": "tool_use",
			"content": []map[string]any{
				{"type": "text", "text": "checking"},
				{
					"type":  "tool_use",
					"id":    "toolu_123",
					"name":  "lookup",
					"input": map[string]any{"query": "relaykit"},
				},
			},
		}); err != nil {
			t.Fatalf("encode upstream response err = %v", err)
		}
	}))
	defer upstream.Close()

	h, err := New(writeTestProviderConfig(t, upstream.URL, "anthropic_messages", "claude-example"))
	if err != nil {
		t.Fatalf("New err = %v", err)
	}

	body := strings.NewReader(`{"model":"claude-example","input":"Search"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", body)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	var got struct {
		Output []map[string]any `json:"output"`
		Status string           `json:"status"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode response err = %v; body=%s", err, rec.Body.String())
	}
	if len(got.Output) != 2 {
		t.Fatalf("output = %+v", got.Output)
	}
	if got.Status != "completed" {
		t.Fatalf("status = %q", got.Status)
	}
	call := got.Output[1]
	if call["type"] != "function_call" || call["call_id"] != "toolu_123" || call["name"] != "lookup" || call["arguments"] != `{"query":"relaykit"}` {
		t.Fatalf("function call = %+v", call)
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
		if req.Model != "upstream-claude" || !req.Stream {
			t.Fatalf("upstream request = %+v", req)
		}
		w.Header().Set("Content-Type", "text/event-stream")
		chunks := []string{
			`event: message_start` + "\n" + `data: {"message":{"id":"msg-stream","model":"upstream-claude"}}`,
			`event: content_block_start` + "\n" + `data: {"index":0,"content_block":{"type":"text","text":""}}`,
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

	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "providers.json")
	cfgJSON := `{"providers":[{"id":"test","name":"Test","base_url":"` + upstream.URL + `","api_format":"anthropic_messages","models":[{"id":"public/claude","upstream_model":"upstream-claude"}]}]}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
		t.Fatal(err)
	}
	h, err := New(cfgPath)
	if err != nil {
		t.Fatalf("New err = %v", err)
	}

	body := strings.NewReader(`{"model":"public/claude","input":"Say hi","stream":true}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", body)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	got := rec.Body.String()
	for _, want := range []string{
		"event: response.created",
		"event: response.output_item.added",
		"event: response.content_part.added",
		`"model":"public/claude"`,
		`"delta":"he"`,
		`"delta":"llo"`,
		"event: response.content_part.done",
		"event: response.output_item.done",
		"event: response.completed",
		`"finish_reason":"end_turn"`,
		`"output_tokens":1`,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("stream missing %q in:\n%s", want, got)
		}
	}
	if strings.Contains(got, "upstream-claude") {
		t.Fatalf("stream leaked upstream model id:\n%s", got)
	}
}

func TestResponsesStreamsAnthropicToolUse(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		chunks := []string{
			`event: message_start` + "\n" + `data: {"message":{"id":"msg-stream-tool","model":"claude-example"}}`,
			`event: content_block_start` + "\n" + `data: {"index":0,"content_block":{"type":"tool_use","id":"toolu_123","name":"lookup","input":{}}}`,
			`event: content_block_delta` + "\n" + `data: {"index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":\""}}`,
			`event: content_block_delta` + "\n" + `data: {"index":0,"delta":{"type":"input_json_delta","partial_json":"needle-tool-argument-9381\"}"}}`,
			`event: content_block_stop` + "\n" + `data: {"index":0}`,
			`event: content_block_start` + "\n" + `data: {"index":1,"content_block":{"type":"tool_use","id":"toolu_456","name":"summarize","input":{}}}`,
			`event: content_block_delta` + "\n" + `data: {"index":1,"delta":{"type":"input_json_delta","partial_json":"{}"}}`,
			`event: content_block_stop` + "\n" + `data: {"index":1}`,
			`event: message_delta` + "\n" + `data: {"delta":{"stop_reason":"tool_use"}}`,
			`event: message_stop` + "\n" + `data: {}`,
		}
		for _, chunk := range chunks {
			if _, err := w.Write([]byte(chunk + "\n\n")); err != nil {
				t.Fatalf("write upstream chunk err = %v", err)
			}
		}
	}))
	defer upstream.Close()

	usageLog := filepath.Join(t.TempDir(), "usage.jsonl")
	h, err := NewWithUsageLog(writeTestProviderConfig(t, upstream.URL, "anthropic_messages", "claude-example"), usageLog)
	if err != nil {
		t.Fatalf("New err = %v", err)
	}

	body := strings.NewReader(`{"model":"claude-example","input":"Search","stream":true}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", body)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	got := rec.Body.String()
	for _, want := range []string{
		"event: response.output_item.added",
		"event: response.output_item.done",
		`"type":"function_call"`,
		`"call_id":"toolu_123"`,
		`"name":"lookup"`,
		`"arguments":"{\"query\":\"needle-tool-argument-9381\"}"`,
		`"call_id":"toolu_456"`,
		`"name":"summarize"`,
		`"arguments":"{}"`,
		`"finish_reason":"tool_use"`,
		`"status":"completed"`,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("stream missing %q in:\n%s", want, got)
		}
	}
	if strings.Index(got, `"call_id":"toolu_123"`) > strings.Index(got, `"call_id":"toolu_456"`) {
		t.Fatalf("function calls emitted out of order:\n%s", got)
	}
	if strings.Index(got, "event: response.output_item.added") > strings.Index(got, "event: response.output_item.done") {
		t.Fatalf("function call start emitted after done:\n%s", got)
	}
	usage, err := os.ReadFile(usageLog)
	if err != nil {
		t.Fatalf("read usage log err = %v", err)
	}
	if strings.Contains(string(usage), "needle-tool-argument-9381") {
		t.Fatalf("usage log contains tool arguments: %s", usage)
	}
}

func TestResponsesStreamsAnthropicToolUseIncompleteArguments(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		chunks := []string{
			`event: message_start` + "\n" + `data: {"message":{"id":"msg-stream-tool","model":"claude-example"}}`,
			`event: content_block_start` + "\n" + `data: {"index":0,"content_block":{"type":"tool_use","id":"toolu_123","name":"lookup","input":{}}}`,
			`event: content_block_delta` + "\n" + `data: {"index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":\"relaykit"}}`,
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

	body := strings.NewReader(`{"model":"claude-example","input":"Search","stream":true}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", body)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	got := rec.Body.String()
	if !strings.Contains(got, "event: response.error") || !strings.Contains(got, "incomplete tool arguments") {
		t.Fatalf("stream did not emit incomplete tool error:\n%s", got)
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

func writeTestProviderConfigWithRouting(t *testing.T, baseURL, apiFormat, model, routing string) string {
	t.Helper()
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "providers.json")
	cfgJSON := `{"providers":[{"id":"test","name":"Test","base_url":"` + baseURL + `","api_format":"` + apiFormat + `","routing":{` + routing + `},"models":[{"id":"` + model + `"}]}]}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
		t.Fatal(err)
	}
	return cfgPath
}
