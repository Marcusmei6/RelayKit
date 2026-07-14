package server

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"strings"
	"time"

	"relaykit/gateway/internal/config"
)

type nativeResponsesStreamResult struct {
	ID        string
	Status    string
	Usage     map[string]any
	Terminal  bool
	ErrorKind string
	eventType string
}

const maximumNativeResponsesResponseBytes = 16 << 20

func (s *Server) nativeOpenAIResponses(w http.ResponseWriter, r *http.Request, raw map[string]json.RawMessage, req responsesRequest, provider config.ProviderProfile, model config.Model, start time.Time) {
	resp, status, failure := s.nativeResponsesUpstream(r.Context(), raw, provider, model, req.Stream)
	if failure != nil {
		s.recordFailedUsage(provider.ID, req.Model, failure.kind, status, start, "responses_http")
		writeJSON(w, status, errorBody(failure.kind, failure.message))
		return
	}
	defer resp.Body.Close()

	if req.Stream {
		if !isSSEContentType(resp.Header.Get("Content-Type")) {
			s.recordFailedUsage(provider.ID, req.Model, "protocol_error", http.StatusBadGateway, start, "responses_http")
			writeJSON(w, http.StatusBadGateway, errorBody("protocol_error", "upstream returned an invalid streaming response"))
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.WriteHeader(http.StatusOK)
		result := forwardNativeResponsesSSE(resp.Body, req.Model, func(event string, data []byte) bool {
			return writeRawSSE(w, event, data)
		})
		if result.ErrorKind != "" {
			s.recordFailedUsage(provider.ID, req.Model, result.ErrorKind, http.StatusBadGateway, start, "responses_http")
			return
		}
		if !result.Terminal {
			s.recordFailedUsage(provider.ID, req.Model, "upstream_stream_truncated", http.StatusBadGateway, start, "responses_http")
			return
		}
		s.recordCompletedUsage(provider.ID, req.Model, result.ID, result.Status, true, result.Usage, start, "responses_http")
		return
	}

	if !isJSONContentType(resp.Header.Get("Content-Type")) {
		s.recordFailedUsage(provider.ID, req.Model, "protocol_error", http.StatusBadGateway, start, "responses_http")
		writeJSON(w, http.StatusBadGateway, errorBody("protocol_error", "upstream returned an invalid response"))
		return
	}
	response, err := rewriteNativeResponsesResponse(resp.Body, req.Model)
	if err != nil {
		s.recordFailedUsage(provider.ID, req.Model, "protocol_error", http.StatusBadGateway, start, "responses_http")
		writeJSON(w, http.StatusBadGateway, errorBody("protocol_error", "upstream returned an invalid response"))
		return
	}
	writeRawJSON(w, http.StatusOK, response.body)
	s.recordCompletedUsage(provider.ID, req.Model, response.id, response.status, false, response.usage, start, "responses_http")
}

func (s *Server) nativeOpenAIResponsesWebSocket(w *bufio.Writer, ctx context.Context, raw map[string]json.RawMessage, req responsesRequest, provider config.ProviderProfile, model config.Model, start time.Time) {
	resp, status, failure := s.nativeResponsesUpstream(ctx, raw, provider, model, true)
	if failure != nil {
		s.recordFailedUsage(provider.ID, req.Model, failure.kind, status, start, "responses_websocket")
		_ = writeWebSocketJSON(w, nativeResponsesErrorEvent(failure.kind))
		return
	}
	defer resp.Body.Close()
	if !isSSEContentType(resp.Header.Get("Content-Type")) {
		s.recordFailedUsage(provider.ID, req.Model, "protocol_error", http.StatusBadGateway, start, "responses_websocket")
		_ = writeWebSocketJSON(w, nativeResponsesErrorEvent("protocol_error"))
		return
	}
	result := forwardNativeResponsesSSE(resp.Body, req.Model, func(_ string, data []byte) bool {
		return writeWebSocketFrame(w, websocketOpcodeText, data) == nil
	})
	if result.ErrorKind != "" {
		s.recordFailedUsage(provider.ID, req.Model, result.ErrorKind, http.StatusBadGateway, start, "responses_websocket")
		return
	}
	if !result.Terminal {
		s.recordFailedUsage(provider.ID, req.Model, "upstream_stream_truncated", http.StatusBadGateway, start, "responses_websocket")
		return
	}
	s.recordCompletedUsage(provider.ID, req.Model, result.ID, result.Status, true, result.Usage, start, "responses_websocket")
}

type nativeResponsesFailure struct {
	kind    string
	message string
}

func (s *Server) nativeResponsesUpstream(ctx context.Context, raw map[string]json.RawMessage, provider config.ProviderProfile, model config.Model, forceStream bool) (*http.Response, int, *nativeResponsesFailure) {
	return s.nativeResponsesUpstreamWithAuth(ctx, raw, provider, model, forceStream, s.applyProviderAuth)
}

func (s *Server) nativeResponsesUpstreamWithAuth(ctx context.Context, raw map[string]json.RawMessage, provider config.ProviderProfile, model config.Model, forceStream bool, applyAuth func(*http.Request, config.ProviderProfile) error) (*http.Response, int, *nativeResponsesFailure) {
	payload, err := nativeResponsesRequestBody(raw, upstreamModelName(model), forceStream)
	if err != nil {
		return nil, http.StatusBadGateway, &nativeResponsesFailure{kind: "protocol_error", message: "invalid Responses request"}
	}
	endpoint, err := nativeResponsesURL(provider.BaseURL)
	if err != nil {
		return nil, http.StatusBadGateway, &nativeResponsesFailure{kind: "protocol_error", message: "invalid provider endpoint"}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(payload))
	if err != nil {
		return nil, http.StatusBadGateway, &nativeResponsesFailure{kind: "upstream_error", message: "upstream request failed"}
	}
	req.Header.Set("Content-Type", "application/json")
	if forceStream {
		req.Header.Set("Accept", "text/event-stream")
	} else {
		req.Header.Set("Accept", "application/json")
	}
	if err := applyAuth(req, provider); err != nil {
		return nil, http.StatusBadGateway, &nativeResponsesFailure{kind: "upstream_auth_error", message: "provider credential unavailable"}
	}
	resp, err := s.client.Do(req)
	if err != nil {
		return nil, http.StatusBadGateway, &nativeResponsesFailure{kind: "upstream_error", message: "upstream request failed"}
	}
	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		_ = resp.Body.Close()
		status, kind, message := nativeResponsesHTTPFailure(resp.StatusCode)
		return nil, status, &nativeResponsesFailure{kind: kind, message: message}
	}
	return resp, http.StatusOK, nil
}

