#!/usr/bin/env python3
"""Regression coverage for the executable chapter/sponsor quality gate."""

import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EVALUATOR_PATH = ROOT / "Tools" / "evaluate_chapter_gold_standard.py"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


spec = importlib.util.spec_from_file_location("chapter_gold_evaluator", EVALUATOR_PATH)
require(spec is not None and spec.loader is not None, "Could not load gold evaluator")
evaluator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evaluator)


valid_chapters = [
    {
        "startSeconds": 0,
        "endSeconds": 50,
        "title": "How the telescope finds candidates",
        "isSponsor": False,
    },
    {
        "startSeconds": 50,
        "endSeconds": 70,
        "title": "Sponsor: Acme observatory equipment",
        "isSponsor": True,
    },
    {
        "startSeconds": 70,
        "endSeconds": 100,
        "title": "Confirming the candidate with follow-up data",
        "isSponsor": False,
    },
]
require(
    evaluator.recomputed_issues(valid_chapters, 100) == [],
    "A contiguous, fully covered timeline was rejected.",
)

invalid_chapters = [
    {
        "startSeconds": 0,
        "endSeconds": 20,
        "title": "Kapitel 1",
        "isSponsor": False,
    },
    {
        "startSeconds": 25,
        "endSeconds": 60,
        "title": "Acme promotion",
        "isSponsor": "yes",
    },
    {
        "startSeconds": 55,
        "endSeconds": 110,
        "title": "Closing topic",
        "isSponsor": True,
    },
]
issues = evaluator.recomputed_issues(invalid_chapters, 100)
for expected_fragment in (
    "not meaningful",
    "gap",
    "overlap",
    "isSponsor must be a boolean",
    "outside episode duration",
    "sponsor interval is invalid",
):
    require(
        any(expected_fragment in issue for issue in issues),
        f"Structural validation missed {expected_fragment!r}: {issues}",
    )

non_numeric_issues = evaluator.recomputed_issues(
    [
        {
            "startSeconds": float("nan"),
            "endSeconds": 100,
            "title": "A real topic",
            "isSponsor": True,
        }
    ],
    100,
)
require(
    any("finite number" in issue for issue in non_numeric_issues),
    "NaN chapter boundaries were accepted.",
)
require(
    any("sponsor interval is invalid" in issue for issue in non_numeric_issues),
    "An invalid sponsor interval was not reported explicitly.",
)
require(
    evaluator.recomputed_issues([], 100) == ["no chapters"],
    "An empty result was not rejected.",
)

timeline_contract_issues = evaluator.recomputed_issues(
    [
        {
            "startSeconds": 10,
            "endSeconds": 10,
            "title": "A named topic",
            "isSponsor": False,
        },
        {
            "startSeconds": 5,
            "endSeconds": 90,
            "title": "Another named topic",
            "isSponsor": False,
        },
    ],
    100,
)
for expected_fragment in (
    "non-positive duration",
    "not strictly monotone",
    "does not start at 0",
    "does not end at episode duration",
):
    require(
        any(expected_fragment in issue for issue in timeline_contract_issues),
        f"Timeline validation missed {expected_fragment!r}: {timeline_contract_issues}",
    )


def run_gate(
    directory: Path,
    generated_chapters: list[dict],
    *,
    min_promo_precision: float,
    min_promo_recall: float,
    min_boundary_f1: float,
    min_title_token_f1: float,
) -> subprocess.CompletedProcess[str]:
    gold_path = directory / "gold.json"
    summary_path = directory / "summary.json"
    gold_path.write_text(
        json.dumps(
            {
                "episodes": [
                    {
                        "id": "quality-fixture",
                        "label": "Quality fixture",
                        "durationSeconds": 100,
                        "chapters": valid_chapters,
                    }
                ]
            }
        ),
        encoding="utf-8",
    )
    summary_path.write_text(
        json.dumps(
            {
                "results": [
                    {
                        "srt": "/tmp/quality-fixture.srt",
                        "durationSeconds": 100,
                        "chapters": generated_chapters,
                    }
                ]
            }
        ),
        encoding="utf-8",
    )
    return subprocess.run(
        [
            sys.executable,
            str(EVALUATOR_PATH),
            "--gold",
            str(gold_path),
            "--summary",
            "fixture-model",
            str(summary_path),
            "--tolerance",
            "1",
            "--min-promo-precision",
            str(min_promo_precision),
            "--min-promo-recall",
            str(min_promo_recall),
            "--min-boundary-f1",
            str(min_boundary_f1),
            "--min-title-token-f1",
            str(min_title_token_f1),
        ],
        text=True,
        capture_output=True,
        check=False,
    )


