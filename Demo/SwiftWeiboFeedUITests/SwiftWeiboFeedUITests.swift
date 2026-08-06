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
        let collapsedHeight = cell.frame.height
        more.tap()

        let expanded = NSPredicate { _, _ in cell.exists && cell.frame.height > collapsedHeight + 1 }
        expectation(for: expanded, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
    }

    func testImageOpensPreview() {
        let app = launchApp()
        let media = app.descendants(matching: .any)["feed.media.0"].firstMatch
        XCTAssertTrue(find(media, in: app), "Expected an image in the demo feed")
        media.tap()

        XCTAssertTrue(app.images["feed.imagePreview"].waitForExistence(timeout: 5))
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
