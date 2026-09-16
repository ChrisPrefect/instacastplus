#!/usr/bin/env python3
"""Isolated chapter comparison against publisher chapters; never submits a queue job.

Run on the transcription host with its DB environment loaded (settings are read only):
  .venv/bin/python tools/ios27_chapter_comparison.py SERVER_ROOT EPISODE_DIR OUTPUT_DIR
The output input.json is also the input for ios27_local_chapter_benchmark.swift.
"""
import hashlib
import json
import sys
import time
from pathlib import Path
from unittest.mock import patch


def main():
    root, episode, output = map(Path, sys.argv[1:])
    output.mkdir(parents=True, exist_ok=True)
    assert not (output / "server.json").exists(), "Choose a new output directory for a new run"
    groups_bytes = (episode / "transcript-readable.json").read_bytes()
    groups = json.loads(groups_bytes)
    reference_bytes = (episode / "chapters-original.json").read_bytes()
    reference = json.loads(reference_bytes)
    assert reference["chapters"], "Publisher chapters are required; generated chapters are not a reference"
    summary = json.loads((episode / "summary.json").read_text())
    duration = max(float(g["end"]) for g in groups)
    sys.path.insert(0, str(root))
    from app import worker
    from app.codex_provider import generate_json, provider_readiness

    # Capture the production prompt builder, with no publisher chapters or sponsor hints.
    # The inference adapter below records its usage here instead of writing production DB rows.
    with patch.object(worker, "call_ai_json") as capture:
        worker.make_ai_chapter_analysis({"id": None, "title": summary["episode_title"]},
                                        groups, duration, [], publisher_chapters=[])
    _, _, prompt, instructions = capture.call_args.args
    inputs = {"title": summary["episode_title"], "duration": duration,
              "transcript_sha256": hashlib.sha256(groups_bytes).hexdigest(),
              "reference_sha256": hashlib.sha256(reference_bytes).hexdigest(),
              "prompt": prompt, "instructions": instructions, "groups": groups}
    (output / "input.json").write_text(json.dumps(inputs, ensure_ascii=False, indent=2) + "\n")
    (output / "reference.json").write_bytes(reference_bytes)
    settings = worker.get_ai_settings()
    assert settings["provider"] == "openai_codex", "This comparison expects the configured Codex server provider"
    model = settings["kimi_model"]
    provider_readiness(model=model, catalog_path=settings["codex_catalog_path"])
    start = time.monotonic()
    result = generate_json(prompt, instructions, model=model, catalog_path=settings["codex_catalog_path"])
    result.update(elapsed_seconds=time.monotonic() - start, model=model,
                  chapters=worker.normalize_ai_topic_chapters(result["payload"], groups, duration),
                  transcript_sha256=inputs["transcript_sha256"])
    (output / "server.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({key: result[key] for key in ["model", "elapsed_seconds", "input_tokens", "output_tokens", "chapters"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
