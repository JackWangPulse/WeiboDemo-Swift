import XCTest

@MainActor
final class SwiftWeiboFeedUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testFeedLaunchesAndShowsRows() {
        let table = app.tables["feed.table"]

        XCTAssertTrue(table.waitForExistence(timeout: 10))
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 10))
    }

    func testMoreExpandsThePost() {
        let more = app.descendants(matching: .any)["feed.more"].firstMatch
        XCTAssertTrue(find(more), "Expected an expandable post in the demo feed")

        let cell = containingCell(of: more)
        let collapsedHeight = cell.frame.height
        more.tap()

        let expanded = NSPredicate { _, _ in cell.exists && cell.frame.height > collapsedHeight + 1 }
        expectation(for: expanded, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
    }

    func testImageOpensPreview() {
        let media = app.descendants(matching: .any)["feed.media.0"].firstMatch
        XCTAssertTrue(find(media), "Expected an image in the demo feed")
        media.tap()

        XCTAssertTrue(app.images["feed.imagePreview"].waitForExistence(timeout: 5))
    }

    private func find(_ element: XCUIElement, maximumSwipes: Int = 8) -> Bool {
        for _ in 0...maximumSwipes {
            if element.waitForExistence(timeout: 1), element.isHittable { return true }
            app.swipeUp()
        }
        return false
    }

    private func containingCell(of element: XCUIElement) -> XCUIElement {
        let frame = element.frame
        return app.cells.allElementsBoundByIndex.first { $0.frame.intersects(frame) } ?? app.cells.firstMatch
    }
}
