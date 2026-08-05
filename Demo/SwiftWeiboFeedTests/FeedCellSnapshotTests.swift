import CoreGraphics
import ImageIO
import XCTest
@testable import SwiftWeiboFeed

final class FeedCellSnapshotTests: XCTestCase {
    func testPixelComparatorAllowsOnlyOneChannelStepAtAntialiasedEdges() throws {
        let reference = try XCTUnwrap(Self.image(bytes: [255, 255, 255, 255, 10, 20, 30, 255]))
        let acceptable = try XCTUnwrap(Self.image(bytes: [255, 255, 255, 255, 11, 19, 30, 255]))
        let changed = try XCTUnwrap(Self.image(bytes: [255, 255, 255, 255, 14, 20, 30, 255]))
        XCTAssertNil(try SnapshotComparator.compare(reference: reference, candidate: acceptable, name: "antialias"))
        let diff = try XCTUnwrap(SnapshotComparator.compare(reference: reference, candidate: changed, name: "changed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: diff.path))
    }

    @MainActor
    func testAllIPhone11WidthCellSnapshots() async throws {
        for snapshot in FeedSnapshotCase.allCases {
            let candidate = try await render(snapshot)
            let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("SnapshotReferences")
            let referenceURL = sourceDirectory.appendingPathComponent(snapshot.rawValue + ".png")
            if ProcessInfo.processInfo.environment["SWIFT_FEED_RECORD_SNAPSHOTS"] == "1" {
                try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
                try pngData(candidate).write(to: referenceURL, options: .atomic)
                continue
            }
            guard let source = CGImageSourceCreateWithURL(referenceURL as CFURL, nil), let reference = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                XCTFail("Missing real UIKit golden \(referenceURL.path). Run this test on a simulator with SWIFT_FEED_RECORD_SNAPSHOTS=1 and review each PNG before committing.")
                continue
            }
            if let diff = try SnapshotComparator.compare(reference: reference, candidate: candidate, name: snapshot.rawValue) {
                try attachSnapshot(reference, name: "\(snapshot.rawValue)-reference.png")
                try attachSnapshot(candidate, name: "\(snapshot.rawValue)-candidate.png")
                try attachSnapshotData(Data(contentsOf: diff), name: "\(snapshot.rawValue)-diff.png")
                XCTFail("Snapshot changed: \(snapshot.rawValue). Diff: \(diff.path). Tolerance is per RGBA channel <= 1 for every pixel; no changed-pixel percentage is ignored.")
            }
        }
    }

    @MainActor
    private func render(_ snapshot: FeedSnapshotCase) async throws -> CGImage {
        let entry = try await makeEntry(snapshot)
        let cell = FeedCell(style: .default, reuseIdentifier: nil, contentNode: FeedContentView(layerFactory: {
            AsyncRenderLayer(executor: ImmediateSnapshotExecutor(), contextFactory: snapshotBitmap)
        }))
        cell.frame = CGRect(x: 0, y: 0, width: 414, height: entry.layout.height)
        cell.contentView.frame = cell.bounds
        let pipeline = SnapshotImagePipeline(mode: snapshot == .imagePlaceholder ? .pending : snapshot == .imageFailure ? .failure : .success)
        let completionGate = SnapshotCompletionGate()
        cell.imageCompletionForTesting = { _, _ in Task { await completionGate.record() } }
        cell.apply(entry, pipeline: pipeline)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        let expectedImages = cell.contentNode.imageBindings(for: entry, scale: 2).count
        if snapshot == .imagePlaceholder {
            XCTAssertTrue(cell.contentNode.imageLayers.allSatisfy { $0.contents == nil }, "placeholder snapshot must remain explicitly unresolved")
        } else if expectedImages > 0 {
            await completionGate.wait(for: expectedImages)
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
        let image = UIGraphicsImageRenderer(size: cell.bounds.size, format: format).image { context in
            UIColor.white.setFill(); context.fill(cell.bounds); cell.layer.render(in: context.cgContext)
        }
        return try XCTUnwrap(image.cgImage)
    }

    @MainActor
    private func makeEntry(_ snapshot: FeedSnapshotCase) async throws -> PreparedFeedEntry {
        var root: [String: Any] = ["id": snapshot.rawValue, "user": ["id": "u", "name": "Snapshot User"], "text": "Plain deterministic text", "reposts_count": 12, "comments_count": 34, "attitudes_count": 56]
        let picture: [String: Any] = ["url": "https://example.com/image.png"]
        switch snapshot {
        case .longText: root["text"] = String(repeating: "Long deterministic timeline text. ", count: 18)
        case .oneImage, .imagePlaceholder, .imageFailure: root["pics"] = [picture]
        case .fourImages: root["pics"] = Array(repeating: picture, count: 4)
        case .nineImages: root["pics"] = Array(repeating: picture, count: 9)
        case .repostText: root["retweeted_status"] = ["id": "r", "user": ["id": "ru", "name": "Reposter"], "text": "Repost deterministic text"]
        case .repostMedia: root["retweeted_status"] = ["id": "r", "user": ["id": "ru", "name": "Reposter"], "text": "Repost with media", "pics": [picture]]
        case .card: root["page_info"] = ["page_title": "Deterministic Card", "page_url": "https://example.com/card", "page_pic": "https://example.com/card.png"]
        case .placeTag: root["tag_struct"] = [["name": "Cupertino"]]
        case .richSemanticText: root["text"] = "Hello @swift #UIKit# https://example.com/path [smile]"
        case .plainText: break
        }
        let item = try JSONDecoder.weibo.decode(FeedItem.self, from: JSONSerialization.data(withJSONObject: root))
        let identity = FeedContentIdentity(itemID: item.id, contentVersion: 0), parsed = FeedTextParser().parse(item.text)
        let repost = item.repost.map { FeedTextParser().parse($0.text) }
        let environment = FeedLayoutEnvironment(width: 414, scale: 2, contentSizeCategory: .large, themeVersion: 0, algorithmVersion: 1)
        let layout = try await FeedLayoutEngine().layout(identity: identity, item: item, parsedBody: parsed, parsedRepost: repost, environment: environment)
        return PreparedFeedEntry(item: item, identity: identity, parsed: parsed, layout: layout)
    }

    private func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData(); let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)); CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination)); return data as Data
    }

    private func attachSnapshot(_ image: CGImage, name: String) throws {
        try attachSnapshotData(pngData(image), name: name)
    }

    private func attachSnapshotData(_ data: Data, name: String) throws {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static func image(bytes: [UInt8]) -> CGImage? {
        let provider = CGDataProvider(data: Data(bytes) as CFData)
        return provider.flatMap { CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: $0, decode: nil, shouldInterpolate: false, intent: .defaultIntent) }
    }
}

