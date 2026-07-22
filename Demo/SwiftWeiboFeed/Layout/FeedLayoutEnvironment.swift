import CoreGraphics
import UIKit

public struct FeedLayoutEnvironment: Hashable, Sendable {
    public let containerPixelWidth: Int
    public let displayScale: Int
    public let contentSizeCategory: String
    public let themeVersion: UInt
    public let layoutAlgorithmVersion: UInt

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

