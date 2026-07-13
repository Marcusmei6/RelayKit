import Foundation
import RelayKitCore
import SwiftUI

struct ContentView: View {
    @Environment(\.colorScheme) private var systemColorScheme
    @EnvironmentObject private var model: AppModel
    @State private var tab = Tab.connect
    @State private var showingProviderForm = false
    @State private var editingProvider: ConfiguredProviderEntry?
    @State private var importingGroup: LocalModelCatalog.SourceGroup?
    @State private var showingOfficialChannel = false
    @State private var officialDetailsExpanded = false
    @State private var showingDeveloperDiagnostics = false
    @State private var showingUsagePath = false
    @State private var usageActivityRange = UsageActivityRange.sevenDays
    private let smokeOpensProviderFromAddStrip: Bool
    private let showCatalogDetail: Bool
    private let showImportCandidate: Bool
    private let usageRefreshIntervalSeconds: UInt64
    private let smokeSectionRecorder: ((String) -> Void)?

    init(initialTab: Tab = .connect, showProviderForm: Bool = false, showCatalogDetail: Bool = false, showImportCandidate: Bool = false, usageRefreshIntervalSeconds: UInt64 = 60, smokeSectionRecorder: ((String) -> Void)? = nil) {
        _tab = State(initialValue: initialTab)
        _showingProviderForm = State(initialValue: false)
        self.smokeOpensProviderFromAddStrip = showProviderForm
        self.showCatalogDetail = showCatalogDetail
        self.showImportCandidate = showImportCandidate
        self.usageRefreshIntervalSeconds = max(1, usageRefreshIntervalSeconds)
        self.smokeSectionRecorder = smokeSectionRecorder
    }

    private var officialCurrentStatusTitle: String {
        ProviderFormLabels.officialStatusTitle(status: model.officialAuthStatus)
    }

    private var officialCurrentStatusIcon: String {
        switch model.officialAuthStatus {
        case "device login pending":
            return "person.badge.key"
        case "login available":
            return "checkmark.seal"
        case "route verified":
            return "checkmark.shield"
        default:
            return "xmark.seal"
        }
    }

    private var officialCurrentStatusColor: Color {
        switch model.officialAuthStatus {
        case "login available", "route verified":
            return Color(hex: 0x8BE0A4)
        case "device login pending":
            return Color(hex: 0xFFD685)
        default:
            return Color(hex: 0xFF9B9B)
        }
    }

    private var officialCurrentStatusSmokeSection: String {
        "official-current-status-" + model.officialAuthStatus.replacingOccurrences(of: " ", with: "-")
    }

    private var officialIsConnected: Bool {
        ProviderFormLabels.officialIsConnected(status: model.officialAuthStatus)
    }

    private var officialShowsDeviceLogin: Bool {
        model.officialAuthStatus == "device login pending"
            && (!model.officialAuthURL.isEmpty || !model.officialDeviceCode.isEmpty)
    }

    private var officialPrimaryActionTitle: String {
        ProviderFormLabels.officialPrimaryActionLabel(status: model.officialAuthStatus)
    }

    private var officialPrimaryActionIcon: String {
        model.officialAuthStatus == "route verified" ? "checkmark.shield" : "person.badge.key"
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
                .padding(18)
            }

            if showingOfficialChannel {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { showingOfficialChannel = false }
                officialChannelSheet
                    .padding(18)
            }

