# Failed media must not close readable episode content

Observed iOS Simulator flow: uncached server-source transcription completed and
imported valid SRT/analysis. Opening the full Player attempted the publisher audio
URL; HTTP 503 reached AVPlayerItemStatusFailed. That branch called close, which
cleared playingEpisode and AudioSession and emitted DidEnd. The actual Player
then lost the episode and could not display its imported text.

Actual red App E2E: app-player-before/transcript-view.json (no text, no cues),
run.log and player-runtime.log (HTTP 503) in this evidence directory.

Expected: release the failed AV resources; keep episode/session and transcript
readability; publish the concrete NSError; no DidEnd and no automatic retry.
Explicit Play uses the existing AudioSession.togglePlay reload path. Explicit
Close must continue clearing the episode/session and emitting DidEnd.

Isolation justification, recorded before test/production edits: normal simulator
UI cannot inspect KVO/time-observer removal, task cancellation, lease cleanup or
force callbacks at a deterministic cleanup boundary. The Foundation Objective-C
harness executes the actual production failed-status branch, cleanup/close and
AudioSession.togglePlay, with recording media/resource boundaries. App E2E remains
the proof that transcript content is actually readable after a failed stream.

Failure matrix:
- Failed AV item preserves selected episode and AudioSession; ready=false,
  failed=true, paused=true, and one visible update with the actual stream error.
- Player, asset, timer, all observer tokens, view, chapter verification and stream
  loader are released exactly once; terminal stream stops without new download.
- Startup failure does not overwrite saved playback position with invalid time.
- No DidEnd or automatic playback retry follows a media failure.
- Explicit togglePlay reopens the same episode with autostart; no forced new
  audio source or automatic action occurs before that user intent.
- Intentional close after failure clears episode/session/error and emits DidEnd.
- Intentional close of a loaded player still saves position, releases resources,
  clears episode/session and emits DidEnd once; repeated close is idempotent.

External explicit Play follow-up, recorded before its fix:
- Widget play/pause, player deep-link play/pause and CarPlay selection must reopen
  the retained failed episode through AudioSession, exactly once and on user intent.
- Loaded paused/playing episodes keep their existing resume/pause semantics;
  an episode still loading must not create another media request.
- CarPlay restored selections and selection of another episode keep their existing
  requested start time and presentation behavior.
Isolation rationale: the iOS App E2E reproduces the shared failed media state and
the full Player's explicit retry. macOS cannot present real iOS widgets or connect
a CarPlay head unit. Extend the existing production CarPlay behavior harness with
the actual widget/deep-link action branches and real AudioSession.togglePlay to
exercise all three entry points without copying their decision logic. No changes
to PlaybackManager.play: it also handles automatic interruption resumes.

WAV streaming follow-up, recorded before production correction:
The actual App E2E in app-player-retry-before retains readable text after HTTP503
and performs a fresh successful HTTP200 on explicit Play, but AVPlayer reports
-11828/-12847. The valid PCM16 mono16kHz fixture plays locally at 114.835875 seconds.
The complete unmodified production ICStreamingCacheLoader reproduces -11828/-12847
in native AVFoundation. A diagnostic subclass changing only audio/wav to the WAV
UTI plays the same bytes. The production MIME mapping omitted WAV while CacheManager
already recognizes audio/wav and audio/x-wav.

Focused failure matrix: both supported WAV MIME aliases must yield an actually
ready AVPlayerItem with the fixture's measured duration; the same file must be
ready locally; no altered audio bytes, fake hash, skipped validation, or alternate
playback source. Keep existing MPEG/video mappings unchanged.
Isolation rationale: the real App E2E proves this failure at the user retry path;
the native complete-loader probe isolates type metadata while retaining real HTTP,
URLSession, temporary file I/O, AVAssetResourceLoader and AVPlayer. Only Core Data
and CacheManager's path/import boundaries are replaced by a temporary fixture store.
This reliably distinguishes bad media, MIME metadata, and lifecycle behavior.

