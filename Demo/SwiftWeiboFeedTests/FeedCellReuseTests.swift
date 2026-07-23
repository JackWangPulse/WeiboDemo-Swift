import CoreGraphics
import XCTest
@testable import SwiftWeiboFeed

@MainActor
final class FeedCellReuseTests: XCTestCase {
    func testContentViewMapsPreparedFramesAndTopicHit() async throws {
        let entry = try await makeEntry(id: "A", text: "hello #swift#", pictures: 1)
        let view = FeedContentView(frame: CGRect(x: 0, y: 0, width: 320, height: entry.layout.height))
        view.apply(entry)

        XCTAssertEqual(view.profileLayer.frame, entry.layout.profile.frame)
        XCTAssertEqual(view.bodyLayer.frame, entry.layout.body.bounds)
        XCTAssertEqual(view.mediaLayers.map(\.frame), entry.layout.mediaFrames)
        let topic = try XCTUnwrap(entry.layout.body.regions.first { if case .topic = $0.action { true } else { false } })
        XCTAssertEqual(view.action(at: topic.rects[0].center), topic.action)
    }

    func testReuseCancelsImageTaskAndStaleImageCannotOverwriteReplacement() async throws {
        let a = try await makeEntry(id: "A", text: "A", pictures: 1)
        let b = try await makeEntry(id: "B", text: "B", pictures: 1)
        let pipeline = ControllableCellImagePipeline()
        let cell = FeedCell(style: .default, reuseIdentifier: "feed")
        cell.apply(a, pipeline: pipeline)
        let firstGeneration = cell.generation
        await pipeline.waitForRequests(2)

        cell.prepareForReuse()
        cell.apply(b, pipeline: pipeline)
        await pipeline.waitForRequests(4)
        XCTAssertGreaterThan(cell.generation, firstGeneration)
        let cancelledA = await pipeline.wasCancelled(urlContaining: "A")
        XCTAssertTrue(cancelledA)

        await pipeline.complete(urlContaining: "B", color: 0x22)
        await pipeline.complete(urlContaining: "A", color: 0x11)
        await Task.yield()
        XCTAssertEqual(cell.representedID, b.item.id)
        XCTAssertTrue(cell.contentNode.imageLayers.allSatisfy { node in
            guard node.contents != nil else { return false }
            return (node.contents as! CGImage).pixelByte == 0x22
        })
    }

    func testToolbarUsesVirtualAccessibleActions() async throws {
        let entry = try await makeEntry(id: "A", text: "body", pictures: 0)
        let view = FeedContentView()
        view.apply(entry)
        let labels = (view.accessibilityElements ?? []).compactMap { ($0 as? UIAccessibilityElement)?.accessibilityLabel }
        XCTAssertTrue(labels.contains("Repost"))
        XCTAssertTrue(labels.contains("Comment"))
        XCTAssertTrue(labels.contains("Like"))
        XCTAssertFalse(view.subviews.contains { $0 is UIButton })
    }

    private func makeEntry(id: String, text: String, pictures: Int) async throws -> PreparedFeedEntry {
        let pictureJSON = pictures == 0 ? "" : String(repeating: "{\"url\":\"https://example.com/picture-\(id).png\"},", count: pictures).dropLast()
        let json = "{\"id\":\"\(id)\",\"user\":{\"id\":\"u\(id)\",\"name\":\"User \(id)\",\"avatar_large\":\"https://example.com/avatar-\(id).png\",\"verified\":false},\"text\":\"\(text)\",\"pics\":[\(pictureJSON)],\"reposts_count\":1,\"comments_count\":2,\"attitudes_count\":3}"
        let item = try JSONDecoder.weibo.decode(FeedItem.self, from: Data(json.utf8))
        let identity = FeedContentIdentity(itemID: item.id, contentVersion: 0)
        let parsed = FeedTextParser().parse(text)
        let environment = FeedLayoutEnvironment(width: 320, scale: 2, contentSizeCategory: .large, themeVersion: 1, algorithmVersion: 1)
        let layout = try await FeedLayoutEngine().layout(identity: identity, item: item, parsedBody: parsed, parsedRepost: nil, environment: environment)
        return PreparedFeedEntry(item: item, identity: identity, parsed: parsed, layout: layout)
    }
}

private actor ControllableCellImagePipeline: ImagePipeline {
    struct Pending { let request: ImageRequest; let continuation: CheckedContinuation<ImageResponse, Error> }
    private var pending: [Pending] = []
    private var cancelled: [URL] = []

    func image(for request: ImageRequest) async throws -> ImageResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending.append(Pending(request: request, continuation: $0)) }
        } onCancel: { Task { await self.recordCancellation(request.url) } }
    }
    func prefetch(_ requests: [ImageRequest]) async {}
    func cancelPrefetch(_ requests: [ImageRequest]) async {}
    private func recordCancellation(_ url: URL) { cancelled.append(url) }
    func waitForRequests(_ count: Int) async { while pending.count < count { await Task.yield() } }
    func wasCancelled(urlContaining value: String) -> Bool { cancelled.contains { $0.absoluteString.contains(value) } }
    func complete(urlContaining value: String, color: UInt8) {
        let matches = pending.filter { $0.request.url.absoluteString.contains(value) }
        pending.removeAll { $0.request.url.absoluteString.contains(value) }
        for match in matches { match.continuation.resume(returning: ImageResponse(request: match.request, image: makeImage(color))) }
    }
    private func makeImage(_ byte: UInt8) -> CGImage {
        let data = Data([byte, 0, 0, 255])
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}

private extension CGRect { var center: CGPoint { CGPoint(x: midX, y: midY) } }
private extension CGImage { var pixelByte: UInt8? { dataProvider?.data.flatMap { CFDataGetBytePtr($0)?[0] } } }
