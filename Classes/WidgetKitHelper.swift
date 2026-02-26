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

    private static let darwinPrefix = "com.iteconomy.instacastplus.widget."
    private static let actions = [
        "playpause", "skipforward", "skipbackward",
        "nextchapter", "prevchapter", "nextepisode", "previousepisode",
        "cyclespeed", "togglesleeptimer", "skipchapter"
    ]

    @objc public static func reloadAllTimelines() {
        if #available(iOS 14.0, *) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Start listening for Darwin notifications from widget control intents.
    /// Call this from InstacastAppDelegate.didFinishLaunchingWithOptions.
    /// Works when the app is alive in background (active audio session).
    @objc public static func startListeningForWidgetActions() {
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
