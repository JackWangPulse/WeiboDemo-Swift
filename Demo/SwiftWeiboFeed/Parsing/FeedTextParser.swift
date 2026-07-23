import Foundation

public struct FeedTextParser: Sendable {
    public init() {}

    public func parse(_ source: String) -> ParsedFeedText {
        FeedSignpost.measure(.parse) { parseUninstrumented(source) }
    }

    private func parseUninstrumented(_ source: String) -> ParsedFeedText {
        guard !source.isEmpty else { return ParsedFeedText(source: source, spans: []) }

        var accepted: [FeedTextSpan] = []
        for candidates in [links(in: source), topics(in: source), mentions(in: source), emoticons(in: source)] {
            for candidate in candidates where !accepted.contains(where: { $0.range.overlaps(candidate.range) }) {
                accepted.append(candidate)
            }
        }
        accepted.sort { $0.range.lowerBound < $1.range.lowerBound }

        var spans: [FeedTextSpan] = []
        var cursor = source.startIndex
        for match in accepted {
            if cursor < match.range.lowerBound {
                spans.append(FeedTextSpan(kind: .plain, range: cursor..<match.range.lowerBound))
            }
            spans.append(match)
            cursor = match.range.upperBound
        }
        if cursor < source.endIndex {
            spans.append(FeedTextSpan(kind: .plain, range: cursor..<source.endIndex))
        }
        return ParsedFeedText(source: source, spans: spans)
    }

    private func links(in source: String) -> [FeedTextSpan] {
        matches(in: source, startsWith: { suffix in
            suffix.hasPrefix("https://") || suffix.hasPrefix("http://")
        }) { start, source in
            var end = start
            while end < source.endIndex, !source[end].isWhitespace {
                source.formIndex(after: &end)
            }
            let candidateRange = start..<end
            end = Self.trimmingSentencePunctuation(from: start..<end, in: source)
            guard end > start else {
                return FeedTextSpan(kind: .plain, range: candidateRange)
            }
            let range = start..<end
            guard let url = Self.validHTTPURL(String(source[range])) else {
                return FeedTextSpan(kind: .plain, range: candidateRange)
            }
            return FeedTextSpan(kind: .link, range: range, action: .url(url))
        }
    }

    private func topics(in source: String) -> [FeedTextSpan] {
        matches(in: source, startsWith: { $0.first == "#" }) { start, source in
            let contentStart = source.index(after: start)
            guard contentStart < source.endIndex,
                  let closing = source[contentStart...].firstIndex(of: "#"),
                  closing > contentStart else { return nil }
            let end = source.index(after: closing)
            return FeedTextSpan(
                kind: .topic,
                range: start..<end,
                action: .topic(String(source[contentStart..<closing]))
            )
        }
    }

    private func mentions(in source: String) -> [FeedTextSpan] {
        matches(in: source, startsWith: { $0.first == "@" }) { start, source in
            let nameStart = source.index(after: start)
            var end = nameStart
            while end < source.endIndex, Self.isMentionCharacter(source[end]) {
                source.formIndex(after: &end)
            }
            guard end > nameStart else { return nil }
            return FeedTextSpan(
                kind: .mention,
                range: start..<end,
                action: .user(String(source[nameStart..<end]))
            )
        }
    }

    private func emoticons(in source: String) -> [FeedTextSpan] {
        matches(in: source, startsWith: { $0.first == "[" }) { start, source in
            let nameStart = source.index(after: start)
            guard nameStart < source.endIndex,
                  let closing = source[nameStart...].firstIndex(of: "]"),
                  closing > nameStart else { return nil }
            let end = source.index(after: closing)
            return FeedTextSpan(
                kind: .emoticon,
                range: start..<end,
                emoticonName: String(source[nameStart..<closing])
            )
        }
    }

    private func matches(
        in source: String,
        startsWith: (Substring) -> Bool,
        makeMatch: (String.Index, String) -> FeedTextSpan?
    ) -> [FeedTextSpan] {
        var result: [FeedTextSpan] = []
        var index = source.startIndex
        while index < source.endIndex {
            if startsWith(source[index...]), let match = makeMatch(index, source) {
                result.append(match)
            }
            source.formIndex(after: &index)
        }
        return result
    }

    private static func isMentionCharacter(_ character: Character) -> Bool {
        character == "_" || character.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
        }
    }

    private static func validHTTPURL(_ token: String) -> URL? {
        guard let components = URLComponents(string: token),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty else { return nil }
        return components.url
    }

    private static func trimmingSentencePunctuation(
        from range: Range<String.Index>,
        in source: String
    ) -> String.Index {
        var end = range.upperBound
        while end > range.lowerBound {
            let lastIndex = source.index(before: end)
            let character = source[lastIndex]
            if terminalSentencePunctuation.contains(character)
                || terminalClosingQuotes.contains(character)
                || shouldTrimAmbiguousASCIITerminator(character, in: source[range.lowerBound..<end])
                || isUnmatchedClosing(character, before: end, in: source[range.lowerBound..<end]) {
                end = lastIndex
            } else {
                break
            }
        }
        return end
    }

    private static let terminalSentencePunctuation: Set<Character> = [
        ".", ",", "。", "，", "！", "？", "；", "："
    ]

    private static let terminalClosingQuotes: Set<Character> = ["\"", "'", "”", "’"]

    private static let ambiguousASCIITerminators: Set<Character> = ["!", "?", ";", ":"]

    private static let closingPairs: [Character: Character] = [
        ")": "(", "]": "[", "}": "{", "）": "（", "】": "【",
        "》": "《", "〉": "〈", "」": "「", "』": "『"
    ]

    private static func isUnmatchedClosing(
        _ character: Character,
        before end: String.Index,
        in token: Substring
    ) -> Bool {
        guard let opening = closingPairs[character] else { return false }
        let prefix = token[..<end]
        return prefix.filter { $0 == character }.count > prefix.filter { $0 == opening }.count
    }

    private static func shouldTrimAmbiguousASCIITerminator(
        _ character: Character,
        in token: Substring
    ) -> Bool {
        guard ambiguousASCIITerminators.contains(character) else { return false }
        guard let components = URLComponents(string: String(token)),
              let query = components.percentEncodedQuery,
              !query.isEmpty,
              query.contains("=") else { return true }
        return false
    }
}
