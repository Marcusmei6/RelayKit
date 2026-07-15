import Foundation
import RelayKitCore
import Security

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
    let importedModels = [
        ProviderConfigDraft.ModelDraft(
            id: "bridge/coder",
            displayName: "Bridge Coder",
            contextWindow: 128000,
            upstreamModel: "upstream-coder"
        ),
        ProviderConfigDraft.ModelDraft(
            id: "bridge/reviewer",
            displayName: "Bridge Reviewer",
            contextWindow: 64000,
            upstreamModel: "upstream-reviewer"
        ),
    ]
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
        models: importedModels,
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
          models.count == 2,
          models.first?["upstream_model"] as? String == "upstream-coder",
          models.last?["id"] as? String == "bridge/reviewer",
          models.last?["upstream_model"] as? String == "upstream-reviewer" else {
        fatalError("provider draft writer did not include prototype metadata: \(json)")
    }
}

func expectProviderDraftWriterNormalizesPrefixedModels() throws {
    let draft = ProviderConfigDraft(
        providerId: "demo",
        providerName: "Demo Anthropic",
        baseURL: "https://example.test/v1",
        apiFormat: "anthropic_messages",
        authEnv: "",
        modelId: "claude-opus-4-6",
        modelDisplayName: "Claude Opus 4.6",
        contextWindow: nil,
        source: "demo",
        modelPrefix: "demo/",
        credentialKind: "keychain",
        credentialReference: "relaykit.provider.example",
        keyHeader: "x-api-key",
        upstreamModel: "claude-opus-4-6",
        models: [
            ProviderConfigDraft.ModelDraft(id: "claude-opus-4-6", displayName: "Claude Opus 4.6", upstreamModel: ""),
            ProviderConfigDraft.ModelDraft(id: "demo/claude-sonnet-4-6", displayName: "Claude Sonnet 4.6", upstreamModel: "claude-sonnet-4-6"),
        ],
        priority: 100,
        visible: true
    )
    let data = try ProviderConfigDraftWriter.addProvider(draft, to: Data(validConfig.utf8))
    let json = try JSONSerialization.jsonObject(with: data)
    try ProviderConfigValidator.validate(json)
    guard let root = json as? [String: Any],
          let providers = root["providers"] as? [[String: Any]],
          let added = providers.last,
          let models = added["models"] as? [[String: Any]],
          models[0]["id"] as? String == "demo/claude-opus-4-6",
          models[0]["upstream_model"] as? String == "claude-opus-4-6",
          models[1]["id"] as? String == "demo/claude-sonnet-4-6",
          models[1]["upstream_model"] as? String == "claude-sonnet-4-6" else {
        fatalError("provider draft writer did not normalize prefixed models: \(json)")
    }
}

func expectProviderDraftWriterWithKeychainReference() throws {
    let draft = ProviderConfigDraft(
        providerId: "local-keychain",
        providerName: "Local Keychain",
        baseURL: "http://127.0.0.1:11436/v1",
        apiFormat: "openai_chat",
        authEnv: "",
        modelId: "keychain/coder",
        modelDisplayName: "Keychain Coder",
        contextWindow: 32000,
        source: "local-keychain",
        modelPrefix: "keychain/",
        credentialKind: "keychain",
        credentialReference: "relaykit.test.provider-token",
        keyHeader: "Authorization",
        upstreamModel: "upstream-coder",
        priority: 50,
        visible: true
    )
    let data = try ProviderConfigDraftWriter.addProvider(draft, to: Data(validConfig.utf8))
    let text = String(data: data, encoding: .utf8) ?? ""
    if text.contains("sk-test-secret-value") {
        fatalError("provider draft wrote a credential value: \(text)")
    }
    let json = try JSONSerialization.jsonObject(with: data)
    try ProviderConfigValidator.validate(json)
    guard let root = json as? [String: Any],
          let providers = root["providers"] as? [[String: Any]],
          let added = providers.last,
          let credentialRef = added["credential_ref"] as? [String: Any],
          credentialRef["kind"] as? String == "keychain",
          credentialRef["value"] as? String == "relaykit.test.provider-token",
          credentialRef["header"] as? String == "Authorization",
          let routing = added["routing"] as? [String: Any],
          routing["status"] as? String == "enabled",
          routing["visible"] as? Bool == true else {
        fatalError("provider draft writer did not include keychain reference: \(json)")
    }
}

func expectProviderDraftWriterWithResponsesProtocol() throws {
    let draft = ProviderConfigDraft(
        providerId: "responses-provider",
        providerName: "Responses Provider",
        baseURL: "https://example.test/v1",
        apiFormat: "openai_responses",
        authEnv: "",
        modelId: "responses/model",
        modelDisplayName: "Responses Model",
        contextWindow: nil,
        source: "responses-provider",
        modelPrefix: "responses/",
        credentialKind: "keychain",
        credentialReference: "relaykit.validation.responses",
        keyHeader: "Authorization",
        upstreamModel: "responses-model",
        priority: 100,
        visible: true
    )
    let data = try ProviderConfigDraftWriter.addProvider(draft, to: Data(validConfig.utf8))
    let text = String(data: data, encoding: .utf8) ?? ""
    if text.contains("fixture-keychain-value") {
        fatalError("Responses draft must not serialize a Keychain value")
    }
    let json = try JSONSerialization.jsonObject(with: data)
    try ProviderConfigValidator.validate(json)
    guard let root = json as? [String: Any],
          let providers = root["providers"] as? [[String: Any]],
          let added = providers.last,
          added["api_format"] as? String == "openai_responses",
          let credentialRef = added["credential_ref"] as? [String: Any],
          credentialRef["kind"] as? String == "keychain",
          credentialRef["value"] as? String == "relaykit.validation.responses",
          Set(credentialRef.keys) == ["kind", "value", "header"] else {
        fatalError("Responses draft did not preserve public configuration fields: \(json)")
    }

    let reopened = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: json))
    guard let reopenedRoot = reopened as? [String: Any],
          let reopenedProvider = (reopenedRoot["providers"] as? [[String: Any]])?.last,
          reopenedProvider["api_format"] as? String == "openai_responses",
          let reopenedReference = reopenedProvider["credential_ref"] as? [String: Any],
          reopenedReference["kind"] as? String == "keychain",
          reopenedReference["value"] as? String == "relaykit.validation.responses" else {
        fatalError("Responses draft did not preserve its protocol and Keychain reference after reopen")
    }
}

