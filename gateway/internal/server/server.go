package server

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"relaykit/gateway/internal/config"
)

type Server struct {
	config *config.Config
	client *http.Client
}

func New(configPath string) (http.Handler, error) {
	s := &Server{client: http.DefaultClient}
	if configPath != "" {
		cfg, err := config.Load(configPath)
		if err != nil {
			return nil, err
		}
		s.config = cfg
	}
	if s.config == nil {
		s.config = &config.Config{
			Providers: []config.ProviderProfile{{
				ID:        "relaykit",
				Name:      "RelayKit Demo",
				BaseURL:   "http://127.0.0.1:11434/v1",
				APIFormat: config.APIFormatOpenAIChat,
				Models:    []config.Model{{ID: "relaykit-demo"}},
			}},
		}
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.healthz)
	mux.HandleFunc("GET /v1/models", s.models)
	mux.HandleFunc("POST /v1/responses", s.responses)
	return mux, nil
}

func (s *Server) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{
		"status": "ok",
	})
}

func (s *Server) models(w http.ResponseWriter, _ *http.Request) {
	var data []map[string]any
	for _, p := range s.config.Providers {
		for _, m := range p.Models {
			data = append(data, map[string]any{
				"id":       m.ID,
				"object":   "model",
				"created":  int64(0),
				"owned_by": p.ID,
			})
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"object": "list",
		"data":   data,
	})
}

func (s *Server) responses(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("Content-Type") == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"error": map[string]string{
				"message": "Content-Type is required",
				"type":    "invalid_request_error",
			},
		})
		return
	}

	var req responsesRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorBody("invalid_request_error", err.Error()))
		return
	}
	provider, ok := s.providerForModel(req.Model)
	if !ok {
		writeJSON(w, http.StatusBadRequest, errorBody("invalid_request_error", "unknown model"))
		return
	}
	messages, err := chatMessages(req.Input)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorBody("invalid_request_error", err.Error()))
		return
	}

	upstreamReq := map[string]any{
		"model":    req.Model,
		"messages": messages,
		"stream":   false,
	}
	payload, err := json.Marshal(upstreamReq)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorBody("server_error", err.Error()))
		return
	}

	upstreamURL, err := url.JoinPath(provider.BaseURL, "chat/completions")
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorBody("server_error", err.Error()))
		return
	}
	httpReq, err := http.NewRequestWithContext(r.Context(), http.MethodPost, upstreamURL, bytes.NewReader(payload))
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorBody("server_error", err.Error()))
		return
	}
	httpReq.Header.Set("Content-Type", "application/json")
	if provider.AuthEnv != "" {
		if token := os.Getenv(provider.AuthEnv); token != "" {
			httpReq.Header.Set("Authorization", "Bearer "+token)
		}
	}

	resp, err := s.client.Do(httpReq)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, errorBody("upstream_error", err.Error()))
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		body, readErr := io.ReadAll(io.LimitReader(resp.Body, 1024))
		if readErr != nil {
			writeJSON(w, http.StatusBadGateway, errorBody("upstream_error", readErr.Error()))
			return
		}
		writeJSON(w, http.StatusBadGateway, errorBody("upstream_error", string(body)))
		return
	}

	var chat chatResponse
	if err := json.NewDecoder(resp.Body).Decode(&chat); err != nil {
		writeJSON(w, http.StatusBadGateway, errorBody("upstream_error", err.Error()))
		return
	}
	writeJSON(w, http.StatusOK, responsesFromChat(chat, req.Model))
}

func (s *Server) providerForModel(model string) (config.ProviderProfile, bool) {
	for _, p := range s.config.Providers {
		for _, m := range p.Models {
			if m.ID == model {
				return p, true
			}
		}
	}
	return config.ProviderProfile{}, false
}

type responsesRequest struct {
	Model string          `json:"model"`
	Input json.RawMessage `json:"input"`
}

type chatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

func chatMessages(input json.RawMessage) ([]chatMessage, error) {
	var text string
	if err := json.Unmarshal(input, &text); err == nil {
		return []chatMessage{{Role: "user", Content: text}}, nil
	}

	var messages []chatMessage
	if err := json.Unmarshal(input, &messages); err != nil {
		return nil, fmt.Errorf("input must be a string or message array")
	}
	for i := range messages {
		if messages[i].Role == "" {
			messages[i].Role = "user"
		}
	}
	return messages, nil
}

type chatResponse struct {
	ID      string         `json:"id"`
	Model   string         `json:"model"`
	Choices []chatChoice   `json:"choices"`
	Usage   map[string]any `json:"usage,omitempty"`
}

type chatChoice struct {
	Message      chatMessage `json:"message"`
	FinishReason string      `json:"finish_reason"`
}

func responsesFromChat(chat chatResponse, requestedModel string) map[string]any {
	model := chat.Model
	if model == "" {
		model = requestedModel
	}
	id := chat.ID
	if id == "" {
		id = fmt.Sprintf("resp_%d", time.Now().UnixNano())
	} else if !strings.HasPrefix(id, "resp_") {
		id = "resp_" + id
	}
	text := ""
	status := "incomplete"
	if len(chat.Choices) > 0 {
		text = chat.Choices[0].Message.Content
		if chat.Choices[0].FinishReason == "stop" {
			status = "completed"
		}
	}

	return map[string]any{
		"id":     id,
		"object": "response",
		"status": status,
		"model":  model,
		"output": []map[string]any{
			{
				"type": "message",
				"role": "assistant",
				"content": []map[string]string{
					{
						"type": "output_text",
						"text": text,
					},
				},
			},
		},
		"usage": chat.Usage,
	}
}

func errorBody(kind, message string) map[string]any {
	return map[string]any{"error": map[string]string{"message": message, "type": kind}}
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		panic(err)
	}
}
