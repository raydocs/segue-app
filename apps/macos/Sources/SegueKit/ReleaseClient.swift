import Foundation
import SegueHelperProtocol

/// Failures the menu can show without quoting the release daemon's own text.
public enum ReleaseClientError: Error, Equatable {
    case notInstalled
    case versionMismatch(Int?)
    case unauthorized
    case malformed
    case rejected(code: String)
    case transport
}

/// What `ConnectionModel` asks the release daemon. `ReleaseClient` is the
/// socket implementation; tests substitute a fake.
public protocol ReleaseControlling: Sendable {
    func restore() async throws -> ReleaseReport
}

/// Versioned JSON lines to the release daemon's socket. Same transport and
/// timeout discipline as `HelperClient`; a different socket and a one-verb
/// contract. The release daemon is the path of last resort, so the client
/// never retries.
public final class ReleaseClient: ReleaseControlling, @unchecked Sendable {
    private let lane: Lane

    public init(socket: any HelperSocket) {
        lane = Lane(socket: socket)
    }

    public static func connectedToReleaseSocket(
        path: String = SeguePaths.releaseSocketPath
    ) -> ReleaseClient {
        ReleaseClient(socket: UnixHelperSocket(path: path))
    }

    public func restore() async throws -> ReleaseReport {
        try await lane.roundTrip(ReleaseEnvelope.restore())
    }

    private actor Lane {
        private let socket: any HelperSocket

        init(socket: any HelperSocket) {
            self.socket = socket
        }

        func roundTrip(_ envelope: ReleaseEnvelope) async throws -> ReleaseReport {
            let request = try JSONEncoder().encode(envelope)
            let replyData: Data
            do {
                replyData = try await socket.transact(request)
            } catch {
                throw ReleaseClient.mapTransport(error)
            }
            let reply: ReleaseEnvelope
            do {
                reply = try JSONDecoder().decode(ReleaseEnvelope.self, from: replyData)
            } catch let error as ReleaseProtocolError {
                throw ReleaseClient.map(error)
            } catch {
                throw ReleaseClientError.malformed
            }
            return try ReleaseClient.report(from: reply)
        }
    }

    private static func report(from reply: ReleaseEnvelope) throws -> ReleaseReport {
        switch reply.kind {
        case .report:
            guard let report = reply.report else {
                throw ReleaseClientError.malformed
            }
            return report
        case .error:
            let code = reply.error?.code ?? ""
            if code == ReleaseErrorCode.unauthorized {
                throw ReleaseClientError.unauthorized
            }
            if code == ReleaseErrorCode.unsupportedVersion {
                throw ReleaseClientError.versionMismatch(nil)
            }
            if code == ReleaseErrorCode.malformed {
                throw ReleaseClientError.malformed
            }
            throw ReleaseClientError.rejected(code: code)
        case .restore:
            throw ReleaseClientError.malformed
        }
    }

    private static func mapTransport(_ failure: Error) -> ReleaseClientError {
        if let failure = failure as? HelperSocketFailure {
            switch failure {
            case .notInstalled:
                return .notInstalled
            case .accessDenied:
                return .unauthorized
            case .closed, .timedOut, .failed:
                return .transport
            }
        }
        return .transport
    }

    private static func map(_ error: ReleaseProtocolError) -> ReleaseClientError {
        switch error {
        case let .unsupportedVersion(version):
            return .versionMismatch(version)
        case .malformed:
            return .malformed
        }
    }
}
