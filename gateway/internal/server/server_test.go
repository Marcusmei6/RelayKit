package server

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/klauspost/compress/zstd"
)

func testBearerCredential(parts ...string) string {
	return "Bearer " + strings.Join(parts, "-")
}

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
	var body struct {
		ProviderCount        int `json:"provider_count"`
		ConfiguredModelCount int `json:"configured_model_count"`
		OfficialModelCount   int `json:"official_model_count"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode health body err = %v", err)
	}
	if body.ProviderCount != 1 || body.ConfiguredModelCount != 1 || body.OfficialModelCount != 0 {
		t.Fatalf("redacted config counts = %+v", body)
	}
}

func TestChatMessagesAcceptsResponsesFunctionCallOutput(t *testing.T) {
	messages, err := chatMessages(json.RawMessage(`[
		{"type":"function_call_output","call_id":"call_exec","output":"OK"}
	]`))
	if err != nil {
		t.Fatalf("chatMessages err = %v", err)
	}
	if len(messages) != 1 {
		t.Fatalf("messages len = %d, want 1", len(messages))
	}
	if messages[0].Role != "user" {
		t.Fatalf("role = %q, want user", messages[0].Role)
	}
	for _, want := range []string{"call_exec", "OK"} {
		if !strings.Contains(messages[0].Content, want) {
			t.Fatalf("tool result message missing %q: %#v", want, messages[0])
		}
	}
}

func TestAnthropicMixedResponsesHistoryPreservesAssistantOutputText(t *testing.T) {
	input := "[{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"first user\"}]},{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"first assistant\"}]},{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"latest user\"}]}]"
	messages, err := chatMessages(json.RawMessage(input))
	if err != nil {
		t.Fatalf("chatMessages err = %v", err)
	}
	request := upstreamRequest("anthropic_messages", "m", messages, false)
	got := request["messages"].([]chatMessage)
	want := []chatMessage{
		{Role: "user", Content: "first user"},
		{Role: "assistant", Content: "first assistant"},
		{Role: "user", Content: "latest user"},
	}
	if !slices.Equal(got, want) {
		t.Fatalf("messages = %#v, want %#v", got, want)
	}
}

func TestResponsesWebSocketRejectsAdapterCompactionTriggerForModelFallback(t *testing.T) {
	var hits int
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, `{"id":"msg_normal","model":"upstream","content":[{"type":"text","text":"normal response"}],"stop_reason":"end_turn"}`)
	}))
	defer upstream.Close()

	h, err := New(writeTestProviderConfig(t, upstream.URL, "anthropic_messages", "claude-example"))
	if err != nil {
		t.Fatalf("New err = %v", err)
	}
	gateway := httptest.NewServer(h)
	defer gateway.Close()
	conn, reader := openTestWebSocket(t, gateway.URL, "/v1/responses")
	defer conn.Close()
	writeTestWebSocketText(t, conn, `{"model":"claude-example","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"history"}]},{"type":"compaction_trigger"}],"client_metadata":{"x-codex-turn-metadata":"{\"request_kind\":\"compaction\"}"}}`)

	var got strings.Builder
	for i := 0; i < 20; i++ {
		opcode, payload := readTestWebSocketFrame(t, reader)
		if opcode == websocketOpcodeClose {
			break
		}
		if opcode == websocketOpcodeText {
			got.Write(payload)
		}
	}
	if !strings.Contains(got.String(), `"type":"response.failed"`) || !strings.Contains(got.String(), `"type":"invalid_request_error"`) {
		t.Fatalf("adapter compaction response = %s", got.String())
	}
	if hits != 0 {
		t.Fatalf("provider upstream hits = %d, want 0", hits)
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
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/models":
			_, _ = w.Write([]byte(`{"data":[{"id":"healthy-upstream"},{"id":"route-503-upstream"}]}`))
		case r.Method == http.MethodPost && r.URL.Path == "/chat/completions":
			var req struct {
				Model string `json:"model"`
			}
			if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
				t.Fatalf("decode health route probe err = %v", err)
			}
			if req.Model == "route-503-upstream" {
				http.Error(w, "provider warming up", http.StatusServiceUnavailable)
				return
			}
			if req.Model != "healthy-upstream" {
				t.Fatalf("route probe model = %q", req.Model)
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"id":    "chatcmpl-health-probe",
				"model": req.Model,
				"choices": []map[string]any{{
					"message":       map[string]string{"role": "assistant", "content": "reachable"},
					"finish_reason": "stop",
				}},
			})
		default:
			t.Fatalf("unexpected health probe request %s %s", r.Method, r.URL.Path)
		}
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
		`{"id":"healthy","name":"Healthy","base_url":"` + healthyUpstream.URL + `","api_format":"openai_chat","credential_ref":{"kind":"key_file","value":"` + keyPath + `"},"models":[{"id":"public/healthy","upstream_model":"healthy-upstream"},{"id":"public/route-503","upstream_model":"route-503-upstream"}]},` +
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
	var body struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
		ModelHealth struct {
			Hidden []struct {
				ID     string `json:"id"`
				Reason string `json:"reason"`
			} `json:"hidden"`
		} `json:"model_health"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode models body err = %v", err)
	}
	for _, model := range body.Data {
		if model.ID == "public/slow" || model.ID == "public/route-503" {
			t.Fatalf("unhealthy model should be hidden from data: %s", got)
		}
	}
	if !strings.Contains(got, `"probed":true`) || !strings.Contains(got, `"unhealthy":2`) {
		t.Fatalf("redacted health counts missing: %s", got)
	}
	foundSlow := false
	foundRoute503 := false
	for _, model := range body.ModelHealth.Hidden {
		if model.ID == "public/slow" && model.Reason == "upstream non-success (HTTP 504)" {
			foundSlow = true
		}
		if model.ID == "public/route-503" && model.Reason == "upstream non-success (HTTP 503)" {
			foundRoute503 = true
		}
	}
	if !foundSlow || !foundRoute503 {
		t.Fatalf("hidden model reason missing: %s", got)
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

func TestResponsesRoutesOfficialPassthroughAndProviderAuthSeparately(t *testing.T) {
	const officialToken = "official-credential-token"
	const inboundToken = "desktop-request-token"
	const providerToken = "provider-token"
	var officialHits int
	var providerHits int

	officialUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		officialHits++
		if r.URL.Path != "/chat/completions" {
			t.Fatalf("official path = %s", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer "+officialToken {
			t.Fatalf("official Authorization = %q", got)
		}
		if got := r.Header.Get("x-api-key"); got != "" {
			t.Fatalf("official received provider key header %q", got)
		}
		var req struct {
			Model string `json:"model"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("decode official request err = %v", err)
		}
		if req.Model != "gpt-5.5" {
			t.Fatalf("official model = %q", req.Model)
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(map[string]any{
			"id":    "chatcmpl-official",
			"model": req.Model,
			"choices": []map[string]any{{
				"message":       map[string]string{"role": "assistant", "content": "OFFICIAL"},
				"finish_reason": "stop",
			}},
			"usage": map[string]int{"prompt_tokens": 1, "completion_tokens": 1},
		}); err != nil {
			t.Fatalf("encode official response err = %v", err)
		}
	}))
	defer officialUpstream.Close()

	providerUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		providerHits++
		if got := r.Header.Get("x-api-key"); got != providerToken {
			t.Fatalf("provider x-api-key = %q", got)
		}
		if got := r.Header.Get("Authorization"); got != "" {
			t.Fatalf("provider received official auth header %q", got)
		}
		var req struct {
			Model string `json:"model"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("decode provider request err = %v", err)
		}
		if req.Model != "provider-upstream" {
			t.Fatalf("provider model = %q", req.Model)
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(map[string]any{
			"id":    "chatcmpl-provider",
			"model": req.Model,
			"choices": []map[string]any{{
				"message":       map[string]string{"role": "assistant", "content": "PROVIDER"},
				"finish_reason": "stop",
			}},
			"usage": map[string]int{"prompt_tokens": 2, "completion_tokens": 3},
		}); err != nil {
			t.Fatalf("encode provider response err = %v", err)
		}
	}))
	defer providerUpstream.Close()

	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "providers.json")
	cfgJSON := `{
  "official_passthrough": {
    "base_url": "` + officialUpstream.URL + `",
    "credential_ref": {"kind": "env", "value": "RELAYKIT_TEST_OFFICIAL_TOKEN"},
    "models": [{"id": "gpt-5.5", "display_name": "GPT-5.5"}]
  },
  "providers": [{
    "id": "relay",
    "name": "Relay Provider",
    "base_url": "` + providerUpstream.URL + `",
    "api_format": "openai_chat",
    "credential_ref": {"kind": "env", "value": "RELAYKIT_TEST_PROVIDER_TOKEN", "header": "x-api-key"},
    "models": [{"id": "demo/claude-haiku-4-5", "upstream_model": "provider-upstream"}]
  }]
}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("RELAYKIT_TEST_OFFICIAL_TOKEN", officialToken)
	t.Setenv("RELAYKIT_TEST_PROVIDER_TOKEN", providerToken)
	usagePath := filepath.Join(dir, "usage.jsonl")
	h, err := NewWithUsageLog(cfgPath, usagePath)
	if err != nil {
		t.Fatalf("New err = %v", err)
	}

	modelsReq := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	modelsRec := httptest.NewRecorder()
	h.ServeHTTP(modelsRec, modelsReq)
	if modelsRec.Code != http.StatusOK {
		t.Fatalf("models status = %d, body = %s", modelsRec.Code, modelsRec.Body.String())
	}
	for _, want := range []string{"gpt-5.5", "demo/claude-haiku-4-5"} {
		if !strings.Contains(modelsRec.Body.String(), want) {
			t.Fatalf("/v1/models missing %q: %s", want, modelsRec.Body.String())
		}
	}

	officialReq := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(`{"model":"gpt-5.5","input":"reply OK"}`))
	officialReq.Header.Set("Content-Type", "application/json")
	officialReq.Header.Set("Authorization", "Bearer "+inboundToken)
	officialRec := httptest.NewRecorder()
	h.ServeHTTP(officialRec, officialReq)
	if officialRec.Code != http.StatusOK {
		t.Fatalf("official status = %d, body = %s", officialRec.Code, officialRec.Body.String())
	}

	providerReq := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(`{"model":"demo/claude-haiku-4-5","input":"reply OK"}`))
	providerReq.Header.Set("Content-Type", "application/json")
	providerReq.Header.Set("Authorization", "Bearer "+inboundToken)
	providerRec := httptest.NewRecorder()
	h.ServeHTTP(providerRec, providerReq)
	if providerRec.Code != http.StatusOK {
		t.Fatalf("provider status = %d, body = %s", providerRec.Code, providerRec.Body.String())
	}

	unknownReq := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(`{"model":"missing-model","input":"reply OK"}`))
	unknownReq.Header.Set("Content-Type", "application/json")
	unknownRec := httptest.NewRecorder()
	h.ServeHTTP(unknownRec, unknownReq)
	if unknownRec.Code != http.StatusBadRequest || !strings.Contains(unknownRec.Body.String(), "unknown model") {
		t.Fatalf("unknown response = %d %s", unknownRec.Code, unknownRec.Body.String())
	}
	if officialHits != 1 || providerHits != 1 {
		t.Fatalf("hits official=%d provider=%d", officialHits, providerHits)
	}
	for _, path := range []string{cfgPath, usagePath} {
		body, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read %s err = %v", path, err)
		}
		if strings.Contains(string(body), officialToken) {
			t.Fatalf("official token leaked into %s: %s", path, body)
		}
		if strings.Contains(string(body), inboundToken) {
			t.Fatalf("inbound auth leaked into %s: %s", path, body)
		}
	}
}

func TestOfficialPassthroughWithoutCredentialReturnsAuthRequired(t *testing.T) {
	const inboundToken = "desktop-request-token"
	var officialHits int

	officialUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		officialHits++
		t.Fatalf("official upstream must not be called without a RelayKit credential")
	}))
	defer officialUpstream.Close()

	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "providers.json")
	cfgJSON := `{
  "official_passthrough": {
    "base_url": "` + officialUpstream.URL + `",
    "models": [{"id": "gpt-5.5", "display_name": "GPT-5.5"}]
  },
  "providers": []
}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
		t.Fatal(err)
	}
	usagePath := filepath.Join(dir, "usage.jsonl")
	h, err := NewWithUsageLog(cfgPath, usagePath)
	if err != nil {
		t.Fatalf("New err = %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(`{"model":"gpt-5.5","input":"reply OK"}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+inboundToken)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), `"type":"auth_required"`) {
		t.Fatalf("body = %s", rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), inboundToken) || strings.Contains(rec.Body.String(), officialUpstream.URL) {
		t.Fatalf("auth failure leaked sensitive detail: %s", rec.Body.String())
	}
	if officialHits != 0 {
		t.Fatalf("official hits = %d, want 0", officialHits)
	}

	raw, err := os.ReadFile(usagePath)
	if err != nil {
		t.Fatalf("read usage log err = %v", err)
	}
	if strings.Contains(string(raw), inboundToken) || strings.Contains(string(raw), officialUpstream.URL) || strings.Contains(string(raw), "reply OK") {
		t.Fatalf("usage log leaked sensitive detail: %s", raw)
	}
	var event struct {
		ProviderID string `json:"provider_id"`
		Model      string `json:"model"`
		Route      string `json:"route"`
		Transport  string `json:"transport"`
		Status     string `json:"status"`
		HTTPStatus int    `json:"http_status"`
		ErrorType  string `json:"error_type"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(raw), &event); err != nil {
		t.Fatalf("decode usage log err = %v; raw=%s", err, raw)
	}
	if event.ProviderID != "openai" || event.Model != "gpt-5.5" || event.Route != "/v1/responses" || event.Transport != "responses_http" || event.Status != "failed" || event.HTTPStatus != http.StatusUnauthorized || event.ErrorType != "auth_required" {
		t.Fatalf("event = %+v", event)
	}
}

func TestResponsesWebSocketRoutesProviderRequest(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Model    string `json:"model"`
			Messages []struct {
				Role    string `json:"role"`
				Content string `json:"content"`
			} `json:"messages"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("decode upstream request err = %v", err)
		}
		if req.Model != "upstream-coder" || len(req.Messages) != 1 || req.Messages[0].Content != "reply OK" {
			t.Fatalf("upstream request = %+v", req)
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(map[string]any{
			"id":    "chatcmpl-ws",
			"model": req.Model,
			"choices": []map[string]any{{
				"message":       map[string]string{"role": "assistant", "content": "OK"},
				"finish_reason": "stop",
			}},
			"usage": map[string]int{"prompt_tokens": 2, "completion_tokens": 1},
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
	usagePath := filepath.Join(dir, "usage.jsonl")
	h, err := NewWithUsageLog(cfgPath, usagePath)
	if err != nil {
		t.Fatalf("New err = %v", err)
	}
	srv := httptest.NewServer(h)
	defer srv.Close()

	conn, reader := openTestWebSocket(t, srv.URL, "/v1/responses")
	defer conn.Close()
	writeTestWebSocketText(t, conn, `{"model":"public/coder","input":"reply OK"}`)
	got := readTestWebSocketUntil(t, reader, "response.completed")
	for _, want := range []string{
		`"type":"response.created"`,
		`"model":"public/coder"`,
		`"type":"response.output_item.added"`,
		`"type":"response.content_part.added"`,
		`"type":"response.output_text.delta"`,
		`"delta":"OK"`,
		`"type":"response.content_part.done"`,
		`"type":"response.output_item.done"`,
		`"type":"response.completed"`,
		`"output_text":"OK"`,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("websocket response missing %q in %s", want, got)
		}
	}
	if strings.Index(got, `"type":"response.output_item.added"`) > strings.Index(got, `"type":"response.output_text.delta"`) {
		t.Fatalf("websocket output item must be added before text delta: %s", got)
	}
	writeTestWebSocketClose(t, conn)

	raw, err := os.ReadFile(usagePath)
	if err != nil {
		t.Fatalf("read usage log err = %v", err)
	}
	if strings.Contains(string(raw), "reply OK") || strings.Contains(string(raw), upstream.URL) {
		t.Fatalf("usage log leaked request content or URL: %s", raw)
	}
	var event struct {
		ProviderID string `json:"provider_id"`
		Model      string `json:"model"`
		Route      string `json:"route"`
		Transport  string `json:"transport"`
		Status     string `json:"status"`
		HTTPStatus int    `json:"http_status"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(raw), &event); err != nil {
		t.Fatalf("decode usage log err = %v; raw=%s", err, raw)
	}
	if event.ProviderID != "test" || event.Model != "public/coder" || event.Route != "/v1/responses" || event.Transport != "responses_websocket" || event.Status != "completed" || event.HTTPStatus != http.StatusOK {
		t.Fatalf("event = %+v", event)
	}
}

func TestResponsesWebSocketEmitsAnthropicXMLToolCallItem(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Model string `json:"model"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("decode upstream request err = %v", err)
		}
		if req.Model != "upstream-claude" {
			t.Fatalf("upstream model = %q", req.Model)
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(map[string]any{
			"id":          "msg-ws-xml-tool",
			"model":       req.Model,
			"stop_reason": "tool_use",
			"content": []map[string]string{{
				"type": "text",
				"text": `<function_calls><invoke name="exec_command"><parameter name="command">pwd</parameter></invoke></function_calls>`,
			}},
		}); err != nil {
			t.Fatalf("encode upstream response err = %v", err)
		}
	}))
	defer upstream.Close()

	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "providers.json")
	cfgJSON := `{"providers":[{"id":"test","name":"Test","base_url":"` + upstream.URL + `","api_format":"anthropic_messages","models":[{"id":"demo/claude-haiku-4-5","upstream_model":"upstream-claude"}]}]}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
		t.Fatal(err)
	}
	h, err := New(cfgPath)
	if err != nil {
		t.Fatalf("New err = %v", err)
	}
	srv := httptest.NewServer(h)
	defer srv.Close()

	conn, reader := openTestWebSocket(t, srv.URL, "/v1/responses")
	defer conn.Close()
	writeTestWebSocketText(t, conn, `{"model":"demo/claude-haiku-4-5","input":"Use shell"}`)
	got := readTestWebSocketUntil(t, reader, "response.completed")
	for _, want := range []string{
		`"type":"function_call"`,
		`"id":"call_`,
		`"name":"exec_command"`,
		`"arguments":"{\"cmd\":\"pwd\"}"`,
		`"model":"demo/claude-haiku-4-5"`,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("websocket response missing %q in %s", want, got)
		}
	}
	for _, forbidden := range []string{"<function_calls>", "<invoke", "<parameter", "upstream-claude"} {
		if strings.Contains(got, forbidden) {
			t.Fatalf("websocket response leaked %q in %s", forbidden, got)
		}
	}
	writeTestWebSocketClose(t, conn)
}

