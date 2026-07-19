#!/usr/bin/env python3
import argparse
from collections import Counter
import json
import math
import re
import sys
import unicodedata
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


GENERIC_TITLE = re.compile(
    r"^(?:kapitel|chapter|abschnitt|segment|thema|topic|intro|outro|"
    r"werbung|advertisement|sponsor|promo|music|musik)(?:\s*[-#:]?\s*\d+)?$",
    re.IGNORECASE,
)

TITLE_STOPWORDS = {
    "aber",
    "als",
    "also",
    "and",
    "auf",
    "aus",
    "bei",
    "das",
    "dem",
    "den",
    "der",
    "des",
    "die",
    "ein",
    "eine",
    "einer",
    "eines",
    "for",
    "from",
    "fuer",
    "how",
    "ist",
    "mit",
    "oder",
    "the",
    "und",
    "von",
    "was",
    "wie",
    "why",
    "with",
    "zum",
    "zur",
}


def finite_number(value):
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
    )


def boundaries(chapters):
    if not isinstance(chapters, list):
        return []
    return [
        float(chapter["startSeconds"])
        for chapter in chapters[1:]
        if isinstance(chapter, dict) and finite_number(chapter.get("startSeconds"))
    ]


def intervals(chapters, key):
    if not isinstance(chapters, list):
        return []
    valid = []
    for chapter in chapters:
        if not isinstance(chapter, dict) or chapter.get(key) is not True:
            continue
        start = chapter.get("startSeconds")
        end = chapter.get("endSeconds")
        if finite_number(start) and finite_number(end) and end > start:
            valid.append((float(start), float(end)))
    valid.sort()
    merged = []
    for start, end in valid:
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged


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


def boundary_f1(precision, recall, generated_count, gold_count):
    if generated_count == 0 and gold_count == 0:
        return 1.0
    if precision + recall == 0:
        return 0.0
    return 2 * precision * recall / (precision + recall)


def title_tokens(title):
    if not isinstance(title, str):
        return []
    normalized = (
        title.casefold()
        .replace("ä", "ae")
        .replace("ö", "oe")
        .replace("ü", "ue")
        .replace("ß", "ss")
    )
    normalized = "".join(
        character
        for character in unicodedata.normalize("NFKD", normalized)
        if not unicodedata.combining(character)
    )
    return [
        token
        for token in re.findall(r"[a-z0-9]+", normalized)
        if len(token) >= 3 and token not in TITLE_STOPWORDS
    ]


def title_token_match(gold_chapters, generated_chapters, tolerance):
    gold_starts = [
        float(chapter["startSeconds"])
        if isinstance(chapter, dict) and finite_number(chapter.get("startSeconds"))
        else None
        for chapter in gold_chapters
    ]
    generated_starts = [
        float(chapter["startSeconds"])
        if isinstance(chapter, dict) and finite_number(chapter.get("startSeconds"))
        else None
        for chapter in generated_chapters
    ]
    unmatched_gold = set(range(len(gold_chapters)))
    pairs = []
    for generated_index, generated_start in enumerate(generated_starts):
        if generated_start is None:
            continue
        candidates = [
            (abs(generated_start - gold_starts[gold_index]), gold_index)
            for gold_index in unmatched_gold
            if gold_starts[gold_index] is not None
            and abs(generated_start - gold_starts[gold_index]) <= tolerance
        ]
        if not candidates:
            continue
        _, gold_index = min(candidates)
        unmatched_gold.remove(gold_index)
        pairs.append((gold_index, generated_index))

    overlap_count = 0
    for gold_index, generated_index in pairs:
        gold_counter = Counter(title_tokens(gold_chapters[gold_index].get("title")))
        generated_counter = Counter(
            title_tokens(generated_chapters[generated_index].get("title"))
        )
        overlap_count += sum((gold_counter & generated_counter).values())

    gold_token_count = sum(
        len(title_tokens(chapter.get("title")))
        for chapter in gold_chapters
        if isinstance(chapter, dict)
    )
    generated_token_count = sum(
        len(title_tokens(chapter.get("title")))
        for chapter in generated_chapters
        if isinstance(chapter, dict)
    )
    precision = safe_ratio(overlap_count, generated_token_count)
    recall = safe_ratio(overlap_count, gold_token_count)
    return {
        "overlapTokenCount": overlap_count,
        "generatedTokenCount": generated_token_count,
        "goldTokenCount": gold_token_count,
        "precision": precision,
        "recall": recall,
        "f1": boundary_f1(
            precision,
            recall,
            generated_token_count,
            gold_token_count,
        ),
    }


