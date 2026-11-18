import XCTest

@testable import SegueAILayer

final class PFAnchorRendererTests: XCTestCase {
    private let v4 = try! CIDR(parsing: "192.0.2.0/24")
    private let v4b = try! CIDR(parsing: "198.51.100.0/24")
    private let v6 = try! CIDR(parsing: "2001:db8::/32")

    func testArmedWithNoCIDRsIsPassRulesOnly() throws {
        let list = AILockList(suffixes: ["api.example"], cidrs: [])
        let text = try PFAnchorRenderer.render(intent: .armed, utun: nil, list: list)
        XCTAssertEqual(
            text,
            """
            # segue.ailock — managed by Segue; do not edit
            pass quick on lo0
            """ + "\n")
    }

    func testArmedWithUtunAndOneCIDR() throws {
        let list = AILockList(suffixes: ["api.example"], cidrs: [v4])
        let text = try PFAnchorRenderer.render(intent: .armed, utun: "utun7", list: list)
        XCTAssertEqual(
            text,
            """
            # segue.ailock — managed by Segue; do not edit
            pass quick on lo0
            pass quick on utun7
            block drop out quick inet to 192.0.2.0/24 label "segue-ai-0"
            """ + "\n")
    }

    func testArmedWithManyCIDRsKeepsListOrderAndUniqueLabels() throws {
        let list = AILockList(suffixes: [], cidrs: [v4, v6, v4b, v6])
        let text = try PFAnchorRenderer.render(intent: .armed, utun: "utun12", list: list)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(
            lines,
            [
                "# segue.ailock — managed by Segue; do not edit",
                "pass quick on lo0",
                "pass quick on utun12",
                "block drop out quick inet to 192.0.2.0/24 label \"segue-ai-0\"",
                "block drop out quick inet6 to 2001:db8::/32 label \"segue-ai-1\"",
                "block drop out quick inet to 198.51.100.0/24 label \"segue-ai-2\"",
            ])
        let labels = lines.filter { $0.contains("label") }
        XCTAssertEqual(Set(labels).count, labels.count, "labels must be unique")
    }

    func testKernelListRendersItsRealCIDRs() throws {
        let list = try AILockList.parse(try AIFixtures.text(named: "ai-lock"))
        let text = try PFAnchorRenderer.render(intent: .armed, utun: "utun3", list: list)
        XCTAssertTrue(
            text.contains(
                "block drop out quick inet to 160.79.104.0/23 label \"segue-ai-0\""))
        XCTAssertTrue(
            text.contains(
                "block drop out quick inet to 153.61.224.0/22 label \"segue-ai-1\""))
        XCTAssertTrue(
            text.contains(
                "block drop out quick inet6 to 2607:6bc0::/48 label \"segue-ai-2\""))
    }

    func testDisarmedRendersNoRules() throws {
        let list = AILockList(suffixes: [], cidrs: [v4])
        let text = try PFAnchorRenderer.render(intent: .disarmed, utun: "utun7", list: list)
        XCTAssertEqual(
            text,
            """
            # segue.ailock — managed by Segue; do not edit
            """ + "\n")
    }

    func testAnchorEndsWithANewline() throws {
        let text = try PFAnchorRenderer.render(
            intent: .armed, utun: nil, list: AILockList(suffixes: [], cidrs: [v4]))
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    func testNonUtunInterfaceNamesAreRejected() {
        let list = AILockList(suffixes: [], cidrs: [v4])
        for name in ["en0", "utun", "utun8x", "tun0", "utun-4", "utun999999999999999", "lo0"] {
            XCTAssertThrowsError(
                try PFAnchorRenderer.render(intent: .armed, utun: name, list: list),
                "expected rejection for \(name)"
            ) { error in
                XCTAssertEqual(error as? PFAnchorError, .invalidInterface(name))
            }
        }
    }

    func testPlainUtunNamesAreAccepted() throws {
        let list = AILockList(suffixes: [], cidrs: [v4])
        for name in ["utun0", "utun7", "utun12345"] {
            let text = try PFAnchorRenderer.render(intent: .armed, utun: name, list: list)
            XCTAssertTrue(text.contains("pass quick on \(name)\n"))
        }
    }
}

final class PFConfHookTests: XCTestCase {
    /// The stock macOS pf.conf shape (Apple's, not Segue's).
    private let stock = """
        #
        # com.apple anchor point
        #
        scrub-anchor "com.apple/*"
        nat-anchor "com.apple/*"
        rdr-anchor "com.apple/*"
        dummynet-anchor "com.apple/*"
        anchor "com.apple/*"
        load anchor "com.apple" from "/etc/pf.anchors/com.apple"

        """