func TestResponsesWebSocketRoutesOfficialAndProviderAuthSeparately(t *testing.T) {
	const officialToken = "official-credential-token"
	const inboundToken = "desktop-request-token"
	const providerToken = "provider-token"
	var officialHits int
	var providerHits int

	officialUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		officialHits++
		if got := r.Header.Get("Authorization"); got != "Bearer "+officialToken {
			t.Fatalf("official Authorization = %q", got)
		}
		if got := r.Header.Get("x-api-key"); got != "" {
			t.Fatalf("official received provider key header %q", got)
		}
		var req struct {
			Model string `json:"model"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("decode official request err = %v", err)
		}
		if req.Model != "gpt-5.5" {
			t.Fatalf("official model = %q", req.Model)
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(map[string]any{
			"id":    "chatcmpl-official-ws",
			"model": req.Model,
			"choices": []map[string]any{{
				"message":       map[string]string{"role": "assistant", "content": "OFFICIAL"},
				"finish_reason": "stop",
			}},
			"usage": map[string]int{"prompt_tokens": 1, "completion_tokens": 1},
		}); err != nil {
			t.Fatalf("encode official response err = %v", err)
		}
	}))
	defer officialUpstream.Close()

	providerUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		providerHits++
		if got := r.Header.Get("x-api-key"); got != providerToken {
			t.Fatalf("provider x-api-key = %q", got)
		}
		if got := r.Header.Get("Authorization"); got != "" {
			t.Fatalf("provider received official auth header %q", got)
		}
		var req struct {
			Model string `json:"model"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("decode provider request err = %v", err)
		}
		if req.Model != "provider-upstream" {
			t.Fatalf("provider model = %q", req.Model)
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(map[string]any{
			"id":    "chatcmpl-provider-ws",
			"model": req.Model,
			"choices": []map[string]any{{
				"message":       map[string]string{"role": "assistant", "content": "PROVIDER"},
				"finish_reason": "stop",
			}},
			"usage": map[string]int{"prompt_tokens": 2, "completion_tokens": 3},
		}); err != nil {
			t.Fatalf("encode provider response err = %v", err)
		}
	}))
	defer providerUpstream.Close()

	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "providers.json")
	cfgJSON := `{
  "official_passthrough": {
    "base_url": "` + officialUpstream.URL + `",
    "credential_ref": {"kind": "env", "value": "RELAYKIT_TEST_OFFICIAL_TOKEN"},
    "models": [{"id": "gpt-5.5", "display_name": "GPT-5.5"}]
  },
  "providers": [{
    "id": "demo",
    "name": "Demo",
    "base_url": "` + providerUpstream.URL + `",
    "api_format": "openai_chat",
    "credential_ref": {"kind": "env", "value": "RELAYKIT_TEST_PROVIDER_TOKEN", "header": "x-api-key"},
    "models": [{"id": "demo/claude-haiku-4-5", "upstream_model": "provider-upstream"}]
  }]
}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("RELAYKIT_TEST_OFFICIAL_TOKEN", officialToken)
	t.Setenv("RELAYKIT_TEST_PROVIDER_TOKEN", providerToken)
	usagePath := filepath.Join(dir, "usage.jsonl")
	h, err := NewWithUsageLog(cfgPath, usagePath)
	if err != nil {
		t.Fatalf("New err = %v", err)
	}
	srv := httptest.NewServer(h)
	defer srv.Close()

	officialConn, officialReader := openTestWebSocketWithHeaders(t, srv.URL, "/v1/responses", map[string]string{
		"Authorization": "Bearer " + inboundToken,
	})
	defer officialConn.Close()
	writeTestWebSocketText(t, officialConn, `{"model":"gpt-5.5","input":"reply OK"}`)
	officialGot := readTestWebSocketUntil(t, officialReader, "response.completed")
	if !strings.Contains(officialGot, `"model":"gpt-5.5"`) || !strings.Contains(officialGot, `"output_text":"OFFICIAL"`) {
		t.Fatalf("official websocket response = %s", officialGot)
	}

	providerConn, providerReader := openTestWebSocketWithHeaders(t, srv.URL, "/v1/responses", map[string]string{
		"Authorization": "Bearer " + inboundToken,
	})
	defer providerConn.Close()
	writeTestWebSocketText(t, providerConn, `{"model":"demo/claude-haiku-4-5","input":"reply OK"}`)
	providerGot := readTestWebSocketUntil(t, providerReader, "response.completed")
	if !strings.Contains(providerGot, `"model":"demo/claude-haiku-4-5"`) || !strings.Contains(providerGot, `"output_text":"PROVIDER"`) {
		t.Fatalf("provider websocket response = %s", providerGot)
	}

	if officialHits != 1 || providerHits != 1 {
		t.Fatalf("hits official=%d provider=%d", officialHits, providerHits)
	}
	raw, err := os.ReadFile(usagePath)
	if err != nil {
		t.Fatalf("read usage log err = %v", err)
	}
	if strings.Contains(string(raw), officialToken) || strings.Contains(string(raw), providerToken) || strings.Contains(string(raw), inboundToken) {
		t.Fatalf("usage log leaked auth material: %s", raw)
	}
	for _, want := range []string{
		`"provider_id":"openai"`,
		`"model":"gpt-5.5"`,
		`"provider_id":"demo"`,
		`"model":"demo/claude-haiku-4-5"`,
		`"transport":"responses_websocket"`,
	} {
		if !strings.Contains(string(raw), want) {
			t.Fatalf("usage log missing %q in %s", want, raw)
		}
	}
}

func TestResponsesWebSocketOfficialFailureIsTerminalAndSanitized(t *testing.T) {
	const inboundToken = "desktop-request-token"
	var officialHits int
	officialUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		officialHits++
		t.Fatalf("official upstream must not be called without a RelayKit credential")
	}))
	defer officialUpstream.Close()

	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "providers.json")
	cfgJSON := `{
  "official_passthrough": {
    "base_url": "` + officialUpstream.URL + `",
    "models": [{"id": "gpt-5.5", "display_name": "GPT-5.5"}]
  },
  "providers": []
}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
		t.Fatal(err)
	}
	usagePath := filepath.Join(dir, "usage.jsonl")
	h, err := NewWithUsageLog(cfgPath, usagePath)
	if err != nil {
		t.Fatalf("New err = %v", err)
	}
	srv := httptest.NewServer(h)
	defer srv.Close()

	conn, reader := openTestWebSocketWithHeaders(t, srv.URL, "/v1/responses", map[string]string{
		"Authorization": "Bearer " + inboundToken,
	})
	defer conn.Close()
	writeTestWebSocketText(t, conn, `{"model":"gpt-5.5","input":"reply OK"}`)
	got := readTestWebSocketUntil(t, reader, "response.failed")
	for _, want := range []string{
		`"type":"response.failed"`,
		`"model":"gpt-5.5"`,
		`"type":"auth_required"`,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("websocket failure missing %q in %s", want, got)
		}
	}
	if strings.Contains(got, inboundToken) || strings.Contains(got, officialUpstream.URL) || strings.Contains(got, "<html>") {
		t.Fatalf("websocket failure leaked sensitive upstream detail: %s", got)
	}
	if officialHits != 0 {
		t.Fatalf("official hits = %d, want 0", officialHits)
	}

	raw, err := os.ReadFile(usagePath)
	if err != nil {
		t.Fatalf("read usage log err = %v", err)
	}
	if strings.Contains(string(raw), inboundToken) || strings.Contains(string(raw), officialUpstream.URL) || strings.Contains(string(raw), "<html>") {
		t.Fatalf("usage log leaked sensitive upstream detail: %s", raw)
	}
	var event struct {
		ProviderID string `json:"provider_id"`
		Model      string `json:"model"`
		Route      string `json:"route"`
		Transport  string `json:"transport"`
		Status     string `json:"status"`
		HTTPStatus int    `json:"http_status"`
		ErrorType  string `json:"error_type"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(raw), &event); err != nil {
		t.Fatalf("decode usage log err = %v; raw=%s", err, raw)
	}
	if event.ProviderID != "openai" || event.Model != "gpt-5.5" || event.Route != "/v1/responses" || event.Transport != "responses_websocket" || event.Status != "failed" || event.HTTPStatus != http.StatusUnauthorized || event.ErrorType != "auth_required" {
		t.Fatalf("event = %+v", event)
	}
}

func TestResponsesGetWithoutWebSocketUpgradeReturnsClearError(t *testing.T) {
	h, err := New(filepath.Join("..", "..", "..", "examples", "providers.example.json"))
	if err != nil {
		t.Fatalf("New err = %v", err)
	}
	req := httptest.NewRequest(http.MethodGet, "/v1/responses", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusUpgradeRequired {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "websocket upgrade required") {
		t.Fatalf("body = %s", rec.Body.String())
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
	req.Header.Set("Authorization", testBearerCredential("request", "header", "secret"))
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

func TestCredentialRefKeychainSetsAuthorizationHeader(t *testing.T) {
	oldLookup := lookupKeychainCredential
	lookupKeychainCredential = func(name string) (string, error) {
		if name != "relaykit.test.provider-token" {
			t.Fatalf("keychain item = %q", name)
		}
		return "keychain-token", nil
	}
	defer func() { lookupKeychainCredential = oldLookup }()

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "Bearer keychain-token" {
			t.Fatalf("Authorization = %q", got)
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(map[string]any{
			"id":    "chatcmpl-keychain",
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
	cfgJSON := `{"providers":[{"id":"test","name":"Test","base_url":"` + upstream.URL + `","api_format":"openai_chat","credential_ref":{"kind":"keychain","value":"relaykit.test.provider-token"},"models":[{"id":"qwen3-coder"}]}]}`
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

func TestAppCredentialHandoffAvoidsSecurityLookup(t *testing.T) {
	oldLookup := lookupKeychainCredential
	lookupKeychainCredential = func(name string) (string, error) {
		t.Fatalf("security lookup must not run for App-injected credential %q", name)
		return "", fmt.Errorf("unexpected security lookup")
	}
	defer func() { lookupKeychainCredential = oldLookup }()

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "Bearer memory-token" {
			t.Fatalf("Authorization = %q", got)
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"id":"chatcmpl-memory","model":"qwen3-coder","choices":[{"message":{"role":"assistant","content":"OK"},"finish_reason":"stop"}]}`)
	}))
	defer upstream.Close()

	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "providers.json")
	cfgJSON := `{"providers":[{"id":"test","name":"Test","base_url":"` + upstream.URL + `","api_format":"openai_chat","credential_ref":{"kind":"keychain","value":"relaykit.test.provider-token"},"models":[{"id":"qwen3-coder"}]}]}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
		t.Fatal(err)
	}

	h, err := NewWithUsageLogAndCredentials(cfgPath, "", map[string]string{
		"relaykit.test.provider-token": "memory-token",
	})
	if err != nil {
		t.Fatalf("NewWithUsageLogAndCredentials err = %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(`{"model":"qwen3-coder","input":"reply OK"}`))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
}

func TestAppCredentialHandoffFailsClosedWithoutInjectedCredential(t *testing.T) {
	oldLookup := lookupKeychainCredential
	securityLookupCalled := false
	lookupKeychainCredential = func(name string) (string, error) {
		securityLookupCalled = true
		return "unexpected-token", nil
	}
	defer func() { lookupKeychainCredential = oldLookup }()

	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "providers.json")
	cfgJSON := `{"providers":[{"id":"test","name":"Test","base_url":"http://127.0.0.1:9/v1","api_format":"openai_chat","credential_ref":{"kind":"keychain","value":"relaykit.test.missing"},"models":[{"id":"qwen3-coder"}]}]}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
		t.Fatal(err)
	}

	h, err := NewWithUsageLogAndCredentials(cfgPath, "", map[string]string{})
	if err != nil {
		t.Fatalf("NewWithUsageLogAndCredentials err = %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(`{"model":"qwen3-coder","input":"reply OK"}`))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadGateway || !strings.Contains(rec.Body.String(), "credential unavailable from RelayKit App") {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	if securityLookupCalled {
		t.Fatal("App credential mode must fail closed without invoking /usr/bin/security")
	}
}

