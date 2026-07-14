package server

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestProviderTestRejectsAmbiguousOrSensitiveRequestBeforeUpstream(t *testing.T) {
	var upstreamHits atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		upstreamHits.Add(1)
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, `{"id":"resp_unexpected","object":"response","status":"completed","output":[]}`)
	}))
	defer upstream.Close()

	h, err := NewWithUsageLogAndCredentials(writeProviderTestNativeConfig(t, upstream.URL), "", map[string]string{"relaykit.test.snapshot": "snapshot-token"})
	if err != nil {
		t.Fatal(err)
	}
	for _, body := range []string{
		`{"provider_id":"native","provider_id":"other","model_id":"public/native"}`,
		`{"provider_id":"native","model_id":"public/native","model_id":"other"}`,
		`{"provider_id":"native","model_id":"public/native"} {}`,
		`{"provider_id":"native","model_id":"public/native","token":"RELAYKIT_FAKE_SENTINEL_DO_NOT_USE"}`,
		`{"provider_id":"native","model_id":"public/native","base_url":"https://example.test"}`,
		`{"provider_id":"native","model_id":"public/native","body":{"input":"RELAYKIT_FAKE_SENTINEL_DO_NOT_USE"}}`,
	} {
		t.Run(body, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/_relaykit/provider-test", strings.NewReader(body))
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), `"type":"invalid_request_error"`) {
				t.Fatalf("response = %d %s", rec.Code, rec.Body.String())
			}
			if strings.Contains(rec.Body.String(), "RELAYKIT_FAKE_SENTINEL_DO_NOT_USE") {
				t.Fatalf("response leaked request content: %s", rec.Body.String())
			}
		})
	}
	if got := upstreamHits.Load(); got != 0 {
		t.Fatalf("upstream calls = %d, want 0", got)
	}
}

