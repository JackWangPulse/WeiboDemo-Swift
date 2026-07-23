import Foundation

private actor ParsingWorker {
    private let parser = FeedTextParser()
    private let startHook: (@Sendable (FeedItem) async throws -> Void)?
    private let endHook: (@Sendable (FeedItem) -> Void)?

    init(
        startHook: (@Sendable (FeedItem) async throws -> Void)?,
        endHook: (@Sendable (FeedItem) -> Void)?
    ) {
        self.startHook = startHook
        self.endHook = endHook
    }

    func parse(_ item: FeedItem) async throws -> (ParsedFeedText, ParsedFeedText?) {
        try Task.checkCancellation()
        try await startHook?(item)
        defer { endHook?(item) }
        try Task.checkCancellation()
        let body = parser.parse(item.text)
        try Task.checkCancellation()
        let repost = item.repost.map { parser.parse($0.text) }
        return (body, repost)
    }
}

private actor ParsingExecutor {
    private let workers: [ParsingWorker]
    private var cursor = 0

    init(
        concurrency: Int,
        startHook: (@Sendable (FeedItem) async throws -> Void)?,
        endHook: (@Sendable (FeedItem) -> Void)?
    ) {
        workers = (0..<max(1, concurrency)).map { _ in ParsingWorker(startHook: startHook, endHook: endHook) }
    }

    func parse(_ item: FeedItem) async throws -> (ParsedFeedText, ParsedFeedText?) {
        try Task.checkCancellation()
        let worker = workers[cursor]
        cursor = (cursor + 1) % workers.count
        try Task.checkCancellation()
        return try await worker.parse(item)
    }
}

public enum FeedChange: Equatable, Sendable {
    case inserted(FeedID, Int)
    case deleted(FeedID, Int)
    case moved(FeedID, Int, Int)
    case contentChanged(FeedID)
    case toolbarChanged(FeedID)
}

public struct PreparedFeedEntry: Sendable {
    public let item: FeedItem
    public let identity: FeedContentIdentity
    public let parsed: ParsedFeedText
    public let layout: FeedItemLayout

    public init(item: FeedItem, identity: FeedContentIdentity, parsed: ParsedFeedText, layout: FeedItemLayout) {
        self.item = item
        self.identity = identity
        self.parsed = parsed
        self.layout = layout
    }
}

