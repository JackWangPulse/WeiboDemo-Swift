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

        XCTAssertEqual(hooks.events.first, .cellApply)
        XCTAssertFalse(
            hooks.events.contains { $0 == .parse || $0 == .layout || $0 == .decode },
            "applying a prepared entry must not parse text, calculate layout, or decode images"
        )
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
        let publication = try await repository.apply(page: page, environment: environment)
        var entries: [PreparedFeedEntry]? = await repository.transferPreparedEntries(matching: publication.token, environment: environment)
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
        let record = store.record(at: target.index), installed = expectation(description: "directional target installed")
        let executor = FeedReprepareExecutor(capacity: 4, concurrency: 2)
        XCTAssertTrue(executor.submit(index: target.index, record: record, priority: target.priority) { index, generation, result in
            guard case let .success(entry) = result else { return }
            XCTAssertTrue(store.install(entry, at: index, generation: generation)); installed.fulfill()
        })
        await fulfillment(of: [installed], timeout: 2)
        let cell = FeedCell(style: .default, reuseIdentifier: nil)
        cell.apply(try XCTUnwrap(store.prepared(at: target.index)), pipeline: EmptyImagePipeline())
        XCTAssertEqual(cell.representedID, record.item.id)
        XCTAssertFalse(cell.contentNode.isAccessibilityElement, "preprepared row must not enter loading placeholder state")
    }

    @MainActor
    func testReprepareDirectionThrashStaysBoundedAndCancelledJobsNeverInstall() async throws {
        let entries = try await makeEntries(count: 8), store = FeedTimelineStore(); store.replace(with: entries)
        store.evictDistantLayouts(retaining: [])
        let gate = ReprepareWorkerGate(), executor = FeedReprepareExecutor(capacity: 4, concurrency: 2, startHook: { record in try await gate.start(record) })
        var installed: [Int] = []
        for index in 0..<8 {
            _ = executor.submit(index: index, record: store.record(at: index), priority: index < 2 ? .forward : .trailing) { index, generation, result in
                guard case let .success(entry) = result, store.install(entry, at: index, generation: generation) else { return }
                installed.append(index)
            }
        }
        await gate.waitUntilStarted(2)
        XCTAssertEqual(executor.occupiedCountForTesting, 4)
        let peak = await gate.peak
        XCTAssertLessThanOrEqual(peak, 2)
        for index in 0..<4 { executor.cancel(index: index) }
        XCTAssertEqual(executor.occupiedCountForTesting, 2, "pending cancellation is immediate, but active cancelled work keeps slots until workers exit")
        XCTAssertEqual(executor.runningCountForTesting, 2)
        XCTAssertEqual(executor.pendingCountForTesting, 0)
        await gate.releaseAll()
        while executor.occupiedCountForTesting != 0 { await Task.yield() }
        XCTAssertTrue(installed.isEmpty)

        let targetInstalled = expectation(description: "new directional target")
        XCTAssertTrue(executor.submit(index: 5, record: store.record(at: 5), priority: .visible) { index, generation, result in
            guard case let .success(entry) = result else { return }
            XCTAssertTrue(store.install(entry, at: index, generation: generation)); targetInstalled.fulfill()
        })
        await fulfillment(of: [targetInstalled], timeout: 2)
        let cell = FeedCell(style: .default, reuseIdentifier: nil); cell.apply(try XCTUnwrap(store.prepared(at: 5)), pipeline: EmptyImagePipeline())
        XCTAssertEqual(cell.representedID, entries[5].item.id)
    }

    @MainActor
    func testRepreparePendingQueuePromotesVisibleAheadOfDistantWork() async throws {
        let entries = try await makeEntries(count: 3), gate = ReprepareWorkerGate()
        let store = FeedTimelineStore(); store.replace(with: entries)
        let executor = FeedReprepareExecutor(capacity: 3, concurrency: 1, startHook: { try await gate.start($0) })
        for (index, priority) in [(0, FeedPreparationPriority.trailing), (1, .trailing), (2, .visible)] {
            XCTAssertTrue(executor.submit(index: index, record: store.record(at: index), priority: priority) { _, _, _ in })
        }
        await gate.waitUntilStarted(1); await gate.releaseAll()
        await gate.waitUntilStarted(3)
        while executor.occupiedCountForTesting != 0 { await Task.yield() }
        let startedIDs = await gate.startedIDs
        XCTAssertEqual(startedIDs, [entries[0].item.id, entries[2].item.id, entries[1].item.id])
    }

    @MainActor
    func testReplacingRunningReprepareEventuallyRunsNewestRecord() async throws {
        let entries = try await makeEntries(count: 1)
        let store = FeedTimelineStore()
        store.replace(with: entries)
        let gate = ReprepareWorkerGate()
        let executor = FeedReprepareExecutor(
            capacity: 1,
            concurrency: 1,
            startHook: { try await gate.start($0) }
        )

        let original = store.record(at: 0)
        XCTAssertTrue(executor.submit(index: 0, record: original, priority: .forward) { _, _, _ in })
        await gate.waitUntilStarted(1)

        _ = store.expand(itemID: original.item.id)
        let expanded = store.record(at: 0)
        let installed = expectation(description: "expanded replacement installed")
        executor.cancel(index: 0)
        XCTAssertTrue(executor.submit(index: 0, record: expanded, priority: .visible) { index, generation, result in
            guard case let .success(entry) = result else { return }
            XCTAssertNil(entry.layout.body.regions.first { $0.action == .expand(entry.item.id) })
            XCTAssertTrue(store.install(entry, at: index, generation: generation))
            installed.fulfill()
        })

        await gate.releaseAll()
        await fulfillment(of: [installed], timeout: 2)
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

    func testOldPublicationTransferIsRejectedAfterNewApplyPublishes() async throws {
        let repository = FeedRepository(), environment = FeedLayoutEnvironment(width: 414, scale: 2, contentSizeCategory: .large, themeVersion: 0, algorithmVersion: 1)
        let oldPage = try JSONDecoder.weibo.decode(FeedPage.self, from: JSONEncoderForSmoke.page(ids: ["old"]))
        let oldPublication = try await repository.apply(page: oldPage, environment: environment)
        let newPage = try JSONDecoder.weibo.decode(FeedPage.self, from: JSONEncoderForSmoke.page(ids: ["new"]))
        let newPublication = try await repository.apply(page: newPage, environment: environment)
        let staleTransfer = await repository.transferPreparedEntries(matching: oldPublication.token, environment: environment)
        XCTAssertNil(staleTransfer)
        let currentTransfer = await repository.transferPreparedEntries(matching: newPublication.token, environment: environment)
        XCTAssertEqual(currentTransfer?.map(\.item.id.rawValue), ["new"])
    }

    func testTransferRetainsAuthoritativeStateAndEnvironmentRelayoutDoesNotReparse() async throws {
        let parseCounter = AtomicCounter()
        let repository = FeedRepository(parsingStartHook: { _ in parseCounter.add(1) })
        let firstEnvironment = FeedLayoutEnvironment(width: 320, scale: 2, contentSizeCategory: .large, themeVersion: 0, algorithmVersion: 1)
        let secondEnvironment = FeedLayoutEnvironment(width: 414, scale: 2, contentSizeCategory: .accessibilityLarge, themeVersion: 1, algorithmVersion: 1)
        let firstPage = try JSONDecoder.weibo.decode(FeedPage.self, from: JSONEncoderForSmoke.page(ids: ["a", "b", "c"]))
        let firstPublication = try await repository.apply(page: firstPage, environment: firstEnvironment)
        let transferred = await repository.transferPreparedEntries(matching: firstPublication.token, environment: firstEnvironment)
        XCTAssertEqual(transferred?.map(\.identity.contentVersion), [0, 0, 0])
        let relayoutPublication = try await repository.apply(page: firstPage, environment: secondEnvironment)
        XCTAssertTrue(relayoutPublication.changes.isEmpty)
        XCTAssertEqual(parseCounter.value, 3, "environment-only refresh must reuse retained parsed semantics")
        let relayout = await repository.snapshot()
        XCTAssertEqual(relayout.map(\.identity.contentVersion), [0, 0, 0])
        XCTAssertTrue(relayout.allSatisfy { $0.layout.identity.environment == secondEnvironment })

        let laterPage = try JSONDecoder.weibo.decode(FeedPage.self, from: JSONEncoderForSmoke.page(ids: ["c", "a"]))
        let later = try await repository.apply(page: laterPage, environment: secondEnvironment)
        XCTAssertEqual(later.changes, [.deleted(FeedID(rawValue: "b"), 1), .moved(FeedID(rawValue: "c"), 2, 0), .moved(FeedID(rawValue: "a"), 0, 1)])
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

private actor ReprepareWorkerGate {
    private var active = 0
    private(set) var peak = 0
    private var started = 0
    private(set) var startedIDs: [FeedID] = []
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func start(_ record: FeedTimelineStore.Record) async throws {
        active += 1; started += 1; startedIDs.append(record.item.id); peak = max(peak, active)
        if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
        active -= 1
        try Task.checkCancellation()
    }
    func waitUntilStarted(_ target: Int) async {
        while started < target { await Task.yield() }
    }
    func releaseAll() {
        released = true; let waiters = releaseWaiters; releaseWaiters.removeAll(); waiters.forEach { $0.resume() }
    }
}
