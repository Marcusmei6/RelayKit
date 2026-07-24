package codexconfig

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/pelletier/go-toml"
)

func TestActivateRequiresExplicitTarget(t *testing.T) {
	_, err := Activate("", []byte("model = \"qwen3-coder\"\n"))
	if err == nil {
		t.Fatal("expected error")
	}
}

func TestActivateRejectsEmptyContent(t *testing.T) {
	_, err := Activate(filepath.Join(t.TempDir(), "config.toml"), nil)
	if err == nil {
		t.Fatal("expected error")
	}
}

func TestActivateWritesNewConfigWithoutBackup(t *testing.T) {
	target := filepath.Join(t.TempDir(), "config.toml")

	result, err := Activate(target, []byte("model = \"qwen3-coder\"\n"))
	if err != nil {
		t.Fatalf("Activate err = %v", err)
	}
	if result.BackupPath != "" {
		t.Fatalf("backup = %q, want empty", result.BackupPath)
	}
	body, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != "model = \"qwen3-coder\"\n" {
		t.Fatalf("body = %q", body)
	}
}

func TestActivateBacksUpExistingConfigAndRestoreRollback(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "config.toml")
	if err := os.WriteFile(target, []byte("model = \"old\"\n"), 0600); err != nil {
		t.Fatal(err)
	}

	result, err := Activate(target, []byte("model = \"relaykit\"\n"))
	if err != nil {
		t.Fatalf("Activate err = %v", err)
	}
	if result.BackupPath == "" || !strings.HasPrefix(result.RollbackCommand, "cp ") {
		t.Fatalf("result = %+v", result)
	}
	backup, err := os.ReadFile(result.BackupPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(backup) != "model = \"old\"\n" {
		t.Fatalf("backup = %q", backup)
	}

	if err := Restore(target, result.BackupPath); err != nil {
		t.Fatalf("Restore err = %v", err)
	}
	restored, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	if string(restored) != "model = \"old\"\n" {
		t.Fatalf("restored = %q", restored)
	}
}

func TestRestoreRequiresExistingBackup(t *testing.T) {
	err := Restore(filepath.Join(t.TempDir(), "config.toml"), "missing.toml")
	if err == nil {
		t.Fatal("expected error")
	}
}

func TestEnableStructurallyMergesOnlyManagedRootValues(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "config.toml")
	statePath := filepath.Join(dir, "relaykit-state.json")
	catalogPath := filepath.Join(dir, "catalog.json")
	original := []byte(`# existing Codex configuration
model = "keep-this-model"
model_provider = "keep-this-provider"
approval_policy = "on-request"
features = ["one", "two"]

[mcp_servers.docs]
command = "docs-server"
args = ["--stdio"]

[[profiles]]
name = "existing"
enabled = true
`)
	if err := os.WriteFile(target, original, 0644); err != nil {
		t.Fatal(err)
	}

	result, err := Enable(EnableOptions{TargetPath: target, CatalogPath: catalogPath, StatePath: statePath})
	if err != nil {
		t.Fatalf("Enable err = %v", err)
	}
	if result.BackupPath == "" {
		t.Fatal("expected backup")
	}
	assertMode(t, result.BackupPath, 0600)
	assertMode(t, statePath, 0600)
	assertMode(t, target, 0600)
	backup, err := os.ReadFile(result.BackupPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(backup) != string(original) {
		t.Fatalf("backup differs from original: %q", backup)
	}

	merged := loadTOML(t, target)
	if got := merged.Get("model"); got != "keep-this-model" {
		t.Fatalf("model = %#v", got)
	}
	if got := merged.Get("model_provider"); got != "keep-this-provider" {
		t.Fatalf("model_provider = %#v", got)
	}
	if got := merged.Get("approval_policy"); got != "on-request" {
		t.Fatalf("approval_policy = %#v", got)
	}
	if got := merged.Get("openai_base_url"); got != managedOpenAIBaseURL {
		t.Fatalf("openai_base_url = %#v", got)
	}
	if got := merged.Get("model_catalog_json"); got != catalogPath {
		t.Fatalf("model_catalog_json = %#v", got)
	}
	if got := merged.Get("mcp_servers.docs.command"); got != "docs-server" {
		t.Fatalf("mcp table was not preserved: %#v", got)
	}
	profiles, ok := merged.Get("profiles").([]*toml.Tree)
	if !ok || len(profiles) != 1 || profiles[0].Get("name") != "existing" {
		t.Fatalf("profiles array was not preserved: %#v", merged.Get("profiles"))
	}

	stateBody, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(stateBody), "keep-this-model") {
		t.Fatalf("state contains target config data: %s", stateBody)
	}
	var state managedState
	if err := json.Unmarshal(stateBody, &state); err != nil {
		t.Fatal(err)
	}
	if state.Target != target || state.Backup != result.BackupPath || state.Managed.ModelCatalogJSON != catalogPath {
		t.Fatalf("state = %+v", state)
	}
}

