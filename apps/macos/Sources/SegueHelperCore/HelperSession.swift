import Foundation
import SegueHelperProtocol

/// Arm, disarm, and status for one helper.
///
/// Arm persists intent, asks the AI layer to install the narrow guard,
/// then starts `segue-kernel` (taking over an orphan left by a dead
/// helper first). Resolver files move to the kernel's DNS port only once
/// the control API reports a connected carrier; a poll loop does that
/// without holding the arm reply. A failed install keeps the intent and
/// reports `last_error`; it does not roll the bit back. While armed the
/// status is never `system`: a missed hold is `degraded`.
///
/// Disarm persists the clear bit, releases the layer (legacy per-service
/// DNS restored while the resolver files still hold names, then the files
/// removed, then the anchor flushed), then stops the kernel: SIGTERM,
/// `stopGrace`, SIGKILL.
///
/// A kernel crash restarts inside the supervisor's budget; whenever the
/// kernel goes down while the intent is armed, the layer converges to the
/// guard and is never released. Helper start with armed intent re-installs
/// the narrow layer and starts the kernel again. A clear intent on start
/// installs nothing, even if rule files are still around.
public final class HelperSession {
    private let store: IntentStore
    private let kernel: KernelControlling
    private let layer: AILayerController
    private let control: KernelControlClient?
    private let tunnelTimeout: TimeInterval
    private let pollInterval: TimeInterval
    /// `kernel_pause` is refused unless the daemon was started with
    /// `--requirement` or `--paths-root`. Disarm remains the only way a
    /// production helper stops the kernel, and that path releases the layer.
    private let allowDevVerbs: Bool
    private let lock = NSLock()
    private var intent: StoredIntent
    private var layerError: String?
    private var convergingTunnel = false
    /// Bumped every time a poll is requested, including when one is already
    /// running. The in-flight loop adopts the new generation and extends
    /// its deadline, so a restart that lands a new control port is not
    /// forgotten when the loop later exits.
    private var convergeGeneration: UInt64 = 0
    private var intentWatch: DispatchSourceTimer?

    /// `reconcileOnInit` is false for the real daemon: it binds the socket
    /// first, then calls `reconcileArmedIntent`. Otherwise a slow (or
    /// failing) anchor load keeps the socket absent for the whole arm.
    /// `tunnelTimeout <= 0` disables the background poll loop (unit tests
    /// drive the convergence by hand).
    public init(
        store: IntentStore,
        kernel: KernelControlling,
        layer: AILayerController,
        control: KernelControlClient? = nil,
        reconcileOnInit: Bool = true,
        tunnelTimeout: TimeInterval = 20,
        pollInterval: TimeInterval = 0.25,
        allowDevVerbs: Bool = false
    ) {
        self.store = store
        self.kernel = kernel
        self.layer = layer
        self.control = control
        self.tunnelTimeout = tunnelTimeout
        self.pollInterval = pollInterval
        self.allowDevVerbs = allowDevVerbs
        intent = (try? store.load()) ?? .disarmed
        kernel.onStateChange = { [weak self] in self?.kernelStateChanged() }
        if reconcileOnInit, intent.armed {
            converge { try layer.reconcileOnLaunch() }
            startKernel()
        }
    }

    /// Armed intent re-installs the narrow layer and starts the kernel
    /// again. A clear intent does nothing.
    public func reconcileArmedIntent() {
        guard isArmed() else { return }
        converge { try layer.reconcileOnLaunch() }
        startKernel()
    }

    /// Poll the intent file. The daemon is often started before the file
    /// exists (the matrix writes it after `launchctl bootstrap`); without
    /// this, the only way to notice the arm was to kill and restart the
    /// helper, which SIGTERMs the kernel. A clear intent is not applied
    /// here — a release still goes through the disarm envelope. `interval
    /// <= 0` does not start the poll.
    public func startIntentWatch(interval: TimeInterval = 0.5) {
        guard interval > 0 else { return }
        lock.lock()
        if intentWatch != nil {
            lock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        intentWatch = timer
        lock.unlock()
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.reloadIntentFromDisk()
        }
        timer.resume()
    }

