from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


episodes_source = (ROOT / "Classes" / "EpisodesTableViewController.m").read_text()
require(
    'ICEpisodeSelectionToggleTitleKey(selectedCellsCount, rowCount).ls' in episodes_source,
    "Episodes selection toggle is not wired to the shared All/None config.",
)
require(
    '"text.badge.plus"' not in episodes_source and '"text.badge.minus"' not in episodes_source,
    "Episodes swipe Play Next action still uses the old plus/minus badge symbols.",
)
require(
    'return [self _downloadStartActionImage];' in episodes_source,
    "Episodes swipe download icon is not using the shared download image.",
)
require(
    'image:[self _downloadStartActionImage]' in episodes_source,
    "Episodes context-menu download icon is not using the shared download image.",
)
require(
    '[weakSelf _togglePlayNextForEpisode:episode];' in episodes_source,
    "Episodes context-menu Play Next action is not using the shared overlay/navigation flow.",
)
require(
    'ICEpisodePlayNextOverlayDisplayDuration()' in episodes_source,
    "Episodes Play Next overlay duration is not wired to the shared 3-second config.",
)
require(
    '[button setTitle:@"Play Next".ls forState:UIControlStateNormal];' in episodes_source,
    "Episodes Play Next overlay is missing the direct navigation button.",
)
require(
    '[self _playNextActionImageForEpisode:episode configuration:config];' in episodes_source,
    "Episodes swipe Play Next action is not using the shared add/remove icon helper.",
)
require(
    '[self _playNextActionTitleForEpisode:episode].ls' in episodes_source,
    "Episodes context-menu Play Next action is still using a static Add title.",
)
require(
    '[self _playNextActionImageForEpisode:episode configuration:nil]' in episodes_source,
    "Episodes context-menu Play Next action is not using the shared add/remove icon helper.",
)
require(
    '@\"Remove from Play Next\"' in episodes_source,
    "Episodes Play Next removal title is missing.",
)
require(
    'CGFloat badgeSide = ceil(iconSide * 0.38f);' in episodes_source,
    "Episodes Play Next removal badge is not using the smaller xmark size.",
)
require(
    'CGRect badgeRect = CGRectMake(-badgeSide * 0.05f,' in episodes_source,
    "Episodes Play Next removal badge is not anchored on the left side.",
)
require(
    'baseImage.size.height - badgeSide * 0.78f' in episodes_source,
    "Episodes Play Next removal badge is not anchored at the bottom.",
)
require(
    '@\"Delete Download\".ls' in episodes_source or '@\"Delete Download\"' in episodes_source,
    "Episodes cached-download action is still not labeled as Delete Download.",
)

directory_search_source = (ROOT / "Classes" / "DirectorySearchViewController.m").read_text()
require(
    'searchBar.searchTextField.font = [UIFont systemFontOfSize:17.0f];' not in directory_search_source,
    "Add Podcast search still overrides the search field font, which inflates the header height.",
)
require(
    '- (void) _updateSearchBarHeaderLayout' in directory_search_source,
    "Add Podcast search is missing the dedicated header layout updater.",
)
require(
    'static CGFloat const kDirectorySearchBarVerticalPadding = 5.0f;' in directory_search_source,
    "Add Podcast search vertical padding is not fixed at 5px.",
)
require(
    'CGFloat verticalPadding = kDirectorySearchBarVerticalPadding;' in directory_search_source,
    "Add Podcast search header layout is not using the shared 5px padding constant.",
)
require(
    'searchBarContainer.backgroundColor = ICBackgroundColor;' in directory_search_source,
    "Add Podcast search header container is still transparent during presentation.",
)
require(
    '[self _updateSearchBarHeaderLayout];' in directory_search_source,
    "Add Podcast search header padding is not refreshed after layout.",
)

upnext_source = (ROOT / "Classes" / "UpNextTableViewController.m").read_text()
require(
    'cell.usesNativeSwipeActions = YES;' in upnext_source,
    "Up Next rows are not opting into the native swipe path.",
)
require(
    'trailingSwipeActionsConfigurationForRowAtIndexPath' in upnext_source
    and 'leadingSwipeActionsConfigurationForRowAtIndexPath' in upnext_source,
    "Up Next must use native table-view swipe actions instead of the legacy cell pan recognizer.",
)
require(
    '[self.navigationController popViewControllerAnimated:YES];' in upnext_source,
    "Up Next close action still cannot pop when the queue screen was pushed from another controller.",
)
require(
    'self.navigationController.viewControllers.firstObject == self' in upnext_source,
    "Up Next close handling is missing the modal-root navigation check.",
)
require(
    upnext_source.count('- (void) viewWillAppear:(BOOL)animated') + upnext_source.count('- (void)viewWillAppear:(BOOL)animated') == 1,
    "Up Next should only declare viewWillAppear: once.",
)
require(
    'if (self.presentedAsMainView) {\n        return;\n    }' in upnext_source,
    "Up Next main-view mode should preserve the sidebar navigation button.",
)

play_next_present_start = episodes_source.index('- (void) _presentPlayNextViewController')
play_next_present_end = episodes_source.index('- (void) _openPlayNextOverlayAction:', play_next_present_start)
play_next_present_block = episodes_source[play_next_present_start:play_next_present_end]
require(
    'pushViewController:controller animated:YES' not in play_next_present_block,
    "Play Next overlay should not push the queue onto the current navigation stack.",
)
require(
    'presentViewController:navigationController animated:YES completion:nil' in play_next_present_block,
    "Play Next overlay is not presenting the queue modally from the bottom anymore.",
)

english_strings = (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text()
require(
    '"Remove from Play Next" = "Remove from Play Next";' in english_strings,
    "English localization for Remove from Play Next is missing.",
)
require(
    '"Delete File" = "Delete Download";' in english_strings or '"Delete Download" = "Delete Download";' in english_strings,
    "English localization for Delete Download is missing.",
)

german_strings = (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text()
require(
    '"Remove from Play Next" = "Aus Abspielliste entfernen";' in german_strings,
    "German localization for Remove from Play Next is missing.",
)
require(
    '"Delete File" = "Download löschen";' in german_strings or '"Delete Download" = "Download löschen";' in german_strings,
    "German localization for Delete Download is missing.",
)

player_source = (ROOT / "Classes" / "PlayerInfoViewController_v5.m").read_text()
needle = 'cell.iconView.image = [UIImage imageNamed:@"Podcast Placeholder 56"];'
start = player_source.index(needle)
end = player_source.index('        return cell;', start)
player_upnext_block = player_source[start:end]
require(
    player_upnext_block.index('cell.objectValue = episode;') < player_upnext_block.index('[iman imageForURL'),
    "Player Up Next rows still assign objectValue after starting the artwork request.",
)
