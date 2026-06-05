from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "MediaFilesViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
    next_method = source.find("\n- (", start + 1)
    return source[start:] if next_method == -1 else source[start:next_method]


is_podcast_mode = method_body(SOURCE, "- (BOOL)_isPodcastMode")
delete_all_section = method_body(SOURCE, "- (NSInteger)_deleteAllButtonSection")
is_episode_section = method_body(SOURCE, "- (BOOL)_isEpisodeSection:(NSInteger)section")
number_of_sections = method_body(SOURCE, "- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView")
rows_in_section = method_body(SOURCE, "- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section")
cell_for_row = method_body(SOURCE, "- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath")
can_edit = method_body(SOURCE, "- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath")
commit_delete = method_body(SOURCE, "- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath")


require(
    "return (self.sortMode == kSortByPodcast);" in is_podcast_mode
    and "podcastSections.count > 0" not in is_podcast_mode,
    "Downloaded Files podcast mode must not depend on podcastSections.count; deleting the last podcast download otherwise changes the table's section model mid-delete.",
)

require(
    "MAX((NSInteger)self.podcastSections.count, 1)" in delete_all_section,
    "Downloaded Files podcast mode must keep a stable placeholder section before the delete-content section when the last podcast section is removed.",
)

require(
    "section < (NSInteger)self.podcastSections.count" in is_episode_section
    and "return section == 0;" in is_episode_section,
    "Only real podcast sections may be editable episode sections; the empty podcast placeholder must not be deletable.",
)

require(
    "MAX((NSInteger)self.podcastSections.count, 1) + 1" in number_of_sections,
    "Downloaded Files podcast mode must keep the same two-section shape when the last podcast's downloads are deleted.",
)

require(
    "self.podcastSections.count == 0 && section == 0" in rows_in_section
    and "return 1;" in rows_in_section,
    "Downloaded Files podcast mode needs a one-row empty placeholder section after the last podcast download is deleted.",
)

require(
    "self.podcastSections.count == 0 && indexPath.section == 0" in cell_for_row
    and "Nothing downloaded yet." in cell_for_row,
    "Downloaded Files podcast mode must render the empty placeholder without falling back to flat mode.",
)

require(
    "return (indexPath.section < (NSInteger)self.podcastSections.count);" in can_edit,
    "The empty podcast placeholder must not expose a delete control.",
)

require(
    "[self _reloadContent];" in commit_delete
    and "[self.tableView reloadData];" in commit_delete,
    "The delete path should still refresh from CacheManager after removing cached files.",
)
