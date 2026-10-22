import XCTest

@MainActor
final class SwiftWeiboFeedUITests: XCTestCase {
    func testFeedLaunchesAndShowsRows() {
        let app = launchApp()
        let table = app.tables["feed.table"]

        XCTAssertTrue(table.waitForExistence(timeout: 10))
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 10))
    }

    func testMoreExpandsThePost() {
        let app = launchApp()
        let more = app.descendants(matching: .any)["feed.more"].firstMatch
        XCTAssertTrue(find(more, in: app), "Expected an expandable post in the demo feed")

        let cell = containingCell(of: more, in: app)
        let cellIdentifier = cell.identifier
        let collapsedHeight = cell.frame.height
        more.tap()

        let expandedCell = app.cells[cellIdentifier]
        let expanded = NSPredicate { _, _ in
            let moreInExpandedCell = expandedCell.descendants(matching: .any)["feed.more"].firstMatch
            return expandedCell.exists
                && expandedCell.frame.height > collapsedHeight + 1
                && !moreInExpandedCell.exists
        }
        expectation(for: expanded, evaluatedWith: nil)
        waitForExpectations(timeout: 15)
    }

    func testImageOpensPreview() {
        let app = launchApp()
        let media = app.descendants(matching: .any)["feed.media.0"].firstMatch
        XCTAssertTrue(find(media, in: app), "Expected an image in the demo feed")
        media.tap()

        XCTAssertTrue(app.images["feed.imagePreview"].waitForExistence(timeout: 5))
    }

    func testNavigatesBetweenCollectionViewControllersWithLayoutTransition() {
        let app = launchApp()
        let table = app.tables["feed.table"]
        let collectionButton = app.buttons["feed.mode.collection"]
        let gridButton = app.buttons["feed.collection.navigation.grid"]

        XCTAssertTrue(table.waitForExistence(timeout: 10))
        XCTAssertTrue(collectionButton.waitForExistence(timeout: 5))
        collectionButton.tap()

        let listCollection = app.collectionViews["feed.collection.list"]
        XCTAssertTrue(listCollection.waitForExistence(timeout: 5))
        XCTAssertEqual(listCollection.value as? String, "list-layout")
        XCTAssertTrue(listCollection.cells.firstMatch.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(listCollection.cells.firstMatch.frame.width, listCollection.frame.width * 0.8)
        XCTAssertTrue(gridButton.waitForExistence(timeout: 5))
        gridButton.tap()

        let gridCollection = app.collectionViews["feed.collection.grid"]
        XCTAssertTrue(gridCollection.waitForExistence(timeout: 5))
        XCTAssertEqual(gridCollection.value as? String, "grid-layout")
        XCTAssertTrue(gridCollection.cells.firstMatch.waitForExistence(timeout: 10))
        let cards = gridCollection.cells.allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(cards.count, 2)
        XCTAssertLessThan(cards[0].frame.width, gridCollection.frame.width * 0.6)
        XCTAssertEqual(cards[0].frame.minY, cards[1].frame.minY, accuracy: 2)
        let sampledHeights = Set(cards.prefix(6).map { Int($0.frame.height.rounded()) })
        XCTAssertGreaterThan(sampledHeights.count, 1, "Grid cards should preserve each feed's adaptive content height")
        let firstCard = gridCollection.cells["feed.collection.cell.0"]
        let secondCard = gridCollection.cells["feed.collection.cell.1"]
        let thirdCard = gridCollection.cells["feed.collection.cell.2"]
        XCTAssertTrue(thirdCard.waitForExistence(timeout: 5))
        let shortestColumnBottom = min(firstCard.frame.maxY, secondCard.frame.maxY)
        XCTAssertEqual(
            thirdCard.frame.minY,
            shortestColumnBottom + 10,
            accuracy: 3,
            "Masonry layout should append the next card to the shortest column without a row-sized gap"
        )
        XCTAssertTrue(
            gridCollection.descendants(matching: .any)["feed.media.0"].firstMatch.waitForExistence(timeout: 5),
            "Collection cards should expose the same rich media subviews as table cells"
        )

        app.navigationBars["Collection Grid"].buttons["Collection List"].tap()
        XCTAssertTrue(listCollection.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(listCollection.cells.firstMatch.frame.width, listCollection.frame.width * 0.8)
        app.navigationBars["Collection List"].buttons["Swift Weibo"].tap()
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        XCTAssertTrue(table.cells.firstMatch.waitForExistence(timeout: 5))
    }

    func testAnimatesListAndGridLayoutsInsideOneCollectionViewController() {
        let app = launchApp()
        let singleControllerButton = app.buttons["feed.mode.collection.single"]
        XCTAssertTrue(singleControllerButton.waitForExistence(timeout: 10))
        singleControllerButton.tap()

        let collection = app.collectionViews["feed.collection.single"]
        let toggleButton = app.buttons["feed.collection.single.toggle"]
        XCTAssertTrue(collection.waitForExistence(timeout: 5))
        XCTAssertEqual(collection.value as? String, "list-layout")
        XCTAssertTrue(collection.cells.firstMatch.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(collection.cells.firstMatch.frame.width, collection.frame.width * 0.8)

        XCTAssertTrue(toggleButton.waitForExistence(timeout: 5))
        toggleButton.tap()
        expectation(for: NSPredicate(format: "value == %@", "grid-layout"), evaluatedWith: collection)
        waitForExpectations(timeout: 5)
        XCTAssertLessThan(collection.cells.firstMatch.frame.width, collection.frame.width * 0.6)

        toggleButton.tap()
        expectation(for: NSPredicate(format: "value == %@", "list-layout"), evaluatedWith: collection)
        waitForExpectations(timeout: 5)
        XCTAssertGreaterThan(collection.cells.firstMatch.frame.width, collection.frame.width * 0.8)
    }

    private func launchApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        return app
    }

    private func find(_ element: XCUIElement, in app: XCUIApplication, maximumSwipes: Int = 8) -> Bool {
        for _ in 0...maximumSwipes {
            if element.waitForExistence(timeout: 1), element.isHittable { return true }
            app.swipeUp()
        }
        return false
    }

    private func containingCell(of element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        let frame = element.frame
        return app.cells.allElementsBoundByIndex.first { $0.frame.intersects(frame) } ?? app.cells.firstMatch
    }
}