func nativeResponsesRequestBody(raw map[string]json.RawMessage, model string, forceStream bool) ([]byte, error) {
	request := make(map[string]json.RawMessage, len(raw)+1)
	for key, value := range raw {
		request[key] = value
	}
	request["model"] = json.RawMessage(strconvQuote(model))
	if forceStream {
		request["stream"] = json.RawMessage("true")
	}
	return json.Marshal(request)
}

func nativeResponsesURL(baseURL string) (string, error) {
	return url.JoinPath(baseURL, "responses")
}

func nativeResponsesHTTPFailure(status int) (int, string, string) {
	switch status {
	case http.StatusBadRequest:
		return http.StatusBadRequest, "upstream_invalid_request", "upstream rejected the request"
	case http.StatusUnauthorized, http.StatusForbidden:
		return http.StatusBadGateway, "upstream_auth_error", "provider authentication failed"
	case http.StatusTooManyRequests:
		return http.StatusTooManyRequests, "rate_limit", "upstream rate limit exceeded"
	case http.StatusServiceUnavailable:
		return http.StatusServiceUnavailable, "unavailable", "upstream service unavailable"
	default:
		return http.StatusBadGateway, "upstream_error", "upstream request failed"
	}
}

func (s *Server) applyProviderSnapshotAuth(req *http.Request, provider config.ProviderProfile) error {
	reference := provider.AuthEnv
	if provider.CredentialRef != nil {
		reference = provider.CredentialRef.Value
	}
	if reference == "" {
		return nil
	}
	token := strings.TrimSpace(s.keychainCredentials[reference])
	if token == "" {
		return fmt.Errorf("provider credential unavailable from RelayKit App")
	}
	setAuthHeader(req, provider, token)
	return nil
}

