import Foundation
import RelayKitCore

let validConfig = """
{
  "providers": [
    {
      "id": "local-openai-compatible",
      "name": "Local OpenAI Compatible",
      "base_url": "http://127.0.0.1:11434/v1",
      "api_format": "openai_chat",
      "auth_env": "RELAYKIT_EXAMPLE_API_KEY",
      "models": [
        {
          "id": "qwen3-coder",
          "display_name": "Qwen3 Coder",
          "context_window": 128000
        }
      ]
    }
  ]
}
"""

func json(_ baseURL: String, extraProviderField: String = "") throws -> Any {
    let body = """
    {
      "providers": [
        {
          "id": "p",
          "name": "Provider",
          "base_url": "\(baseURL)",
          "api_format": "openai_chat"\(extraProviderField),
          "models": [
            {"id": "m"}
          ]
        }
      ]
    }
    """
    return try JSONSerialization.jsonObject(with: Data(body.utf8))
}

func expectValid(_ body: String) throws {
    let value = try JSONSerialization.jsonObject(with: Data(body.utf8))
    try ProviderConfigValidator.validate(value)
}

func expectInvalid(_ value: Any, name: String) {
    do {
        try ProviderConfigValidator.validate(value)
        fatalError("\(name) unexpectedly passed")
    } catch ProviderConfigError.invalid {
    } catch {
        fatalError("\(name) failed with unexpected error: \(error)")
    }
}

func expectProviderDraftWriter() throws {
    let draft = ProviderConfigDraft(
        providerId: "local-new",
        providerName: "Local New",
        baseURL: "http://127.0.0.1:11436/v1",
        apiFormat: "openai_chat",
        authEnv: "RELAYKIT_NEW_API_KEY",
        modelId: "new-coder",
        modelDisplayName: "New Coder",
        contextWindow: 32000
    )
    let data = try ProviderConfigDraftWriter.addProvider(draft, to: Data(validConfig.utf8))
    let json = try JSONSerialization.jsonObject(with: data)
    try ProviderConfigValidator.validate(json)
    guard let root = json as? [String: Any],
          let providers = root["providers"] as? [[String: Any]],
          providers.count == 2,
          let added = providers.last,
          added["id"] as? String == "local-new",
          let credentialRef = added["credential_ref"] as? [String: Any],
          credentialRef["kind"] as? String == "env",
          credentialRef["value"] as? String == "RELAYKIT_NEW_API_KEY",
          let models = added["models"] as? [[String: Any]],
          models.first?["id"] as? String == "new-coder" else {
        fatalError("provider draft writer did not append expected provider: \(json)")
    }
}

func expectProviderDraftWriterWithPrototypeMetadata() throws {
    let draft = ProviderConfigDraft(
        providerId: "local-bridge",
        providerName: "Local Bridge",
        baseURL: "http://127.0.0.1:18787/v1",
        apiFormat: "openai_chat",
        authEnv: "",
        modelId: "bridge/coder",
        modelDisplayName: "Bridge Coder",
        contextWindow: 128000,
        source: "local-bridge",
        modelPrefix: "bridge/",
        modelsURL: "http://127.0.0.1:18787/v1/models",
        credentialKind: "key_file",
        credentialReference: "~/Library/Application Support/RelayKit/bridge.key",
        keyHeader: "Authorization",
        upstreamModel: "upstream-coder",
        streaming: true,
        tools: false,
        usage: true,
        reasoning: true,
        priority: 50,
        visible: true
    )
    let data = try ProviderConfigDraftWriter.addProvider(draft, to: Data(validConfig.utf8))
    let json = try JSONSerialization.jsonObject(with: data)
    try ProviderConfigValidator.validate(json)
    guard let root = json as? [String: Any],
          let providers = root["providers"] as? [[String: Any]],
          let added = providers.last,
          let credentialRef = added["credential_ref"] as? [String: Any],
          credentialRef["kind"] as? String == "key_file",
          credentialRef["header"] as? String == "Authorization",
          let metadata = added["catalog"] as? [String: Any],
          metadata["models_url"] as? String == "http://127.0.0.1:18787/v1/models",
          metadata["key_header"] as? String == "Authorization",
          let capabilities = added["capabilities"] as? [String: Any],
          capabilities["reasoning"] as? Bool == true,
          let routing = added["routing"] as? [String: Any],
          routing["source"] as? String == "local-bridge",
          routing["model_prefix"] as? String == "bridge/",
          routing["priority"] as? Int == 50,
          routing["status"] as? String == "enabled",
          routing["visible"] as? Bool == true,
          let models = added["models"] as? [[String: Any]],
          models.first?["upstream_model"] as? String == "upstream-coder" else {
        fatalError("provider draft writer did not include prototype metadata: \(json)")
    }
}

