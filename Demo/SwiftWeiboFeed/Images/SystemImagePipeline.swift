import CoreGraphics
import Foundation
import ImageIO

enum SystemImagePipelineError: Error {
    case invalidTargetSize
    case invalidResponse
    case encodedImageTooLarge
    case invalidImage
}

private final class ImageDecoder: @unchecked Sendable {
    private static let maximumDimension = 16_384
    private static let maximumSourcePixels = 100_000_000
    private let queue: OperationQueue
    private let hook: (@Sendable () -> Void)?
    private let enqueuedHook: (@Sendable () -> Void)?

    init(hook: (@Sendable () -> Void)?, enqueuedHook: (@Sendable () -> Void)?) {
        self.hook = hook
        self.enqueuedHook = enqueuedHook
        queue = OperationQueue()
        queue.name = "com.ibireme.SwiftWeiboFeed.image-decode"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
    }

    func decode(_ data: Data, request: ImageRequest) async throws -> SendableCGImage {
        try await FeedSignpost.measureAsync(.decode) {
            let state = DecodeState()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    state.install(continuation)
                    let operation = BlockOperation { [hook] in
                        do {
                            try state.checkCancellation()
                            hook?()
                            try state.checkCancellation()
                            let image = try Self.makeThumbnail(data, request: request, checkCancellation: state.checkCancellation)
                            try state.checkCancellation()
                            state.finish(.success(image))
                        } catch { state.finish(.failure(error)) }
                    }
                    state.install(operation)
                    queue.addOperation(operation)
                    enqueuedHook?()
                }
            } onCancel: {
                state.cancel()
            }
        }
    }

    private static func makeThumbnail(
        _ data: Data,
        request: ImageRequest,
        checkCancellation: () throws -> Void
    ) throws -> SendableCGImage {
        let target = request.targetPixelSize
        guard target.width > 0, target.height > 0,
              target.width <= maximumDimension, target.height <= maximumDimension else {
            throw SystemImagePipelineError.invalidTargetSize
        }
        try checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let sourceHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw SystemImagePipelineError.invalidImage
        }
        let width = sourceWidth.intValue
        let height = sourceHeight.intValue
        guard width > 0, height > 0,
              width <= maximumSourcePixels / height else {
            throw SystemImagePipelineError.encodedImageTooLarge
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapsAxes = (5...8).contains(orientation)
        let displayWidth = swapsAxes ? height : width
        let displayHeight = swapsAxes ? width : height
        let scale: Double
        switch request.contentMode {
        case .aspectFit:
            scale = min(Double(target.width) / Double(displayWidth), Double(target.height) / Double(displayHeight))
        case .aspectFill:
            scale = max(Double(target.width) / Double(displayWidth), Double(target.height) / Double(displayHeight))
        }
        let maximum = max(1, Int(ceil(Double(max(width, height)) * min(scale, 1))))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false,
        ]
        try checkCancellation()
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw SystemImagePipelineError.invalidImage
        }
        return SendableCGImage(value: image)
    }
}

private final class SharedSubscriptionState: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: Set<UUID> = []

    func insert(_ subscriber: UUID) {
        _ = lock.withLock { subscribers.insert(subscriber) }
    }

    @discardableResult
    func cancel(_ subscriber: UUID, cache: DecodedImageCache, request: ImageRequest) -> Bool {
        lock.withLock {
            guard subscribers.remove(subscriber) != nil else { return false }
            if subscribers.isEmpty { cache.removeImage(for: request) }
            return subscribers.isEmpty
        }
    }

    @discardableResult
    func finish(_ subscriber: UUID) -> Bool {
        lock.withLock {
            guard subscribers.remove(subscriber) != nil else { return false }
            return subscribers.isEmpty
        }
    }

    func cacheIfEligible(_ body: () -> Void) {
        lock.withLock {
            guard !subscribers.isEmpty else { return }
            body()
        }
    }

    var isEmpty: Bool { lock.withLock { subscribers.isEmpty } }
    var count: Int { lock.withLock { subscribers.count } }
}