func TestLookupKeychainCredentialPrefersRelayKitAccountAndFallsBackToServiceOnly(t *testing.T) {
	oldRun := runSecurityFindGenericPassword
	defer func() { runSecurityFindGenericPassword = oldRun }()

	var calls [][]string
	runSecurityFindGenericPassword = func(args ...string) ([]byte, error) {
		calls = append(calls, append([]string(nil), args...))
		if slices.Contains(args, "-a") {
			return nil, fmt.Errorf("not found")
		}
		return []byte("legacy-token\n"), nil
	}

	token, err := lookupKeychainCredential("relaykit.provider.example")
	if err != nil {
		t.Fatalf("lookup err = %v", err)
	}
	if token != "legacy-token" {
		t.Fatalf("token = %q", token)
	}
	if len(calls) != 2 {
		t.Fatalf("calls = %#v", calls)
	}
	if !slices.Contains(calls[0], "-a") || !slices.Contains(calls[0], "RelayKit") {
		t.Fatalf("first lookup must include RelayKit account: %#v", calls[0])
	}
	if slices.Contains(calls[1], "-a") {
		t.Fatalf("fallback lookup must be service-only: %#v", calls[1])
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
	if req["system"] != "system\n\ndeveloper" || len(messages) != 1 || messages[0].Role != "assistant" {
		t.Fatalf("messages = %+v", messages)
	}
}

func TestAnthropicRequestSeparatesCodexDeveloperContextAndPreservesLatestUserInstruction(t *testing.T) {
	req := upstreamRequest("anthropic_messages", "m", []chatMessage{
		{Role: "developer", Content: "Project rules and repository context."},
		{Role: "user", Content: "Workspace context for RelayKit."},
		{Role: "user", Content: "Render the requested Markdown and end with RELAYKIT_FORMAT_OK."},
	}, false)

	system, ok := req["system"].(string)
	if !ok || system != "Project rules and repository context." {
		t.Fatalf("system = %#v", req["system"])
	}
	messages, ok := req["messages"].([]chatMessage)
	if !ok || len(messages) != 1 {
		t.Fatalf("messages = %#v", req["messages"])
	}
	if messages[0].Role != "user" {
		t.Fatalf("role = %q, want user", messages[0].Role)
	}
	workspaceIndex := strings.Index(messages[0].Content, "Workspace context for RelayKit.")
	latestIndex := strings.Index(messages[0].Content, "RELAYKIT_FORMAT_OK")
	if workspaceIndex < 0 || latestIndex <= workspaceIndex {
		t.Fatalf("latest user instruction was not preserved last: %q", messages[0].Content)
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
		"event: response.output_text.done",
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

func TestResponsesAnthropicBaseWithAPISuffixUsesV1Messages(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/messages" {
			t.Fatalf("upstream path = %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(map[string]any{
			"id":          "msg-api-base",
			"model":       "claude-example",
			"stop_reason": "end_turn",
			"content":     []map[string]string{{"type": "text", "text": "hi"}},
		}); err != nil {
			t.Fatalf("encode upstream response err = %v", err)
		}
	}))
	defer upstream.Close()

	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "providers.json")
	cfgJSON := `{"providers":[{"id":"test","name":"Test","base_url":"` + upstream.URL + `/api","api_format":"anthropic_messages","models":[{"id":"claude-example"}]}]}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
		t.Fatal(err)
	}
	h, err := New(cfgPath)
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

func TestResponsesForwardsFunctionToolsToAnthropic(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/messages" {
			t.Fatalf("upstream path = %s", r.URL.Path)
		}
		var req struct {
			Tools []struct {
				Name        string         `json:"name"`
				Description string         `json:"description"`
				InputSchema map[string]any `json:"input_schema"`
			} `json:"tools"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("decode upstream request err = %v", err)
		}
		if len(req.Tools) != 1 {
			t.Fatalf("upstream tools = %+v", req.Tools)
		}
		tool := req.Tools[0]
		if tool.Name != "exec_command" || tool.Description != "Run a shell command" {
			t.Fatalf("upstream tool identity = %+v", tool)
		}
		if tool.InputSchema["type"] != "object" {
			t.Fatalf("upstream tool input_schema = %+v", tool.InputSchema)
		}
		properties, ok := tool.InputSchema["properties"].(map[string]any)
		if !ok || properties["cmd"] == nil {
			t.Fatalf("upstream tool properties = %+v", tool.InputSchema)
		}

		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(map[string]any{
			"id":          "msg-tool-definition",
			"model":       "claude-example",
			"stop_reason": "end_turn",
			"content":     []map[string]string{{"type": "text", "text": "ready"}},
		}); err != nil {
			t.Fatalf("encode upstream response err = %v", err)
		}
	}))
	defer upstream.Close()

	h, err := New(writeTestProviderConfig(t, upstream.URL, "anthropic_messages", "claude-example"))
	if err != nil {
		t.Fatalf("New err = %v", err)
	}
	body := strings.NewReader(`{
		"model":"claude-example",
		"input":"Run a command",
		"tools":[
			{"type":"function","name":"exec_command","description":"Run a shell command","parameters":{"type":"object","properties":{"cmd":{"type":"string"}},"required":["cmd"]}},
			{"type":"web_search_preview","name":"web_search"}
		]
	}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", body)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
}

func TestResponsesMapsAnthropicExecCommandToolUseToCmd(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/messages" {
			t.Fatalf("upstream path = %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(map[string]any{
			"id":          "msg-exec-tool",
			"model":       "claude-example",
			"stop_reason": "tool_use",
			"content": []map[string]any{{
				"type":  "tool_use",
				"id":    "toolu_exec",
				"name":  "exec_command",
				"input": map[string]any{"command": "pwd"},
			}},
		}); err != nil {
			t.Fatalf("encode upstream response err = %v", err)
		}
	}))
	defer upstream.Close()

	h, err := New(writeTestProviderConfig(t, upstream.URL, "anthropic_messages", "claude-example"))
	if err != nil {
		t.Fatalf("New err = %v", err)
	}

	body := strings.NewReader(`{"model":"claude-example","input":"Run pwd"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", body)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), `"arguments":"{\"cmd\":\"pwd\"}"`) {
		t.Fatalf("exec_command tool_use did not map command to cmd: %s", rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), `\"command\"`) {
		t.Fatalf("exec_command tool_use leaked command argument: %s", rec.Body.String())
	}
}

func TestResponsesMapsAnthropicShellToolUseToExecCommand(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/messages" {
			t.Fatalf("upstream path = %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(map[string]any{
			"id":          "msg-shell-tool",
			"model":       "claude-example",
			"stop_reason": "tool_use",
			"content": []map[string]any{{
				"type":  "tool_use",
				"id":    "toolu_shell",
				"name":  "bash",
				"input": map[string]any{"command": "pwd"},
			}},
		}); err != nil {
			t.Fatalf("encode upstream response err = %v", err)
		}
	}))
	defer upstream.Close()

	h, err := New(writeTestProviderConfig(t, upstream.URL, "anthropic_messages", "claude-example"))
	if err != nil {
		t.Fatalf("New err = %v", err)
	}

	body := strings.NewReader(`{"model":"claude-example","input":"Run pwd"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", body)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	for _, want := range []string{`"name":"exec_command"`, `"arguments":"{\"cmd\":\"pwd\"}"`} {
		if !strings.Contains(rec.Body.String(), want) {
			t.Fatalf("shell tool_use missing %q: %s", want, rec.Body.String())
		}
	}
	for _, forbidden := range []string{`"name":"bash"`, `\"command\"`} {
		if strings.Contains(rec.Body.String(), forbidden) {
			t.Fatalf("shell tool_use leaked %q: %s", forbidden, rec.Body.String())
		}
	}
}

func TestResponsesMapsAnthropicClaudeCodeXMLToolCall(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/messages" {
			t.Fatalf("upstream path = %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(map[string]any{
			"id":          "msg-xml-tool",
			"model":       "claude-example",
			"stop_reason": "tool_use",
			"content": []map[string]string{{
				"type": "text",
				"text": `<function_calls><invoke name="exec_command"><parameter name="command">curl -I https://www.google.com</parameter></invoke></function_calls>`,
			}},
		}); err != nil {
			t.Fatalf("encode upstream response err = %v", err)
		}
	}))
	defer upstream.Close()

	h, err := New(writeTestProviderConfig(t, upstream.URL, "anthropic_messages", "claude-example"))
	if err != nil {
		t.Fatalf("New err = %v", err)
	}

	body := strings.NewReader(`{"model":"claude-example","input":"Use shell"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", body)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	gotBody := rec.Body.String()
	forbidden := []string{"<function_calls>", "<invoke", "<parameter"}
	for _, value := range forbidden {
		if strings.Contains(gotBody, value) {
			t.Fatalf("raw Claude XML leaked %q in body: %s", value, gotBody)
		}
	}
	var got struct {
		OutputText string `json:"output_text"`
		Output     []struct {
			Type      string `json:"type"`
			CallID    string `json:"call_id"`
			Name      string `json:"name"`
			Arguments string `json:"arguments"`
		} `json:"output"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode response err = %v; body=%s", err, rec.Body.String())
	}
	if got.OutputText != "" {
		t.Fatalf("output_text must not contain XML fallback text: %q", got.OutputText)
	}
	if len(got.Output) != 1 || got.Output[0].Type != "function_call" || got.Output[0].Name != "exec_command" {
		t.Fatalf("output = %+v", got.Output)
	}
	if !strings.Contains(got.Output[0].Arguments, `"cmd"`) || strings.Contains(got.Output[0].Arguments, `"command"`) || !strings.Contains(got.Output[0].Arguments, "curl -I https://www.google.com") {
		t.Fatalf("arguments = %s", got.Output[0].Arguments)
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
		"event: response.function_call_arguments.delta",
		"event: response.function_call_arguments.done",
		"event: response.output_item.done",
		`"type":"function_call"`,
		`"call_id":"toolu_123"`,
		`"name":"lookup"`,
		`"delta":"{\"query\":\"needle-tool-argument-9381\"}"`,
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
	if strings.Index(got, "event: response.function_call_arguments.delta") > strings.Index(got, "event: response.function_call_arguments.done") {
		t.Fatalf("function arguments delta emitted after done:\n%s", got)
	}
	if strings.Contains(got, `{}{\"query\"`) {
		t.Fatalf("function arguments contained concatenated empty object: %s", got)
	}
	usage, err := os.ReadFile(usageLog)
	if err != nil {
		t.Fatalf("read usage log err = %v", err)
	}
	if strings.Contains(string(usage), "needle-tool-argument-9381") {
		t.Fatalf("usage log contains tool arguments: %s", usage)
	}
}

func TestResponsesStreamsAnthropicClaudeCodeXMLToolCall(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		chunks := []string{
			`event: message_start` + "\n" + `data: {"message":{"id":"msg-stream-xml-tool","model":"claude-example"}}`,
			`event: content_block_start` + "\n" + `data: {"index":0,"content_block":{"type":"text","text":""}}`,
			`event: content_block_delta` + "\n" + `data: {"index":0,"delta":{"type":"text_delta","text":"<function_calls><invoke name=\"exec_command\"><parameter name=\"command\">pwd</parameter></invoke></function_calls>"}}`,
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

	h, err := New(writeTestProviderConfig(t, upstream.URL, "anthropic_messages", "claude-example"))
	if err != nil {
		t.Fatalf("New err = %v", err)
	}

	body := strings.NewReader(`{"model":"claude-example","input":"Use shell","stream":true}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", body)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	got := rec.Body.String()
	for _, want := range []string{
		`"type":"function_call"`,
		`"name":"exec_command"`,
		"event: response.function_call_arguments.delta",
		"event: response.function_call_arguments.done",
		`"arguments":"{\"cmd\":\"pwd\"}"`,
		`"finish_reason":"tool_use"`,
		`"status":"completed"`,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("stream missing %q in:\n%s", want, got)
		}
	}
	for _, forbidden := range []string{"<function_calls>", "<invoke", "<parameter"} {
		if strings.Contains(got, forbidden) {
			t.Fatalf("stream leaked %q in:\n%s", forbidden, got)
		}
	}
}

func TestResponsesStreamsAnthropicOpusXMLToolCallUsesGenericAnthropicAdapter(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Model string `json:"model"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("decode upstream err = %v", err)
		}
		if req.Model != "claude-opus-4-1-20260701" {
			t.Fatalf("upstream model = %q", req.Model)
		}
		w.Header().Set("Content-Type", "text/event-stream")
		chunks := []string{
			`event: message_start` + "\n" + `data: {"message":{"id":"msg-opus-tool","model":"claude-opus-4-1-20260701"}}`,
			`event: content_block_start` + "\n" + `data: {"index":0,"content_block":{"type":"text","text":""}}`,
			`event: content_block_delta` + "\n" + `data: {"index":0,"delta":{"type":"text_delta","text":"<function_calls><invoke name=\"exec_command\"><parameter name=\"command\">echo opus</parameter></invoke></function_calls>"}}`,
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

	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "providers.json")
	cfgJSON := `{"providers":[{"id":"demo","name":"Demo","base_url":"` + upstream.URL + `","api_format":"anthropic_messages","models":[{"id":"demo/claude-opus-4-1","upstream_model":"claude-opus-4-1-20260701"}]}]}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
		t.Fatal(err)
	}
	h, err := New(cfgPath)
	if err != nil {
		t.Fatalf("New err = %v", err)
	}

	body := strings.NewReader(`{"model":"demo/claude-opus-4-1","input":"Use shell","stream":true}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", body)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	got := rec.Body.String()
	for _, want := range []string{
		`"model":"demo/claude-opus-4-1"`,
		"event: response.output_item.added",
		"event: response.function_call_arguments.delta",
		"event: response.function_call_arguments.done",
		"event: response.output_item.done",
		`"name":"exec_command"`,
		`"arguments":"{\"cmd\":\"echo opus\"}"`,
		"event: response.completed",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("opus stream missing %q in:\n%s", want, got)
		}
	}
	for _, forbidden := range []string{"<function_calls>", "<invoke", "<parameter", "claude-opus-4-1-20260701"} {
		if strings.Contains(got, forbidden) {
			t.Fatalf("opus stream leaked %q in:\n%s", forbidden, got)
		}
	}
}

