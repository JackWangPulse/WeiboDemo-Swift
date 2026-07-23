import CoreGraphics
import CoreText

public struct InteractionRegion: Sendable {
    public let rects: [CGRect]
    public let action: FeedAction
    public let accessibilityLabel: String

    public init(rects: [CGRect], action: FeedAction, accessibilityLabel: String) {
        self.rects = rects
        self.action = action
        self.accessibilityLabel = accessibilityLabel
    }
}
public final class CoreTextLayoutStorage: @unchecked Sendable {
    public let lines: [CTLine]
    public let origins: [CGPoint]

    public init(lines: [CTLine], origins: [CGPoint]) {
        self.lines = lines
        self.origins = origins
    }
}

public struct TextLayout: Sendable {
    public let storage: CoreTextLayoutStorage
    public let bounds: CGRect
    public let regions: [InteractionRegion]

    public init(storage: CoreTextLayoutStorage, bounds: CGRect, regions: [InteractionRegion]) {
        self.storage = storage
        self.bounds = bounds
        self.regions = regions
    }
}
