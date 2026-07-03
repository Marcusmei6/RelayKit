import RelayKitCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab = Tab.connect
    @State private var showingProviderForm = false
    @State private var showingAdvancedSettings = false
    @State private var showingUsagePath = false
    private let smokeSectionRecorder: ((String) -> Void)?

    init(initialTab: Tab = .connect, showProviderForm: Bool = false, smokeSectionRecorder: ((String) -> Void)? = nil) {
        _tab = State(initialValue: initialTab)
        _showingProviderForm = State(initialValue: showProviderForm)
        self.smokeSectionRecorder = smokeSectionRecorder
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0x111827), Color(hex: 0x0A0D14)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                tabRail
                ScrollView {
                    Group {
                        switch tab {
                        case .connect:
                            connectTab
                        case .usage:
                            usageTab
                        case .settings:
                            settingsTab
                        }
                    }
                    .padding(18)
                    .padding(.bottom, 30)
                }
                footer
            }

            if showingProviderForm {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { showingProviderForm = false }
                ProviderFormView {
                    showingProviderForm = false
                }
                .environmentObject(model)
                .smokeSection("tab-provider", recorder: smokeSectionRecorder)
                .smokeSection("provider-modal", recorder: smokeSectionRecorder)
                .smokeSection("credential-reference-form", recorder: smokeSectionRecorder)
                .padding(18)
            }
        }
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: 0x1A3147), Color(hex: 0x101722)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(borderColor))
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x78D8FF))
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text("RelayKit")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text("本地模型网关 · \(codexHeaderStatus)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
            }

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 8) {
                statusPill
                HStack(spacing: 8) {
                    headerMetric("Port", "19777")
                    headerMetric("Models", "\(model.models.count)")
                    headerMetric("Codex", model.codexConnectionIsConfigured ? "on" : "setup")
                }
            }
        }
        .padding(18)
        .smokeSection("relaykit-brand", recorder: smokeSectionRecorder)
        .smokeSection("global-status", recorder: smokeSectionRecorder)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.075), Color.white.opacity(0.025)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .overlay(alignment: .bottom) { Divider().overlay(borderColor) }
    }

    private var statusPill: some View {
        Label(model.gatewayStatus, systemImage: model.gatewayStatus == "ok" || model.gatewayStatus == "running" ? "checkmark.circle.fill" : "circle")
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(statusColor.opacity(0.18), in: Capsule())
            .foregroundStyle(statusColor)
    }

    private func headerMetric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.38))
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
        }
        .frame(minWidth: 48)
    }

    private var tabRail: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    VStack(spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        Text(item.subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(tab == item ? .white.opacity(0.64) : .white.opacity(0.34))
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(tab == item ? .white : .white.opacity(0.48))
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(tab == item ? LinearGradient(colors: [Color(hex: 0x78D8FF), Color(hex: 0xFFD685)], startPoint: .leading, endPoint: .trailing) : LinearGradient(colors: [.clear], startPoint: .leading, endPoint: .trailing))
                        .frame(height: 3)
                        .padding(.horizontal, 18)
                }
            }
        }
        .background(Color.white.opacity(0.045))
        .overlay(alignment: .bottom) { Divider().overlay(borderColor) }
    }

    private var connectTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionCard {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 7) {
                        sectionEyebrow("CLI ROUTE")
                        Text("选择本机 CLI 后管理模型接入")
                            .font(.headline)
                        Text("Codex 是当前 P0 真实目标；Claude Code 保持未来占位。")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.56))
                    }
                    Spacer()
                    gatewayControls
                }

                HStack(spacing: 12) {
                    cliCard(
                        title: "Codex",
                        subtitle: model.codexConnectionStatus,
                        state: model.codexConnectionIsConfigured ? .active : .setup,
                        icon: "terminal.fill"
                    )
                    cliCard(title: "Claude Code", subtitle: "Later", active: false, icon: "hourglass")
                        .disabled(true)
                }
            }
            .smokeSection("tab-connect", recorder: smokeSectionRecorder)
            .smokeSection("cli-route", recorder: smokeSectionRecorder)

            SectionCard {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        sectionEyebrow("MODELS")
                        Text("Codex 已接入模型")
                            .font(.headline)
                    }
                    Spacer()
                    Button {
                        showingProviderForm = true
                    } label: {
                        Label("新增", systemImage: "plus")
                    }
                    .buttonStyle(ControlButtonStyle(prominent: true))
                }
                modelList
            }
            .smokeSection("model-list", recorder: smokeSectionRecorder)
        }
    }

    private var gatewayControls: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 8) {
                Button("Start") { model.startGateway() }
                Button("Stop") { model.stopGateway() }
                Button("Restart") { model.restartGateway() }
            }
            .buttonStyle(ControlButtonStyle())
            HStack(spacing: 8) {
                Button("Health") { Task { await model.refreshHealth() } }
                Button("Models") { Task { await model.refreshModels() } }
            }
            .buttonStyle(ControlButtonStyle())
        }
    }

    private func cliCard(title: String, subtitle: String, active: Bool, icon: String) -> some View {
        cliCard(title: title, subtitle: subtitle, state: active ? .active : .future, icon: icon)
    }

    private func cliCard(title: String, subtitle: String, state: CLIState, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                Spacer()
                Text(state.label)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(state.tint)
            }
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.56))
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(state.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(state.border))
    }

    private var modelList: some View {
        VStack(spacing: 8) {
            if model.models.isEmpty {
                EmptyProductState(
                    title: "No models loaded",
                    message: "Start gateway, then refresh models.",
                    icon: "tray"
                )
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ForEach(model.models) { item in
                    HStack(spacing: 12) {
                        Image(systemName: "cpu")
                            .foregroundStyle(Color(hex: 0x78D8FF))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.id)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(item.ownedBy)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("LOCAL")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.52))
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(borderColor))
                }
            }
        }
    }

    private var usageTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionCard {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        sectionEyebrow("LOCAL USAGE")
                        Text("Usage")
                            .font(.headline)
                        Text("只读取本机 usage JSONL summary；没有 mock rows。")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.56))
                    }
                    Spacer()
                    Button("Refresh") {
                        Task { await model.refreshUsageSummary() }
                    }
                    .buttonStyle(ControlButtonStyle(prominent: true))
                }

                usageKpis
            }
            .smokeSection("tab-usage", recorder: smokeSectionRecorder)
            .smokeSection("usage-kpis", recorder: smokeSectionRecorder)

            SectionCard {
                HStack {
                    Text("模型用量")
                        .font(.headline)
                    Spacer()
                    Button(showingUsagePath ? "Hide path" : "Usage path") {
                        showingUsagePath.toggle()
                    }
                    .buttonStyle(ControlButtonStyle())
                }
                if showingUsagePath {
                    TextField("Usage JSONL path", text: $model.usageLogPath)
                        .textFieldStyle(ProductTextFieldStyle())
                }
                usageRows
            }
            .smokeSection("usage-rows", recorder: smokeSectionRecorder)
        }
    }

    private var usageKpis: some View {
        let requests = model.usageSummaries.reduce(0) { $0 + $1.requests }
        let tokens = model.usageSummaries.reduce(0) { $0 + $1.totalTokens }
        let duration = model.usageSummaries.reduce(0) { $0 + $1.durationMs }
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            kpi("Requests", "\(requests)", "real rows")
            kpi("Tokens", "\(tokens)", "total")
            kpi("Models", "\(Set(model.usageSummaries.map(\.model)).count)", "summarized")
            kpi("Duration", "\(duration)ms", "local")
        }
    }

    private func kpi(_ title: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
            Text(value)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .lineLimit(1)
            Text(note)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.38))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(borderColor))
    }

    private var usageRows: some View {
        VStack(spacing: 8) {
            if model.usageSummaries.isEmpty {
                EmptyProductState(
                    title: "No usage rows",
                    message: "Real local summaries appear after RelayKit traffic.",
                    icon: "chart.bar"
                )
                .frame(maxWidth: .infinity, minHeight: 112)
            } else {
                ForEach(model.usageSummaries) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(item.providerId)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(item.day)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        Text(item.model)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.58))
                            .lineLimit(1)
                        HStack {
                            usageChip("\(item.requests) req")
                            usageChip("\(item.totalTokens) tokens")
                            usageChip("\(item.durationMs)ms")
                        }
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(borderColor))
                }
            }
        }
    }

    private func usageChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.08), in: Capsule())
            .foregroundStyle(.white.opacity(0.72))
    }

    private var settingsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionCard {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        sectionEyebrow("SETTINGS")
                        Text("设置")
                            .font(.headline)
                        Text("只展示真实可执行的本地动作；未来能力保持禁用。")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.56))
                    }
                    Spacer()
                    Button("Refresh") { model.refreshCodexConnectionStatus() }
                        .buttonStyle(ControlButtonStyle())
                }
            }
            .smokeSection("tab-settings", recorder: smokeSectionRecorder)

            SectionCard {
                settingsRow(title: "Gateway helper", subtitle: "Bundled relay on 127.0.0.1:19777", action: "Start") {
                    model.startGateway()
                }
                settingsRow(title: "Provider config", subtitle: shortPath(model.providerConfigPath), action: "Load") {
                    model.loadProviderConfig()
                }
                settingsRow(title: "Codex config", subtitle: model.codexConnectionStatus, action: "Activate") {
                    Task { await model.activateCodexConfig() }
                }
                settingsRow(title: "Claude Code", subtitle: "Future integration", action: "Later", disabled: true) {}
            }
            .smokeSection("settings-actions", recorder: smokeSectionRecorder)

            SectionCard {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Advanced local paths")
                            .font(.subheadline.weight(.semibold))
                        Text("Explicit paths only; RelayKit never writes real ~/.codex/config.toml by default.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.52))
                    }
                    Spacer()
                    Button(showingAdvancedSettings ? "Hide" : "Show") {
                        showingAdvancedSettings.toggle()
                    }
                    .buttonStyle(ControlButtonStyle())
                }
                if showingAdvancedSettings {
                    VStack(spacing: 8) {
                        labeledField("Gateway binary", text: $model.gatewayBinaryPath)
                        labeledField("Provider config", text: $model.providerConfigPath)
                        labeledField("Codex source", text: $model.codexSourcePath)
                        labeledField("Codex target", text: $model.codexTargetPath)
                    }
                }
            }
            .smokeSection("advanced-paths", recorder: smokeSectionRecorder)
        }
    }

    private func settingsRow(title: String, subtitle: String, action: String, disabled: Bool = false, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(1)
            }
            Spacer()
            Button(action, action: perform)
                .buttonStyle(ControlButtonStyle(prominent: !disabled))
                .disabled(disabled)
        }
        .padding(12)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(borderColor))
    }

    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.52))
            TextField(label, text: text)
                .textFieldStyle(ProductTextFieldStyle())
        }
    }

    private var footer: some View {
        Text(model.message.isEmpty ? "Ready" : model.message)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.52))
            .lineLimit(2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.white.opacity(0.035))
            .overlay(alignment: .top) { Divider().overlay(borderColor) }
    }

    private func sectionEyebrow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color(hex: 0x78D8FF).opacity(0.78))
    }

    private var statusColor: Color {
        model.gatewayStatus == "ok" || model.gatewayStatus == "running" ? Color(hex: 0x9AF2D0) : .white.opacity(0.56)
    }

    private var codexHeaderStatus: String {
        model.codexConnectionIsConfigured ? "Codex active" : "Codex setup"
    }
}

