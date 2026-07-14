#!/usr/bin/env swift

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

private let codexBundleIdentifier = "com.openai.codex"
private let relayKitBundleIdentifier = "dev.relaykit.app"
private let axWindowNumberAttribute = "AXWindowNumber" as CFString
private let axIdentifierAttribute = "AXIdentifier" as CFString
private let axLabelAttribute = "AXLabel" as CFString
private let axPlaceholderValueAttribute = "AXPlaceholderValue" as CFString
private let axLinkRole = "AXLink"
private let maximumIdentityBytes: off_t = 64 * 1024
private let maximumCatalogBytes: off_t = 1024 * 1024
private let maximumQueryBytes: off_t = 4 * 1024 * 1024
private let maximumAXDepth = 32
private let maximumAXNodes = 10_000
private let maximumAXDiagnosticDepth = 12
private let maximumAXDiagnosticNodes = 512
private let maximumRelayKitBindingDepth = 12
private let maximumRelayKitBindingNodes = 512
private let selectorWaitSeconds: TimeInterval = 3
private let selectorPollSeconds: TimeInterval = 0.05
private let requiredPrivatePermissions: mode_t = 0o600

private struct DriverFailure: Error {
    let code: String
    let exitStatus: Int32
    let candidateCount: Int?

    init(_ code: String, exitStatus: Int32, candidateCount: Int? = nil) {
        self.code = code
        self.exitStatus = exitStatus
        self.candidateCount = candidateCount
    }
}

private struct DriverReport: Encodable {
    let command: String
    let status: String
    let code: String
    var windowVerified: Bool?
    var modelPickerCount: Int?
    var composerCount: Int?
    var sendCount: Int?
    var candidateCount: Int?
    var actionCount: Int?

    enum CodingKeys: String, CodingKey {
        case command
        case status
        case code
        case windowVerified = "window_verified"
        case modelPickerCount = "model_picker_count"
        case composerCount = "composer_count"
        case sendCount = "send_count"
        case candidateCount = "candidate_count"
        case actionCount = "action_count"
    }

    static func success(
        command: String,
        windowVerified: Bool? = nil,
        modelPickerCount: Int? = nil,
        composerCount: Int? = nil,
        sendCount: Int? = nil,
        candidateCount: Int? = nil,
        actionCount: Int? = nil
    ) -> DriverReport {
        DriverReport(
            command: command,
            status: "ok",
            code: "ok",
            windowVerified: windowVerified,
            modelPickerCount: modelPickerCount,
            composerCount: composerCount,
            sendCount: sendCount,
            candidateCount: candidateCount,
            actionCount: actionCount
        )
    }

    static func failure(command: String, failure: DriverFailure) -> DriverReport {
        DriverReport(
            command: command,
            status: "error",
            code: failure.code,
            windowVerified: nil,
            modelPickerCount: nil,
            composerCount: nil,
            sendCount: nil,
            candidateCount: failure.candidateCount,
            actionCount: nil
        )
    }
}

private func emit(_ report: DriverReport) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let fallback = Data("{\"code\":\"internal_error\",\"command\":\"unknown\",\"status\":\"error\"}\n".utf8)
    guard let encoded = try? encoder.encode(report) else {
        FileHandle.standardOutput.write(fallback)
        return
    }
    FileHandle.standardOutput.write(encoded)
    FileHandle.standardOutput.write(Data([0x0a]))
}

private enum DriverCommand: String {
    case inspect
    case reveal
    case ready
    case prepare
    case submit
    case relayKitProviderConfigure = "relaykit-provider-configure"
    case relayKitProviderVerify = "relaykit-provider-verify"
    case relayKitGatewayStart = "relaykit-gateway-start"
    case relayKitAXInspect = "relaykit-ax-inspect"
    case selfTest = "self-test"
}

private enum DriverApplicationMode {
    case desktop
    case relayKit

    var expectedBundleIdentifier: String {
        switch self {
        case .desktop: return codexBundleIdentifier
        case .relayKit: return relayKitBundleIdentifier
        }
    }
}

private func applicationMode(for command: DriverCommand) -> DriverApplicationMode? {
    switch command {
    case .inspect, .reveal, .ready, .prepare, .submit:
        return .desktop
    case .relayKitProviderConfigure, .relayKitProviderVerify, .relayKitGatewayStart, .relayKitAXInspect:
        return .relayKit
    case .selfTest:
        return nil
    }
}

private struct ParsedArguments {
    let command: DriverCommand
    let options: [String: String]
}

private func redactedCommandName(_ arguments: [String]) -> String {
    guard let raw = arguments.first else { return "unknown" }
    let known = Set([
        "inspect", "reveal", "ready", "prepare", "submit", "self-test",
        "relaykit-provider-configure", "relaykit-provider-verify", "relaykit-gateway-start",
        "relaykit-ax-inspect",
    ])
    return known.contains(raw) ? raw : "unknown"
}

private func requiredOptions(for command: DriverCommand, scenario: String?) throws -> Set<String> {
    switch command {
    case .inspect:
        return ["--pid", "--window-identity"]
    case .reveal:
        return ["--pid", "--window-identity", "--text"]
    case .ready:
        return ["--pid", "--window-identity", "--catalog-labels-file"]
    case .prepare:
        return ["--pid", "--window-identity", "--workspace"]
    case .submit:
        return ["--pid", "--window-identity", "--model-label", "--catalog-labels-file", "--query-file"]
    case .relayKitProviderConfigure:
        return [
            "--pid", "--window-identity", "--provider-name", "--base-url",
            "--synthetic-key", "--model-id",
        ]
    case .relayKitProviderVerify:
        return ["--pid", "--window-identity", "--provider-name", "--base-url", "--model-id"]
    case .relayKitGatewayStart:
        return ["--pid", "--window-identity"]
    case .relayKitAXInspect:
        return ["--pid", "--window-identity", "--diagnostic-output"]
    case .selfTest:
        guard let scenario else {
            throw DriverFailure("invalid_arguments", exitStatus: 2)
        }
        switch scenario {
        case "exact", "zero", "multiple", "reveal-exact", "reveal-multiple", "window-fallback", "window-ambiguous", "model-ui-labels", "send-structure", "composer-value", "empty-composer":
            return ["--scenario"]
        case "query-permissions":
            return ["--scenario", "--query-file"]
        case "catalog-exact":
            return ["--scenario", "--catalog-labels-file", "--model-label"]
        default:
            throw DriverFailure("invalid_arguments", exitStatus: 2)
        }
    }
}

private func parseArguments(_ arguments: [String]) throws -> ParsedArguments {
    guard let rawCommand = arguments.first,
          let command = DriverCommand(rawValue: rawCommand) else {
        throw DriverFailure("invalid_command", exitStatus: 2)
    }
    if command == .selfTest && ProcessInfo.processInfo.environment["RELAYKIT_AX_DRIVER_SELF_TEST"] != "1" {
        throw DriverFailure("invalid_command", exitStatus: 2)
    }
    if command == .relayKitAXInspect && ProcessInfo.processInfo.environment["RELAYKIT_AX_DRIVER_DIAGNOSTIC"] != "1" {
        throw DriverFailure("invalid_command", exitStatus: 2)
    }

    var options: [String: String] = [:]
    var index = 1
    while index < arguments.count {
        let name = arguments[index]
        guard name.hasPrefix("--"), index + 1 < arguments.count, options[name] == nil else {
            throw DriverFailure("invalid_arguments", exitStatus: 2)
        }
        let value = arguments[index + 1]
        guard !value.isEmpty else {
            throw DriverFailure("invalid_arguments", exitStatus: 2)
        }
        options[name] = value
        index += 2
    }

    let required = try requiredOptions(for: command, scenario: options["--scenario"])
    guard Set(options.keys) == required else {
        throw DriverFailure("invalid_arguments", exitStatus: 2)
    }
    return ParsedArguments(command: command, options: options)
}

private enum SecureFileKind {
    case catalog
    case query

    var maximumBytes: off_t {
        switch self {
        case .catalog: return maximumCatalogBytes
        case .query: return maximumQueryBytes
        }
    }

    var invalidCode: String {
        switch self {
        case .catalog: return "catalog_file_invalid"
        case .query: return "query_file_invalid"
        }
    }

    var notRegularCode: String {
        switch self {
        case .catalog: return "catalog_file_not_regular"
        case .query: return "query_file_not_regular"
        }
    }

    var permissionsCode: String {
        switch self {
        case .catalog: return "catalog_file_permissions"
        case .query: return "query_file_permissions"
        }
    }
}

private func closeDescriptor(_ descriptor: Int32) {
    _ = Darwin.close(descriptor)
}

private func openSecureFile(_ path: String, kind: SecureFileKind) throws -> FileHandle {
    guard path.hasPrefix("/") else {
        throw DriverFailure(kind.invalidCode, exitStatus: 3)
    }
    let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
        let code = errno == ELOOP ? kind.notRegularCode : kind.invalidCode
        throw DriverFailure(code, exitStatus: 3)
    }

    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
        closeDescriptor(descriptor)
        throw DriverFailure(kind.invalidCode, exitStatus: 3)
    }
    let fileType = metadata.st_mode & mode_t(S_IFMT)
    guard fileType == mode_t(S_IFREG) else {
        closeDescriptor(descriptor)
        throw DriverFailure(kind.notRegularCode, exitStatus: 3)
    }
    let permissions = metadata.st_mode & mode_t(0o777)
    guard metadata.st_uid == getuid(), permissions == requiredPrivatePermissions else {
        closeDescriptor(descriptor)
        throw DriverFailure(kind.permissionsCode, exitStatus: 3)
    }
    guard metadata.st_size > 0, metadata.st_size <= kind.maximumBytes else {
        closeDescriptor(descriptor)
        throw DriverFailure(kind.invalidCode, exitStatus: 3)
    }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
}

private func validateSecureFile(_ path: String, kind: SecureFileKind) throws {
    let handle = try openSecureFile(path, kind: kind)
    try? handle.close()
}

private func readSecureData(_ path: String, kind: SecureFileKind) throws -> Data {
    let handle = try openSecureFile(path, kind: kind)
    defer { try? handle.close() }
    do {
        guard let data = try handle.readToEnd(), !data.isEmpty else {
            throw DriverFailure(kind.invalidCode, exitStatus: 3)
        }
        return data
    } catch let failure as DriverFailure {
        throw failure
    } catch {
        throw DriverFailure(kind.invalidCode, exitStatus: 3)
    }
}

