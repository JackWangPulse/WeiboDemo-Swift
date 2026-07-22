import CoreGraphics
import Foundation

struct PixelSize: Hashable, Sendable {
    let width: Int
    let height: Int
}

enum ImageContentMode: Hashable, Sendable {
    case aspectFill
    case aspectFit
}

struct ImageRequest: Hashable, Sendable {
    let url: URL
    let targetPixelSize: PixelSize
    let contentMode: ImageContentMode
    let processorVersion: UInt
}

struct ImageResponse: @unchecked Sendable {
    let request: ImageRequest
    let image: CGImage
}