            providerImportOverlay
        }
        .foregroundStyle(primaryText)
        .preferredColorScheme(preferredColorScheme)
        .task {
            await model.refreshLocalCatalog()
            await model.refreshModels()
            if showCatalogDetail, editingProvider == nil {
                openFirstConfiguredProviderFromRowAction()
            }
            if showImportCandidate, importingGroup == nil {
                openFirstDiscoveredCandidateFromRowAction()
            }
            if smokeOpensProviderFromAddStrip, !showingProviderForm {
                openProviderFormFromAddStrip()
            }
        }
        .task(id: tab) {
            await runUsageAutoRefreshIfNeeded()
        }
    }

    private func runUsageAutoRefreshIfNeeded() async {
        guard tab == .usage else { return }
        smokeSectionRecorder?("usage-auto-refresh-enabled")
        await model.refreshUsageSummary()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: usageRefreshIntervalSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await model.refreshUsageSummary()
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
                    headerMetric("Models", "\(model.unifiedModels.count)")
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
                .accessibilityLabel(item.title)
                .accessibilityIdentifier("tab-\(item.rawValue)")
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

    private var connectTab: AnyView {
        AnyView(VStack(alignment: .leading, spacing: 14) {
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
                    codexCliSwitch
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
                        sectionEyebrow("RELAYKIT SETUP")
                        Text("模型接入")
                            .font(.headline)
                        Text("已配置项可编辑；本机发现项可导入配置。")
                            .font(.caption)
                            .foregroundStyle(secondaryText)
                    }
                    Spacer()
                    statusSummaryChips
                }
                modelAccessList
                addStrip
            }
            .smokeRecordOnly("configured-providers", recorder: smokeSectionRecorder)
            .smokeRecordOnly("import-candidates", recorder: smokeSectionRecorder)
            .smokeRecordOnly("add-strip", recorder: smokeSectionRecorder)
            .smokeRecordOnly("auth-blocked-state", recorder: smokeSectionRecorder)
            .smokeRecordOnly("status-summary-inline", recorder: smokeSectionRecorder)
            .smokeRecordOnly("model-access-merged", recorder: smokeSectionRecorder)
        })
    }

    private var codexCliSwitch: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "terminal.fill")
                Spacer()
                Text("SELECTED")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(hex: 0x78D8FF))
            }
            Text("Codex")
                .font(.headline)
            Text(model.codexConnectionStatus)
                .font(.caption)
                .foregroundStyle(secondaryText)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0x78D8FF).opacity(0.11), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: 0x78D8FF).opacity(0.42)))
    }

    @ViewBuilder
    private var providerImportOverlay: some View {
        if let importingGroup {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { self.importingGroup = nil }
            ProviderFormView(
                mode: .import(importingGroup, catalogURL: model.localCatalogURL.absoluteString),
                onClose: {
                    self.importingGroup = nil
                },
                smokeSectionRecorder: smokeSectionRecorder
            )
            .environmentObject(model)
            .smokeSection("provider-import-modal", recorder: smokeSectionRecorder)
            .smokeSection("provider-modal", recorder: smokeSectionRecorder)
            .padding(18)
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

    private var statusSummaryChips: some View {
        HStack(spacing: 6) {
            summaryChip("Providers", "\(model.configuredProviders.count)")
            summaryChip("Models", "\(model.unifiedModels.count)")
            summaryChip("Gateway", productGatewayState)
        }
        .smokeSection("status-summary-inline", recorder: smokeSectionRecorder)
    }

    private func summaryChip(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(mutedText)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(primaryText.opacity(0.82))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(chipBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor))
    }

    private var modelAccessList: AnyView {
        let discoveredGroups = model.localCatalog?.sourceGroups ?? []
        return AnyView(VStack(spacing: 8) {
            officialProviderRow
            if model.configuredProviders.isEmpty && discoveredGroups.isEmpty && model.unifiedModels.isEmpty {
                EmptyProductState(
                    title: "No RelayKit providers",
                    message: "Add one provider to route additional models through RelayKit.",
                    icon: "square.stack.3d.up.slash"
                )
                .frame(maxWidth: .infinity, minHeight: 130)
                .smokeSection("merged-empty-state", recorder: smokeSectionRecorder)
            } else {
                ForEach(model.configuredProviders) { provider in
                    Button {
                        openConfiguredProviderFromRowAction(provider)
                    } label: {
                        configuredProviderRow(provider)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(provider.name)
                    .accessibilityIdentifier("provider-\(provider.id)")
                }
                ForEach(discoveredGroups, id: \.source) { group in
                    Button {
                        openDiscoveredCandidateFromRowAction(group)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "square.and.arrow.down")
                                .foregroundStyle(Color(hex: 0xFFD685))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(group.publicLabel) · discovered")
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text("\(group.count) model(s) · \(group.firstModelId.isEmpty ? "model pending" : group.firstModelId)")
                                    .font(.caption)
                                    .foregroundStyle(secondaryText)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text("IMPORT")
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
            }
        }
        .smokeRecordOnly("model-access-merged", recorder: smokeSectionRecorder))
    }

    private var officialProviderRow: some View {
        Button {
            openOfficialChannelFromRowAction()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal")
                    .foregroundStyle(Color(hex: 0x78D8FF))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text("OpenAI Official / Codex Official")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(ProviderFormLabels.officialRowSubtitle(status: model.officialAuthStatus))
                        .font(.caption)
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(mutedText)
                Text("AUTH")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(mutedText)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(surfaceSubtle, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: 0x78D8FF).opacity(0.32)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("OpenAI Official / Codex Official")
        .accessibilityIdentifier("official-provider-row")
        .smokeSection("official-provider-row", recorder: smokeSectionRecorder)
    }

    private var officialChannelSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("认证官方 Codex 通道")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(primaryText.opacity(0.94))
                    Text("使用 Codex 官方 device authorization 登录到 RelayKit isolated CODEX_HOME。不会读取、复制或复用全局 Codex auth。")
                        .font(.caption)
                        .foregroundStyle(secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    showingOfficialChannel = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(ControlButtonStyle())
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    officialStatusRow(
                        icon: officialCurrentStatusIcon,
                        title: officialCurrentStatusTitle,
                        detail: model.officialAuthDetail,
                        color: officialCurrentStatusColor
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .smokeSection(officialCurrentStatusSmokeSection, recorder: smokeSectionRecorder)

                    Button {
                        smokeSectionRecorder?("official-auth-cta-clicked")
                        model.connectOfficial()
                    } label: {
                        Label(officialPrimaryActionTitle, systemImage: officialPrimaryActionIcon)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ControlButtonStyle(prominent: true))
                    .disabled(ProviderFormLabels.officialPrimaryActionDisabled(status: model.officialAuthStatus, inProgress: model.officialAuthInProgress))
                    .smokeSection("official-auth-cta-action", recorder: smokeSectionRecorder)
                    .smokeSection(officialIsConnected ? "official-connected-cta-disabled" : "", recorder: smokeSectionRecorder)
                }

                HStack(spacing: 8) {
                    Button {
                        smokeSectionRecorder?("official-status-refresh-clicked")
                        model.refreshOfficialAuthStatus()
                    } label: {
                        Label(ProviderFormLabels.officialChannelActionLabels[1], systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(OfficialSecondaryButtonStyle())
                    .smokeSection("official-status-refresh-action", recorder: smokeSectionRecorder)

                    Button {
                        model.disconnectOfficial()
                    } label: {
                        Label(ProviderFormLabels.officialChannelActionLabels[2], systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(OfficialSecondaryButtonStyle())
                    .smokeSection("official-disconnect-action", recorder: smokeSectionRecorder)
                }
            }
            .padding(12)
            .background(surfaceSubtle, in: RoundedRectangle(cornerRadius: 12))
            .smokeSection("official-product-auth-actions", recorder: smokeSectionRecorder)

            if officialShowsDeviceLogin {
                VStack(alignment: .leading, spacing: 5) {
                    if !model.officialAuthURL.isEmpty {
                        Text(model.officialAuthURL)
                            .font(.caption.monospaced())
                            .foregroundStyle(primaryText.opacity(0.80))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    if !model.officialDeviceCode.isEmpty {
                        HStack(spacing: 10) {
                            Text(model.officialDeviceCode)
                                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color(hex: 0x78D8FF))
                                .textSelection(.enabled)
                            Button {
                                smokeSectionRecorder?("official-copy-device-code-clicked")
                                model.copyOfficialDeviceCode()
                            } label: {
                                Label("Copy code", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(OfficialSecondaryButtonStyle())
                            .smokeSection("official-copy-device-code-action", recorder: smokeSectionRecorder)
                        }
                    }
                    if !model.officialAuthURL.isEmpty {
                        Button {
                            smokeSectionRecorder?("official-open-signin-link-clicked")
                            model.openOfficialAuthLink()
                        } label: {
                            Label("Open sign-in link", systemImage: "safari")
                        }
                        .buttonStyle(OfficialSecondaryButtonStyle())
                        .padding(.top, 4)
                        .smokeSection("official-open-signin-link-action", recorder: smokeSectionRecorder)
                    }
                }
                .padding(10)
                .background(chipBackground, in: RoundedRectangle(cornerRadius: 10))
                .smokeSection("official-device-login-visible", recorder: smokeSectionRecorder)
            }

            Text("RelayKit 只保存自己的 isolated Codex 登录目录引用；不能复制 ~/.codex/auth.json，也不能改 ~/.codex/config.toml。")
                .font(.caption)
                .foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .smokeSection("official-token-boundary", recorder: smokeSectionRecorder)

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    officialDetailsExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: officialDetailsExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text("What these states mean")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .smokeSection("official-state-details-toggle", recorder: smokeSectionRecorder)

                if officialDetailsExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        officialStatusRow(
                            icon: "xmark.seal",
                            title: ProviderFormLabels.officialChannelStatusLabels[0],
                            detail: "尚未在 isolated CODEX_HOME 内完成官方 device 登录。",
                            color: Color(hex: 0xFF9B9B)
                        )
                        officialStatusRow(
                            icon: "person.badge.key",
                            title: ProviderFormLabels.officialChannelStatusLabels[1],
                            detail: "Connect Official 已启动，正在等待 device link/code 完成。",
                            color: Color(hex: 0xFFD685)
                        )
                        .smokeSection("official-device-login-pending-state", recorder: smokeSectionRecorder)
                        officialStatusRow(
                            icon: "checkmark.seal",
                            title: ProviderFormLabels.officialChannelStatusLabels[2],
                            detail: "isolated Codex 已登录，但还需要本次 proof 产生新的 route usage。",
                            color: Color(hex: 0x78D8FF)
                        )
                        .smokeSection("official-login-available-state", recorder: smokeSectionRecorder)
                        officialStatusRow(
                            icon: "checkmark.shield",
                            title: ProviderFormLabels.officialChannelStatusLabels[3],
                            detail: "只有本次 official isolated proof 里 gpt-5.5 / demo 都 completed 后才进入此状态。",
                            color: Color(hex: 0x8BE0A4)
                        )
                        .smokeSection("official-route-verified-state", recorder: smokeSectionRecorder)
                    }
                    .padding(.top, 2)
                }
            }
            .font(.caption)
            .foregroundStyle(primaryText.opacity(0.76))
            .padding(12)
            .background(surfaceChrome, in: RoundedRectangle(cornerRadius: 12))
            .smokeSection(officialDetailsExpanded ? "official-state-details-expanded" : "official-state-details-collapsed", recorder: smokeSectionRecorder)
        }
        .padding(18)
        .frame(width: 484)
        .background(sheetBackground, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(borderColor))
        .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
        .smokeSection("official-channel-sheet", recorder: smokeSectionRecorder)
    }

    private func officialStatusRow(icon: String, title: String, detail: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(primaryText.opacity(0.86))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func openOfficialChannelFromRowAction() {
        smokeSectionRecorder?("official-provider-row-action")
        showingOfficialChannel = true
    }

    private func configuredProviderRow(_ provider: ConfiguredProviderEntry) -> some View {
        let health = model.providerHealth(for: provider)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(Color(hex: 0x78D8FF))
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(provider.models.count) model(s) · \(provider.apiFormat)")
                        .font(.caption)
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                Text(provider.credentialKind.uppercased())
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(hex: 0x78D8FF))
            }
            HStack(spacing: 8) {
                Image(systemName: health.hidden.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(health.hidden.isEmpty ? Color(hex: 0x8BE0A4) : Color(hex: 0xFFD685))
                Text(ProviderFormLabels.providerHealthSummary(saved: health.saved, available: health.available, hidden: health.hidden.count))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
                Spacer()
            }
            .smokeSection(health.hidden.isEmpty ? "provider-health-summary" : "provider-health-summary-hidden", recorder: smokeSectionRecorder)
            ForEach(provider.models) { model in
                HStack(spacing: 8) {
                    Image(systemName: "cube")
                        .font(.system(size: 11))
                        .foregroundStyle(mutedText)
                    Text(model.displayName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(model.id)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(chipBackground, in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(surfaceSubtle, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(borderColor))
        .smokeSection("configured-provider-models-inline", recorder: smokeSectionRecorder)
    }

    private var relayKitProductStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("RelayKit status")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(productGatewayState.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(productGatewayState == "running" ? Color(hex: 0x78D8FF) : mutedText)
            }
            acceptanceLine("Providers", "\(model.configuredProviders.count)")
            acceptanceLine("Total models", "\(model.unifiedModels.count)")
            acceptanceLine("Gateway", productGatewayState)
        }
    }

    private var productGatewayState: String {
        model.gatewayStatus == "running" || model.gatewayStatus == "ok" ? "running" : "ready"
    }

    private func acceptanceLine(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(secondaryText)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(value.contains("changed") || value.contains("invalid") || value.contains("missing") ? Color(hex: 0xFF8F70) : primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func unifiedModelRow(_ item: UnifiedModelEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.origin == "catalog" ? "terminal" : "point.3.connected.trianglepath.dotted")
                .foregroundStyle(item.origin == "catalog" ? Color(hex: 0x78D8FF) : Color(hex: 0xFFD685))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName ?? item.modelId)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.modelId)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.origin.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(mutedText)
                Text(item.contextWindow.map { "\($0)" } ?? item.detail)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surfaceSubtle, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(borderColor))
        .smokeSection("unified-model-row", recorder: smokeSectionRecorder)
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
        .accessibilityLabel("新增模型接入")
        .accessibilityIdentifier("provider-add-entry")
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

    private func openFirstDiscoveredCandidateFromRowAction() {
        guard let group = model.localCatalog?.sourceGroups.first else { return }
        openDiscoveredCandidateFromRowAction(group)
    }

    private func openDiscoveredCandidateFromRowAction(_ group: LocalModelCatalog.SourceGroup) {
        smokeSectionRecorder?("discovered-row-action")
        importingGroup = group
    }

    private var usageTab: some View {
        let analytics = usageAnalytics
        return VStack(alignment: .leading, spacing: 14) {
            SectionCard {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        sectionEyebrow("LOCAL USAGE")
                        Text("Usage")
                            .font(.headline)
                        Text("只统计经过 RelayKit 本地 gateway 的 usage JSONL；Official 只代表 RelayKit official route。")
                            .font(.caption)
                            .foregroundStyle(secondaryText)
                    }
                    Spacer()
                Button("Refresh") {
                    Task { await model.refreshUsageSummary() }
                }
                .buttonStyle(ControlButtonStyle(prominent: true))
                .accessibilityLabel("Refresh usage")
                .accessibilityIdentifier("usage-refresh")
                .disabled(model.usageRefreshInProgress)
                }

                usageKpis(analytics)
            }
            .smokeSection("tab-usage", recorder: smokeSectionRecorder)
            .smokeSection("usage-kpis", recorder: smokeSectionRecorder)
            .smokeSection("usage-cost-unavailable", recorder: smokeSectionRecorder)

            SectionCard {
                HStack {
                    Text("Activity")
                        .font(.headline)
                    Spacer()
                    Picker("Activity range", selection: $usageActivityRange) {
                        Text("7D").tag(UsageActivityRange.sevenDays)
                        Text("1M").tag(UsageActivityRange.oneMonth)
                        Text("1Y").tag(UsageActivityRange.oneYear)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                    .smokeSection("usage-activity-range-control", recorder: smokeSectionRecorder)
                }
                usageActivityHeatmap(analytics)
            }
            .smokeSection("usage-activity-heatmap", recorder: smokeSectionRecorder)

            SectionCard {
                HStack {
                    Text("Provider / source")
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
                usageProviderRows(analytics)
            }
            .smokeSection("usage-provider-groups", recorder: smokeSectionRecorder)

            SectionCard {
                Text("Models")
                    .font(.headline)
                usageModelRows(analytics)
            }
            .smokeSection("usage-model-rollups", recorder: smokeSectionRecorder)
        }
    }

    private var usageAnalytics: UsageAnalytics {
        UsageAnalytics(model.usageSummaries)
    }

    private func usageKpis(_ analytics: UsageAnalytics) -> some View {
        let topModel = analytics.topModelSevenDays ?? "n/a"
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                kpi("Today tokens", UsageAnalytics.formatTokens(analytics.todayTokens), analytics.costLabel)
                kpi("7 days tokens", UsageAnalytics.formatTokens(analytics.sevenDayTokens), "local JSONL")
            }
            HStack(spacing: 8) {
                kpi("All time tokens", UsageAnalytics.formatTokens(analytics.allTimeTokens), "RelayKit only")
                kpi("Requests", "\(analytics.requestCount)", "gateway events")
            }
            HStack(spacing: 8) {
                kpi(
                    "Top model 7D",
                    UsageAnalytics.readableModelName(topModel),
                    topModel.contains("/") ? "\((topModel.split(separator: "/").first.map(String.init) ?? "")) · by tokens" : "by tokens",
                    valueSize: 16,
                    valueLineLimit: 2
                )
                .smokeSection("usage-top-model-readable", recorder: smokeSectionRecorder)
                kpi("Active days", "\(analytics.activeDayCount)", ">= 1 event")
            }
        }
    }

    private func kpi(_ title: String, _ value: String, _ note: String, valueSize: CGFloat = 21, valueLineLimit: Int = 1) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(secondaryText)
            Text(value)
                .font(.system(size: min(valueSize, 19), weight: .semibold, design: .rounded))
                .lineLimit(valueLineLimit)
                .truncationMode(.middle)
                .minimumScaleFactor(0.82)
            Text(note)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(mutedText)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surfaceSubtle, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(borderColor))
    }

    private func usageProviderRows(_ analytics: UsageAnalytics) -> some View {
        VStack(spacing: 8) {
            if analytics.providerRollups.isEmpty {
                usageEmptyState
            } else {
                ForEach(analytics.providerRollups, id: \.name) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(item.name)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(item.lastActiveDay)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(mutedText)
                        }
                        Text("Top model: \(item.topModel)")
                            .font(.caption)
                            .foregroundStyle(secondaryText)
                            .lineLimit(1)
                        HStack {
                            usageChip("\(item.requests) req")
                            usageChip("\(UsageAnalytics.formatTokens(item.tokens)) tokens")
                        }
                    }
                    .padding(12)
                    .background(surfaceSubtle, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(borderColor))
                }
            }
        }
    }

    private func usageModelRows(_ analytics: UsageAnalytics) -> some View {
        VStack(spacing: 8) {
            if analytics.modelRollups.isEmpty {
                usageEmptyState
            } else {
                ForEach(analytics.modelRollups, id: \.model) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(item.model)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            Text(item.providerId)
                                .font(.caption.monospaced())
                                .foregroundStyle(mutedText)
                        }
                        HStack {
                            usageChip("today \(UsageAnalytics.formatTokens(item.todayTokens))")
                            usageChip("7d \(UsageAnalytics.formatTokens(item.sevenDayTokens))")
                            usageChip("all \(UsageAnalytics.formatTokens(item.allTimeTokens))")
                            usageChip("\(item.requests) req")
                        }
                    }
                    .padding(12)
                    .background(surfaceSubtle, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(borderColor))
                }
            }
        }
    }

    private func usageActivityHeatmap(_ analytics: UsageAnalytics) -> some View {
        let buckets = analytics.activityBuckets(range: usageActivityRange)
        let columns = Array(repeating: GridItem(.fixed(9), spacing: 4), count: usageActivityColumnCount)
        return VStack(alignment: .leading, spacing: 10) {
            Text("\(analytics.activityUnitLabel(range: usageActivityRange)) · \(buckets.filter(\.isActive).count) active bucket(s)")
                .font(.caption)
                .foregroundStyle(secondaryText)
                .smokeSection("usage-activity-unit-label", recorder: smokeSectionRecorder)
            if model.usageSummaries.isEmpty {
                usageEmptyState
            } else {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(buckets) { bucket in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(usageActivityColor(tokens: bucket.tokens))
                            .frame(width: 9, height: 9)
                            .help("\(bucket.label): \(UsageAnalytics.formatTokens(bucket.tokens)) tokens")
                    }
                }
            }
        }
    }

    private var usageActivityColumnCount: Int {
        switch usageActivityRange {
        case .sevenDays: 14
        case .oneMonth: 15
        case .oneYear: 26
        }
    }

    private var usageEmptyState: some View {
        EmptyProductState(
            title: "No local usage yet",
            message: "RelayKit 只统计经过本地 gateway 的请求。",
            icon: "chart.bar"
        )
        .frame(maxWidth: .infinity, minHeight: 112)
        .smokeSection("usage-empty-state", recorder: smokeSectionRecorder)
    }

    private func usageActivityColor(tokens: Int) -> Color {
        if tokens <= 0 {
            return surfaceSubtle
        }
        if tokens < 200 {
            return Color(hex: 0x86EFAC).opacity(0.45)
        }
        if tokens < 800 {
            return Color(hex: 0x22C55E).opacity(0.72)
        }
        return Color(hex: 0x15803D)
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
                    sectionEyebrow("GENERAL")
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
                    Divider().overlay(borderColor)
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
            }
            .smokeSection("settings-general-group", recorder: smokeSectionRecorder)
            .smokeSection("appearance-control", recorder: smokeSectionRecorder)
            .smokeSection("launch-login-control", recorder: smokeSectionRecorder)

            SectionCard {
                sectionEyebrow("GATEWAY")
                settingsInfoRow(title: "Gateway status", subtitle: model.gatewayStatus)
                settingsInfoRow(title: "Port", subtitle: "127.0.0.1:19777")
                HStack(spacing: 8) {
                    Button("Start") { model.startGateway() }
                        .buttonStyle(ControlButtonStyle(prominent: true))
                        .accessibilityLabel("Start gateway")
                        .accessibilityIdentifier("gateway-start")
                    Button("Stop") { model.stopGateway() }
                        .buttonStyle(ControlButtonStyle())
                    Button("Restart") { model.restartGateway() }
                        .buttonStyle(ControlButtonStyle())
                        .accessibilityLabel("Restart gateway")
                        .accessibilityIdentifier("gateway-restart")
                }
                settingsInfoRow(title: "Usage log path", subtitle: shortPath(model.usageLogPath))
                settingsInfoRow(title: "Helper log path", subtitle: "/tmp/relay.out / /tmp/relay.err")
            }
            .smokeRecordOnly("settings-gateway-group", recorder: smokeSectionRecorder)
            .smokeRecordOnly("settings-actions", recorder: smokeSectionRecorder)
            .smokeRecordOnly("settings-gateway-port-fixed", recorder: smokeSectionRecorder)

            SectionCard {
                sectionEyebrow("CODEX INTEGRATION")
                settingsInfoRow(title: "Official auth status", subtitle: model.officialAuthStatus)
                settingsInfoRow(title: "Isolated CODEX_HOME", subtitle: shortPath(RelayKitPaths.officialCodexHomePath()))
                settingsInfoRow(
                    title: "Route proof",
                    subtitle: model.officialAuthStatus == "route verified" ? "Route verified" : "Not verified"
                )
                Text("RelayKit 不复制、不读取、不保存全局 ~/.codex/auth.json。官方登录只保存在 RelayKit isolated CODEX_HOME。")
                    .font(.caption)
                    .foregroundStyle(secondaryText)
            }
            .smokeSection("settings-codex-group", recorder: smokeSectionRecorder)

            SectionCard {
                sectionEyebrow("DATA & PRIVACY")
                settingsInfoRow(title: "Usage data", subtitle: "Local usage JSONL only")
                settingsInfoRow(title: "Credentials", subtitle: "Credential values stored in Keychain")
                settingsInfoRow(title: "Provider JSON", subtitle: "Stores credential references only")
            }
            .smokeSection("settings-data-privacy-group", recorder: smokeSectionRecorder)

            SectionCard {
                Button {
                    showingDeveloperDiagnostics.toggle()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            sectionEyebrow("DEVELOPER / DIAGNOSTICS")
                            Text("Developer / Diagnostics")
                                .font(.headline)
                            Text("Manual proof, raw local paths, and evidence paths.")
                                .font(.caption)
                                .foregroundStyle(secondaryText)
                        }
                        Spacer()
                        Image(systemName: showingDeveloperDiagnostics ? "chevron.up" : "chevron.down")
                            .foregroundStyle(secondaryText)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Developer / Diagnostics")
                .accessibilityIdentifier("settings-developer-toggle")
                .smokeRecordOnly(showingDeveloperDiagnostics ? "settings-developer-expanded" : "settings-developer-collapsed", recorder: smokeSectionRecorder)

                if showingDeveloperDiagnostics {
                    ManualProofEntryView(
                        acceptance: model.desktopAcceptance,
                        secondaryText: secondaryText,
                        surfaceSubtle: surfaceSubtle,
                        open: {
                            smokeSectionRecorder?("desktop-acceptance-manual-proof-action")
                            model.openManualProofTerminal()
                        }
                    )
                    Divider().overlay(borderColor)
                    Text("Raw local paths")
                        .font(.subheadline.weight(.semibold))
                    VStack(spacing: 8) {
                        labeledField("Gateway binary", text: $model.gatewayBinaryPath)
                        labeledField("Provider config", text: $model.providerConfigPath)
                        labeledField("Usage log", text: $model.usageLogPath)
                        labeledField("Codex source example", text: $model.codexSourcePath)
                        labeledField("Codex target", text: $model.codexTargetPath)
                    }
                    Text("Evidence path: \(shortPath(RelayKitPaths.officialRouteEvidencePath()))")
                        .font(.caption.monospaced())
                        .foregroundStyle(mutedText)
                }
            }
            .smokeRecordOnly("settings-developer-group", recorder: smokeSectionRecorder)
            .smokeRecordOnly("developer-verification", recorder: smokeSectionRecorder)
            .smokeRecordOnly("advanced-paths", recorder: smokeSectionRecorder)
            .smokeRecordOnly(showingDeveloperDiagnostics ? "desktop-acceptance-manual-proof-entry" : "desktop-acceptance-manual-proof-entry-hidden", recorder: smokeSectionRecorder)
        }
    }

    private func settingsInfoRow(title: String, subtitle: String) -> some View {
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

    private var sheetBackground: Color {
        isLightTheme ? Color(hex: 0xF8FBFF) : Color(hex: 0x101722)
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

private struct ProviderModelRowDraft: Identifiable, Equatable {
    let id = UUID()
    var modelId: String
    var displayName: String
    var upstreamModel: String
}

private struct ProviderHTTPProbe {
    let status: Int
    let latencyMS: Int
    let contentType: String
    let data: Data
}

private struct ProviderModelDiscoveryResult {
    let kind: String
    let rows: [ProviderModelRowDraft]
    let endpoint: String
    let status: Int?
    let latencyMS: Int?
}

private struct ProviderFormView: View {
    enum Mode {
        case add
        case edit(ConfiguredProviderEntry)
        case `import`(LocalModelCatalog.SourceGroup, catalogURL: String)

        var title: String {
            switch self {
            case .add: "新增模型接入"
            case .edit: "编辑模型接入"
            case .import: "导入本机发现"
            }
        }

        var saveTitle: String {
            switch self {
            case .add: "保存接入"
            case .edit: "保存"
            case .import: "导入并保存"
            }
        }

        var smokeSection: String {
            switch self {
            case .add: "provider-add-mode"
            case .edit: "provider-edit-mode"
            case .import: "provider-import-mode"
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var systemColorScheme
    let mode: Mode
    let onClose: () -> Void
    let smokeSectionRecorder: ((String) -> Void)?
    @State private var providerId = ""
    @State private var providerName = ""
    @State private var source = "custom"
    @State private var displayPrefix = "custom/"
    @State private var apiFormat = "openai_chat"
    @State private var upstreamProtocolSelectedExplicitly = false
    @State private var baseURL = ""
    @State private var modelsURL = ""
    @State private var credentialReference = ""
    @State private var existingCredentialKind = ""
    @State private var keychainCredential = ""
    @State private var showsNewAPIKey = false
    @State private var savedKeyUnavailable = false
    @State private var savedKeyLoadAttempted = false
    @State private var keyHeader = "Authorization"
    @State private var modelRows: [ProviderModelRowDraft] = [ProviderModelRowDraft(modelId: "", displayName: "", upstreamModel: "")]
    @State private var modelDetectionStatus = "Detect from the provider endpoint or add models manually."
    @State private var isDetectingModels = false
    @State private var isTestingConnection = false
    @State private var connectionTestKind = ""
    @State private var connectionTestLatencyMS: Int?
    @State private var connectionTestModelCount = 0
    @State private var connectionReachableModelCount = 0
    @State private var connectionUnavailableModelCount = 0
    @State private var connectionTestHTTPStatus: Int?
    @State private var connectionDiscoveredEndpoint = ""
    @State private var connectionDiscoveredRows: [ProviderModelRowDraft] = []
    @State private var connectionUsedReachableRows = false
    @State private var manualModelEntryEnabled = false
    @State private var contextWindow = ""
    @State private var isAdvancedExpanded = false
    @State private var hasExpandedAdvanced = false
    @State private var isHiddenModelsExpanded = false

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

    private var isLightTheme: Bool { resolvedScheme == .light }
    private var primaryText: Color { isLightTheme ? Color(hex: 0x111827) : .white }
    private var secondaryText: Color { primaryText.opacity(0.58) }
    private var mutedText: Color { primaryText.opacity(0.38) }
    private var surfaceChrome: Color { isLightTheme ? Color.black.opacity(0.035) : Color.white.opacity(0.035) }
    private var surfaceSubtle: Color { isLightTheme ? Color.black.opacity(0.055) : Color.white.opacity(0.055) }
    private var chipBackground: Color { isLightTheme ? Color.black.opacity(0.08) : Color.white.opacity(0.08) }
    private var sheetBackground: Color { isLightTheme ? Color(hex: 0xF8FBFF) : Color(hex: 0x101722) }

    init(mode: Mode, onClose: @escaping () -> Void, smokeSectionRecorder: ((String) -> Void)?) {
        self.mode = mode
        self.onClose = onClose
        self.smokeSectionRecorder = smokeSectionRecorder
        if case .edit(let provider) = mode {
            _providerId = State(initialValue: provider.id)
            _providerName = State(initialValue: provider.name)
            _source = State(initialValue: provider.source)
            _displayPrefix = State(initialValue: provider.modelPrefix)
            _apiFormat = State(initialValue: provider.apiFormat)
            _upstreamProtocolSelectedExplicitly = State(initialValue: true)
            _baseURL = State(initialValue: provider.baseURL)
            _modelsURL = State(initialValue: provider.modelsURL)
            _credentialReference = State(initialValue: provider.credentialReference)
            _existingCredentialKind = State(initialValue: provider.credentialKind)
            _keyHeader = State(initialValue: provider.keyHeader)
            _modelRows = State(initialValue: provider.models.map {
                ProviderModelRowDraft(modelId: $0.id, displayName: $0.displayName == $0.id ? "" : $0.displayName, upstreamModel: $0.upstreamModel == $0.id ? "" : $0.upstreamModel)
            })
            _modelDetectionStatus = State(initialValue: "Loaded \(provider.models.count) saved model(s) from provider config.")
            _contextWindow = State(initialValue: provider.contextWindow.map(String.init) ?? "")
        } else if case .import(let group, let catalogURL) = mode {
            _providerId = State(initialValue: "import-\(group.source)")
            _providerName = State(initialValue: group.publicLabel)
            _source = State(initialValue: group.source)
            _displayPrefix = State(initialValue: "\(group.source)/")
            _apiFormat = State(initialValue: group.protocolSummary)
            _upstreamProtocolSelectedExplicitly = State(initialValue: true)
            _baseURL = State(initialValue: group.executionBaseURL)
            _modelsURL = State(initialValue: catalogURL)
            _credentialReference = State(initialValue: "")
            _modelRows = State(initialValue: group.modelSummaries.map {
                ProviderModelRowDraft(modelId: $0.id, displayName: ($0.displayName ?? "") == $0.id ? "" : ($0.displayName ?? ""), upstreamModel: ($0.upstreamModel ?? "") == $0.id ? "" : ($0.upstreamModel ?? ""))
            })
            _contextWindow = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            formHeader
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        field("Provider name", $providerName, "My gateway")
                            .smokeSection("provider-name-field", recorder: smokeSectionRecorder)
                        field("API base URL", $baseURL, "https://gateway.example/api")
                            .smokeSection("provider-base-url-field", recorder: smokeSectionRecorder)
                    }

                    AnyView(apiKeyField)
                    AnyView(modelsSection)
                    AnyView(advancedSection)

                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(canSave ? secondaryText : Color(hex: 0xFF8FA3))
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: isAdvancedExpanded ? 520 : 420)
            .smokeSection(isAdvancedExpanded ? "provider-advanced-scroll-container" : "", recorder: smokeSectionRecorder)

            HStack {
                Spacer()
                Button("取消") { onClose() }
                    .buttonStyle(ControlButtonStyle())
                    .accessibilityLabel("Cancel provider")
                    .accessibilityIdentifier("provider-form-cancel")
                Button(mode.saveTitle) { save() }
                    .buttonStyle(ControlButtonStyle(prominent: true))
                    .accessibilityLabel("Save provider")
                    .accessibilityIdentifier("provider-form-save")
                    .disabled(!canSave)
            }
            .padding(.top, 12)
        }
        .padding(18)
        .frame(width: 484)
        .background(sheetBackground, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(borderColor))
        .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
        .smokeSection(mode.smokeSection, recorder: smokeSectionRecorder)
        .smokeSection(importPrefilledSection, recorder: smokeSectionRecorder)
        .smokeSection(importMissingRequiredSection, recorder: smokeSectionRecorder)
        .smokeSection(editPrefilledBaseURLSection, recorder: smokeSectionRecorder)
        .smokeSection(editLoadedModelsSection, recorder: smokeSectionRecorder)
        .smokeSection(isAdvancedExpanded ? "provider-advanced-expanded" : "provider-advanced-default-collapsed", recorder: smokeSectionRecorder)
        .onChange(of: isAdvancedExpanded) { _, expanded in
            if expanded {
                hasExpandedAdvanced = true
                smokeSectionRecorder?("provider-advanced-expanded")
                return
            }
            if hasExpandedAdvanced {
                smokeSectionRecorder?("provider-advanced-collapsed-after-expand")
            }
        }
        .onAppear {
            loadSavedAPIKeyIfNeeded()
        }
    }

    private var formHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(mode.title)
                    .font(.title2.weight(.semibold))
                Text("Add a provider endpoint, then detect or add models for Codex.")
                    .font(.caption)
                    .foregroundStyle(secondaryText)
            }
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(ControlButtonStyle())
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isAdvancedExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isAdvancedExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Advanced")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(secondaryText)
            .smokeSection("provider-advanced-toggle-row", recorder: smokeSectionRecorder)

            if isAdvancedExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Use only for non-default models URL, auth header, or upstream model name.")
                        .font(.system(size: 10))
                        .foregroundStyle(mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Upstream protocol")
                            .font(.caption)
                            .foregroundStyle(secondaryText)
                        Picker("", selection: $apiFormat) {
                            ForEach(ProviderFormLabels.upstreamProtocolOptions, id: \.id) { option in
                                Text(option.label)
                                    .tag(option.id)
                                    .disabled(!option.isEnabled)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .onTapGesture {
                            upstreamProtocolSelectedExplicitly = true
                        }
                        .onChange(of: apiFormat) { _, _ in
                            upstreamProtocolSelectedExplicitly = true
                        }
                        .smokeSection("provider-upstream-protocol-selector", recorder: smokeSectionRecorder)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        field("Custom models URL", $modelsURL, "Default: <base>/models")
                            .smokeSection("provider-models-url-field", recorder: smokeSectionRecorder)
                        field("Custom auth header", $keyHeader, "Authorization")
                            .smokeSection("provider-auth-header-field", recorder: smokeSectionRecorder)
                        field("Upstream model override", firstUpstreamModelBinding, firstModelPlaceholder)
                            .smokeSection("provider-upstream-model-override-field", recorder: smokeSectionRecorder)
                    }
                }
                .padding(.top, 2)
            }
        }
        .smokeSection("provider-advanced-options", recorder: smokeSectionRecorder)
    }

    private func save() {
        let saved: Bool
        switch mode {
        case .add:
            saved = model.addProvider(draft, keychainCredential: keychainCredential)
        case .edit(let provider):
            saved = model.updateProvider(provider.id, draft: draft, keychainCredential: keychainCredential)
        case .import:
            saved = model.addProvider(draft, keychainCredential: keychainCredential)
        }
        if saved {
            onClose()
        }
    }

    private func field(_ label: String, _ value: Binding<String>, _ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(secondaryText)
            TextField(prompt, text: value)
                .textFieldStyle(ProductTextFieldStyle())
                .accessibilityLabel("\(label) field")
                .accessibilityIdentifier("provider-\(label.lowercased().replacingOccurrences(of: " ", with: "-"))-field")
        }
    }

    private var apiKeyField: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("API key")
                .font(.caption)
                .foregroundStyle(secondaryText)
            Text(apiKeyStatusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(primaryText.opacity(0.86))
                .smokeSection(hasExistingKeychainReference ? "api-key-saved-state" : "", recorder: smokeSectionRecorder)
            apiKeyEntryField
            Text(apiKeyHelpText)
                .font(.system(size: 10))
                .foregroundStyle(secondaryText)
                .smokeSection(savedKeyDisabledReasonSmokeSection, recorder: smokeSectionRecorder)
        }
        .smokeSection("provider-api-key-field", recorder: smokeSectionRecorder)
    }

    private var apiKeyEntryField: some View {
        HStack(spacing: 8) {
            apiKeyReplacementInput
                .frame(maxWidth: .infinity)

            Button {
                showsNewAPIKey.toggle()
                smokeSectionRecorder?("api-key-eye-toggle-action")
            } label: {
                Image(systemName: showsNewAPIKey ? "eye.slash" : "eye")
                    .frame(width: 22)
            }
            .accessibilityLabel(ProviderFormLabels.apiKeyEyeLabel(showingKey: showsNewAPIKey))
            .accessibilityIdentifier(ProviderFormLabels.apiKeyEyeLabel(showingKey: showsNewAPIKey))
            .buttonStyle(.plain)
            .foregroundStyle(primaryText.opacity(keychainCredential.isEmpty ? 0.36 : 0.72))
            .disabled(keychainCredential.isEmpty)
            .help("Show or hide this API key")
            .smokeSection(hasExistingKeychainReference ? "api-key-eye-saved-state" : "api-key-eye-new-input", recorder: smokeSectionRecorder)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor))
        .smokeSection(apiKeyInputSmokeSection, recorder: smokeSectionRecorder)
        .onChange(of: keychainCredential) { _, value in
            if value.isEmpty {
                showsNewAPIKey = false
            }
        }
    }

    private var apiKeyInputSmokeSection: String {
        if keychainCredential.isEmpty {
            return savedKeyUnavailable ? "api-key-unavailable" : ""
        }
        if hasExistingKeychainReference {
            return showsNewAPIKey ? "api-key-saved-input-visible" : "api-key-saved-masked-control"
        }
        return showsNewAPIKey ? "api-key-new-input-visible" : "api-key-new-input-hidden"
    }

    private var savedKeyDisabledReasonSmokeSection: String {
        savedKeyUnavailable ? "api-key-saved-key-unavailable" : ""
    }

    private var apiKeyReplacementInput: AnyView {
        let placeholder = ProviderFormLabels.apiKeyPlaceholder(hasReference: hasExistingCredentialReference)
        if showsNewAPIKey {
            return AnyView(
                TextField(placeholder, text: $keychainCredential)
                    .textFieldStyle(.plain)
                    .foregroundStyle(primaryText.opacity(0.90))
                    .accessibilityLabel("API key field")
                    .accessibilityIdentifier("api-key-new-input-field")
            )
        }
        return AnyView(
            SecureField(placeholder, text: $keychainCredential)
                .textFieldStyle(.plain)
                .foregroundStyle(primaryText.opacity(0.90))
                .accessibilityLabel("API key field")
                .accessibilityIdentifier("api-key-new-input-field")
        )
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Models")
                            .font(.caption)
                            .foregroundStyle(secondaryText)
                        protocolChip(ProviderFormLabels.codexRoute)
                            .smokeSection("provider-codex-route-chip", recorder: smokeSectionRecorder)
                        protocolChip(ProviderFormLabels.upstreamProtocol(apiFormat: apiFormatForSave))
                            .smokeSection("provider-upstream-protocol-chip", recorder: smokeSectionRecorder)
                    }
                    Text(modelDetectionStatus)
                        .font(.caption)
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Button(isTestingConnection ? "Testing..." : "Test connection") {
                        Task { await testConnection() }
                    }
                    .buttonStyle(ControlButtonStyle())
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("provider-connection-test-entry")
                    .accessibilityIdentifier("provider-connection-test-entry")
                    .disabled(baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTestingConnection || isDetectingModels)
                    .smokeSection("provider-connection-test-entry", recorder: smokeSectionRecorder)

                    Button(isDetectingModels ? "Detecting..." : "Detect models") {
                        Task { await detectModels() }
                    }
                    .buttonStyle(ControlButtonStyle())
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("provider-model-detection-entry")
                    .accessibilityIdentifier("provider-model-detection-entry")
                    .disabled(baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isDetectingModels || isTestingConnection)
                    .smokeSection("provider-model-detection-entry", recorder: smokeSectionRecorder)
                    Spacer(minLength: 0)
                }
            }
            if !connectionTestKind.isEmpty {
                connectionTestStatusRow
                    .smokeSection("provider-connection-\(connectionTestKind)", recorder: smokeSectionRecorder)
            }
            if let provider = editingProvider {
                providerHealthPanel(provider)
            }
            VStack(spacing: 6) {
                ForEach($modelRows) { $row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            TextField("model id", text: $row.modelId)
                                .textFieldStyle(ProductTextFieldStyle())
                                .accessibilityLabel("Model ID field")
                                .accessibilityIdentifier("provider-model-id-field")
                                .smokeSection("provider-model-id-main-field", recorder: smokeSectionRecorder)
                            if modelRows.count > 1 {
                                Button {
                                    removeModelRow(row.id)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(secondaryText)
                                .frame(width: 28)
                            }
                        }
                        Text(modelRowSummary(row))
                            .font(.system(size: 10))
                            .foregroundStyle(secondaryText)
                            .lineLimit(1)
                    }
                    .smokeSection("provider-model-row", recorder: smokeSectionRecorder)
                    .smokeSection(modelReachabilitySmokeSection(row), recorder: smokeSectionRecorder)
                }
                if manualModelEntryEnabled {
                    Button {
                        modelRows.append(ProviderModelRowDraft(modelId: "", displayName: "", upstreamModel: ""))
                    } label: {
                        Label("Add model manually", systemImage: "plus.circle")
                    }
                    .buttonStyle(ControlButtonStyle())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .smokeSection("provider-add-model-manual-action", recorder: smokeSectionRecorder)
                }
            }
            .smokeSection("provider-model-table", recorder: smokeSectionRecorder)
        }
    }

    private var connectionTestStatusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connectionTestColor)
                .frame(width: 7, height: 7)
            Text(connectionTestText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(primaryText.opacity(0.74))
                .lineLimit(1)
            if let status = connectionTestHTTPStatus {
                Text("HTTP \(status)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(mutedText)
            }
            Spacer()
            if !connectionDiscoveredRows.isEmpty {
                Button("Use \(connectionDiscoveredRows.count) reachable models") {
                    modelRows = connectionDiscoveredRows
                    modelsURL = connectionDiscoveredEndpoint
                    modelDetectionStatus = "Using \(connectionDiscoveredRows.count) reachable model(s); \(connectionUnavailableModelCount) unavailable skipped."
                    manualModelEntryEnabled = false
                    connectionUsedReachableRows = true
                    smokeSectionRecorder?("provider-connection-use-discovered-models")
                    smokeSectionRecorder?("provider-connection-use-reachable-models")
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(hex: 0x78D8FF))
                .accessibilityLabel("provider-connection-use-reachable-visible")
                .accessibilityIdentifier("provider-connection-use-reachable-visible")
                .smokeRecordOnly("provider-connection-use-reachable-visible", recorder: smokeSectionRecorder)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
        .smokeSection(connectionCountsSmokeSection, recorder: smokeSectionRecorder)
        .smokeSection(connectionUsedReachableRows ? "provider-connection-used-reachable-models-only" : "", recorder: smokeSectionRecorder)
    }

    private var connectionTestText: String {
        ProviderFormLabels.connectionStatusLabel(
            kind: connectionTestKind,
            listedCount: connectionTestModelCount,
            reachableCount: connectionReachableModelCount,
            unavailableCount: connectionUnavailableModelCount,
            latencyMS: connectionTestLatencyMS
        )
    }

    private var connectionCountsSmokeSection: String {
        guard connectionTestKind == "connected", connectionTestModelCount > 0 else { return "" }
        return "provider-connection-counts-separated"
    }

    private var connectionTestColor: Color {
        switch connectionTestKind {
        case "connected":
            return Color(hex: 0x8BE0A4)
        case "reachable", "model_list_unavailable":
            return Color(hex: 0xFFD685)
        case "auth_failed", "network_failed":
            return Color(hex: 0xFF8FA3)
        default:
            return mutedText
        }
    }

    private func providerHealthPanel(_ provider: ConfiguredProviderEntry) -> some View {
        let health = model.providerHealth(for: provider)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle()
                    .fill(health.hidden.isEmpty ? Color(hex: 0x8BE0A4) : Color(hex: 0xFFD685))
                    .frame(width: 7, height: 7)
                Text(ProviderFormLabels.providerHealthSummary(saved: health.saved, available: health.available, hidden: health.hidden.count))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(primaryText.opacity(0.76))
                    .lineLimit(1)
                Spacer()
            }
            .smokeSection("provider-health-counts", recorder: smokeSectionRecorder)
            if !health.hidden.isEmpty {
                Button {
                    isHiddenModelsExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isHiddenModelsExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Hidden models")
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(secondaryText)
                .smokeSection("provider-hidden-models-toggle", recorder: smokeSectionRecorder)
                if isHiddenModelsExpanded {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(health.hidden) { hidden in
                            Text(ProviderFormLabels.providerHiddenReason(modelId: hidden.id, reason: hidden.reason))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .smokeSection("provider-hidden-model-reasons", recorder: smokeSectionRecorder)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
    }

    private func modelRowSummary(_ row: ProviderModelRowDraft) -> String {
        let upstream = row.upstreamModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = row.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = upstream.isEmpty ? (model.isEmpty ? "same as Model ID" : model) : upstream
        let reachability = modelReachabilitySummary(row)
        let suffix = reachability.isEmpty ? "" : " · \(reachability)"
        return "\(ProviderFormLabels.upstreamProtocol(apiFormat: apiFormatForSave)) · upstream \(target)\(suffix)"
    }

    private func modelReachabilitySummary(_ row: ProviderModelRowDraft) -> String {
        let id = row.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, case .edit = mode else { return "" }
        if let hidden = model.gatewayModelHealth.hidden.first(where: { $0.id == id }) {
            return "unavailable: \(hidden.reason)"
        }
        if model.models.contains(where: { $0.id == id }) {
            return "reachable"
        }
        return model.gatewayModelHealth.probed ? "unavailable: not listed" : ""
    }

    private func modelReachabilitySmokeSection(_ row: ProviderModelRowDraft) -> String {
        let summary = modelReachabilitySummary(row)
        if summary.hasPrefix("reachable") {
            return "provider-model-reachable-row"
        }
        if summary.hasPrefix("unavailable") {
            return "provider-model-unavailable-row"
        }
        return ""
    }

    private func protocolChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(chipBackground, in: Capsule())
    }

    private var validationMessage: String {
        if resolvedProviderId.isEmpty || providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manualModelDrafts.isEmpty || baseURL.isEmpty {
            return "Provider name, API base URL, and at least one model are required."
        }
        if !displayPrefix.isEmpty && !displayPrefix.hasSuffix("/") {
            return "Display prefix must end with /."
        }
        if !contextWindow.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && Int(contextWindow) == nil {
            return "Context window must be a number."
        }
        if keychainCredential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!hasExistingCredentialReference || savedKeyUnavailable) {
            return "API key is required."
        }
        do {
            _ = try ProviderConfigDraftWriter.addProvider(draft, to: Data(#"{"providers":[]}"#.utf8))
        } catch {
            return error.localizedDescription
        }
        return "Ready to save provider."
    }

    private var canSave: Bool {
        validationMessage.hasPrefix("Ready to save provider")
    }

    private var importPrefilledSection: String {
        guard case .import = mode,
              !providerId.isEmpty,
              manualModelDrafts.count > 1,
              !modelsURL.isEmpty else {
            return ""
        }
        return "provider-import-prefilled-fields"
    }

    private var importMissingRequiredSection: String {
        guard case .import = mode, !canSave else {
            return ""
        }
        return "provider-import-missing-required-fields"
    }

    private var editPrefilledBaseURLSection: String {
        guard case .edit = mode,
              !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        return "provider-edit-base-url-prefilled"
    }

    private var editLoadedModelsSection: String {
        guard case .edit = mode,
              !manualModelDrafts.isEmpty else {
            return ""
        }
        return "provider-edit-models-loaded"
    }

    private var draft: ProviderConfigDraft {
        let models = effectiveModelDrafts
        let first = models.first
        return ProviderConfigDraft(
            providerId: resolvedProviderId,
            providerName: providerName.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: baseURL,
            apiFormat: apiFormatForSave,
            authEnv: "",
            modelId: first?.id ?? "",
            modelDisplayName: first?.displayName ?? first?.id ?? "",
            contextWindow: Int(contextWindow),
            source: source.isEmpty ? resolvedProviderId : source,
            modelPrefix: displayPrefix.isEmpty ? defaultModelPrefix : displayPrefix,
            modelsURL: modelsURL,
            credentialKind: "keychain",
            credentialReference: credentialReferenceForSave,
            keyHeader: keyHeader,
            upstreamModel: first?.upstreamModel ?? "",
            models: models,
            streaming: true,
            tools: false,
            usage: true,
            reasoning: true,
            priority: 100,
            visible: true
        )
    }

    private var editingProvider: ConfiguredProviderEntry? {
        if case .edit(let provider) = mode {
            return provider
        }
        return nil
    }

    private var resolvedProviderId: String {
        let explicit = providerId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            return explicit
        }
        return slug(providerName)
    }

    private var defaultModelPrefix: String {
        switch mode {
        case .edit:
            return ""
        case .add, .import:
            return "\(resolvedProviderId)/"
        }
    }

    private var derivedModelsURL: String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return "" }
        return "\(trimmed)/models"
    }

    private var modelDetectionEndpoints: [String] {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return [] }
        var endpoints: [String] = []
        let explicitModelsURL = modelsURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicitModelsURL.isEmpty {
            endpoints.append(explicitModelsURL)
        }
        if let url = URL(string: trimmed) {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if path.split(separator: "/").last != "v1" {
                endpoints.append("\(trimmed)/v1/models")
            }
        }
        endpoints.append(derivedModelsURL)
        return endpoints.reduce(into: []) { unique, endpoint in
            if !unique.contains(endpoint) {
                unique.append(endpoint)
            }
        }
    }

    private var effectiveModelDrafts: [ProviderConfigDraft.ModelDraft] {
        return manualModelDrafts
    }

    private var manualModelDrafts: [ProviderConfigDraft.ModelDraft] {
        modelRows.compactMap { row in
            let id = row.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }
            let displayName = row.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let upstream = row.upstreamModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return ProviderConfigDraft.ModelDraft(
                id: id,
                displayName: displayName.isEmpty ? id : displayName,
                contextWindow: Int(contextWindow),
                upstreamModel: upstream.isEmpty ? id : upstream
            )
        }
    }

    private var apiFormatForSave: String {
        let haystack = ([providerName, baseURL] + modelRows.flatMap { [$0.modelId, $0.displayName, $0.upstreamModel] })
            .joined(separator: " ")
        return ProviderFormLabels.resolvedUpstreamProtocol(
            selected: apiFormat,
            providerText: haystack,
            selectionIsExplicit: upstreamProtocolSelectedExplicitly
        )
    }

    private var firstModelPlaceholder: String {
        let id = modelRows.first?.modelId.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return id.isEmpty ? "same as Model ID" : id
    }

    private var firstUpstreamModelBinding: Binding<String> {
        Binding {
            modelRows.first?.upstreamModel ?? ""
        } set: { value in
            guard !modelRows.isEmpty else { return }
            modelRows[0].upstreamModel = value
        }
    }

    private var defaultCredentialReference: String {
        "relaykit.provider.\(resolvedProviderId.isEmpty ? "provider" : resolvedProviderId)"
    }

    private var credentialReferenceForSave: String {
        let value = credentialReference.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? defaultCredentialReference : value
    }

    private var hasExistingCredentialReference: Bool {
        !credentialReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasExistingKeychainReference: Bool {
        hasExistingCredentialReference && (existingCredentialKind.isEmpty || existingCredentialKind == "keychain")
    }

    private var apiKeyStatusText: String {
        if savedKeyUnavailable {
            return ProviderFormLabels.keyUnavailableStatus
        }
        return ProviderFormLabels.apiKeyStatus(hasReference: hasExistingCredentialReference, credentialKind: existingCredentialKind)
    }

    private var apiKeyHelpText: String {
        if savedKeyUnavailable {
            return ProviderFormLabels.keyUnavailableStatus
        }
        return hasExistingCredentialReference
            ? "Edit this field to replace the saved Keychain key."
            : "RelayKit stores the value in Keychain when you save."
    }

    private func removeModelRow(_ id: ProviderModelRowDraft.ID) {
        guard modelRows.count > 1 else { return }
        modelRows.removeAll { $0.id == id }
    }

    private func testConnection() async {
        guard !modelDetectionEndpoints.isEmpty else {
            connectionTestKind = "network_failed"
            connectionTestLatencyMS = nil
            connectionTestModelCount = 0
            connectionReachableModelCount = 0
            connectionUnavailableModelCount = 0
            connectionTestHTTPStatus = nil
            connectionDiscoveredRows = []
            connectionDiscoveredEndpoint = ""
            connectionUsedReachableRows = false
            return
        }
        isTestingConnection = true
        defer { isTestingConnection = false }

        let key: String
        do {
            key = try connectionProbeAPIKey()
        } catch {
            connectionTestKind = "auth_failed"
            connectionTestModelCount = 0
            connectionReachableModelCount = 0
            connectionUnavailableModelCount = 0
            connectionDiscoveredRows = []
            connectionDiscoveredEndpoint = ""
            connectionUsedReachableRows = false
            return
        }
        guard !key.isEmpty else {
            connectionTestKind = "auth_failed"
            connectionTestModelCount = 0
            connectionReachableModelCount = 0
            connectionUnavailableModelCount = 0
            connectionTestLatencyMS = nil
            connectionTestHTTPStatus = nil
            connectionDiscoveredRows = []
            connectionDiscoveredEndpoint = ""
            connectionUsedReachableRows = false
            return
        }
        var discovery = await discoverModels(endpoints: modelDetectionEndpoints, key: key)
        if discovery.kind == "connected", apiFormatForSave == "openai_responses" {
            discovery = await probeResponses(discovery, key: key)
        }
        if discovery.kind == "connected" {
            model.startGateway()
            await model.refreshModels()
        }
        applyConnectionResult(discovery)
    }

    private var providerBaseURL: URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    private func connectionProbeAPIKey() throws -> String {
        let typed = keychainCredential.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            return typed
        }
        guard hasExistingKeychainReference else {
            return ""
        }
        return try KeychainCredentialStore.load(service: credentialReferenceForSave)
    }

    private func loadSavedAPIKeyIfNeeded() {
        guard hasExistingKeychainReference,
              !savedKeyLoadAttempted,
              keychainCredential.isEmpty else {
            return
        }
        savedKeyLoadAttempted = true
        do {
            keychainCredential = try KeychainCredentialStore.load(service: credentialReferenceForSave)
            savedKeyUnavailable = false
        } catch {
            savedKeyUnavailable = true
        }
    }

    private func applyConnectionResult(_ result: ProviderModelDiscoveryResult) {
        connectionTestKind = result.kind
        connectionTestLatencyMS = result.latencyMS
        connectionTestHTTPStatus = result.status
        connectionUsedReachableRows = false
        let normalizedRows = normalizedConnectionRows(from: result.rows)
        connectionTestModelCount = normalizedRows.count
        let reachableRows = result.kind == "connected" ? reachableConnectionRows(from: normalizedRows) : []
        connectionReachableModelCount = reachableRows.count
        connectionUnavailableModelCount = result.kind == "connected" ? max(0, normalizedRows.count - reachableRows.count) : 0
        connectionDiscoveredRows = reachableRows
        connectionDiscoveredEndpoint = result.kind == "connected" ? result.endpoint : ""
    }

    private func normalizedConnectionRows(from rows: [ProviderModelRowDraft]) -> [ProviderModelRowDraft] {
        rows.map { row in
            let id = row.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = row.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let upstream = row.upstreamModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if let saved = editingProvider?.models.first(where: { $0.id == id || $0.upstreamModel == id }) {
                let savedDisplay = saved.displayName == saved.id ? "" : saved.displayName
                let savedUpstream = saved.upstreamModel == saved.id ? "" : saved.upstreamModel
                return ProviderModelRowDraft(
                    modelId: saved.id,
                    displayName: displayName.isEmpty || displayName == id ? savedDisplay : displayName,
                    upstreamModel: upstream.isEmpty ? savedUpstream : upstream
                )
            }
            let prefix = displayPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty, !id.hasPrefix(prefix) {
                return ProviderModelRowDraft(
                    modelId: "\(prefix)\(id)",
                    displayName: displayName,
                    upstreamModel: upstream.isEmpty ? id : upstream
                )
            }
            return ProviderModelRowDraft(modelId: id, displayName: displayName, upstreamModel: upstream)
        }
    }

    private func reachableConnectionRows(from rows: [ProviderModelRowDraft]) -> [ProviderModelRowDraft] {
        let visibleIDs = Set(model.models.map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) })
        guard !visibleIDs.isEmpty else { return [] }
        return rows.filter { visibleIDs.contains($0.modelId.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func discoverModels(endpoints: [String], key: String) async -> ProviderModelDiscoveryResult {
        var lastHTTPProbe: ProviderHTTPProbe?
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            do {
                let probe = try await sendProbe(url: url, key: key, timeout: 8)
                lastHTTPProbe = probe
                let rows = parseModelRows(from: probe.data)
                let kind = ProviderFormLabels.providerConnectionKind(
                    httpStatus: probe.status,
                    contentType: probe.contentType,
                    bodyPrefix: responsePrefix(from: probe.data),
                    modelCount: rows.count
                )
                if kind == "auth_failed" {
                    return ProviderModelDiscoveryResult(kind: "auth_failed", rows: [], endpoint: endpoint, status: probe.status, latencyMS: probe.latencyMS)
                }
                if kind == "connected" {
                    return ProviderModelDiscoveryResult(kind: "connected", rows: rows, endpoint: endpoint, status: probe.status, latencyMS: probe.latencyMS)
                }
            } catch {
                continue
            }
        }
        if let lastHTTPProbe {
            return ProviderModelDiscoveryResult(kind: "model_list_unavailable", rows: [], endpoint: "", status: lastHTTPProbe.status, latencyMS: lastHTTPProbe.latencyMS)
        }
        return ProviderModelDiscoveryResult(kind: "network_failed", rows: [], endpoint: "", status: nil, latencyMS: nil)
    }

    private func probeResponses(_ discovery: ProviderModelDiscoveryResult, key: String) async -> ProviderModelDiscoveryResult {
        guard let baseURL = providerBaseURL,
              let model = connectionProbeModel(from: discovery.rows) else {
            return ProviderModelDiscoveryResult(kind: "responses_unavailable", rows: [], endpoint: "", status: discovery.status, latencyMS: discovery.latencyMS)
        }
        let trimmedPath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = trimmedPath.split(separator: "/").last == "v1"
            ? baseURL.appendingPathComponent("responses")
            : baseURL.appendingPathComponent("v1/responses")
        let body: [String: Any] = [
            "model": model,
            "input": "RelayKit connection probe",
            "max_output_tokens": 1,
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return ProviderModelDiscoveryResult(kind: "responses_unavailable", rows: [], endpoint: "", status: discovery.status, latencyMS: discovery.latencyMS)
        }
        do {
            let probe = try await sendProbe(url: endpoint, key: key, timeout: 8, method: "POST", body: bodyData)
            if probe.status == 401 || probe.status == 403 {
                return ProviderModelDiscoveryResult(kind: "auth_failed", rows: [], endpoint: "", status: probe.status, latencyMS: probe.latencyMS)
            }
            guard (200..<300).contains(probe.status) else {
                return ProviderModelDiscoveryResult(kind: "responses_unavailable", rows: [], endpoint: "", status: probe.status, latencyMS: probe.latencyMS)
            }
            return discovery
        } catch {
            return ProviderModelDiscoveryResult(kind: "responses_unavailable", rows: [], endpoint: "", status: nil, latencyMS: nil)
        }
    }

    private func connectionProbeModel(from discoveredRows: [ProviderModelRowDraft]) -> String? {
        for row in modelRows + discoveredRows {
            let upstream = row.upstreamModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !upstream.isEmpty {
                return upstream
            }
            let identifier = row.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !identifier.isEmpty {
                return identifier
            }
        }
        return nil
    }

    private func parseModelRows(from data: Data) -> [ProviderModelRowDraft] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let items = (root["data"] as? [[String: Any]]) ?? (root["models"] as? [[String: Any]]) ?? []
        return items.compactMap { item -> ProviderModelRowDraft? in
            let id = (item["id"] ?? item["slug"] ?? item["model"]) as? String ?? ""
            let cleanID = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanID.isEmpty else { return nil }
            let display = ((item["display_name"] ?? item["displayName"]) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return ProviderModelRowDraft(modelId: cleanID, displayName: display == cleanID ? "" : display, upstreamModel: "")
        }
    }

    private func sendProbe(
        url: URL,
        key: String?,
        timeout: TimeInterval,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> ProviderHTTPProbe {
        var lastError: Error?
        for attempt in 0..<2 {
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.httpMethod = method
            request.httpBody = body
            if body != nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            if let key, !key.isEmpty {
                applyProviderAuthHeaders(to: &request, key: key)
            }
            let started = Date()
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let latency = max(0, Int(Date().timeIntervalSince(started) * 1000))
                let http = response as? HTTPURLResponse
                return ProviderHTTPProbe(
                    status: http?.statusCode ?? 0,
                    latencyMS: latency,
                    contentType: http?.value(forHTTPHeaderField: "content-type") ?? "",
                    data: data
                )
            } catch let error as URLError where attempt == 0 && shouldRetry(error) {
                lastError = error
                continue
            } catch {
                throw error
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    private func applyProviderAuthHeaders(to request: inout URLRequest, key: String) {
        let header = keyHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = header.lowercased()
        if header.isEmpty || normalized == "authorization" {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(key, forHTTPHeaderField: header)
        }
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    }

    private func responsePrefix(from data: Data) -> String {
        String(data: data.prefix(64), encoding: .utf8) ?? ""
    }

    private func shouldRetry(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    private func detectModels() async {
        let endpoints = modelDetectionEndpoints
        guard !endpoints.isEmpty else {
            modelDetectionStatus = "Enter a valid API base URL."
            manualModelEntryEnabled = true
            return
        }
        isDetectingModels = true
        defer { isDetectingModels = false }
        let key = (try? connectionProbeAPIKey()) ?? ""
        let result = await discoverModels(endpoints: endpoints, key: key)
        if result.kind == "connected" {
            modelsURL = result.endpoint
            modelRows = result.rows
            modelDetectionStatus = "Detected \(result.rows.count) model(s)."
            manualModelEntryEnabled = false
            return
        }
        switch result.kind {
        case "auth_failed":
            modelDetectionStatus = "Authentication failed while detecting models."
        case "model_list_unavailable":
            modelDetectionStatus = result.status.map { "Model list unavailable (HTTP \($0)); add models manually." } ?? "Model list unavailable; add models manually."
        default:
            modelDetectionStatus = "Network failed while detecting models; add models manually."
        }
        manualModelEntryEnabled = true
    }

    private func slug(_ value: String) -> String {
        let allowed = value.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        return String(allowed)
            .split(separator: "-")
            .joined(separator: "-")
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
    @Environment(\.isEnabled) private var isEnabled
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        let foreground = if !isEnabled {
            Color.primary.opacity(0.48)
        } else if prominent {
            Color(hex: 0x071018)
        } else {
            Color.primary.opacity(configuration.isPressed ? 0.58 : 0.82)
        }
        let background = if !isEnabled {
            Color.primary.opacity(0.065)
        } else if prominent {
            Color(hex: 0x78D8FF).opacity(configuration.isPressed ? 0.7 : 1)
        } else {
            Color.primary.opacity(configuration.isPressed ? 0.11 : 0.075)
        }
        let stroke = if !isEnabled {
            borderColor
        } else if prominent {
            Color.clear
        } else {
            borderColor
        }

        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(stroke))
    }
}

private struct OfficialSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .foregroundStyle(Color.primary.opacity(configuration.isPressed ? 0.62 : 0.86))
            .background(Color.primary.opacity(configuration.isPressed ? 0.13 : 0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(borderColor))
    }
}

private struct ProductTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.system(size: 12, design: .rounded))
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(borderColor))
            .foregroundColor(.primary.opacity(0.94))
            .accentColor(Color(hex: 0x78D8FF))
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
            .onChange(of: id) { _, newValue in
                recorder?(newValue)
            }
    }
}