private enum CLIState {
    case active
    case setup
    case future

    var label: String {
        switch self {
        case .active: "ACTIVE"
        case .setup: "SETUP"
        case .future: "FUTURE"
        }
    }

    var tint: Color {
        switch self {
        case .active: Color(hex: 0xFFD685)
        case .setup: Color(hex: 0x78D8FF)
        case .future: .white.opacity(0.36)
        }
    }

    var background: Color {
        switch self {
        case .active: Color(hex: 0xFFD685).opacity(0.13)
        case .setup: Color(hex: 0x78D8FF).opacity(0.11)
        case .future: Color.white.opacity(0.055)
        }
    }

    var border: Color {
        switch self {
        case .active: Color(hex: 0xFFD685).opacity(0.42)
        case .setup: Color(hex: 0x78D8FF).opacity(0.34)
        case .future: borderColor
        }
    }
}

enum Tab: String, CaseIterable, Identifiable {
    case connect
    case usage
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connect: "接入"
        case .usage: "Usage"
        case .settings: "设置"
        }
    }

    var subtitle: String {
        switch self {
        case .connect: "本机 CLI"
        case .usage: "Local"
        case .settings: "Paths"
        }
    }
}

private struct ProviderFormView: View {
    @EnvironmentObject private var model: AppModel
    let onClose: () -> Void
    @State private var providerId = ""
    @State private var providerName = ""
    @State private var modelId = ""
    @State private var modelDisplayName = ""
    @State private var apiFormat = "openai_chat"
    @State private var baseURL = ""
    @State private var contextWindow = "128000"
    @State private var authReference = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("新增模型接入")
                        .font(.title2.weight(.semibold))
                    Text("Store credential references, never secret values.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.56))
                }
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(ControlButtonStyle())
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                field("Provider ID", $providerId, "local-openai-compatible")
                field("Provider name", $providerName, "Local OpenAI Compatible")
                field("Model ID", $modelId, "local/coder-fast")
                field("Display name", $modelDisplayName, "Coder Fast")
                field("API format", $apiFormat, "openai_chat")
                field("Base URL", $baseURL, "http://127.0.0.1:11434/v1")
                field("Context window", $contextWindow, "128000")
                field("Auth env ref", $authReference, "RELAYKIT_EXAMPLE_API_KEY")
            }

            Text("Capabilities and priority stay gateway-discovered or future schema work.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.48))

            Text(validationMessage)
                .font(.caption)
                .foregroundStyle(canSave ? .white.opacity(0.56) : Color(hex: 0xFF8FA3))

            HStack {
                Spacer()
                Button("取消") { onClose() }
                    .buttonStyle(ControlButtonStyle())
                Button("保存接入") {
                    if model.addProvider(draft) {
                        onClose()
                    }
                }
                .buttonStyle(ControlButtonStyle(prominent: true))
                .disabled(!canSave)
            }
        }
        .padding(18)
        .frame(width: 484)
        .background(Color(hex: 0x101722), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(borderColor))
        .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
    }

    private func field(_ label: String, _ value: Binding<String>, _ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.52))
            TextField(prompt, text: value)
                .textFieldStyle(ProductTextFieldStyle())
        }
    }

    private var validationMessage: String {
        if providerId.isEmpty || modelId.isEmpty || apiFormat.isEmpty || baseURL.isEmpty {
            return "Provider ID, model ID, API format, and base URL are required."
        }
        if !contextWindow.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && Int(contextWindow) == nil {
            return "Context window must be a number."
        }
        let lowerAuth = authReference.lowercased()
        let credentialMarkers = ["bearer ", "sk-", "api_key=", "token=", "access_token=", "refresh_token=", "password=", "secret=", "authorization="]
        if credentialMarkers.contains(where: lowerAuth.contains) {
            return "Credential values are not allowed; use an environment variable name."
        }
        do {
            _ = try ProviderConfigDraftWriter.addProvider(draft, to: Data(#"{"providers":[]}"#.utf8))
        } catch {
            return error.localizedDescription
        }
        return "Ready to save provider metadata."
    }

    private var canSave: Bool {
        validationMessage == "Ready to save provider metadata."
    }

    private var draft: ProviderConfigDraft {
        ProviderConfigDraft(
            providerId: providerId,
            providerName: providerName.isEmpty ? providerId : providerName,
            baseURL: baseURL,
            apiFormat: apiFormat,
            authEnv: authReference,
            modelId: modelId,
            modelDisplayName: modelDisplayName,
            contextWindow: Int(contextWindow)
        )
    }
}

private struct SectionCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(borderColor))
    }
}