public actor FeedRepository {
    public typealias LayoutPreparation = @Sendable (
        _ item: FeedItem,
        _ identity: FeedContentIdentity,
        _ environment: FeedLayoutEnvironment
    ) async throws -> (ParsedFeedText, FeedItemLayout)

    private struct State: Sendable {
        var entries: [PreparedFeedEntry] = []
        var environment: FeedLayoutEnvironment?
    }

    private let prepareLayout: LayoutPreparation
    private var state = State()
    private var generation: UInt64 = 0

    public init(
        prepareLayout: LayoutPreparation? = nil,
        parsingStartHook: (@Sendable (FeedItem) async throws -> Void)? = nil,
        parsingEndHook: (@Sendable (FeedItem) -> Void)? = nil
    ) {
        if let prepareLayout {
            self.prepareLayout = prepareLayout
        } else {
            let parsingExecutor = ParsingExecutor(
                concurrency: 2,
                startHook: parsingStartHook,
                endHook: parsingEndHook
            )
            let engine = FeedLayoutEngine()
            self.prepareLayout = { item, identity, environment in
                let (parsedBody, parsedRepost) = try await parsingExecutor.parse(item)
                let layout = try await engine.layout(
                    identity: identity,
                    item: item,
                    parsedBody: parsedBody,
                    parsedRepost: parsedRepost,
                    environment: environment
                )
                return (parsedBody, layout)
            }
        }
    }

    public func apply(page: FeedPage, environment: FeedLayoutEnvironment) async throws -> [FeedChange] {
        generation &+= 1
        let requestGeneration = generation
        let oldState = state
        let newItems = Self.deduplicated(page.items)
        let changes = Self.changes(from: oldState.entries.map(\.item), to: newItems)
        let oldEntries = Dictionary(uniqueKeysWithValues: oldState.entries.map { ($0.item.id, $0) })
        let environmentChanged = oldState.environment != environment

        let plans = newItems.map { item -> PreparationPlan in
            if let old = oldEntries[item.id], !Self.layoutContentChanged(old.item, item) {
                if !environmentChanged {
                    return .reuse(PreparedFeedEntry(item: item, identity: old.identity, parsed: old.parsed, layout: old.layout))
                }
                return .prepare(item, old.identity)
            }
            let nextVersion = oldEntries[item.id].map { $0.identity.contentVersion &+ 1 } ?? 0
            return .prepare(item, FeedContentIdentity(itemID: item.id, contentVersion: nextVersion))
        }
        let preparation = prepareLayout

        var prepared = Array<PreparedFeedEntry?>(repeating: nil, count: plans.count)
        var preparationIndexes: [Int] = []
        for (index, plan) in plans.enumerated() {
            if case let .reuse(entry) = plan {
                prepared[index] = entry
            } else {
                preparationIndexes.append(index)
            }
        }
        let workerCount = min(2, preparationIndexes.count)
        let batches = try await withThrowingTaskGroup(of: [(Int, PreparedFeedEntry)].self) { group in
            for worker in 0..<workerCount {
                group.addTask {
                    var batch: [(Int, PreparedFeedEntry)] = []
                    var position = worker
                    while position < preparationIndexes.count {
                        try Task.checkCancellation()
                        let index = preparationIndexes[position]
                        guard case let .prepare(item, identity) = plans[index] else {
                            position += workerCount
                            continue
                        }
                        let (parsed, layout) = try await preparation(item, identity, environment)
                        try Task.checkCancellation()
                        batch.append((index, PreparedFeedEntry(item: item, identity: identity, parsed: parsed, layout: layout)))
                        position += workerCount
                    }
                    return batch
                }
            }
            var values: [(Int, PreparedFeedEntry)] = []
            for try await batch in group { values.append(contentsOf: batch) }
            return values
        }
        for (index, entry) in batches { prepared[index] = entry }
        let complete = prepared.compactMap { $0 }
        guard complete.count == plans.count else { throw CancellationError() }

        try Task.checkCancellation()
        guard requestGeneration == generation else { throw CancellationError() }
        state = State(entries: complete, environment: environment)
        return changes
    }

    public func snapshot() -> [PreparedFeedEntry] { state.entries }

    private enum PreparationPlan: Sendable {
        case reuse(PreparedFeedEntry)
        case prepare(FeedItem, FeedContentIdentity)
    }

    private static func deduplicated(_ items: [FeedItem]) -> [FeedItem] {
        var order: [FeedID] = []
        var byID: [FeedID: FeedItem] = [:]
        order.reserveCapacity(items.count)
        byID.reserveCapacity(items.count)
        for item in items {
            if byID.updateValue(item, forKey: item.id) == nil { order.append(item.id) }
        }
        return order.compactMap { byID[$0] }
    }

    private static func changes(from old: [FeedItem], to new: [FeedItem]) -> [FeedChange] {
        let oldIndex = Dictionary(uniqueKeysWithValues: old.enumerated().map { ($0.element.id, $0.offset) })
        let newIndex = Dictionary(uniqueKeysWithValues: new.enumerated().map { ($0.element.id, $0.offset) })
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        var result: [FeedChange] = []
        for (index, item) in old.enumerated() where newIndex[item.id] == nil { result.append(.deleted(item.id, index)) }
        for (index, item) in new.enumerated() where oldIndex[item.id] == nil { result.append(.inserted(item.id, index)) }
        for (index, item) in new.enumerated() {
            guard let previousIndex = oldIndex[item.id], let previous = oldByID[item.id] else { continue }
            if previousIndex != index { result.append(.moved(item.id, previousIndex, index)) }
            if layoutContentChanged(previous, item) {
                result.append(.contentChanged(item.id))
            } else if toolbarChanged(previous, item) {
                result.append(.toolbarChanged(item.id))
            }
        }
        return result
    }

    private static func toolbarChanged(_ lhs: FeedItem, _ rhs: FeedItem) -> Bool {
        lhs.repostCount != rhs.repostCount || lhs.commentCount != rhs.commentCount || lhs.likeCount != rhs.likeCount
    }

    private static func layoutContentChanged(_ lhs: FeedItem, _ rhs: FeedItem) -> Bool {
        lhs.id != rhs.id || lhs.user != rhs.user || lhs.text != rhs.text || lhs.pictures != rhs.pictures ||
            lhs.repost != rhs.repost || lhs.card != rhs.card || lhs.tags != rhs.tags ||
            lhs.createdAt != rhs.createdAt || lhs.source != rhs.source
    }
}
