import Darwin
import Foundation

public struct StoredIntent: Codable, Equatable, Sendable {
    public var armed: Bool
    public var generation: UInt64
    public var name: String

    public init(armed: Bool, generation: UInt64, name: String) {
        self.armed = armed
        self.generation = generation
        self.name = name
    }

    public static let disarmed = StoredIntent(armed: false, generation: 0, name: "none")
}

public enum IntentStoreError: Error, Equatable {
    case io(Int32)
}

/// Root-owned intent bit. The file is created mode 0600. The directory is
/// created mode 0700 when this store is the one that creates it. Stage 0
/// writes the bit and does nothing else with it.
public struct IntentStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> StoredIntent? {
        let path = fileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(StoredIntent.self, from: data)
    }

    public func save(_ intent: StoredIntent) throws {
        let parent = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: parent.path
            )
        }
        let data = try JSONEncoder().encode(intent)
        let tmp = URL(fileURLWithPath: fileURL.path + ".tmp")
        let fd = try openTruncating(tmp)
        defer { _ = Darwin.close(fd) }
        try writeAll(fd, data)
        if fsync(fd) != 0 {
            throw IntentStoreError.io(errno)
        }
        if rename(tmp, fileURL) != 0 {
            throw IntentStoreError.io(errno)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
    }

    private func openTruncating(_ url: URL) throws -> Int32 {
        let fd: Int32 = url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { return -1 }
            return Darwin.open(pointer, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        }
        guard fd >= 0 else {
            throw IntentStoreError.io(errno)
        }
        return fd
    }

    private func rename(_ from: URL, _ to: URL) -> Int32 {
        from.withUnsafeFileSystemRepresentation { source in
            to.withUnsafeFileSystemRepresentation { dest in
                guard let source, let dest else { return -1 }
                return Darwin.rename(source, dest)
            }
        }
    }

    private func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw IntentStoreError.io(errno)
                }
                if n == 0 {
                    throw IntentStoreError.io(EIO)
                }
                sent += n
            }
        }
    }
}
