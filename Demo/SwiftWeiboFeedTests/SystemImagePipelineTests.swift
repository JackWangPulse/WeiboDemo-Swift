import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import SwiftWeiboFeed

final class SystemImagePipelineTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    func testIdenticalConcurrentRequestsShareOneProtocolLoad() async throws {
        StubURLProtocol.responseData = Self.png(width: 800, height: 400)
        StubURLProtocol.gate = DispatchSemaphore(value: 0)
        let pipeline = makePipeline()
        let request = request(width: 200, height: 200)
        async let first = pipeline.image(for: request)
        async let second = pipeline.image(for: request)
        try await Task.sleep(for: .milliseconds(100))
        StubURLProtocol.gate?.signal()
        _ = try await (first, second)
        XCTAssertEqual(StubURLProtocol.loadCount, 1)
    }

    func testDifferentTargetSizesHaveDistinctDecodedCacheKeys() async throws {
        StubURLProtocol.responseData = Self.png(width: 800, height: 400)
        let pipeline = makePipeline()
        let small = try await pipeline.image(for: request(width: 100, height: 100))
        let large = try await pipeline.image(for: request(width: 300, height: 300))
        XCTAssertLessThan(small.image.width, large.image.width)
        XCTAssertEqual(StubURLProtocol.loadCount, 1, "URLCache should reuse encoded bytes")
    }

    func testCancellingOneWaiterDoesNotCancelAnother() async throws {
        StubURLProtocol.responseData = Self.png(width: 800, height: 400)
        StubURLProtocol.gate = DispatchSemaphore(value: 0)
        let pipeline = makePipeline()
        let request = request(width: 200, height: 200)
        let cancelled = Task { try await pipeline.image(for: request) }
        let survivor = Task { try await pipeline.image(for: request) }
        try await Task.sleep(for: .milliseconds(100))
        cancelled.cancel()
        StubURLProtocol.gate?.signal()
        await XCTAssertThrowsErrorAsync { try await cancelled.value }
        let survivingResponse = try await survivor.value
        XCTAssertEqual(survivingResponse.image.width, 200)
        XCTAssertEqual(StubURLProtocol.loadCount, 1)
    }

    func testDownsamplesLargeImageAndDecodeNeverRunsOnMainThread() async throws {
        StubURLProtocol.responseData = Self.png(width: 4_000, height: 2_000)
        let observations = LockedObservations()
        let pipeline = makePipeline(decodeHook: { observations.append(Thread.isMainThread) })
        let response = try await pipeline.image(for: request(width: 300, height: 300))
        XCTAssertLessThanOrEqual(response.image.width, 300)
        XCTAssertLessThanOrEqual(response.image.height, 300)
        XCTAssertEqual(observations.values, [false])
    }

    func testAppliesEncodedOrientationDuringThumbnailDecode() async throws {
        StubURLProtocol.responseData = Self.png(width: 80, height: 40, properties: [kCGImagePropertyOrientation: 6])
        let response = try await makePipeline().image(for: request(width: 100, height: 100))
        XCTAssertEqual(response.image.width, 40)
        XCTAssertEqual(response.image.height, 80)
    }

    func testOrientedAspectFitUsesDisplayAxesForNonSquareTarget() async throws {
        StubURLProtocol.responseData = Self.png(width: 400, height: 200, properties: [kCGImagePropertyOrientation: 6])
        let response = try await makePipeline().image(for: request(width: 60, height: 180))
        XCTAssertLessThanOrEqual(response.image.width, 60)
        XCTAssertLessThanOrEqual(response.image.height, 180)
        XCTAssertEqual(response.image.width * 2, response.image.height)
    }

    func testOrientedAspectFillUsesDisplayAxes() async throws {
        StubURLProtocol.responseData = Self.png(width: 400, height: 200, properties: [kCGImagePropertyOrientation: 6])
        let response = try await makePipeline().image(for: request(width: 120, height: 120, mode: .aspectFill))
        XCTAssertGreaterThanOrEqual(response.image.width, 120)
        XCTAssertGreaterThanOrEqual(response.image.height, 120)
        XCTAssertEqual(response.image.width * 2, response.image.height)
    }

    func testCancelQueuedDecodeReturnsCancellationWithoutEnteringDecode() async throws {
        StubURLProtocol.responseData = Self.png(width: 800, height: 400)
        let controls = DecodeControls(blockFirst: 2)
        let pipeline = makePipeline(decodeHook: controls.hook)
        let firstRequest = request(width: 201, height: 201, path: "1")
        let secondRequest = request(width: 202, height: 202, path: "2")
        let queuedRequest = request(width: 203, height: 203, path: "3")
        let first = Task { try await pipeline.image(for: firstRequest) }
        let second = Task { try await pipeline.image(for: secondRequest) }
        XCTAssertTrue(controls.waitForEntries(2))
        let queued = Task { try await pipeline.image(for: queuedRequest) }
        try await Task.sleep(for: .milliseconds(50))
        queued.cancel()
        await XCTAssertCancellationError { try await queued.value }
        XCTAssertEqual(controls.entryCount, 2)
        controls.releaseAll()
        _ = try await (first.value, second.value)
    }

    func testCancelDuringControlledDecodeReturnsCancellationAndIsNotCached() async throws {
        StubURLProtocol.responseData = Self.png(width: 800, height: 400)
        let controls = DecodeControls(blockFirst: 1)
        let pipeline = makePipeline(decodeHook: controls.hook)
        let imageRequest = request(width: 204, height: 204, path: "during")
        let task = Task { try await pipeline.image(for: imageRequest) }
        XCTAssertTrue(controls.waitForEntries(1))
        task.cancel()
        controls.releaseAll()
        await XCTAssertCancellationError { try await task.value }
        _ = try await pipeline.image(for: imageRequest)
        XCTAssertEqual(controls.entryCount, 2, "cancelled decode must not populate decoded cache")
    }

    func testCancelAndReprefetchKeepsReplacementOwnership() async throws {
        StubURLProtocol.responseData = Self.png(width: 800, height: 400)
        StubURLProtocol.gate = DispatchSemaphore(value: 0)
        let pipeline = makePipeline()
        let imageRequest = request(width: 205, height: 205, path: "prefetch")
        await pipeline.prefetch([imageRequest])
        try await Task.sleep(for: .milliseconds(50))
        await pipeline.cancelPrefetch([imageRequest])
        await pipeline.prefetch([imageRequest])
        let prefetchCount = await pipeline.prefetchCountForTesting
        XCTAssertEqual(prefetchCount, 1)
        StubURLProtocol.gate?.signal()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertLessThanOrEqual(StubURLProtocol.loadCount, 2)
    }

    private func makePipeline(decodeHook: (@Sendable () -> Void)? = nil) -> SystemImagePipeline {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.urlCache = URLCache(memoryCapacity: 4_000_000, diskCapacity: 0)
        configuration.requestCachePolicy = .useProtocolCachePolicy
        return SystemImagePipeline(configuration: configuration, decodeHook: decodeHook)
    }

    private func request(width: Int, height: Int, mode: ImageContentMode = .aspectFit, path: String = "image") -> ImageRequest {
        ImageRequest(url: URL(string: "https://fixture.invalid/\(path).png")!, targetPixelSize: PixelSize(width: width, height: height), contentMode: mode, processorVersion: 1)
    }

    private static func png(width: Int, height: Int, properties: [CFString: Any]? = nil) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary?)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var gate: DispatchSemaphore?
    nonisolated(unsafe) private static var count = 0
    private let stateLock = NSLock()
    private var stopped = false
    static var loadCount: Int { lock.withLock { count } }

    static func reset() { lock.withLock { count = 0; responseData = Data(); gate = nil } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.count += 1 }
        let data = Self.lock.withLock { Self.responseData }
        let gate = Self.lock.withLock { Self.gate }
        DispatchQueue.global().async { [weak self] in
            _ = gate?.wait(timeout: .now() + 2)
            guard let self, !self.stateLock.withLock({ self.stopped }) else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Cache-Control": "max-age=3600", "Content-Type": "image/png"])!
            guard !self.stateLock.withLock({ self.stopped }) else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
            guard !self.stateLock.withLock({ self.stopped }) else { return }
            self.client?.urlProtocol(self, didLoad: data)
            guard !self.stateLock.withLock({ self.stopped }) else { return }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { stateLock.withLock { stopped = true } }
}

private final class LockedObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []
    var values: [Bool] { lock.withLock { storage } }
    func append(_ value: Bool) { lock.withLock { storage.append(value) } }
}

private final class DecodeControls: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let blockFirst: Int
    private var entries = 0
    init(blockFirst: Int) { self.blockFirst = blockFirst }
    lazy var hook: @Sendable () -> Void = { [weak self] in self?.enter() }
    var entryCount: Int { lock.withLock { entries } }
    func waitForEntries(_ count: Int) -> Bool {
        for _ in 0..<count where entered.wait(timeout: .now() + 2) != .success { return false }
        return true
    }
    func releaseAll() { for _ in 0..<blockFirst { release.signal() } }
    private func enter() {
        let index = lock.withLock { entries += 1; return entries }
        entered.signal()
        if index <= blockFirst { _ = release.wait(timeout: .now() + 2) }
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("Expected error", file: file, line: line) } catch {}
}

private func XCTAssertCancellationError<T>(_ expression: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("Expected CancellationError", file: file, line: line) }
    catch is CancellationError {} catch { XCTFail("Expected CancellationError, got \(error)", file: file, line: line) }
}
