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
	var p ProviderProfile
	for _, provider := range cfg.Providers {
		if provider.ID == "local-openai-compatible" {
			p = provider
			break
		}
	}
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

func TestValidationAcceptsAnthropicMessagesFormat(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "c.json")
	if err := os.WriteFile(p, []byte(`{"providers":[{"id":"p","name":"n","base_url":"http://x","api_format":"anthropic_messages","models":[{"id":"claude-example"}]}]}`), 0600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load(p)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if cfg.Providers[0].APIFormat != APIFormatAnthropicMessages {
		t.Fatalf("api_format = %q", cfg.Providers[0].APIFormat)
	}
}

func TestValidationAcceptsPublicCredentialRefAndMetadata(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "c.json")
	body := `{"providers":[{"id":"p","name":"n","base_url":"https://example.test/v1","api_format":"openai_chat","credential_ref":{"kind":"env","value":"RELAYKIT_PROVIDER_TOKEN"},"capabilities":{"streaming":true,"tools":false,"usage":true,"reasoning":false},"routing":{"source":"custom","model_prefix":"custom/","priority":100,"status":"enabled","visible":true},"models":[{"id":"m","upstream_model":"upstream-m"}]}]}`
	if err := os.WriteFile(p, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load(p)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if cfg.Providers[0].CredentialRef == nil || cfg.Providers[0].CredentialRef.Kind != CredentialKindEnv || cfg.Providers[0].CredentialRef.Value != "RELAYKIT_PROVIDER_TOKEN" {
		t.Fatalf("credential_ref = %+v", cfg.Providers[0].CredentialRef)
	}
	if !cfg.Providers[0].Capabilities.Streaming || !cfg.Providers[0].Capabilities.Usage {
		t.Fatalf("capabilities = %+v", cfg.Providers[0].Capabilities)
	}
	if cfg.Providers[0].Routing.Source != "custom" || cfg.Providers[0].Routing.Status != RoutingStatusEnabled {
		t.Fatalf("routing = %+v", cfg.Providers[0].Routing)
	}
	if cfg.Providers[0].Models[0].UpstreamModel != "upstream-m" {
		t.Fatalf("upstream_model = %q", cfg.Providers[0].Models[0].UpstreamModel)
	}
}

func TestValidationRejectsUnsafeCredentialRefAndMetadata(t *testing.T) {
	cases := map[string]struct {
		body string
		code string
	}{
		"unsupported credential kind": {`{"providers":[{"id":"p","name":"n","base_url":"https://example.test/v1","api_format":"openai_chat","credential_ref":{"kind":"api_key","value":"RELAYKIT_PROVIDER_TOKEN"},"models":[{"id":"m"}]}]}`, CodeValidationError},
		"secret looking env ref":      {`{"providers":[{"id":"p","name":"n","base_url":"https://example.test/v1","api_format":"openai_chat","credential_ref":{"kind":"env","value":"sk-secret-value"},"models":[{"id":"m"}]}]}`, CodeValidationError},
		"relative key file":           {`{"providers":[{"id":"p","name":"n","base_url":"https://example.test/v1","api_format":"openai_chat","credential_ref":{"kind":"key_file","value":"relative.key"},"models":[{"id":"m"}]}]}`, CodeValidationError},
		"capability non bool":         {`{"providers":[{"id":"p","name":"n","base_url":"https://example.test/v1","api_format":"openai_chat","capabilities":{"streaming":"yes"},"models":[{"id":"m"}]}]}`, CodeParseError},
		"unknown capability":          {`{"providers":[{"id":"p","name":"n","base_url":"https://example.test/v1","api_format":"openai_chat","capabilities":{"batch":true},"models":[{"id":"m"}]}]}`, CodeValidationError},
		"unsafe source":               {`{"providers":[{"id":"p","name":"n","base_url":"https://example.test/v1","api_format":"openai_chat","routing":{"source":"Private Source"},"models":[{"id":"m"}]}]}`, CodeValidationError},
		"unsupported status":          {`{"providers":[{"id":"p","name":"n","base_url":"https://example.test/v1","api_format":"openai_chat","routing":{"status":"pretend"},"models":[{"id":"m"}]}]}`, CodeValidationError},
		"credential key":              {`{"providers":[{"id":"p","name":"n","base_url":"https://example.test/v1","api_format":"openai_chat","api_key":"abc","models":[{"id":"m"}]}]}`, CodeValidationError},
		"credential marker value":     {`{"providers":[{"id":"p","name":"n","base_url":"https://example.test/v1","api_format":"openai_chat","models":[{"id":"m","display_name":"api_key=abc"}]}]}`, CodeValidationError},
		"unicode env name":            {`{"providers":[{"id":"p","name":"n","base_url":"https://example.test/v1","api_format":"openai_chat","credential_ref":{"kind":"env","value":"TOKEN_é"},"models":[{"id":"m"}]}]}`, CodeValidationError},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			p := filepath.Join(dir, "c.json")
			if err := os.WriteFile(p, []byte(tc.body), 0600); err != nil {
				t.Fatal(err)
			}
			_, err := Load(p)
			if err == nil {
				t.Fatal("expected validation error")
			}
			if ec := err.(*Error); ec.Code != tc.code {
				t.Fatalf("code = %q, want %q", ec.Code, tc.code)
			}
		})
	}
}
