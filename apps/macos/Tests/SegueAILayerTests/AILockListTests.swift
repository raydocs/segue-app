import XCTest

@testable import SegueAILayer

final class AILockListTests: XCTestCase {
    // Synthetic entries use RFC 5737 / RFC 3849 ranges and `.example` names;
    // the shipped-format assertions load the kernel fixture (see AIFixtures).

    func testParsesTheKernelListFixture() throws {
        let text = try AIFixtures.text(named: "ai-lock")
        let list = try AILockList.parse(text)
        XCTAssertEqual(list.suffixes.count, 42)
        XCTAssertEqual(list.suffixes.first, "anthropic.com")
        XCTAssertTrue(list.suffixes.contains("claude.com"))
        XCTAssertTrue(list.suffixes.contains("generativelanguage.googleapis.com"))
        XCTAssertTrue(list.suffixes.contains("o33249.ingest.us.sentry.io"))
        XCTAssertEqual(list.cidrs.map(\.text), [
            "160.79.104.0/23", "153.61.224.0/22", "2607:6bc0::/48",
        ])
    }

    func testKernelFixtureCIDRVersions() throws {
        let list = try AILockList.parse(try AIFixtures.text(named: "ai-lock"))
        XCTAssertEqual(list.cidrs.map(\.version), [.ipv4, .ipv4, .ipv6])
        XCTAssertEqual(
            list.cidrs[0].bytes, [160, 79, 104, 0])
        XCTAssertEqual(list.cidrs[2].prefixLength, 48)
    }

    func testCommentsAndBlankLinesAreIgnored() throws {
        let list = try AILockList.parse(
            """
            # a whole-line comment
            suffix api.example

            cidr 192.0.2.0/24 # trailing comment
            """)
        XCTAssertEqual(list.suffixes, ["api.example"])
        XCTAssertEqual(list.cidrs.map(\.text), ["192.0.2.0/24"])
    }

    func testSuffixesAreNormalizedAndDeduped() throws {
        let list = try AILockList.parse(
            """
            suffix Api.Example.
            suffix .other.example
            suffix api.example
            """)
        XCTAssertEqual(list.suffixes, ["api.example", "other.example"])
    }

    func testIPv6PrefixesParseWithCanonicalText() throws {
        let list = try AILockList.parse("cidr 2001:db8::/32")
        XCTAssertEqual(list.cidrs.map(\.text), ["2001:db8::/32"])
        XCTAssertEqual(list.cidrs[0].version, .ipv6)
        XCTAssertEqual(list.cidrs[0].prefixLength, 32)
    }

    func testDuplicateCIDRsCollapseIncludingAcrossMerge() throws {
        let base = try AILockList.parse("cidr 192.0.2.0/24")
        let merged = try base.merging(suffixes: [], cidrs: ["192.0.2.0/24", "198.51.100.0/24"])
        XCTAssertEqual(merged.cidrs.map(\.text), ["192.0.2.0/24", "198.51.100.0/24"])
    }

    func testMergeKeepsBuiltInOrderAndDedupesSuffixes() throws {
        let base = try AILockList.parse(
            """
            suffix api.example
            suffix chat.example
            """)
        let merged = try base.merging(
            suffixes: ["API.example.", "extra.example"],
            cidrs: ["203.0.113.0/24"]
        )
        XCTAssertEqual(merged.suffixes, ["api.example", "chat.example", "extra.example"])
        XCTAssertEqual(merged.cidrs.map(\.text), ["203.0.113.0/24"])
    }

    func testUnknownDirectiveIsRejectedWithItsLine() {
        XCTAssertThrowsError(try AILockList.parse("suffix api.example\ndomains other.example")) {
            error in
            XCTAssertEqual(
                error as? AILockList.Error,
                .unknownDirective(lineNumber: 2, directive: "domains"))
        }
    }

