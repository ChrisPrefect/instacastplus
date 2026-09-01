from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CORE_PATH = ROOT / "Classes" / "iOSIntegration" / "ICSharePlayCoordinator.swift"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


require(CORE_PATH.exists(), "The SharePlay coordinator source is missing.")
core = CORE_PATH.read_text()

require(
    "struct ICPodcastListeningActivity: GroupActivity, Transferable, Sendable" in core,
    "The SharePlay payload must be a transferable, sendable GroupActivity.",
)
require(
    'static let activityIdentifier = "com.iteconomy.instacastplus.listen-together"' in core,
    "The SharePlay activity needs a stable, explicit identifier.",
)
require(
    "let episodeIdentifier: String" in core
    and "let feedURL: URL" in core
    and "let episodeGUID: String?" in core
    and "let ownerToken: String" in core
    and "let playbackFinished: Bool" in core,
    "The activity must carry stable episode identity and transition ownership.",
)
require(
    "mediaURL" not in core and "audioURL" not in core and "episodeURL" not in core,
    "The SharePlay payload must not expose a podcast media URL.",
)
require(
    "metadata.type = .listenTogether" in core
    and "metadata.fallbackURL = fallbackURL" in core,
    "SharePlay metadata must describe a listen-together activity with the public fallback link.",
)

require(
    "@MainActor" in core
    and "@objcMembers" in core
    and "final class ICSharePlayCoordinator: NSObject" in core,
    "The Objective-C bridge must keep all mutable GroupSession state on the main actor.",
)
require(
    "@objc(sharedCoordinator)" in core
    and "static let shared = ICSharePlayCoordinator()" in core,
    "Objective-C needs one stable coordinator singleton.",
)
for selector_fragment in (
    "startObservingSessions",
    "redeliverPendingAppliedActivity",
    "activityItemProviderForEpisodeIdentifier:",
    "attachPlayer:episodeIdentifier:",
    "publishLocalEpisodeIdentifier:",
    "publishPlaybackFinishedForEpisodeIdentifier:",
    "acknowledgeAppliedActivityOwnerToken:",
    "isCurrentActivityOwnerToken:",
    "hasActiveSession",
    "canAdvanceAutomatically",
    "leaveSessionForLocalPlayback",
):
    require(selector_fragment in core, f"Missing Objective-C SharePlay bridge API: {selector_fragment}")

require(
    "ICSharePlayActivityDidChangeNotification" in core
    and '"episodeIdentifier"' in core
    and '"ownerToken"' in core
    and '"playbackFinished"' in core
    and '"locallyOriginated"' in core,
    "Incoming activities must be delivered with enough identity to apply and acknowledge them.",
)
require(
    "for await session in ICPodcastListeningActivity.sessions()" in core
    and "session.join()" in core
    and "session.$activity" in core
    and "session.$state" in core,
    "The coordinator must own the complete GroupSession lifecycle.",
)
require(
    "case .joined" in core and "session.activity = activity" in core,
    "Activity changes may only be published after the GroupSession has joined.",
)
require(
    "provider.registerGroupActivity(activity)" in core,
    "The UIKit share item provider must register the GroupActivity.",
)
require(
    "player.playbackCoordinator.delegate = self" in core
    and "coordinateWithSession(session)" in core
    and "identifierFor playerItem" in core,
    "Every AVPlayer must use coordinated playback with a stable item identifier delegate.",
)
require(
    "ownedActivityTokens.contains" in core
    and "pendingAppliedActivity" in core,
    "Automatic transitions need deterministic ownership and remote-apply echo suppression.",
)
require(
    "session.activity.episodeIdentifier == episodeIdentifier" in core
    and "ownedActivityTokens.contains(session.activity.ownerToken)" in core
    and "playbackFinished: true" in core,
    "Only the transition owner may publish the shared no-successor end state.",
)
require(
    "func redeliverPendingAppliedActivity()" in core
    and "guard let pendingAppliedActivity else { return }" in core,
    "A scene reconnect must be able to redeliver an unacknowledged SharePlay activity.",
)
require(
    "func isCurrentActivity(ownerToken: String) -> Bool" in core
    and "activeSession?.activity.ownerToken == ownerToken" in core,
    "Async episode resolution must be able to reject activity from an ended SharePlay session.",
)
require(
    "session.leave()" in core,
    "Local-only playback stops must leave the GroupSession before pausing.",
)

print("SharePlay/Handoff core regression checks passed.")
