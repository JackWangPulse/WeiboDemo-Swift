import CoreGraphics
import XCTest
@testable import SwiftWeiboFeed

final class PerformanceSmokeTests: XCTestCase {
    func testSignpostIntervalsBalanceOnSuccessErrorAndCancellation() async {
        let recorder = FeedSignpostRecorder()
        FeedSignpost.testingRecorder = recorder
        defer { FeedSignpost.testingRecorder = nil }

        FeedSignpost.measure(.parse) {}
        XCTAssertThrowsError(try FeedSignpost.measure(.layout) { throw SmokeError.expected })
        let task = Task {
            try await FeedSignpost.measureAsync(.decode) {
                try await Task.sleep(for: .seconds(30))
            }
        }
        task.cancel()
        _ = try? await task.value

        XCTAssertEqual(recorder.begins, [.parse, .layout, .decode])
        XCTAssertEqual(recorder.ends, [.parse, .layout, .decode])
    }

    func testParserAndLayoutEmitTheirActualBalancedStageIntervals() async throws {
        let recorder = FeedSignpostRecorder(); FeedSignpost.testingRecorder = recorder
        defer { FeedSignpost.testingRecorder = nil }
        let item = try JSONDecoder.weibo.decode(FeedItem.self, from: Data(#"{"id":"stage","user":{"id":"u","name":"User"},"text":"@user #topic#"}"#.utf8))
        let parsed = FeedTextParser().parse(item.text)
        let environment = FeedLayoutEnvironment(width: 414, scale: 2, contentSizeCategory: .large, themeVersion: 0, algorithmVersion: 1)
        _ = try await FeedLayoutEngine().layout(identity: FeedContentIdentity(itemID: item.id, contentVersion: 0), item: item, parsedBody: parsed, parsedRepost: nil, environment: environment)
        XCTAssertEqual(recorder.begins, [.parse, .layout])
        XCTAssertEqual(recorder.ends, [.parse, .layout])
    }

    @MainActor
    func testMemoryPressureDegradesInRequiredOrderAndRetainsVisibleLayouts() async {
        let recorder = PressureRecorder()
        let visible = FeedLayoutIdentity(
            content: FeedContentIdentity(itemID: FeedID(rawValue: "visible"), contentVersion: 1),
            environment: FeedLayoutEnvironment(width: 414, scale: 2, contentSizeCategory: .large, themeVersion: 0, algorithmVersion: 1)
        )
        let coordinator = FeedMemoryPressureCoordinator(
            discardNonvisibleBitmaps: { retained in recorder.record(.bitmaps, retained) },
            clearDecodedImages: { recorder.record(.images, []) },
            discardDistantLayouts: { retained in recorder.record(.layouts, retained) },
            cancelLowPriorityPrefetch: { recorder.record(.prefetch, []) }
        )

        await coordinator.triggerForTesting(retaining: [visible])

        XCTAssertEqual(recorder.steps, [.bitmaps, .images, .layouts, .prefetch])
        XCTAssertEqual(recorder.retainedAtBitmapStep, [visible])
        XCTAssertEqual(recorder.retainedAtLayoutStep, [visible])
    }

    @MainActor
    func testCellApplyConsumesPreparedEntryWithoutParserLayoutOrDecodeHooks() async throws {
        let hooks = FeedPerformanceHookRecorder()
        FeedPerformanceHooks.testingObserver = { hooks.record($0) }
        defer { FeedPerformanceHooks.testingObserver = nil }
        let item = try JSONDecoder.weibo.decode(FeedItem.self, from: Data(#"{"id":"smoke","user":{"id":"u","name":"User"},"text":"already prepared"}"#.utf8))
        let identity = FeedContentIdentity(itemID: item.id, contentVersion: 0)
        let environment = FeedLayoutEnvironment(width: 414, scale: 2, contentSizeCategory: .large, themeVersion: 0, algorithmVersion: 1)
        // Preparation happens before installing the observer that guards the main-thread apply path.
        FeedPerformanceHooks.testingObserver = nil
        let parsed = FeedTextParser().parse(item.text)
        let layout = try await FeedLayoutEngine().layout(identity: identity, item: item, parsedBody: parsed, parsedRepost: nil, environment: environment)
        FeedPerformanceHooks.testingObserver = { hooks.record($0) }
        let entry = PreparedFeedEntry(item: item, identity: identity, parsed: parsed, layout: layout)

        FeedCell(style: .default, reuseIdentifier: nil).apply(entry, pipeline: EmptyImagePipeline())

        XCTAssertEqual(hooks.events, [.cellApply])
    }

    func testRepresentativeParserAndLayoutBenchmarks() throws {
        let ordinary = "ordinary timeline text"
        let complex = String(repeating: "@user #topic# https://example.com/path [smile] 中文 ", count: 30)
        var consumed = 0
        measure(metrics: [XCTClockMetric()]) {
            for source in [ordinary, complex] { consumed += FeedTextParser().parse(source).spans.count }
        }
        XCTAssertGreaterThan(consumed, 0)
    }

    func testOrdinaryAndComplexLayoutClockMetric() throws {
        let items = try ["ordinary", String(repeating: "@user #topic# https://example.com long ", count: 40)].enumerated().map { index, text in
            try JSONDecoder.weibo.decode(FeedItem.self, from: Data("{\"id\":\"metric-\(index)\",\"user\":{\"id\":\"u\",\"name\":\"User\"},\"text\":\"\(text)\"}".utf8))
        }
        let environment = FeedLayoutEnvironment(width: 414, scale: 2, contentSizeCategory: .large, themeVersion: 0, algorithmVersion: 1)
        let options = XCTMeasureOptions(); options.iterationCount = 3
        let counter = AtomicCounter()
        measure(metrics: [XCTClockMetric()], options: options) {
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                for item in items {
                    let parsed = FeedTextParser().parse(item.text)
                    if let layout = try? await FeedLayoutEngine().layout(identity: FeedContentIdentity(itemID: item.id, contentVersion: 0), item: item, parsedBody: parsed, parsedRepost: nil, environment: environment) {
                        counter.add(Int(layout.height))
                    }
                }
                semaphore.signal()
            }
            semaphore.wait()
        }
        XCTAssertGreaterThan(counter.value, 0)
    }

    @MainActor
    func testRealTimelineStoreEvictsDistantPreparedLayoutsButRetainsExactGeometryAndVisibleLayout() async throws {
        let entries = try await makeEntries(count: 3)
        let store = FeedTimelineStore(); store.replace(with: entries)
        let cache = FeedLayoutCache(); entries.forEach { cache.insert($0.layout, cost: 1) }
        let visible = Set([entries[1].layout.identity])

        store.evictDistantLayouts(retaining: visible)
        cache.removeAllExcept(visible)

        XCTAssertEqual(store.preparedIndexesForTesting, [1])
        XCTAssertEqual((0..<3).map(store.height), entries.map(\.layout.height))
        XCTAssertNil(cache.value(for: entries[0].layout.identity))
        XCTAssertNotNil(cache.value(for: entries[1].layout.identity))
        XCTAssertNil(cache.value(for: entries[2].layout.identity))
    }

    @MainActor
    func testMemoryPressureCoordinatorMutatesRealCachesStoreAndPrefetchInOrder() async throws {
        let entries = try await makeEntries(count: 3), store = FeedTimelineStore(); store.replace(with: entries)
        let layoutCache = FeedLayoutCache(); entries.forEach { layoutCache.insert($0.layout, cost: 1) }
        let decoded = DecodedImageCache(), pipeline = SystemImagePipeline(decodedCache: decoded)
        let request = ImageRequest(url: URL(string: "https://example.com/cached.png")!, targetPixelSize: PixelSize(width: 1, height: 1), contentMode: .aspectFill, processorVersion: 1)
        decoded.insert(SendableCGImage(value: try XCTUnwrap(Self.markerImage())), for: request)
        let prefetch = FeedPrefetchCoordinator(itemCount: 3, imagePipeline: pipeline, requestProvider: { _ in [] })
        _ = prefetch.update(visible: 0..<1, requested: [2], direction: .forward)
        let visible = Set([entries[0].layout.identity]), order = PressureRecorder()
        let coordinator = FeedMemoryPressureCoordinator(
            discardNonvisibleBitmaps: { retained in order.record(.bitmaps, retained) },
            clearDecodedImages: { await pipeline.clearDecodedCache(); order.record(.images, []) },
            discardDistantLayouts: { retained in store.evictDistantLayouts(retaining: retained); layoutCache.removeAllExcept(retained); order.record(.layouts, retained) },
            cancelLowPriorityPrefetch: { prefetch.shedLowPriorityWork(retaining: [0]); await pipeline.cancelAllPrefetch(); order.record(.prefetch, []) }
        )
        await coordinator.handle(retaining: visible)
        XCTAssertEqual(order.steps, [.bitmaps, .images, .layouts, .prefetch])
        XCTAssertNil(decoded.image(for: request))
        XCTAssertEqual(store.preparedIndexesForTesting, [0])
        XCTAssertNotNil(layoutCache.value(for: entries[0].layout.identity)); XCTAssertNil(layoutCache.value(for: entries[1].layout.identity))
        let prefetchCount = await pipeline.prefetchCountForTesting
        XCTAssertEqual(prefetchCount, 0)
    }

    @MainActor
    func testAllProductionOwnersReleaseDistantCoreTextStorageAfterTransferAndPressure() async throws {
        let repository = FeedRepository()
        let page = try JSONDecoder.weibo.decode(FeedPage.self, from: JSONEncoderForSmoke.page(ids: ["0", "1", "2"]))
        let environment = FeedLayoutEnvironment(width: 414, scale: 2, contentSizeCategory: .large, themeVersion: 0, algorithmVersion: 1)
        _ = try await repository.apply(page: page, environment: environment)
        var entries: [PreparedFeedEntry]? = await repository.transferPreparedEntries()
        weak let distantStorage = entries?[2].layout.body.storage
        let store = FeedTimelineStore(); store.replace(with: try XCTUnwrap(entries))
        let cache = FeedLayoutCache(); entries?.forEach { cache.insert($0.layout, cost: 1) }
        let prefetch = FeedPrefetchCoordinator(imagePipeline: EmptyImagePipeline()); prefetch.setEntries(try XCTUnwrap(entries))
        let visible = Set([try XCTUnwrap(entries?[0].layout.identity)])
        store.evictDistantLayouts(retaining: visible); cache.removeAllExcept(visible); entries = nil
        let repositoryIsEmpty = await repository.snapshot().isEmpty
        XCTAssertTrue(repositoryIsEmpty)
        XCTAssertNil(distantStorage, "repository transfer, timeline store, layout cache and prefetch metadata must release distant CoreText storage")
        XCTAssertEqual(store.preparedIndexesForTesting, [0])
    }

    @MainActor
    func testDirectionalLayoutJobRestoresEvictedTargetBeforeCellApply() async throws {
        let entries = try await makeEntries(count: 6), store = FeedTimelineStore(); store.replace(with: entries)
        store.evictDistantLayouts(retaining: [entries[0].layout.identity])
        let coordinator = FeedPrefetchCoordinator(itemCount: entries.count)
        let update = coordinator.update(visible: 0..<1, requested: [], direction: .forward)
        let target = try XCTUnwrap(update.jobs.first { $0.kind == .layout && $0.index == 1 })
        let record = store.record(at: target.index)
        let restored = try await Task.detached {
            let parsed = FeedTextParser().parse(record.item.text)
            let layout = try await FeedLayoutEngine().layout(identity: record.identity, item: record.item, parsedBody: parsed, parsedRepost: nil, environment: record.expectedLayoutIdentity.environment)
            return PreparedFeedEntry(item: record.item, identity: record.identity, parsed: parsed, layout: layout)
        }.value
        XCTAssertTrue(store.install(restored, at: target.index, generation: record.generation))
        let cell = FeedCell(style: .default, reuseIdentifier: nil)
        cell.apply(try XCTUnwrap(store.prepared(at: target.index)), pipeline: EmptyImagePipeline())
        XCTAssertEqual(cell.representedID, record.item.id)
        XCTAssertFalse(cell.contentNode.isAccessibilityElement, "preprepared row must not enter loading placeholder state")
    }

    @MainActor
    func testBlockedOldEnvironmentInstallIsIgnoredAfterTimelineReplacement() async throws {
        let old = try await makeEntries(count: 1), store = FeedTimelineStore(); store.replace(with: old)
        let oldRecord = store.record(at: 0)
        let replacement = try await makeEntries(count: 2); store.replace(with: replacement)
        XCTAssertFalse(store.install(old[0], at: 0, generation: oldRecord.generation))
        XCTAssertEqual(store.record(at: 0).generation, store.generation)
        XCTAssertEqual(store.prepared(at: 0)?.item.id, replacement[0].item.id)
    }

    func testRepositoryAtomicTransferCannotClearNewerApply() async throws {
        let repository = FeedRepository(), environment = FeedLayoutEnvironment(width: 414, scale: 2, contentSizeCategory: .large, themeVersion: 0, algorithmVersion: 1)
        let oldPage = try JSONDecoder.weibo.decode(FeedPage.self, from: JSONEncoderForSmoke.page(ids: ["old"]))
        _ = try await repository.apply(page: oldPage, environment: environment)
        let old = await repository.transferPreparedEntries()
        let newPage = try JSONDecoder.weibo.decode(FeedPage.self, from: JSONEncoderForSmoke.page(ids: ["new"]))
        _ = try await repository.apply(page: newPage, environment: environment)
        XCTAssertEqual(old.map(\.item.id.rawValue), ["old"])
        let current = await repository.snapshot().map(\.item.id.rawValue)
        XCTAssertEqual(current, ["new"])
    }

    func testFiveHundredMixedItemsPrepareOffMainWithExactCachedHeights() async throws {
        let base = try JSONDecoder.weibo.decode(FeedItem.self, from: Data(#"{"id":"base","user":{"id":"u","name":"User"},"text":"@user #topic# https://example.com","pics":[]}"#.utf8))
        let data = try JSONEncoderForSmoke.makePage(from: base, count: 500)
        let page = try JSONDecoder.weibo.decode(FeedPage.self, from: data)
        let repository = FeedRepository()
        let environment = FeedLayoutEnvironment(width: 414, scale: 2, contentSizeCategory: .large, themeVersion: 0, algorithmVersion: 1)
        _ = try await repository.apply(page: page, environment: environment)
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.count, 500)
        XCTAssertTrue(snapshot.allSatisfy { $0.layout.height > 0 && $0.layout.identity.environment == environment })
    }

    @MainActor
    private func makeEntries(count: Int) async throws -> [PreparedFeedEntry] {
        let environment = FeedLayoutEnvironment(width: 414, scale: 2, contentSizeCategory: .large, themeVersion: 0, algorithmVersion: 1)
        var result: [PreparedFeedEntry] = []
        for index in 0..<count {
            let item = try JSONDecoder.weibo.decode(FeedItem.self, from: Data("{\"id\":\"\(index)\",\"user\":{\"id\":\"u\",\"name\":\"User\"},\"text\":\"row \(index)\"}".utf8))
            let identity = FeedContentIdentity(itemID: item.id, contentVersion: 0), parsed = FeedTextParser().parse(item.text)
            let layout = try await FeedLayoutEngine().layout(identity: identity, item: item, parsedBody: parsed, parsedRepost: nil, environment: environment)
            result.append(PreparedFeedEntry(item: item, identity: identity, parsed: parsed, layout: layout))
        }
        return result
    }

    private static func markerImage() -> CGImage? {
        let provider = CGDataProvider(data: Data([0, 0, 0, 255]) as CFData)
        return provider.flatMap { CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: $0, decode: nil, shouldInterpolate: false, intent: .defaultIntent) }
    }
}

private enum JSONEncoderForSmoke {
    static func makePage(from item: FeedItem, count: Int) throws -> Data {
        let statuses: [[String: Any]] = (0..<count).map { index in
            ["id": "smoke-\(index)", "user": ["id": "u", "name": "User"], "text": index.isMultiple(of: 2) ? item.text : String(repeating: "long text ", count: 20)]
        }
        return try JSONSerialization.data(withJSONObject: ["statuses": statuses])
    }
    static func page(ids: [String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["statuses": ids.map { ["id": $0, "user": ["id": "u", "name": "User"], "text": $0] }])
    }
}

private enum SmokeError: Error { case expected }

private final class PressureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var steps: [FeedMemoryPressureStep] = []
    private(set) var retainedAtBitmapStep: Set<FeedLayoutIdentity> = []
    private(set) var retainedAtLayoutStep: Set<FeedLayoutIdentity> = []
    func record(_ step: FeedMemoryPressureStep, _ retained: Set<FeedLayoutIdentity>) {
        lock.withLock {
            steps.append(step)
            if step == .bitmaps { retainedAtBitmapStep = retained }
            if step == .layouts { retainedAtLayoutStep = retained }
        }
    }
}

private final class FeedPerformanceHookRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [FeedPerformanceStage] = []
    var events: [FeedPerformanceStage] { lock.withLock { storage } }
    func record(_ event: FeedPerformanceStage) { lock.withLock { storage.append(event) } }
}

private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock(); private var storage = 0
    var value: Int { lock.withLock { storage } }
    func add(_ value: Int) { lock.withLock { storage += value } }
}

private actor EmptyImagePipeline: ImagePipeline {
    func image(for request: ImageRequest) async throws -> ImageResponse { throw CancellationError() }
    func prefetch(_ requests: [ImageRequest]) async {}
    func cancelPrefetch(_ requests: [ImageRequest]) async {}
}
