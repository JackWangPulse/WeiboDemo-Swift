import CoreGraphics
import Foundation
import QuartzCore

protocol DisplayExecutor: Sendable {
    func execute(_ block: @escaping @Sendable () -> Void)
}

private final class RenderQueueExecutor: DisplayExecutor, @unchecked Sendable {
    static let shared = RenderQueueExecutor()
    private let queue: OperationQueue

    private init() {
        queue = OperationQueue()
        queue.name = "com.ibireme.SwiftWeiboFeed.render"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
    }

    func execute(_ block: @escaping @Sendable () -> Void) {
        queue.addOperation(block)
    }
}

struct BitmapContext: @unchecked Sendable {
    let context: CGContext
    let makeImage: () -> CGImage?
}

private final class WeakLayerBox: @unchecked Sendable {
    weak var value: AsyncRenderLayer?
    init(_ value: AsyncRenderLayer) { self.value = value }
}

typealias BitmapContextFactory = @Sendable (_ width: Int, _ height: Int, _ opaque: Bool) -> BitmapContext?

public final class AsyncRenderLayer: CALayer {
    private static let maximumBitmapBytes = 64 * 1_024 * 1_024
    private static let bytesPerPixel = 4
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [WeakLayerBox] = []

    private struct State {
        var identity: RenderIdentity?
        var token: DisplayCancellationToken?
    }

    private let stateLock = NSLock()
    private var state = State()
    private let executor: any DisplayExecutor
    private let contextFactory: BitmapContextFactory
    private let commitObserver: (@MainActor (RenderIdentity, CGImage) -> Void)?

    public override init() {
        executor = RenderQueueExecutor.shared
        contextFactory = Self.makeBitmapContext
        commitObserver = nil
        super.init()
        Self.register(self)
    }

    override public init(layer: Any) {
        executor = RenderQueueExecutor.shared
        contextFactory = Self.makeBitmapContext
        commitObserver = nil
        super.init(layer: layer)
        Self.register(self)
    }

    required init?(coder: NSCoder) {
        executor = RenderQueueExecutor.shared
        contextFactory = Self.makeBitmapContext
        commitObserver = nil
        super.init(coder: coder)
        Self.register(self)
    }

    init(
        executor: any DisplayExecutor = RenderQueueExecutor.shared,
        contextFactory: @escaping BitmapContextFactory = AsyncRenderLayer.makeBitmapContext,
        commit: (@MainActor (RenderIdentity, CGImage) -> Void)? = nil
    ) {
        self.executor = executor
        self.contextFactory = contextFactory
        commitObserver = commit
        super.init()
        Self.register(self)
    }

    convenience init(_ commit: @escaping @MainActor (RenderIdentity, CGImage) -> Void) {
        self.init(executor: RenderQueueExecutor.shared, contextFactory: Self.makeBitmapContext, commit: commit)
    }

    @MainActor
    public func display(_ task: AsyncDisplayTask) {
        guard task.size.width.isFinite, task.size.height.isFinite, task.scale.isFinite,
              task.size.width > 0, task.size.height > 0, task.scale > 0 else {
            cancelDisplay()
            return
        }

        let token = DisplayCancellationToken()
        let opaque = isOpaque
        stateLock.withLock {
            state.token?.cancel()
            state = State(identity: task.identity, token: token)
        }
        let factory = contextFactory
        let layerBox = WeakLayerBox(self)
        executor.execute {
            let interval = FeedSignpost.begin(.display)
            defer { interval.end() }
            guard !token.isCancelled else { return }
            guard let (width, height) = Self.pixelDimensions(size: task.size, scale: task.scale),
                  !token.isCancelled,
                  let bitmap = factory(width, height, opaque) else { return }
            bitmap.context.scaleBy(x: task.scale, y: task.scale)
            guard !token.isCancelled else { return }
            task.draw(bitmap.context, token)
            // Drawing closures use the token between their semantic groups; the layer
            // checks again at the boundary before materializing the immutable bitmap.
            guard !token.isCancelled, let image = bitmap.makeImage(), !token.isCancelled else { return }
            DispatchQueue.main.async {
                guard let self = layerBox.value, !token.isCancelled, self.isCurrent(task.identity, token: token) else { return }
                if let commitObserver = self.commitObserver {
                    commitObserver(task.identity, image)
                } else {
                    self.contentsScale = task.scale
                    self.contents = image
                }
            }
        }
    }

    @MainActor
    public func cancelDisplay() {
        stateLock.withLock {
            state.token?.cancel()
            state = State()
        }
    }

    private func isCurrent(_ identity: RenderIdentity, token: DisplayCancellationToken) -> Bool {
        stateLock.withLock { state.identity == identity && state.token === token }
    }

    @MainActor
    static func discardNonvisibleBitmaps(retaining layouts: Set<FeedLayoutIdentity>) {
        let layers = registryLock.withLock { () -> [AsyncRenderLayer] in
            registry.removeAll { $0.value == nil }
            return registry.compactMap(\.value)
        }
        for layer in layers {
            let identity = layer.stateLock.withLock { layer.state.identity }
            guard let identity, !layouts.contains(identity.layout) else { continue }
            layer.cancelDisplay()
            layer.contents = nil
        }
    }

    private static func register(_ layer: AsyncRenderLayer) {
        registryLock.withLock { registry.append(WeakLayerBox(layer)) }
    }

    private static func pixelDimensions(size: CGSize, scale: CGFloat) -> (Int, Int)? {
        let scaledWidth = (size.width * scale).rounded()
        let scaledHeight = (size.height * scale).rounded()
        let intUpperBound = CGFloat(Int.max)
        guard scaledWidth.isFinite, scaledHeight.isFinite,
              scaledWidth > 0, scaledHeight > 0,
              scaledWidth < intUpperBound, scaledHeight < intUpperBound else { return nil }

        let maximumPixels = maximumBitmapBytes / bytesPerPixel
        guard scaledWidth <= CGFloat(maximumPixels), scaledHeight <= CGFloat(maximumPixels) else { return nil }
        let width = Int(scaledWidth)
        let height = Int(scaledHeight)
        guard width <= maximumPixels / height else { return nil }
        return (width, height)
    }

    private static func makeBitmapContext(width: Int, height: Int, opaque: Bool) -> BitmapContext? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipFirst : .premultipliedFirst
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: alpha.rawValue
        ) else { return nil }
        return BitmapContext(context: context, makeImage: { context.makeImage() })
    }
}

extension AsyncRenderLayer: @unchecked Sendable {}
