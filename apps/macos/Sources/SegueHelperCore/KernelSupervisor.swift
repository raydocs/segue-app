import Darwin
import Foundation

/// How a child ended. `signal` is an uncaught signal (`terminationReason`).
public enum ProcessExit: Equatable, Sendable {
    case code(Int32)
    case signal(Int32)
}

/// Documented `segue-kernel` statuses (docs/design/macos.md appendix) plus
/// signals. SIGTERM and SIGINT are the clean shutdown the kernel catches;
/// an uncaught SIGKILL is not.
public enum KernelExitCode: Equatable, Sendable {
    case cleanShutdown
    case listenerFailed
    case badArguments
    case configRejected
    case tunSetupFailed
    case signaled(Int32)
    case unknown(Int32)

    public init(_ exit: ProcessExit) {
        switch exit {
        case let .signal(signal):
            if signal == SIGTERM || signal == SIGINT {
                self = .cleanShutdown
            } else {
                self = .signaled(signal)
            }
        case let .code(status):
            switch status {
            case 0: self = .cleanShutdown
            case 1: self = .listenerFailed
            case 2: self = .badArguments
            case 3: self = .configRejected
            case 4: self = .tunSetupFailed
            default: self = .unknown(status)
            }
        }
    }

    public var stateName: String {
        switch self {
        case .cleanShutdown: return "clean_shutdown"
        case .listenerFailed: return "listener_failed"
        case .badArguments: return "bad_arguments"
        case .configRejected: return "config_rejected"
        case .tunSetupFailed: return "tun_setup_failed"
        case let .signaled(signal): return "signal_\(signal)"
        case let .unknown(status): return "exit_\(status)"
        }
    }

    /// Crashes restart inside the budget. A clean exit and a rejected
    /// config or argv do not: repeating them cannot succeed.
    public var restarts: Bool {
        switch self {
        case .listenerFailed, .tunSetupFailed, .signaled, .unknown:
            return true
        case .cleanShutdown, .badArguments, .configRejected:
            return false
        }
    }
}

public struct LaunchRequest: Equatable, Sendable {
    public var arguments: [String]

    public init(arguments: [String]) {
        self.arguments = arguments
    }
}

public protocol RunningProcess: AnyObject {
    var pid: Int32 { get }
    var isRunning: Bool { get }
    func send(signal: Int32)
    /// True when the process has exited. Implementations may return
    /// immediately; the timeout is the production grace, not a sleep the
    /// tests must honor.
    func waitUntilExited(timeout: TimeInterval) -> Bool
}

/// `onExit` runs after `launch` has returned, on whatever thread the
/// launcher chooses. It must not run re-entrantly inside `launch`.
public protocol ProcessLauncher: AnyObject {
    func launch(
        _ request: LaunchRequest,
        onExit: @escaping (Int32, ProcessExit) -> Void
    ) throws -> RunningProcess
}

public protocol SupervisorClock: AnyObject {
    func now() -> Date
}

public final class SystemSupervisorClock: SupervisorClock {
    public init() {}

    public func now() -> Date { Date() }
}

public struct KernelSnapshot: Equatable, Sendable {
    public var state: String
    public var pid: Int32?
    public var lastExit: String?
    /// Set when a utun is up. This supervisor does not poll the kernel
    /// control API, so its own snapshots leave the field nil; a stand-in
    /// used by tests publishes the interface and the kernel DNS address.
    public var tunInterface: String?
    /// Kernel DNS listen address: an IP, or `ip:53`. Nil when unpublished.
    public var dnsAddress: String?

    public init(
        state: String,
        pid: Int32?,
        lastExit: String?,
        tunInterface: String? = nil,
        dnsAddress: String? = nil
    ) {
        self.state = state
        self.pid = pid
        self.lastExit = lastExit
        self.tunInterface = tunInterface
        self.dnsAddress = dnsAddress
    }
}

public protocol KernelSupervising: AnyObject {
    func snapshot() -> KernelSnapshot
}

public enum LaunchError: Error, Equatable {
    case emptyCommand
}

