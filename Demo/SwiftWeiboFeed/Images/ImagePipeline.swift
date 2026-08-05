import Foundation

protocol ImagePipeline: Sendable {
    func image(for request: ImageRequest) async throws -> ImageResponse
    func prefetch(_ requests: [ImageRequest]) async
    func cancelPrefetch(_ requests: [ImageRequest]) async
}
/*
 Cell 只依赖这个接口，不关心底层用的是：
 当前的 SystemImagePipeline
 YYWebImage 适配器
 Kingfisher
 Nuke
 自研图片框架
 这就是之前说的“后续可以替换 YYWebImage”的接口边界。
*/
