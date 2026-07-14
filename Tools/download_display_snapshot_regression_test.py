#!/usr/bin/env python3
"""Pins the Downloads table to one stable combined episode snapshot per reload."""

from pathlib import Path


SOURCE = (Path(__file__).resolve().parents[1] / "Classes" / "DownloadsViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = SOURCE.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


require("@property (nonatomic, copy) NSArray<CDEpisode*>* displayEpisodes;" in SOURCE,
        "Downloads needs a stable display snapshot instead of rebuilding two full arrays per row query.")
rebuild = body("- (void) _rebuildDisplayEpisodes")
require(rebuild.count("cachingEpisodes") == 1 and rebuild.count("failedDownloadEpisodes") == 1,
        "Only the central snapshot rebuild may copy and combine active and failed download arrays.")

for signature in (
    "- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:",
    "- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:",
    "- (CGFloat)tableView:(UITableView*)tableView heightForRowAtIndexPath:",
    "- (void) _loadImagesForOnscreenRows",
):
    method = body(signature)
    require("self.displayEpisodes" in method and "_displayEpisodes" not in method and
            "cachingEpisodes" not in method and "failedDownloadEpisodes" not in method,
            f"{signature} must read the O(1) snapshot and never rebuild full download arrays.")

view_will_appear = body("- (void)viewWillAppear:")
require(view_will_appear.find("_rebuildDisplayEpisodes") < view_will_appear.find("reloadData"),
        "The initial Downloads reload must publish a fresh snapshot first.")
require(SOURCE.count("_rebuildDisplayEpisodes") >= 4,
        "Active, failed, terminal, and initial state changes must refresh the snapshot before table reloads.")

print("Download display-snapshot regression checks passed")