func TestProviderTestUsesSnapshotCredentialAndSanitizesResult(t *testing.T) {
	var gotBody map[string]any
	var gotAuthorization string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuthorization = r.Header.Get("Authorization")
		if err := json.NewDecoder(r.Body).Decode(&gotBody); err != nil {
			t.Fatal(err)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, `{"id":"resp_probe","object":"response","model":"native-upstream","status":"completed","output":[]}`)
	}))
	defer upstream.Close()

	h, err := NewWithUsageLogAndCredentials(writeProviderTestNativeConfig(t, upstream.URL), "", map[string]string{"relaykit.test.snapshot": "snapshot-token"})
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/_relaykit/provider-test", strings.NewReader(`{"provider_id":"native","model_id":"public/native"}`))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("response = %d %s", rec.Code, rec.Body.String())
	}
	if gotAuthorization != "Bearer snapshot-token" {
		t.Fatalf("authorization = %q", gotAuthorization)
	}
	if gotBody["model"] != "native-upstream" || gotBody["input"] != "Return a tiny reachability confirmation." || gotBody["max_output_tokens"] != float64(1) || len(gotBody) != 3 {
		t.Fatalf("probe body = %#v", gotBody)
	}
	var result struct {
		ProviderID string `json:"provider_id"`
		ModelID    string `json:"model_id"`
		Status     string `json:"status"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result != (struct {
		ProviderID string `json:"provider_id"`
		ModelID    string `json:"model_id"`
		Status     string `json:"status"`
	}{ProviderID: "native", ModelID: "public/native", Status: "ok"}) {
		t.Fatalf("result = %#v", result)
	}
	for _, forbidden := range []string{"snapshot-token", "native-upstream", upstream.URL, "resp_probe"} {
		if strings.Contains(rec.Body.String(), forbidden) {
			t.Fatalf("result leaked %q: %s", forbidden, rec.Body.String())
		}
	}
}

func TestProviderTestPostsNativeResponsesExactlyOnce(t *testing.T) {
	cases := []struct {
		name      string
		handler   http.HandlerFunc
		want      int
		wantError string
	}{
		{"success", nativeProviderTestResponse(http.StatusOK, "application/json", `{"id":"resp_ok","object":"response","status":"completed","output":[]}`), http.StatusOK, ""},
		{"unauthorized", nativeProviderTestResponse(http.StatusUnauthorized, "application/json", `{"error":"RELAYKIT_FAKE_SENTINEL_DO_NOT_USE"}`), http.StatusBadGateway, "auth_failed"},
		{"forbidden", nativeProviderTestResponse(http.StatusForbidden, "application/json", `{"error":"RELAYKIT_FAKE_SENTINEL_DO_NOT_USE"}`), http.StatusBadGateway, "auth_failed"},
		{"invalid upstream request", nativeProviderTestResponse(http.StatusBadRequest, "application/json", `{"error":"RELAYKIT_FAKE_SENTINEL_DO_NOT_USE"}`), http.StatusBadRequest, "responses_unavailable"},
		{"rate limited", nativeProviderTestResponse(http.StatusTooManyRequests, "application/json", `{"error":"RELAYKIT_FAKE_SENTINEL_DO_NOT_USE"}`), http.StatusTooManyRequests, "responses_unavailable"},
		{"unavailable", nativeProviderTestResponse(http.StatusServiceUnavailable, "application/json", `{"error":"RELAYKIT_FAKE_SENTINEL_DO_NOT_USE"}`), http.StatusServiceUnavailable, "responses_unavailable"},
		{"upstream error", nativeProviderTestResponse(http.StatusInternalServerError, "application/json", `{"error":"RELAYKIT_FAKE_SENTINEL_DO_NOT_USE"}`), http.StatusBadGateway, "responses_unavailable"},
		{"invalid JSON response", nativeProviderTestResponse(http.StatusOK, "application/json", `{"id":`), http.StatusBadGateway, "responses_unavailable"},
		{"invalid response media", nativeProviderTestResponse(http.StatusOK, "text/html", `RELAYKIT_FAKE_SENTINEL_DO_NOT_USE`), http.StatusBadGateway, "responses_unavailable"},
		{"lost response", func(w http.ResponseWriter, r *http.Request) {
			hijacker, ok := w.(http.Hijacker)
			if !ok {
				t.Fatal("response writer cannot hijack")
			}
			conn, _, err := hijacker.Hijack()
			if err != nil {
				t.Fatal(err)
			}
			_ = conn.Close()
		}, http.StatusBadGateway, "network_failed"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var posts atomic.Int32
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method == http.MethodPost {
					posts.Add(1)
				}
				tc.handler(w, r)
			}))
			defer upstream.Close()
			h, err := NewWithUsageLogAndCredentials(writeProviderTestNativeConfig(t, upstream.URL), "", map[string]string{"relaykit.test.snapshot": "snapshot-token"})
			if err != nil {
				t.Fatal(err)
			}
			req := httptest.NewRequest(http.MethodPost, "/_relaykit/provider-test", strings.NewReader(`{"provider_id":"native","model_id":"public/native"}`))
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			if rec.Code != tc.want || posts.Load() != 1 || providerTestResultError(t, rec) != tc.wantError {
				t.Fatalf("response=%d %s posts=%d", rec.Code, rec.Body.String(), posts.Load())
			}
			if strings.Contains(rec.Body.String(), "RELAYKIT_FAKE_SENTINEL_DO_NOT_USE") {
				t.Fatalf("response leaked upstream content: %s", rec.Body.String())
			}
		})
	}

	t.Run("timeout", func(t *testing.T) {
		started := make(chan struct{})
		var posts atomic.Int32
		upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			posts.Add(1)
			close(started)
			time.Sleep(200 * time.Millisecond)
			w.Header().Set("Content-Type", "application/json")
			_, _ = fmt.Fprint(w, `{"id":"resp_late","object":"response","status":"completed","output":[]}`)
		}))
		defer upstream.Close()
		h, err := NewWithUsageLogAndCredentials(writeProviderTestNativeConfig(t, upstream.URL), "", map[string]string{"relaykit.test.snapshot": "snapshot-token"})
		if err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
		defer cancel()
		req := httptest.NewRequest(http.MethodPost, "/_relaykit/provider-test", strings.NewReader(`{"provider_id":"native","model_id":"public/native"}`)).WithContext(ctx)
		rec := httptest.NewRecorder()
		done := make(chan struct{})
		go func() {
			h.ServeHTTP(rec, req)
			close(done)
		}()
		select {
		case <-started:
		case <-time.After(time.Second):
			t.Fatal("upstream POST did not start")
		}
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Fatal("provider test did not stop after timeout")
		}
		if rec.Code != http.StatusBadGateway || posts.Load() != 1 || providerTestResultError(t, rec) != "network_failed" {
			t.Fatalf("response=%d %s posts=%d", rec.Code, rec.Body.String(), posts.Load())
		}
	})
}

func TestProviderTestMapsCredentialAndLocalFailures(t *testing.T) {
	t.Run("missing snapshot credential", func(t *testing.T) {
		var posts atomic.Int32
		upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			posts.Add(1)
		}))
		defer upstream.Close()
		h, err := NewWithUsageLogAndCredentials(writeProviderTestNativeConfig(t, upstream.URL), "", nil)
		if err != nil {
			t.Fatal(err)
		}
		req := httptest.NewRequest(http.MethodPost, "/_relaykit/provider-test", strings.NewReader(`{"provider_id":"native","model_id":"public/native"}`))
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != http.StatusBadGateway || providerTestResultError(t, rec) != "auth_failed" || posts.Load() != 0 {
			t.Fatalf("response=%d %s posts=%d", rec.Code, rec.Body.String(), posts.Load())
		}
	})

	for _, tc := range []struct {
		name       string
		apiFormat  string
		providerID string
		modelID    string
		wantError  string
	}{
		{"unknown model", "openai_responses", "native", "missing", "unknown_model"},
		{"unsupported format", "openai_chat", "native", "public/native", "unsupported_provider_format"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var posts atomic.Int32
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				posts.Add(1)
			}))
			defer upstream.Close()
			h, err := NewWithUsageLogAndCredentials(writeProviderTestConfig(t, upstream.URL, tc.apiFormat), "", map[string]string{"relaykit.test.snapshot": "snapshot-token"})
			if err != nil {
				t.Fatal(err)
			}
			body := fmt.Sprintf(`{"provider_id":%q,"model_id":%q}`, tc.providerID, tc.modelID)
			req := httptest.NewRequest(http.MethodPost, "/_relaykit/provider-test", strings.NewReader(body))
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			if rec.Code != http.StatusBadRequest || providerTestResultError(t, rec) != tc.wantError || posts.Load() != 0 {
				t.Fatalf("response=%d %s posts=%d", rec.Code, rec.Body.String(), posts.Load())
			}
		})
	}
}

func TestResponsesRejectsEveryDuplicateTopLevelNativeRequest(t *testing.T) {
	var upstreamHits atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		upstreamHits.Add(1)
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, `{"id":"resp_unexpected","object":"response","status":"completed","output":[]}`)
	}))
	defer upstream.Close()
	h, err := New(writeNativeResponsesConfig(t, upstream.URL, "public/native"))
	if err != nil {
		t.Fatal(err)
	}
	for _, body := range []string{
		`{"model":"public/native","input":"first","input":"second"}`,
		`{"model":"public/native","input":"x","tools":[],"tools":[]}`,
		`{"model":"public/native","input":"x","metadata":{},"metadata":{}}`,
		`{"model":"public/native","model":"other","input":"x"}`,
		`{"model":"public/native","input":"x","stream":false,"stream":true}`,
		`{"model":"public/native","input":"x","future":1,"future":2}`,
	} {
		t.Run(body, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(body))
			req.Header.Set("Content-Type", "application/json")
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), `"type":"invalid_request_error"`) {
				t.Fatalf("response = %d %s", rec.Code, rec.Body.String())
			}
		})
	}
	if got := upstreamHits.Load(); got != 0 {
		t.Fatalf("upstream calls = %d, want 0", got)
	}
}

func TestNativeResponsesWebSocketRejectsDuplicateEnvelopeOrResponseFields(t *testing.T) {
	var upstreamHits atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		upstreamHits.Add(1)
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = fmt.Fprint(w, "event: response.completed\\ndata: {\\\"type\\\":\\\"response.completed\\\",\\\"response\\\":{\\\"id\\\":\\\"resp_unexpected\\\",\\\"object\\\":\\\"response\\\",\\\"status\\\":\\\"completed\\\",\\\"output\\\":[]}}\\n\\n")
	}))
	defer upstream.Close()
	h, err := New(writeNativeResponsesConfig(t, upstream.URL, "public/native"))
	if err != nil {
		t.Fatal(err)
	}
	for _, payload := range []string{
		`{"model":"public/native","input":"first","input":"second"}`,
		`{"type":"response.create","type":"response.create","response":{"model":"public/native","input":"x"}}`,
		`{"type":"response.create","response":{"model":"public/native","input":"first","input":"second"}}`,
		`{"type":"response.create","response":{"model":"public/native","input":"x","metadata":{},"metadata":{}}}`,
	} {
		t.Run(payload, func(t *testing.T) {
			srv := httptest.NewServer(h)
			defer srv.Close()
			conn, reader := openTestWebSocket(t, srv.URL, "/v1/responses")
			defer conn.Close()
			writeTestWebSocketText(t, conn, payload)
			events := readNativeWebSocketAllEvents(t, reader)
			if len(events) != 1 || events[0]["type"] != "response.error" || events[0]["error"].(map[string]any)["type"] != "protocol_error" {
				t.Fatalf("events = %#v", events)
			}
		})
	}
	if got := upstreamHits.Load(); got != 0 {
		t.Fatalf("upstream calls = %d, want 0", got)
	}
}

func TestNativeResponsesNonStreamingRejectsDuplicateTopLevelUpstreamResponse(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, `{"id":"resp_first","id":"resp_second","object":"response","status":"completed","output":[]}`)
	}))
	defer upstream.Close()
	h, err := New(writeNativeResponsesConfig(t, upstream.URL, "public/native"))
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(`{"model":"public/native","input":"x"}`))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadGateway || !strings.Contains(rec.Body.String(), `"type":"protocol_error"`) {
		t.Fatalf("response = %d %s", rec.Code, rec.Body.String())
	}
}

func TestNativeOpenAIResponsesCatalogProbeDoesNotRetryPost(t *testing.T) {
	var getHits, postHits atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			getHits.Add(1)
			w.Header().Set("Content-Type", "application/json")
			_, _ = fmt.Fprint(w, `{"data":[{"id":"native-upstream"}]}`)
		case http.MethodPost:
			postHits.Add(1)
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = fmt.Fprint(w, `{"error":"unavailable"}`)
		default:
			t.Fatalf("method = %s", r.Method)
		}
	}))
	defer upstream.Close()
	configPath := writeProviderTestNativeConfig(t, upstream.URL)
	h, err := NewWithUsageLogAndCredentials(configPath, "", map[string]string{"relaykit.test.snapshot": "snapshot-token"})
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || getHits.Load() != 1 || postHits.Load() != 1 {
		t.Fatalf("response=%d %s get=%d post=%d", rec.Code, rec.Body.String(), getHits.Load(), postHits.Load())
	}
}

func nativeProviderTestResponse(status int, contentType, body string) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", contentType)
		w.WriteHeader(status)
		_, _ = fmt.Fprint(w, body)
	}
}

func writeProviderTestNativeConfig(t *testing.T, baseURL string) string {
	t.Helper()
	return writeProviderTestConfig(t, baseURL, "openai_responses")
}

func writeProviderTestConfig(t *testing.T, baseURL, apiFormat string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "providers.json")
	body := `{"providers":[{"id":"native","name":"Native","base_url":"` + baseURL + `","api_format":"` + apiFormat + `","credential_ref":{"kind":"keychain","value":"relaykit.test.snapshot"},"models":[{"id":"public/native","upstream_model":"native-upstream"}]}]}`
	if err := os.WriteFile(path, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
	return path
}

func providerTestResultError(t *testing.T, rec *httptest.ResponseRecorder) string {
	t.Helper()
	var result providerTestResult
	if err := json.Unmarshal(rec.Body.Bytes(), &result); err != nil {
		t.Fatalf("decode provider test result: %v: %s", err, rec.Body.String())
	}
	if result.Error == nil {
		return ""
	}
	return result.Error.Type
}