with tempfile.TemporaryDirectory() as temporary_directory:
    directory = Path(temporary_directory)
    passing = run_gate(
        directory,
        valid_chapters,
        min_promo_precision=1,
        min_promo_recall=1,
        min_boundary_f1=1,
        min_title_token_f1=1,
    )
    require(
        passing.returncode == 0,
        f"A perfect fixture failed the quality gate:\n{passing.stdout}\n{passing.stderr}",
    )

    low_quality = [
        {
            "startSeconds": 0,
            "endSeconds": 40,
            "title": "Opening subject",
            "isSponsor": False,
        },
        {
            "startSeconds": 40,
            "endSeconds": 100,
            "title": "Sponsor: overly broad generated promotion",
            "isSponsor": True,
        },
    ]
    failing = run_gate(
        directory,
        low_quality,
        min_promo_precision=0.9,
        min_promo_recall=0.9,
        min_boundary_f1=0.9,
        min_title_token_f1=0,
    )
    require(failing.returncode != 0, "Metrics below their thresholds exited successfully.")
    for metric in ("promoPrecision", "boundaryF1"):
        require(
            metric in failing.stderr,
            f"The failed gate did not identify {metric}: {failing.stderr}",
        )

    low_recall = [
        {
            "startSeconds": 0,
            "endSeconds": 50,
            "title": "Opening subject",
            "isSponsor": False,
        },
        {
            "startSeconds": 50,
            "endSeconds": 60,
            "title": "Sponsor: only half of the promotion",
            "isSponsor": True,
        },
        {
            "startSeconds": 60,
            "endSeconds": 70,
            "title": "Promotion incorrectly treated as content",
            "isSponsor": False,
        },
        {
            "startSeconds": 70,
            "endSeconds": 100,
            "title": "Closing subject",
            "isSponsor": False,
        },
    ]
    recall_failure = run_gate(
        directory,
        low_recall,
        min_promo_precision=0,
        min_promo_recall=0.9,
        min_boundary_f1=0,
        min_title_token_f1=0,
    )
    require(recall_failure.returncode != 0, "Low sponsor recall exited successfully.")
    require(
        "promoRecall" in recall_failure.stderr,
        f"The failed gate did not identify promoRecall: {recall_failure.stderr}",
    )

    structurally_invalid = run_gate(
        directory,
        invalid_chapters,
        min_promo_precision=0,
        min_promo_recall=0,
        min_boundary_f1=0,
        min_title_token_f1=0,
    )
    require(
        structurally_invalid.returncode != 0,
        "Structurally invalid chapters passed with permissive metric thresholds.",
    )
    require(
        "structural issues" in structurally_invalid.stderr,
        f"Structural gate failure was not explained: {structurally_invalid.stderr}",
    )

    irrelevant_titles = [
        {**chapter, "title": "foo"}
        for chapter in valid_chapters
    ]
    title_failure = run_gate(
        directory,
        irrelevant_titles,
        min_promo_precision=1,
        min_promo_recall=1,
        min_boundary_f1=1,
        min_title_token_f1=0.5,
    )
    require(
        title_failure.returncode != 0,
        "Irrelevant titles passed despite perfect boundaries and sponsor intervals.",
    )
    require(
        "titleTokenF1" in title_failure.stderr,
        f"The failed gate did not identify titleTokenF1: {title_failure.stderr}",
    )

    missing_thresholds = subprocess.run(
        [
            sys.executable,
            str(EVALUATOR_PATH),
            "--gold",
            str(directory / "gold.json"),
            "--summary",
            "fixture-model",
            str(directory / "summary.json"),
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    require(
        missing_thresholds.returncode != 0,
        "The evaluator can still approve a model without explicit acceptance thresholds.",
    )

print("Chapter gold-standard evaluator regression checks passed.")
