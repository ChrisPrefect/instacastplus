from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
    next_method = source.find("\n- (", start + 1)
    return source[start:] if next_method == -1 else source[start:next_method]


source = (ROOT / "Classes" / "PlayerInfoViewController_v5.m").read_text()

observing = method_body(source, "- (void) _setObserving:(BOOL)observing")
update_visible_cells = method_body(source, "- (void) _updateVisibleCells")

require(
    '[audioSession addTaskObserver:self forKeyPath:@"playlist"' in observing
    and '[audioSession removeTaskObserver:self forKeyPath:@"playlist"]' in observing,
    "PlayerInfoViewController_v5 must observe AudioSession.playlist so automatic Up Next removals refresh the embedded Up Next section before stale rows are reused.",
)
require(
    "cellForRowAtIndexPath:" not in update_visible_cells,
    "Playback time/chapter updates must not ask UITableView to materialize cells; stale Up Next index paths can re-enter cell/height creation after the playlist shrinks.",
)
require(
    "self.tableView.visibleCells" in update_visible_cells
    and "indexPathForCell:" in update_visible_cells,
    "Visible chapter progress updates should inspect already-materialized cells and derive their index paths from those cells.",
)