func TestResponsesStreamsFragmentedClaudeXMLToolCallsWithoutLeaks(t *testing.T) {
	const probe = "set -eux\nprintf 'RELAYKIT_TOOL_PROOF\\n'\npwd\nwhoami\ncurl -I https://www.google.com 2>&1 | head -20\nping -c 1 www.google.com 2>&1 | head -20"
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		delta := func(text string) string {
			data, err := json.Marshal(map[string]any{
				"index": 0,
				"delta": map[string]string{"type": "text_delta", "text": text},
			})
			if err != nil {
				t.Fatalf("marshal delta err = %v", err)
			}
			return "event: content_block_delta\n" + "data: " + string(data)
		}
		chunks := []string{
			`event: message_start` + "\n" + `data: {"message":{"id":"msg-stream-fragmented-xml","model":"claude-example"}}`,
			`event: content_block_start` + "\n" + `data: {"index":0,"content_block":{"type":"text","text":""}}`,
			delta("Before summary. "),
			delta(`<function_calls><invoke name="exec_command"><parameter name="command">` + probe[:35]),
			delta(probe[35:] + `</parameter></invoke><invoke name="exec_command"><parameter name="command">pwd</parameter></invoke></function_calls>`),
			delta(" After summary."),
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

	h, err := New(writeTestProviderConfig(t, upstream.URL, "anthropic_messages", "claude-example"))
	if err != nil {
		t.Fatalf("New err = %v", err)
	}

	body := strings.NewReader(`{"model":"claude-example","input":"Use a real shell probe","stream":true}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", body)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	got := rec.Body.String()
	for _, want := range []string{
		`"delta":"Before summary. "`,
		`"delta":" After summary."`,
		"event: response.function_call_arguments.delta",
		"event: response.function_call_arguments.done",
		`"name":"exec_command"`,
		`\"cmd\"`,
		"RELAYKIT_TOOL_PROOF",
		"curl -I https://www.google.com",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("fragmented XML stream missing %q in:\n%s", want, got)
		}
	}
	if strings.Count(got, "event: response.function_call_arguments.done") != 2 {
		t.Fatalf("want two function calls, got stream:\n%s", got)
	}
	addedIndexes := []int{}
	doneIndexes := []int{}
	scanner := bufio.NewScanner(strings.NewReader(got))
	for scanner.Scan() {
		line := strings.TrimPrefix(scanner.Text(), "data: ")
		if line == scanner.Text() {
			continue
		}
		var event struct {
			Type        string `json:"type"`
			OutputIndex int    `json:"output_index"`
			Item        struct {
				Type string `json:"type"`
			} `json:"item"`
		}
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			continue
		}
		if event.Type == "response.output_item.added" && event.Item.Type == "function_call" {
			addedIndexes = append(addedIndexes, event.OutputIndex)
		}
		if event.Type == "response.function_call_arguments.done" {
			doneIndexes = append(doneIndexes, event.OutputIndex)
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatalf("scan response stream err = %v", err)
	}
	if !slices.Equal(addedIndexes, []int{1, 2}) {
		t.Fatalf("function_call output_item.added indexes = %v, want [1 2]\n%s", addedIndexes, got)
	}
	if !slices.Equal(doneIndexes, []int{1, 2}) {
		t.Fatalf("function_call argument done indexes = %v, want [1 2]\n%s", doneIndexes, got)
	}
	for _, forbidden := range []string{"<function_calls", "<invoke", "<parameter", `\"command\"`, "printf OK", "reply OK"} {
		if strings.Contains(got, forbidden) {
			t.Fatalf("fragmented XML stream leaked %q in:\n%s", forbidden, got)
		}
	}
}

func TestSplitClaudeXMLToolCallsPreservesTextAndMultipleInvokes(t *testing.T) {
	const probe = "set -eux\nprintf 'RELAYKIT_TOOL_PROOF\\n'\npwd\nwhoami\ncurl -I https://www.google.com 2>&1 | head -20\nping -c 1 www.google.com 2>&1 | head -20"
	text := `Prefix. <function_calls><invoke name="exec_command"><parameter name="command">` + probe + `</parameter></invoke><invoke name="exec_command"><parameter name="command">pwd</parameter></invoke></function_calls> Suffix.`

	clean, calls, pending := splitClaudeXMLToolCallsFromText(text)

	if clean != "Prefix.  Suffix." {
		t.Fatalf("clean text = %q", clean)
	}
	if pending != "" {
		t.Fatalf("pending XML = %q", pending)
	}
	if len(calls) != 2 {
		t.Fatalf("calls = %+v", calls)
	}
	var firstArgs map[string]string
	if err := json.Unmarshal([]byte(calls[0].Arguments), &firstArgs); err != nil {
		t.Fatalf("first call arguments are not JSON: %s", calls[0].Arguments)
	}
	if calls[0].Name != "exec_command" || firstArgs["cmd"] == "" || firstArgs["command"] != "" {
		t.Fatalf("first call did not map command to cmd: %+v", calls[0])
	}
	if !strings.Contains(firstArgs["cmd"], "RELAYKIT_TOOL_PROOF") || strings.Contains(firstArgs["cmd"], "printf OK") || strings.Contains(firstArgs["cmd"], "reply OK") {
		t.Fatalf("first call arguments are not the real shell probe: %+v", calls[0])
	}
	if calls[1].Arguments != `{"cmd":"pwd"}` {
		t.Fatalf("second call arguments = %s", calls[1].Arguments)
	}
	for _, forbidden := range []string{"<function_calls", "<invoke", "<parameter"} {
		if strings.Contains(clean, forbidden) {
			t.Fatalf("clean text leaked %q: %s", forbidden, clean)
		}
	}
}

func TestSplitClaudeToolCallsHandlesBareInvokeAndToolCallJSON(t *testing.T) {
	const probe = "set -eux\nprintf 'RELAYKIT_TOOL_PROOF\\n'\npwd\nwhoami\ncurl -I https://www.google.com 2>&1 | head -20\nping -c 1 www.google.com 2>&1 | head -20"
	text := `A <invoke name="bash"><parameter name="command">` + probe + `</parameter></invoke> B <tool_call>{"name":"shell","arguments":{"command":"pwd"}}</tool_call> C`

	clean, calls, pending := splitClaudeXMLToolCallsFromText(text)

	if clean != "A  B  C" || pending != "" {
		t.Fatalf("clean=%q pending=%q", clean, pending)
	}
	if len(calls) != 2 {
		t.Fatalf("calls = %+v", calls)
	}
	for i, call := range calls {
		if call.Name != "exec_command" {
			t.Fatalf("call %d name = %q", i, call.Name)
		}
		if strings.Contains(call.Arguments, "command") || !strings.Contains(call.Arguments, `"cmd"`) {
			t.Fatalf("call %d arguments not normalized: %s", i, call.Arguments)
		}
	}
	if !strings.Contains(calls[0].Arguments, "RELAYKIT_TOOL_PROOF") || calls[1].Arguments != `{"cmd":"pwd"}` {
		t.Fatalf("calls = %+v", calls)
	}
	for _, forbidden := range []string{"<invoke", "<parameter", "<tool_call", "</tool_call", "printf OK", "reply OK"} {
		if strings.Contains(clean, forbidden) {
			t.Fatalf("clean text leaked %q: %s", forbidden, clean)
		}
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

func TestNativeOpenAIResponsesNonStreamingPreservesProtocol(t *testing.T) {
	const providerToken = "native-provider-token"
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/responses" {
			t.Fatalf("upstream path = %q, want /responses", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer "+providerToken {
			t.Fatalf("provider auth = %q", got)
		}
		if got := r.Header.Get("X-Inbound-Only"); got != "" {
			t.Fatalf("inbound header leaked upstream: %q", got)
		}
		var got map[string]any
		if err := json.NewDecoder(r.Body).Decode(&got); err != nil {
			t.Fatalf("decode upstream request: %v", err)
		}
		if got["model"] != "native-upstream" || got["future_field"] != "preserved" {
			t.Fatalf("request projection = %#v", got)
		}
		if _, ok := got["instructions"]; !ok {
			t.Fatalf("instructions missing: %#v", got)
		}
		if _, ok := got["input"].([]any); !ok {
			t.Fatalf("structured input was not preserved: %#v", got["input"])
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"id":     "resp_native",
			"object": "response",
			"model":  "native-upstream",
			"status": "completed",
			"output": []map[string]any{
				{"id": "rs_1", "type": "reasoning", "status": "completed", "summary": []any{}},
				{"id": "msg_1", "type": "message", "status": "completed", "role": "assistant", "content": []map[string]string{{"type": "output_text", "text": "native"}}},
				{"id": "fc_1", "type": "function_call", "call_id": "call_1", "name": "lookup", "arguments": `{"city":"Paris"}`, "status": "completed"},
			},
			"usage": map[string]int{"input_tokens": 7, "output_tokens": 5, "total_tokens": 12},
		})
	}))
	defer upstream.Close()

	t.Setenv("RELAYKIT_NATIVE_PROVIDER_TOKEN", providerToken)
	usagePath := filepath.Join(t.TempDir(), "usage.jsonl")
	h, err := NewWithUsageLog(writeNativeResponsesConfig(t, upstream.URL, "public/native"), usagePath)
	if err != nil {
		t.Fatalf("New err = %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(`{"model":"public/native","instructions":"Keep JSON","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]},{"type":"function_call_output","call_id":"prior_call","output":"done"}],"reasoning":{"effort":"high"},"tools":[{"type":"function","name":"lookup","parameters":{"type":"object"}}],"tool_choice":"auto","parallel_tool_calls":true,"metadata":{"trace":"fixture"},"include":["reasoning.encrypted_content"],"future_field":"preserved"}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer inbound-token")
	req.Header.Set("X-Inbound-Only", "must-not-forward")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d body = %s", rec.Code, rec.Body.String())
	}
	var response map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode native response: %v", err)
	}
	if response["model"] != "public/native" || response["id"] != "resp_native" || response["status"] != "completed" {
		t.Fatalf("response projection = %#v", response)
	}
	output, _ := response["output"].([]any)
	if len(output) != 3 || output[2].(map[string]any)["call_id"] != "call_1" {
		t.Fatalf("native output items changed: %#v", response["output"])
	}
	usage, err := os.ReadFile(usagePath)
	if err != nil {
		t.Fatalf("read usage: %v", err)
	}
	if strings.Contains(string(usage), "inbound-token") || strings.Contains(string(usage), "hello") || strings.Contains(string(usage), upstream.URL) {
		t.Fatalf("native usage leaked request detail: %s", usage)
	}
	var usageEvent map[string]any
	if err := json.Unmarshal(bytes.TrimSpace(usage), &usageEvent); err != nil {
		t.Fatalf("decode native usage: %v", err)
	}
	if usageEvent["provider_id"] != "native" || usageEvent["model"] != "public/native" || usageEvent["input_tokens"] != float64(7) || usageEvent["output_tokens"] != float64(5) || usageEvent["total_tokens"] != float64(12) {
		t.Fatalf("native usage = %#v", usageEvent)
	}
}

