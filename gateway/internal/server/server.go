package server

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/klauspost/compress/zstd"

	"relaykit/gateway/internal/config"
)

type Server struct {
	config                   *config.Config
	client                   *http.Client
	usageLogPath             string
	keychainCredentials      map[string]string
	allowKeychainCLIFallback bool
	officialStructuralTrace  *officialStructuralTrace
}

const maximumResponsesRequestBytes = 16 << 20

var runSecurityFindGenericPassword = func(args ...string) ([]byte, error) {
	return exec.Command("/usr/bin/security", args...).Output()
}

var lookupKeychainCredential = func(name string) (string, error) {
	out, err := runSecurityFindGenericPassword("find-generic-password", "-s", name, "-a", "RelayKit", "-w")
	if err != nil {
		out, err = runSecurityFindGenericPassword("find-generic-password", "-s", name, "-w")
	}
	if err != nil {
		return "", fmt.Errorf("keychain credential unavailable")
	}
	token := strings.TrimSpace(string(out))
	if token == "" {
		return "", fmt.Errorf("keychain credential is empty")
	}
	return token, nil
}

func New(configPath string) (http.Handler, error) {
	return NewWithUsageLog(configPath, "")
}

func NewWithUsageLog(configPath, usageLogPath string) (http.Handler, error) {
	return newServer(configPath, usageLogPath, nil, true)
}

func NewWithUsageLogAndCredentials(configPath, usageLogPath string, credentials map[string]string) (http.Handler, error) {
	return newServer(configPath, usageLogPath, credentials, false)
}

func newServer(configPath, usageLogPath string, credentials map[string]string, allowKeychainCLIFallback bool) (http.Handler, error) {
	credentialCopy := make(map[string]string, len(credentials))
	for reference, value := range credentials {
		credentialCopy[reference] = value
	}
	s := &Server{
		client:                   http.DefaultClient,
		keychainCredentials:      credentialCopy,
		allowKeychainCLIFallback: allowKeychainCLIFallback,
	}
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
	trace, err := newOfficialStructuralTraceFromEnv()
	if err != nil {
		return nil, err
	}
	s.officialStructuralTrace = trace

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.healthz)
	mux.HandleFunc("GET /v1/models", s.models)
	mux.HandleFunc("POST /_relaykit/provider-test", s.providerTest)
	mux.HandleFunc("GET /v1/responses", s.responsesWebSocket)
	mux.HandleFunc("POST /v1/responses", s.responses)
	return mux, nil
}

func (s *Server) healthz(w http.ResponseWriter, _ *http.Request) {
	configuredModelCount := 0
	for _, provider := range s.config.Providers {
		configuredModelCount += len(provider.Models)
	}
	officialModelCount := 0
	if s.config.OfficialPassthrough != nil {
		officialModelCount = len(s.config.OfficialPassthrough.Models)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"service":                "relaykit",
		"status":                 "ok",
		"provider_count":         len(s.config.Providers),
		"configured_model_count": configuredModelCount,
		"official_model_count":   officialModelCount,
	})
}

func (s *Server) models(w http.ResponseWriter, _ *http.Request) {
	models, health := s.catalogModels()
	writeJSON(w, http.StatusOK, map[string]any{
		"object":       "list",
		"data":         models,
		"models":       models,
		"model_health": health,
	})
}

type providerTestRequest struct {
	ProviderID string
	ModelID    string
}

type providerTestResult struct {
	ProviderID string             `json:"provider_id"`
	ModelID    string             `json:"model_id"`
	Status     string             `json:"status"`
	Error      *providerTestError `json:"error,omitempty"`
}

type providerTestError struct {
	Type string `json:"type"`
}

func (s *Server) providerTest(w http.ResponseWriter, r *http.Request) {
	request, err := decodeProviderTestRequest(r.Body)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorBody("invalid_request_error", "invalid provider test request"))
		return
	}
	provider, model, ok := s.providerByIDAndModel(request.ProviderID, request.ModelID)
	if !ok || !providerEnabled(provider) {
		writeProviderTestResult(w, http.StatusBadRequest, request, "failed", "unknown_model")
		return
	}
	if provider.APIFormat != config.APIFormatOpenAIResponses {
		writeProviderTestResult(w, http.StatusBadRequest, request, "failed", "unsupported_provider_format")
		return
	}

	raw := map[string]json.RawMessage{
		"input":             json.RawMessage(`"Return a tiny reachability confirmation."`),
		"max_output_tokens": json.RawMessage(`1`),
	}
	payload, err := nativeResponsesRequestBody(raw, upstreamModelName(model), false)
	if err != nil {
		writeProviderTestResult(w, http.StatusBadGateway, request, "failed", "responses_unavailable")
		return
	}
	endpoint, err := nativeResponsesURL(provider.BaseURL)
	if err != nil {
		writeProviderTestResult(w, http.StatusBadGateway, request, "failed", "responses_unavailable")
		return
	}
	upstreamRequest, err := http.NewRequestWithContext(r.Context(), http.MethodPost, endpoint, bytes.NewReader(payload))
	if err != nil {
		writeProviderTestResult(w, http.StatusBadGateway, request, "failed", "responses_unavailable")
		return
	}
	upstreamRequest.Header.Set("Content-Type", "application/json")
	upstreamRequest.Header.Set("Accept", "application/json")
	if err := s.applyProviderSnapshotAuth(upstreamRequest, provider); err != nil {
		writeProviderTestResult(w, http.StatusBadGateway, request, "failed", "auth_failed")
		return
	}
	response, err := s.doNativeResponsesRequest(upstreamRequest)
	if err != nil {
		writeProviderTestResult(w, http.StatusBadGateway, request, "failed", "network_failed")
		return
	}
	defer response.Body.Close()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		status, _, _ := nativeResponsesHTTPFailure(response.StatusCode)
		errorType := "responses_unavailable"
		if response.StatusCode == http.StatusUnauthorized || response.StatusCode == http.StatusForbidden {
			errorType = "auth_failed"
		}
		writeProviderTestResult(w, status, request, "failed", errorType)
		return
	}
	if !isJSONContentType(response.Header.Get("Content-Type")) {
		writeProviderTestResult(w, http.StatusBadGateway, request, "failed", "responses_unavailable")
		return
	}
	parsed, err := rewriteNativeResponsesResponse(response.Body, model.ID)
	if err != nil || parsed.status != "completed" {
		writeProviderTestResult(w, http.StatusBadGateway, request, "failed", "responses_unavailable")
		return
	}
	writeProviderTestResult(w, http.StatusOK, request, "ok", "")
}

func decodeProviderTestRequest(body io.Reader) (providerTestRequest, error) {
	encoded, err := io.ReadAll(io.LimitReader(body, maximumResponsesRequestBytes+1))
	if err != nil || len(encoded) > maximumResponsesRequestBytes {
		return providerTestRequest{}, fmt.Errorf("invalid provider test request")
	}
	raw, err := strictJSONObject(encoded)
	if err != nil || len(raw) != 2 || raw["provider_id"] == nil || raw["model_id"] == nil {
		return providerTestRequest{}, fmt.Errorf("invalid provider test request")
	}
	for key := range raw {
		if key != "provider_id" && key != "model_id" {
			return providerTestRequest{}, fmt.Errorf("invalid provider test request")
		}
	}
	var request providerTestRequest
	if err := json.Unmarshal(raw["provider_id"], &request.ProviderID); err != nil || strings.TrimSpace(request.ProviderID) == "" {
		return providerTestRequest{}, fmt.Errorf("invalid provider test request")
	}
	if err := json.Unmarshal(raw["model_id"], &request.ModelID); err != nil || strings.TrimSpace(request.ModelID) == "" {
		return providerTestRequest{}, fmt.Errorf("invalid provider test request")
	}
	return request, nil
}

func writeProviderTestResult(w http.ResponseWriter, status int, request providerTestRequest, resultStatus, errorType string) {
	result := providerTestResult{ProviderID: request.ProviderID, ModelID: request.ModelID, Status: resultStatus}
	if errorType != "" {
		result.Error = &providerTestError{Type: errorType}
	}
	writeJSON(w, status, result)
}

func (s *Server) catalogModels() ([]map[string]any, map[string]any) {
	type catalogCandidate struct {
		provider config.ProviderProfile
		model    config.Model
		entry    map[string]any
	}
	var candidates []catalogCandidate
	if s.config.OfficialPassthrough != nil {
		for _, m := range s.config.OfficialPassthrough.Models {
			entry := map[string]any{
				"id":       m.ID,
				"object":   "model",
				"created":  int64(0),
				"owned_by": "openai",
				"source":   "openai",
			}
			if m.DisplayName != "" {
				entry["display_name"] = m.DisplayName
			}
			candidates = append(candidates, catalogCandidate{
				model: m,
				entry: entry,
			})
		}
	}
	for _, p := range s.config.Providers {
		if !providerEnabled(p) {
			continue
		}
		for _, m := range p.Models {
			entry := map[string]any{
				"id":       m.ID,
				"object":   "model",
				"created":  int64(0),
				"owned_by": p.ID,
			}
			if p.Routing.Source != "" {
				entry["source"] = p.Routing.Source
			}
			if p.Routing.Visible {
				entry["visibility"] = "list"
			}
			if p.Routing.Priority > 0 {
				entry["priority"] = p.Routing.Priority
			}
			if m.DisplayName != "" {
				entry["display_name"] = m.DisplayName
			}
			if m.UpstreamModel != "" {
				entry["upstream_model"] = m.UpstreamModel
			}
			candidates = append(candidates, catalogCandidate{
				provider: p,
				model:    m,
				entry:    entry,
			})
		}
	}
	healthy := make([]bool, len(candidates))
	reasons := make([]string, len(candidates))
	probed := false
	for i, candidate := range candidates {
		if candidate.provider.ID == "" {
			healthy[i] = true
			continue
		}
		if !shouldProbeCatalogModel(candidate.provider) {
			healthy[i] = true
			continue
		}
		probed = true
		healthy[i], reasons[i] = s.probeModel(candidate.provider, candidate.model)
	}

	data := make([]map[string]any, 0, len(candidates))
	unhealthyCount := 0
	hidden := make([]map[string]any, 0)
	for i, candidate := range candidates {
		if !healthy[i] {
			unhealthyCount++
			hidden = append(hidden, map[string]any{
				"id":     candidate.model.ID,
				"reason": healthReason(reasons[i]),
			})
			continue
		}
		data = append(data, candidate.entry)
	}
	return data, map[string]any{
		"probed":    probed,
		"healthy":   len(data),
		"unhealthy": unhealthyCount,
		"hidden":    hidden,
	}
}

func shouldProbeCatalogModel(provider config.ProviderProfile) bool {
	return provider.CredentialRef != nil &&
		(provider.CredentialRef.Kind == config.CredentialKindKeyFile || provider.CredentialRef.Kind == config.CredentialKindKeychain)
}

func (s *Server) probeModel(provider config.ProviderProfile, model config.Model) (bool, string) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()

	modelsURL, err := providerModelsURL(provider)
	if err != nil {
		return false, "network failed"
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, modelsURL, nil)
	if err != nil {
		return false, "network failed"
	}
	if err := s.applyProviderAuth(req, provider); err != nil {
		return false, "auth failed"
	}
	resp, err := s.client.Do(req)
	if err != nil {
		return false, "network failed"
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return false, "auth failed"
	}
	if resp.StatusCode == http.StatusNotFound {
		return false, "unsupported model"
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return false, fmt.Sprintf("upstream non-success (HTTP %d)", resp.StatusCode)
	}
	if !modelListContains(body, upstreamModelName(model)) {
		return false, "unsupported model"
	}

	probeRoute := func() (bool, string) {
		upstreamReq := probeUpstreamRequest(provider.APIFormat, upstreamModelName(model))
		payload, err := json.Marshal(upstreamReq)
		if err != nil {
			return false, "network failed"
		}
		upstreamURL, err := providerUpstreamURL(provider)
		if err != nil {
			return false, "network failed"
		}
		httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, upstreamURL, bytes.NewReader(payload))
		if err != nil {
			return false, "network failed"
		}
		httpReq.Header.Set("Content-Type", "application/json")
		if err := s.applyProviderAuth(httpReq, provider); err != nil {
			return false, "auth failed"
		}
		resp, err = s.client.Do(httpReq)
		if err != nil {
			return false, "network failed"
		}
		defer resp.Body.Close()
		if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
			return false, "auth failed"
		}
		if resp.StatusCode == http.StatusNotFound {
			return false, "unsupported model"
		}
		if resp.StatusCode < 200 || resp.StatusCode > 299 {
			return false, fmt.Sprintf("upstream non-success (HTTP %d)", resp.StatusCode)
		}
		if provider.APIFormat == config.APIFormatAnthropicMessages {
			var msg anthropicResponse
			if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&msg); err != nil {
				return false, "upstream decode error"
			}
			return true, ""
		}
		if provider.APIFormat == config.APIFormatOpenAIResponses {
			if !isJSONContentType(resp.Header.Get("Content-Type")) {
				return false, "upstream decode error"
			}
			nativeResponse, err := rewriteNativeResponsesResponse(io.LimitReader(resp.Body, 1<<20), model.ID)
			if err != nil {
				return false, "upstream decode error"
			}
			if nativeResponse.status != "completed" {
				return false, "upstream response not completed"
			}
			return true, ""
		}
		var chat chatResponse
		if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&chat); err != nil {
			return false, "upstream decode error"
		}
		return true, ""
	}
	ok, reason := probeRoute()
	if provider.APIFormat != config.APIFormatOpenAIResponses && !ok && strings.HasPrefix(reason, "upstream non-success") {
		time.Sleep(700 * time.Millisecond)
		return probeRoute()
	}
	return ok, reason
}

