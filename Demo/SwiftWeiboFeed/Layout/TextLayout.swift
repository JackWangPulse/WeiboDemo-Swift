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

public struct TextAttachment: @unchecked Sendable {
    public let image: CGImage
    public let frame: CGRect
}

public struct TextLayout: Sendable {
    public let storage: CoreTextLayoutStorage
    public let bounds: CGRect
    public let regions: [InteractionRegion]
    public let attachments: [TextAttachment]
    /// Lines whose pixels are identical in the collapsed and expanded layouts.
    /// Keeping this boundary in the immutable layout lets the display layer retain
    /// those pixels when only the expandable tail changes.
    public let stablePrefixLineCount: Int

    public init(storage: CoreTextLayoutStorage, bounds: CGRect, regions: [InteractionRegion], attachments: [TextAttachment] = [], stablePrefixLineCount: Int = 0) {
        self.storage = storage
        self.bounds = bounds
        self.regions = regions
        self.attachments = attachments
        self.stablePrefixLineCount = min(max(0, stablePrefixLineCount), storage.lines.count)
    }

    public var stablePrefixFragment: TextRenderFragment? {
        guard stablePrefixLineCount > 0 else { return nil }
        return fragment(for: 0..<stablePrefixLineCount)
    }

    public var mutableTailFragment: TextRenderFragment {
        fragment(for: stablePrefixLineCount..<storage.lines.count)
    }

    private func fragment(for range: Range<Int>) -> TextRenderFragment {
        guard !range.isEmpty, !storage.lines.isEmpty else {
            return TextRenderFragment(storage: CoreTextLayoutStorage(lines: [], origins: []), bounds: .zero, attachments: [])
        }
        let lineHeight = bounds.height / CGFloat(storage.lines.count)
        let fragmentBounds = CGRect(
            x: bounds.minX,
            y: bounds.minY + CGFloat(range.lowerBound) * lineHeight,
            width: bounds.width,
            height: CGFloat(range.count) * lineHeight
        )
        let fragmentAttachments = attachments.filter { fragmentBounds.intersects($0.frame) }
        return TextRenderFragment(
            storage: CoreTextLayoutStorage(
                lines: Array(storage.lines[range]),
                origins: Array(storage.origins[range])
            ),
            bounds: fragmentBounds,
            attachments: fragmentAttachments
        )
    }
}

public struct TextRenderFragment: Sendable {
    public let storage: CoreTextLayoutStorage
    public let bounds: CGRect
    public let attachments: [TextAttachment]

    public init(storage: CoreTextLayoutStorage, bounds: CGRect, attachments: [TextAttachment]) {
        self.storage = storage
        self.bounds = bounds
        self.attachments = attachments
    }
}