func TestNativeOpenAIResponsesStreamsEventsAndReportsTruncation(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/responses" {
			t.Fatalf("upstream path = %q, want /v1/responses", r.URL.Path)
		}
		var request map[string]any
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Fatal(err)
		}
		if request["stream"] != true || request["model"] != "native-upstream" {
			t.Fatalf("stream request = %#v", request)
		}
		w.Header().Set("Content-Type", "text/event-stream")
		if request["input"] == "truncate" {
			_, _ = fmt.Fprint(w, "event: response.created\ndata: {\"type\":\"response.created\",\"sequence_number\":1,\"response\":{\"id\":\"resp_truncated\",\"model\":\"native-upstream\",\"status\":\"in_progress\",\"output\":[]}}\n\n")
			return
		}
		if request["input"] == "incomplete" || request["input"] == "failed" {
			status := request["input"].(string)
			_, _ = fmt.Fprintf(w, "event: response.%s\ndata: {\"type\":\"response.%s\",\"sequence_number\":1,\"response\":{\"id\":\"resp_%s\",\"object\":\"response\",\"model\":\"native-upstream\",\"status\":\"%s\",\"output\":[]}}\n\n", status, status, status, status)
			return
		}
		for _, event := range []string{
			"event: response.created\n" + `data: {"type":"response.created","sequence_number":1,"response":{"id":"resp_stream","model":"native-upstream","status":"in_progress","output":[]}}`,
			"event: response.output_item.added\n" + `data: {"type":"response.output_item.added","sequence_number":2,"output_index":0,"item":{"id":"msg_stream","type":"message","status":"in_progress","content":[]}}`,
			"event: response.function_call_arguments.delta\n" + `data: {"type":"response.function_call_arguments.delta","sequence_number":3,"output_index":1,"call_id":"call_stream","delta":"{\"city\":"}`,
			"event: response.completed\n" + `data: {"type":"response.completed","sequence_number":4,"response":{"id":"resp_stream","object":"response","model":"native-upstream","status":"completed","output":[],"usage":{"input_tokens":3,"output_tokens":2,"total_tokens":5}}}`,
		} {
			_, _ = fmt.Fprint(w, event+"\n\n")
		}
	}))
	defer upstream.Close()

	h, err := New(writeNativeResponsesConfig(t, upstream.URL+"/v1/", "public/native"))
	if err != nil {
		t.Fatalf("New err = %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(`{"model":"public/native","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"stream"}]}],"stream":true}`))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	got := rec.Body.String()
	for _, want := range []string{"event: response.created", "event: response.output_item.added", "event: response.function_call_arguments.delta", "event: response.completed", `"model":"public/native"`, `"call_id":"call_stream"`, `"sequence_number":4`} {
		if !strings.Contains(got, want) {
			t.Fatalf("native stream missing %q:\n%s", want, got)
		}
	}
	if strings.Index(got, "response.created") > strings.Index(got, "response.completed") {
		t.Fatalf("event order changed:\n%s", got)
	}

	truncated := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(`{"model":"public/native","input":"truncate","stream":true}`))
	truncated.Header.Set("Content-Type", "application/json")
	truncatedRec := httptest.NewRecorder()
	h.ServeHTTP(truncatedRec, truncated)
	truncatedBody := truncatedRec.Body.String()
	if strings.Count(truncatedBody, "event: response.error") != 1 || !strings.Contains(truncatedBody, "upstream_stream_truncated") || strings.Contains(truncatedBody, "response.completed") {
		t.Fatalf("truncated stream = %s", truncatedBody)
	}
	for _, terminal := range []string{"incomplete", "failed"} {
		terminalReq := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(`{"model":"public/native","input":"`+terminal+`","stream":true}`))
		terminalReq.Header.Set("Content-Type", "application/json")
		terminalRec := httptest.NewRecorder()
		h.ServeHTTP(terminalRec, terminalReq)
		terminalBody := terminalRec.Body.String()
		if !strings.Contains(terminalBody, "event: response."+terminal) || !strings.Contains(terminalBody, `"model":"public/native"`) || strings.Contains(terminalBody, "response.error") {
			t.Fatalf("%s stream = %s", terminal, terminalBody)
		}
	}
}

func TestNativeResponsesRejectsRedirectWithoutFollowing(t *testing.T) {
	for _, redirectStatus := range []int{http.StatusMovedPermanently, http.StatusFound, http.StatusTemporaryRedirect, http.StatusPermanentRedirect} {
		t.Run(fmt.Sprintf("status %d", redirectStatus), func(t *testing.T) {
			var sourcePosts, targetHits atomic.Int32
			target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				targetHits.Add(1)
				w.Header().Set("Content-Type", "application/json")
				_, _ = fmt.Fprint(w, `{"id":"resp_redirected","object":"response","status":"completed","output":[]}`)
			}))
			defer target.Close()
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method == http.MethodPost {
					sourcePosts.Add(1)
				}
				w.Header().Set("Location", target.URL+"/responses")
				w.WriteHeader(redirectStatus)
			}))
			defer upstream.Close()

			h, err := New(writeNativeResponsesConfig(t, upstream.URL, "public/native"))
			if err != nil {
				t.Fatal(err)
			}
			assertRejected := func(transport string, call func() string) {
				t.Helper()
				sourcePosts.Store(0)
				targetHits.Store(0)
				if body := call(); !strings.Contains(body, "upstream_error") {
					t.Fatalf("%s redirect response = %s", transport, body)
				}
				if sourcePosts.Load() != 1 || targetHits.Load() != 0 {
					t.Fatalf("%s source posts=%d target hits=%d", transport, sourcePosts.Load(), targetHits.Load())
				}
			}
			assertRejected("http", func() string {
				req := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(`{"model":"public/native","input":"redirect"}`))
				req.Header.Set("Content-Type", "application/json")
				rec := httptest.NewRecorder()
				h.ServeHTTP(rec, req)
				if rec.Code != http.StatusBadGateway {
					t.Fatalf("http status = %d, body = %s", rec.Code, rec.Body.String())
				}
				return rec.Body.String()
			})
			assertRejected("sse", func() string {
				req := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(`{"model":"public/native","input":"redirect","stream":true}`))
				req.Header.Set("Content-Type", "application/json")
				rec := httptest.NewRecorder()
				h.ServeHTTP(rec, req)
				if rec.Code != http.StatusBadGateway {
					t.Fatalf("sse status = %d, body = %s", rec.Code, rec.Body.String())
				}
				return rec.Body.String()
			})
			assertRejected("websocket", func() string {
				srv := httptest.NewServer(h)
				defer srv.Close()
				conn, reader := openTestWebSocket(t, srv.URL, "/v1/responses")
				defer conn.Close()
				writeTestWebSocketText(t, conn, `{"model":"public/native","input":"redirect"}`)
				events := readNativeWebSocketAllEvents(t, reader)
				body, err := json.Marshal(events)
				if err != nil {
					t.Fatal(err)
				}
				return string(body)
			})
		})
	}
}

func TestForwardNativeResponsesSSEByteBudget(t *testing.T) {
	terminal := "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_budget\",\"object\":\"response\",\"model\":\"native-upstream\",\"status\":\"completed\",\"output\":[]}}\n\n"
	created := "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_budget\",\"model\":\"native-upstream\",\"status\":\"in_progress\",\"output\":[]}}\n\n"
	smallEvent := "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"" + strings.Repeat("x", 4096) + "\"}\n\n"
	if len(terminal) > maximumNativeResponsesSSEBytes {
		t.Fatal("terminal fixture exceeds SSE budget")
	}
	exactBoundary := strings.Repeat("\n", maximumNativeResponsesSSEBytes-len(terminal)) + terminal
	manySmallEventsOver := strings.Repeat(smallEvent, maximumNativeResponsesSSEBytes/len(smallEvent)+1)
	singleEventOver := "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"" + strings.Repeat("x", maximumNativeResponsesSSEBytes) + "\"}\n\n"

	for _, tc := range []struct {
		name          string
		stream        string
		wantTerminal  bool
		wantErrorKind string
	}{
		{"many small events over total", manySmallEventsOver, false, "upstream_stream_error"},
		{"single event over", singleEventOver, false, "upstream_stream_error"},
		{"exact boundary", exactBoundary, true, ""},
		{"normal terminal", terminal, true, ""},
		{"truncated", created, false, "upstream_stream_truncated"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var sent []string
			result := forwardNativeResponsesSSE(strings.NewReader(tc.stream), "public/native", func(event string, _ []byte) bool {
				sent = append(sent, event)
				return true
			})
			if result.Terminal != tc.wantTerminal || result.ErrorKind != tc.wantErrorKind {
				t.Fatalf("result = %+v, want terminal=%t error=%q", result, tc.wantTerminal, tc.wantErrorKind)
			}
			if tc.wantTerminal && len(sent) == 0 {
				t.Fatal("terminal event was not forwarded")
			}
			if tc.wantErrorKind != "" && (len(sent) == 0 || sent[len(sent)-1] != "response.error") {
				t.Fatalf("error event not forwarded: %v", sent)
			}
		})
	}
}

func TestNativeOpenAIResponsesWebSocketForwardsProviderEvents(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/responses" {
			t.Fatalf("upstream path = %q", r.URL.Path)
		}
		var request map[string]any
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Fatal(err)
		}
		if request["stream"] != true || request["model"] != "native-upstream" || request["future"] != "preserved" {
			t.Fatalf("websocket upstream request = %#v", request)
		}
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = fmt.Fprint(w, "event: response.completed\ndata: {\"type\":\"response.completed\",\"sequence_number\":1,\"response\":{\"id\":\"resp_ws\",\"object\":\"response\",\"model\":\"native-upstream\",\"status\":\"completed\",\"output\":[]}}\n\n")
	}))
	defer upstream.Close()

	h, err := New(writeNativeResponsesConfig(t, upstream.URL, "public/native"))
	if err != nil {
		t.Fatalf("New err = %v", err)
	}
	srv := httptest.NewServer(h)
	defer srv.Close()
	conn, reader := openTestWebSocket(t, srv.URL, "/v1/responses")
	defer conn.Close()
	writeTestWebSocketText(t, conn, `{"type":"response.create","response":{"model":"public/native","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"ws"}]}],"future":"preserved"}}`)
	got := readTestWebSocketUntil(t, reader, "response.completed")
	if !strings.Contains(got, `"model":"public/native"`) || !strings.Contains(got, `"sequence_number":1`) {
		t.Fatalf("websocket native event = %s", got)
	}
	bareConn, bareReader := openTestWebSocket(t, srv.URL, "/v1/responses")
	defer bareConn.Close()
	writeTestWebSocketText(t, bareConn, `{"model":"public/native","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"bare"}]}],"future":"preserved"}`)
	bare := readTestWebSocketUntil(t, bareReader, "response.completed")
	if !strings.Contains(bare, `"model":"public/native"`) || !strings.Contains(bare, `"sequence_number":1`) {
		t.Fatalf("bare websocket native event = %s", bare)
	}
}

func TestNativeOpenAIResponsesClassifiesUpstreamFailures(t *testing.T) {
	cases := []struct {
		name        string
		upstream    int
		contentType string
		body        string
		wantStatus  int
		wantType    string
	}{
		{"bad request", http.StatusBadRequest, "application/json", `{"error":"bad input"}`, http.StatusBadRequest, "upstream_invalid_request"},
		{"unauthorized", http.StatusUnauthorized, "text/html", "<html>credential</html>", http.StatusBadGateway, "upstream_auth_error"},
		{"rate limited", http.StatusTooManyRequests, "application/json", `{"error":"slow down"}`, http.StatusTooManyRequests, "rate_limit"},
		{"unavailable", http.StatusServiceUnavailable, "application/json", `{"error":"retry"}`, http.StatusServiceUnavailable, "unavailable"},
		{"wrong media", http.StatusOK, "text/html", "<html>not json</html>", http.StatusBadGateway, "protocol_error"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", tc.contentType)
				w.WriteHeader(tc.upstream)
				_, _ = w.Write([]byte(tc.body))
			}))
			defer upstream.Close()
			h, err := New(writeNativeResponsesConfig(t, upstream.URL, "public/native"))
			if err != nil {
				t.Fatal(err)
			}
			req := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(`{"model":"public/native","input":"fixture"}`))
			req.Header.Set("Content-Type", "application/json")
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			if rec.Code != tc.wantStatus || !strings.Contains(rec.Body.String(), `"type":"`+tc.wantType+`"`) {
				t.Fatalf("response = %d %s", rec.Code, rec.Body.String())
			}
			if strings.Contains(rec.Body.String(), "credential") || strings.Contains(rec.Body.String(), "<html>") {
				t.Fatalf("unsanitized upstream failure: %s", rec.Body.String())
			}
		})
	}
}

func TestNativeOpenAIResponsesCatalogProbeUsesResponsesEndpoint(t *testing.T) {
	oldLookup := lookupKeychainCredential
	keychainLookups := 0
	lookupKeychainCredential = func(name string) (string, error) {
		keychainLookups++
		if name != "relaykit.test.native-probe" {
			t.Fatalf("keychain item = %q", name)
		}
		return "keychain-probe-token", nil
	}
	defer func() { lookupKeychainCredential = oldLookup }()

	cases := []struct {
		name          string
		baseV1        bool
		credential    string
		validResponse bool
	}{
		{"key file root valid", false, "key_file", true},
		{"key file v1 malformed", true, "key_file", false},
		{"keychain root malformed", false, "keychain", false},
		{"keychain v1 valid", true, "keychain", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			expectedProbePath := "/responses"
			expectedModelsPath := "/models"
			if tc.baseV1 {
				expectedProbePath = "/v1/responses"
				expectedModelsPath = "/v1/models"
			}
			probeHits := 0
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch r.URL.Path {
				case expectedModelsPath:
					w.Header().Set("Content-Type", "application/json")
					_, _ = w.Write([]byte(`{"data":[{"id":"native-upstream"}]}`))
				case expectedProbePath:
					probeHits++
					if strings.Contains(r.URL.Path, "chat/completions") {
						t.Fatalf("native probe used chat endpoint %q", r.URL.Path)
					}
					wantAuth := testBearerCredential("keychain", "probe", "token")
					if tc.credential == "key_file" {
						wantAuth = "file-probe-token"
					}
					if got := r.Header.Get("x-native-key"); tc.credential == "key_file" && got != wantAuth {
						t.Fatalf("key-file auth = %q, want %q", got, wantAuth)
					}
					if got := r.Header.Get("Authorization"); tc.credential == "keychain" && got != wantAuth {
						t.Fatalf("keychain auth = %q, want %q", got, wantAuth)
					}
					var request map[string]any
					if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
						t.Fatalf("decode probe request: %v", err)
					}
					if request["model"] != "native-upstream" || request["stream"] != false || request["input"] == nil || request["messages"] != nil {
						t.Fatalf("native probe request = %#v", request)
					}
					w.Header().Set("Content-Type", "application/json")
					if tc.validResponse {
						_, _ = w.Write([]byte(`{"id":"resp_probe","object":"response","model":"native-upstream","status":"completed","output":[]}`))
					} else {
						_, _ = w.Write([]byte(`{"id":"resp_probe","object":"response","model":"native-upstream","status":`))
					}
				default:
					t.Fatalf("unexpected upstream path %q", r.URL.Path)
				}
			}))
			defer upstream.Close()

			dir := t.TempDir()
			baseURL := upstream.URL
			if tc.baseV1 {
				baseURL += "/v1/"
			}
			credential := `{"kind":"keychain","value":"relaykit.test.native-probe"}`
			if tc.credential == "key_file" {
				keyPath := filepath.Join(dir, "provider.key")
				if err := os.WriteFile(keyPath, []byte("file-probe-token\n"), 0600); err != nil {
					t.Fatal(err)
				}
				credential = `{"kind":"key_file","value":"` + keyPath + `","header":"x-native-key"}`
			}
			cfgPath := filepath.Join(dir, "providers.json")
			cfgJSON := `{"providers":[{"id":"native","name":"Native","base_url":"` + baseURL + `","api_format":"openai_responses","credential_ref":` + credential + `,"models":[{"id":"public/native","upstream_model":"native-upstream"}]}]}`
			if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
				t.Fatal(err)
			}
			h, err := New(cfgPath)
			if err != nil {
				t.Fatal(err)
			}
			req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			if rec.Code != http.StatusOK || probeHits != 1 {
				t.Fatalf("catalog response = %d %s; probe hits=%d", rec.Code, rec.Body.String(), probeHits)
			}
			if tc.validResponse {
				if !strings.Contains(rec.Body.String(), `"id":"public/native"`) {
					t.Fatalf("valid native model hidden: %s", rec.Body.String())
				}
			} else {
				if strings.Contains(rec.Body.String(), `"id":"public/native","object":"model"`) || !strings.Contains(rec.Body.String(), "upstream decode error") {
					t.Fatalf("malformed native probe not hidden: %s", rec.Body.String())
				}
			}
			for _, secret := range []string{"file-probe-token", "keychain-probe-token", upstream.URL} {
				if strings.Contains(rec.Body.String(), secret) {
					t.Fatalf("catalog leaked %q: %s", secret, rec.Body.String())
				}
			}
		})
	}
	if keychainLookups != 4 {
		t.Fatalf("injected keychain lookups = %d, want 4", keychainLookups)
	}
}

func TestNativeOpenAIResponsesCatalogProbeRequiresCompletedStatus(t *testing.T) {
	cases := []struct {
		status  string
		visible bool
	}{
		{"completed", true},
		{"failed", false},
		{"incomplete", false},
	}
	for _, tc := range cases {
		t.Run(tc.status, func(t *testing.T) {
			probeHits := 0
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if got := r.Header.Get("x-native-key"); got != "probe-status-token" {
					t.Fatalf("probe auth = %q", got)
				}
				switch r.URL.Path {
				case "/models":
					w.Header().Set("Content-Type", "application/json")
					_, _ = w.Write([]byte(`{"data":[{"id":"native-upstream"}]}`))
				case "/responses":
					probeHits++
					var request map[string]any
					if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
						t.Fatal(err)
					}
					if request["model"] != "native-upstream" || request["stream"] != false || request["input"] == nil || request["messages"] != nil {
						t.Fatalf("native probe request = %#v", request)
					}
					w.Header().Set("Content-Type", "application/json")
					_, _ = fmt.Fprintf(w, `{"id":"resp_probe_%s","object":"response","model":"native-upstream","status":%q,"output":[],"error":{"message":"PROBE_STATUS_SECRET"}}`, tc.status, tc.status)
				default:
					t.Fatalf("native probe used non-Responses endpoint %q", r.URL.Path)
				}
			}))
			defer upstream.Close()

			dir := t.TempDir()
			keyPath := filepath.Join(dir, "provider.key")
			if err := os.WriteFile(keyPath, []byte("probe-status-token\n"), 0600); err != nil {
				t.Fatal(err)
			}
			cfgPath := filepath.Join(dir, "providers.json")
			cfgJSON := `{"providers":[{"id":"native","name":"Native","base_url":"` + upstream.URL + `","api_format":"openai_responses","credential_ref":{"kind":"key_file","value":"` + keyPath + `","header":"x-native-key"},"models":[{"id":"public/native","upstream_model":"native-upstream"}]}]}`
			if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
				t.Fatal(err)
			}
			h, err := New(cfgPath)
			if err != nil {
				t.Fatal(err)
			}
			req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			if rec.Code != http.StatusOK || probeHits != 1 {
				t.Fatalf("catalog response = %d %s; probe hits=%d", rec.Code, rec.Body.String(), probeHits)
			}
			body := rec.Body.String()
			if tc.visible {
				if !strings.Contains(body, `"id":"public/native"`) || !strings.Contains(body, `"healthy":1`) || strings.Contains(body, "upstream response not completed") {
					t.Fatalf("completed probe not healthy: %s", body)
				}
			} else if strings.Contains(body, `"id":"public/native","object":"model"`) || !strings.Contains(body, `"reason":"upstream response not completed"`) || !strings.Contains(body, `"unhealthy":1`) {
				t.Fatalf("%s probe not hidden: %s", tc.status, body)
			}
			for _, forbidden := range []string{"PROBE_STATUS_SECRET", "probe-status-token", upstream.URL, "resp_probe_"} {
				if strings.Contains(body, forbidden) {
					t.Fatalf("catalog leaked %q: %s", forbidden, body)
				}
			}
		})
	}
}

