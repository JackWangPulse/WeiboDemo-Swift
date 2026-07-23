import Foundation

public enum RenderRegion: Hashable, Sendable {
    case headerBody
    case profile
    case body
    case repost
    case card
    case tag
    case cardTag
    case toolbar
}

public struct RenderIdentity: Hashable, Sendable {
    public let layout: FeedLayoutIdentity
    public let region: RenderRegion
    public let generation: UInt

    public init(layout: FeedLayoutIdentity, region: RenderRegion, generation: UInt) {
        self.layout = layout
        self.region = region
        self.generation = generation
    }
}
