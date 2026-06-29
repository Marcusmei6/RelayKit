package main

import (
	"bytes"
	"encoding/json"
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
