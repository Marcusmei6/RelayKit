package server

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"relaykit/gateway/internal/config"
)

type Server struct {
	config       *config.Config
	client       *http.Client
	usageLogPath string
}

func New(configPath string) (http.Handler, error) {
	return NewWithUsageLog(configPath, "")
}

func NewWithUsageLog(configPath, usageLogPath string) (http.Handler, error) {
	s := &Server{client: http.DefaultClient}
	s.usageLogPath = usageLogPath
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
	start := time.Now()
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

	upstreamReq := upstreamRequest(provider.APIFormat, req.Model, messages, req.Stream)
	payload, err := json.Marshal(upstreamReq)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorBody("server_error", err.Error()))
		return
	}

	upstreamURL, err := url.JoinPath(provider.BaseURL, upstreamPath(provider.APIFormat))
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
			if provider.APIFormat == config.APIFormatAnthropicMessages {
				httpReq.Header.Set("x-api-key", token)
			} else {
				httpReq.Header.Set("Authorization", "Bearer "+token)
			}
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
	if provider.APIFormat == config.APIFormatAnthropicMessages {
		if req.Stream {
			result := s.streamAnthropic(w, resp.Body, req.Model)
			s.recordCompletedUsage(provider.ID, req.Model, result.ID, result.Status, true, result.Usage, start)
			return
		}
		var msg anthropicResponse
		if err := json.NewDecoder(resp.Body).Decode(&msg); err != nil {
			writeJSON(w, http.StatusBadGateway, errorBody("upstream_error", err.Error()))
			return
		}
		writeJSON(w, http.StatusOK, responsesFromAnthropic(msg, req.Model))
		s.recordCompletedUsage(provider.ID, req.Model, responseID(msg.ID), statusFromFinish(msg.StopReason), false, msg.Usage, start)
		return
	}
	if req.Stream {
		result := s.streamChat(w, resp.Body, req.Model)
		s.recordCompletedUsage(provider.ID, req.Model, result.ID, result.Status, true, result.Usage, start)
		return
	}

	if err := json.NewDecoder(resp.Body).Decode(&chat); err != nil {
		writeJSON(w, http.StatusBadGateway, errorBody("upstream_error", err.Error()))
		return
	}
	writeJSON(w, http.StatusOK, responsesFromChat(chat, req.Model))
	s.recordCompletedUsage(provider.ID, req.Model, responseID(chat.ID), chatStatus(chat), false, chat.Usage, start)
}

func upstreamPath(apiFormat string) string {
	if apiFormat == config.APIFormatAnthropicMessages {
		return "messages"
	}
	return "chat/completions"
}

