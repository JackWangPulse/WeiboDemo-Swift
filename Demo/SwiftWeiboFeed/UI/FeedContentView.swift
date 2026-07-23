import CoreText
import UIKit

@MainActor
public final class FeedContentView: UIView {
    let profileLayer: AsyncRenderLayer
    let bodyLayer: AsyncRenderLayer
    let repostLayer: AsyncRenderLayer
    let cardLayer: AsyncRenderLayer
    let tagLayer: AsyncRenderLayer
    let toolbarLayer: AsyncRenderLayer
    private let highlightLayer = CALayer()
    let avatarBadgeLayer = CALayer()
    private(set) var nameBadgeLayers: [CALayer] = []
    private(set) var imageLayers: [CALayer] = []
    private(set) var mediaLayers: [CALayer] = []
    private let resourceProvider: any WeiboResourceProviding

    var avatarLayer: CALayer? { imageLayers.first }

    private var entry: PreparedFeedEntry?
    private var interactionRegions: [InteractionRegion] = []
    private var selectedRegion: InteractionRegion?
    public var onAction: ((FeedAction) -> Void)?

    public override convenience init(frame: CGRect) {
        self.init(frame: frame, resourceProvider: WeiboResourceProvider.shared, layerFactory: { AsyncRenderLayer() })
    }

