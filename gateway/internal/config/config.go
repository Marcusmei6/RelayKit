package config

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"strings"
	"unicode"
)

const (
	CodeReadError              = "config_read_error"
	CodeParseError             = "config_parse_error"
	CodeValidationError        = "config_validation_error"
	CodeUnsupportedFormat      = "unsupported_provider_format"
	APIFormatOpenAIChat        = "openai_chat"
	APIFormatOpenAIResponses   = "openai_responses"
	APIFormatAnthropicMessages = "anthropic_messages"
	CredentialKindEnv          = "env"
	CredentialKindKeychain     = "keychain"
	CredentialKindKeyFile      = "key_file"
	CredentialKindCodexHome    = "codex_home"
	RoutingStatusEnabled       = "enabled"
	RoutingStatusDisabled      = "disabled"
)

type Error struct {
	Code string
	Err  error
}

func (e *Error) Error() string {
	if e.Err == nil {
		return e.Code
	}
	return e.Code + ": " + e.Err.Error()
}

func (e *Error) Unwrap() error {
	return e.Err
}

type Config struct {
	OfficialPassthrough *OfficialPassthrough `json:"official_passthrough,omitempty"`
	Providers           []ProviderProfile    `json:"providers"`
}

type OfficialPassthrough struct {
	BaseURL       string         `json:"base_url"`
	CredentialRef *CredentialRef `json:"credential_ref,omitempty"`
	CodexBinary   string         `json:"codex_binary,omitempty"`
	Models        []Model        `json:"models"`
}

type ProviderProfile struct {
	ID            string         `json:"id"`
	Name          string         `json:"name"`
	BaseURL       string         `json:"base_url"`
	APIFormat     string         `json:"api_format"`
	AuthEnv       string         `json:"auth_env,omitempty"`
	CredentialRef *CredentialRef `json:"credential_ref,omitempty"`
	Capabilities  Capabilities   `json:"capabilities,omitempty"`
	Routing       Routing        `json:"routing,omitempty"`
	Catalog       Catalog        `json:"catalog,omitempty"`
	Models        []Model        `json:"models"`
}

type CredentialRef struct {
	Kind   string `json:"kind"`
	Value  string `json:"value"`
	Header string `json:"header,omitempty"`
}

type Capabilities struct {
	Streaming bool `json:"streaming,omitempty"`
	Tools     bool `json:"tools,omitempty"`
	Usage     bool `json:"usage,omitempty"`
	Reasoning bool `json:"reasoning,omitempty"`
}

type Routing struct {
	Source      string `json:"source,omitempty"`
	ModelPrefix string `json:"model_prefix,omitempty"`
	Priority    int    `json:"priority,omitempty"`
	Status      string `json:"status,omitempty"`
	Visible     bool   `json:"visible,omitempty"`
}

type Catalog struct {
	ModelsURL string `json:"models_url,omitempty"`
	KeyHeader string `json:"key_header,omitempty"`
}

type Model struct {
	ID            string `json:"id"`
	DisplayName   string `json:"display_name,omitempty"`
	UpstreamModel string `json:"upstream_model,omitempty"`
	ContextWindow int    `json:"context_window,omitempty"`
}

func Load(path string) (*Config, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, &Error{Code: CodeReadError, Err: err}
	}

	var cfg Config
	var publicBoundary any
	if err := json.Unmarshal(body, &publicBoundary); err != nil {
		return nil, &Error{Code: CodeParseError, Err: err}
	}
	if err := rejectCredentialContent(publicBoundary); err != nil {
		return nil, &Error{Code: CodeValidationError, Err: err}
	}
	if err := validateRawMetadata(publicBoundary); err != nil {
		return nil, &Error{Code: CodeValidationError, Err: err}
	}
	if err := json.Unmarshal(body, &cfg); err != nil {
		return nil, &Error{Code: CodeParseError, Err: err}
	}
	normalizeProviderModels(&cfg)
	if err := validate(cfg); err != nil {
		return nil, err
	}
	return &cfg, nil
}

