#!/usr/bin/env python3
"""Check the shared episode-link contract and durable chapter preference wiring."""
from pathlib import Path
import json
import plistlib
ROOT = Path(__file__).resolve().parents[1]
def read(path): return (ROOT / path).read_text()
share = read('Classes/ICShareItem.m')
for token in ['https://instacast.ch/share/episode', 'queryItemWithName:@"url"', 'queryItemWithName:@"guid"', 'square.and.arrow.up', 'activityItemProviderForEpisodeIdentifier:', 'popoverPresentationController.sourceView', 'popoverPresentationController.sourceRect']:
    assert token in share, token
for filename in ['EpisodesTableViewController.m','UpNextTableViewController.m','AppleWatchEpisodesViewController.m']:
    assert 'shareActionForEpisode:episode' in read('Classes/' + filename), filename
assert 'activityViewControllerForEpisode:self.episode' in read('Classes/EpisodeViewController.m')
aasa = json.loads(read('Server/well-known/apple-app-site-association'))
assert any(c['/'] == '/share/episode' for c in aasa['applinks']['details'][0]['components'])
assert 'https://apps.apple.com/app/id6472283494' in read('Server/share/index.html')
scene = read('Classes/InstacastSceneDelegate.m').split('// episode share link:',1)[1].split('self.feedView =',1)[0]
for token in ['[ep.guid isEqualToString:episodeGUID]', 'playbackViewControllerWithEpisode:persistentEpisode', 'autostart:YES']:
    assert token in scene, token
assert plistlib.loads((ROOT / 'Resources/Defaults.plist').read_bytes())['RememberChapterPosition'] is True
settings = read('Classes/PlaybackSettingsViewController.m')
for key in ['Remember Chapter Position','Remember Chapter Position Explanation','Replay after Pause Explanation']:
    assert '@"' + key + '".ls' in settings, key
    for lang in ['de','en']:
        assert '"' + key + '" =' in read(f'Resources/{lang}.lproj/Localizable.strings'), (lang,key)
assert 'setBool:sender.on forKey:PlayerRememberChapterPosition' in settings
export = read('Classes/ImportExportSettingsViewController.m')
restore = read('Classes/InstacastBackupImporter.m')
for key in ['rememberChapterPosition','chapterPlaybackPositions']:
    assert key in export and key in restore, key
assert 'dataWithJSONObject:chapterPositions' in export
assert 'setObject:positions forKey:PlayerChapterPlaybackPositions' in restore
player = read('Classes/PlayerInfoViewController_v5.m')
assert player.count('timeForChapterSelectionAtIndex:indexPath.row') == 2, 'Loaded feed chapters and cold player must both resume'
assert '@"untimed": @YES' in player.split('static NSArray<NSDictionary*>* ICTranscriptParsePlainText',1)[1].split('static BOOL',1)[0]
print('Episode sharing, chapter settings, backup, and localization checks passed')