private func readCatalogLabels(_ path: String) throws -> Set<String> {
    let data = try readSecureData(path, kind: .catalog)
    let decoded: [String]
    do {
        decoded = try JSONDecoder().decode([String].self, from: data)
    } catch {
        throw DriverFailure("catalog_file_invalid", exitStatus: 3)
    }
    guard !decoded.isEmpty, decoded.allSatisfy({ !$0.isEmpty }) else {
        throw DriverFailure("catalog_file_invalid", exitStatus: 3)
    }
    return Set(decoded)
}

private func readQuery(_ path: String) throws -> String {
    let data = try readSecureData(path, kind: .query)
    guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
        throw DriverFailure("query_file_invalid", exitStatus: 3)
    }
    return value
}

private func composerValue(query: String) throws -> String {
    let value: String
    if query.hasSuffix("\r\n") {
        value = String(query.dropLast())
    } else if query.hasSuffix("\n") {
        value = String(query.dropLast())
    } else {
        value = query
    }
    guard !value.isEmpty else {
        throw DriverFailure("query_file_invalid", exitStatus: 3)
    }
    return value
}

private func composerIsEmpty(value: String?, placeholder: String?) -> Bool {
    let codexPlaceholderValues = Set(["\n随心输入", "\nDo anything"])
    return value == "" ||
        (placeholder != nil && value == placeholder) ||
        (value.map { codexPlaceholderValues.contains($0) } ?? false)
}

private func composerReadbackMatches(actual: String?, expected: String) -> Bool {
    guard let actual else { return false }
    if actual == expected {
        return true
    }
    return expected.contains("\n") &&
        actual == expected.replacingOccurrences(of: "\n", with: " ")
}

private struct WindowIdentity: Decodable, Equatable {
    let pid: pid_t
    let windowID: UInt32

    enum CodingKeys: String, CodingKey {
        case pid
        case windowID = "window_id"
    }
}

private func readIdentityData(_ path: String) throws -> Data {
    guard path.hasPrefix("/") else {
        throw DriverFailure("window_identity_invalid", exitStatus: 3)
    }
    let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
        throw DriverFailure("window_identity_invalid", exitStatus: 3)
    }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
          metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
          metadata.st_uid == getuid(),
          metadata.st_size > 0,
          metadata.st_size <= maximumIdentityBytes else {
        closeDescriptor(descriptor)
        throw DriverFailure("window_identity_invalid", exitStatus: 3)
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    do {
        guard let data = try handle.readToEnd(), !data.isEmpty else {
            throw DriverFailure("window_identity_invalid", exitStatus: 3)
        }
        return data
    } catch let failure as DriverFailure {
        throw failure
    } catch {
        throw DriverFailure("window_identity_invalid", exitStatus: 3)
    }
}

private func readWindowIdentity(_ path: String) throws -> WindowIdentity {
    do {
        return try JSONDecoder().decode(WindowIdentity.self, from: readIdentityData(path))
    } catch let failure as DriverFailure {
        throw failure
    } catch {
        throw DriverFailure("window_identity_invalid", exitStatus: 3)
    }
}

private struct DriverContext {
    let pid: pid_t
    let identityPath: String
    let identity: WindowIdentity
    let applicationMode: DriverApplicationMode
}

private func makeContext(
    options: [String: String],
    command: DriverCommand
) throws -> DriverContext {
    guard let rawPID = options["--pid"],
          let numericPID = Int32(rawPID),
          numericPID > 0,
          let identityPath = options["--window-identity"],
          let applicationMode = applicationMode(for: command) else {
        throw DriverFailure("invalid_arguments", exitStatus: 2)
    }
    let identity = try readWindowIdentity(identityPath)
    guard identity.pid == numericPID else {
        throw DriverFailure("window_identity_pid_mismatch", exitStatus: 4)
    }
    return DriverContext(
        pid: numericPID,
        identityPath: identityPath,
        identity: identity,
        applicationMode: applicationMode
    )
}

private func number(_ value: Any?) -> NSNumber? {
    value as? NSNumber
}

private func copyAXAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
        return nil
    }
    return value
}

private func axWindowNumber(_ element: AXUIElement) -> UInt32? {
    guard let value = copyAXAttribute(element, axWindowNumberAttribute) as? NSNumber else {
        return nil
    }
    return value.uint32Value
}

private struct BoundWindow {
    let window: AXUIElement
}

private struct WindowServerMetadata: Decodable {
    let ownerPID: pid_t
    let windowID: UInt32?
    let layer: Int?

    enum CodingKeys: String, CodingKey {
        case ownerPID = "owner_pid"
        case windowID = "window_id"
        case layer
    }
}

private func currentWindowServerMetadata() -> [WindowServerMetadata] {
    let rawWindows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] ?? []
    return rawWindows.compactMap { window in
        guard let ownerPID = number(window[kCGWindowOwnerPID as String])?.int32Value else {
            return nil
        }
        return WindowServerMetadata(
            ownerPID: ownerPID,
            windowID: number(window[kCGWindowNumber as String])?.uint32Value,
            layer: number(window[kCGWindowLayer as String])?.intValue
        )
    }
}

private func verifyWindowServerIdentity(
    _ context: DriverContext,
    windows: [WindowServerMetadata]
) throws -> Int {
    let processWindows = windows.filter { window in
        guard window.ownerPID == context.pid else { return false }
        switch context.applicationMode {
        case .desktop:
            return window.layer == 0
        case .relayKit:
            return true
        }
    }
    let matches = processWindows.filter {
        $0.windowID == context.identity.windowID
    }
    guard matches.count == 1 else {
        throw DriverFailure("window_identity_changed", exitStatus: 4, candidateCount: matches.count)
    }
    switch context.applicationMode {
    case .desktop:
        return processWindows.count
    case .relayKit:
        return matches.count
    }
}

private func boundWindowIndex(
    windowNumbers: [UInt32?],
    expectedWindowID: UInt32,
    windowServerWindowCount: Int
) throws -> Int {
    let exactMatches = windowNumbers.indices.filter { windowNumbers[$0] == expectedWindowID }
    if exactMatches.count == 1 {
        return exactMatches[0]
    }
    if exactMatches.isEmpty,
       windowServerWindowCount == 1,
       windowNumbers.count == 1 {
        return 0
    }
    throw DriverFailure("window_selector_not_unique", exitStatus: 4, candidateCount: windowNumbers.count)
}

private func verifyApplicationIdentity(
    context: DriverContext,
    currentIdentity: WindowIdentity,
    processIsRunning: Bool,
    bundleIdentifier: String?,
    windowServerMetadata: () -> [WindowServerMetadata],
    frontmostPID: () -> pid_t?,
    accessibilityTrusted: () -> Bool,
    requireFrontmost: Bool
) throws -> Int {
    guard currentIdentity == context.identity, currentIdentity.pid == context.pid else {
        throw DriverFailure("window_identity_changed", exitStatus: 4)
    }
    guard processIsRunning else {
        throw DriverFailure("process_unavailable", exitStatus: 4)
    }
    guard bundleIdentifier == context.applicationMode.expectedBundleIdentifier else {
        throw DriverFailure("process_identity_mismatch", exitStatus: 4)
    }
    let windowServerWindowCount = try verifyWindowServerIdentity(
        context,
        windows: windowServerMetadata()
    )
    if requireFrontmost, frontmostPID() != context.pid {
        throw DriverFailure("frontmost_identity_mismatch", exitStatus: 4)
    }
    guard accessibilityTrusted() else {
        throw DriverFailure("accessibility_permission_unavailable", exitStatus: 4)
    }
    return windowServerWindowCount
}

private func resolveBoundWindowIndex(
    context: DriverContext,
    currentIdentity: WindowIdentity,
    processIsRunning: Bool,
    bundleIdentifier: String?,
    windowServerMetadata: () -> [WindowServerMetadata],
    frontmostPID: () -> pid_t?,
    accessibilityTrusted: () -> Bool,
    axWindowNumbers: () -> [UInt32?]
) throws -> Int {
    let windowServerWindowCount = try verifyApplicationIdentity(
        context: context,
        currentIdentity: currentIdentity,
        processIsRunning: processIsRunning,
        bundleIdentifier: bundleIdentifier,
        windowServerMetadata: windowServerMetadata,
        frontmostPID: frontmostPID,
        accessibilityTrusted: accessibilityTrusted,
        requireFrontmost: context.applicationMode == .desktop
    )
    return try boundWindowIndex(
        windowNumbers: axWindowNumbers(),
        expectedWindowID: context.identity.windowID,
        windowServerWindowCount: windowServerWindowCount
    )
}

private struct BoundActionRoot<Node> {
    let root: Node
    let candidateCount: Int
}

private func uniqueRelayKitPopoverRoot<Node>(
    applicationRoot: Node,
    role: (Node) -> String?,
    children: (Node) -> [Node]?,
    identical: (Node, Node) -> Bool
) throws -> Node {
    var visited: [Node] = []
    var candidates: [Node] = []
    var truncated = false
    var childrenUnavailable = false

    func append(_ node: Node, depth: Int) {
        guard depth <= maximumRelayKitBindingDepth,
              visited.count < maximumRelayKitBindingNodes else {
            truncated = true
            return
        }
        guard !visited.contains(where: { identical($0, node) }) else {
            truncated = true
            return
        }
        visited.append(node)

        if depth > 0, role(node) == "AXPopover" {
            candidates.append(node)
        }
        guard let nodeChildren = children(node) else {
            childrenUnavailable = true
            return
        }
        if depth == maximumRelayKitBindingDepth {
            if !nodeChildren.isEmpty {
                truncated = true
            }
            return
        }
        for child in nodeChildren {
            guard visited.count < maximumRelayKitBindingNodes else {
                truncated = true
                break
            }
            append(child, depth: depth + 1)
        }
    }

    append(applicationRoot, depth: 0)
    guard !childrenUnavailable, !truncated, candidates.count == 1 else {
        throw DriverFailure(
            "window_selector_not_unique",
            exitStatus: 4,
            candidateCount: candidates.count
        )
    }
    return candidates[0]
}

private func uniqueRelayKitPopoverRoot(applicationRoot: AXUIElement) throws -> AXUIElement {
    try uniqueRelayKitPopoverRoot(
        applicationRoot: applicationRoot,
        role: { copyAXString($0, kAXRoleAttribute as CFString) },
        children: {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                $0,
                kAXChildrenAttribute as CFString,
                &value
            ) == .success,
            let children = value as? [AXUIElement] else {
                return nil
            }
            return children
        },
        identical: { CFEqual($0, $1) }
    )
}

