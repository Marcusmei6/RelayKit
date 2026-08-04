import Foundation

public struct RelayKitRuntimeEndpoint: Equatable, Sendable {
    public static let productPort = 19777
    public static let host = "127.0.0.1"

    public let port: Int

    public static let product = RelayKitRuntimeEndpoint(port: productPort)

    public static func isProtectedPort(_ port: Int) -> Bool {
        port == 18787 || port == productPort
    }

    public var listenAddress: String {
        "\(Self.host):\(port)"
    }

    public var httpBaseURL: URL {
        URL(string: "http://\(listenAddress)")!
    }

    public var codexBaseURL: URL {
        httpBaseURL.appending(path: "v1")
    }

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> RelayKitRuntimeEndpoint {
        guard environment["RELAYKIT_RUNTIME_SAFETY_TEST"] == "1" else {
            return product
        }
        guard let rawPort = environment["RELAYKIT_RUNTIME_SAFETY_PORT"],
              rawPort.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
              let port = Int(rawPort),
              (1024...65535).contains(port),
              !isProtectedPort(port) else {
            throw RelayKitRuntimeEndpointError.invalidTestEndpoint
        }
        return RelayKitRuntimeEndpoint(port: port)
    }
}

enum RelayKitRuntimeEndpointError: LocalizedError {
    case invalidTestEndpoint

    var errorDescription: String? {
        switch self {
        case .invalidTestEndpoint:
            "RelayKit runtime safety test endpoint is invalid."
        }
    }
}
