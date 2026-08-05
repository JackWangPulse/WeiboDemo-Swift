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
/*
 请求不只有 url 还要有targetpixelsize
 同一个 URL 显示成 40×40 头像和 240×240 大图，是两个不同请求。
 */
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
