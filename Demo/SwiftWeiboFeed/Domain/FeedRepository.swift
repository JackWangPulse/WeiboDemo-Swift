import Foundation

private actor ParsingWorker {
    private let parser = FeedTextParser()
    private let startHook: (@Sendable () -> Void)?
    private let endHook: (@Sendable () -> Void)?

    init(startHook: (@Sendable () -> Void)?, endHook: (@Sendable () -> Void)?) {
        self.startHook = startHook
        self.endHook = endHook
    }

    func parse(_ item: FeedItem) -> (ParsedFeedText, ParsedFeedText?) {
        startHook?()
        defer { endHook?() }
        return (parser.parse(item.text), item.repost.map { parser.parse($0.text) })
    }
}

private actor ParsingExecutor {
    private let workers: [ParsingWorker]
    private var cursor = 0

    init(concurrency: Int, startHook: (@Sendable () -> Void)?, endHook: (@Sendable () -> Void)?) {
        workers = (0..<max(1, concurrency)).map { _ in ParsingWorker(startHook: startHook, endHook: endHook) }
    }

    func parse(_ item: FeedItem) async -> (ParsedFeedText, ParsedFeedText?) {
        let worker = workers[cursor]
        cursor = (cursor + 1) % workers.count
        return await worker.parse(item)
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
        parsingStartHook: (@Sendable () -> Void)? = nil,
        parsingEndHook: (@Sendable () -> Void)? = nil
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
                let (parsedBody, parsedRepost) = await parsingExecutor.parse(item)
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

        let prepared = try await withThrowingTaskGroup(of: (Int, PreparedFeedEntry).self) { group in
            var result = Array<PreparedFeedEntry?>(repeating: nil, count: plans.count)
            for (index, plan) in plans.enumerated() {
                switch plan {
                case let .reuse(entry):
                    result[index] = entry
                case let .prepare(item, identity):
                    group.addTask {
                        try Task.checkCancellation()
                        let (parsed, layout) = try await preparation(item, identity, environment)
                        try Task.checkCancellation()
                        return (index, PreparedFeedEntry(item: item, identity: identity, parsed: parsed, layout: layout))
                    }
                }
            }
            for try await (index, entry) in group { result[index] = entry }
            return result.compactMap { $0 }
        }

        try Task.checkCancellation()
        guard requestGeneration == generation else { throw CancellationError() }
        state = State(entries: prepared, environment: environment)
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