private struct SmokeRecordOnlyModifier: ViewModifier {
    let id: String
    let recorder: ((String) -> Void)?

    func body(content: Content) -> some View {
        content
            .onAppear {
                recorder?(id)
            }
            .onChange(of: id) { _, newValue in
                recorder?(newValue)
            }
    }
}

private struct ManualProofEntryView: View {
    let acceptance: DesktopAcceptanceEvidence
    let secondaryText: Color
    let surfaceSubtle: Color
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            proofLine("Manual proof", acceptance.manualStatus)
            proofLine("Proof root", shortPath(acceptance.proofRoot))
            commandLine(acceptance.startCommand)
            HStack {
                Button(action: open) {
                    Label("Open Proof Terminal", systemImage: "terminal")
                }
                .buttonStyle(ControlButtonStyle(prominent: true))
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Spacer()
                Text("Reauth if needed, send demo + GPT-5.5")
                    .font(.caption)
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
            }
        }
    }

    private func proofLine(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(secondaryText)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func commandLine(_ command: String) -> some View {
        HStack(spacing: 8) {
            Text("Command")
                .font(.caption)
                .foregroundStyle(secondaryText)
            Text(command)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(surfaceSubtle, in: RoundedRectangle(cornerRadius: 10))
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
    @ViewBuilder
    func smokeSection(_ id: String, recorder: ((String) -> Void)?) -> some View {
        if id.isEmpty {
            self
        } else {
            modifier(SmokeSectionModifier(id: id, recorder: recorder))
        }
    }

    func smokeRecordOnly(_ id: String, recorder: ((String) -> Void)?) -> some View {
        modifier(SmokeRecordOnlyModifier(id: id, recorder: recorder))
    }
}
