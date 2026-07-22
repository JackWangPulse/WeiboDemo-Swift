import Foundation

protocol ImagePipeline: Sendable {
    func image(for request: ImageRequest) async throws -> ImageResponse
    func prefetch(_ requests: [ImageRequest]) async
    func cancelPrefetch(_ requests: [ImageRequest]) async
}
