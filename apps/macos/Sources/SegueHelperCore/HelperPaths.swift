import Foundation

/// Paths the daemon uses when it is not given flags. Tests and a dev run
/// pass their own; nothing here creates the directories.
public struct HelperPaths: Equatable, Sendable {
    public var socketPath: String
    public var intentPath: String
    public var kernelPath: String
    public var configPath: String
    public var stateDir: String
    /// The kernel's own log (`--log`), under the helper's directory.
    public var kernelLogPath: String
    /// Where the kernel writes `{"addr": "...", "token": "..."}` for its
    /// control API: `control.token_file` from the config, resolved into
    /// the state dir when it is relative.
    public var controlTokenPath: String
    public var allowedUIDFile: String
    /// Built-in AI lock list (`suffix` / `cidr` lines). Reread on every arm.
    /// A missing file or a parse error while armed is `ai_list_error`, not
    /// an empty list.
    public var aiLockPath: String
    /// Loopback DNS guard. Production is 5354; a dev run passes a port above 1024.
    public var guardPort: UInt16
    /// `/etc/pf.conf` in production. A dev run points this at a temp file so
    /// the helper can arm without root.
    public var pfConfPath: String
    /// `/etc/resolver` in production. A dev run points this at a temp directory.
    public var resolverDirectory: String
    /// `pfctl` binary. Production is `/sbin/pfctl`. `--pfctl` points a dev run
    /// at a recording stand-in so the anchor text can be checked without root.
    public var pfctlPath: String
    /// Empty means the production Developer ID requirement. A non-empty value
    /// is what the daemon evaluates instead (the same escape the release
    /// daemon has) so an unsigned dev build can answer `status_read`.
    public var requirement: String

    public init(
        socketPath: String,
        intentPath: String,
        kernelPath: String,
        configPath: String,
        stateDir: String,
        kernelLogPath: String = "/Library/Application Support/Segue/kernel.log",
        controlTokenPath: String = "/Library/Application Support/Segue/kernel/control.json",
        allowedUIDFile: String,
        aiLockPath: String,
        guardPort: UInt16 = 5354,
        pfConfPath: String = "/etc/pf.conf",
        resolverDirectory: String = "/etc/resolver",
        pfctlPath: String = "/sbin/pfctl",
        requirement: String = ""
    ) {
        self.socketPath = socketPath
        self.intentPath = intentPath
        self.kernelPath = kernelPath
        self.configPath = configPath
        self.stateDir = stateDir
        self.kernelLogPath = kernelLogPath
        self.controlTokenPath = controlTokenPath
        self.allowedUIDFile = allowedUIDFile
        self.aiLockPath = aiLockPath
        self.guardPort = guardPort
        self.pfConfPath = pfConfPath
        self.resolverDirectory = resolverDirectory
        self.pfctlPath = pfctlPath
        self.requirement = requirement
    }

    public static let production = HelperPaths(
        socketPath: "/var/run/segue/service.sock",
        intentPath: "/Library/Application Support/Segue/ai-lock.intent",
        kernelPath: "/Library/PrivilegedHelperTools/segue-kernel",
        configPath: "/Library/Application Support/Segue/kernel.json",
        stateDir: "/Library/Application Support/Segue/kernel",
        kernelLogPath: "/Library/Application Support/Segue/kernel.log",
        controlTokenPath: "/Library/Application Support/Segue/kernel/control.json",
        allowedUIDFile: "/Library/PrivilegedHelperTools/segue.allowed-uid",
        aiLockPath: "/Library/Application Support/Segue/ai-lock.txt",
        guardPort: 5354,
        pfConfPath: "/etc/pf.conf",
        resolverDirectory: "/etc/resolver",
        requirement: ""
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
            case "--kernel-log":
                if let next { paths.kernelLogPath = next; index += 1 }
            case "--control-token":
                if let next { paths.controlTokenPath = next; index += 1 }
            case "--allowed-uids":
                if let next { paths.allowedUIDFile = next; index += 1 }
            case "--ai-lock":
                if let next { paths.aiLockPath = next; index += 1 }
            case "--guard-port":
                if let next, let port = UInt16(next), port > 0 {
                    paths.guardPort = port
                    index += 1
                }
            case "--pf-conf":
                if let next { paths.pfConfPath = next; index += 1 }
            case "--pfctl":
                if let next { paths.pfctlPath = next; index += 1 }
            case "--resolver-dir":
                if let next { paths.resolverDirectory = next; index += 1 }
            case "--requirement":
                if let next { paths.requirement = next; index += 1 }
            case "--paths-root":
                if let next {
                    applyRoot(next, to: &paths)
                    index += 1
                }
            default:
                break
            }
            index += 1
        }
        return paths
    }

    /// Dev/test base. Later flags still win, so `--paths-root` then
    /// `--socket` keeps the explicit socket. Every path the helper writes
    /// lands under `root`; production launchd does not pass this flag.
    private static func applyRoot(_ root: String, to paths: inout HelperPaths) {
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        paths.socketPath = base + "/run/service.sock"
        paths.intentPath = base + "/ai-lock.intent"
        paths.kernelPath = base + "/bin/segue-kernel"
        paths.configPath = base + "/kernel.json"
        paths.stateDir = base + "/kernel"
        paths.kernelLogPath = base + "/kernel.log"
        paths.controlTokenPath = base + "/kernel/control.json"
        paths.allowedUIDFile = base + "/allowed-uid"
        paths.aiLockPath = base + "/ai-lock.txt"
        paths.pfConfPath = base + "/etc/pf.conf"
        paths.resolverDirectory = base + "/etc/resolver"
    }
}