private func resolveBoundActionRoot<Node>(
    context: DriverContext,
    currentIdentity: WindowIdentity,
    processIsRunning: Bool,
    bundleIdentifier: String?,
    windowServerMetadata: () -> [WindowServerMetadata],
    frontmostPID: () -> pid_t?,
    accessibilityTrusted: () -> Bool,
    axWindows: () -> (available: Bool, roots: [Node]),
    axWindowNumber: (Node) -> UInt32?,
    relayKitPopoverRoot: () throws -> Node
) throws -> BoundActionRoot<Node> {
    let windowServerWindowCount = try verifyApplicationIdentity(
        context: context,
        currentIdentity: currentIdentity,
        processIsRunning: processIsRunning,
        bundleIdentifier: bundleIdentifier,
        windowServerMetadata: windowServerMetadata,
        frontmostPID: frontmostPID,
        accessibilityTrusted: accessibilityTrusted,
        requireFrontmost: context.applicationMode == .desktop
    )
    let availableAXWindows = axWindows()
    guard availableAXWindows.available else {
        throw DriverFailure("window_selector_not_unique", exitStatus: 4, candidateCount: 0)
    }
    let axWindowRoots = availableAXWindows.roots
    if !axWindowRoots.isEmpty || context.applicationMode == .desktop {
        let windowNumbers = axWindowRoots.map(axWindowNumber)
        if context.applicationMode == .relayKit,
           !windowNumbers.allSatisfy({ $0 == nil }),
           windowNumbers.filter({ $0 == context.identity.windowID }).count != 1 {
            throw DriverFailure(
                "window_selector_not_unique",
                exitStatus: 4,
                candidateCount: axWindowRoots.count
            )
        }
        let selectedIndex = try boundWindowIndex(
            windowNumbers: windowNumbers,
            expectedWindowID: context.identity.windowID,
            windowServerWindowCount: windowServerWindowCount
        )
        return BoundActionRoot(root: axWindowRoots[selectedIndex], candidateCount: axWindowRoots.count)
    }
    return BoundActionRoot(root: try relayKitPopoverRoot(), candidateCount: 1)
}

private func verifyBoundWindow(_ context: DriverContext) throws -> BoundWindow {
    let currentIdentity = try readWindowIdentity(context.identityPath)
    let running = NSRunningApplication(processIdentifier: context.pid)
    let selection = try resolveBoundActionRoot(
        context: context,
        currentIdentity: currentIdentity,
        processIsRunning: running.map { !$0.isTerminated } ?? false,
        bundleIdentifier: running?.bundleIdentifier,
        windowServerMetadata: currentWindowServerMetadata,
        frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        accessibilityTrusted: { AXIsProcessTrusted() },
        axWindows: {
            let application = AXUIElementCreateApplication(context.pid)
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(
                application,
                kAXWindowsAttribute as CFString,
                &value
            )
            let windows = value as? [AXUIElement]
            return (status == .success && windows != nil, windows ?? [])
        },
        axWindowNumber: axWindowNumber,
        relayKitPopoverRoot: {
            try uniqueRelayKitPopoverRoot(
                applicationRoot: AXUIElementCreateApplication(context.pid)
            )
        }
    )
    return BoundWindow(window: selection.root)
}

private struct SemanticRecord {
    let role: String
    let semanticStrings: Set<String>
    let enabled: Bool
    let writable: Bool
    let pressable: Bool
}

private struct AXNode {
    let element: AXUIElement
    let semantic: SemanticRecord
}

private typealias SemanticSelector = (SemanticRecord) -> Bool

private func copyAXString(_ element: AXUIElement, _ attribute: CFString) -> String? {
    copyAXAttribute(element, attribute) as? String
}

private func semanticRecord(for element: AXUIElement) -> SemanticRecord {
    let role = copyAXString(element, kAXRoleAttribute as CFString) ?? ""
    let semanticAttributes: [CFString] = [
        kAXTitleAttribute as CFString,
        kAXDescriptionAttribute as CFString,
        kAXHelpAttribute as CFString,
        kAXValueAttribute as CFString,
        axIdentifierAttribute,
        axLabelAttribute,
        axPlaceholderValueAttribute,
    ]
    var semanticStrings = Set<String>()
    for attribute in semanticAttributes {
        if let value = copyAXString(element, attribute), !value.isEmpty {
            semanticStrings.insert(value)
        }
    }

    let enabled = (copyAXAttribute(element, kAXEnabledAttribute as CFString) as? NSNumber)?.boolValue == true
    var settable = DarwinBoolean(false)
    let writable = AXUIElementIsAttributeSettable(
        element,
        kAXValueAttribute as CFString,
        &settable
    ) == .success && settable.boolValue

    var actionValues: CFArray?
    let actionNames: [String]
    if AXUIElementCopyActionNames(element, &actionValues) == .success,
       let copied = actionValues as? [String] {
        actionNames = copied
    } else {
        actionNames = []
    }
    let pressable = actionNames.firstIndex(of: kAXPressAction as String) != nil
    return SemanticRecord(
        role: role,
        semanticStrings: semanticStrings,
        enabled: enabled,
        writable: writable,
        pressable: pressable
    )
}

private func appendAXNodes(
    from element: AXUIElement,
    depth: Int,
    nodes: inout [AXNode]
) throws {
    guard depth <= maximumAXDepth, nodes.count < maximumAXNodes else {
        throw DriverFailure("ax_tree_limit", exitStatus: 4)
    }
    nodes.append(AXNode(element: element, semantic: semanticRecord(for: element)))
    let children = copyAXAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
    for child in children {
        try appendAXNodes(from: child, depth: depth + 1, nodes: &nodes)
    }
}

private func collectAXNodes(from window: AXUIElement) throws -> [AXNode] {
    var nodes: [AXNode] = []
    try appendAXNodes(from: window, depth: 0, nodes: &nodes)
    return nodes
}

private func appendMatchingAXNodes(
    from element: AXUIElement,
    depth: Int,
    selector: SemanticSelector,
    visited: inout Int,
    matches: inout [AXNode]
) throws {
    guard depth <= maximumAXDepth, visited < maximumAXNodes else {
        throw DriverFailure("ax_tree_limit", exitStatus: 4)
    }
    visited += 1
    let node = AXNode(element: element, semantic: semanticRecord(for: element))
    if selector(node.semantic) {
        matches.append(node)
        if matches.count > 1 {
            return
        }
    }
    let children = copyAXAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
    for child in children where matches.count <= 1 {
        try appendMatchingAXNodes(
            from: child,
            depth: depth + 1,
            selector: selector,
            visited: &visited,
            matches: &matches
        )
    }
}

private func applicationOverlayMatches(
    context: DriverContext,
    selector: @escaping SemanticSelector
) throws -> [AXNode] {
    let root: AXUIElement
    switch context.applicationMode {
    case .desktop:
        _ = try verifyBoundWindow(context)
        root = AXUIElementCreateApplication(context.pid)
    case .relayKit:
        root = try verifyBoundWindow(context).window
    }
    var visited = 0
    var matches: [AXNode] = []
    try appendMatchingAXNodes(
        from: root,
        depth: 0,
        selector: selector,
        visited: &visited,
        matches: &matches
    )
    return matches
}

private func applicationOverlayNode(
    context: DriverContext,
    selector: @escaping SemanticSelector
) throws -> AXNode {
    let matches = try applicationOverlayMatches(context: context, selector: selector)
    guard matches.count == 1 else {
        throw DriverFailure("selector_not_unique", exitStatus: 5, candidateCount: matches.count)
    }
    return matches[0]
}

private func semanticSnapshot(_ nodes: [AXNode]) -> [String] {
    nodes.flatMap { node in
        node.semantic.semanticStrings.map { "\(node.semantic.role)\u{1f}\($0)" }
    }.sorted()
}

private func matchingIndices(
    in records: [SemanticRecord],
    selector: SemanticSelector
) -> [Int] {
    records.indices.filter { selector(records[$0]) }
}

private func requireUniqueIndex(_ indices: [Int]) throws -> Int {
    guard indices.count == 1 else {
        throw DriverFailure("selector_not_unique", exitStatus: 5, candidateCount: indices.count)
    }
    return indices[0]
}

private func requireUniqueNode(
    in nodes: [AXNode],
    selector: SemanticSelector
) throws -> AXNode {
    let index = try requireUniqueIndex(matchingIndices(in: nodes.map(\.semantic), selector: selector))
    return nodes[index]
}

private func withSelectorFailureCode<T>(
    _ code: String,
    operation: () throws -> T
) throws -> T {
    do {
        return try operation()
    } catch let failure as DriverFailure where failure.code == "selector_not_unique" {
        throw DriverFailure(code, exitStatus: failure.exitStatus, candidateCount: failure.candidateCount)
    }
}

private func exactSemanticMatch(_ record: SemanticRecord, accepted: Set<String>) -> Bool {
    for value in record.semanticStrings where accepted.contains(value) {
        return true
    }
    return false
}

private let composerSelector: SemanticSelector = { record in
    let roles = Set([kAXTextAreaRole as String, kAXTextFieldRole as String])
    return roles.contains(record.role) && record.enabled && record.writable
}

private let sendLabels = Set(["Send", "发送"])
private let sendSelector: SemanticSelector = { record in
    record.role == kAXButtonRole as String &&
        record.enabled &&
        record.pressable &&
        exactSemanticMatch(record, accepted: sendLabels)
}

private let addContentLabels = Set(["添加文件等内容", "Add files and more", "Add files"])
private let fullAccessLabels = Set(["完全访问", "Full access"])
private let dictationLabels = Set(["听写", "Dictation"])
private let unlabeledButtonSelector: SemanticSelector = { record in
    record.role == kAXButtonRole as String &&
        record.enabled &&
        record.pressable &&
        record.semanticStrings.isEmpty
}

private func structuralSendButtonIndex(in records: [SemanticRecord]) throws -> Int {
    let hasAddContent = records.contains { exactSemanticMatch($0, accepted: addContentLabels) }
    let hasFullAccess = records.contains { exactSemanticMatch($0, accepted: fullAccessLabels) }
    let hasDictation = records.contains { exactSemanticMatch($0, accepted: dictationLabels) }
    let candidates = matchingIndices(in: records, selector: unlabeledButtonSelector)
    guard hasAddContent, hasFullAccess, hasDictation, candidates.count == 1 else {
        throw DriverFailure("send_selector_not_unique", exitStatus: 5, candidateCount: candidates.count)
    }
    return candidates[0]
}

private let reasoningEffortLabels = ["低", "中", "高", "超高", "Low", "Medium", "High", "Extra High"]

private func codexModelMenuLabel(catalogLabel: String) -> String {
    guard catalogLabel.hasPrefix("GPT-") else { return catalogLabel }
    return String(catalogLabel.dropFirst(4)).replacingOccurrences(of: "-", with: " ")
}

