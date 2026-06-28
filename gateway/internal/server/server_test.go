package server

import (
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
