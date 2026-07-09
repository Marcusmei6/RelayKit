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

func TestOfficialPassthroughCodexHomeRunsIsolatedCodexExec(t *testing.T) {
	const inboundToken = "desktop-request-token"
	var officialHits int

	officialUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		officialHits++
		t.Fatalf("official HTTP upstream must not be called for codex_home credentials")
	}))
	defer officialUpstream.Close()

	dir := t.TempDir()
	codexHome := filepath.Join(dir, "codex-home")
	if err := os.MkdirAll(codexHome, 0700); err != nil {
		t.Fatal(err)
	}
	recordPath := filepath.Join(dir, "codex-record.json")
	fakeCodex := filepath.Join(dir, "codex")
	fakeScript := `#!/bin/sh
set -eu
out=""
model=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then out="$arg"; fi
  if [ "$prev" = "-m" ]; then model="$arg"; fi
  prev="$arg"
done
cat >/dev/null
printf '%s\n' "OK" >"$out"
printf '{"home":"%s","codex_home":"%s","model":"%s","args":"%s"}\n' "$HOME" "$CODEX_HOME" "$model" "$*" >"$RELAYKIT_TEST_CODEX_RECORD"
`
	if err := os.WriteFile(fakeCodex, []byte(fakeScript), 0700); err != nil {
		t.Fatal(err)
	}

	cfgPath := filepath.Join(dir, "providers.json")
	cfgJSON := `{
  "official_passthrough": {
    "base_url": "` + officialUpstream.URL + `",
    "credential_ref": {"kind": "codex_home", "value": "` + codexHome + `"},
    "codex_binary": "` + fakeCodex + `",
    "models": [{"id": "gpt-5.5", "display_name": "GPT-5.5"}]
  },
  "providers": []
}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("RELAYKIT_TEST_CODEX_RECORD", recordPath)
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

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), `"model":"gpt-5.5"`) || !strings.Contains(rec.Body.String(), `"output_text":"OK"`) {
		t.Fatalf("response = %s", rec.Body.String())
	}
	if officialHits != 0 {
		t.Fatalf("official hits = %d, want 0", officialHits)
	}
	record, err := os.ReadFile(recordPath)
	if err != nil {
		t.Fatalf("read codex record err = %v", err)
	}
	if !strings.Contains(string(record), `"home":"`+filepath.Join(dir, "home")+`"`) || !strings.Contains(string(record), `"codex_home":"`+codexHome+`"`) || !strings.Contains(string(record), `"model":"gpt-5.5"`) || !strings.Contains(string(record), "--ignore-user-config") {
		t.Fatalf("codex record = %s", record)
	}
	raw, err := os.ReadFile(usagePath)
	if err != nil {
		t.Fatalf("read usage log err = %v", err)
	}
	if strings.Contains(string(raw), inboundToken) || strings.Contains(string(raw), codexHome) || strings.Contains(string(raw), fakeCodex) {
		t.Fatalf("usage log leaked official credential detail: %s", raw)
	}
	var event struct {
		ProviderID string `json:"provider_id"`
		Model      string `json:"model"`
		Transport  string `json:"transport"`
		Status     string `json:"status"`
		HTTPStatus int    `json:"http_status"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(raw), &event); err != nil {
		t.Fatalf("decode usage log err = %v; raw=%s", err, raw)
	}
	if event.ProviderID != "openai" || event.Model != "gpt-5.5" || event.Transport != "responses_http" || event.Status != "completed" || event.HTTPStatus != http.StatusOK {
		t.Fatalf("event = %+v", event)
	}
}

func TestOfficialPassthroughCodexHomeStreamsViaIsolatedCodexExec(t *testing.T) {
	const inboundToken = "desktop-request-token"
	var officialHits int

	officialUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		officialHits++
		t.Fatalf("official HTTP upstream must not be called for codex_home credentials")
	}))
	defer officialUpstream.Close()

	dir := t.TempDir()
	codexHome := filepath.Join(dir, "codex-home")
	if err := os.MkdirAll(codexHome, 0700); err != nil {
		t.Fatal(err)
	}
	recordPath := filepath.Join(dir, "codex-record.json")
	fakeCodex := filepath.Join(dir, "codex")
	fakeScript := `#!/bin/sh
set -eu
out=""
model=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then out="$arg"; fi
  if [ "$prev" = "-m" ]; then model="$arg"; fi
  prev="$arg"
done
cat >/dev/null
printf '%s\n' "OK" >"$out"
printf '{"home":"%s","codex_home":"%s","model":"%s","args":"%s"}\n' "$HOME" "$CODEX_HOME" "$model" "$*" >"$RELAYKIT_TEST_CODEX_RECORD"
`
	if err := os.WriteFile(fakeCodex, []byte(fakeScript), 0700); err != nil {
		t.Fatal(err)
	}

	cfgPath := filepath.Join(dir, "providers.json")
	cfgJSON := `{
  "official_passthrough": {
    "base_url": "` + officialUpstream.URL + `",
    "credential_ref": {"kind": "codex_home", "value": "` + codexHome + `"},
    "codex_binary": "` + fakeCodex + `",
    "models": [{"id": "gpt-5.5", "display_name": "GPT-5.5"}]
  },
  "providers": []
}`
	if err := os.WriteFile(cfgPath, []byte(cfgJSON), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("RELAYKIT_TEST_CODEX_RECORD", recordPath)
	usagePath := filepath.Join(dir, "usage.jsonl")
	h, err := NewWithUsageLog(cfgPath, usagePath)
	if err != nil {
		t.Fatalf("New err = %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(`{"model":"gpt-5.5","input":"reply OK","stream":true}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+inboundToken)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	if got := rec.Header().Get("Content-Type"); !strings.Contains(got, "text/event-stream") {
		t.Fatalf("content type = %q", got)
	}
	body := rec.Body.String()
	for _, want := range []string{
		"event: response.created",
		"event: response.output_item.added",
		"event: response.output_text.delta",
		`"delta":"OK"`,
		"event: response.completed",
		`"model":"gpt-5.5"`,
		`"output_text":"OK"`,
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("stream response missing %q in %s", want, body)
		}
	}
	if officialHits != 0 {
		t.Fatalf("official hits = %d, want 0", officialHits)
	}
	record, err := os.ReadFile(recordPath)
	if err != nil {
		t.Fatalf("read codex record err = %v", err)
	}
	if !strings.Contains(string(record), `"model":"gpt-5.5"`) || !strings.Contains(string(record), "--ignore-user-config") {
		t.Fatalf("codex record = %s", record)
	}
	raw, err := os.ReadFile(usagePath)
	if err != nil {
		t.Fatalf("read usage log err = %v", err)
	}
	if strings.Contains(string(raw), inboundToken) || strings.Contains(string(raw), codexHome) || strings.Contains(string(raw), fakeCodex) {
		t.Fatalf("usage log leaked official credential detail: %s", raw)
	}
	var event struct {
		ProviderID string `json:"provider_id"`
		Model      string `json:"model"`
		Transport  string `json:"transport"`
		Streaming  bool   `json:"streaming"`
		Status     string `json:"status"`
		HTTPStatus int    `json:"http_status"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(raw), &event); err != nil {
		t.Fatalf("decode usage log err = %v; raw=%s", err, raw)
	}
	if event.ProviderID != "openai" || event.Model != "gpt-5.5" || event.Transport != "responses_http" || !event.Streaming || event.Status != "completed" || event.HTTPStatus != http.StatusOK {
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
