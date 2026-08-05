import Darwin
import Foundation
import RelayKitCore

@MainActor
final class GatewayProcess {
    private var process: Process?
    private var adoptedBackgroundGateway = false
    private var controlBinaryPath = ""
    private var controlTokenPath = ""
    private var controlParentProcessIdentifier: Int32?
    private var controlOwnerLease: FileHandle?
    private var controlOwnerLeasePath = ""
    private(set) var usesManagedService = false
    private(set) var expectedServiceMode = "managed"
    private let endpoint: RelayKitRuntimeEndpoint
    var onUnexpectedTermination: (() -> Void)?

    init(endpoint: RelayKitRuntimeEndpoint) {
        self.endpoint = endpoint
    }

    var isRunning: Bool {
        process?.isRunning == true || adoptedBackgroundGateway
    }

    var processIdentifier: Int32? {
        guard let process, process.isRunning else {
            return nil
        }
        return process.processIdentifier
    }

    func holdControlOwnerLease(at path: String) throws {
        if controlOwnerLease != nil {
            guard controlOwnerLeasePath == path else {
                throw GatewayProcessError.commandFailed("gateway control owner lease path changed")
            }
            return
        }
        let deadline = Date().addingTimeInterval(2)
        var descriptor: Int32 = -1
        repeat {
            descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK | O_NONBLOCK)
            if descriptor >= 0 {
                break
            }
            guard (errno == EWOULDBLOCK || errno == EAGAIN), Date() < deadline else {
                throw GatewayProcessError.commandFailed("gateway control owner lease is unavailable")
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while true
        guard descriptor >= 0 else {
            throw GatewayProcessError.commandFailed("gateway control owner lease is unavailable")
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & 0o777) == 0o600,
              info.st_uid == getuid(),
              info.st_nlink == 1 else {
            Darwin.close(descriptor)
            throw GatewayProcessError.commandFailed("gateway control owner lease is invalid")
        }

        controlOwnerLease = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        controlOwnerLeasePath = path
    }

    func start(
        binaryPath: String,
        configPath: String,
        usageLogPath: String? = nil,
        credentialHandoff: Data,
        controlTokenPath: String = "",
        runtimeConfigSHA256: String = "",
        launchdManaged: Bool = false,
        managedRouteEnabled: Bool = true,
        parentProcessIdentifier: Int32? = nil,
        managedCodexTarget: String? = nil,
        managedCodexState: String? = nil
    ) throws {
        guard (managedCodexTarget == nil) == (managedCodexState == nil),
              managedCodexTarget?.isEmpty != true,
              managedCodexState?.isEmpty != true else {
            throw GatewayProcessError.commandFailed("managed Codex target and state must be passed together")
        }
        let directProcessRunning = process?.isRunning == true
        let previouslyAdopted = adoptedBackgroundGateway
        if (directProcessRunning || previouslyAdopted),
           let parentProcessIdentifier,
           parentProcessIdentifier > 0 {
            try adoptRunningGateway(
                binaryPath: binaryPath,
                credentialHandoff: credentialHandoff,
                controlTokenPath: controlTokenPath,
                runtimeConfigSHA256: runtimeConfigSHA256,
                parentProcessIdentifier: parentProcessIdentifier,
                managedRouteEnabled: managedRouteEnabled,
                launchdManaged: launchdManaged && previouslyAdopted,
                attempts: launchdManaged ? 20 : 1
            )
            adoptedBackgroundGateway = previouslyAdopted
            controlBinaryPath = binaryPath
            self.controlTokenPath = controlTokenPath
            controlParentProcessIdentifier = parentProcessIdentifier
            usesManagedService = launchdManaged && previouslyAdopted
            expectedServiceMode = managedRouteEnabled ? "managed" : "official_fallback"
            return
        }
        if directProcessRunning || previouslyAdopted {
            return
        }
        if launchdManaged,
           let parentProcessIdentifier,
           parentProcessIdentifier > 0 {
            do {
                try adoptRunningGateway(
                    binaryPath: binaryPath,
                    credentialHandoff: credentialHandoff,
                    controlTokenPath: controlTokenPath,
                    runtimeConfigSHA256: runtimeConfigSHA256,
                    parentProcessIdentifier: parentProcessIdentifier,
                    managedRouteEnabled: managedRouteEnabled,
                    launchdManaged: launchdManaged,
                    attempts: launchdManaged ? 20 : 1
                )
                adoptedBackgroundGateway = true
                controlBinaryPath = binaryPath
                self.controlTokenPath = controlTokenPath
                controlParentProcessIdentifier = parentProcessIdentifier
                usesManagedService = launchdManaged
                expectedServiceMode = managedRouteEnabled ? "managed" : "official_fallback"
                return
            } catch {
                adoptedBackgroundGateway = false
                usesManagedService = false
                throw error
            }
        }
        if launchdManaged {
            adoptedBackgroundGateway = false
            usesManagedService = false
            throw GatewayProcessError.commandFailed("RelayKit background gateway did not become available.")
        }
        let process = makeStartProcess(
            binaryPath: binaryPath,
            configPath: configPath,
            usageLogPath: usageLogPath,
            parentProcessIdentifier: parentProcessIdentifier,
            managedCodexTarget: managedCodexTarget,
            managedCodexState: managedCodexState,
            controlTokenPath: controlTokenPath,
            managedRouteEnabled: managedRouteEnabled
        )
        let terminationRelay = GatewayTerminationRelay { [weak self] processIdentifier in
            self?.handleTermination(processIdentifier: processIdentifier)
        }
        process.terminationHandler = { [terminationRelay] terminated in
            terminationRelay.receive(processIdentifier: terminated.processIdentifier)
        }
        let credentialPipe = Pipe()
        process.standardInput = credentialPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            try credentialPipe.fileHandleForWriting.write(contentsOf: credentialHandoff)
            try credentialPipe.fileHandleForWriting.close()
        } catch {
            try? credentialPipe.fileHandleForWriting.close()
            terminateAndReap(process)
            throw GatewayProcessError.commandFailed("gateway credential handoff failed")
        }
        Thread.sleep(forTimeInterval: 0.2)
        if !process.isRunning {
            throw GatewayProcessError.commandFailed("gateway exited during startup")
        }
        self.process = process
        adoptedBackgroundGateway = false
        controlBinaryPath = binaryPath
        self.controlTokenPath = controlTokenPath
        controlParentProcessIdentifier = parentProcessIdentifier
        usesManagedService = false
        expectedServiceMode = managedRouteEnabled ? "managed" : "official_fallback"
    }

