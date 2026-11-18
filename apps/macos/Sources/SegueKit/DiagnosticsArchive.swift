import Foundation

public struct DiagnosticsLog: Equatable, Sendable {
    public var name: String
    public var body: String

    public init(name: String, body: String) {
        self.name = name
        self.body = body
    }
}

enum ZipError: Error, Equatable {
    case bad
}

/// STORE-method zip. Diagnostics are small text; compression would not
/// change what the redactor has to see.
enum ZipStore {
    static func archive(files: [(name: String, bytes: Data)], now: Date) -> Data {
        let stamp = dosStamp(now)
        var locals = Data()
        var central = Data()
        var count: UInt16 = 0
        for file in files {
            let nameBytes = Data(file.name.utf8)
            guard nameBytes.count <= Int(UInt16.max), file.bytes.count <= Int(UInt32.max) else {
                continue
            }
            let crc = CRC32.checksum(file.bytes)
            let offset = UInt32(locals.count)
            appendLocal(
                to: &locals,
                name: nameBytes,
                bytes: file.bytes,
                crc: crc,
                time: stamp.time,
                date: stamp.date
            )
            appendCentral(
                to: &central,
                name: nameBytes,
                bytes: file.bytes,
                crc: crc,
                time: stamp.time,
                date: stamp.date,
                offset: offset
            )
            count += 1
        }
        var archive = locals
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        appendEnd(
            to: &archive,
            count: count,
            centralSize: UInt32(central.count),
            centralOffset: centralOffset
        )
        return archive
    }

    /// Reads STORE entries. Used by tests to prove the archive is a zip,
    /// not just a byte blob that happens to contain the filenames.
    static func read(_ data: Data) throws -> [String: Data] {
        var offset = 0
        var files: [String: Data] = [:]
        while offset + 4 <= data.count {
            let signature = uint32(data, offset)
            if signature == 0x0201_4B50 || signature == 0x0605_4B50 {
                break
            }
            guard signature == 0x0403_4B50 else {
                throw ZipError.bad
            }
            guard offset + 30 <= data.count else {
                throw ZipError.bad
            }
            let method = uint16(data, offset + 8)
            let crc = uint32(data, offset + 14)
            let compressed = Int(uint32(data, offset + 18))
            let uncompressed = Int(uint32(data, offset + 22))
            let nameLength = Int(uint16(data, offset + 26))
            let extraLength = Int(uint16(data, offset + 28))
            let nameStart = offset + 30
            let dataStart = nameStart + nameLength + extraLength
            guard method == 0,
                  nameStart + nameLength <= data.count,
                  dataStart + compressed <= data.count,
                  compressed == uncompressed
            else {
                throw ZipError.bad
            }
            let nameData = data.subdata(in: nameStart ..< (nameStart + nameLength))
            let payload = data.subdata(in: dataStart ..< (dataStart + compressed))
            guard CRC32.checksum(payload) == crc, let name = String(data: nameData, encoding: .utf8) else {
                throw ZipError.bad
            }
            files[name] = payload
            offset = dataStart + compressed
        }
        guard !files.isEmpty || data.count >= 22 else {
            throw ZipError.bad
        }
        return files
    }

    static func safeLogName(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        var cleaned = ""
        for scalar in base.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" || scalar == "_" {
                cleaned.unicodeScalars.append(scalar)
            } else {
                cleaned.unicodeScalars.append("_")
            }
        }
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." || cleaned.hasPrefix(".") {
            return "log.txt"
        }
        return cleaned
    }

    private static func appendLocal(
        to data: inout Data,
        name: Data,
        bytes: Data,
        crc: UInt32,
        time: UInt16,
        date: UInt16
    ) {
        appendUInt32(0x0403_4B50, to: &data)
        appendUInt16(20, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(time, to: &data)
        appendUInt16(date, to: &data)
        appendUInt32(crc, to: &data)
        appendUInt32(UInt32(bytes.count), to: &data)
        appendUInt32(UInt32(bytes.count), to: &data)
        appendUInt16(UInt16(name.count), to: &data)
        appendUInt16(0, to: &data)
        data.append(name)
        data.append(bytes)
    }

    private static func appendCentral(
        to data: inout Data,
        name: Data,
        bytes: Data,
        crc: UInt32,
        time: UInt16,
        date: UInt16,
        offset: UInt32
    ) {
        appendUInt32(0x0201_4B50, to: &data)
        appendUInt16(20, to: &data)
        appendUInt16(20, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(time, to: &data)
        appendUInt16(date, to: &data)
        appendUInt32(crc, to: &data)
        appendUInt32(UInt32(bytes.count), to: &data)
        appendUInt32(UInt32(bytes.count), to: &data)
        appendUInt16(UInt16(name.count), to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt32(0, to: &data)
        appendUInt32(offset, to: &data)
        data.append(name)
    }

    private static func appendEnd(
        to data: inout Data,
        count: UInt16,
        centralSize: UInt32,
        centralOffset: UInt32
    ) {
        appendUInt32(0x0605_4B50, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(count, to: &data)
        appendUInt16(count, to: &data)
        appendUInt32(centralSize, to: &data)
        appendUInt32(centralOffset, to: &data)
        appendUInt16(0, to: &data)
    }

    private static func dosStamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let year = max(0, min(127, (parts.year ?? 1980) - 1980))
        let time = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        let day = UInt16(year << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        return (time, day)
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var remaining = value
        for _ in 0 ..< 4 {
            data.append(UInt8(remaining & 0xFF))
            remaining >>= 8
        }
    }

    private static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[data.index(data.startIndex, offsetBy: offset)])
            | (UInt16(data[data.index(data.startIndex, offsetBy: offset + 1)]) << 8)
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for shift in 0 ..< 4 {
            let byte = data[data.index(data.startIndex, offsetBy: offset + shift)]
            value |= UInt32(byte) << (8 * shift)
        }
        return value
    }
}

enum CRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                let mask: UInt32 = (crc & 1) == 1 ? 0xEDB8_8320 : 0
                crc = (crc >> 1) ^ mask
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

enum DiagnosticsArchive {
    static let maxLogBytes = 1_048_576

    static func write(
        files: [(name: String, bytes: Data)],
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
        var unique: [String: Int] = [:]
        var redacted: [(name: String, bytes: Data)] = []
        for file in files {
            let text = String(decoding: file.bytes, as: UTF8.self)
            let clean = DiagnosticsRedactor.redact(
                text,
                home: home,
                secrets: secrets,
                peerAddresses: peerAddresses
            )
            let name = uniqueName(file.name, used: &unique)
            guard let bytes = clean.data(using: .utf8) else {
                throw DiagnosticsError.unwritable
            }
            redacted.append((name, bytes))
        }
        let archive = ZipStore.archive(files: redacted, now: now)
        let url = directory.appendingPathComponent("segue-diagnostics-\(DiagnosticsWriter.fileStamp(now)).zip")
        do {
            try archive.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw DiagnosticsError.unwritable
        }
        return url
    }

    private static func uniqueName(_ name: String, used: inout [String: Int]) -> String {
        let seen = used[name, default: 0]
        used[name] = seen + 1
        if seen == 0 {
            return name
        }
        return "\(seen + 1)-\(name)"
    }
}
