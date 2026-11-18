import XCTest

@testable import SegueAILayer

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }
}

/// Builds DNS query packets the way a stub resolver would.
private func query(
    id: UInt16 = 0x1234,
    name: String,
    qtype: UInt16,
    qclass: UInt16 = 1,
    flags: UInt16 = 0x0100,  // RD set, like a real stub resolver
    qdcount: UInt16 = 1,
    ancount: UInt16 = 0,
    nscount: UInt16 = 0,
    arcount: UInt16 = 0,
    trailing: Data = Data()
) -> Data {
    var data = Data()
    data.appendUInt16(id)
    data.appendUInt16(flags)
    data.appendUInt16(qdcount)
    data.appendUInt16(ancount)
    data.appendUInt16(nscount)
    data.appendUInt16(arcount)
    for label in name.split(separator: ".") where !label.isEmpty {
        data.append(UInt8(label.count))
        for byte in label.utf8 { data.append(byte) }
    }
    data.append(0)
    data.appendUInt16(qtype)
    data.appendUInt16(qclass)
    data.append(trailing)
    return data
}


/// The question-section bytes of a built packet (everything from byte 12,
/// or up to `end` when the packet carries trailing records).
private func questionBytes(of packet: Data, upTo end: Int? = nil) -> Data {
    let start = packet.startIndex + 12
    if let end {
        return Data(packet[start..<packet.startIndex + end])
    }
    return Data(packet[start...])
}

final class GuardResponderTests: XCTestCase {
    private let responder = GuardResponder(
        suffixes: ["anthropic.com", "claude.ai", "api.example"])

    private func assertReply(
        _ reply: Data?,
        to packet: Data,
        id: UInt16 = 0x1234,
        rcode: UInt8,
        questionBytes: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let reply else {
            return XCTFail("expected a reply", file: file, line: line)
        }
        // Header: ID echoed, QR set, RD copied, our rcode, one question,
        // zero records of any kind.
        let expected = Data([
            UInt8(id >> 8), UInt8(id & 0xFF),
            0x80 | (packet[2] & 0x01), rcode,
            0, 1, 0, 0, 0, 0, 0, 0,
        ]) + questionBytes
        XCTAssertEqual(reply, expected, file: file, line: line)
    }

    func testArmedAQueryGetsNoErrorWithZeroAnswers() {
        let packet = query(name: "api.anthropic.com", qtype: 1)
        let question = questionBytes(of: packet)
        let reply = responder.reply(to: packet)
        assertReply(reply, to: packet, rcode: 0, questionBytes: Data(question))
        // Zero answers, literally: nothing after the echoed question.
        XCTAssertEqual(reply?.count, 12 + question.count)
    }

    func testArmedAAAAQueryGetsNoErrorWithZeroAnswers() {
        let packet = query(name: "api.anthropic.com", qtype: 28)
        let question = questionBytes(of: packet)
        assertReply(responder.reply(to: packet), to: packet, rcode: 0, questionBytes: question)
    }

    func testArmedNonAddressQueriesGetNoErrorEmpty() {
        for qtype in [UInt16(15), 16, 2, 255] {  // MX, TXT, NS, ANY
            let packet = query(name: "api.anthropic.com", qtype: qtype)
            let question = questionBytes(of: packet)
            assertReply(
                responder.reply(to: packet), to: packet, rcode: 0, questionBytes: question)
        }
    }

    func testUppercaseArmedNameStillMatches() {
        let packet = query(name: "API.Anthropic.COM", qtype: 1)
        let question = questionBytes(of: packet)
        assertReply(responder.reply(to: packet), to: packet, rcode: 0, questionBytes: question)
    }

    func testTheSuffixNameItselfIsArmed() {
        let packet = query(name: "anthropic.com", qtype: 1)
        let question = questionBytes(of: packet)
        assertReply(responder.reply(to: packet), to: packet, rcode: 0, questionBytes: question)
    }

    func testSiblingNameIsNotArmed() {
        // `notanthropic.com` shares the ending but not the label boundary.
        let packet = query(name: "notanthropic.com", qtype: 1)
        let question = questionBytes(of: packet)
        assertReply(responder.reply(to: packet), to: packet, rcode: 5, questionBytes: question)
    }

    func testNonArmedNameIsRefused() {
        let packet = query(name: "www.example.org", qtype: 1)
        let question = questionBytes(of: packet)
        assertReply(responder.reply(to: packet), to: packet, rcode: 5, questionBytes: question)
    }