    deinit {
        intentWatch?.cancel()
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
            startKernel()
        case .disarm:
            guard let disarm = envelope.disarm else { throw HelperProtocolError.malformed }
            try remember(StoredIntent(
                armed: false,
                generation: disarm.generation,
                name: disarm.intent.rawValue
            ))
            // Layer first: resolver files removed (and any legacy DNS
            // snapshot restored) before the anchor flushes, then the
            // tunnel it was protecting goes away.
            converge { try layer.disarm() }
            kernel.stop()
        case .kernelPause:
            // Dev verb. `stop` sets the supervisor's stop flag, so this
            // clean exit is not restarted. The layer stays armed and
            // converges to the guard (no utun, resolver on the guard port).
            // Disarm is the wrong tool: it releases the anchor and the files.
            guard allowDevVerbs else {
                return HelperEnvelope.failure(
                    code: HelperErrorCode.unauthorized,
                    message: "kernel_pause requires --requirement or --paths-root"
                )
            }
            kernel.stop()
            if isArmed() {
                convergeTowardTunnel()
            }
        case .statusRead:
            if isArmed() {
                convergeTowardTunnel()
            }
        case .status, .error:
            throw HelperProtocolError.malformed
        }
        return HelperEnvelope.status(currentStatus())
    }

    // MARK: - kernel convergence

    /// Best-effort start (an existing child is left alone; an orphan from
    /// a dead helper is taken over first), one converge now — a kernel
    /// that already answers the control API is switched to immediately —
    /// then the background poll that follows a just-started kernel to
    /// "connected with a utun".
    private func startKernel() {
        try? kernel.start()
        convergeTowardTunnel()
        scheduleTunnelConvergence()
    }

    /// Converge the layer to what the kernel reports right now: resolver
    /// files at the kernel's loopback DNS port while a carrier is connected
    /// and that port is published, the guard port in every other state.
    /// Never called with a clear intent — a release only ever follows the
    /// disarm envelope.
    private func convergeTowardTunnel() {
        guard isArmed() else { return }
        converge { try layer.kernelChanged() }
    }

    /// The start returns before the kernel has a carrier. Poll until
    /// `GET /v1/status` reports a connected carrier with a utun, and
    /// `POST /v1/connect` on every pass that is not there yet. One shot
    /// at the start is not enough: the token file is written after the
    /// kernel binds, so the first call often finds no `control.json`,
    /// and a restart replaces that file with a new port and token. The
    /// control client re-reads the file on every call. The loop gives up
    /// after `tunnelTimeout` (extended when a restart arrives mid-poll)
    /// and leaves the guard in place.
    private func scheduleTunnelConvergence() {
        guard tunnelTimeout > 0 else { return }
        lock.lock()
        convergeGeneration &+= 1
        if convergingTunnel {
            lock.unlock()
            return
        }
        convergingTunnel = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.pollTunnel()
        }
    }

    private func pollTunnel() {
        var deadline = Date().addingTimeInterval(tunnelTimeout)
        var generation = currentConvergeGeneration()
        while Date() < deadline {
            let now = currentConvergeGeneration()
            if now != generation {
                // A restart asked for another poll while this one was
                // in flight. The previous "up" belonged to the dead
                // process; give the new control port a full window.
                generation = now
                deadline = Date().addingTimeInterval(tunnelTimeout)
            }
            let snap = kernel.snapshot()
            // `dnsAddress` is published only for a connected carrier,
            // so both set is the kernel's own "tunnel up".
            if snap.tunInterface != nil, snap.dnsAddress != nil,
               currentConvergeGeneration() == generation {
                break
            }
            control?.connect()
            convergeTowardTunnel()
            Thread.sleep(forTimeInterval: pollInterval)
        }
        lock.lock()
        let missed = convergeGeneration != generation
        convergingTunnel = false
        lock.unlock()
        if missed {
            scheduleTunnelConvergence()
        }
    }

    private func currentConvergeGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return convergeGeneration
    }

    /// An intent file written after start. Armed and different from what
    /// we already applied: persist it (no-op when the bytes match), install
    /// the layer, and start the kernel. `start` leaves a live child alone.
    private func reloadIntentFromDisk() {
        guard let loaded = try? store.load(), loaded.armed else { return }
        lock.lock()
        let previous = intent
        lock.unlock()
        guard loaded != previous else { return }
        do {
            try remember(loaded)
        } catch {
            return
        }
        converge { try layer.arm() }
        startKernel()
    }

    /// The supervisor's exit report: crash, clean stop, or budget
    /// exhaustion. While the intent is armed the layer never releases; it
    /// converges to what the kernel reports now (the guard, while the
    /// kernel is down or coming back) and the poll loop keeps watching a
    /// restarted kernel.
    private func kernelStateChanged() {
        guard isArmed() else { return }
        convergeTowardTunnel()
        scheduleTunnelConvergence()
    }

    // MARK: - state

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
        // Armed and not actually held is degraded, never system. A write
        // that never landed, or an observe that could not run, must not
        // look like ordinary DNS.
        var aiLayer = observed.aiLayer
        var dnsMode = observed.dnsMode
        if intent.armed && (aiLayer == AILayerState.system || dnsMode == AILayerState.system) {
            aiLayer = AILayerState.degraded
            if dnsMode == AILayerState.system {
                dnsMode = AILayerState.guardMode
            }
        }
        return HelperStatus(
            armed: intent.armed,
            generation: intent.generation,
            held: held,
            tunInterface: kernelSnap.tunInterface,
            rulesDigest: "",
            evidence: StatusEvidence(tcpProofMs: nil, dnsReadback: observed.dnsReadback),
            lastError: lastError,
            aiLayer: aiLayer,
            helper: HelperProcessReport(state: "running"),
            kernel: KernelReport(
                state: kernelSnap.state,
                pid: kernelSnap.pid,
                lastExit: kernelSnap.lastExit,
                lastStderr: kernelSnap.lastStderr
            ),
            anchorLoaded: observed.anchorLoaded,
            resolverFilesPresent: observed.resolverFilesPresent,
            guardListening: observed.guardListening,
            dnsMode: dnsMode,
            aiListError: intent.armed ? layer.listError() : nil
        )
    }
}
