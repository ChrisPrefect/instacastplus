//
//  WidgetKitHelper.swift
//  Instacast
//
//  Bridges WidgetCenter (pure Swift class) to Objective-C.
//  Also listens for Darwin notifications from widget AppIntents for playback control.
//

import Foundation
@preconcurrency import WidgetKit

@objc public final class WidgetKitHelper: NSObject {

    /// Notification posted when a widget control action is received via Darwin notification.
    /// The userInfo contains "action" key with the action string.
    @objc public static let controlActionNotification = NSNotification.Name("WidgetControlActionNotification")

    /// Posted when the set of installed widget kinds changes (a widget was added/removed).
    /// The exporter listens and populates snapshots for any newly-installed kind so a freshly
    /// added widget fills as soon as the app next runs (WidgetKit never wakes the app itself
    /// for a Core Data export). userInfo["addedKinds"] = [String].
    @objc public static let installedWidgetsDidChangeNotification = NSNotification.Name("ICWidgetInstalledKindsDidChange")

    private static let darwinPrefix = "com.iteconomy.instacastplus.widget."
    private static let actions = [
        "playpause", "skipforward", "skipbackward",
        "nextchapter", "prevchapter", "nextepisode", "previousepisode",
        "cyclespeed", "togglesleeptimer", "skipchapter"
    ]

    // Throttle: each kind can reload at most once per 2 seconds.
    // Prevents startup cascades (Core Data changes, feed refreshes, etc.) from spamming WidgetKit.
    private nonisolated(unsafe) static var _lastReloadAll: Date?
    private nonisolated(unsafe) static var _lastReloadNowPlaying: Date?
    private nonisolated(unsafe) static var _lastReloadLists: Date?
    private nonisolated(unsafe) static var _lastReloadStats: Date?
    private static let _minInterval: TimeInterval = 2.0

    // MARK: - Installed-widget gate (per kind)
    //
    // The app must export ONLY the data an actually-installed widget reads. A user with just
    // the NowPlaying (last-played) widget must never trigger the expensive lists export, etc.
    // `getCurrentConfigurations` is async, so we cache the installed widget kinds (persisted
    // across launches) and answer synchronously from ObjC. Unknown (never probed) → assume
    // installed, so the very first launch still populates before the first probe returns.
    private nonisolated(unsafe) static var _installedKinds: Set<String>? = nil
    private static let _installedKindsDefaultsKey = "ICWidgetInstalledKindsCache"

    private static func cachedInstalledKinds() -> Set<String>? {
        if let kinds = _installedKinds { return kinds }
        if let saved = UserDefaults.standard.array(forKey: _installedKindsDefaultsKey) as? [String] {
            return Set(saved)
        }
        return nil // never probed
    }

    /// Whether a specific widget kind is installed. Unknown → true (allow first populate).
    @objc public static func isWidgetKindInstalled(_ kind: String) -> Bool {
        guard let kinds = cachedInstalledKinds() else { return true }
        return kinds.contains(kind)
    }

    /// Any widget at all installed? Unknown → true.
    @objc public static var hasInstalledWidgets: Bool {
        guard let kinds = cachedInstalledKinds() else { return true }
        return !kinds.isEmpty
    }

    // ObjC-friendly per-kind accessors (avoid passing the Swift constant across the bridge).
    @objc public static var isNowPlayingWidgetInstalled: Bool { isWidgetKindInstalled(ICWidgetConstants.nowPlayingWidgetKind) }
    @objc public static var isSmartListWidgetInstalled: Bool { isWidgetKindInstalled(ICWidgetConstants.smartListWidgetKind) }
    @objc public static var isStatsWidgetInstalled: Bool { isWidgetKindInstalled(ICWidgetConstants.statsWidgetKind) }

