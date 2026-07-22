import CoreGraphics

public struct RepostLayout: Sendable {
    public let frame: CGRect
    public let body: TextLayout
    public let mediaFrames: [CGRect]

    public init(frame: CGRect, body: TextLayout, mediaFrames: [CGRect]) {
        self.frame = frame
        self.body = body
        self.mediaFrames = mediaFrames
    }
}

public struct ToolbarLayout: Sendable {
    public let frame: CGRect
    public let regions: [InteractionRegion]

    public init(frame: CGRect, regions: [InteractionRegion]) {
        self.frame = frame
        self.regions = regions
    }
}

public struct FeedItemLayout: Sendable {
    public let identity: FeedLayoutIdentity
    public let height: CGFloat
    public let body: TextLayout
    public let avatarFrame: CGRect
    public let mediaFrames: [CGRect]
    public let repost: RepostLayout?
    public let toolbar: ToolbarLayout

    public init(
        identity: FeedLayoutIdentity,
        height: CGFloat,
        body: TextLayout,
        avatarFrame: CGRect,
        mediaFrames: [CGRect],
        repost: RepostLayout?,
        toolbar: ToolbarLayout
    ) {
        self.identity = identity
        self.height = height
        self.body = body
        self.avatarFrame = avatarFrame
        self.mediaFrames = mediaFrames
        self.repost = repost
        self.toolbar = toolbar
    }

    public var allFrames: [CGRect] {
        var frames = [body.bounds, avatarFrame]
        frames.append(contentsOf: mediaFrames)
        if let repost {
            frames.append(repost.frame)
            frames.append(repost.body.bounds)
            frames.append(contentsOf: repost.mediaFrames)
        }
        frames.append(toolbar.frame)
        return frames
    }
}

public extension CGRect {
    var isFiniteAndNonNegative: Bool {
        origin.x.isFinite && origin.y.isFinite &&
            size.width.isFinite && size.height.isFinite &&
            origin.x >= 0 && origin.y >= 0 &&
            size.width >= 0 && size.height >= 0
    }
}

