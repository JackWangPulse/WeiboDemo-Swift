import XCTest
@testable import SwiftWeiboFeed

final class FeedModelsTests: XCTestCase {
    func testDecodesBundledTimeline() throws {
        let data = try FeedFixtureLoader.data(named: "weibo_0")
        let page = try JSONDecoder.weibo.decode(FeedPage.self, from: data)
        XCTAssertFalse(page.items.isEmpty)
        XCTAssertFalse(page.items[0].id.rawValue.isEmpty)
    }

    func testDecodesEveryBundledTimeline() throws {
        for fixtureIndex in 0...7 {
            let data = try FeedFixtureLoader.data(named: "weibo_\(fixtureIndex)")
            let page = try JSONDecoder.weibo.decode(FeedPage.self, from: data)
            XCTAssertFalse(page.items.isEmpty, "weibo_\(fixtureIndex) should contain feed items")
        }
    }

    func testDecodesPicInfosInPicIDOrder() throws {
        let data = try FeedFixtureLoader.data(named: "weibo_0")
        let page = try JSONDecoder.weibo.decode(FeedPage.self, from: data)

        XCTAssertEqual(page.items[7].pictures.count, 2)
        XCTAssertEqual(page.items[9].repost?.pictures.count, 9)
        XCTAssertEqual(
            page.items[9].repost?.pictures.first?.url?.absoluteString,
            "http://ww3.sinaimg.cn/or180/648ac377gw1evvb5q5xw9j20k50qo7ar.jpg"
        )
        XCTAssertEqual(
            page.items[9].repost?.pictures.map(\.id),
            [
                "648ac377gw1evvb5q5xw9j20k50qo7ar",
                "648ac377gw1evvb64986kj20ke0qo79q",
                "648ac377gw1evvb638ctyj20jg0qon80",
                "648ac377gw1evvb5p5racj20kg0p07eo",
                "648ac377gw1evvb61yq07j20kg0q8wqx",
                "648ac377gw1evvb671w2nj20kg0pugvo",
                "648ac377gw1evvb6917s9j20kg0qdwkm",
                "648ac377gw1evvb69y6z0j20kg0ox0y5",
                "648ac377gw1evvb6bwk53j20kg0o7q8n",
            ]
        )
    }

    func testMissingOptionalMediaDoesNotFailItem() throws {
        let json = #"{"statuses":[{"id":1,"text":"hello","user":{"id":2,"name":"A"}}]}"#.data(using: .utf8)!
        let page = try JSONDecoder.weibo.decode(FeedPage.self, from: json)
        XCTAssertEqual(page.items[0].pictures, [])
        XCTAssertNil(page.items[0].repost)
    }

    func testDecodesStringIDsAndDefaultsAbsentCountsAndTags() throws {
        let json = #"{"statuses":[{"id":"1","text":"hello","user":{"id":"2","name":"A"}}]}"#.data(using: .utf8)!
        let item = try JSONDecoder.weibo.decode(FeedPage.self, from: json).items[0]
        XCTAssertEqual(item.id, FeedID(rawValue: "1"))
        XCTAssertEqual(item.user.id, FeedID(rawValue: "2"))
        XCTAssertEqual(item.tags, [])
        XCTAssertEqual(item.repostCount, 0)
        XCTAssertEqual(item.commentCount, 0)
        XCTAssertEqual(item.likeCount, 0)
        XCTAssertNil(item.createdAt)
        XCTAssertNil(item.source)
        XCTAssertFalse(item.user.isVerified)
    }

    func testDecodesProfileMetadataAndNormalizesHTMLSource() throws {
        let json = #"{"statuses":[{"id":"1","created_at":"Fri Sep 11 20:41:01 +0800 2015","source":"<a href=\"https://weibo.com\">Foo &amp; Bar &#x4E2D;&#25991;</a>","text":"hello","user":{"id":"2","name":"A","verified":true,"verified_type":0,"verified_reason":"Author"}}]}"#.data(using: .utf8)!
        let item = try JSONDecoder.weibo.decode(FeedPage.self, from: json).items[0]
        XCTAssertNotNil(item.createdAt)
        XCTAssertEqual(item.source, "Foo & Bar 中文")
        XCTAssertTrue(item.user.isVerified)
        XCTAssertEqual(item.user.verifiedType, 0)
        XCTAssertEqual(item.user.verifiedReason, "Author")
    }

    func testMalformedOptionalProfileMetadataIsTolerated() throws {
        let json = #"{"statuses":[{"id":"1","created_at":"not-a-date","source":"<a></a>","text":"hello","user":{"id":"2","name":"A","verified":"bad","verified_type":"bad"}}]}"#.data(using: .utf8)!
        let item = try JSONDecoder.weibo.decode(FeedPage.self, from: json).items[0]
        XCTAssertNil(item.createdAt)
        XCTAssertNil(item.source)
        XCTAssertFalse(item.user.isVerified)
        XCTAssertNil(item.user.verifiedType)
    }

    func testSourceEntityDecodingIsSinglePassForNestedEncoding() throws {
        let json = #"{"statuses":[{"id":"1","source":"<a>&amp;#x41; &amp;lt; &#65; &#x4E2D;</a>","text":"hello","user":{"id":"2","name":"A"}}]}"#.data(using: .utf8)!
        let item = try JSONDecoder.weibo.decode(FeedPage.self, from: json).items[0]
        XCTAssertEqual(item.source, "&#x41; &lt; A 中")
    }
}
