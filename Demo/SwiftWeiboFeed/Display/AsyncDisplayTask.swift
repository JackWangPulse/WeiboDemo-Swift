import CoreGraphics
import Foundation

public final class DisplayCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.withLock { cancelled = true }
    }

    public var isCancelled: Bool {
        lock.withLock { cancelled }
    }
}

public struct AsyncDisplayTask: @unchecked Sendable {
    public let identity: RenderIdentity
    public let size: CGSize
    public let scale: CGFloat
    public let draw: (CGContext, DisplayCancellationToken) -> Void

    public init(identity: RenderIdentity, size: CGSize, scale: CGFloat, draw: @escaping (CGContext, DisplayCancellationToken) -> Void) {
        self.identity = identity
        self.size = size
        self.scale = scale
        self.draw = draw
    }
}
