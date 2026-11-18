import Darwin
import Foundation
import SegueHelperCore
import SegueHelperProtocol

public enum ReleaseSocketError: Error, Equatable {
    case alreadyStarted
    case failed(String)
}

/// Decode a request envelope into a reply. One verb: `restore` runs the
/// restorer and answers with the read-back; anything else is malformed. The
/// restorer never throws and never blocks on the helper.
public final class ReleaseSession {
    private let restorer: ReleaseRestorer

    public init(restorer: ReleaseRestorer) {
        self.restorer = restorer
    }

    public func handle(_ envelope: ReleaseEnvelope) -> ReleaseEnvelope {
        guard envelope.kind == .restore else {
            return ReleaseEnvelope.failure(
                code: ReleaseErrorCode.malformed,
                message: "the release daemon only answers restore"
            )
        }
        return ReleaseEnvelope.report(restorer.restore())
    }
}

/// Line-oriented JSON server for the release daemon, one request at a time.
/// The peer check is the helper's: allowed uid plus the code-signing
/// requirement, evaluated before any request line is read. The listen socket
/// is non-blocking and polled so `stop()` does not need to close it from
/// another thread.
public final class ReleaseSocketServer {
    public let path: String
    private let session: ReleaseSession
    private let peers: PeerCredentialSource
    private let policy: PeerPolicy
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var started = false
    private var stopped = false
    private var done: DispatchSemaphore?

    public init(
        path: String,
        session: ReleaseSession,
        peers: PeerCredentialSource,
        policy: PeerPolicy
    ) {
        self.path = path
        self.session = session
        self.peers = peers
        self.policy = policy
    }

    public func start() throws {
        lock.lock()
        if started {
            lock.unlock()
            throw ReleaseSocketError.alreadyStarted
        }
        started = true
        lock.unlock()

        let fd: Int32
        do {
            try unlinkSocketFile(path)
            fd = try unixSocket()
        } catch let error as UnixSocketError {
            throw ReleaseSocketError.failed(String(describing: error))
        }
        var handedOff = false
        defer {
            if !handedOff {
                _ = Darwin.close(fd)
            }
        }
        do {
            setNonBlocking(fd, true)
            try bindUnixSocket(fd: fd, path: path)
            guard Darwin.listen(fd, 16) == 0 else {
                throw UnixSocketError.failed("listen", errno)
            }
        } catch let error as UnixSocketError {
            throw ReleaseSocketError.failed(String(describing: error))
        }
        _ = path.withCString { chmod($0, 0o666) }

        let semaphore = DispatchSemaphore(value: 0)
        lock.lock()
        listenFD = fd
        done = semaphore
        handedOff = true
        lock.unlock()
        let thread = Thread { [weak self] in
            self?.acceptLoop(listenFD: fd)
            semaphore.signal()
        }
        thread.name = "segue-release.accept"
        thread.start()
    }

    public func stop() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        let semaphore = done
        lock.unlock()
        // Longer than the per-connection read timeout so a stuck line
        // finishes and the accept thread can signal before we close.
        _ = semaphore?.wait(timeout: .now() + 5)
        lock.lock()
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 {
            _ = Darwin.close(fd)
        }
        _ = path.withCString { unlink($0) }
    }

    private func isStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop(listenFD: Int32) {
        while !isStopped() {
            var pollSet = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollSet, 1, 50)
            if isStopped() { break }
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }
            let client = Darwin.accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                break
            }
            serve(client)
        }
    }

    private func serve(_ client: Int32) {
        defer { _ = Darwin.close(client) }
        _ = fcntl(client, F_SETFD, FD_CLOEXEC)
        setNonBlocking(client, false)
        var nosig: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout.size(ofValue: nosig)))
        setReceiveTimeout(client, seconds: 3)
        guard admit(client) else { return }
        while !isStopped() {
            do {
                guard let line = try LineIO.readLine(fd: client) else { return }
                try handleLine(client, line)
            } catch LineIOError.timeout, LineIOError.tooLong {
                try? reply(client, ReleaseEnvelope.failure(
                    code: ReleaseErrorCode.malformed,
                    message: "request was empty, too long, or stalled"
                ))
                return
            } catch {
                try? reply(client, ReleaseEnvelope.failure(
                    code: ReleaseErrorCode.internalError,
                    message: "request failed"
                ))
                return
            }
        }
    }

    private func admit(_ client: Int32) -> Bool {
        guard let peer = peers.identity(of: client) else {
            try? reply(client, ReleaseEnvelope.failure(
                code: ReleaseErrorCode.unauthorized,
                message: "peer identity unavailable"
            ))
            return false
        }
        switch authorize(peer: peer, policy: policy) {
        case .allow:
            return true
        case let .deny(reason):
            try? reply(client, ReleaseEnvelope.failure(
                code: ReleaseErrorCode.unauthorized,
                message: "peer denied: \(reason.rawValue)"
            ))
            return false
        }
    }

    private func handleLine(_ client: Int32, _ line: Data) throws {
        if line.isEmpty {
            try reply(client, ReleaseEnvelope.failure(
                code: ReleaseErrorCode.malformed,
                message: "empty request"
            ))
            return
        }
        do {
            let envelope = try JSONDecoder().decode(ReleaseEnvelope.self, from: line)
            try reply(client, session.handle(envelope))
        } catch let error as ReleaseProtocolError {
            switch error {
            case let .unsupportedVersion(version):
                try reply(client, ReleaseEnvelope.failure(
                    code: ReleaseErrorCode.unsupportedVersion,
                    message: "unsupported protocol version \(version)"
                ))
            case .malformed:
                try reply(client, ReleaseEnvelope.failure(
                    code: ReleaseErrorCode.malformed,
                    message: "malformed request"
                ))
            }
        } catch is DecodingError {
            try reply(client, ReleaseEnvelope.failure(
                code: ReleaseErrorCode.malformed,
                message: "malformed request"
            ))
        } catch {
            try reply(client, ReleaseEnvelope.failure(
                code: ReleaseErrorCode.internalError,
                message: "request failed"
            ))
        }
    }

    private func reply(_ client: Int32, _ envelope: ReleaseEnvelope) throws {
        let data = try JSONEncoder().encode(envelope)
        try LineIO.writeLine(fd: client, payload: data)
    }
}
