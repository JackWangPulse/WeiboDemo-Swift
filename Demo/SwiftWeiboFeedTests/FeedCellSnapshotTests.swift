import CoreGraphics
import ImageIO
import XCTest
@testable import SwiftWeiboFeed

final class FeedCellSnapshotTests: XCTestCase {
    func testPixelComparatorAllowsOnlyOneChannelStepAtAntialiasedEdges() throws {
        let reference = try XCTUnwrap(Self.image(bytes: [255, 255, 255, 255, 10, 20, 30, 255]))
        let acceptable = try XCTUnwrap(Self.image(bytes: [255, 255, 255, 255, 11, 19, 30, 255]))
        let changed = try XCTUnwrap(Self.image(bytes: [255, 255, 255, 255, 14, 20, 30, 255]))
        XCTAssertNil(try SnapshotComparator.compare(reference: reference, candidate: acceptable, name: "antialias"))
        let diff = try XCTUnwrap(SnapshotComparator.compare(reference: reference, candidate: changed, name: "changed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: diff.path))
    }

    func testSnapshotManifestCoversEveryRequiredIPhone11WidthCase() {
        XCTAssertEqual(FeedSnapshotCase.allCases.map(\.rawValue), [
            "plain-text", "long-text", "one-image", "four-images", "nine-images",
            "repost-text", "repost-media", "card", "place-tag", "rich-semantic-text",
            "image-placeholder", "image-failure",
        ])
        XCTAssertEqual(FeedSnapshotReference.iPhone11Width, 414)
        XCTAssertTrue(FeedSnapshotCase.allCases.allSatisfy { FeedSnapshotReference.pngData(for: $0) != nil })
    }

    private static func image(bytes: [UInt8]) -> CGImage? {
        let provider = CGDataProvider(data: Data(bytes) as CFData)
        return provider.flatMap { CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: $0, decode: nil, shouldInterpolate: false, intent: .defaultIntent) }
    }
}
