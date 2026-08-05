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
        let cancelledA = pipeline.wasCancelled(urlContaining: "A")
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
        XCTAssertEqual(entry.layout.toolbar.items.map { $0.count.storage.lines.count }, [1, 1, 1])
    }

    func testTouchAndAccessibilityActivationDispatchSameAction() async throws {
        let entry = try await makeEntry(id: "A", text: "hello #swift#", pictures: 0)
        let view = FeedContentView(); view.apply(entry)
        var actions: [FeedAction] = []; view.onAction = { actions.append($0) }
        let topic = try XCTUnwrap(entry.layout.body.regions.first { if case .topic = $0.action { true } else { false } })
        let point = topic.rects[0].center
        view.beginInteraction(at: point); view.endInteraction(at: point)
        let toolbarElement = try XCTUnwrap((view.accessibilityElements as? [FeedAccessibilityElement])?.first { $0.action == .like })
        XCTAssertTrue(toolbarElement.accessibilityActivate())
        XCTAssertEqual(actions, [topic.action, .like])
        XCTAssertEqual(toolbarElement.accessibilityFrameInContainerSpace, entry.layout.toolbar.regions[2].rects[0])
        XCTAssertTrue(toolbarElement.accessibilityTraits.contains(.button))
    }

    func testMediaTapRoutesGalleryAndSelectedIndex() async throws {
        let entry = try await makeEntry(id: "media", text: "body", pictures: 2)
        let view = FeedContentView()
        var actions: [FeedAction] = []
        view.onAction = { actions.append($0) }
        view.apply(entry)

        let secondFrame = try XCTUnwrap(entry.layout.mediaFrames.dropFirst().first)
        let point = secondFrame.center
        view.beginInteraction(at: point)
        view.endInteraction(at: point)

        guard case let .media(urls, index) = try XCTUnwrap(actions.first) else {
            return XCTFail("Expected media action")
        }
        XCTAssertEqual(index, 1)
        XCTAssertEqual(urls.map(\.absoluteString), [
            "https://example.com/picture-media.png",
            "https://example.com/picture-media.png",
        ])
    }

    func testReplacementAndReuseCancelPendingInteraction() async throws {
        let a = try await makeEntry(id: "A", text: "#same#", pictures: 0), b = try await makeEntry(id: "B", text: "#same#", pictures: 0)
        let view = FeedContentView(); var actions: [FeedAction] = []; view.onAction = { actions.append($0) }
        view.apply(a); let point = a.layout.body.regions[0].rects[0].center; view.beginInteraction(at: point)
        view.apply(b); view.endInteraction(at: point); XCTAssertTrue(actions.isEmpty)
        view.beginInteraction(at: point); view.endInteraction(at: point); XCTAssertEqual(actions, [b.layout.body.regions[0].action])
        view.beginInteraction(at: point); view.clear(); view.endInteraction(at: point); XCTAssertEqual(actions.count, 1)
    }

    func testImageRequestsUseExactPixelsAndContentsScale() async throws {
        let entry = try await makeEntry(id: "A", text: "body", pictures: 1)
        let pipeline = ControllableCellImagePipeline(); let cell = FeedCell(style: .default, reuseIdentifier: nil)
        cell.apply(entry, pipeline: pipeline); await pipeline.waitForRequests(2)
        let sizes = await pipeline.requestSizes()
        XCTAssertEqual(sizes, [PixelSize(width: 80, height: 80), PixelSize(width: 296, height: 296)])
        await pipeline.complete(urlContaining: "A", color: 0x33); await Task.yield()
        XCTAssertTrue(cell.contentNode.imageLayers.allSatisfy { $0.contentsScale == 2 })
    }

    func testMismatchedImageResponseRequestIsRejected() async throws {
        let entry = try await makeEntry(id: "A", text: "body", pictures: 0); let pipeline = ControllableCellImagePipeline(); let cell = FeedCell(style: .default, reuseIdentifier: nil)
        cell.apply(entry, pipeline: pipeline); await pipeline.waitForRequests(1)
        await pipeline.completeMismatched(urlContaining: "A")
        await drainMainActor()
        XCTAssertNil(cell.contentNode.imageLayers[0].contents)
    }

    func testEverySemanticBitmapContainsDrawnPixelsWithinItsBounds() async throws {
        let entry = try await makeComplexEntry()
        let executor = CellDisplayExecutor()
        var commits: [RenderRegion: CGImage] = [:]
        let view = FeedContentView(layerFactory: {
            AsyncRenderLayer(executor: executor, contextFactory: makeCellBitmap) { identity, image in commits[identity.region] = image }
        })
        view.apply(entry); view.display(entry: entry, generation: 1, scale: 2)
        executor.runAll(); await drainMainActor()
        for region in [RenderRegion.profile, .body, .repost, .card, .tag, .toolbar] {
            let image = try XCTUnwrap(commits[region], "missing \(region)")
            XCTAssertTrue(image.hasPixelVariation, "\(region) must draw visible pixels inside its bitmap")
        }
        XCTAssertTrue(try XCTUnwrap(commits[.toolbar]).firstBitmapRowHasInk, "toolbar separator must occupy the UIKit top edge")
    }

    func testCellReplacementCancelsBlockedADrawsBeforeBCommits() async throws {
        let a = try await makeEntry(id: "A", text: "A", pictures: 0)
        let b = try await makeEntry(id: "B", text: "B", pictures: 0)
        let executor = CellDisplayExecutor(); var commits: [RenderIdentity] = []
        let view = FeedContentView(layerFactory: { AsyncRenderLayer(executor: executor, contextFactory: makeCellBitmap) { identity, _ in commits.append(identity) } })
        let cell = FeedCell(style: .default, reuseIdentifier: nil, contentNode: view)
        let pipeline = ControllableCellImagePipeline()
        cell.apply(a, pipeline: pipeline)
        let aCount = executor.count
        cell.apply(b, pipeline: pipeline)
        executor.run(from: aCount); executor.run(to: aCount)
        await drainMainActor()
        XCTAssertFalse(commits.isEmpty)
        XCTAssertTrue(commits.allSatisfy { $0.layout.content.itemID == b.item.id && $0.generation == cell.generation })
    }

    func testCardAndRepostBindingsMapFramesAndReplacementRemovesOldLayers() async throws {
        let complex = try await makeComplexEntry(); let simple = try await makeEntry(id: "B", text: "B", pictures: 0)
        let view = FeedContentView(); view.apply(complex)
        let bindings = view.imageBindings(for: complex, scale: 2)
        XCTAssertEqual(bindings.map(\.1), [complex.layout.mediaFrames[0], complex.layout.repost!.mediaFrames[0], complex.layout.repost!.card!.imageFrame!, complex.layout.card!.imageFrame!])
        let oldLayers = view.imageLayers
        let marker = makeMarkerImage(0x77); oldLayers.forEach { $0.contents = marker }
        view.apply(simple)
        XCTAssertTrue(oldLayers.allSatisfy { $0.superlayer == nil && $0.contents == nil })
        XCTAssertEqual(view.imageLayers.count, 1)
        XCTAssertTrue(view.mediaLayers.isEmpty)
    }


    func testRepostBodyHasStaticAccessibilityElementAtPreparedFrame() async throws {
        let entry = try await makeComplexEntry(); let view = FeedContentView(); view.apply(entry)
        let element = try XCTUnwrap((view.accessibilityElements as? [UIAccessibilityElement])?.first { $0.accessibilityLabel == "repost text" })
        XCTAssertEqual(element.accessibilityFrameInContainerSpace, entry.layout.repost?.body.bounds)
        XCTAssertTrue(element.accessibilityTraits.contains(.staticText))
    }

    func testNonBodySemanticTextDrawsIntoTransparentLocalBitmaps() async throws {
        let entry = try await makeComplexEntry(); let token = DisplayCancellationToken()
        let cases: [(TextLayout, CGRect)] = [(entry.layout.profile.name, entry.layout.profile.frame), (entry.layout.repost!.body, entry.layout.repost!.frame), (entry.layout.card!.text, entry.layout.card!.frame), (entry.layout.tag!.text, entry.layout.tag!.frame)]
        for (text, region) in cases {
            let bitmap = try XCTUnwrap(makeCellBitmap(width: Int(region.width * 2), height: Int(region.height * 2), opaque: false)); bitmap.context.scaleBy(x: 2, y: 2)
            FeedContentView.draw(text, in: bitmap.context, region: region, token: token)
            XCTAssertTrue(try XCTUnwrap(bitmap.makeImage()).hasNonzeroAlpha, "text clipped for region \(region)")
        }
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

    private func makeComplexEntry() async throws -> PreparedFeedEntry {
        let json = "{\"id\":\"complex\",\"user\":{\"id\":\"u\",\"name\":\"Profile Name\",\"verified\":false},\"text\":\"body text\",\"pics\":[{\"url\":\"https://example.com/main-picture.png\"}],\"page_info\":{\"page_title\":\"Main Card\",\"page_url\":\"https://example.com/main\",\"page_pic\":\"https://example.com/main-card.png\"},\"tag_struct\":[{\"name\":\"Tag Text\"}],\"retweeted_status\":{\"id\":\"r\",\"user\":{\"id\":\"ru\",\"name\":\"Reposter\",\"verified\":false},\"text\":\"repost text\",\"pics\":[{\"url\":\"https://example.com/repost-picture.png\"}],\"page_info\":{\"page_title\":\"Repost Card\",\"page_url\":\"https://example.com/repost\",\"page_pic\":\"https://example.com/repost-card.png\"}},\"reposts_count\":12,\"comments_count\":34,\"attitudes_count\":56}"
        let item = try JSONDecoder.weibo.decode(FeedItem.self, from: Data(json.utf8)); let identity = FeedContentIdentity(itemID: item.id, contentVersion: 0)
        let parsed = FeedTextParser().parse(item.text); let repostParsed = item.repost.map { FeedTextParser().parse($0.text) }
        let environment = FeedLayoutEnvironment(width: 320, scale: 2, contentSizeCategory: .large, themeVersion: 1, algorithmVersion: 1)
        let layout = try await FeedLayoutEngine().layout(identity: identity, item: item, parsedBody: parsed, parsedRepost: repostParsed, environment: environment)
        return PreparedFeedEntry(item: item, identity: identity, parsed: parsed, parsedRepost: repostParsed, layout: layout)
    }

    private func drainMainActor() async { await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } } }
}