    init(
        frame: CGRect = .zero,
        resourceProvider: any WeiboResourceProviding = WeiboResourceProvider.shared,
        layerFactory: () -> AsyncRenderLayer
    ) {
        profileLayer = layerFactory(); bodyLayer = layerFactory(); repostLayer = layerFactory()
        cardLayer = layerFactory(); tagLayer = layerFactory(); toolbarLayer = layerFactory()
        self.resourceProvider = resourceProvider
        super.init(frame: frame)
        isAccessibilityElement = false
        isOpaque = true
        for node in [profileLayer, bodyLayer, repostLayer, cardLayer, tagLayer, toolbarLayer] {
            node.contentsGravity = .topLeft
            layer.addSublayer(node)
        }
        highlightLayer.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.14).cgColor
        highlightLayer.isHidden = true
        layer.addSublayer(highlightLayer)
        avatarBadgeLayer.contentsGravity = .resizeAspect
        layer.addSublayer(avatarBadgeLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func apply(_ entry: PreparedFeedEntry) {
        cancelInteraction()
        backgroundColor = .clear
        isAccessibilityElement = false
        accessibilityLabel = nil
        self.entry = entry
        let layout = entry.layout
        backgroundColor = UIColor(cgColor: layout.identity.environment.palette.background.cgColor)
        frame.size.height = layout.height
        profileLayer.frame = layout.profile.frame
        bodyLayer.frame = layout.body.bounds
        repostLayer.frame = layout.repost?.frame ?? .zero
        cardLayer.frame = layout.card?.frame ?? .zero
        tagLayer.frame = layout.tag?.frame ?? .zero
        toolbarLayer.frame = layout.toolbar.frame
        rebuildImageLayers(entry)
        configureProfileDecorations(entry)
        interactionRegions = Self.regions(layout)
        rebuildAccessibility(entry)
    }

    func display(entry: PreparedFeedEntry, generation: UInt, scale: CGFloat) {
        let layout = entry.layout
        let palette = layout.identity.environment.palette
        let moreImage = resourceProvider.image(.timelineMore)
        let toolbarImages = layout.toolbar.items.map { resourceProvider.image($0.resource) }
        display(profileLayer, frame: layout.profile.frame, identity: identity(entry, .profile, generation), scale: scale) { context, token in
            Self.fill(context, size: layout.profile.frame.size, color: palette.background)
            Self.draw(layout.profile.name, in: context, region: layout.profile.frame, token: token)
            if let time = layout.profile.time { Self.draw(time, in: context, region: layout.profile.frame, token: token) }
            if let source = layout.profile.source { Self.draw(source, in: context, region: layout.profile.frame, token: token) }
            if let moreImage {
                Self.drawImage(moreImage, frame: CGRect(x: layout.profile.frame.width - 32, y: 10, width: 20, height: 20), context: context)
            }
        }
        display(bodyLayer, frame: layout.body.bounds, identity: identity(entry, .body, generation), scale: scale) { Self.draw(layout.body, in: $0, region: layout.body.bounds, token: $1) }
        if let repost = layout.repost {
            display(repostLayer, frame: repost.frame, identity: identity(entry, .repost, generation), scale: scale) { context, token in
                Self.fill(context, size: repost.frame.size, color: palette.repostBackground)
                Self.draw(repost.body, in: context, region: repost.frame, token: token)
                if let card = repost.card { Self.strokeSeparator(context, globalY: card.frame.minY, region: repost.frame, color: palette.separator); Self.draw(card.text, in: context, region: repost.frame, token: token) }
            }
        }
        if let card = layout.card { display(cardLayer, frame: card.frame, identity: identity(entry, .card, generation), scale: scale) { context, token in Self.fill(context, size: card.frame.size, color: palette.repostBackground); Self.strokeSeparator(context, globalY: card.frame.minY, region: card.frame, color: palette.separator); Self.draw(card.text, in: context, region: card.frame, token: token) } }
        if let tag = layout.tag { display(tagLayer, frame: tag.frame, identity: identity(entry, .tag, generation), scale: scale) { context, token in Self.fill(context, size: tag.frame.size, color: palette.repostBackground); Self.draw(tag.text, in: context, region: tag.frame, token: token) } }
        display(toolbarLayer, frame: layout.toolbar.frame, identity: identity(entry, .toolbar, generation), scale: scale) { context, token in
            guard !token.isCancelled else { return }
            Self.strokeSeparator(context, globalY: layout.toolbar.frame.minY, region: layout.toolbar.frame, color: palette.separator)
            for (item, image) in zip(layout.toolbar.items, toolbarImages) {
                guard !token.isCancelled else { return }
                if let image {
                    Self.drawImage(image, frame: item.iconFrame.offsetBy(dx: -layout.toolbar.frame.minX, dy: -layout.toolbar.frame.minY), context: context)
                }
                Self.draw(item.count, in: context, region: layout.toolbar.frame, token: token)
            }
        }
    }

    public func action(at point: CGPoint) -> FeedAction? {
        interactionRegions.first { region in region.rects.contains { $0.contains(point) } }?.action
    }

    func imageBindings(for entry: PreparedFeedEntry, scale: CGFloat) -> [(URL, CGRect, CALayer)] {
        var sources: [(URL?, CGRect)] = [(entry.item.user.avatarURL, entry.layout.profile.avatarFrame)]
        sources += zip(entry.item.pictures.map(\.url), entry.layout.mediaFrames).map { ($0.0, $0.1) }
        if let repost = entry.item.repost, let repostLayout = entry.layout.repost {
            sources += zip(repost.pictures.map(\.url), repostLayout.mediaFrames).map { ($0.0, $0.1) }
            if let imageFrame = repostLayout.card?.imageFrame { sources.append((repost.card?.imageURL, imageFrame)) }
        }
        if let imageFrame = entry.layout.card?.imageFrame { sources.append((entry.item.card?.imageURL, imageFrame)) }
        return zip(sources, imageLayers).compactMap { source, layer in source.0.map { ($0, source.1, layer) } }
    }

    func clear() {
        cancelInteraction()
        entry = nil; interactionRegions = []; accessibilityElements = nil
        cancelRendering()
        for node in [profileLayer, bodyLayer, repostLayer, cardLayer, tagLayer, toolbarLayer] { node.frame = .zero }
        imageLayers.forEach { $0.contents = nil; $0.removeFromSuperlayer() }
        imageLayers.removeAll(); mediaLayers.removeAll()
        avatarBadgeLayer.contents = nil; avatarBadgeLayer.frame = .zero
        nameBadgeLayers.forEach { $0.removeFromSuperlayer() }; nameBadgeLayers.removeAll()
        highlightLayer.isHidden = true
    }

    func cancelRendering() {
        for node in [profileLayer, bodyLayer, repostLayer, cardLayer, tagLayer, toolbarLayer] {
            node.cancelDisplay()
            node.contents = nil
        }
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let point = touches.first?.location(in: self) { beginInteraction(at: point) }
    }
    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { if let point = touches.first?.location(in: self) { endInteraction(at: point) } else { cancelInteraction() } }
    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancelInteraction() }

    func beginInteraction(at point: CGPoint) {
        selectedRegion = region(at: point)
        guard let selectedRegion else { return }
        highlightLayer.frame = selectedRegion.rects.reduce(.null) { $0.union($1) }
        highlightLayer.isHidden = false
    }