func healthReason(reason string) string {
	if strings.HasPrefix(reason, "upstream non-success") {
		return reason
	}
	switch reason {
	case "auth failed", "network failed", "upstream non-success", "unsupported model", "upstream decode error", "upstream response not completed":
		return reason
	default:
		return "upstream non-success"
	}
}

func providerModelsURL(provider config.ProviderProfile) (string, error) {
	if provider.Catalog.ModelsURL != "" {
		return provider.Catalog.ModelsURL, nil
	}
	if provider.APIFormat == config.APIFormatAnthropicMessages && anthropicBaseNeedsV1(provider.BaseURL) {
		return url.JoinPath(provider.BaseURL, "v1/models")
	}
	return url.JoinPath(provider.BaseURL, "models")
}

func modelListContains(body []byte, target string) bool {
	if strings.TrimSpace(target) == "" {
		return false
	}
	var root any
	if err := json.Unmarshal(body, &root); err != nil {
		return false
	}
	return containsModelID(root, target)
}

func containsModelID(value any, target string) bool {
	switch v := value.(type) {
	case []any:
		for _, item := range v {
			if containsModelID(item, target) {
				return true
			}
		}
	case map[string]any:
		for _, key := range []string{"id", "slug", "model"} {
			if id, ok := v[key].(string); ok && id == target {
				return true
			}
		}
		for _, key := range []string{"data", "models"} {
			if containsModelID(v[key], target) {
				return true
			}
		}
	case string:
		return v == target
	}
	return false
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

	body, closeBody, err := requestBodyReader(r)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorBody("invalid_request_error", err.Error()))
		return
	}
	if closeBody != nil {
		defer closeBody()
	}

	rawRequest, req, err := decodeResponsesRequest(body)
	if err != nil {
		status := http.StatusBadRequest
		if err == errResponsesRequestTooLarge {
			status = http.StatusRequestEntityTooLarge
		}
		writeJSON(w, status, errorBody("invalid_request_error", "invalid request body"))
		return
	}
	if body := s.validateResponsesModel(req.Model, start, "responses_http"); body != nil {
		writeJSON(w, http.StatusBadRequest, body)
		return
	}
	if provider, model, ok := s.providerForModel(req.Model); ok && provider.APIFormat == config.APIFormatOpenAIResponses {
		s.nativeOpenAIResponses(w, r, rawRequest, req, provider, model, start)
		return
	}
	messages, err := chatMessages(req.Input)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorBody("invalid_request_error", err.Error()))
		return
	}
	if !req.Stream {
		result, status, body := s.completeResponse(r.Context(), req, messages, start, "responses_http")
		if status != http.StatusOK {
			writeJSON(w, status, body)
			return
		}
		writeJSON(w, http.StatusOK, result)
		return
	}
	if model, ok := s.officialModelForModel(req.Model); ok {
		s.officialResponses(w, r, req, model, messages, start)
		return
	}
	provider, model, ok := s.providerForModel(req.Model)
	if !ok {
		writeJSON(w, http.StatusBadRequest, errorBody("invalid_request_error", "unknown model"))
		return
	}

	upstreamReq := upstreamRequest(provider.APIFormat, upstreamModelName(model), messages, req.Stream)
	addProviderTools(upstreamReq, provider.APIFormat, req.Tools)
	payload, err := json.Marshal(upstreamReq)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorBody("server_error", err.Error()))
		return
	}

	upstreamURL, err := providerUpstreamURL(provider)
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
	if err := s.applyProviderAuth(httpReq, provider); err != nil {
		writeJSON(w, http.StatusBadGateway, errorBody("upstream_auth_error", err.Error()))
		return
	}

	resp, err := s.client.Do(httpReq)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, errorBody("upstream_error", "upstream request failed"))
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		writeJSON(w, http.StatusBadGateway, errorBody("upstream_error", fmt.Sprintf("upstream returned non-success status %d", resp.StatusCode)))
		return
	}

	var chat chatResponse
	if provider.APIFormat == config.APIFormatAnthropicMessages {
		if req.Stream {
			result := s.streamAnthropic(w, resp.Body, req.Model)
			s.recordCompletedUsage(provider.ID, req.Model, result.ID, result.Status, true, result.Usage, start, "responses_http")
			return
		}
		var msg anthropicResponse
		if err := json.NewDecoder(resp.Body).Decode(&msg); err != nil {
			writeJSON(w, http.StatusBadGateway, errorBody("upstream_error", err.Error()))
			return
		}
		writeJSON(w, http.StatusOK, responsesFromAnthropic(msg, req.Model))
		s.recordCompletedUsage(provider.ID, req.Model, responseID(msg.ID), statusFromFinish(msg.StopReason), false, msg.Usage, start, "responses_http")
		return
	}
	if req.Stream {
		result := s.streamChat(w, resp.Body, req.Model)
		s.recordCompletedUsage(provider.ID, req.Model, result.ID, result.Status, true, result.Usage, start, "responses_http")
		return
	}

	if err := json.NewDecoder(resp.Body).Decode(&chat); err != nil {
		writeJSON(w, http.StatusBadGateway, errorBody("upstream_error", err.Error()))
		return
	}
	writeJSON(w, http.StatusOK, responsesFromChat(chat, req.Model))
	s.recordCompletedUsage(provider.ID, req.Model, responseID(chat.ID), chatStatus(chat), false, chat.Usage, start, "responses_http")
}

func (s *Server) responsesWebSocket(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	if !isWebSocketUpgrade(r) {
		writeJSON(w, http.StatusUpgradeRequired, errorBody("invalid_request_error", "websocket upgrade required"))
		return
	}
	conn, rw, err := acceptWebSocket(w, r)
	if err != nil {
		log.Printf("websocket upgrade failed: %v", err)
		return
	}
	defer conn.Close()

	for {
		opcode, payload, err := readWebSocketFrame(rw.Reader)
		if err != nil {
			_ = writeWebSocketClose(rw.Writer)
			return
		}
		switch opcode {
		case websocketOpcodeClose:
			return
		case websocketOpcodePing:
			_ = writeWebSocketFrame(rw.Writer, websocketOpcodePong, payload)
		case websocketOpcodeText, websocketOpcodeBinary:
			envelope, err := strictJSONObject(payload)
			if err != nil {
				_ = writeWebSocketJSON(rw.Writer, nativeResponsesErrorEvent("protocol_error"))
				_ = writeWebSocketClose(rw.Writer)
				return
			}
			requestBody := envelope
			if rawType, hasType := envelope["type"]; hasType {
				var eventType string
				if err := json.Unmarshal(rawType, &eventType); err != nil || eventType != "response.create" {
					_ = writeWebSocketJSON(rw.Writer, nativeResponsesErrorEvent("protocol_error"))
					_ = writeWebSocketClose(rw.Writer)
					return
				}
				if envelope["response"] != nil {
					requestBody, err = strictJSONObject(envelope["response"])
					if err != nil {
						_ = writeWebSocketJSON(rw.Writer, nativeResponsesErrorEvent("protocol_error"))
						_ = writeWebSocketClose(rw.Writer)
						return
					}
				} else {
					requestBody = make(map[string]json.RawMessage, len(envelope)-1)
					for key, value := range envelope {
						if key != "type" {
							requestBody[key] = value
						}
					}
				}
				if requestBody == nil {
					_ = writeWebSocketJSON(rw.Writer, nativeResponsesErrorEvent("protocol_error"))
					_ = writeWebSocketClose(rw.Writer)
					return
				}
			}
			requestJSON, err := json.Marshal(requestBody)
			if err != nil {
				_ = writeWebSocketJSON(rw.Writer, nativeResponsesErrorEvent("protocol_error"))
				_ = writeWebSocketClose(rw.Writer)
				return
			}
			parsedBody, req, err := decodeResponsesRequest(bytes.NewReader(requestJSON))
			if err != nil {
				_ = writeWebSocketJSON(rw.Writer, nativeResponsesErrorEvent("protocol_error"))
				_ = writeWebSocketClose(rw.Writer)
				return
			}
			requestBody = parsedBody
			if body := s.validateResponsesModel(req.Model, start, "responses_websocket"); body != nil {
				_ = writeWebSocketJSON(rw.Writer, nativeResponsesErrorEvent("invalid_request_error"))
				_ = writeWebSocketClose(rw.Writer)
				return
			}
			requestCtx, cancelRequest := context.WithCancel(r.Context())
			monitorDone := monitorWebSocketClientClose(conn, rw.Reader, cancelRequest)
			defer func() {
				cancelRequest()
				_ = conn.Close()
				<-monitorDone
			}()
			if provider, model, ok := s.providerForModel(req.Model); ok && provider.APIFormat == config.APIFormatOpenAIResponses {
				s.nativeOpenAIResponsesWebSocket(rw.Writer, requestCtx, requestBody, req, provider, model, start)
				_ = writeWebSocketClose(rw.Writer)
				return
			}
			messages, err := chatMessages(req.Input)
			if err != nil {
				_ = writeWebSocketJSON(rw.Writer, map[string]any{"type": "response.error", "message": err.Error()})
				_ = writeWebSocketClose(rw.Writer)
				return
			}
			result, status, body := s.completeResponse(requestCtx, req, messages, start, "responses_websocket")
			if status != http.StatusOK {
				_ = writeWebSocketFailedEvent(rw.Writer, req.Model, body)
				_ = writeWebSocketClose(rw.Writer)
				return
			}
			_ = writeWebSocketResponseEvents(rw.Writer, result)
			_ = writeWebSocketClose(rw.Writer)
			return
		}
	}
}

func writeWebSocketFailedEvent(w *bufio.Writer, model string, body map[string]any) error {
	errBody := body["error"]
	id := responseID("")
	return writeWebSocketJSON(w, map[string]any{
		"type": "response.failed",
		"response": map[string]any{
			"id":     id,
			"object": "response",
			"status": "failed",
			"model":  model,
			"output": []map[string]any{},
			"error":  errBody,
		},
		"error": errBody,
	})
}

