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

public struct FeedPublicationToken: Hashable, Sendable {
    public let generation: UInt64
    public let environment: FeedLayoutEnvironment
}

public struct FeedPublication: Sendable {
    public let changes: [FeedChange]
    public let token: FeedPublicationToken
}

public struct PreparedFeedEntry: Sendable {
    public let item: FeedItem // 微博数据
    public let identity: FeedContentIdentity // 稳定身份，用于 Diff
    public let parsed: ParsedFeedText // 解析后的正文
    public let parsedRepost: ParsedFeedText? // 解析后的转发正文
    public let layout: FeedItemLayout // 提前计算好的尺寸与位置

    public init(item: FeedItem, identity: FeedContentIdentity, parsed: ParsedFeedText, parsedRepost: ParsedFeedText? = nil, layout: FeedItemLayout) {
        self.item = item
        self.identity = identity
        self.parsed = parsed
        self.parsedRepost = parsedRepost
        self.layout = layout
    }
}
// actor 保证这些状态不会同时被多个异步任务修改，避免第一页和第二页请求互相覆盖。
public actor FeedRepository {
    public typealias LayoutPreparation = @Sendable (
        _ item: FeedItem,
        _ identity: FeedContentIdentity,
        _ environment: FeedLayoutEnvironment
    ) async throws -> (ParsedFeedText, ParsedFeedText?, FeedItemLayout)

    private struct RetainedEntry: Sendable { // 解析文本缓存
        let item: FeedItem
        let identity: FeedContentIdentity
        let parsed: ParsedFeedText
        let parsedRepost: ParsedFeedText?
    }

    private struct State: Sendable {
        var retained: [RetainedEntry] = []
        var prepared: [PreparedFeedEntry] = []
        var environment: FeedLayoutEnvironment?
        var publication: FeedPublicationToken?
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
            // 下面干的FeedItem -> 解析正文、转发正文 -> 计算 Cell 布局
            // 为以后铺垫 -> PreparedFeedEntry -> 之后cell渲染
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
                return (parsedBody, parsedRepost, layout)
            }
        }
    }

    public func apply(page: FeedPage, environment: FeedLayoutEnvironment) async throws -> FeedPublication {
        generation &+= 1
        let requestGeneration = generation
        let oldState = state
        let newItems = Self.deduplicated(page.items)
        let changes = Self.changes(from: oldState.retained.map(\.item), to: newItems)
        let oldEntries = Dictionary(uniqueKeysWithValues: oldState.retained.map { ($0.item.id, $0) })
        let oldPrepared = Dictionary(uniqueKeysWithValues: oldState.prepared.map { ($0.item.id, $0) })
        let environmentChanged = oldState.environment != environment

        let plans = newItems.map { item -> PreparationPlan in
            if let old = oldEntries[item.id], !Self.layoutContentChanged(old.item, item) {
                if !environmentChanged, let prepared = oldPrepared[item.id] {
                    return .reuse(PreparedFeedEntry(item: item, identity: old.identity, parsed: old.parsed, parsedRepost: old.parsedRepost, layout: prepared.layout))
                }
                return .relayout(item, old.identity, old.parsed, old.parsedRepost)
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
        let indexesToPrepare = preparationIndexes
        let batches = try await withThrowingTaskGroup(of: [(Int, PreparedFeedEntry)].self) { group in
            for worker in 0..<workerCount {
                group.addTask {
                    var batch: [(Int, PreparedFeedEntry)] = []
                    var position = worker
                    while position < indexesToPrepare.count {
                        try Task.checkCancellation()
                        let index = indexesToPrepare[position]
                        let item: FeedItem, identity: FeedContentIdentity, parsed: ParsedFeedText, parsedRepost: ParsedFeedText?, layout: FeedItemLayout
                        /*
                         reuse：数据和屏幕环境都没变，直接复用整个结果。
                         relayout：微博内容没变，但屏幕宽度或字体环境变了；复用富文本，只重新计算布局。
                         prepare：微博内容变了或者是新数据；重新解析并重新布局。
                        */
                        switch plans[index] {
                        case let .prepare(nextItem, nextIdentity):
                            item = nextItem; identity = nextIdentity
                            (parsed, parsedRepost, layout) = try await preparation(item, identity, environment)
                        case let .relayout(nextItem, nextIdentity, retainedParsed, retainedRepost):
                            item = nextItem; identity = nextIdentity; parsed = retainedParsed; parsedRepost = retainedRepost
                            layout = try await FeedLayoutEngine().layout(identity: identity, item: item, parsedBody: parsed, parsedRepost: parsedRepost, environment: environment)
                        case .reuse:
                            position += workerCount; continue
                        }
                        try Task.checkCancellation()
                        batch.append((index, PreparedFeedEntry(item: item, identity: identity, parsed: parsed, parsedRepost: parsedRepost, layout: layout)))
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
        let token = FeedPublicationToken(generation: requestGeneration, environment: environment)
        let retained = complete.map { RetainedEntry(item: $0.item, identity: $0.identity, parsed: $0.parsed, parsedRepost: $0.parsedRepost) }
        state = State(retained: retained, prepared: complete, environment: environment, publication: token)
        return FeedPublication(changes: changes, token: token)
    }

    public func snapshot() -> [PreparedFeedEntry] { state.prepared }

    /// Atomically transfers heavyweight prepared ownership. No later request can
    /// be cleared by a stale snapshot/release pair because there is no second step.
    public func transferPreparedEntries(matching token: FeedPublicationToken, environment: FeedLayoutEnvironment) -> [PreparedFeedEntry]? {
        guard token.environment == environment, state.publication == token, state.environment == environment else { return nil }
        let entries = state.prepared
        state.prepared = []
        state.publication = nil
        return entries
    }

    private enum PreparationPlan: Sendable {
        case reuse(PreparedFeedEntry)
        case prepare(FeedItem, FeedContentIdentity)
        case relayout(FeedItem, FeedContentIdentity, ParsedFeedText, ParsedFeedText?)
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
