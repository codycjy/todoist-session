import XCTest
@testable import SessionCore

final class BlockPageLinkTests: XCTestCase {
    private let page = "file:///Users/me/Library/Application%20Support/Session/blocked.html"

    func testAcceptsOnlyHttpAndHttps() {
        XCTAssertTrue(BlockPageLink.isSafeOriginal(URL(string: "https://example.com/a")!))
        XCTAssertTrue(BlockPageLink.isSafeOriginal(URL(string: "HTTP://example.com")!))
        XCTAssertFalse(BlockPageLink.isSafeOriginal(URL(string: "file:///etc/passwd")!))
        XCTAssertFalse(BlockPageLink.isSafeOriginal(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(BlockPageLink.isSafeOriginal(URL(string: "data:text/html,hi")!))
    }

    func testFragmentRoundTrip() {
        let original = URL(string: "https://example.com/a?b=c&d=e#frag")!
        let frag = BlockPageLink.fragment(for: original)
        XCTAssertEqual(BlockPageLink.originalURL(fromTabURL: page + "#" + frag), original)
    }

    func testRejectsUnsafeSchemesInFragment() {
        for bad in ["javascript:alert(1)", "file:///etc/hosts", "data:text/html,x"] {
            let enc = bad.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            XCTAssertNil(BlockPageLink.originalURL(fromTabURL: page + "#o=" + enc), bad)
        }
    }

    func testRequiresExactBlockPagePath() {
        let enc = "https%3A%2F%2Fa.com"
        XCTAssertNil(BlockPageLink.originalURL(fromTabURL: "https://evil.com/Session/blocked.html#o=" + enc))
        XCTAssertNil(BlockPageLink.originalURL(fromTabURL: "file:///x/Session/blocked.html.bak#o=" + enc))
        XCTAssertNil(BlockPageLink.originalURL(fromTabURL: "file:///x/other.html?u=/Session/blocked.html#o=" + enc))
        XCTAssertNil(BlockPageLink.originalURL(fromTabURL: "file:///x/Session/blocked.html"))
        XCTAssertEqual(BlockPageLink.originalURL(fromTabURL: "file:///x/Session/blocked.html#o=" + enc),
                       URL(string: "https://a.com"))
    }

    func testAppleScriptEscaping() {
        XCTAssertEqual("plain".appleScriptEscaped, "plain")
        XCTAssertEqual(#"a"b"#.appleScriptEscaped, #"a\"b"#)
        XCTAssertEqual(#"a\b"#.appleScriptEscaped, #"a\\b"#)
        XCTAssertEqual(#"\""#.appleScriptEscaped, #"\\\""#)
        XCTAssertEqual("a\nb\rc".appleScriptEscaped, "a\\nb\\rc")
        XCTAssertEqual("https://x.com/\"&do shell script \"x".appleScriptEscaped,
                       "https://x.com/\\\"&do shell script \\\"x")
    }
}
