import CoreGraphics
import Foundation

struct SendableCGImage: @unchecked Sendable {
    let value: CGImage
}

final class DecodedImageCache: @unchecked Sendable {
    private final class Key: NSObject {
        let request: ImageRequest
        init(_ request: ImageRequest) { self.request = request }
        override var hash: Int { request.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? Key)?.request == request }
    }

    private final class Value: NSObject {
        let image: SendableCGImage
        init(_ image: SendableCGImage) { self.image = image }
    }

    private let storage = NSCache<Key, Value>()

    init(totalCostLimit: Int = 64 * 1_024 * 1_024) {
        storage.totalCostLimit = max(0, totalCostLimit)
    }

    func image(for request: ImageRequest) -> SendableCGImage? {
        storage.object(forKey: Key(request))?.image
    }

    func insert(_ image: SendableCGImage, for request: ImageRequest) {
        guard image.value.height > 0,
              image.value.bytesPerRow <= Int.max / image.value.height else { return }
        storage.setObject(Value(image), forKey: Key(request), cost: image.value.bytesPerRow * image.value.height)
    }

    func removeImage(for request: ImageRequest) {
        storage.removeObject(forKey: Key(request))
    }

    func removeAll() { storage.removeAllObjects() }
}
