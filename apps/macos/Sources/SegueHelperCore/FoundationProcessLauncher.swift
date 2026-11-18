import Darwin
import Foundation

/// Execs the argument vector. Stdout and stderr go to `/dev/null` so a
/// chatty child cannot fill a pipe and stall. The kernel's own log path is
/// a later stage.
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
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { proc in
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
