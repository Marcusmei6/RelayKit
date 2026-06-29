import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                gatewayControls
                models
                usage
                activation
                status
            }
            .padding(24)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("RelayKit")
                .font(.title)
            Text("Local gateway control")
                .foregroundStyle(.secondary)
        }
    }

    private var gatewayControls: some View {
        GroupBox("Gateway") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Status", value: model.gatewayStatus)
                TextField("Gateway binary path", text: $model.gatewayBinaryPath)
                    .textFieldStyle(.roundedBorder)
                TextField("Provider config path", text: $model.providerConfigPath)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Start") { model.startGateway() }
                    Button("Stop") { model.stopGateway() }
                    Button("Health") {
                        Task { await model.refreshHealth() }
                    }
                    Button("Refresh Models") {
                        Task { await model.refreshModels() }
                    }
                }
            }
        }
    }

    private var models: some View {
        GroupBox("Models") {
            if model.models.isEmpty {
                Text("No models loaded")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                List(model.models) { item in
                    HStack {
                        Text(item.id)
                        Spacer()
                        Text(item.ownedBy)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 120)
            }
        }
    }

    private var activation: some View {
        GroupBox("Codex Config Activation") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Source config path", text: $model.codexSourcePath)
                    .textFieldStyle(.roundedBorder)
                TextField("Explicit target config path", text: $model.codexTargetPath)
                    .textFieldStyle(.roundedBorder)
                Button("Activate") {
                    Task { await model.activateCodexConfig() }
                }
            }
        }
    }

    private var usage: some View {
        GroupBox("Usage") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Usage JSONL path", text: $model.usageLogPath)
                    .textFieldStyle(.roundedBorder)
                Button("Refresh Usage") {
                    Task { await model.refreshUsageSummary() }
                }
                if model.usageSummaries.isEmpty {
                    Text("No usage loaded")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow {
                            Text("Day")
                            Text("Provider")
                            Text("Model")
                            Text("Requests")
                            Text("Tokens")
                        }
                        .foregroundStyle(.secondary)
                        ForEach(model.usageSummaries) { item in
                            GridRow {
                                Text(item.day)
                                Text(item.providerId)
                                Text(item.model)
                                Text("\(item.requests)")
                                Text("\(item.totalTokens)")
                            }
                        }
                    }
                }
            }
        }
    }

    private var status: some View {
        Text(model.message.isEmpty ? "Ready" : model.message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
