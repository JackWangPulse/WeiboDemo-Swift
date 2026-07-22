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

    init(hook: (@Sendable () -> Void)?) {
        self.hook = hook
        queue = OperationQueue()
        queue.name = "com.ibireme.SwiftWeiboFeed.image-decode"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
    }

    func decode(_ data: Data, request: ImageRequest) async throws -> SendableCGImage {
        try await withCheckedThrowingContinuation { continuation in
            queue.addOperation { [hook] in
                do {
                    hook?()
                    continuation.resume(returning: try Self.makeThumbnail(data, request: request))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func makeThumbnail(_ data: Data, request: ImageRequest) throws -> SendableCGImage {
        let target = request.targetPixelSize
        guard target.width > 0, target.height > 0,
              target.width <= maximumDimension, target.height <= maximumDimension else {
            throw SystemImagePipelineError.invalidTargetSize
        }
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
        let scale: Double
        switch request.contentMode {
        case .aspectFit:
            scale = min(Double(target.width) / Double(width), Double(target.height) / Double(height))
        case .aspectFill:
            scale = max(Double(target.width) / Double(width), Double(target.height) / Double(height))
        }
        let maximum = max(1, Int(ceil(Double(max(width, height)) * min(scale, 1))))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw SystemImagePipelineError.invalidImage
        }
        return SendableCGImage(value: image)
    }
}

actor SystemImagePipeline: ImagePipeline {
    private struct InFlight {
        let task: Task<SendableCGImage, Error>
        var subscribers: Set<UUID>
    }

    private static let maximumEncodedBytes = 80 * 1_024 * 1_024
    private let session: URLSession
    private let cache: DecodedImageCache
    private let decoder: ImageDecoder
    private var inFlight: [ImageRequest: InFlight] = [:]
    private var prefetchTasks: [ImageRequest: Task<Void, Never>] = [:]

    init(
        configuration: URLSessionConfiguration = .default,
        decodedCache: DecodedImageCache = DecodedImageCache(),
        decodeHook: (@Sendable () -> Void)? = nil
    ) {
        if configuration.urlCache == nil {
            configuration.urlCache = URLCache(memoryCapacity: 32 * 1_024 * 1_024, diskCapacity: 128 * 1_024 * 1_024)
        }
        configuration.requestCachePolicy = .useProtocolCachePolicy
        session = URLSession(configuration: configuration)
        cache = decodedCache
        decoder = ImageDecoder(hook: decodeHook)
    }

    func image(for request: ImageRequest) async throws -> ImageResponse {
        try Task.checkCancellation()
        if let cached = cache.image(for: request) {
            return ImageResponse(request: request, image: cached.value)
        }
        let subscriber = UUID()
        let task: Task<SendableCGImage, Error>
        if var current = inFlight[request] {
            current.subscribers.insert(subscriber)
            inFlight[request] = current
            task = current.task
        } else {
            let session = session
            let decoder = decoder
            let cache = cache
            task = Task.detached(priority: Task.currentPriority) {
                var urlRequest = URLRequest(url: request.url)
                urlRequest.cachePolicy = .useProtocolCachePolicy
                let (data, response) = try await session.data(for: urlRequest)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw SystemImagePipelineError.invalidResponse
                }
                guard data.count <= Self.maximumEncodedBytes else { throw SystemImagePipelineError.encodedImageTooLarge }
                let image = try await decoder.decode(data, request: request)
                cache.insert(image, for: request)
                return image
            }
            inFlight[request] = InFlight(task: task, subscribers: [subscriber])
        }

        return try await withTaskCancellationHandler {
            do {
                let image = try await task.value
                try Task.checkCancellation()
                unsubscribe(subscriber, request: request, cancelWhenEmpty: false)
                return ImageResponse(request: request, image: image.value)
            } catch {
                unsubscribe(subscriber, request: request, cancelWhenEmpty: true)
                throw error
            }
        } onCancel: {
            Task { await self.unsubscribe(subscriber, request: request, cancelWhenEmpty: true) }
        }
    }

    func prefetch(_ requests: [ImageRequest]) async {
        for request in requests where prefetchTasks[request] == nil {
            prefetchTasks[request] = Task { [weak self] in
                _ = try? await self?.image(for: request)
                await self?.prefetchFinished(request)
            }
        }
    }

    func cancelPrefetch(_ requests: [ImageRequest]) async {
        for request in requests {
            prefetchTasks.removeValue(forKey: request)?.cancel()
        }
    }

    private func unsubscribe(_ subscriber: UUID, request: ImageRequest, cancelWhenEmpty: Bool) {
        guard var current = inFlight[request] else { return }
        current.subscribers.remove(subscriber)
        if current.subscribers.isEmpty {
            inFlight.removeValue(forKey: request)
            if cancelWhenEmpty { current.task.cancel() }
        } else {
            inFlight[request] = current
        }
    }

    private func prefetchFinished(_ request: ImageRequest) {
        prefetchTasks.removeValue(forKey: request)
    }
}
