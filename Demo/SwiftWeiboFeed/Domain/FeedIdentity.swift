import Foundation
// 为什么不直接用string 编译器能区分不同业务身份。 区分微博ID 用户ID
// Hashable 比较是否相等 作为 Dictionary 的 Key 作为缓存身份的一部分
public struct FeedID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try LosslessStringID(from: decoder).value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct FeedContentIdentity: Hashable, Sendable {
    public let itemID: FeedID
    public let contentVersion: UInt

    public init(itemID: FeedID, contentVersion: UInt) {
        self.itemID = itemID
        self.contentVersion = contentVersion
    }
}

struct LosslessStringID: Decodable {
    /*
     JSON ID
       ├─ String → 直接保存
       ├─ Int64  → 转成 String
       ├─ UInt64 → 转成 String
       └─ 其他类型 → 解码失败
    */
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self.value = value
        } else if let value = try? container.decode(Int64.self) {
            self.value = String(value)
        } else if let value = try? container.decode(UInt64.self) {
            self.value = String(value)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected a string or integer ID")
            )
        }
    }
}
