import RelayKitCore
import SwiftUI

struct ContentView: View {
    @Environment(\.colorScheme) private var systemColorScheme
    @EnvironmentObject private var model: AppModel
    @State private var tab = Tab.connect
    @State private var showingProviderForm = false
    @State private var editingProvider: ConfiguredProviderEntry?
    @State private var selectedReferenceGroup: LocalModelCatalog.SourceGroup?
    @State private var showingAdvancedSettings = false
    @State private var showingUsagePath = false
    private let smokeOpensProviderFromAddStrip: Bool
    private let showCatalogDetail: Bool
    private let showReferenceDetail: Bool
    private let smokeSectionRecorder: ((String) -> Void)?

    init(initialTab: Tab = .connect, showProviderForm: Bool = false, showCatalogDetail: Bool = false, showReferenceDetail: Bool = false, smokeSectionRecorder: ((String) -> Void)? = nil) {
        _tab = State(initialValue: initialTab)
        _showingProviderForm = State(initialValue: false)
        self.smokeOpensProviderFromAddStrip = showProviderForm
        self.showCatalogDetail = showCatalogDetail
        self.showReferenceDetail = showReferenceDetail
        self.smokeSectionRecorder = smokeSectionRecorder
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: backgroundGradient,
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
                ProviderFormView(
                    mode: .add,
                    onClose: {
                        showingProviderForm = false
                    },
                    smokeSectionRecorder: smokeSectionRecorder
                )
                .environmentObject(model)
                .smokeSection("tab-provider", recorder: smokeSectionRecorder)
                .smokeSection("provider-modal", recorder: smokeSectionRecorder)
                .smokeSection("credential-reference-form", recorder: smokeSectionRecorder)
                .padding(18)
            }

            if let editingProvider {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { self.editingProvider = nil }
                ProviderFormView(
                    mode: .edit(editingProvider),
                    onClose: {
                        self.editingProvider = nil
                    },
                    smokeSectionRecorder: smokeSectionRecorder
                )
                .environmentObject(model)
                .smokeSection("provider-edit-modal", recorder: smokeSectionRecorder)
                .smokeSection("provider-modal", recorder: smokeSectionRecorder)
                .smokeSection("credential-reference-form", recorder: smokeSectionRecorder)
                .padding(18)
            }

