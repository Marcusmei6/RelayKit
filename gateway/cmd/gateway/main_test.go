package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestActivateCodexConfigRequiresExplicitTarget(t *testing.T) {
	source := filepath.Join(t.TempDir(), "codex.toml")
	if err := os.WriteFile(source, []byte("model = \"qwen3-coder\"\n"), 0600); err != nil {
		t.Fatal(err)
	}

	var stdout, stderr bytes.Buffer
	code := run([]string{"activate-codex-config", "-source", source}, &stdout, &stderr)

	if code == 0 {
		t.Fatal("expected failure")
	}
	if !strings.Contains(stderr.String(), "target is required") {
		t.Fatalf("stderr = %q", stderr.String())
	}
}

func TestSummarizeUsageAggregatesByDayProviderModel(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "usage.jsonl")
	body := strings.Join([]string{
		`{"timestamp":"2026-06-30T01:02:03Z","provider_id":"p1","model":"m1","input_tokens":1,"output_tokens":2,"total_tokens":3,"duration_ms":10}`,
		`{"timestamp":"2026-06-30T04:05:06Z","provider_id":"p1","model":"m1","input_tokens":4,"output_tokens":5,"total_tokens":9,"duration_ms":20}`,
		`{"timestamp":"2026-07-01T01:02:03Z","provider_id":"p1","model":"m2","input_tokens":7,"output_tokens":8,"total_tokens":15,"duration_ms":30}`,
	}, "\n") + "\n"
	if err := os.WriteFile(path, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}

	var stdout, stderr bytes.Buffer
	code := run([]string{"summarize-usage", "-path", path}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, stderr.String())
	}
	var got []usageSummary
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("decode summary err = %v; stdout=%s", err, stdout.String())
	}
	if len(got) != 2 {
		t.Fatalf("summary count = %d, got %+v", len(got), got)
	}
	if got[0].Day != "2026-06-30" || got[0].ProviderID != "p1" || got[0].Model != "m1" || got[0].Requests != 2 || got[0].InputTokens != 5 || got[0].OutputTokens != 7 || got[0].TotalTokens != 12 || got[0].DurationMS != 30 {
		t.Fatalf("first summary = %+v", got[0])
	}
	if got[1].Day != "2026-07-01" || got[1].Model != "m2" || got[1].Requests != 1 {
		t.Fatalf("second summary = %+v", got[1])
	}
}

func TestSummarizeUsageMissingFileReturnsEmpty(t *testing.T) {
	path := filepath.Join(t.TempDir(), "missing.jsonl")
	var stdout, stderr bytes.Buffer
	code := run([]string{"summarize-usage", "-path", path}, &stdout, &stderr)
	if code != 0 || strings.TrimSpace(stdout.String()) != "[]" || stderr.Len() != 0 {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
}

func TestActivateCodexConfigWritesExplicitTargetAndPrintsRollback(t *testing.T) {
	dir := t.TempDir()
	source := filepath.Join(dir, "codex.toml")
	target := filepath.Join(dir, "config.toml")
	if err := os.WriteFile(source, []byte("model = \"relaykit\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte("model = \"old\"\n"), 0600); err != nil {
		t.Fatal(err)
	}

	var stdout, stderr bytes.Buffer
	code := run([]string{"activate-codex-config", "-source", source, "-target", target}, &stdout, &stderr)

	if code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, stderr.String())
	}
	body, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != "model = \"relaykit\"\n" {
		t.Fatalf("target = %q", body)
	}
	if !strings.Contains(stdout.String(), "rollback: cp ") {
		t.Fatalf("stdout = %q", stdout.String())
	}
}

