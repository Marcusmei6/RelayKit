package server

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"sync"
	"time"

	"relaykit/gateway/internal/config"
)

type catalogState struct {
	mu                 sync.Mutex
	entries            map[string]catalogLastKnownGood
	providerTestRoutes map[string]string
}

type catalogLastKnownGood struct {
	Timestamp         time.Time
	ConfigFingerprint string
}

type catalogLastKnownGoodSnapshot struct {
	Timestamp         time.Time
	ConfigFingerprint string
	Stale             bool
}

func newCatalogState() *catalogState {
	return &catalogState{
		entries:            make(map[string]catalogLastKnownGood),
		providerTestRoutes: make(map[string]string),
	}
}

func (s *catalogState) markProviderTestReachable(providerID, modelID, configFingerprint string, timestamp time.Time) {
	s.markRouteReachable(providerID, modelID, configFingerprint, timestamp)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.providerTestRoutes[catalogStateKey(providerID, modelID)] = configFingerprint
}

func (s *catalogState) providerTestReachable(providerID, modelID, configFingerprint string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.providerTestRoutes[catalogStateKey(providerID, modelID)] == configFingerprint
}

func (s *catalogState) markRouteReachable(providerID, modelID, configFingerprint string, timestamp time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.entries[catalogStateKey(providerID, modelID)] = catalogLastKnownGood{
		Timestamp:         timestamp.UTC(),
		ConfigFingerprint: configFingerprint,
	}
}

func (s *catalogState) lastKnownGood(providerID, modelID, configFingerprint string) (catalogLastKnownGoodSnapshot, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	entry, ok := s.entries[catalogStateKey(providerID, modelID)]
	if !ok {
		return catalogLastKnownGoodSnapshot{}, false
	}
	return catalogLastKnownGoodSnapshot{
		Timestamp:         entry.Timestamp,
		ConfigFingerprint: entry.ConfigFingerprint,
		Stale:             entry.ConfigFingerprint != configFingerprint,
	}, true
}

func catalogStateKey(providerID, modelID string) string {
	return providerID + "\x00" + modelID
}

func catalogConfigFingerprint(provider config.ProviderProfile, model config.Model) string {
	payload, _ := json.Marshal(struct {
		ProviderID    string                `json:"provider_id"`
		BaseURL       string                `json:"base_url"`
		APIFormat     string                `json:"api_format"`
		Catalog       config.Catalog        `json:"catalog"`
		CredentialRef *config.CredentialRef `json:"credential_ref"`
		Routing       config.Routing        `json:"routing"`
		Model         config.Model          `json:"model"`
	}{provider.ID, provider.BaseURL, provider.APIFormat, provider.Catalog, provider.CredentialRef, provider.Routing, model})
	sum := sha256.Sum256(payload)
	return hex.EncodeToString(sum[:])
}
