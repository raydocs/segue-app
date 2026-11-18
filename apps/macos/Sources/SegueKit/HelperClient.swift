import Foundation

/// Failures the menu can show without quoting the helper's own text.
public enum HelperClientError: Error, Equatable {
    case notInstalled
    case versionMismatch(Int?)
    case unauthorized
    case malformed
    case rejected(code: String)
    case transport
}

/// What `ConnectionModel` asks the helper. `HelperClient` is the socket
/// implementation; tests substitute a fake.
public protocol HelperControlling: Sendable {
    func readStatus() async throws -> HelperStatus
    func arm(_ intent: ArmIntent) async throws -> HelperStatus
    func disarm(_ intent: DisarmIntent) async throws -> HelperStatus
}

/// Arm body for an explicit Connect. The helper owns the kernel JSON; the
/// menu only names the intent.
public enum HelperRequests {
    public static func userConnect(generation: UInt64) -> ArmIntent {
        ArmIntent(
            generation: generation,
            anchorRevision: 0,
            manifestDigest: "",
            egress: [],
            exitIfaces: [],
            strict: false,
            evidence: ArmEvidence(policyVersion: nil, posture: "connecting")
        )
    }
}

/// Versioned JSON lines to the helper socket. One transaction is in flight.
public final class HelperClient: HelperControlling, @unchecked Sendable {
    private let lane: Lane

    public init(socket: any HelperSocket) {
        lane = Lane(socket: socket)
    }

    public static func connectedToHelperSocket(
        path: String = SeguePaths.helperSocketPath
    ) -> HelperClient {
        HelperClient(socket: UnixHelperSocket(path: path))
    }

    public func readStatus() async throws -> HelperStatus {
        try await lane.roundTrip(HelperEnvelope.statusRead())
    }

    public func arm(_ intent: ArmIntent) async throws -> HelperStatus {
        try await lane.roundTrip(try HelperEnvelope.arm(intent))
    }

    public func disarm(_ intent: DisarmIntent) async throws -> HelperStatus {
        try await lane.roundTrip(try HelperEnvelope.disarm(intent))
    }

    private actor Lane {
        private let socket: any HelperSocket

        init(socket: any HelperSocket) {
            self.socket = socket
        }

        func roundTrip(_ envelope: HelperEnvelope) async throws -> HelperStatus {
            let request = try JSONEncoder().encode(envelope)
            let replyData: Data
            do {
                replyData = try await socket.transact(request)
            } catch let failure as HelperSocketFailure {
                throw HelperClient.map(failure)
            } catch {
                throw HelperClientError.transport
            }
            let reply: HelperEnvelope
            do {
                reply = try JSONDecoder().decode(HelperEnvelope.self, from: replyData)
            } catch let error as HelperProtocolError {
                throw HelperClient.map(error)
            } catch {
                throw HelperClientError.malformed
            }
            return try HelperClient.status(from: reply)
        }
    }

    private static func status(from reply: HelperEnvelope) throws -> HelperStatus {
        switch reply.kind {
        case .status:
            guard let status = reply.status else {
                throw HelperClientError.malformed
            }
            return status
        case .error:
            let code = reply.error?.code ?? ""
            if code == HelperErrorCode.unauthorized {
                throw HelperClientError.unauthorized
            }
            if code == HelperErrorCode.unsupportedVersion {
                throw HelperClientError.versionMismatch(nil)
            }
            if code == HelperErrorCode.malformed {
                throw HelperClientError.malformed
            }
            throw HelperClientError.rejected(code: code)
        case .arm, .disarm, .statusRead:
            throw HelperClientError.malformed
        }
    }

    private static func map(_ failure: HelperSocketFailure) -> HelperClientError {
        switch failure {
        case .notInstalled:
            return .notInstalled
        case .accessDenied:
            return .unauthorized
        case .closed, .timedOut, .failed:
            return .transport
        }
    }

    private static func map(_ error: HelperProtocolError) -> HelperClientError {
        switch error {
        case let .unsupportedVersion(version):
            return .versionMismatch(version)
        case .malformed:
            return .malformed
        }
    }
}
