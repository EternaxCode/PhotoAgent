import Foundation
import ImageIO
import CoreGraphics

actor ThumbnailStore {
    static let shared = ThumbnailStore()
    private var cache: [URL: CGImage] = [:]

    func thumbnail(for url: URL) -> CGImage? {
        if let cached = cache[url] { return cached }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        cache[url] = image
        return image
    }

    func clear() {
        cache.removeAll()
    }
}
