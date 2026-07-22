import CoreGraphics
import XCTest
@testable import SwiftWeiboFeed

final class AsyncRenderLayerTests: XCTestCase {
    @MainActor
    func testOlderBlockedRenderCannotOverwriteNewGeneration() async throws {
        let aStarted = DispatchSemaphore(value: 0)
        let releaseA = DispatchSemaphore(value: 0)
        defer { releaseA.signal() }
        let bCommitted = expectation(description: "B commits while A is blocked")
        var commits: [(RenderIdentity, Bool)] = []
        let layer = AsyncRenderLayer { identity, _ in
            commits.append((identity, Thread.isMainThread))
            if identity.generation == 2 { bCommitted.fulfill() }
        }
        let a = identity(generation: 1)
        let b = identity(generation: 2)
        let blockedA = AsyncDisplayTask(identity: a, size: CGSize(width: 4, height: 4), scale: 2) { _, _ in
            aStarted.signal()
            _ = releaseA.wait(timeout: .now() + 2)
        }

        layer.display(blockedA)
        XCTAssertEqual(aStarted.wait(timeout: .now() + 1), .success, "A must enter drawing before B is displayed")
        layer.display(task(identity: b, color: 0x22))
        await fulfillment(of: [bCommitted], timeout: 1)
        releaseA.signal()
        await drainMainActor()

        XCTAssertEqual(commits.map(\.0), [b])
        XCTAssertEqual(commits.map(\.1), [true])
    }

    @MainActor
    func testCancellationBeforeExecutionSkipsAllocationAndCommit() async {
        let executor = ControllableDisplayExecutor()
        let factory = ContextFactorySpy()
        var commits = 0
        let layer = AsyncRenderLayer(executor: executor, contextFactory: factory.make) { _, _ in commits += 1 }

        layer.display(task(identity: identity(generation: 1), color: 1))
        layer.cancelDisplay()
        executor.run(at: 0)
        await drainMainActor()

        XCTAssertEqual(factory.allocations.count, 0)
        XCTAssertEqual(commits, 0)
    }

    @MainActor
    func testZeroSizeAndInvalidScaleAreRejectedWithoutAllocation() async {
        let executor = ControllableDisplayExecutor()
        let factory = ContextFactorySpy()
        let layer = AsyncRenderLayer(executor: executor, contextFactory: factory.make) { _, _ in XCTFail("invalid task committed") }

        for task in [
            AsyncDisplayTask(identity: identity(generation: 1), size: .zero, scale: 2) { _, _ in },
            AsyncDisplayTask(identity: identity(generation: 2), size: CGSize(width: 2, height: 2), scale: 0) { _, _ in },
        ] {
            layer.display(task)
            XCTAssertEqual(executor.count, 0, "invalid work must not be enqueued")
        }
        XCTAssertTrue(factory.allocations.isEmpty)
    }

    @MainActor
    func testScaledDimensionOverflowAndUnsafeBitmapSizesNeverAllocateOrCommit() async {
        let executor = ControllableDisplayExecutor()
        let factory = ContextFactorySpy()
        var commits = 0
        let layer = AsyncRenderLayer(executor: executor, contextFactory: factory.make) { _, _ in commits += 1 }
        let overIntMax = CGFloat(Int.max) * 2
        let tasks = [
            AsyncDisplayTask(identity: identity(generation: 1), size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 1), scale: 2) { _, _ in },
            AsyncDisplayTask(identity: identity(generation: 2), size: CGSize(width: overIntMax, height: 1), scale: 1) { _, _ in },
            AsyncDisplayTask(identity: identity(generation: 3), size: CGSize(width: 8_193, height: 2_048), scale: 1) { _, _ in },
        ]

        for (index, task) in tasks.enumerated() {
            layer.display(task)
            XCTAssertEqual(executor.count, index + 1)
            executor.run(at: index)
            await drainMainActor()
        }