func writeWebSocketResponseEvents(w *bufio.Writer, result map[string]any) error {
	id := stringValue(result["id"])
	model := stringValue(result["model"])
	status := stringValue(result["status"])
	if status == "" {
		status = "completed"
	}
	outputText := stringValue(result["output_text"])
	usage, _ := result["usage"].(map[string]any)

	if err := writeWebSocketJSON(w, map[string]any{
		"type": "response.created",
		"response": map[string]any{
			"id":     id,
			"object": "response",
			"model":  model,
			"status": "in_progress",
			"output": []map[string]any{},
		},
		"id":     id,
		"model":  model,
		"status": "in_progress",
	}); err != nil {
		return err
	}

	if outputText != "" {
		itemID := messageItemID(id)
		if err := writeWebSocketJSON(w, map[string]any{
			"type":         "response.output_item.added",
			"output_index": 0,
			"item": map[string]any{
				"id":      itemID,
				"type":    "message",
				"status":  "in_progress",
				"role":    "assistant",
				"content": []map[string]any{},
			},
		}); err != nil {
			return err
		}
		if err := writeWebSocketJSON(w, map[string]any{
			"type":          "response.content_part.added",
			"item_id":       itemID,
			"output_index":  0,
			"content_index": 0,
			"part": map[string]any{
				"type": "output_text",
				"text": "",
			},
		}); err != nil {
			return err
		}
		if err := writeWebSocketJSON(w, map[string]any{
			"type":          "response.output_text.delta",
			"item_id":       itemID,
			"output_index":  0,
			"content_index": 0,
			"delta":         outputText,
		}); err != nil {
			return err
		}
		if err := writeWebSocketJSON(w, map[string]any{
			"type":          "response.output_text.done",
			"item_id":       itemID,
			"output_index":  0,
			"content_index": 0,
			"text":          outputText,
		}); err != nil {
			return err
		}
		if err := writeWebSocketJSON(w, map[string]any{
			"type":          "response.content_part.done",
			"item_id":       itemID,
			"output_index":  0,
			"content_index": 0,
			"part": map[string]any{
				"type": "output_text",
				"text": outputText,
			},
		}); err != nil {
			return err
		}
		if err := writeWebSocketJSON(w, map[string]any{
			"type":         "response.output_item.done",
			"output_index": 0,
			"item": map[string]any{
				"id":     itemID,
				"type":   "message",
				"status": status,
				"role":   "assistant",
				"content": []map[string]string{{
					"type": "output_text",
					"text": outputText,
				}},
			},
		}); err != nil {
			return err
		}
	}
	if output, ok := result["output"].([]map[string]any); ok {
		for index, item := range output {
			itemType := stringValue(item["type"])
			callID := stringValue(item["call_id"])
			itemID := stringValue(item["id"])
			if itemID == "" {
				itemID = callID
			}
			name := stringValue(item["name"])
			switch itemType {
			case "function_call":
				arguments := stringValue(item["arguments"])
				if err := writeWebSocketJSON(w, map[string]any{
					"type":         "response.output_item.added",
					"output_index": index,
					"item": map[string]any{
						"type":      "function_call",
						"id":        itemID,
						"status":    "in_progress",
						"call_id":   callID,
						"name":      name,
						"arguments": "",
					},
				}); err != nil {
					return err
				}
				if err := writeWebSocketFunctionCallArguments(w, "response.function_call_arguments.delta", index, callID, arguments); err != nil {
					return err
				}
				if err := writeWebSocketFunctionCallArguments(w, "response.function_call_arguments.done", index, callID, arguments); err != nil {
					return err
				}
			case "custom_tool_call":
				input := stringValue(item["input"])
				if err := writeWebSocketJSON(w, map[string]any{
					"type":         "response.output_item.added",
					"output_index": index,
					"item": map[string]any{
						"type":    "custom_tool_call",
						"id":      itemID,
						"status":  "in_progress",
						"call_id": callID,
						"name":    name,
						"input":   "",
					},
				}); err != nil {
					return err
				}
				if err := writeWebSocketCustomToolCallInput(w, "response.custom_tool_call_input.delta", index, callID, input); err != nil {
					return err
				}
				if err := writeWebSocketCustomToolCallInput(w, "response.custom_tool_call_input.done", index, callID, input); err != nil {
					return err
				}
			default:
				continue
			}
			if err := writeWebSocketJSON(w, map[string]any{
				"type":         "response.output_item.done",
				"output_index": index,
				"item":         item,
			}); err != nil {
				return err
			}
		}
	}

	return writeWebSocketJSON(w, map[string]any{
		"type":     "response.completed",
		"response": result,
		"status":   status,
		"usage":    usage,
	})
}

func stringValue(value any) string {
	text, _ := value.(string)
	return text
}

func functionCallArgumentsEvent(event string, outputIndex int, callID, arguments string) map[string]any {
	payload := map[string]any{
		"type":         event,
		"item_id":      callID,
		"output_index": outputIndex,
	}
	if strings.HasSuffix(event, ".delta") {
		payload["delta"] = arguments
	} else {
		payload["arguments"] = arguments
	}
	return payload
}

func writeSSEFunctionCallArguments(w http.ResponseWriter, event string, outputIndex int, callID, arguments string) bool {
	return writeSSE(w, event, functionCallArgumentsEvent(event, outputIndex, callID, arguments))
}

func writeWebSocketFunctionCallArguments(w *bufio.Writer, event string, outputIndex int, callID, arguments string) error {
	return writeWebSocketJSON(w, functionCallArgumentsEvent(event, outputIndex, callID, arguments))
}

func customToolCallInputEvent(event string, outputIndex int, callID, input string) map[string]any {
	payload := map[string]any{
		"type":         event,
		"item_id":      callID,
		"output_index": outputIndex,
	}
	if strings.HasSuffix(event, ".delta") {
		payload["delta"] = input
	} else {
		payload["input"] = input
	}
	return payload
}

func writeSSECustomToolCallInput(w http.ResponseWriter, event string, outputIndex int, callID, input string) bool {
	return writeSSE(w, event, customToolCallInputEvent(event, outputIndex, callID, input))
}

func writeWebSocketCustomToolCallInput(w *bufio.Writer, event string, outputIndex int, callID, input string) error {
	return writeWebSocketJSON(w, customToolCallInputEvent(event, outputIndex, callID, input))
}

func (s *Server) completeResponse(ctx context.Context, req responsesRequest, messages []chatMessage, start time.Time, transport string) (map[string]any, int, map[string]any) {
	if model, ok := s.officialModelForModel(req.Model); ok {
		if officialUsesCodexHome(*s.config.OfficialPassthrough) {
			result, err := s.completeOfficialWithCodex(ctx, *s.config.OfficialPassthrough, model, req, messages)
			if err != nil {
				status, errorType, message := officialCodexFailureDetails(err)
				s.recordFailedUsage("openai", req.Model, errorType, status, start, transport)
				return nil, status, errorBody(errorType, message)
			}
			s.recordCompletedUsage("openai", req.Model, responseID(""), "completed", false, nil, start, transport)
			return result, http.StatusOK, nil
		}
		upstreamReq := upstreamRequest(config.APIFormatOpenAIChat, upstreamModelName(model), messages, false)
		payload, err := json.Marshal(upstreamReq)
		if err != nil {
			s.recordFailedUsage("openai", req.Model, "server_error", http.StatusInternalServerError, start, transport)
			return nil, http.StatusInternalServerError, errorBody("server_error", err.Error())
		}
		upstreamURL, err := officialUpstreamURL(*s.config.OfficialPassthrough)
		if err != nil {
			s.recordFailedUsage("openai", req.Model, "server_error", http.StatusInternalServerError, start, transport)
			return nil, http.StatusInternalServerError, errorBody("server_error", err.Error())
		}
		httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, upstreamURL, bytes.NewReader(payload))
		if err != nil {
			s.recordFailedUsage("openai", req.Model, "server_error", http.StatusInternalServerError, start, transport)
			return nil, http.StatusInternalServerError, errorBody("server_error", err.Error())
		}
		httpReq.Header.Set("Content-Type", "application/json")
		if err := s.applyOfficialAuth(httpReq, *s.config.OfficialPassthrough); err != nil {
			s.recordFailedUsage("openai", req.Model, "auth_required", http.StatusUnauthorized, start, transport)
			return nil, http.StatusUnauthorized, errorBody("auth_required", "RelayKit official credential is not configured")
		}
		resp, err := s.client.Do(httpReq)
		if err != nil {
			s.recordFailedUsage("openai", req.Model, "upstream_error", http.StatusBadGateway, start, transport)
			return nil, http.StatusBadGateway, errorBody("upstream_error", "upstream request failed")
		}
		defer resp.Body.Close()
		if resp.StatusCode < 200 || resp.StatusCode > 299 {
			s.recordFailedUsage("openai", req.Model, "upstream_non_success", http.StatusBadGateway, start, transport)
			return nil, http.StatusBadGateway, errorBody("upstream_error", fmt.Sprintf("upstream returned non-success status %d", resp.StatusCode))
		}
		var chat chatResponse
		if err := json.NewDecoder(resp.Body).Decode(&chat); err != nil {
			s.recordFailedUsage("openai", req.Model, "upstream_decode_error", http.StatusBadGateway, start, transport)
			return nil, http.StatusBadGateway, errorBody("upstream_error", err.Error())
		}
		result := responsesFromChat(chat, req.Model)
		s.recordCompletedUsage("openai", req.Model, responseID(chat.ID), chatStatus(chat), false, chat.Usage, start, transport)
		return result, http.StatusOK, nil
	}

	provider, model, ok := s.providerForModel(req.Model)
	if !ok {
		s.recordFailedUsage("unknown", req.Model, "unknown_model", http.StatusBadRequest, start, transport)
		return nil, http.StatusBadRequest, errorBody("invalid_request_error", "unknown model")
	}
	upstreamReq := upstreamRequest(provider.APIFormat, upstreamModelName(model), messages, false)
	addProviderTools(upstreamReq, provider.APIFormat, req.Tools)
	payload, err := json.Marshal(upstreamReq)
	if err != nil {
		s.recordFailedUsage(provider.ID, req.Model, "server_error", http.StatusInternalServerError, start, transport)
		return nil, http.StatusInternalServerError, errorBody("server_error", err.Error())
	}
	upstreamURL, err := providerUpstreamURL(provider)
	if err != nil {
		s.recordFailedUsage(provider.ID, req.Model, "server_error", http.StatusInternalServerError, start, transport)
		return nil, http.StatusInternalServerError, errorBody("server_error", err.Error())
	}
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, upstreamURL, bytes.NewReader(payload))
	if err != nil {
		s.recordFailedUsage(provider.ID, req.Model, "server_error", http.StatusInternalServerError, start, transport)
		return nil, http.StatusInternalServerError, errorBody("server_error", err.Error())
	}
	httpReq.Header.Set("Content-Type", "application/json")
	if err := s.applyProviderAuth(httpReq, provider); err != nil {
		s.recordFailedUsage(provider.ID, req.Model, "upstream_auth_error", http.StatusBadGateway, start, transport)
		return nil, http.StatusBadGateway, errorBody("upstream_auth_error", err.Error())
	}
	resp, err := s.client.Do(httpReq)
	if err != nil {
		s.recordFailedUsage(provider.ID, req.Model, "upstream_error", http.StatusBadGateway, start, transport)
		return nil, http.StatusBadGateway, errorBody("upstream_error", "upstream request failed")
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		s.recordFailedUsage(provider.ID, req.Model, "upstream_non_success", http.StatusBadGateway, start, transport)
		return nil, http.StatusBadGateway, errorBody("upstream_error", fmt.Sprintf("upstream returned non-success status %d", resp.StatusCode))
	}
	if provider.APIFormat == config.APIFormatAnthropicMessages {
		var msg anthropicResponse
		if err := json.NewDecoder(resp.Body).Decode(&msg); err != nil {
			s.recordFailedUsage(provider.ID, req.Model, "upstream_decode_error", http.StatusBadGateway, start, transport)
			return nil, http.StatusBadGateway, errorBody("upstream_error", err.Error())
		}
		result := responsesFromAnthropic(msg, req.Model)
		s.recordCompletedUsage(provider.ID, req.Model, responseID(msg.ID), statusFromFinish(msg.StopReason), false, msg.Usage, start, transport)
		return result, http.StatusOK, nil
	}
	var chat chatResponse
	if err := json.NewDecoder(resp.Body).Decode(&chat); err != nil {
		s.recordFailedUsage(provider.ID, req.Model, "upstream_decode_error", http.StatusBadGateway, start, transport)
		return nil, http.StatusBadGateway, errorBody("upstream_error", err.Error())
	}
	result := responsesFromChat(chat, req.Model)
	s.recordCompletedUsage(provider.ID, req.Model, responseID(chat.ID), chatStatus(chat), false, chat.Usage, start, transport)
	return result, http.StatusOK, nil
}

func (s *Server) officialResponses(w http.ResponseWriter, r *http.Request, req responsesRequest, model config.Model, messages []chatMessage, start time.Time) {
	if officialUsesCodexHome(*s.config.OfficialPassthrough) {
		result, err := s.completeOfficialWithCodex(r.Context(), *s.config.OfficialPassthrough, model, req, messages)
		if err != nil {
			status, errorType, message := officialCodexFailureDetails(err)
			s.recordFailedUsage("openai", req.Model, errorType, status, start, "responses_http")
			writeJSON(w, status, errorBody(errorType, message))
			return
		}
		usage, _ := result["usage"].(map[string]any)
		status := stringValue(result["status"])
		if status == "" {
			status = "completed"
		}
		s.recordCompletedUsage("openai", req.Model, responseID(stringValue(result["id"])), status, req.Stream, usage, start, "responses_http")
		if req.Stream {
			writeCompletedResponsesSSE(w, result)
			return
		}
		writeJSON(w, http.StatusOK, result)
		return
	}

	upstreamReq := upstreamRequest(config.APIFormatOpenAIChat, upstreamModelName(model), messages, req.Stream)
	payload, err := json.Marshal(upstreamReq)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorBody("server_error", err.Error()))
		return
	}
	upstreamURL, err := officialUpstreamURL(*s.config.OfficialPassthrough)
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
	if err := s.applyOfficialAuth(httpReq, *s.config.OfficialPassthrough); err != nil {
		s.recordFailedUsage("openai", req.Model, "auth_required", http.StatusUnauthorized, start, "responses_http")
		writeJSON(w, http.StatusUnauthorized, errorBody("auth_required", "RelayKit official credential is not configured"))
		return
	}
	resp, err := s.client.Do(httpReq)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, errorBody("upstream_error", "upstream request failed"))
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		writeJSON(w, http.StatusBadGateway, errorBody("upstream_error", fmt.Sprintf("upstream returned non-success status %d", resp.StatusCode)))
		return
	}
	if req.Stream {
		result := s.streamChat(w, resp.Body, req.Model)
		s.recordCompletedUsage("openai", req.Model, result.ID, result.Status, true, result.Usage, start, "responses_http")
		return
	}
	var chat chatResponse
	if err := json.NewDecoder(resp.Body).Decode(&chat); err != nil {
		writeJSON(w, http.StatusBadGateway, errorBody("upstream_error", err.Error()))
		return
	}
	writeJSON(w, http.StatusOK, responsesFromChat(chat, req.Model))
	s.recordCompletedUsage("openai", req.Model, responseID(chat.ID), chatStatus(chat), false, chat.Usage, start, "responses_http")
}

