package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"relaykit/gateway/internal/codexconfig"
	"relaykit/gateway/internal/launchsocket"
	"relaykit/gateway/internal/server"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) > 0 && args[0] == "enable-codex-config" {
		return enableCodexConfig(args[1:], stdout, stderr)
	}
	if len(args) > 0 && args[0] == "disable-codex-config" {
		return disableCodexConfig(args[1:], stdout, stderr)
	}
	if len(args) > 0 && args[0] == "codex-config-status" {
		return codexConfigStatus(args[1:], stdout, stderr)
	}
	if len(args) > 0 && args[0] == "activate-codex-config" {
		return activateCodexConfig(args[1:], stdout, stderr)
	}
	if len(args) > 0 && args[0] == "summarize-usage" {
		return summarizeUsage(args[1:], stdout, stderr)
	}
	if len(args) > 0 && args[0] == "gateway-control" {
		return gatewayControl(args[1:], stdinForControl(), stdout, stderr)
	}
	signal.Ignore(syscall.SIGPIPE)
	if err := runServer(args, os.Stdin, stderr); err != nil {
		fmt.Fprintf(stderr, "%v\n", err)
		return 1
	}
	return 0
}

var stdinForControl = func() io.Reader {
	return os.Stdin
}

func codexConfigStatus(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("codex-config-status", flag.ContinueOnError)
	fs.SetOutput(stderr)
	target := fs.String("target", "", "destination Codex config TOML path")
	state := fs.String("state", "", "RelayKit managed-state JSON path")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *target == "" || *state == "" {
		fmt.Fprintln(stderr, "target and state are required")
		return 2
	}
	status, err := codexconfig.IntegrationStatus(*target, *state)
	if err != nil {
		fmt.Fprintf(stderr, "Codex config status failed: %v\n", err)
		return 1
	}
	fmt.Fprintln(stdout, status)
	return 0
}

func enableCodexConfig(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("enable-codex-config", flag.ContinueOnError)
	fs.SetOutput(stderr)
	target := fs.String("target", "", "destination Codex config TOML path")
	catalog := fs.String("catalog", "", "absolute RelayKit model catalog JSON path")
	state := fs.String("state", "", "RelayKit managed-state JSON path")
	baseURL := fs.String("base-url", "", "optional managed loopback OpenAI base URL")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *target == "" || *catalog == "" || *state == "" {
		fmt.Fprintln(stderr, "target, catalog, and state are required")
		return 2
	}
	result, err := codexconfig.Enable(codexconfig.EnableOptions{
		TargetPath:           *target,
		CatalogPath:          *catalog,
		StatePath:            *state,
		ManagedOpenAIBaseURL: *baseURL,
	})
	if err != nil {
		fmt.Fprintf(stderr, "enable Codex config failed: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "Codex config enabled\ntarget: %s\nstate: %s\nmanaged: openai_base_url, model_catalog_json\n", result.TargetPath, result.StatePath)
	if result.BackupPath != "" {
		fmt.Fprintf(stdout, "backup: %s\n", result.BackupPath)
	}
	return 0
}

func disableCodexConfig(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("disable-codex-config", flag.ContinueOnError)
	fs.SetOutput(stderr)
	target := fs.String("target", "", "destination Codex config TOML path")
	state := fs.String("state", "", "RelayKit managed-state JSON path")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *target == "" || *state == "" {
		fmt.Fprintln(stderr, "target and state are required")
		return 2
	}
	result, err := codexconfig.Disable(*target, *state)
	if err != nil {
		fmt.Fprintf(stderr, "disable Codex config failed: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "Codex config disabled\ntarget: %s\nremoved: %s\n", result.TargetPath, strings.Join(result.Removed, ", "))
	if len(result.Restored) > 0 {
		fmt.Fprintf(stdout, "restored previous values: %s\n", strings.Join(result.Restored, ", "))
	}
	if len(result.Preserved) > 0 {
		fmt.Fprintf(stdout, "preserved later changes: %s\n", strings.Join(result.Preserved, ", "))
	}
	return 0
}

type usageLogEvent struct {
	Timestamp    string `json:"timestamp"`
	ProviderID   string `json:"provider_id"`
	Model        string `json:"model"`
	InputTokens  int64  `json:"input_tokens"`
	OutputTokens int64  `json:"output_tokens"`
	TotalTokens  int64  `json:"total_tokens"`
	DurationMS   int64  `json:"duration_ms"`
}

type usageSummary struct {
	Day          string `json:"day"`
	ProviderID   string `json:"provider_id"`
	Model        string `json:"model"`
	Requests     int64  `json:"requests"`
	InputTokens  int64  `json:"input_tokens"`
	OutputTokens int64  `json:"output_tokens"`
	TotalTokens  int64  `json:"total_tokens"`
	DurationMS   int64  `json:"duration_ms"`
}

func summarizeUsage(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("summarize-usage", flag.ContinueOnError)
	fs.SetOutput(stderr)
	path := fs.String("path", defaultUsageLogPath(), "usage JSONL path")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	summaries, err := readUsageSummaries(*path)
	if err != nil {
		fmt.Fprintf(stderr, "summarize usage failed: %v\n", err)
		return 1
	}
	if err := json.NewEncoder(stdout).Encode(summaries); err != nil {
		fmt.Fprintf(stderr, "write summary failed: %v\n", err)
		return 1
	}
	return 0
}

func readUsageSummaries(path string) ([]usageSummary, error) {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return []usageSummary{}, nil
		}
		return nil, err
	}
	defer f.Close()

	byKey := map[string]*usageSummary{}
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		var event usageLogEvent
		if err := json.Unmarshal(scanner.Bytes(), &event); err != nil {
			return nil, err
		}
		day := event.Timestamp
		if len(day) >= len("2006-01-02") {
			day = day[:len("2006-01-02")]
		}
		key := day + "\x00" + event.ProviderID + "\x00" + event.Model
		summary := byKey[key]
		if summary == nil {
			summary = &usageSummary{Day: day, ProviderID: event.ProviderID, Model: event.Model}
			byKey[key] = summary
		}
		summary.Requests++
		summary.InputTokens += event.InputTokens
		summary.OutputTokens += event.OutputTokens
		summary.TotalTokens += event.TotalTokens
		summary.DurationMS += event.DurationMS
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}

	out := make([]usageSummary, 0, len(byKey))
	for _, summary := range byKey {
		out = append(out, *summary)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Day != out[j].Day {
			return out[i].Day < out[j].Day
		}
		if out[i].ProviderID != out[j].ProviderID {
			return out[i].ProviderID < out[j].ProviderID
		}
		return out[i].Model < out[j].Model
	})
	return out, nil
}

