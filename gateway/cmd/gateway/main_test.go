package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
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
