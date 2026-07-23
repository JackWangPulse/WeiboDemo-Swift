import XCTest
@testable import SwiftWeiboFeed

final class FeedRepositoryTests: XCTestCase {
    func testRepositoryDeduplicatesIDsAndKeepsFirstOccurrenceOrder() async throws {
        let repository = FeedRepository()
        let page = try decodePage(idsAndTexts: [("1", "one"), ("1", "replacement"), ("2", "two")])

        let changes = try await repository.apply(page: page, environment: environment())
        let snapshot = await repository.snapshot()

        XCTAssertEqual(snapshot.map(\.item.id.rawValue), ["1", "2"])
        XCTAssertEqual(snapshot.first?.item.text, "replacement")
        XCTAssertEqual(changes.compactMap { change -> String? in
            guard case let .inserted(id, _) = change else { return nil }
            return id.rawValue
        }, ["1", "2"])
    }

    func testBodyChangeIncrementsVersionWhileToolbarChangeReusesLayoutVersion() async throws {
        let repository = FeedRepository()
        try await repository.apply(page: decodePage(idsAndTexts: [("1", "one")]), environment: environment())
        let firstSnapshot = await repository.snapshot()
        let first = try XCTUnwrap(firstSnapshot.first)

        let contentChanges = try await repository.apply(page: decodePage(idsAndTexts: [("1", "changed")]), environment: environment())
        let secondSnapshot = await repository.snapshot()
        let second = try XCTUnwrap(secondSnapshot.first)
        XCTAssertEqual(contentChanges, [.contentChanged(FeedID(rawValue: "1"))])
        XCTAssertEqual(second.identity.contentVersion, first.identity.contentVersion + 1)

        let toolbarChanges = try await repository.apply(page: decodePage(idsAndTexts: [("1", "changed")], counts: (1, 2, 3)), environment: environment())
        let thirdSnapshot = await repository.snapshot()
        let third = try XCTUnwrap(thirdSnapshot.first)
        XCTAssertEqual(toolbarChanges, [.toolbarChanged(FeedID(rawValue: "1"))])
        XCTAssertEqual(third.identity, second.identity)
        XCTAssertEqual(third.item.likeCount, 3)
    }

    func testMovesAndDeletesAreDeterministic() async throws {
        let repository = FeedRepository()
        try await repository.apply(page: decodePage(idsAndTexts: [("1", "a"), ("2", "b"), ("3", "c")]), environment: environment())
        let changes = try await repository.apply(page: decodePage(idsAndTexts: [("3", "c"), ("1", "a")]), environment: environment())
        XCTAssertEqual(changes, [
            .deleted(FeedID(rawValue: "2"), 1),
            .moved(FeedID(rawValue: "3"), 2, 0),
            .moved(FeedID(rawValue: "1"), 0, 1)
        ])
    }

    func testEnvironmentChangeRelayoutsWithoutChangingContentVersion() async throws {
        let repository = FeedRepository()
        let page = try decodePage(idsAndTexts: [("1", "one")])
        try await repository.apply(page: page, environment: environment())
        let firstSnapshot = await repository.snapshot()
        let first = try XCTUnwrap(firstSnapshot.first)
        let changes = try await repository.apply(page: page, environment: environment(width: 400, theme: 1))
        let secondSnapshot = await repository.snapshot()
        let second = try XCTUnwrap(secondSnapshot.first)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(second.identity, first.identity)
        XCTAssertNotEqual(second.layout.identity.environment, first.layout.identity.environment)
    }

