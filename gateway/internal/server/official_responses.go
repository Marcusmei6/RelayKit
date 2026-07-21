package server

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"relaykit/gateway/internal/config"
)

type officialCodexAuthFile struct {
	AuthMode string                  `json:"auth_mode"`
	Tokens   officialCodexAuthTokens `json:"tokens"`
	path     string
	raw      map[string]json.RawMessage
	encoded  []byte
}

type officialCodexAuthTokens struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	AccountID    string `json:"account_id"`
}

const (
	officialOAuthTokenEndpoint = "https://auth.openai.com/oauth/token"
	officialOAuthClientID      = "app_EMoamEEZ73f0CkXaXp7hrann"
)

var officialForwardedHeaders = []string{
	"OpenAI-Beta",
	"User-Agent",
	"originator",
	"session_id",
	"x-client-request-id",
	"x-codex-beta-features",
	"x-codex-installation-id",
	"x-codex-parent-thread-id",
	"x-codex-session-id",
	"x-codex-turn-metadata",
	"x-codex-turn-state",
	"x-codex-window-id",
	"x-codex-ws-stream-request-start-ms",
	"x-oai-attestation",
	"x-openai-internal-codex-responses-lite",
	"x-openai-subagent",
	"x-responsesapi-include-timing-metrics",
}

func (s *Server) officialOpenAIResponses(w http.ResponseWriter, r *http.Request, raw map[string]json.RawMessage, req responsesRequest, official config.OfficialPassthrough, model config.Model, start time.Time, compact bool) {
	route := "/v1/responses"
	if compact {
		route = "/v1/responses/compact"
	}
	resp, status, failure := s.officialResponsesUpstream(r.Context(), r.Header, raw, official, model, req.Stream, compact)
	if failure != nil {
		s.recordFailedUsageRoute("openai", req.Model, failure.kind, status, start, "responses_http", route)
		writeJSON(w, status, errorBody(failure.kind, failure.message))
		return
	}
	defer resp.Body.Close()

	if req.Stream {
		if !isSSEContentType(resp.Header.Get("Content-Type")) {
			s.recordFailedUsageRoute("openai", req.Model, "protocol_error", http.StatusBadGateway, start, "responses_http", route)
			writeJSON(w, http.StatusBadGateway, errorBody("protocol_error", "official upstream returned an invalid streaming response"))
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.WriteHeader(http.StatusOK)
		result := forwardNativeResponsesSSE(resp.Body, req.Model, func(event string, data []byte) bool {
			return writeRawSSE(w, event, data)
		})
		if result.ErrorKind != "" {
			s.recordFailedUsageRoute("openai", req.Model, result.ErrorKind, http.StatusBadGateway, start, "responses_http", route)
			return
		}
		if !result.Terminal {
			s.recordFailedUsageRoute("openai", req.Model, "upstream_stream_truncated", http.StatusBadGateway, start, "responses_http", route)
			return
		}
		s.recordCompletedUsageRoute("openai", req.Model, result.ID, result.Status, true, result.Usage, start, "responses_http", route)
		return
	}

	if !isJSONContentType(resp.Header.Get("Content-Type")) {
		s.recordFailedUsageRoute("openai", req.Model, "protocol_error", http.StatusBadGateway, start, "responses_http", route)
		writeJSON(w, http.StatusBadGateway, errorBody("protocol_error", "official upstream returned an invalid response"))
		return
	}
	response, err := rewriteNativeResponsesResponse(resp.Body, req.Model)
	if err != nil {
		s.recordFailedUsageRoute("openai", req.Model, "protocol_error", http.StatusBadGateway, start, "responses_http", route)
		writeJSON(w, http.StatusBadGateway, errorBody("protocol_error", "official upstream returned an invalid response"))
		return
	}
	writeRawJSON(w, http.StatusOK, response.body)
	s.recordCompletedUsageRoute("openai", req.Model, response.id, response.status, false, response.usage, start, "responses_http", route)
}

func (s *Server) officialOpenAIResponsesWebSocket(w *bufio.Writer, ctx context.Context, inbound http.Header, raw map[string]json.RawMessage, req responsesRequest, official config.OfficialPassthrough, model config.Model, start time.Time) {
	resp, status, failure := s.officialResponsesUpstream(ctx, inbound, raw, official, model, true, false)
	if failure != nil {
		s.recordFailedUsage("openai", req.Model, failure.kind, status, start, "responses_websocket")
		_ = writeWebSocketJSON(w, nativeResponsesErrorEvent(failure.kind))
		return
	}
	defer resp.Body.Close()
	if !isSSEContentType(resp.Header.Get("Content-Type")) {
		s.recordFailedUsage("openai", req.Model, "protocol_error", http.StatusBadGateway, start, "responses_websocket")
		_ = writeWebSocketJSON(w, nativeResponsesErrorEvent("protocol_error"))
		return
	}
	result := forwardNativeResponsesSSE(resp.Body, req.Model, func(_ string, data []byte) bool {
		return writeWebSocketFrame(w, websocketOpcodeText, data) == nil
	})
	if result.ErrorKind != "" {
		s.recordFailedUsage("openai", req.Model, result.ErrorKind, http.StatusBadGateway, start, "responses_websocket")
		return
	}
	if !result.Terminal {
		s.recordFailedUsage("openai", req.Model, "upstream_stream_truncated", http.StatusBadGateway, start, "responses_websocket")
		return
	}
	s.recordCompletedUsage("openai", req.Model, result.ID, result.Status, true, result.Usage, start, "responses_websocket")
}

func (s *Server) officialResponsesCompact(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	if r.Header.Get("Content-Type") == "" {
		writeJSON(w, http.StatusBadRequest, errorBody("invalid_request_error", "Content-Type is required"))
		return
	}
	body, closeBody, err := requestBodyReader(r)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorBody("invalid_request_error", "invalid request body"))
		return
	}
	if closeBody != nil {
		defer closeBody()
	}
	raw, req, err := decodeResponsesRequest(body)
	if err != nil {
		status := http.StatusBadRequest
		if err == errResponsesRequestTooLarge {
			status = http.StatusRequestEntityTooLarge
		}
		writeJSON(w, status, errorBody("invalid_request_error", "invalid request body"))
		return
	}
	model, ok := s.officialModelForModel(req.Model)
	if !ok || s.config.OfficialPassthrough == nil || !officialUsesCodexHome(*s.config.OfficialPassthrough) {
		s.recordFailedUsageRoute("openai", req.Model, "unknown_model", http.StatusBadRequest, start, "responses_http", "/v1/responses/compact")
		writeJSON(w, http.StatusBadRequest, errorBody("invalid_request_error", "unknown official model"))
		return
	}
	s.officialOpenAIResponses(w, r, raw, req, *s.config.OfficialPassthrough, model, start, true)
}

