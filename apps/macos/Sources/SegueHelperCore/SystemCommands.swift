import Foundation
import SegueAILayer

/// What one bounded command printed. A non-zero `status` is not thrown here;
/// the caller decides whether that is a failure.
public struct SystemCommandOutput: Equatable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum SystemCommandError: Error, Equatable {
    case io(String)
}

/// Every side effect the AI layer is allowed to perform. `LiveSystemCommands`
/// is the process and file implementation. Tests use a recording stand-in and
/// never construct the live type.
public protocol SystemCommands: AnyObject {
    func run(program: String, arguments: [String], standardInput: String?) throws -> SystemCommandOutput

    func readTextFile(_ path: String) throws -> String
    func writeTextFile(_ path: String, _ contents: String) throws
    func removeFile(_ path: String) throws
    func fileExists(_ path: String) -> Bool

    func startGuardListener(address: String, port: UInt16, responder: GuardResponder) throws
    func stopGuardListener() throws
    func guardIsListening() -> Bool

    /// Entry names directly inside a directory, sorted. A directory that does
    /// not exist is an empty list, not an error: the release daemon scans
    /// `/etc/resolver`, which a machine may not have.
    func listDirectory(_ path: String) throws -> [String]
}

public enum SystemPrograms {
    public static let pfctl = "/sbin/pfctl"
    public static let networksetup = "/usr/sbin/networksetup"
}

/// Parsers for the command text the controller sends and reads back.
public enum SystemText {
    public static func listsAnchor(_ text: String, name: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            line.trimmingCharacters(in: .whitespacesAndNewlines) == name
        }
    }

    /// `networksetup -listnetworkserviceorder`. Disabled services (a leading
    /// `*` on the name) are skipped. The hardware device is the stable id;
    /// networksetup itself addresses services by display name.
    public static func serviceOrder(_ text: String) -> [DNSServiceRecord] {
        var records: [DNSServiceRecord] = []
        var pending: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if let name = indexedServiceName(line) {
                pending = name
                continue
            }
            if let pendingName = pending, let device = deviceName(line) {
                records.append(DNSServiceRecord(serviceID: device, name: pendingName, servers: []))
                pending = nil
            }
        }
        return records
    }

    /// `networksetup -getdnsservers`. The "aren't any" sentence is an empty
    /// list, which is a real restore target (DHCP), not a missing service.
    public static func dnsServers(_ text: String) -> [String] {
        if text.contains("aren't any") { return [] }
        return text.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    public static func isDNSToken(_ text: String) -> Bool {
        guard !text.isEmpty, text != "Empty", !text.hasPrefix("-") else { return false }
        return !text.contains(where: \.isWhitespace)
    }

    private static func indexedServiceName(_ line: String) -> String? {
        guard line.hasPrefix("("), let close = line.firstIndex(of: ")") else { return nil }
        let head = line[line.index(after: line.startIndex)..<close]
        guard !head.isEmpty, head.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        let name = line[line.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("*") else { return nil }
        return name
    }

    private static func deviceName(_ line: String) -> String? {
        guard let range = line.range(of: "Device: ") else { return nil }
        let tail = line[range.upperBound...]
        let device = tail.prefix(while: { $0 != ")" && $0 != "," })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !device.isEmpty else { return nil }
        return String(device)
    }
}
