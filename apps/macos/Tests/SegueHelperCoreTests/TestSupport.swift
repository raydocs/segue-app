import Darwin
import Foundation
import SegueAILayer
import SegueHelperProtocol
import XCTest

@testable import SegueHelperCore

enum HelperFixtures {
    static func data(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SegueKitTests/Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    static func minified(_ name: String) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data(name))
        let compact = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: compact, as: UTF8.self)
    }
}

func posixMode(at url: URL) throws -> Int {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let mode = try XCTUnwrap(attrs[.posixPermissions] as? NSNumber)
    return mode.intValue & 0o777
}

func temporaryDirectory(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class ManualClock: SupervisorClock {
    var nowDate: Date

    init(_ date: Date) {
        nowDate = date
    }

    func now() -> Date { nowDate }

    func advance(_ seconds: TimeInterval) {
        nowDate = nowDate.addingTimeInterval(seconds)
    }
}

final class FakeLauncher: ProcessLauncher {
    final class Proc: RunningProcess {
        let pid: Int32
        let onExit: (Int32, ProcessExit) -> Void
        var ignoreTerminate = false
        var observeSignal: ((Int32) -> Void)?
        private(set) var running = true
        private(set) var signals: [Int32] = []
        private(set) var waits: [TimeInterval] = []

        init(pid: Int32, onExit: @escaping (Int32, ProcessExit) -> Void) {
            self.pid = pid
            self.onExit = onExit
        }

        var isRunning: Bool { running }

        func send(signal: Int32) {
            signals.append(signal)
            observeSignal?(signal)
            if signal == SIGKILL || (signal == SIGTERM && !ignoreTerminate) {
                finish(.signal(signal))
            }
        }

        func waitUntilExited(timeout: TimeInterval) -> Bool {
            waits.append(timeout)
            return !running
        }

        func finish(_ exit: ProcessExit) {
            guard running else { return }
            running = false
            onExit(pid, exit)
        }
    }

    private(set) var procs: [Proc] = []
    private(set) var requests: [[String]] = []
    private var nextPid: Int32 = 400
    var ignoreTerminate = false
    /// Fires inside `send`, before the exit callback, so a test can see
    /// the machine state at the moment a signal goes out.
    var onSend: ((Int32, Int32) -> Void)?

    func launch(
        _ request: LaunchRequest,
        onExit: @escaping (Int32, ProcessExit) -> Void
    ) throws -> RunningProcess {
        requests.append(request.arguments)
        let pid = nextPid
        let proc = Proc(pid: pid, onExit: onExit)
        proc.ignoreTerminate = ignoreTerminate
        proc.observeSignal = { [weak self] signal in
            self?.onSend?(pid, signal)
        }
        nextPid += 1
        procs.append(proc)
        return proc
    }

    var latest: Proc { procs[procs.count - 1] }
}

/// Stand-in for the kernel's control API. The supervisor publishes
/// whatever it is told, so tests drive "connected with a utun" by hand.
final class FakeControlClient: KernelControlClient {
    var status: KernelControlStatus?
    private(set) var connectCalls = 0

    func readStatus() -> KernelControlStatus? { status }

    func connect() { connectCalls += 1 }
}

final class StaticPeers: PeerCredentialSource {
    private let lock = NSLock()
    private var current: PeerIdentity?

    func set(_ identity: PeerIdentity?) {
        lock.lock()
        current = identity
        lock.unlock()
    }

    func identity(of socket: Int32) -> PeerIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
}

final class LineClient {
    private let fd: Int32
    private var open = true

    init(path: String) throws {
        let fd = try unixSocket()
        setReceiveTimeout(fd, seconds: 3)
        do {
            try connectUnixSocket(fd: fd, path: path)
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
        self.fd = fd
    }

    func send(_ text: String) throws -> Data {
        try LineIO.writeLine(fd: fd, payload: Data(text.utf8))
        return try read()
    }

    func read() throws -> Data {
        guard let line = try LineIO.readLine(fd: fd) else {
            throw LineIOError.read(0)
        }
        return line
    }

    func close() {
        if open {
            open = false
            _ = Darwin.close(fd)
        }
    }

    deinit { close() }
}

func decodeEnvelope(_ data: Data) throws -> HelperEnvelope {
    try JSONDecoder().decode(HelperEnvelope.self, from: data)
}

final class HelperHarness {
    let directory: URL
    let socketPath: String
    let intentURL: URL
    let launcher: FakeLauncher
    let supervisor: KernelSupervisor
    let peers: StaticPeers
    let server: HelperSocketServer

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("h-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socketPath = directory.appendingPathComponent("s.sock").path
        if socketPath.utf8.count >= 104 {
            throw UnixSocketError.pathTooLong(socketPath.utf8.count)
        }
        let intentURL = directory.appendingPathComponent("state/ai-lock.intent")
        let launcher = FakeLauncher()
        let supervisor = KernelSupervisor(
            kernelPath: "/Library/PrivilegedHelperTools/segue-kernel",
            configPath: "/Library/Application Support/Segue/kernel.json",
            stateDir: "/Library/Application Support/Segue/kernel",
            launcher: launcher
        )
        let peers = StaticPeers()
        peers.set(PeerIdentity(uid: getuid(), codeSigningSatisfied: true))
        let layer = AILayerController(
            commands: RecordingSystemCommands(),
            kernel: supervisor,
            list: AILockList(
                suffixes: ["example.com"],
                cidrs: [try CIDR(parsing: "192.0.2.0/24")]
            ),
            paths: AILayerPaths(
                pfConfPath: "/etc/pf.conf",
                resolverDirectory: "/etc/resolver",
                snapshotPath: directory.appendingPathComponent("dns-snapshot.json").path,
                guardAddress: "127.0.0.1",
                guardPort: AILayerPaths.defaultGuardPort
            )
        )
        // `tunnelTimeout: 0` keeps the background convergence loop out of
        // these socket tests; the kernel here has no control API at all.
        let session = HelperSession(
            store: IntentStore(fileURL: intentURL),
            kernel: supervisor,
            layer: layer,
            control: nil,
            reconcileOnInit: true,
            tunnelTimeout: 0
        )
        let server = HelperSocketServer(
            path: socketPath,
            session: session,
            peers: peers,
            policy: PeerPolicy(allowedUIDs: [getuid()], requirement: SegueCodeSigning.requirement)
        )
        self.directory = directory
        self.socketPath = socketPath
        self.intentURL = intentURL
        self.launcher = launcher
        self.supervisor = supervisor
        self.peers = peers
        self.server = server
        try server.start()
    }

    func roundTrip(_ json: String) throws -> HelperEnvelope {
        let client = try LineClient(path: socketPath)
        defer { client.close() }
        return try decodeEnvelope(client.send(json))
    }

    func stop() {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { stop() }
}
