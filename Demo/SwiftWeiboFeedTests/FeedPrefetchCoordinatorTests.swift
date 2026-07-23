import XCTest
@testable import SwiftWeiboFeed

@MainActor
final class FeedPrefetchCoordinatorTests: XCTestCase {
    func testVisiblePreparationOutranksForwardAndTrailingWork() {
        let coordinator = FeedPrefetchCoordinator(itemCount: 100, renderCapacity: 30)
        let update = coordinator.update(visible: 20..<25, requested: [], direction: .forward)
        let renders = update.jobs.filter { $0.kind == .render }
        XCTAssertEqual(Array(renders.prefix(5).map(\.index)), Array(20..<25))
        XCTAssertTrue(renders.prefix(5).allSatisfy { $0.priority == .visible })
        XCTAssertLessThan(update.jobs.firstIndex(where: { $0.index == 25 })!, update.jobs.firstIndex(where: { $0.index == 19 })!)
        XCTAssertTrue(renders.contains { $0.index == 34 && $0.priority == .forward })
        XCTAssertTrue(renders.contains { $0.index == 18 && $0.priority == .trailing })
        XCTAssertFalse(renders.contains { $0.index == 35 || $0.index == 17 })
    }

    func testReversingDirectionCancelsDistantOldForwardWork() {
        let coordinator = FeedPrefetchCoordinator(itemCount: 100, renderCapacity: 50)
        _ = coordinator.update(visible: 20..<25, requested: [90], direction: .forward)
        let reversal = coordinator.update(visible: 20..<25, requested: [90], direction: .backward)
        XCTAssertTrue(reversal.cancelled.contains(34))
        XCTAssertFalse(reversal.cancelled.contains(19))
        XCTAssertFalse(reversal.cancelled.contains(90))
        XCTAssertTrue(reversal.jobs.contains { $0.index == 15 && $0.priority == .forward })
        XCTAssertTrue(reversal.jobs.contains { $0.index == 90 && $0.priority == .tablePrefetch })
    }

    func testQueuePressureDropsLowPriorityRenderBeforeRequiredLayout() {
        let coordinator = FeedPrefetchCoordinator(itemCount: 100, renderCapacity: 3)
        let update = coordinator.update(visible: 10..<13, requested: Set(13..<25), direction: .forward)
        let layoutIndexes = Set(update.jobs.filter { $0.kind == .layout }.map(\.index))
        let renderJobs = update.jobs.filter { $0.kind == .render }
        XCTAssertTrue(Set(10..<25).isSubset(of: layoutIndexes))
        XCTAssertEqual(renderJobs.count, 3)
        XCTAssertTrue(renderJobs.allSatisfy { $0.priority == .visible })
    }

    func testBundledPagesExpandToFiveHundredStableUniqueItems() async throws {
        let urls = try (0..<8).map { index in
            try XCTUnwrap(Bundle.main.url(forResource: "weibo_\(index)", withExtension: "json"))
        }
        let page = try await Task.detached {
            try FeedViewController.loadDemoPage(resourceURLs: urls, minimumCount: 500)
        }.value
        XCTAssertEqual(page.items.count, 500)
        XCTAssertEqual(Set(page.items.map(\.id)).count, 500)
    }

    func testSharedImageRequestPrefetchesFirstOwnerAndCancelsLastOwner() async {
        let pipeline = PrefetchPipelineSpy()
        let shared = request(99)
        let coordinator = FeedPrefetchCoordinator(
            itemCount: 3,
            renderCapacity: 2,
            imagePipeline: pipeline,
            requestProvider: { _ in [shared] }
        )
        _ = coordinator.update(visible: 0..<1, requested: [], direction: .forward)
        await coordinator.waitForImageOperations()
        _ = coordinator.update(visible: 1..<2, requested: [], direction: .forward)
        await coordinator.waitForImageOperations()
        coordinator.cancel(indexes: [1, 2])
        await coordinator.waitForImageOperations()

        let calls = await pipeline.calls
        XCTAssertEqual(calls, [.prefetch([shared]), .cancel([shared])])
    }

    func testCapacityDropCancelsImageEvenWhenIndexRemainsInFullWindow() async {
        let pipeline = PrefetchPipelineSpy()
        let requests = Dictionary(uniqueKeysWithValues: (0..<5).map { ($0, request($0)) })
        let coordinator = FeedPrefetchCoordinator(
            itemCount: 5,
            renderCapacity: 2,
            imagePipeline: pipeline,
            requestProvider: { [requests] in [requests[$0]!] }
        )
        _ = coordinator.update(visible: 2..<3, requested: [], direction: .forward)
        await coordinator.waitForImageOperations()
        let reversal = coordinator.update(visible: 2..<3, requested: [], direction: .backward)
        await coordinator.waitForImageOperations()

        XCTAssertFalse(reversal.cancelled.contains(3), "index 3 remains in the full trailing layout window")
        let calls = await pipeline.calls
        XCTAssertTrue(calls.contains(.cancel([requests[3]!])))
        XCTAssertTrue(calls.contains(.prefetch([requests[0]!])))
    }

    func testReversalCommandsStayOrderedWhenOldPrefetchIsDelayed() async {
        let pipeline = PrefetchPipelineSpy()
        await pipeline.blockNextPrefetch()
        let requests = Dictionary(uniqueKeysWithValues: (0..<5).map { ($0, request($0)) })
        let coordinator = FeedPrefetchCoordinator(
            itemCount: 5,
            renderCapacity: 2,
            imagePipeline: pipeline,
            requestProvider: { [requests] in [requests[$0]!] }
        )
        _ = coordinator.update(visible: 2..<3, requested: [], direction: .forward)
        await pipeline.waitUntilBlocked()
        _ = coordinator.update(visible: 2..<3, requested: [], direction: .backward)
        await pipeline.releaseBlockedPrefetch()
        await coordinator.waitForImageOperations()

        let calls = await pipeline.calls
        XCTAssertEqual(calls, [
            .prefetch([requests[2]!, requests[3]!]),
            .cancel([requests[3]!]),
            .prefetch([requests[0]!])
        ])
    }

    private func request(_ value: Int) -> ImageRequest {
        ImageRequest(
            url: URL(string: "https://example.com/\(value).png")!,
            targetPixelSize: PixelSize(width: 20, height: 20),
            contentMode: .aspectFill,
            processorVersion: 1
        )
    }
}

private enum PrefetchCall: Equatable {
    case prefetch(Set<ImageRequest>)
    case cancel(Set<ImageRequest>)
}

private actor PrefetchPipelineSpy: ImagePipeline {
    private(set) var calls: [PrefetchCall] = []
    private var shouldBlock = false
    private var isBlocked = false
    private var blockContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func image(for request: ImageRequest) async throws -> ImageResponse { throw CancellationError() }

    func prefetch(_ requests: [ImageRequest]) async {
        calls.append(.prefetch(Set(requests)))
        guard shouldBlock else { return }
        shouldBlock = false
        isBlocked = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { blockContinuation = $0 }
        isBlocked = false
    }

    func cancelPrefetch(_ requests: [ImageRequest]) async { calls.append(.cancel(Set(requests))) }

    func blockNextPrefetch() { shouldBlock = true }

    func waitUntilBlocked() async {
        if isBlocked { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseBlockedPrefetch() {
        blockContinuation?.resume()
        blockContinuation = nil
    }
}
