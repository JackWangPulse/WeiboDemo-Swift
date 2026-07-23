import CoreGraphics
import Foundation

/// Main-thread row metadata deliberately keeps exact table geometry after its
/// heavyweight CoreText layout is evicted. Re-preparation swaps the same content
/// identity back in and never changes `exactHeight` for the current environment.
@MainActor
final class FeedTimelineStore {
    struct Record: Sendable {
        let item: FeedItem
        let identity: FeedContentIdentity
        let expectedLayoutIdentity: FeedLayoutIdentity
        let generation: UInt64
        let exactHeight: CGFloat
        var prepared: PreparedFeedEntry?
    }

    private(set) var records: [Record] = []
    private(set) var generation: UInt64 = 0

    func replace(with entries: [PreparedFeedEntry]) {
        generation &+= 1
        let current = generation
        records = entries.map { Record(item: $0.item, identity: $0.identity, expectedLayoutIdentity: $0.layout.identity, generation: current, exactHeight: $0.layout.height, prepared: $0) }
    }

    var count: Int { records.count }
    func height(at index: Int) -> CGFloat { records[index].exactHeight }
    func prepared(at index: Int) -> PreparedFeedEntry? { records[index].prepared }
    func record(at index: Int) -> Record { records[index] }

    func install(_ entry: PreparedFeedEntry, at index: Int, generation expectedGeneration: UInt64) -> Bool {
        guard generation == expectedGeneration, records.indices.contains(index),
              records[index].generation == expectedGeneration,
              records[index].identity == entry.identity,
              records[index].expectedLayoutIdentity == entry.layout.identity,
              abs(records[index].exactHeight - entry.layout.height) < 0.5 else { return false }
        records[index].prepared = entry
        return true
    }

    func evictDistantLayouts(retaining visible: Set<FeedLayoutIdentity>) {
        for index in records.indices {
            guard let prepared = records[index].prepared,
                  !visible.contains(prepared.layout.identity) else { continue }
            records[index].prepared = nil
        }
    }

    var preparedIndexesForTesting: Set<Int> {
        Set(records.indices.filter { records[$0].prepared != nil })
    }
}
