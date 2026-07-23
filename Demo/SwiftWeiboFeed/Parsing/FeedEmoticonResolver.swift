import Foundation
import ImageIO

enum FeedEmoticonResolver {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var paths: [String: URL]?
    nonisolated(unsafe) private static let images: NSCache<NSURL, ImageBox> = {
        let cache = NSCache<NSURL, ImageBox>()
        cache.totalCostLimit = 8 * 1_024 * 1_024
        cache.countLimit = 256
        return cache
    }()

    static func image(named name: String) -> CGImage? {
        precondition(!Thread.isMainThread, "Emoticon resource I/O and decode must stay off-main")
        let map = lock.withLock { () -> [String: URL] in
            if let paths { return paths }
            let loaded = loadPaths(); paths = loaded; return loaded
        }
        guard let url = map[name] else { return nil }
        return lock.withLock {
            let key = url as NSURL
            if let cached = images.object(forKey: key) { return cached.image }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
            images.setObject(ImageBox(image), forKey: key, cost: image.bytesPerRow * image.height)
            return image
        }
    }

    static func clearDecodedCache() { lock.withLock { images.removeAllObjects() } }

    static func resourceURL(named name: String) -> URL? {
        lock.withLock {
            if paths == nil { paths = loadPaths() }
            return paths?[name]
        }
    }

    private static func loadPaths() -> [String: URL] {
        guard let bundleURL = Bundle.main.url(forResource: "EmoticonWeibo", withExtension: "bundle"),
              let bundle = Bundle(url: bundleURL),
              let rootURL = bundle.url(forResource: "emoticons", withExtension: "plist"),
              let rootData = try? Data(contentsOf: rootURL),
              let root = try? PropertyListSerialization.propertyList(from: rootData, format: nil) as? [String: Any],
              let packages = root["packages"] as? [[String: Any]] else { return [:] }
        var result: [String: URL] = [:]
        for package in packages {
            guard let id = package["id"] as? String,
                  let infoURL = bundle.url(forResource: "info", withExtension: "plist", subdirectory: id),
                  let data = try? Data(contentsOf: infoURL),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let emoticons = info["emoticons"] as? [[String: Any]] else { continue }
            for emoticon in emoticons {
                guard let file = emoticon["png"] as? String, !file.isEmpty,
                      let url = bundle.url(forResource: file, withExtension: nil, subdirectory: id) else { continue }
                for key in ["chs", "cht"] {
                    guard let token = emoticon[key] as? String else { continue }
                    result[String(token.dropFirst().dropLast())] = url
                }
            }
        }
        return result
    }
}

private final class ImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