func writeCompletedResponsesSSE(w http.ResponseWriter, result map[string]any) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.WriteHeader(http.StatusOK)

	id := stringValue(result["id"])
	model := stringValue(result["model"])
	status := stringValue(result["status"])
	if status == "" {
		status = "completed"
	}
	outputText := stringValue(result["output_text"])
	usage, _ := result["usage"].(map[string]any)

	if !writeSSE(w, "response.created", map[string]any{
		"type": "response.created",
		"response": map[string]any{
			"id":     id,
			"object": "response",
			"model":  model,
			"status": "in_progress",
			"output": []map[string]any{},
		},
		"id":     id,
		"model":  model,
		"status": "in_progress",
	}) {
		return
	}

	if outputText != "" {
		itemID := messageItemID(id)
		if !writeSSE(w, "response.output_item.added", map[string]any{
			"type":         "response.output_item.added",
			"output_index": 0,
			"item": map[string]any{
				"id":      itemID,
				"type":    "message",
				"status":  "in_progress",
				"role":    "assistant",
				"content": []map[string]any{},
			},
		}) {
			return
		}
		if !writeSSE(w, "response.content_part.added", map[string]any{
			"type":          "response.content_part.added",
			"item_id":       itemID,
			"output_index":  0,
			"content_index": 0,
			"part": map[string]any{
				"type": "output_text",
				"text": "",
			},
		}) {
			return
		}
		if !writeSSE(w, "response.output_text.delta", map[string]any{
			"type":          "response.output_text.delta",
			"item_id":       itemID,
			"output_index":  0,
			"content_index": 0,
			"delta":         outputText,
		}) {
			return
		}
		if !writeSSE(w, "response.output_text.done", map[string]any{
			"type":          "response.output_text.done",
			"item_id":       itemID,
			"output_index":  0,
			"content_index": 0,
			"text":          outputText,
		}) {
			return
		}
		if !writeSSE(w, "response.content_part.done", map[string]any{
			"type":          "response.content_part.done",
			"item_id":       itemID,
			"output_index":  0,
			"content_index": 0,
			"part": map[string]any{
				"type": "output_text",
				"text": outputText,
			},
		}) {
			return
		}
		if !writeSSE(w, "response.output_item.done", map[string]any{
			"type":         "response.output_item.done",
			"output_index": 0,
			"item": map[string]any{
				"id":     itemID,
				"type":   "message",
				"status": status,
				"role":   "assistant",
				"content": []map[string]string{{
					"type": "output_text",
					"text": outputText,
				}},
			},
		}) {
			return
		}
	}
	if output, ok := result["output"].([]map[string]any); ok {
		for index, item := range output {
			itemType := stringValue(item["type"])
			callID := stringValue(item["call_id"])
			switch itemType {
			case "function_call":
				arguments := stringValue(item["arguments"])
				if !writeSSE(w, "response.output_item.added", map[string]any{
					"type":         "response.output_item.added",
					"output_index": index,
					"item": map[string]any{
						"type":      "function_call",
						"call_id":   callID,
						"name":      stringValue(item["name"]),
						"arguments": "",
					},
				}) ||
					!writeSSEFunctionCallArguments(w, "response.function_call_arguments.delta", index, callID, arguments) ||
					!writeSSEFunctionCallArguments(w, "response.function_call_arguments.done", index, callID, arguments) {
					return
				}
			case "custom_tool_call":
				input := stringValue(item["input"])
				if !writeSSE(w, "response.output_item.added", map[string]any{
					"type":         "response.output_item.added",
					"output_index": index,
					"item": map[string]any{
						"type":    "custom_tool_call",
						"call_id": callID,
						"name":    stringValue(item["name"]),
						"input":   "",
					},
				}) ||
					!writeSSECustomToolCallInput(w, "response.custom_tool_call_input.delta", index, callID, input) ||
					!writeSSECustomToolCallInput(w, "response.custom_tool_call_input.done", index, callID, input) {
					return
				}
			default:
				continue
			}
			if !writeSSE(w, "response.output_item.done", map[string]any{
				"type":         "response.output_item.done",
				"output_index": index,
				"item":         item,
			}) {
				return
			}
		}
	}

	_ = writeSSE(w, "response.completed", map[string]any{
		"type":     "response.completed",
		"response": result,
		"status":   status,
		"usage":    usage,
	})
}

func requestBodyReader(r *http.Request) (io.Reader, func(), error) {
	switch strings.ToLower(r.Header.Get("Content-Encoding")) {
	case "", "identity":
		return r.Body, nil, nil
	case "zstd":
		decoder, err := zstd.NewReader(r.Body)
		if err != nil {
			return nil, nil, err
		}
		return decoder, decoder.Close, nil
	default:
		return nil, nil, fmt.Errorf("unsupported content encoding")
	}
}

var errResponsesRequestTooLarge = fmt.Errorf("responses request exceeds size limit")

func decodeResponsesRequest(body io.Reader) (map[string]json.RawMessage, responsesRequest, error) {
	encoded, err := io.ReadAll(io.LimitReader(body, maximumResponsesRequestBytes+1))
	if err != nil {
		return nil, responsesRequest{}, fmt.Errorf("read request body")
	}
	if len(encoded) > maximumResponsesRequestBytes {
		return nil, responsesRequest{}, errResponsesRequestTooLarge
	}
	raw, err := strictJSONObject(encoded)
	if err != nil {
		return nil, responsesRequest{}, fmt.Errorf("invalid request body")
	}
	var req responsesRequest
	if raw["model"] != nil {
		if err := json.Unmarshal(raw["model"], &req.Model); err != nil {
			return nil, responsesRequest{}, fmt.Errorf("invalid request body")
		}
	}
	if raw["stream"] != nil {
		if err := json.Unmarshal(raw["stream"], &req.Stream); err != nil {
			return nil, responsesRequest{}, fmt.Errorf("invalid request body")
		}
	}
	req.Input = raw["input"]
	if raw["tools"] != nil {
		if err := json.Unmarshal(raw["tools"], &req.Tools); err != nil {
			return nil, responsesRequest{}, fmt.Errorf("invalid request body")
		}
	}
	req.raw = raw
	return raw, req, nil
}

func (s *Server) validateResponsesModel(model string, start time.Time, transport string) map[string]any {
	if strings.TrimSpace(model) == "" {
		s.recordFailedUsage("unknown", model, "invalid_request_error", http.StatusBadRequest, start, transport)
		return errorBody("invalid_request_error", "model is required")
	}
	if _, _, ok := s.providerForModel(model); ok {
		return nil
	}
	if _, ok := s.officialModelForModel(model); ok {
		return nil
	}
	s.recordFailedUsage("unknown", model, "unknown_model", http.StatusBadRequest, start, transport)
	return errorBody("invalid_request_error", "unknown model")
}

func upstreamPath(apiFormat string) string {
	if apiFormat == config.APIFormatAnthropicMessages {
		return "messages"
	}
	if apiFormat == config.APIFormatOpenAIResponses {
		return "responses"
	}
	return "chat/completions"
}

func providerUpstreamURL(provider config.ProviderProfile) (string, error) {
	return url.JoinPath(provider.BaseURL, providerUpstreamPath(provider))
}

func officialUpstreamURL(official config.OfficialPassthrough) (string, error) {
	return url.JoinPath(official.BaseURL, "chat/completions")
}

func providerUpstreamPath(provider config.ProviderProfile) string {
	if provider.APIFormat == config.APIFormatAnthropicMessages && anthropicBaseNeedsV1(provider.BaseURL) {
		return "v1/messages"
	}
	return upstreamPath(provider.APIFormat)
}

func anthropicBaseNeedsV1(baseURL string) bool {
	parsed, err := url.Parse(baseURL)
	if err != nil {
		return false
	}
	path := strings.TrimRight(parsed.EscapedPath(), "/")
	return path != "" && !strings.HasSuffix(path, "/v1")
}

func upstreamRequest(apiFormat, model string, messages []chatMessage, stream bool) map[string]any {
	if apiFormat == config.APIFormatAnthropicMessages {
		system, anthropicInput := anthropicMessages(messages)
		request := map[string]any{
			"model":      model,
			"max_tokens": 1024,
			"messages":   anthropicInput,
			"stream":     stream,
		}
		if system != "" {
			request["system"] = system
		}
		return request
	}
	return map[string]any{
		"model":    model,
		"messages": messages,
		"stream":   stream,
	}
}

func addProviderTools(request map[string]any, apiFormat string, tools []responsesTool) {
	if apiFormat != config.APIFormatAnthropicMessages {
		return
	}
	anthropicTools := make([]map[string]any, 0, len(tools))
	for _, tool := range tools {
		if tool.Type != "function" || tool.Name == "" {
			continue
		}
		inputSchema := tool.Parameters
		if inputSchema == nil {
			inputSchema = map[string]any{"type": "object", "properties": map[string]any{}}
		}
		anthropicTools = append(anthropicTools, map[string]any{
			"name":         tool.Name,
			"description":  tool.Description,
			"input_schema": inputSchema,
		})
	}
	if len(anthropicTools) > 0 {
		request["tools"] = anthropicTools
	}
}

func probeUpstreamRequest(apiFormat, model string) map[string]any {
	if apiFormat == config.APIFormatOpenAIResponses {
		return map[string]any{
			"model":             model,
			"input":             "Return a tiny reachability confirmation.",
			"stream":            false,
			"max_output_tokens": 16,
		}
	}
	messages := []chatMessage{{Role: "user", Content: "Return a tiny reachability confirmation."}}
	req := upstreamRequest(apiFormat, model, messages, false)
	req["max_tokens"] = 16
	return req
}

func anthropicMessages(messages []chatMessage) (string, []chatMessage) {
	var systemParts []string
	out := make([]chatMessage, 0, len(messages))
	for _, message := range messages {
		switch message.Role {
		case "system", "developer":
			systemParts = append(systemParts, message.Content)
			continue
		case "assistant":
		default:
			message.Role = "user"
		}
		if len(out) > 0 && out[len(out)-1].Role == message.Role {
			out[len(out)-1].Content += "\n\n" + message.Content
			continue
		}
		out = append(out, message)
	}
	return strings.Join(systemParts, "\n\n"), out
}

func providerAuthEnv(provider config.ProviderProfile) string {
	if provider.AuthEnv != "" {
		return provider.AuthEnv
	}
	if provider.CredentialRef != nil && provider.CredentialRef.Kind == config.CredentialKindEnv {
		return provider.CredentialRef.Value
	}
	return ""
}

func (s *Server) applyProviderAuth(req *http.Request, provider config.ProviderProfile) error {
	if authEnv := providerAuthEnv(provider); authEnv != "" {
		if token := os.Getenv(authEnv); token != "" {
			setAuthHeader(req, provider, token)
		}
		return nil
	}
	if provider.CredentialRef == nil {
		return nil
	}
	if provider.CredentialRef.Kind == config.CredentialKindKeychain {
		token, err := s.keychainCredential(provider.CredentialRef.Value)
		if err != nil {
			return err
		}
		setAuthHeader(req, provider, token)
		return nil
	}
	if provider.CredentialRef.Kind != config.CredentialKindKeyFile {
		return nil
	}
	path := strings.TrimPrefix(provider.CredentialRef.Value, "~/")
	if path != provider.CredentialRef.Value {
		if home, err := os.UserHomeDir(); err == nil {
			path = filepath.Join(home, path)
		}
	}
	body, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("credential file unavailable")
	}
	token := strings.TrimSpace(string(body))
	if token == "" {
		return fmt.Errorf("credential file is empty")
	}
	setAuthHeader(req, provider, token)
	return nil
}

func (s *Server) applyOfficialAuth(req *http.Request, official config.OfficialPassthrough) error {
	if official.CredentialRef == nil {
		return fmt.Errorf("official credential is not configured")
	}
	token, err := s.credentialRefToken(*official.CredentialRef)
	if err != nil {
		return err
	}
	setCredentialHeader(req, official.CredentialRef.Header, token)
	return nil
}

func officialUsesCodexHome(official config.OfficialPassthrough) bool {
	return official.CredentialRef != nil && official.CredentialRef.Kind == config.CredentialKindCodexHome
}

