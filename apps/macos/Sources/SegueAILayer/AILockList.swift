import Darwin
import Foundation

/// One IP prefix from the AI lock list, normalized for PF `to <cidr>`
/// rendering. IPv4 and IPv6; the address text is canonical (`::` compressed)
/// and host bits below the prefix length are rejected, not silently masked.
public struct CIDR: Equatable, Hashable, Sendable, CustomStringConvertible {
    public enum Version: Equatable, Hashable, Sendable {
        case ipv4
        case ipv6
    }

    public enum ParseProblem: Equatable, Sendable {
        case notAnAddress
        case missingPrefixLength
        case extraSlashes
        case prefixNotNumeric
        case prefixOutOfRange(max: Int)
        case hostBitsSet
    }

    public let version: Version
    /// Network-order address bytes: 4 for IPv4, 16 for IPv6.
    public let bytes: [UInt8]
    public let prefixLength: Int

    public var description: String { text }

    /// Canonical `address/length` text (the form the renderer emits).
    public var text: String {
        switch version {
        case .ipv4:
            return "\(bytes.map(String.init).joined(separator: "."))/\(prefixLength)"
        case .ipv6:
            return "\(CIDR.ipv6Text(bytes))/\(prefixLength)"
        }
    }

    public init(version: Version, bytes: [UInt8], prefixLength: Int) {
        self.version = version
        self.bytes = bytes
        self.prefixLength = prefixLength
    }

    /// Parses `address/length`. Host bits set below the prefix length are an
    /// error (`hostBitsSet`), not a rounding step.
    public init(parsing raw: String) throws {
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { throw ParseError(.extraSlashes, raw) }
        guard parts.count == 2 else { throw ParseError(.missingPrefixLength, raw) }
        let addressText = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let prefixText = String(parts[1]).trimmingCharacters(in: .whitespaces)

        guard !prefixText.isEmpty, prefixText.allSatisfy({ ("0"..."9").contains($0) }),
            let prefixValue = UInt(prefixText)
        else { throw ParseError(.prefixNotNumeric, raw) }

        if let v4 = CIDR.ipv4Bytes(addressText) {
            guard prefixValue <= 32 else { throw ParseError(.prefixOutOfRange(max: 32), raw) }
            let prefixLength = Int(prefixValue)
            guard CIDR.hostBitsAreClear(v4, prefixLength: prefixLength) else {
                throw ParseError(.hostBitsSet, raw)
            }
            self.init(version: .ipv4, bytes: v4, prefixLength: prefixLength)
        } else if let v6 = CIDR.ipv6Bytes(addressText) {
            guard prefixValue <= 128 else { throw ParseError(.prefixOutOfRange(max: 128), raw) }
            let prefixLength = Int(prefixValue)
            guard CIDR.hostBitsAreClear(v6, prefixLength: prefixLength) else {
                throw ParseError(.hostBitsSet, raw)
            }
            self.init(version: .ipv6, bytes: v6, prefixLength: prefixLength)
        } else {
            throw ParseError(.notAnAddress, raw)
        }
    }

    public struct ParseError: Error, Equatable {
        public let problem: ParseProblem
        public let input: String

        public init(_ problem: ParseProblem, _ input: String) {
            self.problem = problem
            self.input = input
        }
    }

    static func ipv4Bytes(_ text: String) -> [UInt8]? {
        var addr = in_addr()
        guard text.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }
        return withUnsafeBytes(of: addr.s_addr) { Array($0) }
    }

    static func ipv6Bytes(_ text: String) -> [UInt8]? {
        var addr = in6_addr()
        guard text.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
        return withUnsafeBytes(of: addr) { Array($0.prefix(16)) }
    }

    static func ipv6Text(_ bytes: [UInt8]) -> String {
        var addr = in6_addr()
        withUnsafeMutableBytes(of: &addr) { $0.copyBytes(from: bytes) }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return String(cString: buffer)
    }

    /// true when every bit below `prefixLength`'s network part is zero: the
    /// value is a prefix, not an address inside one.
    static func hostBitsAreClear(_ bytes: [UInt8], prefixLength: Int) -> Bool {
        for (index, byte) in bytes.enumerated() {
            let bitBase = index * 8
            if bitBase >= prefixLength {
                // This byte and everything after it is host bits.
                if byte != 0 { return false }
            } else {
                let hostBits = bitBase + 8 - prefixLength  // 0...7
                if hostBits > 0, byte & ((1 << UInt8(hostBits)) &- 1) != 0 { return false }
            }
        }
        return true
    }
}

/// Normalizes one armed name suffix. The same rules serve the kernel list
/// parser, `/etc/resolver` filenames, and the DNS guard's name matching, so a
/// suffix that parses is safe to use everywhere the lock names it.
enum AILockSuffix {
    /// `Anthropic.COM.` → `anthropic.com`. nil when the text is not a plain
    /// DNS name: empty, a path, a wildcard, a label over 63 bytes or with
    /// characters outside letters, digits and interior hyphens.
    static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix(".") { text.removeFirst() }
        if text.hasSuffix(".") { text.removeLast() }
        guard !text.isEmpty, text.count <= 253, !text.contains("/") else { return nil }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return nil }
        for label in labels {
            guard (1...63).contains(label.count) else { return nil }
            guard label.first != "-", label.last != "-" else { return nil }
            for character in label where !isAllowed(character) { return nil }
        }
        return text
    }

    private static func isAllowed(_ character: Character) -> Bool {
        ("a"..."z").contains(character) || ("0"..."9").contains(character) || character == "-"
    }
}

