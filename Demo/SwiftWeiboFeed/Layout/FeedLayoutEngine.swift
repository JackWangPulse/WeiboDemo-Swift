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
        item: FeedItem,
        parsedBody: ParsedFeedText,
        parsedRepost: ParsedFeedText?,
        environment: FeedLayoutEnvironment
    ) async throws -> FeedItemLayout {
        try Task.checkCancellation()
        let operation = BlockOperation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.addExecutionBlock { [layoutStartHook] in
                    guard !operation.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    layoutStartHook?()
                    do {
                        try Self.checkCancellation(operation)
                        let result = try Self.compute(
                            item: item,
                            parsedBody: parsedBody,
                            parsedRepost: parsedRepost,
                            environment: environment,
                            operation: operation
                        )
                        try Self.checkCancellation(operation)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                queue.addOperation(operation)
            }
        } onCancel: {
            operation.cancel()
        }
    }

    private static func compute(
        item: FeedItem,
        parsedBody: ParsedFeedText,
        parsedRepost: ParsedFeedText?,
        environment: FeedLayoutEnvironment,
        operation: Operation
    ) throws -> FeedItemLayout {
        precondition(!Thread.isMainThread, "Feed layout must never run on the main thread")
        try checkCancellation(operation)
        let scale = CGFloat(max(environment.displayScale, 1))
        let width = CGFloat(environment.containerPixelWidth) / scale
        let inset: CGFloat = 12
        let contentWidth = max(0, width - inset * 2)
        let bodyX: CGFloat = 64
        let bodyWidth = max(0, width - bodyX - inset)
        var cursor: CGFloat = 64
        let body = try makeTextLayout(parsedBody, x: bodyX, y: cursor, width: bodyWidth, itemID: item.id, operation: operation)
        cursor = body.bounds.maxY + 12

        try checkCancellation(operation)
        let media = mediaFrames(count: item.pictures.count, x: inset, y: cursor, availableWidth: contentWidth)
        if let last = media.last { cursor = last.maxY + 12 }

        var repostLayout: RepostLayout?
        if let repost = item.repost, let parsedRepost {
            let repostTop = cursor
            let repostBody = try makeTextLayout(parsedRepost, x: 24, y: repostTop + 12, width: max(0, width - 48), itemID: repost.id, operation: operation)
            var repostBottom = repostBody.bounds.maxY + 12
            let repostMedia = mediaFrames(count: repost.pictures.count, x: 24, y: repostBottom, availableWidth: max(0, width - 48))
            if let last = repostMedia.last { repostBottom = last.maxY + 12 }
            let frame = CGRect(x: inset, y: repostTop, width: contentWidth, height: repostBottom - repostTop)
            repostLayout = RepostLayout(frame: frame, body: repostBody, mediaFrames: repostMedia)
            cursor = frame.maxY + 12
        }

        if item.card != nil { cursor += 68 }
        if !item.tags.isEmpty { cursor += 32 }
        try checkCancellation(operation)
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
        let height = toolbarFrame.maxY + 8
        try checkCancellation(operation)
        return FeedItemLayout(
            identity: FeedLayoutIdentity(content: .init(itemID: item.id, contentVersion: 1), environment: environment),
            height: height,
            body: body,
            avatarFrame: CGRect(x: inset, y: 12, width: 40, height: 40),
            mediaFrames: media,
            repost: repostLayout,
            toolbar: ToolbarLayout(frame: toolbarFrame, regions: toolbarRegions)
        )
    }

    private static func makeTextLayout(
        _ parsed: ParsedFeedText,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        itemID: FeedID,
        operation: Operation
    ) throws -> TextLayout {
        try checkCancellation(operation)
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
        try checkCancellation(operation)
        let typesetter = CTTypesetterCreateWithAttributedString(text)
        var lines = [CTLine]()
        var origins = [CGPoint]()
        var ranges = [CFRange]()
        var index = 0
        let length = text.length
        let maximumLines = 6
        while index < length && lines.count < maximumLines {
            try checkCancellation(operation)
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, index, Double(width)))
            let range = CFRange(location: index, length: min(count, length - index))
            lines.append(CTTypesetterCreateLine(typesetter, range))
            origins.append(CGPoint(x: x, y: y + CGFloat(lines.count - 1) * 20 + 16))
            ranges.append(range)
            index += range.length
        }
        let truncated = index < length
        if truncated, let finalLine = lines.last {
            let token = NSAttributedString(
                string: "… More",
                attributes: [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: UIColor.systemBlue]
            )
            let tokenLine = CTLineCreateWithAttributedString(token)
            lines[lines.count - 1] = CTLineCreateTruncatedLine(finalLine, Double(width), .end, tokenLine) ?? finalLine
        }
        let bounds = CGRect(x: x, y: y, width: width, height: CGFloat(lines.count) * 20)
        var regions = parsed.spans.compactMap { span -> InteractionRegion? in
            guard let action = span.action else { return nil }
            let semanticRange = NSRange(span.range, in: parsed.source)
            let rects = interactionRects(for: semanticRange, lineRanges: ranges, lines: lines, origins: origins)
            guard !rects.isEmpty else { return nil }
            return InteractionRegion(rects: rects, action: action, accessibilityLabel: String(parsed.source[span.range]))
        }
        if truncated, let line = lines.last, let origin = origins.last {
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            regions.append(InteractionRegion(
                rects: [CGRect(x: min(origin.x + lineWidth, bounds.maxX - 44), y: origin.y - 16, width: 44, height: 20)],
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
        origins: [CGPoint]
    ) -> [CGRect] {
        zip(zip(lineRanges, lines), origins).compactMap { pair, origin in
            let lineRange = NSRange(location: pair.0.location, length: pair.0.length)
            let intersection = NSIntersectionRange(range, lineRange)
            guard intersection.length > 0 else { return nil }
            let start = CGFloat(CTLineGetOffsetForStringIndex(pair.1, intersection.location, nil))
            let end = CGFloat(CTLineGetOffsetForStringIndex(pair.1, NSMaxRange(intersection), nil))
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

    private static func checkCancellation(_ operation: Operation) throws {
        if operation.isCancelled { throw CancellationError() }
    }
}
