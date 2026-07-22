import XCTest
@testable import SwiftWeiboFeed

final class FeedTextParserTests: XCTestCase {
    private let parser = FeedTextParser()

    func testParsesMixedSemanticText() throws {
        let source = "@alice 看#Swift# https://t.cn/a [笑哭]"

        let result = parser.parse(source)

        XCTAssertEqual(result.source, source)
        XCTAssertEqual(result.spans.map(\.kind), [.mention, .plain, .topic, .plain, .link, .plain, .emoticon])
        XCTAssertEqual(result.spans.compactMap(\.action).count, 3)
        XCTAssertEqual(result.spans.map { String(source[$0.range]) }, ["@alice", " 看", "#Swift#", " ", "https://t.cn/a", " ", "[笑哭]"])
        XCTAssertEqual(result.spans[0].action, .user("alice"))
        XCTAssertEqual(result.spans[2].action, .topic("Swift"))
        XCTAssertEqual(result.spans[4].action, .url(try XCTUnwrap(URL(string: "https://t.cn/a"))))
        XCTAssertEqual(result.spans[6].emoticonName, "笑哭")
    }

    func testLinkWinsOverLowerPriorityTokensInsideItsRange() {
        let source = "https://example.com/#Swift#/@alice/[笑哭]"

        let result = parser.parse(source)

        XCTAssertEqual(result.spans.map(\.kind), [.link])
        XCTAssertEqual(String(source[result.spans[0].range]), source)
    }

    func testMalformedTokensRemainPlainAndValidUnicodeRangesArePreserved() {
        let source = "👨‍👩‍👧‍👦 @甲 #未闭合 [坏"

        let result = parser.parse(source)

        XCTAssertEqual(result.spans.map(\.kind), [.plain, .mention, .plain])
        XCTAssertEqual(result.spans.map { String(source[$0.range]) }, ["👨‍👩‍👧‍👦 ", "@甲", " #未闭合 [坏"])
        XCTAssertTrue(result.spans.allSatisfy {
            $0.range.lowerBound >= source.startIndex && $0.range.upperBound <= source.endIndex
        })
        XCTAssertEqual(result.spans.map { String(source[$0.range]) }.joined(), source)
    }

    func testEmptySourceProducesNoSpans() {
        XCTAssertTrue(parser.parse("").spans.isEmpty)
    }
}