private func modelPickerLabels(catalogLabels: Set<String>) -> Set<String> {
    Set(catalogLabels.flatMap { label in
        let menuLabel = codexModelMenuLabel(catalogLabel: label)
        return [menuLabel] + reasoningEffortLabels.map { "\(menuLabel) \($0)" }
    })
}

private func modelPickerSelector(catalogLabels: Set<String>) -> SemanticSelector {
    let accepted = modelPickerLabels(catalogLabels: catalogLabels)
    return { record in
        record.role == kAXPopUpButtonRole as String &&
            record.enabled &&
            record.pressable &&
            exactSemanticMatch(record, accepted: accepted)
    }
}

private func menuItemSelector(modelLabel: String) -> SemanticSelector {
    let target = Set([codexModelMenuLabel(catalogLabel: modelLabel)])
    return { record in
        record.role == kAXMenuItemRole as String &&
            record.enabled &&
            record.pressable &&
            exactSemanticMatch(record, accepted: target)
    }
}

private func modelCategorySelector(catalogLabels: Set<String>) -> SemanticSelector {
    let labels = Set(catalogLabels.flatMap { label -> [String] in
        let menuLabel = codexModelMenuLabel(catalogLabel: label)
        return ["模型 \(menuLabel)", "Model \(menuLabel)"]
    })
    return { record in
        record.role == kAXMenuItemRole as String &&
            record.enabled &&
            record.pressable &&
            exactSemanticMatch(record, accepted: labels)
    }
}

private func workspaceOpenerSelector(workspace: String) -> SemanticSelector {
    let labels = Set([
        "New task in \(workspace)",
        "在 \(workspace) 中新建任务",
    ])
    let roles = Set([kAXButtonRole as String, axLinkRole, kAXMenuItemRole as String])
    return { record in
        roles.contains(record.role) &&
            record.enabled &&
            record.pressable &&
            exactSemanticMatch(record, accepted: labels)
    }
}

private func markdownHeadingSelector(text: String) -> SemanticSelector {
    { record in
        record.role == kAXHeadingRole as String &&
            exactSemanticMatch(record, accepted: Set([text]))
    }
}

private func performAXAction(_ element: AXUIElement, action: CFString) -> AXError {
    AXUIElementPerformAction(element, action)
}

private func currentNodes(_ context: DriverContext) throws -> [AXNode] {
    let bound = try verifyBoundWindow(context)
    return try collectAXNodes(from: bound.window)
}

private func structuralSendButton(context: DriverContext) throws -> AXNode {
    let nodes = try currentNodes(context)
    let composer = try requireUniqueNode(in: nodes, selector: composerSelector)
    var ancestor = composer.element
    var lastCandidateCount = 0
    for _ in 0..<7 {
        guard let parentValue = copyAXAttribute(ancestor, kAXParentAttribute as CFString) else {
            break
        }
        let parent = parentValue as! AXUIElement
        ancestor = parent
        let containerNodes = try collectAXNodes(from: ancestor)
        let records = containerNodes.map(\.semantic)
        lastCandidateCount = matchingIndices(in: records, selector: unlabeledButtonSelector).count
        do {
            return containerNodes[try structuralSendButtonIndex(in: records)]
        } catch let failure as DriverFailure where failure.code == "send_selector_not_unique" {
            continue
        }
    }
    throw DriverFailure("send_selector_not_unique", exitStatus: 5, candidateCount: lastCandidateCount)
}

private func performVerifiedPress(
    context: DriverContext,
    selector: SemanticSelector,
    ambiguousAfterAttempt: Bool = false,
    targetProvider: ((DriverContext) throws -> AXNode)? = nil
) throws {
    let before = try verifyBoundWindow(context)
    let target: AXNode
    if let targetProvider {
        target = try targetProvider(context)
    } else {
        target = try requireUniqueNode(in: collectAXNodes(from: before.window), selector: selector)
    }
    let result = performAXAction(target.element, action: kAXPressAction as CFString)
    guard result == .success else {
        let code = ambiguousAfterAttempt ? "send_result_ambiguous" : "ax_press_failed"
        throw DriverFailure(code, exitStatus: ambiguousAfterAttempt ? 7 : 6)
    }
    do {
        _ = try verifyBoundWindow(context)
    } catch {
        if ambiguousAfterAttempt {
            throw DriverFailure("send_result_ambiguous", exitStatus: 7)
        }
        throw error
    }
}

private func performVerifiedWrite(
    context: DriverContext,
    selector: SemanticSelector,
    value: String,
    failureCode: String = "composer_write_failed"
) throws {
    let before = try verifyBoundWindow(context)
    let target = try requireUniqueNode(in: collectAXNodes(from: before.window), selector: selector)
    guard AXUIElementSetAttributeValue(
        target.element,
        kAXValueAttribute as CFString,
        value as CFString
    ) == .success else {
        throw DriverFailure(failureCode, exitStatus: 6)
    }
    _ = try verifyBoundWindow(context)
}

private func waitForUniqueSelector(
    context: DriverContext,
    selector: @escaping SemanticSelector
) throws {
    let deadline = Date().addingTimeInterval(selectorWaitSeconds)
    while true {
        let nodes = try currentNodes(context)
        let matches = matchingIndices(in: nodes.map(\.semantic), selector: selector)
        if matches.count == 1 {
            return
        }
        if matches.count > 1 || Date() >= deadline {
            throw DriverFailure("selector_not_unique", exitStatus: 5, candidateCount: matches.count)
        }
        Thread.sleep(forTimeInterval: selectorPollSeconds)
    }
}

private func waitForUniqueApplicationOverlaySelector(
    context: DriverContext,
    selector: @escaping SemanticSelector
) throws {
    let deadline = Date().addingTimeInterval(selectorWaitSeconds)
    while true {
        let matches = try applicationOverlayMatches(context: context, selector: selector)
        if matches.count == 1 {
            return
        }
        if matches.count > 1 || Date() >= deadline {
            throw DriverFailure("selector_not_unique", exitStatus: 5, candidateCount: matches.count)
        }
        Thread.sleep(forTimeInterval: selectorPollSeconds)
    }
}

private func waitForFreshComposer(
    context: DriverContext,
    previousComposer: AXUIElement?,
    previousSnapshot: [String]
) throws -> [AXNode] {
    let deadline = Date().addingTimeInterval(selectorWaitSeconds)
    while true {
        let nodes = try currentNodes(context)
        let matches = matchingIndices(in: nodes.map(\.semantic), selector: composerSelector)
        if matches.count == 1 {
            let candidate = nodes[matches[0]].element
            if previousComposer == nil ||
                !CFEqual(candidate, previousComposer) ||
                semanticSnapshot(nodes) != previousSnapshot {
                return nodes
            }
        }
        if matches.count > 1 {
            throw DriverFailure("selector_not_unique", exitStatus: 5, candidateCount: matches.count)
        }
        if Date() >= deadline {
            if matches.count == 1 {
                let candidate = nodes[matches[0]].element
                if composerIsEmpty(
                    value: copyAXString(candidate, kAXValueAttribute as CFString),
                    placeholder: copyAXString(candidate, axPlaceholderValueAttribute)
                ) {
                    return nodes
                }
            }
            throw DriverFailure("fresh_task_not_verified", exitStatus: 5, candidateCount: matches.count)
        }
        Thread.sleep(forTimeInterval: selectorPollSeconds)
    }
}

private func waitForComposerReadback(
    context: DriverContext,
    expected: String
) throws -> [AXNode] {
    let deadline = Date().addingTimeInterval(selectorWaitSeconds)
    while true {
        let nodes = try currentNodes(context)
        let matches = matchingIndices(in: nodes.map(\.semantic), selector: composerSelector)
        if matches.count == 1,
           composerReadbackMatches(
               actual: copyAXString(nodes[matches[0]].element, kAXValueAttribute as CFString),
               expected: expected
           ) {
            return nodes
        }
        if matches.count > 1 {
            throw DriverFailure("selector_not_unique", exitStatus: 5, candidateCount: matches.count)
        }
        if Date() >= deadline {
            throw DriverFailure("composer_readback_mismatch", exitStatus: 6, candidateCount: matches.count)
        }
        Thread.sleep(forTimeInterval: selectorPollSeconds)
    }
}

private func waitForModelSelection(
    context: DriverContext,
    pickerSelector: @escaping SemanticSelector,
    modelLabel: String
) throws {
    let deadline = Date().addingTimeInterval(selectorWaitSeconds)
    let target = modelPickerLabels(catalogLabels: Set([modelLabel]))
    while true {
        let nodes = try currentNodes(context)
        let matches = matchingIndices(in: nodes.map(\.semantic), selector: pickerSelector)
        if matches.count == 1,
           exactSemanticMatch(nodes[matches[0]].semantic, accepted: target) {
            return
        }
        if matches.count > 1 {
            throw DriverFailure("selector_not_unique", exitStatus: 5, candidateCount: matches.count)
        }
        if Date() >= deadline {
            let code = matches.isEmpty ? "selector_not_unique" : "model_selection_not_verified"
            throw DriverFailure(code, exitStatus: 5, candidateCount: matches.count)
        }
        Thread.sleep(forTimeInterval: selectorPollSeconds)
    }
}

private struct AXDiagnosticNodeRecord: Encodable {
    let ordinal: Int
    let parent: Int?
    let depth: Int
    let role: String
    let subrole: String?
    let childCount: Int
    let windowNumberPresent: Bool
    let matchesExpectedWindow: Bool

    enum CodingKeys: String, CodingKey {
        case ordinal
        case parent
        case depth
        case role
        case subrole
        case childCount = "child_count"
        case windowNumberPresent = "window_number_present"
        case matchesExpectedWindow = "matches_expected_window"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ordinal, forKey: .ordinal)
        if let parent {
            try container.encode(parent, forKey: .parent)
        } else {
            try container.encodeNil(forKey: .parent)
        }
        try container.encode(depth, forKey: .depth)
        try container.encode(role, forKey: .role)
        if let subrole {
            try container.encode(subrole, forKey: .subrole)
        } else {
            try container.encodeNil(forKey: .subrole)
        }
        try container.encode(childCount, forKey: .childCount)
        try container.encode(windowNumberPresent, forKey: .windowNumberPresent)
        try container.encode(matchesExpectedWindow, forKey: .matchesExpectedWindow)
    }
}

private struct AXDiagnosticRoleCount: Encodable {
    let role: String
    let count: Int
}

private struct AXDiagnosticDepthCount: Encodable {
    let depth: Int
    let count: Int
}

private struct AXDiagnosticReport: Encodable {
    let status: String
    let nodes: [AXDiagnosticNodeRecord]
    let roleCounts: [AXDiagnosticRoleCount]
    let depthCounts: [AXDiagnosticDepthCount]
    let axWindowsAvailable: Bool
    let axWindowsCount: Int
    let numberedWindowCount: Int
    let matchingWindowCount: Int
    let truncated: Bool