func TestEnableManagedOpenAIBaseURLDefaultsAndRestoresCustomLoopback(t *testing.T) {
	t.Run("default remains the established managed URL", func(t *testing.T) {
		dir := t.TempDir()
		target := filepath.Join(dir, "config.toml")
		state := filepath.Join(dir, "state.json")
		if err := os.WriteFile(target, []byte("model = \"keep\"\n"), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := Enable(EnableOptions{TargetPath: target, CatalogPath: filepath.Join(dir, "catalog.json"), StatePath: state}); err != nil {
			t.Fatal(err)
		}
		if got := loadTOML(t, target).Get("openai_base_url"); got != managedOpenAIBaseURL {
			t.Fatalf("openai_base_url = %#v", got)
		}
		stateBody, err := os.ReadFile(state)
		if err != nil {
			t.Fatal(err)
		}
		var managed managedState
		if err := json.Unmarshal(stateBody, &managed); err != nil {
			t.Fatal(err)
		}
		if managed.Managed.OpenAIBaseURL != managedOpenAIBaseURL {
			t.Fatalf("managed state base URL = %q", managed.Managed.OpenAIBaseURL)
		}
	})

	t.Run("custom loopback is recorded and restored by parent-loss recovery", func(t *testing.T) {
		dir := t.TempDir()
		target := filepath.Join(dir, "config.toml")
		state := filepath.Join(dir, "state.json")
		original := []byte("model = \"keep\"\nopenai_base_url = \"http://127.0.0.1:11434/v1\"\n")
		if err := os.WriteFile(target, original, 0600); err != nil {
			t.Fatal(err)
		}
		baseURL := randomLoopbackBaseURL(t)
		if _, err := Enable(EnableOptions{
			TargetPath:           target,
			CatalogPath:          filepath.Join(dir, "catalog.json"),
			StatePath:            state,
			ManagedOpenAIBaseURL: baseURL,
		}); err != nil {
			t.Fatal(err)
		}
		if got := loadTOML(t, target).Get("openai_base_url"); got != baseURL {
			t.Fatalf("openai_base_url = %#v", got)
		}
		stateBody, err := os.ReadFile(state)
		if err != nil {
			t.Fatal(err)
		}
		var managed managedState
		if err := json.Unmarshal(stateBody, &managed); err != nil {
			t.Fatal(err)
		}
		if managed.Managed.OpenAIBaseURL != baseURL {
			t.Fatalf("managed state base URL = %q", managed.Managed.OpenAIBaseURL)
		}
		decision, err := RecoveryDecisionForParentLoss(target, state)
		if err != nil || decision != RecoveryShutdown {
			t.Fatalf("decision=%q err=%v", decision, err)
		}
		got, err := os.ReadFile(target)
		if err != nil || string(got) != string(original) {
			t.Fatalf("original values not restored: %q, %v", got, err)
		}
	})
}

func TestEnableRejectsInvalidManagedOpenAIBaseURLWithoutLeak(t *testing.T) {
	invalidURLs := []string{
		"https://127.0.0.1:23456/v1",
		"http://localhost:23456/v1",
		"http://[::1]:23456/v1",
		"http://user@127.0.0.1:23456/v1",
		"http://127.0.0.1:23456/v1?token=secret",
		"http://127.0.0.1:23456/v1#fragment",
		"http://127.0.0.1:23456/v1/",
		"http://127.0.0.1:1023/v1",
		"http://127.0.0.1:65536/v1",
		"http://127.0.0.1/v1",
	}
	for _, baseURL := range invalidURLs {
		t.Run(baseURL, func(t *testing.T) {
			dir := t.TempDir()
			target := filepath.Join(dir, "config.toml")
			state := filepath.Join(dir, "state.json")
			original := []byte("model = \"keep\"\n")
			if err := os.WriteFile(target, original, 0600); err != nil {
				t.Fatal(err)
			}
			_, err := Enable(EnableOptions{
				TargetPath:           target,
				CatalogPath:          filepath.Join(dir, "catalog.json"),
				StatePath:            state,
				ManagedOpenAIBaseURL: baseURL,
			})
			if err == nil || err.Error() != "invalid managed base URL" {
				t.Fatalf("Enable error = %v", err)
			}
			if strings.Contains(err.Error(), baseURL) {
				t.Fatalf("error leaked managed URL: %q", err)
			}
			got, readErr := os.ReadFile(target)
			if readErr != nil || string(got) != string(original) {
				t.Fatalf("target changed: %q, %v", got, readErr)
			}
			if _, statErr := os.Stat(state); !os.IsNotExist(statErr) {
				t.Fatalf("state should not exist, stat err = %v", statErr)
			}
		})
	}
}

func TestEnablePreservesDistinctQuotedProjectTables(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "config.toml")
	statePath := filepath.Join(dir, "relaykit-state.json")
	catalogPath := filepath.Join(dir, "catalog.json")
	original := []byte(`model = "keep"

[projects.'"/workspace/Iris"']
trust_level = "quoted-key"

[projects."/workspace/Iris"]
trust_level = "path-key"
`)
	if err := os.WriteFile(target, original, 0600); err != nil {
		t.Fatal(err)
	}

	if _, err := Enable(EnableOptions{TargetPath: target, CatalogPath: catalogPath, StatePath: statePath}); err != nil {
		t.Fatalf("Enable err = %v", err)
	}
	merged := loadTOML(t, target)
	if got := merged.GetPath([]string{"projects", `"/workspace/Iris"`, "trust_level"}); got != "quoted-key" {
		t.Fatalf("quoted project key changed: %#v", got)
	}
	if got := merged.GetPath([]string{"projects", "/workspace/Iris", "trust_level"}); got != "path-key" {
		t.Fatalf("path project key changed: %#v", got)
	}
	if status, err := IntegrationStatus(target, statePath); err != nil || status != StatusEnabled {
		t.Fatalf("status = %q, %v", status, err)
	}

	if _, err := Disable(target, statePath); err != nil {
		t.Fatalf("Disable err = %v", err)
	}
	restored, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	if string(restored) != string(original) {
		t.Fatalf("unrelated TOML formatting changed:\n%s", restored)
	}
}

