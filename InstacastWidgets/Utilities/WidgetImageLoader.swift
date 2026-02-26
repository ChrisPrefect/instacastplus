import UIKit
import SwiftUI

/// Loads podcast artwork images from the App Group shared container.
enum WidgetImageLoader {

    private static var imagesURL: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ICWidgetConstants.appGroupID
        ) else { return nil }
        return container.appendingPathComponent(ICWidgetConstants.imagesFolder)
    }

    /// Load a UIImage from the shared container by relative path.
    static func loadUIImage(relativePath: String?) -> UIImage? {
        guard let relativePath, !relativePath.isEmpty,
              let imagesDir = imagesURL else { return nil }
        let fileURL = imagesDir.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return UIImage(data: data)
    }

    /// Load a SwiftUI Image from the shared container.
    static func loadImage(relativePath: String?) -> Image? {
        guard let uiImage = loadUIImage(relativePath: relativePath) else { return nil }
        return Image(uiImage: uiImage)
    }
}
