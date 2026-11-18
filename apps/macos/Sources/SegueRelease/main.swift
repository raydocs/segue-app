import Darwin
import Foundation
import SegueHelperCore
import SegueReleaseCore

do {
    try runReleaseDaemon()
} catch {
    FileHandle.standardError.write(Data("segue-release: \(error)\n".utf8))
    exit(1)
}

/// Root release daemon, the escape hatch of `docs/design/macos.md` §3. It
/// listens on its own socket, checks the peer the same way the helper does,
/// and answers `restore` by clearing the anchor, the marked resolver files,
/// the DNS snapshot, and the arm intent. It never talks to the helper, so a
/// stuck helper cannot delay it.
private func runReleaseDaemon() throws {
    let paths = ReleasePaths.parse(CommandLine.arguments)
    let uidText = (try? String(contentsOfFile: paths.allowedUIDFile, encoding: .utf8)) ?? ""
    let uids = parseAllowedUIDs(uidText)
    if uids.isEmpty {
        FileHandle.standardError.write(Data(
            "segue-release: no allowed uids; denying every peer\n".utf8
        ))
    }
    let peers = try DarwinPeerCredentials(requirement: SegueCodeSigning.requirement)
    let policy = PeerPolicy(allowedUIDs: uids, requirement: SegueCodeSigning.requirement)
    let restorer = ReleaseRestorer.live(paths: paths)
    let server = ReleaseSocketServer(
        path: paths.socketPath,
        session: ReleaseSession(restorer: restorer),
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
    FileHandle.standardError.write(Data("segue-release: listening \(paths.socketPath)\n".utf8))

    signal(SIGPIPE, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let shutdown = {
        server.stop()
        exit(0)
    }
    term.setEventHandler(handler: shutdown)
    interrupt.setEventHandler(handler: shutdown)
    term.resume()
    interrupt.resume()
    dispatchMain()
}