func (s *Server) officialResponsesUpstream(ctx context.Context, inbound http.Header, raw map[string]json.RawMessage, official config.OfficialPassthrough, model config.Model, forceStream, compact bool) (*http.Response, int, *nativeResponsesFailure) {
	payload, err := nativeResponsesRequestBody(raw, upstreamModelName(model), forceStream)
	if err != nil {
		return nil, http.StatusBadRequest, &nativeResponsesFailure{kind: "invalid_request_error", message: "invalid Responses request"}
	}
	endpointPath := "responses"
	if compact {
		endpointPath = "responses/compact"
	}
	endpoint, err := url.JoinPath(s.officialCodexBaseURL, endpointPath)
	if err != nil {
		return nil, http.StatusBadGateway, &nativeResponsesFailure{kind: "protocol_error", message: "invalid official endpoint"}
	}
	auth, err := readOfficialCodexAuth(official)
	if err != nil {
		return nil, http.StatusUnauthorized, &nativeResponsesFailure{kind: "auth_required", message: "RelayKit official Codex login is not connected"}
	}
	buildRequest := func(auth officialCodexAuthFile) (*http.Request, error) {
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(payload))
		if err != nil {
			return nil, err
		}
		req.Header.Set("Content-Type", "application/json")
		if forceStream {
			req.Header.Set("Accept", "text/event-stream")
		} else {
			req.Header.Set("Accept", "application/json")
		}
		for _, name := range officialForwardedHeaders {
			for _, value := range inbound.Values(name) {
				req.Header.Add(name, value)
			}
		}
		if req.Header.Get("OpenAI-Beta") == "" {
			req.Header.Set("OpenAI-Beta", "responses=experimental")
		}
		if req.Header.Get("originator") == "" {
			req.Header.Set("originator", "codex_cli_rs")
		}
		req.Header.Set("Authorization", "Bearer "+auth.Tokens.AccessToken)
		req.Header.Set("ChatGPT-Account-Id", auth.Tokens.AccountID)
		return req, nil
	}
	req, err := buildRequest(auth)
	if err != nil {
		return nil, http.StatusBadGateway, &nativeResponsesFailure{kind: "upstream_error", message: "official upstream request failed"}
	}
	resp, err := s.doNativeResponsesRequest(req)
	if err != nil {
		return nil, http.StatusBadGateway, &nativeResponsesFailure{kind: "upstream_error", message: "official upstream request failed"}
	}
	if resp.StatusCode == http.StatusUnauthorized {
		_ = resp.Body.Close()
		auth, err = s.refreshOfficialCodexAuth(ctx, official, auth.Tokens.AccessToken)
		if err != nil {
			return nil, http.StatusUnauthorized, &nativeResponsesFailure{kind: "auth_required", message: "RelayKit official Codex login is not connected"}
		}
		req, err = buildRequest(auth)
		if err != nil {
			return nil, http.StatusBadGateway, &nativeResponsesFailure{kind: "upstream_error", message: "official upstream request failed"}
		}
		resp, err = s.doNativeResponsesRequest(req)
		if err != nil {
			return nil, http.StatusBadGateway, &nativeResponsesFailure{kind: "upstream_error", message: "official upstream request failed"}
		}
	}
	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		_ = resp.Body.Close()
		status, kind, message := officialResponsesHTTPFailure(resp.StatusCode)
		return nil, status, &nativeResponsesFailure{kind: kind, message: message}
	}
	return resp, http.StatusOK, nil
}