func normalizeProviderModels(cfg *Config) {
	for pi := range cfg.Providers {
		prefix := strings.TrimSpace(cfg.Providers[pi].Routing.ModelPrefix)
		if prefix == "" {
			continue
		}
		for mi := range cfg.Providers[pi].Models {
			model := &cfg.Providers[pi].Models[mi]
			id := strings.TrimSpace(model.ID)
			upstream := strings.TrimSpace(model.UpstreamModel)
			if strings.HasPrefix(id, prefix) {
				model.ID = id
				model.UpstreamModel = upstream
				continue
			}
			if upstream == "" {
				upstream = id
			}
			model.ID = prefix + safeModelSlug(id)
			model.UpstreamModel = upstream
		}
	}
}

func safeModelSlug(value string) string {
	lower := strings.ToLower(strings.TrimSpace(value))
	var b strings.Builder
	lastDash := false
	for i := 0; i < len(lower); i++ {
		c := lower[i]
		if (c >= 'a' && c <= 'z') || isASCIIDigit(c) {
			b.WriteByte(c)
			lastDash = false
			continue
		}
		if !lastDash {
			b.WriteByte('-')
			lastDash = true
		}
	}
	slug := strings.Trim(b.String(), "-")
	if slug == "" {
		return "model"
	}
	if slug[0] < 'a' || slug[0] > 'z' {
		return "model-" + slug
	}
	return slug
}

func validate(cfg Config) error {
	if len(cfg.Providers) == 0 && cfg.OfficialPassthrough == nil {
		return &Error{Code: CodeValidationError, Err: fmt.Errorf("providers required")}
	}
	if cfg.OfficialPassthrough != nil {
		if cfg.OfficialPassthrough.BaseURL == "" || len(cfg.OfficialPassthrough.Models) == 0 {
			return &Error{Code: CodeValidationError, Err: fmt.Errorf("invalid official_passthrough")}
		}
		if err := validateBaseURL(cfg.OfficialPassthrough.BaseURL); err != nil {
			return &Error{Code: CodeValidationError, Err: fmt.Errorf("invalid official_passthrough base_url: %w", err)}
		}
		if cfg.OfficialPassthrough.CredentialRef != nil {
			if err := validateOfficialCredentialRef(*cfg.OfficialPassthrough.CredentialRef); err != nil {
				return &Error{Code: CodeValidationError, Err: fmt.Errorf("invalid official_passthrough credential_ref: %w", err)}
			}
		}
		if cfg.OfficialPassthrough.CodexBinary != "" && strings.ContainsAny(cfg.OfficialPassthrough.CodexBinary, "\n\r") {
			return &Error{Code: CodeValidationError, Err: fmt.Errorf("invalid official_passthrough codex_binary")}
		}
		for _, m := range cfg.OfficialPassthrough.Models {
			if m.ID == "" {
				return &Error{Code: CodeValidationError, Err: fmt.Errorf("model id required for official_passthrough")}
			}
		}
	}
	for _, p := range cfg.Providers {
		if p.ID == "" || p.Name == "" || p.BaseURL == "" || p.APIFormat == "" || len(p.Models) == 0 {
			return &Error{Code: CodeValidationError, Err: fmt.Errorf("invalid provider %q", p.ID)}
		}
		if p.APIFormat != APIFormatOpenAIChat && p.APIFormat != APIFormatOpenAIResponses && p.APIFormat != APIFormatAnthropicMessages {
			return &Error{Code: CodeUnsupportedFormat, Err: fmt.Errorf("unsupported api_format %q", p.APIFormat)}
		}
		if err := validateBaseURL(p.BaseURL); err != nil {
			return &Error{Code: CodeValidationError, Err: fmt.Errorf("invalid base_url for provider %q: %w", p.ID, err)}
		}
		if p.AuthEnv != "" && !isEnvName(p.AuthEnv) {
			return &Error{Code: CodeValidationError, Err: fmt.Errorf("auth_env must be an environment variable name for provider %q", p.ID)}
		}
		if p.CredentialRef != nil {
			if err := validateCredentialRef(*p.CredentialRef); err != nil {
				return &Error{Code: CodeValidationError, Err: fmt.Errorf("invalid credential_ref for provider %q: %w", p.ID, err)}
			}
		}
		if err := validateRouting(p.Routing); err != nil {
			return &Error{Code: CodeValidationError, Err: fmt.Errorf("invalid routing for provider %q: %w", p.ID, err)}
		}
		if err := validateCatalog(p.Catalog); err != nil {
			return &Error{Code: CodeValidationError, Err: fmt.Errorf("invalid catalog for provider %q: %w", p.ID, err)}
		}
		for _, m := range p.Models {
			if m.ID == "" {
				return &Error{Code: CodeValidationError, Err: fmt.Errorf("model id required for provider %q", p.ID)}
			}
			if containsCredentialMarker(m.UpstreamModel) {
				return &Error{Code: CodeValidationError, Err: fmt.Errorf("upstream_model must not contain credential-looking values for provider %q", p.ID)}
			}
		}
	}
	return nil
}

