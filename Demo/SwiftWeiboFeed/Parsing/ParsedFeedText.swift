public struct FeedTextSpan: Hashable, Sendable {
    public let kind: FeedSpanKind
    public let range: Range<String.Index>
    public let action: FeedAction?
    public let emoticonName: String?

    public init(
        kind: FeedSpanKind,
        range: Range<String.Index>,
        action: FeedAction? = nil,
        emoticonName: String? = nil
    ) {
        self.kind = kind
        self.range = range
        self.action = action
        self.emoticonName = emoticonName
    }
}

public struct ParsedFeedText: Sendable {
    public let source: String
    public let spans: [FeedTextSpan]

    public init(source: String, spans: [FeedTextSpan]) {
        self.source = source
        self.spans = spans
    }
}
