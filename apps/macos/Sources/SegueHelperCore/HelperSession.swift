import Foundation
import SegueHelperProtocol

/// Arm, disarm, and status for one helper.
///
/// Arm persists intent, then asks the AI layer to install. A failed install
/// keeps the intent and reports `last_error`; it does not roll the bit back
/// and it does not start the kernel. Disarm persists the clear bit, then
/// releases the layer. Status while armed converges to the kernel: a dead
/// tunnel switches to the guard and does not release the layer. A clear
/// intent on start installs nothing, even if rule files are still around.
public final class HelperSession {
    private let store: IntentStore
    private let kernel: KernelSupervising
    private let layer: AILayerController
    private let lock = NSLock()
    private var intent: StoredIntent
    private var layerError: String?

    /// `reconcileOnInit` is false for the real daemon: it binds the socket
    /// first, then calls `reconcileArmedIntent`. Otherwise a slow (or
    /// failing) anchor load keeps the socket absent for the whole arm.
    public init(
        store: IntentStore,
        kernel: KernelSupervising,
        layer: AILayerController,
        reconcileOnInit: Bool = true
    ) {
        self.store = store
        self.kernel = kernel
        self.layer = layer
        intent = (try? store.load()) ?? .disarmed
        if reconcileOnInit, intent.armed {
            converge { try layer.reconcileOnLaunch() }
        }
    }

    /// Armed intent re-installs the narrow layer. A clear intent does nothing.
    public func reconcileArmedIntent() {
        guard isArmed() else { return }
        converge { try layer.reconcileOnLaunch() }
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
            converge { try layer.arm() }
        case .disarm:
            guard let disarm = envelope.disarm else { throw HelperProtocolError.malformed }
            try remember(StoredIntent(
                armed: false,
                generation: disarm.generation,
                name: disarm.intent.rawValue
            ))
            converge { try layer.disarm() }
        case .statusRead:
            if isArmed() {
                converge { try layer.kernelChanged() }
            }
        case .status, .error:
            throw HelperProtocolError.malformed
        }
        return HelperEnvelope.status(currentStatus())
    }

    private func converge(_ body: () throws -> Void) {
        do {
            try body()
            setLayerError(nil)
        } catch {
            setLayerError(AILayerError.code(of: error))
        }
    }

    private func remember(_ updated: StoredIntent) throws {
        try store.save(updated)
        lock.lock()
        intent = updated
        lock.unlock()
    }

    private func isArmed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return intent.armed
    }

    private func setLayerError(_ message: String?) {
        lock.lock()
        layerError = message
        lock.unlock()
    }

    private func currentStatus() -> HelperStatus {
        lock.lock()
        let intent = self.intent
        let layerError = self.layerError
        lock.unlock()
        let kernelSnap = kernel.snapshot()
        let observed = (try? layer.observe()) ?? .unknown
        let lastError = layerError ?? (kernelSnap.state == "kernel_failed" ? "kernel_failed" : nil)
        let held = intent.armed && (observed.anchorLoaded || observed.namesHeld)
        return HelperStatus(
            armed: intent.armed,
            generation: intent.generation,
            held: held,
            tunInterface: kernelSnap.tunInterface,
            rulesDigest: "",
            evidence: StatusEvidence(tcpProofMs: nil, dnsReadback: observed.dnsReadback),
            lastError: lastError,
            aiLayer: observed.dnsMode,
            helper: HelperProcessReport(state: "running"),
            kernel: KernelReport(state: kernelSnap.state, pid: kernelSnap.pid, lastExit: kernelSnap.lastExit),
            anchorLoaded: observed.anchorLoaded,
            resolverFilesPresent: observed.resolverFilesPresent,
            guardListening: observed.guardListening,
            dnsMode: observed.dnsMode
        )
    }
}