            if let selectedReferenceGroup {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { self.selectedReferenceGroup = nil }
                ReferenceGroupDetailView(group: selectedReferenceGroup) {
                    self.selectedReferenceGroup = nil
                }
                .smokeSection("reference-detail-modal", recorder: smokeSectionRecorder)
                .padding(18)
            }
        }
        .foregroundStyle(primaryText)
        .preferredColorScheme(preferredColorScheme)
        .task {
            await model.refreshLocalCatalog()
            if showCatalogDetail, editingProvider == nil {
                openFirstConfiguredProviderFromRowAction()
            }
            if showReferenceDetail, selectedReferenceGroup == nil {
                openFirstReferenceGroupFromRowAction()
            }
            if smokeOpensProviderFromAddStrip, !showingProviderForm {
                openProviderFormFromAddStrip()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        LinearGradient(
                            colors: logoGradient,
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
                    .foregroundStyle(secondaryText)
            }

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 8) {
                statusPill
                HStack(spacing: 8) {
                    headerMetric("Port", "19777")
                    headerMetric("Models", "\(model.localCatalog?.modelCount ?? 0)")
                    headerMetric("Codex", model.codexConnectionIsConfigured ? "on" : "setup")
                }
            }
        }
        .padding(18)
        .smokeSection("relaykit-brand", recorder: smokeSectionRecorder)
        .smokeSection("global-status", recorder: smokeSectionRecorder)
        .background(
            LinearGradient(
                colors: headerGradient,
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
                .foregroundStyle(mutedText)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(primaryText.opacity(0.82))
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
                            .foregroundStyle(tab == item ? secondaryText : mutedText)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(tab == item ? primaryText : mutedText)
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(tab == item ? LinearGradient(colors: [Color(hex: 0x78D8FF), Color(hex: 0xFFD685)], startPoint: .leading, endPoint: .trailing) : LinearGradient(colors: [.clear], startPoint: .leading, endPoint: .trailing))
                        .frame(height: 3)
                        .padding(.horizontal, 18)
                }
            }
        }
        .background(railBackground)
        .overlay(alignment: .bottom) { Divider().overlay(borderColor) }
    }

    private var connectTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionCard {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 7) {
                        sectionEyebrow("LOCAL CLI")
                        Text("本机 CLI")
                            .font(.headline)
                        Text(model.localCatalogStatus)
                            .font(.caption)
                            .foregroundStyle(secondaryText)
                    }
                    Spacer()
                    Button("重扫") {
                        Task { await model.refreshLocalCatalog() }
                    }
                    .buttonStyle(ControlButtonStyle())
                }

                HStack(spacing: 12) {
                    cliSwitch(
                        title: "Codex",
                        subtitle: model.codexConnectionStatus,
                        selected: true,
                        disabled: false,
                        icon: "terminal.fill"
                    )
                    cliSwitch(title: "Claude Code", subtitle: "Future", selected: false, disabled: true, icon: "hourglass")
                        .disabled(true)
                }
            }
            .smokeSection("tab-connect", recorder: smokeSectionRecorder)
            .smokeSection("cli-route", recorder: smokeSectionRecorder)
            .smokeSection("local-cli-scan", recorder: smokeSectionRecorder)
            .smokeSection("cli-selected-state", recorder: smokeSectionRecorder)
            .smokeSection("codex-target-state", recorder: smokeSectionRecorder)
            .smokeSection("claude-disabled-placeholder", recorder: smokeSectionRecorder)

            SectionCard {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        sectionEyebrow("RELAYKIT PROVIDERS")
                        Text("已配置接入")
                            .font(.headline)
                        Text("这些是 RelayKit 本地 provider/client 配置，可编辑。")
                            .font(.caption)
                            .foregroundStyle(secondaryText)
                    }
                }
                configuredProviderList
                addStrip
            }
            .smokeSection("configured-providers", recorder: smokeSectionRecorder)
            .smokeSection("add-strip", recorder: smokeSectionRecorder)
            .smokeSection("auth-blocked-state", recorder: smokeSectionRecorder)

            SectionCard {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        sectionEyebrow("REFERENCE DISCOVERY")
                        Text("可参考的本机发现来源")
                            .font(.headline)
                        Text("执行状态：\(model.localCatalogAuthState)")
                            .font(.caption)
                            .foregroundStyle(secondaryText)
                    }
                }
                referenceCatalogList
            }
            .smokeSection("reference-catalog", recorder: smokeSectionRecorder)
        }
    }

    private func cliSwitch(title: String, subtitle: String, selected: Bool, disabled: Bool, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                Spacer()
                Text(disabled ? "FUTURE" : selected ? "SELECTED" : "READY")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(disabled ? mutedText : Color(hex: 0x78D8FF))
            }
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(secondaryText)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color(hex: 0x78D8FF).opacity(0.11) : surfaceSubtle, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? Color(hex: 0x78D8FF).opacity(0.42) : borderColor))
    }

    private var configuredProviderList: some View {
        VStack(spacing: 8) {
            if model.configuredProviders.isEmpty {
                EmptyProductState(
                    title: "No RelayKit providers",
                    message: "Add a local provider/client config to route models through RelayKit.",
                    icon: "square.stack.3d.up.slash"
                )
                .frame(maxWidth: .infinity, minHeight: 130)
            } else {
                ForEach(model.configuredProviders) { provider in
                    Button {
                        openConfiguredProviderFromRowAction(provider)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "slider.horizontal.3")
                                .foregroundStyle(Color(hex: 0x78D8FF))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.name)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text("\(provider.apiFormat) · \(provider.modelId)")
                                    .font(.caption)
                                    .foregroundStyle(secondaryText)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(provider.credentialKind.uppercased())
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color(hex: 0x78D8FF))
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(surfaceSubtle, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(borderColor))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var referenceCatalogList: some View {
        VStack(spacing: 8) {
            if let catalog = model.localCatalog, !catalog.sourceGroups.isEmpty {
                ForEach(catalog.sourceGroups, id: \.source) { group in
                    Button {
                        openReferenceGroupFromRowAction(group)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "server.rack")
                                .foregroundStyle(Color(hex: 0xFFD685))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.publicLabel)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text("\(group.count) discovered model(s) · reference only")
                                    .font(.caption)
                                    .foregroundStyle(secondaryText)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text("DISCOVERY")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color(hex: 0xFFD685))
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(surfaceSubtle, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(borderColor))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                EmptyProductState(
                    title: "No reference catalog",
                    message: "Local discovery is unavailable or returned no models.",
                    icon: "magnifyingglass"
                )
                .frame(maxWidth: .infinity, minHeight: 150)
            }
        }
    }

    private var addStrip: some View {
        Button {
            openProviderFormFromAddStrip()
        } label: {
            HStack {
                Image(systemName: "plus")
                Text("新增模型接入")
                Spacer()
            }
            .font(.subheadline.weight(.semibold))
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Color(hex: 0x78D8FF).opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: 0x78D8FF).opacity(0.36), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        }
        .buttonStyle(.plain)
    }

    private func openProviderFormFromAddStrip() {
        smokeSectionRecorder?("add-strip-action")
        showingProviderForm = true
    }

    private func openFirstConfiguredProviderFromRowAction() {
        guard let provider = model.configuredProviders.first else { return }
        openConfiguredProviderFromRowAction(provider)
    }

    private func openConfiguredProviderFromRowAction(_ provider: ConfiguredProviderEntry) {
        smokeSectionRecorder?("configured-provider-row-action")
        editingProvider = provider
    }

    private func openFirstReferenceGroupFromRowAction() {
        guard let group = model.localCatalog?.sourceGroups.first else { return }
        openReferenceGroupFromRowAction(group)
    }

    private func openReferenceGroupFromRowAction(_ group: LocalModelCatalog.SourceGroup) {
        smokeSectionRecorder?("reference-row-action")
        selectedReferenceGroup = group
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
                            .foregroundStyle(secondaryText)
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
                .foregroundStyle(secondaryText)
            Text(value)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .lineLimit(1)
            Text(note)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(mutedText)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surfaceSubtle, in: RoundedRectangle(cornerRadius: 14))
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
                                .foregroundStyle(mutedText)
                        }
                        Text(item.model)
                            .font(.caption)
                            .foregroundStyle(secondaryText)
                            .lineLimit(1)
                        HStack {
                            usageChip("\(item.requests) req")
                            usageChip("\(item.totalTokens) tokens")
                            usageChip("\(item.durationMs)ms")
                        }
                    }
                    .padding(12)
                    .background(surfaceSubtle, in: RoundedRectangle(cornerRadius: 14))
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
            .background(chipBackground, in: Capsule())
            .foregroundStyle(primaryText.opacity(0.72))
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
                            .foregroundStyle(secondaryText)
                    }
                    Spacer()
                    Button("Refresh") { model.refreshCodexConnectionStatus() }
                        .buttonStyle(ControlButtonStyle())
                }
            }
            .smokeSection("tab-settings", recorder: smokeSectionRecorder)

            SectionCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Appearance")
                                .font(.subheadline.weight(.semibold))
                            Text("Persists across launches and changes this popover theme.")
                                .font(.caption)
                                .foregroundStyle(secondaryText)
                        }
                        Spacer()
                    }
                    Picker("Appearance", selection: Binding(
                        get: { model.appearanceMode },
                        set: { model.setAppearanceMode($0) }
                    )) {
                        Text("System").tag(AppAppearanceMode.system)
                        Text("Light").tag(AppAppearanceMode.light)
                        Text("Dark").tag(AppAppearanceMode.dark)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            .smokeSection("appearance-control", recorder: smokeSectionRecorder)

            SectionCard {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Launch at login")
                            .font(.subheadline.weight(.semibold))
                        Text("macOS login item status: \(model.launchAtLoginStatus)")
                            .font(.caption)
                            .foregroundStyle(secondaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { model.launchAtLoginRequested },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    Button("Refresh") {
                        model.refreshLaunchAtLoginStatus()
                    }
                    .buttonStyle(ControlButtonStyle())
                }
            }
            .smokeSection("launch-login-control", recorder: smokeSectionRecorder)

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
                            .foregroundStyle(secondaryText)
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
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            Button(action, action: perform)
                .buttonStyle(ControlButtonStyle(prominent: !disabled))
                .disabled(disabled)
        }
        .padding(12)
        .background(surfaceSubtle, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(borderColor))
    }

    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(secondaryText)
            TextField(label, text: text)
                .textFieldStyle(ProductTextFieldStyle())
        }
    }

    private var footer: some View {
        Text(model.message.isEmpty ? "Ready" : model.message)
            .font(.caption)
            .foregroundStyle(secondaryText)
            .lineLimit(2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(surfaceChrome)
            .overlay(alignment: .top) { Divider().overlay(borderColor) }
    }

    private func sectionEyebrow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color(hex: 0x78D8FF).opacity(0.78))
    }

    private var statusColor: Color {
        model.gatewayStatus == "ok" || model.gatewayStatus == "running" ? Color(hex: 0x0F766E) : secondaryText
    }

    private var codexHeaderStatus: String {
        model.codexConnectionIsConfigured ? "Codex active" : "Codex setup"
    }

    private var resolvedScheme: ColorScheme {
        switch model.appearanceMode {
        case .system:
            return systemColorScheme
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch model.appearanceMode {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    private var isLightTheme: Bool {
        resolvedScheme == .light
    }

    private var backgroundGradient: [Color] {
        isLightTheme ? [Color(hex: 0xF5F8FC), Color(hex: 0xE8EEF7)] : [Color(hex: 0x111827), Color(hex: 0x0A0D14)]
    }

    private var logoGradient: [Color] {
        isLightTheme ? [Color(hex: 0xDDEEFF), Color(hex: 0xF8FBFF)] : [Color(hex: 0x1A3147), Color(hex: 0x101722)]
    }

    private var headerGradient: [Color] {
        isLightTheme ? [Color.white.opacity(0.86), Color(hex: 0xE7F0FA).opacity(0.72)] : [Color.white.opacity(0.075), Color.white.opacity(0.025)]
    }

    private var railBackground: Color {
        isLightTheme ? Color.black.opacity(0.045) : Color.white.opacity(0.045)
    }

    private var surfaceChrome: Color {
        isLightTheme ? Color.black.opacity(0.035) : Color.white.opacity(0.035)
    }

    private var surfaceSubtle: Color {
        isLightTheme ? Color.black.opacity(0.055) : Color.white.opacity(0.055)
    }

    private var chipBackground: Color {
        isLightTheme ? Color.black.opacity(0.08) : Color.white.opacity(0.08)
    }

    private var primaryText: Color {
        isLightTheme ? Color(hex: 0x111827) : .white
    }

    private var secondaryText: Color {
        primaryText.opacity(0.58)
    }

    private var mutedText: Color {
        primaryText.opacity(0.38)
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
    enum Mode {
        case add
        case edit(ConfiguredProviderEntry)

        var title: String {
            switch self {
            case .add: "新增模型接入"
            case .edit: "编辑模型接入"
            }
        }

        var saveTitle: String {
            switch self {
            case .add: "保存接入"
            case .edit: "保存"
            }
        }

        var smokeSection: String {
            switch self {
            case .add: "provider-add-mode"
            case .edit: "provider-edit-mode"
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    let mode: Mode
    let onClose: () -> Void
    let smokeSectionRecorder: ((String) -> Void)?
    @State private var providerId = ""
    @State private var source = "custom"
    @State private var displayPrefix = "custom/"
    @State private var apiFormat = "openai_chat"
    @State private var baseURL = ""
    @State private var modelsURL = ""
    @State private var credentialKind = "env"
    @State private var credentialReference = ""
    @State private var keychainCredential = ""
    @State private var keyHeader = "Authorization"
    @State private var modelMapping = ""
    @State private var contextWindow = ""

    init(mode: Mode, onClose: @escaping () -> Void, smokeSectionRecorder: ((String) -> Void)?) {
        self.mode = mode
        self.onClose = onClose
        self.smokeSectionRecorder = smokeSectionRecorder
        if case .edit(let provider) = mode {
            _providerId = State(initialValue: provider.id)
            _source = State(initialValue: provider.source)
            _displayPrefix = State(initialValue: provider.modelPrefix)
            _apiFormat = State(initialValue: provider.apiFormat)
            _baseURL = State(initialValue: provider.baseURL)
            _modelsURL = State(initialValue: provider.modelsURL)
            _credentialKind = State(initialValue: provider.credentialKind)
            _credentialReference = State(initialValue: provider.credentialReference)
            _keyHeader = State(initialValue: provider.keyHeader)
            _modelMapping = State(initialValue: provider.upstreamModel.isEmpty ? provider.modelId : "\(provider.modelId) -> \(provider.upstreamModel)")
            _contextWindow = State(initialValue: provider.contextWindow.map(String.init) ?? "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.title)
                        .font(.title2.weight(.semibold))
                    Text("Store credential references and routing metadata, never secret values.")
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
                field("Provider ID", $providerId, "local-bridge")
                field("Protocol", $apiFormat, "openai_chat")
                field("Base URL", $baseURL, "https://api.example.com/v1")
                field("Models URL", $modelsURL, "optional /v1/models URL")
                field("Credential mode", $credentialKind, "env | keychain | key_file")
                field("Credential ref", $credentialReference, "RELAYKIT_PROVIDER_TOKEN")
                field("Key header", $keyHeader, "Authorization")
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Model mapping")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.52))
                TextField("public/model -> upstream-model", text: $modelMapping)
                    .textFieldStyle(ProductTextFieldStyle())
            }

            if credentialKind == "keychain" {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Keychain credential")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.52))
                    SecureField("optional value to store in macOS Keychain", text: $keychainCredential)
                        .textFieldStyle(ProductTextFieldStyle())
                }
            }

            Text("Credential values are written only to macOS Keychain; provider JSON stores references.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.48))

            DisclosureGroup("Advanced") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    field("Source", $source, "custom")
                    field("Display prefix", $displayPrefix, "custom/")
                    field("Context window", $contextWindow, "128000")
                }
                .padding(.top, 8)
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.62))

            Text(validationMessage)
                .font(.caption)
                .foregroundStyle(canSave ? .white.opacity(0.56) : Color(hex: 0xFF8FA3))

            HStack {
                Spacer()
                Button("取消") { onClose() }
                    .buttonStyle(ControlButtonStyle())
                Button(mode.saveTitle) {
                    let saved: Bool
                    switch mode {
                    case .add:
                        saved = model.addProvider(draft, keychainCredential: keychainCredential)
                    case .edit(let provider):
                        saved = model.updateProvider(provider.id, draft: draft, keychainCredential: keychainCredential)
                    }
                    if saved {
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
        .preferredColorScheme(.dark)
        .smokeSection(mode.smokeSection, recorder: smokeSectionRecorder)
        .smokeSection("provider-protocol-field", recorder: smokeSectionRecorder)
        .smokeSection("provider-base-url-field", recorder: smokeSectionRecorder)
        .smokeSection("provider-models-url-field", recorder: smokeSectionRecorder)
        .smokeSection("provider-model-mapping-field", recorder: smokeSectionRecorder)
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
        let parsed = parsedMapping
        if providerId.isEmpty || parsed.publicModel.isEmpty || apiFormat.isEmpty || baseURL.isEmpty {
            return "Provider ID, model mapping, protocol, and base URL are required."
        }
        if !displayPrefix.isEmpty && !displayPrefix.hasSuffix("/") {
            return "Display prefix must end with /."
        }
        if !contextWindow.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && Int(contextWindow) == nil {
            return "Context window must be a number."
        }
        let lowerAuth = credentialReference.lowercased()
        let credentialMarkers = ["bearer ", "sk-", "api_key=", "token=", "access_token=", "refresh_token=", "password=", "secret=", "authorization="]
        if credentialMarkers.contains(where: lowerAuth.contains) {
            return "Credential values are not allowed; use a reference."
        }
        if credentialKind == "env" && !credentialReference.isEmpty && !isEnvReference(credentialReference) {
            return "Env credential refs must be environment variable names."
        }
        if credentialKind == "key_file" && !credentialReference.isEmpty &&
            !credentialReference.hasPrefix("~/") && !credentialReference.hasPrefix("/") {
            return "Key-file refs must be absolute or home-relative paths."
        }
        if credentialKind != "env" && credentialKind != "keychain" && credentialKind != "key_file" {
            return "Credential mode must be env, keychain, or key_file."
        }
        do {
            _ = try ProviderConfigDraftWriter.addProvider(draft, to: Data(#"{"providers":[]}"#.utf8))
        } catch {
            return error.localizedDescription
        }
        return "Ready to save provider metadata."
    }

    private var canSave: Bool {
        validationMessage.hasPrefix("Ready to save provider metadata")
    }

    private var draft: ProviderConfigDraft {
        let parsed = parsedMapping
        return ProviderConfigDraft(
            providerId: providerId,
            providerName: providerId,
            baseURL: baseURL,
            apiFormat: apiFormat,
            authEnv: credentialKind == "env" ? credentialReference : "",
            modelId: parsed.publicModel,
            modelDisplayName: parsed.publicModel,
            contextWindow: Int(contextWindow),
            source: source,
            modelPrefix: displayPrefix,
            modelsURL: modelsURL,
            credentialKind: credentialKind,
            credentialReference: credentialReference,
            keyHeader: keyHeader,
            upstreamModel: parsed.upstreamModel,
            streaming: true,
            tools: false,
            usage: true,
            reasoning: true,
            priority: 100,
            visible: true
        )
    }

    private var parsedMapping: (publicModel: String, upstreamModel: String) {
        let cleaned = modelMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return ("", "")
        }
        let parts = cleaned.components(separatedBy: "->")
        let publicModel = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let upstreamModel = parts.dropFirst().joined(separator: "->").trimmingCharacters(in: .whitespacesAndNewlines)
        return (publicModel, upstreamModel)
    }

    private func isEnvReference(_ value: String) -> Bool {
        let pattern = #"^[A-Za-z_][A-Za-z0-9_]*$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}

private struct ReferenceGroupDetailView: View {
    let group: LocalModelCatalog.SourceGroup
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.publicLabel)
                        .font(.title2.weight(.semibold))
                    Text("\(group.count) discovered model(s) · reference only")
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

            VStack(alignment: .leading, spacing: 8) {
                detailRow("Source", "redacted")
                detailRow("Model IDs", "redacted")
                detailRow("RelayKit route", "not configured")
                detailRow("Use", "reference/import hint")
            }

            HStack {
                Spacer()
                Button("关闭") { onClose() }
                    .buttonStyle(ControlButtonStyle())
            }
        }
        .padding(18)
        .frame(width: 420)
        .background(Color(hex: 0x101722), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(borderColor))
        .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
        .preferredColorScheme(.dark)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.white.opacity(0.52))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
        .font(.caption)
        .padding(10)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
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
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
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
                .foregroundStyle(.primary.opacity(0.32))
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.52))
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
            .foregroundStyle(prominent ? Color(hex: 0x071018) : .primary.opacity(configuration.isPressed ? 0.58 : 0.82))
            .background(prominent ? Color(hex: 0x78D8FF).opacity(configuration.isPressed ? 0.7 : 1) : Color.primary.opacity(configuration.isPressed ? 0.11 : 0.075), in: RoundedRectangle(cornerRadius: 10))
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
            .background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(borderColor))
            .foregroundStyle(.primary)
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

private let borderColor = Color.primary.opacity(0.12)

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
