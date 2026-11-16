#!/usr/bin/env python3
"""Compare CloudKit sources with the locally reviewed schema snapshot, offline."""

import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re


def source_fingerprints(root):
    result = {}
    for directory in (
        "Classes", "Shared", "VemedioDatabase", "VemedioKit",
        "InstacastWatch", "InstacastWidgets", "InstacastWatchWidgets", "Submodules",
    ):
        for path in (root / directory).rglob("*"):
            if not path.is_file() or path.suffix not in {".swift", ".m", ".mm", ".h"}:
                continue
            data = path.read_bytes()
            if re.search(rb"\b(?:CKRecord|CKQuery|RecordKind)\b", data):
                result[str(path.relative_to(root))] = hashlib.sha256(data).hexdigest()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument(
        "--record-reviewed-sources", action="store_true",
        help="Record source fingerprints after reviewing that the schema is unchanged.",
    )
    args = parser.parse_args()
    root = args.root.resolve()
    directory = root / "Tools/CloudKit"
    baseline_path = directory / "source-baseline.json"
    baseline = json.loads(baseline_path.read_text())
    schema_hash = hashlib.sha256((directory / "production-schema.ckdb").read_bytes()).hexdigest()
    if schema_hash != baseline["schema_sha256"]:
        print("CloudKit-Schema-Snapshot wurde seit der letzten Prüfung verändert.")
        return 1

    current = source_fingerprints(root)
    if not current:
        print("Keine CloudKit-Quellen gefunden; lokalen Vergleich prüfen.")
        return 1
    if args.record_reviewed_sources:
        baseline["source_files"] = current
        baseline["source_reviewed_at"] = datetime.date.today().isoformat()
        baseline_path.write_text(json.dumps(baseline, indent=2, sort_keys=True) + "\n")
        print(f"Lokale Schema-Prüfung für {len(current)} Quelldateien gespeichert.")
        return 0

    previous = baseline["source_files"]
    changed = sorted(path for path in previous.keys() | current.keys()
                     if previous.get(path) != current.get(path))
    if changed:
        print("CloudKit-Quellen lokal geändert; Schema-Auswirkungen prüfen:")
        for path in changed:
            print(f"  {path}")
        return 1
    print(f"CloudKit lokal unverändert: {len(current)} Quelldateien, "
          f"gespeicherter Schema-Stand {baseline['schema_verified_at']}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
