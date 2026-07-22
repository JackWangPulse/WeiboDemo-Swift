import Foundation

public extension JSONDecoder {
    static var weibo: JSONDecoder { JSONDecoder() }
}

public struct FeedPage: Decodable, Sendable {
    public let items: [FeedItem]

    private enum CodingKeys: String, CodingKey { case items = "statuses" }
}

public struct FeedUser: Decodable, Hashable, Sendable {
    public let id: FeedID
    public let name: String
    public let avatarURL: URL?

    private enum CodingKeys: String, CodingKey {
        case id, name
        case screenName = "screen_name"
        case avatarURL = "avatar_large"
        case profileImageURL = "profile_image_url"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(FeedID.self, forKey: .id)
        if let name = try container.decodeIfPresent(String.self, forKey: .name) {
            self.name = name
        } else {
            name = try container.decode(String.self, forKey: .screenName)
        }
        avatarURL = container.lossyURL(forKey: .avatarURL)
            ?? container.lossyURL(forKey: .profileImageURL)
    }
}

public struct FeedPicture: Decodable, Hashable, Sendable {
    public let id: String?
    public let url: URL?

    private enum CodingKeys: String, CodingKey {
        case id = "pid"
        case url
        case thumbnailURL = "thumbnail_pic"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        url = container.lossyURL(forKey: .url)
            ?? container.lossyURL(forKey: .thumbnailURL)
    }
}

public struct FeedCard: Decodable, Hashable, Sendable {
    public let title: String?
    public let description: String?
    public let imageURL: URL?
    public let targetURL: URL?

    private enum CodingKeys: String, CodingKey {
        case title = "page_title"
        case description = "page_desc"
        case imageURL = "page_pic"
        case targetURL = "page_url"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        imageURL = container.lossyURL(forKey: .imageURL)
        targetURL = container.lossyURL(forKey: .targetURL)
    }
}

private extension KeyedDecodingContainer {
    func lossyURL(forKey key: Key) -> URL? {
        guard let string = try? decodeIfPresent(String.self, forKey: key),
              !string.isEmpty else { return nil }
        return URL(string: string)
    }
}

public struct FeedTag: Decodable, Hashable, Sendable {
    public let name: String

    private enum CodingKeys: String, CodingKey {
        case name
        case tagName = "tag_name"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decode(String.self, forKey: .tagName)
    }
}

private indirect enum FeedItemRepost: Decodable, Hashable, Sendable {
    case item(FeedItem)

    init(from decoder: Decoder) throws {
        self = .item(try FeedItem(from: decoder))
    }
}

public struct FeedItem: Decodable, Hashable, Sendable {
    public let id: FeedID
    public let user: FeedUser
    public let text: String
    public let pictures: [FeedPicture]
    public var repost: FeedItem? {
        guard case let .item(item)? = repostStorage else { return nil }
        return item
    }
    public let card: FeedCard?
    public let tags: [FeedTag]
    public let repostCount: Int
    public let commentCount: Int
    public let likeCount: Int

    private let repostStorage: FeedItemRepost?

    private enum CodingKeys: String, CodingKey {
        case id, user, text, pics
        case pictureURLs = "pic_urls"
        case repost = "retweeted_status"
        case card = "page_info"
        case tags = "tag_struct"
        case repostCount = "reposts_count"
        case commentCount = "comments_count"
        case likeCount = "attitudes_count"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(FeedID.self, forKey: .id)
        user = try container.decode(FeedUser.self, forKey: .user)
        text = try container.decode(String.self, forKey: .text)
        pictures = (try? container.decodeIfPresent([FeedPicture].self, forKey: .pics))
            ?? (try? container.decodeIfPresent([FeedPicture].self, forKey: .pictureURLs))
            ?? []
        repostStorage = try? container.decodeIfPresent(FeedItemRepost.self, forKey: .repost)
        card = try? container.decodeIfPresent(FeedCard.self, forKey: .card)
        tags = (try? container.decodeIfPresent([FeedTag].self, forKey: .tags)) ?? []
        repostCount = (try? container.decodeIfPresent(Int.self, forKey: .repostCount)) ?? 0
        commentCount = (try? container.decodeIfPresent(Int.self, forKey: .commentCount)) ?? 0
        likeCount = (try? container.decodeIfPresent(Int.self, forKey: .likeCount)) ?? 0
    }
}
