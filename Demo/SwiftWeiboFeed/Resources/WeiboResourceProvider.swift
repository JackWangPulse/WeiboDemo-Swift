import CoreGraphics
import Foundation
import ImageIO

public enum WeiboResource: Hashable, Sendable {
    case toolbarRepost
    case toolbarComment
    case toolbarUnlike
    case toolbarLike
    case avatarVIP
    case avatarEnterpriseVIP
    case avatarGrassroot
    case timelineMore
    case timelineGIF
    case timelineLongImage

    fileprivate var baseName: String {
        switch self {
        case .toolbarRepost: "timeline_icon_retweet"
        case .toolbarComment: "timeline_icon_comment"
        case .toolbarUnlike: "timeline_icon_unlike"
        case .toolbarLike: "timeline_icon_like"
        case .avatarVIP: "avatar_vip"
        case .avatarEnterpriseVIP: "avatar_enterprise_vip"
        case .avatarGrassroot: "avatar_grassroot"
        case .timelineMore: "timeline_icon_more"
        case .timelineGIF: "timeline_image_gif"
        case .timelineLongImage: "timeline_image_longimage"
        }
    }
}

protocol WeiboResourceProviding: Sendable {
    func image(_ resource: WeiboResource) -> CGImage?
    func membershipImage(rank: Int) -> CGImage?
}

final class WeiboResourceProvider: WeiboResourceProviding, @unchecked Sendable {
    static let shared = WeiboResourceProvider()

    private let resourceBundle: Bundle?
    private let lock = NSLock()
    private var imageCache = [String: CGImage]()

    init(bundle: Bundle = .main) {
        resourceBundle = bundle.url(
            forResource: "ResourceWeibo",
            withExtension: "bundle"
        ).flatMap(Bundle.init(url:))
    }

    func image(_ resource: WeiboResource) -> CGImage? {
        image(named: resource.baseName)
    }

    func membershipImage(rank: Int) -> CGImage? {
        image(named: "common_icon_membership_level\(rank)")
            ?? image(named: "common_icon_membership")
    }

    private func image(named name: String) -> CGImage? {
        if let cached = lock.withLock({ imageCache[name] }) {
            return cached
        }
        guard let url = scaledResourceURL(named: name),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ) else {
            return nil
        }
        lock.withLock { imageCache[name] = image }
        return image
    }

    private func scaledResourceURL(named name: String) -> URL? {
        guard let resourceBundle else { return nil }
        for suffix in ["@3x", "@2x", ""] {
            if let url = resourceBundle.url(
                forResource: name + suffix,
                withExtension: "png"
            ) {
                return url
            }
        }
        return nil
    }
}
