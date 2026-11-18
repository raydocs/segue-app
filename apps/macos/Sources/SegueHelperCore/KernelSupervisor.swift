import Darwin
import Foundation
import SegueHelperProtocol

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
    /// Where the child's stdout/stderr are appended (the kernel log dir).
    /// Nil sends both to `/dev/null`, as before the capture existed.
    public var stdoutPath: String?
    public var stderrPath: String?

    public init(arguments: [String], stdoutPath: String? = nil, stderrPath: String? = nil) {
        self.arguments = arguments
        self.stdoutPath = stdoutPath
        self.stderrPath = stderrPath
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
    /// Tail of `kernel.stderr` (≤2 KiB, redacted), published only while
    /// the state is `kernel_failed` — the one state whose cause the exit
    /// code alone does not name.
    public var lastStderr: String?
    /// The utun the kernel's control API names, published only while the
    /// supervisor's child is running. Nil when the kernel is down or not
    /// answering.
    public var tunInterface: String?
    /// Kernel DNS listen address (from the config, `dns.listen`), published
    /// only while the control API reports a connected carrier. The layer
    /// aims `/etc/resolver` at `127.0.0.1` and this port. An address that
    /// is not loopback `host:port` is unpublished and the guard port is used.
    public var dnsAddress: String?

    public init(
        state: String,
        pid: Int32?,
        lastExit: String?,
        lastStderr: String? = nil,
        tunInterface: String? = nil,
        dnsAddress: String? = nil
    ) {
        self.state = state
        self.pid = pid
        self.lastExit = lastExit
        self.lastStderr = lastStderr
        self.tunInterface = tunInterface
        self.dnsAddress = dnsAddress
    }
}

public protocol KernelSupervising: AnyObject {
    func snapshot() -> KernelSnapshot
}

/// The session's handle on the kernel: the read-back plus the lifecycle.
/// `onStateChange` runs after any transition (start aside), never while
/// the supervisor holds its lock, so the handler may call `snapshot()`.
public protocol KernelControlling: KernelSupervising {
    var onStateChange: (() -> Void)? { get set }
    /// Idempotent. Clears a previous `kernel_failed` and the budget.
    func start() throws
    /// SIGTERM, `stopGrace` seconds, then SIGKILL.
    func stop()
}

public enum LaunchError: Error, Equatable {
    case emptyCommand
}

/// Owns one `segue-kernel run` child and reports what its control API
/// says about the tunnel.
///
/// A crash (listener failure, tun setup failure, unknown status, or an
/// uncaught signal) is restarted up to `restartLimit` times inside
/// `restartWindow`. The next crash stays down and reports `kernel_failed`
/// until `start()` is called again. Stop sends SIGTERM and, if the child
/// is still alive after `stopGrace`, SIGKILL. The real CLI is
/// `segue-kernel [run] [--state-dir DIR] [--log PATH] <kernel.json>` —
/// the config path is positional and there is no `--config` flag.
///
/// The child's pid goes to `<stateDir>/kernel.pid`. A start that finds a
/// live kernel named in a leftover pid file (a previous helper died
/// without stopping it) takes that process over before spawning, because
/// a fresh child could not bind the ports the orphan still holds.
///
/// The child's stdout and stderr are appended to `kernel.stdout` /
/// `kernel.stderr` in the kernel log dir (the `--log` file's directory),
/// mode 0600 and rotated by the launcher at 1 MiB, so a crash that only
/// prints its cause still leaves it on disk. While the state is
/// `kernel_failed` the snapshot also carries the last 2 KiB of stderr,
/// redacted, as `lastStderr`.
public final class KernelSupervisor: KernelControlling {
    public let kernelPath: String
    public let configPath: String
    public let stateDir: String
    public let logPath: String

    /// Set by the session; runs after exits and budget exhaustion, off
    /// the internal lock.
    public var onStateChange: (() -> Void)?

