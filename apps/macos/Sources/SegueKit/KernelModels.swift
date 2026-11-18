import Foundation

/// JSON the kernel control API returns.
///
/// `GET /v1/status` (and the POST replies) use this shape. `state` is the
/// coarse value the menu may show. `posture` is finer. `tun` says whether a
/// utun is actually up. A click is not a status.

public enum KernelState: String, Codable, Equatable, Sendable {
    case connected
    case reconnecting
    case disconnected
}

public enum KernelPosture: String, Codable, Equatable, Sendable {
    case connecting
    case connected
    case reconnecting
    case error
    case disconnected
}

public enum PolicySource: String, Codable, Equatable, Sendable {
    case inline
    case signed
}

public enum TunRoutes: String, Codable, Equatable, Sendable {
    case absent
    case installed
}

public struct ControlRefusal: Codable, Equatable, Sendable {
    public var exit: String
    /// Relay `REJECT` code. `1` is a version mismatch, `2` is auth.
    public var code: Int

    public init(exit: String, code: Int) {
        self.exit = exit
        self.code = code
    }
}

public struct KernelPolicyStatus: Codable, Equatable, Sendable {
    public var source: PolicySource
    public var valid: Bool
    public var version: UInt64?
    public var expiresAt: UInt64?
    public var highWater: UInt64

    enum CodingKeys: String, CodingKey {
        case source
        case valid
        case version
        case expiresAt = "expires_at"
        case highWater = "high_water"
    }

    public init(
        source: PolicySource,
        valid: Bool,
        version: UInt64?,
        expiresAt: UInt64?,
        highWater: UInt64
    ) {
        self.source = source
        self.valid = valid
        self.version = version
        self.expiresAt = expiresAt
        self.highWater = highWater
    }
}

public struct TunState: Codable, Equatable, Sendable {
    public var interfaceName: String?
    public var routes: TunRoutes

    enum CodingKeys: String, CodingKey {
        case interfaceName = "interface"
        case routes
    }

    public init(interfaceName: String?, routes: TunRoutes) {
        self.interfaceName = interfaceName
        self.routes = routes
    }
}

public struct KernelStatus: Codable, Equatable, Sendable {
    public var state: KernelState
    public var posture: KernelPosture
    public var exitChoice: String
    public var currentExit: String?
    public var exits: [String]
    public var revoked: Bool
    public var controlRefused: [ControlRefusal]
    public var policy: KernelPolicyStatus
    public var tun: TunState

    enum CodingKeys: String, CodingKey {
        case state
        case posture
        case exitChoice = "exit_choice"
        case currentExit = "current_exit"
        case exits
        case revoked
        case controlRefused = "control_refused"
        case policy
        case tun
    }

    public init(
        state: KernelState,
        posture: KernelPosture,
        exitChoice: String,
        currentExit: String?,
        exits: [String],
        revoked: Bool,
        controlRefused: [ControlRefusal],
        policy: KernelPolicyStatus,
        tun: TunState
    ) {
        self.state = state
        self.posture = posture
        self.exitChoice = exitChoice
        self.currentExit = currentExit
        self.exits = exits
        self.revoked = revoked
        self.controlRefused = controlRefused
        self.policy = policy
        self.tun = tun
    }

    /// The menu shows connected only from this snapshot: kernel `state` is
    /// `connected`, the device was not revoked, and a utun has its routes.
    public var showsConnected: Bool {
        guard !revoked, state == .connected, tun.routes == .installed else {
            return false
        }
        guard let name = tun.interfaceName, !name.isEmpty else {
            return false
        }
        return true
    }

    /// Short copy for the menu. Internal refusal codes stay off this line.
    public var statusLine: String {
        if revoked {
            return "This device was revoked."
        }
        if showsConnected {
            if controlRefused.isEmpty {
                return "Connected."
            }
            return "Connected. Reconnect or update."
        }
        switch state {
        case .connected:
            return "The tunnel is not up."
        case .reconnecting:
            return "Reconnecting."
        case .disconnected:
            return "Not connected."
        }
    }
}

public struct KernelErrorBody: Codable, Equatable, Sendable {
    public var error: String

    public init(error: String) {
        self.error = error
    }
}

/// `{"exit":"auto"}` body for `POST /v1/exit`.
public struct ExitSelection: Codable, Equatable, Sendable {
    public var exit: String

    public init(exit: String) {
        self.exit = exit
    }
}

/// On-disk token file the kernel writes: `{"addr":"127.0.0.1:port","token":"..."}`.
public struct ControlTokenFile: Codable, Equatable, Sendable {
    public var addr: String
    public var token: String

    public init(addr: String, token: String) {
        self.addr = addr
        self.token = token
    }
}