Post-import timing proof, recorded before boundary test and production correction:
The full App E2E now reproduces successful import, readable transcript through HTTP
503, explicit retry and real playback, followed by audioVerified/timingVerified
false. app-timing-before/snapshot-flow/playback-retry-view.json proves that only
WAV ctime changes; device/inode/size/mtime and the analysis snapshot remain stable.
Native complete-loader probes in the simulator container isolate the cause without
App/Player/Chapter code: BSD st_flags changes from 0 to UF_TRACKED (64), alongside
ctime, after publication. The SDK defines UF_TRACKED as document-ID tracking. The
same loader outside the container remains stable. Reading NSURLDocumentIdentifierKey
does not synchronously establish that flag, so no unsupported flag mutation or
invented import-finalization step is justified.

Required behavior: retain strict snapshot invalidation; only after previously
verified audio and unchanged verified artifacts may one new asynchronous SHA proof
restore timing. It must use the same selected episode, asset, chapter generation,
stream loader and lease, the same artifact snapshots, and a stable new audio
snapshot. Publish the new anchor only after positive hash verification. Do not
retry automatically after failed proof or authorize an unverified artifact.

Failure matrix for deterministic callback boundaries:
- Metadata-only audio snapshot change immediately removes timing permissions and
  triggers one new proof; unchanged bytes restore the original permissions.
- Real audio hash mismatch stays blocked and cannot adopt the new snapshot.
- Audio, SRT or analysis changes during hashing reject the result.
- Artifact change before revalidation does not reuse the previous proof.
- Changed episode, media asset, chapter generation, loader or lease rejects callback.
- Transcript-only proof must not accidentally authorize unverified generated chapters.
- Repeated UI reads while revalidation is pending do not start repeated hashes.
- Synchronous KVO reads during proof publication must see the new verified anchor.

Isolation justification: the real App E2E is the primary metadata-churn regression;
it cannot deterministically replace assets/files between starting SHA work and its
completion. Extend the existing Objective-C production-method runtime harness,
substituting only SHA completion and filesystem snapshot boundaries, to force
those races. Actual hashing remains covered by the existing audio-identity runtime
and full App E2E against the unchanged real fixture; do not replace production
hashing or snapshot comparisons with simulated logic.

Initial SHA completion boundary, recorded before its test/production change:
The earlier correction only revalidates a previously published proof. A metadata
change while the first SHA is pending discards even a matching result forever.
Blindly reanchoring to a second matching source would lose protection if AVAsset
had already buffered different bytes. Before allowing any retry, preserve the
original NSURLGenerationIdentifierKey from asset/source selection. Native iOS
filesystem observation confirms this opaque write-generation ID is unchanged by
system UF_TRACKED, but changes on in-place writes even before writer close and
with size/inode/mtime preserved (mtime restored with nanosecond utimensat).

Concrete isolated failure: execute production ICAudioIdentity.sha256 and real
artifactSnapshotIdentifier, hold the completion, then add a hardlink to change
only ctime. This deterministic metadata boundary represents the same invalidating
transition observed from system UF_TRACKED, without manually changing BSD flags.
Repeat SHA only if the original content generation and original artifact snapshots
remain unchanged; content writes, replaced files, missing generation, changed
artifacts, and stale playback lifecycle must remain blocked. A second unstable
snapshot must not cause an unbounded hashing loop. Original content generation
must be captured before hashing and must never adopt changed bytes.

The App E2E cannot schedule the kernel document tracker within a SHA operation;
the native container probe proves the actual UF_TRACKED behavior, while this real
hash/snapshot callback test deterministically exercises the otherwise identical
race boundary. Negative controls mutate content in place and restore exact mtime,
including changed bytes whose digest matches a different artifact revision, to
ensure the original source is never silently replaced.

Confirmed service-pause timeline regression, before manager/queue edits:
Real App E2E transcribing.png -> paused.png shows the confirmed transcription stage
regress to "not begun". Production apply first receives episode.phase=transcribing,
then replaces serverPhase with the paused presentation state when service_status is
unavailable and work is absent. No field retains the acknowledged processing phase.
Retain only a known, validated server processing phase separately, persist it across
restart, and clear it when a new request UUID is created. A same-request status
reconciliation or import retry must not invent a new phase. Unrecognized protocol
phases and invalid stored values must not be displayed as processing history.

The real UIKit regression is retained under player-text/pause-timeline-before.
Extend the existing real-manager persistence harness before production edits to
cover legacy/no-work service pause, disk restore, genuine new-request reset, known
older phase restoration, and unknown phase rejection. Those persistence boundaries
cannot be forced reliably by a single screenshot, so the focused production-method
harness complements the real renderer and App E2E evidence.