    func testMissingValueIsRejected() {
        XCTAssertThrowsError(try AILockList.parse("suffix")) { error in
            XCTAssertEqual(
                error as? AILockList.Error,
                .missingValue(lineNumber: 1, directive: "suffix"))
        }
        XCTAssertThrowsError(try AILockList.parse("# c\ncidr")) { error in
            XCTAssertEqual(
                error as? AILockList.Error,
                .missingValue(lineNumber: 2, directive: "cidr"))
        }
    }

    func testExtraTokensAreRejected() {
        XCTAssertThrowsError(try AILockList.parse("suffix api.example extra.example")) { error in
            XCTAssertEqual(error as? AILockList.Error, .extraTokens(lineNumber: 1))
        }
    }

    func testMalformedSuffixesAreRejected() {
        let longLabel = String(repeating: "a", count: 64)
        let bad: [(line: String, value: String)] = [
            ("suffix .", "."),  // empty after dot stripping
            ("suffix ..", ".."),  // empty after dot stripping
            ("suffix a..b.example", "a..b.example"),  // empty label
            ("suffix -leading.example", "-leading.example"),
            ("suffix trailing-.example", "trailing-.example"),
            ("suffix under_score.example", "under_score.example"),
            ("suffix a/b.example", "a/b.example"),  // path separator
            ("suffix *.example", "*.example"),  // wildcard
            ("suffix \(longLabel).example", "\(longLabel).example"),  // label over 63
        ]
        for case let (line, value) in bad {
            XCTAssertThrowsError(
                try AILockList.parse(line), "expected rejection for: \(line)"
            ) { error in
                XCTAssertEqual(
                    error as? AILockList.Error,
                    .invalidSuffix(lineNumber: 1, value: value),
                    "wrong error for: \(line)")
            }
        }
    }

    func testMalformedCIDRsAreRejectedWithTypedProblems() {
        let cases: [(String, CIDR.ParseProblem)] = [
            ("cidr 192.0.2.1/24", .hostBitsSet),  // host bit below /24
            ("cidr 192.0.2.0/33", .prefixOutOfRange(max: 32)),
            ("cidr 2001:db8::/129", .prefixOutOfRange(max: 128)),
            ("cidr 2001:db8:1::/32", .hostBitsSet),
            ("cidr 192.0.2.0/x", .prefixNotNumeric),
            ("cidr 192.0.2.0/", .prefixNotNumeric),
            ("cidr not-an-address/24", .notAnAddress),
            ("cidr 192.0.2.0", .missingPrefixLength),
            ("cidr 192.0.2.0/24/24", .extraSlashes),
        ]
        for (line, problem) in cases {
            XCTAssertThrowsError(try AILockList.parse(line), "expected rejection for: \(line)") {
                error in
                XCTAssertEqual(
                    error as? AILockList.Error,
                    .invalidCIDR(lineNumber: 1, value: String(line.dropFirst(5)), problem: problem),
                    "wrong error for: \(line)")
            }
        }
    }

    func testFirstBadLineWins() {
        XCTAssertThrowsError(
            try AILockList.parse("suffix api.example\nsuffix bad_name.example\nnonsense x")
        ) { error in
            XCTAssertEqual(
                error as? AILockList.Error,
                .invalidSuffix(lineNumber: 2, value: "bad_name.example"))
        }
    }

    func testBundleEntriesAreValidatedWithoutALineNumber() {
        XCTAssertThrowsError(
            try AILockList().merging(suffixes: ["under_score.example"], cidrs: [])
        ) { error in
            XCTAssertEqual(
                error as? AILockList.Error,
                .invalidSuffix(lineNumber: nil, value: "under_score.example"))
        }
        XCTAssertThrowsError(
            try AILockList().merging(suffixes: [], cidrs: ["192.0.2.1/24"])
        ) { error in
            XCTAssertEqual(
                error as? AILockList.Error,
                .invalidCIDR(
                    lineNumber: nil, value: "192.0.2.1/24", problem: .hostBitsSet))
        }
    }

    func testEmptyListIsEmpty() throws {
        let list = try AILockList.parse("# nothing armed\n\n")
        XCTAssertEqual(list.suffixes, [])
        XCTAssertEqual(list.cidrs, [])
    }
}
