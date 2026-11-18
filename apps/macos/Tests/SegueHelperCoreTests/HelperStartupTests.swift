import Darwin
import Foundation
import Security
import XCTest

@testable import SegueHelperCore

/// Runs the built `segue-core-helper` with every path under a temp directory
/// and a guard port above 1024. No root, no launchd, no PF.
final class HelperStartupTests: XCTestCase {
    func testDevHelperAnswersStatusAndArmedGuard() throws {
        guard let binary = Self.builtHelper() else {
            XCTFail("segue-core-helper was not built; run swift build before swift test")
            return
        }
        let requirement = try XCTUnwrap(
            Self.ownRequirement(),
            "this process has no designated requirement to admit itself"
        )
        // sockaddr_un is 104 bytes. NSTemporaryDirectory() plus a UUID does not fit.
        let root = URL(fileURLWithPath: "/tmp/segue-hs-\(UInt32.random(in: 0...UInt32.max))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suffix = "ailock-fixture.example.com"
        try Data("\(getuid())\n".utf8).write(to: root.appendingPathComponent("allowed-uid"))
        try Data("suffix \(suffix)\n".utf8).write(to: root.appendingPathComponent("ai-lock.txt"))
        try Data(
            "{\"armed\":true,\"generation\":1,\"name\":\"user_connect\"}\n".utf8
        ).write(to: root.appendingPathComponent("ai-lock.intent"))

        let port: UInt16 = 35354
        let socket = root.appendingPathComponent("run/service.sock").path
        let errURL = root.appendingPathComponent("helper.err")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let errHandle = try FileHandle(forWritingTo: errURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "--paths-root", root.path,
            "--guard-port", String(port),
            "--requirement", requirement,
        ]
        process.standardError = errHandle
        process.standardOutput = errHandle
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            try? errHandle.close()
        }

        let appeared = Self.waitUntil(seconds: 8) {
            FileManager.default.fileExists(atPath: socket) || !process.isRunning
        }
        XCTAssertTrue(appeared)
        let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        guard FileManager.default.fileExists(atPath: socket) else {
            XCTFail("socket missing; helper stderr:\n\(stderr)")
            return
        }

        let status = try Self.roundTrip(socket: socket, line: #"{"version":1,"kind":"status_read"}"#)
        XCTAssertTrue(status.contains("\"armed\":true"), status)

        for qtype in [UInt16(1), UInt16(28)] {
            let reply = try Self.queryGuard(port: port, name: "www.\(suffix)", qtype: qtype)
            XCTAssertEqual(reply.rcode, 0, "qtype \(qtype) stderr:\n\(stderr)")
            XCTAssertEqual(reply.ancount, 0, "qtype \(qtype)")
        }
    }

    private static func builtHelper() -> String? {
        if let env = ProcessInfo.processInfo.environment["SEGUE_HELPER_BIN"],
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        let here = URL(fileURLWithPath: #filePath)
        let macos = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            macos.appendingPathComponent(".build/debug/segue-core-helper").path,
            macos.appendingPathComponent(".build/release/segue-core-helper").path,
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func ownRequirement() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &code) == errSecSuccess, let code else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, SecCSFlags(rawValue: 0), &requirement) == errSecSuccess,
              let requirement
        else {
            return nil
        }
        var text: CFString?
        guard SecRequirementCopyString(requirement, SecCSFlags(rawValue: 0), &text) == errSecSuccess,
              let text
        else {
            return nil
        }
        return text as String
    }

    private static func waitUntil(seconds: TimeInterval, _ body: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if body() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return body()
    }

    private static func roundTrip(socket: String, line: String, timeout: Int = 3) throws -> String {
        let fd = try unixSocket()
        defer { _ = Darwin.close(fd) }
        try connectUnixSocket(fd: fd, path: socket)
        setReceiveTimeout(fd, seconds: timeout)
        try LineIO.writeLine(fd: fd, payload: Data(line.utf8))
        let data = try XCTUnwrap(try LineIO.readLine(fd: fd))
        return String(decoding: data, as: UTF8.self)
    }

