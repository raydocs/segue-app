import Foundation
import SegueAILayer
import SegueHelperCore

/// Paths the release daemon uses when it is not given flags. The intent, the
/// snapshot, and the allowed-uid file are the helper's own files: the release
/// daemon clears what the helper wrote, so it reads the same locations and
/// never invents its own. Nothing here creates the directories.
public struct ReleasePaths: Equatable, Sendable {
    public var socketPath: String
    public var intentPath: String
    public var snapshotPath: String
    public var resolverDirectory: String
    public var allowedUIDFile: String
    /// Empty means the production Developer ID requirement. A non-empty value
    /// is the requirement text the daemon evaluates instead — the throwaway
    /// VM matrix passes an `identifier` requirement for its ad-hoc ctl.
    /// Production launchd plists omit the flag.
    public var requirement: String

    public init(
        socketPath: String,
        intentPath: String,
        snapshotPath: String,
        resolverDirectory: String,
        allowedUIDFile: String,
        requirement: String = ""
    ) {
        self.socketPath = socketPath
        self.intentPath = intentPath
        self.snapshotPath = snapshotPath
        self.resolverDirectory = resolverDirectory
        self.allowedUIDFile = allowedUIDFile
        self.requirement = requirement
    }

    public static let production = ReleasePaths(
        socketPath: "/var/run/segue-release.sock",
        intentPath: HelperPaths.production.intentPath,
        snapshotPath: URL(fileURLWithPath: HelperPaths.production.intentPath)
            .deletingLastPathComponent()
            .appendingPathComponent("dns-snapshot.json")
            .path,
        resolverDirectory: ResolverFiles.resolverDirectory,
        allowedUIDFile: HelperPaths.production.allowedUIDFile
    )

    /// `arguments` includes argv0. Unknown tokens are skipped.
    public static func parse(
        _ arguments: [String],
        defaults: ReleasePaths = .production
    ) -> ReleasePaths {
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
            case "--snapshot":
                if let next { paths.snapshotPath = next; index += 1 }
            case "--resolver-dir":
                if let next { paths.resolverDirectory = next; index += 1 }
            case "--allowed-uids":
                if let next { paths.allowedUIDFile = next; index += 1 }
            case "--requirement":
                if let next { paths.requirement = next; index += 1 }
            default:
                break
            }
            index += 1
        }
        return paths
    }
}