func readOfficialCodexAuth(official config.OfficialPassthrough) (officialCodexAuthFile, error) {
	if official.CredentialRef == nil || official.CredentialRef.Kind != config.CredentialKindCodexHome {
		return officialCodexAuthFile{}, fmt.Errorf("official codex home is not configured")
	}
	codexHome := official.CredentialRef.Value
	if strings.HasPrefix(codexHome, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return officialCodexAuthFile{}, err
		}
		codexHome = filepath.Join(home, strings.TrimPrefix(codexHome, "~/"))
	}
	body, err := os.ReadFile(filepath.Join(codexHome, "auth.json"))
	if err != nil {
		return officialCodexAuthFile{}, err
	}
	var auth officialCodexAuthFile
	if err := json.Unmarshal(body, &auth.raw); err != nil {
		return officialCodexAuthFile{}, err
	}
	if err := json.Unmarshal(body, &auth); err != nil {
		return officialCodexAuthFile{}, err
	}
	if auth.AuthMode != "chatgpt" || strings.TrimSpace(auth.Tokens.AccessToken) == "" || strings.TrimSpace(auth.Tokens.AccountID) == "" {
		return officialCodexAuthFile{}, fmt.Errorf("official Codex login is incomplete")
	}
	auth.path = filepath.Join(codexHome, "auth.json")
	auth.encoded = append([]byte(nil), body...)
	return auth, nil
}

