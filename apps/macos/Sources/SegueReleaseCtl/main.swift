import Darwin
import Foundation
import SegueHelperProtocol
import SegueKit

// segue-release-ctl restore [--socket PATH]
//
// One request on the release daemon's socket, using SegueKit's ReleaseClient
// so the bytes are ReleaseEnvelope.restore() and not a hand-built JSON line.
// Prints the read-back fields. Exit 0 when a report came back; the matrix
// decides whether that read-back is clean.

@main
enum SegueReleaseCtl {
    static func main() async {
        exit(await run())
    }

    private static func run() async -> Int32 {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2, arguments[1] == "restore" else {
            FileHandle.standardError.write(Data(
                "usage: segue-release-ctl restore [--socket PATH]\n".utf8
            ))
            return 2
        }
        var socketPath = SeguePaths.releaseSocketPath
        var index = 2
        while index < arguments.count {
            let flag = arguments[index]
            if flag == "--socket", index + 1 < arguments.count {
                socketPath = arguments[index + 1]
                index += 2
                continue
            }
            FileHandle.standardError.write(Data(
                "segue-release-ctl: unknown argument \(flag)\n".utf8
            ))
            return 2
        }

        let client = ReleaseClient.connectedToReleaseSocket(path: socketPath)
        let report: ReleaseReport
        do {
            report = try await client.restore()
        } catch {
            print("error=\(String(describing: error))")
            return 1
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = (try? encoder.encode(report)) ?? Data()
        let json = String(data: encoded, encoding: .utf8) ?? ""
        print("outcome=\(report.outcome)")
        print("anchor_loaded=\(report.anchorLoaded)")
        print("resolver_files_remaining=\(report.resolverFilesRemaining.joined(separator: ","))")
        print("dns_mode=\(report.dnsMode)")
        print("intent_cleared=\(report.intentCleared)")
        print("snapshot_cleared=\(report.snapshotCleared)")
        print("dns_restored_services=\(report.dnsRestoredServices.joined(separator: ","))")
        print("failures=\(report.failures.joined(separator: ","))")
        print("report=\(json)")
        return 0
    }
}
