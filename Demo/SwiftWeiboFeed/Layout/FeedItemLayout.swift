import CoreGraphics

public struct ProfileLayout: Sendable {
    public let frame: CGRect
    public let avatarFrame: CGRect
    public let name: TextLayout
    public let time: TextLayout?
    public let source: TextLayout?
    public let verificationFrame: CGRect?
    public let accessibilityLabel: String
    public let regions: [InteractionRegion]

    public init(frame: CGRect, avatarFrame: CGRect, name: TextLayout, time: TextLayout?, source: TextLayout?, verificationFrame: CGRect?, accessibilityLabel: String, regions: [InteractionRegion]) {
        self.frame = frame
        self.avatarFrame = avatarFrame
        self.name = name
        self.time = time
        self.source = source
        self.verificationFrame = verificationFrame
        self.accessibilityLabel = accessibilityLabel
        self.regions = regions
    }
}

public struct CardLayout: Sendable {
    public let frame: CGRect
    public let imageFrame: CGRect?
    public let text: TextLayout
    public let regions: [InteractionRegion]

    public init(frame: CGRect, imageFrame: CGRect?, text: TextLayout, regions: [InteractionRegion]) {
        self.frame = frame
        self.imageFrame = imageFrame
        self.text = text
        self.regions = regions
    }
}

public struct TagLayout: Sendable {
    public let frame: CGRect
    public let text: TextLayout
    public let regions: [InteractionRegion]

    public init(frame: CGRect, text: TextLayout, regions: [InteractionRegion]) {
        self.frame = frame
        self.text = text
        self.regions = regions
    }
}

public struct RepostLayout: Sendable {
    public let frame: CGRect
    public let body: TextLayout
    public let mediaFrames: [CGRect]
    public let card: CardLayout?

    public init(frame: CGRect, body: TextLayout, mediaFrames: [CGRect], card: CardLayout?) {
        self.frame = frame
        self.body = body
        self.mediaFrames = mediaFrames
        self.card = card
    }
}

public struct ToolbarLayout: Sendable {
    public let frame: CGRect
    public let regions: [InteractionRegion]
    public let items: [ToolbarItemLayout]

    public init(frame: CGRect, regions: [InteractionRegion], items: [ToolbarItemLayout] = []) {
        self.frame = frame
        self.regions = regions
        self.items = items
    }
}

public struct ToolbarItemLayout: Sendable {
    public let action: FeedAction
    public let iconFrame: CGRect
    public let count: TextLayout

    public init(action: FeedAction, iconFrame: CGRect, count: TextLayout) {
        self.action = action
        self.iconFrame = iconFrame
        self.count = count
    }
}

public struct FeedItemLayout: Sendable {
    public let identity: FeedLayoutIdentity
    public let height: CGFloat
    public let profile: ProfileLayout
    public let body: TextLayout
    public let mediaFrames: [CGRect]
    public let repost: RepostLayout?
    public let card: CardLayout?
    public let tag: TagLayout?
    public let toolbar: ToolbarLayout

    public init(
        identity: FeedLayoutIdentity,
        height: CGFloat,
        profile: ProfileLayout,
        body: TextLayout,
        mediaFrames: [CGRect],
        repost: RepostLayout?,
        card: CardLayout?,
        tag: TagLayout?,
        toolbar: ToolbarLayout
    ) {
        self.identity = identity
        self.height = height
        self.profile = profile
        self.body = body
        self.mediaFrames = mediaFrames
        self.repost = repost
        self.card = card
        self.tag = tag
        self.toolbar = toolbar
    }

    public var allFrames: [CGRect] {
        var frames = [profile.frame, profile.avatarFrame, profile.name.bounds, body.bounds]
        if let time = profile.time { frames.append(time.bounds) }
        if let source = profile.source { frames.append(source.bounds) }
        if let verificationFrame = profile.verificationFrame { frames.append(verificationFrame) }
        frames.append(contentsOf: profile.regions.flatMap(\.rects))
        frames.append(contentsOf: profile.name.storage.origins.map { CGRect(origin: $0, size: .zero) })
        frames.append(contentsOf: profile.time?.storage.origins.map { CGRect(origin: $0, size: .zero) } ?? [])
        frames.append(contentsOf: profile.source?.storage.origins.map { CGRect(origin: $0, size: .zero) } ?? [])
        frames.append(contentsOf: profile.name.regions.flatMap(\.rects))
        frames.append(contentsOf: profile.time?.regions.flatMap(\.rects) ?? [])
        frames.append(contentsOf: profile.source?.regions.flatMap(\.rects) ?? [])
        frames.append(contentsOf: body.storage.origins.map { CGRect(origin: $0, size: .zero) })
        frames.append(contentsOf: body.regions.flatMap(\.rects))
        frames.append(contentsOf: mediaFrames)
        if let repost {
            frames.append(repost.frame)
            frames.append(repost.body.bounds)
            frames.append(contentsOf: repost.body.storage.origins.map { CGRect(origin: $0, size: .zero) })
            frames.append(contentsOf: repost.body.regions.flatMap(\.rects))
            frames.append(contentsOf: repost.mediaFrames)
            if let card = repost.card { frames.append(contentsOf: card.allFrames) }
        }
        if let card { frames.append(contentsOf: card.allFrames) }
        if let tag { frames.append(contentsOf: tag.allFrames) }
        frames.append(toolbar.frame)
        frames.append(contentsOf: toolbar.regions.flatMap(\.rects))
        frames.append(contentsOf: toolbar.items.flatMap { [$0.iconFrame, $0.count.bounds] })
        return frames
    }
}

private extension CardLayout {
    var allFrames: [CGRect] {
        var frames = [frame, text.bounds]
        if let imageFrame { frames.append(imageFrame) }
        frames.append(contentsOf: text.storage.origins.map { CGRect(origin: $0, size: .zero) })
        frames.append(contentsOf: text.regions.flatMap(\.rects))
        frames.append(contentsOf: regions.flatMap(\.rects))
        return frames
    }
}

private extension TagLayout {
    var allFrames: [CGRect] {
        var frames = [frame, text.bounds]
        frames.append(contentsOf: text.storage.origins.map { CGRect(origin: $0, size: .zero) })
        frames.append(contentsOf: text.regions.flatMap(\.rects))
        frames.append(contentsOf: regions.flatMap(\.rects))
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