    private let launcher: ProcessLauncher
    private let control: KernelControlClient?
    private let clock: SupervisorClock
    private let stopGrace: TimeInterval
    private let externalProbe: (Int32, String) -> Bool
    private var budget: RestartBudget
    private let lock = NSLock()
    private var running: RunningProcess?
    private var phase: Phase = .stopped
    private var lastExit: KernelExitCode?
    private var stopRequested = false
    /// `dns.listen` from the kernel config. Published only while the
    /// control API reports a connected carrier.
    private var dnsListen: String?

    public init(
        kernelPath: String,
        configPath: String,
        stateDir: String,
        launcher: ProcessLauncher,
        logPath: String = "/Library/Application Support/Segue/kernel.log",
        control: KernelControlClient? = nil,
        clock: SupervisorClock = SystemSupervisorClock(),
        restartLimit: Int = 10,
        restartWindow: TimeInterval = 600,
        stopGrace: TimeInterval = 5,
        externalProbe: @escaping (Int32, String) -> Bool = KernelSupervisor.probeExternalProcess
    ) {
        self.kernelPath = kernelPath
        self.configPath = configPath
        self.stateDir = stateDir
        self.launcher = launcher
        self.logPath = logPath
        self.control = control
        self.clock = clock
        self.stopGrace = stopGrace
        self.externalProbe = externalProbe
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
        var tunInterface: String?
        var dnsAddress: String?
        if case .running = phase, let control {
            if let status = control.readStatus() {
                tunInterface = status.tunInterface
                // The kernel answers DNS as soon as it boots, but the
                // carrier is what makes that resolver the one armed names
                // should use. Until then the layer keeps the guard port.
                if status.state == "connected" { dnsAddress = dnsListen }
            }
        }
        var lastStderr: String?
        if case .kernelFailed = phase {
            lastStderr = Self.redactedStderrTail(stderrCapturePath)
        }
        return KernelSnapshot(
            state: phase.stateName,
            pid: pid,
            lastExit: lastExit?.stateName,
            lastStderr: lastStderr,
            tunInterface: tunInterface,
            dnsAddress: dnsAddress
        )
    }

