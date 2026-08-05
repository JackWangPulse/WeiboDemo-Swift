import Foundation

enum WeiboNameBadge: Equatable, Sendable {
    case enterpriseVIP
    case membership(rank: Int)
}

struct WeiboUserPresentation: Equatable, Sendable {
    // 输出三个显示结果 昵称颜色 昵称右侧徽章，可能有多个 头像右下角认证图标
    let nameColor: FeedRGBA
    let nameBadges: [WeiboNameBadge]
    let avatarBadge: WeiboResource?

    init(user: FeedUser) {
        let verification = Verification(user: user)
        nameColor = user.membershipRank > 0
            ? Self.memberNameColor
            : Self.normalNameColor

        var badges = [WeiboNameBadge]()
        if verification == .organization {
            badges.append(.enterpriseVIP)
        }
        if user.membershipRank > 0 {
            badges.append(.membership(rank: user.membershipRank))
        }
        nameBadges = badges

        switch verification {
        case .standard:
            avatarBadge = .avatarVIP
        case .club:
            avatarBadge = .avatarGrassroot
        case .none, .organization:
            avatarBadge = nil
        }
    }

    private static let normalNameColor = FeedRGBA(
        red: 0x33 / 255.0,
        green: 0x33 / 255.0,
        blue: 0x33 / 255.0,
        alpha: 1
    )
    private static let memberNameColor = FeedRGBA(
        red: 0xF2 / 255.0,
        green: 0x62 / 255.0,
        blue: 0x20 / 255.0,
        alpha: 1
    )
}

private extension WeiboUserPresentation {
    enum Verification {
        case none
        case standard
        case organization
        case club

        init(user: FeedUser) {
            if user.isVerified {
                self = .standard
            } else if user.verifiedType == 220 {
                self = .club
            } else if user.verifiedType == -1, user.verifiedLevel == 3 {
                self = .organization
            } else {
                self = .none
            }
        }
    }
}