func (s *Server) refreshOfficialCodexAuth(ctx context.Context, official config.OfficialPassthrough, staleAccessToken string) (officialCodexAuthFile, error) {
	s.officialAuthRefreshMu.Lock()
	defer s.officialAuthRefreshMu.Unlock()

	auth, err := readOfficialCodexAuth(official)
	if err != nil {
		return officialCodexAuthFile{}, err
	}
	if auth.Tokens.AccessToken != staleAccessToken {
		return auth, nil
	}
	if strings.TrimSpace(auth.Tokens.RefreshToken) == "" {
		return officialCodexAuthFile{}, fmt.Errorf("official refresh token is unavailable")
	}
	form := url.Values{
		"client_id":     []string{officialOAuthClientID},
		"grant_type":    []string{"refresh_token"},
		"refresh_token": []string{auth.Tokens.RefreshToken},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, officialOAuthTokenEndpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return officialCodexAuthFile{}, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	resp, err := s.doNativeResponsesRequest(req)
	if err != nil {
		return officialCodexAuthFile{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		return officialCodexAuthFile{}, fmt.Errorf("official token refresh failed")
	}
	var refreshed struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		IDToken      string `json:"id_token"`
	}
	decoder := json.NewDecoder(io.LimitReader(resp.Body, 1<<20))
	if err := decoder.Decode(&refreshed); err != nil || strings.TrimSpace(refreshed.AccessToken) == "" {
		return officialCodexAuthFile{}, fmt.Errorf("official token refresh returned an invalid response")
	}
	if err := ensureJSONEOF(decoder); err != nil {
		return officialCodexAuthFile{}, fmt.Errorf("official token refresh returned an invalid response")
	}

	latest, err := readOfficialCodexAuth(official)
	if err != nil {
		return officialCodexAuthFile{}, err
	}
	if latest.Tokens.AccessToken != staleAccessToken || latest.Tokens.RefreshToken != auth.Tokens.RefreshToken {
		return latest, nil
	}
	auth = latest
	var rawTokens map[string]json.RawMessage
	if err := json.Unmarshal(auth.raw["tokens"], &rawTokens); err != nil || rawTokens == nil {
		return officialCodexAuthFile{}, fmt.Errorf("official auth tokens are invalid")
	}
	rawTokens["access_token"] = json.RawMessage(strconvQuote(refreshed.AccessToken))
	if strings.TrimSpace(refreshed.RefreshToken) != "" {
		rawTokens["refresh_token"] = json.RawMessage(strconvQuote(refreshed.RefreshToken))
	}
	if strings.TrimSpace(refreshed.IDToken) != "" {
		rawTokens["id_token"] = json.RawMessage(strconvQuote(refreshed.IDToken))
	}
	auth.raw["tokens"], err = json.Marshal(rawTokens)
	if err != nil {
		return officialCodexAuthFile{}, err
	}
	auth.raw["last_refresh"] = json.RawMessage(strconvQuote(time.Now().UTC().Format(time.RFC3339)))
	updated, err := json.Marshal(auth.raw)
	if err != nil {
		return officialCodexAuthFile{}, err
	}
	written, err := writeOfficialCodexAuth(auth.path, auth.encoded, updated)
	if err != nil {
		return officialCodexAuthFile{}, err
	}
	if !written {
		return readOfficialCodexAuth(official)
	}
	return readOfficialCodexAuth(official)
}

func writeOfficialCodexAuth(path string, expected, body []byte) (bool, error) {
	lock, err := os.OpenFile(path+".relaykit.lock", os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return false, err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return false, err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	current, err := os.ReadFile(path)
	if err != nil {
		return false, err
	}
	if !bytes.Equal(current, expected) {
		return false, nil
	}
	info, err := os.Stat(path)
	if err != nil {
		return false, err
	}
	temp, err := os.CreateTemp(filepath.Dir(path), ".relaykit-auth-*.json")
	if err != nil {
		return false, err
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)
	if err := temp.Chmod(info.Mode().Perm()); err != nil {
		_ = temp.Close()
		return false, err
	}
	if _, err := temp.Write(body); err != nil {
		_ = temp.Close()
		return false, err
	}
	if err := temp.Sync(); err != nil {
		_ = temp.Close()
		return false, err
	}
	if err := temp.Close(); err != nil {
		return false, err
	}
	if err := os.Rename(tempPath, path); err != nil {
		return false, err
	}
	return true, nil
}

func officialResponsesHTTPFailure(status int) (int, string, string) {
	switch status {
	case http.StatusBadRequest:
		return http.StatusBadRequest, "upstream_invalid_request", "official upstream rejected the request"
	case http.StatusUnauthorized, http.StatusForbidden:
		return http.StatusUnauthorized, "auth_required", "RelayKit official Codex login is not connected"
	case http.StatusTooManyRequests:
		return http.StatusTooManyRequests, "rate_limit", "official upstream rate limit exceeded"
	case http.StatusServiceUnavailable:
		return http.StatusServiceUnavailable, "unavailable", "official upstream service unavailable"
	default:
		return http.StatusBadGateway, "upstream_error", "official upstream request failed"
	}
}