    /// Refresh the cached installed-widget kinds. Call on launch and foreground.
    @objc public static func refreshInstalledWidgets() {
        if #available(iOS 14.0, *) {
            if ProcessInfo.processInfo.isiOSAppOnMac {
                _installedKinds = []
                UserDefaults.standard.set([String](), forKey: _installedKindsDefaultsKey)
                return
            }
            let previous = cachedInstalledKinds()
            WidgetCenter.shared.getCurrentConfigurations { result in
                if case .success(let configs) = result {
                    let kinds = Set(configs.map { $0.kind })
                    _installedKinds = kinds
                    UserDefaults.standard.set(Array(kinds), forKey: _installedKindsDefaultsKey)
                    // A newly-installed kind needs its snapshot populated now (the app won't be
                    // woken by WidgetKit for it). Notify the exporter with the added kinds.
                    let added = previous == nil ? kinds : kinds.subtracting(previous!)
                    if !added.isEmpty {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(
                                name: installedWidgetsDidChangeNotification,
                                object: nil,
                                userInfo: ["addedKinds": Array(added)]
                            )
                        }
                    }
                }
                // .failure: keep the previous cached value.
            }
        } else {
            _installedKinds = []
        }
    }

    /// Key in the App Group UserDefaults where SmartList widgets record the podcast+filter
    /// combos they are configured to show. The app exports episode data ONLY for these, so a
    /// podcast the user never selected costs nothing. Written by the widget provider (which
    /// knows its own config), read by WidgetDataExporter. Mirrors ICWidgetConstants.
    @objc public static let requestedPodcastKeysDefaultsKey = ICWidgetConstants.requestedPodcastKeysDefaultsKey

    @objc public static func reloadAllTimelines() {
        if #available(iOS 14.0, *) {
            if ProcessInfo.processInfo.isiOSAppOnMac { return }
            let now = Date()
            if let last = _lastReloadAll, now.timeIntervalSince(last) < _minInterval { return }
            _lastReloadAll = now
            _lastReloadNowPlaying = now
            _lastReloadLists = now
            _lastReloadStats = now
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Reload only the NowPlaying widget timeline — preserves budget for other widgets.
    @objc public static func reloadNowPlayingTimeline() {
        if #available(iOS 14.0, *) {
            if ProcessInfo.processInfo.isiOSAppOnMac { return }
            let now = Date()
            if let last = _lastReloadNowPlaying, now.timeIntervalSince(last) < _minInterval { return }
            _lastReloadNowPlaying = now
            WidgetCenter.shared.reloadTimelines(ofKind: ICWidgetConstants.nowPlayingWidgetKind)
        }
    }

    /// Reload only the SmartList widget timeline.
    @objc public static func reloadListsTimeline() {
        if #available(iOS 14.0, *) {
            if ProcessInfo.processInfo.isiOSAppOnMac { return }
            let now = Date()
            if let last = _lastReloadLists, now.timeIntervalSince(last) < _minInterval { return }
            _lastReloadLists = now
            WidgetCenter.shared.reloadTimelines(ofKind: ICWidgetConstants.smartListWidgetKind)
        }
    }

    /// Reload only the Stats widget timeline.
    @objc public static func reloadStatsTimeline() {
        if #available(iOS 14.0, *) {
            if ProcessInfo.processInfo.isiOSAppOnMac { return }
            let now = Date()
            if let last = _lastReloadStats, now.timeIntervalSince(last) < _minInterval { return }
            _lastReloadStats = now
            WidgetCenter.shared.reloadTimelines(ofKind: ICWidgetConstants.statsWidgetKind)
        }
    }

    /// Start listening for Darwin notifications from widget control intents.
    /// Call this from InstacastAppDelegate.didFinishLaunchingWithOptions.
    /// Works when the app is alive in background (active audio session).
    @objc public static func startListeningForWidgetActions() {
        // iOS widgets don't work on macOS ("Designed for iPad") — skip.
        if #available(iOS 14.0, *), ProcessInfo.processInfo.isiOSAppOnMac { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for action in actions {
            let name = CFNotificationName((darwinPrefix + action) as CFString)
            CFNotificationCenterAddObserver(
                center,
                nil,
                { (_, _, cfName, _, _) in
                    guard let cfName else { return }
                    let fullName = cfName.rawValue as String
                    guard fullName.hasPrefix(WidgetKitHelper.darwinPrefix) else { return }
                    let action = String(fullName.dropFirst(WidgetKitHelper.darwinPrefix.count))
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: WidgetKitHelper.controlActionNotification,
                            object: nil,
                            userInfo: ["action": action]
                        )
                    }
                },
                name.rawValue,
                nil,
                .deliverImmediately
            )
        }
    }
}