        XCTAssertTrue(factory.allocations.isEmpty)
        XCTAssertEqual(commits, 0)
    }

    @MainActor
    func testScaleDeterminesRoundedPixelDimensionsAndAllocationRunsOffMain() async {
        let done = expectation(description: "commit")
        let factory = ContextFactorySpy()
        let layer = AsyncRenderLayer(contextFactory: factory.make) { _, image in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(image.width, 7)
            XCTAssertEqual(image.height, 10)
            done.fulfill()
        }
        layer.isOpaque = true

        layer.display(AsyncDisplayTask(identity: identity(generation: 1), size: CGSize(width: 2.25, height: 3.25), scale: 3) { _, _ in })
        await fulfillment(of: [done], timeout: 2)

        XCTAssertEqual(factory.allocations.map { [$0.width, $0.height] }, [[7, 10]])
        XCTAssertEqual(factory.allocations.map(\.onMain), [false])
        XCTAssertEqual(factory.allocations.map(\.opaque), [true])
        XCTAssertEqual(factory.allocations.map(\.colorSpaceName), [CGColorSpace(name: CGColorSpace.sRGB)?.name])
    }

    @MainActor
    func testCancellationDuringDrawingPreventsImageCreationAndCommit() async {
        let executor = ControllableDisplayExecutor()
        let factory = ContextFactorySpy()
        var imageCreations = 0
        var commits = 0
        factory.imageCreationHook = { imageCreations += 1 }
        let layer = AsyncRenderLayer(executor: executor, contextFactory: factory.make) { _, _ in commits += 1 }
        let render = AsyncDisplayTask(identity: identity(generation: 1), size: CGSize(width: 3, height: 3), scale: 2) { _, token in
            token.cancel()
        }

        layer.display(render)
        executor.run(at: 0)
        await drainMainActor()

        XCTAssertEqual(factory.allocations.count, 1)
        XCTAssertEqual(imageCreations, 0)
        XCTAssertEqual(commits, 0)
    }

    private func identity(generation: UInt) -> RenderIdentity {
        let environment = FeedLayoutEnvironment(width: 100, scale: 2, contentSizeCategory: .large, themeVersion: 1, algorithmVersion: 1)
        return RenderIdentity(
            layout: FeedLayoutIdentity(content: FeedContentIdentity(itemID: FeedID(rawValue: "item"), contentVersion: 1), environment: environment),
            region: .headerBody,
            generation: generation
        )
    }

    private func task(identity: RenderIdentity, color: UInt8) -> AsyncDisplayTask {
        AsyncDisplayTask(identity: identity, size: CGSize(width: 4, height: 4), scale: 2) { context, _ in
            context.setFillColor(red: CGFloat(color) / 255, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    @MainActor
    private func drainMainActor() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

private final class ControllableDisplayExecutor: DisplayExecutor, @unchecked Sendable {
    private var blocks: [@Sendable () -> Void] = []
    private let lock = NSLock()

    var count: Int { lock.withLock { blocks.count } }

    func execute(_ block: @escaping @Sendable () -> Void) {
        lock.withLock { blocks.append(block) }
    }

    func run(at index: Int) {
        let block = lock.withLock { blocks[index] }
        block()
    }
}

private final class ContextFactorySpy: @unchecked Sendable {
    struct Allocation {
        let width: Int
        let height: Int
        let onMain: Bool
        let opaque: Bool
        let colorSpaceName: CFString?
    }

    private let lock = NSLock()
    private(set) var allocations: [Allocation] = []
    var imageCreationHook: (() -> Void)?

    func make(width: Int, height: Int, opaque: Bool) -> BitmapContext? {
        lock.withLock {
            allocations.append(Allocation(width: width, height: height, onMain: Thread.isMainThread, opaque: opaque, colorSpaceName: CGColorSpace(name: CGColorSpace.sRGB)?.name))
        }
        let alphaInfo: CGImageAlphaInfo = opaque ? .noneSkipFirst : .premultipliedFirst
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alphaInfo.rawValue) else { return nil }
        return BitmapContext(context: context, makeImage: { [weak self] in
            self?.imageCreationHook?()
            return context.makeImage()
        })
    }
}
