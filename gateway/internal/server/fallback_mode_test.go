package server

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

func TestOfficialFallbackKeepsOfficialAndRejectsProviderWithoutCredential(t *testing.T) {
	var officialHits atomic.Int32
	official := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		officialHits.Add(1)
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, `{"id":"chatcmpl-official-fallback","model":"official-upstream","choices":[{"message":{"role":"assistant","content":"official fixture"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`)
	}))
	defer official.Close()

	var providerHits atomic.Int32
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		providerHits.Add(1)
		if r.Header.Get("Authorization") != "Bearer fixture-provider-token" {
			t.Fatalf("provider authorization header was not applied")
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, `{"id":"chatcmpl-provider","model":"provider-upstream","choices":[{"message":{"role":"assistant","content":"provider fixture"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`)
	}))
	defer provider.Close()

	handler := newFallbackModeTestServer(t, official.URL, provider.URL)
	assertResponsesStatus(t, handler, "provider-model", http.StatusOK)
	if providerHits.Load() != 1 {
		t.Fatalf("provider hits before fallback = %d", providerHits.Load())
	}

	handler.EnterFallbackOfficialOnly()
	handler.credentialMu.RLock()
	credentialCount := len(handler.keychainCredentials)
	handler.credentialMu.RUnlock()
	if credentialCount != 0 {
		t.Fatalf("provider credentials retained after fallback: %d", credentialCount)
	}
	models := httptest.NewRecorder()
	handler.ServeHTTP(models, httptest.NewRequest(http.MethodGet, "/v1/models", nil))
	if models.Code != http.StatusOK {
		t.Fatalf("fallback models status = %d", models.Code)
	}
	if providerHits.Load() != 1 {
		t.Fatalf("provider upstream was probed by fallback catalog: %d", providerHits.Load())
	}

	rec := assertResponsesStatus(t, handler, "provider-model", http.StatusConflict)
	if !strings.Contains(rec.Body.String(), `"type":"restart_codex_required"`) {
		t.Fatalf("provider fallback response = %s", rec.Body.String())
	}
	if providerHits.Load() != 1 {
		t.Fatalf("provider upstream was called during fallback: %d", providerHits.Load())
	}

	assertResponsesStatus(t, handler, "official-model", http.StatusOK)
	if officialHits.Load() != 1 {
		t.Fatalf("official hits during fallback = %d", officialHits.Load())
	}

	health := httptest.NewRecorder()
	handler.ServeHTTP(health, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if health.Code != http.StatusOK || !strings.Contains(health.Body.String(), `"mode":"official_fallback"`) {
		t.Fatalf("fallback health = %d %s", health.Code, health.Body.String())
	}

	handler.EnterManaged(map[string]string{"fixture.provider": "fixture-provider-token"})
	assertResponsesStatus(t, handler, "provider-model", http.StatusOK)
	if providerHits.Load() != 2 {
		t.Fatalf("provider route was not restored after adoption: %d", providerHits.Load())
	}
}

func TestOfficialFallbackRejectsProviderOverPersistentWebSocket(t *testing.T) {
	official := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, `{"id":"unused","choices":[]}`)
	}))
	defer official.Close()
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		t.Fatal("provider upstream must not be called during fallback")
	}))
	defer provider.Close()

	handler := newFallbackModeTestServer(t, official.URL, provider.URL)
	handler.EnterFallbackOfficialOnly()
	gateway := httptest.NewServer(handler)
	defer gateway.Close()

	conn, reader := openTestWebSocket(t, gateway.URL, "/v1/responses")
	defer conn.Close()
	writeTestWebSocketText(t, conn, `{"model":"provider-model","input":"fixture websocket"}`)
	got := readTestWebSocketUntil(t, reader, "response.failed")
	if !strings.Contains(got, `"type":"restart_codex_required"`) {
		t.Fatalf("provider WebSocket fallback response = %s", got)
	}
}

