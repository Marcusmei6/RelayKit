package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	toml "github.com/pelletier/go-toml"
)

func TestGatewayParentLossRestoresConfigAndKeepsCachedClientContinuity(t *testing.T) {
	const modeKey = "RELAYKIT_TEST_TWO_EPOCH_MODE"
	switch os.Getenv(modeKey) {
	case "parent":
		runTwoEpochFakeAppParent(modeKey)
		return
	case "helper":
		os.Exit(run([]string{
			"-listen", os.Getenv("RELAYKIT_TEST_LISTEN"),
			"-config", os.Getenv("RELAYKIT_TEST_PROVIDER_CONFIG"),
			"-usage-log", os.Getenv("RELAYKIT_TEST_USAGE_LOG"),
			"-credential-stdin",
			"-parent-pid", os.Getenv("RELAYKIT_TEST_PARENT_PID"),
			"-managed-codex-target", os.Getenv("RELAYKIT_TEST_CODEX_TARGET"),
			"-managed-codex-state", os.Getenv("RELAYKIT_TEST_CODEX_STATE"),
			"-control-token-file", os.Getenv("RELAYKIT_TEST_CONTROL_TOKEN"),
		}, os.Stdout, os.Stderr))
	}

	var gatewayUpstreamHits atomic.Int32
	var directClientHits atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/v1/chat/completions":
			gatewayUpstreamHits.Add(1)
			_, _ = io.WriteString(w, `{"id":"chatcmpl-two-epoch","model":"official-upstream","choices":[{"message":{"role":"assistant","content":"fixture response"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`)
		case "/v1/responses":
			directClientHits.Add(1)
			_, _ = io.WriteString(w, `{"id":"resp-direct","object":"response","model":"official-upstream","status":"completed","output":[],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}`)
		default:
			http.NotFound(w, r)
		}
	}))
	defer upstream.Close()

	dir := t.TempDir()
	target := filepath.Join(dir, "config.toml")
	state := filepath.Join(dir, "state.json")
	catalog := filepath.Join(dir, "catalog.json")
	configPath := filepath.Join(dir, "providers.json")
	credentialPath := filepath.Join(dir, "official.key")
	controlTokenPath := filepath.Join(dir, "control.token")
	usagePath := filepath.Join(dir, "usage.jsonl")
	pidPath := filepath.Join(dir, "helper.pid")
	address := randomLoopbackAddress(t)
	cachedBaseURL := "http://" + address + "/v1"
	directBaseURL := upstream.URL + "/v1"

	original := []byte("model = \"official-model\"\nopenai_base_url = " + strconv.Quote(directBaseURL) + "\n")
	if err := os.WriteFile(target, original, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(credentialPath, []byte("fixture-token"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(controlTokenPath, []byte(strings.Repeat("a", 64)), 0600); err != nil {
		t.Fatal(err)
	}
	configBody, err := json.Marshal(map[string]any{
		"official_passthrough": map[string]any{
			"base_url": upstream.URL + "/v1",
			"credential_ref": map[string]string{
				"kind":   "key_file",
				"value":  credentialPath,
				"header": "Authorization",
			},
			"models": []map[string]string{{
				"id":             "official-model",
				"upstream_model": "official-upstream",
			}},
		},
		"providers": []any{},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath, configBody, 0600); err != nil {
		t.Fatal(err)
	}
	if code := run([]string{
		"enable-codex-config",
		"-target", target,
		"-catalog", catalog,
		"-state", state,
		"-base-url", cachedBaseURL,
	}, io.Discard, io.Discard); code != 0 {
		t.Fatal("could not create managed route")
	}

	parent := exec.Command(os.Args[0], "-test.run=^TestGatewayParentLossRestoresConfigAndKeepsCachedClientContinuity$")
	parent.Env = append(os.Environ(),
		modeKey+"=parent",
		"RELAYKIT_TEST_LISTEN="+address,
		"RELAYKIT_TEST_PROVIDER_CONFIG="+configPath,
		"RELAYKIT_TEST_USAGE_LOG="+usagePath,
		"RELAYKIT_TEST_CODEX_TARGET="+target,
		"RELAYKIT_TEST_CODEX_STATE="+state,
		"RELAYKIT_TEST_HELPER_PID_PATH="+pidPath,
		"RELAYKIT_TEST_CONTROL_TOKEN="+controlTokenPath,
	)
	parentInput, err := parent.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	parent.Stdout = io.Discard
	parent.Stderr = io.Discard
	if err := parent.Start(); err != nil {
		t.Fatal(err)
	}

	helperPID := waitForPIDFile(t, pidPath)
	defer func() {
		_ = syscall.Kill(helperPID, syscall.SIGTERM)
		_ = parentInput.Close()
		if parent.Process != nil {
			_ = parent.Process.Kill()
		}
	}()
	waitForLoopbackListener(t, address)

	cachedClient := &http.Client{Timeout: 2 * time.Second}
	sendCachedOfficialRequest(t, cachedClient, cachedBaseURL)
	if gatewayUpstreamHits.Load() != 1 {
		t.Fatalf("first cached request upstream hits = %d", gatewayUpstreamHits.Load())
	}

	if err := parentInput.Close(); err != nil {
		t.Fatal(err)
	}
	if err := parent.Wait(); err != nil {
		t.Fatalf("fake App parent exit failed: %v", err)
	}
	waitForRestoredDirectBaseURL(t, target, directBaseURL)

	restoredBaseURL := readConfiguredBaseURL(t, target)
	directRequest, err := http.NewRequest(http.MethodPost, restoredBaseURL+"/responses", bytes.NewBufferString(`{"model":"official-model","input":"fixture direct"}`))
	if err != nil {
		t.Fatal(err)
	}
	directRequest.Header.Set("Content-Type", "application/json")
	directResponse, err := (&http.Client{Timeout: 2 * time.Second}).Do(directRequest)
	if err != nil {
		t.Fatalf("new client could not use restored direct Official base URL: %v", err)
	}
	_ = directResponse.Body.Close()
	if directResponse.StatusCode != http.StatusOK || directClientHits.Load() != 1 {
		t.Fatalf("new client direct response = %d, hits = %d", directResponse.StatusCode, directClientHits.Load())
	}

	time.Sleep(500 * time.Millisecond)
	sendCachedOfficialRequest(t, cachedClient, cachedBaseURL)
	if gatewayUpstreamHits.Load() != 2 {
		t.Fatalf("second cached request upstream hits = %d", gatewayUpstreamHits.Load())
	}
	if err := syscall.Kill(helperPID, 0); err != nil {
		t.Fatalf("helper exited after successful config restoration: %v", err)
	}

	var controlOutput bytes.Buffer
	var controlError bytes.Buffer
	controlEndpoint := "http://" + address
	if code := gatewayControl([]string{
		"-endpoint", controlEndpoint,
		"-token-file", controlTokenPath,
		"-action", "adopt",
		"-parent-pid", strconv.Itoa(os.Getpid()),
	}, strings.NewReader(`{"version":1,"credentials":{}}`), &controlOutput, &controlError); code != 0 {
		t.Fatalf("new App could not adopt the fallback data plane: %s", controlError.String())
	}
	if !strings.Contains(controlOutput.String(), "gateway control adopt: managed") {
		t.Fatalf("adopt output = %q", controlOutput.String())
	}
	assertGatewayMode(t, controlEndpoint, "managed")
	if err := syscall.Kill(helperPID, 0); err != nil {
		t.Fatalf("adoption replaced the helper process: %v", err)
	}
	if code := gatewayControl([]string{
		"-endpoint", controlEndpoint,
		"-token-file", controlTokenPath,
		"-action", "release",
		"-parent-pid", strconv.Itoa(os.Getpid()),
	}, strings.NewReader(""), io.Discard, io.Discard); code != 0 {
		t.Fatal("adopted App could not release the data plane into fallback")
	}
	assertGatewayMode(t, controlEndpoint, "official_fallback")
	sendCachedOfficialRequest(t, cachedClient, cachedBaseURL)
	if code := gatewayControl([]string{
		"-endpoint", controlEndpoint,
		"-token-file", controlTokenPath,
		"-action", "adopt",
		"-parent-pid", strconv.Itoa(os.Getpid()),
		"-route-enabled=false",
	}, strings.NewReader(`{"version":1,"credentials":{}}`), io.Discard, io.Discard); code != 0 {
		t.Fatal("disabled App could not adopt the data plane for fallback monitoring")
	}
	assertGatewayMode(t, controlEndpoint, "official_fallback")
	if code := gatewayControl([]string{
		"-endpoint", controlEndpoint,
		"-token-file", controlTokenPath,
		"-action", "adopt",
		"-parent-pid", strconv.Itoa(os.Getpid()),
	}, strings.NewReader(`{"version":1,"credentials":{}}`), io.Discard, io.Discard); code != 0 {
		t.Fatal("released data plane could not be adopted again")
	}
	if code := gatewayControl([]string{
		"-endpoint", controlEndpoint,
		"-token-file", controlTokenPath,
		"-action", "shutdown",
		"-parent-pid", strconv.Itoa(os.Getpid()),
	}, strings.NewReader(""), io.Discard, io.Discard); code != 0 {
		t.Fatal("adopted App could not explicitly retire the data plane")
	}
}

func runTwoEpochFakeAppParent(modeKey string) {
	helper := exec.Command(os.Args[0], "-test.run=^TestGatewayParentLossRestoresConfigAndKeepsCachedClientContinuity$")
	helper.Env = append(os.Environ(),
		modeKey+"=helper",
		"RELAYKIT_TEST_PARENT_PID="+strconv.Itoa(os.Getpid()),
	)
	helper.Stdin = strings.NewReader(`{"version":1,"credentials":{}}`)
	helper.Stdout = io.Discard
	helper.Stderr = io.Discard
	if err := helper.Start(); err != nil {
		os.Exit(2)
	}
	if err := os.WriteFile(os.Getenv("RELAYKIT_TEST_HELPER_PID_PATH"), []byte(strconv.Itoa(helper.Process.Pid)), 0600); err != nil {
		_ = helper.Process.Kill()
		os.Exit(2)
	}
	_, _ = io.Copy(io.Discard, os.Stdin)
	os.Exit(0)
}

func sendCachedOfficialRequest(t *testing.T, client *http.Client, baseURL string) {
	t.Helper()
	request, err := http.NewRequest(http.MethodPost, baseURL+"/responses", bytes.NewBufferString(`{"model":"official-model","input":"fixture cached"}`))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := client.Do(request)
	if err != nil {
		t.Fatalf("cached Codex client lost RelayKit continuity after config restoration: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("cached Codex client response after config restoration = %d", response.StatusCode)
	}
}

func waitForRestoredDirectBaseURL(t *testing.T, target, expected string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if readConfiguredBaseURLIfAvailable(target) == expected {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("managed config was not restored to the direct Official base URL")
}

func readConfiguredBaseURL(t *testing.T, target string) string {
	t.Helper()
	value := readConfiguredBaseURLIfAvailable(target)
	if value == "" {
		t.Fatal("restored config has no openai_base_url")
	}
	return value
}

func readConfiguredBaseURLIfAvailable(target string) string {
	body, err := os.ReadFile(target)
	if err != nil {
		return ""
	}
	tree, err := toml.LoadBytes(body)
	if err != nil {
		return ""
	}
	value, _ := tree.Get("openai_base_url").(string)
	return value
}

func assertGatewayMode(t *testing.T, endpoint, expected string) {
	t.Helper()
	response, err := (&http.Client{Timeout: 2 * time.Second}).Get(endpoint + "/healthz")
	if err != nil {
		t.Fatalf("gateway health failed: %v", err)
	}
	defer response.Body.Close()
	var body map[string]any
	if err := json.NewDecoder(response.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if body["mode"] != expected {
		t.Fatalf("gateway mode = %#v, want %q", body["mode"], expected)
	}
}

func TestGatewayControlTokenFileFailsClosed(t *testing.T) {
	dir := t.TempDir()
	token := strings.Repeat("b", 64)
	valid := filepath.Join(dir, "control.token")
	if err := os.WriteFile(valid, []byte(token), 0600); err != nil {
		t.Fatal(err)
	}
	if got, err := readControlToken(valid); err != nil || got != token {
		t.Fatalf("valid control token = %q, %v", got, err)
	}

	authPath := filepath.Join(dir, "auth.json")
	if err := os.WriteFile(authPath, []byte(token), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := readControlToken(authPath); err == nil {
		t.Fatal("auth.json control token path was accepted")
	}
	link := filepath.Join(dir, "linked.token")
	if err := os.Symlink(valid, link); err != nil {
		t.Fatal(err)
	}
	if _, err := readControlToken(link); err == nil {
		t.Fatal("symlink control token path was accepted")
	}
	wide := filepath.Join(dir, "wide.token")
	if err := os.WriteFile(wide, []byte(token), 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := readControlToken(wide); err == nil {
		t.Fatal("group/world-readable control token path was accepted")
	}
}

func TestGatewayControlAdoptDoesNotExposeTokenOrCredential(t *testing.T) {
	dir := t.TempDir()
	token := strings.Repeat("c", 64)
	credential := "fixture-control-credential"
	tokenPath := filepath.Join(dir, "control.token")
	if err := os.WriteFile(tokenPath, []byte(token), 0600); err != nil {
		t.Fatal(err)
	}
	var received gatewayControlRequest
	control := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatal(err)
		}
		plaintext, err := openGatewayControlPayload(token, body)
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(plaintext, &received); err != nil {
			t.Fatal(err)
		}
		response, err := json.Marshal(gatewayControlResponse{Status: "ok", Mode: "managed"})
		if err != nil {
			t.Fatal(err)
		}
		encrypted, err := sealGatewayControlPayload(token, response)
		if err != nil {
			t.Fatal(err)
		}
		w.Header().Set("Content-Type", "application/vnd.relaykit.control+json")
		_, _ = w.Write(encrypted)
	}))
	defer control.Close()

	var stdout, stderr bytes.Buffer
	code := gatewayControl([]string{
		"-endpoint", control.URL,
		"-token-file", tokenPath,
		"-action", "adopt",
		"-parent-pid", strconv.Itoa(os.Getpid()),
	}, strings.NewReader(`{"version":1,"credentials":{"fixture.ref":"`+credential+`"}}`), &stdout, &stderr)
	if code != 0 || received.Action != "adopt" || received.Credentials["fixture.ref"] != credential {
		t.Fatalf("control result code=%d request=%+v stderr=%q", code, received, stderr.String())
	}
	for _, secret := range []string{token, credential} {
		if strings.Contains(stdout.String(), secret) || strings.Contains(stderr.String(), secret) {
			t.Fatalf("control output exposed fixture secret")
		}
	}
}

func TestGatewayControlDoesNotExposeSecretsToUnverifiedEndpoint(t *testing.T) {
	dir := t.TempDir()
	token := strings.Repeat("d", 64)
	credential := "fixture-unverified-endpoint-credential"
	tokenPath := filepath.Join(dir, "control.token")
	if err := os.WriteFile(tokenPath, []byte(token), 0600); err != nil {
		t.Fatal(err)
	}

	var observed bytes.Buffer
	unverified := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for name, values := range r.Header {
			observed.WriteString(name)
			observed.WriteString(strings.Join(values, ","))
		}
		body, _ := io.ReadAll(r.Body)
		observed.Write(body)
		http.Error(w, "not RelayKit", http.StatusUnauthorized)
	}))
	defer unverified.Close()

	code := gatewayControl([]string{
		"-endpoint", unverified.URL,
		"-token-file", tokenPath,
		"-action", "adopt",
		"-parent-pid", strconv.Itoa(os.Getpid()),
	}, strings.NewReader(`{"version":1,"credentials":{"fixture.ref":"`+credential+`"}}`), io.Discard, io.Discard)
	if code == 0 {
		t.Fatal("unverified endpoint was accepted")
	}
	for _, secret := range []string{token, credential} {
		if strings.Contains(observed.String(), secret) {
			t.Fatalf("unverified endpoint observed a control secret")
		}
	}
}
