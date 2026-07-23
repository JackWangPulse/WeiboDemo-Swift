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
        _ = coordinator.update(visible: 20..<25, requested: [], direction: .forward)
        let reversal = coordinator.update(visible: 20..<25, requested: [], direction: .backward)
        XCTAssertTrue(reversal.cancelled.contains(34))
        XCTAssertFalse(reversal.cancelled.contains(19))
        XCTAssertTrue(reversal.jobs.contains { $0.index == 15 && $0.priority == .forward })
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
}