func expectProviderTestRequestContract() throws {
    let request = ProviderTestRequest(providerID: "responses-provider", modelID: "responses/model")
    let data = try JSONEncoder().encode(request)
    let text = String(data: data, encoding: .utf8) ?? ""
    guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(body.keys) == ["provider_id", "model_id"],
          body["provider_id"] as? String == "responses-provider",
          body["model_id"] as? String == "responses/model" else {
        fatalError("provider-test request schema must contain only provider_id and model_id: \(text)")
    }
    for forbidden in ["token", "key", "url", "body", "authorization", "input", "max_output_tokens"] {
        if text.localizedCaseInsensitiveContains(forbidden) {
            fatalError("provider-test request leaked forbidden field \(forbidden): \(text)")
        }
    }

    let response = try JSONDecoder().decode(
        ProviderTestResponse.self,
        from: Data(#"{"provider_id":"responses-provider","model_id":"responses/model","status":"ok"}"#.utf8)
    )
    if response.providerID != "responses-provider" ||
        response.modelID != "responses/model" ||
        response.status != .ok ||
        response.connectionKind != .connected ||
        response.error != nil {
        fatalError("provider-test sanitized response did not decode as expected: \(response)")
    }
}

func expectProviderTestEnumMapping() throws {
    let cases: [(String, ProviderTestConnectionKind)] = [
        ("auth_failed", .authFailed),
        ("network_failed", .networkFailed),
        ("responses_unavailable", .responsesUnavailable),
        ("unknown_model", .responsesUnavailable),
        ("unsupported_provider_format", .responsesUnavailable),
    ]
    for (errorType, expectedKind) in cases {
        let data = Data(#"{"provider_id":"responses-provider","model_id":"responses/model","status":"failed","error":{"type":"\#(errorType)"}}"#.utf8)
        let response = try JSONDecoder().decode(ProviderTestResponse.self, from: data)
        if response.status != .failed || response.error?.type.rawValue != errorType || response.connectionKind != expectedKind {
            fatalError("provider-test enum mapping failed for \(errorType): \(response)")
        }
    }
}

func expectProviderTestSaveActionIsIdempotent() {
    let providerID = "responses-provider"
    var persistedProviderIDs = Set<String>()
    let first = ProviderTestSaveAction.resolve(providerID: providerID, persistedProviderIDs: persistedProviderIDs)
    if first != .add {
        fatalError("first add/import provider test save must add: \(first)")
    }
    persistedProviderIDs.insert(providerID)
    let second = ProviderTestSaveAction.resolve(providerID: providerID, persistedProviderIDs: persistedProviderIDs)
    if second != .update(originalProviderID: providerID) {
        fatalError("subsequent add/import provider test save must update the persisted provider: \(second)")
    }
}

func expectProviderTestSinglePostLifecycle() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let content = try String(contentsOf: root.appendingPathComponent("Sources/RelayKitApp/Views/ContentView.swift"), encoding: .utf8)
    let appModel = try String(contentsOf: root.appendingPathComponent("Sources/RelayKitApp/Stores/AppModel.swift"), encoding: .utf8)

    guard let responseStart = content.range(of: "private func testSavedResponsesConnection() async"),
          let responseEnd = content.range(of: "private func saveForConnectionTest() -> Bool", range: responseStart.upperBound..<content.endIndex) else {
        fatalError("Responses connection-test function boundaries are missing")
    }
    let responseBody = content[responseStart.lowerBound..<responseEnd.lowerBound]
    if responseBody.contains("refreshModels()") {
        fatalError("typed provider-test success must not refresh models and trigger a second Responses POST")
    }

    guard let modelStart = appModel.range(of: "func testSavedProviderConnection(providerID: String, modelID: String) async throws"),
          let modelEnd = appModel.range(of: "func providerHealth", range: modelStart.upperBound..<appModel.endIndex) else {
        fatalError("AppModel provider-test function boundaries are missing")
    }
    let modelBody = appModel[modelStart.lowerBound..<modelEnd.lowerBound]
    if modelBody.contains("restartGateway()") || !modelBody.contains("if !gateway.isRunning") {
        fatalError("provider test must reuse a running gateway and start only when stopped")
    }
    if !content.contains("ProviderTestSaveAction.resolve") {
        fatalError("add/import provider tests must use the idempotent save decision")
    }
}

func expectResponsesConnectionUsesGatewayOnly() throws {
    let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/RelayKitApp/Views/ContentView.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    for forbidden in ["probeResponses(", "connectionProbeAPIKey(", "connectionProbeModel(", "RelayKit connection probe", "max_output_tokens"] {
        if source.contains(forbidden) {
            fatalError("Responses connection test must not retain direct upstream probe helper: \(forbidden)")
        }
    }
    for required in [
        "model.testSavedProviderConnection",
        "provider-upstream-protocol-selector",
        "provider-upstream-protocol-option-\\(option.id)",
        "provider-form-save",
        "provider-\\(provider.id)",
        "provider-saved-key-state",
        "provider-provider-name-field",
        "provider-api-base-url-field",
        "provider-model-id-field",
    ] {
        if !source.contains(required) {
            fatalError("provider harness accessibility identifier or local gateway connection path is missing: \(required)")
        }
    }
}

func expectProviderModalAccessibilityContract() throws {
    let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/RelayKitApp/Views/ContentView.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    guard let formStart = source.range(of: "private struct ProviderFormView: View"),
          let formEnd = source.range(of: "private struct SectionCard", range: formStart.upperBound..<source.endIndex) else {
        fatalError("ProviderFormView boundaries are missing")
    }
    let form = source[formStart.lowerBound..<formEnd.lowerBound]

    if form.contains(".smokeSection(") {
        fatalError("provider form telemetry must not create accessibility ancestors")
    }
    guard form.contains(".accessibilityElement(children: .contain)"),
          form.contains(".accessibilityIdentifier(\"provider-form-container\")") else {
        fatalError("provider form must expose one contained accessibility root")
    }
    if form.components(separatedBy: "provider-form-container").count - 1 != 1 {
        fatalError("provider form container identifier must remain unique")
    }
    guard let providerNameStart = form.range(of: "TextField(\"My gateway\", text: $providerName)"),
          let providerNameEnd = form.range(of: ".smokeRecordOnly(\"provider-name-field\"", range: providerNameStart.upperBound..<form.endIndex),
          let baseURLStart = form.range(of: "TextField(\"https://gateway.example/api\", text: $baseURL)"),
          let baseURLEnd = form.range(of: ".smokeRecordOnly(\"provider-base-url-field\"", range: baseURLStart.upperBound..<form.endIndex),
          let apiKeyStart = form.range(of: "private var apiKeyReplacementInput: AnyView"),
          let apiKeyEnd = form.range(of: "private var modelsSection", range: apiKeyStart.upperBound..<form.endIndex),
          let modelIDStart = form.range(of: "TextField(\"model id\", text: $row.modelId)"),
          let modelIDEnd = form.range(of: "if modelRows.count > 1", range: modelIDStart.upperBound..<form.endIndex),
          let advancedToggleStart = form.range(of: "Button {\n                isAdvancedExpanded.toggle()"),
          let advancedToggleEnd = form.range(of: "if isAdvancedExpanded", range: advancedToggleStart.upperBound..<form.endIndex),
          let saveStart = form.range(of: "Button(mode.saveTitle) { save() }"),
          let saveEnd = form.range(of: ".padding(.top, 12)", range: saveStart.upperBound..<form.endIndex) else {
        fatalError("provider form accessibility child boundaries are missing")
    }
    let accessibilityChildren: [(identifier: String, source: Substring, expectedCount: Int)] = [
        ("provider-provider-name-field", form[providerNameStart.lowerBound..<providerNameEnd.lowerBound], 1),
        ("provider-api-base-url-field", form[baseURLStart.lowerBound..<baseURLEnd.lowerBound], 1),
        ("api-key-new-input-field", form[apiKeyStart.lowerBound..<apiKeyEnd.lowerBound], 2),
        ("provider-model-id-field", form[modelIDStart.lowerBound..<modelIDEnd.lowerBound], 1),
        ("provider-advanced-toggle-row", form[advancedToggleStart.lowerBound..<advancedToggleEnd.lowerBound], 1),
        ("provider-form-save", form[saveStart.lowerBound..<saveEnd.lowerBound], 1),
    ]
    for child in accessibilityChildren {
        let exactModifier = ".accessibilityIdentifier(\"\(child.identifier)\")"
        let count = child.source.components(separatedBy: exactModifier).count - 1
        if count != child.expectedCount {
            fatalError("provider form accessibility child must use exact modifier in its control boundary: \(child.identifier)")
        }
    }

    guard let protocolPickerStart = form.range(of: "Picker(\"\", selection: $apiFormat) {"),
          let protocolPickerEnd = form.range(of: "\n                    VStack", range: protocolPickerStart.upperBound..<form.endIndex) else {
        fatalError("upstream protocol Picker boundaries are missing")
    }
    let protocolPicker = form[protocolPickerStart.lowerBound..<protocolPickerEnd.lowerBound]
    guard protocolPicker.contains(".accessibilityIdentifier(\"provider-upstream-protocol-selector\")"),
          protocolPicker.contains(".smokeRecordOnly(\"provider-upstream-protocol-selector\", recorder: smokeSectionRecorder)") else {
        fatalError("upstream protocol Picker must retain its explicit accessibility identifier and telemetry recorder")
    }

    guard let addStart = source.range(of: "if showingProviderForm"),
          let editStart = source.range(of: "if let editingProvider", range: addStart.upperBound..<source.endIndex),
          let officialStart = source.range(of: "if showingOfficialChannel", range: editStart.upperBound..<source.endIndex),
          let importStart = source.range(of: "private var providerImportOverlay"),
          let importEnd = source.range(of: "private func cliSwitch", range: importStart.upperBound..<source.endIndex) else {
        fatalError("provider modal presentation boundaries are missing")
    }
    let modalContracts: [(name: String, source: Substring, mode: String, recorders: [String])] = [
        (
            "add",
            source[addStart.lowerBound..<editStart.lowerBound],
            "mode: .add",
            ["tab-provider", "provider-modal"]
        ),
        (
            "edit",
            source[editStart.lowerBound..<officialStart.lowerBound],
            "mode: .edit(editingProvider)",
            ["provider-edit-modal", "provider-modal"]
        ),
        (
            "import",
            source[importStart.lowerBound..<importEnd.lowerBound],
            "mode: .import(importingGroup, catalogURL: model.localCatalogURL.absoluteString)",
            ["provider-import-modal", "provider-modal"]
        ),
    ]
    for modal in modalContracts {
        if modal.source.contains(".smokeSection(") {
            fatalError("provider \(modal.name) modal telemetry must not create accessibility ancestors")
        }
        if !modal.source.contains(modal.mode) {
            fatalError("provider \(modal.name) modal accessibility contract is missing mode: \(modal.mode)")
        }
        for recorder in modal.recorders {
            let exactRecorder = ".smokeRecordOnly(\"\(recorder)\", recorder: smokeSectionRecorder)"
            if modal.source.components(separatedBy: exactRecorder).count - 1 != 1 {
                fatalError("provider \(modal.name) modal must preserve fixed telemetry recorder: \(recorder)")
            }
        }
    }
    guard let recordOnlyStart = source.range(of: "func smokeRecordOnly("),
          let recordOnlyEnd = source.range(of: "\n    }\n}", range: recordOnlyStart.upperBound..<source.endIndex) else {
        fatalError("smokeRecordOnly helper boundaries are missing")
    }
    if !source[recordOnlyStart.lowerBound..<recordOnlyEnd.lowerBound].contains("if id.isEmpty") {
        fatalError("smokeRecordOnly must preserve empty telemetry conditions")
    }
}

func expectExplicitUpstreamProtocolSelectionWins() {
    let selected = ProviderFormLabels.resolvedUpstreamProtocol(
        selected: "openai_responses",
        providerText: "Anthropic-compatible endpoint"
    )
    if selected != "openai_responses" {
        fatalError("explicit upstream protocol selection must override name-based inference: \(selected)")
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
        {"id": "fixture-model-a", "owned_by": "source-beta", "context_window": 128000, "protocol": "openai_chat", "transport": "remote_bridge", "bridge_host": "127.0.0.1:18788", "upstream_model": "up-a", "status": "ready", "visibility": "visible"},
        {"id": "fixture-model-b", "source": "source-beta", "protocol": "openai_chat", "transport": "remote_bridge", "bridge_host": "127.0.0.1:18788", "upstream_model": "up-b"},
        {"id": "fixture-model-c", "owned_by": "source-alpha", "display_name": "Fixture C", "protocol": "", "status": "ready"}
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
    if summary.sourceGroups.first?.firstModelId != "fixture-model-c" {
        fatalError("catalog import candidate should retain safe local model ids for UI prefill")
    }
    let beta = summary.sourceGroups[1]
    if beta.modelSummaries.count != 2 ||
        beta.protocolSummary != "openai_chat" ||
        beta.transportSummary != "remote_bridge" ||
        beta.bridgeHost != "127.0.0.1:18788" ||
        beta.executionBaseURL != "http://127.0.0.1:18788/v1" ||
        beta.modelSummaries.first?.upstreamModel != "up-a" ||
        beta.modelSummaries.first?.status != "ready" ||
        beta.modelSummaries.first?.visibility != "visible" {
        fatalError("catalog import fields missing: \(beta)")
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

func expectProviderConfigPathRecoversStaleTemporaryPreference() {
    let stale = "/tmp/relaykit-detail-debug.dead/fixture-providers.json"
    let resolved = RelayKitPaths.resolvedProviderConfigPath(savedPath: stale) { _ in false }
    if resolved != RelayKitPaths.providerConfigPath() {
        fatalError("stale tmp provider config should recover to App Support: \(resolved)")
    }
    let existing = RelayKitPaths.resolvedProviderConfigPath(savedPath: "/tmp/relaykit-real-proof.live/providers.json") { $0 == "/tmp/relaykit-real-proof.live/providers.json" }
    if existing != RelayKitPaths.providerConfigPath() {
        fatalError("existing proof tmp provider config should recover to App Support: \(existing)")
    }
    let smoke = RelayKitPaths.resolvedProviderConfigPath(savedPath: "/tmp/relaykit-ui-smoke-config.abc/providers.json") { $0 == "/tmp/relaykit-ui-smoke-config.abc/providers.json" }
    if smoke != RelayKitPaths.providerConfigPath() {
        fatalError("existing smoke tmp provider config should recover to App Support: \(smoke)")
    }
    let unrelatedTmp = RelayKitPaths.resolvedProviderConfigPath(savedPath: "/tmp/user-selected-providers.json") { $0 == "/tmp/user-selected-providers.json" }
    if unrelatedTmp != "/tmp/user-selected-providers.json" {
        fatalError("unrelated tmp provider config should remain explicit: \(unrelatedTmp)")
    }
}

func expectOfficialProofRootOverride() {
    let home = URL(fileURLWithPath: "/tmp/relaykit-proof-user", isDirectory: true)
    let defaultRoot = "/tmp/relaykit-proof-user/Library/Application Support/RelayKit/OfficialProof"
    let isolatedRoot = "/tmp/relaykit-proof-user/Library/Application Support/RelayKit/DesktopProof/official-proof"
    let environment = ["RELAYKIT_OFFICIAL_PROOF_ROOT": isolatedRoot]
    if RelayKitPaths.officialProofRoot(environment: environment, homeDirectory: home) != isolatedRoot {
        fatalError("manual proof official auth root override was not honored")
    }
    if RelayKitPaths.officialProofRoot(environment: ["RELAYKIT_OFFICIAL_PROOF_ROOT": "/tmp/outside-relaykit"], homeDirectory: home) != defaultRoot {
        fatalError("official auth root override escaped RelayKit App Support")
    }
    if RelayKitPaths.officialProofRoot(environment: ["RELAYKIT_OFFICIAL_PROOF_ROOT": "relative/path"], homeDirectory: home) != defaultRoot {
        fatalError("official auth root override accepted a relative path")
    }
}

func expectProviderFormPresentationLabels() {
    if ProviderFormLabels.codexRoute != "Codex route: Responses" {
        fatalError("Codex route label must distinguish client route")
    }
    if ProviderFormLabels.upstreamProtocol(apiFormat: "anthropic_messages") != "Upstream: Anthropic" {
        fatalError("Anthropic upstream label must be explicit")
    }
    if ProviderFormLabels.upstreamProtocol(apiFormat: "openai_chat") != "Upstream: OpenAI Chat" {
        fatalError("OpenAI upstream label must be explicit")
    }
    if ProviderFormLabels.apiKeyStatus(hasReference: true, credentialKind: "keychain") != "API key saved in Keychain" {
        fatalError("Keychain saved state label regressed")
    }
    if ProviderFormLabels.apiKeyStatus(hasReference: false, credentialKind: "") != "No API key saved" {
        fatalError("Empty API key state label regressed")
    }
    if ProviderFormLabels.apiKeyPlaceholder(hasReference: true) != "Paste API key" {
        fatalError("Saved credential placeholder regressed")
    }
    if ProviderFormLabels.apiKeyPlaceholder(hasReference: false) != "Paste API key" {
        fatalError("Empty credential placeholder regressed")
    }
    if ProviderFormLabels.apiKeyReplaceButtonVisible(hasReference: true) ||
        ProviderFormLabels.apiKeyReplaceButtonVisible(hasReference: false) {
        fatalError("API key replacement must use the same field, not a separate Replace button")
    }
    if ProviderFormLabels.savedKeyMask != "••••••••••••" {
        fatalError("Saved key mask must not include fake saved text")
    }
    if ProviderFormLabels.keyUnavailableStatus != "Key unavailable, paste a new key" {
        fatalError("Unavailable Keychain copy regressed")
    }
    if ProviderFormLabels.apiKeyEyeLabel(showingKey: false) != "Show API key" ||
        ProviderFormLabels.apiKeyEyeLabel(showingKey: true) != "Hide API key" {
        fatalError("API key eye toggle labels regressed")
    }
    if ProviderFormLabels.officialPrimaryActionLabel(status: "route verified") != "Route verified" ||
        !ProviderFormLabels.officialPrimaryActionDisabled(status: "route verified", inProgress: false) {
        fatalError("Route verified official CTA must be disabled and not invite sign-in")
    }
    if ProviderFormLabels.officialPrimaryActionLabel(status: "login available") != "Logged in" ||
        !ProviderFormLabels.officialPrimaryActionDisabled(status: "login available", inProgress: false) {
        fatalError("Logged-in official CTA must be disabled and not invite sign-in")
    }
    if ProviderFormLabels.officialPrimaryActionDisabled(status: "not connected", inProgress: false) {
        fatalError("Disconnected official CTA should remain available")
    }
    let enabledProtocols = ProviderFormLabels.upstreamProtocolOptions.filter(\.isEnabled).map(\.id)
    if enabledProtocols != ["anthropic_messages", "openai_chat", "openai_responses"] {
        fatalError("Provider Advanced protocols must match gateway support: \(enabledProtocols)")
    }
    let plannedProtocols = ProviderFormLabels.upstreamProtocolOptions.filter { !$0.isEnabled }.map(\.label)
    if !plannedProtocols.isEmpty {
        fatalError("Responses provider route must be selectable: \(plannedProtocols)")
    }
    let advancedLabels = ProviderFormLabels.ordinaryAdvancedLabels
    let expectedAdvanced = ["Upstream protocol", "Custom models URL", "Custom auth header", "Upstream model override"]
    if advancedLabels != expectedAdvanced {
        fatalError("Ordinary Advanced labels regressed: \(advancedLabels)")
    }
    let leakedLabels = ProviderFormLabels.hiddenOrdinaryAdvancedLabels.filter { advancedLabels.contains($0) }
    if !leakedLabels.isEmpty {
        fatalError("Raw config labels leaked into ordinary Advanced: \(leakedLabels)")
    }
}

func expectRedactedProviderSaveAndGatewayGuidance() {
    if ProviderFormLabels.gatewayStoppedGuidance != "Gateway is stopped · test a provider connection or start it in Settings" {
        fatalError("stopped gateway guidance regressed")
    }
    let added = ProviderFormLabels.providerAddedMessage(storedKey: true, backupCreated: true)
    if added != "Stored Keychain credential; added provider; backup created" || added.contains("/") {
        fatalError("provider add confirmation must not expose a backup path: \(added)")
    }
    let updated = ProviderFormLabels.providerUpdatedMessage(backupCreated: true)
    if updated != "Saved provider; backup created" || updated.contains("/") {
        fatalError("provider update confirmation must not expose a backup path: \(updated)")
    }
    let config = ProviderFormLabels.providerConfigSavedMessage(backupCreated: true)
    if config != "Saved provider config; backup created" || config.contains("/") {
        fatalError("provider config confirmation must not expose a backup path: \(config)")
    }
}

func expectOfficialAuthURLSanitizer() {
    let samples = [
        "\u{001B}[0mhttps://auth.openai.com/codex/device\u{001B}[0m",
        "\u{001B}]8;;https://auth.openai.com/codex/device\u{0007}https://auth.openai.com/codex/device\u{001B}]8;;\u{0007}",
        "https://auth.openai.com/codex/device%1B%5B0m",
        "\"https://auth.openai.com/codex/device\".",
    ]
    for sample in samples {
        if ProviderFormLabels.sanitizedOfficialAuthURL(from: sample) != "https://auth.openai.com/codex/device" {
            fatalError("official auth URL sanitizer failed for \(sample.debugDescription)")
        }
    }
}

func expectOfficialStatusFormatter() {
    if ProviderFormLabels.officialRowSubtitle(status: "route verified") != "已连接 · Route verified" {
        fatalError("route verified row should not show disconnected")
    }
    if ProviderFormLabels.officialRowSubtitle(status: "login available") != "已连接 · Login available" {
        fatalError("login available row should not show disconnected")
    }
    if ProviderFormLabels.officialStatusTitle(status: "device login pending") != "Device login pending" {
        fatalError("official sheet status title regressed")
    }
}

func expectProviderConnectionLabels() {
    if ProviderFormLabels.connectionStatusLabel(kind: "connected", listedCount: 5, reachableCount: 3, unavailableCount: 2, latencyMS: 123) != "List reachable · 5 listed · 3 reachable · 2 unavailable · 123 ms" {
        fatalError("connected connection label regressed")
    }
    if ProviderFormLabels.connectionStatusLabel(kind: "auth_failed", listedCount: 0, reachableCount: 0, unavailableCount: 0, latencyMS: nil) != "Authentication failed · check API key" {
        fatalError("auth failed label must tell the user what to fix")
    }
    if ProviderFormLabels.connectionStatusLabel(kind: "model_list_unavailable", listedCount: 0, reachableCount: 0, unavailableCount: 0, latencyMS: 42) != "Model list unavailable · check models URL or model ID · 42 ms" {
        fatalError("model list unavailable label must tell the user what to fix")
    }
    if ProviderFormLabels.connectionStatusLabel(kind: "network_failed", listedCount: 0, reachableCount: 0, unavailableCount: 0, latencyMS: nil) != "Network failed · check API base URL" {
        fatalError("network failed label must tell the user what to fix")
    }
}

func expectProviderHealthLabels() {
    if ProviderFormLabels.providerHealthSummary(saved: 5, available: 3, hidden: 2) != "5 saved / 3 available / 2 hidden" {
        fatalError("provider health summary copy regressed")
    }
    if ProviderFormLabels.providerHiddenReason(modelId: "demo/claude-opus-4-6", reason: "upstream non-success") != "demo/claude-opus-4-6 · upstream non-success" {
        fatalError("provider hidden reason copy regressed")
    }
}

func expectProviderConnectionClassification() {
    let connected = ProviderFormLabels.providerConnectionKind(
        httpStatus: 200,
        contentType: "application/json",
        bodyPrefix: #"{"data":[{"id":"m"}]}"#,
        modelCount: 1
    )
    if connected != "connected" {
        fatalError("success model discovery should be connected: \(connected)")
    }
    let unauthorized = ProviderFormLabels.providerConnectionKind(httpStatus: 401, contentType: "application/json")
    if unauthorized != "auth_failed" {
        fatalError("401 should be auth_failed: \(unauthorized)")
    }
    let html = ProviderFormLabels.providerConnectionKind(
        httpStatus: 200,
        contentType: "text/html; charset=UTF-8",
        bodyPrefix: "<html>",
        modelCount: 0
    )
    if html != "model_list_unavailable" {
        fatalError("HTML model response should be unavailable: \(html)")
    }
    let missing = ProviderFormLabels.providerConnectionKind(httpStatus: 404, contentType: "application/json")
    if missing != "model_list_unavailable" {
        fatalError("404 model response should be unavailable: \(missing)")
    }
    let timeout = ProviderFormLabels.providerConnectionKind(httpStatus: nil, networkFailed: true)
    if timeout != "network_failed" {
        fatalError("timeout/network failure should be network_failed: \(timeout)")
    }
}

func expectUsageAnalytics() {
    let rows = [
        UsageSummary(day: "2026-07-09", providerId: "openai", model: "gpt-5.5", requests: 2, inputTokens: 100, outputTokens: 50, totalTokens: 150, durationMs: 1000),
        UsageSummary(day: "2026-07-08", providerId: "demo", model: "demo/claude-sonnet-4-6", requests: 3, inputTokens: 200, outputTokens: 300, totalTokens: 500, durationMs: 2000),
        UsageSummary(day: "2026-07-02", providerId: "demo", model: "demo/claude-opus-4-6", requests: 1, inputTokens: 40, outputTokens: 60, totalTokens: 100, durationMs: 900),
        UsageSummary(day: "2026-06-20", providerId: "openai", model: "gpt-5.1", requests: 1, inputTokens: 10, outputTokens: 15, totalTokens: 25, durationMs: 500),
    ]
    let analytics = UsageAnalytics(rows, today: "2026-07-09")
    if analytics.todayTokens != 150 || analytics.sevenDayTokens != 650 || analytics.allTimeTokens != 775 {
        fatalError("usage token rollup regressed: \(analytics)")
    }
    if analytics.requestCount != 7 || analytics.activeDayCount != 4 {
        fatalError("usage request/day rollup regressed")
    }
    if analytics.topModelSevenDays != "demo/claude-sonnet-4-6" {
        fatalError("usage top model 7D regressed: \(String(describing: analytics.topModelSevenDays))")
    }
    let providerNames = analytics.providerRollups.map(\.name)
    if providerNames != ["Official Codex / OpenAI", "Third-party providers"] {
        fatalError("provider grouping regressed: \(providerNames)")
    }
    if analytics.providerRollups[0].tokens != 175 || analytics.providerRollups[1].tokens != 600 {
        fatalError("provider token grouping regressed: \(analytics.providerRollups)")
    }
    if analytics.modelRollups.first?.model != "demo/claude-sonnet-4-6" {
        fatalError("model rollup should sort by all-time tokens")
    }
    if UsageAnalytics.formatTokens(999) != "999" ||
        UsageAnalytics.formatTokens(1_500) != "1.5K" ||
        UsageAnalytics.formatTokens(103_912) != "103.9K" ||
        UsageAnalytics.formatTokens(103_700_000) != "103.7M" ||
        UsageAnalytics.formatTokens(2_500_000_000) != "2.5B" {
        fatalError("usage token unit formatting regressed")
    }
    if UsageAnalytics.readableModelName("demo/claude-haiku-4-5") != "claude-haiku-4-5" ||
        UsageAnalytics.readableModelName("demo/claude-sonnet-4-6") != "claude-sonnet-4-6" ||
        UsageAnalytics.readableModelName("gpt-5.5") != "gpt-5.5" {
        fatalError("top model readable label regressed")
    }
    let sevenDayBuckets = analytics.activityBuckets(range: .sevenDays)
    if sevenDayBuckets.count != 14 || sevenDayBuckets.filter(\.isActive).count != 2 || analytics.activityUnitLabel(range: .sevenDays) != "7D · half-day" {
        fatalError("7D activity buckets regressed: \(sevenDayBuckets)")
    }
    if analytics.activityBuckets(range: .oneMonth).count != 30 || analytics.activityUnitLabel(range: .oneMonth) != "1M · daily" {
        fatalError("1M activity buckets regressed")
    }
    if analytics.activityBuckets(range: .oneYear).count != 53 || analytics.activityUnitLabel(range: .oneYear) != "1Y · weekly" {
        fatalError("1Y activity buckets regressed")
    }
    if analytics.costLabel != "Cost unavailable" {
        fatalError("usage must not invent cost")
    }
}

func expectOfficialChannelPresentationLabels() {
    let actions = ProviderFormLabels.officialChannelActionLabels
    if actions != ["Connect Official", "Check status", "Disconnect"] {
        fatalError("Official channel actions must stay product-facing: \(actions)")
    }
    let expectedStatus = ["Not connected", "Device login pending", "Login available", "Route verified"]
    if ProviderFormLabels.officialChannelStatusLabels != expectedStatus {
        fatalError("Official channel status must be based on current login plus route proof: \(ProviderFormLabels.officialChannelStatusLabels)")
    }
    let productText = (ProviderFormLabels.officialChannelStatusLabels + actions).joined(separator: " ")
    for forbidden in ["Official auth not implemented", "Run isolated official passthrough check", "Open Codex Desktop", "Copy verification command", "Terminal", "manual proof"] {
        if productText.localizedCaseInsensitiveContains(forbidden) {
            fatalError("Official product sheet leaked debug/manual action: \(forbidden)")
        }
    }
}

func expectKeychainCredentialStore() throws {
    let service = "relaykit.validation.\(UUID().uuidString)"
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: "RelayKit",
    ]
    defer {
        SecItemDelete(query as CFDictionary)
    }
    try KeychainCredentialStore.save(value: "fixture-keychain-value", service: service)
    let value = try KeychainCredentialStore.load(service: service)
    if value != "fixture-keychain-value" {
        fatalError("Keychain credential store did not load expected fixture value")
    }
    try KeychainCredentialStore.delete(service: service)
    do {
        _ = try KeychainCredentialStore.load(service: service)
        fatalError("deleted Keychain credential remained readable")
    } catch ProviderConfigError.invalid {
    }
    let legacyService = "relaykit.validation.legacy.\(UUID().uuidString)"
    let legacyQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: legacyService,
    ]
    defer {
        SecItemDelete(legacyQuery as CFDictionary)
    }
    var addLegacy = legacyQuery
    addLegacy[kSecValueData as String] = Data("legacy-service-only-value".utf8)
    let addStatus = SecItemAdd(addLegacy as CFDictionary, nil)
    if addStatus != errSecSuccess {
        fatalError("failed to add legacy service-only Keychain item: \(addStatus)")
    }
    let legacyValue = try KeychainCredentialStore.load(service: legacyService)
    if legacyValue != "legacy-service-only-value" {
        fatalError("Keychain credential store did not load service-only fallback")
    }
}

func expectGatewayCredentialHandoff() throws {
    let config = Data(#"""
    {
      "providers": [
        {"credential_ref":{"kind":"keychain","value":"relaykit.provider.one"}},
        {"credential_ref":{"kind":"env","value":"RELAYKIT_ENV_KEY"}},
        {"credential_ref":{"kind":"keychain","value":"relaykit.provider.one"}},
        {"credential_ref":{"kind":"keychain","value":"relaykit.provider.missing"}}
      ]
    }
    """#.utf8)
    var loadedReferences: [String] = []
    let handoff = try GatewayCredentialHandoff.encode(configData: config) { reference in
        loadedReferences.append(reference)
        if reference == "relaykit.provider.missing" {
            throw ProviderConfigError.invalid("missing fixture")
        }
        return "fixture-value"
    }
    let object = try JSONSerialization.jsonObject(with: handoff)
    guard let root = object as? [String: Any],
          root["version"] as? Int == 1,
          let credentials = root["credentials"] as? [String: String],
          credentials == ["relaykit.provider.one": "fixture-value"] else {
        fatalError("gateway credential handoff payload is incorrect")
    }
    if loadedReferences != ["relaykit.provider.missing", "relaykit.provider.one"] {
        fatalError("gateway credential handoff must load each Keychain reference once in stable order: \(loadedReferences)")
    }
    if String(data: handoff, encoding: .utf8)?.contains("RELAYKIT_ENV_KEY") == true {
        fatalError("gateway credential handoff must not include non-Keychain references")
    }
}

func expectStatusPopoverAccessibilityContract() throws {
    let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/RelayKitApp/App/RelayKitApp.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    guard source.contains("final class RelayKitApp: NSObject, NSApplicationDelegate, NSPopoverDelegate"),
          source.contains("private let popover = NSPopover()"),
          source.contains("popover.delegate = self"),
          source.components(separatedBy: "relaykit-popover-root").count == 2,
          source.contains("func popoverDidShow") && source.contains("attachPopoverAccessibilityRoot()"),
          source.contains("func popoverDidClose") && source.contains("detachPopoverAccessibilityRoot()") else {
        fatalError("status popover AX delegate contract is missing")
    }
    guard let attachStart = source.range(of: "private func attachPopoverAccessibilityRoot()"),
          let detachStart = source.range(of: "private func detachPopoverAccessibilityRoot()", range: attachStart.upperBound..<source.endIndex),
          let terminateStart = source.range(of: "func applicationWillTerminate", range: detachStart.upperBound..<source.endIndex),
          let terminateEnd = source.range(of: "@objc private func togglePopover", range: terminateStart.upperBound..<source.endIndex) else {
        fatalError("status popover AX helper boundaries are missing")
    }
    let attach = source[attachStart.lowerBound..<detachStart.lowerBound]
    let detach = source[detachStart.lowerBound..<terminateStart.lowerBound]
    let termination = source[terminateStart.lowerBound..<terminateEnd.lowerBound]
    for required in ["statusItem.button", "popover.setAccessibilityElement(true)", "popover.setAccessibilityRole(.popover)", "popover.setAccessibilityIdentifier", "popover.setAccessibilityParent(button)", "button.setAccessibilityChildren([popover])"] {
        if !attach.contains(required) { fatalError("popover attach is missing \(required)") }
    }
    for required in ["setAccessibilityChildren([])", "popover.setAccessibilityParent(nil)"] {
        if !detach.contains(required) { fatalError("popover detach is missing \(required)") }
    }
    guard let detachCall = termination.range(of: "detachPopoverAccessibilityRoot()"),
          let gatewayStop = termination.range(of: "model.stopGateway()"),
          let authStop = termination.range(of: "model.stopOfficialAuthProcessForShutdown()"),
          detachCall.lowerBound < gatewayStop.lowerBound && gatewayStop.lowerBound < authStop.lowerBound else {
        fatalError("termination must detach popover AX linkage before shutdown")
    }
    for forbidden in ["ContentView", "ProviderForm", "Keychain", "Gateway", "NSPanel", "NSWindow", "accessibilityTitle", "accessibilityValue", "coordinate", "hitTest"] {
        if attach.contains(forbidden) || detach.contains(forbidden) { fatalError("popover AX helper must not use \(forbidden)") }
    }
    for required in ["togglePopover", "popover.show(relativeTo:", "popover.performClose", "showStatusMenu", "quitRelayKit", "addGlobalMonitorForEvents"] {
        if !source.contains(required) { fatalError("existing popover behavior regressed: \(required)") }
    }
}

try expectValid(validConfig)
try expectProviderDraftWriter()
try expectProviderDraftWriterWithPrototypeMetadata()
try expectProviderDraftWriterNormalizesPrefixedModels()
try expectProviderDraftWriterWithKeychainReference()
try expectProviderDraftWriterWithResponsesProtocol()
try expectProviderTestRequestContract()
try expectProviderTestEnumMapping()
expectProviderTestSaveActionIsIdempotent()
try expectProviderTestSinglePostLifecycle()
try expectResponsesConnectionUsesGatewayOnly()
try expectProviderModalAccessibilityContract()
expectProviderDraftRejectsCredentialValue()
try expectLocalCatalogSummary()
try expectCredentialRefContract()
try expectCapabilityContract()
expectAppSettingsPersistence()
expectProviderConfigPathRecoversStaleTemporaryPreference()
expectOfficialProofRootOverride()
expectProviderFormPresentationLabels()
expectExplicitUpstreamProtocolSelectionWins()
expectRedactedProviderSaveAndGatewayGuidance()
expectOfficialChannelPresentationLabels()
expectOfficialAuthURLSanitizer()
expectOfficialStatusFormatter()
expectProviderConnectionLabels()
expectProviderHealthLabels()
expectProviderConnectionClassification()
expectUsageAnalytics()
try expectKeychainCredentialStore()
try expectGatewayCredentialHandoff()
try expectStatusPopoverAccessibilityContract()
if RelayKitPaths.gatewayBinaryPath(bundle: Bundle(for: BundleSentinel.self)) != "../gateway/bin/relay" {
    fatalError("non-app bundle should fall back to development gateway path")
}
if !RelayKitPaths.providerConfigPath(bundle: Bundle(for: BundleSentinel.self)).hasSuffix("Library/Application Support/RelayKit/providers.json") {
    fatalError("provider config path should default to user app support")
}
if !RelayKitPaths.officialCredentialRefPath().hasSuffix("Library/Application Support/RelayKit/OfficialProof/official-credential.json") {
    fatalError("official credential reference should live in RelayKit App Support")
}
if RelayKitPaths.exampleProviderConfigPath(bundle: Bundle(for: BundleSentinel.self)) != "../examples/providers.example.json" {
    fatalError("non-app bundle should expose development example provider config path")
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
