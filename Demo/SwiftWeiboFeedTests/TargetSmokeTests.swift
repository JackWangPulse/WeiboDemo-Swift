import XCTest
@testable import SwiftWeiboFeed

final class TargetSmokeTests: XCTestCase {
    func testTargetLoads() {
        XCTAssertEqual(SwiftWeiboFeedConfiguration.minimumOSMajorVersion, 16)
    }
}