    enum CodingKeys: String, CodingKey {
        case status
        case nodes
        case roleCounts = "role_counts"
        case depthCounts = "depth_counts"
        case axWindowsAvailable = "ax_windows_available"
        case axWindowsCount = "ax_windows_count"
        case numberedWindowCount = "numbered_window_count"
        case matchingWindowCount = "matching_window_count"
        case truncated
    }
}

private func sanitizedAXRole(_ value: String?) -> String {
    guard let value,
          value.hasPrefix("AX"),
          value.utf8.count <= 64,
          value.unicodeScalars.allSatisfy({ scalar in
              switch scalar.value {
              case 48...57, 65...90, 95, 97...122:
                  return true
              default:
                  return false
              }
          }) else {
        return "AXUnknown"
    }
    return value
}

private func makeAXDiagnosticReport<Node>(
    root: Node,
    expectedWindowID: UInt32,
    axWindowsAvailable: Bool,
    axWindowsCount: Int,
    role: (Node) -> String?,
    subrole: (Node) -> String?,
    children: (Node) -> [Node],
    windowNumber: (Node) -> UInt32?,
    identical: (Node, Node) -> Bool
) -> AXDiagnosticReport {
    var records: [AXDiagnosticNodeRecord] = []
    var visited: [Node] = []
    var truncated = false

    func append(_ node: Node, parent: Int?, depth: Int) {
        guard depth <= maximumAXDiagnosticDepth,
              records.count < maximumAXDiagnosticNodes else {
            truncated = true
            return
        }
        guard !visited.contains(where: { identical($0, node) }) else {
            truncated = true
            return
        }
        visited.append(node)

        let nodeChildren = children(node)
        let nodeWindowNumber = windowNumber(node)
        let ordinal = records.count
        let rawSubrole = subrole(node)
        records.append(AXDiagnosticNodeRecord(
            ordinal: ordinal,
            parent: parent,
            depth: depth,
            role: sanitizedAXRole(role(node)),
            subrole: rawSubrole.map { sanitizedAXRole($0) },
            childCount: nodeChildren.count,
            windowNumberPresent: nodeWindowNumber != nil,
            matchesExpectedWindow: nodeWindowNumber == expectedWindowID
        ))

        if depth == maximumAXDiagnosticDepth {
            if !nodeChildren.isEmpty {
                truncated = true
            }
            return
        }
        for child in nodeChildren {
            guard records.count < maximumAXDiagnosticNodes else {
                truncated = true
                break
            }
            append(child, parent: ordinal, depth: depth + 1)
        }
    }

    append(root, parent: nil, depth: 0)
    let roleCounts = Dictionary(grouping: records, by: { $0.role })
        .map { AXDiagnosticRoleCount(role: $0.key, count: $0.value.count) }
        .sorted { $0.role < $1.role }
    let depthCounts = Dictionary(grouping: records, by: { $0.depth })
        .map { AXDiagnosticDepthCount(depth: $0.key, count: $0.value.count) }
        .sorted { $0.depth < $1.depth }
    return AXDiagnosticReport(
        status: "ok",
        nodes: records,
        roleCounts: roleCounts,
        depthCounts: depthCounts,
        axWindowsAvailable: axWindowsAvailable,
        axWindowsCount: axWindowsCount,
        numberedWindowCount: records.filter(\.windowNumberPresent).count,
        matchingWindowCount: records.filter(\.matchesExpectedWindow).count,
        truncated: truncated
    )
}

