import Darwin
import Foundation

final class GatewayProcess {
    private var process: Process?

    var isRunning: Bool {
        process?.isRunning == true
    }

    var processIdentifier: Int32? {
        guard let process, process.isRunning else {
            return nil
        }
        return process.processIdentifier
    }

    func start(
        binaryPath: String,
        configPath: String,
        usageLogPath: String? = nil,
        credentialHandoff: Data,
        parentProcessIdentifier: Int32? = nil
    ) throws {
        if isRunning {
            return
        }
        let process = makeStartProcess(
            binaryPath: binaryPath,
            configPath: configPath,
            usageLogPath: usageLogPath,
            parentProcessIdentifier: parentProcessIdentifier
        )
        let credentialPipe = Pipe()
        process.standardInput = credentialPipe
        process.standardOutput = Pipe()
        let errors = Pipe()
        process.standardError = errors
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
            let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw GatewayProcessError.commandFailed(stderr.isEmpty ? "gateway exited during startup" : stderr)
        }
        self.process = process
    }

    func makeStartProcess(
        binaryPath: String,
        configPath: String,
        usageLogPath: String? = nil,
        parentProcessIdentifier: Int32? = nil
    ) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath, relativeTo: appDirectory()).standardized
        process.arguments = ["-listen", "127.0.0.1:19777", "-config", configPath, "-credential-stdin"]
        if let usageLogPath, !usageLogPath.isEmpty {
            process.arguments?.append(contentsOf: ["-usage-log", usageLogPath])
        }
        if let parentProcessIdentifier, parentProcessIdentifier > 0 {
            process.arguments?.append(contentsOf: ["-parent-pid", "\(parentProcessIdentifier)"])
        }
        return process
    }

    func stop() {
        guard let process, process.isRunning else {
            self.process = nil
            return
        }
        terminateAndReap(process)
        self.process = nil
    }

    func activateCodexConfig(binaryPath: String, source: String, target: String) throws -> String {
        try runGatewayCommand(binaryPath: binaryPath, arguments: ["activate-codex-config", "-source", source, "-target", target])
    }

    func summarizeUsage(binaryPath: String, usageLogPath: String) throws -> String {
        try runGatewayCommand(binaryPath: binaryPath, arguments: ["summarize-usage", "-path", usageLogPath])
    }

    private func runGatewayCommand(binaryPath: String, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: binaryPath, relativeTo: appDirectory()).standardized
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()

        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw GatewayProcessError.commandFailed(stderr.isEmpty ? stdout : stderr)
        }
        return stdout
    }

    private func appDirectory() -> URL {
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
