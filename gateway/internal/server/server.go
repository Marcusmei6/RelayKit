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
	"sync"
	"sync/atomic"
	"time"

	"github.com/klauspost/compress/zstd"

	"relaykit/gateway/internal/config"
)

type Server struct {
	config                   *config.Config
	client                   *http.Client
	handler                  http.Handler
	usageLogPath             string
	credentialMu             sync.RWMutex
	keychainCredentials      map[string]string
	allowKeychainCLIFallback bool
	fallbackOfficialOnly     atomic.Bool
	fallbackProviderTest     atomic.Bool
	officialAuthRefreshMu    sync.Mutex
	compactionTargetMu       sync.Mutex
	compactionTargets        map[string]compactionTargetHint
	officialCodexBaseURL     string
	catalogState             *catalogState
}

const (
	maximumResponsesRequestBytes           = 32 << 20
	maximumResponsesWebSocketEnvelopeBytes = 64 << 10
	maximumWebSocketControlPayloadBytes    = 125
	maximumProviderTestRequestBytes        = 64 << 10
)

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

func New(configPath string) (*Server, error) {
	return NewWithUsageLog(configPath, "")
}

func NewWithUsageLog(configPath, usageLogPath string) (*Server, error) {
	return newServer(configPath, usageLogPath, nil, true)
}

func NewWithUsageLogAndCredentials(configPath, usageLogPath string, credentials map[string]string) (*Server, error) {
	return newServer(configPath, usageLogPath, credentials, false)
}

func newServer(configPath, usageLogPath string, credentials map[string]string, allowKeychainCLIFallback bool) (*Server, error) {
	return newServerWithOfficialEndpoint(configPath, usageLogPath, credentials, allowKeychainCLIFallback, config.OfficialCodexBaseURL)
}

func newServerWithOfficialEndpoint(configPath, usageLogPath string, credentials map[string]string, allowKeychainCLIFallback bool, officialCodexBaseURL string) (*Server, error) {
	credentialCopy := make(map[string]string, len(credentials))
	for reference, value := range credentials {
		credentialCopy[reference] = value
	}
	s := &Server{
		client:                   http.DefaultClient,
		keychainCredentials:      credentialCopy,
		allowKeychainCLIFallback: allowKeychainCLIFallback,
		officialCodexBaseURL:     officialCodexBaseURL,
		catalogState:             newCatalogState(),
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
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.healthz)
	mux.HandleFunc("GET /v1/models", s.models)
	mux.HandleFunc("POST /_relaykit/provider-test", s.providerTest)
	mux.HandleFunc("GET /v1/responses", s.responsesWebSocket)
	mux.HandleFunc("POST /v1/responses", s.responses)
	mux.HandleFunc("POST /v1/responses/compact", s.officialResponsesCompact)
	s.handler = mux
	return s, nil
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.handler.ServeHTTP(w, r)
}

// EnterFallbackOfficialOnly preserves the listener for already-running Codex
// clients while removing provider credential capability after the App owner
// exits. Official passthrough remains available through its existing route.
func (s *Server) EnterFallbackOfficialOnly() {
	s.fallbackOfficialOnly.Store(true)
	s.fallbackProviderTest.Store(false)
	s.credentialMu.Lock()
	for reference := range s.keychainCredentials {
		delete(s.keychainCredentials, reference)
	}
	s.credentialMu.Unlock()
}

func (s *Server) EnterFallbackWithCredentials(credentials map[string]string) {
	s.replaceRuntimeCredentials(credentials)
	s.fallbackProviderTest.Store(true)
	s.fallbackOfficialOnly.Store(true)
}

func (s *Server) EnterManaged(credentials map[string]string) {
	s.replaceRuntimeCredentials(credentials)
	s.fallbackProviderTest.Store(false)
	s.fallbackOfficialOnly.Store(false)
}

func (s *Server) replaceRuntimeCredentials(credentials map[string]string) {
	replacement := make(map[string]string, len(credentials))
	for reference, value := range credentials {
		replacement[reference] = value
	}
	s.credentialMu.Lock()
	for reference := range s.keychainCredentials {
		delete(s.keychainCredentials, reference)
	}
	for reference, value := range replacement {
		s.keychainCredentials[reference] = value
	}
	s.credentialMu.Unlock()
}

