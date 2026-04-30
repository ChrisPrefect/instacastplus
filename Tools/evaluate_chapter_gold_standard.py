#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


DEFAULT_SUMMARIES = [
    (
        "qwen3-4b-instruct-2507",
        "/tmp/instacast-chapter-bench-results/qwen3-4b-instruct-2507-starts5-all/summary.json",
    ),
    (
        "gemma-4-e2b",
        "/tmp/instacast-chapter-bench-results/gemma-4-e2b-starts5-all/summary.json",
    ),
]


def load_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def episode_id_from_result(result):
    return Path(result.get("srt", "")).stem


def boundaries(chapters):
    return [int(chapter["startSeconds"]) for chapter in chapters[1:]]


def intervals(chapters, key):
    return [
        (int(chapter["startSeconds"]), int(chapter["endSeconds"]))
        for chapter in chapters
        if chapter.get(key) and int(chapter["endSeconds"]) > int(chapter["startSeconds"])
    ]


def total_duration(intervals_):
    return sum(end - start for start, end in intervals_)


def overlap_duration(left, right):
    total = 0
    for a_start, a_end in left:
        for b_start, b_end in right:
            total += max(0, min(a_end, b_end) - max(a_start, b_start))
    return total


def safe_ratio(numerator, denominator):
    if denominator == 0:
        return 1.0 if numerator == 0 else 0.0
    return numerator / denominator


def recomputed_issues(chapters, duration):
    return []


def match_boundaries(gold, generated, tolerance):
    gold_boundaries = boundaries(gold)
    generated_boundaries = boundaries(generated)
    unmatched_gold = set(range(len(gold_boundaries)))
    matches = []
    for generated_index, generated_start in enumerate(generated_boundaries):
        candidates = [
            (abs(generated_start - gold_boundaries[gold_index]), gold_index)
            for gold_index in unmatched_gold
            if abs(generated_start - gold_boundaries[gold_index]) <= tolerance
        ]
        if not candidates:
            continue
        error, gold_index = min(candidates)
        unmatched_gold.remove(gold_index)
        matches.append(
            {
                "generatedIndex": generated_index,
                "generatedStart": generated_start,
                "goldIndex": gold_index,
                "goldStart": gold_boundaries[gold_index],
                "errorSeconds": error,
            }
        )
    precision = safe_ratio(len(matches), len(generated_boundaries))
    recall = safe_ratio(len(matches), len(gold_boundaries))
    f1 = safe_ratio(2 * precision * recall, precision + recall)
    return {
        "matches": matches,
        "generatedBoundaryCount": len(generated_boundaries),
        "goldBoundaryCount": len(gold_boundaries),
        "precision": precision,
        "recall": recall,
        "f1": f1,
        "meanAbsoluteErrorSeconds": safe_ratio(
            sum(match["errorSeconds"] for match in matches), len(matches)
        ),
        "unmatchedGoldStarts": [
            start
            for index, start in enumerate(gold_boundaries)
            if index in unmatched_gold
        ],
        "unmatchedGeneratedStarts": [
            start
            for start in generated_boundaries
            if all(match["generatedStart"] != start for match in matches)
        ],
    }


def evaluate_episode(gold_episode, generated_result, tolerance):
    gold_chapters = gold_episode["chapters"]
    generated_chapters = generated_result.get("chapters", [])
    duration = generated_result.get("durationSeconds", gold_episode["durationSeconds"])
    boundary = match_boundaries(gold_chapters, generated_chapters, tolerance)

    gold_promo = intervals(gold_chapters, "isSponsor")
    generated_promo = intervals(generated_chapters, "isSponsor")
    promo_overlap = overlap_duration(gold_promo, generated_promo)
    gold_promo_seconds = total_duration(gold_promo)
    generated_promo_seconds = total_duration(generated_promo)

    gold_skip = intervals(gold_chapters, "skipCandidate")
    skip_overlap = overlap_duration(gold_skip, generated_promo)
    gold_skip_seconds = total_duration(gold_skip)

    return {
        "id": gold_episode["id"],
        "label": gold_episode["label"],
        "goldChapterCount": len(gold_chapters),
        "generatedChapterCount": len(generated_chapters),
        "goldPromoSeconds": gold_promo_seconds,
        "generatedPromoSeconds": generated_promo_seconds,
        "promoOverlapSeconds": promo_overlap,
        "promoPrecision": safe_ratio(promo_overlap, generated_promo_seconds),
        "promoRecall": safe_ratio(promo_overlap, gold_promo_seconds),
        "skipRecallViaSponsor": safe_ratio(skip_overlap, gold_skip_seconds),
        "boundary": boundary,
        "issues": sorted(
            set(generated_result.get("issues", []) + recomputed_issues(generated_chapters, duration))
        ),
        "elapsedSeconds": generated_result.get("elapsedSeconds"),
        "promptCharacters": generated_result.get("promptCharacters"),
        "contextTokens": generated_result.get("contextTokens"),
        "chapters": generated_chapters,
    }