/// Owns one `segue-kernel run` child.
///
/// A crash (listener failure, tun setup failure, unknown status, or an
/// uncaught signal) is restarted up to `restartLimit` times inside
/// `restartWindow`. The next crash stays down and reports `kernel_failed`
/// until `start()` is called again. Stop sends SIGTERM and, if the child
/// is still alive after `stopGrace`, SIGKILL.
public final class KernelSupervisor: KernelSupervising {
    public let kernelPath: String
    public let configPath: String
    public let stateDir: String

    private let launcher: ProcessLauncher
    private let clock: SupervisorClock
    private let stopGrace: TimeInterval
    private var budget: RestartBudget
    private let lock = NSLock()
    private var running: RunningProcess?
    private var phase: Phase = .stopped
    private var lastExit: KernelExitCode?
    private var stopRequested = false

    public init(
        kernelPath: String,
        configPath: String,
        stateDir: String,
        launcher: ProcessLauncher,
        clock: SupervisorClock = SystemSupervisorClock(),
        restartLimit: Int = 10,
        restartWindow: TimeInterval = 600,
        stopGrace: TimeInterval = 5
    ) {
        self.kernelPath = kernelPath
        self.configPath = configPath
        self.stateDir = stateDir
        self.launcher = launcher
        self.clock = clock
        self.stopGrace = stopGrace
        budget = RestartBudget(limit: restartLimit, window: restartWindow)
    }

    public func snapshot() -> KernelSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let pid: Int32?
        if case let .running(pidValue) = phase {
            pid = pidValue
        } else {
            pid = nil
        }
        return KernelSnapshot(state: phase.stateName, pid: pid, lastExit: lastExit?.stateName)
    }

    /// An explicit start clears a previous `kernel_failed` and the budget.
    /// It does not run unless something calls it. Stage 0's session does not.
    public func start() throws {
        try sync {
            guard running == nil else { return }
            stopRequested = false
            budget.reset()
            try launchLocked()
        }
    }

    public func stop() {
        let proc: RunningProcess? = syncValue {
            stopRequested = true
            return running
        }
        guard let proc else { return }
        proc.send(signal: SIGTERM)
        if !proc.waitUntilExited(timeout: stopGrace) {
            proc.send(signal: SIGKILL)
            _ = proc.waitUntilExited(timeout: stopGrace)
        }
        syncValue {
            if running?.pid == proc.pid {
                running = nil
                phase = .stopped
            }
        }
    }

    private func handleExit(pid: Int32, exit: ProcessExit) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = running, current.pid == pid else { return }
        running = nil
        let mapped = KernelExitCode(exit)
        lastExit = mapped
        if stopRequested {
            phase = .stopped
            return
        }
        guard mapped.restarts else {
            phase = .settled(mapped)
            return
        }
        guard budget.consume(now: clock.now()) else {
            phase = .kernelFailed(mapped)
            return
        }
        do {
            try launchLocked()
        } catch {
            phase = .kernelFailed(mapped)
        }
    }

    /// Caller holds `lock`.
    private func launchLocked() throws {
        let request = LaunchRequest(arguments: [
            kernelPath, "run", "--config", configPath, "--state-dir", stateDir,
        ])
        let proc = try launcher.launch(request) { [weak self] pid, exit in
            self?.handleExit(pid: pid, exit: exit)
        }
        running = proc
        phase = .running(pid: proc.pid)
    }

    private func sync(_ body: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try body()
    }

    private func syncValue<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private enum Phase: Equatable {
        case stopped
        case running(pid: Int32)
        case settled(KernelExitCode)
        case kernelFailed(KernelExitCode)

        var stateName: String {
            switch self {
            case .stopped: return "stopped"
            case .running: return "running"
            case let .settled(exit): return exit.stateName
            case .kernelFailed: return "kernel_failed"
            }
        }
    }
}

private struct RestartBudget {
    var limit: Int
    var window: TimeInterval
    private var stamps: [Date] = []

    // Explicit: older Swift makes the memberwise init private when any stored
    // property is private, which broke the macos-15 CI build.
    init(limit: Int, window: TimeInterval) {
        self.limit = limit
        self.window = window
    }

    mutating func reset() {
        stamps.removeAll()
    }

    mutating func consume(now: Date) -> Bool {
        stamps.removeAll { now.timeIntervalSince($0) >= window }
        guard stamps.count < limit else { return false }
        stamps.append(now)
        return true
    }
}