func upstreamRequest(apiFormat, model string, messages []chatMessage, stream bool) map[string]any {
	if apiFormat == config.APIFormatAnthropicMessages {
		return map[string]any{
			"model":      model,
			"max_tokens": 1024,
			"messages":   messages,
			"stream":     stream,
		}
	}
	return map[string]any{
		"model":    model,
		"messages": messages,
		"stream":   stream,
	}
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
	Model  string          `json:"model"`
	Input  json.RawMessage `json:"input"`
	Stream bool            `json:"stream"`
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

type chatStreamChunk struct {
	ID      string             `json:"id"`
	Model   string             `json:"model"`
	Choices []chatStreamChoice `json:"choices"`
	Usage   map[string]any     `json:"usage,omitempty"`
}

type chatStreamChoice struct {
	Delta        chatMessage `json:"delta"`
	FinishReason string      `json:"finish_reason"`
}

type anthropicResponse struct {
	ID         string           `json:"id"`
	Model      string           `json:"model"`
	Content    []anthropicBlock `json:"content"`
	StopReason string           `json:"stop_reason"`
	Usage      map[string]any   `json:"usage,omitempty"`
}

type anthropicBlock struct {
	Type  string          `json:"type"`
	Text  string          `json:"text,omitempty"`
	ID    string          `json:"id,omitempty"`
	Name  string          `json:"name,omitempty"`
	Input json.RawMessage `json:"input,omitempty"`
}

type anthropicStreamEvent struct {
	Message *struct {
		ID    string `json:"id"`
		Model string `json:"model"`
	} `json:"message,omitempty"`
	Delta *struct {
		Type       string `json:"type,omitempty"`
		Text       string `json:"text,omitempty"`
		StopReason string `json:"stop_reason,omitempty"`
	} `json:"delta,omitempty"`
	Usage map[string]any `json:"usage,omitempty"`
}

type streamResult struct {
	ID     string
	Status string
	Usage  map[string]any
}

func (s *Server) streamChat(w http.ResponseWriter, body io.Reader, requestedModel string) streamResult {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.WriteHeader(http.StatusOK)

	scanner := bufio.NewScanner(body)
	created := false
	finishReason := ""
	id := ""
	var usage map[string]any
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, ":") {
			continue
		}
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		data := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if data == "[DONE]" {
			if !writeSSE(w, "response.completed", map[string]any{
				"type":          "response.completed",
				"status":        statusFromFinish(finishReason),
				"finish_reason": finishReason,
				"usage":         usage,
			}) {
				return streamResult{}
			}
			return streamResult{ID: responseID(id), Status: statusFromFinish(finishReason), Usage: usage}
		}

		var chunk chatStreamChunk
		if err := json.Unmarshal([]byte(data), &chunk); err != nil {
			if !writeSSE(w, "response.error", map[string]any{
				"type":    "response.error",
				"message": err.Error(),
			}) {
				return streamResult{}
			}
			return streamResult{}
		}
		if !created {
			id = chunk.ID
			if chunk.Model == "" {
				chunk.Model = requestedModel
			}
			if !writeSSE(w, "response.created", map[string]any{
				"type":   "response.created",
				"id":     responseID(chunk.ID),
				"model":  chunk.Model,
				"status": "in_progress",
			}) {
				return streamResult{}
			}
			created = true
		}
		if chunk.Usage != nil {
			usage = chunk.Usage
		}
		for _, choice := range chunk.Choices {
			if choice.FinishReason != "" {
				finishReason = choice.FinishReason
			}
			if choice.Delta.Content != "" {
				if !writeSSE(w, "response.output_text.delta", map[string]any{
					"type":  "response.output_text.delta",
					"delta": choice.Delta.Content,
				}) {
					return streamResult{}
				}
			}
		}
	}
	if err := scanner.Err(); err != nil {
		if !writeSSE(w, "response.error", map[string]any{
			"type":    "response.error",
			"message": err.Error(),
		}) {
			return streamResult{}
		}
		return streamResult{}
	}
	if !writeSSE(w, "response.error", map[string]any{
		"type":    "response.error",
		"message": "upstream stream ended before [DONE]",
	}) {
		return streamResult{}
	}
	return streamResult{}
}

func (s *Server) streamAnthropic(w http.ResponseWriter, body io.Reader, requestedModel string) streamResult {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.WriteHeader(http.StatusOK)

	scanner := bufio.NewScanner(body)
	event := ""
	finishReason := ""
	id := ""
	var usage map[string]any
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, ":") {
			continue
		}
		if strings.HasPrefix(line, "event:") {
			event = strings.TrimSpace(strings.TrimPrefix(line, "event:"))
			continue
		}
		if !strings.HasPrefix(line, "data:") {
			continue
		}

		var payload anthropicStreamEvent
		if err := json.Unmarshal([]byte(strings.TrimSpace(strings.TrimPrefix(line, "data:"))), &payload); err != nil {
			if !writeSSE(w, "response.error", map[string]any{"type": "response.error", "message": err.Error()}) {
				return streamResult{}
			}
			return streamResult{}
		}
		switch event {
		case "message_start":
			model := requestedModel
			if payload.Message != nil {
				if payload.Message.Model != "" {
					model = payload.Message.Model
				}
				id = payload.Message.ID
			}
			if !writeSSE(w, "response.created", map[string]any{"type": "response.created", "id": responseID(id), "model": model, "status": "in_progress"}) {
				return streamResult{}
			}
		case "content_block_delta":
			if payload.Delta != nil && payload.Delta.Text != "" {
				if !writeSSE(w, "response.output_text.delta", map[string]any{"type": "response.output_text.delta", "delta": payload.Delta.Text}) {
					return streamResult{}
				}
			}
		case "message_delta":
			if payload.Delta != nil {
				finishReason = payload.Delta.StopReason
			}
			if payload.Usage != nil {
				usage = payload.Usage
			}
		case "message_stop":
			if !writeSSE(w, "response.completed", map[string]any{"type": "response.completed", "status": statusFromFinish(finishReason), "finish_reason": finishReason, "usage": usage}) {
				return streamResult{}
			}
			return streamResult{ID: responseID(id), Status: statusFromFinish(finishReason), Usage: usage}
		}
	}
	if err := scanner.Err(); err != nil {
		if !writeSSE(w, "response.error", map[string]any{"type": "response.error", "message": err.Error()}) {
			return streamResult{}
		}
		return streamResult{}
	}
	if !writeSSE(w, "response.error", map[string]any{"type": "response.error", "message": "upstream stream ended before message_stop"}) {
		return streamResult{}
	}
	return streamResult{}
}