func (s *Server) IsOfficialFallback() bool {
	return s.fallbackOfficialOnly.Load()
}

func (s *Server) providerRouteUnavailable(model string) bool {
	if !s.fallbackOfficialOnly.Load() {
		return false
	}
	_, _, ok := s.providerForModel(model)
	return ok
}

func fallbackProviderError() map[string]any {
	return errorBody("restart_codex_required", "RelayKit was disabled. Restart Codex before using provider models.")
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
	mode := "managed"
	if s.fallbackOfficialOnly.Load() {
		mode = "official_fallback"
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"service":                "relaykit",
		"status":                 "ok",
		"mode":                   mode,
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
	if s.fallbackOfficialOnly.Load() && !s.fallbackProviderTest.Load() {
		writeProviderTestResult(w, http.StatusConflict, request, "failed", "restart_codex_required")
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
	s.catalogState.markProviderTestReachable(provider.ID, model.ID, catalogConfigFingerprint(provider, model), time.Now())
	writeProviderTestResult(w, http.StatusOK, request, "ok", "")
}

func decodeProviderTestRequest(body io.Reader) (providerTestRequest, error) {
	encoded, err := io.ReadAll(io.LimitReader(body, maximumProviderTestRequestBytes+1))
	if err != nil || len(encoded) > maximumProviderTestRequestBytes {
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
	configured := make([]map[string]any, 0, len(candidates))
	discovered := make([]map[string]any, 0, len(candidates))
	routeReachable := make([]map[string]any, 0, len(candidates))
	temporarilyUnavailable := make([]map[string]any, 0)
	lastKnownGood := make([]map[string]any, 0)
	probed := false
	data := make([]map[string]any, 0, len(candidates))
	unhealthyCount := 0
	hidden := make([]map[string]any, 0)
	for _, candidate := range candidates {
		configured = append(configured, map[string]any{"id": candidate.model.ID})
		if candidate.provider.ID == "" || !shouldProbeCatalogModel(candidate.provider) {
			data = append(data, candidate.entry)
			continue
		}
		probed = true
		fingerprint := catalogConfigFingerprint(candidate.provider, candidate.model)
		probe := s.probeModel(candidate.provider, candidate.model)
		if probe.discovered {
			discovered = append(discovered, map[string]any{"id": candidate.model.ID})
		}
		if probe.routeReachable {
			s.catalogState.markRouteReachable(candidate.provider.ID, candidate.model.ID, fingerprint, time.Now())
		}
		snapshot, hasSnapshot := s.catalogState.lastKnownGood(candidate.provider.ID, candidate.model.ID, fingerprint)
		if hasSnapshot {
			lastKnownGood = append(lastKnownGood, map[string]any{
				"id":                 candidate.model.ID,
				"timestamp":          snapshot.Timestamp.Format(time.RFC3339Nano),
				"config_fingerprint": snapshot.ConfigFingerprint,
				"stale":              snapshot.Stale,
			})
		}
		providerTestReachable := s.catalogState.providerTestReachable(candidate.provider.ID, candidate.model.ID, fingerprint)
		if probe.routeReachable || providerTestReachable {
			routeReachable = append(routeReachable, map[string]any{"id": candidate.model.ID})
		}
		if probe.routeReachable || providerTestReachable || (hasSnapshot && !snapshot.Stale) {
			data = append(data, candidate.entry)
			continue
		}
		if probe.routeAttempted {
			unhealthyCount++
			hidden = append(hidden, map[string]any{
				"id":     candidate.model.ID,
				"reason": healthReason(probe.routeFailure),
			})
			continue
		}
		temporarilyUnavailable = append(temporarilyUnavailable, map[string]any{
			"id":     candidate.model.ID,
			"reason": healthReason(probe.discoveryFailure),
		})
		data = append(data, candidate.entry)
	}
	return data, map[string]any{
		"probed":                  probed,
		"healthy":                 len(data),
		"unhealthy":               unhealthyCount,
		"configured":              configured,
		"discovered":              discovered,
		"route_reachable":         routeReachable,
		"temporarily_unavailable": temporarilyUnavailable,
		"hidden":                  hidden,
		"last_known_good":         lastKnownGood,
	}
}

func shouldProbeCatalogModel(provider config.ProviderProfile) bool {
	return provider.CredentialRef != nil &&
		(provider.CredentialRef.Kind == config.CredentialKindKeyFile || provider.CredentialRef.Kind == config.CredentialKindKeychain)
}

type catalogProbeResult struct {
	discovered       bool
	discoveryFailure string
	routeAttempted   bool
	routeReachable   bool
	routeFailure     string
}

func (s *Server) probeModel(provider config.ProviderProfile, model config.Model) catalogProbeResult {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()

	modelsURL, err := providerModelsURL(provider)
	if err != nil {
		return catalogProbeResult{discoveryFailure: "network failed"}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, modelsURL, nil)
	if err != nil {
		return catalogProbeResult{discoveryFailure: "network failed"}
	}
	if err := s.applyProviderAuth(req, provider); err != nil {
		return catalogProbeResult{discoveryFailure: "auth failed"}
	}
	resp, err := s.client.Do(req)
	if err != nil {
		return catalogProbeResult{discoveryFailure: "network failed"}
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return catalogProbeResult{discoveryFailure: "auth failed"}
	}
	if resp.StatusCode == http.StatusNotFound {
		return catalogProbeResult{discoveryFailure: "discovery unavailable"}
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return catalogProbeResult{discoveryFailure: fmt.Sprintf("upstream non-success (HTTP %d)", resp.StatusCode)}
	}
	if !modelListContains(body, upstreamModelName(model)) {
		return catalogProbeResult{discoveryFailure: "model not discovered"}
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
		ok, reason = probeRoute()
	}
	return catalogProbeResult{discovered: true, routeAttempted: true, routeReachable: ok, routeFailure: reason}
}

func healthReason(reason string) string {
	if strings.HasPrefix(reason, "upstream non-success") {
		return reason
	}
	switch reason {
	case "auth failed", "network failed", "discovery unavailable", "model not discovered", "upstream non-success", "unsupported model", "upstream decode error", "upstream response not completed":
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
	if s.providerRouteUnavailable(req.Model) {
		if provider, _, ok := s.providerForModel(req.Model); ok {
			s.recordFailedUsage(provider.ID, req.Model, "restart_codex_required", http.StatusConflict, start, "responses_http")
		}
		writeJSON(w, http.StatusConflict, fallbackProviderError())
		return
	}
	officialCompaction, officialCompactionModel, officialCompactionOK := s.observeOfficialCompactionTarget(req)
	if model, ok := s.officialModelForModel(req.Model); ok && officialUsesCodexHome(*s.config.OfficialPassthrough) {
		s.officialOpenAIResponses(w, r, rawRequest, req, *s.config.OfficialPassthrough, model, start, false)
		return
	}
	if provider, model, ok := s.providerForModel(req.Model); ok && provider.APIFormat == config.APIFormatOpenAIResponses {
		s.nativeOpenAIResponses(w, r, rawRequest, req, provider, model, start)
		return
	}
	if provider, _, ok := s.providerForModel(req.Model); ok && responsesInputHasCompactionTrigger(req.Input) {
		if officialCompactionOK {
			req.Model = officialCompactionModel.ID
			s.officialOpenAIResponses(w, r, rawRequest, req, officialCompaction, officialCompactionModel, start, false)
			return
		}
		s.recordFailedUsage(provider.ID, req.Model, "invalid_request_error", http.StatusBadRequest, start, "responses_http")
		writeJSON(w, http.StatusBadRequest, errorBody("invalid_request_error", "provider adapter does not support Responses compaction"))
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

	type inboundFrame struct {
		opcode  byte
		payload []byte
	}
	frames := make(chan inboundFrame, 1)
	readerResult := make(chan error, 1)
	var cancelMu sync.Mutex
	var cancelInFlight context.CancelFunc
	cancelCurrent := func() {
		cancelMu.Lock()
		cancel := cancelInFlight
		cancelMu.Unlock()
		if cancel != nil {
			cancel()
		}
	}
	setCancel := func(cancel context.CancelFunc) {
		cancelMu.Lock()
		cancelInFlight = cancel
		cancelMu.Unlock()
	}
	clearCancel := func() {
		cancelMu.Lock()
		cancelInFlight = nil
		cancelMu.Unlock()
	}
	go func() {
		for {
			opcode, payload, err := readWebSocketFrame(rw.Reader, maximumResponsesRequestBytes+maximumResponsesWebSocketEnvelopeBytes)
			if err != nil {
				cancelCurrent()
				readerResult <- err
				return
			}
			if opcode == websocketOpcodeClose {
				cancelCurrent()
				readerResult <- nil
				return
			}
			if opcode == websocketOpcodePong {
				continue
			}
			select {
			case frames <- inboundFrame{opcode: opcode, payload: payload}:
			default:
				cancelCurrent()
				readerResult <- fmt.Errorf("websocket client sent concurrent frames")
				return
			}
		}
	}()

	for {
		var frame inboundFrame
		select {
		case err := <-readerResult:
			if err != nil {
				_ = writeWebSocketClose(rw.Writer)
			}
			return
		case frame = <-frames:
		}
		opcode, payload := frame.opcode, frame.payload
		switch opcode {
		case websocketOpcodePing:
			_ = writeWebSocketFrame(rw.Writer, websocketOpcodePong, payload)
		case websocketOpcodeText, websocketOpcodeBinary:
			start := time.Now()
			envelope, err := strictJSONObject(payload)
			if err != nil {
				_ = writeWebSocketJSON(rw.Writer, nativeResponsesErrorEvent("protocol_error"))
				_ = writeWebSocketClose(rw.Writer)
				return
			}
			requestJSON := payload
			if rawType, hasType := envelope["type"]; hasType {
				var eventType string
				if err := json.Unmarshal(rawType, &eventType); err != nil || eventType != "response.create" {
					_ = writeWebSocketJSON(rw.Writer, nativeResponsesErrorEvent("protocol_error"))
					_ = writeWebSocketClose(rw.Writer)
					return
				}
				if rawResponse, hasResponse := envelope["response"]; hasResponse {
					if _, err := strictJSONObject(rawResponse); err != nil {
						_ = writeWebSocketJSON(rw.Writer, nativeResponsesErrorEvent("protocol_error"))
						_ = writeWebSocketClose(rw.Writer)
						return
					}
					if len(payload)-len(rawResponse) > maximumResponsesWebSocketEnvelopeBytes {
						_ = writeWebSocketJSON(rw.Writer, nativeResponsesErrorEvent("protocol_error"))
						_ = writeWebSocketClose(rw.Writer)
						return
					}
					requestJSON = rawResponse
				} else {
					requestBody := make(map[string]json.RawMessage, len(envelope)-1)
					for key, value := range envelope {
						if key != "type" {
							requestBody[key] = value
						}
					}
					var encoded bytes.Buffer
					encoder := json.NewEncoder(&encoded)
					encoder.SetEscapeHTML(false)
					if err := encoder.Encode(requestBody); err != nil {
						_ = writeWebSocketJSON(rw.Writer, nativeResponsesErrorEvent("protocol_error"))
						_ = writeWebSocketClose(rw.Writer)
						return
					}
					requestJSON = bytes.TrimSuffix(encoded.Bytes(), []byte{'\n'})
				}
			}
			parsedBody, req, err := decodeResponsesRequest(bytes.NewReader(requestJSON))
			if err != nil {
				_ = writeWebSocketJSON(rw.Writer, nativeResponsesErrorEvent("protocol_error"))
				_ = writeWebSocketClose(rw.Writer)
				return
			}
			requestBody := parsedBody
			if body := s.validateResponsesModel(req.Model, start, "responses_websocket"); body != nil {
				_ = writeWebSocketJSON(rw.Writer, nativeResponsesErrorEvent("invalid_request_error"))
				_ = writeWebSocketClose(rw.Writer)
				return
			}
			if s.providerRouteUnavailable(req.Model) {
				if provider, _, ok := s.providerForModel(req.Model); ok {
					s.recordFailedUsage(provider.ID, req.Model, "restart_codex_required", http.StatusConflict, start, "responses_websocket")
				}
				_ = writeWebSocketFailedEvent(rw.Writer, req.Model, fallbackProviderError())
				continue
			}
			officialCompaction, officialCompactionModel, officialCompactionOK := s.observeOfficialCompactionTarget(req)
			requestCtx, cancelRequest := context.WithCancel(r.Context())
			setCancel(cancelRequest)
			finishRequest := func() {
				clearCancel()
				cancelRequest()
			}
			if model, ok := s.officialModelForModel(req.Model); ok && officialUsesCodexHome(*s.config.OfficialPassthrough) {
				s.officialOpenAIResponsesWebSocket(rw.Writer, requestCtx, r.Header, requestBody, req, *s.config.OfficialPassthrough, model, start)
				finishRequest()
				continue
			}
			if provider, model, ok := s.providerForModel(req.Model); ok && provider.APIFormat == config.APIFormatOpenAIResponses {
				s.nativeOpenAIResponsesWebSocket(rw.Writer, requestCtx, requestBody, req, provider, model, start)
				finishRequest()
				continue
			}
			if provider, _, ok := s.providerForModel(req.Model); ok && responsesInputHasCompactionTrigger(req.Input) {
				if officialCompactionOK {
					req.Model = officialCompactionModel.ID
					s.officialOpenAIResponsesWebSocket(rw.Writer, requestCtx, r.Header, requestBody, req, officialCompaction, officialCompactionModel, start)
					finishRequest()
					continue
				}
				s.recordFailedUsage(provider.ID, req.Model, "invalid_request_error", http.StatusBadRequest, start, "responses_websocket")
				_ = writeWebSocketFailedEvent(rw.Writer, req.Model, errorBody("invalid_request_error", "provider adapter does not support Responses compaction"))
				finishRequest()
				continue
			}
			messages, err := chatMessages(req.Input)
			if err != nil {
				_ = writeWebSocketJSON(rw.Writer, map[string]any{"type": "response.error", "message": err.Error()})
				_ = writeWebSocketClose(rw.Writer)
				finishRequest()
				return
			}
			result, status, body := s.completeResponse(requestCtx, req, messages, start, "responses_websocket")
			if status != http.StatusOK {
				_ = writeWebSocketFailedEvent(rw.Writer, req.Model, body)
				finishRequest()
				continue
			}
			_ = writeWebSocketResponseEvents(rw.Writer, result)
			finishRequest()
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
	if raw["client_metadata"] != nil {
		if err := json.Unmarshal(raw["client_metadata"], &req.ClientMetadata); err != nil {
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
	s.credentialMu.RLock()
	token := s.keychainCredentials[reference]
	s.credentialMu.RUnlock()
	if token != "" {
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
	Model          string                  `json:"model"`
	Input          json.RawMessage         `json:"input"`
	Stream         bool                    `json:"stream"`
	Tools          []responsesTool         `json:"tools,omitempty"`
	ClientMetadata responsesClientMetadata `json:"client_metadata,omitempty"`
	raw            map[string]json.RawMessage
}

type responsesClientMetadata struct {
	SessionID    string `json:"session_id"`
	ThreadID     string `json:"thread_id"`
	TurnMetadata string `json:"x-codex-turn-metadata"`
}

type responsesTurnMetadata struct {
	RequestKind string `json:"request_kind"`
	SessionID   string `json:"session_id"`
	ThreadID    string `json:"thread_id"`
}

type compactionTargetHint struct {
	model     string
	expiresAt time.Time
}

const (
	compactionTargetHintTTL    = 30 * time.Second
	maximumCompactionTargetIDs = 256
	maximumCompactionTargets   = 256
)

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

func (s *Server) observeOfficialCompactionTarget(req responsesRequest) (config.OfficialPassthrough, config.Model, bool) {
	var metadata responsesTurnMetadata
	if err := json.Unmarshal([]byte(req.ClientMetadata.TurnMetadata), &metadata); err != nil {
		return config.OfficialPassthrough{}, config.Model{}, false
	}
	outerSessionID := strings.TrimSpace(req.ClientMetadata.SessionID)
	innerSessionID := strings.TrimSpace(metadata.SessionID)
	outerThreadID := strings.TrimSpace(req.ClientMetadata.ThreadID)
	innerThreadID := strings.TrimSpace(metadata.ThreadID)
	if (outerSessionID != "" && innerSessionID != "" && outerSessionID != innerSessionID) ||
		(outerThreadID != "" && innerThreadID != "" && outerThreadID != innerThreadID) {
		return config.OfficialPassthrough{}, config.Model{}, false
	}
	sessionID := outerSessionID
	if sessionID == "" {
		sessionID = innerSessionID
	}
	threadID := outerThreadID
	if threadID == "" {
		threadID = innerThreadID
	}
	if sessionID == "" || threadID == "" || len(sessionID) > maximumCompactionTargetIDs || len(threadID) > maximumCompactionTargetIDs {
		return config.OfficialPassthrough{}, config.Model{}, false
	}
	key := sessionID + "\x00" + threadID
	now := time.Now()
	s.compactionTargetMu.Lock()
	defer s.compactionTargetMu.Unlock()
	if s.compactionTargets == nil {
		s.compactionTargets = make(map[string]compactionTargetHint)
	}
	for candidate, hint := range s.compactionTargets {
		if !hint.expiresAt.After(now) {
			delete(s.compactionTargets, candidate)
		}
	}
	switch metadata.RequestKind {
	case "prewarm":
		if _, exists := s.compactionTargets[key]; !exists && len(s.compactionTargets) >= maximumCompactionTargets {
			return config.OfficialPassthrough{}, config.Model{}, false
		}
		s.compactionTargets[key] = compactionTargetHint{model: req.Model, expiresAt: now.Add(compactionTargetHintTTL)}
		return config.OfficialPassthrough{}, config.Model{}, false
	case "compaction":
		hint, ok := s.compactionTargets[key]
		delete(s.compactionTargets, key)
		if !ok || s.config.OfficialPassthrough == nil || !officialUsesCodexHome(*s.config.OfficialPassthrough) {
			return config.OfficialPassthrough{}, config.Model{}, false
		}
		for _, model := range s.config.OfficialPassthrough.Models {
			if model.ID == hint.model {
				return *s.config.OfficialPassthrough, model, true
			}
		}
		return config.OfficialPassthrough{}, config.Model{}, false
	default:
		delete(s.compactionTargets, key)
		return config.OfficialPassthrough{}, config.Model{}, false
	}
}

func responsesInputHasCompactionTrigger(input json.RawMessage) bool {
	var items []json.RawMessage
	if err := json.Unmarshal(input, &items); err != nil {
		return false
	}
	for _, rawItem := range items {
		var item struct {
			Type string `json:"type"`
		}
		if json.Unmarshal(rawItem, &item) == nil && item.Type == "compaction_trigger" {
			return true
		}
	}
	return false
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
		if part.Text != "" && (part.Type == "" || part.Type == "input_text" || part.Type == "output_text" || part.Type == "text") {
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
	s.recordCompletedUsageRoute(providerID, model, requestID, status, streaming, usage, start, transport, "/v1/responses")
}

func (s *Server) recordCompletedUsageRoute(providerID, model, requestID, status string, streaming bool, usage map[string]any, start time.Time, transport, route string) {
	normalizedUsage := responsesUsage(usage)
	s.recordUsage(usageEvent{
		Timestamp:    time.Now().UTC().Format(time.RFC3339Nano),
		RequestID:    requestID,
		ProviderID:   providerID,
		Model:        model,
		Route:        route,
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
	s.recordFailedUsageRoute(providerID, model, errorType, httpStatus, start, transport, "/v1/responses")
}

func (s *Server) recordFailedUsageRoute(providerID, model, errorType string, httpStatus int, start time.Time, transport, route string) {
	s.recordUsage(usageEvent{
		Timestamp:  time.Now().UTC().Format(time.RFC3339Nano),
		ProviderID: providerID,
		Model:      model,
		Route:      route,
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

func websocketAcceptKey(key string) string {
	sum := sha1.Sum([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	return base64.StdEncoding.EncodeToString(sum[:])
}

func readWebSocketFrame(r *bufio.Reader, maximumPayloadBytes uint64) (byte, []byte, error) {
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
	if opcode&0x8 != 0 && length > maximumWebSocketControlPayloadBytes {
		return 0, nil, fmt.Errorf("websocket control frame too large")
	}
	if length > maximumPayloadBytes {
		return 0, nil, fmt.Errorf("websocket frame too large")
	}
	var mask [4]byte
	if masked {
		if _, err := io.ReadFull(r, mask[:]); err != nil {
			return 0, nil, err
		}
	}
	payload := make([]byte, int(length))
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
