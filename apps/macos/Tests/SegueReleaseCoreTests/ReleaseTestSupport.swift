import Darwin
import Foundation
import SegueAILayer
import SegueHelperCore
import SegueHelperProtocol
import XCTest

@testable import SegueReleaseCore

/// In-memory pfctl, networksetup, and files. Never touches the real system.
/// Mirrors the helper's recording fake, trimmed to what a restore does.
final class RecordingReleaseCommands: SystemCommands {
    private(set) var files: [String: String] = [:]
    private(set) var anchorLoaded: Bool
    private(set) var services: [DNSServiceRecord]
    private(set) var invocations: [String] = []
    /// A label that the next matching invocation fails with, e.g. "setdnsservers".
    var failNext: String?

    init(anchorLoaded: Bool = false) {
        self.anchorLoaded = anchorLoaded
        services = [
            DNSServiceRecord(serviceID: "en0", name: "Wi-Fi", servers: ["127.0.0.1"]),
            DNSServiceRecord(serviceID: "en1", name: "Ethernet", servers: ["127.0.0.1"]),
        ]
    }

    func seedFile(_ path: String, contents: String) {
        files[path] = contents
    }

    func seedAnchor(_ loaded: Bool) {
        anchorLoaded = loaded
    }

    /// A service that disappeared after the snapshot was taken.
    func dropService(named name: String) {
        services.removeAll { $0.name == name }
    }

    func discardLog() {
        invocations.removeAll()
    }

    func run(program: String, arguments: [String], standardInput: String?) throws -> SystemCommandOutput {
        let label = "\(program) \(arguments.joined(separator: " "))"
        invocations.append(label)
        if let failNext, label.contains(failNext) {
            self.failNext = nil
            return SystemCommandOutput(status: 1, stdout: "", stderr: "injected failure")
        }
        if program == SystemPrograms.pfctl {
            return pfctl(arguments)
        }
        if program == SystemPrograms.networksetup {
            return networksetup(arguments)
        }
        return SystemCommandOutput(status: 127, stdout: "", stderr: "unexpected program \(program)")
    }

    func readTextFile(_ path: String) throws -> String {
        invocations.append("read \(path)")
        guard let text = files[path] else { throw SystemCommandError.io("missing \(path)") }
        return text
    }

    func writeTextFile(_ path: String, _ contents: String) throws {
        invocations.append("write \(path)")
        files[path] = contents
    }

    func removeFile(_ path: String) throws {
        invocations.append("remove \(path)")
        files[path] = nil
    }

    func fileExists(_ path: String) -> Bool {
        files[path] != nil
    }

    func listDirectory(_ path: String) throws -> [String] {
        invocations.append("list \(path)")
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return files.keys
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .sorted()
    }

    func startGuardListener(address: String, port: UInt16, responder: GuardResponder) throws {}

    func stopGuardListener() throws {}

    func guardIsListening() -> Bool { false }

    func servers(_ serviceName: String) -> [String] {
        services.first { $0.name == serviceName }?.servers ?? []
    }

    private func pfctl(_ arguments: [String]) -> SystemCommandOutput {
        if arguments == ["-s", "Anchors"] {
            let stdout = anchorLoaded ? "  \(PFAnchorRenderer.anchorName)\n" : ""
            return SystemCommandOutput(status: 0, stdout: stdout, stderr: "")
        }
        if arguments == ["-a", PFAnchorRenderer.anchorName, "-F", "all"] {
            anchorLoaded = false
            return SystemCommandOutput(status: 0, stdout: "", stderr: "")
        }
        return SystemCommandOutput(status: 1, stdout: "", stderr: "unexpected pfctl \(arguments)")
    }

    private func networksetup(_ arguments: [String]) -> SystemCommandOutput {
        if arguments == ["-listnetworkserviceorder"] {
            return SystemCommandOutput(status: 0, stdout: serviceOrderText(), stderr: "")
        }
        if arguments.first == "-getdnsservers", arguments.count == 2 {
            guard let service = services.first(where: { $0.name == arguments[1] }) else {
                return SystemCommandOutput(status: 1, stdout: "", stderr: "service not found")
            }
            if service.servers.isEmpty {
                let stdout = "There aren't any DNS Servers set on \(service.name).\n"
                return SystemCommandOutput(status: 0, stdout: stdout, stderr: "")
            }
            return SystemCommandOutput(
                status: 0,
                stdout: service.servers.joined(separator: "\n") + "\n",
                stderr: ""
            )
        }
        if arguments.first == "-setdnsservers", arguments.count >= 3 {
            guard let index = services.firstIndex(where: { $0.name == arguments[1] }) else {
                return SystemCommandOutput(status: 1, stdout: "", stderr: "service not found")
            }
            let existing = services[index]
            let requested = Array(arguments.dropFirst(2))
            let servers = requested == ["Empty"] ? [] : requested
            services[index] = DNSServiceRecord(
                serviceID: existing.serviceID,
                name: existing.name,
                servers: servers
            )
            return SystemCommandOutput(status: 0, stdout: "", stderr: "")
        }
        return SystemCommandOutput(status: 1, stdout: "", stderr: "unexpected networksetup \(arguments)")
    }

