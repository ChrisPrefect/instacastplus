import Foundation

enum ICWidgetConstants {
    static let appGroupID = "group.com.iteconomy.instacastplus"
    static let urlScheme  = "instacastplus"

    // JSON filenames in the shared container
    static let nowPlayingFile      = "widget_nowplaying.json"
    static let listsIndexFile      = "widget_lists.json"
    static let listEpisodesPrefix  = "widget_list_"  // + listUID + ".json"
    static let statsFile           = "widget_stats.json"
    static let settingsFile        = "widget_settings.json"
    static let listeningLogFile    = "widget_listening_log.plist"

    // Shared images subfolder
    static let imagesFolder        = "WidgetImages"

    // Widget kind identifiers
    static let nowPlayingWidgetKind     = "NowPlayingWidget"
    static let smartListWidgetKind      = "SmartListWidget"
    static let statsWidgetKind          = "StatsWidget"

    // Fallback URL (should never be needed, but prevents force-unwrap crashes)
    private static let fallbackURL = URL(string: "instacastplus://")!

    // MARK: - SF Symbol for skip buttons

    /// Returns the appropriate SF Symbol name for a skip button (e.g. "goforward.30", "gobackward.15")
    static func skipSymbolName(forward: Bool, seconds: Int) -> String {
        let prefix = forward ? "goforward" : "gobackward"
        let available = [5, 10, 15, 30, 45, 60, 75, 90]
        let closest = available.min(by: { abs($0 - seconds) < abs($1 - seconds) }) ?? 30
        return "\(prefix).\(closest)"
    }

    // MARK: - Deep link URL helpers

    static func playerURL(action: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = "player"
        if let action {
            components.queryItems = [URLQueryItem(name: "action", value: action)]
        }
        return components.url ?? fallbackURL
    }

    static func episodeURL(objectHash: String, action: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = "episode"
        components.path = "/\(objectHash)"
        if let action {
            components.queryItems = [URLQueryItem(name: "action", value: action)]
        }
        return components.url ?? fallbackURL
    }

    static func listURL(listUID: String) -> URL {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = "list"
        components.path = "/\(listUID)"
        return components.url ?? fallbackURL
    }
}
