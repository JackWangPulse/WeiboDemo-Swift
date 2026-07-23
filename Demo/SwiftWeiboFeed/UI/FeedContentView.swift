import CoreText
import UIKit

@MainActor
public final class FeedContentView: UIView {
    let profileLayer = AsyncRenderLayer()
    let bodyLayer = AsyncRenderLayer()
    let repostLayer = AsyncRenderLayer()
    let cardLayer = AsyncRenderLayer()
    let tagLayer = AsyncRenderLayer()
    let toolbarLayer = AsyncRenderLayer()
    private let highlightLayer = CALayer()
    private(set) var imageLayers: [CALayer] = []
    var mediaLayers: [CALayer] { Array(imageLayers.dropFirst(imageLayers.isEmpty ? 0 : 1)) }

    private var entry: PreparedFeedEntry?
    private var interactionRegions: [InteractionRegion] = []

    public override init(frame: CGRect) {
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
            Self.draw(layout.profile.name, in: context, offset: layout.profile.frame.origin, token: token)
            if let time = layout.profile.time { Self.draw(time, in: context, offset: layout.profile.frame.origin, token: token) }
            if let source = layout.profile.source { Self.draw(source, in: context, offset: layout.profile.frame.origin, token: token) }
        }
        display(bodyLayer, frame: layout.body.bounds, identity: identity(entry, .body, generation), scale: scale) { Self.draw(layout.body, in: $0, offset: layout.body.bounds.origin, token: $1) }
        if let repost = layout.repost {
            display(repostLayer, frame: repost.frame, identity: identity(entry, .repost, generation), scale: scale) { context, token in
                context.setFillColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)
                context.fill(CGRect(origin: .zero, size: repost.frame.size))
                Self.draw(repost.body, in: context, offset: repost.frame.origin, token: token)
            }
        }
        if let card = layout.card { display(cardLayer, frame: card.frame, identity: identity(entry, .card, generation), scale: scale) { Self.draw(card.text, in: $0, offset: card.frame.origin, token: $1) } }
        if let tag = layout.tag { display(tagLayer, frame: tag.frame, identity: identity(entry, .tag, generation), scale: scale) { Self.draw(tag.text, in: $0, offset: tag.frame.origin, token: $1) } }
        display(toolbarLayer, frame: layout.toolbar.frame, identity: identity(entry, .toolbar, generation), scale: scale) { context, token in
            guard !token.isCancelled else { return }
            context.setStrokeColor(red: 0.82, green: 0.82, blue: 0.84, alpha: 1)
            context.move(to: .zero); context.addLine(to: CGPoint(x: layout.toolbar.frame.width, y: 0)); context.strokePath()
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
            if let card = repost.card { sources.append((card.imageURL, repostLayout.card?.imageFrame ?? .zero)) }
        }
        if let card = entry.item.card { sources.append((card.imageURL, entry.layout.card?.imageFrame ?? .zero)) }
        return zip(sources, imageLayers).compactMap { source, layer in source.0.map { ($0, source.1, layer) } }
    }

    func clear() {
        entry = nil; interactionRegions = []; accessibilityElements = nil
        cancelRendering()
        for node in [profileLayer, bodyLayer, repostLayer, cardLayer, tagLayer, toolbarLayer] { node.frame = .zero }
        imageLayers.forEach { $0.contents = nil; $0.removeFromSuperlayer() }
        imageLayers.removeAll(); highlightLayer.isHidden = true
    }

    func cancelRendering() {
        for node in [profileLayer, bodyLayer, repostLayer, cardLayer, tagLayer, toolbarLayer] {
            node.cancelDisplay()
            node.contents = nil
        }
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self), let region = interactionRegions.first(where: { $0.rects.contains(where: { $0.contains(point) }) }) else { return }
        highlightLayer.frame = region.rects.reduce(.null) { $0.union($1) }
        highlightLayer.isHidden = false
    }
    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { highlightLayer.isHidden = true }
    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { highlightLayer.isHidden = true }

    private func rebuildImageLayers(_ entry: PreparedFeedEntry) {
        imageLayers.forEach { $0.removeFromSuperlayer() }
        var frames = [entry.layout.profile.avatarFrame] + entry.layout.mediaFrames
        if let repost = entry.layout.repost { frames += repost.mediaFrames; if let image = repost.card?.imageFrame { frames.append(image) } }
        if let image = entry.layout.card?.imageFrame { frames.append(image) }
        imageLayers = frames.map { frame in
            let node = CALayer(); node.frame = frame; node.contentsGravity = .resizeAspectFill; node.masksToBounds = true; layer.addSublayer(node); return node
        }
        layer.addSublayer(highlightLayer)
    }

    private func rebuildAccessibility(_ entry: PreparedFeedEntry) {
        var elements: [UIAccessibilityElement] = []
        func append(label: String, frame: CGRect, traits: UIAccessibilityTraits = .button) {
            let element = UIAccessibilityElement(accessibilityContainer: self); element.accessibilityLabel = label; element.accessibilityTraits = traits; element.accessibilityFrameInContainerSpace = frame; elements.append(element)
        }
        append(label: entry.layout.profile.accessibilityLabel, frame: entry.layout.profile.frame)
        append(label: entry.parsed.source, frame: entry.layout.body.bounds, traits: .staticText)
        for region in interactionRegions { for rect in region.rects { append(label: region.accessibilityLabel, frame: rect) } }
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
    private static func draw(_ text: TextLayout, in context: CGContext, offset: CGPoint, token: DisplayCancellationToken) {
        context.saveGState(); context.textMatrix = .identity
        for (line, origin) in zip(text.storage.lines, text.storage.origins) { guard !token.isCancelled else { break }; context.textPosition = CGPoint(x: origin.x - offset.x, y: text.bounds.height - (origin.y - offset.y)); CTLineDraw(line, context) }
        context.restoreGState()
    }
    private static func regions(_ layout: FeedItemLayout) -> [InteractionRegion] {
        var result = layout.profile.regions + layout.body.regions
        if let repost = layout.repost { result += repost.body.regions + (repost.card?.regions ?? []) }
        result += layout.card?.regions ?? []; result += layout.tag?.regions ?? []; result += layout.toolbar.regions
        return result
    }
}