private struct EmptyProductState: View {
    let title: String
    let message: String
    let icon: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.32))
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.52))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ControlButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .foregroundStyle(prominent ? Color(hex: 0x071018) : .white.opacity(configuration.isPressed ? 0.58 : 0.82))
            .background(prominent ? Color(hex: 0x78D8FF).opacity(configuration.isPressed ? 0.7 : 1) : Color.white.opacity(configuration.isPressed ? 0.11 : 0.075), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(prominent ? Color.clear : borderColor))
    }
}

private struct ProductTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.system(size: 12, design: .rounded))
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(borderColor))
            .foregroundStyle(.white)
    }
}

private struct SmokeSectionModifier: ViewModifier {
    let id: String
    let recorder: ((String) -> Void)?

    func body(content: Content) -> some View {
        content
            .accessibilityIdentifier(id)
            .onAppear {
                recorder?(id)
            }
    }
}

private let borderColor = Color.white.opacity(0.12)

private func shortPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let collapsed = path.replacingOccurrences(of: home, with: "~")
    if collapsed.count <= 46 {
        return collapsed
    }
    return "..." + collapsed.suffix(43)
}

private extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

private extension View {
    func smokeSection(_ id: String, recorder: ((String) -> Void)?) -> some View {
        modifier(SmokeSectionModifier(id: id, recorder: recorder))
    }
}