func TestNativeOpenAIResponsesCatalogProbeRequiresExactJSONContentType(t *testing.T) {
	cases := []struct {
		name        string
		contentType string
		visible     bool
	}{
		{"exact", "application/json", true},
		{"params", "application/json; charset=utf-8", true},
		{"case", `Application/JSON; Charset="UTF-8"`, true},
		{"plain text", "text/plain", false},
		{"json evil", "application/json-evil", false},
		{"malformed params", "application/json; charset", false},
		{"empty", "", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			probeHits := 0
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if got := r.Header.Get("x-native-key"); got != "probe-media-token" {
					t.Fatalf("probe auth = %q", got)
				}
				switch r.URL.Path {
				case "/v1/models":
					w.Header().Set("Content-Type", "application/json")
					_, _ = w.Write([]byte(`{"data":[{"id":"native-upstream"}]}`))
				case "/v1/responses":
					probeHits++
					w.Header()["Content-Type"] = []string{tc.contentType}
					_, _ = w.Write([]byte(`{"id":"resp_probe_media","object":"response","model":"native-upstream","status":"completed","output":[{"text":"PROBE_MEDIA_SECRET"}],"usage":{"total_tokens":999}}`))
				default:
					t.Fatalf("native probe used non-Responses endpoint %q", r.URL.Path)
				}
			}))
			defer upstream.Close()

			dir := t.TempDir()
			keyPath := filepath.Join(dir, "provider.key")
			if err := os.WriteFile(keyPath, []byte("probe-media-token\n"), 0600); err != nil {
				t.Fatal(err)
			}
			cfgPath := filepath.Join(dir, "providers.json")
			cfgJSON := `{"providers":[{"id":"native","name":"Native","base_url":"` + upstream.URL + `/v1/","api_format":"openai_responses","credential_ref":{"kind":"key_file","value":"` + keyPath + `","header":"x-native-key"},"models":[{"id":"public/native","upstream_model":"native-upstream"}]}]}`
			if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
				t.Fatal(err)
			}
			h, err := New(cfgPath)
			if err != nil {
				t.Fatal(err)
			}
			req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			if rec.Code != http.StatusOK || probeHits != 1 {
				t.Fatalf("catalog response = %d %s; probe hits=%d", rec.Code, rec.Body.String(), probeHits)
			}
			body := rec.Body.String()
			if tc.visible {
				if !strings.Contains(body, `"id":"public/native"`) || !strings.Contains(body, `"healthy":1`) {
					t.Fatalf("valid probe media hidden: %s", body)
				}
			} else if strings.Contains(body, `"id":"public/native","object":"model"`) || !strings.Contains(body, `"reason":"upstream decode error"`) || !strings.Contains(body, `"unhealthy":1`) {
				t.Fatalf("invalid probe media exposed: %s", body)
			}
			for _, forbidden := range []string{"PROBE_MEDIA_SECRET", "probe-media-token", upstream.URL, "resp_probe_media", `"total_tokens":999`} {
				if strings.Contains(body, forbidden) {
					t.Fatalf("catalog leaked %q: %s", forbidden, body)
				}
			}
		})
	}
}

func TestNativeOpenAIResponsesStreamErrorIsSingleTerminalFailure(t *testing.T) {
	cases := []struct {
		name        string
		contentType string
		event       string
		dataType    string
	}{
		{"error event mixed case media", "Text/Event-Stream; Charset=UTF-8", "error", "error"},
		{"response error standard media", "text/event-stream", "response.error", "response.error"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			const secret = "STREAM_SECRET_SENTINEL"
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", tc.contentType)
				w.Header().Set("X-Upstream-Secret", secret)
				_, _ = fmt.Fprintf(w, "event: %s\ndata: {\"type\":%q,\"error\":{\"message\":%q}}\n\n", tc.event, tc.dataType, secret)
				_, _ = fmt.Fprint(w, "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_after_error\",\"object\":\"response\",\"model\":\"native-upstream\",\"status\":\"completed\",\"output\":[]}}\n\n")
			}))
			defer upstream.Close()
			usagePath := filepath.Join(t.TempDir(), "usage.jsonl")
			h, err := NewWithUsageLog(writeNativeResponsesConfig(t, upstream.URL, "public/native"), usagePath)
			if err != nil {
				t.Fatal(err)
			}
			req := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(`{"model":"public/native","input":"stream error","stream":true}`))
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("Authorization", testBearerCredential("INBOUND", "SECRET", "SENTINEL"))
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			body := rec.Body.String()
			if strings.Count(body, "event: response.error") != 1 || strings.Count(body, `"type":"response.error"`) != 1 {
				t.Fatalf("terminal error count:\n%s", body)
			}
			for _, forbidden := range []string{"upstream_stream_truncated", "response.completed", secret, "INBOUND_SECRET_SENTINEL", "X-Upstream-Secret"} {
				if strings.Contains(body, forbidden) {
					t.Fatalf("stream error leaked/duplicated %q:\n%s", forbidden, body)
				}
			}
			usage, err := os.ReadFile(usagePath)
			if err != nil {
				t.Fatal(err)
			}
			lines := bytes.Split(bytes.TrimSpace(usage), []byte("\n"))
			if len(lines) != 1 || !bytes.Contains(lines[0], []byte(`"status":"failed"`)) || bytes.Contains(lines[0], []byte(`"status":"completed"`)) || bytes.Contains(lines[0], []byte(secret)) {
				t.Fatalf("stream error usage = %s", usage)
			}
		})
	}

	var sent [][]byte
	result := forwardNativeResponsesSSE(io.MultiReader(
		strings.NewReader("event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_scan\",\"model\":\"native-upstream\",\"status\":\"in_progress\"}}\n\n"),
		streamReadError{},
	), "public/native", func(_ string, data []byte) bool {
		sent = append(sent, append([]byte(nil), data...))
		return true
	})
	joined := string(bytes.Join(sent, []byte("\n")))
	if result.ErrorKind == "" || strings.Count(joined, `"type":"response.error"`) != 1 || strings.Contains(joined, "response.completed") {
		t.Fatalf("scanner failure result=%+v events=%s", result, joined)
	}
}

func TestNativeOpenAIResponsesNonStreamingRejectsErrorEnvelopeAndInvalidShape(t *testing.T) {
	cases := []struct {
		name       string
		body       string
		valid      bool
		wantStatus string
	}{
		{"error envelope", `{"error":{"type":"provider_error","message":"NONSTREAM_SECRET"}}`, false, ""},
		{"empty object", `{}`, false, ""},
		{"missing object", `{"id":"resp_x","status":"completed"}`, false, ""},
		{"missing id", `{"object":"response","status":"completed"}`, false, ""},
		{"missing status", `{"id":"resp_x","object":"response"}`, false, ""},
		{"unknown status", `{"id":"resp_x","object":"response","status":"queued"}`, false, ""},
		{"nonterminal status", `{"id":"resp_x","object":"response","status":"in_progress"}`, false, ""},
		{"trailing garbage", `{"id":"resp_x","object":"response","status":"completed"} trailing`, false, ""},
		{"completed", `{"id":"resp_completed","object":"response","model":"native-upstream","status":"completed","output":[]}`, true, "completed"},
		{"failed", `{"id":"resp_failed","object":"response","model":"native-upstream","status":"failed","error":{"type":"model_error"},"output":[]}`, true, "failed"},
		{"incomplete", `{"id":"resp_incomplete","object":"response","model":"native-upstream","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}`, true, "incomplete"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				_, _ = w.Write([]byte(tc.body))
			}))
			defer upstream.Close()
			usagePath := filepath.Join(t.TempDir(), "usage.jsonl")
			h, err := NewWithUsageLog(writeNativeResponsesConfig(t, upstream.URL, "public/native"), usagePath)
			if err != nil {
				t.Fatal(err)
			}
			req := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(`{"model":"public/native","input":"strict fixture"}`))
			req.Header.Set("Content-Type", "application/json")
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			usage, err := os.ReadFile(usagePath)
			if err != nil {
				t.Fatal(err)
			}
			if tc.valid {
				if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"status":"`+tc.wantStatus+`"`) || !strings.Contains(rec.Body.String(), `"model":"public/native"`) {
					t.Fatalf("valid response = %d %s", rec.Code, rec.Body.String())
				}
				if !bytes.Contains(usage, []byte(`"status":"`+tc.wantStatus+`"`)) {
					t.Fatalf("valid usage forged status: %s", usage)
				}
			} else {
				if rec.Code != http.StatusBadGateway || !strings.Contains(rec.Body.String(), `"type":"protocol_error"`) {
					t.Fatalf("invalid response accepted = %d %s", rec.Code, rec.Body.String())
				}
				for _, forbidden := range []string{"NONSTREAM_SECRET", "provider_error", "resp_x", `"status":"completed"`} {
					if strings.Contains(rec.Body.String(), forbidden) {
						t.Fatalf("invalid response leaked/forged %q: %s", forbidden, rec.Body.String())
					}
				}
				if !bytes.Contains(usage, []byte(`"status":"failed"`)) || bytes.Contains(usage, []byte(`"status":"completed"`)) {
					t.Fatalf("invalid response usage = %s", usage)
				}
			}
		})
	}
}

func TestNativeOpenAIResponsesStreamsCompleteLifecycle(t *testing.T) {
	const providerToken = "LIFECYCLE_PROVIDER_TOKEN"
	fixture := nativeResponsesLifecycleFixture()
	requestChecks := 0
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestChecks++
		if r.URL.Path != "/v1/responses" || r.Header.Get("Authorization") != "Bearer "+providerToken || r.Header.Get("X-Inbound-Secret") != "" {
			t.Fatalf("upstream route/headers = %s %#v", r.URL.Path, r.Header)
		}
		var request map[string]any
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Fatal(err)
		}
		for _, field := range []string{"instructions", "input", "reasoning", "tools", "tool_choice", "parallel_tool_calls", "metadata", "include", "future_field"} {
			if request[field] == nil {
				t.Fatalf("request field %q missing: %#v", field, request)
			}
		}
		if request["model"] != "native-upstream" || request["stream"] != true {
			t.Fatalf("request projection = %#v", request)
		}
		w.Header().Set("Content-Type", "text/event-stream")
		writeNativeResponsesLifecycleFixture(t, w, fixture)
	}))
	defer upstream.Close()
	t.Setenv("RELAYKIT_NATIVE_PROVIDER_TOKEN", providerToken)
	h, err := New(writeNativeResponsesConfig(t, upstream.URL+"/v1/", "public/native"))
	if err != nil {
		t.Fatal(err)
	}
	requestBody := `{"model":"public/native","instructions":"lifecycle","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"full"}]}],"reasoning":{"effort":"high"},"tools":[{"type":"function","name":"lookup","parameters":{"type":"object"}}],"tool_choice":"auto","parallel_tool_calls":true,"metadata":{"model":"user-model"},"include":["reasoning.encrypted_content"],"future_field":{"model":"future-model"},"stream":true}`
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(requestBody))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer HTTP_INBOUND_SECRET")
	req.Header.Set("X-Inbound-Secret", "HTTP_INBOUND_SECRET")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	assertNativeLifecycleEvents(t, decodeNativeSSEEvents(t, rec.Body.String()))

	srv := httptest.NewServer(h)
	defer srv.Close()
	conn, reader := openTestWebSocketWithHeaders(t, srv.URL, "/v1/responses", map[string]string{"Authorization": "Bearer WS_INBOUND_SECRET", "X-Inbound-Secret": "WS_INBOUND_SECRET"})
	defer conn.Close()
	writeTestWebSocketText(t, conn, `{"type":"response.create","response":`+requestBody+`}`)
	assertNativeLifecycleEvents(t, readNativeWebSocketEvents(t, reader))
	if requestChecks != 2 {
		t.Fatalf("upstream request checks = %d, want 2", requestChecks)
	}
}

func TestNativeOpenAIResponsesRejectsMalformedTerminalEnvelope(t *testing.T) {
	for _, tc := range nativeTerminalEnvelopeCases() {
		t.Run(tc.name, func(t *testing.T) {
			const sentinel = "TERMINAL_SECRET_SENTINEL"
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "text/event-stream")
				_, _ = fmt.Fprintf(w, "event: %s\ndata: %s\n\n", tc.eventType, tc.body)
				_, _ = fmt.Fprint(w, "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_later\",\"object\":\"response\",\"model\":\"native-upstream\",\"status\":\"completed\",\"output\":[]}}\n\n")
			}))
			defer upstream.Close()
			usagePath := filepath.Join(t.TempDir(), "usage.jsonl")
			h, err := NewWithUsageLog(writeNativeResponsesConfig(t, upstream.URL, "public/native"), usagePath)
			if err != nil {
				t.Fatal(err)
			}

			req := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(`{"model":"public/native","input":"terminal","stream":true}`))
			req.Header.Set("Content-Type", "application/json")
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			httpEvents := decodeNativeSSEEvents(t, rec.Body.String())

			srv := httptest.NewServer(h)
			defer srv.Close()
			conn, reader := openTestWebSocket(t, srv.URL, "/v1/responses")
			writeTestWebSocketText(t, conn, `{"model":"public/native","input":"terminal"}`)
			wsEvents := readNativeWebSocketAllEvents(t, reader)
			_ = conn.Close()

			usage := readNativeUsageEvents(t, usagePath)
			if tc.valid {
				for transport, events := range map[string][]map[string]any{"http": httpEvents, "websocket": wsEvents} {
					if len(events) != 1 || events[0]["type"] != tc.eventType {
						t.Fatalf("%s valid terminal events = %#v", transport, events)
					}
					response := events[0]["response"].(map[string]any)
					if response["object"] != "response" || response["id"] != tc.wantID || response["status"] != tc.wantStatus || response["model"] != "public/native" || response["output"].([]any)[0].(map[string]any)["id"] != "msg_terminal" || response["usage"].(map[string]any)["total_tokens"] != float64(13) {
						t.Fatalf("%s valid terminal response = %#v", transport, response)
					}
				}
				if len(usage) != 2 || usage[0]["status"] != tc.wantStatus || usage[1]["status"] != tc.wantStatus {
					t.Fatalf("valid terminal usage = %#v", usage)
				}
				return
			}

			for transport, events := range map[string][]map[string]any{"http": httpEvents, "websocket": wsEvents} {
				if len(events) != 1 || events[0]["type"] != "response.error" || events[0]["error"].(map[string]any)["type"] != "protocol_error" {
					t.Fatalf("%s malformed terminal events = %#v", transport, events)
				}
				raw, _ := json.Marshal(events)
				for _, forbidden := range []string{tc.eventType, "resp_terminal", "resp_later", sentinel, `"total_tokens":999`, "response.completed", "response.failed", "response.incomplete", "upstream_stream_truncated"} {
					if forbidden != "" && strings.Contains(string(raw), forbidden) {
						t.Fatalf("%s malformed terminal leaked/forged %q: %s", transport, forbidden, raw)
					}
				}
			}
			if len(usage) != 2 {
				t.Fatalf("malformed terminal usage count = %d: %#v", len(usage), usage)
			}
			for _, event := range usage {
				if event["status"] != "failed" || event["error_type"] != "protocol_error" || event["request_id"] != nil || event["input_tokens"] != nil || event["output_tokens"] != nil || event["total_tokens"] != nil {
					t.Fatalf("malformed terminal usage = %#v", event)
				}
			}
		})
	}
}