    func testRecursionDesiredIsCopiedButNeverHonoured() {
        let packet = query(name: "api.example", qtype: 1, flags: 0x0000)
        let question = questionBytes(of: packet)
        // RA stays 0 in the reply: this listener never recurses.
        assertReply(responder.reply(to: packet), to: packet, rcode: 0, questionBytes: question)
    }

    func testReplyToAHandBuiltLiteralPacket() {
        // Bytes, not the builder: qname api.anthropic.com, A, IN. Each label
        // is a length byte followed by that many bytes, then the root's zero.
        let question: [UInt8] =
            [3] + Array("api".utf8)
            + [9] + Array("anthropic".utf8)
            + [3] + Array("com".utf8)
            + [0, 0x00, 0x01, 0x00, 0x01]
        let packet = Data([0xAB, 0xCD, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0] + question)
        let reply = responder.reply(to: packet)
        assertReply(
            reply, to: packet, id: 0xABCD, rcode: 0, questionBytes: Data(question))
    }

    func testAdditionalRecordsAreIgnoredNotAnswered() {
        // An EDNS OPT pseudo-record in the additional section is normal for
        // modern resolvers; the reply drops it and answers the question.
        let opt: [UInt8] = [0, 0x29, 16, 0, 0, 0, 0, 0, 0]  // root name, OPT, UDP 4096
        let packet = query(name: "api.anthropic.com", qtype: 1, arcount: 1, trailing: Data(opt))
        let reply = responder.reply(to: packet)
        let trailingEnd = packet.count - opt.count
        assertReply(reply, to: packet, rcode: 0, questionBytes: questionBytes(of: packet, upTo: trailingEnd))
    }

    func testRootNameIsNotArmed() throws {
        let packet = query(name: ".", qtype: 1)
        let parsed = try XCTUnwrap(responder.question(in: packet))
        XCTAssertEqual(parsed.name, ".")
        let question = questionBytes(of: packet)
        assertReply(responder.reply(to: packet), to: packet, rcode: 5, questionBytes: question)
    }

    func testMalformedPacketsAreDropped() {
        let good = query(name: "api.anthropic.com", qtype: 1)
        var bad: [Data] = [
            Data(good.prefix(11)),  // header cut short
            Data(good.prefix(12)),  // header only, no question
            Data(good.prefix(good.count - 4)),  // question cut before qtype
            Data(good.prefix(good.count - 12)),  // cut inside the last label
            query(name: "api.anthropic.com", qtype: 1, flags: 0x8000),  // QR set
            query(name: "api.anthropic.com", qtype: 1, flags: 0x0800),  // opcode 1
            query(name: "api.anthropic.com", qtype: 1, flags: 0x2800),  // opcode 5
            query(name: "api.anthropic.com", qtype: 1, qdcount: 2),
            query(name: "api.anthropic.com", qtype: 1, qdcount: 0),
            query(name: "api.anthropic.com", qtype: 1, ancount: 1),
            query(name: "api.anthropic.com", qtype: 1, nscount: 1),
            // A compression pointer where a label length belongs.
            Data([0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 0x0C, 0, 1, 0, 1]),
            // A reserved label length (192 > 63 without being a valid pointer
            // start is covered above; 100 is simply invalid).
            Data([0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 100, 1, 0, 1, 0, 1]),
        ]
        // A name past the 255-octet wire limit.
        let longName = (1...5).map { _ in String(repeating: "a", count: 63) }
            .joined(separator: ".")
        bad.append(query(name: longName, qtype: 1))
        // A label that promises more bytes than the packet has.
        bad.append(Data([0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 40, 0x61]))

        for packet in bad {
            XCTAssertNil(responder.reply(to: packet), "expected drop for \(packet as NSData)")
            XCTAssertNil(responder.question(in: packet))
        }
    }

    func testInitNormalizesAndDedupesSuffixes() {
        let responder = GuardResponder(suffixes: ["Anthropic.COM.", "anthropic.com", "bad_name"])
        XCTAssertEqual(responder.armedSuffixes, ["anthropic.com"])
    }

    func testIsArmedMatchesCaseAndLabelBoundaries() {
        XCTAssertTrue(responder.isArmed(name: "api.anthropic.com."))
        XCTAssertTrue(responder.isArmed(name: "API.ANTHROPIC.COM"))
        XCTAssertTrue(responder.isArmed(name: "deep.sub.claude.ai."))
        XCTAssertFalse(responder.isArmed(name: "anthropic.com.evil.example."))
        XCTAssertFalse(responder.isArmed(name: "notanthropic.com."))
        XCTAssertFalse(responder.isArmed(name: "."))
        XCTAssertFalse(responder.isArmed(name: ""))
    }
}
