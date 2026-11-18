import Darwin
import Foundation
import SegueHelperCore

do {
    try runHelper()
} catch {
    FileHandle.standardError.write(Data("segue-core-helper: \(error)\n".utf8))
    exit(1)
}

/// Root helper. It listens, checks the peer, stores arm intent, installs
/// or releases the narrow AI layer, and runs `segue-kernel` as a child.
private func runHelper() throws {
    let paths = HelperPaths.parse(CommandLine.arguments)
    let uidText = (try? String(contentsOfFile: paths.allowedUIDFile, encoding: .utf8)) ?? ""
    let uids = parseAllowedUIDs(uidText)
    if uids.isEmpty {
        FileHandle.standardError.write(Data(
            "segue-core-helper: no allowed uids; denying every peer\n".utf8
        ))
    }
    // Default is the Developer ID requirement. `--requirement` is how a dev
    // run and the throwaway VM matrix admit a peer that is not that identity.
    let requirement = paths.requirement.isEmpty ? SegueCodeSigning.requirement : paths.requirement
    let peers = try DarwinPeerCredentials(requirement: requirement)
    let policy = PeerPolicy(allowedUIDs: uids, requirement: requirement)
    let control = LiveKernelControlClient(tokenFilePath: paths.controlTokenPath)
    let supervisor = KernelSupervisor(
        kernelPath: paths.kernelPath,
        configPath: paths.configPath,
        stateDir: paths.stateDir,
        launcher: FoundationProcessLauncher(),
        logPath: paths.kernelLogPath,
        control: control
    )
    let session = HelperSession(
        store: IntentStore(fileURL: URL(fileURLWithPath: paths.intentPath)),
        kernel: supervisor,
        layer: AILayerController.live(kernel: supervisor, paths: paths),
        control: control,
        reconcileOnInit: false
    )
    let server = HelperSocketServer(
        path: paths.socketPath,
        session: session,
        peers: peers,
        policy: policy
    )
    let socketDir = URL(fileURLWithPath: paths.socketPath).deletingLastPathComponent()
    try FileManager.default.createDirectory(
        at: socketDir,
        withIntermediateDirectories: true
    )
    try server.start()
    FileHandle.standardError.write(Data(
        "segue-core-helper: listening \(paths.socketPath) guard \(paths.guardPort)\n".utf8
    ))
    // Socket is up before the anchor load. Reconcile can spend seconds in
    // pfctl; the matrix used to probe during that window and record a missing socket.
    session.reconcileArmedIntent()
    // An intent written after bootstrap (the matrix does this) is picked
    // up here. Restarting the helper to notice it SIGTERMs the kernel.
    session.startIntentWatch()

    signal(SIGPIPE, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let shutdown = {
        server.stop()
        supervisor.stop()
        exit(0)
    }
    term.setEventHandler(handler: shutdown)
    interrupt.setEventHandler(handler: shutdown)
    term.resume()
    interrupt.resume()
    dispatchMain()
}
