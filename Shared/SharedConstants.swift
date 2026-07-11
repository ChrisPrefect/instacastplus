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

    // App Group UserDefaults key: the podcast+filter combos SmartList widgets are configured to
    // show. Written by the widget provider, read by the app's exporter (on-demand export).
    static let requestedPodcastKeysDefaultsKey = "ICWidgetRequestedPodcastKeys"

    // App Group UserDefaults key: the LIST uids SmartList widgets are configured to show. The app
    // only exports/reloads episode data for these lists — a list no widget shows costs nothing.
    static let displayedListUIDsDefaultsKey = "ICWidgetDisplayedListUIDs"

    // App Group UserDefaults key: {widgetKind: lastSeenUnixTime}. Each widget records itself here
    // when its timeline runs, so the app knows which widget kinds are installed WITHOUT calling
    // WidgetCenter.getCurrentConfigurations — which would try to decode the widget-only config
    // intent in the app process and log ~N failures per call.
    static let widgetKindLastSeenDefaultsKey = "ICWidgetKindLastSeen"

    /// Widget side: record that a widget of this kind is present (called from its timeline).
    static func recordWidgetKindInstalled(_ kind: String) {
        guard let d = UserDefaults(suiteName: appGroupID) else { return }
        var m = (d.dictionary(forKey: widgetKindLastSeenDefaultsKey) as? [String: Double]) ?? [:]
        m[kind] = Date().timeIntervalSince1970
        d.set(m, forKey: widgetKindLastSeenDefaultsKey)
    }

    /// App side: kinds seen within `seconds` (widgets refresh well inside a day). Returns nil when
    /// nothing has ever been recorded, so the caller can fall back to "assume installed".
    static func installedWidgetKinds(within seconds: TimeInterval = 24 * 3600) -> Set<String>? {
        guard let d = UserDefaults(suiteName: appGroupID),
              let m = d.dictionary(forKey: widgetKindLastSeenDefaultsKey) as? [String: Double] else { return nil }
        let cutoff = Date().timeIntervalSince1970 - seconds
        return Set(m.filter { $0.value >= cutoff }.keys)
    }

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

    /// Deep link a widget shows when it has no exported data yet. Opening it launches the app,
    /// which immediately (re-)exports all installed widgets' snapshots.
    static let refreshWidgetsHost = "refresh-widgets"
    static func refreshWidgetsURL() -> URL {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = refreshWidgetsHost
        return components.url ?? fallbackURL
    }
}
