import Foundation

public enum RelayKitPaths {
    public static func gatewayBinaryPath(bundle: Bundle = .main) -> String {
        let bundled = bundle.bundleURL
            .appendingPathComponent("Contents/MacOS/relay")
            .path
        if FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        return "../gateway/bin/relay"
    }
}
