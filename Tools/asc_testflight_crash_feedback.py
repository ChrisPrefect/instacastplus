#!/usr/bin/env python3
"""Fetch TestFlight crash feedback submissions via the App Store Connect API.

Reads the private key from disk; never prints key or token.
"""
import json
import sys
import time
import urllib.request
import urllib.parse

import jwt

KEY_ID = "7QUKV6MHZ2"
ISSUER_ID = "69a6de70-cba8-47e3-e053-5b8c7c11a4d1"
KEY_PATH = "/Users/Chris/Developer/AuthKey_7QUKV6MHZ2.p8"
APP_ID = "6472283494"
BASE = "https://api.appstoreconnect.apple.com"


def make_token():
    with open(KEY_PATH, "r") as f:
        private_key = f.read()
    now = int(time.time())
    payload = {"iss": ISSUER_ID, "iat": now, "exp": now + 19 * 60, "aud": "appstoreconnect-v1"}
    return jwt.encode(payload, private_key, algorithm="ES256", headers={"kid": KEY_ID, "typ": "JWT"})


def get(path, token, params=None, raw=False):
    url = BASE + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req) as resp:
            data = resp.read()
            return data if raw else json.loads(data)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:600]
        print(f"HTTP {e.code} for {path}: {body}", file=sys.stderr)
        return None


def main():
    token = make_token()
    listing = get(f"/v1/apps/{APP_ID}/betaFeedbackCrashSubmissions", token, params={
        "limit": "20",
        "sort": "-createdDate",
        "fields[betaFeedbackCrashSubmissions]": "createdDate,comment,email,deviceModel,osVersion,appPlatform,devicePlatform,locale,buildBundleId",
    })
    if listing is None:
        print("listing failed", file=sys.stderr)
        sys.exit(1)
    items = listing.get("data", [])
    print(f"crash feedback submissions: {len(items)}")
    for item in items:
        attrs = item.get("attributes", {})
        print("-", item.get("id"), "|", attrs.get("createdDate"), "|", attrs.get("deviceModel"),
              attrs.get("osVersion"), "|", (attrs.get("comment") or "")[:160])

    # download the crash log of each submission
    for item in items:
        sub_id = item.get("id")
        detail = get(f"/v1/betaFeedbackCrashSubmissions/{sub_id}/crashLog", token)
        if detail is None:
            continue
        data = detail.get("data", {})
        attrs = data.get("attributes", {})
        log_url = attrs.get("url")
        if not log_url:
            print(f"no url for {sub_id}; attrs keys: {list(attrs.keys())}")
            continue
        req = urllib.request.Request(log_url)
        with urllib.request.urlopen(req) as resp:
            content = resp.read()
        out = f"/tmp/tf_crash_{sub_id}.crash"
        with open(out, "wb") as f:
            f.write(content)
        print(f"saved {out} ({len(content)} bytes)")


if __name__ == "__main__":
    main()
