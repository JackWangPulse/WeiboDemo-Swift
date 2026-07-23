import XCTest
@testable import SwiftWeiboFeed

final class WeiboResourceProviderTests: XCTestCase {
    func testRequiredTimelineResourcesResolveFromBundledDemoAssets() {
        let provider = WeiboResourceProvider(bundle: .main)
        let required: [WeiboResource] = [
            .toolbarRepost,
            .toolbarComment,
            .toolbarUnlike,
            .toolbarLike,
            .avatarVIP,
            .avatarEnterpriseVIP,
            .avatarGrassroot,
            .timelineMore,
            .timelineGIF,
            .timelineLongImage,
        ]

        for resource in required {
            XCTAssertNotNil(provider.image(resource), "\(resource) must resolve")
        }
    }

    func testMembershipRankUsesSpecificImageThenGenericFallback() {
        let provider = WeiboResourceProvider(bundle: .main)

        XCTAssertNotNil(provider.membershipImage(rank: 1))
        XCTAssertNotNil(provider.membershipImage(rank: 99))
    }
}
