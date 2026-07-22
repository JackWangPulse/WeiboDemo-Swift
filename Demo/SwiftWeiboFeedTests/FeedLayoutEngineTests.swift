import CoreGraphics
import CoreText
import UIKit
import XCTest
@testable import SwiftWeiboFeed

final class FeedLayoutEngineTests: XCTestCase {
    func testLayoutIsRepeatableWithExactHeightAndRunsOffMain() async throws {
        let item = try makeItem(text: "Hello @alice visit https://example.com #Swift#")
        let parsed = FeedTextParser().parse(item.text)
        let startsOnMain = LockedValues<Bool>()
        let engine = FeedLayoutEngine(layoutStartHook: {
            startsOnMain.append(Thread.isMainThread)
        })

        let identity = contentIdentity(for: item)
        let first = try await engine.layout(identity: identity, item: item, parsedBody: parsed, parsedRepost: nil, environment: environment())
        let second = try await engine.layout(identity: identity, item: item, parsedBody: parsed, parsedRepost: nil, environment: environment())

        XCTAssertEqual(first.height, second.height, accuracy: 0.001)
        XCTAssertEqual(first.height, 160, accuracy: 0.001)
        XCTAssertEqual(first.identity.content, identity)
        XCTAssertEqual(first.profile.regions.map(\.action), [.user("1")])
        XCTAssertEqual(first.body.bounds, second.body.bounds)
        XCTAssertEqual(first.body.storage.origins, second.body.storage.origins)
        XCTAssertEqual(first.allFrames, second.allFrames)
        XCTAssertEqual(first.body.regions.map(\.action), second.body.regions.map(\.action))
        XCTAssertEqual(startsOnMain.values, [false, false])
        assertFinite(first)
    }

    func testSemanticSpansAndToolbarProduceOneRegionPerAction() async throws {
        let item = try makeItem(text: "Hi @alice #Swift# https://example.com")
        let parsed = FeedTextParser().parse(item.text)
        let layout = try await FeedLayoutEngine().layout(
            identity: contentIdentity(for: item), item: item, parsedBody: parsed, parsedRepost: nil, environment: environment()
        )

        XCTAssertEqual(layout.body.regions.map(\.action), [
            .user("alice"), .topic("Swift"), .url(try XCTUnwrap(URL(string: "https://example.com"))),
        ])
        XCTAssertEqual(layout.toolbar.regions.map(\.action), [.repost, .comment, .like])
        XCTAssertTrue((layout.body.regions + layout.toolbar.regions).allSatisfy { !$0.rects.isEmpty })
        assertFinite(layout)
    }

    func testLongBodyTruncatesAndAddsExpandRegion() async throws {
        let item = try makeItem(text: String(repeating: "👨‍👩‍👧‍👦 中文长句会换行。", count: 30) + " https://hidden.example.com")
        let layout = try await FeedLayoutEngine().layout(
            identity: contentIdentity(for: item), item: item, parsedBody: FeedTextParser().parse(item.text), parsedRepost: nil, environment: environment()
        )

        XCTAssertEqual(layout.body.storage.lines.count, 6)
        XCTAssertEqual(layout.body.regions.last?.action, .expand(item.id))
        XCTAssertFalse(layout.body.regions.last?.rects.isEmpty ?? true)
        XCTAssertFalse(layout.body.regions.contains { $0.action == .url(URL(string: "https://hidden.example.com")!) })
        let expandRect = try XCTUnwrap(layout.body.regions.last?.rects.first)
        XCTAssertTrue(layout.body.bounds.contains(expandRect))
        assertFinite(layout)
    }

    func testForcedNewlineTruncationClipsPartialURLBeforeExactToken() async throws {
        let text = "1\n2\n3\n4\n5\nhttps://example.com/" + String(repeating: "路径", count: 80) + " tail"
        let item = try makeItem(text: text)
        let layout = try await FeedLayoutEngine().layout(identity: contentIdentity(for: item), item: item, parsedBody: FeedTextParser().parse(text), parsedRepost: nil, environment: environment())
        let url = try XCTUnwrap(layout.body.regions.first { if case .url = $0.action { true } else { false } })
        let expand = try XCTUnwrap(layout.body.regions.first { $0.action == .expand(item.id) })
        XCTAssertEqual(layout.body.storage.lines.count, 6)
        XCTAssertEqual(layout.body.storage.lines.count, layout.body.storage.origins.count)
        XCTAssertLessThanOrEqual(try XCTUnwrap(url.rects.last).maxX, try XCTUnwrap(expand.rects.first).minX + 0.001)
    }