    private func serviceOrderText() -> String {
        var lines = ["An asterisk (*) denotes that a network service is disabled.", ""]
        for (offset, service) in services.enumerated() {
            lines.append("(\(offset + 1)) \(service.name)")
            lines.append("(Hardware Port: \(service.name), Device: \(service.serviceID))")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

final class StaticReleasePeers: PeerCredentialSource {
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

final class ReleaseLineClient {
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

func decodeReleaseEnvelope(_ data: Data) throws -> ReleaseEnvelope {
    try JSONDecoder().decode(ReleaseEnvelope.self, from: data)
}

/// A daemon wired to the recording fake, on a temp socket.
final class ReleaseHarness {
    let directory: URL
    let socketPath: String
    let intentPath: String
    let commands: RecordingReleaseCommands
    let restorer: ReleaseRestorer
    let peers: StaticReleasePeers
    let server: ReleaseSocketServer
    let paths: ReleasePaths

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("r-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socketPath = directory.appendingPathComponent("r.sock").path
        if socketPath.utf8.count >= 104 {
            throw UnixSocketError.pathTooLong(socketPath.utf8.count)
        }
        let intentPath = directory.appendingPathComponent("ai-lock.intent").path
        let commands = RecordingReleaseCommands()
        let paths = ReleasePaths(
            socketPath: socketPath,
            intentPath: intentPath,
            snapshotPath: directory.appendingPathComponent("dns-snapshot.json").path,
            resolverDirectory: directory.appendingPathComponent("resolver").path,
            allowedUIDFile: directory.appendingPathComponent("segue.allowed-uid").path
        )
        let restorer = ReleaseRestorer(commands: commands, paths: paths)
        let peers = StaticReleasePeers()
        peers.set(PeerIdentity(uid: getuid(), codeSigningSatisfied: true))
        let server = ReleaseSocketServer(
            path: socketPath,
            session: ReleaseSession(restorer: restorer),
            peers: peers,
            policy: PeerPolicy(allowedUIDs: [getuid()], requirement: SegueCodeSigning.requirement)
        )
        self.directory = directory
        self.socketPath = socketPath
        self.intentPath = intentPath
        self.commands = commands
        self.restorer = restorer
        self.peers = peers
        self.server = server
        self.paths = paths
        try server.start()
    }

    func roundTrip(_ json: String) throws -> ReleaseEnvelope {
        let client = try ReleaseLineClient(path: socketPath)
        defer { client.close() }
        return try decodeReleaseEnvelope(client.send(json))
    }

    func stop() {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { stop() }
}

/// The state the helper leaves behind when it armed and cannot answer.
enum ArmedState {
    static func install(_ commands: RecordingReleaseCommands, paths: ReleasePaths) throws {
        commands.seedAnchor(true)
        for (name, body) in try ResolverFiles.render(suffixes: ["api.example", "chat.example"], port: 5354) {
            commands.seedFile(paths.resolverDirectory + "/" + name, contents: body)
        }
        // A foreign resolver file: same servers, no marker.
        commands.seedFile(
            paths.resolverDirectory + "/other.example",
            contents: "nameserver 127.0.0.1\nport 5354\n"
        )
        let snapshot = DNSSnapshot(services: [
            DNSServiceRecord(serviceID: "en0", name: "Wi-Fi", servers: ["192.0.2.1"]),
            DNSServiceRecord(serviceID: "en1", name: "Ethernet", servers: []),
        ])
        let text = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        commands.seedFile(paths.snapshotPath, contents: text)
        try IntentStore(fileURL: URL(fileURLWithPath: paths.intentPath))
            .save(StoredIntent(armed: true, generation: 4, name: "user_connect"))
    }
}
