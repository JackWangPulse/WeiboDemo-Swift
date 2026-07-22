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

    func testTrailingSentencePunctuationRemainsPlain() throws {
        let cases = [
            ("https://example.com/path,", "https://example.com/path", ","),
            ("https://example.com/path.", "https://example.com/path", "."),
            ("https://example.com/path。", "https://example.com/path", "。"),
            ("https://example.com/path，", "https://example.com/path", "，"),
            ("https://example.com/path）", "https://example.com/path", "）")
        ]

        for (source, link, punctuation) in cases {
            let result = parser.parse(source)

            XCTAssertEqual(result.spans.map(\.kind), [.link, .plain], source)
            XCTAssertEqual(String(source[result.spans[0].range]), link, source)
            XCTAssertEqual(String(source[result.spans[1].range]), punctuation, source)
            XCTAssertEqual(result.spans[0].action, .url(try XCTUnwrap(URL(string: link))), source)
        }
    }

    func testTrailingASCIIProseTerminatorsAndClosingQuotesRemainPlain() {
        let cases = ["!", "?", ";", ":", "\"", "'", "”", "’"]

        for punctuation in cases {
            let source = "https://example.com/path\(punctuation)"
            let result = parser.parse(source)

            XCTAssertEqual(result.spans.map(\.kind), [.link, .plain], source)
            XCTAssertEqual(String(source[result.spans[0].range]), "https://example.com/path", source)
            XCTAssertEqual(String(source[result.spans[1].range]), punctuation, source)
        }
    }

    func testTerminalQueryPunctuationAndPortSyntaxRemainInURL() {
        let cases = [
            "https://example.com/search?q=what?",
            "https://example.com/search?q=wow!",
            "https://example.com/search?q=value;",
            "https://example.com/search?q=value:",
            "https://example.com:8080/path"
        ]

        for source in cases {
            let result = parser.parse(source)

            XCTAssertEqual(result.spans.map(\.kind), [.link], source)
            XCTAssertEqual(String(source[result.spans[0].range]), source, source)
        }
    }

    func testBalancedClosingParenthesisRemainsPartOfURL() {
        let source = "https://example.com/wiki/Function_(math)"

        let result = parser.parse(source)

        XCTAssertEqual(result.spans.map(\.kind), [.link])
        XCTAssertEqual(String(source[result.spans[0].range]), source)
    }

    func testMalformedAndHostlessHTTPCandidatesRemainPlain() {
        let cases = ["http://", "https:///path", "http://?query"]

        for source in cases {
            let result = parser.parse(source)

            XCTAssertEqual(result.spans.map(\.kind), [.plain], source)
            XCTAssertNil(result.spans[0].action, source)
        }
    }

    func testMalformedHTTPCandidateBlocksNestedSemanticRecognition() {
        let source = "https:///path#topic#/@alice/[笑哭]"

        let result = parser.parse(source)

        XCTAssertEqual(result.spans.map(\.kind), [.plain])
        XCTAssertEqual(String(source[result.spans[0].range]), source)
        XCTAssertNil(result.spans[0].action)
    }

    func testTopicWinsOverOverlappingMention() {
        let source = "#@alice#"

        let result = parser.parse(source)

        XCTAssertEqual(result.spans.map(\.kind), [.topic])
        XCTAssertEqual(result.spans[0].action, .topic("@alice"))
    }

    func testTopicWinsOverOverlappingEmoticon() {
        let source = "#[笑哭]#"

        let result = parser.parse(source)

        XCTAssertEqual(result.spans.map(\.kind), [.topic])
        XCTAssertEqual(result.spans[0].action, .topic("[笑哭]"))
    }

    func testAdjacentCandidateSurvivesAfterRejectedOverlap() {
        let source = "#@alice#[鼓掌]"

        let result = parser.parse(source)

        XCTAssertEqual(result.spans.map(\.kind), [.topic, .emoticon])
        XCTAssertEqual(result.spans[0].action, .topic("@alice"))
        XCTAssertEqual(result.spans[1].emoticonName, "鼓掌")
        XCTAssertEqual(result.spans.map { String(source[$0.range]) }.joined(), source)
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