private actor ControllableCellImagePipeline: ImagePipeline {
    struct Pending { let request: ImageRequest; let continuation: CheckedContinuation<ImageResponse, Error> }
    private var pending: [Pending] = []
    nonisolated let cancellations = CellCancellationRecorder()

    func image(for request: ImageRequest) async throws -> ImageResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending.append(Pending(request: request, continuation: $0)) }
        } onCancel: { self.cancellations.record(request.url) }
    }
    func prefetch(_ requests: [ImageRequest]) async {}
    func cancelPrefetch(_ requests: [ImageRequest]) async {}
    func waitForRequests(_ count: Int) async { while pending.count < count { await Task.yield() } }
    nonisolated func wasCancelled(urlContaining value: String) -> Bool { cancellations.contains(value) }
    func requestSizes() -> [PixelSize] { pending.map(\.request.targetPixelSize) }
    func complete(urlContaining value: String, color: UInt8) {
        let matches = pending.filter { $0.request.url.absoluteString.contains(value) }
        pending.removeAll { $0.request.url.absoluteString.contains(value) }
        for match in matches { match.continuation.resume(returning: ImageResponse(request: match.request, image: makeImage(color))) }
    }
    func completeMismatched(urlContaining value: String) {
        let matches = pending.filter { $0.request.url.absoluteString.contains(value) }; pending.removeAll { $0.request.url.absoluteString.contains(value) }
        for match in matches {
            let wrong = ImageRequest(url: URL(string: "https://example.com/wrong.png")!, targetPixelSize: match.request.targetPixelSize, contentMode: match.request.contentMode, processorVersion: match.request.processorVersion)
            match.continuation.resume(returning: ImageResponse(request: wrong, image: makeImage(0x44)))
        }
    }
    private func makeImage(_ byte: UInt8) -> CGImage {
        let data = Data([byte, 0, 0, 255])
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}

