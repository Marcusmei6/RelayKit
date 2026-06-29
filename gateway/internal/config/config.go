package config

import (
	"encoding/json"
	"fmt"
	"os"
)

const (
	CodeReadError              = "config_read_error"
	CodeParseError             = "config_parse_error"
	CodeValidationError        = "config_validation_error"
	CodeUnsupportedFormat      = "unsupported_provider_format"
	APIFormatOpenAIChat        = "openai_chat"
	APIFormatAnthropicMessages = "anthropic_messages"
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
	Providers []ProviderProfile `json:"providers"`
}

type ProviderProfile struct {
	ID        string  `json:"id"`
	Name      string  `json:"name"`
	BaseURL   string  `json:"base_url"`
	APIFormat string  `json:"api_format"`
	AuthEnv   string  `json:"auth_env,omitempty"`
	Models    []Model `json:"models"`
}

type Model struct {
	ID            string `json:"id"`
	DisplayName   string `json:"display_name,omitempty"`
	ContextWindow int    `json:"context_window,omitempty"`
}

func Load(path string) (*Config, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, &Error{Code: CodeReadError, Err: err}
	}

	var cfg Config
	if err := json.Unmarshal(body, &cfg); err != nil {
		return nil, &Error{Code: CodeParseError, Err: err}
	}
	if err := validate(cfg); err != nil {
		return nil, err
	}
	return &cfg, nil
}

func validate(cfg Config) error {
	if len(cfg.Providers) == 0 {
		return &Error{Code: CodeValidationError, Err: fmt.Errorf("providers required")}
	}
	for _, p := range cfg.Providers {
		if p.ID == "" || p.Name == "" || p.BaseURL == "" || p.APIFormat == "" || len(p.Models) == 0 {
			return &Error{Code: CodeValidationError, Err: fmt.Errorf("invalid provider %q", p.ID)}
		}
		if p.APIFormat != APIFormatOpenAIChat && p.APIFormat != APIFormatAnthropicMessages {
			return &Error{Code: CodeUnsupportedFormat, Err: fmt.Errorf("unsupported api_format %q", p.APIFormat)}
		}
		for _, m := range p.Models {
			if m.ID == "" {
				return &Error{Code: CodeValidationError, Err: fmt.Errorf("model id required for provider %q", p.ID)}
			}
		}
	}
	return nil
}
