import Foundation

public final class FeedLayoutCache: @unchecked Sendable {
    private final class Key: NSObject {
        let value: FeedLayoutIdentity

        init(_ value: FeedLayoutIdentity) {
            self.value = value
        }

        override var hash: Int { value.hashValue }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Key else { return false }
            return value == other.value
        }
    }

    private final class Value {
        let layout: FeedItemLayout

        init(_ layout: FeedItemLayout) {
            self.layout = layout
        }
    }

    private let cache = NSCache<Key, Value>()
    private let lock = NSLock()
    private var insertedKeys: Set<FeedLayoutIdentity> = []

    public init(countLimit: Int = 0, totalCostLimit: Int = 0) {
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
    }

    public func value(for key: FeedLayoutIdentity) -> FeedItemLayout? {
        cache.object(forKey: Key(key))?.layout
    }

    public func insert(_ value: FeedItemLayout, cost: Int) {
        lock.lock()
        cache.setObject(Value(value), forKey: Key(value.identity), cost: cost)
        insertedKeys.insert(value.identity)
        lock.unlock()
    }

    public func removeAllExcept(_ keys: Set<FeedLayoutIdentity>) {
        lock.lock()
        let keysToRemove = insertedKeys.subtracting(keys)
        insertedKeys.formIntersection(keys)
        for key in keysToRemove {
            cache.removeObject(forKey: Key(key))
        }
        lock.unlock()
    }
}