func TestEnablePreservesUnrelatedMultilineStringWithTableLikeContent(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "config.toml")
	statePath := filepath.Join(dir, "relaykit-state.json")
	catalogPath := filepath.Join(dir, "catalog.json")
	original := []byte(`description = """
[this-is-text-not-a-table]
"""
model = "keep"
`)
	if err := os.WriteFile(target, original, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := Enable(EnableOptions{TargetPath: target, CatalogPath: catalogPath, StatePath: statePath}); err != nil {
		t.Fatalf("Enable err = %v", err)
	}
	if status, err := IntegrationStatus(target, statePath); err != nil || status != StatusEnabled {
		t.Fatalf("status = %q, %v", status, err)
	}
	if _, err := Disable(target, statePath); err != nil {
		t.Fatalf("Disable err = %v", err)
	}
	restored, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	if string(restored) != string(original) {
		t.Fatalf("unrelated multiline TOML changed:\n%s", restored)
	}
}

func TestEnableAcceptsPreexistingMultilineManagedStrings(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "config.toml")
	statePath := filepath.Join(dir, "relaykit-state.json")
	catalogPath := filepath.Join(dir, "catalog.json")
	originalBaseURL := "http://127.0.0.1:11434/v1"
	originalCatalog := filepath.Join(dir, "original-catalog.json")
	original := fmt.Sprintf("openai_base_url = \"\"\"\\\n%s\\\n\"\"\" # base note\nmodel_catalog_json = \"\"\"\\\n%s\\\n\"\"\"\nmodel = \"keep\"\n", originalBaseURL, originalCatalog)
	if err := os.WriteFile(target, []byte(original), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := Enable(EnableOptions{TargetPath: target, CatalogPath: catalogPath, StatePath: statePath}); err != nil {
		t.Fatalf("Enable err = %v", err)
	}
	if status, err := IntegrationStatus(target, statePath); err != nil || status != StatusEnabled {
		t.Fatalf("status = %q, %v", status, err)
	}
	if _, err := Disable(target, statePath); err != nil {
		t.Fatalf("Disable err = %v", err)
	}
	disabled := loadTOML(t, target)
	if disabled.Get("openai_base_url") != originalBaseURL || disabled.Get("model_catalog_json") != originalCatalog || disabled.Get("model") != "keep" {
		t.Fatalf("multiline managed values were not restored: %#v", disabled.ToMap())
	}
	body, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), "# base note") {
		t.Fatalf("managed-field comment was not preserved:\n%s", body)
	}
}

