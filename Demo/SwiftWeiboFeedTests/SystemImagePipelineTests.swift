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

    private func makePipeline(decodeHook: (@Sendable () -> Void)? = nil) -> SystemImagePipeline {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.urlCache = URLCache(memoryCapacity: 4_000_000, diskCapacity: 0)
        configuration.requestCachePolicy = .useProtocolCachePolicy
        return SystemImagePipeline(configuration: configuration, decodeHook: decodeHook)
    }

    private func request(width: Int, height: Int) -> ImageRequest {
        ImageRequest(url: URL(string: "https://fixture.invalid/image.png")!, targetPixelSize: PixelSize(width: width, height: height), contentMode: .aspectFit, processorVersion: 1)
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
            guard let self else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Cache-Control": "max-age=3600", "Content-Type": "image/png"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

private final class LockedObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []
    var values: [Bool] { lock.withLock { storage } }
    func append(_ value: Bool) { lock.withLock { storage.append(value) } }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("Expected error", file: file, line: line) } catch {}
}
