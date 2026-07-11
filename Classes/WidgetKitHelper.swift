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
    // The app must export ONLY the data an actually-installed widget reads. We DON'T use
    // WidgetCenter.getCurrentConfigurations for this — that API decodes each widget's config
    // intent in the app process, and the SmartList config intent lives only in the widget
    // binary, so it logs ~N "Failed to instantiate SmartListConfigIntent" errors per call.
    // Instead each widget records its kind (ICWidgetConstants.recordWidgetKindInstalled) when its
    // timeline runs; we read that here. Nothing recorded yet → assume installed (first launch).
    private static let _seenKindsDefaultsKey = "ICWidgetInstalledKindsCache"  // previously-seen set, for added-detection

    private static func cachedInstalledKinds() -> Set<String>? {
        ICWidgetConstants.installedWidgetKinds()
    }

    /// Whether a specific widget kind is installed. Unknown (nothing recorded yet) → true.
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

    /// Refresh installed-widget knowledge from the widgets' self-reports. Call on launch/foreground.
    @objc public static func refreshInstalledWidgets() {
        refreshInstalledWidgets(completion: nil)
    }

    /// Same, then run `completion`. Posts installedWidgetsDidChangeNotification for kinds that
    /// newly appeared since last check (they need their snapshot exported now). Synchronous now
    /// (no async WidgetCenter round-trip), so the completion runs immediately.
    @objc public static func refreshInstalledWidgets(completion: (@Sendable () -> Void)?) {
        let current = ICWidgetConstants.installedWidgetKinds() ?? []
        let previous = Set(UserDefaults.standard.array(forKey: _seenKindsDefaultsKey) as? [String] ?? [])
        UserDefaults.standard.set(Array(current), forKey: _seenKindsDefaultsKey)
        let added = current.subtracting(previous)
        if !added.isEmpty {
            NotificationCenter.default.post(name: installedWidgetsDidChangeNotification,
                                            object: nil,
                                            userInfo: ["addedKinds": Array(added)])
        }
        completion?()
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
