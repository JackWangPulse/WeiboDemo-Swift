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
              let enumerator = FileManager.default.enumerator(
                at: bundleURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else { return [:] }
        var result: [String: URL] = [:]
        for case let infoURL as URL in enumerator {
            guard infoURL.lastPathComponent == "info.plist" || infoURL.lastPathComponent == "info.json",
                  let info = metadata(at: infoURL),
                  let emoticons = info["emoticons"] as? [[String: Any]] else { continue }
            let directory = infoURL.deletingLastPathComponent()
            for emoticon in emoticons {
                guard let file = emoticon["png"] as? String, !file.isEmpty,
                      let url = imageURL(named: file, in: directory) else { continue }
                for key in ["chs", "cht"] {
                    guard let token = emoticon[key] as? String,
                          token.first == "[", token.last == "]", token.count > 2 else { continue }
                    result[String(token.dropFirst().dropLast())] = url
                }
            }
        }
        return result
    }

    private static func imageURL(named file: String, in directory: URL) -> URL? {
        let declared = directory.appendingPathComponent(file)
        let extensionName = declared.pathExtension
        let stem = declared.deletingPathExtension().lastPathComponent
        let candidates = [
            declared,
            directory.appendingPathComponent("\(stem)@3x").appendingPathExtension(extensionName),
            directory.appendingPathComponent("\(stem)@2x").appendingPathExtension(extensionName),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func metadata(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if url.pathExtension == "json" {
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}

private final class ImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