def recomputed_issues(chapters, duration):
    if not isinstance(chapters, list):
        return ["chapters must be an array"]
    if not chapters:
        return ["no chapters"]

    issues = []
    valid_duration = finite_number(duration) and duration > 0
    if not valid_duration:
        issues.append("episode duration must be a positive finite number")

    valid_boundaries = []
    for index, chapter in enumerate(chapters):
        if not isinstance(chapter, dict):
            issues.append(f"chapter {index} must be an object")
            valid_boundaries.append(None)
            continue

        start = chapter.get("startSeconds")
        end = chapter.get("endSeconds")
        start_is_valid = finite_number(start)
        end_is_valid = finite_number(end)
        if not start_is_valid:
            issues.append(f"chapter {index} startSeconds must be a finite number")
        if not end_is_valid:
            issues.append(f"chapter {index} endSeconds must be a finite number")

        title = chapter.get("title")
        normalized_title = title.strip() if isinstance(title, str) else ""
        if not normalized_title:
            issues.append(f"chapter {index} title must be nonempty")
        elif not any(character.isalnum() for character in normalized_title) or GENERIC_TITLE.fullmatch(
            normalized_title
        ):
            issues.append(f"chapter {index} title is not meaningful: {normalized_title!r}")

        is_sponsor = chapter.get("isSponsor")
        if not isinstance(is_sponsor, bool):
            issues.append(f"chapter {index} isSponsor must be a boolean")

        if start_is_valid and end_is_valid:
            start = float(start)
            end = float(end)
            valid_boundaries.append((start, end))
            if end <= start:
                issues.append(f"chapter {index} has non-positive duration")
            if valid_duration and (start < 0 or end > duration):
                issues.append(f"chapter {index} is outside episode duration")
            sponsor_interval_is_valid = (
                end > start and (not valid_duration or (start >= 0 and end <= duration))
            )
        else:
            valid_boundaries.append(None)
            sponsor_interval_is_valid = False

        if is_sponsor is True and not sponsor_interval_is_valid:
            issues.append(f"chapter {index} sponsor interval is invalid")

    epsilon = 1e-6
    first_boundary = valid_boundaries[0]
    if first_boundary is not None and abs(first_boundary[0]) > epsilon:
        issues.append("timeline does not start at 0")

    previous_start = None
    for index, boundary in enumerate(valid_boundaries):
        if boundary is None:
            continue
        start, _ = boundary
        if previous_start is not None and start <= previous_start:
            issues.append(f"chapter starts are not strictly monotone at chapter {index}")
        previous_start = start

    for index, (left, right) in enumerate(zip(valid_boundaries, valid_boundaries[1:])):
        if left is None or right is None:
            continue
        delta = right[0] - left[1]
        if delta > epsilon:
            issues.append(f"timeline has a gap before chapter {index + 1}")
        elif delta < -epsilon:
            issues.append(f"timeline has an overlap before chapter {index + 1}")

    last_boundary = valid_boundaries[-1]
    if (
        valid_duration
        and last_boundary is not None
        and abs(last_boundary[1] - duration) > epsilon
    ):
        issues.append("timeline does not end at episode duration")

    return issues


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
    f1 = boundary_f1(
        precision,
        recall,
        len(generated_boundaries),
        len(gold_boundaries),
    )
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
    duration = gold_episode["durationSeconds"]
    boundary = match_boundaries(gold_chapters, generated_chapters, tolerance)
    title = title_token_match(gold_chapters, generated_chapters, tolerance)

    gold_promo = intervals(gold_chapters, "isSponsor")
    generated_promo = intervals(generated_chapters, "isSponsor")
    promo_overlap = overlap_duration(gold_promo, generated_promo)
    gold_promo_seconds = total_duration(gold_promo)
    generated_promo_seconds = total_duration(generated_promo)

    gold_skip = intervals(gold_chapters, "skipCandidate")
    skip_overlap = overlap_duration(gold_skip, generated_promo)
    gold_skip_seconds = total_duration(gold_skip)

    reported_issues = generated_result.get("issues", [])
    if not isinstance(reported_issues, list):
        reported_issues = [str(reported_issues)]
    structural_issues = recomputed_issues(generated_chapters, duration)

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
        "title": title,
        "issues": sorted(set(reported_issues + structural_issues)),
        "structuralIssues": structural_issues,
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
    title_overlap = sum(
        evaluation["title"]["overlapTokenCount"] for evaluation in evaluations
    )
    generated_title_tokens = sum(
        evaluation["title"]["generatedTokenCount"] for evaluation in evaluations
    )
    gold_title_tokens = sum(
        evaluation["title"]["goldTokenCount"] for evaluation in evaluations
    )
    title_precision = safe_ratio(title_overlap, generated_title_tokens)
    title_recall = safe_ratio(title_overlap, gold_title_tokens)
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
        "boundaryF1": boundary_f1(
            boundary_precision,
            boundary_recall,
            generated_boundaries,
            gold_boundaries,
        ),
        "titleTokenPrecision": title_precision,
        "titleTokenRecall": title_recall,
        "titleTokenF1": boundary_f1(
            title_precision,
            title_recall,
            generated_title_tokens,
            gold_title_tokens,
        ),
        "promoPrecision": safe_ratio(promo_overlap, generated_promo),
        "promoRecall": safe_ratio(promo_overlap, gold_promo),
        "structuralIssueCount": sum(
            len(evaluation["structuralIssues"]) for evaluation in evaluations
        ),
        "issueCount": sum(len(evaluation["issues"]) for evaluation in evaluations),
        "meanChapterCountDelta": safe_ratio(
            sum(
                abs(evaluation["generatedChapterCount"] - evaluation["goldChapterCount"])
                for evaluation in evaluations
            ),
            len(evaluations),
        ),
        "evaluations": evaluations,
    }