private func writeAtomicPrivateJSON<T: Encodable>(_ value: T, to path: String) throws {
    guard path.hasPrefix("/"), !FileManager.default.fileExists(atPath: path) else {
        throw DriverFailure("diagnostic_output_invalid", exitStatus: 3)
    }
    let parent = (path as NSString).deletingLastPathComponent
    var parentMetadata = stat()
    guard lstat(parent, &parentMetadata) == 0,
          parentMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
          parentMetadata.st_uid == getuid() else {
        throw DriverFailure("diagnostic_output_invalid", exitStatus: 3)
    }

    let temporaryPath = "\(path).tmp.\(getpid()).\(UUID().uuidString)"
    let descriptor = Darwin.open(
        temporaryPath,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
        mode_t(S_IRUSR | S_IWUSR)
    )
    guard descriptor >= 0 else {
        throw DriverFailure("diagnostic_output_invalid", exitStatus: 3)
    }
    var renamed = false
    defer {
        closeDescriptor(descriptor)
        if !renamed {
            _ = Darwin.unlink(temporaryPath)
        }
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var data: Data
    do {
        data = try encoder.encode(value)
    } catch {
        throw DriverFailure("diagnostic_output_invalid", exitStatus: 3)
    }
    data.append(0x0a)
    let wroteAll = data.withUnsafeBytes { rawBuffer -> Bool in
        guard let baseAddress = rawBuffer.baseAddress else { return false }
        var offset = 0
        while offset < rawBuffer.count {
            let result = Darwin.write(
                descriptor,
                baseAddress.advanced(by: offset),
                rawBuffer.count - offset
            )
            if result <= 0 {
                return false
            }
            offset += result
        }
        return true
    }
    guard wroteAll,
          Darwin.fsync(descriptor) == 0,
          Darwin.rename(temporaryPath, path) == 0 else {
        throw DriverFailure("diagnostic_output_invalid", exitStatus: 3)
    }
    renamed = true
}

private func verifyAXDiagnosticIdentity(_ context: DriverContext) throws {
    let currentIdentity = try readWindowIdentity(context.identityPath)
    let running = NSRunningApplication(processIdentifier: context.pid)
    _ = try verifyApplicationIdentity(
        context: context,
        currentIdentity: currentIdentity,
        processIsRunning: running.map { !$0.isTerminated } ?? false,
        bundleIdentifier: running?.bundleIdentifier,
        windowServerMetadata: currentWindowServerMetadata,
        frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        accessibilityTrusted: { AXIsProcessTrusted() },
        requireFrontmost: true
    )
}

private func executeRelayKitAXInspect(options: [String: String]) throws -> DriverReport {
    guard let outputPath = options["--diagnostic-output"] else {
        throw DriverFailure("invalid_arguments", exitStatus: 2)
    }
    let context = try makeContext(options: options, command: .relayKitAXInspect)
    try verifyAXDiagnosticIdentity(context)

    let application = AXUIElementCreateApplication(context.pid)
    var axWindowsValue: CFTypeRef?
    let axWindowsStatus = AXUIElementCopyAttributeValue(
        application,
        kAXWindowsAttribute as CFString,
        &axWindowsValue
    )
    let axWindows = axWindowsValue as? [AXUIElement]
    let report = makeAXDiagnosticReport(
        root: application,
        expectedWindowID: context.identity.windowID,
        axWindowsAvailable: axWindowsStatus == .success && axWindows != nil,
        axWindowsCount: axWindows?.count ?? 0,
        role: { copyAXString($0, kAXRoleAttribute as CFString) },
        subrole: { copyAXString($0, kAXSubroleAttribute as CFString) },
        children: {
            copyAXAttribute($0, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
        },
        windowNumber: axWindowNumber,
        identical: { CFEqual($0, $1) }
    )
    try writeAtomicPrivateJSON(report, to: outputPath)
    return .success(
        command: "relaykit-ax-inspect",
        windowVerified: true,
        actionCount: 0
    )
}

private func executeInspect(options: [String: String]) throws -> DriverReport {
    let context = try makeContext(options: options, command: .inspect)
    let nodes = try currentNodes(context)
    let records = nodes.map(\.semantic)
    let pickerCount = records.filter { $0.role == kAXPopUpButtonRole as String }.count
    let composerCount = matchingIndices(in: records, selector: composerSelector).count
    let sendCount = matchingIndices(in: records, selector: sendSelector).count
    return .success(
        command: "inspect",
        windowVerified: true,
        modelPickerCount: pickerCount,
        composerCount: composerCount,
        sendCount: sendCount,
        actionCount: 0
    )
}

private func executeReveal(options: [String: String]) throws -> DriverReport {
    guard let text = options["--text"],
          !text.isEmpty,
          text.utf8.count <= 256,
          !text.contains("\n"),
          !text.contains("\r") else {
        throw DriverFailure("invalid_arguments", exitStatus: 2)
    }
    let context = try makeContext(options: options, command: .reveal)
    let target = try requireUniqueNode(
        in: currentNodes(context),
        selector: markdownHeadingSelector(text: text)
    )
    guard performAXAction(target.element, action: "AXScrollToVisible" as CFString) == .success else {
        throw DriverFailure("reveal_failed", exitStatus: 6)
    }
    _ = try verifyBoundWindow(context)
    return .success(command: "reveal", windowVerified: true, candidateCount: 1, actionCount: 1)
}

private func executeReady(options: [String: String]) throws -> DriverReport {
    guard let catalogPath = options["--catalog-labels-file"] else {
        throw DriverFailure("invalid_arguments", exitStatus: 2)
    }
    let catalogLabels = try readCatalogLabels(catalogPath)
    let context = try makeContext(options: options, command: .ready)
    let nodes = try currentNodes(context)
    let records = nodes.map(\.semantic)
    let pickerCount = matchingIndices(in: records, selector: modelPickerSelector(catalogLabels: catalogLabels)).count
    let composerCount = matchingIndices(in: records, selector: composerSelector).count
    guard pickerCount == 1, composerCount == 1 else {
        throw DriverFailure("desktop_ui_not_ready", exitStatus: 5, candidateCount: pickerCount)
    }
    return .success(
        command: "ready",
        windowVerified: true,
        modelPickerCount: pickerCount,
        composerCount: composerCount,
        sendCount: 0,
        actionCount: 0
    )
}

private func executePrepare(options: [String: String]) throws -> DriverReport {
    guard let workspace = options["--workspace"] else {
        throw DriverFailure("invalid_arguments", exitStatus: 2)
    }
    let context = try makeContext(options: options, command: .prepare)
    let previousNodes = try currentNodes(context)
    let previousMatches = matchingIndices(in: previousNodes.map(\.semantic), selector: composerSelector)
    if previousMatches.count > 1 {
        throw DriverFailure("selector_not_unique", exitStatus: 5, candidateCount: previousMatches.count)
    }
    let previousComposer = previousMatches.first.map { previousNodes[$0].element }
    let previousSnapshot = semanticSnapshot(previousNodes)
    try performVerifiedPress(context: context, selector: workspaceOpenerSelector(workspace: workspace))
    let nodes = try waitForFreshComposer(
        context: context,
        previousComposer: previousComposer,
        previousSnapshot: previousSnapshot
    )
    let composerMatches = matchingIndices(in: nodes.map(\.semantic), selector: composerSelector)

    let pickerCount = nodes.map(\.semantic).filter { $0.role == kAXPopUpButtonRole as String }.count
    let sendCount = matchingIndices(in: nodes.map(\.semantic), selector: sendSelector).count
    return .success(
        command: "prepare",
        windowVerified: true,
        modelPickerCount: pickerCount,
        composerCount: composerMatches.count,
        sendCount: sendCount,
        actionCount: 1
    )
}

private func executeSubmit(options: [String: String]) throws -> DriverReport {
    guard let modelLabel = options["--model-label"],
          let catalogPath = options["--catalog-labels-file"],
          let queryPath = options["--query-file"] else {
        throw DriverFailure("invalid_arguments", exitStatus: 2)
    }
    let catalogLabels = try readCatalogLabels(catalogPath)
    guard catalogLabels.contains(modelLabel) else {
        throw DriverFailure("model_label_not_in_catalog", exitStatus: 3)
    }
    try validateSecureFile(queryPath, kind: .query)

    let context = try makeContext(options: options, command: .submit)
    let pickerSelector = modelPickerSelector(catalogLabels: catalogLabels)
    try withSelectorFailureCode("model_picker_not_unique") {
        try waitForUniqueSelector(context: context, selector: pickerSelector)
    }
    var nodes = try currentNodes(context)
    var picker = try withSelectorFailureCode("model_picker_not_unique") {
        try requireUniqueNode(in: nodes, selector: pickerSelector)
    }
    var actionCount = 0
    let targetLabels = modelPickerLabels(catalogLabels: Set([modelLabel]))

    if !exactSemanticMatch(picker.semantic, accepted: targetLabels) {
        try performVerifiedPress(context: context, selector: pickerSelector)
        actionCount += 1
        let categorySelector = modelCategorySelector(catalogLabels: catalogLabels)
        try withSelectorFailureCode("model_category_not_unique") {
            try waitForUniqueApplicationOverlaySelector(context: context, selector: categorySelector)
            try performVerifiedPress(
                context: context,
                selector: categorySelector,
                targetProvider: { try applicationOverlayNode(context: $0, selector: categorySelector) }
            )
        }
        actionCount += 1
        let exactMenuItem = menuItemSelector(modelLabel: modelLabel)
        try withSelectorFailureCode("model_menu_item_not_unique") {
            try waitForUniqueApplicationOverlaySelector(context: context, selector: exactMenuItem)
            try performVerifiedPress(
                context: context,
                selector: exactMenuItem,
                targetProvider: { try applicationOverlayNode(context: $0, selector: exactMenuItem) }
            )
        }
        actionCount += 1
        try waitForModelSelection(
            context: context,
            pickerSelector: pickerSelector,
            modelLabel: modelLabel
        )
    }

    nodes = try currentNodes(context)
    picker = try withSelectorFailureCode("model_picker_not_unique") {
        try requireUniqueNode(in: nodes, selector: pickerSelector)
    }
    guard exactSemanticMatch(picker.semantic, accepted: targetLabels) else {
        throw DriverFailure("model_selection_not_verified", exitStatus: 5)
    }
    _ = try withSelectorFailureCode("composer_not_unique") {
        try requireUniqueNode(in: nodes, selector: composerSelector)
    }

    let query = try composerValue(query: readQuery(queryPath))
    try performVerifiedWrite(context: context, selector: composerSelector, value: query)
    actionCount += 1

    nodes = try waitForComposerReadback(context: context, expected: query)
    _ = try structuralSendButton(context: context)
    try performVerifiedPress(
        context: context,
        selector: unlabeledButtonSelector,
        ambiguousAfterAttempt: true,
        targetProvider: structuralSendButton
    )
    actionCount += 1
    return .success(
        command: "submit",
        windowVerified: true,
        modelPickerCount: 1,
        composerCount: 1,
        sendCount: 1,
        actionCount: actionCount
    )
}

private func relayKitIdentifierSelector(
    _ identifier: String,
    roles: Set<String> = [],
    writable: Bool = false,
    pressable: Bool = false
) -> SemanticSelector {
    { record in
        (roles.isEmpty || roles.contains(record.role)) &&
            record.enabled &&
            (!writable || record.writable) &&
            (!pressable || record.pressable) &&
            exactSemanticMatch(record, accepted: Set([identifier]))
    }
}

private func relayKitProviderID(_ name: String) -> String {
    let allowed = name.lowercased().unicodeScalars.map { scalar -> Character in
        CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
    }
    return String(allowed).split(separator: "-").joined(separator: "-")
}

private func validatedRelayKitProviderOptions(
    _ options: [String: String],
    requireSyntheticKey: Bool
) throws -> (name: String, baseURL: String, modelID: String, syntheticKey: String?) {
    guard let name = options["--provider-name"],
          let baseURL = options["--base-url"],
          let modelID = options["--model-id"],
          !name.isEmpty, name.utf8.count <= 128,
          !modelID.isEmpty, modelID.utf8.count <= 256,
          !name.contains("\n"), !name.contains("\r"),
          !modelID.contains("\n"), !modelID.contains("\r"),
          relayKitProviderID(name).hasPrefix("dogfood-") else {
        throw DriverFailure("invalid_arguments", exitStatus: 2)
    }
    guard let components = URLComponents(string: baseURL),
          components.scheme == "http",
          components.host == "127.0.0.1",
          components.port != nil,
          components.user == nil,
          components.password == nil,
          components.query == nil,
          components.fragment == nil else {
        throw DriverFailure("invalid_arguments", exitStatus: 2)
    }
    let syntheticKey = options["--synthetic-key"]
    if requireSyntheticKey {
        guard let syntheticKey,
              syntheticKey.hasPrefix("RELAYKIT_FAKE_"),
              syntheticKey.utf8.count <= 256,
              !syntheticKey.contains("\n"),
              !syntheticKey.contains("\r") else {
            throw DriverFailure("invalid_arguments", exitStatus: 2)
        }
    }
    return (name, baseURL, modelID, syntheticKey)
}

private func waitForRelayKitValue(
    context: DriverContext,
    identifier: String,
    expected: String
) throws {
    let selector = relayKitIdentifierSelector(
        identifier,
        roles: Set([kAXTextFieldRole as String, kAXTextAreaRole as String]),
        writable: true
    )
    let deadline = Date().addingTimeInterval(selectorWaitSeconds)
    while true {
        let nodes = try currentNodes(context)
        let matches = matchingIndices(in: nodes.map(\.semantic), selector: selector)
        if matches.count == 1,
           copyAXString(nodes[matches[0]].element, kAXValueAttribute as CFString) == expected {
            return
        }
        if matches.count > 1 || Date() >= deadline {
            throw DriverFailure("relaykit_value_not_verified", exitStatus: 6, candidateCount: matches.count)
        }
        Thread.sleep(forTimeInterval: selectorPollSeconds)
    }
}

private func writeRelayKitField(
    context: DriverContext,
    identifier: String,
    value: String,
    verifyReadback: Bool = true
) throws {
    let selector = relayKitIdentifierSelector(
        identifier,
        roles: Set([kAXTextFieldRole as String, kAXTextAreaRole as String]),
        writable: true
    )
    try waitForUniqueSelector(context: context, selector: selector)
    try performVerifiedWrite(
        context: context,
        selector: selector,
        value: value,
        failureCode: "relaykit_field_write_failed"
    )
    if verifyReadback {
        try waitForRelayKitValue(context: context, identifier: identifier, expected: value)
    }
}

private func waitForRelayKitSemantic(
    context: DriverContext,
    identifier: String,
    expected: String
) throws {
    let selector = relayKitIdentifierSelector(identifier)
    let deadline = Date().addingTimeInterval(selectorWaitSeconds)
    while true {
        let nodes = try currentNodes(context)
        let matches = matchingIndices(in: nodes.map(\.semantic), selector: selector)
        if matches.count == 1,
           exactSemanticMatch(nodes[matches[0]].semantic, accepted: Set([expected])) {
            return
        }
        if matches.count > 1 || Date() >= deadline {
            throw DriverFailure("relaykit_state_not_verified", exitStatus: 6, candidateCount: matches.count)
        }
        Thread.sleep(forTimeInterval: selectorPollSeconds)
    }
}

private func executeRelayKitProviderConfigure(options: [String: String]) throws -> DriverReport {
    let provider = try validatedRelayKitProviderOptions(options, requireSyntheticKey: true)
    guard let syntheticKey = provider.syntheticKey else {
        throw DriverFailure("invalid_arguments", exitStatus: 2)
    }
    let context = try makeContext(options: options, command: .relayKitProviderConfigure)
    let buttonRoles = Set([kAXButtonRole as String])
    let popupRoles = Set([kAXPopUpButtonRole as String, kAXButtonRole as String])

    try performVerifiedPress(
        context: context,
        selector: relayKitIdentifierSelector("tab-connect", roles: buttonRoles, pressable: true)
    )
    try waitForUniqueSelector(
        context: context,
        selector: relayKitIdentifierSelector("provider-add-entry", roles: buttonRoles, pressable: true)
    )
    try performVerifiedPress(
        context: context,
        selector: relayKitIdentifierSelector("provider-add-entry", roles: buttonRoles, pressable: true)
    )

    try writeRelayKitField(context: context, identifier: "provider-provider-name-field", value: provider.name)
    try writeRelayKitField(context: context, identifier: "provider-api-base-url-field", value: provider.baseURL)
    try writeRelayKitField(
        context: context,
        identifier: "api-key-new-input-field",
        value: syntheticKey,
        verifyReadback: false
    )
    try writeRelayKitField(context: context, identifier: "provider-model-id-field", value: provider.modelID)

    let advancedSelector = relayKitIdentifierSelector(
        "provider-advanced-toggle-row",
        roles: buttonRoles,
        pressable: true
    )
    try performVerifiedPress(context: context, selector: advancedSelector)
    let protocolSelector = relayKitIdentifierSelector(
        "provider-upstream-protocol-selector",
        roles: popupRoles,
        pressable: true
    )
    try waitForUniqueSelector(context: context, selector: protocolSelector)
    try performVerifiedPress(context: context, selector: protocolSelector)

    let responsesOption = relayKitIdentifierSelector(
        "provider-upstream-protocol-option-openai_responses",
        roles: Set([kAXMenuItemRole as String]),
        pressable: true
    )
    try waitForUniqueApplicationOverlaySelector(context: context, selector: responsesOption)
    try performVerifiedPress(
        context: context,
        selector: responsesOption,
        targetProvider: { try applicationOverlayNode(context: $0, selector: responsesOption) }
    )
    try waitForRelayKitSemantic(
        context: context,
        identifier: "provider-upstream-protocol-selector",
        expected: "OpenAI Responses"
    )

    let saveSelector = relayKitIdentifierSelector("provider-form-save", roles: buttonRoles, pressable: true)
    try waitForUniqueSelector(context: context, selector: saveSelector)
    try performVerifiedPress(context: context, selector: saveSelector)
    try waitForUniqueSelector(
        context: context,
        selector: relayKitIdentifierSelector(
            "provider-\(relayKitProviderID(provider.name))",
            roles: buttonRoles,
            pressable: true
        )
    )
    return .success(
        command: "relaykit-provider-configure",
        windowVerified: true,
        candidateCount: 1,
        actionCount: 10
    )
}

private func executeRelayKitProviderVerify(options: [String: String]) throws -> DriverReport {
    let provider = try validatedRelayKitProviderOptions(options, requireSyntheticKey: false)
    let context = try makeContext(options: options, command: .relayKitProviderVerify)
    let buttonRoles = Set([kAXButtonRole as String])
    try performVerifiedPress(
        context: context,
        selector: relayKitIdentifierSelector("tab-connect", roles: buttonRoles, pressable: true)
    )
    let providerRow = relayKitIdentifierSelector(
        "provider-\(relayKitProviderID(provider.name))",
        roles: buttonRoles,
        pressable: true
    )
    try waitForUniqueSelector(context: context, selector: providerRow)
    try performVerifiedPress(context: context, selector: providerRow)

    try waitForRelayKitValue(
        context: context,
        identifier: "provider-provider-name-field",
        expected: provider.name
    )
    try waitForRelayKitValue(
        context: context,
        identifier: "provider-api-base-url-field",
        expected: provider.baseURL
    )
    try waitForRelayKitValue(
        context: context,
        identifier: "provider-model-id-field",
        expected: provider.modelID
    )
    try waitForRelayKitSemantic(
        context: context,
        identifier: "provider-upstream-protocol-selector",
        expected: "OpenAI Responses"
    )
    try waitForUniqueSelector(
        context: context,
        selector: relayKitIdentifierSelector("provider-saved-key-state")
    )
    return .success(
        command: "relaykit-provider-verify",
        windowVerified: true,
        candidateCount: 1,
        actionCount: 2
    )
}

private func executeRelayKitGatewayStart(options: [String: String]) throws -> DriverReport {
    let context = try makeContext(options: options, command: .relayKitGatewayStart)
    let buttonRoles = Set([kAXButtonRole as String])
    try performVerifiedPress(
        context: context,
        selector: relayKitIdentifierSelector("tab-settings", roles: buttonRoles, pressable: true)
    )
    let gatewayStart = relayKitIdentifierSelector("gateway-start", roles: buttonRoles, pressable: true)
    try waitForUniqueSelector(context: context, selector: gatewayStart)
    try performVerifiedPress(context: context, selector: gatewayStart)
    return .success(
        command: "relaykit-gateway-start",
        windowVerified: true,
        candidateCount: 1,
        actionCount: 2
    )
}

private func syntheticRecord(_ value: String) -> SemanticRecord {
    SemanticRecord(
        role: kAXPopUpButtonRole as String,
        semanticStrings: Set([value]),
        enabled: true,
        writable: false,
        pressable: true
    )
}

private func syntheticButton(_ value: String?) -> SemanticRecord {
    SemanticRecord(
        role: kAXButtonRole as String,
        semanticStrings: value.map { Set([$0]) } ?? [],
        enabled: true,
        writable: false,
        pressable: true
    )
}

private func syntheticHeading(_ value: String) -> SemanticRecord {
    SemanticRecord(
        role: kAXHeadingRole as String,
        semanticStrings: Set([value]),
        enabled: true,
        writable: false,
        pressable: false
    )
}

private func executeSelfTest(options: [String: String]) throws -> DriverReport {
    guard let scenario = options["--scenario"] else {
        throw DriverFailure("invalid_arguments", exitStatus: 2)
    }
    switch scenario {
    case "exact":
        let target = "Official GPT-5.5"
        let records = [syntheticRecord(target), syntheticRecord("Official GPT-5.5 Extended")]
        let selector: SemanticSelector = { $0.semanticStrings.contains(target) }
        let matches = matchingIndices(in: records, selector: selector)
        _ = try requireUniqueIndex(matches)
        return .success(command: "self-test", candidateCount: matches.count, actionCount: 0)
    case "zero":
        _ = try requireUniqueIndex([])
        throw DriverFailure("internal_error", exitStatus: 70)
    case "multiple":
        let target = "Official GPT-5.5"
        let records = [syntheticRecord(target), syntheticRecord(target)]
        let selector: SemanticSelector = { $0.semanticStrings.contains(target) }
        _ = try requireUniqueIndex(matchingIndices(in: records, selector: selector))
        throw DriverFailure("internal_error", exitStatus: 70)
    case "reveal-exact":
        let target = "RelayKit Rich Text Check"
        let records = [syntheticHeading(target), syntheticHeading("RelayKit Rich Text Check Extended"), syntheticButton(target)]
        let matches = matchingIndices(in: records, selector: markdownHeadingSelector(text: target))
        _ = try requireUniqueIndex(matches)
        return .success(command: "self-test", candidateCount: matches.count, actionCount: 0)
    case "reveal-multiple":
        let target = "RelayKit Rich Text Check"
        let records = [syntheticHeading(target), syntheticHeading(target)]
        let matches = matchingIndices(in: records, selector: markdownHeadingSelector(text: target))
        _ = try requireUniqueIndex(matches)
        throw DriverFailure("internal_error", exitStatus: 70)
    case "window-fallback":
        let index = try boundWindowIndex(
            windowNumbers: [nil],
            expectedWindowID: 42,
            windowServerWindowCount: 1
        )
        return .success(command: "self-test", candidateCount: index + 1, actionCount: 0)
    case "window-ambiguous":
        _ = try boundWindowIndex(
            windowNumbers: [nil, nil],
            expectedWindowID: 42,
            windowServerWindowCount: 1
        )
        throw DriverFailure("internal_error", exitStatus: 70)
    case "model-ui-labels":
        let labels = Set(["GPT-5.5", "GPT-5.6-Luna", "GPT-5.3-Codex-Spark", "Claude 4.5 Haiku"])
        guard codexModelMenuLabel(catalogLabel: "GPT-5.6-Luna") == "5.6 Luna",
              codexModelMenuLabel(catalogLabel: "GPT-5.3-Codex-Spark") == "5.3 Codex Spark",
              codexModelMenuLabel(catalogLabel: "Claude 4.5 Haiku") == "Claude 4.5 Haiku" else {
            throw DriverFailure("model_ui_label_projection_failed", exitStatus: 8)
        }
        let records = [syntheticRecord("5.5 中"), syntheticRecord("15.5 中")]
        let matches = matchingIndices(in: records, selector: modelPickerSelector(catalogLabels: labels))
        _ = try requireUniqueIndex(matches)
        let categoryRecords = [
            SemanticRecord(role: kAXMenuItemRole as String, semanticStrings: Set(["模型 5.5"]), enabled: true, writable: false, pressable: true),
            SemanticRecord(role: kAXMenuItemRole as String, semanticStrings: Set(["模型 15.5"]), enabled: true, writable: false, pressable: true),
        ]
        let categoryMatches = matchingIndices(in: categoryRecords, selector: modelCategorySelector(catalogLabels: labels))
        _ = try requireUniqueIndex(categoryMatches)
        return .success(command: "self-test", candidateCount: matches.count, actionCount: 0)
    case "send-structure":
        let records = [
            syntheticButton("添加文件等内容"),
            syntheticButton("完全访问"),
            syntheticButton("听写"),
            syntheticButton(nil),
        ]
        _ = try structuralSendButtonIndex(in: records)
        return .success(command: "self-test", candidateCount: 1, actionCount: 0)
    case "composer-value":
        guard try composerValue(query: "one\n") == "one",
              try composerValue(query: "one\r\n") == "one",
              try composerValue(query: "one\n\n") == "one\n",
              try composerValue(query: "one") == "one",
              composerReadbackMatches(actual: "one\ntwo", expected: "one\ntwo"),
              composerReadbackMatches(actual: "one two", expected: "one\ntwo"),
              !composerReadbackMatches(actual: "one  two", expected: "one\ntwo"),
              !composerReadbackMatches(actual: "one two", expected: "one  two") else {
            throw DriverFailure("composer_value_normalization_failed", exitStatus: 8)
        }
        return .success(command: "self-test", candidateCount: 1, actionCount: 0)
    case "empty-composer":
        guard composerIsEmpty(value: "", placeholder: "Do anything"),
              composerIsEmpty(value: "Do anything", placeholder: "Do anything"),
              composerIsEmpty(value: "\n随心输入", placeholder: nil),
              composerIsEmpty(value: "\nDo anything", placeholder: nil),
              !composerIsEmpty(value: nil, placeholder: "Do anything"),
              !composerIsEmpty(value: "\n随心输入 draft", placeholder: nil),
              !composerIsEmpty(value: "draft", placeholder: "Do anything") else {
            throw DriverFailure("empty_composer_detection_failed", exitStatus: 8)
        }
        return .success(command: "self-test", candidateCount: 1, actionCount: 0)
    case "query-permissions":
        guard let path = options["--query-file"] else {
            throw DriverFailure("invalid_arguments", exitStatus: 2)
        }
        try validateSecureFile(path, kind: .query)
        return .success(command: "self-test", actionCount: 0)
    case "catalog-exact":
        guard let path = options["--catalog-labels-file"],
              let modelLabel = options["--model-label"] else {
            throw DriverFailure("invalid_arguments", exitStatus: 2)
        }
        let labels = try readCatalogLabels(path)
        guard labels.contains(modelLabel) else {
            throw DriverFailure("model_label_not_in_catalog", exitStatus: 3)
        }
        let records = labels.sorted().map(syntheticRecord)
        let selector: SemanticSelector = { $0.semanticStrings.contains(modelLabel) }
        let matches = matchingIndices(in: records, selector: selector)
        _ = try requireUniqueIndex(matches)
        return .success(command: "self-test", candidateCount: matches.count, actionCount: 0)
    default:
        throw DriverFailure("invalid_arguments", exitStatus: 2)
    }
}

#if RELAYKIT_AX_DRIVER_TESTING
private struct BoundActionRootTestNode: Decodable {
    let id: Int
    let role: String?
    let childrenStatus: String?
    let children: [Int]

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case childrenStatus = "children_status"
        case children
    }
}

private struct BoundWindowTestInput: Decodable {
    let currentIdentity: WindowIdentity
    let processRunning: Bool
    let bundleIdentifier: String?
    let windows: [WindowServerMetadata]
    let frontmostPID: pid_t?
    let accessibilityTrusted: Bool
    let axWindowNumbers: [UInt32?]
    let axWindowsAvailable: Bool?
    let axWindowsMalformed: Bool?
    let axWindowNodeIDs: [Int]?
    let rootID: Int?
    let nodes: [BoundActionRootTestNode]?
    let expectedActionRootID: Int?
    let semanticTargetIDs: [Int]?
    let expectedSemanticTargetCount: Int?

    enum CodingKeys: String, CodingKey {
        case currentIdentity = "current_identity"
        case processRunning = "process_running"
        case bundleIdentifier = "bundle_identifier"
        case windows
        case frontmostPID = "frontmost_pid"
        case accessibilityTrusted = "accessibility_trusted"
        case axWindowNumbers = "ax_window_numbers"
        case axWindowsAvailable = "ax_windows_available"
        case axWindowsMalformed = "ax_windows_malformed"
        case axWindowNodeIDs = "ax_window_node_ids"
        case rootID = "root_id"
        case nodes
        case expectedActionRootID = "expected_action_root_id"
        case semanticTargetIDs = "semantic_target_ids"
        case expectedSemanticTargetCount = "expected_semantic_target_count"
    }
}

private struct AXDiagnosticTestNode: Decodable {
    let id: Int
    let role: String?
    let subrole: String?
    let windowNumber: UInt32?
    let children: [Int]

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case subrole
        case windowNumber = "window_number"
        case children
    }
}