func validateCatalog(c Catalog) error {
	if c.ModelsURL != "" {
		u, err := url.Parse(c.ModelsURL)
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") {
			return fmt.Errorf("models_url must be an http(s) URL")
		}
		if err := validateBaseURL(c.ModelsURL); err != nil {
			return fmt.Errorf("models_url: %w", err)
		}
	}
	if c.KeyHeader != "" && !isSafeReferenceName(c.KeyHeader) {
		return fmt.Errorf("key_header must be a safe header reference")
	}
	return nil
}

func validateBaseURL(raw string) error {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme == "" || u.Host == "" {
		return fmt.Errorf("must be an absolute URL")
	}
	if u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return fmt.Errorf("must not contain credentials, query, or fragment")
	}
	return nil
}

func validateCredentialRef(ref CredentialRef) error {
	if containsCredentialMarker(ref.Value) {
		return fmt.Errorf("must not contain credential-looking values")
	}
	if ref.Header != "" && !isSafeHeaderName(ref.Header) {
		return fmt.Errorf("header must be a safe HTTP header name")
	}
	switch ref.Kind {
	case CredentialKindEnv:
		if !isEnvName(ref.Value) {
			return fmt.Errorf("env value must be an environment variable name")
		}
	case CredentialKindKeychain:
		if !isSafeReferenceName(ref.Value) {
			return fmt.Errorf("keychain value must be a local item reference")
		}
	case CredentialKindKeyFile:
		if !strings.HasPrefix(ref.Value, "~/") && !strings.HasPrefix(ref.Value, "/") {
			return fmt.Errorf("key_file value must be an absolute or home-relative path")
		}
		if strings.ContainsAny(ref.Value, "\n\r") {
			return fmt.Errorf("key_file value must be a single path")
		}
	default:
		return fmt.Errorf("unsupported kind %q", ref.Kind)
	}
	return nil
}

func validateOfficialCredentialRef(ref CredentialRef) error {
	if ref.Kind == CredentialKindCodexHome {
		if !strings.HasPrefix(ref.Value, "~/") && !strings.HasPrefix(ref.Value, "/") {
			return fmt.Errorf("codex_home value must be an absolute or home-relative path")
		}
		if strings.ContainsAny(ref.Value, "\n\r") {
			return fmt.Errorf("codex_home value must be a single path")
		}
		if ref.Header != "" {
			return fmt.Errorf("codex_home must not set a header")
		}
		return nil
	}
	return validateCredentialRef(ref)
}

