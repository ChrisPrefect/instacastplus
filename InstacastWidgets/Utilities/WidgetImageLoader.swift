import UIKit
import SwiftUI

/// Loads podcast artwork images from the App Group shared container.
@MainActor
enum WidgetImageLoader {

    private static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    private static var imagesURL: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ICWidgetConstants.appGroupID
        ) else { return nil }
        return container.appendingPathComponent(ICWidgetConstants.imagesFolder)
    }

    private static func fileURL(relativePath: String) -> URL? {
        guard let imagesDir = imagesURL else { return nil }
        return imagesDir.appendingPathComponent(relativePath)
    }

    private static func cacheKey(for fileURL: URL, relativePath: String) -> NSString? {
        let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys),
              let fileSize = resourceValues.fileSize else {
            return nil
        }

        let modifiedAt = resourceValues.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(relativePath)#\(fileSize)#\(modifiedAt)" as NSString
    }

    private static func imageCost(_ image: UIImage) -> Int {
        let pixelWidth = Int(image.size.width * image.scale)
        let pixelHeight = Int(image.size.height * image.scale)
        return max(1, pixelWidth * pixelHeight * 4)
    }

    /// Load a UIImage from the shared container by relative path.
    static func loadUIImage(relativePath: String?) -> UIImage? {
        guard let relativePath, !relativePath.isEmpty,
              let fileURL = fileURL(relativePath: relativePath) else { return nil }

        let cacheKey = cacheKey(for: fileURL, relativePath: relativePath) ?? (relativePath as NSString)

        if let cachedImage = imageCache.object(forKey: cacheKey) {
            return cachedImage
        }

        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              let image = UIImage(data: data) else { return nil }

        imageCache.setObject(image, forKey: cacheKey, cost: imageCost(image))
        return image
    }

    /// Load a SwiftUI Image from the shared container.
    static func loadImage(relativePath: String?) -> Image? {
        guard let uiImage = loadUIImage(relativePath: relativePath) else { return nil }
        return Image(uiImage: uiImage)
    }
}