    func testRepostHasContainedBodyAndMedia() async throws {
        let item = try makeItem(text: "Original", repostText: "Reposted @bob", repostPictures: 4)
        let repost = try XCTUnwrap(item.repost)
        let layout = try await FeedLayoutEngine().layout(
            identity: contentIdentity(for: item), item: item,
            parsedBody: FeedTextParser().parse(item.text),
            parsedRepost: FeedTextParser().parse(repost.text),
            environment: environment()
        )

        let repostLayout = try XCTUnwrap(layout.repost)
        XCTAssertEqual(repostLayout.mediaFrames.count, 4)
        XCTAssertTrue(repostLayout.frame.contains(repostLayout.body.bounds))
        XCTAssertTrue(repostLayout.mediaFrames.allSatisfy(repostLayout.frame.contains))
        XCTAssertEqual(repostLayout.body.regions.map(\.action), [.user("bob")])
        assertFinite(layout)
    }

    func testMediaGeometryForOneFourAndNinePictures() async throws {
        let engine = FeedLayoutEngine()
        for count in [1, 4, 9] {
            let item = try makeItem(text: "Pictures", pictures: count)
            let layout = try await engine.layout(
                identity: contentIdentity(for: item), item: item, parsedBody: FeedTextParser().parse(item.text), parsedRepost: nil, environment: environment()
            )
            XCTAssertEqual(layout.mediaFrames.count, count)
            let expectedColumns = count == 1 ? 1 : (count == 4 ? 2 : 3)
            XCTAssertEqual(Set(layout.mediaFrames.map(\.minX)).count, expectedColumns)
            XCTAssertEqual(Set(layout.mediaFrames.map(\.minY)).count, count == 1 ? 1 : (count == 4 ? 2 : 3))
            XCTAssertTrue(layout.mediaFrames.allSatisfy { $0.width == $0.height })
            for (index, frame) in layout.mediaFrames.enumerated() {
                XCTAssertEqual(frame.minX, layout.mediaFrames[index % expectedColumns].minX, accuracy: 0.001)
                XCTAssertTrue(layout.mediaFrames.enumerated().allSatisfy { $0.offset == index || !$0.element.intersects(frame) })
            }
            assertFinite(layout)
        }
    }