    /// A real helper, a fake kernel. The kernel writes `control.json` only
    /// after a delay and stays `disconnected` with no utun until
    /// `POST /v1/connect`. Killing it (SIGKILL, so the supervisor restarts
    /// it) binds a new port and a new token. The helper must reach
    /// `tun_interface=utun9` both times — which it cannot do if connect is
    /// fired once before the token file exists, or if the token is cached.
    func testFakeKernelArmConnectsAcrossRestart() throws {
        guard let binary = Self.builtHelper() else {
            XCTFail("segue-core-helper was not built; run swift build before swift test")
            return
        }
        let requirement = try XCTUnwrap(
            Self.ownRequirement(),
            "this process has no designated requirement to admit itself"
        )
        let root = URL(fileURLWithPath: "/tmp/segue-ka-\(UInt32.random(in: 0...UInt32.max))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let kernelDir = root.appendingPathComponent("kernel")
        let binDir = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: kernelDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let script = binDir.appendingPathComponent("segue-kernel")
        try Data(Self.fakeKernelScript.utf8).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: script.path
        )
        let config: [String: Any] = ["dns": ["listen": "127.0.0.1:53"]]
        try JSONSerialization.data(withJSONObject: config).write(to: root.appendingPathComponent("kernel.json"))
        try Data("\(getuid())\n".utf8).write(to: root.appendingPathComponent("allowed-uid"))
        try Data("suffix arm-fixture.example\n".utf8).write(to: root.appendingPathComponent("ai-lock.txt"))

        let port = Self.freeUDPPort()
        let socket = root.appendingPathComponent("run/service.sock").path
        let errURL = root.appendingPathComponent("helper.err")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let errHandle = try FileHandle(forWritingTo: errURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "--paths-root", root.path,
            "--kernel", script.path,
            "--guard-port", String(port),
            "--requirement", requirement,
        ]
        var env = ProcessInfo.processInfo.environment
        env["SEGUE_FAKE_KERNEL_DELAY"] = "0.8"
        process.environment = env
        process.standardError = errHandle
        process.standardOutput = errHandle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            try? errHandle.close()
        }

        let appeared = Self.waitUntil(seconds: 8) {
            FileManager.default.fileExists(atPath: socket) || !process.isRunning
        }
        XCTAssertTrue(appeared)
        guard FileManager.default.fileExists(atPath: socket), process.isRunning else {
            XCTFail("socket missing; helper stderr:\n\(Self.textFile(errURL))\nfake:\n\(Self.textFile(kernelDir.appendingPathComponent("fake.log")))")
            return
        }

        // Armed only after the helper is listening, so the intent watch
        // (not startup reconcile) is what starts the kernel.
        let intent = "{\"armed\":true,\"generation\":1,\"name\":\"user_connect\"}\n"
        try Data(intent.utf8).write(to: root.appendingPathComponent("ai-lock.intent"))

        let first = try Self.waitForTun(socket: socket, seconds: 20)
        if first == nil {
            XCTFail("helper did not report utun9; stderr:\n\(Self.textFile(errURL))\nfake:\n\(Self.textFile(kernelDir.appendingPathComponent("fake.log")))\nconnects:\n\(Self.textFile(kernelDir.appendingPathComponent("connects.log")))\nlast:\n\(Self.lastStatus)")
            return
        }
        let firstInstances = Self.connectInstances(kernelDir.appendingPathComponent("connects.log"))
        XCTAssertEqual(firstInstances.count, 1, "connect should hit the first control port: \(firstInstances)")

        let killed = Darwin.kill(pid_t(first?.pid ?? -1), SIGKILL)
        XCTAssertEqual(killed, 0, "SIGKILL kernel pid \(first?.pid ?? -1)")

