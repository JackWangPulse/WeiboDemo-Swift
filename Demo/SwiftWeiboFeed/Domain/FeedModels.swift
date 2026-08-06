import Foundation

/*
 {
   "statuses": [
     {
       "id": 123,
       "user": {
         "id": "456",
         "screen_name": "续迁 pocky",
         "avatar_large": "http://example.com/avatar.jpg",
         "verified": true,
         "mbrank": 4
       }
     }
   ]
 }
 解析成
 FeedPage(
     items: [
         FeedItem(
             user: FeedUser(
                 id: FeedID(rawValue: "456"),
                 name: "续迁 pocky",
                 avatarURL: ...,
                 isVerified: true,
                 membershipRank: 4
             )
         )
     ]
 )
 */

public extension JSONDecoder {  // 自定义 Decodable：怎样兼容微博 JSON 中缺字段、错误类型和旧 URL。
    static var weibo: JSONDecoder { JSONDecoder() }
}
// Decodable表示它可以从 JSON、Plist 等编码数据中被创建。
// Sendable 它表示这个值可以安全地从一个并发执行环境传给另一个执行环境。可多线程通信
public struct FeedPage: Decodable, Sendable { // 一次加载的一页微博
    public let items: [FeedItem]
    // 把 statuses 映射成 items
    private enum CodingKeys: String, CodingKey { case items = "statuses" }
}

public struct FeedUser: Decodable, Hashable, Sendable {  //用户、头像、认证和会员信息。
    // 用户基本信息
    public let id: FeedID
    public let name: String
    public let avatarURL: URL?
    // 认证信息
    public let isVerified: Bool
    public let verifiedType: Int?
    public let verifiedLevel: Int?
    public let verifiedReason: String?
    // 会员信息
    public let membershipRank: Int
    // 处理字段差异
    private enum CodingKeys: String, CodingKey {
        case id, name
        case screenName = "screen_name"
        case avatarURL = "avatar_large"
        case profileImageURL = "profile_image_url"
        case isVerified = "verified"
        case verifiedType = "verified_type"
        case verifiedLevel = "verified_level"
        case verifiedReason = "verified_reason"
        case membershipRank = "mbrank"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(FeedID.self, forKey: .id) // 没有用try? 说明id必须要有
        // 两级fallback
        if let name = try container.decodeIfPresent(String.self, forKey: .name) {
            self.name = name
        } else {
            name = try container.decode(String.self, forKey: .screenName)
        }
        // 头像也是两级fallback 首先获取高清 不行就nil
        avatarURL = container.lossyURL(forKey: .avatarURL)
            ?? container.lossyURL(forKey: .profileImageURL)
        isVerified = (try? container.decodeIfPresent(Bool.self, forKey: .isVerified)) ?? false
        verifiedType = try? container.decodeIfPresent(Int.self, forKey: .verifiedType)
        verifiedLevel = try? container.decodeIfPresent(Int.self, forKey: .verifiedLevel)
        verifiedReason = try? container.decodeIfPresent(String.self, forKey: .verifiedReason)
        membershipRank = (try? container.decodeIfPresent(Int.self, forKey: .membershipRank)) ?? 0
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

    init(id: String?, url: URL?) {
        self.id = id
        self.url = url
    }
}

private struct FeedPictureVariant: Decodable {
    let url: URL?

    private enum CodingKeys: String, CodingKey { case url }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = container.lossyURL(forKey: .url)
    }
}

private struct FeedPictureInfo: Decodable {
    let id: String?
    let thumbnail: FeedPictureVariant?
    let bmiddle: FeedPictureVariant?
    let middleplus: FeedPictureVariant?
    let large: FeedPictureVariant?
    let largest: FeedPictureVariant?
    let original: FeedPictureVariant?

    var preferredURL: URL? {
        if let url = thumbnail?.url { return url }
        if let url = bmiddle?.url { return url }
        if let url = middleplus?.url { return url }
        if let url = large?.url { return url }
        if let url = largest?.url { return url }
        return original?.url
    }