func expectProviderDraftRejectsCredentialValue() {
    let draft = ProviderConfigDraft(
        providerId: "local-new",
        providerName: "Local New",
        baseURL: "http://127.0.0.1:11436/v1",
        apiFormat: "openai_chat",
        authEnv: "sk-not-a-reference",
        modelId: "new-coder",
        modelDisplayName: "",
        contextWindow: nil
    )
    do {
        _ = try ProviderConfigDraftWriter.addProvider(draft, to: Data(validConfig.utf8))
        fatalError("provider draft credential value unexpectedly passed")
    } catch ProviderConfigError.invalid {
    } catch {
        fatalError("provider draft credential value failed with unexpected error: \(error)")
    }
}

func expectLocalCatalogSummary() throws {
    let body = """
    {
      "data": [
        {"id": "fixture-model-a", "owned_by": "source-beta", "context_window": 128000},
        {"id": "fixture-model-b", "source": "source-beta"},
        {"id": "fixture-model-c", "owned_by": "source-alpha", "display_name": "Fixture C"}
      ]
    }
    """
    let summary = try LocalModelCatalog.decode(Data(body.utf8))
    if summary.modelCount != 3 {
        fatalError("catalog model count = \(summary.modelCount)")
    }
    if summary.sourceGroups.map(\.source) != ["source-alpha", "source-beta"] {
        fatalError("catalog groups = \(summary.sourceGroups)")
    }
    if summary.sourceGroups.map(\.publicLabel) != ["source-1", "source-2"] {
        fatalError("catalog public labels must not expose source names: \(summary.sourceGroups)")
    }
    if summary.redactedEvidence["model_ids_redacted"] as? Bool != true {
        fatalError("catalog evidence must redact model ids: \(summary.redactedEvidence)")
    }
}