        let second = try Self.waitForTun(socket: socket, seconds: 20) { status in
            guard let pid = Self.kernelPID(status), pid != first?.pid else { return false }
            let instances = Self.connectInstances(kernelDir.appendingPathComponent("connects.log"))
            return instances.count >= 2
        }
        if second == nil {
            XCTFail("helper did not reconnect after restart; stderr:\n\(Self.textFile(errURL))\nfake:\n\(Self.textFile(kernelDir.appendingPathComponent("fake.log")))\nconnects:\n\(Self.textFile(kernelDir.appendingPathComponent("connects.log")))\nlast:\n\(Self.lastStatus)")
            return
        }
        XCTAssertNotEqual(second?.pid, first?.pid)
        XCTAssertGreaterThanOrEqual(
            Self.connectInstances(kernelDir.appendingPathComponent("connects.log")).count,
            2
        )
    }

    /// The matrix starts the helper, then writes `ai-lock.fixture.txt`, then
    /// arms on the socket. The anchor text, the resolver file, and the guard
    /// must follow that file: tunnel while the fake kernel is connected,
    /// guard after it is killed. `ai_layer` is never `degraded`.
    func testMatrixFixtureArmsTunnelThenGuard() throws {
        guard let binary = Self.builtHelper() else {
            XCTFail("segue-core-helper was not built; run swift build before swift test")
            return
        }
        let requirement = try XCTUnwrap(
            Self.ownRequirement(),
            "this process has no designated requirement to admit itself"
        )
        let root = URL(fileURLWithPath: "/tmp/segue-r5-\(UInt32.random(in: 0...UInt32.max))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let kernelDir = root.appendingPathComponent("kernel")
        let binDir = root.appendingPathComponent("bin")
        let pfDir = root.appendingPathComponent("pfctl")
        try FileManager.default.createDirectory(at: kernelDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pfDir, withIntermediateDirectories: true)
        let script = binDir.appendingPathComponent("segue-kernel")
        try Data(Self.fakeKernelScript.utf8).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: script.path
        )
        let pfctl = binDir.appendingPathComponent("pfctl")
        try Data(Self.fakePfctlScript.utf8).write(to: pfctl)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: pfctl.path
        )
        let kernelDNS = "127.0.0.1:15353"
        let config: [String: Any] = ["dns": ["listen": kernelDNS]]
        try JSONSerialization.data(withJSONObject: config).write(to: root.appendingPathComponent("kernel.json"))
        try Data("\(getuid())\n".utf8).write(to: root.appendingPathComponent("allowed-uid"))

        let port = Self.freeUDPPort()
        XCTAssertNotEqual(port, 15353)
        let socket = root.appendingPathComponent("run/service.sock").path
        let listURL = root.appendingPathComponent("ai-lock.fixture.txt")
        let resolverFile = root.appendingPathComponent("etc/resolver/ailock-fixture.example.com")
        let errURL = root.appendingPathComponent("helper.err")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let errHandle = try FileHandle(forWritingTo: errURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "--paths-root", root.path,
            "--ai-lock", listURL.path,
            "--kernel", script.path,
            "--guard-port", String(port),
            "--pfctl", pfctl.path,
            "--requirement", requirement,
        ]
        var env = ProcessInfo.processInfo.environment
        env["SEGUE_FAKE_KERNEL_DELAY"] = "0.3"
        env["SEGUE_FAKE_PFCTL_DIR"] = pfDir.path
        process.environment = env
        process.standardError = errHandle
        process.standardOutput = errHandle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            try? errHandle.close()
        }

        let appeared = Self.waitUntil(seconds: 8) {
            FileManager.default.fileExists(atPath: socket) || !process.isRunning
        }
        XCTAssertTrue(appeared)
        guard FileManager.default.fileExists(atPath: socket), process.isRunning else {
            XCTFail("socket missing; helper stderr:\n\(Self.textFile(errURL))")
            return
        }

        // The matrix copies this file after launchd has already started the
        // helper. On current main the list was read once at startup and
        // stayed empty.
        try Data(Self.matrixFixture.utf8).write(to: listURL)
        _ = try Self.roundTrip(socket: socket, line: Self.armLine, timeout: 10)

        var degraded: String?
        var tunnelLine = ""
        let tunnel = Self.waitUntil(seconds: 20) {
            let line: String
            do {
                line = try Self.roundTrip(socket: socket, line: #"{"version":1,"kind":"status_read"}"#, timeout: 10)
            } catch {
                return false
            }
            guard let status = Self.statusBody(line) else { return false }
            if status["ai_layer"] as? String == "degraded" {
                degraded = line
                return true
            }
            let file = Self.textFile(resolverFile)
            let rules = Self.textFile(pfDir.appendingPathComponent("anchor.rules"))
            let ready = status["ai_layer"] as? String == "tunnel"
                && status["dns_mode"] as? String == "kernel"
                && status["tun_interface"] as? String == "utun9"
                && file.contains("port 15353")
                && file.contains("nameserver 127.0.0.1")
                && rules.contains("block drop out quick inet to 198.51.100.0/24")
            if ready { tunnelLine = line }
            return ready
        }
        if degraded != nil || !tunnel {
            XCTFail(
                "expected tunnel, never degraded; degraded=\(degraded ?? "nil") last=\(tunnelLine) stderr:\n\(Self.textFile(errURL))\npfctl:\n\(Self.textFile(pfDir.appendingPathComponent("calls.log")))\nresolver:\n\(Self.textFile(resolverFile))\nfake:\n\(Self.textFile(kernelDir.appendingPathComponent("fake.log")))"
            )
            return
        }
        XCTAssertNil(Self.statusBody(tunnelLine)?["ai_list_error"])
        let resolverDir = resolverFile.deletingLastPathComponent().path
        let attrs = try FileManager.default.attributesOfItem(atPath: resolverDir)
        let mode = try XCTUnwrap(attrs[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue, 0o755)
        for qtype in [UInt16(1), UInt16(28)] {
            let reply = try Self.queryGuard(port: port, name: "www.ailock-fixture.example.com", qtype: qtype)
            XCTAssertEqual(reply.rcode, 0, "qtype \(qtype)")
            XCTAssertEqual(reply.ancount, 0, "qtype \(qtype)")
        }

        try Data(Self.sleepingKernelScript.utf8).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: script.path
        )
        let kernelPID = try XCTUnwrap(Self.kernelPID(Self.statusBody(tunnelLine) ?? [:]))
        XCTAssertEqual(Darwin.kill(pid_t(kernelPID), SIGKILL), 0, "SIGKILL kernel pid \(kernelPID)")

        degraded = nil
        var guardLine = ""
        let held = Self.waitUntil(seconds: 20) {
            let line: String
            do {
                line = try Self.roundTrip(socket: socket, line: #"{"version":1,"kind":"status_read"}"#, timeout: 10)
            } catch {
                return false
            }
            guard let status = Self.statusBody(line) else { return false }
            if status["ai_layer"] as? String == "degraded" {
                degraded = line
                return true
            }
            let file = Self.textFile(resolverFile)
            let ready = status["ai_layer"] as? String == "guard"
                && status["dns_mode"] as? String == "guard"
                && file.contains("port \(port)")
                && !file.contains("port 15353")
            if ready { guardLine = line }
            return ready
        }
        if degraded != nil || !held {
            XCTFail(
                "expected guard after kill, never degraded; degraded=\(degraded ?? "nil") last=\(guardLine) stderr:\n\(Self.textFile(errURL))\nresolver:\n\(Self.textFile(resolverFile))\nfake:\n\(Self.textFile(kernelDir.appendingPathComponent("fake.log")))"
            )
            return
        }
        let rules = Self.textFile(pfDir.appendingPathComponent("anchor.rules"))
        XCTAssertTrue(rules.contains("198.51.100.0/24"), rules)
    }

    private static var lastStatus = ""

    /// `status_read` until `tun_interface` is utun9 and the kernel pid is set.
    /// `ready` can demand a new pid or a second connect.
    private static func waitForTun(
        socket: String,
        seconds: TimeInterval,
        ready: (([String: Any]) -> Bool)? = nil
    ) throws -> (pid: Int, status: [String: Any])? {
        var found: (pid: Int, status: [String: Any])?
        let ok = waitUntil(seconds: seconds) {
            let line: String
            do {
                line = try roundTrip(socket: socket, line: #"{"version":1,"kind":"status_read"}"#, timeout: 10)
            } catch {
                lastStatus = "roundTrip \(error)"
                return false
            }
            lastStatus = line
            guard let status = statusBody(line),
                  status["tun_interface"] as? String == "utun9",
                  let pid = kernelPID(status)
            else { return false }
            if let ready, !ready(status) { return false }
            found = (pid, status)
            return true
        }
        return ok ? found : nil
    }

    private static func statusBody(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["status"] as? [String: Any]
    }

    private static func kernelPID(_ status: [String: Any]) -> Int? {
        guard let kernel = status["kernel"] as? [String: Any] else { return nil }
        if let pid = kernel["pid"] as? Int, pid > 0 { return pid }
        if let pid = kernel["pid"] as? NSNumber, pid.intValue > 0 { return pid.intValue }
        return nil
    }

    /// One line per accepted `POST /v1/connect`: `<instance> <port>`.
    private static func connectInstances(_ url: URL) -> Set<String> {
        let text = textFile(url)
        var ids = Set<String>()
        for line in text.split(separator: "\n") {
            let id = line.split(separator: " ").first.map(String.init) ?? ""
            if !id.isEmpty { ids.insert(id) }
        }
        return ids
    }

    private static func textFile(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static func freeUDPPort() -> UInt16 {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        if fd < 0 { return 35355 }
        defer { _ = Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 { return 35355 }
        var latest = addr
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &latest) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &length)
            }
        }
        if named != 0 { return 35355 }
        return UInt16(bigEndian: latest.sin_port)
    }

    /// Same text `copy_fixture_list` writes. Comments are the matrix's; the
    /// suffix and CIDR are what the anchor and the guard must arm.
    private static let matrixFixture = """
    # VM matrix fixture. Not the product ai-lock.txt (that file is not modified).
    # The kernel merges ailock-fixture.example.com and 198.51.100.0/24 from the signed
    # bundle. The helper reads this file because it does not merge a bundle yet.
    suffix ailock-fixture.example.com
    cidr 198.51.100.0/24

    """

    private static let armLine = """
    {"version":1,"kind":"arm","arm":{"schemaVersion":1,"generation":1,"intent":"user_connect","anchor_revision":1,"manifest_digest":"abc","egress":[],"exit_ifaces":[],"strict":false,"evidence":{"posture":"connecting"}}}
    """

    /// Records anchor stdin and answers `-sr` with it. No root, no real PF.
    private static let fakePfctlScript = """
    #!/usr/bin/python3
    import os, sys
    logdir = os.environ.get("SEGUE_FAKE_PFCTL_DIR", "")
    if not logdir:
        sys.stderr.write("no SEGUE_FAKE_PFCTL_DIR\\n")
        sys.exit(2)
    os.makedirs(logdir, exist_ok=True)
    args = sys.argv[1:]
    data = sys.stdin.read()
    rules = os.path.join(logdir, "anchor.rules")
    with open(os.path.join(logdir, "calls.log"), "a") as fh:
        fh.write("%r\\n" % (args,))
        if data:
            fh.write(data)
            if not data.endswith("\\n"):
                fh.write("\\n")
            fh.write("---\\n")
    if args == ["-a", "segue.ailock", "-f", "-"]:
        with open(rules, "w") as fh:
            fh.write(data)
        sys.exit(0)
    if args == ["-a", "segue.ailock", "-sr"]:
        if os.path.exists(rules):
            sys.stdout.write(open(rules).read())
        sys.exit(0)
    if args == ["-a", "segue.ailock", "-F", "all"]:
        try:
            os.remove(rules)
        except OSError:
            pass
        sys.exit(0)
    sys.stderr.write("unexpected %r\\n" % (args,))
    sys.exit(1)
    """

    /// Replacement kernel: stays up, never publishes a carrier, so the
    /// helper has to hold names on the guard port.
    private static let sleepingKernelScript = """
    #!/usr/bin/python3
    import os, sys, time
    args = sys.argv[1:]
    state = None
    i = 0
    while i < len(args):
        if args[i] == "--state-dir" and i + 1 < len(args):
            state = args[i + 1]
            i += 2
            continue
        i += 1
    if state:
        try:
            os.remove(os.path.join(state, "control.json"))
        except OSError:
            pass
    while True:
        time.sleep(30)
    """

    /// Fake `segue-kernel`. Delay, then serve the control API. `state` stays
    /// `disconnected` and `tun.interface` stays null until `POST /v1/connect`.
    /// Each launch binds a new port and appends `<instance> <port>` when that
    /// port accepts connect.
    private static let fakeKernelScript = """
    #!/usr/bin/python3
    import json, os, socket, sys, time
    args = sys.argv[1:]
    state = None
    i = 0
    while i < len(args):
        if args[i] == "--state-dir" and i + 1 < len(args):
            state = args[i + 1]
            i += 2
            continue
        i += 1
    if not state:
        sys.exit(2)
    os.makedirs(state, exist_ok=True)
    instance = os.urandom(4).hex()
    def trace(msg):
        with open(os.path.join(state, "fake.log"), "a") as fh:
            fh.write("%s %s\\n" % (instance, msg))
    trace("start")
    time.sleep(float(os.environ.get("SEGUE_FAKE_KERNEL_DELAY", "0.8")))
    token = os.urandom(8).hex()
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(16)
    host, port = srv.getsockname()
    body = json.dumps({"addr": "%s:%d" % (host, port), "token": token})
    tmp = os.path.join(state, "control.json.tmp")
    final = os.path.join(state, "control.json")
    with open(tmp, "w") as fh:
        fh.write(body)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, final)
    os.chmod(final, 0o600)
    trace("listen %s:%d" % (host, port))
    connected = False
    def status():
        if connected:
            return {"state": "connected", "tun": {"interface": "utun9", "routes": "installed"}}
        return {"state": "disconnected", "tun": {"interface": None, "routes": "absent"}}
    def handle(conn):
        global connected
        data = b""
        conn.settimeout(5)
        while b"\\r\\n\\r\\n" not in data and len(data) < 8192:
            chunk = conn.recv(1024)
            if not chunk:
                break
            data += chunk
        text = data.decode("utf-8", "replace")
        head = text.split("\\r\\n\\r\\n", 1)[0]
        lines = head.split("\\r\\n")
        req = lines[0] if lines else ""
        headers = {}
        for line in lines[1:]:
            if ":" in line:
                key, value = line.split(":", 1)
                headers[key.strip().lower()] = value.strip()
        parts = req.split(" ")
        method = parts[0] if parts else ""
        path = parts[1] if len(parts) > 1 else ""
        auth = headers.get("authorization", "")
        if auth != "Bearer " + token:
            code, payload = 401, {"error": "bad token"}
        elif method == "GET" and path == "/v1/status":
            code, payload = 200, status()
        elif method == "POST" and path == "/v1/connect":
            connected = True
            with open(os.path.join(state, "connects.log"), "a") as fh:
                fh.write("%s %d\\n" % (instance, port))
                fh.flush()
            code, payload = 200, status()
        else:
            code, payload = 404, {"error": "not found"}
        raw = json.dumps(payload).encode("utf-8")
        reason = {200: "OK", 401: "Unauthorized", 404: "Not Found"}.get(code, "Error")
        resp = (
            "HTTP/1.1 %d %s\\r\\nContent-Type: application/json\\r\\nContent-Length: %d\\r\\nConnection: close\\r\\n\\r\\n"
            % (code, reason, len(raw))
        ).encode("utf-8") + raw
        conn.sendall(resp)
        conn.close()
    while True:
        try:
            client, _addr = srv.accept()
        except OSError:
            break
        try:
            handle(client)
        except Exception as exc:
            trace("err %s" % exc)
            try:
                client.close()
            except Exception:
                pass
    """

    private static func queryGuard(port: UInt16, name: String, qtype: UInt16) throws -> (rcode: Int, ancount: Int) {
        let query = dnsQuery(name: name, qtype: qtype)
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { _ = Darwin.close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = port.bigEndian
        dest.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let sent = query.withUnsafeBytes { raw -> Int in
            withUnsafePointer(to: &dest) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.sendto(fd, raw.baseAddress, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        XCTAssertEqual(sent, query.count)
        var buffer = [UInt8](repeating: 0, count: 512)
        let got = Darwin.recvfrom(fd, &buffer, buffer.count, 0, nil, nil)
        XCTAssertGreaterThanOrEqual(got, 12)
        let rcode = Int(buffer[3] & 0x0F)
        let ancount = Int(buffer[6]) << 8 | Int(buffer[7])
        return (rcode, ancount)
    }

    private static func dnsQuery(name: String, qtype: UInt16) -> Data {
        var packet = Data([0xAB, 0xCD, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8)
            packet.append(UInt8(bytes.count))
            packet.append(contentsOf: bytes)
        }
        packet.append(0)
        packet.append(UInt8(qtype >> 8))
        packet.append(UInt8(qtype & 0xFF))
        packet.append(contentsOf: [0x00, 0x01])
        return packet
    }
}
