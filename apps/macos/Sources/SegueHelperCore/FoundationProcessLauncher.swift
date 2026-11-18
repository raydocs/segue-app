import Darwin
import Foundation

/// Opens a kernel capture file for appending: `kernel.stdout` /
/// `kernel.stderr` in the kernel log dir. Mode 0600, rotated when the
/// current file has reached `rotateBytes` (`path` becomes `path.1`,
/// replacing the previous backup), so one stream costs at most about
/// `rotateBytes * 2` on disk. Rotation happens at open — each launch —
/// because the child writes the fd directly; a supervisor that restarts
/// a crash-looping kernel still bounds the file.
enum KernelOutputFile {
    static let rotateBytes = 1 << 20

    static func openForAppending(_ path: String) -> FileHandle? {
        let manager = FileManager.default
        let attributes = try? manager.attributesOfItem(atPath: path)
        if let size = attributes?[.size] as? Int, size >= rotateBytes {
            try? manager.removeItem(atPath: path + ".1")
            try? manager.moveItem(atPath: path, toPath: path + ".1")
        }
        if !manager.fileExists(atPath: path) {
            guard manager.createFile(
                atPath: path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else { return nil }
        } else {
            // A pre-existing file may be wider than 0600.
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
        guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) else {
            return nil
        }
        do {
            try handle.seekToEnd()
            return handle
        } catch {
            try? handle.close()
            return nil
        }
    }
}

/// Execs the argument vector. Stdout and stderr go to `/dev/null` so a
/// chatty child cannot fill a pipe and stall; the kernel writes its own
/// `--log` file. When the request names capture paths, both streams are
/// appended there instead (see `KernelOutputFile`); a path that cannot be
/// opened falls back to `/dev/null` — a lost capture must never stop the
/// kernel from starting.
public final class FoundationProcessLauncher: ProcessLauncher {
    public init() {}

    public func launch(
        _ request: LaunchRequest,
        onExit: @escaping (Int32, ProcessExit) -> Void
    ) throws -> RunningProcess {
        guard let executable = request.arguments.first, !executable.isEmpty else {
            throw LaunchError.emptyCommand
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(request.arguments.dropFirst())
        let stdout = request.stdoutPath.flatMap(KernelOutputFile.openForAppending) ?? FileHandle.nullDevice
        let stderr = request.stderrPath.flatMap(KernelOutputFile.openForAppending) ?? FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { proc in
            // The child holds its own dups; closing here stops the parent
            // side from pinning the file (and the rotated copy) open.
            try? stdout.close()
            try? stderr.close()
            let status = proc.terminationStatus
            let exit: ProcessExit = proc.terminationReason == .uncaughtSignal
                ? .signal(status)
                : .code(status)
            onExit(proc.processIdentifier, exit)
        }
        try process.run()
        return FoundationRunningProcess(process: process)
    }
}

private final class FoundationRunningProcess: RunningProcess {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    var pid: Int32 { process.processIdentifier }

    var isRunning: Bool { process.isRunning }

    func send(signal: Int32) {
        guard isRunning, pid > 0 else { return }
        _ = Darwin.kill(pid, signal)
    }

    func waitUntilExited(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !isRunning
    }
}