    private enum CodingKeys: String, CodingKey {
        case id = "pic_id"
        case thumbnail, bmiddle, middleplus, large, largest, original
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
    // URL 字段有问题时允许丢弃这个字段，不让整个模型解码失败。
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
// indirect 表示枚举关联值使用间接存储。??
private indirect enum FeedItemRepost: Decodable, Hashable, Sendable {
    case item(FeedItem)

    init(from decoder: Decoder) throws {
        self = .item(try FeedItem(from: decoder))
    }
}

public struct FeedItem: Decodable, Hashable, Sendable {  // 一条微博的完整数据
    // 核心内容
    public let id: FeedID
    public let user: FeedUser
    public let text: String
    // 媒体
    public let pictures: [FeedPicture]
    // 附加内容
    public var repost: FeedItem? {
        guard case let .item(item)? = repostStorage else { return nil }
        return item
    } // 业务上，转发微博本身也是一条微博，间接枚举 节省内存
    public let card: FeedCard? // Card 对应微博中的链接卡片
    public let tags: [FeedTag]
    // 互动数据
    public let repostCount: Int
    public let commentCount: Int
    public let likeCount: Int
    // 元数据
    public let createdAt: Date?
    public let source: String?

    private let repostStorage: FeedItemRepost?

    private enum CodingKeys: String, CodingKey {
        case id, user, text, pics
        case pictureURLs = "pic_urls"
        case pictureIDs = "pic_ids"
        case pictureInfos = "pic_infos"
        case repost = "retweeted_status"
        case card = "page_info"
        case tags = "tag_struct"
        case repostCount = "reposts_count"
        case commentCount = "comments_count"
        case likeCount = "attitudes_count"
        case createdAt = "created_at"
        case source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 必须要的字段 没id建立不了缓存和cell身份 没user展示不了作者主页 处理不了用户点击 没text则丢失文本主体
        id = try container.decode(FeedID.self, forKey: .id)
        user = try container.decode(FeedUser.self, forKey: .user)
        text = try container.decode(String.self, forKey: .text)
        // FeedPicture 只保存图片身份和 URL ImagePipeline 负责下载和解码
        let directPictures = (try? container.decodeIfPresent([FeedPicture].self, forKey: .pics))
            ?? (try? container.decodeIfPresent([FeedPicture].self, forKey: .pictureURLs))
            ?? []
        if directPictures.isEmpty {
            let infos = (try? container.decodeIfPresent([String: FeedPictureInfo].self, forKey: .pictureInfos)) ?? [:]
            let declaredIDs = (try? container.decodeIfPresent([String].self, forKey: .pictureIDs)) ?? []
            let orderedIDs = declaredIDs.isEmpty ? infos.keys.sorted() : declaredIDs
            pictures = orderedIDs.map { id in
                let info = infos[id]
                return FeedPicture(id: info?.id ?? id, url: info?.preferredURL)
            }
        } else {
            pictures = directPictures
        }
        // 业务上，转发微博本身也是一条微博
        repostStorage = try? container.decodeIfPresent(FeedItemRepost.self, forKey: .repost)
        card = try? container.decodeIfPresent(FeedCard.self, forKey: .card)
        tags = (try? container.decodeIfPresent([FeedTag].self, forKey: .tags)) ?? []
        repostCount = (try? container.decodeIfPresent(Int.self, forKey: .repostCount)) ?? 0
        commentCount = (try? container.decodeIfPresent(Int.self, forKey: .commentCount)) ?? 0
        likeCount = (try? container.decodeIfPresent(Int.self, forKey: .likeCount)) ?? 0
        let createdAtString = try? container.decodeIfPresent(String.self, forKey: .createdAt)
        createdAt = createdAtString.flatMap(Self.parseWeiboDate)
        source = (try? container.decodeIfPresent(String.self, forKey: .source)).flatMap(Self.normalizedSource)
    }

    private static func parseWeiboDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return formatter.date(from: value)
    }

    private static func normalizedSource(_ raw: String) -> String? {
        var normalized = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        normalized = decodeHTMLEntitiesOnce(normalized)
        normalized = normalized
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func decodeHTMLEntitiesOnce(_ source: String) -> String {
        let named = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">"]
        var result = ""
        var cursor = source.startIndex
        while cursor < source.endIndex {
            guard source[cursor] == "&", let semicolon = source[cursor...].firstIndex(of: ";") else {
                result.append(source[cursor]); cursor = source.index(after: cursor); continue
            }
            let entityStart = source.index(after: cursor)
            let entity = String(source[entityStart..<semicolon])
            let decoded: String?
            if let namedValue = named[entity] {
                decoded = namedValue
            } else if entity.hasPrefix("#x"), let value = UInt32(entity.dropFirst(2), radix: 16), let scalar = UnicodeScalar(value) {
                decoded = String(scalar)
            } else if entity.hasPrefix("#"), let value = UInt32(entity.dropFirst()), let scalar = UnicodeScalar(value) {
                decoded = String(scalar)
            } else {
                decoded = nil
            }
            guard let decoded else {
                result.append(source[cursor]); cursor = source.index(after: cursor); continue
            }
            result += decoded
            cursor = source.index(after: semicolon)
        }
        return result
    }
}