def acceptance_failures(report, thresholds):
    failures = []
    for metric, minimum in thresholds.items():
        actual = report[metric]
        if actual < minimum:
            failures.append(f"{metric}={actual:.3f} below required {minimum:.3f}")
    if report["issueCount"]:
        failures.append(
            f"{report['issueCount']} reported/structural issues "
            f"({report['structuralIssueCount']} structural issues)"
        )
    return failures


def print_summary(report):
    print(
        f"{report['model']}: episodes={report['episodeCount']} "
        f"elapsed={report['elapsedSeconds']:.1f}s "
        f"boundary_f1={report['boundaryF1']:.3f} "
        f"boundary_precision={report['boundaryPrecision']:.3f} "
        f"boundary_recall={report['boundaryRecall']:.3f} "
        f"title_token_f1={report['titleTokenF1']:.3f} "
        f"promo_precision={report['promoPrecision']:.3f} "
        f"promo_recall={report['promoRecall']:.3f} "
        f"mean_count_delta={report['meanChapterCountDelta']:.2f} "
        f"issues={report['issueCount']}"
    )
    for evaluation in report["evaluations"]:
        boundary = evaluation["boundary"]
        issue_text = ", ".join(evaluation["issues"]) if evaluation["issues"] else "ok"
        print(
            f"  {evaluation['id']} {evaluation['label']}: "
            f"gold={evaluation['goldChapterCount']} generated={evaluation['generatedChapterCount']} "
            f"boundary_f1={boundary['f1']:.3f} "
            f"title_token_f1={evaluation['title']['f1']:.3f} "
            f"promo_p/r={evaluation['promoPrecision']:.3f}/{evaluation['promoRecall']:.3f} "
            f"issues={issue_text}"
        )
        if boundary["unmatchedGoldStarts"]:
            print(f"    missed_gold_starts={boundary['unmatchedGoldStarts']}")
        if boundary["unmatchedGeneratedStarts"]:
            print(f"    extra_generated_starts={boundary['unmatchedGeneratedStarts']}")


def unit_interval(value):
    try:
        number = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a number between 0 and 1") from error
    if not math.isfinite(number) or number < 0 or number > 1:
        raise argparse.ArgumentTypeError("must be a finite number between 0 and 1")
    return number


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--gold", default="Tools/chapter_gold_standard.json")
    parser.add_argument("--tolerance", type=int, default=30)
    parser.add_argument("--summary", action="append", nargs=2, metavar=("NAME", "PATH"))
    parser.add_argument(
        "--min-promo-precision",
        type=unit_interval,
        required=True,
        help="Required time-weighted sponsor precision (0...1).",
    )
    parser.add_argument(
        "--min-promo-recall",
        type=unit_interval,
        required=True,
        help="Required time-weighted sponsor recall (0...1).",
    )
    parser.add_argument(
        "--min-boundary-f1",
        type=unit_interval,
        required=True,
        help="Required chapter-boundary F1 (0...1).",
    )
    parser.add_argument(
        "--min-title-token-f1",
        type=unit_interval,
        required=True,
        help="Required token-overlap F1 against the gold chapter titles (0...1).",
    )
    parser.add_argument("--out")
    args = parser.parse_args()
    if args.tolerance < 0:
        parser.error("--tolerance must be non-negative")

    thresholds = {
        "promoPrecision": args.min_promo_precision,
        "promoRecall": args.min_promo_recall,
        "boundaryF1": args.min_boundary_f1,
        "titleTokenF1": args.min_title_token_f1,
    }

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
        report = combine(model_name, evaluations)
        failures = acceptance_failures(report, thresholds)
        report["acceptance"] = {
            "passed": not failures,
            "thresholds": thresholds,
            "failures": failures,
        }
        reports.append(report)

    for index, report in enumerate(reports):
        if index:
            print()
        print_summary(report)

    if args.out:
        Path(args.out).write_text(
            json.dumps(
                {
                    "toleranceSeconds": args.tolerance,
                    "acceptanceThresholds": thresholds,
                    "reports": reports,
                },
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )

    failed_reports = [report for report in reports if not report["acceptance"]["passed"]]
    if failed_reports:
        for report in failed_reports:
            print(
                f"QUALITY GATE FAILED for {report['model']}: "
                + "; ".join(report["acceptance"]["failures"]),
                file=sys.stderr,
            )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
