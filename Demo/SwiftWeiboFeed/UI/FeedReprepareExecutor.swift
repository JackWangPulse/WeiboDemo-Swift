import Foundation

typealias FeedReprepareStartHook = @Sendable (FeedTimelineStore.Record) async throws -> Void

private actor FeedReprepareWorker {
    private let startHook: FeedReprepareStartHook?
    init(startHook: FeedReprepareStartHook?) { self.startHook = startHook }

    func prepare(_ record: FeedTimelineStore.Record) async throws -> PreparedFeedEntry {
        try Task.checkCancellation()
        try await startHook?(record)
        try Task.checkCancellation()
        let parsed = FeedTextParser().parse(record.item.text)
        let parsedRepost = record.item.repost.map { FeedTextParser().parse($0.text) }
        try Task.checkCancellation()
        let layout = try await FeedLayoutEngine().layout(
            identity: record.identity,
            item: record.item,
            parsedBody: parsed,
            parsedRepost: parsedRepost,
            environment: record.expectedLayoutIdentity.environment
        )
        try Task.checkCancellation()
        return PreparedFeedEntry(item: record.item, identity: record.identity, parsed: parsed, layout: layout)
    }
}

/// Owns every re-preparation task. Cancellation marks a slot but does not free it;
/// the slot is released only after the worker observes cancellation and exits.
@MainActor
final class FeedReprepareExecutor {
    typealias Completion = @MainActor (Int, UInt64, Result<PreparedFeedEntry, Error>) -> Void
    private struct Pending {
        let token: UUID
        let index: Int
        let record: FeedTimelineStore.Record
        let priority: FeedPreparationPriority
        let completion: Completion
    }
    private struct Running { let token: UUID; let task: Task<Void, Never> }
    private let workers: [FeedReprepareWorker]
    private let capacity: Int
    private var cursor = 0
    private var pending: [Int: Pending] = [:]
    private var running: [Int: Running] = [:]

    init(capacity: Int = 16, concurrency: Int = 2, startHook: FeedReprepareStartHook? = nil) {
        self.capacity = max(1, capacity)
        workers = (0..<max(1, concurrency)).map { _ in FeedReprepareWorker(startHook: startHook) }
    }

    @discardableResult
    func submit(index: Int, record: FeedTimelineStore.Record, priority: FeedPreparationPriority, completion: @escaping Completion) -> Bool {
        guard pending[index] == nil, running[index] == nil, occupiedCountForTesting < capacity else { return false }
        let token = UUID()
        pending[index] = Pending(token: token, index: index, record: record, priority: priority, completion: completion)
        schedule()
        return true
    }

    func cancel(index: Int) {
        if pending.removeValue(forKey: index) != nil { return }
        running[index]?.task.cancel()
    }
    func cancelAll() {
        pending.removeAll()
        running.values.forEach { $0.task.cancel() }
    }

    private func schedule() {
        while running.count < workers.count, let next = pending.values.min(by: {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.index < $1.index
        }) {
            pending.removeValue(forKey: next.index)
            let worker = workers[cursor]; cursor = (cursor + 1) % workers.count
            let taskPriority: TaskPriority = (next.priority == .visible || next.priority == .forward) ? .userInitiated : .utility
            let task = Task(priority: taskPriority) { [weak self] in
                let result: Result<PreparedFeedEntry, Error>
                do { result = .success(try await worker.prepare(next.record)) }
                catch { result = .failure(error) }
                guard let self else { return }
                self.finish(next, result: result, cancelled: Task.isCancelled)
            }
            running[next.index] = Running(token: next.token, task: task)
        }
    }

    private func finish(_ pendingJob: Pending, result: Result<PreparedFeedEntry, Error>, cancelled: Bool) {
        guard running[pendingJob.index]?.token == pendingJob.token else { return }
        running.removeValue(forKey: pendingJob.index)
        if !cancelled { pendingJob.completion(pendingJob.index, pendingJob.record.generation, result) }
        schedule()
    }

    var occupiedCountForTesting: Int { pending.count + running.count }
    var runningCountForTesting: Int { running.count }
    var pendingCountForTesting: Int { pending.count }
    var capacityForTesting: Int { capacity }
}
