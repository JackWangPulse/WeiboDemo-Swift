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
        environment: FeedLayoutEnvironment,
        maximumBodyLines: Int? = 6,
        maximumRepostLines: Int? = 6
    ) async throws -> FeedItemLayout {
        try await FeedSignpost.measureAsync(.layout) {
            try Task.checkCancellation()
            let cancellation = LayoutCancellation()
            let completion = LayoutCompletion<FeedItemLayout>()
            let operation = BlockOperation { [layoutStartHook] in
                guard !cancellation.isCancelled else { return }
                layoutStartHook?()
                do {
                    let result = try Self.compute(item: item, identity: identity, parsedBody: parsedBody, parsedRepost: parsedRepost, environment: environment, maximumBodyLines: maximumBodyLines, maximumRepostLines: maximumRepostLines, cancellation: cancellation)
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
        maximumBodyLines: Int?,
        maximumRepostLines: Int?,
        cancellation: LayoutCancellation
    ) throws -> FeedItemLayout {
        // 用户头像和名称 -> 正文 -> 原微博图片 -> 转发区域 -> 卡片 -> 标签 -> 工具栏
        precondition(!Thread.isMainThread, "Feed layout must never run on the main thread")
        try checkCancellation(cancellation)
        let scale = CGFloat(max(environment.displayScale, 1))
        let width = CGFloat(environment.containerPixelWidth) / scale
        let inset = WeiboVisualMetrics.contentInset
        let contentWidth = max(0, width - inset * 2) // 计算微博内容可用宽度
        let bodyX = inset
        let bodyWidth = contentWidth
        let profile = try makeProfileLayout(item: item, width: width, environment: environment, cancellation: cancellation)
        var cursor = profile.frame.maxY // cursor 是纵向布局游标，布局头像区域后
        let body = try makeTextLayout(parsedBody, x: bodyX, y: cursor, width: bodyWidth, itemID: item.id, environment: environment, maximumLines: maximumBodyLines, cancellation: cancellation)
        cursor = body.bounds.maxY + WeiboVisualMetrics.textPadding // 布局正文后

        try checkCancellation(cancellation)
        let media = mediaFrames(count: item.pictures.count, x: inset, y: cursor, availableWidth: contentWidth)
        if let last = media.last { cursor = last.maxY + 12 }

        var repostLayout: RepostLayout?
        if let repost = item.repost, let parsedRepost {
            let repostTop = cursor // 记录转发区域顶部
            // 计算转发正文
            let repostBody = try makeTextLayout(parsedRepost, x: 24, y: repostTop + 12, width: max(0, width - 48), itemID: repost.id, environment: environment, maximumLines: maximumRepostLines, cancellation: cancellation)
            var repostBottom = repostBody.bounds.maxY + 12
            let repostMedia = mediaFrames(count: repost.pictures.count, x: 24, y: repostBottom, availableWidth: max(0, width - 48))
            if let last = repostMedia.last { repostBottom = last.maxY + 12 }
            // 如果转发微博带有链接卡片
            let repostCard = try repost.card.map {
                try makeCardLayout($0, x: 24, y: repostBottom, width: max(0, width - 48), environment: environment, cancellation: cancellation)
            }
            if let repostCard { repostBottom = repostCard.frame.maxY + 12 }
            // 得到整个转发区域
            let frame = CGRect(x: inset, y: repostTop, width: contentWidth, height: repostBottom - repostTop)
            // LayoutEngine 只提供 frame。灰色背景真不在这里绘制
            repostLayout = RepostLayout(frame: frame, body: repostBody, mediaFrames: repostMedia, card: repostCard)
            cursor = frame.maxY + 12
        }

        let card = try item.card.map { try makeCardLayout($0, x: inset, y: cursor, width: contentWidth, environment: environment, cancellation: cancellation) }
        if let card { cursor = card.frame.maxY + 12 }
        // Match the original YYKit Weibo demo, which intentionally renders only the first tag.
        let tag = try item.tags.first.map { try makeTagLayout($0, x: inset, y: cursor, width: contentWidth, environment: environment, cancellation: cancellation) }
        if let tag { cursor = tag.frame.maxY + 12 }
        try checkCancellation(cancellation)
        let toolbarHeight = WeiboVisualMetrics.toolbarHeight
        let toolbarFrame = CGRect(x: 0, y: cursor, width: width, height: toolbarHeight)
        let sectionWidth = width / 3
        let actions: [(FeedAction, WeiboResource, String)] = [
            (.repost, .toolbarRepost, "Repost"),
            (.comment, .toolbarComment, "Comment"),
            (.like, .toolbarUnlike, "Like"),
        ]
        let toolbarRegions = actions.enumerated().map { index, value in
            InteractionRegion(
                rects: [CGRect(x: CGFloat(index) * sectionWidth, y: cursor, width: sectionWidth, height: toolbarHeight)],
                action: value.0,
                accessibilityLabel: value.2
            )
        }
        let counts = [item.repostCount, item.commentCount, item.likeCount]
        let toolbarItems = actions.enumerated().map { index, value in
            let sectionX = CGFloat(index) * sectionWidth
            return ToolbarItemLayout(
                action: value.0,
                resource: value.1,
                iconFrame: CGRect(x: sectionX + sectionWidth / 2 - 26, y: cursor + (toolbarHeight - 16) / 2, width: 16, height: 16),
                count: makeSingleLineText(String(counts[index]), x: sectionX + sectionWidth / 2 - 4, y: cursor + (toolbarHeight - max(20, CGFloat(environment.bodyLineHeight))) / 2, width: 34, color: environment.palette.secondaryText, fontSize: max(13, CGFloat(environment.bodyFontSize) * 0.8))
            )
        }
        let height = toolbarFrame.maxY + WeiboVisualMetrics.toolbarBottomMargin // 最终 Cell 高度
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

    private static func makeProfileLayout(item: FeedItem, width: CGFloat, environment: FeedLayoutEnvironment, cancellation: LayoutCancellation) throws -> ProfileLayout {
        try checkCancellation(cancellation)
        let lineHeight = CGFloat(environment.bodyLineHeight)
        let avatarSide: CGFloat = 40
        // 整个用户信息区域
        let frame = CGRect(x: 0, y: WeiboVisualMetrics.topMargin, width: width, height: WeiboVisualMetrics.profileHeight)
        // 头像位置
        let avatar = CGRect(x: WeiboVisualMetrics.contentInset, y: frame.minY + 12, width: avatarSide, height: avatarSide)
        // 名称起始位置
        let textX = avatar.maxX + WeiboVisualMetrics.nameAvatarSpacing
        // 认证角标
        let verificationFrame = item.user.isVerified ? CGRect(x: avatar.maxX - 8, y: avatar.maxY - 8, width: 12, height: 12) : nil
        let name = makeSingleLineText(item.user.name, x: textX, y: frame.minY + 9, width: max(0, width - textX - 44), color: WeiboUserPresentation(user: item.user).nameColor, fontSize: WeiboVisualMetrics.nameFontSize)
        let timeText = item.createdAt.map(Self.formatProfileDate)
        // 时间与来源
        let metaY = frame.minY + 30
        let metaFont = WeiboVisualMetrics.sourceFontSize
        let timeWidth = min(120 * max(1, lineHeight / 20), max(0, width - textX - 12))
        let time = timeText.map { makeSingleLineText($0, x: textX, y: metaY, width: timeWidth, color: environment.palette.secondaryText, fontSize: metaFont) }
        let sourceX = time == nil ? textX : textX + timeWidth + 4
        let source = item.source.map { makeSingleLineText($0, x: sourceX, y: metaY, width: max(0, width - sourceX - 12), color: environment.palette.secondaryText, fontSize: metaFont) }
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
            regions: [InteractionRegion(rects: [avatar, name.bounds], action: .user(item.user.id.rawValue), accessibilityLabel: accessibilityLabel)] // 点击区域
        )
    }

    private static func formatProfileDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func makeCardLayout(_ card: FeedCard, x: CGFloat, y: CGFloat, width: CGFloat, environment: FeedLayoutEnvironment, cancellation: LayoutCancellation) throws -> CardLayout {
        try checkCancellation(cancellation)
        let height = max(64, CGFloat(environment.bodyLineHeight) + 32)
        let frame = CGRect(x: x, y: y, width: width, height: height)
        let imageFrame = card.imageURL == nil ? nil : CGRect(x: x, y: y, width: height, height: height)
        let textX = imageFrame?.maxX.advanced(by: 8) ?? x + 8
        let title = card.title ?? card.description ?? "Link"
        let text = makeSingleLineText(title, x: textX, y: y + (height - max(20, CGFloat(environment.bodyLineHeight))) / 2, width: max(0, frame.maxX - textX - 8), color: environment.palette.primaryText, fontSize: CGFloat(environment.bodyFontSize))
        let regions = card.targetURL.map { [InteractionRegion(rects: [frame], action: .url($0), accessibilityLabel: title)] } ?? []
        return CardLayout(frame: frame, imageFrame: imageFrame, text: text, regions: regions)
    }

    private static func makeTagLayout(_ tag: FeedTag, x: CGFloat, y: CGFloat, width: CGFloat, environment: FeedLayoutEnvironment, cancellation: LayoutCancellation) throws -> TagLayout {
        try checkCancellation(cancellation)
        let height = max(28, CGFloat(environment.bodyLineHeight) + 8)
        let frame = CGRect(x: x, y: y, width: width, height: height)
        let text = makeSingleLineText(tag.name, x: x + 8, y: y + 4, width: max(0, width - 16), color: environment.palette.accent, fontSize: CGFloat(environment.bodyFontSize))
        return TagLayout(frame: frame, text: text, regions: [InteractionRegion(rects: [frame], action: .tag(tag.name), accessibilityLabel: tag.name)])
    }

    private static func makeSingleLineText(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat, color: FeedRGBA, fontSize: CGFloat = 16) -> TextLayout {
        guard width > 0 else {
            return TextLayout(storage: CoreTextLayoutStorage(lines: [], origins: []), bounds: CGRect(x: x, y: y, width: 0, height: 0), regions: [])
        }
        let attributes: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): CTFontCreateWithName(".AppleSystemUIFont" as CFString, fontSize, nil), .init(kCTForegroundColorAttributeName as String): color.cgColor]
        let attributed = NSAttributedString(string: value, attributes: attributes)
        let original = CTLineCreateWithAttributedString(attributed)
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
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
        let lineHeight = max(20, fontSize * 1.25)
        return TextLayout(storage: CoreTextLayoutStorage(lines: [line], origins: [CGPoint(x: x, y: y + fontSize)]), bounds: CGRect(x: x, y: y, width: width, height: lineHeight), regions: [])
    }

    private static func makeTextLayout(
        _ parsed: ParsedFeedText,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        itemID: FeedID,
        environment: FeedLayoutEnvironment,
        maximumLines: Int?,
        cancellation: LayoutCancellation
    ) throws -> TextLayout {
        try checkCancellation(cancellation)
        let lineHeight = CGFloat(environment.bodyLineHeight)
        let fontSize = CGFloat(environment.bodyFontSize)
        let ascent = min(lineHeight - 2, fontSize)
        let prepared = makeAttributedText(
            parsed: parsed,
            lineHeight: lineHeight,
            fontSize: fontSize,
            ascent: ascent,
            environment: environment
        )
        let text = prepared.text
        let replacements = prepared.replacements
        try checkCancellation(cancellation)
        // 从当前字符开始，在指定宽度内（一行）最多能容纳多少字符？
        let typesetter = CTTypesetterCreateWithAttributedString(text)
        var lines = [CTLine]()
        var origins = [CGPoint]()
        var ranges = [CFRange]()
        var indexBases = [Int]()
        var index = 0
        let length = text.length
        let lineLimit = maximumLines ?? Int.max
        while index < length && lines.count < lineLimit {
            try checkCancellation(cancellation)
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, index, Double(width)))
            let range = CFRange(location: index, length: min(count, length - index))
            lines.append(CTTypesetterCreateLine(typesetter, range))
            // CoreText 绘制文字使用的是“基线坐标”，不是 UILabel 常见的左上角坐标。
            origins.append(CGPoint(x: x, y: y + CGFloat(lines.count - 1) * lineHeight + ascent))
            ranges.append(range)
            indexBases.append(0)
            index += range.length
        }
        let truncated = index < length // 如果文本还没结束，表示正文被截断。
        var visibleUTF16End = length
        var expandRect: CGRect?
        // 最后一行添加 … More
        if truncated, let finalRange = ranges.last, let origin = origins.last {
            let token = NSAttributedString(
                string: "… More",
                attributes: [.init(kCTFontAttributeName as String): CTFontCreateWithName(".AppleSystemUIFont" as CFString, fontSize, nil), .init(kCTForegroundColorAttributeName as String): environment.palette.accent.cgColor]
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
            expandRect = CGRect(x: x + tokenOffset, y: origin.y - ascent, width: tokenWidth, height: lineHeight)
        }
        // 得到正文总高度
        let bounds = CGRect(x: x, y: y, width: width, height: CGFloat(lines.count) * lineHeight)
        if let rect = expandRect {
            let hitWidth = max(44, rect.width)
            let hitHeight: CGFloat = 44
            var minX = rect.midX - hitWidth / 2
            var minY = rect.midY - hitHeight / 2
            minX = max(bounds.minX, minX)
            minX = min(bounds.maxX - hitWidth, minX)
            minY = max(bounds.minY, minY)
            minY = min(bounds.maxY - hitHeight, minY)
            expandRect = CGRect(x: minX, y: minY, width: hitWidth, height: hitHeight)
        }
        var regions = makeSemanticRegions(
            parsed: parsed,
            replacements: replacements,
            visibleUTF16End: visibleUTF16End,
            lineRanges: ranges,
            lines: lines,
            origins: origins,
            indexBases: indexBases,
            ascent: ascent,
            lineHeight: lineHeight
        )
        if let expandRect {
            regions.append(InteractionRegion(
                rects: [expandRect],
                action: .expand(itemID), // 用户点击 More 时，就能根据 itemID 展开对应微博。
                accessibilityLabel: "Expand"
            ))
        }
        let attachments = makeAttachments(
            lines: lines,
            origins: origins,
            visibleUTF16End: visibleUTF16End,
            ascent: ascent,
            lineHeight: lineHeight
        )
        // 1. CoreText 的行和坐标 2. 正文整体位置 3. 链接和 More 的点击区域 4. 表情图片及位置
        return TextLayout(storage: CoreTextLayoutStorage(lines: lines, origins: origins), bounds: bounds, regions: regions, attachments: attachments)
    }

    private static let attachmentImageKey = NSAttributedString.Key("FeedEmoticonImage")
    // 设置字体和颜色，固定行高，（链接，话题，@用户的蓝色）表情图片占位
    private static func makeAttributedText(
        parsed: ParsedFeedText,
        lineHeight: CGFloat,
        fontSize: CGFloat,
        ascent: CGFloat,
        environment: FeedLayoutEnvironment
    ) -> PreparedAttributedText {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.lineSpacing = 0
        let text = NSMutableAttributedString(
            string: parsed.source,
            attributes: [
                .init(kCTFontAttributeName as String): CTFontCreateWithName(".AppleSystemUIFont" as CFString, fontSize, nil),
                .init(kCTForegroundColorAttributeName as String): environment.palette.primaryText.cgColor,
                .paragraphStyle: paragraph
            ]
        )
        var emoticons = [(range: NSRange, image: CGImage)]()
        for span in parsed.spans {
            guard span.kind == .emoticon,
                  let name = span.emoticonName,
                  let image = FeedEmoticonResolver.image(named: name) else { continue }
            emoticons.append((NSRange(span.range, in: parsed.source), image))
        }
        emoticons.sort { $0.range.location < $1.range.location }

        var replacements = [(original: NSRange, displayLocation: Int, image: CGImage)]()
        var removed = 0
        for emoticon in emoticons {
            let location = emoticon.range.location - removed
            let metrics = RunDelegateMetrics(
                width: lineHeight,
                ascent: ascent,
                descent: max(0, lineHeight - ascent)
            )
            guard let delegate = makeRunDelegate(metrics) else { continue }
            text.replaceCharacters(in: NSRange(location: location, length: emoticon.range.length), with: "\u{FFFC}")
            text.addAttributes([
                .init(kCTRunDelegateAttributeName as String): delegate,
                attachmentImageKey: AttachmentImageBox(emoticon.image)
            ], range: NSRange(location: location, length: 1))
            replacements.append((emoticon.range, location, emoticon.image))
            removed += emoticon.range.length - 1
        }

        for span in parsed.spans {
            guard span.kind != .plain, span.kind != .emoticon else { continue }
            let range = displayRange(for: NSRange(span.range, in: parsed.source), replacements: replacements)
            text.addAttribute(
                .init(kCTForegroundColorAttributeName as String),
                value: environment.palette.accent.cgColor,
                range: range
            )
        }
        return PreparedAttributedText(text: text, replacements: replacements)
    }

    private static func makeRunDelegate(_ metrics: RunDelegateMetrics) -> CTRunDelegate? {
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateCurrentVersion,
            dealloc: feedRunDelegateDealloc,
            getAscent: feedRunDelegateGetAscent,
            getDescent: feedRunDelegateGetDescent,
            getWidth: feedRunDelegateGetWidth
        )
        let refCon = Unmanaged.passRetained(metrics).toOpaque()
        //这个字符宽度 = 一行高度
        //这个字符实际需要绘制一张表情图片
        guard let delegate = CTRunDelegateCreate(&callbacks, refCon) else {
            Unmanaged<RunDelegateMetrics>.fromOpaque(refCon).release()
            return nil
        }
        return delegate
    }

    private static func makeSemanticRegions(
        parsed: ParsedFeedText,
        replacements: [(original: NSRange, displayLocation: Int, image: CGImage)],
        visibleUTF16End: Int,
        lineRanges: [CFRange],
        lines: [CTLine],
        origins: [CGPoint],
        indexBases: [Int],
        ascent: CGFloat,
        lineHeight: CGFloat
    ) -> [InteractionRegion] {
        var regions = [InteractionRegion]()
        let visibleRange = NSRange(location: 0, length: visibleUTF16End)
        for span in parsed.spans {
            guard let action = span.action else { continue }
            let semanticRange = displayRange(for: NSRange(span.range, in: parsed.source), replacements: replacements)
            let clipped = NSIntersectionRange(semanticRange, visibleRange)
            guard clipped.length > 0 else { continue }
            let rects = interactionRects(
                for: clipped,
                lineRanges: lineRanges,
                lines: lines,
                origins: origins,
                indexBases: indexBases,
                ascent: ascent,
                lineHeight: lineHeight
            )
            guard !rects.isEmpty else { continue }
            regions.append(InteractionRegion(
                rects: rects,
                action: action,
                accessibilityLabel: String(parsed.source[span.range])
            ))
        }
        return regions
    }

    private static func makeAttachments(
        lines: [CTLine],
        origins: [CGPoint],
        visibleUTF16End: Int,
        ascent: CGFloat,
        lineHeight: CGFloat
    ) -> [TextAttachment] {
        var attachments = [TextAttachment]()
        for lineIndex in lines.indices {
            for run in CTLineGetGlyphRuns(lines[lineIndex]) as! [CTRun] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let image = (attributes[attachmentImageKey] as? AttachmentImageBox)?.image else { continue }
                let runRange = CTRunGetStringRange(run)
                guard runRange.location < visibleUTF16End else { continue }
                let offset = CGFloat(CTLineGetOffsetForStringIndex(lines[lineIndex], runRange.location, nil))
                let runWidth = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil))
                attachments.append(TextAttachment(
                    image: image,
                    frame: CGRect(
                        x: origins[lineIndex].x + offset,
                        y: origins[lineIndex].y - ascent,
                        width: runWidth,
                        height: lineHeight
                    )
                ))
            }
        }
        return attachments
    }

    private static func displayRange(for original: NSRange, replacements: [(original: NSRange, displayLocation: Int, image: CGImage)]) -> NSRange {
        let before = replacements.filter { NSMaxRange($0.original) <= original.location }.reduce(0) { $0 + $1.original.length - 1 }
        let inside = replacements.filter { $0.original.location >= original.location && NSMaxRange($0.original) <= NSMaxRange(original) }
        let removedInside = inside.reduce(0) { $0 + $1.original.length - 1 }
        return NSRange(location: original.location - before, length: original.length - removedInside)
    }

    private static func interactionRects(
        for range: NSRange,
        lineRanges: [CFRange],
        lines: [CTLine],
        origins: [CGPoint],
        indexBases: [Int],
        ascent: CGFloat,
        lineHeight: CGFloat
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
            return CGRect(x: origin.x + min(start, end), y: origin.y - ascent, width: max(abs(end - start), 1), height: lineHeight)
        }
    }
    // 表示图片数量、起始位置以及图片区可用宽度。
    private static func mediaFrames(count: Int, x: CGFloat, y: CGFloat, availableWidth: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        if count == 1 {
            // Match the original YYKit fallback for pictures without usable
            // metadata: a square occupying half of the content width.
            let side = availableWidth / 2
            return [CGRect(x: x, y: y, width: side, height: side)]
        }
        // 四张图采用两列，否则三列
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

private final class RunDelegateMetrics {
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    init(width: CGFloat, ascent: CGFloat, descent: CGFloat) {
        self.width = width
        self.ascent = ascent
        self.descent = descent
    }
}

private func feedRunDelegateDealloc(_ refCon: UnsafeMutableRawPointer) {
    Unmanaged<RunDelegateMetrics>.fromOpaque(refCon).release()
}

private func feedRunDelegateGetAscent(_ refCon: UnsafeMutableRawPointer) -> CGFloat {
    Unmanaged<RunDelegateMetrics>.fromOpaque(refCon).takeUnretainedValue().ascent
}

private func feedRunDelegateGetDescent(_ refCon: UnsafeMutableRawPointer) -> CGFloat {
    Unmanaged<RunDelegateMetrics>.fromOpaque(refCon).takeUnretainedValue().descent
}

private func feedRunDelegateGetWidth(_ refCon: UnsafeMutableRawPointer) -> CGFloat {
    Unmanaged<RunDelegateMetrics>.fromOpaque(refCon).takeUnretainedValue().width
}

private struct PreparedAttributedText {
    let text: NSMutableAttributedString
    let replacements: [(original: NSRange, displayLocation: Int, image: CGImage)]
}

private final class AttachmentImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
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