    func testQueuedLayoutCanBeCancelledBeforeItStarts() async throws {
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let engine = FeedLayoutEngine(layoutStartHook: {
            started.signal()
            gate.wait()
        })
        let item = try makeItem(text: "Queued")
        let firstParsed = FeedTextParser().parse(item.text)
        let secondParsed = FeedTextParser().parse(item.text)
        let cancelledParsed = FeedTextParser().parse(item.text)
        let layoutEnvironment = environment()
        let itemIdentity = contentIdentity(for: item)
        let first = Task { try await engine.layout(identity: itemIdentity, item: item, parsedBody: firstParsed, parsedRepost: nil, environment: layoutEnvironment) }
        let second = Task { try await engine.layout(identity: itemIdentity, item: item, parsedBody: secondParsed, parsedRepost: nil, environment: layoutEnvironment) }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        let cancelled = Task { try await engine.layout(identity: itemIdentity, item: item, parsedBody: cancelledParsed, parsedRepost: nil, environment: layoutEnvironment) }
        cancelled.cancel()
        let cancelledPromptly = expectation(description: "queued cancellation resumes")
        Task {
            do { _ = try await cancelled.value } catch is CancellationError { cancelledPromptly.fulfill() } catch {}
        }
        await fulfillment(of: [cancelledPromptly], timeout: 1)
        gate.signal(); gate.signal()

        _ = try await first.value
        _ = try await second.value
        do {
            _ = try await cancelled.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }

    func testObservedLayoutConcurrencyNeverExceedsTwo() async throws {
        let tracker = ConcurrencyTracker()
        let engine = FeedLayoutEngine(layoutStartHook: { tracker.measureBriefWork() })
        let item = try makeItem(text: "Concurrent")
        let parsed = FeedTextParser().parse(item.text)
        let identity = contentIdentity(for: item)
        let environment = environment()
        try await withThrowingTaskGroup(of: FeedItemLayout.self) { group in
            for _ in 0..<12 {
                group.addTask { try await engine.layout(identity: identity, item: item, parsedBody: parsed, parsedRepost: nil, environment: environment) }
            }
            for try await _ in group {}
        }
        XCTAssertLessThanOrEqual(tracker.maximum, 2)
    }

    func testProfileCardTagAndRepostCardHaveCompleteContainedGeometry() async throws {
        let item = try makeRichItem()
        let repost = try XCTUnwrap(item.repost)
        let identity = contentIdentity(for: item, version: 9)
        let layout = try await FeedLayoutEngine().layout(
            identity: identity,
            item: item,
            parsedBody: FeedTextParser().parse(item.text),
            parsedRepost: FeedTextParser().parse(repost.text),
            environment: environment()
        )

        XCTAssertEqual(layout.identity.content, identity)
        XCTAssertTrue(layout.profile.frame.contains(layout.profile.avatarFrame))
        XCTAssertTrue(layout.profile.frame.contains(layout.profile.name.bounds))
        XCTAssertEqual(layout.profile.regions.map(\.action), [.user("1")])
        XCTAssertNotNil(layout.profile.time)
        XCTAssertNotNil(layout.profile.source)
        XCTAssertNotNil(layout.profile.verificationFrame)
        XCTAssertTrue(layout.profile.regions[0].accessibilityLabel.contains("verified"))
        XCTAssertTrue(layout.profile.accessibilityLabel.contains("iPhone客户端"))
        let card = try XCTUnwrap(layout.card)
        XCTAssertTrue(card.frame.contains(card.text.bounds))
        XCTAssertTrue(card.imageFrame.map(card.frame.contains) ?? false)
        XCTAssertEqual(card.regions.map(\.action), [.url(URL(string: "https://example.com/card")!)])
        let tag = try XCTUnwrap(layout.tag)
        XCTAssertTrue(tag.frame.contains(tag.text.bounds))
        XCTAssertEqual(tag.regions.map(\.action), [.tag("Swift")])
        XCTAssertEqual(tag.regions.first?.accessibilityLabel, "Swift", "Only the first tag is rendered for original-demo parity")
        let repostCard = try XCTUnwrap(layout.repost?.card)
        XCTAssertTrue(try XCTUnwrap(layout.repost).frame.contains(repostCard.frame))
        assertFinite(layout)
    }

    func testLongUnicodeSingleLineLayoutsStayWithinDeclaredWidth() async throws {
        let item = try makeRichItem(longValues: true)
        let layout = try await FeedLayoutEngine().layout(identity: contentIdentity(for: item), item: item, parsedBody: FeedTextParser().parse(item.text), parsedRepost: FeedTextParser().parse(item.repost!.text), environment: environment(width: 240))
        for text in [layout.profile.name, layout.card!.text, layout.tag!.text] {
            XCTAssertEqual(text.storage.lines.count, text.storage.origins.count)
            XCTAssertLessThanOrEqual(CGFloat(CTLineGetTypographicBounds(text.storage.lines[0], nil, nil, nil)), text.bounds.width + 0.001)
        }
    }
    func testLayoutEnvironmentUsesPixelWidthAndStableContentSizeName() {
        let environment = FeedLayoutEnvironment(
            width: 390,
            scale: 3,
            contentSizeCategory: .large,
            themeVersion: 1,
            algorithmVersion: 2
        )

        XCTAssertEqual(environment.containerPixelWidth, 1_170)
        XCTAssertEqual(environment.displayScale, 3)
        XCTAssertEqual(environment.contentSizeCategory, UIContentSizeCategory.large.rawValue)
        XCTAssertEqual(environment.themeVersion, 1)
        XCTAssertEqual(environment.layoutAlgorithmVersion, 2)
    }

    func testEveryEnvironmentComponentParticipatesInLayoutIdentity() {
        let content = FeedContentIdentity(itemID: FeedID(rawValue: "42"), contentVersion: 7)
        let baseline = environment()
        let identities = [
            FeedLayoutIdentity(content: content, environment: baseline),
            FeedLayoutIdentity(content: content, environment: environment(width: 391)),
            FeedLayoutIdentity(content: content, environment: environment(scale: 2)),
            FeedLayoutIdentity(content: content, environment: environment(contentSizeCategory: .extraLarge)),
            FeedLayoutIdentity(content: content, environment: environment(themeVersion: 2)),
            FeedLayoutIdentity(content: content, environment: environment(algorithmVersion: 2)),
        ]

        XCTAssertEqual(Set(identities).count, identities.count)
    }

    func testCacheMissesWhenAnyEnvironmentComponentChanges() {
        let cache = FeedLayoutCache()
        let content = FeedContentIdentity(itemID: FeedID(rawValue: "42"), contentVersion: 7)
        let identity = FeedLayoutIdentity(content: content, environment: environment())
        cache.insert(makeLayout(identity: identity), cost: 64)

        XCTAssertNotNil(cache.value(for: identity))
        XCTAssertNil(cache.value(for: .init(content: content, environment: environment(width: 391))))
        XCTAssertNil(cache.value(for: .init(content: content, environment: environment(scale: 2))))
        XCTAssertNil(cache.value(for: .init(content: content, environment: environment(contentSizeCategory: .extraLarge))))
        XCTAssertNil(cache.value(for: .init(content: content, environment: environment(themeVersion: 2))))
        XCTAssertNil(cache.value(for: .init(content: content, environment: environment(algorithmVersion: 2))))
    }

    func testRemoveAllExceptRetainsOnlyRequestedLayouts() {
        let cache = FeedLayoutCache()
        let first = identity(id: "1")
        let second = identity(id: "2")
        cache.insert(makeLayout(identity: first), cost: 1)
        cache.insert(makeLayout(identity: second), cost: 1)

        cache.removeAllExcept([second])

        XCTAssertNil(cache.value(for: first))
        XCTAssertNotNil(cache.value(for: second))
    }

    func testLayoutPrimitivesRetainFiniteGeometryAndInteractions() {
        let rect = CGRect(x: 12, y: 24, width: 48, height: 20)
        let region = InteractionRegion(rects: [rect], action: .topic("Swift"), accessibilityLabel: "#Swift#")
        let body = TextLayout(
            storage: CoreTextLayoutStorage(lines: [], origins: []),
            bounds: CGRect(x: 0, y: 0, width: 300, height: 80),
            regions: [region]
        )
        let layout = FeedItemLayout(
            identity: identity(id: "finite"),
            height: 160,
            profile: emptyProfile(),
            body: body,
            mediaFrames: [CGRect(x: 12, y: 100, width: 48, height: 48)],
            repost: nil,
            card: nil,
            tag: nil,
            toolbar: ToolbarLayout(frame: CGRect(x: 0, y: 148, width: 300, height: 12), regions: [])
        )

        XCTAssertEqual(layout.body.regions.first?.action, .topic("Swift"))
        XCTAssertEqual(layout.body.regions.first?.rects, [rect])
        XCTAssertTrue(layout.allFrames.allSatisfy(\.isFiniteAndNonNegative))
        XCTAssertTrue(layout.allFrames.allSatisfy { $0.maxY <= layout.height })
    }

    private func environment(
        width: CGFloat = 390,
        scale: CGFloat = 3,
        contentSizeCategory: UIContentSizeCategory = .large,
        themeVersion: UInt = 1,
        algorithmVersion: UInt = 1
    ) -> FeedLayoutEnvironment {
        FeedLayoutEnvironment(
            width: width,
            scale: scale,
            contentSizeCategory: contentSizeCategory,
            themeVersion: themeVersion,
            algorithmVersion: algorithmVersion
        )
    }

    private func identity(id: String) -> FeedLayoutIdentity {
        FeedLayoutIdentity(
            content: FeedContentIdentity(itemID: FeedID(rawValue: id), contentVersion: 1),
            environment: environment()
        )
    }

    private func makeLayout(identity: FeedLayoutIdentity) -> FeedItemLayout {
        FeedItemLayout(
            identity: identity,
            height: 1,
            profile: emptyProfile(),
            body: TextLayout(storage: CoreTextLayoutStorage(lines: [], origins: []), bounds: .zero, regions: []),
            mediaFrames: [],
            repost: nil,
            card: nil,
            tag: nil,
            toolbar: ToolbarLayout(frame: .zero, regions: [])
        )
    }

    private func contentIdentity(for item: FeedItem, version: UInt = 1) -> FeedContentIdentity {
        FeedContentIdentity(itemID: item.id, contentVersion: version)
    }

    private func emptyProfile() -> ProfileLayout {
        let text = TextLayout(storage: CoreTextLayoutStorage(lines: [], origins: []), bounds: .zero, regions: [])
        return ProfileLayout(frame: .zero, avatarFrame: .zero, name: text, time: nil, source: nil, verificationFrame: nil, accessibilityLabel: "", regions: [])
    }

    private func makeItem(text: String, pictures: Int = 0, repostText: String? = nil, repostPictures: Int = 0) throws -> FeedItem {
        func pictureJSON(_ count: Int) -> String {
            (0..<count).map { "{\"pid\":\"p\($0)\",\"url\":\"https://example.com/\($0).jpg\"}" }.joined(separator: ",")
        }
        let repost = repostText.map { repostText in
            ",\"retweeted_status\":{\"id\":\"repost\",\"user\":{\"id\":\"2\",\"name\":\"Bob\"},\"text\":\"\(repostText)\",\"pics\":[\(pictureJSON(repostPictures))]}"
        } ?? ""
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let json = "{\"id\":\"item\",\"user\":{\"id\":\"1\",\"name\":\"Alice\"},\"text\":\"\(escaped)\",\"pics\":[\(pictureJSON(pictures))]\(repost)}"
        return try JSONDecoder.weibo.decode(FeedItem.self, from: Data(json.utf8))
    }

    private func makeRichItem(longValues: Bool = false) throws -> FeedItem {
        let suffix = longValues ? String(repeating: "👩🏽‍💻超长", count: 80) : ""
        let json = "{\"id\":\"item\",\"created_at\":\"Fri Sep 11 20:41:01 +0800 2015\",\"source\":\"<a>iPhone客户端</a>\",\"user\":{\"id\":\"1\",\"name\":\"Alice\(suffix)\",\"verified\":true,\"verified_reason\":\"Author\"},\"text\":\"Body\",\"page_info\":{\"page_title\":\"Main card\(suffix)\",\"page_pic\":\"https://example.com/main.jpg\",\"page_url\":\"https://example.com/card\"},\"tag_struct\":[{\"tag_name\":\"Swift\(suffix)\"},{\"tag_name\":\"Ignored\"}],\"retweeted_status\":{\"id\":\"repost\",\"user\":{\"id\":\"2\",\"name\":\"Bob\"},\"text\":\"Repost\",\"page_info\":{\"page_title\":\"Repost card\",\"page_url\":\"https://example.com/repost\"}}}"
        return try JSONDecoder.weibo.decode(FeedItem.self, from: Data(json.utf8))
    }

    private func assertFinite(_ layout: FeedItemLayout, file: StaticString = #filePath, line: UInt = #line) {
        let interactionRects = layout.body.regions.flatMap(\.rects)
            + (layout.repost?.body.regions.flatMap(\.rects) ?? [])
            + layout.toolbar.regions.flatMap(\.rects)
        let origins = layout.body.storage.origins + (layout.repost?.body.storage.origins ?? [])
        XCTAssertTrue(layout.allFrames.allSatisfy(\.isFiniteAndNonNegative), file: file, line: line)
        XCTAssertTrue(interactionRects.allSatisfy(\.isFiniteAndNonNegative), file: file, line: line)
        XCTAssertTrue(origins.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 }, file: file, line: line)
        XCTAssertTrue(layout.allFrames.allSatisfy { $0.maxY <= layout.height }, file: file, line: line)
        XCTAssertTrue(layout.allFrames.allSatisfy { $0.maxX <= layout.toolbar.frame.width + 0.001 }, file: file, line: line)
        var texts = [layout.profile.name, layout.body]
        if let time = layout.profile.time { texts.append(time) }
        if let source = layout.profile.source { texts.append(source) }
        if let repost = layout.repost { texts.append(repost.body) }
        if let card = layout.card { texts.append(card.text) }
        if let tag = layout.tag { texts.append(tag.text) }
        XCTAssertTrue(texts.allSatisfy { $0.storage.lines.count == $0.storage.origins.count }, file: file, line: line)
    }
}

private final class LockedValues<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = [Element]()

    var values: [Element] { lock.withLock { storage } }
    func append(_ value: Element) { lock.withLock { storage.append(value) } }
}

private final class ConcurrencyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var recordedMaximum = 0
    var maximum: Int { lock.withLock { recordedMaximum } }

    func measureBriefWork() {
        lock.withLock { active += 1; recordedMaximum = max(recordedMaximum, active) }
        Thread.sleep(forTimeInterval: 0.03)
        lock.withLock { active -= 1 }
    }
}