func responsesFromChat(chat chatResponse, requestedModel string) map[string]any {
	model := chat.Model
	if model == "" {
		model = requestedModel
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
		"id":     responseID(chat.ID),
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

func responsesFromAnthropic(msg anthropicResponse, requestedModel string) map[string]any {
	model := msg.Model
	if model == "" {
		model = requestedModel
	}
	text := ""
	output := []map[string]any{}
	for _, block := range msg.Content {
		if block.Type == "text" {
			text += block.Text
		}
		if block.Type == "tool_use" {
			arguments := "{}"
			if len(block.Input) > 0 {
				arguments = string(block.Input)
			}
			output = append(output, map[string]any{
				"type":      "function_call",
				"call_id":   block.ID,
				"name":      block.Name,
				"arguments": arguments,
			})
		}
	}
	if text != "" {
		output = append([]map[string]any{
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
		}, output...)
	}
	return map[string]any{
		"id":     responseID(msg.ID),
		"object": "response",
		"status": statusFromFinish(msg.StopReason),
		"model":  model,
		"output": output,
		"usage":  msg.Usage,
	}
}

func responseID(id string) string {
	if id == "" {
		return fmt.Sprintf("resp_%d", time.Now().UnixNano())
	}
	if strings.HasPrefix(id, "resp_") {
		return id
	}
	return "resp_" + id
}

func statusFromFinish(finishReason string) string {
	if finishReason == "stop" || finishReason == "end_turn" || finishReason == "stop_sequence" || finishReason == "tool_use" {
		return "completed"
	}
	return "incomplete"
}

func chatStatus(chat chatResponse) string {
	if len(chat.Choices) > 0 {
		return statusFromFinish(chat.Choices[0].FinishReason)
	}
	return "incomplete"
}

type usageEvent struct {
	Timestamp    string `json:"timestamp"`
	RequestID    string `json:"request_id,omitempty"`
	ProviderID   string `json:"provider_id"`
	Model        string `json:"model"`
	Route        string `json:"route"`
	Streaming    bool   `json:"streaming"`
	Status       string `json:"status"`
	HTTPStatus   int    `json:"http_status"`
	InputTokens  int64  `json:"input_tokens,omitempty"`
	OutputTokens int64  `json:"output_tokens,omitempty"`
	TotalTokens  int64  `json:"total_tokens,omitempty"`
	DurationMS   int64  `json:"duration_ms"`
}

func (s *Server) recordCompletedUsage(providerID, model, requestID, status string, streaming bool, usage map[string]any, start time.Time) {
	s.recordUsage(usageEvent{
		Timestamp:    time.Now().UTC().Format(time.RFC3339Nano),
		RequestID:    requestID,
		ProviderID:   providerID,
		Model:        model,
		Route:        "/v1/responses",
		Streaming:    streaming,
		Status:       status,
		HTTPStatus:   http.StatusOK,
		DurationMS:   time.Since(start).Milliseconds(),
		InputTokens:  tokenCount(usage, "input_tokens", "prompt_tokens"),
		OutputTokens: tokenCount(usage, "output_tokens", "completion_tokens"),
		TotalTokens:  tokenCount(usage, "total_tokens"),
	})
}

func (s *Server) recordUsage(event usageEvent) {
	if s.usageLogPath == "" || event.Status == "" {
		return
	}
	if err := os.MkdirAll(filepath.Dir(s.usageLogPath), 0700); err != nil {
		log.Printf("usage log mkdir failed: %v", err)
		return
	}
	f, err := os.OpenFile(s.usageLogPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		log.Printf("usage log open failed: %v", err)
		return
	}
	defer func() {
		if err := f.Close(); err != nil {
			log.Printf("usage log close failed: %v", err)
		}
	}()
	if err := json.NewEncoder(f).Encode(event); err != nil {
		log.Printf("usage log write failed: %v", err)
	}
}

func tokenCount(usage map[string]any, keys ...string) int64 {
	for _, key := range keys {
		switch v := usage[key].(type) {
		case float64:
			return int64(v)
		case int:
			return int64(v)
		case int64:
			return v
		case json.Number:
			n, _ := v.Int64()
			return n
		}
	}
	return 0
}

func errorBody(kind, message string) map[string]any {
	return map[string]any{"error": map[string]string{"message": message, "type": kind}}
}

func writeSSE(w http.ResponseWriter, event string, value any) bool {
	body, err := json.Marshal(value)
	if err != nil {
		body = []byte(`{"type":"response.error","message":"sse_encode_error"}`)
		event = "response.error"
	}
	if _, err := fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event, body); err != nil {
		return false
	}
	if flusher, ok := w.(http.Flusher); ok {
		flusher.Flush()
	}
	return true
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		panic(err)
	}
}
