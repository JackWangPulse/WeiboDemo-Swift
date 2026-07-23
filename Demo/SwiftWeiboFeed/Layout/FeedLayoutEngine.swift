import CoreText
import Foundation
import UIKit

public final class FeedLayoutEngine: @unchecked Sendable {
    public typealias LayoutStartHook = @Sendable () -> Void

    private let queue: OperationQueue
    private let layoutStartHook: LayoutStartHook?

    public init(layoutStartHook: LayoutStartHook? = nil) {
        let queue = OperationQueue()
        queue.name = "com.ibireme.SwiftWeiboFeed.layout"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        self.queue = queue
        self.layoutStartHook = layoutStartHook
    }

    public func layout(
        identity: FeedContentIdentity,
        item: FeedItem,
        parsedBody: ParsedFeedText,
        parsedRepost: ParsedFeedText?,
        environment: FeedLayoutEnvironment
    ) async throws -> FeedItemLayout {
        try await FeedSignpost.measureAsync(.layout) {
            try Task.checkCancellation()
            let cancellation = LayoutCancellation()
            let completion = LayoutCompletion<FeedItemLayout>()
            let operation = BlockOperation { [layoutStartHook] in
                guard !cancellation.isCancelled else { return }
                layoutStartHook?()
                do {
                    let result = try Self.compute(item: item, identity: identity, parsedBody: parsedBody, parsedRepost: parsedRepost, environment: environment, cancellation: cancellation)
                    completion.resume(.success(result))
                } catch { completion.resume(.failure(error)) }
            }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    completion.install(continuation)
                    queue.addOperation(operation)
                }
            } onCancel: {
                cancellation.cancel()
                operation.cancel()
                completion.resume(.failure(CancellationError()))
            }
        }
    }

    private static func compute(
        item: FeedItem,
        identity: FeedContentIdentity,
        parsedBody: ParsedFeedText,
        parsedRepost: ParsedFeedText?,
        environment: FeedLayoutEnvironment,
        cancellation: LayoutCancellation
    ) throws -> FeedItemLayout {
        precondition(!Thread.isMainThread, "Feed layout must never run on the main thread")
        try checkCancellation(cancellation)
        let scale = CGFloat(max(environment.displayScale, 1))
        let width = CGFloat(environment.containerPixelWidth) / scale
        let inset: CGFloat = 12
        let contentWidth = max(0, width - inset * 2)
        let bodyX: CGFloat = 64
        let bodyWidth = max(0, width - bodyX - inset)
        let profile = try makeProfileLayout(item: item, width: width, cancellation: cancellation)
        var cursor: CGFloat = profile.frame.maxY + 12
        let body = try makeTextLayout(parsedBody, x: bodyX, y: cursor, width: bodyWidth, itemID: item.id, cancellation: cancellation)
        cursor = body.bounds.maxY + 12

        try checkCancellation(cancellation)
        let media = mediaFrames(count: item.pictures.count, x: inset, y: cursor, availableWidth: contentWidth)
        if let last = media.last { cursor = last.maxY + 12 }

        var repostLayout: RepostLayout?
        if let repost = item.repost, let parsedRepost {
            let repostTop = cursor
            let repostBody = try makeTextLayout(parsedRepost, x: 24, y: repostTop + 12, width: max(0, width - 48), itemID: repost.id, cancellation: cancellation)
            var repostBottom = repostBody.bounds.maxY + 12
            let repostMedia = mediaFrames(count: repost.pictures.count, x: 24, y: repostBottom, availableWidth: max(0, width - 48))
            if let last = repostMedia.last { repostBottom = last.maxY + 12 }
            let repostCard = try repost.card.map {
                try makeCardLayout($0, x: 24, y: repostBottom, width: max(0, width - 48), cancellation: cancellation)
            }
            if let repostCard { repostBottom = repostCard.frame.maxY + 12 }
            let frame = CGRect(x: inset, y: repostTop, width: contentWidth, height: repostBottom - repostTop)
            repostLayout = RepostLayout(frame: frame, body: repostBody, mediaFrames: repostMedia, card: repostCard)
            cursor = frame.maxY + 12
        }

        let card = try item.card.map { try makeCardLayout($0, x: inset, y: cursor, width: contentWidth, cancellation: cancellation) }
        if let card { cursor = card.frame.maxY + 12 }
        // Match the original YYKit Weibo demo, which intentionally renders only the first tag.
        let tag = try item.tags.first.map { try makeTagLayout($0, x: inset, y: cursor, width: contentWidth, cancellation: cancellation) }
        if let tag { cursor = tag.frame.maxY + 12 }
        try checkCancellation(cancellation)
        let toolbarFrame = CGRect(x: 0, y: cursor, width: width, height: 44)
        let sectionWidth = width / 3
        let actions: [(FeedAction, String)] = [(.repost, "Repost"), (.comment, "Comment"), (.like, "Like")]
        let toolbarRegions = actions.enumerated().map { index, value in
            InteractionRegion(
                rects: [CGRect(x: CGFloat(index) * sectionWidth, y: cursor, width: sectionWidth, height: 44)],
                action: value.0,
                accessibilityLabel: value.1
            )
        }
        let counts = [item.repostCount, item.commentCount, item.likeCount]
        let toolbarItems = actions.enumerated().map { index, value in
            let sectionX = CGFloat(index) * sectionWidth
            return ToolbarItemLayout(
                action: value.0,
                iconFrame: CGRect(x: sectionX + sectionWidth / 2 - 26, y: cursor + 14, width: 16, height: 16),
                count: makeSingleLineText(String(counts[index]), x: sectionX + sectionWidth / 2 - 4, y: cursor + 12, width: 34, color: .secondaryLabel, fontSize: 13)
            )
        }
        let height = toolbarFrame.maxY + 8
        try checkCancellation(cancellation)
        return FeedItemLayout(
            identity: FeedLayoutIdentity(content: identity, environment: environment),
            height: height,
            profile: profile,
            body: body,
            mediaFrames: media,
            repost: repostLayout,
            card: card,
            tag: tag,
            toolbar: ToolbarLayout(frame: toolbarFrame, regions: toolbarRegions, items: toolbarItems)
        )
    }

    private static func makeProfileLayout(item: FeedItem, width: CGFloat, cancellation: LayoutCancellation) throws -> ProfileLayout {
        try checkCancellation(cancellation)
        let frame = CGRect(x: 0, y: 0, width: width, height: 64)
        let avatar = CGRect(x: 12, y: 12, width: 40, height: 40)
        let verificationFrame = item.user.isVerified ? CGRect(x: 48, y: 40, width: 12, height: 12) : nil
        let name = makeSingleLineText(item.user.name, x: 64, y: 12, width: max(0, width - 76), color: .label)
        let timeText = item.createdAt.map(Self.formatProfileDate)
        let time = timeText.map { makeSingleLineText($0, x: 64, y: 34, width: 92, color: .secondaryLabel, fontSize: 12) }
        let sourceX = time == nil ? 64 : 160
        let source = item.source.map { makeSingleLineText($0, x: CGFloat(sourceX), y: 34, width: max(0, width - CGFloat(sourceX) - 12), color: .secondaryLabel, fontSize: 12) }
        let verificationDescription = item.user.verifiedReason.map { ", verified, \($0)" } ?? (item.user.isVerified ? ", verified" : "")
        let metadataDescription = [timeText, item.source].compactMap { $0 }.joined(separator: ", ")
        let accessibilityLabel = item.user.name + verificationDescription + (metadataDescription.isEmpty ? "" : ", " + metadataDescription)
        return ProfileLayout(
            frame: frame,
            avatarFrame: avatar,
            name: name,
            time: time,
            source: source,
            verificationFrame: verificationFrame,
            accessibilityLabel: accessibilityLabel,
            regions: [InteractionRegion(rects: [avatar, name.bounds], action: .user(item.user.id.rawValue), accessibilityLabel: accessibilityLabel)]
        )
    }

    private static func formatProfileDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func makeCardLayout(_ card: FeedCard, x: CGFloat, y: CGFloat, width: CGFloat, cancellation: LayoutCancellation) throws -> CardLayout {
        try checkCancellation(cancellation)
        let frame = CGRect(x: x, y: y, width: width, height: 64)
        let imageFrame = card.imageURL == nil ? nil : CGRect(x: x, y: y, width: 64, height: 64)
        let textX = imageFrame?.maxX.advanced(by: 8) ?? x + 8
        let title = card.title ?? card.description ?? "Link"
        let text = makeSingleLineText(title, x: textX, y: y + 22, width: max(0, frame.maxX - textX - 8), color: .label)
        let regions = card.targetURL.map { [InteractionRegion(rects: [frame], action: .url($0), accessibilityLabel: title)] } ?? []
        return CardLayout(frame: frame, imageFrame: imageFrame, text: text, regions: regions)
    }

    private static func makeTagLayout(_ tag: FeedTag, x: CGFloat, y: CGFloat, width: CGFloat, cancellation: LayoutCancellation) throws -> TagLayout {
        try checkCancellation(cancellation)
        let frame = CGRect(x: x, y: y, width: width, height: 28)
        let text = makeSingleLineText(tag.name, x: x + 8, y: y + 4, width: max(0, width - 16), color: .systemBlue)
        return TagLayout(frame: frame, text: text, regions: [InteractionRegion(rects: [frame], action: .tag(tag.name), accessibilityLabel: tag.name)])
    }

    private static func makeSingleLineText(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat, color: UIColor, fontSize: CGFloat = 16) -> TextLayout {
        guard width > 0 else {
            return TextLayout(storage: CoreTextLayoutStorage(lines: [], origins: []), bounds: CGRect(x: x, y: y, width: 0, height: 0), regions: [])
        }
        let attributed = NSAttributedString(string: value, attributes: [.font: UIFont.systemFont(ofSize: fontSize), .foregroundColor: color])
        let original = CTLineCreateWithAttributedString(attributed)
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [.font: UIFont.systemFont(ofSize: fontSize), .foregroundColor: color]))
        let originalWidth = CGFloat(CTLineGetTypographicBounds(original, nil, nil, nil))
        let tokenWidth = CGFloat(CTLineGetTypographicBounds(token, nil, nil, nil))
        let line: CTLine
        if originalWidth <= width {
            line = original
        } else if tokenWidth <= width, let truncated = CTLineCreateTruncatedLine(original, Double(width), .end, token) {
            line = truncated
        } else {
            line = CTLineCreateWithAttributedString(NSAttributedString(string: ""))
        }
        return TextLayout(storage: CoreTextLayoutStorage(lines: [line], origins: [CGPoint(x: x, y: y + 16)]), bounds: CGRect(x: x, y: y, width: width, height: 20), regions: [])
    }

    private static func makeTextLayout(
        _ parsed: ParsedFeedText,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        itemID: FeedID,
        cancellation: LayoutCancellation
    ) throws -> TextLayout {
        try checkCancellation(cancellation)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 20
        paragraph.maximumLineHeight = 20
        paragraph.lineSpacing = 0
        let text = NSMutableAttributedString(
            string: parsed.source,
            attributes: [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: UIColor.label, .paragraphStyle: paragraph]
        )
        for span in parsed.spans where span.kind != .plain {
            let range = NSRange(span.range, in: parsed.source)
            text.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: range)
        }
        try checkCancellation(cancellation)
        let typesetter = CTTypesetterCreateWithAttributedString(text)
        var lines = [CTLine]()
        var origins = [CGPoint]()
        var ranges = [CFRange]()
        var indexBases = [Int]()
        var index = 0
        let length = text.length
        let maximumLines = 6
        while index < length && lines.count < maximumLines {
            try checkCancellation(cancellation)
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, index, Double(width)))
            let range = CFRange(location: index, length: min(count, length - index))
            lines.append(CTTypesetterCreateLine(typesetter, range))
            origins.append(CGPoint(x: x, y: y + CGFloat(lines.count - 1) * 20 + 16))
            ranges.append(range)
            indexBases.append(0)
            index += range.length
        }
        let truncated = index < length
        var visibleUTF16End = length
        var expandRect: CGRect?
        if truncated, let finalRange = ranges.last, let origin = origins.last {
            let token = NSAttributedString(
                string: "… More",
                attributes: [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: UIColor.systemBlue]
            )
            let tokenLine = CTLineCreateWithAttributedString(token)
            let tokenWidth = CGFloat(CTLineGetTypographicBounds(tokenLine, nil, nil, nil))
            let visibleWidth = max(0, width - tokenWidth)
            let prefixCount = CTTypesetterSuggestClusterBreak(typesetter, finalRange.location, Double(visibleWidth))
            visibleUTF16End = min(finalRange.location + prefixCount, finalRange.location + finalRange.length)
            let source = text.string as NSString
            while visibleUTF16End > finalRange.location {
                let previousCodeUnit = source.character(at: visibleUTF16End - 1)
                guard previousCodeUnit == 0x0A || previousCodeUnit == 0x0D else { break }
                visibleUTF16End -= 1
            }
            if let lastRange = ranges.indices.last {
                ranges[lastRange].length = visibleUTF16End - ranges[lastRange].location
            }
            let explicitLine = NSMutableAttributedString(attributedString: text.attributedSubstring(from: NSRange(location: finalRange.location, length: visibleUTF16End - finalRange.location)))
            explicitLine.append(token)
            lines[lines.count - 1] = CTLineCreateWithAttributedString(explicitLine)
            indexBases[indexBases.count - 1] = finalRange.location
            let prefixLine = CTLineCreateWithAttributedString(text.attributedSubstring(from: NSRange(location: finalRange.location, length: visibleUTF16End - finalRange.location)))
            let tokenOffset = CGFloat(CTLineGetTypographicBounds(prefixLine, nil, nil, nil))
            expandRect = CGRect(x: x + tokenOffset, y: origin.y - 16, width: tokenWidth, height: 20)
        }
        let bounds = CGRect(x: x, y: y, width: width, height: CGFloat(lines.count) * 20)
        var regions = parsed.spans.compactMap { span -> InteractionRegion? in
            guard let action = span.action else { return nil }
            let semanticRange = NSRange(span.range, in: parsed.source)
            let clipped = NSIntersectionRange(semanticRange, NSRange(location: 0, length: visibleUTF16End))
            guard clipped.length > 0 else { return nil }
            let rects = interactionRects(for: clipped, lineRanges: ranges, lines: lines, origins: origins, indexBases: indexBases)
            guard !rects.isEmpty else { return nil }
            return InteractionRegion(rects: rects, action: action, accessibilityLabel: String(parsed.source[span.range]))
        }
        if let expandRect {
            regions.append(InteractionRegion(
                rects: [expandRect],
                action: .expand(itemID),
                accessibilityLabel: "Expand"
            ))
        }
        return TextLayout(storage: CoreTextLayoutStorage(lines: lines, origins: origins), bounds: bounds, regions: regions)
    }

    private static func interactionRects(
        for range: NSRange,
        lineRanges: [CFRange],
        lines: [CTLine],
        origins: [CGPoint],
        indexBases: [Int]
    ) -> [CGRect] {
        lineRanges.indices.compactMap { lineIndex in
            let lineRange = NSRange(location: lineRanges[lineIndex].location, length: lineRanges[lineIndex].length)
            let intersection = NSIntersectionRange(range, lineRange)
            guard intersection.length > 0 else { return nil }
            let line = lines[lineIndex]
            let origin = origins[lineIndex]
            let indexBase = indexBases[lineIndex]
            let start = CGFloat(CTLineGetOffsetForStringIndex(line, intersection.location - indexBase, nil))
            let end = CGFloat(CTLineGetOffsetForStringIndex(line, NSMaxRange(intersection) - indexBase, nil))
            return CGRect(x: origin.x + min(start, end), y: origin.y - 16, width: max(abs(end - start), 1), height: 20)
        }
    }

    private static func mediaFrames(count: Int, x: CGFloat, y: CGFloat, availableWidth: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        if count == 1 {
            let side = min(240, availableWidth)
            return [CGRect(x: x, y: y, width: side, height: side)]
        }
        let columns = count == 4 ? 2 : 3
        let spacing: CGFloat = 4
        let side = (availableWidth - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        return (0..<min(count, 9)).map { index in
            CGRect(
                x: x + CGFloat(index % columns) * (side + spacing),
                y: y + CGFloat(index / columns) * (side + spacing),
                width: side,
                height: side
            )
        }
    }

    private static func checkCancellation(_ cancellation: LayoutCancellation) throws {
        if cancellation.isCancelled { throw CancellationError() }
    }
}

private final class LayoutCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

private final class LayoutCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pending: Result<Value, Error>?

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let result = lock.withLock { () -> Result<Value, Error>? in
            if let pending { return pending }
            self.continuation = continuation
            return nil
        }
        if let result {
            continuation.resume(with: result)
        }
    }

    func resume(_ result: Result<Value, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Value, Error>? in
            guard pending == nil else { return nil }
            guard let continuation else {
                pending = result
                return nil
            }
            self.continuation = nil
            pending = result
            return continuation
        }
        continuation?.resume(with: result)
    }
}
