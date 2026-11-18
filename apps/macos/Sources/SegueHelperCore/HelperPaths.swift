import Foundation

/// Paths the daemon uses when it is not given flags. Tests and a dev run
/// pass their own; nothing here creates the directories.
public struct HelperPaths: Equatable, Sendable {
    public var socketPath: String
    public var intentPath: String
    public var kernelPath: String
    public var configPath: String
    public var stateDir: String
    public var allowedUIDFile: String

    public init(
        socketPath: String,
        intentPath: String,
        kernelPath: String,
        configPath: String,
        stateDir: String,
        allowedUIDFile: String
    ) {
        self.socketPath = socketPath
        self.intentPath = intentPath
        self.kernelPath = kernelPath
        self.configPath = configPath
        self.stateDir = stateDir
        self.allowedUIDFile = allowedUIDFile
    }

    public static let production = HelperPaths(
        socketPath: "/var/run/segue/service.sock",
        intentPath: "/Library/Application Support/Segue/ai-lock.intent",
        kernelPath: "/Library/PrivilegedHelperTools/segue-kernel",
        configPath: "/Library/Application Support/Segue/kernel.json",
        stateDir: "/Library/Application Support/Segue/kernel",
        allowedUIDFile: "/Library/PrivilegedHelperTools/segue.allowed-uid"
    )

    /// `arguments` includes argv0. Unknown tokens are skipped.
    public static func parse(
        _ arguments: [String],
        defaults: HelperPaths = .production
    ) -> HelperPaths {
        var paths = defaults
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            let next = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch flag {
            case "--socket":
                if let next { paths.socketPath = next; index += 1 }
            case "--intent":
                if let next { paths.intentPath = next; index += 1 }
            case "--kernel":
                if let next { paths.kernelPath = next; index += 1 }
            case "--config":
                if let next { paths.configPath = next; index += 1 }
            case "--state-dir":
                if let next { paths.stateDir = next; index += 1 }
            case "--allowed-uids":
                if let next { paths.allowedUIDFile = next; index += 1 }
            default:
                break
            }
            index += 1
        }
        return paths
    }
}
