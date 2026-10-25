import XCTest
@testable import SessionCore

final class BlockListTests: XCTestCase {
    private let list = BlockList(apps: ["com.tencent.xinWeChat"], domains: ["youtube.com", "twitter.com"])

    func testBlockedAppIsHidden() {
        XCTAssertEqual(list.decide(bundleId: "com.tencent.xinWeChat", urlHost: nil), .hideApp(bundleId: "com.tencent.xinWeChat"))
    }
    func testExactAndSubdomainMatch() {
        XCTAssertEqual(list.decide(bundleId: "com.google.Chrome", urlHost: "youtube.com"), .redirectSite(host: "youtube.com"))
        XCTAssertEqual(list.decide(bundleId: "com.google.Chrome", urlHost: "www.youtube.com"), .redirectSite(host: "www.youtube.com"))
        XCTAssertEqual(list.decide(bundleId: "com.google.Chrome", urlHost: "m.TWITTER.com"), .redirectSite(host: "m.twitter.com"))
    }
    func testLookalikeDomainIsNotBlocked() {
        XCTAssertEqual(list.decide(bundleId: "com.google.Chrome", urlHost: "notyoutube.com"), .allow)
        XCTAssertEqual(list.decide(bundleId: "com.google.Chrome", urlHost: "youtube.com.evil.org"), .allow)
    }
    func testAppRuleWinsOverSiteRule() {
        let both = BlockList(apps: ["com.google.Chrome"], domains: ["youtube.com"])
        XCTAssertEqual(both.decide(bundleId: "com.google.Chrome", urlHost: "youtube.com"), .hideApp(bundleId: "com.google.Chrome"))
    }
    func testNothingBlockedWhenEmptyOrUnknown() {
        XCTAssertEqual(BlockList().decide(bundleId: "x", urlHost: "youtube.com"), .allow)
        XCTAssertEqual(list.decide(bundleId: nil, urlHost: nil), .allow)
    }
    func testParsesCommaSeparatedLists() {
        let l = BlockList(appsCSV: " a.b , c.d ,,", domainsCSV: "Foo.com, bar.org ")
        XCTAssertEqual(l.apps, ["a.b", "c.d"])
        XCTAssertEqual(l.domains, ["foo.com", "bar.org"])
    }
    func testMergedCombinesBothLists() {
        let m = BlockList(apps: ["a"], domains: ["x.com"]).merged(with: BlockList(apps: ["b"], domains: ["y.com"]))
        XCTAssertEqual(m.apps, ["a", "b"])
        XCTAssertEqual(m.domains, ["x.com", "y.com"])
    }
}