def combine(model_name, evaluations):
    matched = sum(len(evaluation["boundary"]["matches"]) for evaluation in evaluations)
    generated_boundaries = sum(
        evaluation["boundary"]["generatedBoundaryCount"] for evaluation in evaluations
    )
    gold_boundaries = sum(
        evaluation["boundary"]["goldBoundaryCount"] for evaluation in evaluations
    )
    boundary_precision = safe_ratio(matched, generated_boundaries)
    boundary_recall = safe_ratio(matched, gold_boundaries)
    promo_overlap = sum(evaluation["promoOverlapSeconds"] for evaluation in evaluations)
    generated_promo = sum(evaluation["generatedPromoSeconds"] for evaluation in evaluations)
    gold_promo = sum(evaluation["goldPromoSeconds"] for evaluation in evaluations)
    elapsed = sum(
        evaluation["elapsedSeconds"]
        for evaluation in evaluations
        if isinstance(evaluation["elapsedSeconds"], (int, float))
    )
    return {
        "model": model_name,
        "episodeCount": len(evaluations),
        "elapsedSeconds": elapsed,
        "boundaryPrecision": boundary_precision,
        "boundaryRecall": boundary_recall,
        "boundaryF1": safe_ratio(
            2 * boundary_precision * boundary_recall,
            boundary_precision + boundary_recall,
        ),
        "promoPrecision": safe_ratio(promo_overlap, generated_promo),
        "promoRecall": safe_ratio(promo_overlap, gold_promo),
        "meanChapterCountDelta": safe_ratio(
            sum(
                abs(evaluation["generatedChapterCount"] - evaluation["goldChapterCount"])
                for evaluation in evaluations
            ),
            len(evaluations),
        ),
        "evaluations": evaluations,
    }


def print_summary(report):
    print(
        f"{report['model']}: episodes={report['episodeCount']} "
        f"elapsed={report['elapsedSeconds']:.1f}s "
        f"boundary_f1={report['boundaryF1']:.3f} "
        f"boundary_precision={report['boundaryPrecision']:.3f} "
        f"boundary_recall={report['boundaryRecall']:.3f} "
        f"promo_precision={report['promoPrecision']:.3f} "
        f"promo_recall={report['promoRecall']:.3f} "
        f"mean_count_delta={report['meanChapterCountDelta']:.2f}"
    )
    for evaluation in report["evaluations"]:
        boundary = evaluation["boundary"]
        issue_text = ", ".join(evaluation["issues"]) if evaluation["issues"] else "ok"
        print(
            f"  {evaluation['id']} {evaluation['label']}: "
            f"gold={evaluation['goldChapterCount']} generated={evaluation['generatedChapterCount']} "
            f"boundary_f1={boundary['f1']:.3f} "
            f"promo_p/r={evaluation['promoPrecision']:.3f}/{evaluation['promoRecall']:.3f} "
            f"issues={issue_text}"
        )
        if boundary["unmatchedGoldStarts"]:
            print(f"    missed_gold_starts={boundary['unmatchedGoldStarts']}")
        if boundary["unmatchedGeneratedStarts"]:
            print(f"    extra_generated_starts={boundary['unmatchedGeneratedStarts']}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--gold", default="Tools/chapter_gold_standard.json")
    parser.add_argument("--tolerance", type=int, default=30)
    parser.add_argument("--summary", action="append", nargs=2, metavar=("NAME", "PATH"))
    parser.add_argument("--out")
    args = parser.parse_args()

    gold = load_json(args.gold)
    gold_by_id = {episode["id"]: episode for episode in gold["episodes"]}
    summaries = args.summary or [
        (name, path) for name, path in DEFAULT_SUMMARIES if Path(path).exists()
    ]
    if not summaries:
        raise SystemExit("No summaries found. Pass --summary NAME PATH.")

    reports = []
    for model_name, summary_path in summaries:
        summary = load_json(summary_path)
        results_by_id = {
            episode_id_from_result(result): result
            for result in summary.get("results", [])
            if episode_id_from_result(result) in gold_by_id
        }
        missing = sorted(set(gold_by_id) - set(results_by_id))
        if missing:
            raise SystemExit(f"{model_name}: missing generated results for {missing}")
        evaluations = [
            evaluate_episode(gold_episode, results_by_id[gold_episode["id"]], args.tolerance)
            for gold_episode in gold["episodes"]
        ]
        reports.append(combine(model_name, evaluations))

    for index, report in enumerate(reports):
        if index:
            print()
        print_summary(report)

    if args.out:
        Path(args.out).write_text(
            json.dumps({"toleranceSeconds": args.tolerance, "reports": reports}, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )


if __name__ == "__main__":
    main()