func TestEnableAndDisableCodexConfigUseExplicitManagedState(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "config.toml")
	catalog := filepath.Join(dir, "catalog.json")
	state := filepath.Join(dir, "state.json")
	const privateValue = "do-not-print-this-config-value"
	if err := os.WriteFile(target, []byte("model = \"keep\"\nsecret_note = \""+privateValue+"\"\n"), 0600); err != nil {
		t.Fatal(err)
	}

	var stdout, stderr bytes.Buffer
	code := run([]string{"enable-codex-config", "-target", target, "-catalog", catalog, "-state", state}, &stdout, &stderr)
	if code != 0 || stderr.Len() != 0 {
		t.Fatalf("enable code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
	if !strings.Contains(stdout.String(), "Codex config enabled") || strings.Contains(stdout.String(), privateValue) {
		t.Fatalf("enable output = %q", stdout.String())
	}
	configured, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(configured), "model = \"keep\"") || !strings.Contains(string(configured), "openai_base_url") {
		t.Fatalf("configured target = %q", configured)
	}

	stdout.Reset()
	stderr.Reset()
	code = run([]string{"disable-codex-config", "-target", target, "-state", state}, &stdout, &stderr)
	if code != 0 || stderr.Len() != 0 {
		t.Fatalf("disable code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
	if !strings.Contains(stdout.String(), "removed: openai_base_url, model_catalog_json") || strings.Contains(stdout.String(), privateValue) {
		t.Fatalf("disable output = %q", stdout.String())
	}
}

func TestEnableCodexConfigPassesCustomBaseURLWithoutOutputLeak(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "config.toml")
	catalog := filepath.Join(dir, "catalog.json")
	state := filepath.Join(dir, "state.json")
	baseURL := "http://" + randomLoopbackAddress(t) + "/v1"
	if err := os.WriteFile(target, []byte("model = \"keep\"\n"), 0600); err != nil {
		t.Fatal(err)
	}

	var stdout, stderr bytes.Buffer
	code := run([]string{"enable-codex-config", "-target", target, "-catalog", catalog, "-state", state, "-base-url", baseURL}, &stdout, &stderr)
	if code != 0 || stderr.Len() != 0 {
		t.Fatalf("enable code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
	if strings.Contains(stdout.String(), baseURL) || strings.Contains(stderr.String(), baseURL) {
		t.Fatalf("enable output leaked base URL: stdout=%q stderr=%q", stdout.String(), stderr.String())
	}
	configured, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(configured), "openai_base_url = "+strconv.Quote(baseURL)) {
		t.Fatalf("configured target = %q", configured)
	}
}

func TestDisableCodexConfigReportsRestoredPreviousValues(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "config.toml")
	catalog := filepath.Join(dir, "catalog.json")
	state := filepath.Join(dir, "state.json")
	if err := os.WriteFile(target, []byte("openai_base_url = \"http://127.0.0.1:11434/v1\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	if code := run([]string{"enable-codex-config", "-target", target, "-catalog", catalog, "-state", state}, &stdout, &stderr); code != 0 {
		t.Fatalf("enable code=%d stderr=%q", code, stderr.String())
	}
	stdout.Reset()
	stderr.Reset()
	if code := run([]string{"disable-codex-config", "-target", target, "-state", state}, &stdout, &stderr); code != 0 {
		t.Fatalf("disable code=%d stderr=%q", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "restored previous values: openai_base_url") {
		t.Fatalf("disable output = %q", stdout.String())
	}
}

func TestEnableCodexConfigRequiresExplicitArguments(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := run([]string{"enable-codex-config", "-target", "config.toml"}, &stdout, &stderr)
	if code != 2 || !strings.Contains(stderr.String(), "target, catalog, and state are required") {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
}

func TestCodexConfigStatusCommandReportsManagedState(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "config.toml")
	state := filepath.Join(dir, "state.json")
	catalog := filepath.Join(dir, "catalog.json")
	if err := os.WriteFile(target, []byte("model = \"keep\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	if code := run([]string{"enable-codex-config", "-target", target, "-catalog", catalog, "-state", state}, &stdout, &stderr); code != 0 {
		t.Fatalf("enable failed: %s", stderr.String())
	}
	stdout.Reset()
	stderr.Reset()
	if code := run([]string{"codex-config-status", "-target", target, "-state", state}, &stdout, &stderr); code != 0 || strings.TrimSpace(stdout.String()) != "enabled" {
		t.Fatalf("status code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
}

func TestActivateCodexConfigRefusesAuthJSONSource(t *testing.T) {
	dir := t.TempDir()
	source := filepath.Join(dir, "auth.json")
	target := filepath.Join(dir, "config.toml")
	if err := os.WriteFile(source, []byte(`{"token":"RELAYKIT_FAKE_SENTINEL_DO_NOT_USE"}`), 0600); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	code := run([]string{"activate-codex-config", "-source", source, "-target", target}, &stdout, &stderr)
	if code != 2 || !strings.Contains(stderr.String(), "auth.json paths are not allowed") {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
	if _, err := os.Stat(target); !os.IsNotExist(err) {
		t.Fatalf("target should not exist, stat err = %v", err)
	}
}

func TestReadCredentialHandoff(t *testing.T) {
	credentials, err := readCredentialHandoff(strings.NewReader(`{"version":1,"credentials":{"relaykit.provider.one":"fixture-secret"}}`))
	if err != nil {
		t.Fatalf("readCredentialHandoff err = %v", err)
	}
	if len(credentials) != 1 || credentials["relaykit.provider.one"] != "fixture-secret" {
		t.Fatalf("credentials = %#v", credentials)
	}
}

func TestReadCredentialHandoffRejectsInvalidPayloadWithoutEchoingSecret(t *testing.T) {
	const secret = "fixture-secret-must-not-leak"
	_, err := readCredentialHandoff(strings.NewReader(`{"version":2,"credentials":{"relaykit.provider.one":"` + secret + `"}}`))
	if err == nil {
		t.Fatal("invalid credential handoff unexpectedly passed")
	}
	if strings.Contains(err.Error(), secret) {
		t.Fatalf("credential handoff error leaked secret: %v", err)
	}
}

func TestParseParentPIDRequiresPositiveInteger(t *testing.T) {
	for _, tc := range []struct {
		value string
		want  int
		valid bool
	}{
		{"1", 1, true},
		{"0", 0, false},
		{"-1", 0, false},
		{"not-a-pid", 0, false},
	} {
		t.Run(tc.value, func(t *testing.T) {
			got, err := parseParentPID(tc.value)
			if tc.valid {
				if err != nil || got != tc.want {
					t.Fatalf("parseParentPID(%q) = %d, %v", tc.value, got, err)
				}
				return
			}
			if err == nil {
				t.Fatalf("parseParentPID(%q) unexpectedly succeeded", tc.value)
			}
		})
	}
}

func TestGatewayParentLossRejectsIncompleteManagedRouteFlags(t *testing.T) {
	configPath := writeGatewayConfig(t)
	target := filepath.Join(t.TempDir(), "config.toml")
	state := filepath.Join(t.TempDir(), "state.json")
	for _, tc := range []struct {
		args []string
		want string
	}{
		{args: []string{"-listen", randomLoopbackAddress(t), "-config", configPath, "-managed-codex-target", target}, want: "managed Codex target and state"},
		{args: []string{"-listen", randomLoopbackAddress(t), "-config", configPath, "-managed-codex-target", target, "-managed-codex-state", state}, want: "positive parent PID"},
	} {
		err := runServer(tc.args, strings.NewReader(""), io.Discard)
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Fatalf("runServer(%q) error = %v, want %q", tc.args, err, tc.want)
		}
	}
}

func TestGatewayParentLossRejectsAuthAndSymlinkManagedPaths(t *testing.T) {
	dir := t.TempDir()
	authPath := filepath.Join(dir, "auth.json")
	if err := os.WriteFile(authPath, []byte(`{"fixture":"RELAYKIT_FAKE_SENTINEL_DO_NOT_USE"}`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := validateManagedCodexRecoveryPaths(os.Getpid(), authPath, filepath.Join(dir, "state.json")); err == nil || !strings.Contains(err.Error(), "must not be auth.json") {
		t.Fatalf("auth target error = %v", err)
	}
	link := filepath.Join(dir, "config.toml")
	if err := os.Symlink(filepath.Join(dir, "target.toml"), link); err != nil {
		t.Fatal(err)
	}
	if err := validateManagedCodexRecoveryPaths(os.Getpid(), link, filepath.Join(dir, "state.json")); err == nil || !strings.Contains(err.Error(), "must not be a symbolic link") {
		t.Fatalf("symlink target error = %v", err)
	}
}

func TestGatewayParentLossRestoresManagedRouteBeforeStopping(t *testing.T) {
	if os.Getenv("RELAYKIT_TEST_PARENT") == "restore" {
		time.Sleep(300 * time.Millisecond)
		os.Exit(0)
	}

	parent := exec.Command(os.Args[0], "-test.run=^TestGatewayParentLossRestoresManagedRouteBeforeStopping$")
	parent.Env = append(os.Environ(), "RELAYKIT_TEST_PARENT=restore")
	if err := parent.Start(); err != nil {
		t.Fatal(err)
	}

	dir := t.TempDir()
	target := filepath.Join(dir, "config.toml")
	state := filepath.Join(dir, "state.json")
	original := []byte("model = \"keep\"\n")
	if err := os.WriteFile(target, original, 0600); err != nil {
		t.Fatal(err)
	}
	managedBaseURL := "http://" + randomLoopbackAddress(t) + "/v1"
	if code := run([]string{"enable-codex-config", "-target", target, "-catalog", filepath.Join(dir, "catalog.json"), "-state", state, "-base-url", managedBaseURL}, io.Discard, io.Discard); code != 0 {
		t.Fatal("could not create managed route")
	}
	configPath := writeGatewayConfig(t)
	listenAddress := randomLoopbackAddress(t)
	usagePath := filepath.Join(t.TempDir(), "usage.jsonl")
	done := make(chan error, 1)
	go func() {
		done <- runServer([]string{
			"-listen", listenAddress,
			"-config", configPath,
			"-usage-log", usagePath,
			"-parent-pid", strconv.Itoa(parent.Process.Pid),
			"-managed-codex-target", target,
			"-managed-codex-state", state,
		}, strings.NewReader(""), io.Discard)
	}()
	if err := parent.Wait(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("runServer returned %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("gateway did not stop after parent exited")
	}
	got, err := os.ReadFile(target)
	if err != nil || string(got) != string(original) {
		t.Fatalf("managed route was not restored: %q, %v", got, err)
	}
}

func TestGatewayParentLossRetainsListenerWhenRecoveryIsUnsafe(t *testing.T) {
	if os.Getenv("RELAYKIT_TEST_PARENT") == "retain" {
		time.Sleep(300 * time.Millisecond)
		os.Exit(0)
	}

	parent := exec.Command(os.Args[0], "-test.run=^TestGatewayParentLossRetainsListenerWhenRecoveryIsUnsafe$")
	parent.Env = append(os.Environ(), "RELAYKIT_TEST_PARENT=retain")
	if err := parent.Start(); err != nil {
		t.Fatal(err)
	}

	dir := t.TempDir()
	target := filepath.Join(dir, "config.toml")
	state := filepath.Join(dir, "state.json")
	catalog := filepath.Join(dir, "catalog.json")
	if err := os.WriteFile(target, []byte("model = \"keep\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if code := run([]string{"enable-codex-config", "-target", target, "-catalog", catalog, "-state", state}, io.Discard, io.Discard); code != 0 {
		t.Fatal("could not create managed route")
	}
	configured, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	partial := strings.Replace(string(configured), "model_catalog_json = "+strconv.Quote(catalog), "model_catalog_json = \"/later/catalog.json\"", 1)
	if partial == string(configured) {
		t.Fatal("could not create partial catalog drift")
	}
	if err := os.WriteFile(target, []byte(partial), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0500); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(dir, 0700)
	address := randomLoopbackAddress(t)
	configPath := writeGatewayConfig(t)
	usagePath := filepath.Join(t.TempDir(), "usage.jsonl")
	go func() {
		_ = runServer([]string{
			"-listen", address,
			"-config", configPath,
			"-usage-log", usagePath,
			"-parent-pid", strconv.Itoa(parent.Process.Pid),
			"-managed-codex-target", target,
			"-managed-codex-state", state,
		}, strings.NewReader(""), io.Discard)
	}()
	if err := parent.Wait(); err != nil {
		t.Fatal(err)
	}
	time.Sleep(600 * time.Millisecond)
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", address, 50*time.Millisecond)
		if err == nil {
			conn.Close()
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatal("gateway listener was not retained after unsafe recovery")
}

func TestGatewayParentLossRetainsListenerAfterAppPipeReadersClose(t *testing.T) {
	const modeKey = "RELAYKIT_TEST_BROKEN_APP_PIPE_MODE"
	switch os.Getenv(modeKey) {
	case "parent":
		runBrokenAppPipeParent(modeKey)
		return
	case "helper":
		os.Exit(run([]string{
			"-listen", os.Getenv("RELAYKIT_TEST_LISTEN"),
			"-config", os.Getenv("RELAYKIT_TEST_PROVIDER_CONFIG"),
			"-credential-stdin",
			"-parent-pid", os.Getenv("RELAYKIT_TEST_PARENT_PID"),
			"-managed-codex-target", os.Getenv("RELAYKIT_TEST_CODEX_TARGET"),
			"-managed-codex-state", os.Getenv("RELAYKIT_TEST_CODEX_STATE"),
		}, os.Stdout, os.Stderr))
	}

	dir := t.TempDir()
	target := filepath.Join(dir, "config.toml")
	state := filepath.Join(dir, "state.json")
	catalog := filepath.Join(dir, "catalog.json")
	pidPath := filepath.Join(t.TempDir(), "helper.pid")
	address := randomLoopbackAddress(t)
	managedBaseURL := "http://" + address + "/v1"
	if err := os.WriteFile(target, []byte("model = \"keep\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if code := run([]string{
		"enable-codex-config",
		"-target", target,
		"-catalog", catalog,
		"-state", state,
		"-base-url", managedBaseURL,
	}, io.Discard, io.Discard); code != 0 {
		t.Fatal("could not create managed route")
	}

	parent := exec.Command(os.Args[0], "-test.run=^TestGatewayParentLossRetainsListenerAfterAppPipeReadersClose$")
	parent.Env = append(os.Environ(),
		modeKey+"=parent",
		"RELAYKIT_TEST_LISTEN="+address,
		"RELAYKIT_TEST_PROVIDER_CONFIG="+writeGatewayConfig(t),
		"RELAYKIT_TEST_CODEX_TARGET="+target,
		"RELAYKIT_TEST_CODEX_STATE="+state,
		"RELAYKIT_TEST_HELPER_PID_PATH="+pidPath,
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
		_ = os.Chmod(dir, 0700)
		_ = run([]string{"disable-codex-config", "-target", target, "-state", state}, io.Discard, io.Discard)
		_ = syscall.Kill(helperPID, syscall.SIGTERM)
	}()
	waitForLoopbackListener(t, address)
	if err := os.Chmod(dir, 0500); err != nil {
		t.Fatal(err)
	}
	if code := run([]string{"disable-codex-config", "-target", target, "-state", state}, io.Discard, io.Discard); code == 0 {
		t.Fatal("restore-failure injection did not prevent managed config restoration")
	}
	configured, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(configured), managedBaseURL) {
		t.Fatal("restore-failure injection removed the managed base URL")
	}

	if err := parentInput.Close(); err != nil {
		t.Fatal(err)
	}
	if err := parent.Wait(); err != nil {
		t.Fatalf("fake App parent exit failed: %v", err)
	}
	time.Sleep(750 * time.Millisecond)
	if err := syscall.Kill(helperPID, 0); err != nil {
		t.Fatalf("gateway helper exited after App pipe readers closed: %v", err)
	}
	if conn, err := net.DialTimeout("tcp", address, 250*time.Millisecond); err != nil {
		t.Fatalf("gateway listener disappeared after App pipe readers closed: %v", err)
	} else {
		_ = conn.Close()
	}
}

func runBrokenAppPipeParent(modeKey string) {
	stdoutReader, stdoutWriter, err := os.Pipe()
	if err != nil {
		os.Exit(2)
	}
	stderrReader, stderrWriter, err := os.Pipe()
	if err != nil {
		_ = stdoutReader.Close()
		_ = stdoutWriter.Close()
		os.Exit(2)
	}
	helper := exec.Command(os.Args[0], "-test.run=^TestGatewayParentLossRetainsListenerAfterAppPipeReadersClose$")
	helper.Env = append(os.Environ(),
		modeKey+"=helper",
		"RELAYKIT_TEST_PARENT_PID="+strconv.Itoa(os.Getpid()),
	)
	helper.Stdin = strings.NewReader(`{"version":1,"credentials":{}}`)
	helper.Stdout = stdoutWriter
	helper.Stderr = stderrWriter
	if err := helper.Start(); err != nil {
		_ = stdoutReader.Close()
		_ = stdoutWriter.Close()
		_ = stderrReader.Close()
		_ = stderrWriter.Close()
		os.Exit(2)
	}
	_ = stdoutWriter.Close()
	_ = stderrWriter.Close()
	if err := os.WriteFile(os.Getenv("RELAYKIT_TEST_HELPER_PID_PATH"), []byte(strconv.Itoa(helper.Process.Pid)), 0600); err != nil {
		_ = helper.Process.Kill()
		_ = stdoutReader.Close()
		_ = stderrReader.Close()
		os.Exit(2)
	}
	_, _ = io.Copy(io.Discard, os.Stdin)
	_ = stdoutReader.Close()
	_ = stderrReader.Close()
	os.Exit(0)
}

func waitForPIDFile(t *testing.T, path string) int {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		data, err := os.ReadFile(path)
		if err == nil {
			pid, parseErr := strconv.Atoi(strings.TrimSpace(string(data)))
			if parseErr == nil && pid > 0 {
				return pid
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("fake App parent did not publish the helper PID")
	return 0
}

func waitForLoopbackListener(t *testing.T, address string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", address, 50*time.Millisecond)
		if err == nil {
			_ = conn.Close()
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("gateway helper did not start its loopback listener")
}

func writeGatewayConfig(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "providers.json")
	config := `{"providers":[{"id":"test","name":"Test","base_url":"http://127.0.0.1:9/v1","api_format":"openai_chat","models":[{"id":"test-model"}]}]}`
	if err := os.WriteFile(path, []byte(config), 0600); err != nil {
		t.Fatal(err)
	}
	return path
}

func randomLoopbackAddress(t *testing.T) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	return address
}