/// The armed destinations of the AI lock: name suffixes plus IP prefixes.
/// Suffixes match the name and every subdomain; CIDRs are outbound block
/// targets for the PF anchor. Order is significant (the renderer emits one
/// labeled rule per CIDR, in list order), and both kinds are deduped on
/// construction so a bundle cannot widen a rule by repeating it.
public struct AILockList: Equatable, Sendable {
    public let suffixes: [String]
    public let cidrs: [CIDR]

    public init(suffixes: [String] = [], cidrs: [CIDR] = []) {
        var seenSuffixes = Set<String>()
        self.suffixes = suffixes.filter { seenSuffixes.insert($0).inserted }
        var seenCIDRs = Set<CIDR>()
        self.cidrs = cidrs.filter { seenCIDRs.insert($0).inserted }
    }

    public enum Error: Swift.Error, Equatable {
        /// `nil` line numbers come from bundle-supplied entries, which have no
        /// file position to report.
        case unknownDirective(lineNumber: Int?, directive: String)
        case missingValue(lineNumber: Int?, directive: String)
        case extraTokens(lineNumber: Int?)
        case invalidSuffix(lineNumber: Int?, value: String)
        case invalidCIDR(lineNumber: Int?, value: String, problem: CIDR.ParseProblem)
    }

    /// Parses the kernel's built-in list (`segue-kernel/data/ai-lock.txt`).
    /// A line is `suffix <domain>` or `cidr <prefix>`; `#` starts a comment
    /// that runs to the end of the line.
    public static func parse(_ text: String) throws -> AILockList {
        var suffixes: [String] = []
        var cidrs: [CIDR] = []
        var lineNumber = 0
        var pendingError: Error?

        text.enumerateLines { rawLine, _ in
            lineNumber += 1
            var line = rawLine
            if let comment = line.firstIndex(of: "#") {
                line = String(line[..<comment])
            }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard !tokens.isEmpty else { return }
            let directive = String(tokens[0])
            let valueText = tokens.count > 1 ? String(tokens[1]) : nil

            func record(_ error: Error) {
                if pendingError == nil { pendingError = error }
            }

            switch directive {
            case "suffix":
                guard let valueText else {
                    record(.missingValue(lineNumber: lineNumber, directive: directive))
                    return
                }
                guard tokens.count == 2 else { record(.extraTokens(lineNumber: lineNumber)); return }
                if let normalized = AILockSuffix.normalize(valueText) {
                    suffixes.append(normalized)
                } else {
                    record(.invalidSuffix(lineNumber: lineNumber, value: valueText))
                }
            case "cidr":
                guard let valueText else {
                    record(.missingValue(lineNumber: lineNumber, directive: directive))
                    return
                }
                guard tokens.count == 2 else { record(.extraTokens(lineNumber: lineNumber)); return }
                do {
                    cidrs.append(try CIDR(parsing: valueText))
                } catch let error as CIDR.ParseError {
                    record(
                        .invalidCIDR(
                            lineNumber: lineNumber, value: valueText, problem: error.problem
                        ))
                } catch {
                    record(.invalidCIDR(lineNumber: lineNumber, value: valueText, problem: .notAnAddress))
                }
            default:
                record(.unknownDirective(lineNumber: lineNumber, directive: directive))
            }
        }

        if let pendingError { throw pendingError }
        return AILockList(suffixes: suffixes, cidrs: cidrs)
    }

    /// Merges a signed bundle's extra `ai_domains` and `ai_cidrs` into this
    /// list. Built-ins keep their order and position; bundle entries follow
    /// and duplicates of either side appear once. Everything the bundle adds
    /// is validated with the same rules as the file.
    public func merging(suffixes extraSuffixes: [String], cidrs extraCIDRs: [String]) throws
        -> AILockList
    {
        var normalizedSuffixes: [String] = []
        for raw in extraSuffixes {
            guard let normalized = AILockSuffix.normalize(raw) else {
                throw Error.invalidSuffix(lineNumber: nil, value: raw)
            }
            normalizedSuffixes.append(normalized)
        }
        var parsedCIDRs: [CIDR] = []
        for raw in extraCIDRs {
            do {
                parsedCIDRs.append(try CIDR(parsing: raw))
            } catch let error as CIDR.ParseError {
                throw Error.invalidCIDR(lineNumber: nil, value: raw, problem: error.problem)
            } catch {
                throw Error.invalidCIDR(lineNumber: nil, value: raw, problem: .notAnAddress)
            }
        }
        return AILockList(
            suffixes: suffixes + normalizedSuffixes,
            cidrs: cidrs + parsedCIDRs
        )
    }
}