    func endInteraction(at point: CGPoint) {
        let selected = selectedRegion; cancelInteraction()
        guard let selected, selected.rects.contains(where: { $0.contains(point) }) else { return }
        onAction?(selected.action)
    }

    private func cancelInteraction() { selectedRegion = nil; highlightLayer.isHidden = true }
    private func region(at point: CGPoint) -> InteractionRegion? { interactionRegions.first { $0.rects.contains { $0.contains(point) } } }

    private func rebuildImageLayers(_ entry: PreparedFeedEntry) {
        imageLayers.forEach { $0.contents = nil; $0.removeFromSuperlayer() }
        var frames = [entry.layout.profile.avatarFrame] + entry.layout.mediaFrames
        if let repost = entry.layout.repost { frames += repost.mediaFrames; if let image = repost.card?.imageFrame { frames.append(image) } }
        if let image = entry.layout.card?.imageFrame { frames.append(image) }
        imageLayers = frames.map { frame in
            let node = CALayer(); node.frame = frame; node.contentsGravity = .resizeAspectFill; node.masksToBounds = true; node.backgroundColor = UIColor.systemGray5.cgColor; layer.addSublayer(node); return node
        }
        if let avatarLayer = imageLayers.first {
            avatarLayer.cornerRadius = entry.layout.profile.avatarFrame.width / 2
            avatarLayer.borderWidth = 1 / CGFloat(max(entry.layout.identity.environment.displayScale, 1))
            avatarLayer.borderColor = UIColor(white: 0, alpha: 0.09).cgColor
        }
        let mediaCount = entry.layout.mediaFrames.count + (entry.layout.repost?.mediaFrames.count ?? 0)
        mediaLayers = Array(imageLayers.dropFirst().prefix(mediaCount))
        layer.addSublayer(highlightLayer)
        layer.addSublayer(avatarBadgeLayer)
    }

