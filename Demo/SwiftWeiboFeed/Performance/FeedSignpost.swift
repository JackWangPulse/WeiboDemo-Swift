import CoreGraphics
import Foundation
import ImageIO
import os.signpost

enum FeedPerformanceStage: String, CaseIterable, Sendable {
    case parse = "feed.parse"
    case layout = "feed.layout"
    case display = "feed.display"
    case download = "image.download"
    case decode = "image.decode"
    case cellApply = "cell.apply"
}

final class FeedSignpostRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var beginStorage: [FeedPerformanceStage] = []
    private var endStorage: [FeedPerformanceStage] = []
    var begins: [FeedPerformanceStage] { lock.withLock { beginStorage } }
    var ends: [FeedPerformanceStage] { lock.withLock { endStorage } }
    fileprivate func begin(_ stage: FeedPerformanceStage) { lock.withLock { beginStorage.append(stage) } }
    fileprivate func end(_ stage: FeedPerformanceStage) { lock.withLock { endStorage.append(stage) } }
}

enum FeedPerformanceHooks {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var observerStorage: (@Sendable (FeedPerformanceStage) -> Void)?
    nonisolated(unsafe) static var testingObserver: (@Sendable (FeedPerformanceStage) -> Void)? {
        get { lock.withLock { observerStorage } }
        set { lock.withLock { observerStorage = newValue } }
    }
    static func record(_ stage: FeedPerformanceStage) { testingObserver?(stage) }
}

enum FeedSignpost {
    private static let log = OSLog(subsystem: "com.ibireme.SwiftWeiboFeed", category: .pointsOfInterest)
    private static let recorderLock = NSLock()
    nonisolated(unsafe) private static var recorderStorage: FeedSignpostRecorder?
    nonisolated(unsafe) static var testingRecorder: FeedSignpostRecorder? {
        get { recorderLock.withLock { recorderStorage } }
        set { recorderLock.withLock { recorderStorage = newValue } }
    }

    static func measure<T>(_ stage: FeedPerformanceStage, _ operation: () throws -> T) rethrows -> T {
        let interval = begin(stage)
        defer { interval.end() }
        return try operation()
    }

    static func measureAsync<T>(_ stage: FeedPerformanceStage, _ operation: () async throws -> T) async rethrows -> T {
        let interval = begin(stage)
        defer { interval.end() }
        return try await operation()
    }

    static func begin(_ stage: FeedPerformanceStage) -> FeedSignpostInterval {
        let id = OSSignpostID(log: log)
        switch stage {
        case .parse: os_signpost(.begin, log: log, name: "feed.parse", signpostID: id)
        case .layout: os_signpost(.begin, log: log, name: "feed.layout", signpostID: id)
        case .display: os_signpost(.begin, log: log, name: "feed.display", signpostID: id)
        case .download: os_signpost(.begin, log: log, name: "image.download", signpostID: id)
        case .decode: os_signpost(.begin, log: log, name: "image.decode", signpostID: id)
        case .cellApply: os_signpost(.begin, log: log, name: "cell.apply", signpostID: id)
        }
        testingRecorder?.begin(stage)
        FeedPerformanceHooks.record(stage)
        return FeedSignpostInterval(stage: stage, id: id)
    }

    fileprivate static func end(_ stage: FeedPerformanceStage, id: OSSignpostID) {
        switch stage {
        case .parse: os_signpost(.end, log: log, name: "feed.parse", signpostID: id)
        case .layout: os_signpost(.end, log: log, name: "feed.layout", signpostID: id)
        case .display: os_signpost(.end, log: log, name: "feed.display", signpostID: id)
        case .download: os_signpost(.end, log: log, name: "image.download", signpostID: id)
        case .decode: os_signpost(.end, log: log, name: "image.decode", signpostID: id)
        case .cellApply: os_signpost(.end, log: log, name: "cell.apply", signpostID: id)
        }
        testingRecorder?.end(stage)
    }
}