type nativeResponsesResponse struct {
	body   []byte
	id     string
	status string
	usage  map[string]any
}

func rewriteNativeResponsesResponse(reader io.Reader, publicModel string) (nativeResponsesResponse, error) {
	body, err := io.ReadAll(io.LimitReader(reader, maximumNativeResponsesResponseBytes+1))
	if err != nil {
		return nativeResponsesResponse{}, err
	}
	if len(body) > maximumNativeResponsesResponseBytes {
		return nativeResponsesResponse{}, fmt.Errorf("native response exceeds size limit")
	}
	response, err := strictJSONObject(body)
	if err != nil {
		return nativeResponsesResponse{}, err
	}
	id, status, err := validateNativeResponseIdentity(response, "")
	if err != nil {
		return nativeResponsesResponse{}, err
	}
	if _, ok := response["model"]; ok {
		response["model"] = json.RawMessage(strconvQuote(publicModel))
	}
	rewritten, err := json.Marshal(response)
	if err != nil {
		return nativeResponsesResponse{}, err
	}
	result := nativeResponsesResponse{body: rewritten, id: id, status: status}
	_ = json.Unmarshal(response["usage"], &result.usage)
	return result, nil
}

func ensureJSONEOF(decoder *json.Decoder) error {
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return fmt.Errorf("multiple JSON values")
		}
		return err
	}
	return nil
}

func isNativeResponsesTerminalStatus(status string) bool {
	return status == "completed" || status == "failed" || status == "incomplete"
}

func validateNativeResponseIdentity(response map[string]json.RawMessage, expectedStatus string) (string, string, error) {
	if response == nil {
		return "", "", fmt.Errorf("invalid native response")
	}
	var object, id, status string
	if err := json.Unmarshal(response["object"], &object); err != nil || object != "response" {
		return "", "", fmt.Errorf("invalid native response object")
	}
	if err := json.Unmarshal(response["id"], &id); err != nil || strings.TrimSpace(id) == "" {
		return "", "", fmt.Errorf("invalid native response id")
	}
	if err := json.Unmarshal(response["status"], &status); err != nil || !isNativeResponsesTerminalStatus(status) {
		return "", "", fmt.Errorf("invalid native response status")
	}
	if expectedStatus != "" && status != expectedStatus {
		return "", "", fmt.Errorf("native response status mismatch")
	}
	return id, status, nil
}

func forwardNativeResponsesSSE(reader io.Reader, publicModel string, send func(event string, data []byte) bool) nativeResponsesStreamResult {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 4096), 16<<20)
	var event string
	var data []string
	result := nativeResponsesStreamResult{}
	flush := func() bool {
		if len(data) == 0 {
			event = ""
			return true
		}
		rewritten, terminal, parsed, err := rewriteNativeResponsesEvent([]byte(strings.Join(data, "\n")), publicModel, event)
		if err != nil {
			_ = send("response.error", mustJSON(nativeResponsesErrorEvent("protocol_error")))
			result.ErrorKind = "protocol_error"
			return false
		}
		if event == "" || parsed.ErrorKind != "" || terminal {
			event = parsed.eventType
		}
		if !send(event, rewritten) {
			return false
		}
		if terminal {
			result = parsed
			result.Terminal = true
		}
		event = ""
		data = nil
		return true
	}
	for scanner.Scan() {
		line := scanner.Text()
		switch {
		case line == "":
			if !flush() {
				return result
			}
			if result.Terminal {
				return result
			}
		case strings.HasPrefix(line, "event:"):
			event = strings.TrimSpace(strings.TrimPrefix(line, "event:"))
		case strings.HasPrefix(line, "data:"):
			data = append(data, strings.TrimSpace(strings.TrimPrefix(line, "data:")))
		}
	}
	if len(data) > 0 {
		if !flush() || result.Terminal {
			return result
		}
	}
	if err := scanner.Err(); err != nil {
		_ = send("response.error", mustJSON(nativeResponsesErrorEvent("upstream_stream_error")))
		result.ErrorKind = "upstream_stream_error"
		return result
	}
	if !result.Terminal {
		_ = send("response.error", mustJSON(nativeResponsesErrorEvent("upstream_stream_truncated")))
		result.ErrorKind = "upstream_stream_truncated"
	}
	return result
}