private final class CellCancellationRecorder: @unchecked Sendable {
    private let lock = NSLock(); private var urls: [URL] = []
    func record(_ url: URL) { lock.withLock { urls.append(url) } }
    func contains(_ value: String) -> Bool { lock.withLock { urls.contains { $0.absoluteString.contains(value) } } }
}

private extension CGRect { var center: CGPoint { CGPoint(x: midX, y: midY) } }
private extension CGImage { var pixelByte: UInt8? { dataProvider?.data.flatMap { CFDataGetBytePtr($0)?[0] } } }
private extension CGImage {
    var hasPixelVariation: Bool {
        guard let data = dataProvider?.data, let bytes = CFDataGetBytePtr(data), CFDataGetLength(data) > 1 else { return false }
        let first = bytes[0]
        return (1..<CFDataGetLength(data)).contains { bytes[$0] != first }
    }
    var hasNonzeroAlpha: Bool {
        guard let data = dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        return stride(from: 3, to: CFDataGetLength(data), by: 4).contains { bytes[$0] != 0 }
    }
    var firstBitmapRowHasInk: Bool {
        guard let data = dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        return (0..<min(bytesPerRow, CFDataGetLength(data))).contains { bytes[$0] != 0 }
    }
}

private final class CellDisplayExecutor: DisplayExecutor, @unchecked Sendable {
    private var blocks: [@Sendable () -> Void] = []
    var count: Int { blocks.count }
    func execute(_ block: @escaping @Sendable () -> Void) { blocks.append(block) }
    func runAll() { run(from: 0) }
    func run(from index: Int) { for block in blocks.dropFirst(index) { block() } }
    func run(to end: Int) { for block in blocks.prefix(end) { block() } }
}

private func makeCellBitmap(width: Int, height: Int, opaque: Bool) -> BitmapContext? {
    let alpha: CGImageAlphaInfo = opaque ? .noneSkipFirst : .premultipliedFirst
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue) else { return nil }
    return BitmapContext(context: context, makeImage: { context.makeImage() })
}

private func makeMarkerImage(_ byte: UInt8) -> CGImage {
    let data = Data([byte, 0, 0, 255]); let provider = CGDataProvider(data: data as CFData)!
    return CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}
