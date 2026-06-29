package codexconfig

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
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