private struct AXDiagnosticTestInput: Decodable {
    let currentIdentity: WindowIdentity
    let processRunning: Bool
    let bundleIdentifier: String?
    let windows: [WindowServerMetadata]
    let frontmostPID: pid_t?
    let accessibilityTrusted: Bool
    let axWindowsAvailable: Bool
    let axWindowsCount: Int
    let rootID: Int
    let nodes: [AXDiagnosticTestNode]

    enum CodingKeys: String, CodingKey {
        case currentIdentity = "current_identity"
        case processRunning = "process_running"
        case bundleIdentifier = "bundle_identifier"
        case windows
        case frontmostPID = "frontmost_pid"
        case accessibilityTrusted = "accessibility_trusted"
        case axWindowsAvailable = "ax_windows_available"
        case axWindowsCount = "ax_windows_count"
        case rootID = "root_id"
        case nodes
    }
}

private func executeBoundWindowTest(
    _ parsed: ParsedArguments,
    inputPath: String
) throws -> DriverReport {
    guard ProcessInfo.processInfo.environment["RELAYKIT_AX_DRIVER_SELF_TEST"] == "1",
          parsed.command != .selfTest,
          inputPath.hasPrefix("/") else {
        throw DriverFailure("invalid_arguments", exitStatus: 2)
    }
    let input: BoundWindowTestInput
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: inputPath))
        input = try JSONDecoder().decode(BoundWindowTestInput.self, from: data)
    } catch {
        throw DriverFailure("invalid_arguments", exitStatus: 2)
    }
    let context = try makeContext(options: parsed.options, command: parsed.command)
    let suppliedNodes = input.nodes ?? []
    let syntheticWindowNodes = input.axWindowNumbers.indices.map { index in
        BoundActionRootTestNode(
            id: 10_000 + index,
            role: "AXWindow",
            childrenStatus: nil,
            children: []
        )
    }
    let nodes = suppliedNodes.isEmpty ? syntheticWindowNodes : suppliedNodes
    let nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    let windowNodeIDs = input.axWindowNodeIDs ?? syntheticWindowNodes.map(\.id)
    guard nodesByID.count == nodes.count,
          windowNodeIDs.count == input.axWindowNumbers.count else {
        throw DriverFailure("invalid_arguments", exitStatus: 2)
    }
    let axWindowRoots = windowNodeIDs.compactMap { nodesByID[$0] }
    guard axWindowRoots.count == windowNodeIDs.count else {
        throw DriverFailure("invalid_arguments", exitStatus: 2)
    }
    let applicationRoot: BoundActionRootTestNode
    if let rootID = input.rootID {
        guard let root = nodesByID[rootID] else {
            throw DriverFailure("invalid_arguments", exitStatus: 2)
        }
        applicationRoot = root
    } else {
        applicationRoot = BoundActionRootTestNode(
            id: -1,
            role: "AXApplication",
            childrenStatus: nil,
            children: []
        )
    }
    let selection = try resolveBoundActionRoot(
        context: context,
        currentIdentity: input.currentIdentity,
        processIsRunning: input.processRunning,
        bundleIdentifier: input.bundleIdentifier,
        windowServerMetadata: { input.windows },
        frontmostPID: { input.frontmostPID },
        accessibilityTrusted: { input.accessibilityTrusted },
        axWindows: {
            (
                (input.axWindowsAvailable ?? true) && !(input.axWindowsMalformed ?? false),
                axWindowRoots
            )
        },
        axWindowNumber: { node in
            guard let index = windowNodeIDs.firstIndex(of: node.id) else { return nil }
            return input.axWindowNumbers[index]
        },
        relayKitPopoverRoot: {
            try uniqueRelayKitPopoverRoot(
                applicationRoot: applicationRoot,
                role: { $0.role },
                children: { node in
                    guard (node.childrenStatus ?? "success") == "success" else {
                        return nil
                    }
                    let children = node.children.compactMap { nodesByID[$0] }
                    return children.count == node.children.count ? children : nil
                },
                identical: { $0.id == $1.id }
            )
        }
    )
    if let expectedActionRootID = input.expectedActionRootID,
       selection.root.id != expectedActionRootID {
        throw DriverFailure("internal_error", exitStatus: 70)
    }
    if let semanticTargetIDs = input.semanticTargetIDs,
       let expectedSemanticTargetCount = input.expectedSemanticTargetCount {
        var pending = [selection.root]
        var visited = Set<Int>()
        var targetCount = 0
        while let node = pending.popLast() {
            guard visited.insert(node.id).inserted else { continue }
            if semanticTargetIDs.contains(node.id) {
                targetCount += 1
            }
            pending.append(contentsOf: node.children.compactMap { nodesByID[$0] })
        }
        guard targetCount == expectedSemanticTargetCount else {
            throw DriverFailure("internal_error", exitStatus: 70)
        }
    }
    return .success(
        command: parsed.command.rawValue,
        windowVerified: true,
        candidateCount: selection.candidateCount,
        actionCount: 0
    )
}