    func makeStartProcess(
        binaryPath: String,
        configPath: String,
        usageLogPath: String? = nil,
        parentProcessIdentifier: Int32? = nil,
        managedCodexTarget: String? = nil,
        managedCodexState: String? = nil,
        controlTokenPath: String? = nil,
        managedRouteEnabled: Bool = true
    ) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath, relativeTo: Self.appDirectory()).standardized
        process.arguments = ["-listen", endpoint.listenAddress, "-config", configPath, "-credential-stdin"]
        if let usageLogPath, !usageLogPath.isEmpty {
            process.arguments?.append(contentsOf: ["-usage-log", usageLogPath])
        }
        if let parentProcessIdentifier, parentProcessIdentifier > 0 {
            process.arguments?.append(contentsOf: ["-parent-pid", "\(parentProcessIdentifier)"])
        }
        if let managedCodexTarget, let managedCodexState {
            process.arguments?.append(contentsOf: ["-managed-codex-target", managedCodexTarget, "-managed-codex-state", managedCodexState])
        }
        if let controlTokenPath, !controlTokenPath.isEmpty {
            process.arguments?.append(contentsOf: ["-control-token-file", controlTokenPath])
        }
        process.arguments?.append("-route-enabled=\(managedRouteEnabled ? "true" : "false")")
        return process
    }

    func stop() {
        if adoptedBackgroundGateway {
            requestAdoptedGatewayShutdown()
            adoptedBackgroundGateway = false
            usesManagedService = false
            clearControlState()
            return
        }
        guard let process, process.isRunning else {
            self.process = nil
            clearControlState()
            return
        }
        process.terminationHandler = nil
        terminateAndReap(process)
        self.process = nil
        clearControlState()
    }

    func restartDataPlane() throws {
        if adoptedBackgroundGateway {
            try requestAdoptedGatewayShutdownOrThrow()
            adoptedBackgroundGateway = false
            usesManagedService = false
            clearControlState()
            Thread.sleep(forTimeInterval: 0.25)
            return
        }
        guard let process, process.isRunning else {
            self.process = nil
            clearControlState()
            return
        }
        process.terminationHandler = nil
        terminateAndReap(process)
        self.process = nil
        clearControlState()
    }

    func leaveRunningForFallback() throws {
        if adoptedBackgroundGateway {
            if !usesManagedService {
                try requestAdoptedGatewayShutdownOrThrow()
                adoptedBackgroundGateway = false
                clearControlState()
                return
            }
            try requestAdoptedGatewayRelease()
            adoptedBackgroundGateway = false
            usesManagedService = false
            clearControlState()
            return
        }
        guard let process, process.isRunning else {
            self.process = nil
            clearControlState()
            return
        }
        if !usesManagedService {
            process.terminationHandler = nil
            terminateAndReap(process)
            self.process = nil
            clearControlState()
            return
        }
        try requestAdoptedGatewayRelease()
        process.terminationHandler = nil
        self.process = nil
        clearControlState()
    }

    func enableCodexConfig(binaryPath: String, target: String, catalog: String, state: String) throws -> String {
        try Self.runGatewayCommand(
            binaryPath: binaryPath,
            arguments: ["enable-codex-config", "-target", target, "-catalog", catalog, "-state", state, "-base-url", endpoint.codexBaseURL.absoluteString]
        )
    }

    func disableCodexConfig(binaryPath: String, target: String, state: String) throws -> String {
        try Self.runGatewayCommand(
            binaryPath: binaryPath,
            arguments: ["disable-codex-config", "-target", target, "-state", state]
        )
    }

    func codexConfigStatus(binaryPath: String, target: String, state: String) throws -> String {
        try Self.runGatewayCommand(
            binaryPath: binaryPath,
            arguments: ["codex-config-status", "-target", target, "-state", state]
        )
    }

    nonisolated static func summarizeUsage(binaryPath: String, usageLogPath: String) throws -> String {
        try runGatewayCommand(binaryPath: binaryPath, arguments: ["summarize-usage", "-path", usageLogPath])
    }

    private nonisolated static func runGatewayCommand(binaryPath: String, arguments: [String], standardInput: Data? = nil) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: binaryPath, relativeTo: appDirectory()).standardized
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        let input = standardInput.map { _ in Pipe() }
        process.standardInput = input
        try process.run()
        if let standardInput, let input {
            try input.fileHandleForWriting.write(contentsOf: standardInput)
            try input.fileHandleForWriting.close()
        }
        process.waitUntilExit()

        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw GatewayProcessError.commandFailed(stderr.isEmpty ? stdout : stderr)
        }
        return stdout
    }

    private func requestAdoptedGatewayShutdown() {
        try? requestAdoptedGatewayShutdownOrThrow()
    }

    private func requestAdoptedGatewayShutdownOrThrow() throws {
        guard !controlBinaryPath.isEmpty,
              !controlTokenPath.isEmpty,
              let parent = controlParentProcessIdentifier,
              parent > 0 else {
            throw GatewayProcessError.commandFailed("gateway shutdown control is unavailable")
        }
        _ = try Self.runGatewayCommand(
            binaryPath: controlBinaryPath,
            arguments: [
                "gateway-control",
                "-endpoint", endpoint.httpBaseURL.absoluteString,
                "-token-file", controlTokenPath,
                "-action", "shutdown",
                "-parent-pid", "\(parent)",
            ]
        )
    }

    private func requestAdoptedGatewayRelease() throws {
        guard !controlBinaryPath.isEmpty,
              !controlTokenPath.isEmpty,
              let parent = controlParentProcessIdentifier,
              parent > 0 else {
            throw GatewayProcessError.commandFailed("gateway fallback control is unavailable")
        }
        _ = try Self.runGatewayCommand(
            binaryPath: controlBinaryPath,
            arguments: [
                "gateway-control",
                "-endpoint", endpoint.httpBaseURL.absoluteString,
                "-token-file", controlTokenPath,
                "-action", "release",
                "-parent-pid", "\(parent)",
            ]
        )
    }

    private struct GatewayControlStatus {
        let mode: String
        let runtimeConfigSHA256: String
    }

    private func requestGatewayControlStatus(
        binaryPath: String,
        controlTokenPath: String,
        runtimeConfigSHA256: String? = nil
    ) throws -> GatewayControlStatus {
        var arguments = [
            "gateway-control",
            "-endpoint", endpoint.httpBaseURL.absoluteString,
            "-token-file", controlTokenPath,
            "-action", "status",
        ]
        if let runtimeConfigSHA256, !runtimeConfigSHA256.isEmpty {
            arguments.append(contentsOf: ["-runtime-config-sha256", runtimeConfigSHA256])
        }
        let output = try Self.runGatewayCommand(binaryPath: binaryPath, arguments: arguments)
        let tokens = output
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" })
            .map(String.init)
        guard let statusTokenIndex = tokens.firstIndex(where: { $0.hasPrefix("status:") }),
              statusTokenIndex + 1 < tokens.count else {
            throw GatewayProcessError.commandFailed("gateway control status is invalid")
        }
        let mode = tokens[statusTokenIndex].dropFirst("status:".count).isEmpty
            ? tokens[statusTokenIndex + 1]
            : String(tokens[statusTokenIndex].dropFirst("status:".count))
        guard !mode.isEmpty,
              let digestToken = tokens.first(where: { $0.hasPrefix("runtime_config_sha256=") }) else {
            throw GatewayProcessError.commandFailed("gateway control status digest is unavailable")
        }
        let digest = String(digestToken.dropFirst("runtime_config_sha256=".count))
        guard digest.count == 64,
              digest.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (97...102).contains($0.value)
              }) else {
            throw GatewayProcessError.commandFailed("gateway control status digest is invalid")
        }
        return GatewayControlStatus(mode: mode, runtimeConfigSHA256: digest)
    }

    private func requestAdoptedGatewayReplacement(
        binaryPath: String,
        controlTokenPath: String,
        parentProcessIdentifier: Int32,
        runtimeConfigSHA256: String
    ) throws {
        _ = try Self.runGatewayCommand(
            binaryPath: binaryPath,
            arguments: [
                "gateway-control",
                "-endpoint", endpoint.httpBaseURL.absoluteString,
                "-token-file", controlTokenPath,
                "-action", "replace",
                "-parent-pid", "\(parentProcessIdentifier)",
                "-runtime-config-sha256", runtimeConfigSHA256,
            ]
        )
    }

    private func adoptRunningGateway(
        binaryPath: String,
        credentialHandoff: Data,
        controlTokenPath: String,
        runtimeConfigSHA256: String,
        parentProcessIdentifier: Int32,
        managedRouteEnabled: Bool,
        launchdManaged: Bool,
        attempts: Int
    ) throws {
        var replacementRequested = false
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                let status = try requestGatewayControlStatus(
                    binaryPath: binaryPath,
                    controlTokenPath: controlTokenPath,
                    runtimeConfigSHA256: runtimeConfigSHA256
                )
                if status.runtimeConfigSHA256 != runtimeConfigSHA256 {
                    guard launchdManaged,
                          status.mode == "official_fallback" else {
                        throw GatewayProcessError.commandFailed(
                            "gateway runtime configuration is stale and cannot be adopted: the helper is owned or not background-managed"
                        )
                    }
                    if replacementRequested {
                        if attempt + 1 < attempts {
                            Thread.sleep(forTimeInterval: 0.25)
                            continue
                        }
                        throw GatewayProcessError.commandFailed(
                            "gateway runtime configuration is stale and cannot be adopted: the replacement did not load the requested bytes"
                        )
                    }
                    replacementRequested = true
                    do {
                        try requestAdoptedGatewayReplacement(
                            binaryPath: binaryPath,
                            controlTokenPath: controlTokenPath,
                            parentProcessIdentifier: parentProcessIdentifier,
                            runtimeConfigSHA256: runtimeConfigSHA256
                        )
                    } catch {
                        throw GatewayProcessError.commandFailed(
                            "RelayKit could not replace the stale background gateway: \(error.localizedDescription)"
                        )
                    }
                    Thread.sleep(forTimeInterval: 0.25)
                    continue
                }
                _ = try Self.runGatewayCommand(
                    binaryPath: binaryPath,
                    arguments: [
                        "gateway-control",
                        "-endpoint", endpoint.httpBaseURL.absoluteString,
                        "-token-file", controlTokenPath,
                        "-action", "adopt",
                        "-parent-pid", "\(parentProcessIdentifier)",
                        "-route-enabled=\(managedRouteEnabled ? "true" : "false")",
                        "-runtime-config-sha256", runtimeConfigSHA256,
                    ],
                    standardInput: credentialHandoff
                )
                return
            } catch {
                lastError = error
                if let gatewayError = error as? GatewayProcessError,
                   gatewayError.errorDescription?.contains("stale and cannot be adopted") == true ||
                   gatewayError.errorDescription?.contains("could not replace the stale background gateway") == true {
                    throw gatewayError
                }
            }
            if attempt + 1 < attempts {
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        let detail = lastError?.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines) ?? "gateway control endpoint is unavailable"
        throw GatewayProcessError.commandFailed("RelayKit gateway could not adopt the managed helper: \(detail)")
    }

    private func clearControlState() {
        controlBinaryPath = ""
        controlTokenPath = ""
        controlParentProcessIdentifier = nil
        usesManagedService = false
    }

    private nonisolated static func appDirectory() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    private func terminateAndReap(_ process: Process, timeout: TimeInterval = 2) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            let forcedDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < forcedDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    private func handleTermination(processIdentifier: Int32) {
        guard process?.processIdentifier == processIdentifier else { return }
        process = nil
        onUnexpectedTermination?()
    }
}

private final class GatewayTerminationRelay: @unchecked Sendable {
    private let deliver: @MainActor @Sendable (Int32) -> Void

    init(deliver: @escaping @MainActor @Sendable (Int32) -> Void) {
        self.deliver = deliver
    }

    func receive(processIdentifier: Int32) {
        Task { @MainActor [deliver] in
            deliver(processIdentifier)
        }
    }
}

enum GatewayProcessError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return message.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