func TestNativeOpenAIResponsesRequiresExactContentTypes(t *testing.T) {
	cases := []struct {
		name        string
		stream      bool
		contentType string
		valid       bool
	}{
		{"json exact", false, "application/json", true},
		{"json legal charset", false, "application/json; charset=utf-8", true},
		{"json legal case", false, `Application/JSON; Charset="UTF-8"`, true},
		{"json evil suffix", false, "application/json-evil", false},
		{"json foo suffix", false, "application/jsonfoo", false},
		{"problem json", false, "application/problem+json", false},
		{"json malformed params", false, "application/json; charset", false},
		{"json empty", false, "", false},
		{"sse exact", true, "text/event-stream", true},
		{"sse legal charset", true, "text/event-stream; charset=utf-8", true},
		{"sse legal case", true, `Text/Event-Stream; Charset="UTF-8"`, true},
		{"sse evil suffix", true, "text/event-stream-evil", false},
		{"sse foo suffix", true, "text/event-streamfoo", false},
		{"sse malformed params", true, "text/event-stream; charset", false},
		{"sse empty", true, "", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			const sentinel = "MEDIA_SECRET_SENTINEL"
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", tc.contentType)
				if tc.stream {
					_, _ = fmt.Fprint(w, "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_media\",\"object\":\"response\",\"model\":\"native-upstream\",\"status\":\"completed\",\"output\":[{\"id\":\"msg_media\",\"text\":\"MEDIA_SECRET_SENTINEL\"}],\"usage\":{\"total_tokens\":999}}}\n\n")
					return
				}
				_, _ = fmt.Fprint(w, `{"id":"resp_media","object":"response","model":"native-upstream","status":"completed","output":[{"id":"msg_media","text":"MEDIA_SECRET_SENTINEL"}],"usage":{"total_tokens":999}}`)
			}))
			defer upstream.Close()
			usagePath := filepath.Join(t.TempDir(), "usage.jsonl")
			h, err := NewWithUsageLog(writeNativeResponsesConfig(t, upstream.URL, "public/native"), usagePath)
			if err != nil {
				t.Fatal(err)
			}
			body := `{"model":"public/native","input":"media"}`
			if tc.stream {
				body = `{"model":"public/native","input":"media","stream":true}`
			}
			req := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(body))
			req.Header.Set("Content-Type", "application/json")
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			usage := readNativeUsageEvents(t, usagePath)
			if tc.valid {
				if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "resp_media") || len(usage) != 1 || usage[0]["status"] != "completed" || usage[0]["total_tokens"] != float64(999) {
					t.Fatalf("valid media response=%d %s usage=%#v", rec.Code, rec.Body.String(), usage)
				}
				return
			}
			if rec.Code != http.StatusBadGateway || !strings.Contains(rec.Body.String(), `"type":"protocol_error"`) || len(usage) != 1 || usage[0]["status"] != "failed" || usage[0]["error_type"] != "protocol_error" {
				t.Fatalf("invalid media response=%d %s usage=%#v", rec.Code, rec.Body.String(), usage)
			}
			for _, forbidden := range []string{sentinel, "resp_media", `"total_tokens":999`, tc.contentType} {
				if forbidden != "" && (strings.Contains(rec.Body.String(), forbidden) || strings.Contains(fmt.Sprint(usage), forbidden)) {
					t.Fatalf("invalid media leaked/parsed %q: response=%s usage=%#v", forbidden, rec.Body.String(), usage)
				}
			}
		})
	}
}

func TestNativeOpenAIResponsesRejectsSSEHeaderPayloadTypeMismatch(t *testing.T) {
	statuses := []string{"completed", "failed", "incomplete"}
	for _, status := range statuses {
		cases := []struct {
			name       string
			headerType string
			payload    string
		}{
			{
				name:       status + " terminal payload under nonterminal header",
				headerType: "response.created",
				payload:    `{"type":"response.` + status + `","sentinel":"SSE_MISMATCH_SECRET","response":{"id":"resp_mismatch","object":"response","model":"native-upstream","status":"` + status + `","output":[],"usage":{"total_tokens":999}}}`,
			},
			{
				name:       status + " terminal header over nonterminal payload",
				headerType: "response." + status,
				payload:    `{"type":"response.created","sentinel":"SSE_MISMATCH_SECRET","response":{"id":"resp_mismatch","object":"response","model":"native-upstream","status":"in_progress","output":[],"usage":{"total_tokens":999}}}`,
			},
		}
		for _, tc := range cases {
			t.Run(tc.name, func(t *testing.T) {
				upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					w.Header().Set("Content-Type", "text/event-stream")
					_, _ = fmt.Fprintf(w, "event: %s\ndata: %s\n\n", tc.headerType, tc.payload)
					_, _ = fmt.Fprint(w, "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_later_mismatch\",\"object\":\"response\",\"model\":\"native-upstream\",\"status\":\"completed\",\"output\":[]}}\n\n")
				}))
				defer upstream.Close()
				usagePath := filepath.Join(t.TempDir(), "usage.jsonl")
				h, err := NewWithUsageLog(writeNativeResponsesConfig(t, upstream.URL, "public/native"), usagePath)
				if err != nil {
					t.Fatal(err)
				}
				req := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(`{"model":"public/native","input":"mismatch","stream":true}`))
				req.Header.Set("Content-Type", "application/json")
				rec := httptest.NewRecorder()
				h.ServeHTTP(rec, req)
				httpEvents := decodeNativeSSEEvents(t, rec.Body.String())

				srv := httptest.NewServer(h)
				defer srv.Close()
				conn, reader := openTestWebSocket(t, srv.URL, "/v1/responses")
				writeTestWebSocketText(t, conn, `{"model":"public/native","input":"mismatch"}`)
				wsEvents := readNativeWebSocketAllEvents(t, reader)
				_ = conn.Close()

				for transport, events := range map[string][]map[string]any{"http": httpEvents, "websocket": wsEvents} {
					if len(events) != 1 || events[0]["type"] != "response.error" || events[0]["error"].(map[string]any)["type"] != "protocol_error" {
						t.Fatalf("%s mismatch events = %#v", transport, events)
					}
					raw, _ := json.Marshal(events)
					for _, forbidden := range []string{"response.completed", "response.failed", "response.incomplete", "response.created", "resp_mismatch", "resp_later_mismatch", "SSE_MISMATCH_SECRET", "upstream_stream_truncated", `"total_tokens":999`} {
						if strings.Contains(string(raw), forbidden) {
							t.Fatalf("%s mismatch leaked/recovered %q: %s", transport, forbidden, raw)
						}
					}
				}
				usage := readNativeUsageEvents(t, usagePath)
				if len(usage) != 2 {
					t.Fatalf("mismatch usage count = %d: %#v", len(usage), usage)
				}
				for _, event := range usage {
					if event["status"] != "failed" || event["error_type"] != "protocol_error" || event["request_id"] != nil || event["total_tokens"] != nil {
						t.Fatalf("mismatch usage = %#v", event)
					}
				}
			})
		}
	}
}

func TestNativeOpenAIResponsesRejectsEventWithoutHeaderOrPayloadType(t *testing.T) {
	cases := []struct {
		name       string
		firstEvent string
		valid      bool
	}{
		{
			name:       "missing header and payload type",
			firstEvent: "data: {\"sentinel\":\"EVENT_IDENTITY_SECRET\",\"id\":\"resp_identity_fake\",\"status\":\"completed\",\"usage\":{\"total_tokens\":999}}\n\n",
		},
		{
			name:       "missing header with payload type",
			firstEvent: "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_identity_valid\",\"object\":\"response\",\"model\":\"native-upstream\",\"status\":\"completed\",\"output\":[],\"usage\":{\"total_tokens\":13}}}\n\n",
			valid:      true,
		},
		{
			name:       "matching header and payload type",
			firstEvent: "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_identity_valid\",\"object\":\"response\",\"model\":\"native-upstream\",\"status\":\"completed\",\"output\":[],\"usage\":{\"total_tokens\":13}}}\n\n",
			valid:      true,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "text/event-stream")
				_, _ = fmt.Fprint(w, tc.firstEvent)
				_, _ = fmt.Fprint(w, "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_identity_later\",\"object\":\"response\",\"model\":\"native-upstream\",\"status\":\"completed\",\"output\":[],\"usage\":{\"total_tokens\":999}}}\n\n")
			}))
			defer upstream.Close()
			usagePath := filepath.Join(t.TempDir(), "usage.jsonl")
			h, err := NewWithUsageLog(writeNativeResponsesConfig(t, upstream.URL, "public/native"), usagePath)
			if err != nil {
				t.Fatal(err)
			}

			req := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(`{"model":"public/native","input":"event identity","stream":true}`))
			req.Header.Set("Content-Type", "application/json")
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			httpEvents := decodeNativeSSEEvents(t, rec.Body.String())

			srv := httptest.NewServer(h)
			defer srv.Close()
			conn, reader := openTestWebSocket(t, srv.URL, "/v1/responses")
			writeTestWebSocketText(t, conn, `{"model":"public/native","input":"event identity"}`)
			wsEvents := readNativeWebSocketAllEvents(t, reader)
			_ = conn.Close()

			usage := readNativeUsageEvents(t, usagePath)
			if tc.valid {
				for transport, events := range map[string][]map[string]any{"http": httpEvents, "websocket": wsEvents} {
					if len(events) != 1 || events[0]["type"] != "response.completed" {
						t.Fatalf("%s valid identity events = %#v", transport, events)
					}
					response := events[0]["response"].(map[string]any)
					if response["id"] != "resp_identity_valid" || response["object"] != "response" || response["status"] != "completed" || response["model"] != "public/native" || response["usage"].(map[string]any)["total_tokens"] != float64(13) {
						t.Fatalf("%s valid identity response = %#v", transport, response)
					}
				}
				if len(usage) != 2 || usage[0]["status"] != "completed" || usage[1]["status"] != "completed" {
					t.Fatalf("valid identity usage = %#v", usage)
				}
				return
			}

			if strings.Contains(rec.Body.String(), "event: message") {
				t.Fatalf("missing identity forwarded as default message:\n%s", rec.Body.String())
			}
			for transport, events := range map[string][]map[string]any{"http": httpEvents, "websocket": wsEvents} {
				if len(events) != 1 || events[0]["type"] != "response.error" || events[0]["error"].(map[string]any)["type"] != "protocol_error" {
					t.Fatalf("%s missing identity events = %#v", transport, events)
				}
				raw, _ := json.Marshal(events)
				for _, forbidden := range []string{"EVENT_IDENTITY_SECRET", "resp_identity_fake", "resp_identity_later", "response.completed", "upstream_stream_truncated", `"status":"completed"`, `"total_tokens":999`} {
					if strings.Contains(string(raw), forbidden) {
						t.Fatalf("%s missing identity leaked/recovered %q: %s", transport, forbidden, raw)
					}
				}
			}
			if len(usage) != 2 {
				t.Fatalf("missing identity usage count = %d: %#v", len(usage), usage)
			}
			for _, event := range usage {
				if event["status"] != "failed" || event["error_type"] != "protocol_error" || event["request_id"] != nil || event["input_tokens"] != nil || event["output_tokens"] != nil || event["total_tokens"] != nil {
					t.Fatalf("missing identity usage = %#v", event)
				}
			}
		})
	}
}

func TestNativeOpenAIResponsesWebSocketRejectsUnknownTypedEnvelope(t *testing.T) {
	cases := []struct {
		name    string
		payload string
		valid   bool
	}{
		{"bare body", `{"model":"public/native","input":"bare"}`, true},
		{"response create", `{"type":"response.create","response":{"model":"public/native","input":"typed"}}`, true},
		{"unknown string", `{"type":"response.cancel","model":"public/native","input":"UNKNOWN_TYPE_SECRET"}`, false},
		{"case variant", `{"type":"Response.Create","model":"public/native","input":"UNKNOWN_TYPE_SECRET"}`, false},
		{"null", `{"type":null,"model":"public/native","input":"UNKNOWN_TYPE_SECRET"}`, false},
		{"boolean", `{"type":true,"model":"public/native","input":"UNKNOWN_TYPE_SECRET"}`, false},
		{"number", `{"type":7,"model":"public/native","input":"UNKNOWN_TYPE_SECRET"}`, false},
		{"object", `{"type":{"name":"response.create"},"model":"public/native","input":"UNKNOWN_TYPE_SECRET"}`, false},
		{"array", `{"type":["response.create"],"model":"public/native","input":"UNKNOWN_TYPE_SECRET"}`, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			upstreamHits := 0
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				upstreamHits++
				w.Header().Set("Content-Type", "text/event-stream")
				_, _ = fmt.Fprint(w, "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_typed\",\"object\":\"response\",\"model\":\"native-upstream\",\"status\":\"completed\",\"output\":[]}}\n\n")
			}))
			defer upstream.Close()
			usagePath := filepath.Join(t.TempDir(), "usage.jsonl")
			h, err := NewWithUsageLog(writeNativeResponsesConfig(t, upstream.URL, "public/native"), usagePath)
			if err != nil {
				t.Fatal(err)
			}
			srv := httptest.NewServer(h)
			defer srv.Close()
			conn, reader := openTestWebSocket(t, srv.URL, "/v1/responses")
			writeTestWebSocketText(t, conn, tc.payload)
			events := readNativeWebSocketAllEvents(t, reader)
			_ = conn.Close()
			if tc.valid {
				if upstreamHits != 1 || len(events) != 1 || events[0]["type"] != "response.completed" || events[0]["response"].(map[string]any)["model"] != "public/native" {
					t.Fatalf("valid typed envelope hits=%d events=%#v", upstreamHits, events)
				}
				return
			}
			if upstreamHits != 0 || len(events) != 1 || events[0]["type"] != "response.error" || events[0]["error"].(map[string]any)["type"] != "protocol_error" {
				t.Fatalf("unknown typed envelope hits=%d events=%#v", upstreamHits, events)
			}
			raw, _ := json.Marshal(events)
			for _, forbidden := range []string{"UNKNOWN_TYPE_SECRET", "response.cancel", "Response.Create", `"type":true`, `"type":7`} {
				if strings.Contains(string(raw), forbidden) {
					t.Fatalf("typed envelope echoed %q: %s", forbidden, raw)
				}
			}
			if usage, err := os.ReadFile(usagePath); err == nil && len(bytes.TrimSpace(usage)) != 0 {
				t.Fatalf("typed envelope wrote usage before routing: %s", usage)
			}
		})
	}
}

type nativeTerminalEnvelopeCase struct {
	name       string
	eventType  string
	body       string
	valid      bool
	wantID     string
	wantStatus string
}

func nativeTerminalEnvelopeCases() []nativeTerminalEnvelopeCase {
	statuses := []string{"completed", "failed", "incomplete"}
	var cases []nativeTerminalEnvelopeCase
	for _, status := range statuses {
		eventType := "response." + status
		validBody := fmt.Sprintf(`{"type":%q,"sentinel":"TERMINAL_SECRET_SENTINEL","response":{"id":%q,"object":"response","model":"native-upstream","status":%q,"output":[{"id":"msg_terminal","type":"message","status":"completed"}],"usage":{"input_tokens":8,"output_tokens":5,"total_tokens":13}}}`, eventType, "resp_"+status, status)
		cases = append(cases, nativeTerminalEnvelopeCase{name: status + " valid", eventType: eventType, body: validBody, valid: true, wantID: "resp_" + status, wantStatus: status})
		invalidResponses := []struct {
			name     string
			response string
		}{
			{"missing response", ""},
			{"null response", `,"response":null`},
			{"nonobject response", `,"response":"TERMINAL_SECRET_SENTINEL"`},
			{"missing object", `,"response":{"id":"resp_terminal","status":"` + status + `","usage":{"total_tokens":999}}`},
			{"wrong object", `,"response":{"id":"resp_terminal","object":"not-response","status":"` + status + `","usage":{"total_tokens":999}}`},
			{"missing id", `,"response":{"object":"response","status":"` + status + `","usage":{"total_tokens":999}}`},
			{"empty id", `,"response":{"id":"","object":"response","status":"` + status + `","usage":{"total_tokens":999}}`},
			{"whitespace id", `,"response":{"id":"   ","object":"response","status":"` + status + `","usage":{"total_tokens":999}}`},
			{"missing status", `,"response":{"id":"resp_terminal","object":"response","usage":{"total_tokens":999}}`},
		}
		for _, invalid := range invalidResponses {
			body := `{"type":"` + eventType + `","sentinel":"TERMINAL_SECRET_SENTINEL"` + invalid.response + `}`
			cases = append(cases, nativeTerminalEnvelopeCase{name: status + " " + invalid.name, eventType: eventType, body: body})
		}
		for _, mismatch := range statuses {
			if mismatch == status {
				continue
			}
			body := `{"type":"` + eventType + `","sentinel":"TERMINAL_SECRET_SENTINEL","response":{"id":"resp_terminal","object":"response","status":"` + mismatch + `","usage":{"total_tokens":999}}}`
			cases = append(cases, nativeTerminalEnvelopeCase{name: status + " mismatched " + mismatch, eventType: eventType, body: body})
		}
		missingType := `{"sentinel":"TERMINAL_SECRET_SENTINEL","response":{"id":"resp_terminal","object":"response","status":"` + status + `","usage":{"total_tokens":999}}}`
		cases = append(cases, nativeTerminalEnvelopeCase{name: status + " missing type", eventType: eventType, body: missingType})
	}
	return cases
}