private func executeAXDiagnosticTest(
    _ parsed: ParsedArguments,
    inputPath: String
) throws -> DriverReport {
    guard ProcessInfo.processInfo.environment["RELAYKIT_AX_DRIVER_SELF_TEST"] == "1",
          ProcessInfo.processInfo.environment["RELAYKIT_AX_DRIVER_DIAGNOSTIC"] == "1",
          parsed.command == .relayKitAXInspect,
          inputPath.hasPrefix("/"),
          let outputPath = parsed.options["--diagnostic-output"] else {
        throw DriverFailure("invalid_arguments", exitStatus: 2)
    }
    let input: AXDiagnosticTestInput
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: inputPath))
        input = try JSONDecoder().decode(AXDiagnosticTestInput.self, from: data)
    } catch {
        throw DriverFailure("invalid_arguments", exitStatus: 2)
    }
    let context = try makeContext(options: parsed.options, command: parsed.command)
    _ = try verifyApplicationIdentity(
        context: context,
        currentIdentity: input.currentIdentity,
        processIsRunning: input.processRunning,
        bundleIdentifier: input.bundleIdentifier,
        windowServerMetadata: { input.windows },
        frontmostPID: { input.frontmostPID },
        accessibilityTrusted: { input.accessibilityTrusted },
        requireFrontmost: true
    )

    let nodesByID = Dictionary(uniqueKeysWithValues: input.nodes.map { ($0.id, $0) })
    guard nodesByID.count == input.nodes.count,
          let root = nodesByID[input.rootID] else {
        throw DriverFailure("invalid_arguments", exitStatus: 2)
    }
    let report = makeAXDiagnosticReport(
        root: root,
        expectedWindowID: context.identity.windowID,
        axWindowsAvailable: input.axWindowsAvailable,
        axWindowsCount: input.axWindowsCount,
        role: { $0.role },
        subrole: { $0.subrole },
        children: { node in node.children.compactMap { nodesByID[$0] } },
        windowNumber: { $0.windowNumber },
        identical: { $0.id == $1.id }
    )
    try writeAtomicPrivateJSON(report, to: outputPath)
    return .success(
        command: parsed.command.rawValue,
        windowVerified: true,
        actionCount: 0
    )
}
#endif

private func execute(_ parsed: ParsedArguments) throws -> DriverReport {
#if RELAYKIT_AX_DRIVER_TESTING
    if let inputPath = ProcessInfo.processInfo.environment["RELAYKIT_AX_DRIVER_DIAGNOSTIC_TEST_INPUT"] {
        return try executeAXDiagnosticTest(parsed, inputPath: inputPath)
    }
    if let inputPath = ProcessInfo.processInfo.environment["RELAYKIT_AX_DRIVER_BOUND_WINDOW_TEST_INPUT"] {
        return try executeBoundWindowTest(parsed, inputPath: inputPath)
    }
#endif
    switch parsed.command {
    case .inspect:
        return try executeInspect(options: parsed.options)
    case .reveal:
        return try executeReveal(options: parsed.options)
    case .ready:
        return try executeReady(options: parsed.options)
    case .prepare:
        return try executePrepare(options: parsed.options)
    case .submit:
        return try executeSubmit(options: parsed.options)
    case .relayKitProviderConfigure:
        return try executeRelayKitProviderConfigure(options: parsed.options)
    case .relayKitProviderVerify:
        return try executeRelayKitProviderVerify(options: parsed.options)
    case .relayKitGatewayStart:
        return try executeRelayKitGatewayStart(options: parsed.options)
    case .relayKitAXInspect:
        return try executeRelayKitAXInspect(options: parsed.options)
    case .selfTest:
        return try executeSelfTest(options: parsed.options)
    }
}

let rawArguments = Array(CommandLine.arguments.dropFirst())
let commandName = redactedCommandName(rawArguments)
do {
    let parsed = try parseArguments(rawArguments)
    emit(try execute(parsed))
    exit(0)
} catch let failure as DriverFailure {
    emit(.failure(command: commandName, failure: failure))
    exit(failure.exitStatus)
} catch {
    let failure = DriverFailure("internal_error", exitStatus: 70)
    emit(.failure(command: commandName, failure: failure))
    exit(failure.exitStatus)
}
