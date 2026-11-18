import Foundation
import SegueHelperProtocol

/// The redactor lives in SegueHelperProtocol so the privileged helper
/// scrubs the kernel stderr tail with the same rules. The alias keeps
/// app-side callers (`DiagnosticsWriter`, `ConnectionModel`) unchanged.
public typealias DiagnosticsRedactor = SegueHelperProtocol.DiagnosticsRedactor

public enum DiagnosticsError: Error, Equatable {
    case directoryMissing
    case unwritable
}

public struct DiagnosticsDocument: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public var schemaVersion: Int
    public var exportedAt: String
    public var statusLine: String
    public var showsConnected: Bool
    public var configFolder: String
    public var kernel: KernelStatus?
    public var helper: HelperStatus?
    public var lastError: String?

    public init(
        schemaVersion: Int,
        exportedAt: String,
        statusLine: String,
        showsConnected: Bool,
        configFolder: String,
        kernel: KernelStatus?,
        helper: HelperStatus?,
        lastError: String?
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.statusLine = statusLine
        self.showsConnected = showsConnected
        self.configFolder = configFolder
        self.kernel = kernel
        self.helper = helper
        self.lastError = lastError
    }
}

enum DiagnosticsWriter {
    static func write(
        document: DiagnosticsDocument,
        to directory: URL,
        now: Date,
        home: String,
        secrets: [String],
        peerAddresses: [String],
        fileManager: FileManager
    ) throws -> URL {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw DiagnosticsError.directoryMissing
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(document)
        var text = String(decoding: encoded, as: UTF8.self)
        text = DiagnosticsRedactor.redact(
            text,
            home: home,
            secrets: secrets,
            peerAddresses: peerAddresses
        )
        if !text.hasSuffix("\n") {
            text.append("\n")
        }
        guard let data = text.data(using: .utf8) else {
            throw DiagnosticsError.unwritable
        }
        let url = directory.appendingPathComponent("segue-diagnostics-\(fileStamp(now)).json")
        do {
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw DiagnosticsError.unwritable
        }
        return url
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func fileStamp(_ date: Date) -> String {
        timestamp(date)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
    }
}
