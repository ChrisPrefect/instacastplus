// Appended only to the simulator test's copy of WatchEpisodeViews.swift.
// Calls production download/player/store methods; no implementation is replaced.
@MainActor
enum WatchDownloadReviewProbe {
    static func start() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DownloadReview", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                let path = directory.appendingPathComponent("command.json")
                guard let data = try? Data(contentsOf: path),
                      let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                try? FileManager.default.removeItem(at: path)
                let store = WatchManifestStore.shared
                let player = WatchPlayerController.shared
                let hash = "download-review"
                var reply: [String: Any] = ["id": command["id"] ?? ""]
                do {
                    switch command["action"] as? String {
                    case "fixture":
                        let entry = WatchManifestEntry(episodeHash: hash, selectionIdentifier: hash,
                            feedIdentifier: "review", title: "Positionsprüfung", podcastTitle: "Regression",
                            imageURL: nil, pubDate: Date(), durationHint: 180, position: 60, consumed: false,
                            mediaURL: URL(string: command["url"] as! String)!, selectionSource: .manual,
                            watchAddedDate: Date(), playbackOrder: 0, skipForwardSeconds: 30, skipBackwardSeconds: 30,
                            expectedFileSize: (command["bytes"] as! NSNumber).int64Value,
                            skipChapterNames: [], autoSkipSponsors: false)
                        try await WatchDownloadManager.shared.replaceManifest(entries: [entry], manifestRevision: nil) {}
                    case "retry": WatchDownloadManager.shared.prioritizeEpisode(hash: hash)
                    case "play": reply["started"] = await player.play(store.episode(hash: hash)!)
                    case "pause": player.pause()
                    case "seek": player.seek(to: 90)
                    case "remove": WatchDownloadManager.shared.removeEpisode(hash: hash)
                    case "ackRemoval":
                        WatchDownloadManager.shared.acknowledgeDeletedEpisodes(
                            hashes: [hash], selectionIdentifiers: [hash], selectionDates: [])
                    case "render":
                        if let episode = store.episode(hash: hash) {
                            for width in [160, 184] {
                                let row = WatchEpisodeRow(episode: episode, accentColor: .orange,
                                    playbackPosition: episode.lastPlaybackPosition, isCurrent: false)
                                    .frame(width: CGFloat(width), alignment: .leading)
                                    .padding(8)
                                    .background(Color(white: 0.13))
                                    .environment(\.colorScheme, .dark)
                                let renderer = ImageRenderer(content: row)
                                renderer.scale = 3
                                guard let image = renderer.uiImage, let png = image.pngData() else {
                                    throw NSError(domain: "Review", code: 1)
                                }
                                try png.write(to: directory.appendingPathComponent("row-\(width).png"))
                            }
                        }
                    default: break
                    }
                } catch { reply["error"] = error.localizedDescription }
                if let episode = store.episode(hash: hash) {
                    reply["episode"] = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(episode))
                    reply["fileExists"] = episode.localFileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                }
                reply["isPlaying"] = player.isPlaying
                reply["currentPosition"] = player.currentPosition
                reply["downloadedCount"] = store.downloadedEpisodeCount
                try? JSONSerialization.data(withJSONObject: reply, options: .prettyPrinted)
                    .write(to: directory.appendingPathComponent("reply.json"), options: .atomic)
            }
        }
    }
}