func activateCodexConfig(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("activate-codex-config", flag.ContinueOnError)
	fs.SetOutput(stderr)
	target := fs.String("target", "", "destination Codex config path")
	source := fs.String("source", "", "source config TOML path")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *target == "" {
		fmt.Fprintln(stderr, "target is required")
		return 2
	}
	if *source == "" {
		fmt.Fprintln(stderr, "source is required")
		return 2
	}
	if codexconfig.IsAuthJSONPath(*target) || codexconfig.IsAuthJSONPath(*source) {
		fmt.Fprintln(stderr, "auth.json paths are not allowed")
		return 2
	}
	content, err := os.ReadFile(*source)
	if err != nil {
		fmt.Fprintf(stderr, "read source failed: %v\n", err)
		return 1
	}
	result, err := codexconfig.Activate(*target, content)
	if err != nil {
		fmt.Fprintf(stderr, "activate failed: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "activated: %s\n", result.TargetPath)
	if result.BackupPath != "" {
		fmt.Fprintf(stdout, "backup: %s\nrollback: %s\n", result.BackupPath, result.RollbackCommand)
	}
	return 0
}

const (
	maximumCredentialHandoffBytes      = 1 << 20
	maximumGatewayControlEnvelopeBytes = 2 << 20
)

func parseParentPID(value string) (int, error) {
	pid, err := strconv.Atoi(value)
	if err != nil || pid <= 0 {
		return 0, fmt.Errorf("parent PID must be a positive integer")
	}
	return pid, nil
}

func validateManagedCodexRecoveryPaths(parentPID int, targetPath, statePath string, allowUnowned bool) error {
	if (targetPath == "") != (statePath == "") {
		return fmt.Errorf("managed Codex target and state must be supplied together")
	}
	if targetPath == "" {
		return nil
	}
	if parentPID <= 0 && !allowUnowned {
		return fmt.Errorf("managed Codex recovery requires a positive parent PID")
	}
	if codexconfig.IsAuthJSONPath(targetPath) || codexconfig.IsAuthJSONPath(statePath) {
		return fmt.Errorf("managed Codex recovery paths must not be auth.json")
	}
	if _, err := codexconfig.IntegrationStatus(targetPath, statePath); err != nil {
		return fmt.Errorf("managed Codex recovery paths are invalid: %w", err)
	}
	return nil
}

func allowsUnownedManagedLifecycle(appManaged bool, launchdSocketName, controlTokenPath string, restoreAfter time.Duration) bool {
	if appManaged {
		return true
	}
	return launchdSocketName != "" && controlTokenPath != "" && restoreAfter > 0
}

func reconcileUnownedManagedRouteAtStartup(targetPath, statePath string, managedEpochObserved, appOwnerActive bool) (bool, error) {
	if targetPath == "" || !managedEpochObserved || appOwnerActive {
		return false, nil
	}
	decision, err := codexconfig.RecoveryDecisionForParentLossWithContinuity(targetPath, statePath, true)
	return decision == codexconfig.RecoveryRetainListener, err
}

func parentProcessAlive(pid int) bool {
	process, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	err = process.Signal(syscall.Signal(0))
	return err == nil || errors.Is(err, syscall.EPERM)
}

type credentialHandoff struct {
	Version     int               `json:"version"`
	Credentials map[string]string `json:"credentials"`
}

type gatewayControlRequest struct {
	Version             int               `json:"version"`
	Action              string            `json:"action"`
	ParentPID           int               `json:"parent_pid,omitempty"`
	RouteEnabled        bool              `json:"route_enabled,omitempty"`
	RuntimeConfigSHA256 string            `json:"runtime_config_sha256,omitempty"`
	Credentials         map[string]string `json:"credentials"`
}

type gatewayControlResponse struct {
	Status              string `json:"status"`
	Mode                string `json:"mode"`
	RuntimeConfigSHA256 string `json:"runtime_config_sha256"`
}

type ownerLoss struct {
	pid        int
	generation uint64
}

type ownerState struct {
	mu                   sync.Mutex
	pid                  int
	generation           uint64
	managedEpochObserved bool
}

const ownerRecoveryRetryInterval = 250 * time.Millisecond

// ownerRecoveryRetry owns the single retry timer for an unowned generation.
// It is only touched by the runServer event loop, so retries cannot create
// competing goroutines or timers.
type ownerRecoveryRetry struct {
	pending *ownerLoss
	timer   *time.Timer
	channel <-chan time.Time
}

func (r *ownerRecoveryRetry) arm(loss ownerLoss) {
	if r.pending == nil || *r.pending != loss {
		pending := loss
		r.pending = &pending
	}
	if r.timer == nil {
		r.timer = time.NewTimer(ownerRecoveryRetryInterval)
		r.channel = r.timer.C
		return
	}
	if r.channel != nil {
		return
	}
	r.timer.Reset(ownerRecoveryRetryInterval)
	r.channel = r.timer.C
}

func (r *ownerRecoveryRetry) take() (ownerLoss, bool) {
	if r.channel == nil || r.pending == nil {
		return ownerLoss{}, false
	}
	r.channel = nil
	return *r.pending, true
}

func (r *ownerRecoveryRetry) clear() {
	r.pending = nil
	if r.timer == nil {
		r.channel = nil
		return
	}
	if !r.timer.Stop() {
		select {
		case <-r.timer.C:
		default:
		}
	}
	r.timer = nil
	r.channel = nil
}

func newOwnerState(pid int, managedEpochObserved bool) *ownerState {
	generation := uint64(0)
	if pid > 0 || managedEpochObserved {
		generation = 1
	}
	return &ownerState{pid: pid, generation: generation, managedEpochObserved: managedEpochObserved}
}

func (s *ownerState) snapshot() (int, uint64, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.pid, s.generation, s.managedEpochObserved
}

func (s *ownerState) markManagedEpoch() {
	s.mu.Lock()
	s.managedEpochObserved = true
	s.mu.Unlock()
}

func (s *ownerState) adopt(pid int, routeEnabled bool) {
	s.mu.Lock()
	s.adoptLocked(pid, routeEnabled)
	s.mu.Unlock()
}

func (s *ownerState) beginAdopt(pid int) bool {
	s.mu.Lock()
	if s.pid > 0 && s.pid != pid {
		s.mu.Unlock()
		return false
	}
	return true
}

func (s *ownerState) adoptLocked(pid int, routeEnabled bool) {
	s.generation++
	s.pid = pid
	if routeEnabled {
		s.managedEpochObserved = true
	}
}

func (s *ownerState) release(pid int) bool {
	s.mu.Lock()
	if !s.beginReleaseLocked(pid) {
		s.mu.Unlock()
		return false
	}
	s.finishReleaseLocked()
	return true
}

func (s *ownerState) beginRelease(pid int) bool {
	s.mu.Lock()
	if !s.beginReleaseLocked(pid) {
		s.mu.Unlock()
		return false
	}
	return true
}

func (s *ownerState) beginReleaseLocked(pid int) bool {
	if s.pid != pid || pid <= 0 {
		return false
	}
	return true
}

func (s *ownerState) finishReleaseLocked() {
	s.pid = 0
	s.generation++
	s.mu.Unlock()
}

func (s *ownerState) markOwnerLost(pid int) (ownerLoss, bool) {
	return s.markOwnerLostAndClear(pid, nil)
}

// markOwnerLostAndClear closes the old owner epoch while holding the same
// generation lock used by adoption and recovery. The clear callback must
// remove all owner-scoped capability before another epoch can adopt.
func (s *ownerState) markOwnerLostAndClear(pid int, clear func()) (ownerLoss, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if pid <= 0 || s.pid != pid {
		return ownerLoss{}, false
	}
	s.pid = 0
	s.generation++
	if clear != nil {
		clear()
	}
	return ownerLoss{pid: pid, generation: s.generation}, true
}

func (s *ownerState) unownedLoss() ownerLoss {
	s.mu.Lock()
	defer s.mu.Unlock()
	return ownerLoss{generation: s.generation}
}

func (s *ownerState) recoveryEligible(event ownerLoss) bool {
	s.mu.Lock()
	eligible := s.pid == 0 && s.generation == event.generation
	s.mu.Unlock()
	return eligible
}

func (s *ownerState) beginRecovery(event ownerLoss) bool {
	s.mu.Lock()
	if s.pid != 0 || s.generation != event.generation {
		s.mu.Unlock()
		return false
	}
	return true

}

func (s *ownerState) beginUnownedReplace() bool {
	s.mu.Lock()
	if s.pid != 0 {
		s.mu.Unlock()
		return false
	}
	return true
}

func (s *ownerState) endTransition() {
	s.mu.Unlock()
}

func (s *ownerState) managedEpochObservedLocked() bool {
	return s.managedEpochObserved
}

type gatewayControlEnvelope struct {
	Nonce      string `json:"nonce"`
	Ciphertext string `json:"ciphertext"`
}

func readCredentialHandoff(reader io.Reader) (map[string]string, error) {
	body, err := io.ReadAll(io.LimitReader(reader, maximumCredentialHandoffBytes+1))
	if err != nil {
		return nil, fmt.Errorf("read credential handoff failed")
	}
	if len(body) > maximumCredentialHandoffBytes {
		return nil, fmt.Errorf("credential handoff exceeds size limit")
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	var payload credentialHandoff
	if err := decoder.Decode(&payload); err != nil {
		return nil, fmt.Errorf("invalid credential handoff")
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return nil, fmt.Errorf("invalid credential handoff")
	}
	if payload.Version != 1 || payload.Credentials == nil {
		return nil, fmt.Errorf("unsupported credential handoff")
	}
	credentials := make(map[string]string, len(payload.Credentials))
	for reference, value := range payload.Credentials {
		if reference == "" || value == "" {
			return nil, fmt.Errorf("invalid credential handoff entry")
		}
		credentials[reference] = value
	}
	return credentials, nil
}

func gatewayControl(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("gateway-control", flag.ContinueOnError)
	fs.SetOutput(stderr)
	endpoint := fs.String("endpoint", "http://127.0.0.1:19777", "RelayKit loopback endpoint")
	tokenPath := fs.String("token-file", "", "owner-only RelayKit control token path")
	action := fs.String("action", "status", "status, adopt, replace, release, or shutdown")
	parentPID := fs.Int("parent-pid", 0, "adopting App process ID")
	routeEnabled := fs.Bool("route-enabled", true, "enable provider routes for an adopted managed Codex epoch")
	runtimeConfigSHA256 := fs.String("runtime-config-sha256", "", "expected runtime-config SHA-256 digest")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *tokenPath == "" {
		fmt.Fprintln(stderr, "control token file is required")
		return 2
	}
	if *action != "status" && *action != "adopt" && *action != "replace" && *action != "release" && *action != "shutdown" {
		fmt.Fprintln(stderr, "unsupported gateway control action")
		return 2
	}
	if (*action == "adopt" || *action == "replace" || *action == "release" || *action == "shutdown") && *parentPID <= 0 {
		fmt.Fprintln(stderr, "positive parent PID is required")
		return 2
	}
	parsed, err := url.Parse(*endpoint)
	if err != nil || parsed.Scheme != "http" || parsed.Hostname() != "127.0.0.1" || parsed.User != nil ||
		(parsed.Path != "" && parsed.Path != "/") || parsed.RawPath != "" || parsed.RawQuery != "" || parsed.Fragment != "" {
		fmt.Fprintln(stderr, "gateway control endpoint must be loopback HTTP")
		return 2
	}
	token, err := readControlToken(*tokenPath)
	if err != nil {
		fmt.Fprintln(stderr, "gateway control token is unavailable")
		return 1
	}
	request := gatewayControlRequest{
		Version:             1,
		Action:              *action,
		ParentPID:           *parentPID,
		RouteEnabled:        *routeEnabled,
		RuntimeConfigSHA256: *runtimeConfigSHA256,
	}
	if *action == "adopt" {
		handoff, readErr := readCredentialHandoff(stdin)
		if readErr != nil {
			fmt.Fprintln(stderr, "gateway credential handoff failed")
			return 1
		}
		request.Credentials = handoff
	}
	plaintext, err := json.Marshal(request)
	if err != nil {
		fmt.Fprintln(stderr, "gateway control request failed")
		return 1
	}
	body, err := sealGatewayControlPayload(token, plaintext)
	if err != nil {
		fmt.Fprintln(stderr, "gateway control request failed")
		return 1
	}
	controlURL := strings.TrimRight(*endpoint, "/") + "/_relaykit/control"
	httpRequest, err := http.NewRequest(http.MethodPost, controlURL, bytes.NewReader(body))
	if err != nil {
		fmt.Fprintln(stderr, "gateway control request failed")
		return 1
	}
	httpRequest.Header.Set("Content-Type", "application/vnd.relaykit.control+json")
	client := &http.Client{Timeout: 2 * time.Second}
	response, err := client.Do(httpRequest)
	if err != nil {
		fmt.Fprintln(stderr, "gateway control endpoint is unavailable")
		return 1
	}
	defer response.Body.Close()
	encryptedResponse, err := io.ReadAll(io.LimitReader(response.Body, 8193))
	if err != nil || len(encryptedResponse) > 8192 {
		fmt.Fprintln(stderr, "gateway control response is invalid")
		return 1
	}
	responseBody, err := openGatewayControlPayload(token, encryptedResponse)
	if err != nil {
		fmt.Fprintln(stderr, "gateway control response is invalid")
		return 1
	}
	var result gatewayControlResponse
	decoder := json.NewDecoder(bytes.NewReader(responseBody))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&result); err != nil || decoder.Decode(&struct{}{}) != io.EOF {
		fmt.Fprintln(stderr, "gateway control response is invalid")
		return 1
	}
	if response.StatusCode != http.StatusOK || result.Status != "ok" {
		fmt.Fprintf(stderr, "gateway control action failed with status %d\n", response.StatusCode)
		return 1
	}
	fmt.Fprintf(stdout, "gateway control %s: %s\n", *action, result.Mode)
	if result.RuntimeConfigSHA256 != "" {
		fmt.Fprintf(stdout, "runtime_config_sha256=%s\n", result.RuntimeConfigSHA256)
	}
	return 0
}

func readControlToken(path string) (string, error) {
	if path == "" || !filepath.IsAbs(path) || codexconfig.IsAuthJSONPath(path) {
		return "", fmt.Errorf("invalid control token path")
	}
	info, err := os.Lstat(path)
	if err != nil {
		return "", err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || info.Mode().Perm() != 0600 {
		return "", fmt.Errorf("unsafe control token file")
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); !ok || int(stat.Uid) != os.Getuid() {
		return "", fmt.Errorf("control token owner mismatch")
	}
	body, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	token := strings.TrimSpace(string(body))
	decoded, err := hex.DecodeString(token)
	if err != nil || len(decoded) != 32 {
		return "", fmt.Errorf("invalid control token")
	}
	return token, nil
}

func acquireControlTokenLeaseProbe(path string) (bool, *os.File, error) {
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return false, nil, err
	}

	var info syscall.Stat_t
	if err := syscall.Fstat(fd, &info); err != nil {
		_ = syscall.Close(fd)
		return false, nil, err
	}
	if info.Mode&syscall.S_IFMT != syscall.S_IFREG || info.Mode&0777 != 0600 ||
		int(info.Uid) != os.Getuid() || info.Nlink != 1 {
		_ = syscall.Close(fd)
		return false, nil, fmt.Errorf("unsafe control token file")
	}
	if err := syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = syscall.Close(fd)
		if errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN) {
			return true, nil, nil
		}
		return false, nil, err
	}
	lease := os.NewFile(uintptr(fd), "gateway-control-owner-lease")
	if lease == nil {
		_ = syscall.Flock(fd, syscall.LOCK_UN)
		_ = syscall.Close(fd)
		return false, nil, fmt.Errorf("control token owner lease unavailable")
	}
	return false, lease, nil
}

