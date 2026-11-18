import Foundation
import SegueHelperProtocol

/// Arm, disarm, and status for one helper.
///
/// Arm and disarm are persisted and answered. They do not start the kernel,
/// install a packet filter, or write a resolver file. The reply says
/// `ai_layer` is not implemented so a caller cannot mistake stage 0 for
/// protection. A corrupt intent file comes back disarmed rather than armed.
public final class HelperSession {
    private let store: IntentStore
    private let kernel: KernelSupervising
    private let lock = NSLock()
    private var intent: StoredIntent

    public init(store: IntentStore, kernel: KernelSupervising) {
        self.store = store
        self.kernel = kernel
        intent = (try? store.load()) ?? .disarmed
    }

    public func handle(_ envelope: HelperEnvelope) throws -> HelperEnvelope {
        switch envelope.kind {
        case .arm:
            guard let arm = envelope.arm else { throw HelperProtocolError.malformed }
            try remember(StoredIntent(
                armed: true,
                generation: arm.generation,
                name: arm.intent.rawValue
            ))
        case .disarm:
            guard let disarm = envelope.disarm else { throw HelperProtocolError.malformed }
            try remember(StoredIntent(
                armed: false,
                generation: disarm.generation,
                name: disarm.intent.rawValue
            ))
        case .statusRead:
            break
        case .status, .error:
            throw HelperProtocolError.malformed
        }
        return HelperEnvelope.status(currentStatus())
    }

    private func remember(_ updated: StoredIntent) throws {
        try store.save(updated)
        lock.lock()
        intent = updated
        lock.unlock()
    }

    private func currentStatus() -> HelperStatus {
        lock.lock()
        let intent = self.intent
        lock.unlock()
        let kernel = kernel.snapshot()
        return HelperStatus(
            armed: intent.armed,
            generation: intent.generation,
            held: false,
            tunInterface: nil,
            rulesDigest: "",
            evidence: StatusEvidence(tcpProofMs: nil, dnsReadback: false),
            lastError: kernel.state == "kernel_failed" ? "kernel_failed" : nil,
            aiLayer: AILayerState.notImplemented,
            helper: HelperProcessReport(state: "running"),
            kernel: KernelReport(state: kernel.state, pid: kernel.pid, lastExit: kernel.lastExit)
        )
    }
}