final class FeedSignpostInterval: @unchecked Sendable {
    private let lock = NSLock()
    private let stage: FeedPerformanceStage
    private let id: OSSignpostID
    private var finished = false
    fileprivate init(stage: FeedPerformanceStage, id: OSSignpostID) { self.stage = stage; self.id = id }
    func end() {
        let shouldEnd = lock.withLock { () -> Bool in
            guard !finished else { return false }
            finished = true
            return true
        }
        if shouldEnd { FeedSignpost.end(stage, id: id) }
    }
    deinit { end() }
}

enum FeedMemoryPressureStep: Sendable { case bitmaps, images, layouts, prefetch }

/// A deliberately linear coordinator: each await is an observable degradation
/// boundary, so a later stage can never race ahead of a more disposable cache.
@MainActor
final class FeedMemoryPressureCoordinator {
    typealias RetainingAction = @MainActor @Sendable (Set<FeedLayoutIdentity>) async -> Void
    typealias Action = @MainActor @Sendable () async -> Void
    private let discardNonvisibleBitmaps: RetainingAction
    private let clearDecodedImages: Action
    private let discardDistantLayouts: RetainingAction
    private let cancelLowPriorityPrefetch: Action

    init(
        discardNonvisibleBitmaps: @escaping RetainingAction,
        clearDecodedImages: @escaping Action,
        discardDistantLayouts: @escaping RetainingAction,
        cancelLowPriorityPrefetch: @escaping Action
    ) {
        self.discardNonvisibleBitmaps = discardNonvisibleBitmaps
        self.clearDecodedImages = clearDecodedImages
        self.discardDistantLayouts = discardDistantLayouts
        self.cancelLowPriorityPrefetch = cancelLowPriorityPrefetch
    }

    func handle(retaining visible: Set<FeedLayoutIdentity>) async {
        await discardNonvisibleBitmaps(visible)
        await clearDecodedImages()
        await discardDistantLayouts(visible)
        await cancelLowPriorityPrefetch()
    }

    func triggerForTesting(retaining visible: Set<FeedLayoutIdentity>) async { await handle(retaining: visible) }
}

enum FeedSnapshotCase: String, CaseIterable, Sendable {
    case plainText = "plain-text", longText = "long-text"
    case oneImage = "one-image", fourImages = "four-images", nineImages = "nine-images"
    case repostText = "repost-text", repostMedia = "repost-media", card, placeTag = "place-tag"
    case richSemanticText = "rich-semantic-text", imagePlaceholder = "image-placeholder", imageFailure = "image-failure"
}

enum SnapshotComparator {
    /// Returns a PNG diff path when any channel differs by more than the documented
    /// one-level antialiasing tolerance. Dimension changes always fail.
    static func compare(reference: CGImage, candidate: CGImage, name: String) throws -> URL? {
        guard reference.width == candidate.width, reference.height == candidate.height else {
            return try writeDiff(reference: reference, candidate: candidate, name: name)
        }
        let referenceBytes = try rgba(reference), candidateBytes = try rgba(candidate)
        guard zip(referenceBytes, candidateBytes).contains(where: { abs(Int($0) - Int($1)) > 1 }) else { return nil }
        return try writeDiff(reference: reference, candidate: candidate, name: name)
    }

    private static func rgba(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.coderInvalidValue) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    private static func writeDiff(reference: CGImage, candidate: CGImage, name: String) throws -> URL {
        let width = max(reference.width, candidate.width), height = max(reference.height, candidate.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        // Non-overlap caused by a dimension change is always visible red.
        for pixel in 0..<(width * height) { bytes[pixel * 4] = 255; bytes[pixel * 4 + 3] = 255 }
        let lhs = try rgba(reference), rhs = try rgba(candidate)
        for y in 0..<min(reference.height, candidate.height) {
            for x in 0..<min(reference.width, candidate.width) {
                let source = (y * reference.width + x) * 4, other = (y * candidate.width + x) * 4, target = (y * width + x) * 4
                let changed = (0..<4).contains { abs(Int(lhs[source + $0]) - Int(rhs[other + $0])) > 1 }
                bytes[target] = changed ? 255 : 0; bytes[target + 1] = 0; bytes[target + 2] = 0; bytes[target + 3] = 255
            }
        }
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let image = context.makeImage() else { throw CocoaError(.coderInvalidValue) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftWeiboFeed-\(name)-diff.png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }
}
