import Combine
import Foundation

@MainActor
final class WatchEpisodeRowState: ObservableObject, Identifiable {
    let id: String
    @Published private(set) var episode: WatchEpisode

    init(episode: WatchEpisode) {
        id = episode.episodeHash
        self.episode = episode
    }

    func update(_ updatedEpisode: WatchEpisode) {
        guard updatedEpisode != episode else { return }
        episode = updatedEpisode
    }
}

@MainActor
final class WatchEpisodeCollectionState: ObservableObject {
    @Published private(set) var structuralRevision: UInt64 = 0
    private(set) var episodes: [WatchEpisode] = []
    private var rowStateByHash: [String: WatchEpisodeRowState] = [:]

    func replace(with updatedEpisodes: [WatchEpisode]) {
        episodes = updatedEpisodes
        synchronizeRowStates()
        structuralRevision &+= 1
    }

    func updateRuntimeEpisode(at index: Int, with updatedEpisode: WatchEpisode) {
        episodes[index] = updatedEpisode
        updateRowState(with: updatedEpisode)
    }

    func updateStructuralEpisode(at index: Int, with updatedEpisode: WatchEpisode) {
        let previousHash = episodes[index].episodeHash
        episodes[index] = updatedEpisode
        if previousHash == updatedEpisode.episodeHash {
            updateRowState(with: updatedEpisode)
        } else {
            synchronizeRowStates()
        }
        structuralRevision &+= 1
    }

    func updateStructuralEpisodes(
        _ updates: [(index: Int, episode: WatchEpisode)]
    ) {
        guard !updates.isEmpty else { return }
        var membershipChanged = false
        for update in updates {
            membershipChanged = membershipChanged ||
                episodes[update.index].episodeHash != update.episode.episodeHash
            episodes[update.index] = update.episode
            if !membershipChanged {
                updateRowState(with: update.episode)
            }
        }
        if membershipChanged {
            synchronizeRowStates()
        }
        structuralRevision &+= 1
    }

    private func updateRowState(with updatedEpisode: WatchEpisode) {
        if let rowState = rowStateByHash[updatedEpisode.episodeHash] {
            rowState.update(updatedEpisode)
        } else {
            rowStateByHash[updatedEpisode.episodeHash] = WatchEpisodeRowState(
                episode: updatedEpisode
            )
        }
    }

    func rowState(forEpisodeHash episodeHash: String) -> WatchEpisodeRowState? {
        rowStateByHash[episodeHash]
    }

    func rowStates(in orderedEpisodes: [WatchEpisode]) -> [WatchEpisodeRowState] {
        orderedEpisodes.compactMap { rowStateByHash[$0.episodeHash] }
    }

    private func synchronizeRowStates() {
        var synchronizedStates: [String: WatchEpisodeRowState] = [:]
        synchronizedStates.reserveCapacity(episodes.count)
        for episode in episodes where synchronizedStates[episode.episodeHash] == nil {
            if let rowState = rowStateByHash[episode.episodeHash] {
                rowState.update(episode)
                synchronizedStates[episode.episodeHash] = rowState
            } else {
                synchronizedStates[episode.episodeHash] = WatchEpisodeRowState(episode: episode)
            }
        }
        rowStateByHash = synchronizedStates
    }
}
