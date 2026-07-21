package server

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestOfficialCodexHomeProxiesNativeResponsesWithOAuth(t *testing.T) {
	const accessToken = "test-access-token"
	const accountID = "test-account-id"
	var hits int
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		if r.Method != http.MethodPost || r.URL.Path != "/responses" {
			t.Fatalf("official request = %s %s", r.Method, r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer "+accessToken {
			t.Fatalf("Authorization = %q", got)
		}
		if got := r.Header.Get("ChatGPT-Account-Id"); got != accountID {
			t.Fatalf("ChatGPT-Account-Id = %q", got)
		}
		if got := r.Header.Get("OpenAI-Beta"); got != "responses=experimental" {
			t.Fatalf("OpenAI-Beta = %q", got)
		}
		if got := r.Header.Get("x-codex-installation-id"); got != "installation-test" {
			t.Fatalf("x-codex-installation-id = %q", got)
		}
		if got := r.Header.Get("Cookie"); got != "" {
			t.Fatalf("Cookie was forwarded: %q", got)
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		if body["model"] != "official-upstream" || body["input"] != "reply OK" {
			t.Fatalf("official body = %#v", body)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, `{"id":"resp_official","object":"response","model":"official-upstream","status":"completed","output":[],"usage":{"input_tokens":2,"output_tokens":3,"total_tokens":5}}`)
	}))
	defer upstream.Close()

	h, _ := newOfficialCodexHomeTestHandler(t, upstream.URL, accessToken, accountID)
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(`{"model":"public-official","input":"reply OK"}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer desktop-token-must-not-pass")
	req.Header.Set("OpenAI-Beta", "responses=experimental")
	req.Header.Set("x-codex-installation-id", "installation-test")
	req.Header.Set("Cookie", "desktop-cookie-must-not-pass")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK || hits != 1 {
		t.Fatalf("response = %d %s; hits=%d", rec.Code, rec.Body.String(), hits)
	}
	if !strings.Contains(rec.Body.String(), `"model":"public-official"`) {
		t.Fatalf("public model was not restored: %s", rec.Body.String())
	}
	for _, secret := range []string{accessToken, accountID, "desktop-token-must-not-pass", "desktop-cookie-must-not-pass"} {
		if strings.Contains(rec.Body.String(), secret) {
			t.Fatalf("response leaked %q: %s", secret, rec.Body.String())
		}
	}
}

func TestOfficialCodexHomeProxiesCompactionEndpoint(t *testing.T) {
	var hits int
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		if r.Method != http.MethodPost || r.URL.Path != "/responses/compact" {
			t.Fatalf("compact request = %s %s", r.Method, r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, `{"id":"resp_compact","object":"response","model":"official-upstream","status":"completed","output":[{"id":"cmp_1","type":"compaction","encrypted_content":"opaque-test-value"}]}`)
	}))
	defer upstream.Close()

	h, authPath := newOfficialCodexHomeTestHandler(t, upstream.URL, "test-access-token", "test-account-id")
	req := httptest.NewRequest(http.MethodPost, "/v1/responses/compact", strings.NewReader(`{"model":"public-official","input":[{"role":"user","content":"compact me"}]}`))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK || hits != 1 {
		t.Fatalf("response = %d %s; hits=%d", rec.Code, rec.Body.String(), hits)
	}
	if !strings.Contains(rec.Body.String(), `"type":"compaction"`) || !strings.Contains(rec.Body.String(), `"model":"public-official"`) {
		t.Fatalf("invalid compact response: %s", rec.Body.String())
	}
	usage, err := os.ReadFile(filepath.Join(filepath.Dir(filepath.Dir(authPath)), "usage.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(usage), `"route":"/v1/responses/compact"`) {
		t.Fatalf("compact usage route = %s", usage)
	}
}

func TestOfficialCodexHomeStreamsNativeResponsesOverHTTPAndWebSocket(t *testing.T) {
	var hits int
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		if body["model"] != "official-upstream" || body["stream"] != true {
			t.Fatalf("stream body = %#v", body)
		}
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = fmt.Fprint(w, "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_stream\",\"object\":\"response\",\"model\":\"official-upstream\",\"status\":\"in_progress\",\"output\":[]}}\n\n")
		_, _ = fmt.Fprint(w, "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"OK\"}\n\n")
		_, _ = fmt.Fprint(w, "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_stream\",\"object\":\"response\",\"model\":\"official-upstream\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"total_tokens\":2}}}\n\n")
	}))
	defer upstream.Close()

	h, _ := newOfficialCodexHomeTestHandler(t, upstream.URL, "test-access-token", "test-account-id")
	httpReq := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(`{"model":"public-official","input":"stream","stream":true}`))
	httpReq.Header.Set("Content-Type", "application/json")
	httpRec := httptest.NewRecorder()
	h.ServeHTTP(httpRec, httpReq)
	if httpRec.Code != http.StatusOK || !strings.Contains(httpRec.Body.String(), `"model":"public-official"`) || !strings.Contains(httpRec.Body.String(), `"delta":"OK"`) {
		t.Fatalf("HTTP stream = %d %s", httpRec.Code, httpRec.Body.String())
	}

	gateway := httptest.NewServer(h)
	defer gateway.Close()
	conn, reader := openTestWebSocket(t, gateway.URL, "/v1/responses")
	defer conn.Close()
	writeTestWebSocketText(t, conn, `{"model":"public-official","input":"stream"}`)
	got := readTestWebSocketUntil(t, reader, "response.completed")
	if !strings.Contains(got, `"model":"public-official"`) || !strings.Contains(got, `"delta":"OK"`) {
		t.Fatalf("WebSocket stream = %s", got)
	}
	if hits != 2 {
		t.Fatalf("upstream hits = %d, want 2", hits)
	}
}

func TestOfficialCodexHomeRefreshesAfterUnauthorizedAndRetriesOnce(t *testing.T) {
	const oldAccess = "test-old-access"
	const newAccess = "test-new-access"
	const oldRefresh = "test-old-refresh"
	const newRefresh = "test-new-refresh"
	var upstreamHits int
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		upstreamHits++
		switch r.Header.Get("Authorization") {
		case "Bearer " + oldAccess:
			w.WriteHeader(http.StatusUnauthorized)
		case "Bearer " + newAccess:
			w.Header().Set("Content-Type", "application/json")
			_, _ = fmt.Fprint(w, `{"id":"resp_refreshed","object":"response","status":"completed","output":[]}`)
		default:
			t.Fatalf("unexpected Authorization %q", r.Header.Get("Authorization"))
		}
	}))
	defer upstream.Close()

	var refreshHits int
	originalTransport := http.DefaultTransport
	http.DefaultTransport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Scheme == "https" && r.URL.Host == "auth.openai.com" && r.URL.Path == "/oauth/token" {
			refreshHits++
			if err := r.ParseForm(); err != nil {
				t.Fatal(err)
			}
			if r.Form.Get("grant_type") != "refresh_token" || r.Form.Get("refresh_token") != oldRefresh || r.Form.Get("client_id") != "app_EMoamEEZ73f0CkXaXp7hrann" {
				t.Fatalf("refresh form = %#v", r.Form)
			}
			return &http.Response{
				StatusCode: http.StatusOK,
				Header:     http.Header{"Content-Type": []string{"application/json"}},
				Body:       io.NopCloser(strings.NewReader(`{"access_token":"` + newAccess + `","refresh_token":"` + newRefresh + `","id_token":"test-new-id-token"}`)),
				Request:    r,
			}, nil
		}
		return originalTransport.RoundTrip(r)
	})
	defer func() { http.DefaultTransport = originalTransport }()

	h, authPath := newOfficialCodexHomeTestHandler(t, upstream.URL, oldAccess, "test-account-id")
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(`{"model":"public-official","input":"retry"}`))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK || upstreamHits != 2 || refreshHits != 1 {
		t.Fatalf("response=%d %s upstreamHits=%d refreshHits=%d", rec.Code, rec.Body.String(), upstreamHits, refreshHits)
	}
	stored, err := os.ReadFile(authPath)
	if err != nil {
		t.Fatal(err)
	}
	var auth map[string]any
	if err := json.Unmarshal(stored, &auth); err != nil {
		t.Fatal(err)
	}
	tokens := auth["tokens"].(map[string]any)
	if tokens["access_token"] != newAccess || tokens["refresh_token"] != newRefresh || tokens["id_token"] != "test-new-id-token" || tokens["account_id"] != "test-account-id" {
		t.Fatalf("stored tokens were not updated safely: %#v", tokens)
	}
	if _, ok := auth["future_field"]; !ok {
		t.Fatalf("unknown auth field was dropped: %#v", auth)
	}
	for _, secret := range []string{oldAccess, newAccess, oldRefresh, newRefresh} {
		if strings.Contains(rec.Body.String(), secret) {
			t.Fatalf("response leaked %q: %s", secret, rec.Body.String())
		}
	}
}

func TestOfficialCodexHomeDoesNotOverwriteConcurrentAuthRefresh(t *testing.T) {
	const staleAccess = "test-stale-access"
	const externalAccess = "test-external-access"
	var upstreamHits int
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		upstreamHits++
		switch r.Header.Get("Authorization") {
		case "Bearer " + staleAccess:
			w.WriteHeader(http.StatusUnauthorized)
		case "Bearer " + externalAccess:
			w.Header().Set("Content-Type", "application/json")
			_, _ = fmt.Fprint(w, `{"id":"resp_external_refresh","object":"response","status":"completed","output":[]}`)
		default:
			w.WriteHeader(http.StatusForbidden)
		}
	}))
	defer upstream.Close()

	h, authPath := newOfficialCodexHomeTestHandler(t, upstream.URL, staleAccess, "test-account-id")
	var refreshHits int
	originalTransport := http.DefaultTransport
	http.DefaultTransport = roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Scheme == "https" && r.URL.Host == "auth.openai.com" && r.URL.Path == "/oauth/token" {
			refreshHits++
			stored, err := os.ReadFile(authPath)
			if err != nil {
				t.Fatal(err)
			}
			var auth map[string]any
			if err := json.Unmarshal(stored, &auth); err != nil {
				t.Fatal(err)
			}
			tokens := auth["tokens"].(map[string]any)
			tokens["access_token"] = externalAccess
			tokens["refresh_token"] = "test-external-refresh"
			auth["future_field"] = map[string]bool{"external": true}
			updated, err := json.Marshal(auth)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(authPath, updated, 0600); err != nil {
				t.Fatal(err)
			}
			return &http.Response{
				StatusCode: http.StatusOK,
				Header:     http.Header{"Content-Type": []string{"application/json"}},
				Body:       io.NopCloser(strings.NewReader(`{"access_token":"test-losing-access","refresh_token":"test-losing-refresh"}`)),
				Request:    r,
			}, nil
		}
		return originalTransport.RoundTrip(r)
	})
	defer func() { http.DefaultTransport = originalTransport }()

	req := httptest.NewRequest(http.MethodPost, "/v1/responses", strings.NewReader(`{"model":"public-official","input":"concurrent refresh"}`))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || upstreamHits != 2 || refreshHits != 1 {
		t.Fatalf("response=%d %s upstreamHits=%d refreshHits=%d", rec.Code, rec.Body.String(), upstreamHits, refreshHits)
	}
	stored, err := os.ReadFile(authPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(stored), externalAccess) || !strings.Contains(string(stored), "test-external-refresh") || !strings.Contains(string(stored), `"external":true`) {
		t.Fatalf("concurrent auth update was overwritten: %s", stored)
	}
}

func TestWriteOfficialCodexAuthRejectsChangedSnapshot(t *testing.T) {
	path := filepath.Join(t.TempDir(), "auth.json")
	expected := []byte(`{"state":"expected"}`)
	external := []byte(`{"state":"external"}`)
	if err := os.WriteFile(path, expected, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, external, 0600); err != nil {
		t.Fatal(err)
	}
	written, err := writeOfficialCodexAuth(path, expected, []byte(`{"state":"relaykit"}`))
	if err != nil {
		t.Fatal(err)
	}
	if written {
		t.Fatal("changed auth snapshot was overwritten")
	}
	stored, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(stored) != string(external) {
		t.Fatalf("stored auth = %s", stored)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) {
	return f(r)
}

func newOfficialCodexHomeTestHandler(t *testing.T, baseURL, accessToken, accountID string) (http.Handler, string) {
	t.Helper()
	dir := t.TempDir()
	codexHome := filepath.Join(dir, "codex-home")
	if err := os.MkdirAll(codexHome, 0700); err != nil {
		t.Fatal(err)
	}
	auth := map[string]any{
		"auth_mode":    "chatgpt",
		"future_field": map[string]bool{"keep": true},
		"last_refresh": "2026-07-21T00:00:00Z",
		"tokens": map[string]string{
			"access_token":  accessToken,
			"refresh_token": "test-old-refresh",
			"account_id":    accountID,
			"id_token":      "test-id-token",
		},
	}
	authBody, err := json.Marshal(auth)
	if err != nil {
		t.Fatal(err)
	}
	authPath := filepath.Join(codexHome, "auth.json")
	if err := os.WriteFile(authPath, authBody, 0600); err != nil {
		t.Fatal(err)
	}
	cfg := map[string]any{
		"official_passthrough": map[string]any{
			"base_url": "https://chatgpt.com/backend-api/codex",
			"credential_ref": map[string]string{
				"kind":  "codex_home",
				"value": codexHome,
			},
			"codex_binary": "/usr/bin/false",
			"models": []map[string]string{{
				"id":             "public-official",
				"upstream_model": "official-upstream",
			}},
		},
		"providers": []any{},
	}
	cfgBody, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	cfgPath := filepath.Join(dir, "providers.json")
	if err := os.WriteFile(cfgPath, cfgBody, 0600); err != nil {
		t.Fatal(err)
	}
	h, err := newServerWithOfficialEndpoint(cfgPath, filepath.Join(dir, "usage.jsonl"), nil, true, baseURL)
	if err != nil {
		t.Fatal(err)
	}
	return h, authPath
}
