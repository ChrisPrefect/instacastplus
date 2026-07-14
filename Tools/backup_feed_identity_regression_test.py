#!/usr/bin/env python3
"""Pins one shared feed-URL identity rule across preview and actual import."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DB_H = (ROOT / "Classes" / "Model" / "DatabaseManager.h").read_text()
DB_M = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()
PREVIEW = (ROOT / "Classes" / "InstacastBackupImportViewController.m").read_text()
IMPORTER = (ROOT / "Classes" / "InstacastBackupImporter.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


for declaration in ("normalizedFeedURLStringForURLString", "equivalentFeedURLStringsForURLString"):
    require(declaration in DB_H and declaration in DB_M,
            f"DatabaseManager must expose the shared pure feed identity helper {declaration}.")

require("equivalentFeedURLStringsForURLString" in DB_M.split("- (CDFeed*) feedWithSourceURL:", 1)[1],
        "The actual subscription lookup must use the same HTTP/HTTPS and trailing-slash identity as backup analysis.")
require("[DatabaseManager normalizedFeedURLStringForURLString:" in PREVIEW and
        "[DatabaseManager equivalentFeedURLStringsForURLString:" in PREVIEW,
        "Backup preview must use the central feed identity rule rather than a private copy.")
require("[DatabaseManager equivalentFeedURLStringsForURLString:" in IMPORTER,
        "Backup episode resolution must use the central feed identity rule rather than a third heuristic.")

print("Backup feed identity regression checks passed")
