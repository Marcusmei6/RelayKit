import Foundation

final class GatewayProcess {
    private var process: Process?

    var isRunning: Bool {
        process?.isRunning == true
    }

    func start(binaryPath: String, configPath: String) throws {
        if isRunning {
            return
        }
        let process = makeStartProcess(binaryPath: binaryPath, configPath: configPath)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        self.process = process
    }

    func makeStartProcess(binaryPath: String, configPath: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath, relativeTo: appDirectory()).standardized
        process.arguments = ["-listen", "127.0.0.1:19777", "-config", configPath]
        return process
    }

    func stop() {
        guard let process, process.isRunning else {
            self.process = nil
            return
        }
        process.terminate()
        self.process = nil
    }

    func activateCodexConfig(binaryPath: String, source: String, target: String) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: binaryPath, relativeTo: appDirectory()).standardized
        process.arguments = ["activate-codex-config", "-source", source, "-target", target]
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

    private func gatewayDirectory() -> URL {
        URL(fileURLWithPath: "../gateway", relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardized
    }

    private func appDirectory() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
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
