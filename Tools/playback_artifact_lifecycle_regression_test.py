from pathlib import Path
import unittest
R=Path(__file__).resolve().parents[1]
class Lifecycle(unittest.TestCase):
 def test_source_proof_rechecks_snapshot(self):
  s=(R/'Classes/ChapterGenerator.swift').read_text(); self.assertIn('expectedTranscriptSnapshot == TranscriptionEngine.shared.transcriptSnapshotIdentifier',s)
 def test_cue_snapshot_not_just_episode(self):
  s=(R/'Classes/PlayerInfoViewController_v5.m').read_text(); self.assertIn('transcriptSnapshot',s); self.assertIn('_transcriptDescriptorIsCurrent:',s)
 def test_persisted_intervals(self):
  s=(R/'Classes/ChapterGenerator.swift').read_text(); b=s[s.index('@objc func loadChapters(for'):s.index('@objc(verifyPlaybackAudio')]; self.assertIn('validatePersistedChapterIntervals',b)
 def test_widget_action_identity(self):
  s=(R/'Classes/WidgetDataExporter.m').read_text(); self.assertIn('chapterTimelineIdentifier:timelineIdentifier',s)
  s=(R/'InstacastWidgets/Intents/WidgetControlIntents.swift').read_text(); self.assertIn('chapterTimelineIdentifier',s)
 def test_checkpoint_ranges(self):
  s=(R/'Classes/TranscriptionEngine.swift').read_text(); self.assertIn('candidate.isValid(forDuration: totalDuration)',s)
if __name__=='__main__':unittest.main()