func TestAppOwnedFallbackAllowsProviderTestButNotProviderRoute(t *testing.T) {
	var providerHits atomic.Int32
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		providerHits.Add(1)
		if r.Header.Get("Authorization") != "Bearer fixture-provider-token" {
			t.Fatalf("provider authorization header was not applied")
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, `{"id":"resp_probe","object":"response","model":"native-upstream","status":"completed","output":[]}`)
	}))
	defer provider.Close()

	handler, err := NewWithUsageLogAndCredentials(
		writeProviderTestNativeConfig(t, provider.URL),
		"",
		map[string]string{"relaykit.test.snapshot": "fixture-provider-token"},
	)
	if err != nil {
		t.Fatal(err)
	}
	handler.EnterFallbackWithCredentials(map[string]string{"relaykit.test.snapshot": "fixture-provider-token"})

	route := assertResponsesStatus(t, handler, "public/native", http.StatusConflict)
	if !strings.Contains(route.Body.String(), `"type":"restart_codex_required"`) {
		t.Fatalf("provider route fallback response = %s", route.Body.String())
	}
	if providerHits.Load() != 0 {
		t.Fatalf("provider route reached upstream in fallback: %d", providerHits.Load())
	}

	testRequest := httptest.NewRequest(
		http.MethodPost,
		"/_relaykit/provider-test",
		strings.NewReader(`{"provider_id":"native","model_id":"public/native"}`),
	)
	testResponse := httptest.NewRecorder()
	handler.ServeHTTP(testResponse, testRequest)
	if testResponse.Code != http.StatusOK || providerHits.Load() != 1 {
		t.Fatalf("provider test in App-owned fallback = %d %s hits=%d", testResponse.Code, testResponse.Body.String(), providerHits.Load())
	}

	handler.EnterFallbackOfficialOnly()
	afterRelease := httptest.NewRecorder()
	handler.ServeHTTP(
		afterRelease,
		httptest.NewRequest(
			http.MethodPost,
			"/_relaykit/provider-test",
			strings.NewReader(`{"provider_id":"native","model_id":"public/native"}`),
		),
	)
	if afterRelease.Code != http.StatusConflict ||
		!strings.Contains(afterRelease.Body.String(), `"type":"restart_codex_required"`) ||
		providerHits.Load() != 1 {
		t.Fatalf("provider test after App release = %d %s hits=%d", afterRelease.Code, afterRelease.Body.String(), providerHits.Load())
	}
}

func newFallbackModeTestServer(t *testing.T, officialURL, providerURL string) *Server {
	t.Helper()
	dir := t.TempDir()
	officialKey := filepath.Join(dir, "official.key")
	if err := os.WriteFile(officialKey, []byte("fixture-official-token"), 0600); err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(dir, "providers.json")
	body := fmt.Sprintf(`{
		"official_passthrough": {
			"base_url": %q,
			"credential_ref": {"kind":"key_file","value":%q,"header":"Authorization"},
			"models": [{"id":"official-model","upstream_model":"official-upstream"}]
		},
		"providers": [{
			"id":"fixture-provider",
			"name":"Fixture Provider",
			"base_url":%q,
			"api_format":"openai_chat",
			"credential_ref":{"kind":"keychain","value":"fixture.provider"},
			"models":[{"id":"provider-model","upstream_model":"provider-upstream"}]
		}]
	}`, officialURL+"/v1", officialKey, providerURL+"/v1")
	if err := os.WriteFile(configPath, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
	handler, err := NewWithUsageLogAndCredentials(
		configPath,
		filepath.Join(dir, "usage.jsonl"),
		map[string]string{"fixture.provider": "fixture-provider-token"},
	)
	if err != nil {
		t.Fatal(err)
	}
	return handler
}

func assertResponsesStatus(t *testing.T, handler http.Handler, model string, expected int) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(
		http.MethodPost,
		"/v1/responses",
		strings.NewReader(fmt.Sprintf(`{"model":%q,"input":"fixture"}`, model)),
	)
	request.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != expected {
		t.Fatalf("%s response = %d %s, want %d", model, recorder.Code, recorder.Body.String(), expected)
	}
	return recorder
}
