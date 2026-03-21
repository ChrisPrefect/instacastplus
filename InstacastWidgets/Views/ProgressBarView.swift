import SwiftUI

/// Simple static progress bar for widgets.
struct ProgressBarView: View {
    let progress: Double
    var tintColor: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.gray.opacity(0.2))

                RoundedRectangle(cornerRadius: 1.5)
                    .fill(tintColor)
                    .frame(width: geo.size.width * min(max(progress, 0), 1))
            }
        }
    }
}

// MARK: - Color from hex string

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgbValue: UInt64 = 0
        scanner.scanHexInt64(&rgbValue)
        self.init(
            red: Double((rgbValue >> 16) & 0xFF) / 255.0,
            green: Double((rgbValue >> 8) & 0xFF) / 255.0,
            blue: Double(rgbValue & 0xFF) / 255.0
        )
    }
}

// MARK: - Accent color from widget settings

@MainActor
enum WidgetAccentColor {
    /// Default Instacast orange #FF5300
    static let defaultHex = "#FF5300"
    private static var cachedColor = Color(hex: defaultHex)
    private static var cachedSettingsDate: Date?

    static var color: Color {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ICWidgetConstants.appGroupID
        ) else {
            return cachedColor
        }

        let fileURL = container.appendingPathComponent(ICWidgetConstants.settingsFile)
        let modifiedAt = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if cachedSettingsDate != modifiedAt {
            cachedSettingsDate = modifiedAt
            let hex = SharedContainerReader.readSettings()?.accentColorHex ?? defaultHex
            cachedColor = Color(hex: hex)
        }
        return cachedColor
    }
}