func gatewayControlAEAD(token string) (cipher.AEAD, error) {
	key, err := hex.DecodeString(token)
	if err != nil || len(key) != 32 {
		return nil, fmt.Errorf("invalid control token")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

func sealGatewayControlPayload(token string, plaintext []byte) ([]byte, error) {
	aead, err := gatewayControlAEAD(token)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, err
	}
	ciphertext := aead.Seal(nil, nonce, plaintext, []byte("relaykit-gateway-control-v1"))
	return json.Marshal(gatewayControlEnvelope{
		Nonce:      base64.RawStdEncoding.EncodeToString(nonce),
		Ciphertext: base64.RawStdEncoding.EncodeToString(ciphertext),
	})
}

func openGatewayControlPayload(token string, body []byte) ([]byte, error) {
	var envelope gatewayControlEnvelope
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&envelope); err != nil || decoder.Decode(&struct{}{}) != io.EOF {
		return nil, fmt.Errorf("invalid control envelope")
	}
	aead, err := gatewayControlAEAD(token)
	if err != nil {
		return nil, err
	}
	nonce, err := base64.RawStdEncoding.DecodeString(envelope.Nonce)
	if err != nil || len(nonce) != aead.NonceSize() {
		return nil, fmt.Errorf("invalid control nonce")
	}
	ciphertext, err := base64.RawStdEncoding.DecodeString(envelope.Ciphertext)
	if err != nil {
		return nil, fmt.Errorf("invalid control ciphertext")
	}
	return aead.Open(nil, nonce, ciphertext, []byte("relaykit-gateway-control-v1"))
}

