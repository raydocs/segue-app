import Foundation

/// The helper did not answer Restore network within the model's timeout.
/// Distinct from `HelperClientError.transport` so a slow helper and a dead
/// socket can be told apart in logs and tests.
enum RestoreFallbackError: Error, Equatable {
    case helperTimedOut
}

/// Races an async operation against a deadline. The loser is never awaited
/// and never cancelled: an escape hatch must not hang waiting for the very
/// helper it is escaping. Operations must therefore self-bound — the helper
/// client's socket timeouts do that in production, and fakes in tests sleep
/// out their own deadline.
enum RestoreRace {
    static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let box = FinishBox<T>(continuation)
            Task.detached(priority: .userInitiated) {
                do {
                    box.resume(returning: try await operation())
                } catch {
                    box.resume(throwing: error)
                }
            }
            Task.detached(priority: .userInitiated) {
                let nanos = UInt64((max(0, seconds) * 1_000_000_000).rounded(.down))
                try? await Task.sleep(nanoseconds: nanos)
                box.resume(throwing: RestoreFallbackError.helperTimedOut)
            }
        }
    }

    /// Resumes the continuation exactly once, whatever the two tasks do.
    private final class FinishBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var finished = false

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func resume(returning value: T) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            continuation?.resume(returning: value)
            continuation = nil
        }

        func resume(throwing error: Error) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
