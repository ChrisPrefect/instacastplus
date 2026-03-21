from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


source = (ROOT / "Classes" / "DirectorySearchViewController.m").read_text()

update_start = source.index("- (void) _updateSearchBarHeaderLayout")
update_end = source.index("-(void)searchBarColorUpdates", update_start)
update_block = source[update_start:update_end]

require(
    "BOOL needsHeaderReset" in update_block,
    "Add Podcast search header layout does not guard tableHeaderView resets yet.",
)
require(
    "self.tableView.tableHeaderView = searchBarContainer;" in update_block,
    "Add Podcast search header layout can no longer refresh the table header when its size changes.",
)
require(
    "static CGFloat const kDirectorySearchBarVerticalPadding = 5.0f;" in source,
    "Add Podcast search vertical padding is no longer fixed at 5px.",
)
require(
    "searchBarContainer.backgroundColor = ICBackgroundColor;" in source,
    "Add Podcast search header container is still transparent during presentation.",
)
require(
    "CGFloat verticalPadding = kDirectorySearchBarVerticalPadding;" in update_block,
    "Add Podcast search header layout is not using the shared 5px vertical padding constant.",
)

assignment_index = update_block.index("self.tableView.tableHeaderView = searchBarContainer;")
guard_window = update_block[max(0, assignment_index - 200):assignment_index]
require(
    "if (needsHeaderReset)" in guard_window,
    "Add Podcast search still resets tableHeaderView on every layout pass, which can hang the screen in a recursive layout loop.",
)