type officialCodexFailure struct {
	status    int
	errorType string
	message   string
}

func (failure *officialCodexFailure) Error() string {
	return failure.message
}

func classifyOfficialCodexFailure(stderr string, contextError error) error {
	if contextError == context.DeadlineExceeded {
		return &officialCodexFailure{
			status:    http.StatusGatewayTimeout,
			errorType: "official_timeout",
			message:   "RelayKit official Codex request timed out",
		}
	}
	normalized := strings.ToLower(stderr)
	if strings.Contains(normalized, "not supported when using codex with a chatgpt account") {
		return &officialCodexFailure{
			status:    http.StatusBadRequest,
			errorType: "model_not_supported",
			message:   "Official model is not available for this Codex account",
		}
	}
	if strings.Contains(normalized, "unknown model") {
		return &officialCodexFailure{
			status:    http.StatusBadRequest,
			errorType: "unknown_model",
			message:   "Official model is not recognized by the current Codex installation",
		}
	}
	for _, marker := range []string{"not logged in", "login required", "unauthorized", "authentication failed", "refresh token"} {
		if strings.Contains(normalized, marker) {
			return &officialCodexFailure{
				status:    http.StatusUnauthorized,
				errorType: "auth_required",
				message:   "RelayKit official Codex login is not connected",
			}
		}
	}
	return &officialCodexFailure{
		status:    http.StatusBadGateway,
		errorType: "official_request_failed",
		message:   "RelayKit official Codex request failed",
	}
}

func officialCodexFailureDetails(err error) (int, string, string) {
	if failure, ok := err.(*officialCodexFailure); ok {
		return failure.status, failure.errorType, failure.message
	}
	return http.StatusBadGateway, "official_request_failed", "RelayKit official Codex request failed"
}

type officialCodexDecision struct {
	Kind          string `json:"kind"`
	Name          string `json:"name"`
	ArgumentsJSON string `json:"arguments_json"`
	Text          string `json:"text"`
}

const officialCodexDecisionSchema = `{
  "type": "object",
  "additionalProperties": false,
  "required": ["kind", "name", "arguments_json", "text"],
  "properties": {
    "kind": {"type": "string", "enum": ["message", "function_call"]},
    "name": {"type": "string"},
    "arguments_json": {"type": "string"},
    "text": {"type": "string"}
  }
}`

const (
	explicitExecCommandPrefix   = "Use the shell tool to run exactly: "
	explicitExecCommandSuffix   = "\nThen report only the exact tool output."
	explicitExecCommandV1Prefix = "RELAYKIT_EXEC_COMMAND_V1 "
)

func (s *Server) completeOfficialWithCodex(ctx context.Context, official config.OfficialPassthrough, model config.Model, req responsesRequest, messages []chatMessage) (map[string]any, error) {
	execCapability := officialExecCommandCapability(req.Input, req.Tools)
	command, messageOnly, err := officialExplicitExecCommand(req.Input, messages, req.Tools)
	if err != nil {
		s.officialStructuralTrace.recordRejectedOfficialRequest(req.raw, req.Input, officialStructuralRejectionForError(err))
		return nil, &officialCodexFailure{
			status:    http.StatusBadRequest,
			errorType: "invalid_request_error",
			message:   "invalid explicit shell tool request",
		}
	}
	if command != "" {
		return explicitExecCommandResponse(command, model.ID, execCapability)
	}

	codexHome := strings.TrimPrefix(official.CredentialRef.Value, "~/")
	if codexHome != official.CredentialRef.Value {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, err
		}
		codexHome = filepath.Join(home, codexHome)
	}
	isolatedHome := filepath.Join(filepath.Dir(codexHome), "home")
	if err := os.MkdirAll(isolatedHome, 0700); err != nil {
		return nil, err
	}
	outDir, err := os.MkdirTemp("", "relaykit-codex-official-*")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(outDir)
	outPath := filepath.Join(outDir, "last-message.txt")
	schemaPath := filepath.Join(outDir, "tool-decision-schema.json")
	binary := official.CodexBinary
	if binary == "" {
		binary = "codex"
	}
	cmdCtx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	args := []string{"exec", "--skip-git-repo-check", "--ephemeral", "--ignore-rules", "--ignore-user-config", "--sandbox", "read-only", "--color", "never"}
	prompt := codexPrompt(messages)
	if messageOnly {
		args = append(args, "--disable", "shell_tool", "--disable", "unified_exec")
		prompt = codexExplicitToolResultPrompt(messages)
	} else if len(req.Tools) > 0 {
		if err := os.WriteFile(schemaPath, []byte(officialCodexDecisionSchema), 0600); err != nil {
			return nil, err
		}
		args = append(args, "--disable", "shell_tool", "--disable", "unified_exec", "--output-schema", schemaPath)
		prompt, err = codexToolDecisionPrompt(messages, req.Tools)
		if err != nil {
			return nil, err
		}
	}
	args = append(args, "-m", upstreamModelName(model), "-o", outPath, "-")
	cmd := exec.CommandContext(cmdCtx, binary, args...)
	cmd.Env = append(os.Environ(), "HOME="+isolatedHome, "CODEX_HOME="+codexHome)
	cmd.Stdin = strings.NewReader(prompt)
	cmd.Stdout = io.Discard
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return nil, classifyOfficialCodexFailure(stderr.String(), cmdCtx.Err())
	}
	body, err := os.ReadFile(outPath)
	if err != nil {
		return nil, err
	}
	text := strings.TrimSpace(string(body))
	if text == "" {
		return nil, fmt.Errorf("empty official response")
	}
	if messageOnly {
		return responsesFromChat(chatResponse{
			ID: "codex-official",
			Choices: []chatChoice{{
				Message:      chatMessage{Role: "assistant", Content: text},
				FinishReason: "stop",
			}},
		}, model.ID), nil
	}
	if len(req.Tools) > 0 {
		return responsesFromOfficialCodexDecision(text, req.Tools, model.ID)
	}
	return responsesFromChat(chatResponse{
		ID: "codex-official",
		Choices: []chatChoice{{
			Message:      chatMessage{Role: "assistant", Content: text},
			FinishReason: "stop",
		}},
	}, model.ID), nil
}

func codexExplicitToolResultPrompt(messages []chatMessage) string {
	return "The requested external shell command has already completed. Do not call or request any tool. " +
		"Return only the final textual answer from the completed tool result.\nConversation:\n" + codexPrompt(messages)
}

