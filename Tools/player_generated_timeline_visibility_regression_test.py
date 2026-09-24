#!/usr/bin/env python3
"""All generated timestamp consumers must wait for the current audio proof."""
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
player = (ROOT / "Classes/PlayerInfoViewController_v5.m").read_text()
playback = (ROOT / "Classes/PlaybackManager.m").read_text()
assert "transcriptLoadGeneration" in player, "A superseded same-URL transcript load can replace the current cue snapshot"

def body(source, signature):
    start = source.index(signature)
    while source.find(";", start) < source.find("{", start):
        start = source.index(signature, start + len(signature))
    return source[start:source.find("\n- (", start + len(signature))]

assert "_transcriptTimingVerified" in body(player, "- (void)_transcriptTextViewTapped:"), "Transcript taps still consume unverified timestamps"
assert "_transcriptTimingVerified" in body(player, "- (void)_updateTranscriptSyncTimerState"), "Unverified timestamps still drive playback-follow highlighting"
timing = body(player, "- (BOOL)_transcriptTimingVerified")
assert "transcriptLoadedEpisodeHash" in timing and "playingEpisode.objectHash" in timing and "transcriptCues.count == 0" in timing, "Timestamp navigation requires cues for the currently playing episode"
assert '@"isGenerated"' in timing and '@"untimed"' in timing and "_transcriptDescriptorIsCurrent:" in timing, "Publisher timing and generated timing must use their respective source contracts"
descriptor = body(player, "- (BOOL)_transcriptDescriptorIsCurrent:")
assert "_generatedTranscriptMayLoadForEpisodeHash:" in descriptor and "verifiedTranscriptSnapshot" in descriptor, "Generated cue snapshots must retain their verified source identity"
generated = body(player, "- (BOOL)_generatedTranscriptMayLoadForEpisodeHash:")
assert "playingEpisode.objectHash" in generated and "generatedArtifactTimingIsCurrent" in generated and "transcriptAudioVerified" in generated and "transcriptSnapshotIdentifierFor:" in generated, "Generated transcript navigation must require the current episode, audio proof, and artifact snapshot"
footer = body(player, "- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:")
assert "_audioIdentityNotice" in footer and "_hasChapters" not in footer, "Notice must exist even without chapter rows or automatic skipping"
assert "sourceChapter" in body(player, "- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:"), "A stale displayed row may not seek a replacement chapter by index"
assert "loadGeneration != self.transcriptLoadGeneration" in body(player, "- (void)_loadTranscriptDescriptor:"), "Same-URL cache callbacks must retain load ownership"
assert "loadGeneration != self.transcriptLoadGeneration" in body(player, "- (void)_loadTranscriptDescriptorFromNetwork:"), "Same-URL network callbacks must retain load ownership"
assert "srtURLFor:episodeHash" in body(player, "- (NSData*)_cachedTranscriptDataForEpisodeHash:"), "Generated SRT must be read from its current atomic source, not an older URL cache"
load = body(playback, "- (void) _startLoadingChapters")
assert "self.pendingGeneratedChapters = metaChapters;" in load and "chapters = metaChapters;" not in load
assert "containsObject:chapter" in body(playback, "- (void) seekToChapter:"), "Detached chapter objects must not initiate seeks"
print("Generated timeline visibility and transcript navigation guards passed.")