func TestRepeatedEnableRejectsDriftWithoutWrites(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "config.toml")
	statePath := filepath.Join(dir, "relaykit-state.json")
	firstCatalog := filepath.Join(dir, "catalog-1.json")
	secondCatalog := filepath.Join(dir, "catalog-2.json")
	if err := os.WriteFile(target, []byte("model = \"keep\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := Enable(EnableOptions{TargetPath: target, CatalogPath: firstCatalog, StatePath: statePath}); err != nil {
		t.Fatal(err)
	}
	tree := loadTOML(t, target)
	tree.Set("openai_base_url", "http://127.0.0.1:29999/v1")
	drifted, err := tree.ToTomlString()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte(drifted), 0600); err != nil {
		t.Fatal(err)
	}
	targetBefore, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	stateBefore, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Enable(EnableOptions{TargetPath: target, CatalogPath: secondCatalog, StatePath: statePath}); err == nil || !strings.Contains(err.Error(), "managed Codex settings changed") {
		t.Fatalf("repeated Enable drift error = %v", err)
	}
	targetAfter, _ := os.ReadFile(target)
	stateAfter, _ := os.ReadFile(statePath)
	if string(targetAfter) != string(targetBefore) || string(stateAfter) != string(stateBefore) {
		t.Fatal("rejected repeated Enable changed target or state")
	}
}

func TestDisablePreservesCommentOnRemovedManagedField(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "config.toml")
	statePath := filepath.Join(dir, "relaykit-state.json")
	catalogPath := filepath.Join(dir, "catalog.json")
	if err := os.WriteFile(target, []byte("model = \"keep\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := Enable(EnableOptions{TargetPath: target, CatalogPath: catalogPath, StatePath: statePath}); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	withComment := strings.Replace(string(body), "model_catalog_json = "+fmt.Sprintf("%q", catalogPath), "model_catalog_json = "+fmt.Sprintf("%q", catalogPath)+" # keep this note", 1)
	if err := os.WriteFile(target, []byte(withComment), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := Disable(target, statePath); err != nil {
		t.Fatal(err)
	}
	disabled, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(disabled), "# keep this note") || strings.Contains(string(disabled), "model_catalog_json") {
		t.Fatalf("managed-field comment was not preserved:\n%s", disabled)
	}
}

func TestEnableRejectsRelativeCatalogAndInvalidTOMLWithoutWrites(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "config.toml")
	statePath := filepath.Join(dir, "state.json")
	original := []byte("model = [\n")
	if err := os.WriteFile(target, original, 0600); err != nil {
		t.Fatal(err)
	}

	_, err := Enable(EnableOptions{TargetPath: target, CatalogPath: "catalog.json", StatePath: statePath})
	if err == nil || !strings.Contains(err.Error(), "catalog path must be absolute") {
		t.Fatalf("relative catalog error = %v", err)
	}
	_, err = Enable(EnableOptions{TargetPath: target, CatalogPath: filepath.Join(dir, "catalog.json"), StatePath: statePath})
	if err == nil || err.Error() != "invalid target TOML" {
		t.Fatalf("invalid TOML error = %v", err)
	}
	body, readErr := os.ReadFile(target)
	if readErr != nil || string(body) != string(original) {
		t.Fatalf("target changed after failed enable: %q, %v", body, readErr)
	}
	if _, err := os.Stat(statePath); !os.IsNotExist(err) {
		t.Fatalf("state should not exist, stat err = %v", err)
	}
}

func TestEnableCreatesMissingTargetWithoutClaimingBackup(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "missing-config.toml")
	statePath := filepath.Join(dir, "state.json")
	result, err := Enable(EnableOptions{TargetPath: target, CatalogPath: filepath.Join(dir, "catalog.json"), StatePath: statePath})
	if err != nil {
		t.Fatalf("Enable error = %v", err)
	}
	if result.BackupPath != "" {
		t.Fatalf("new target must not claim backup %q", result.BackupPath)
	}
	if status, err := IntegrationStatus(target, statePath); err != nil || status != StatusEnabled {
		t.Fatalf("status = %q, %v", status, err)
	}
}

