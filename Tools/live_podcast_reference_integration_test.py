#!/usr/bin/env python3
"""Opt-in live reference check for a public podcast transcript and ID3 chapters.

The test downloads RSS and transcript HTML into memory and requests only the leading
ID3 range of the MP3. It never writes or prints transcript/audio content.

Run with:
    RUN_LIVE_PODCAST_REFERENCE_TEST=1 \
      python3 Tools/live_podcast_reference_integration_test.py
"""

from __future__ import annotations

import html
from html.parser import HTMLParser
import os
import struct
import sys
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET


RSS_URL = "https://daringfireball.net/thetalkshow/rss"
EPISODE_TITLE = "450: ‘Perp Walk for Selfies’, With Jason Snell"
EPISODE_URL = "https://daringfireball.net/thetalkshow/2026/06/23/ep-450"
TRANSCRIPT_URL = "https://podsearch.david-smith.org/episodes/7972"
MEDIA_URL = (
    "https://traffic.libsyn.com/secure/daringfireball/"
    "thetalkshow-450-jason-snell.mp3"
)
MEDIA_LENGTH = 79_348_637
MEDIA_DURATION_MS = 9_885_622
RANGE_END = 524_287
USER_AGENT = "InstacastPlus-LiveReferenceTest/1.0"

EXPECTED_CHAPTERS = [
    ("chp0", 0, 440_000, "Ditching Chrome"),
    ("chp1", 440_000, 1_303_000, "Meeting Apple execs"),
    (
        "chp2",
        1_303_000,
        2_196_000,
        "Alan Dye vs. John Giannandrea’s exits from Apple",
    ),
    ("chp3", 2_196_000, 2_347_000, "Sponsor: Factor"),
    ("chp4", 2_347_000, 3_851_000, "Cook to Ternus transition"),
    ("chp5", 3_851_000, 4_015_000, "Sponsor: Squarespace"),
    ("chp6", 4_015_000, 4_952_000, "WWDC live events"),
    ("chp7", 4_952_000, 5_948_000, "Boring fixes matter"),
    ("chp8", 5_948_000, 6_099_000, "Sponsor: Finalist"),
    ("chp9", 6_099_000, 8_010_000, "‘Designed in California’"),
    ("chp10", 8_010_000, 9_885_622, "Siri AI is good"),
]


def fetch(url: str, *, byte_range: str | None = None) -> tuple[bytes, object]:
    headers = {"User-Agent": USER_AGENT}
    if byte_range is not None:
        headers["Range"] = byte_range
    response = urlopen(Request(url, headers=headers), timeout=30)
    return response.read(), response


def synchsafe_integer(raw: bytes) -> int:
    assert len(raw) == 4 and all(byte < 0x80 for byte in raw)
    return (raw[0] << 21) | (raw[1] << 14) | (raw[2] << 7) | raw[3]


def id3_frames(payload: bytes):
    cursor = 0
    while cursor + 10 <= len(payload):
        frame_id = payload[cursor : cursor + 4]
        if frame_id == b"\0\0\0\0":
            break
        assert all(0x20 <= byte <= 0x7E for byte in frame_id)
        size = int.from_bytes(payload[cursor + 4 : cursor + 8], "big")
        end = cursor + 10 + size
        assert size > 0 and end <= len(payload)
        yield frame_id.decode("ascii"), payload[cursor + 10 : end]
        cursor = end


def terminated_ascii(payload: bytes, cursor: int = 0) -> tuple[str, int]:
    end = payload.index(0, cursor)
    return payload[cursor:end].decode("ascii"), end + 1


def id3_text(payload: bytes) -> str:
    assert payload
    encoding = payload[0]
    codecs = {0: "latin-1", 1: "utf-16", 2: "utf-16-be", 3: "utf-8"}
    assert encoding in codecs
    return payload[1:].decode(codecs[encoding]).rstrip("\0")


def parse_chapter(payload: bytes) -> tuple[str, int, int, str]:
    element_id, cursor = terminated_ascii(payload)
    assert cursor + 16 <= len(payload)
    start_ms, end_ms, start_offset, end_offset = struct.unpack(
        ">IIII", payload[cursor : cursor + 16]
    )
    assert start_offset == end_offset == 0xFFFFFFFF
    embedded = list(id3_frames(payload[cursor + 16 :]))
    titles = [id3_text(data) for frame_id, data in embedded if frame_id == "TIT2"]
    assert len(titles) == 1
    return element_id, start_ms, end_ms, titles[0]


def parse_ctoc(payload: bytes) -> list[str]:
    _, cursor = terminated_ascii(payload)
    assert cursor + 2 <= len(payload)
    flags = payload[cursor]
    child_count = payload[cursor + 1]
    assert flags & 0x02, "reference CTOC must be top-level"
    cursor += 2
    child_ids = []
    for _ in range(child_count):
        child_id, cursor = terminated_ascii(payload, cursor)
        child_ids.append(child_id)
    return child_ids


class TranscriptParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.heading_tag: str | None = None
        self.heading_data: list[str] = []
        self.headings: dict[str, list[str]] = {"h1": [], "h2": []}
        self.segment_depth = 0
        self.segment_time: int | None = None
        self.segment_text: list[str] = []
        self.anchor_depth = 0
        self.cues: list[tuple[int, str]] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = dict(attrs)
        if tag in self.headings:
            self.heading_tag = tag
            self.heading_data = []

        if tag == "div" and attributes.get("class") == "segment":
            assert self.segment_depth == 0
            self.segment_depth = 1
            self.segment_time = None
            self.segment_text = []
            return
        if self.segment_depth:
            if tag == "div":
                self.segment_depth += 1
            if tag == "p" and self.segment_time is None:
                timestamp = attributes.get("id", "")
                assert timestamp.isdigit()
                self.segment_time = int(timestamp)
            if tag == "a":
                self.anchor_depth += 1

    def handle_endtag(self, tag: str) -> None:
        if tag == self.heading_tag:
            heading = " ".join("".join(self.heading_data).split())
            self.headings[tag].append(html.unescape(heading))
            self.heading_tag = None
            self.heading_data = []

        if self.segment_depth and tag == "a":
            self.anchor_depth -= 1
        if self.segment_depth and tag == "div":
            self.segment_depth -= 1
            if self.segment_depth == 0:
                assert self.segment_time is not None
                text = " ".join("".join(self.segment_text).split())
                if text:
                    self.cues.append((self.segment_time, html.unescape(text)))

    def handle_data(self, data: str) -> None:
        if self.heading_tag:
            self.heading_data.append(data)
        if self.segment_depth and self.anchor_depth == 0:
            self.segment_text.append(data)


def verify_rss() -> None:
    raw, _ = fetch(RSS_URL)
    root = ET.fromstring(raw)
    items = [
        item for item in root.findall("./channel/item")
        if item.findtext("title") == EPISODE_TITLE
    ]
    assert len(items) == 1
    item = items[0]
    assert item.findtext("link") == EPISODE_URL
    assert item.findtext("pubDate") == "Tue, 23 Jun 2026 12:18:08 EDT"
    enclosure = item.find("enclosure")
    assert enclosure is not None
    assert enclosure.attrib == {
        "url": MEDIA_URL,
        "length": str(MEDIA_LENGTH),
        "type": "audio/mpeg",
    }
    duration = item.findtext("{http://www.itunes.com/dtds/podcast-1.0.dtd}duration")
    assert duration == "02:44:45"


def verify_id3() -> tuple[list[tuple[str, int, int, str]], int]:
    raw, response = fetch(MEDIA_URL, byte_range=f"bytes=0-{RANGE_END}")
    assert response.status == 206
    assert response.headers.get("Content-Range") == (
        f"bytes 0-{RANGE_END}/{MEDIA_LENGTH}"
    )
    assert len(raw) == RANGE_END + 1
    assert raw[:3] == b"ID3" and raw[3:5] == bytes((3, 0))
    tag_end = 10 + synchsafe_integer(raw[6:10])
    assert tag_end == 263_660 and tag_end <= len(raw)

    chapters = []
    ctocs = []
    durations = []
    for frame_id, payload in id3_frames(raw[10:tag_end]):
        if frame_id == "CHAP":
            chapters.append(parse_chapter(payload))
        elif frame_id == "CTOC":
            ctocs.append(parse_ctoc(payload))
        elif frame_id == "TLEN":
            durations.append(int(id3_text(payload)))

    assert chapters == EXPECTED_CHAPTERS
    assert len(ctocs) == 1
    assert ctocs[0] == [chapter[0] for chapter in chapters]
    assert durations == [MEDIA_DURATION_MS]
    assert chapters[0][1] == 0 and chapters[-1][2] == MEDIA_DURATION_MS
    assert all(left[2] == right[1] for left, right in zip(chapters, chapters[1:]))

    sponsors = [chapter for chapter in chapters if chapter[3].startswith("Sponsor: ")]
    assert [(start, end, title) for _, start, end, title in sponsors] == [
        (2_196_000, 2_347_000, "Sponsor: Factor"),
        (3_851_000, 4_015_000, "Sponsor: Squarespace"),
        (5_948_000, 6_099_000, "Sponsor: Finalist"),
    ]
    assert sum(end - start for _, start, end, _ in sponsors) == 466_000
    return chapters, len(raw)


def verify_transcript(chapters: list[tuple[str, int, int, str]]) -> tuple[int, int, float]:
    raw, _ = fetch(TRANSCRIPT_URL)
    parser = TranscriptParser()
    parser.feed(raw.decode("utf-8"))
    assert parser.headings["h1"] == ["The Talk Show"]
    assert parser.headings["h2"] == [EPISODE_TITLE]

    cues = parser.cues
    assert len(cues) >= 2_500
    character_count = sum(len(text) for _, text in cues)
    assert character_count >= 100_000
    times_ms = [seconds * 1_000 for seconds, _ in cues]
    assert times_ms[0] == 0
    assert all(left <= right for left, right in zip(times_ms, times_ms[1:]))
    assert times_ms[-1] <= MEDIA_DURATION_MS
    assert times_ms[-1] >= MEDIA_DURATION_MS - 5_000
    coverage_ratio = times_ms[-1] / MEDIA_DURATION_MS
    assert coverage_ratio >= 0.999
    for _, start_ms, end_ms, _ in chapters:
        assert any(start_ms <= timestamp < end_ms for timestamp in times_ms)
    return len(cues), character_count, coverage_ratio


def main() -> int:
    if os.environ.get("RUN_LIVE_PODCAST_REFERENCE_TEST") != "1":
        print("skipped: set RUN_LIVE_PODCAST_REFERENCE_TEST=1 to use live network data")
        return 0

    verify_rss()
    chapters, range_bytes = verify_id3()
    cue_count, character_count, coverage_ratio = verify_transcript(chapters)
    sponsor_count = sum(title.startswith("Sponsor: ") for *_, title in chapters)
    print(
        "live podcast reference passed: "
        f"cues={cue_count}, transcriptCharacters={character_count}, "
        f"cueCoverage={coverage_ratio:.5f}, durationSeconds={MEDIA_DURATION_MS / 1000:.3f}, "
        f"chapters={len(chapters)}, chapterCoverageSeconds={MEDIA_DURATION_MS / 1000:.3f}, "
        f"sponsors={sponsor_count}, sponsorSeconds=466.000, id3RangeBytes={range_bytes}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