func expectCredentialRefContract() throws {
    try expectValid("""
    {
      "providers": [
        {
          "id": "p",
          "name": "Provider",
          "base_url": "https://example.test/v1",
          "api_format": "openai_chat",
          "credential_ref": {
            "kind": "env",
            "value": "RELAYKIT_PROVIDER_TOKEN",
            "header": "x-relay-api-key"
          },
          "models": [
            {"id": "m"}
          ]
        }
      ]
    }
    """)
    expectInvalid(try json("https://example.test/v1", extraProviderField: #", "credential_ref": {"kind": "api_key", "value": "RELAYKIT_PROVIDER_TOKEN"}"#), name: "unsupported credential ref kind")
    expectInvalid(try json("https://example.test/v1", extraProviderField: #", "credential_ref": {"kind": "env", "value": "sk-secret-value"}"#), name: "credential ref secret-looking value")
    expectInvalid(try json("https://example.test/v1", extraProviderField: #", "credential_ref": {"kind": "env", "value": "RELAYKIT_PROVIDER_TOKEN", "header": "Bad Header"}"#), name: "credential ref unsafe header")
    expectInvalid(try json("https://example.test/v1", extraProviderField: #", "credential_ref": {"kind": "key_file", "value": "relative.key"}"#), name: "key file ref relative path")
    expectInvalid(try json("https://example.test/v1", extraProviderField: #", "credential_ref": {"kind": "env", "value": "TOKEN_\u00E9"}"#), name: "credential ref unicode env")
}

func expectCapabilityContract() throws {
    try expectValid("""
    {
      "providers": [
        {
          "id": "p",
          "name": "Provider",
          "base_url": "https://example.test/v1",
          "api_format": "openai_chat",
          "capabilities": {
            "streaming": true,
            "tools": false,
            "usage": true,
            "reasoning": false
          },
          "routing": {
            "source": "custom",
            "model_prefix": "custom/",
            "priority": 100,
            "status": "enabled",
            "visible": true
          },
          "models": [
            {"id": "m", "upstream_model": "upstream-m"}
          ]
        }
      ]
    }
    """)
    expectInvalid(try json("https://example.test/v1", extraProviderField: #", "capabilities": {"streaming": "yes"}"#), name: "capability non-bool")
    expectInvalid(try json("https://example.test/v1", extraProviderField: #", "capabilities": {"batch": true}"#), name: "capability unknown")
    expectInvalid(try json("https://example.test/v1", extraProviderField: #", "routing": {"source": "Private Source"}"#), name: "routing source unsafe")
    expectInvalid(try json("https://example.test/v1", extraProviderField: #", "routing": {"status": "pretend"}"#), name: "routing unsupported status")
}

func expectAppSettingsPersistence() {
    let suiteName = "RelayKitAppValidationTests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        fatalError("could not create test defaults")
    }
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    let store = AppSettingsStore(defaults: defaults)
    if store.appearanceMode != .system {
        fatalError("default appearance mode should be system")
    }
    store.appearanceMode = .light
    if AppSettingsStore(defaults: defaults).appearanceMode != .light {
        fatalError("appearance mode did not persist")
    }
    defaults.set("unsupported", forKey: AppSettingsStore.appearanceModeKey)
    if AppSettingsStore(defaults: defaults).appearanceMode != .system {
        fatalError("unsupported appearance mode should fall back to system")
    }
    store.launchAtLoginRequested = true
    if AppSettingsStore(defaults: defaults).launchAtLoginRequested != true {
        fatalError("launch at login requested state did not persist")
    }
}

try expectValid(validConfig)
try expectProviderDraftWriter()
try expectProviderDraftWriterWithPrototypeMetadata()
expectProviderDraftRejectsCredentialValue()
try expectLocalCatalogSummary()
try expectCredentialRefContract()
try expectCapabilityContract()
expectAppSettingsPersistence()
if RelayKitPaths.gatewayBinaryPath(bundle: Bundle(for: BundleSentinel.self)) != "../gateway/bin/relay" {
    fatalError("non-app bundle should fall back to development gateway path")
}
if RelayKitPaths.providerConfigPath(bundle: Bundle(for: BundleSentinel.self)) != "../examples/providers.example.json" {
    fatalError("non-app bundle should fall back to development provider config path")
}
if RelayKitPaths.codexConfigSourcePath(bundle: Bundle(for: BundleSentinel.self)) != "../examples/codex.config.example.toml" {
    fatalError("non-app bundle should fall back to development Codex config source path")
}
expectInvalid(try json("https://user:pass@example.test/v1"), name: "url userinfo")
expectInvalid(try json("https://example.test/v1?sig=abc"), name: "url query")
expectInvalid(try json("https://example.test/v1?access_token=abc"), name: "url query access_token")
expectInvalid(try json("https://example.test/v1#cursor"), name: "url fragment")
expectInvalid(try json("https://example.test/v1#refresh_token=abc"), name: "url fragment refresh_token")
expectInvalid(try json("https://example.test/v1", extraProviderField: #", "api_key": "abc""#), name: "credential key")
expectInvalid(try json("https://example.test/v1", extraProviderField: #", "credential": "abc""#), name: "credential key generic")
expectInvalid(try json("https://example.test/v1", extraProviderField: #", "credentials": "abc""#), name: "credential key plural")
expectInvalid(try json("https://example.test/v1", extraProviderField: #", "auth_env": "keychain:item""#), name: "bad auth env")

print("RelayKitAppValidationTests passed")

private final class BundleSentinel {}