func TestEnableLeavesTargetUnchangedIfStateDirectoryCannotBeCreated(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "config.toml")
	original := []byte("model = \"keep\"\n")
	if err := os.WriteFile(target, original, 0644); err != nil {
		t.Fatal(err)
	}
	blocker := filepath.Join(dir, "not-a-directory")
	if err := os.WriteFile(blocker, []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}

	_, err := Enable(EnableOptions{
		TargetPath:  target,
		CatalogPath: filepath.Join(dir, "catalog.json"),
		StatePath:   filepath.Join(blocker, "state.json"),
	})
	if err == nil {
		t.Fatalf("Enable error = %v", err)
	}
	body, readErr := os.ReadFile(target)
	if readErr != nil || string(body) != string(original) {
		t.Fatalf("target was not restored: %q, %v", body, readErr)
	}
	assertMode(t, target, 0644)
}

func TestIntegrationStatusDistinguishesEnabledDriftedAndDisabled(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "config.toml")
	statePath := filepath.Join(dir, "state.json")
	catalogPath := filepath.Join(dir, "catalog.json")
	if status, err := IntegrationStatus(target, statePath); err != nil || status != StatusDisabled {
		t.Fatalf("initial status = %q, %v", status, err)
	}
	if err := os.WriteFile(target, []byte("model = \"keep\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := Enable(EnableOptions{TargetPath: target, CatalogPath: catalogPath, StatePath: statePath}); err != nil {
		t.Fatal(err)
	}
	if status, err := IntegrationStatus(target, statePath); err != nil || status != StatusEnabled {
		t.Fatalf("enabled status = %q, %v", status, err)
	}
	tree := loadTOML(t, target)
	tree.Set("openai_base_url", "http://127.0.0.1:19999/v1")
	changed, err := tree.ToTomlString()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte(changed), 0600); err != nil {
		t.Fatal(err)
	}
	if status, err := IntegrationStatus(target, statePath); err != nil || status != StatusDrifted {
		t.Fatalf("drifted status = %q, %v", status, err)
	}
}