func readNativeWebSocketAllEvents(t *testing.T, reader *bufio.Reader) []map[string]any {
	t.Helper()
	var events []map[string]any
	for len(events) < 10 {
		opcode, body := readTestWebSocketFrame(t, reader)
		if opcode == websocketOpcodeClose {
			return events
		}
		if opcode != websocketOpcodeText {
			continue
		}
		var event map[string]any
		if err := json.Unmarshal(body, &event); err != nil {
			t.Fatalf("decode websocket event: %v: %s", err, body)
		}
		events = append(events, event)
	}
	t.Fatalf("websocket did not close: %#v", events)
	return nil
}

func TestResponsesRejectsOversizedOrAmbiguousRequestBeforeUpstream(t *testing.T) {
	upstreamHits := 0
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		upstreamHits++
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, `{"id":"resp_unexpected","object":"response","status":"completed","output":[]}`)
	}))
	defer upstream.Close()

	h, err := New(writeNativeResponsesConfig(t, upstream.URL, "public/native"))
	if err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name string
		body string
		want int
	}{
		{"top level array", `[]`, http.StatusBadRequest},
		{"trailing JSON", `{"model":"public/native","input":"x"} {}`, http.StatusBadRequest},
		{"duplicate model", `{"model":"public/native","model":"other","input":"x"}`, http.StatusBadRequest},
		{"duplicate stream", `{"model":"public/native","stream":false,"stream":true,"input":"x"}`, http.StatusBadRequest},
		{"missing model", `{"input":"x"}`, http.StatusBadRequest},
		{"empty model", `{"model":"  ","input":"x"}`, http.StatusBadRequest},
		{"unknown model", `{"model":"missing","input":"x"}`, http.StatusBadRequest},
		{"too large", `{"model":"public/native","input":"` + strings.Repeat("x", maximumResponsesRequestBytes) + `"}`, http.StatusRequestEntityTooLarge},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(tc.body))
			req.Header.Set("Content-Type", "application/json")
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			if rec.Code != tc.want || !strings.Contains(rec.Body.String(), `"type":"invalid_request_error"`) {
				t.Fatalf("response = %d %s", rec.Code, rec.Body.String())
			}
		})
	}
	if upstreamHits != 0 {
		t.Fatalf("upstream was called %d times for rejected requests", upstreamHits)
	}
}

func TestRewriteNativeResponsesResponseRejectsExactMaxPlusOne(t *testing.T) {
	prefix := `{"id":"resp_limit","object":"response","status":"completed","output":[],"future":"`
	suffix := `"}`
	valid := prefix + strings.Repeat("x", maximumNativeResponsesResponseBytes-len(prefix)-len(suffix)) + suffix
	if len(valid) != maximumNativeResponsesResponseBytes {
		t.Fatalf("valid response size = %d", len(valid))
	}
	if _, err := rewriteNativeResponsesResponse(strings.NewReader(valid), "public/native"); err != nil {
		t.Fatalf("response exactly at limit rejected: %v", err)
	}
	over := valid[:len(valid)-len(suffix)] + "x" + suffix
	if len(over) != maximumNativeResponsesResponseBytes+1 {
		t.Fatalf("over response size = %d", len(over))
	}
	if _, err := rewriteNativeResponsesResponse(strings.NewReader(over), "public/native"); err == nil {
		t.Fatal("response over limit unexpectedly accepted")
	}
}

func TestNativeResponsesWebSocketClientCloseCancelsUpstream(t *testing.T) {
	upstreamStarted := make(chan struct{})
	upstreamCanceled := make(chan struct{})
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		close(upstreamStarted)
		<-r.Context().Done()
		close(upstreamCanceled)
	}))
	defer upstream.Close()

	h, err := New(writeNativeResponsesConfig(t, upstream.URL, "public/native"))
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(h)
	defer srv.Close()
	conn, _ := openTestWebSocket(t, srv.URL, "/v1/responses")
	defer conn.Close()
	writeTestWebSocketText(t, conn, `{"model":"public/native","input":"cancel me"}`)
	select {
	case <-upstreamStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("upstream request did not start")
	}
	writeTestWebSocketClose(t, conn)
	select {
	case <-upstreamCanceled:
	case <-time.After(2 * time.Second):
		t.Fatal("upstream request was not canceled after websocket close")
	}
}

func readNativeUsageEvents(t *testing.T, path string) []map[string]any {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var events []map[string]any
	for _, line := range bytes.Split(bytes.TrimSpace(raw), []byte("\n")) {
		var event map[string]any
		if err := json.Unmarshal(line, &event); err != nil {
			t.Fatalf("decode usage: %v: %s", err, line)
		}
		events = append(events, event)
	}
	return events
}

type streamReadError struct{}

func (streamReadError) Read([]byte) (int, error) {
	return 0, fmt.Errorf("STREAM_READER_SECRET")
}

func nativeResponsesLifecycleFixture() []map[string]any {
	reasoning := map[string]any{"id": "rs_lifecycle", "type": "reasoning", "status": "completed", "summary": []any{}}
	messageAdded := map[string]any{"id": "msg_lifecycle", "type": "message", "status": "in_progress", "role": "assistant", "content": []any{}}
	messageDone := map[string]any{"id": "msg_lifecycle", "type": "message", "status": "completed", "role": "assistant", "content": []map[string]any{{"type": "output_text", "text": "native text"}}}
	functionAdded := map[string]any{"id": "fc_lifecycle", "type": "function_call", "status": "in_progress", "call_id": "call_lifecycle", "name": "lookup", "arguments": "", "model": "tool-model"}
	functionDone := map[string]any{"id": "fc_lifecycle", "type": "function_call", "status": "completed", "call_id": "call_lifecycle", "name": "lookup", "arguments": `{"city":"Paris"}`, "model": "tool-model"}
	return []map[string]any{
		{"type": "response.created", "sequence_number": 1, "response": map[string]any{"id": "resp_lifecycle", "object": "response", "model": "native-upstream", "status": "in_progress", "metadata": map[string]any{"model": "user-model"}, "output": []any{}}},
		{"type": "response.output_item.added", "sequence_number": 2, "output_index": 0, "item": reasoning},
		{"type": "response.output_item.done", "sequence_number": 3, "output_index": 0, "item": reasoning},
		{"type": "response.output_item.added", "sequence_number": 4, "output_index": 1, "item": messageAdded},
		{"type": "response.content_part.added", "sequence_number": 5, "item_id": "msg_lifecycle", "output_index": 1, "content_index": 0, "part": map[string]any{"type": "output_text", "text": ""}},
		{"type": "response.output_text.delta", "sequence_number": 6, "item_id": "msg_lifecycle", "output_index": 1, "content_index": 0, "delta": "native text"},
		{"type": "response.output_text.done", "sequence_number": 7, "item_id": "msg_lifecycle", "output_index": 1, "content_index": 0, "text": "native text"},
		{"type": "response.content_part.done", "sequence_number": 8, "item_id": "msg_lifecycle", "output_index": 1, "content_index": 0, "part": map[string]any{"type": "output_text", "text": "native text"}},
		{"type": "response.output_item.done", "sequence_number": 9, "output_index": 1, "item": messageDone},
		{"type": "response.output_item.added", "sequence_number": 10, "output_index": 2, "item": functionAdded},
		{"type": "response.function_call_arguments.delta", "sequence_number": 11, "item_id": "fc_lifecycle", "output_index": 2, "call_id": "call_lifecycle", "delta": `{"city":"`},
		{"type": "response.function_call_arguments.done", "sequence_number": 12, "item_id": "fc_lifecycle", "output_index": 2, "call_id": "call_lifecycle", "arguments": `{"city":"Paris"}`},
		{"type": "response.output_item.done", "sequence_number": 13, "output_index": 2, "item": functionDone},
		{"type": "response.completed", "sequence_number": 14, "response": map[string]any{"id": "resp_lifecycle", "object": "response", "model": "native-upstream", "status": "completed", "metadata": map[string]any{"model": "user-model"}, "output": []any{reasoning, messageDone, functionDone}, "usage": map[string]int{"input_tokens": 11, "output_tokens": 7, "total_tokens": 18}}},
	}
}

func writeNativeResponsesLifecycleFixture(t *testing.T, w io.Writer, fixture []map[string]any) {
	t.Helper()
	for _, event := range fixture {
		body, err := json.Marshal(event)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event["type"], body); err != nil {
			t.Fatal(err)
		}
	}
}

func decodeNativeSSEEvents(t *testing.T, body string) []map[string]any {
	t.Helper()
	var events []map[string]any
	for _, line := range strings.Split(body, "\n") {
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		var event map[string]any
		if err := json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &event); err != nil {
			t.Fatalf("decode SSE event: %v\n%s", err, body)
		}
		events = append(events, event)
	}
	return events
}

func readNativeWebSocketEvents(t *testing.T, reader *bufio.Reader) []map[string]any {
	t.Helper()
	var events []map[string]any
	for len(events) < 20 {
		opcode, body := readTestWebSocketFrame(t, reader)
		if opcode == websocketOpcodeClose {
			break
		}
		if opcode != websocketOpcodeText {
			continue
		}
		var event map[string]any
		if err := json.Unmarshal(body, &event); err != nil {
			t.Fatalf("decode websocket event: %v: %s", err, body)
		}
		events = append(events, event)
		if event["type"] == "response.completed" {
			return events
		}
	}
	t.Fatalf("websocket lifecycle incomplete: %#v", events)
	return nil
}

func assertNativeLifecycleEvents(t *testing.T, events []map[string]any) {
	t.Helper()
	wantTypes := []string{
		"response.created",
		"response.output_item.added",
		"response.output_item.done",
		"response.output_item.added",
		"response.content_part.added",
		"response.output_text.delta",
		"response.output_text.done",
		"response.content_part.done",
		"response.output_item.done",
		"response.output_item.added",
		"response.function_call_arguments.delta",
		"response.function_call_arguments.done",
		"response.output_item.done",
		"response.completed",
	}
	if len(events) != len(wantTypes) {
		t.Fatalf("event count = %d, want %d: %#v", len(events), len(wantTypes), events)
	}
	for i, event := range events {
		if event["type"] != wantTypes[i] || event["sequence_number"] != float64(i+1) {
			t.Fatalf("event %d = %#v, want type=%s sequence=%d", i, event, wantTypes[i], i+1)
		}
	}
	completed := events[len(events)-1]["response"].(map[string]any)
	if completed["id"] != "resp_lifecycle" || completed["status"] != "completed" || completed["model"] != "public/native" || completed["metadata"].(map[string]any)["model"] != "user-model" {
		t.Fatalf("completed response = %#v", completed)
	}
	usage := completed["usage"].(map[string]any)
	if usage["input_tokens"] != float64(11) || usage["output_tokens"] != float64(7) || usage["total_tokens"] != float64(18) {
		t.Fatalf("usage = %#v", usage)
	}
	functionAdded := events[9]["item"].(map[string]any)
	functionDone := events[12]["item"].(map[string]any)
	if functionAdded["id"] != "fc_lifecycle" || functionAdded["call_id"] != "call_lifecycle" || functionAdded["model"] != "tool-model" || functionDone["arguments"] != `{"city":"Paris"}` || events[10]["delta"] != `{"city":"` || events[11]["arguments"] != `{"city":"Paris"}` {
		t.Fatalf("function lifecycle changed: added=%#v done=%#v delta=%#v args=%#v", functionAdded, functionDone, events[10], events[11])
	}
}

func writeNativeResponsesConfig(t *testing.T, baseURL, publicModel string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "providers.json")
	body := `{"providers":[{"id":"native","name":"Native","base_url":"` + baseURL + `","api_format":"openai_responses","credential_ref":{"kind":"env","value":"RELAYKIT_NATIVE_PROVIDER_TOKEN"},"models":[{"id":"` + publicModel + `","upstream_model":"native-upstream"}]}]}`
	if err := os.WriteFile(path, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
	return path
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

func openTestWebSocket(t *testing.T, serverURL, path string) (net.Conn, *bufio.Reader) {
	t.Helper()
	return openTestWebSocketWithHeaders(t, serverURL, path, nil)
}

func openTestWebSocketWithHeaders(t *testing.T, serverURL, path string, headers map[string]string) (net.Conn, *bufio.Reader) {
	t.Helper()
	parsed, err := url.Parse(serverURL)
	if err != nil {
		t.Fatal(err)
	}
	conn, err := net.Dial("tcp", parsed.Host)
	if err != nil {
		t.Fatal(err)
	}
	key := base64.StdEncoding.EncodeToString([]byte("relaykit-test-key"))
	if _, err := fmt.Fprintf(conn, "GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: %s\r\n", path, parsed.Host, key); err != nil {
		t.Fatal(err)
	}
	for name, value := range headers {
		if _, err := fmt.Fprintf(conn, "%s: %s\r\n", name, value); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := fmt.Fprint(conn, "\r\n"); err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(conn)
	status, err := reader.ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(status, "101") {
		t.Fatalf("websocket status = %s", status)
	}
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			t.Fatal(err)
		}
		if line == "\r\n" {
			break
		}
	}
	return conn, reader
}

func writeTestWebSocketText(t *testing.T, conn net.Conn, text string) {
	t.Helper()
	payload := []byte(text)
	frame := []byte{0x81}
	switch {
	case len(payload) < 126:
		frame = append(frame, byte(0x80|len(payload)))
	case len(payload) <= 65535:
		frame = append(frame, 0x80|126, byte(len(payload)>>8), byte(len(payload)))
	default:
		t.Fatalf("test payload too large")
	}
	mask := []byte{1, 2, 3, 4}
	frame = append(frame, mask...)
	for i, b := range payload {
		frame = append(frame, b^mask[i%4])
	}
	if _, err := conn.Write(frame); err != nil {
		t.Fatal(err)
	}
}

func writeTestWebSocketClose(t *testing.T, conn net.Conn) {
	t.Helper()
	if _, err := conn.Write([]byte{0x88, 0x80, 1, 2, 3, 4}); err != nil {
		t.Fatal(err)
	}
}

func readTestWebSocketUntil(t *testing.T, reader *bufio.Reader, needle string) string {
	t.Helper()
	var got strings.Builder
	for i := 0; i < 20; i++ {
		opcode, payload := readTestWebSocketFrame(t, reader)
		if opcode == 0x8 {
			t.Fatalf("websocket closed before %q; got %s", needle, got.String())
		}
		if opcode == 0x1 {
			got.Write(payload)
			if strings.Contains(got.String(), needle) {
				return got.String()
			}
		}
	}
	t.Fatalf("websocket never sent %q; got %s", needle, got.String())
	return ""
}

func readTestWebSocketFrame(t *testing.T, reader *bufio.Reader) (byte, []byte) {
	t.Helper()
	header, err := reader.ReadByte()
	if err != nil {
		t.Fatal(err)
	}
	lengthByte, err := reader.ReadByte()
	if err != nil {
		t.Fatal(err)
	}
	opcode := header & 0x0f
	length := int(lengthByte & 0x7f)
	switch length {
	case 126:
		extended := make([]byte, 2)
		if _, err := io.ReadFull(reader, extended); err != nil {
			t.Fatal(err)
		}
		length = int(extended[0])<<8 | int(extended[1])
	case 127:
		t.Fatalf("test websocket reader does not support 64-bit payload lengths")
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(reader, payload); err != nil {
		t.Fatal(err)
	}
	return opcode, payload
}
