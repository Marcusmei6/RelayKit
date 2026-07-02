import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab = Tab.connect
    @State private var showingProviderForm = false

    init(initialTab: Tab = .connect, showProviderForm: Bool = false) {
        _tab = State(initialValue: initialTab)
        _showingProviderForm = State(initialValue: showProviderForm)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .bottom], 14)

            Divider()

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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(14)

            Divider()
            Text(model.message.isEmpty ? "Ready" : model.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(.regularMaterial)
        .sheet(isPresented: $showingProviderForm) {
            ProviderFormView()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("RelayKit")
                    .font(.title2.weight(.semibold))
                Text("local model gateway")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Label(model.gatewayStatus, systemImage: model.gatewayStatus == "ok" || model.gatewayStatus == "running" ? "checkmark.circle.fill" : "circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.gatewayStatus == "ok" || model.gatewayStatus == "running" ? .green : .secondary)
                Text("127.0.0.1:19777")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    private var connectTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            metricGrid

            HStack {
                Button("Start") { model.startGateway() }
                Button("Stop") { model.stopGateway() }
                Button("Restart") { model.restartGateway() }
                Spacer()
                Button("Health") { Task { await model.refreshHealth() } }
                Button("Models") { Task { await model.refreshModels() } }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("本机 CLI")
                    .font(.headline)
                HStack(spacing: 8) {
                    cliCard(title: "Codex", subtitle: "P0 active target", active: true)
                    cliCard(title: "Claude Code", subtitle: "Later", active: false)
                        .disabled(true)
                }
            }

            HStack {
                Text("Codex 已接入模型")
                    .font(.headline)
                Spacer()
                Button {
                    showingProviderForm = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("新增模型接入")
            }

            modelList
        }
    }

    private var metricGrid: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                metric("Gateway", model.gatewayStatus)
                metric("Port", "19777")
            }
            GridRow {
                metric("Health", model.gatewayStatus == "ok" ? "ok" : "unknown")
                metric("Models", "\(model.models.count)")
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func cliCard(title: String, subtitle: String, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(active ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var modelList: some View {
        VStack(spacing: 8) {
            if model.models.isEmpty {
                ContentUnavailableView("No models loaded", systemImage: "tray", description: Text("Start gateway, then refresh models."))
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ForEach(model.models) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.id)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(item.ownedBy)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("LOCAL")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var usageTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Usage")
                    .font(.headline)
                Spacer()
                Button("Refresh") {
                    Task { await model.refreshUsageSummary() }
                }
            }
            TextField("Usage JSONL path", text: $model.usageLogPath)
                .textFieldStyle(.roundedBorder)

            if model.usageSummaries.isEmpty {
                ContentUnavailableView("No usage rows", systemImage: "chart.bar", description: Text("RelayKit will show real local summaries after gateway traffic."))
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ForEach(model.usageSummaries) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(item.providerId) / \(item.model)")
                            .font(.subheadline.weight(.semibold))
                        Text("\(item.day) · \(item.requests) req · \(item.totalTokens) tokens · \(item.durationMs)ms")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var settingsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设置")
                .font(.headline)
            LabeledContent("Gateway binary") {
                TextField("Gateway binary path", text: $model.gatewayBinaryPath)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Provider config") {
                TextField("Provider config path", text: $model.providerConfigPath)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Codex source") {
                TextField("Source config path", text: $model.codexSourcePath)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Codex target") {
                TextField("Explicit target config path", text: $model.codexTargetPath)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("Activate Codex Config") {
                    Task { await model.activateCodexConfig() }
                }
                Button("Load Provider JSON") { model.loadProviderConfig() }
            }
            Text("No fake toggles. Launch-at-login, theme, Git usage, and Claude Code are deferred.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
}

private struct ProviderFormView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var providerId = ""
    @State private var source = "official"
    @State private var modelId = ""
    @State private var upstreamModel = ""
    @State private var apiFormat = "openai_chat"
    @State private var baseURL = ""
    @State private var contextWindow = "128000"
    @State private var authReference = ""
    @State private var reasoning = false
    @State private var streaming = true
    @State private var tools = false
    @State private var usage = true
    @State private var visible = true
    @State private var priority = "100"
    @State private var status = "enabled"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新增模型接入")
                .font(.title2.weight(.semibold))
            Text("Public-safe form only. Store credential references, never secret values.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                row("Provider ID", $providerId, "local-openai-compatible")
                row("Source", $source, "official / custom")
                row("Model ID", $modelId, "local/coder-fast")
                row("Upstream model", $upstreamModel, "qwen3-coder")
                row("API format", $apiFormat, "openai_chat")
                row("Base URL", $baseURL, "http://127.0.0.1:11434/v1")
                row("Context window", $contextWindow, "128000")
                row("Credential ref", $authReference, "RELAYKIT_EXAMPLE_API_KEY")
                row("Priority", $priority, "100")
                row("Status", $status, "enabled")
            }

            HStack {
                Toggle("Reasoning", isOn: $reasoning)
                Toggle("Streaming", isOn: $streaming)
                Toggle("Tools", isOn: $tools)
                Toggle("Usage", isOn: $usage)
                Toggle("Visible", isOn: $visible)
            }
            .toggleStyle(.checkbox)

            Text(validationMessage)
                .font(.caption)
                .foregroundStyle(validationMessage == "Ready to save after provider writer lands." ? Color.secondary : Color.red)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存接入") {}
                    .disabled(true)
                    .help("Provider writer is deferred; this P0 slice only replaces the JSON editor primary path.")
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private func row(_ label: String, _ value: Binding<String>, _ prompt: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            TextField(prompt, text: value)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var validationMessage: String {
        if providerId.isEmpty || modelId.isEmpty || apiFormat.isEmpty || baseURL.isEmpty {
            return "Provider ID, model ID, API format, and base URL are required."
        }
        if authReference.lowercased().contains("sk-") || authReference.lowercased().contains("bearer ") {
            return "Credential values are not allowed; use env, Keychain item, or key-file reference."
        }
        return "Ready to save after provider writer lands."
    }
}
