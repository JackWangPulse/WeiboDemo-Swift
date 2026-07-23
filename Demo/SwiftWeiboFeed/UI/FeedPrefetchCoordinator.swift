import Foundation

enum FeedScrollDirection: Sendable { case forward, backward }
enum FeedPreparationKind: Sendable { case layout, render }
enum FeedPreparationPriority: Int, Comparable, Sendable {
    case visible = 0, forward = 1, tablePrefetch = 2, trailing = 3
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct FeedPreparationJob: Equatable, Sendable {
    let index: Int
    let kind: FeedPreparationKind
    let priority: FeedPreparationPriority
}

struct FeedPrefetchUpdate: Sendable {
    let jobs: [FeedPreparationJob]
    let cancelled: Set<Int>
}

/// Owns the bounded, directional working set. Layout requests are never shed;
/// speculative render/image warming is capped and cancelled on direction changes.
@MainActor
final class FeedPrefetchCoordinator {
    private var itemCount: Int
    private let renderCapacity: Int
    private var activeIndexes: Set<Int> = []
    private var entries: [PreparedFeedEntry] = []
    private let imagePipeline: (any ImagePipeline)?
    private var requestsByIndex: [Int: [ImageRequest]] = [:]

    init(itemCount: Int = 0, renderCapacity: Int = 48, imagePipeline: (any ImagePipeline)? = nil) {
        self.itemCount = max(0, itemCount)
        self.renderCapacity = max(0, renderCapacity)
        self.imagePipeline = imagePipeline
    }

    func setEntries(_ entries: [PreparedFeedEntry]) {
        cancelAllImagePrefetch()
        self.entries = entries
        itemCount = entries.count
        activeIndexes.removeAll()
        requestsByIndex.removeAll()
    }

    @discardableResult
    func update(visible: Range<Int>, requested: Set<Int>, direction: FeedScrollDirection) -> FeedPrefetchUpdate {
        let visible = clamped(visible)
        let visibleCount = max(1, visible.count)
        let forwardCount = visibleCount * 2
        let trailingCount = max(1, visibleCount / 2)
        let forward: Range<Int>
        let trailing: Range<Int>
        switch direction {
        case .forward:
            forward = clamped(visible.upperBound..<(visible.upperBound + forwardCount))
            trailing = clamped((visible.lowerBound - trailingCount)..<visible.lowerBound)
        case .backward:
            forward = clamped((visible.lowerBound - forwardCount)..<visible.lowerBound)
            trailing = clamped(visible.upperBound..<(visible.upperBound + trailingCount))
        }

        let requested = Set(requested.filter { (0..<itemCount).contains($0) })
        let priorities = prioritizedIndexes(visible: visible, forward: forward, requested: requested, trailing: trailing)
        let nextActive = Set(priorities.map(\.index))
        let cancelled = activeIndexes.subtracting(nextActive)
        activeIndexes = nextActive

        // Exact layout demand survives pressure. Render warming consumes only the
        // bounded capacity, with visible rows taking all slots first.
        let layoutIndexes = Set(visible).union(requested)
        let layoutJobs = priorities
            .filter { layoutIndexes.contains($0.index) }
            .map { FeedPreparationJob(index: $0.index, kind: .layout, priority: $0.priority) }
        let effectiveRenderCapacity = max(renderCapacity, visible.count)
        let renderJobs = priorities.prefix(effectiveRenderCapacity).map {
            FeedPreparationJob(index: $0.index, kind: .render, priority: $0.priority)
        }
        synchronizeImagePrefetch(priorities: Array(priorities.prefix(effectiveRenderCapacity)), cancelled: cancelled)
        return FeedPrefetchUpdate(jobs: layoutJobs + renderJobs, cancelled: cancelled)
    }

    func cancel(indexes: Set<Int>) {
        activeIndexes.subtract(indexes)
        cancelImagePrefetch(indexes: indexes)
    }

    private func prioritizedIndexes(
        visible: Range<Int>, forward: Range<Int>, requested: Set<Int>, trailing: Range<Int>
    ) -> [(index: Int, priority: FeedPreparationPriority)] {
        var seen = Set<Int>()
        var result: [(Int, FeedPreparationPriority)] = []
        func append<S: Sequence>(_ indexes: S, priority: FeedPreparationPriority) where S.Element == Int {
            for index in indexes where seen.insert(index).inserted { result.append((index, priority)) }
        }
        append(visible, priority: .visible)
        append(forward, priority: .forward)
        append(requested.sorted(), priority: .tablePrefetch)
        append(trailing, priority: .trailing)
        return result
    }

    private func clamped(_ range: Range<Int>) -> Range<Int> {
        max(0, min(itemCount, range.lowerBound))..<max(0, min(itemCount, range.upperBound))
    }

    private func synchronizeImagePrefetch(
        priorities: [(index: Int, priority: FeedPreparationPriority)], cancelled: Set<Int>
    ) {
        guard let imagePipeline else { return }
        cancelImagePrefetch(indexes: cancelled)
        var fresh: [ImageRequest] = []
        for value in priorities where requestsByIndex[value.index] == nil && value.index < entries.count {
            let requests = Self.imageRequests(for: entries[value.index])
            requestsByIndex[value.index] = requests
            fresh.append(contentsOf: requests)
        }
        guard !fresh.isEmpty else { return }
        Task { await imagePipeline.prefetch(fresh) }
    }

    private func cancelImagePrefetch(indexes: Set<Int>) {
        guard let imagePipeline else { return }
        let requests = indexes.flatMap { requestsByIndex.removeValue(forKey: $0) ?? [] }
        guard !requests.isEmpty else { return }
        Task { await imagePipeline.cancelPrefetch(requests) }
    }

    private func cancelAllImagePrefetch() { cancelImagePrefetch(indexes: Set(requestsByIndex.keys)) }

    private static func imageRequests(for entry: PreparedFeedEntry) -> [ImageRequest] {
        let scale = max(1, entry.layout.identity.environment.displayScale)
        var sources: [(URL?, CGRect)] = [(entry.item.user.avatarURL, entry.layout.profile.avatarFrame)]
        sources += zip(entry.item.pictures.map(\.url), entry.layout.mediaFrames).map { ($0.0, $0.1) }
        if let repost = entry.item.repost, let layout = entry.layout.repost {
            sources += zip(repost.pictures.map(\.url), layout.mediaFrames).map { ($0.0, $0.1) }
            if let frame = layout.card?.imageFrame { sources.append((repost.card?.imageURL, frame)) }
        }
        if let frame = entry.layout.card?.imageFrame { sources.append((entry.item.card?.imageURL, frame)) }
        return sources.compactMap { url, frame in
            url.map {
                ImageRequest(
                    url: $0,
                    targetPixelSize: PixelSize(
                        width: max(1, Int((frame.width * CGFloat(scale)).rounded())),
                        height: max(1, Int((frame.height * CGFloat(scale)).rounded()))
                    ),
                    contentMode: .aspectFill,
                    processorVersion: 1
                )
            }
        }
    }
}
