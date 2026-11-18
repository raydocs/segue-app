import Darwin
import Dispatch
import Foundation
import SegueAILayer

/// Process and file IO for the AI layer. Tests never construct this type:
/// nothing here is exercised by `swift test`, and it will call `pfctl` and
/// `networksetup` and write the paths it is given.
public final class LiveSystemCommands: SystemCommands {
    private let lock = NSLock()
    private var server: GuardUDPServer?

    public init() {}

    public func run(program: String, arguments: [String], standardInput: String?) throws
        -> SystemCommandOutput
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe = Pipe()
        if standardInput != nil {
            process.standardInput = stdinPipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        try process.run()
        if let standardInput {
            let writer = stdinPipe.fileHandleForWriting
            try? writer.write(contentsOf: Data(standardInput.utf8))
            try? writer.close()
        }

        // Drain both pipes off this thread so a chatty child cannot fill a
        // pipe and block before `waitUntilExit`. These commands are small;
        // the split is only so a full pipe cannot stall the helper.
        let box = PipeBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            box.storeStdout((try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data())
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            box.storeStderr((try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data())
            group.leave()
        }
        process.waitUntilExit()
        group.wait()
        let (out, err) = box.copy()
        return SystemCommandOutput(
            status: process.terminationStatus,
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self)
        )
    }

    public func readTextFile(_ path: String) throws -> String {
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw SystemCommandError.io("read \(path)")
        }
    }

    public func writeTextFile(_ path: String, _ contents: String) throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw SystemCommandError.io("write \(path)")
        }
    }

    public func removeFile(_ path: String) throws {
        if !FileManager.default.fileExists(atPath: path) { return }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            throw SystemCommandError.io("remove \(path)")
        }
    }

    public func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func startGuardListener(address: String, port: UInt16, responder: GuardResponder) throws {
        lock.lock()
        defer { lock.unlock() }
        if let server, server.address == address, server.port == port {
            server.update(responder)
            return
        }
        server?.stop()
        server = nil
        server = try GuardUDPServer(address: address, port: port, responder: responder)
    }

    public func stopGuardListener() throws {
        lock.lock()
        let running = server
        server = nil
        lock.unlock()
        running?.stop()
    }

    public func guardIsListening() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return server != nil
    }
}

/// Joined after `DispatchGroup.wait`, which happens-before the reads.
private final class PipeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func storeStdout(_ data: Data) {
        lock.lock()
        stdout = data
        lock.unlock()
    }

    func storeStderr(_ data: Data) {
        lock.lock()
        stderr = data
        lock.unlock()
    }

    func copy() -> (Data, Data) {
        lock.lock()
        defer { lock.unlock() }
        return (stdout, stderr)
    }
}

/// UDP DNS on 127.0.0.1. Answers with `GuardResponder` and never recurses.
private final class GuardUDPServer {
    let address: String
    let port: UInt16
    private let lock = NSLock()
    private var responder: GuardResponder
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var stopped = false

    init(address: String, port: UInt16, responder: GuardResponder) throws {
        self.address = address
        self.port = port
        self.responder = responder
        let fd = try Self.bind(address: address, port: port)
        self.fd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "segue.guard-dns"))
        source.setEventHandler { [weak self] in
            self?.receive()
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        self.source = source
    }

    func update(_ responder: GuardResponder) {
        lock.lock()
        self.responder = responder
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopped = true
        let source = self.source
        self.source = nil
        fd = -1
        lock.unlock()
        source?.cancel()
    }

    private func receive() {
        lock.lock()
        if stopped || fd < 0 {
            lock.unlock()
            return
        }
        let fd = self.fd
        let responder = self.responder
        lock.unlock()

        var buffer = [UInt8](repeating: 0, count: 4096)
        var from = sockaddr_in()
        var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &from) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.recvfrom(fd, &buffer, buffer.count, 0, raw, &fromLen)
            }
        }
        guard count > 0 else { return }
        let query = Data(buffer.prefix(Int(count)))
        guard let reply = responder.reply(to: query) else { return }
        _ = reply.withUnsafeBytes { raw in
            withUnsafePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { dest in
                    Darwin.sendto(fd, raw.baseAddress, reply.count, 0, dest, fromLen)
                }
            }
        }
    }

    private static func bind(address: String, port: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw SystemCommandError.io("socket \(errno)") }
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, address, &addr.sin_addr) == 1 else {
            Darwin.close(fd)
            throw SystemCommandError.io("inet_pton")
        }
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.bind(fd, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let error = errno
            Darwin.close(fd)
            throw SystemCommandError.io("bind \(error)")
        }
        return fd
    }
}
