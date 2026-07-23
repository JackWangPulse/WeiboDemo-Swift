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
    private(set) var imageLayers: [CALayer] = []
    private(set) var mediaLayers: [CALayer] = []

    private var entry: PreparedFeedEntry?
    private var interactionRegions: [InteractionRegion] = []
    private var selectedRegion: InteractionRegion?
    public var onAction: ((FeedAction) -> Void)?

    public override convenience init(frame: CGRect) {
        self.init(frame: frame, layerFactory: { AsyncRenderLayer() })
    }

    init(frame: CGRect = .zero, layerFactory: () -> AsyncRenderLayer) {
        profileLayer = layerFactory(); bodyLayer = layerFactory(); repostLayer = layerFactory()
        cardLayer = layerFactory(); tagLayer = layerFactory(); toolbarLayer = layerFactory()
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func apply(_ entry: PreparedFeedEntry) {
        cancelInteraction()
        self.entry = entry
        let layout = entry.layout
        frame.size.height = layout.height
        profileLayer.frame = layout.profile.frame
        bodyLayer.frame = layout.body.bounds
        repostLayer.frame = layout.repost?.frame ?? .zero
        cardLayer.frame = layout.card?.frame ?? .zero
        tagLayer.frame = layout.tag?.frame ?? .zero
        toolbarLayer.frame = layout.toolbar.frame
        rebuildImageLayers(entry)
        interactionRegions = Self.regions(layout)
        rebuildAccessibility(entry)
    }

    func display(entry: PreparedFeedEntry, generation: UInt, scale: CGFloat) {
        let layout = entry.layout
        display(profileLayer, frame: layout.profile.frame, identity: identity(entry, .profile, generation), scale: scale) { context, token in
            Self.fill(context, size: layout.profile.frame.size, color: (1, 1, 1, 1))
            Self.draw(layout.profile.name, in: context, region: layout.profile.frame, token: token)
            if let time = layout.profile.time { Self.draw(time, in: context, region: layout.profile.frame, token: token) }
            if let source = layout.profile.source { Self.draw(source, in: context, region: layout.profile.frame, token: token) }
        }
        display(bodyLayer, frame: layout.body.bounds, identity: identity(entry, .body, generation), scale: scale) { Self.draw(layout.body, in: $0, region: layout.body.bounds, token: $1) }
        if let repost = layout.repost {
            display(repostLayer, frame: repost.frame, identity: identity(entry, .repost, generation), scale: scale) { context, token in
                context.setFillColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)
                context.fill(CGRect(origin: .zero, size: repost.frame.size))
                Self.draw(repost.body, in: context, region: repost.frame, token: token)
                if let card = repost.card { Self.strokeSeparator(context, globalY: card.frame.minY, region: repost.frame); Self.draw(card.text, in: context, region: repost.frame, token: token) }
            }
        }
        if let card = layout.card { display(cardLayer, frame: card.frame, identity: identity(entry, .card, generation), scale: scale) { context, token in Self.fill(context, size: card.frame.size, color: (0.95, 0.95, 0.96, 1)); Self.strokeSeparator(context, globalY: card.frame.minY, region: card.frame); Self.draw(card.text, in: context, region: card.frame, token: token) } }
        if let tag = layout.tag { display(tagLayer, frame: tag.frame, identity: identity(entry, .tag, generation), scale: scale) { context, token in Self.fill(context, size: tag.frame.size, color: (0.94, 0.97, 1, 1)); Self.draw(tag.text, in: context, region: tag.frame, token: token) } }
        display(toolbarLayer, frame: layout.toolbar.frame, identity: identity(entry, .toolbar, generation), scale: scale) { context, token in
            guard !token.isCancelled else { return }
            Self.strokeSeparator(context, globalY: layout.toolbar.frame.minY, region: layout.toolbar.frame)
            for item in layout.toolbar.items {
                guard !token.isCancelled else { return }
                Self.drawToolbarIcon(item.action, frame: item.iconFrame.offsetBy(dx: -layout.toolbar.frame.minX, dy: -layout.toolbar.frame.minY), context: context)
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
        imageLayers.removeAll(); mediaLayers.removeAll(); highlightLayer.isHidden = true
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
        let mediaCount = entry.layout.mediaFrames.count + (entry.layout.repost?.mediaFrames.count ?? 0)
        mediaLayers = Array(imageLayers.dropFirst().prefix(mediaCount))
        layer.addSublayer(highlightLayer)
    }

    private func rebuildAccessibility(_ entry: PreparedFeedEntry) {
        var elements: [UIAccessibilityElement] = []
        func append(label: String, frame: CGRect, traits: UIAccessibilityTraits = .button, action: FeedAction? = nil) {
            let element = FeedAccessibilityElement(accessibilityContainer: self, action: action) { [weak self] action in self?.onAction?(action) }
            element.accessibilityLabel = label; element.accessibilityTraits = traits; element.accessibilityFrameInContainerSpace = frame; elements.append(element)
        }
        append(label: entry.parsed.source, frame: entry.layout.body.bounds, traits: .staticText)
        if let repost = entry.item.repost, let repostLayout = entry.layout.repost {
            append(label: repost.text, frame: repostLayout.body.bounds, traits: .staticText)
        }
        for region in interactionRegions { append(label: region.accessibilityLabel, frame: region.rects.reduce(.null) { $0.union($1) }, action: region.action) }
        for (index, frame) in entry.layout.mediaFrames.enumerated() { append(label: "Media \(index + 1)", frame: frame, traits: .image) }
        if let repost = entry.layout.repost {
            for (index, frame) in repost.mediaFrames.enumerated() { append(label: "Repost media \(index + 1)", frame: frame, traits: .image) }
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
        context.restoreGState()
    }
    private static func fill(_ context: CGContext, size: CGSize, color: (CGFloat, CGFloat, CGFloat, CGFloat)) { context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: color.3); context.fill(CGRect(origin: .zero, size: size)) }
    private static func strokeSeparator(_ context: CGContext, globalY: CGFloat, region: CGRect) { context.setStrokeColor(red: 0.82, green: 0.82, blue: 0.84, alpha: 1); context.move(to: CGPoint(x: 0, y: region.height - (globalY - region.minY))); context.addLine(to: CGPoint(x: region.width, y: region.height - (globalY - region.minY))); context.strokePath() }
    private static func drawToolbarIcon(_ action: FeedAction, frame: CGRect, context: CGContext) { context.setStrokeColor(red: 0.35, green: 0.35, blue: 0.38, alpha: 1); context.strokeEllipse(in: frame.insetBy(dx: 2, dy: 2)); if action == .like { context.move(to: CGPoint(x: frame.midX, y: frame.minY)); context.addLine(to: CGPoint(x: frame.midX, y: frame.maxY)); context.strokePath() } }
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
