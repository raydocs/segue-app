import Foundation

/// The question section of one DNS query, as the guard sees it. `name` is
/// lowercased with the root label's trailing dot kept (`api.anthropic.com.`).
public struct DNSQuestion: Equatable, Sendable {
    public let name: String
    public let qtype: UInt16
    public let qclass: UInt16

    public init(name: String, qtype: UInt16, qclass: UInt16) {
        self.name = name
        self.qtype = qtype
        self.qclass = qclass
    }
}

/// Answers DNS for the armed AI suffixes while the tunnel is down and intent
/// is still armed (design `docs/design/macos.md` §2). It owns nothing but
/// this decision: armed names get NOERROR with zero answers (an address that
/// resolves to nothing, so lookups fail fast instead of timing out), every
/// other name is REFUSED, and it never recurses — the `/etc/resolver` files
/// mean non-armed names should not arrive here at all.
public struct GuardResponder: Equatable, Sendable {
    /// Armed suffixes, normalized by the same rules as `AILockList`.
    public let armedSuffixes: [String]

    public init(suffixes: [String]) {
        var seen = Set<String>()
        self.armedSuffixes = suffixes
            .compactMap(AILockSuffix.normalize)
            .filter { seen.insert($0).inserted }
    }

    /// Suffix match, case-insensitive, on the name and every subdomain.
    /// `notanthropic.com.` is not armed by `anthropic.com`.
    public func isArmed(name: String) -> Bool {
        var normalized = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix(".") { normalized.removeFirst() }
        guard !normalized.isEmpty else { return false }
        if !normalized.hasSuffix(".") { normalized.append(".") }
        return armedSuffixes.contains { suffix in
            normalized == "\(suffix)." || normalized.hasSuffix(".\(suffix).")
        }
    }

    /// The reply bytes for a raw UDP DNS query, or nil when the packet is
    /// malformed and must be dropped without an answer.
    public func reply(to query: Data) -> Data? {
        guard let parsed = DNSCodec.parseQuery(query) else { return nil }
        let rcode: UInt8 = isArmed(name: parsed.question.name)
            ? DNSCodec.rcodeNoError
            : DNSCodec.rcodeRefused

        var reply = Data(capacity: parsed.questionRange.upperBound - query.startIndex)
        reply.append(query.prefix(2))  // the client's ID, echoed
        reply.append(DNSCodec.flagsQR | (parsed.recursionDesired ? DNSCodec.flagsRD : 0))
        reply.append(rcode)
        reply.append(contentsOf: [0, 1, 0, 0, 0, 0, 0, 0])  // one question, no records
        reply.append(query[parsed.questionRange])  // question echoed verbatim
        return reply
    }

    /// The question a packet asks, for logging and tests. nil when malformed.
    public func question(in query: Data) -> DNSQuestion? {
        DNSCodec.parseQuery(query)?.question
    }
}

/// A hand-written DNS wire codec, question side only: enough to read one
/// query and write its header back. No compression, no EDNS, no recursion.
enum DNSCodec {
    static let rcodeNoError: UInt8 = 0
    static let rcodeRefused: UInt8 = 5
    static let flagsQR: UInt8 = 0x80
    static let flagsRD: UInt8 = 0x01
    static let headerLength = 12
    static let maxWireNameLength = 255

    struct ParsedQuery {
        let question: DNSQuestion
        let recursionDesired: Bool
        /// Byte range of the question section within the query packet
        /// (index space of the packet it was parsed from).
        let questionRange: Range<Data.Index>
    }

    static func parseQuery(_ data: Data) -> ParsedQuery? {
        guard data.count >= headerLength else { return nil }
        let flags = readU16(data, 2)
        let isResponse = (flags >> 15) & 0x1
        let opcode = (flags >> 11) & 0xF
        guard isResponse == 0, opcode == 0 else { return nil }
        let recursionDesired = (flags >> 8) & 0x1 == 1

        guard readU16(data, 4) == 1 else { return nil }  // exactly one question
        guard readU16(data, 6) == 0, readU16(data, 8) == 0 else { return nil }  // not a query

        var labels: [String] = []
        let base = data.startIndex
        var offset = headerLength
        var wireNameLength = 1  // the root label's zero byte
        while true {
            guard offset < data.count else { return nil }
            let labelLength = Int(data[data.startIndex + offset])
            if labelLength == 0 {
                offset += 1
                break
            }
            // A pointer (or the reserved 64-191 range) never appears in a
            // question name on the wire from a client.
            guard (1...63).contains(labelLength) else { return nil }
            guard offset + 1 + labelLength <= data.count else { return nil }
            let label = data[(base + offset + 1)..<(base + offset + 1 + labelLength)]
            // Invalid UTF-8 becomes U+FFFD, which no armed suffix contains,
            // so a mangled name can only miss the match, never hit it.
            labels.append(String(decoding: label, as: UTF8.self).lowercased())
            offset += 1 + labelLength
            wireNameLength += 1 + labelLength
            guard wireNameLength <= maxWireNameLength else { return nil }
        }
        guard offset + 4 <= data.count else { return nil }
        let qtype = readU16(data, offset)
        let qclass = readU16(data, offset + 2)
        let questionEnd = offset + 4

        let name = labels.joined(separator: ".") + "."
        return ParsedQuery(
            question: DNSQuestion(name: name, qtype: qtype, qclass: qclass),
            recursionDesired: recursionDesired,
            questionRange: (base + headerLength)..<(base + questionEnd)
        )
    }

    static func readU16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) << 8
            | UInt16(data[data.startIndex + offset + 1])
    }
}