func officialExplicitExecCommand(input json.RawMessage, _ []chatMessage, tools []responsesTool) (command string, messageOnly bool, err error) {
	execCapability := officialExecCommandCapability(input, tools)
	execCommandAllowed := execCapability != officialExecCommandUnavailable
	var text string
	if json.Unmarshal(input, &text) == nil {
		command, explicit, err := parseExplicitExecCommand(text, execCommandAllowed)
		if !explicit {
			return "", false, nil
		}
		return command, false, err
	}

	var items []responsesInputItem
	if json.Unmarshal(input, &items) != nil {
		return "", false, nil
	}
	currentUser := -1
	for i := len(items) - 1; i >= 0; i-- {
		if items[i].Role == "user" && (items[i].Type == "" || items[i].Type == "message") {
			currentUser = i
			break
		}
	}
	if currentUser < 0 {
		return "", false, nil
	}
	message, ok := items[currentUser].chatMessage()
	if !ok {
		return "", false, nil
	}
	command, explicit, err := parseExplicitExecCommand(message.Content, execCommandAllowed)
	if !explicit {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	if currentUser == len(items)-1 {
		return command, false, nil
	}
	if len(items)-currentUser != 3 {
		return "", false, newOfficialStructuralRejectionError("roundtrip", "malformed", "invalid explicit shell tool roundtrip")
	}
	if err := validateExplicitExecCommandRoundTrip(command, items[currentUser+1], items[currentUser+2], execCapability); err != nil {
		return "", false, err
	}
	return "", true, nil
}

func parseExplicitExecCommand(text string, execCommandAllowed bool) (command string, explicit bool, err error) {
	if strings.HasPrefix(text, explicitExecCommandV1Prefix) {
		if strings.ContainsAny(text, "\r\n\x00") {
			return "", true, newOfficialStructuralRejectionError("command", "malformed", "invalid V1 explicit shell command line")
		}
		object, err := strictJSONObject([]byte(strings.TrimPrefix(text, explicitExecCommandV1Prefix)))
		if err != nil || len(object) != 1 {
			return "", true, newOfficialStructuralRejectionError("command", "malformed", "invalid V1 explicit shell command")
		}
		if json.Unmarshal(object["cmd"], &command) != nil || strings.TrimSpace(command) == "" || strings.ContainsAny(command, "\r\n\x00") {
			return "", true, newOfficialStructuralRejectionError("command", "malformed", "invalid V1 explicit shell command value")
		}
		if !execCommandAllowed {
			return "", true, newOfficialStructuralRejectionError("command", "incompatible", "incompatible explicit shell command")
		}
		return command, true, nil
	}
	if !strings.HasPrefix(text, explicitExecCommandPrefix) {
		return "", false, nil
	}
	candidate := strings.TrimPrefix(text, explicitExecCommandPrefix)
	if !strings.HasSuffix(candidate, explicitExecCommandSuffix) {
		return "", true, newOfficialStructuralRejectionError("command", "malformed", "malformed explicit shell command")
	}
	command = strings.TrimSuffix(candidate, explicitExecCommandSuffix)
	if command == "" || strings.ContainsAny(command, "\r\n") || !execCommandAllowed {
		return "", true, newOfficialStructuralRejectionError("command", "incompatible", "incompatible explicit shell command")
	}
	return command, true, nil
}

func validateExplicitExecCommandRoundTrip(command string, call, output responsesInputItem, capability officialExecCommandCapabilityKind) error {
	var outputType string
	switch capability {
	case officialExecCommandFunction:
		if call.Type != "function_call" || strings.TrimSpace(call.CallID) == "" || call.Name != "exec_command" {
			return newOfficialStructuralRejectionError("tool_call", "malformed", "invalid explicit shell function call")
		}
		arguments, err := strictJSONObject([]byte(call.Arguments))
		if err != nil || len(arguments) != 1 {
			return newOfficialStructuralRejectionError("call_arguments", "malformed", "invalid explicit shell function arguments")
		}
		var calledCommand string
		if json.Unmarshal(arguments["cmd"], &calledCommand) != nil || calledCommand != command {
			return newOfficialStructuralRejectionError("call_arguments", "mismatch", "explicit shell function arguments do not match")
		}
		outputType = "function_call_output"
	case officialExecCommandCustom:
		expectedInput, err := codeModeExecProgram(command)
		if err != nil {
			return err
		}
		if call.Type != "custom_tool_call" || strings.TrimSpace(call.CallID) == "" || call.Name != "exec" || call.Input != expectedInput {
			return newOfficialStructuralRejectionError("call_input", "mismatch", "invalid explicit shell custom tool call")
		}
		outputType = "custom_tool_call_output"
	default:
		return newOfficialStructuralRejectionError("tool_capability", "unavailable", "explicit shell tool capability is unavailable")
	}
	if output.Type != outputType || strings.TrimSpace(output.CallID) == "" || output.CallID != call.CallID {
		return newOfficialStructuralRejectionError("tool_output", "malformed", "invalid explicit shell tool output")
	}
	if rawJSONPresent(output.Output) && rawJSONPresent(output.Content) {
		return newOfficialStructuralRejectionError("tool_output", "ambiguous", "ambiguous explicit shell function output")
	}
	var result string
	var err error
	if rawJSONPresent(output.Output) {
		result, err = responseToolOutputText(output.Output)
	} else if rawJSONPresent(output.Content) {
		result, err = responseToolOutputText(output.Content)
	}
	if err != nil {
		return newOfficialStructuralRejectionError("tool_output", "unsupported", "invalid explicit shell function output content")
	}
	if strings.TrimSpace(result) == "" {
		return newOfficialStructuralRejectionError("tool_output", "empty", "empty explicit shell function output")
	}
	return nil
}

func officialExecCommandToolAllowed(tools []responsesTool) bool {
	found := false
	for _, tool := range tools {
		if tool.Name != "exec_command" {
			continue
		}
		if found || tool.Type != "function" || tool.Parameters["type"] != "object" {
			return false
		}
		properties, ok := tool.Parameters["properties"].(map[string]any)
		if !ok {
			return false
		}
		cmd, ok := properties["cmd"].(map[string]any)
		if !ok || cmd["type"] != "string" {
			return false
		}
		required, ok := tool.Parameters["required"].([]any)
		if !ok || len(required) != 1 || required[0] != "cmd" {
			return false
		}
		found = true
	}
	return found
}

type officialExecCommandCapabilityKind int

const (
	officialExecCommandUnavailable officialExecCommandCapabilityKind = iota
	officialExecCommandFunction
	officialExecCommandCustom
)

func officialExecCommandCapability(input json.RawMessage, tools []responsesTool) officialExecCommandCapabilityKind {
	if officialExecCommandToolAllowed(tools) {
		return officialExecCommandFunction
	}
	var items []struct {
		Type  string `json:"type"`
		Role  string `json:"role"`
		Tools []struct {
			Type string `json:"type"`
			Name string `json:"name"`
		} `json:"tools"`
	}
	if json.Unmarshal(input, &items) != nil {
		return officialExecCommandUnavailable
	}
	additionalToolsCount := 0
	execToolCount := 0
	for _, item := range items {
		if item.Type != "additional_tools" {
			continue
		}
		additionalToolsCount++
		if item.Role != "developer" || len(item.Tools) == 0 {
			return officialExecCommandUnavailable
		}
		for _, tool := range item.Tools {
			if tool.Name != "exec" {
				continue
			}
			if tool.Type != "custom" {
				return officialExecCommandUnavailable
			}
			execToolCount++
		}
	}
	if additionalToolsCount == 1 && execToolCount == 1 {
		return officialExecCommandCustom
	}
	return officialExecCommandUnavailable
}

func explicitExecCommandResponse(command, requestedModel string, capability officialExecCommandCapabilityKind) (map[string]any, error) {
	var output map[string]any
	arguments, err := json.Marshal(map[string]string{"cmd": command})
	if err != nil {
		return nil, err
	}
	response := responseID("")
	callID := strings.Replace(response, "resp_", "call_", 1)
	switch capability {
	case officialExecCommandFunction:
		output = map[string]any{
			"type":      "function_call",
			"id":        callID,
			"status":    "completed",
			"call_id":   callID,
			"name":      "exec_command",
			"arguments": string(arguments),
		}
	case officialExecCommandCustom:
		input, err := codeModeExecProgram(command)
		if err != nil {
			return nil, err
		}
		output = map[string]any{
			"type":    "custom_tool_call",
			"id":      callID,
			"status":  "completed",
			"call_id": callID,
			"name":    "exec",
			"input":   input,
		}
	default:
		return nil, fmt.Errorf("explicit shell tool capability is unavailable")
	}
	return map[string]any{
		"id":          response,
		"object":      "response",
		"status":      "completed",
		"model":       requestedModel,
		"output_text": "",
		"output":      []map[string]any{output},
		"usage":       responsesUsage(nil),
	}, nil
}

func codeModeExecProgram(command string) (string, error) {
	encoded, err := json.Marshal(command)
	if err != nil {
		return "", err
	}
	return "const result = await tools.exec_command({cmd:" + string(encoded) + "}); text(result.output);", nil
}

func codexToolDecisionPrompt(messages []chatMessage, tools []responsesTool) (string, error) {
	encodedTools, err := json.Marshal(tools)
	if err != nil {
		return "", err
	}
	return "You are choosing the next response for a separate client. Do not call or execute any of your own tools. " +
		"The client will execute an external function_call exactly once. If the conversation can be answered now, " +
		"return kind=message with final text. If an external tool is required, return kind=function_call using one exact " +
		"tool name and put a compact JSON object string in arguments_json. Use empty name, arguments_json={} and empty " +
		"text where a field does not apply.\nExternal tools: " + string(encodedTools) + "\nConversation:\n" + codexPrompt(messages), nil
}

func responsesFromOfficialCodexDecision(raw string, tools []responsesTool, requestedModel string) (map[string]any, error) {
	var decision officialCodexDecision
	if err := json.Unmarshal([]byte(raw), &decision); err != nil {
		return nil, fmt.Errorf("invalid official tool decision")
	}
	if decision.Kind == "message" {
		text := strings.TrimSpace(decision.Text)
		if text == "" {
			return nil, fmt.Errorf("empty official message decision")
		}
		return responsesFromChat(chatResponse{
			ID: "codex-official",
			Choices: []chatChoice{{
				Message:      chatMessage{Role: "assistant", Content: text},
				FinishReason: "stop",
			}},
		}, requestedModel), nil
	}
	if decision.Kind != "function_call" || !officialToolAllowed(decision.Name, tools) {
		return nil, fmt.Errorf("invalid official function decision")
	}
	arguments := normalizeToolArguments(decision.Name, strings.TrimSpace(decision.ArgumentsJSON))
	var argumentObject map[string]any
	if arguments == "" || json.Unmarshal([]byte(arguments), &argumentObject) != nil || argumentObject == nil {
		return nil, fmt.Errorf("invalid official function arguments")
	}
	response := responseID("")
	callID := strings.Replace(response, "resp_", "call_", 1)
	return map[string]any{
		"id":          response,
		"object":      "response",
		"status":      "completed",
		"model":       requestedModel,
		"output_text": "",
		"output": []map[string]any{{
			"type":      "function_call",
			"id":        callID,
			"status":    "completed",
			"call_id":   callID,
			"name":      decision.Name,
			"arguments": arguments,
		}},
		"usage": responsesUsage(nil),
	}, nil
}

func officialToolAllowed(name string, tools []responsesTool) bool {
	for _, tool := range tools {
		if tool.Type == "function" && tool.Name == name {
			return true
		}
	}
	return false
}

func codexPrompt(messages []chatMessage) string {
	var b strings.Builder
	for _, message := range messages {
		role := message.Role
		if role == "" {
			role = "user"
		}
		fmt.Fprintf(&b, "%s: %s\n", role, message.Content)
	}
	return b.String()
}

func (s *Server) credentialRefToken(ref config.CredentialRef) (string, error) {
	switch ref.Kind {
	case config.CredentialKindEnv:
		token := strings.TrimSpace(os.Getenv(ref.Value))
		if token == "" {
			return "", fmt.Errorf("environment credential unavailable")
		}
		return token, nil
	case config.CredentialKindKeychain:
		return s.keychainCredential(ref.Value)
	case config.CredentialKindKeyFile:
		path := strings.TrimPrefix(ref.Value, "~/")
		if path != ref.Value {
			if home, err := os.UserHomeDir(); err == nil {
				path = filepath.Join(home, path)
			}
		}
		body, err := os.ReadFile(path)
		if err != nil {
			return "", fmt.Errorf("credential file unavailable")
		}
		token := strings.TrimSpace(string(body))
		if token == "" {
			return "", fmt.Errorf("credential file is empty")
		}
		return token, nil
	default:
		return "", fmt.Errorf("unsupported credential kind")
	}
}

func (s *Server) keychainCredential(reference string) (string, error) {
	if token := s.keychainCredentials[reference]; token != "" {
		return token, nil
	}
	if !s.allowKeychainCLIFallback {
		return "", fmt.Errorf("keychain credential unavailable from RelayKit App")
	}
	return lookupKeychainCredential(reference)
}

func setAuthHeader(req *http.Request, provider config.ProviderProfile, token string) {
	header := ""
	if provider.CredentialRef != nil {
		header = provider.CredentialRef.Header
	}
	if header == "" && provider.APIFormat == config.APIFormatAnthropicMessages {
		header = "x-api-key"
	}
	if header == "" {
		header = "Authorization"
	}
	setCredentialHeader(req, header, token)
}

func setCredentialHeader(req *http.Request, header, token string) {
	if header == "" {
		header = "Authorization"
	}
	if header == "Authorization" {
		req.Header.Set(header, "Bearer "+token)
		return
	}
	req.Header.Set(header, token)
}

func (s *Server) providerForModel(model string) (config.ProviderProfile, config.Model, bool) {
	for _, p := range s.config.Providers {
		if !providerEnabled(p) {
			continue
		}
		for _, m := range p.Models {
			if m.ID == model {
				return p, m, true
			}
		}
	}
	return config.ProviderProfile{}, config.Model{}, false
}

func (s *Server) providerByIDAndModel(providerID, modelID string) (config.ProviderProfile, config.Model, bool) {
	for _, provider := range s.config.Providers {
		if provider.ID != providerID {
			continue
		}
		for _, model := range provider.Models {
			if model.ID == modelID {
				return provider, model, true
			}
		}
	}
	return config.ProviderProfile{}, config.Model{}, false
}

func (s *Server) officialModelForModel(model string) (config.Model, bool) {
	if s.config.OfficialPassthrough == nil {
		return config.Model{}, false
	}
	for _, m := range s.config.OfficialPassthrough.Models {
		if m.ID == model {
			return m, true
		}
	}
	return config.Model{}, false
}

func providerEnabled(provider config.ProviderProfile) bool {
	return provider.Routing.Status != config.RoutingStatusDisabled
}

func upstreamModelName(model config.Model) string {
	if model.UpstreamModel != "" {
		return model.UpstreamModel
	}
	return model.ID
}

type responsesRequest struct {
	Model  string          `json:"model"`
	Input  json.RawMessage `json:"input"`
	Stream bool            `json:"stream"`
	Tools  []responsesTool `json:"tools,omitempty"`
	raw    map[string]json.RawMessage
}

type responsesTool struct {
	Type        string         `json:"type"`
	Name        string         `json:"name"`
	Description string         `json:"description,omitempty"`
	Parameters  map[string]any `json:"parameters,omitempty"`
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
	if err := json.Unmarshal(input, &messages); err == nil {
		validMessages := len(messages) > 0
		for i := range messages {
			if messages[i].Role == "" {
				messages[i].Role = "user"
			}
			if messages[i].Content == "" {
				validMessages = false
			}
		}
		if validMessages {
			return messages, nil
		}
	}

	var items []responsesInputItem
	if err := json.Unmarshal(input, &items); err != nil {
		return nil, fmt.Errorf("input must be a string, message array, or Responses input items")
	}
	messages = nil
	for _, item := range items {
		message, ok := item.chatMessage()
		if ok {
			messages = append(messages, message)
		}
	}
	if len(messages) == 0 {
		return nil, fmt.Errorf("input must include at least one text message")
	}
	return messages, nil
}

type responsesInputItem struct {
	Type      string          `json:"type"`
	Role      string          `json:"role"`
	Content   json.RawMessage `json:"content"`
	CallID    string          `json:"call_id"`
	Name      string          `json:"name"`
	Arguments string          `json:"arguments"`
	Input     string          `json:"input"`
	Output    json.RawMessage `json:"output"`
}

func (i responsesInputItem) chatMessage() (chatMessage, bool) {
	if i.Type == "function_call_output" {
		output := ""
		if rawJSONPresent(i.Output) {
			if text, err := responseToolOutputText(i.Output); err == nil {
				output = strings.TrimSpace(text)
			}
		}
		if output == "" {
			if text, err := responseToolOutputText(i.Content); err == nil {
				output = strings.TrimSpace(text)
			}
		}
		if output == "" {
			return chatMessage{}, false
		}
		prefix := "Tool result"
		if i.CallID != "" {
			prefix += " " + i.CallID
		}
		return chatMessage{Role: "user", Content: prefix + ":\n" + output}, true
	}
	if i.Type != "" && i.Type != "message" {
		return chatMessage{}, false
	}
	role := i.Role
	if role == "" {
		role = "user"
	}

	var text string
	if err := json.Unmarshal(i.Content, &text); err == nil {
		return chatMessage{Role: role, Content: text}, text != ""
	}

	var parts []responsesInputContentPart
	if err := json.Unmarshal(i.Content, &parts); err != nil {
		return chatMessage{}, false
	}
	var texts []string
	for _, part := range parts {
		if part.Text != "" && (part.Type == "" || part.Type == "input_text" || part.Type == "text") {
			texts = append(texts, part.Text)
		}
	}
	if len(texts) == 0 {
		return chatMessage{}, false
	}
	return chatMessage{Role: role, Content: strings.Join(texts, "\n")}, true
}

func rawJSONPresent(value json.RawMessage) bool {
	trimmed := bytes.TrimSpace(value)
	return len(trimmed) > 0 && !bytes.Equal(trimmed, []byte("null"))
}

func responseToolOutputText(value json.RawMessage) (string, error) {
	if !rawJSONPresent(value) {
		return "", nil
	}
	var text string
	if err := json.Unmarshal(value, &text); err == nil {
		return text, nil
	}
	var parts []responsesInputContentPart
	if err := json.Unmarshal(value, &parts); err != nil || len(parts) == 0 {
		return "", fmt.Errorf("tool output must be text or input_text items")
	}
	texts := make([]string, 0, len(parts))
	for _, part := range parts {
		if part.Type != "input_text" || part.Text == "" {
			return "", fmt.Errorf("tool output contains an unsupported content item")
		}
		texts = append(texts, part.Text)
	}
	return strings.Join(texts, "\n"), nil
}

type responsesInputContentPart struct {
	Type string `json:"type"`
	Text string `json:"text"`
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
	Index        int             `json:"index,omitempty"`
	ContentBlock *anthropicBlock `json:"content_block,omitempty"`
	Message      *struct {
		ID    string `json:"id"`
		Model string `json:"model"`
	} `json:"message,omitempty"`
	Delta *struct {
		Type        string `json:"type,omitempty"`
		Text        string `json:"text,omitempty"`
		PartialJSON string `json:"partial_json,omitempty"`
		StopReason  string `json:"stop_reason,omitempty"`
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
	itemStarted := false
	outputText := ""
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
			status := statusFromFinish(finishReason)
			responseUsage := responsesUsage(usage)
			response := map[string]any{
				"id":          responseID(id),
				"object":      "response",
				"status":      status,
				"model":       requestedModel,
				"output":      []map[string]any{},
				"output_text": outputText,
				"usage":       responseUsage,
			}
			if itemStarted {
				itemID := messageItemID(id)
				response["output"] = []map[string]any{{
					"id":     itemID,
					"type":   "message",
					"status": status,
					"role":   "assistant",
					"content": []map[string]string{{
						"type": "output_text",
						"text": outputText,
					}},
				}}
				if !writeSSE(w, "response.output_text.done", map[string]any{
					"type":          "response.output_text.done",
					"item_id":       itemID,
					"output_index":  0,
					"content_index": 0,
					"text":          outputText,
				}) {
					return streamResult{}
				}
				if !writeSSE(w, "response.content_part.done", map[string]any{
					"type":          "response.content_part.done",
					"item_id":       itemID,
					"output_index":  0,
					"content_index": 0,
					"part": map[string]any{
						"type": "output_text",
						"text": outputText,
					},
				}) {
					return streamResult{}
				}
				if !writeSSE(w, "response.output_item.done", map[string]any{
					"type":         "response.output_item.done",
					"output_index": 0,
					"item": map[string]any{
						"id":     itemID,
						"type":   "message",
						"status": status,
						"role":   "assistant",
						"content": []map[string]string{{
							"type": "output_text",
							"text": outputText,
						}},
					},
				}) {
					return streamResult{}
				}
			}
			if !writeSSE(w, "response.completed", map[string]any{
				"type":          "response.completed",
				"response":      response,
				"status":        status,
				"finish_reason": finishReason,
				"usage":         responseUsage,
			}) {
				return streamResult{}
			}
			return streamResult{ID: responseID(id), Status: status, Usage: usage}
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
			model := requestedModel
			if model == "" {
				model = chunk.Model
			}
			if !writeSSE(w, "response.created", map[string]any{
				"type": "response.created",
				"response": map[string]any{
					"id":     responseID(chunk.ID),
					"object": "response",
					"model":  model,
					"status": "in_progress",
					"output": []map[string]any{},
				},
				"id":     responseID(chunk.ID),
				"model":  model,
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
				if !itemStarted {
					itemID := messageItemID(id)
					if !writeSSE(w, "response.output_item.added", map[string]any{
						"type":         "response.output_item.added",
						"output_index": 0,
						"item": map[string]any{
							"id":      itemID,
							"type":    "message",
							"status":  "in_progress",
							"role":    "assistant",
							"content": []map[string]any{},
						},
					}) {
						return streamResult{}
					}
					if !writeSSE(w, "response.content_part.added", map[string]any{
						"type":          "response.content_part.added",
						"item_id":       itemID,
						"output_index":  0,
						"content_index": 0,
						"part": map[string]any{
							"type": "output_text",
							"text": "",
						},
					}) {
						return streamResult{}
					}
					itemStarted = true
				}
				outputText += choice.Delta.Content
				if !writeSSE(w, "response.output_text.delta", map[string]any{
					"type":          "response.output_text.delta",
					"item_id":       messageItemID(id),
					"output_index":  0,
					"content_index": 0,
					"delta":         choice.Delta.Content,
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
	itemStarted := false
	outputText := ""
	var usage map[string]any
	tools := map[int]*streamToolCall{}
	var toolOrder []int
	var inlineToolCalls []streamToolCall
	xmlTextBuffer := ""
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
				if model == "" && payload.Message.Model != "" {
					model = payload.Message.Model
				}
				id = payload.Message.ID
			}
			if !writeSSE(w, "response.created", map[string]any{"type": "response.created", "id": responseID(id), "model": model, "status": "in_progress"}) {
				return streamResult{}
			}
		case "content_block_start":
			if payload.ContentBlock != nil && payload.ContentBlock.Type == "text" && !itemStarted {
				itemID := messageItemID(id)
				if !writeSSE(w, "response.output_item.added", map[string]any{
					"type":         "response.output_item.added",
					"output_index": 0,
					"item": map[string]any{
						"id":      itemID,
						"type":    "message",
						"status":  "in_progress",
						"role":    "assistant",
						"content": []map[string]any{},
					},
				}) {
					return streamResult{}
				}
				if !writeSSE(w, "response.content_part.added", map[string]any{
					"type":          "response.content_part.added",
					"item_id":       itemID,
					"output_index":  0,
					"content_index": 0,
					"part": map[string]any{
						"type": "output_text",
						"text": "",
					},
				}) {
					return streamResult{}
				}
				itemStarted = true
			}
			if payload.ContentBlock != nil && payload.ContentBlock.Type == "tool_use" && payload.ContentBlock.ID != "" && payload.ContentBlock.Name != "" {
				arguments := ""
				if len(payload.ContentBlock.Input) > 0 {
					arguments = string(payload.ContentBlock.Input)
					if strings.TrimSpace(arguments) == "{}" {
						arguments = ""
					}
				}
				toolName := normalizeToolName(payload.ContentBlock.Name)
				tools[payload.Index] = &streamToolCall{ID: payload.ContentBlock.ID, Name: toolName, Arguments: arguments}
				toolOrder = append(toolOrder, payload.Index)
				if !writeSSE(w, "response.output_item.added", map[string]any{"type": "response.output_item.added", "output_index": payload.Index, "item": map[string]any{"type": "function_call", "id": payload.ContentBlock.ID, "status": "in_progress", "call_id": payload.ContentBlock.ID, "name": toolName, "arguments": ""}}) {
					return streamResult{}
				}
			}
		case "content_block_delta":
			if payload.Delta != nil && payload.Delta.Text != "" {
				cleanText, calls, pendingXML := splitClaudeXMLToolCallsFromText(xmlTextBuffer + payload.Delta.Text)
				xmlTextBuffer = pendingXML
				for _, call := range calls {
					inlineToolCalls = append(inlineToolCalls, call)
					outputIndex := len(inlineToolCalls) - 1
					if itemStarted {
						outputIndex++
					}
					if !writeSSE(w, "response.output_item.added", map[string]any{"type": "response.output_item.added", "output_index": outputIndex, "item": map[string]any{"type": "function_call", "id": call.ID, "status": "in_progress", "call_id": call.ID, "name": call.Name, "arguments": ""}}) {
						return streamResult{}
					}
					if !writeSSEFunctionCallArguments(w, "response.function_call_arguments.delta", outputIndex, call.ID, call.Arguments) {
						return streamResult{}
					}
					if !writeSSEFunctionCallArguments(w, "response.function_call_arguments.done", outputIndex, call.ID, call.Arguments) {
						return streamResult{}
					}
					if !writeSSE(w, "response.output_item.done", map[string]any{"type": "response.output_item.done", "output_index": outputIndex, "item": map[string]any{"type": "function_call", "id": call.ID, "status": "completed", "call_id": call.ID, "name": call.Name, "arguments": call.Arguments}}) {
						return streamResult{}
					}
				}
				if cleanText == "" {
					break
				}
				outputText += cleanText
				if !writeSSE(w, "response.output_text.delta", map[string]any{
					"type":          "response.output_text.delta",
					"item_id":       messageItemID(id),
					"output_index":  0,
					"content_index": 0,
					"delta":         cleanText,
				}) {
					return streamResult{}
				}
			}
			if payload.Delta != nil && payload.Delta.PartialJSON != "" {
				if tool := tools[payload.Index]; tool != nil {
					tool.Arguments += payload.Delta.PartialJSON
				}
			}
		case "content_block_stop":
			if tool := tools[payload.Index]; tool != nil {
				if tool.Arguments == "" {
					tool.Arguments = "{}"
				}
				tool.Done = true
			}
		case "message_delta":
			if payload.Delta != nil {
				finishReason = payload.Delta.StopReason
			}
			if payload.Usage != nil {
				usage = payload.Usage
			}
		case "message_stop":
			for _, index := range toolOrder {
				tool := tools[index]
				if !tool.Done {
					if !writeSSE(w, "response.error", map[string]any{"type": "response.error", "message": "incomplete tool arguments"}) {
						return streamResult{}
					}
					return streamResult{}
				}
				tool.Arguments = normalizeToolArguments(tool.Name, tool.Arguments)
				if !writeSSEFunctionCallArguments(w, "response.function_call_arguments.delta", index, tool.ID, tool.Arguments) {
					return streamResult{}
				}
				if !writeSSEFunctionCallArguments(w, "response.function_call_arguments.done", index, tool.ID, tool.Arguments) {
					return streamResult{}
				}
				if !writeSSE(w, "response.output_item.done", map[string]any{"type": "response.output_item.done", "output_index": index, "item": map[string]any{"type": "function_call", "id": tool.ID, "status": "completed", "call_id": tool.ID, "name": tool.Name, "arguments": tool.Arguments}}) {
					return streamResult{}
				}
			}
			status := statusFromFinish(finishReason)
			responseUsage := responsesUsage(usage)
			responseOutput := []map[string]any{}
			response := map[string]any{
				"id":          responseID(id),
				"object":      "response",
				"status":      status,
				"model":       requestedModel,
				"output":      responseOutput,
				"output_text": outputText,
				"usage":       responseUsage,
			}
			if itemStarted {
				itemID := messageItemID(id)
				responseOutput = append(responseOutput, map[string]any{
					"id":     itemID,
					"type":   "message",
					"status": status,
					"role":   "assistant",
					"content": []map[string]string{{
						"type": "output_text",
						"text": outputText,
					}},
				})
				if !writeSSE(w, "response.output_text.done", map[string]any{
					"type":          "response.output_text.done",
					"item_id":       itemID,
					"output_index":  0,
					"content_index": 0,
					"text":          outputText,
				}) {
					return streamResult{}
				}
				if !writeSSE(w, "response.content_part.done", map[string]any{
					"type":          "response.content_part.done",
					"item_id":       itemID,
					"output_index":  0,
					"content_index": 0,
					"part": map[string]any{
						"type": "output_text",
						"text": outputText,
					},
				}) {
					return streamResult{}
				}
				if !writeSSE(w, "response.output_item.done", map[string]any{
					"type":         "response.output_item.done",
					"output_index": 0,
					"item": map[string]any{
						"id":     itemID,
						"type":   "message",
						"status": status,
						"role":   "assistant",
						"content": []map[string]string{{
							"type": "output_text",
							"text": outputText,
						}},
					},
				}) {
					return streamResult{}
				}
			}
			for _, call := range inlineToolCalls {
				responseOutput = append(responseOutput, map[string]any{
					"type":      "function_call",
					"call_id":   call.ID,
					"name":      call.Name,
					"arguments": call.Arguments,
				})
			}
			response["output"] = responseOutput
			if !writeSSE(w, "response.completed", map[string]any{
				"type":          "response.completed",
				"response":      response,
				"status":        status,
				"finish_reason": finishReason,
				"usage":         responseUsage,
			}) {
				return streamResult{}
			}
			return streamResult{ID: responseID(id), Status: status, Usage: usage}
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

type streamToolCall struct {
	ID        string
	Name      string
	Arguments string
	Done      bool
}

func responsesFromChat(chat chatResponse, requestedModel string) map[string]any {
	model := requestedModel
	if model == "" {
		model = chat.Model
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
		"id":          responseID(chat.ID),
		"object":      "response",
		"status":      status,
		"model":       model,
		"output_text": text,
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
		"usage": responsesUsage(chat.Usage),
	}
}

func responsesFromAnthropic(msg anthropicResponse, requestedModel string) map[string]any {
	model := requestedModel
	if model == "" {
		model = msg.Model
	}
	text := ""
	output := []map[string]any{}
	for _, block := range msg.Content {
		if block.Type == "text" {
			cleanText, calls := parseClaudeXMLToolCallsFromText(block.Text)
			text += cleanText
			for _, call := range calls {
				output = append(output, map[string]any{
					"type":      "function_call",
					"id":        call.ID,
					"status":    "completed",
					"call_id":   call.ID,
					"name":      call.Name,
					"arguments": call.Arguments,
				})
			}
		}
		if block.Type == "tool_use" {
			arguments := "{}"
			if len(block.Input) > 0 {
				arguments = string(block.Input)
			}
			toolName := normalizeToolName(block.Name)
			arguments = normalizeToolArguments(toolName, arguments)
			output = append(output, map[string]any{
				"type":      "function_call",
				"id":        block.ID,
				"status":    "completed",
				"call_id":   block.ID,
				"name":      toolName,
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
		"id":          responseID(msg.ID),
		"object":      "response",
		"status":      statusFromFinish(msg.StopReason),
		"model":       model,
		"output_text": text,
		"output":      output,
		"usage":       responsesUsage(msg.Usage),
	}
}

func parseClaudeXMLToolCallsFromText(text string) (string, []streamToolCall) {
	clean, calls, pending := splitClaudeXMLToolCallsFromText(text)
	if pending != "" {
		return text, nil
	}
	return clean, calls
}

func splitClaudeXMLToolCallsFromText(text string) (string, []streamToolCall, string) {
	var clean strings.Builder
	calls := []streamToolCall{}
	rest := text
	for {
		start, kind := nextClaudeToolBlockStart(rest)
		if start < 0 {
			clean.WriteString(rest)
			return clean.String(), calls, ""
		}
		clean.WriteString(rest[:start])
		closeTag := "</" + kind + ">"
		closeStart := strings.Index(rest[start:], closeTag)
		if closeStart < 0 {
			return clean.String(), calls, rest[start:]
		}
		end := start + closeStart + len(closeTag)
		block := rest[start:end]
		blockCalls := parseClaudeXMLToolCallBlock(block)
		if kind == "tool_call" {
			blockCalls = parseClaudeJSONToolCallBlock(block)
		}
		if len(blockCalls) == 0 {
			clean.WriteString(block)
		} else {
			calls = append(calls, blockCalls...)
		}
		rest = rest[end:]
	}
}

var (
	claudeInvokePattern    = regexp.MustCompile(`(?s)<invoke\b([^>]*)>(.*?)</invoke>`)
	claudeParameterPattern = regexp.MustCompile(`(?s)<parameter\b([^>]*)>(.*?)</parameter>`)
	claudeNameAttrPattern  = regexp.MustCompile(`\bname\s*=\s*["']([^"']+)["']`)
)

func nextClaudeToolBlockStart(text string) (int, string) {
	start := -1
	kind := ""
	for _, candidate := range []struct {
		tag  string
		kind string
	}{
		{"<function_calls", "function_calls"},
		{"<invoke", "invoke"},
		{"<tool_call", "tool_call"},
	} {
		index := strings.Index(text, candidate.tag)
		if index >= 0 && (start < 0 || index < start) {
			start = index
			kind = candidate.kind
		}
	}
	return start, kind
}

func parseClaudeXMLToolCallBlock(block string) []streamToolCall {
	matches := claudeInvokePattern.FindAllStringSubmatch(block, -1)
	calls := make([]streamToolCall, 0, len(matches))
	for _, match := range matches {
		name := normalizeToolName(claudeXMLNameAttr(match[1]))
		if name == "" {
			continue
		}
		args := map[string]any{}
		for _, parameter := range claudeParameterPattern.FindAllStringSubmatch(match[2], -1) {
			paramName := claudeXMLNameAttr(parameter[1])
			if paramName == "" {
				continue
			}
			if name == "exec_command" && paramName == "command" {
				paramName = "cmd"
			}
			args[paramName] = strings.TrimSpace(html.UnescapeString(parameter[2]))
		}
		argBytes, err := json.Marshal(args)
		if err != nil {
			continue
		}
		sum := sha1.Sum([]byte(name + "\x00" + string(argBytes)))
		calls = append(calls, streamToolCall{
			ID:        fmt.Sprintf("call_%x", sum[:8]),
			Name:      name,
			Arguments: string(argBytes),
			Done:      true,
		})
	}
	return calls
}

func parseClaudeJSONToolCallBlock(block string) []streamToolCall {
	openEnd := strings.Index(block, ">")
	closeStart := strings.LastIndex(block, "</tool_call>")
	if openEnd < 0 || closeStart <= openEnd {
		return nil
	}
	var raw struct {
		Name      string `json:"name"`
		Arguments any    `json:"arguments"`
		Input     any    `json:"input"`
	}
	body := strings.TrimSpace(html.UnescapeString(block[openEnd+1 : closeStart]))
	if err := json.Unmarshal([]byte(body), &raw); err != nil {
		return nil
	}
	name := normalizeToolName(raw.Name)
	if name == "" {
		return nil
	}
	args := raw.Arguments
	if args == nil {
		args = raw.Input
	}
	if args == nil {
		args = map[string]any{}
	}
	var argBytes []byte
	switch value := args.(type) {
	case string:
		if json.Valid([]byte(value)) {
			argBytes = []byte(value)
		} else {
			argBytes, _ = json.Marshal(map[string]any{"command": value})
		}
	default:
		var err error
		argBytes, err = json.Marshal(value)
		if err != nil {
			return nil
		}
	}
	arguments := normalizeToolArguments(name, string(argBytes))
	sum := sha1.Sum([]byte(name + "\x00" + arguments))
	return []streamToolCall{{
		ID:        fmt.Sprintf("call_%x", sum[:8]),
		Name:      name,
		Arguments: arguments,
		Done:      true,
	}}
}

func claudeXMLNameAttr(attrs string) string {
	match := claudeNameAttrPattern.FindStringSubmatch(attrs)
	if len(match) < 2 {
		return ""
	}
	return strings.TrimSpace(match[1])
}

func normalizeToolName(name string) string {
	switch name {
	case "bash", "shell", "mcp__shell__run_command":
		return "exec_command"
	default:
		return name
	}
}

func normalizeToolArguments(name string, arguments string) string {
	if name != "exec_command" || arguments == "" {
		return arguments
	}
	var args map[string]any
	if err := json.Unmarshal([]byte(arguments), &args); err != nil {
		return arguments
	}
	if _, ok := args["cmd"]; !ok {
		if value, ok := args["command"]; ok {
			args["cmd"] = value
			delete(args, "command")
		}
	}
	normalized, err := json.Marshal(args)
	if err != nil {
		return arguments
	}
	return string(normalized)
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

func messageItemID(id string) string {
	return strings.Replace(responseID(id), "resp_", "msg_", 1)
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

func responsesUsage(usage map[string]any) map[string]any {
	if usage == nil {
		return nil
	}
	input := tokenCount(usage, "input_tokens", "prompt_tokens")
	output := tokenCount(usage, "output_tokens", "completion_tokens")
	total := tokenCount(usage, "total_tokens")
	if total == 0 {
		total = input + output
	}
	return map[string]any{
		"input_tokens":  input,
		"output_tokens": output,
		"total_tokens":  total,
	}
}

type usageEvent struct {
	Timestamp    string `json:"timestamp"`
	RequestID    string `json:"request_id,omitempty"`
	ProviderID   string `json:"provider_id"`
	Model        string `json:"model"`
	Route        string `json:"route"`
	Transport    string `json:"transport"`
	Streaming    bool   `json:"streaming"`
	Status       string `json:"status"`
	HTTPStatus   int    `json:"http_status"`
	ErrorType    string `json:"error_type,omitempty"`
	InputTokens  int64  `json:"input_tokens,omitempty"`
	OutputTokens int64  `json:"output_tokens,omitempty"`
	TotalTokens  int64  `json:"total_tokens,omitempty"`
	DurationMS   int64  `json:"duration_ms"`
}

func (s *Server) recordCompletedUsage(providerID, model, requestID, status string, streaming bool, usage map[string]any, start time.Time, transport string) {
	normalizedUsage := responsesUsage(usage)
	s.recordUsage(usageEvent{
		Timestamp:    time.Now().UTC().Format(time.RFC3339Nano),
		RequestID:    requestID,
		ProviderID:   providerID,
		Model:        model,
		Route:        "/v1/responses",
		Transport:    transport,
		Streaming:    streaming,
		Status:       status,
		HTTPStatus:   http.StatusOK,
		DurationMS:   time.Since(start).Milliseconds(),
		InputTokens:  tokenCount(normalizedUsage, "input_tokens"),
		OutputTokens: tokenCount(normalizedUsage, "output_tokens"),
		TotalTokens:  tokenCount(normalizedUsage, "total_tokens"),
	})
}

func (s *Server) recordFailedUsage(providerID, model, errorType string, httpStatus int, start time.Time, transport string) {
	s.recordUsage(usageEvent{
		Timestamp:  time.Now().UTC().Format(time.RFC3339Nano),
		ProviderID: providerID,
		Model:      model,
		Route:      "/v1/responses",
		Transport:  transport,
		Status:     "failed",
		HTTPStatus: httpStatus,
		ErrorType:  errorType,
		DurationMS: time.Since(start).Milliseconds(),
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

const (
	websocketOpcodeText   = 0x1
	websocketOpcodeBinary = 0x2
	websocketOpcodeClose  = 0x8
	websocketOpcodePing   = 0x9
	websocketOpcodePong   = 0xa
)

func isWebSocketUpgrade(r *http.Request) bool {
	return strings.EqualFold(r.Header.Get("Upgrade"), "websocket") &&
		strings.Contains(strings.ToLower(r.Header.Get("Connection")), "upgrade")
}

func acceptWebSocket(w http.ResponseWriter, r *http.Request) (net.Conn, *bufio.ReadWriter, error) {
	key := strings.TrimSpace(r.Header.Get("Sec-WebSocket-Key"))
	if key == "" {
		writeJSON(w, http.StatusBadRequest, errorBody("invalid_request_error", "Sec-WebSocket-Key is required"))
		return nil, nil, fmt.Errorf("missing websocket key")
	}
	hijacker, ok := w.(http.Hijacker)
	if !ok {
		writeJSON(w, http.StatusInternalServerError, errorBody("server_error", "websocket hijack unavailable"))
		return nil, nil, fmt.Errorf("hijack unavailable")
	}
	conn, rw, err := hijacker.Hijack()
	if err != nil {
		return nil, nil, err
	}
	accept := websocketAcceptKey(key)
	if _, err := fmt.Fprintf(rw, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept); err != nil {
		_ = conn.Close()
		return nil, nil, err
	}
	if err := rw.Flush(); err != nil {
		_ = conn.Close()
		return nil, nil, err
	}
	return conn, rw, nil
}

func monitorWebSocketClientClose(conn net.Conn, reader *bufio.Reader, cancel context.CancelFunc) <-chan struct{} {
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			opcode, _, err := readWebSocketFrame(reader)
			if err != nil || opcode == websocketOpcodeClose {
				cancel()
				_ = conn.Close()
				return
			}
		}
	}()
	return done
}

func websocketAcceptKey(key string) string {
	sum := sha1.Sum([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	return base64.StdEncoding.EncodeToString(sum[:])
}

func readWebSocketFrame(r *bufio.Reader) (byte, []byte, error) {
	header, err := r.ReadByte()
	if err != nil {
		return 0, nil, err
	}
	lengthByte, err := r.ReadByte()
	if err != nil {
		return 0, nil, err
	}
	opcode := header & 0x0f
	masked := lengthByte&0x80 != 0
	length := uint64(lengthByte & 0x7f)
	switch length {
	case 126:
		var extended [2]byte
		if _, err := io.ReadFull(r, extended[:]); err != nil {
			return 0, nil, err
		}
		length = uint64(binary.BigEndian.Uint16(extended[:]))
	case 127:
		var extended [8]byte
		if _, err := io.ReadFull(r, extended[:]); err != nil {
			return 0, nil, err
		}
		length = binary.BigEndian.Uint64(extended[:])
	}
	if length > 1<<20 {
		return 0, nil, fmt.Errorf("websocket frame too large")
	}
	var mask [4]byte
	if masked {
		if _, err := io.ReadFull(r, mask[:]); err != nil {
			return 0, nil, err
		}
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(r, payload); err != nil {
		return 0, nil, err
	}
	if masked {
		for i := range payload {
			payload[i] ^= mask[i%4]
		}
	}
	return opcode, payload, nil
}

func writeWebSocketJSON(w *bufio.Writer, value any) error {
	body, err := json.Marshal(value)
	if err != nil {
		body = []byte(`{"type":"response.error","message":"websocket_encode_error"}`)
	}
	return writeWebSocketFrame(w, websocketOpcodeText, body)
}

func writeWebSocketClose(w *bufio.Writer) error {
	return writeWebSocketFrame(w, websocketOpcodeClose, nil)
}

func writeWebSocketFrame(w *bufio.Writer, opcode byte, payload []byte) error {
	frame := []byte{0x80 | opcode}
	switch {
	case len(payload) < 126:
		frame = append(frame, byte(len(payload)))
	case len(payload) <= 65535:
		frame = append(frame, 126, byte(len(payload)>>8), byte(len(payload)))
	default:
		frame = append(frame, 127)
		var extended [8]byte
		binary.BigEndian.PutUint64(extended[:], uint64(len(payload)))
		frame = append(frame, extended[:]...)
	}
	frame = append(frame, payload...)
	if _, err := w.Write(frame); err != nil {
		return err
	}
	return w.Flush()
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
