import CoreGraphics
import CoreText
import UIKit
import XCTest
@testable import SwiftWeiboFeed

final class FeedLayoutEngineTests: XCTestCase {
    func testLayoutEnvironmentUsesPixelWidthAndStableContentSizeName() {
        let environment = FeedLayoutEnvironment(
            width: 390,
            scale: 3,
            contentSizeCategory: .large,
            themeVersion: 1,
            algorithmVersion: 2
        )

        XCTAssertEqual(environment.containerPixelWidth, 1_170)
        XCTAssertEqual(environment.displayScale, 3)
        XCTAssertEqual(environment.contentSizeCategory, UIContentSizeCategory.large.rawValue)
        XCTAssertEqual(environment.themeVersion, 1)
        XCTAssertEqual(environment.layoutAlgorithmVersion, 2)
    }

    func testEveryEnvironmentComponentParticipatesInLayoutIdentity() {
        let content = FeedContentIdentity(itemID: FeedID(rawValue: "42"), contentVersion: 7)
        let baseline = environment()
        let identities = [
            FeedLayoutIdentity(content: content, environment: baseline),
            FeedLayoutIdentity(content: content, environment: environment(width: 391)),
            FeedLayoutIdentity(content: content, environment: environment(scale: 2)),
            FeedLayoutIdentity(content: content, environment: environment(contentSizeCategory: .extraLarge)),
            FeedLayoutIdentity(content: content, environment: environment(themeVersion: 2)),
            FeedLayoutIdentity(content: content, environment: environment(algorithmVersion: 2)),
        ]

        XCTAssertEqual(Set(identities).count, identities.count)
    }

    func testCacheMissesWhenAnyEnvironmentComponentChanges() {
        let cache = FeedLayoutCache()
        let content = FeedContentIdentity(itemID: FeedID(rawValue: "42"), contentVersion: 7)
        let identity = FeedLayoutIdentity(content: content, environment: environment())
        cache.insert(makeLayout(identity: identity), cost: 64)

        XCTAssertNotNil(cache.value(for: identity))
        XCTAssertNil(cache.value(for: .init(content: content, environment: environment(width: 391))))
        XCTAssertNil(cache.value(for: .init(content: content, environment: environment(scale: 2))))
        XCTAssertNil(cache.value(for: .init(content: content, environment: environment(contentSizeCategory: .extraLarge))))
        XCTAssertNil(cache.value(for: .init(content: content, environment: environment(themeVersion: 2))))
        XCTAssertNil(cache.value(for: .init(content: content, environment: environment(algorithmVersion: 2))))
    }

    func testRemoveAllExceptRetainsOnlyRequestedLayouts() {
        let cache = FeedLayoutCache()
        let first = identity(id: "1")
        let second = identity(id: "2")
        cache.insert(makeLayout(identity: first), cost: 1)
        cache.insert(makeLayout(identity: second), cost: 1)

        cache.removeAllExcept([second])

        XCTAssertNil(cache.value(for: first))
        XCTAssertNotNil(cache.value(for: second))
    }

    func testLayoutPrimitivesRetainFiniteGeometryAndInteractions() {
        let rect = CGRect(x: 12, y: 24, width: 48, height: 20)
        let region = InteractionRegion(rects: [rect], action: .topic("Swift"), accessibilityLabel: "#Swift#")
        let body = TextLayout(
            storage: CoreTextLayoutStorage(lines: [], origins: []),
            bounds: CGRect(x: 0, y: 0, width: 300, height: 80),
            regions: [region]
        )
        let layout = FeedItemLayout(
            identity: identity(id: "finite"),
            height: 160,
            body: body,
            avatarFrame: CGRect(x: 12, y: 12, width: 40, height: 40),
            mediaFrames: [CGRect(x: 12, y: 100, width: 48, height: 48)],
            repost: nil,
            toolbar: ToolbarLayout(frame: CGRect(x: 0, y: 148, width: 300, height: 12), regions: [])
        )

        XCTAssertEqual(layout.body.regions.first?.action, .topic("Swift"))
        XCTAssertEqual(layout.body.regions.first?.rects, [rect])
        XCTAssertTrue(layout.allFrames.allSatisfy(\.isFiniteAndNonNegative))
        XCTAssertTrue(layout.allFrames.allSatisfy { $0.maxY <= layout.height })
    }

    private func environment(
        width: CGFloat = 390,
        scale: CGFloat = 3,
        contentSizeCategory: UIContentSizeCategory = .large,
        themeVersion: UInt = 1,
        algorithmVersion: UInt = 1
    ) -> FeedLayoutEnvironment {
        FeedLayoutEnvironment(
            width: width,
            scale: scale,
            contentSizeCategory: contentSizeCategory,
            themeVersion: themeVersion,
            algorithmVersion: algorithmVersion
        )
    }

    private func identity(id: String) -> FeedLayoutIdentity {
        FeedLayoutIdentity(
            content: FeedContentIdentity(itemID: FeedID(rawValue: id), contentVersion: 1),
            environment: environment()
        )
    }

    private func makeLayout(identity: FeedLayoutIdentity) -> FeedItemLayout {
        FeedItemLayout(
            identity: identity,
            height: 1,
            body: TextLayout(storage: CoreTextLayoutStorage(lines: [], origins: []), bounds: .zero, regions: []),
            avatarFrame: .zero,
            mediaFrames: [],
            repost: nil,
            toolbar: ToolbarLayout(frame: .zero, regions: [])
        )
    }
}
