// Appended to an unchanged copy of WatchPlayerController.swift by the simulator test.
// Uses the real player, manifest, timer, persistence and phone-state handler.
extension WatchPlayerController {
    static func startPositionProbe() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PositionProbe", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                let path = directory.appendingPathComponent("command.json")
                guard let data = try? Data(contentsOf: path),
                      let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                try? FileManager.default.removeItem(at: path)
                let controller = WatchPlayerController.shared
                var reply: [String: Any] = ["id": command["id"] ?? ""]
                do {
                    switch command["action"] as? String {
                    case "fixture":
                        let entry = WatchManifestEntry(episodeHash: "position-probe", selectionIdentifier: "position-probe",
                            feedIdentifier: "probe", title: "Positionsprüfung", podcastTitle: "Regression",
                            imageURL: nil, pubDate: Date(), durationHint: 4800, position: 3319, consumed: false,
                            mediaURL: URL(string: "https://example.invalid/position-probe.wav")!, selectionSource: .manual,
                            watchAddedDate: Date(), playbackOrder: 0, skipForwardSeconds: 30, skipBackwardSeconds: 30,
                            expectedFileSize: 76800044, skipChapterNames: [], autoSkipSponsors: false)
                        _ = try await WatchManifestStore.shared.applyManifest(entries: [entry])
                        try await WatchManifestStore.shared.updateEpisodeDurably(hash: entry.episodeHash) { episode in
                            episode.status = .downloaded
                            episode.localFileURL = directory.appendingPathComponent("fixture.wav")
                            episode.actualDuration = 4800
                            episode.actualFileSize = 76800044
                            episode.downloadedBytes = 76800044
                            episode.lastPlaybackPosition = 3319
                            episode.lastPlaybackDate = nil
                            episode.consumed = false
                        }
                    case "play":
                        reply["started"] = await controller.play(WatchManifestStore.shared.episode(hash: "position-probe")!)
                    case "stall":
                        // Simulate the observed OS stop without an AVAudioPlayer delegate callback.
                        controller.player?.pause()
                    case "pause": controller.pause()
                    case "flush": controller.flushPlaybackState()
                    case "phone":
                        controller.applyPhoneState([
                            "episodeHash": "position-probe", "position": command["position"] ?? 4200,
                            "timestamp": controller.dateFormatter.string(from: Date()), "consumed": false
                        ])
                    case "seek": controller.seek(to: (command["position"] as? NSNumber)?.doubleValue ?? 3319)
                    default: break
                    }
                } catch { reply["error"] = error.localizedDescription }
                let episode = WatchManifestStore.shared.episode(hash: "position-probe")
                reply["isPlaying"] = controller.isPlaying
                reply["audioPlaying"] = controller.player?.isPlaying ?? false
                reply["time"] = controller.player?.currentTime ?? 0
                reply["storedPosition"] = episode?.lastPlaybackPosition ?? -1
                reply["storedDate"] = episode?.lastPlaybackDate?.timeIntervalSince1970 ?? 0
                reply["timerValid"] = controller.timer?.isValid ?? false
                reply["activeMarker"] = UserDefaults.standard.string(forKey: controller.playbackActiveHashKey) ?? ""
                try? JSONSerialization.data(withJSONObject: reply, options: .prettyPrinted)
                    .write(to: directory.appendingPathComponent("reply.json"), options: .atomic)
            }
        }
    }
}
