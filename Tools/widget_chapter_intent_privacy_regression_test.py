from pathlib import Path
s=(Path(__file__).resolve().parents[1]/'InstacastWidgets/Intents/WidgetControlIntents.swift').read_text().split('struct SkipToChapterIntent:',1)[1]
assert 'static var isDiscoverable: Bool { false }' in s, 'Widget timeline-token carrier must not appear in Shortcuts/Siri discovery'
assert 'var chapterTimelineIdentifier: String?' in s, 'Legacy index-only intents must not prompt for an internal UUID'
print('Widget chapter intent keeps internal timeline identity out of user configuration')