    func testOlderPreparationCannotOverwriteNewerApply() async throws {
        let parser = FeedTextParser()
        let engine = FeedLayoutEngine()
        let oldPreparationEntered = expectation(description: "old preparation entered")
        let oldPreparationGate = PreparationGate()
        let repository = FeedRepository { item, identity, environment in
            if item.text == "old" {
                oldPreparationEntered.fulfill()
                await oldPreparationGate.waitUntilReleased()
            }
            let body = parser.parse(item.text)
            let repost = item.repost.map { parser.parse($0.text) }
            let layout = try await engine.layout(identity: identity, item: item, parsedBody: body, parsedRepost: repost, environment: environment)
            return (body, layout)
        }
        let oldPage = try decodePage(idsAndTexts: [("1", "old")])
        let newPage = try decodePage(idsAndTexts: [("1", "new")])
        let layoutEnvironment = environment()

        let older = Task { try await repository.apply(page: oldPage, environment: layoutEnvironment) }
        await fulfillment(of: [oldPreparationEntered], timeout: 1)

        let newerResult: Result<[FeedChange], Error>
        do {
            newerResult = .success(try await repository.apply(page: newPage, environment: layoutEnvironment))
        } catch {
            newerResult = .failure(error)
        }
        await oldPreparationGate.release()

        do {
            _ = try await older.value
            XCTFail("Superseded preparation should not commit")
        } catch is CancellationError {}
        _ = try newerResult.get()

        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.first?.item.text, "new")
        XCTAssertEqual(snapshot.first?.parsed.source, "new")
    }

    func testDefaultParsingFanOutIsBoundedAndPublishesOnlyCompleteSnapshot() async throws {
        let counter = ParsingPeakCounter()
        let barrier = TwoParseBarrier()
        let repository = FeedRepository(
            parsingStartHook: { _ in
                counter.enter()
                await barrier.arriveAndWait()
            },
            parsingEndHook: { _ in counter.leave() }
        )
        let page = try decodePage(idsAndTexts: (0..<24).map { ("\($0)", "body @user \($0)") })

        _ = try await repository.apply(page: page, environment: environment())
        let snapshot = await repository.snapshot()

        XCTAssertEqual(snapshot.count, 24)
        XCTAssertTrue(snapshot.allSatisfy { !$0.layout.allFrames.isEmpty })
        XCTAssertEqual(counter.peak, 2)
    }

    func testCancelledBatchStopsSchedulingAndLeavesSnapshotAtomic() async throws {
        let gate = CancelledParsingGate()
        let repository = FeedRepository(parsingStartHook: { item in
            try await gate.parsingStarted(item)
        })
        let baseline = try decodePage(idsAndTexts: [("baseline", "ready")])
        _ = try await repository.apply(page: baseline, environment: environment())
        let baselineSnapshot = await repository.snapshot()

        let oldPage = try decodePage(idsAndTexts: (0..<20).map { ("old-\($0)", "old \($0)") })
        let newPage = try decodePage(idsAndTexts: (0..<6).map { ("new-\($0)", "new \($0)") })
        let testEnvironment = environment()
        await gate.blockOldParses()
        let oldApply = Task { try await repository.apply(page: oldPage, environment: testEnvironment) }
        await gate.waitUntilTwoOldParsesStarted()

        oldApply.cancel()
        let newApply = Task { try await repository.apply(page: newPage, environment: testEnvironment) }
        let inProgress = await repository.snapshot()
        XCTAssertEqual(inProgress.map(\.item.id.rawValue), ["baseline"])
        XCTAssertEqual(inProgress.map(\.identity), baselineSnapshot.map(\.identity))
        XCTAssertEqual(inProgress.map(\.layout.identity), baselineSnapshot.map(\.layout.identity))
        XCTAssertEqual(inProgress.map(\.parsed.source), ["ready"])

        await gate.releaseOldParses()
        do {
            _ = try await oldApply.value
            XCTFail("cancelled old batch must not publish")
        } catch is CancellationError {}
        _ = try await newApply.value

        let oldStartCount = await gate.oldStartCount
        XCTAssertEqual(oldStartCount, 2, "cancelled workers must not start the remaining old parses")
        let final = await repository.snapshot()
        XCTAssertEqual(final.map(\.item.id.rawValue), (0..<6).map { "new-\($0)" })
        XCTAssertEqual(final.count, 6)
    }

    private func decodePage(idsAndTexts: [(String, String)], counts: (Int, Int, Int) = (0, 0, 0)) throws -> FeedPage {
        let statuses = idsAndTexts.map { id, text in
            #"{"id":"\#(id)","text":"\#(text)","user":{"id":"u\#(id)","name":"User"},"reposts_count":\#(counts.0),"comments_count":\#(counts.1),"attitudes_count":\#(counts.2)}"#
        }.joined(separator: ",")
        return try JSONDecoder.weibo.decode(FeedPage.self, from: Data("{\"statuses\":[\(statuses)]}".utf8))
    }

    private func environment(width: CGFloat = 320, theme: UInt = 0) -> FeedLayoutEnvironment {
        FeedLayoutEnvironment(width: width, scale: 2, contentSizeCategory: .large, themeVersion: theme, algorithmVersion: 1)
    }
}

private final class ParsingPeakCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var maximum = 0

    var peak: Int { lock.withLock { maximum } }
    func enter() { lock.withLock { current += 1; maximum = max(maximum, current) } }
    func leave() { lock.withLock { current -= 1 } }
}

private actor TwoParseBarrier {
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrivals += 1
        guard arrivals < 2 else {
            waiters.forEach { $0.resume() }
            waiters.removeAll()
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor CancelledParsingGate {
    private var blocksOld = false
    private(set) var oldStartCount = 0
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func blockOldParses() { blocksOld = true }

    func parsingStarted(_ item: FeedItem) async throws {
        guard blocksOld, item.id.rawValue.hasPrefix("old-") else { return }
        oldStartCount += 1
        if oldStartCount == 2 {
            entryWaiters.forEach { $0.resume() }
            entryWaiters.removeAll()
        }
        await withCheckedContinuation { releaseWaiters.append($0) }
        try Task.checkCancellation()
    }

    func waitUntilTwoOldParsesStarted() async {
        if oldStartCount >= 2 { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func releaseOldParses() {
        blocksOld = false
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor PreparationGate {
    private var isReleased = false
    private var waiter: CheckedContinuation<Void, Never>?

    func waitUntilReleased() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func release() {
        isReleased = true
        waiter?.resume()
        waiter = nil
    }
}
