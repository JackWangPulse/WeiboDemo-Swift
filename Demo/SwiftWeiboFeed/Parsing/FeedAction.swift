import Foundation

public enum FeedSpanKind: Hashable, Sendable {
    case plain
    case mention
    case topic
    case link
    case emoticon
}

public enum FeedAction: Hashable, Sendable {
    case user(String)
    case topic(String)
    case url(URL)
    case tag(String)
    case expand(FeedID)
    case repost
    case comment
    case like
}