func rewriteNativeResponsesEvent(data []byte, publicModel, sseEventType string) ([]byte, bool, nativeResponsesStreamResult, error) {
	var event map[string]json.RawMessage
	if err := json.Unmarshal(data, &event); err != nil {
		return nil, false, nativeResponsesStreamResult{}, err
	}
	result := nativeResponsesStreamResult{}
	_ = json.Unmarshal(event["type"], &result.Status)
	eventType := result.Status
	result.Status = ""
	if eventType == "" {
		return nil, false, nativeResponsesStreamResult{}, fmt.Errorf("SSE event type missing")
	}
	if sseEventType != "" && sseEventType != eventType {
		return nil, false, nativeResponsesStreamResult{}, fmt.Errorf("SSE event type mismatch")
	}
	if eventType == "error" || eventType == "response.error" {
		result.Status = "failed"
		result.ErrorKind = "upstream_stream_error"
		result.eventType = "response.error"
		return mustJSON(nativeResponsesErrorEvent(result.ErrorKind)), true, result, nil
	}
	terminalStatus := nativeResponsesTerminalEventStatus(eventType)
	responseRaw, hasResponse := event["response"]
	if terminalStatus != "" && !hasResponse {
		return nil, false, nativeResponsesStreamResult{}, fmt.Errorf("terminal response missing")
	}
	if hasResponse {
		var response map[string]json.RawMessage
		if err := json.Unmarshal(responseRaw, &response); err != nil {
			return nil, false, nativeResponsesStreamResult{}, err
		}
		if response == nil {
			return nil, false, nativeResponsesStreamResult{}, fmt.Errorf("terminal response is null")
		}
		if terminalStatus != "" {
			id, status, err := validateNativeResponseIdentity(response, terminalStatus)
			if err != nil {
				return nil, false, nativeResponsesStreamResult{}, err
			}
			result.ID = id
			result.Status = status
		}
		if _, ok := response["model"]; ok {
			response["model"] = json.RawMessage(strconvQuote(publicModel))
		}
		responseRaw, err := json.Marshal(response)
		if err != nil {
			return nil, false, nativeResponsesStreamResult{}, err
		}
		event["response"] = responseRaw
		if terminalStatus == "" {
			_ = json.Unmarshal(response["id"], &result.ID)
			_ = json.Unmarshal(response["status"], &result.Status)
		}
		_ = json.Unmarshal(response["usage"], &result.Usage)
	}
	terminal := terminalStatus != ""
	result.eventType = eventType
	rewritten, err := json.Marshal(event)
	return rewritten, terminal, result, err
}

func nativeResponsesTerminalEventStatus(eventType string) string {
	status := strings.TrimPrefix(eventType, "response.")
	if strings.HasPrefix(eventType, "response.") && isNativeResponsesTerminalStatus(status) {
		return status
	}
	return ""
}

func nativeResponsesErrorEvent(kind string) map[string]any {
	return map[string]any{"type": "response.error", "error": map[string]string{"type": kind, "message": "upstream Responses stream failed"}}
}

func isJSONContentType(contentType string) bool {
	return hasExactMediaType(contentType, "application/json")
}

func isSSEContentType(contentType string) bool {
	return hasExactMediaType(contentType, "text/event-stream")
}

func hasExactMediaType(contentType, expected string) bool {
	mediaType, _, err := mime.ParseMediaType(contentType)
	return err == nil && strings.EqualFold(mediaType, expected)
}

func writeRawJSON(w http.ResponseWriter, status int, body []byte) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

func writeRawSSE(w http.ResponseWriter, event string, data []byte) bool {
	if event == "" {
		event = "message"
	}
	if _, err := w.Write([]byte("event: " + event + "\ndata: " + string(data) + "\n\n")); err != nil {
		return false
	}
	if flusher, ok := w.(http.Flusher); ok {
		flusher.Flush()
	}
	return true
}

func mustJSON(value any) []byte {
	body, _ := json.Marshal(value)
	return body
}

func strconvQuote(value string) string {
	encoded, _ := json.Marshal(value)
	return string(encoded)
}
