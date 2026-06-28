package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadExampleConfig(t *testing.T) {
	path := filepath.Join("..", "..", "..", "examples", "providers.example.json")
	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load err = %v", err)
	}
	if len(cfg.Providers) != 1 {
		t.Fatalf("providers = %d, want 1", len(cfg.Providers))
	}
	p := cfg.Providers[0]
	if p.ID != "local-openai-compatible" {
		t.Fatalf("id = %q", p.ID)
	}
	if p.Name != "Local OpenAI Compatible" {
		t.Fatalf("name = %q", p.Name)
	}
	if p.BaseURL != "http://127.0.0.1:11434/v1" {
		t.Fatalf("base_url = %q", p.BaseURL)
	}
	if p.APIFormat != "openai_chat" {
		t.Fatalf("api_format = %q", p.APIFormat)
	}
	if p.AuthEnv != "RELAYKIT_EXAMPLE_API_KEY" {
		t.Fatalf("auth_env = %q", p.AuthEnv)
	}
	if strings.Contains(p.AuthEnv, "sk-") || len(p.AuthEnv) > 128 {
		t.Fatalf("auth_env looks like a secret: %q", p.AuthEnv)
	}
	if len(p.Models) != 1 {
		t.Fatalf("models = %d, want 1", len(p.Models))
	}
	m := p.Models[0]
	if m.ID != "qwen3-coder" {
		t.Fatalf("model id = %q", m.ID)
	}
	if m.DisplayName != "Qwen3 Coder" {
		t.Fatalf("display_name = %q", m.DisplayName)
	}
	if m.ContextWindow != 128000 {
		t.Fatalf("context_window = %d", m.ContextWindow)
	}
}

func TestLoadMissingFile(t *testing.T) {
	_, err := Load("missing.json")
	if err == nil {
		t.Fatal("expected error for missing file")
	}
	ec, ok := err.(*Error)
	if !ok {
		t.Fatalf("err type = %T, want *config.Error", err)
	}
	if ec.Code != CodeReadError {
		t.Fatalf("code = %q, want %q", ec.Code, CodeReadError)
	}
}

func TestLoadInvalidJSON(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "bad.json")
	if err := os.WriteFile(p, []byte("{not json"), 0600); err != nil {
		t.Fatal(err)
	}
	_, err := Load(p)
	if err == nil {
		t.Fatal("expected parse error")
	}
	ec := err.(*Error)
	if ec.Code != CodeParseError {
		t.Fatalf("code = %q, want %q", ec.Code, CodeParseError)
	}
}

func TestValidationRejectsEmptyProviders(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "c.json")
	if err := os.WriteFile(p, []byte(`{"providers":[]}`), 0600); err != nil {
		t.Fatal(err)
	}
	_, err := Load(p)
	if err == nil {
		t.Fatal("expected validation error")
	}
	if ec := err.(*Error); ec.Code != CodeValidationError {
		t.Fatalf("code = %q, want %q", ec.Code, CodeValidationError)
	}
}

func TestValidationRejectsMissingProviderFields(t *testing.T) {
	cases := map[string]string{
		"missing id":         `{"providers":[{"name":"n","base_url":"http://x","api_format":"openai_chat","models":[{"id":"m"}]}]}`,
		"missing base_url":   `{"providers":[{"id":"p","name":"n","api_format":"openai_chat","models":[{"id":"m"}]}]}`,
		"missing api_format": `{"providers":[{"id":"p","name":"n","base_url":"http://x","models":[{"id":"m"}]}]}`,
		"empty models":       `{"providers":[{"id":"p","name":"n","base_url":"http://x","api_format":"openai_chat","models":[]}]}`,
		"missing model id":   `{"providers":[{"id":"p","name":"n","base_url":"http://x","api_format":"openai_chat","models":[{"display_name":"M"}]}]}`,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			p := filepath.Join(dir, "c.json")
			if err := os.WriteFile(p, []byte(body), 0600); err != nil {
				t.Fatal(err)
			}
			_, err := Load(p)
			if err == nil {
				t.Fatal("expected validation error")
			}
			if ec := err.(*Error); ec.Code != CodeValidationError {
				t.Fatalf("code = %q, want %q", ec.Code, CodeValidationError)
			}
		})
	}
}

func TestValidationRejectsUnsupportedFormat(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "c.json")
	if err := os.WriteFile(p, []byte(`{"providers":[{"id":"p","name":"n","base_url":"http://x","api_format":"anthropic","models":[{"id":"m"}]}]}`), 0600); err != nil {
		t.Fatal(err)
	}
	_, err := Load(p)
	if err == nil {
		t.Fatal("expected unsupported format error")
	}
	if ec := err.(*Error); ec.Code != CodeUnsupportedFormat {
		t.Fatalf("code = %q, want %q", ec.Code, CodeUnsupportedFormat)
	}
}

func TestAuthEnvOptional(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "c.json")
	if err := os.WriteFile(p, []byte(`{"providers":[{"id":"p","name":"n","base_url":"http://x","api_format":"openai_chat","models":[{"id":"m"}]}]}`), 0600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load(p)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if cfg.Providers[0].AuthEnv != "" {
		t.Fatalf("auth_env = %q, want empty", cfg.Providers[0].AuthEnv)
	}
}
