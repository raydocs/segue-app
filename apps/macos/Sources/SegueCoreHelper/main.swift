import Darwin
import Foundation
import SegueHelperCore

do {
    try runHelper()
} catch {
    FileHandle.standardError.write(Data("segue-core-helper: \(error)\n".utf8))
    exit(1)
}

/// Root helper. It listens, checks the peer, stores arm intent, and installs
/// or releases the narrow AI layer. It does not start `segue-kernel`.
private func runHelper() throws {
    let paths = HelperPaths.parse(CommandLine.arguments)
    let uidText = (try? String(contentsOfFile: paths.allowedUIDFile, encoding: .utf8)) ?? ""
    let uids = parseAllowedUIDs(uidText)
    if uids.isEmpty {
        FileHandle.standardError.write(Data(
            "segue-core-helper: no allowed uids; denying every peer\n".utf8
        ))
    }
    let peers = try DarwinPeerCredentials(requirement: SegueCodeSigning.requirement)
    let policy = PeerPolicy(allowedUIDs: uids, requirement: SegueCodeSigning.requirement)
    let supervisor = KernelSupervisor(
        kernelPath: paths.kernelPath,
        configPath: paths.configPath,
        stateDir: paths.stateDir,
        launcher: FoundationProcessLauncher()
    )
    let session = HelperSession(
        store: IntentStore(fileURL: URL(fileURLWithPath: paths.intentPath)),
        kernel: supervisor,
        layer: AILayerController.live(kernel: supervisor, paths: paths)
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
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o755))]
    )
    try server.start()
    FileHandle.standardError.write(Data("segue-core-helper: listening \(paths.socketPath)\n".utf8))

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
