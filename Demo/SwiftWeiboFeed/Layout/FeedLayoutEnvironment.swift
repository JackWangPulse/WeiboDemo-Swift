import CoreGraphics
import UIKit

public struct FeedRGBA: Hashable, Sendable {
    public let red: Double, green: Double, blue: Double, alpha: Double
    var cgColor: CGColor { CGColor(red: red, green: green, blue: blue, alpha: alpha) }
}

public struct FeedPalette: Hashable, Sendable {
    public let background: FeedRGBA
    public let primaryText: FeedRGBA
    public let secondaryText: FeedRGBA
    public let accent: FeedRGBA
    public let repostBackground: FeedRGBA
    public let separator: FeedRGBA
    public let icon: FeedRGBA
}

public struct FeedLayoutEnvironment: Hashable, Sendable {
    public let containerPixelWidth: Int
    public let displayScale: Int
    public let contentSizeCategory: String
    public let themeVersion: UInt
    public let layoutAlgorithmVersion: UInt
    public let bodyFontSize: Double
    public let bodyLineHeight: Double
    public let palette: FeedPalette

    public init(
        width: CGFloat,
        scale: CGFloat,
        contentSizeCategory: UIContentSizeCategory,
        themeVersion: UInt,
        algorithmVersion: UInt
    ) {
        containerPixelWidth = Int((width * scale).rounded())
        displayScale = Int(scale.rounded())
        self.contentSizeCategory = contentSizeCategory.rawValue
        self.themeVersion = themeVersion
        layoutAlgorithmVersion = algorithmVersion
        let scale: Double
        switch contentSizeCategory {
        case .extraSmall: scale = 0.82
        case .small: scale = 0.9
        case .medium: scale = 0.95
        case .large: scale = 1
        case .extraLarge: scale = 1.12
        case .extraExtraLarge: scale = 1.24
        case .extraExtraExtraLarge: scale = 1.36
        default: scale = contentSizeCategory.isAccessibilityCategory ? 1.65 : 1
        }
        bodyFontSize = 16 * scale
        bodyLineHeight = 20 * scale
        if themeVersion == 0 {
            palette = FeedPalette(background: FeedRGBA(red: 1, green: 1, blue: 1, alpha: 1), primaryText: FeedRGBA(red: 0.08, green: 0.08, blue: 0.09, alpha: 1), secondaryText: FeedRGBA(red: 0.42, green: 0.42, blue: 0.45, alpha: 1), accent: FeedRGBA(red: 0.05, green: 0.42, blue: 0.9, alpha: 1), repostBackground: FeedRGBA(red: 0.96, green: 0.96, blue: 0.97, alpha: 1), separator: FeedRGBA(red: 0.82, green: 0.82, blue: 0.84, alpha: 1), icon: FeedRGBA(red: 0.35, green: 0.35, blue: 0.38, alpha: 1))
        } else {
            palette = FeedPalette(background: FeedRGBA(red: 0.07, green: 0.07, blue: 0.08, alpha: 1), primaryText: FeedRGBA(red: 0.93, green: 0.93, blue: 0.95, alpha: 1), secondaryText: FeedRGBA(red: 0.62, green: 0.62, blue: 0.66, alpha: 1), accent: FeedRGBA(red: 0.35, green: 0.68, blue: 1, alpha: 1), repostBackground: FeedRGBA(red: 0.12, green: 0.12, blue: 0.14, alpha: 1), separator: FeedRGBA(red: 0.28, green: 0.28, blue: 0.31, alpha: 1), icon: FeedRGBA(red: 0.68, green: 0.68, blue: 0.72, alpha: 1))
        }
    }

    @MainActor
    public static func resolve(width: CGFloat, scale: CGFloat, contentSizeCategory: UIContentSizeCategory, themeVersion: UInt, algorithmVersion: UInt) -> Self {
        Self(width: width, scale: scale, contentSizeCategory: contentSizeCategory, themeVersion: themeVersion, algorithmVersion: algorithmVersion)
    }
}
public struct FeedLayoutIdentity: Hashable, Sendable {
    public let content: FeedContentIdentity
    public let environment: FeedLayoutEnvironment

    public init(content: FeedContentIdentity, environment: FeedLayoutEnvironment) {
        self.content = content
        self.environment = environment
    }
}