private final class DecodeState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SendableCGImage, Error>?
    private weak var operation: Operation?
    private var completed = false
    private var cancelled = false

    func install(_ continuation: CheckedContinuation<SendableCGImage, Error>) {
        let cancelImmediately = lock.withLock {
            guard !completed else { return true }
            self.continuation = continuation
            return cancelled
        }
        if cancelImmediately { finish(.failure(CancellationError())) }
    }

    func install(_ operation: Operation) {
        let cancelImmediately = lock.withLock {
            self.operation = operation
            return cancelled
        }
        if cancelImmediately { operation.cancel() }
    }

    func cancel() {
        let operation = lock.withLock { () -> Operation? in
            cancelled = true
            return self.operation
        }
        operation?.cancel()
        finish(.failure(CancellationError()))
    }

    func checkCancellation() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }

    func finish(_ result: Result<SendableCGImage, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<SendableCGImage, Error>? in
            guard !completed, let continuation = self.continuation else { return nil }
            completed = true
            self.continuation = nil
            operation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

actor SystemImagePipeline: ImagePipeline {
    private struct InFlight {
        let task: Task<SendableCGImage, Error>
        let subscriptions: SharedSubscriptionState
    }

    private static let maximumEncodedBytes = 80 * 1_024 * 1_024
    private let session: URLSession
    private let encodedCache: URLCache?
    private let cache: DecodedImageCache
    private let decoder: ImageDecoder
    private let cancellationCleanupHook: (@Sendable () -> Void)?
    private var inFlight: [ImageRequest: InFlight] = [:]
    private struct PrefetchEntry {
        let token: UUID
        var task: Task<Void, Never>?
    }
    private var prefetchTasks: [ImageRequest: PrefetchEntry] = [:]

    init(
        configuration: URLSessionConfiguration = .default,
        decodedCache: DecodedImageCache = DecodedImageCache(),
        decodeHook: (@Sendable () -> Void)? = nil,
        decodeEnqueuedHook: (@Sendable () -> Void)? = nil,
        cancellationCleanupHook: (@Sendable () -> Void)? = nil
    ) {
        if configuration.urlCache == nil {
            configuration.urlCache = URLCache(memoryCapacity: 32 * 1_024 * 1_024, diskCapacity: 128 * 1_024 * 1_024)
        }
        configuration.requestCachePolicy = .useProtocolCachePolicy
        session = URLSession(configuration: configuration)
        encodedCache = configuration.urlCache
        cache = decodedCache
        decoder = ImageDecoder(hook: decodeHook, enqueuedHook: decodeEnqueuedHook)
        self.cancellationCleanupHook = cancellationCleanupHook
    }

    func image(for request: ImageRequest) async throws -> ImageResponse {
        try Task.checkCancellation()
        // 解码图片的缓存
        if let cached = cache.image(for: request) {
            return ImageResponse(request: request, image: cached.value)
        }
        let subscriber = UUID()
        let task: Task<SendableCGImage, Error>
        let subscriptions: SharedSubscriptionState
        // 合并相同请求
        if let current = inFlight[request] {
            current.subscriptions.insert(subscriber)
            // 它不会再次下载，只是订阅同一个任务结果。
            task = current.task
            subscriptions = current.subscriptions
        } else {
            let session = session
            let encodedCache = encodedCache
            let decoder = decoder
            let cache = cache
            let state = SharedSubscriptionState()
            state.insert(subscriber)
            subscriptions = state
            task = Task.detached(priority: Task.currentPriority) {
                var urlRequest = URLRequest(url: request.url)
                urlRequest.cachePolicy = .useProtocolCachePolicy
                let data: Data
                let response: URLResponse
                let loadedFromCache: Bool
                if let cached = encodedCache?.cachedResponse(for: urlRequest),
                   let cachedHTTP = cached.response as? HTTPURLResponse,
                   (200..<300).contains(cachedHTTP.statusCode) {
                    data = cached.data
                    response = cached.response
                    loadedFromCache = true
                } else {
                    // URLCache may retain an intermediate 301/302 when a redirected
                    // request is cancelled. Never treat that redirect body as image
                    // bytes; evict it and let URLSession perform the redirect again.
                    encodedCache?.removeCachedResponse(for: urlRequest)
                    (data, response) = try await FeedSignpost.measureAsync(.download) {
                        // 没有缓存、也没有正在执行的相同任务时：下载原图数据
                        try await session.data(for: urlRequest)
                    }
                    loadedFromCache = false
                }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw SystemImagePipelineError.invalidResponse
                }
                guard data.count <= Self.maximumEncodedBytes else { throw SystemImagePipelineError.encodedImageTooLarge }
                if !loadedFromCache {
                    encodedCache?.storeCachedResponse(
                        CachedURLResponse(response: http, data: data, storagePolicy: .allowed),
                        for: urlRequest
                    )
                }
                // 后台缩略解码 异步
                let image = try await decoder.decode(data, request: request)
                try Task.checkCancellation()
                state.cacheIfEligible { cache.insert(image, for: request) }
                try Task.checkCancellation()
                return image
            }
            inFlight[request] = InFlight(task: task, subscriptions: state)
        }

        return try await withTaskCancellationHandler {
            do {
                let image = try await task.value
                try Task.checkCancellation()
                unsubscribe(subscriber, request: request, subscriptions: subscriptions, cancelWhenEmpty: false)
                return ImageResponse(request: request, image: image.value)
            } catch {
                unsubscribe(subscriber, request: request, subscriptions: subscriptions, cancelWhenEmpty: true)
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            // cell 滑走触发
            let isEmpty = subscriptions.cancel(subscriber, cache: self.cache, request: request)
            let cleanupHook = self.cancellationCleanupHook
            Task {
                cleanupHook?()
                await self.cleanupCancelledSubscriber(request: request, subscriptions: subscriptions, cancelTask: isEmpty)
            }
        }
    }

    func prefetch(_ requests: [ImageRequest]) async {
        for request in requests where prefetchTasks[request] == nil {
            let token = UUID()
            prefetchTasks[request] = PrefetchEntry(token: token, task: nil)
            let task = Task { [weak self] in
                _ = try? await self?.image(for: request)
                await self?.prefetchFinished(request, token: token)
            }
            if prefetchTasks[request]?.token == token {
                prefetchTasks[request]?.task = task
            } else {
                task.cancel()
            }
        }
    }

    func cancelPrefetch(_ requests: [ImageRequest]) async {
        for request in requests {
            prefetchTasks.removeValue(forKey: request)?.task?.cancel()
        }
    }

    func clearDecodedCache() {
        cache.removeAll()
    }

    func cancelAllPrefetch() {
        let tasks = prefetchTasks.values.compactMap(\.task)
        prefetchTasks.removeAll()
        tasks.forEach { $0.cancel() }
    }

    private func unsubscribe(
        _ subscriber: UUID,
        request: ImageRequest,
        subscriptions: SharedSubscriptionState,
        cancelWhenEmpty: Bool
    ) {
        let isEmpty = subscriptions.finish(subscriber)
        guard let current = inFlight[request], current.subscriptions === subscriptions else { return }
        if isEmpty {
            inFlight.removeValue(forKey: request)
            if cancelWhenEmpty { current.task.cancel() }
        }
    }

    private func cleanupCancelledSubscriber(
        request: ImageRequest,
        subscriptions: SharedSubscriptionState,
        cancelTask: Bool
    ) {
        guard let current = inFlight[request], current.subscriptions === subscriptions else { return }
        if cancelTask, subscriptions.isEmpty {
            inFlight.removeValue(forKey: request)
            current.task.cancel()
        }
    }

    private func prefetchFinished(_ request: ImageRequest, token: UUID) {
        // 已经没有页面需要它，就避免留下这次低价值结果占据解码缓存。
        guard prefetchTasks[request]?.token == token else { return }
        prefetchTasks.removeValue(forKey: request)
    }

    var prefetchCountForTesting: Int { prefetchTasks.count }
    func activeSubscriberCountForTesting(_ request: ImageRequest) -> Int {
        inFlight[request]?.subscriptions.count ?? 0
    }
}
