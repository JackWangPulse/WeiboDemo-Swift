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
        let source = String(repeating: "ordinary @user #topic# https://example.com/path ", count: 30)
        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<100 { _ = FeedTextParser().parse(source) }
        }
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

private actor EmptyImagePipeline: ImagePipeline {
    func image(for request: ImageRequest) async throws -> ImageResponse { throw CancellationError() }
    func prefetch(_ requests: [ImageRequest]) async {}
    func cancelPrefetch(_ requests: [ImageRequest]) async {}
}