func validateRouting(r Routing) error {
	if r.Source != "" && !isSafeSlug(r.Source) {
		return fmt.Errorf("source must be a public-safe slug")
	}
	if r.ModelPrefix != "" {
		prefix := strings.TrimSuffix(r.ModelPrefix, "/")
		if !strings.HasSuffix(r.ModelPrefix, "/") || !isSafeSlug(prefix) {
			return fmt.Errorf("model_prefix must be a public-safe slug ending in /")
		}
	}
	if r.Priority < 0 {
		return fmt.Errorf("priority must be non-negative")
	}
	if r.Status != "" && r.Status != RoutingStatusEnabled && r.Status != RoutingStatusDisabled {
		return fmt.Errorf("unsupported status %q", r.Status)
	}
	return nil
}

func isEnvName(value string) bool {
	if value == "" {
		return false
	}
	for i := 0; i < len(value); i++ {
		c := value[i]
		if i == 0 && !(c == '_' || isASCIILetter(c)) {
			return false
		}
		if !(c == '_' || isASCIILetter(c) || isASCIIDigit(c)) {
			return false
		}
	}
	return true
}

func isSafeSlug(value string) bool {
	if value == "" {
		return false
	}
	for i := 0; i < len(value); i++ {
		c := value[i]
		if i == 0 && !(c >= 'a' && c <= 'z') {
			return false
		}
		if !((c >= 'a' && c <= 'z') || isASCIIDigit(c) || c == '-') {
			return false
		}
	}
	return true
}

func isSafeReferenceName(value string) bool {
	if value == "" || strings.ContainsAny(value, "\n\r") {
		return false
	}
	for _, r := range value {
		if !(unicode.IsLetter(r) || unicode.IsDigit(r) || strings.ContainsRune("._:@/-", r)) {
			return false
		}
	}
	return true
}

func isSafeHeaderName(value string) bool {
	if value == "" {
		return false
	}
	for i := 0; i < len(value); i++ {
		c := value[i]
		if !(c == '-' || isASCIILetter(c) || isASCIIDigit(c)) {
			return false
		}
	}
	return true
}

func isASCIILetter(c byte) bool {
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
}

func isASCIIDigit(c byte) bool {
	return c >= '0' && c <= '9'
}

func containsCredentialMarker(value string) bool {
	lower := strings.ToLower(value)
	for _, marker := range []string{"bearer ", "sk-", "api_key=", "token=", "access_token=", "refresh_token=", "password=", "secret=", "authorization="} {
		if strings.Contains(lower, marker) {
			return true
		}
	}
	return false
}

func rejectCredentialContent(value any) error {
	switch v := value.(type) {
	case map[string]any:
		for key, child := range v {
			if isForbiddenCredentialKey(key) {
				return fmt.Errorf("credential field is not allowed: %s", key)
			}
			if err := rejectCredentialContent(child); err != nil {
				return err
			}
		}
	case []any:
		for _, child := range v {
			if err := rejectCredentialContent(child); err != nil {
				return err
			}
		}
	case string:
		if containsCredentialMarker(v) {
			return fmt.Errorf("credential-looking value is not allowed")
		}
	}
	return nil
}

func isForbiddenCredentialKey(key string) bool {
	switch strings.ToLower(key) {
	case "api_key", "apikey", "token", "secret", "credential", "credentials", "authorization", "cookie", "password", "bearer_token", "access_token", "refresh_token":
		return true
	default:
		return false
	}
}

func validateRawMetadata(value any) error {
	root, ok := value.(map[string]any)
	if !ok {
		return nil
	}
	providers, ok := root["providers"].([]any)
	if !ok {
		return nil
	}
	for _, item := range providers {
		provider, ok := item.(map[string]any)
		if !ok {
			continue
		}
		capabilities, ok := provider["capabilities"].(map[string]any)
		if !ok {
			continue
		}
		for key := range capabilities {
			switch key {
			case "streaming", "tools", "usage", "reasoning":
			default:
				return fmt.Errorf("unsupported capability: %s", key)
			}
		}
	}
	return nil
}