    private func configureProfileDecorations(_ entry: PreparedFeedEntry) {
        let presentation = WeiboUserPresentation(user: entry.item.user)
        avatarBadgeLayer.contents = presentation.avatarBadge.flatMap(resourceProvider.image)
        avatarBadgeLayer.frame = presentation.avatarBadge == nil
            ? .zero
            : CGRect(
                x: entry.layout.profile.avatarFrame.maxX - 11,
                y: entry.layout.profile.avatarFrame.maxY - 11,
                width: 14,
                height: 14
            )

        nameBadgeLayers.forEach { $0.removeFromSuperlayer() }
        nameBadgeLayers.removeAll()
        let lineWidth = entry.layout.profile.name.storage.lines.first.map {
            CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil))
        } ?? 0
        var x = min(entry.layout.profile.name.bounds.maxX - 16, entry.layout.profile.name.bounds.minX + lineWidth + 3)
        for badge in presentation.nameBadges {
            let image: CGImage?
            switch badge {
            case .enterpriseVIP: image = resourceProvider.image(.avatarEnterpriseVIP)
            case let .membership(rank): image = resourceProvider.membershipImage(rank: rank)
            }
            guard let image else { continue }
            let node = CALayer()
            node.contents = image
            node.contentsGravity = .resizeAspect
            node.frame = CGRect(x: x, y: entry.layout.profile.name.bounds.minY + 2, width: 16, height: 16)
            layer.addSublayer(node)
            nameBadgeLayers.append(node)
            x += 18
        }
        layer.addSublayer(highlightLayer)
        layer.addSublayer(avatarBadgeLayer)
    }

    private func rebuildAccessibility(_ entry: PreparedFeedEntry) {
        var elements: [UIAccessibilityElement] = []
        func append(label: String, frame: CGRect, traits: UIAccessibilityTraits = .button, action: FeedAction? = nil) {
            let element = FeedAccessibilityElement(accessibilityContainer: self, action: action) { [weak self] action in self?.onAction?(action) }
            element.accessibilityLabel = label; element.accessibilityTraits = traits; element.accessibilityFrameInContainerSpace = frame; elements.append(element)
        }
        for span in entry.parsed.spans where span.kind == .plain {
            let plainBody = String(entry.parsed.source[span.range])
            if !plainBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                append(label: plainBody, frame: entry.layout.body.bounds, traits: .staticText)
            }
        }
        if let repostLayout = entry.layout.repost, let parsedRepost = entry.parsedRepost {
            let plainRepost = parsedRepost.spans.filter { $0.kind == .plain }.map { String(parsedRepost.source[$0.range]) }.joined()
            if !plainRepost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                append(label: plainRepost, frame: repostLayout.body.bounds, traits: .staticText)
            }
        }
        for region in interactionRegions { append(label: region.accessibilityLabel, frame: region.rects.reduce(.null) { $0.union($1) }, action: region.action) }
        for (index, frame) in entry.layout.mediaFrames.enumerated() { append(label: "Media \(index + 1)", frame: frame, traits: .image) }
        if let repost = entry.layout.repost {
            for (index, frame) in repost.mediaFrames.enumerated() { append(label: "Repost media \(index + 1)", frame: frame, traits: .image) }
        }
        elements.sort {
            if $0.accessibilityFrameInContainerSpace.minY != $1.accessibilityFrameInContainerSpace.minY {
                return $0.accessibilityFrameInContainerSpace.minY < $1.accessibilityFrameInContainerSpace.minY
            }
            return $0.accessibilityFrameInContainerSpace.minX < $1.accessibilityFrameInContainerSpace.minX
        }
        accessibilityElements = elements
    }

    private func identity(_ entry: PreparedFeedEntry, _ region: RenderRegion, _ generation: UInt) -> RenderIdentity { RenderIdentity(layout: entry.layout.identity, region: region, generation: generation) }
    private func display(_ node: AsyncRenderLayer, frame: CGRect, identity: RenderIdentity, scale: CGFloat, draw: @escaping (CGContext, DisplayCancellationToken) -> Void) {
        guard !frame.isEmpty else { node.cancelDisplay(); node.contents = nil; return }
        node.display(AsyncDisplayTask(identity: identity, size: frame.size, scale: scale, draw: draw))
    }
    static func draw(_ text: TextLayout, in context: CGContext, region: CGRect, token: DisplayCancellationToken) {
        context.saveGState(); context.textMatrix = .identity
        for (line, origin) in zip(text.storage.lines, text.storage.origins) { guard !token.isCancelled else { break }; context.textPosition = CGPoint(x: origin.x - region.minX, y: region.height - (origin.y - region.minY)); CTLineDraw(line, context) }
        for attachment in text.attachments where !token.isCancelled {
            let local = CGRect(x: attachment.frame.minX - region.minX, y: region.height - (attachment.frame.maxY - region.minY), width: attachment.frame.width, height: attachment.frame.height)
            context.draw(attachment.image, in: local)
        }
        context.restoreGState()
    }
    private static func fill(_ context: CGContext, size: CGSize, color: (CGFloat, CGFloat, CGFloat, CGFloat)) { context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: color.3); context.fill(CGRect(origin: .zero, size: size)) }
    private static func fill(_ context: CGContext, size: CGSize, color: FeedRGBA) { context.setFillColor(color.cgColor); context.fill(CGRect(origin: .zero, size: size)) }
    private static func strokeSeparator(_ context: CGContext, globalY: CGFloat, region: CGRect, color: FeedRGBA) { context.setStrokeColor(color.cgColor); context.move(to: CGPoint(x: 0, y: region.height - (globalY - region.minY))); context.addLine(to: CGPoint(x: region.width, y: region.height - (globalY - region.minY))); context.strokePath() }
    private static func drawImage(_ image: CGImage, frame: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: frame.minY * 2 + frame.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: frame)
        context.restoreGState()
    }
    private static func regions(_ layout: FeedItemLayout) -> [InteractionRegion] {
        var result = layout.profile.regions + layout.body.regions
        if let repost = layout.repost { result += repost.body.regions + (repost.card?.regions ?? []) }
        result += layout.card?.regions ?? []; result += layout.tag?.regions ?? []; result += layout.toolbar.regions
        return result
    }
}

@MainActor
final class FeedAccessibilityElement: UIAccessibilityElement {
    let action: FeedAction?
    private let activation: (FeedAction) -> Void
    init(accessibilityContainer container: Any, action: FeedAction?, activation: @escaping (FeedAction) -> Void) { self.action = action; self.activation = activation; super.init(accessibilityContainer: container) }
    override func accessibilityActivate() -> Bool { guard let action else { return false }; activation(action); return true }
}
