import Foundation

enum FeedScrollDirection: Sendable { case forward, backward }
enum FeedPreparationKind: Sendable { case layout, render }
enum FeedPreparationPriority: Int, Comparable, Sendable {
    // 0 当前屏幕上的 Cell，最高优先级;   1 滚动方向前方，即将出现;
    // 2 UITableView 系统建议预加载的行; 3 已经滑过去但仍靠近屏幕的行，最低优先级;
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

actor FeedImagePrefetchDriver {
    private let pipeline: any ImagePipeline
    private var owners: [ImageRequest: Set<Int>] = [:]
    private var generation: UInt64 = 0

    init(pipeline: any ImagePipeline) { self.pipeline = pipeline }

    func replaceOwners(generation nextGeneration: UInt64, with next: [ImageRequest: Set<Int>]) async {
        guard nextGeneration > generation else { return }
        generation = nextGeneration
        let removed = Array(owners.keys.filter { next[$0] == nil })
        let added = Array(next.keys.filter { owners[$0] == nil })
        owners = next
        // The actor intentionally serializes cancellation before warming. A request
        // shared by multiple indexes remains present and produces neither call.
        if !removed.isEmpty { await pipeline.cancelPrefetch(removed) }
        if !added.isEmpty { await pipeline.prefetch(added) }
    }
}

/// Owns the bounded, directional working set. Layout requests are never shed;
/// speculative render/image warming is capped and cancelled on direction changes.
@MainActor
final class FeedPrefetchCoordinator {
    private var itemCount: Int
    private let renderCapacity: Int
    private var layoutWindowIndexes: Set<Int> = []
    private var renderWindowIndexes: Set<Int> = []
    /// Lightweight request metadata only. The coordinator must never own parsed
    /// text, CoreText lines, or a PreparedFeedEntry.
    private var requestsByIndex: [Int: [ImageRequest]] = [:]
    private let imageDriver: FeedImagePrefetchDriver?
    private let requestProvider: ((Int) -> [ImageRequest])?
    private var imageOperation = Task<Void, Never> {}
    private var imageGeneration: UInt64 = 0

    init(
        itemCount: Int = 0,
        renderCapacity: Int = 48,
        imagePipeline: (any ImagePipeline)? = nil,
        requestProvider: ((Int) -> [ImageRequest])? = nil
    ) {
        self.itemCount = max(0, itemCount)
        self.renderCapacity = max(0, renderCapacity)
        imageDriver = imagePipeline.map(FeedImagePrefetchDriver.init)
        self.requestProvider = requestProvider
    }

    func setEntries(_ entries: [PreparedFeedEntry]) {
        submitImageOwners([:])
        requestsByIndex = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.offset, Self.imageRequests(for: $0.element)) })
        itemCount = entries.count
        layoutWindowIndexes.removeAll()
        renderWindowIndexes.removeAll()
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
        let nextLayoutWindow = Set(priorities.map(\.index))
        let cancelled = layoutWindowIndexes.subtracting(nextLayoutWindow)
        layoutWindowIndexes = nextLayoutWindow

        // Exact layout demand survives pressure. Render warming consumes only the
        // bounded capacity, with visible rows taking all slots first.
        let layoutJobs = priorities.map {
            FeedPreparationJob(index: $0.index, kind: .layout, priority: $0.priority)
        }
        let effectiveRenderCapacity = max(renderCapacity, visible.count)
        let renderPriorities = Array(priorities.prefix(effectiveRenderCapacity))
        let renderJobs = renderPriorities.map {
            FeedPreparationJob(index: $0.index, kind: .render, priority: $0.priority)
        }
        renderWindowIndexes = Set(renderPriorities.map(\.index))
        submitImageOwners(imageOwners(for: renderPriorities.map(\.index)))
        return FeedPrefetchUpdate(jobs: layoutJobs + renderJobs, cancelled: cancelled)
    }

    func cancel(indexes: Set<Int>) {
        layoutWindowIndexes.subtract(indexes)
        renderWindowIndexes.subtract(indexes)
        submitImageOwners(imageOwners(for: renderWindowIndexes.sorted()))
    }

    func shedLowPriorityWork(retaining visible: Set<Int>) {
        layoutWindowIndexes.formIntersection(visible)
        renderWindowIndexes.formIntersection(visible)
        submitImageOwners(imageOwners(for: renderWindowIndexes.sorted()))
    }

    func waitForImageOperations() async { await imageOperation.value }

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

    private func imageOwners(for indexes: [Int]) -> [ImageRequest: Set<Int>] {
        var owners: [ImageRequest: Set<Int>] = [:]
        for index in indexes {
            let requests: [ImageRequest]
            if let requestProvider {
                requests = requestProvider(index)
            } else if let metadata = requestsByIndex[index] {
                requests = metadata
            } else {
                requests = []
            }
            for request in requests { owners[request, default: []].insert(index) }
        }
        return owners
    }

    private func submitImageOwners(_ owners: [ImageRequest: Set<Int>]) {
        guard let imageDriver else { return }
        imageGeneration &+= 1
        let generation = imageGeneration
        let previous = imageOperation
        imageOperation = Task {
            await previous.value
            await imageDriver.replaceOwners(generation: generation, with: owners)
        }
    }

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