private struct ImmediateSnapshotExecutor: DisplayExecutor { func execute(_ block: @escaping @Sendable () -> Void) { block() } }
private func snapshotBitmap(width: Int, height: Int, opaque: Bool) -> BitmapContext? {
    let alpha: CGImageAlphaInfo = opaque ? .noneSkipFirst : .premultipliedFirst
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: alpha.rawValue) else { return nil }
    return BitmapContext(context: context, makeImage: { context.makeImage() })
}

private actor SnapshotImagePipeline: ImagePipeline {
    enum Mode { case success, pending, failure }
    let mode: Mode
    init(mode: Mode) { self.mode = mode }
    func image(for request: ImageRequest) async throws -> ImageResponse {
        switch mode {
        case .pending: try await Task.sleep(for: .seconds(60)); throw CancellationError()
        case .failure: throw CocoaError(.fileReadCorruptFile)
        case .success:
            let bytes = Data([40, 120, 220, 255]); let provider = CGDataProvider(data: bytes as CFData)!
            let image = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            return ImageResponse(request: request, image: image)
        }
    }
    func prefetch(_ requests: [ImageRequest]) async {}
    func cancelPrefetch(_ requests: [ImageRequest]) async {}
}

private actor SnapshotCompletionGate {
    private var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func record() {
        count += 1
        let ready = waiters.filter { count >= $0.0 }; waiters.removeAll { count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
    func wait(for target: Int) async {
        guard count < target else { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }
}