func TestRecoveryDecision(t *testing.T) {
	t.Run("disabled shuts down", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "config.toml")
		decision, err := RecoveryDecisionForParentLoss(path, filepath.Join(t.TempDir(), "state.json"))
		if err != nil || decision != RecoveryShutdown {
			t.Fatalf("decision=%q err=%v", decision, err)
		}
	})

	t.Run("partial catalog drift removes the still-managed base URL", func(t *testing.T) {
		dir := t.TempDir()
		target := filepath.Join(dir, "config.toml")
		state := filepath.Join(dir, "state.json")
		if err := os.WriteFile(target, []byte("model = \"keep\"\n"), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := Enable(EnableOptions{TargetPath: target, CatalogPath: filepath.Join(dir, "catalog.json"), StatePath: state}); err != nil {
			t.Fatal(err)
		}
		later := []byte("model = \"keep\"\nopenai_base_url = \"http://127.0.0.1:19777/v1\"\nmodel_catalog_json = \"/later/catalog.json\"\n")
		if err := os.WriteFile(target, later, 0600); err != nil {
			t.Fatal(err)
		}

		decision, err := RecoveryDecisionForParentLoss(target, state)
		if err != nil || decision != RecoveryShutdown {
			t.Fatalf("decision=%q err=%v", decision, err)
		}
		disabled := loadTOML(t, target)
		if got := disabled.Get("openai_base_url"); got != nil {
			t.Fatalf("managed base URL remains after recovery: %#v", got)
		}
		if got := disabled.Get("model_catalog_json"); got != "/later/catalog.json" {
			t.Fatalf("later catalog changed: %#v", got)
		}
		if _, err := os.Stat(state); !os.IsNotExist(err) {
			t.Fatalf("state should be removed, stat err = %v", err)
		}
	})

	t.Run("enabled restores original values before shutdown", func(t *testing.T) {
		dir := t.TempDir()
		target := filepath.Join(dir, "config.toml")
		state := filepath.Join(dir, "state.json")
		original := []byte("model = \"keep\"\nopenai_base_url = \"http://127.0.0.1:11434/v1\"\n")
		if err := os.WriteFile(target, original, 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := Enable(EnableOptions{TargetPath: target, CatalogPath: filepath.Join(dir, "catalog.json"), StatePath: state}); err != nil {
			t.Fatal(err)
		}

		decision, err := RecoveryDecisionForParentLoss(target, state)
		if err != nil || decision != RecoveryShutdown {
			t.Fatalf("decision=%q err=%v", decision, err)
		}
		got, err := os.ReadFile(target)
		if err != nil || string(got) != string(original) {
			t.Fatalf("original values not restored: %q, %v", got, err)
		}
	})

	t.Run("partial drift restore failure retains listener", func(t *testing.T) {
		dir := t.TempDir()
		target := filepath.Join(dir, "config.toml")
		state := filepath.Join(dir, "state.json")
		if err := os.WriteFile(target, []byte("model = \"keep\"\n"), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := Enable(EnableOptions{TargetPath: target, CatalogPath: filepath.Join(dir, "catalog.json"), StatePath: state}); err != nil {
			t.Fatal(err)
		}
		partial := loadTOML(t, target)
		partial.Set("model_catalog_json", "/later/catalog.json")
		body, err := partial.ToTomlString()
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(target, []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(dir, 0500); err != nil {
			t.Fatal(err)
		}
		defer os.Chmod(dir, 0700)

		decision, err := RecoveryDecisionForParentLoss(target, state)
		if err == nil || decision != RecoveryRetainListener {
			t.Fatalf("decision=%q err=%v", decision, err)
		}
		if status, statusErr := IntegrationStatus(target, state); statusErr != nil || status != StatusDrifted {
			t.Fatalf("status=%q err=%v", status, statusErr)
		}
	})
}

func TestEnableRefusesAuthJSONPathsWithoutReadingOrWritingThem(t *testing.T) {
	dir := t.TempDir()
	authPath := filepath.Join(dir, "auth.json")
	original := []byte(`{"token":"RELAYKIT_FAKE_SENTINEL_DO_NOT_USE"}`)
	if err := os.WriteFile(authPath, original, 0600); err != nil {
		t.Fatal(err)
	}
	_, err := Enable(EnableOptions{
		TargetPath:  authPath,
		CatalogPath: filepath.Join(dir, "catalog.json"),
		StatePath:   filepath.Join(dir, "state.json"),
	})
	if err == nil || err.Error() != "auth.json paths are not allowed" {
		t.Fatalf("Enable error = %v", err)
	}
	body, readErr := os.ReadFile(authPath)
	if readErr != nil || string(body) != string(original) {
		t.Fatalf("auth.json was changed: %q, %v", body, readErr)
	}
}

func TestManagedConfigCommandsRejectSymlinksWithoutReadingAuthTarget(t *testing.T) {
	dir := t.TempDir()
	authPath := filepath.Join(dir, "auth.json")
	targetLink := filepath.Join(dir, "config.toml")
	stateLink := filepath.Join(dir, "state.json")
	catalog := filepath.Join(dir, "catalog.json")
	secret := []byte("fixture-auth-must-remain-unread-and-unchanged")
	if err := os.WriteFile(authPath, secret, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(authPath, targetLink); err != nil {
		t.Fatal(err)
	}
	if _, err := Enable(EnableOptions{TargetPath: targetLink, CatalogPath: catalog, StatePath: filepath.Join(dir, "managed.json")}); err == nil || !strings.Contains(err.Error(), "must not be a symbolic link") {
		t.Fatalf("Enable symlink error = %v", err)
	}
	if err := os.Symlink(authPath, stateLink); err != nil {
		t.Fatal(err)
	}
	if _, err := IntegrationStatus(filepath.Join(dir, "missing-config.toml"), stateLink); err == nil || !strings.Contains(err.Error(), "must not be a symbolic link") {
		t.Fatalf("IntegrationStatus symlink error = %v", err)
	}
	body, err := os.ReadFile(authPath)
	if err != nil || string(body) != string(secret) {
		t.Fatalf("auth target changed: %q, %v", body, err)
	}
}

func TestDisableRemovesOnlyUnchangedManagedValues(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "config.toml")
	statePath := filepath.Join(dir, "state.json")
	catalogPath := filepath.Join(dir, "catalog.json")
	if err := os.WriteFile(target, []byte("model = \"keep\"\nmodel_provider = \"official\"\n[table]\narray = [1, 2]\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := Enable(EnableOptions{TargetPath: target, CatalogPath: catalogPath, StatePath: statePath}); err != nil {
		t.Fatal(err)
	}
	changed := loadTOML(t, target)
	changed.Set("openai_base_url", "http://127.0.0.1:29999/v1")
	body, err := changed.ToTomlString()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}

	result, err := Disable(target, statePath)
	if err != nil {
		t.Fatalf("Disable err = %v", err)
	}
	if strings.Join(result.Removed, ",") != "model_catalog_json" || strings.Join(result.Preserved, ",") != "openai_base_url" {
		t.Fatalf("result = %+v", result)
	}
	disabled := loadTOML(t, target)
	if got := disabled.Get("openai_base_url"); got != "http://127.0.0.1:29999/v1" {
		t.Fatalf("later user change was removed: %#v", got)
	}
	if got := disabled.Get("model_catalog_json"); got != nil {
		t.Fatalf("managed catalog was not removed: %#v", got)
	}
	if disabled.Get("model") != "keep" || disabled.Get("model_provider") != "official" || disabled.Get("table.array") == nil {
		t.Fatalf("unrelated config changed: %#v", disabled.ToMap())
	}
	if _, err := os.Stat(statePath); !os.IsNotExist(err) {
		t.Fatalf("state should be removed, stat err = %v", err)
	}
}

func TestDisableRestoresPreexistingManagedFieldsAfterRepeatedEnable(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "config.toml")
	statePath := filepath.Join(dir, "state.json")
	firstCatalog := filepath.Join(dir, "catalog-1.json")
	secondCatalog := filepath.Join(dir, "catalog-2.json")
	originalBaseURL := "http://127.0.0.1:11434/v1"
	originalCatalog := filepath.Join(dir, "original-catalog.json")
	original := fmt.Sprintf("model = \"keep\"\nopenai_base_url = %q\nmodel_catalog_json = %q\n", originalBaseURL, originalCatalog)
	if err := os.WriteFile(target, []byte(original), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := Enable(EnableOptions{TargetPath: target, CatalogPath: firstCatalog, StatePath: statePath}); err != nil {
		t.Fatal(err)
	}
	if _, err := Enable(EnableOptions{TargetPath: target, CatalogPath: secondCatalog, StatePath: statePath}); err != nil {
		t.Fatal(err)
	}

	result, err := Disable(target, statePath)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(result.Restored, ",") != "openai_base_url,model_catalog_json" || len(result.Removed) != 0 || len(result.Preserved) != 0 {
		t.Fatalf("result = %+v", result)
	}
	disabled := loadTOML(t, target)
	if disabled.Get("openai_base_url") != originalBaseURL || disabled.Get("model_catalog_json") != originalCatalog || disabled.Get("model") != "keep" {
		t.Fatalf("preexisting values were not restored: %#v", disabled.ToMap())
	}
}

func TestDisableRejectsMismatchedOrInvalidStateWithoutChangingTarget(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "config.toml")
	statePath := filepath.Join(dir, "state.json")
	original := []byte("model = \"keep\"\n")
	if err := os.WriteFile(target, original, 0600); err != nil {
		t.Fatal(err)
	}
	state := managedState{Version: stateVersion, Target: filepath.Join(dir, "other.toml"), Backup: filepath.Join(dir, "config.toml.bak.20260721T000000.000000000Z"), Managed: managedValues{OpenAIBaseURL: managedOpenAIBaseURL, ModelCatalogJSON: filepath.Join(dir, "catalog.json")}}
	body, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(statePath, body, 0600); err != nil {
		t.Fatal(err)
	}

	_, err = Disable(target, statePath)
	if err == nil || !strings.Contains(err.Error(), "does not match") {
		t.Fatalf("Disable error = %v", err)
	}
	got, err := os.ReadFile(target)
	if err != nil || string(got) != string(original) {
		t.Fatalf("target changed: %q, %v", got, err)
	}
}

func loadTOML(t *testing.T, path string) *toml.Tree {
	t.Helper()
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	tree, err := toml.LoadBytes(body)
	if err != nil {
		t.Fatalf("load TOML: %v\n%s", err, body)
	}
	return tree
}

func assertMode(t *testing.T, path string, want os.FileMode) {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != want {
		t.Fatalf("%s mode = %04o, want %04o", path, got, want)
	}
}

func randomLoopbackBaseURL(t *testing.T) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	return "http://127.0.0.1:" + strconv.Itoa(port) + "/v1"
}