    func testHookIsAppendedToTheStockFileOnce() throws {
        let result = try PFConfHook.ensure(stock)
        XCTAssertTrue(result.inserted)
        XCTAssertEqual(
            result.text,
            stock + "anchor \"segue.ailock\"\n",
            "everything but the appended hook line must survive byte-for-byte")
    }

    func testFileWithoutTrailingNewlineGetsOneOnlyBeforeTheHook() throws {
        let text = "scrub-anchor \"com.apple/*\"\nanchor \"com.apple/*\""
        let result = try PFConfHook.ensure(text)
        XCTAssertEqual(result.text, text + "\nanchor \"segue.ailock\"\n")
    }

    func testEmptyFileBecomesJustTheHook() throws {
        let result = try PFConfHook.ensure("")
        XCTAssertEqual(result.text, "anchor \"segue.ailock\"\n")
        XCTAssertTrue(result.inserted)
    }

    func testEnsureIsIdempotent() throws {
        let once = try PFConfHook.ensure(stock).text
        let twice = try PFConfHook.ensure(once)
        XCTAssertFalse(twice.inserted)
        XCTAssertEqual(twice.text, once)
        XCTAssertTrue(try PFConfHook.verify(once))
        XCTAssertFalse(try PFConfHook.verify(stock))
    }

    func testHookSurvivesWhenOtherLinesChangedAroundIt() throws {
        let hooked = try PFConfHook.ensure(stock).text
        let edited = hooked.replacingOccurrences(
            of: "load anchor \"com.apple\"", with: "load anchor \"com.apple\" ")
        XCTAssertFalse(try PFConfHook.ensure(edited).inserted)
    }

    func testDuplicatedHookIsRejected() {
        let duplicated = stock + "anchor \"segue.ailock\"\nanchor \"segue.ailock\"\n"
        XCTAssertThrowsError(try PFConfHook.ensure(duplicated)) { error in
            XCTAssertEqual(error as? PFConfHookError, .duplicatedHook)
        }
    }

    func testForeignSegueAnchorIsRejected() {
        let foreign = stock + "anchor \"segue.other\"\n"
        XCTAssertThrowsError(try PFConfHook.ensure(foreign)) { error in
            XCTAssertEqual(
                error as? PFConfHookError, .foreignAnchor(name: "segue.other"))
        }
    }

    func testForeignDirectiveOnOurAnchorNameIsRejected() {
        // The helper writes `anchor` only; a scrub/nat/rdr anchor wearing the
        // same name was not written by this code.
        for directive in ["scrub-anchor", "nat-anchor", "rdr-anchor", "dummynet-anchor"] {
            let text = stock + "\(directive) \"segue.ailock\"\n"
            XCTAssertThrowsError(try PFConfHook.ensure(text), "expected rejection: \(directive)")
        }
    }

    func testBootLoadDirectiveIsRejected() {
        let loaded = stock + "load anchor \"segue.ailock\" from \"/etc/pf.anchors/segue\"\n"
        XCTAssertThrowsError(try PFConfHook.ensure(loaded)) { error in
            XCTAssertEqual(
                error as? PFConfHookError, .bootLoadDirective(name: "segue.ailock"))
        }
    }

    func testBootLoadOfAForeignSegueAnchorIsRejected() {
        let loaded = stock + "load anchor \"segue.other\" from \"/etc/pf.anchors/segue\"\n"
        XCTAssertThrowsError(try PFConfHook.ensure(loaded)) { error in
            XCTAssertEqual(
                error as? PFConfHookError, .foreignAnchor(name: "segue.other"))
        }
    }

    func testAppleAnchorsAreLeftAloneAndNotForeign() throws {
        // The stock file carries Apple's own `load anchor "com.apple" from`
        // and anchor wildcards; none of that is in Segue's namespace, so a
        // present hook still verifies clean next to it.
        let hooked = try PFConfHook.ensure(stock).text
        XCTAssertTrue(try PFConfHook.verify(hooked))
        XCTAssertTrue(hooked.contains("load anchor \"com.apple\" from \"/etc/pf.anchors/com.apple\""))
    }

    func testCommentLinesAndBlankLinesAreIgnored() throws {
        let text = """
            # anchor "segue.other" mentioned in a comment

            # anchor "segue.ailock"
            pass in all
            """
        let result = try PFConfHook.ensure(text)
        XCTAssertTrue(result.inserted)
        XCTAssertTrue(result.text.hasSuffix("pass in all\nanchor \"segue.ailock\"\n"))
    }
}
