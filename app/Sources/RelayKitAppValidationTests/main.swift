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
    if modelBody.contains("refreshModels()") ||
        !modelBody.contains("recordProviderTestResult(result)") ||
        !modelBody.contains("models.removeAll { $0.id == result.modelID }") ||
        !modelBody.contains("models.append(RelayModel(id: result.modelID, ownedBy: result.providerID))") {
        fatalError("typed provider-test result must update model availability without a second provider probe")
    }
    if !content.contains("ProviderTestSaveAction.resolve") {
        fatalError("add/import provider tests must use the idempotent save decision")
    }

    guard let saveStart = content.range(of: "private func save()"),
          let saveEnd = content.range(of: "private func field", range: saveStart.upperBound..<content.endIndex) else {
        fatalError("provider save function boundaries are missing")
    }
    let saveBody = content[saveStart.lowerBound..<saveEnd.lowerBound]
    if !saveBody.contains("case .add, .import:") ||
        !saveBody.contains("persistAddOrImportDraft()") ||
        !saveBody.contains("ProviderTestSaveAction.resolve") ||
        !saveBody.contains("model.updateProvider(originalProviderID") {
        fatalError("final Save must update a provider already persisted by Responses connection test")
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

func expectCodexCatalogMerge() throws {
    let official = Data(#"""
    {
      "catalog_revision": "current",
      "models": [
        {
          "slug": "gpt-official",
          "display_name": "GPT Official",
          "context_window": 128000,
          "supported_in_api": true,
          "service_tiers": ["standard"],
          "preserved_metadata": {"kind": "official"}
        }
      ]
    }
    """#.utf8)
    let gateway = Data(#"""
    {
      "data": [
        {"id": "provider/healthy", "owned_by": "provider", "display_name": "Healthy Provider"},
        {"id": "provider/hidden", "owned_by": "provider"}
      ],
      "model_health": {"hidden": [{"id": "provider/hidden", "reason": "unavailable"}]}
    }
    """#.utf8)
    let data = try CodexModelCatalog.merge(officialCatalog: official, gatewayModels: gateway, includeOfficialModels: true)
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          root["catalog_revision"] as? String == "current",
          let models = root["models"] as? [[String: Any]],
          models.count == 2,
          let officialModel = models.first,
          (officialModel["preserved_metadata"] as? [String: String])?["kind"] == "official",
          officialModel["supports_reasoning_summaries"] as? Bool == true,
          let provider = models.last,
          provider["slug"] as? String == "provider/healthy",
          provider["display_name"] as? String == "Healthy Provider",
          provider["context_window"] as? Int == 128000,
          provider["protocol"] as? String == "responses",
          provider["transport"] as? String == "local_relaykit",
          provider["supports_reasoning_summaries"] as? Bool == true,
          provider["supported_in_api"] as? Bool == true else {
        fatalError("Codex catalog merge did not preserve official metadata and add only healthy RelayKit models")
    }

    let duplicateGateway = Data(#"{"data":[{"id":"provider/healthy"},{"id":"provider/healthy"}]}"#.utf8)
    do {
        _ = try CodexModelCatalog.merge(officialCatalog: official, gatewayModels: duplicateGateway, includeOfficialModels: true)
        fatalError("duplicate healthy gateway model must fail catalog generation")
    } catch CodexModelCatalogError.duplicateGatewayModel("provider/healthy") {
    }

    let providerOnly = try CodexModelCatalog.merge(officialCatalog: official, gatewayModels: gateway, includeOfficialModels: false)
    let providerOnlyRoot = try JSONSerialization.jsonObject(with: providerOnly) as? [String: Any]
    let providerOnlyModels = providerOnlyRoot?["models"] as? [[String: Any]]
    if providerOnlyModels?.map({ $0["slug"] as? String }) != ["provider/healthy"] ||
        providerOnlyModels?.first?["supports_reasoning_summaries"] as? Bool != true {
        fatalError("provider-only catalog exposed unavailable official routes")
    }

    let explicitFalseOfficial = Data(#"""
    {
      "models": [
        {
          "slug": "gpt-explicit-false",
          "supports_reasoning_summaries": false
        }
      ]
    }
    """#.utf8)
    let explicitFalse = try CodexModelCatalog.merge(officialCatalog: explicitFalseOfficial, gatewayModels: gateway, includeOfficialModels: true)
    let explicitFalseRoot = try JSONSerialization.jsonObject(with: explicitFalse) as? [String: Any]
    let explicitFalseModels = explicitFalseRoot?["models"] as? [[String: Any]]
    if explicitFalseModels?.contains(where: { $0["supports_reasoning_summaries"] as? Bool != false }) != false {
        fatalError("catalog merge overwrote an explicit reasoning-summary capability")
    }

    let collidingGateway = Data(#"{"data":[{"id":"gpt-official","owned_by":"provider"}]}"#.utf8)
    let collidingProviderOnly = try CodexModelCatalog.merge(
        officialCatalog: official,
        gatewayModels: collidingGateway,
        includeOfficialModels: false
    )
    let collidingRoot = try JSONSerialization.jsonObject(with: collidingProviderOnly) as? [String: Any]
    let collidingModels = collidingRoot?["models"] as? [[String: Any]]
    if collidingModels?.first?["slug"] as? String != "gpt-official" {
        fatalError("provider-only catalog incorrectly dropped an Official-slug provider route")
    }

    let pendingHealth = Data(#"{"model_health":{"probed":false,"healthy":7,"unhealthy":0}}"#.utf8)
    let unhealthyHealth = Data(#"{"model_health":{"probed":true,"healthy":8,"unhealthy":1}}"#.utf8)
    let healthyHealth = Data(#"{"model_health":{"probed":true,"healthy":9,"unhealthy":0}}"#.utf8)
    if try !CodexModelCatalog.gatewayModelsNeedRetry(pendingHealth) ||
        !CodexModelCatalog.gatewayModelsNeedRetry(unhealthyHealth) ||
        CodexModelCatalog.gatewayModelsNeedRetry(healthyHealth) {
        fatalError("Codex catalog gateway health retry decision is incorrect")
    }

    let sixStateGateway = Data(#"""
    {
      "data": [
        {"id": "provider/reachable"},
        {"id": "provider/discovered"},
        {"id": "provider/temporary"},
        {"id": "provider/lkg"},
        {"id": "provider/stale"},
        {"id": "provider/hidden"}
      ],
      "model_health": {
        "configured": [
          {"id": "provider/reachable"}, {"id": "provider/discovered"}, {"id": "provider/temporary"},
          {"id": "provider/lkg"}, {"id": "provider/stale"}, {"id": "provider/hidden"}
        ],
        "discovered": [{"id": "provider/reachable"}, {"id": "provider/discovered"}],
        "route_reachable": [{"id": "provider/reachable"}],
        "temporarily_unavailable": [{"id": "provider/temporary", "reason": "auth failed"}],
        "hidden": [{"id": "provider/hidden", "reason": "route unavailable"}],
        "last_known_good": [
          {"id": "provider/lkg", "timestamp": "2026-07-24T00:00:00Z", "config_fingerprint": "matching", "stale": false},
          {"id": "provider/stale", "timestamp": "2026-07-24T00:00:00Z", "config_fingerprint": "old", "stale": true}
        ]
      }
    }
    """#.utf8)
    let sixState = try CodexModelCatalog.merge(officialCatalog: official, gatewayModels: sixStateGateway, includeOfficialModels: false)
    let sixStateRoot = try JSONSerialization.jsonObject(with: sixState) as? [String: Any]
    let sixStateModels = sixStateRoot?["models"] as? [[String: Any]] ?? []
    let sixStateByID = Dictionary(uniqueKeysWithValues: sixStateModels.compactMap { model in
        (model["slug"] as? String).map { ($0, model) }
    })
    guard sixStateByID.values.allSatisfy({ $0["status"] as? String == "ready" }),
          sixStateByID["provider/reachable"]?["relaykit_availability"] as? String == "route_reachable",
          sixStateByID["provider/discovered"]?["relaykit_availability"] as? String == "configured",
          sixStateByID["provider/temporary"]?["relaykit_availability"] as? String == "temporarily_unavailable",
          sixStateByID["provider/lkg"]?["relaykit_availability"] as? String == "last_known_good",
          sixStateByID["provider/stale"]?["relaykit_availability"] as? String == "configured",
          sixStateByID["provider/hidden"] == nil,
          (sixStateByID["provider/lkg"]?["description"] as? String)?.contains("last known good") == true,
          !(sixStateByID["provider/temporary"]?["description"] as? String ?? "").contains("auth failed") else {
        fatalError("catalog six-state/LKG projection lost configured visibility or claimed stale availability")
    }
}

func expectRuntimeSafetyStateContracts() {
    let startupHealthy = RuntimeSafetyReducer.transition(from: .disabled, event: .startupManagedRouteHealthy)
    guard startupHealthy.state == .protected, !startupHealthy.restartHelper, !startupHealthy.disableManagedFields, !startupHealthy.stopHelper else {
        fatalError("healthy stale-enabled startup must adopt the helper as Protected without churn")
    }

    let startupUnhealthy = RuntimeSafetyReducer.transition(from: .disabled, event: .startupManagedRouteUnhealthy)
    guard startupUnhealthy.state == .recovering, startupUnhealthy.restartHelper, !startupUnhealthy.disableManagedFields, !startupUnhealthy.stopHelper else {
        fatalError("unhealthy stale-enabled startup must begin exactly one bounded recovery")
    }

    let unexpectedExit = RuntimeSafetyReducer.transition(from: .protected, event: .helperExited)
    guard unexpectedExit.state == .recovering, unexpectedExit.restartHelper, !unexpectedExit.disableManagedFields, !unexpectedExit.stopHelper else {
        fatalError("unexpected managed helper exit must request one recovery restart")
    }

    let restartSuccess = RuntimeSafetyReducer.transition(from: .recovering, event: .helperRestartSucceeded)
    guard restartSuccess.state == .protected, !restartSuccess.restartHelper, !restartSuccess.disableManagedFields, !restartSuccess.stopHelper else {
        fatalError("healthy recovery restart must return to Protected")
    }

    let retryFailure = RuntimeSafetyReducer.transition(from: .recovering, event: .helperRestartFailed)
    guard retryFailure.state == .recovering, !retryFailure.restartHelper, retryFailure.disableManagedFields, !retryFailure.stopHelper else {
        fatalError("failed bounded retry must request managed field restoration")
    }

    let disableSuccess = RuntimeSafetyReducer.transition(from: retryFailure.state, event: .managedFieldsDisabled(helperIsRunning: true))
    guard disableSuccess.state == .disabled, !disableSuccess.restartHelper, !disableSuccess.disableManagedFields, disableSuccess.stopHelper else {
        fatalError("failed retry plus safe disable must become Disabled")
    }

    let disableFailure = RuntimeSafetyReducer.transition(from: retryFailure.state, event: .managedFieldsCouldNotBeRestored(helperIsRunning: true))
    guard disableFailure.state == .atRisk, !disableFailure.restartHelper, !disableFailure.disableManagedFields, !disableFailure.stopHelper else {
        fatalError("failed restore must remain At risk instead of claiming a dead route is safe")
    }

    let activationHealthFailure = RuntimeSafetyReducer.transition(from: .protected, event: .managedRouteHealthFailed)
    guard activationHealthFailure.state == .recovering, activationHealthFailure.restartHelper, !activationHealthFailure.disableManagedFields else {
        fatalError("managed route health failure must enter the same bounded recovery restart path")
    }

    let intentionalShutdown = RuntimeSafetyReducer.transition(from: .protected, event: .intentionalShutdown)
    guard intentionalShutdown.state == .protected, !intentionalShutdown.restartHelper, !intentionalShutdown.disableManagedFields, !intentionalShutdown.stopHelper else {
        fatalError("intentional shutdown must never request a helper restart")
    }
}

func expectRuntimeSafetyEndpointContract() throws {
    let product = try RelayKitRuntimeEndpoint.resolve(environment: [:])
    guard product.port == 19777,
          product.listenAddress == "127.0.0.1:19777",
          product.httpBaseURL.absoluteString == "http://127.0.0.1:19777",
          product.codexBaseURL.absoluteString == "http://127.0.0.1:19777/v1" else {
        fatalError("default runtime endpoint must remain exactly 127.0.0.1:19777")
    }

    let isolated = try RelayKitRuntimeEndpoint.resolve(environment: [
        "RELAYKIT_RUNTIME_SAFETY_TEST": "1",
        "RELAYKIT_RUNTIME_SAFETY_PORT": "19790",
    ])
    guard isolated.port == 19790,
          isolated.listenAddress == "127.0.0.1:19790",
          isolated.httpBaseURL.absoluteString == "http://127.0.0.1:19790",
          isolated.codexBaseURL.absoluteString == "http://127.0.0.1:19790/v1" else {
        fatalError("valid runtime safety endpoint did not remain loopback-only")
    }

    let ignoredTestEnvironment = try RelayKitRuntimeEndpoint.resolve(environment: [
        "RELAYKIT_RUNTIME_SAFETY_TEST": "0",
        "RELAYKIT_RUNTIME_SAFETY_PORT": "18787",
    ])
    if ignoredTestEnvironment != product {
        fatalError("runtime endpoint override must require RELAYKIT_RUNTIME_SAFETY_TEST=1")
    }

    let invalidEnvironments: [[String: String]] = [
        ["RELAYKIT_RUNTIME_SAFETY_TEST": "1"],
        ["RELAYKIT_RUNTIME_SAFETY_TEST": "1", "RELAYKIT_RUNTIME_SAFETY_PORT": "not-a-port"],
        ["RELAYKIT_RUNTIME_SAFETY_TEST": "1", "RELAYKIT_RUNTIME_SAFETY_PORT": "1023"],
        ["RELAYKIT_RUNTIME_SAFETY_TEST": "1", "RELAYKIT_RUNTIME_SAFETY_PORT": "65536"],
        ["RELAYKIT_RUNTIME_SAFETY_TEST": "1", "RELAYKIT_RUNTIME_SAFETY_PORT": "18787"],
        ["RELAYKIT_RUNTIME_SAFETY_TEST": "1", "RELAYKIT_RUNTIME_SAFETY_PORT": "19777"],
    ]
    for environment in invalidEnvironments {
        do {
            _ = try RelayKitRuntimeEndpoint.resolve(environment: environment)
            fatalError("invalid runtime safety endpoint was accepted: \(environment)")
        } catch {
            let message = error.localizedDescription
            if message != "RelayKit runtime safety test endpoint is invalid." ||
                environment.values.contains(where: message.contains) {
                fatalError("runtime safety endpoint error must fail closed without leaking input: \(message)")
            }
        }
    }

    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let endpoint = try String(contentsOf: root.appendingPathComponent("Sources/RelayKitCore/RelayKitRuntimeEndpoint.swift"), encoding: .utf8)
    let gateway = try String(contentsOf: root.appendingPathComponent("Sources/RelayKitApp/Services/GatewayProcess.swift"), encoding: .utf8)
    let client = try String(contentsOf: root.appendingPathComponent("Sources/RelayKitApp/Services/GatewayClient.swift"), encoding: .utf8)
    let verifier = try String(contentsOf: root.appendingPathComponent("Sources/RelayKitApp/Services/BundledGatewayVerifier.swift"), encoding: .utf8)
    let appModel = try String(contentsOf: root.appendingPathComponent("Sources/RelayKitApp/Stores/AppModel.swift"), encoding: .utf8)
    let content = try String(contentsOf: root.appendingPathComponent("Sources/RelayKitApp/Views/ContentView.swift"), encoding: .utf8)
    let app = try String(contentsOf: root.appendingPathComponent("Sources/RelayKitApp/App/RelayKitApp.swift"), encoding: .utf8)

    for required in [
        "RELAYKIT_RUNTIME_SAFETY_TEST",
        "RELAYKIT_RUNTIME_SAFETY_PORT",
        "static let productPort = 19777",
        "static let host = \"127.0.0.1\"",
        "guard environment[\"RELAYKIT_RUNTIME_SAFETY_TEST\"] == \"1\" else",
        "return product",
        "(1024...65535).contains(port)",
        "static func isProtectedPort",
        "port == 18787",
        "port == productPort",
        "!isProtectedPort(port)",
        "RelayKit runtime safety test endpoint is invalid.",
        "var listenAddress: String",
        "var httpBaseURL: URL",
        "var codexBaseURL: URL",
    ] {
        if !endpoint.contains(required) {
            fatalError("runtime endpoint resolver contract missing \(required)")
        }
    }
    for forbidden in ["RELAYKIT_RUNTIME_SAFETY_HOST", "RELAYKIT_RUNTIME_SAFETY_BASE_URL", "URLComponents"] {
        if endpoint.contains(forbidden) {
            fatalError("runtime endpoint resolver must not accept a configurable host or base URL: \(forbidden)")
        }
    }
    for required in ["endpoint.listenAddress", "-base-url", "endpoint.codexBaseURL.absoluteString"] {
        if !gateway.contains(required) {
            fatalError("gateway endpoint contract missing \(required)")
        }
    }
    for required in ["init(endpoint: RelayKitRuntimeEndpoint)", "endpoint.httpBaseURL"] {
        if !client.contains(required) {
            fatalError("gateway client endpoint contract missing \(required)")
        }
    }
    for required in ["try RelayKitRuntimeEndpoint.resolve()", "endpoint.httpBaseURL"] {
        if !verifier.contains(required) {
            fatalError("bundled verifier endpoint contract missing \(required)")
        }
    }
    for required in ["let runtimeEndpoint: RelayKitRuntimeEndpoint", "init(endpoint: RelayKitRuntimeEndpoint)", "GatewayProcess(endpoint: endpoint)", "GatewayClient(endpoint: endpoint)", "runtimeEndpoint.listenAddress"] {
        if !appModel.contains(required) {
            fatalError("AppModel endpoint contract missing \(required)")
        }
    }
    for required in ["let endpoint: RelayKitRuntimeEndpoint", "try RelayKitRuntimeEndpoint.resolve()", "RelayKit runtime safety test endpoint is invalid.", "exit(2)", "RelayKitApp(endpoint: endpoint)", "model.runtimeEndpoint.listenAddress"] {
        if !app.contains(required) {
            fatalError("App entrypoint fail-closed contract missing \(required)")
        }
    }
    if appModel.contains(".product") || appModel.contains("RelayKitRuntimeEndpoint.resolve()") || app.contains("AppModel()") {
        fatalError("invalid runtime endpoint must not construct a product fallback AppModel, client, or gateway")
    }
    for required in ["model.runtimeEndpoint.port", "model.runtimeEndpoint.listenAddress"] {
        if !content.contains(required) {
            fatalError("port label endpoint contract missing \(required)")
        }
    }
    for source in [gateway, client, verifier, appModel, content, app] {
        if source.contains("19777") {
            fatalError("runtime endpoint must not retain a split-brain 19777 hardcode")
        }
    }
}

func expectRuntimeSafetyLifecycleSourceContracts() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let appModel = try String(contentsOf: root.appendingPathComponent("Sources/RelayKitApp/Stores/AppModel.swift"), encoding: .utf8)
    let gateway = try String(contentsOf: root.appendingPathComponent("Sources/RelayKitApp/Services/GatewayProcess.swift"), encoding: .utf8)
    let backgroundService = try String(contentsOf: root.appendingPathComponent("Sources/RelayKitApp/Services/GatewayBackgroundService.swift"), encoding: .utf8)
    let bundledVerifier = try String(contentsOf: root.appendingPathComponent("Sources/RelayKitApp/Services/BundledGatewayVerifier.swift"), encoding: .utf8)
    let content = try String(contentsOf: root.appendingPathComponent("Sources/RelayKitApp/Views/ContentView.swift"), encoding: .utf8)
    let agentPlist = try String(contentsOf: root.appendingPathComponent("Resources/dev.relaykit.gateway.plist"), encoding: .utf8)
    let bundleScript = try String(contentsOf: root.deletingLastPathComponent().appendingPathComponent("script/build_app_bundle.sh"), encoding: .utf8)
    let packageScript = try String(contentsOf: root.deletingLastPathComponent().appendingPathComponent("script/package_release.sh"), encoding: .utf8)

    for required in [
        "@Published private(set) var runtimeSafetyState: RuntimeSafetyState = .disabled",
        "await beginManagedGatewayRecovery(event: .managedRouteHealthFailed, officialCatalog: lastOfficialCatalog)",
        "await beginManagedGatewayRecovery(event: .helperExited, officialCatalog: lastOfficialCatalog)",
        "if gateway.isRunning {\n            gateway.stop()",
        "startGateway(officialCatalog: officialCatalog)",
        "let disabled = applyRuntimeSafety(event: .managedFieldsDisabled(helperIsRunning: gateway.isRunning))",
        "if disabled.stopHelper {\n                gateway.stop()",
        "gatewayStatus = gateway.isRunning ? \"running\" : \"stopped\"",
        "lastOfficialCatalog",
        "GatewayBackgroundService().ensureRegisteredIfPackaged()",
        "gateway.holdControlOwnerLease(at: controlTokenPath)",
        "beginGatewayServiceMonitorIfNeeded()",
        "healthMode()",
    ] {
        if !appModel.contains(required) { fatalError("runtime safety lifecycle contract missing \(required)") }
    }
    if appModel.contains("startupRouteReachableButUnowned") {
        fatalError("startup health contract must retain Protected adoption without an unowned-listener expansion")
    }
    for required in ["@MainActor\nfinal class GatewayProcess", "-managed-codex-target", "-managed-codex-state", "launchdManaged", "usesManagedService", "managedRouteEnabled: Bool = true", "private(set) var expectedServiceMode", "-route-enabled=\\(managedRouteEnabled ? \"true\" : \"false\")", "\"release\"", "Task { @MainActor", "process.terminationHandler = nil", "func holdControlOwnerLease(at path: String) throws", "O_EXLOCK | O_NONBLOCK", "func restartDataPlane() throws", "func leaveRunningForFallback() throws", "nonisolated static func summarizeUsage", "nonisolated static func runGatewayCommand", "nonisolated static func appDirectory", "GatewayTerminationRelay: @unchecked Sendable"] {
        if !gateway.contains(required) { fatalError("gateway lifecycle safety contract missing \(required)") }
    }
    guard let tokenPath = appModel.range(of: "let controlTokenPath = try ensureGatewayControlToken()"),
          let ownerLease = appModel.range(of: "try gateway.holdControlOwnerLease(at: controlTokenPath)", range: tokenPath.upperBound..<appModel.endIndex),
          let routeStatus = appModel.range(of: "let managedRouteEnabled = managedCodexRouteStatus() == \"enabled\"", range: ownerLease.upperBound..<appModel.endIndex),
          let serviceRegistration = appModel.range(of: "GatewayBackgroundService().ensureRegisteredIfPackaged()", range: routeStatus.upperBound..<appModel.endIndex),
          tokenPath.lowerBound < ownerLease.lowerBound && ownerLease.lowerBound < routeStatus.lowerBound && routeStatus.lowerBound < serviceRegistration.lowerBound else {
        fatalError("App must hold the control-token owner lease before reading route state or starting launchd")
    }
    for required in ["let managedRouteEnabled = managedCodexRouteStatus() == \"enabled\"", "managedRouteEnabled: managedRouteEnabled", "mode != self.gateway.expectedServiceMode"] {
        if !appModel.contains(required) {
            fatalError("two-epoch App route-mode contract missing \(required)")
        }
    }
    for required in ["SMAppService.agent(plistName:", "case .requiresApproval:", "System Settings > General > Login Items", "return false"] {
        if !backgroundService.contains(required) {
            fatalError("background service fail-closed contract missing \(required)")
        }
    }
    for required in ["<key>BundleProgram</key>", "<string>Contents/MacOS/relay</string>", "<key>RunAtLoad</key>", "<key>ThrottleInterval</key>", "<integer>1</integer>", "<key>Sockets</key>", "<key>RelayKitGateway</key>", "<string>127.0.0.1</string>", "<string>19777</string>"] {
        if !agentPlist.contains(required) {
            fatalError("background gateway plist contract missing \(required)")
        }
    }
    for forbidden in ["credential", "auth.json", "StandardOutPath", "StandardErrorPath", "18787"] {
        if agentPlist.localizedCaseInsensitiveContains(forbidden) {
            fatalError("background gateway plist must not contain \(forbidden)")
        }
    }
    guard bundleScript.contains("APP_LAUNCH_AGENTS="),
          bundleScript.contains("dev.relaykit.gateway.plist") else {
        fatalError("App bundle must embed the RelayKit-owned background gateway plist")
    }
    for script in [bundleScript, packageScript] {
        guard script.contains("select_isolated_verify_port"),
              script.contains("RELAYKIT_RUNTIME_SAFETY_TEST=1"),
              script.contains("RELAYKIT_RUNTIME_SAFETY_PORT=") else {
            fatalError("bundled gateway verification must use an isolated non-product endpoint")
        }
    }
    guard let startBegin = gateway.range(of: "func start("),
          let startEnd = gateway.range(of: "func makeStartProcess", range: startBegin.upperBound..<gateway.endIndex) else {
        fatalError("gateway start implementation is missing")
    }
    let longLivedStart = String(gateway[startBegin.lowerBound..<startEnd.lowerBound])
    guard longLivedStart.contains("process.standardOutput = FileHandle.nullDevice"),
          longLivedStart.contains("process.standardError = FileHandle.nullDevice") else {
        fatalError("long-lived gateway output must use App-independent stable sinks")
    }
    if longLivedStart.contains("process.standardOutput = Pipe()") ||
        longLivedStart.contains("process.standardError = Pipe()") {
        fatalError("long-lived gateway output must not use undrained App-owned pipes")
    }
    if gateway.contains("final class GatewayProcess: @unchecked Sendable") || !bundledVerifier.contains("@MainActor\nenum BundledGatewayVerifier") {
        fatalError("GatewayProcess actor isolation or bundled verifier actor contract regressed")
    }
    guard let stopStart = gateway.range(of: "func stop()"),
          let stopEnd = gateway.range(of: "func enableCodexConfig", range: stopStart.upperBound..<gateway.endIndex),
          let detach = gateway.range(of: "process.terminationHandler = nil", range: stopStart.upperBound..<stopEnd.lowerBound),
          let terminate = gateway.range(of: "terminateAndReap(process)", range: detach.upperBound..<stopEnd.lowerBound),
          detach.lowerBound < terminate.lowerBound else {
        fatalError("intentional gateway stop must detach terminationHandler before stopping")
    }
    guard let fallbackStart = gateway.range(of: "func leaveRunningForFallback() throws"),
          let fallbackEnd = gateway.range(of: "func enableCodexConfig", range: fallbackStart.upperBound..<gateway.endIndex),
          let fallbackBody = gateway.range(of: "process.terminationHandler = nil", range: fallbackStart.upperBound..<fallbackEnd.lowerBound),
          !gateway[fallbackStart.lowerBound..<fallbackEnd.lowerBound].contains("terminateAndReap") else {
        fatalError("fallback handoff must detach App ownership without terminating the data plane")
    }
    _ = fallbackBody
    guard let restartStart = appModel.range(of: "func restartGateway()"),
          let restartEnd = appModel.range(of: "func refreshHealth()", range: restartStart.upperBound..<appModel.endIndex) else {
        fatalError("gateway restart implementation is missing")
    }
    let restartBody = appModel[restartStart.lowerBound..<restartEnd.lowerBound]
    guard restartBody.contains("try gateway.restartDataPlane()"),
          !restartBody.contains("stopGateway()"),
          restartBody.contains("gateway.disableCodexConfig") else {
        fatalError("gateway restart must preserve the managed epoch and fail closed if replacement startup fails")
    }
    if !content.contains("Route safety: \\(model.runtimeSafetyState.rawValue)") {
        fatalError("Codex surface must show the observable runtime safety state")
    }
}

func expectCodexCatalogProcessDrainContract() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let source = try String(
        contentsOf: root.appendingPathComponent("Sources/RelayKitApp/Services/CodexCatalogBuilder.swift"),
        encoding: .utf8
    )
    guard source.contains("process.standardError = FileHandle.nullDevice") else {
        fatalError("Codex catalog stderr must not corrupt JSON output")
    }
    guard let drain = source.range(of: "readDataToEndOfFile()"),
          let wait = source.range(of: "process.waitUntilExit()"),
          drain.lowerBound < wait.lowerBound else {
        fatalError("Codex catalog output must be drained before waiting so a large catalog cannot deadlock")
    }
    guard source.contains(".local/bin/codex"),
          source.contains("FileManager.default.isExecutableFile") else {
        fatalError("Codex catalog builder must use a controlled installed-CLI fallback")
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
    let historicalDist = "/opt/relaykit-fixture/RelayKit/dist/signed-beta-v0.1.0/run/runtime/providers.json"
    let resolvedHistoricalDist = RelayKitPaths.resolvedProviderConfigPath(savedPath: historicalDist) { $0 == historicalDist }
    if resolvedHistoricalDist != RelayKitPaths.providerConfigPath() {
        fatalError("historical RelayKit dist provider config should recover to App Support: \(resolvedHistoricalDist)")
    }
    let desktopProof = "/opt/relaykit-fixture/Library/Application Support/RelayKit/DesktopProof/home/Library/Application Support/RelayKit/providers.json"
    let resolvedDesktopProof = RelayKitPaths.resolvedProviderConfigPath(savedPath: desktopProof) { $0 == desktopProof }
    if resolvedDesktopProof != RelayKitPaths.providerConfigPath() {
        fatalError("DesktopProof provider config should recover to App Support: \(resolvedDesktopProof)")
    }
    let unrelatedDist = "/opt/relaykit-fixture/AnotherProject/dist/providers.json"
    let preservedUnrelatedDist = RelayKitPaths.resolvedProviderConfigPath(savedPath: unrelatedDist) { $0 == unrelatedDist }
    if preservedUnrelatedDist != unrelatedDist {
        fatalError("unrelated dist provider config should remain explicit: \(preservedUnrelatedDist)")
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

func expectGatewayDisplayStateContract() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let appModel = try String(contentsOf: root.appendingPathComponent("Sources/RelayKitApp/Stores/AppModel.swift"), encoding: .utf8)
    let content = try String(contentsOf: root.appendingPathComponent("Sources/RelayKitApp/Views/ContentView.swift"), encoding: .utf8)

    for required in [
        "enum GatewayDisplayState: String",
        "case stopped = \"Stopped\"",
        "case running = \"Running\"",
        "case error = \"Error\"",
        "case \"ok\", \"running\":",
        "case \"stopped\":",
        "var gatewayDisplayState: GatewayDisplayState",
        "GatewayDisplayState(rawGatewayHealth: gatewayStatus)",
    ] {
        if !appModel.contains(required) {
            fatalError("gateway display state contract is missing \(required)")
        }
    }

    if content.contains("model.gatewayStatus") || content.contains("productGatewayState") {
        fatalError("ContentView must use the AppModel gateway display state instead of raw health")
    }
    for required in [
        "Label(model.gatewayDisplayState.rawValue",
        "summaryChip(\"Gateway\", model.gatewayDisplayState.rawValue)",
        "let displayState = model.gatewayDisplayState",
        "settingsInfoRow(title: \"Gateway status\", subtitle: model.gatewayDisplayState.rawValue)",
    ] {
        if !content.contains(required) {
            fatalError("gateway display state is not wired into every product surface: \(required)")
        }
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

func expectOfficialChannelPresentationLabels() throws {
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

    let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/RelayKitApp/Views/ContentView.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    guard let rowStart = source.range(of: "private var officialProviderRow: some View"),
          let sheetStart = source.range(of: "private var officialChannelSheet: some View", range: rowStart.upperBound..<source.endIndex) else {
        fatalError("Official provider row boundaries are missing")
    }
    let row = source[rowStart.lowerBound..<sheetStart.lowerBound]
    for required in [
        "Image(systemName: officialCurrentStatusIcon)",
        ".foregroundStyle(officialCurrentStatusColor)",
        "officialSnapshot.status.rawValue",
    ] {
        if !row.contains(required) {
            fatalError("Official provider row does not expose current auth state: \(required)")
        }
    }
    if row.contains("Image(systemName: \"checkmark.seal\")") {
        fatalError("Official provider row retained a false-positive static checkmark")
    }
    if source.components(separatedBy: ".frame(width: 444)").count - 1 != 2 ||
        source.contains(".frame(width: 484)") {
        fatalError("Popover overlays must fit the 480-point compact width")
    }
    for required in [
        "private var tabContent: some View",
        "case .connect:\n            ScrollView",
        "connectTab\n                    .padding(18)",
        "case .usage:\n            ScrollView",
        "case .settings:\n            ScrollView",
        "private var officialActionSection: some View",
        "private var officialSheetDetails: some View",
        ".frame(maxHeight: officialDetailsExpanded ? 340 : 210)",
        ".accessibilityIdentifier(\"official-details-scroll-container\")",
    ] where !source.contains(required) {
        fatalError("compact overflow contract is missing: \(required)")
    }
}

func expectOfficialChannelSnapshots() {
    let noEvidence = OfficialRouteEvidence(
        gatewayRunning: false,
        currentRun: false,
        loginStatusMatches: false,
        currentOfficialEventFound: false,
        currentProviderEventFound: false,
        appExecutableHashMatches: false,
        providerConfigHashMatches: false,
        appProcessMatches: false,
        gatewayProcessMatches: false
    )
    let notConnected = OfficialChannelSnapshot.resolve(loggedIn: false, authInProgress: false, routeEvidence: noEvidence, detail: "fixture")
    if notConnected.status != .notConnected || notConnected.primaryActionDisabled {
        fatalError("not connected snapshot regressed")
    }
    let pending = OfficialChannelSnapshot.resolve(loggedIn: false, authInProgress: true, routeEvidence: noEvidence, detail: "fixture")
    if pending.status != .deviceLoginPending || !pending.primaryActionDisabled {
        fatalError("pending snapshot regressed")
    }
    let loginAvailable = OfficialChannelSnapshot.resolve(loggedIn: true, authInProgress: false, routeEvidence: noEvidence, detail: "fixture")
    if loginAvailable.status != .loginAvailable || !loginAvailable.isConnected || !loginAvailable.primaryActionDisabled {
        fatalError("login available snapshot regressed")
    }
    let currentEvidence = OfficialRouteEvidence(
        gatewayRunning: true,
        currentRun: true,
        loginStatusMatches: true,
        currentOfficialEventFound: true,
        currentProviderEventFound: true,
        appExecutableHashMatches: true,
        providerConfigHashMatches: true,
        appProcessMatches: true,
        gatewayProcessMatches: true
    )
    let verified = OfficialChannelSnapshot.resolve(loggedIn: true, authInProgress: false, routeEvidence: currentEvidence, detail: "fixture")
    if verified.status != .routeVerified || !verified.isConnected || !verified.primaryActionDisabled {
        fatalError("verified snapshot regressed")
    }
    let staleGateway = OfficialRouteEvidence(
        gatewayRunning: false,
        currentRun: true,
        loginStatusMatches: true,
        currentOfficialEventFound: true,
        currentProviderEventFound: true,
        appExecutableHashMatches: true,
        providerConfigHashMatches: true,
        appProcessMatches: true,
        gatewayProcessMatches: true
    )
    if OfficialChannelSnapshot.resolve(loggedIn: true, authInProgress: false, routeEvidence: staleGateway, detail: "fixture").status != .loginAvailable {
        fatalError("stale or stopped gateway must remain login available")
    }
    let staleProcess = OfficialRouteEvidence(
        gatewayRunning: true,
        currentRun: true,
        loginStatusMatches: true,
        currentOfficialEventFound: true,
        currentProviderEventFound: true,
        appExecutableHashMatches: true,
        providerConfigHashMatches: true,
        appProcessMatches: false,
        gatewayProcessMatches: true
    )
    if OfficialChannelSnapshot.resolve(loggedIn: true, authInProgress: false, routeEvidence: staleProcess, detail: "fixture").status != .loginAvailable {
        fatalError("process-mismatched route evidence must remain login available")
    }
    let staleTimestamp = OfficialRouteEvidence(
        gatewayRunning: true, currentRun: true, loginStatusMatches: true,
        currentOfficialEventFound: true, currentProviderEventFound: true,
        appExecutableHashMatches: true, providerConfigHashMatches: true,
        appProcessMatches: true, gatewayProcessMatches: true,
        evidenceFreshForProcesses: false
    )
    if OfficialChannelSnapshot.resolve(loggedIn: true, authInProgress: false, routeEvidence: staleTimestamp, detail: "fixture").status != .loginAvailable {
        fatalError("pre-launch route evidence must remain login available")
    }
}

func expectProviderSaveTransactions() throws {
    enum FixtureError: Error { case injected }
    var config = Data("original".utf8)
    var credential: String? = "old-key"
    let keychainFailure = ProviderSaveTransaction.Dependencies(
        loadCredential: { _ in
            guard let credential else { throw FixtureError.injected }
            return credential
        },
        saveCredential: { _, _ in throw FixtureError.injected },
        deleteCredential: { _ in credential = nil },
        writeConfig: { config = $0 },
        readConfig: { config },
        restoreConfig: { config = $0 ?? Data() },
        reloadConfig: {}
    )
    do {
        try ProviderSaveTransaction.commit(
            proposedConfig: Data("new".utf8), originalConfig: config,
            credential: .init(service: "fixture", value: "new-key"), dependencies: keychainFailure
        )
        fatalError("injected Keychain failure unexpectedly committed")
    } catch {
        if config != Data("original".utf8) || credential != "old-key" {
            fatalError("Keychain failure changed config or credential")
        }
    }

    config = Data("original".utf8)
    credential = nil
    let addWriteFailure = ProviderSaveTransaction.Dependencies(
        loadCredential: { _ in nil },
        saveCredential: { _, value in credential = value },
        deleteCredential: { _ in credential = nil },
        writeConfig: { _ in throw FixtureError.injected },
        readConfig: { config },
        restoreConfig: { config = $0 ?? Data() },
        reloadConfig: {}
    )
    do {
        try ProviderSaveTransaction.commit(
            proposedConfig: Data("new".utf8), originalConfig: config,
            credential: .init(service: "fixture", value: "new-key"), dependencies: addWriteFailure
        )
        fatalError("injected add write failure unexpectedly committed")
    } catch {
        if config != Data("original".utf8) || credential != nil {
            fatalError("add write failure did not roll back config and new credential")
        }
    }

    config = Data("original".utf8)
    credential = "old-key"
    let updateReadbackFailure = ProviderSaveTransaction.Dependencies(
        loadCredential: { _ in
            guard let credential else { throw FixtureError.injected }
            return credential
        },
        saveCredential: { _, value in credential = value },
        deleteCredential: { _ in credential = nil },
        writeConfig: { config = $0 },
        readConfig: { Data("mismatch".utf8) },
        restoreConfig: { config = $0 ?? Data() },
        reloadConfig: {}
    )
    do {
        try ProviderSaveTransaction.commit(
            proposedConfig: Data("new".utf8), originalConfig: config,
            credential: .init(service: "fixture", value: "new-key"), dependencies: updateReadbackFailure
        )
        fatalError("injected update readback failure unexpectedly committed")
    } catch {
        if config != Data("original".utf8) || credential != "old-key" {
            fatalError("update readback failure did not restore original config and key")
        }
    }

    config = Data("original".utf8)
    credential = "old-key"
    var reloadCount = 0
    let updateReloadFailure = ProviderSaveTransaction.Dependencies(
        loadCredential: { _ in credential },
        saveCredential: { _, value in credential = value },
        deleteCredential: { _ in credential = nil },
        writeConfig: { config = $0 },
        readConfig: { config },
        restoreConfig: { config = $0 ?? Data() },
        reloadConfig: {
            reloadCount += 1
            if reloadCount == 1 { throw FixtureError.injected }
        }
    )
    do {
        try ProviderSaveTransaction.commit(
            proposedConfig: Data("new".utf8), originalConfig: config,
            credential: .init(service: "fixture", value: "new-key"), dependencies: updateReloadFailure
        )
        fatalError("injected update reload failure unexpectedly committed")
    } catch {
        if config != Data("original".utf8) || credential != "old-key" || reloadCount != 2 {
            fatalError("update reload failure did not restore config, key, and runtime reload")
        }
    }

    config = Data("original".utf8)
    credential = "old-key"
    var rollbackAttempts: [String] = []
    let allRollbackFailures = ProviderSaveTransaction.Dependencies(
        loadCredential: { _ in credential },
        saveCredential: { _, value in
            if value == "new-key" { credential = value; return }
            rollbackAttempts.append("credential")
            throw FixtureError.injected
        },
        deleteCredential: { _ in rollbackAttempts.append("delete") },
        writeConfig: { _ in throw FixtureError.injected },
        readConfig: { config },
        restoreConfig: { _ in rollbackAttempts.append("config"); throw FixtureError.injected },
        reloadConfig: { rollbackAttempts.append("reload"); throw FixtureError.injected }
    )
    do {
        try ProviderSaveTransaction.commit(
            proposedConfig: Data("new".utf8), originalConfig: config,
            credential: .init(service: "fixture", value: "new-key"), dependencies: allRollbackFailures
        )
        fatalError("injected rollback failures unexpectedly committed")
    } catch {
        if rollbackAttempts != ["config", "credential", "reload"] {
            fatalError("rollback did not attempt every independent compensation: \(rollbackAttempts)")
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

func expectSignedBetaAppContracts() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let appModel = try String(contentsOf: root.appendingPathComponent("Sources/RelayKitApp/Stores/AppModel.swift"), encoding: .utf8)
    let gateway = try String(contentsOf: root.appendingPathComponent("Sources/RelayKitApp/Services/GatewayProcess.swift"), encoding: .utf8)
    let content = try String(contentsOf: root.appendingPathComponent("Sources/RelayKitApp/Views/ContentView.swift"), encoding: .utf8)
    let app = try String(contentsOf: root.appendingPathComponent("Sources/RelayKitApp/App/RelayKitApp.swift"), encoding: .utf8)

    for required in [
        "func startGatewayOnOrdinaryLaunch()",
        "await refreshModels(officialCatalog: officialCatalog)",
        "func reconcileGatewayAfterOfficialStatusChange(wasConnected: Bool)",
        "wasConnected != officialSnapshot.isConnected, gateway.isRunning",
        "reconcileGatewayAfterOfficialStatusChange(wasConnected: wasConnected)",
        "func reloadGatewayAfterProviderConfigChange() throws",
        "func enableCodexForDesktop() async",
        "func disableCodexForDesktop() async",
        "func rebuildCodexCatalog(gatewayModels snapshot: Data? = nil, officialCatalog: Data? = nil) async throws",
        "let gatewayModels = try await client.modelListData()",
        "await rebuildCodexCatalogIfEnabled(gatewayModels: gatewayModels, officialCatalog: officialCatalog)",
        "func gatewayModelsForCodexCatalog() async throws",
        "try configuredProvidersExist()",
        "try CodexModelCatalog.gatewayModelsNeedRetry(models)",
        "Task.sleep(nanoseconds: 700_000_000)",
        "OfficialCodexAuthState.isConnected(at: authURL)",
        "let providers = root[\"providers\"] as? [[String: Any]]",
        "includeOfficialModels: includeOfficial",
        "var codexIntegrationHasManagedState: Bool",
        "RelayKitPaths.defaultCodexConfigPath()",
        "RelayKitPaths.codexCatalogPath()",
        "RelayKitPaths.codexConfigStatePath()",
    ] {
        if !appModel.contains(required) { fatalError("Signed Beta App contract missing \(required)") }
    }
    if appModel.components(separatedBy: "reconcileGatewayAfterOfficialStatusChange(wasConnected: wasConnected)").count - 1 < 2 {
        fatalError("Official status refresh and explicit disconnect must both reconcile the running gateway")
    }
    guard let initializerStart = appModel.range(of: "    init(endpoint: RelayKitRuntimeEndpoint) {"),
          let initializerEnd = appModel.range(of: "    func useTemporaryProviderConfigPath", range: initializerStart.upperBound..<appModel.endIndex) else {
        fatalError("AppModel initializer contract is missing")
    }
    let initializer = appModel[initializerStart.lowerBound..<initializerEnd.lowerBound]
    if !initializer.contains("loadOfficialAuthStateFromDisk()") || initializer.contains("refreshOfficialAuthStatus()") {
        fatalError("ordinary launch must synchronously load Official auth before starting the gateway")
    }
    for required in ["enable-codex-config", "disable-codex-config", "codex-config-status", "-target", "-catalog", "-state"] {
        if !gateway.contains(required) { fatalError("Codex config command contract missing \(required)") }
    }
    for required in [
        "confirmationDialog(", "Enable RelayKit", "Disable RelayKit", "managed fields", "restart Codex",
        "openai_base_url", "model_catalog_json", ".bak.<timestamp>", "RelayKitPaths.codexConfigStatePath()",
        "restores their pre-existing values", "never reads or writes auth.json", "does not change model or model_provider",
    ] {
        if !content.localizedCaseInsensitiveContains(required) { fatalError("Codex confirmation UI contract missing \(required)") }
    }
    if gateway.contains("activate-codex-config") || appModel.contains("activateCodexConfig") {
        fatalError("legacy Codex activation command must not remain reachable")
    }
    if appModel.contains("runCodex(arguments: [\"login\", \"status\"]") {
        fatalError("ordinary official status must not depend on a Codex subprocess")
    }
    if !app.contains("Task { await model.startGatewayOnOrdinaryLaunch() }") {
        fatalError("ordinary App launch must prepare its complete gateway without blocking UI establishment")
    }
    if !appModel.contains("func startGatewayOnOrdinaryLaunch() async") ||
        !appModel.contains("let codexBinary = try CodexCatalogBuilder.resolveBinary()") ||
        !appModel.contains("Task.detached") ||
        !appModel.contains("catalog(accountProjection: true, binary: codexBinary)") ||
        !appModel.contains("startGateway(officialCatalog:") {
        fatalError("ordinary launch must resolve AppKit state on MainActor, build the catalog off MainActor, and start one complete gateway")
    }
}

func expectStatusPopoverContract() throws {
    let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/RelayKitApp/App/RelayKitApp.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let contentURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/RelayKitApp/Views/ContentView.swift")
    let content = try String(contentsOf: contentURL, encoding: .utf8)
    for forbidden in ["RelayKitPanel", "NSPanel(", "styleMask: [.titled", "makeKeyAndOrderFront", "activate(ignoringOtherApps:)"] {
        if source.contains(forbidden) { fatalError("status popover retained window experiment token: \(forbidden)") }
    }
    guard source.contains("final class RelayKitApp: NSObject, NSApplicationDelegate"),
          source.contains("private let popover = NSPopover()"),
          source.contains("app.setActivationPolicy(.accessory)") else {
        fatalError("single reusable accessory status popover contract is missing")
    }
    guard let launchStart = source.range(of: "func applicationDidFinishLaunching"),
          let resignStart = source.range(of: "func applicationDidResignActive", range: launchStart.upperBound..<source.endIndex),
          let terminateStart = source.range(of: "func applicationWillTerminate", range: resignStart.upperBound..<source.endIndex),
          let toggleStart = source.range(of: "@objc private func togglePopover", range: terminateStart.upperBound..<source.endIndex),
          let menuStart = source.range(of: "private func showStatusMenu", range: toggleStart.upperBound..<source.endIndex),
          let quitStart = source.range(of: "@objc private func quitRelayKit", range: menuStart.upperBound..<source.endIndex),
          let valueStart = source.range(of: "private static func value", range: quitStart.upperBound..<source.endIndex),
          let evidenceStart = source.range(of: "private func writeSmokeEvidence(gatewayExercise:", range: valueStart.upperBound..<source.endIndex) else {
        fatalError("status popover lifecycle helper boundaries are missing")
    }
    let launch = source[launchStart.lowerBound..<resignStart.lowerBound]
    let resign = source[resignStart.lowerBound..<terminateStart.lowerBound]
    let termination = source[terminateStart.lowerBound..<toggleStart.lowerBound]
    let toggle = source[toggleStart.lowerBound..<menuStart.lowerBound]
    let quit = source[quitStart.lowerBound..<valueStart.lowerBound]
    let evidence = source[evidenceStart.lowerBound..<source.endIndex]
    for required in ["#selector(togglePopover(_:))", "sendAction(on: [.leftMouseUp, .rightMouseUp])", "popover.behavior = smokeKeepsPopoverOpen ? .applicationDefined : .transient", "popover.contentSize = NSSize(width: 480, height: 760)", "popover.contentViewController = NSHostingController(", "NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown])", "DispatchQueue.main.async", "self?.popover.close()", "self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)"] {
        if !launch.contains(required) { fatalError("status popover launch setup is missing \(required)") }
    }
    for forbidden in ["NSPopoverDelegate", "popover.delegate = self", "popoverDidShow", "popoverDidClose", "popoverAccessibilityGeneration", "popoverAccessibilityIdentifier", "popoverAccessibilityWindow", "schedulePopoverAccessibilityAttachment", "attachPopoverAccessibilityRoot", "detachPopoverAccessibilityRoot", "setAccessibilityRole(.popover)", "setAccessibilityIdentifier(", "setAccessibilityParent(", "setAccessibilityChildren(", "application.setAccessibilityWindows", "_AXUIElementGetWindow", "window.windowNumber", "relaykit-popover-root-window-"] {
        if source.contains(forbidden) { fatalError("status popover retained forbidden AX binding: \(forbidden)") }
    }
    guard content.contains(".accessibilityIdentifier(\"tab-\\(item.rawValue)\")"),
          content.contains("case connect"), content.contains("case usage"), content.contains("case settings") else {
        fatalError("actionable tab accessibility identifiers are missing")
    }
    for identifier in ["tab-connect", "tab-usage", "tab-settings"] {
        if content.contains(".smokeSection(\"\(identifier)\"") {
            fatalError("page smoke marker duplicates the actionable AX identifier: \(identifier)")
        }
        if !content.contains(".smokeRecordOnly(\"\(identifier)\"") {
            fatalError("page smoke evidence marker is missing: \(identifier)")
        }
    }
    guard let rightClick = toggle.range(of: "NSApplication.shared.currentEvent?.type == .rightMouseUp"),
          let rightClose = toggle.range(of: "popover.performClose", range: rightClick.upperBound..<toggle.endIndex),
          let rightMenu = toggle.range(of: "showStatusMenu(sender)", range: rightClick.upperBound..<toggle.endIndex),
          let rightReturn = toggle.range(of: "return", range: rightMenu.upperBound..<toggle.endIndex),
          let leftStart = toggle.range(of: "if popover.isShown", range: rightReturn.upperBound..<toggle.endIndex),
          rightClick.lowerBound < rightClose.lowerBound && rightClose.lowerBound < rightMenu.lowerBound &&
          rightMenu.lowerBound < rightReturn.lowerBound && rightReturn.lowerBound < leftStart.lowerBound else {
        fatalError("right-click must close the popover before showing the status menu")
    }
    for required in ["popover.performClose(sender)", "popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)"] {
        if !toggle[leftStart.lowerBound...].contains(required) { fatalError("left-click popover toggle is missing \(required)") }
    }
    guard let leftShow = toggle.range(of: "popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)", range: leftStart.upperBound..<toggle.endIndex),
          let activate = toggle.range(of: "NSApplication.shared.activate()", range: leftShow.upperBound..<toggle.endIndex),
          leftShow.lowerBound < activate.lowerBound else {
        fatalError("ordinary popover must restore the last known-good show-then-activate order")
    }
    guard let smokeGuard = resign.range(of: "guard !CommandLine.arguments.contains(\"--ui-smoke\") else { return }"),
          let resignClose = resign.range(of: "popover.close()"), smokeGuard.lowerBound < resignClose.lowerBound else {
        fatalError("status popover resign lifecycle is missing")
    }
    guard let removeMonitor = termination.range(of: "NSEvent.removeMonitor"),
          let close = termination.range(of: "popover.close()"),
          let gatewayFinish = termination.range(of: "model.finishGatewayLifecycleForAppTermination()"),
          let authStop = termination.range(of: "model.stopOfficialAuthProcessForShutdown()"),
          removeMonitor.lowerBound < close.lowerBound && close.lowerBound < gatewayFinish.lowerBound &&
          gatewayFinish.lowerBound < authStop.lowerBound else {
        fatalError("termination must remove monitor and close popover before shutdown")
    }
    if termination.contains("model.stopGateway()") {
        fatalError("App termination must not unconditionally destroy the cached-client data plane")
    }
    if !quit.contains("NSApplication.shared.terminate(sender)") {
        fatalError("Quit must use NSApplication termination")
    }
    for required in [
        "let popoverEvidence: [String: Any] = [",
        "\"popover\": popoverEvidence",
        "\"kind\": \"menu-bar-popover\"",
    ] {
        if !evidence.contains(required) { fatalError("canonical popover smoke evidence is missing \(required)") }
    }
    for forbidden in ["\"panel\": [", "nonactivating-nspanel", "menu-bar-panel"] {
        if evidence.contains(forbidden) { fatalError("canonical popover smoke evidence retained \(forbidden)") }
    }
    let panelSourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/RelayKitApp/App/RelayKitPanel.swift")
    if FileManager.default.fileExists(atPath: panelSourceURL.path) {
        fatalError("obsolete RelayKitPanel source must be removed after restoring NSPopover")
    }
}

func expectGracefulTerminationRestoresCodexRouteBeforeStoppingGateway() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let appModel = try String(contentsOf: root.appendingPathComponent("Sources/RelayKitApp/Stores/AppModel.swift"), encoding: .utf8)
    let app = try String(contentsOf: root.appendingPathComponent("Sources/RelayKitApp/App/RelayKitApp.swift"), encoding: .utf8)

    guard let shutdownStart = appModel.range(of: "func prepareForGracefulTermination() -> Bool"),
          let statusStart = appModel.range(of: "gateway.codexConfigStatus(", range: shutdownStart.upperBound..<appModel.endIndex),
          let disableStart = appModel.range(of: "gateway.disableCodexConfig(", range: statusStart.upperBound..<appModel.endIndex),
          statusStart.lowerBound < disableStart.lowerBound else {
        fatalError("graceful termination must check guarded Codex state before guarded restoration")
    }
    let shutdown = appModel[shutdownStart.lowerBound..<appModel.endIndex]
    for required in ["case \"enabled\"", "case \"disabled\"", "case \"drifted\"", "RelayKitPaths.defaultCodexConfigPath()", "RelayKitPaths.codexConfigStatePath()", "gatewayMustSurviveTermination = gateway.isRunning", "managedRouteEpochObserved && gateway.isRunning"] {
        if !shutdown.contains(required) {
            fatalError("graceful termination guard is missing \(required)")
        }
    }
    guard let disabledStart = shutdown.range(of: "case \"disabled\":"),
          let disabledReturn = shutdown.range(of: "return true", range: disabledStart.upperBound..<shutdown.endIndex),
          let driftedStart = shutdown.range(of: "case \"drifted\":"),
          let driftedReturn = shutdown.range(of: "return false", range: driftedStart.upperBound..<shutdown.endIndex),
          disabledStart.lowerBound < disabledReturn.lowerBound,
          driftedStart.lowerBound < driftedReturn.lowerBound,
          shutdown.contains("guard codexIntegrationHasManagedState else") else {
        fatalError("graceful termination must allow disabled integration and cancel on guarded restoration failure")
    }

    guard let shouldTerminateStart = app.range(of: "func applicationShouldTerminate"),
          let willTerminateStart = app.range(of: "func applicationWillTerminate", range: shouldTerminateStart.upperBound..<app.endIndex),
          shouldTerminateStart.lowerBound < willTerminateStart.lowerBound else {
        fatalError("application termination guard is missing")
    }
    let shouldTerminate = app[shouldTerminateStart.lowerBound..<willTerminateStart.lowerBound]
    for required in ["model.prepareForGracefulTermination()", ".terminateCancel", ".terminateNow"] {
        if !shouldTerminate.contains(required) {
            fatalError("application termination must cancel on guarded Codex restoration failure")
        }
    }

    let termination = app[willTerminateStart.lowerBound..<app.endIndex]
    guard let gatewayFinish = termination.range(of: "model.finishGatewayLifecycleForAppTermination()"),
          let authStop = termination.range(of: "model.stopOfficialAuthProcessForShutdown()"),
          gatewayFinish.lowerBound < authStop.lowerBound else {
        fatalError("successful termination must preserve cached-client continuity before auth shutdown")
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
try expectCodexCatalogMerge()
expectRuntimeSafetyStateContracts()
try expectRuntimeSafetyEndpointContract()
try expectRuntimeSafetyLifecycleSourceContracts()
try expectCodexCatalogProcessDrainContract()
try expectCredentialRefContract()
try expectCapabilityContract()
expectAppSettingsPersistence()
expectProviderConfigPathRecoversStaleTemporaryPreference()
expectOfficialProofRootOverride()
expectProviderFormPresentationLabels()
expectExplicitUpstreamProtocolSelectionWins()
expectRedactedProviderSaveAndGatewayGuidance()
try expectGatewayDisplayStateContract()
try expectOfficialChannelPresentationLabels()
try expectOfficialCodexAuthState()
expectOfficialChannelSnapshots()
try expectProviderSaveTransactions()
expectOfficialAuthURLSanitizer()
expectOfficialStatusFormatter()
expectProviderConnectionLabels()
expectProviderHealthLabels()
expectProviderConnectionClassification()
expectUsageAnalytics()
try expectSignedBetaAppContracts()
try expectStatusPopoverContract()
try expectGracefulTerminationRestoresCodexRouteBeforeStoppingGateway()
try expectKeychainCredentialStore()
try expectGatewayCredentialHandoff()
if RelayKitPaths.gatewayBinaryPath(bundle: Bundle(for: BundleSentinel.self)) != "../gateway/bin/relay" {
    fatalError("non-app bundle should fall back to development gateway path")
}
if !RelayKitPaths.providerConfigPath(bundle: Bundle(for: BundleSentinel.self)).hasSuffix("Library/Application Support/RelayKit/providers.json") {
    fatalError("provider config path should default to user app support")
}
if !RelayKitPaths.codexCatalogPath().hasSuffix("Library/Application Support/RelayKit/codex-model-catalog.json") ||
    !RelayKitPaths.codexConfigStatePath().hasSuffix("Library/Application Support/RelayKit/codex-config-state.json") ||
    !RelayKitPaths.gatewayControlTokenPath().hasSuffix("Library/Application Support/RelayKit/gateway-control.token") ||
    !RelayKitPaths.defaultCodexConfigPath().hasSuffix(".codex/config.toml") {
    fatalError("Codex managed paths must stay in App Support with the default Codex config target")
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
