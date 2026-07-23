import CoreGraphics

enum WeiboVisualMetrics {
    static let topMargin: CGFloat = 8
    static let contentInset: CGFloat = 12
    static let textPadding: CGFloat = 10
    static let pictureSpacing: CGFloat = 4
    static let profileHeight: CGFloat = 56
    static let nameAvatarSpacing: CGFloat = 14
    static let toolbarHeight: CGFloat = 35
    static let toolbarBottomMargin: CGFloat = 2
    static let nameFontSize: CGFloat = 16
    static let sourceFontSize: CGFloat = 12
    static let bodyFontSize: CGFloat = 17
    static let repostFontSize: CGFloat = 16
    static let link = FeedRGBA(hex: 0x527EAD)
    static let innerBackground = FeedRGBA(hex: 0xF7F7F7)
}

extension FeedRGBA {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
