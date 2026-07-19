#!/usr/bin/env python3
"""Source-aware regression checks for lossless automatic episode discovery."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SUBSCRIPTIONS = (ROOT / "Classes/Model/SubscriptionManager.m").read_text()
QUEUE = (ROOT / "Classes/TranscriptionQueue.swift").read_text()


post_start = SUBSCRIPTIONS.index("- (void)_postDidAddEpisodesNotification:")
post_end = SUBSCRIPTIONS.index("\n}", post_start)
post_body = SUBSCRIPTIONS[post_start:post_end]

durable_record = "recordAutomaticDiscoveryForEpisodes:episodes"
direct_handoff = "scheduleAutomaticProcessingForEpisodes:episodes"
assert durable_record in post_body and direct_handoff in post_body, (
    "new episode hashes must enter the durable discovery outbox before queue handoff"
)
assert post_body.index(durable_record) < post_body.index(direct_handoff), (
    "automatic queue handoff must wait for the durable discovery record"
)

assert "@objc(scheduleAutomaticProcessingForEpisodes:)" in QUEUE, (
    "TranscriptionQueue must expose the direct SubscriptionManager handoff"
)
assert "@objc(recordAutomaticDiscoveryForEpisodes:)" in QUEUE, (
    "TranscriptionQueue must expose the durable pre-handoff discovery record"
)
assert "forName: NSNotification.Name(\"SubscriptionManagerDidAddEpisodesNotification\")" not in QUEUE, (
    "automatic processing must not depend on a notification observer that may not exist yet"
)

print("Automatic transcription discovery regression checks passed.")