    /// An explicit start clears a previous `kernel_failed` and the budget.
    public func start() throws {
        try sync {
            guard running == nil else { return }
            stopRequested = false
            budget.reset()
            dnsListen = Self.readDNSListen(configPath: configPath)
            takeOverOrphanLocked()
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
                Self.removePIDFile(pidFilePath)
            }
        }
    }

    private func handleExit(pid: Int32, exit: ProcessExit) {
        var changed = false
        lock.lock()
        if let current = running, current.pid == pid {
            running = nil
            Self.removePIDFile(pidFilePath)
            let mapped = KernelExitCode(exit)
            lastExit = mapped
            if stopRequested {
                phase = .stopped
            } else if !mapped.restarts {
                phase = .settled(mapped)
            } else if !budget.consume(now: clock.now()) {
                phase = .kernelFailed(mapped)
            } else if !launchAfterExitLocked() {
                phase = .kernelFailed(mapped)
            }
            changed = true
        }
        lock.unlock()
        if changed { onStateChange?() }
    }

    /// Caller holds `lock`. A relaunch that throws must not escape
    /// `handleExit` (it would drop the exit on the floor).
    private func launchAfterExitLocked() -> Bool {
        do {
            try launchLocked()
            return true
        } catch {
            return false
        }
    }

    /// Caller holds `lock`.
    private func launchLocked() throws {
        let request = LaunchRequest(
            arguments: [
                kernelPath, "run", "--state-dir", stateDir, "--log", logPath, configPath,
            ],
            stdoutPath: stdoutCapturePath,
            stderrPath: stderrCapturePath
        )
        let proc = try launcher.launch(request) { [weak self] pid, exit in
            self?.handleExit(pid: pid, exit: exit)
        }
        running = proc
        phase = .running(pid: proc.pid)
        Self.writePIDFile(pidFilePath, pid: proc.pid)
    }

    /// Caller holds `lock`. An orphan is a leftover from a helper that
    /// died (SIGKILL, crash) between launching the kernel and exiting
    /// cleanly. Only a live process whose executable name matches the
    /// kernel's is touched; a stale pid after a reboot points at another
    /// process or nothing and is just cleared.
    private func takeOverOrphanLocked() {
        guard let pid = Self.readPIDFile(pidFilePath), pid > 0 else { return }
        let name = (kernelPath as NSString).lastPathComponent
        guard externalProbe(pid, name) else {
            Self.removePIDFile(pidFilePath)
            return
        }
        _ = Darwin.kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(stopGrace)
        while Date() < deadline, externalProbe(pid, name) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if externalProbe(pid, name) {
            _ = Darwin.kill(pid, SIGKILL)
            let killDeadline = Date().addingTimeInterval(1)
            while Date() < killDeadline, externalProbe(pid, name) {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        Self.removePIDFile(pidFilePath)
    }

    private var pidFilePath: String { stateDir + "/kernel.pid" }

    /// The kernel log dir (the `--log` file's directory) also holds the
    /// captured child output: `kernel.stdout` / `kernel.stderr` next to
    /// `kernel.log`.
    private var logDirectory: String { (logPath as NSString).deletingLastPathComponent }
    private var stdoutCapturePath: String { logDirectory + "/kernel.stdout" }
    private var stderrCapturePath: String { logDirectory + "/kernel.stderr" }

    /// Last `stderrTailBytes` of the capture file, redacted. The redaction
    /// is the same one diagnostics export uses; the tail is what a
    /// `kernel_failed` row can show without shipping the whole log.
    private static func redactedStderrTail(_ path: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > 0 else { return nil }
        let window = UInt64(stderrTailBytes)
        let start = size > window ? size - window : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: stderrTailBytes),
              !data.isEmpty
        else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return DiagnosticsRedactor.redact(text, home: NSHomeDirectory())
    }

    /// The `kernel_failed` status carries at most this many bytes of the
    /// captured stderr.
    private static let stderrTailBytes = 2 * 1_024

    // MARK: - files and process facts

    private static func writePIDFile(_ path: String, pid: Int32) {
        FileManager.default.createFile(
            atPath: path,
            contents: Data("\(pid)\n".utf8),
            attributes: [.posixPermissions: 0o600]
        )
    }

    private static func readPIDFile(_ path: String) -> Int32? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0
        else { return nil }
        return pid
    }

    private static func removePIDFile(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// `dns.listen` from the kernel config: where the kernel's DNS
    /// answers. Nil when the config is unreadable or has none; the layer
    /// then keeps the guard.
    static func readDNSListen(configPath: String) -> String? {
        guard let data = FileManager.default.contents(atPath: configPath),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dns = object["dns"] as? [String: Any],
              let listen = dns["listen"] as? String,
              !listen.isEmpty
        else { return nil }
        return listen
    }

    /// True when `pid` is alive and its executable name is `name`
    /// (`kern.proc.pid` `p_comm`, the short name `ps -o comm` prints).
    public static func probeExternalProcess(pid: Int32, name: String) -> Bool {
        if Darwin.kill(pid, 0) != 0, errno == ESRCH { return false }
        guard let comm = processName(pid: pid) else { return false }
        return comm == name
    }

    private static func processName(pid: Int32) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard mib.withUnsafeMutableBufferPointer({ buffer -> Int32 in
            sysctl(buffer.baseAddress, 4, &info, &size, nil, 0)
        }) == 0, size >= MemoryLayout<kinfo_proc>.size else { return nil }
        return withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            let bytes = raw.prefix(while: { $0 != 0 })
            return String(bytes: bytes, encoding: .utf8)
        }
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