func validCredentialMap(credentials map[string]string) bool {
	if credentials == nil {
		return false
	}
	for reference, value := range credentials {
		if reference == "" || value == "" {
			return false
		}
	}
	return true
}

func validRuntimeConfigSHA256(value string) bool {
	if len(value) != sha256.Size*2 || value != strings.ToLower(value) {
		return false
	}
	for _, character := range value {
		if !((character >= '0' && character <= '9') || (character >= 'a' && character <= 'f')) {
			return false
		}
	}
	return true
}

func runtimeConfigDigest(path string) (string, error) {
	if strings.TrimSpace(path) == "" {
		return "", fmt.Errorf("runtime config path is unavailable")
	}
	body, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(body)
	return hex.EncodeToString(digest[:]), nil
}

func writeControlResponse(w http.ResponseWriter, status int, result string, handler *server.Server, token string) {
	mode := "managed"
	if handler.IsOfficialFallback() {
		mode = "official_fallback"
	}
	plaintext, err := json.Marshal(gatewayControlResponse{
		Status:              result,
		Mode:                mode,
		RuntimeConfigSHA256: handler.RuntimeConfigSHA256(),
	})
	if err != nil {
		http.Error(w, "control response unavailable", http.StatusInternalServerError)
		return
	}
	body, err := sealGatewayControlPayload(token, plaintext)
	if err != nil {
		http.Error(w, "control response unavailable", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/vnd.relaykit.control+json")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

func runServer(args []string, stdin io.Reader, stderr io.Writer) error {
	fs := flag.NewFlagSet("gateway", flag.ContinueOnError)
	fs.SetOutput(stderr)
	listen := fs.String("listen", "127.0.0.1:19777", "loopback listen address")
	configPath := fs.String("config", "../examples/providers.example.json", "provider profile JSON path")
	usageLogPath := fs.String("usage-log", defaultUsageLogPath(), "local usage JSONL path")
	credentialStdin := fs.Bool("credential-stdin", false, "read App-provided credentials from standard input")
	parentPIDValue := fs.String("parent-pid", "", "optional positive parent process ID")
	managedCodexTarget := fs.String("managed-codex-target", "", "optional managed Codex config TOML path for parent-loss recovery")
	managedCodexState := fs.String("managed-codex-state", "", "optional RelayKit managed-state JSON path for parent-loss recovery")
	controlTokenPath := fs.String("control-token-file", "", "optional owner-only control token path")
	launchdSocketName := fs.String("launchd-socket-name", "", "optional launchd socket activation name")
	appManaged := fs.Bool("app-managed", false, "use RelayKit App-owned paths and launchd socket activation")
	initialOfficialFallback := fs.Bool("initial-official-fallback", false, "start without provider credentials until an App adopts the helper")
	initialRouteEnabled := fs.Bool("route-enabled", true, "allow provider routes for an App-owned direct helper")
	restoreUnownedAfter := fs.Duration("restore-unowned-after", 0, "restore an unowned managed route after this adoption grace period")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *appManaged {
		configDir, err := os.UserConfigDir()
		if err != nil {
			return fmt.Errorf("RelayKit Application Support directory is unavailable")
		}
		home, err := os.UserHomeDir()
		if err != nil {
			return fmt.Errorf("RelayKit home directory is unavailable")
		}
		support := filepath.Join(configDir, "RelayKit")
		*configPath = filepath.Join(support, "gateway-runtime.json")
		*usageLogPath = filepath.Join(support, "usage.jsonl")
		*managedCodexTarget = filepath.Join(home, ".codex", "config.toml")
		*managedCodexState = filepath.Join(support, "codex-config-state.json")
		*controlTokenPath = filepath.Join(support, "gateway-control.token")
		*launchdSocketName = "RelayKitGateway"
		*initialOfficialFallback = true
		if *restoreUnownedAfter == 0 {
			*restoreUnownedAfter = 10 * time.Second
		}
	}
	parentPID := 0
	if *parentPIDValue != "" {
		var err error
		parentPID, err = parseParentPID(*parentPIDValue)
		if err != nil {
			return err
		}
		if !parentProcessAlive(parentPID) {
			return fmt.Errorf("parent process is not running")
		}
	}
	allowUnowned := allowsUnownedManagedLifecycle(
		*appManaged,
		*launchdSocketName,
		*controlTokenPath,
		*restoreUnownedAfter,
	)
	backgroundManaged := *launchdSocketName != "" && *controlTokenPath != ""
	if err := validateManagedCodexRecoveryPaths(parentPID, *managedCodexTarget, *managedCodexState, allowUnowned); err != nil {
		return err
	}
	controlToken := ""
	appOwnerActive := false
	var startupRecoveryLease *os.File
	if *controlTokenPath != "" {
		var err error
		controlToken, err = readControlToken(*controlTokenPath)
		if err != nil {
			return fmt.Errorf("gateway control token failed validation")
		}
		if backgroundManaged {
			appOwnerActive, startupRecoveryLease, err = acquireControlTokenLeaseProbe(*controlTokenPath)
			if err != nil {
				return fmt.Errorf("gateway control owner lease failed validation")
			}
			if startupRecoveryLease != nil {
				defer func() {
					if startupRecoveryLease != nil {
						_ = startupRecoveryLease.Close()
					}
				}()
			}
		}
	}
	var handler *server.Server
	var runtimeCredentials map[string]string
	var err error
	if *credentialStdin || *appManaged {
		if *credentialStdin {
			credentials, readErr := readCredentialHandoff(stdin)
			if readErr != nil {
				return readErr
			}
			runtimeCredentials = credentials
		}
		// App-managed helpers are permanently handoff-only. In particular,
		// they must never fall back to invoking the macOS Keychain CLI.
		handler, err = server.NewWithUsageLogAndCredentials(*configPath, *usageLogPath, runtimeCredentials)
	} else {
		handler, err = server.NewWithUsageLog(*configPath, *usageLogPath)
	}
	if err != nil {
		return fmt.Errorf("gateway config failed: %w", err)
	}
	if *initialOfficialFallback {
		handler.EnterFallbackOfficialOnly()
	} else if !*initialRouteEnabled {
		handler.EnterFallbackWithCredentials(runtimeCredentials)
	}

	managedEpochObserved := *appManaged
	ownerState := newOwnerState(parentPID, managedEpochObserved)
	if *managedCodexTarget != "" {
		status, statusErr := codexconfig.IntegrationStatus(*managedCodexTarget, *managedCodexState)
		if statusErr == nil && (status == codexconfig.StatusEnabled || status == codexconfig.StatusDrifted) {
			ownerState.markManagedEpoch()
		}
	}
	if retain, recoveryErr := reconcileUnownedManagedRouteAtStartup(
		*managedCodexTarget,
		*managedCodexState,
		backgroundManaged && func() bool { _, _, observed := ownerState.snapshot(); return observed }(),
		appOwnerActive,
	); retain {
		handler.EnterFallbackOfficialOnly()
		if recoveryErr != nil {
			log.Printf("unowned managed route recovery retained the fallback listener")
		}
	}
	if startupRecoveryLease != nil {
		if err := startupRecoveryLease.Close(); err != nil {
			return fmt.Errorf("gateway control owner lease release failed")
		}
		startupRecoveryLease = nil
	}

	var listener net.Listener
	if *launchdSocketName != "" {
		listener, err = launchsocket.Activate(*launchdSocketName)
		if err != nil {
			return err
		}
	} else {
		listener, err = net.Listen("tcp", *listen)
		if err != nil {
			return fmt.Errorf("gateway listen failed: %w", err)
		}
	}
	rootCtx, cancelRoot := context.WithCancel(context.Background())
	ownerLost := make(chan ownerLoss, 1)
	retireRequested := make(chan struct{}, 1)
	var recoveryRetry ownerRecoveryRetry
	rootHandler := http.Handler(handler)
	if controlToken != "" {
		controlMux := http.NewServeMux()
		controlMux.Handle("/", handler)
		controlMux.HandleFunc("POST /_relaykit/control", func(w http.ResponseWriter, r *http.Request) {
			encryptedBody, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maximumGatewayControlEnvelopeBytes))
			if err != nil {
				http.Error(w, "invalid control request", http.StatusBadRequest)
				return
			}
			plaintext, err := openGatewayControlPayload(controlToken, encryptedBody)
			if err != nil {
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}
			var request gatewayControlRequest
			decoder := json.NewDecoder(bytes.NewReader(plaintext))
			decoder.DisallowUnknownFields()
			if err := decoder.Decode(&request); err != nil || decoder.Decode(&struct{}{}) != io.EOF || request.Version != 1 {
				writeControlResponse(w, http.StatusBadRequest, "invalid_request", handler, controlToken)
				return
			}
			switch request.Action {
			case "status":
				writeControlResponse(w, http.StatusOK, "ok", handler, controlToken)
			case "adopt":
				if !validRuntimeConfigSHA256(request.RuntimeConfigSHA256) || request.RuntimeConfigSHA256 != handler.RuntimeConfigSHA256() {
					writeControlResponse(w, http.StatusConflict, "runtime_config_mismatch", handler, controlToken)
					return
				}
				if request.ParentPID <= 0 || !parentProcessAlive(request.ParentPID) || !validCredentialMap(request.Credentials) {
					writeControlResponse(w, http.StatusBadRequest, "invalid_request", handler, controlToken)
					return
				}
				if !ownerState.beginAdopt(request.ParentPID) {
					writeControlResponse(w, http.StatusConflict, "owner_mismatch", handler, controlToken)
					return
				}
				if request.RouteEnabled {
					handler.EnterManaged(request.Credentials)
				} else {
					handler.EnterFallbackWithCredentials(request.Credentials)
				}
				ownerState.adoptLocked(request.ParentPID, request.RouteEnabled)
				ownerState.endTransition()
				writeControlResponse(w, http.StatusOK, "ok", handler, controlToken)
			case "replace":
				if !backgroundManaged {
					writeControlResponse(w, http.StatusConflict, "background_helper_required", handler, controlToken)
					return
				}
				if !validRuntimeConfigSHA256(request.RuntimeConfigSHA256) {
					writeControlResponse(w, http.StatusConflict, "runtime_config_mismatch", handler, controlToken)
					return
				}
				if !ownerState.beginUnownedReplace() {
					writeControlResponse(w, http.StatusConflict, "owner_mismatch", handler, controlToken)
					return
				}
				if !handler.IsOfficialFallback() {
					ownerState.endTransition()
					writeControlResponse(w, http.StatusConflict, "owner_mismatch", handler, controlToken)
					return
				}
				if request.ParentPID <= 0 || !parentProcessAlive(request.ParentPID) {
					ownerState.endTransition()
					writeControlResponse(w, http.StatusConflict, "requester_unavailable", handler, controlToken)
					return
				}
				diskDigest, digestErr := runtimeConfigDigest(*configPath)
				if digestErr != nil || diskDigest != request.RuntimeConfigSHA256 {
					ownerState.endTransition()
					writeControlResponse(w, http.StatusConflict, "runtime_config_mismatch", handler, controlToken)
					return
				}
				writeControlResponse(w, http.StatusOK, "ok", handler, controlToken)
				ownerState.endTransition()
				select {
				case retireRequested <- struct{}{}:
				default:
				}
			case "release":
				if !backgroundManaged {
					writeControlResponse(w, http.StatusConflict, "direct_helper_release_forbidden", handler, controlToken)
					return
				}
				if request.ParentPID <= 0 || !ownerState.beginRelease(request.ParentPID) {
					writeControlResponse(w, http.StatusConflict, "owner_mismatch", handler, controlToken)
					return
				}
				managedEpochObserved := ownerState.managedEpochObservedLocked()
				if *managedCodexTarget != "" {
					decision, recoveryErr := codexconfig.RecoveryDecisionForParentLossWithContinuity(
						*managedCodexTarget,
						*managedCodexState,
						managedEpochObserved,
					)
					if decision != codexconfig.RecoveryRetainListener || recoveryErr != nil {
						ownerState.endTransition()
						writeControlResponse(w, http.StatusConflict, "route_restore_failed", handler, controlToken)
						return
					}
				}
				handler.EnterFallbackOfficialOnly()
				ownerState.finishReleaseLocked()
				writeControlResponse(w, http.StatusOK, "ok", handler, controlToken)
			case "shutdown":
				currentOwner, _, _ := ownerState.snapshot()
				if request.ParentPID <= 0 || request.ParentPID != currentOwner {
					writeControlResponse(w, http.StatusConflict, "owner_mismatch", handler, controlToken)
					return
				}
				writeControlResponse(w, http.StatusOK, "ok", handler, controlToken)
				select {
				case retireRequested <- struct{}{}:
				default:
				}
			default:
				writeControlResponse(w, http.StatusBadRequest, "invalid_request", handler, controlToken)
			}
		})
		rootHandler = controlMux
	}
	srv := &http.Server{
		Addr:              *listen,
		Handler:           rootHandler,
		ReadHeaderTimeout: 5 * time.Second,
		BaseContext: func(net.Listener) context.Context {
			return rootCtx
		},
	}

	errCh := make(chan error, 1)
	go func() {
		log.Printf("relaykit gateway listening on http://%s", *listen)
		errCh <- srv.Serve(listener)
	}()
	parentMonitorDone := make(chan struct{})
	if parentPID > 0 || controlToken != "" {
		go func() {
			defer close(parentMonitorDone)
			ticker := time.NewTicker(250 * time.Millisecond)
			defer ticker.Stop()
			for {
				select {
				case <-rootCtx.Done():
					return
				case <-ticker.C:
					currentOwner, _, _ := ownerState.snapshot()
					if currentOwner <= 0 {
						continue
					}
					_, _, managedEpochObserved := ownerState.snapshot()
					if !managedEpochObserved && *managedCodexTarget != "" {
						status, statusErr := codexconfig.IntegrationStatus(*managedCodexTarget, *managedCodexState)
						if statusErr == nil && (status == codexconfig.StatusEnabled || status == codexconfig.StatusDrifted) {
							ownerState.markManagedEpoch()
						}
					}
					if !parentProcessAlive(currentOwner) {
						loss, marked := ownerState.markOwnerLostAndClear(currentOwner, handler.EnterFallbackOfficialOnly)
						if !marked {
							continue
						}
						select {
						case ownerLost <- loss:
						case <-rootCtx.Done():
							return
						}
					}
				}
			}
		}()
	} else {
		close(parentMonitorDone)
	}
	_, _, managedEpochObserved = ownerState.snapshot()
	if *restoreUnownedAfter > 0 && managedEpochObserved && appOwnerActive {
		go func() {
			timer := time.NewTimer(*restoreUnownedAfter)
			defer timer.Stop()
			select {
			case <-rootCtx.Done():
				return
			case <-timer.C:
				currentOwner, _, _ := ownerState.snapshot()
				if currentOwner == 0 {
					select {
					case ownerLost <- ownerState.unownedLoss():
					case <-rootCtx.Done():
					}
				}
			}
		}()
	}
	defer func() {
		recoveryRetry.clear()
		cancelRoot()
		<-parentMonitorDone
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(stop)

	attemptOwnerLossRecovery := func(loss ownerLoss) bool {
		if !ownerState.beginRecovery(loss) {
			if recoveryRetry.pending != nil && *recoveryRetry.pending == loss {
				recoveryRetry.clear()
			}
			return true
		}
		// Clear owner-scoped credentials before probing for a replacement lease.
		// The owner-state lock remains held so adoption cannot race this cutover.
		handler.EnterFallbackOfficialOnly()
		if backgroundManaged {
			active, lease, leaseErr := acquireControlTokenLeaseProbe(*controlTokenPath)
			if lease != nil {
				_ = lease.Close()
			}
			if leaseErr != nil || active {
				ownerState.endTransition()
				recoveryRetry.arm(loss)
				return true
			}
		}
		managedEpochObserved := ownerState.managedEpochObservedLocked()
		if *managedCodexTarget != "" {
			decision, recoveryErr := codexconfig.RecoveryDecisionForParentLossWithContinuity(
				*managedCodexTarget,
				*managedCodexState,
				managedEpochObserved,
			)
			if decision == codexconfig.RecoveryRetainListener {
				ownerState.endTransition()
				recoveryRetry.clear()
				if recoveryErr != nil {
					log.Printf("parent process exited; gateway listener retained (At risk): managed route recovery was not fully verified")
				}
				return true
			}
		}
		ownerState.endTransition()
		recoveryRetry.clear()
		return false
	}

	for {
		select {
		case sig := <-stop:
			log.Printf("shutting down after %s", sig)
			goto shutdown
		case <-retireRequested:
			log.Printf("shutting down after owner request")
			goto shutdown
		case loss := <-ownerLost:
			if !attemptOwnerLossRecovery(loss) {
				log.Printf("shutting down after parent process exited")
				goto shutdown
			}
		case <-recoveryRetry.channel:
			loss, pending := recoveryRetry.take()
			if !pending {
				continue
			}
			if !attemptOwnerLossRecovery(loss) {
				log.Printf("shutting down after parent process exited")
				goto shutdown
			}
		case err := <-errCh:
			if rootCtx.Err() != nil {
				goto shutdown
			}
			if err != nil && err != http.ErrServerClosed {
				return fmt.Errorf("gateway failed: %w", err)
			}
			return nil
		}
	}

shutdown:
	recoveryRetry.clear()
	cancelRoot()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil && !errors.Is(err, net.ErrClosed) {
		_ = srv.Close()
		return fmt.Errorf("shutdown failed: %w", err)
	}
	return nil
}

func defaultUsageLogPath() string {
	dir, err := os.UserConfigDir()
	if err != nil {
		return ""
	}
	return filepath.Join(dir, "RelayKit", "usage.jsonl")
}
