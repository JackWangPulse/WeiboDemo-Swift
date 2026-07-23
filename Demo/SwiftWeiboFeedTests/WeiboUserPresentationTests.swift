import XCTest
@testable import SwiftWeiboFeed

final class WeiboUserPresentationTests: XCTestCase {
    func testVerifiedMemberUsesOrangeNameMembershipAndVIPAvatarBadge() throws {
        let user = try decodeUser(
            """
            {"id":"u","name":"Member","verified":true,"verified_type":0,"mbrank":3}
            """
        )
        let presentation = WeiboUserPresentation(user: user)

        XCTAssertEqual(user.membershipRank, 3)
        XCTAssertEqual(
            presentation.nameColor,
            FeedRGBA(
                red: 0xF2 / 255.0,
                green: 0x62 / 255.0,
                blue: 0x20 / 255.0,
                alpha: 1
            )
        )
        XCTAssertEqual(presentation.nameBadges, [.membership(rank: 3)])
        XCTAssertEqual(presentation.avatarBadge, .avatarVIP)
    }

    func testOrganizationUsesEnterpriseNameBadgeAndNoAvatarBadge() throws {
        let user = try decodeUser(
            """
            {
              "id":"u",
              "name":"Organization",
              "verified":false,
              "verified_type":-1,
              "verified_level":3
            }
            """
        )
        let presentation = WeiboUserPresentation(user: user)

        XCTAssertEqual(presentation.nameBadges, [.enterpriseVIP])
        XCTAssertNil(presentation.avatarBadge)
    }

    func testClubUserUsesGrassrootAvatarBadge() throws {
        let user = try decodeUser(
            """
            {"id":"u","name":"Club","verified":false,"verified_type":220}
            """
        )

        XCTAssertEqual(
            WeiboUserPresentation(user: user).avatarBadge,
            .avatarGrassroot
        )
    }

    private func decodeUser(_ json: String) throws -> FeedUser {
        try JSONDecoder.weibo.decode(FeedUser.self, from: Data(json.utf8))
    }
}
