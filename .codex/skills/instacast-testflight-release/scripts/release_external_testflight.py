#!/usr/bin/env python3
import argparse
import base64
import datetime
import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


BASE_URL = "https://api.appstoreconnect.apple.com/v1"
DEFAULT_APP_ID = "6472283494"
DEFAULT_GROUP_ID = "aefb6bc1-71f0-4c9d-a792-9b455c0d9a23"
DEFAULT_KEY_ID = "7QUKV6MHZ2"
DEFAULT_ISSUER_ID = "69a6de70-cba8-47e3-e053-5b8c7c11a4d1"
DEFAULT_KEY_PATH = "/Users/Chris/Developer/AuthKey_7QUKV6MHZ2.p8"


class ASCClient:
    def __init__(self, key_id, issuer_id, key_path):
        self.key_id = key_id
        self.issuer_id = issuer_id
        self.key_path = key_path
        self._token = None
        self._token_exp = 0

    def token(self):
        if self._token and time.time() < self._token_exp - 30:
            return self._token

        result = subprocess.run(
            [
                "xcrun",
                "altool",
                "--generate-jwt",
                "--apiKey",
                self.key_id,
                "--apiIssuer",
                self.issuer_id,
                "--p8-file-path",
                self.key_path,
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        match = re.search(
            r"([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)",
            result.stdout + "\n" + result.stderr,
        )
        if not match:
            raise RuntimeError("Could not read ASC JWT from altool output")

        self._token = match.group(1)
        self._token_exp = self._jwt_expiry(self._token)
        return self._token

    @staticmethod
    def _jwt_expiry(token):
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload))
        exp = claims.get("exp")
        if not isinstance(exp, (int, float)):
            raise RuntimeError("Could not read ASC JWT expiration")
        return float(exp)

    def request(self, method, path, params=None, data=None, ok=(200, 201, 204)):
        url = BASE_URL + path
        if params:
            url += "?" + urllib.parse.urlencode(params, doseq=True)

        body = json.dumps(data).encode("utf-8") if data is not None else None
        request = urllib.request.Request(
            url,
            data=body,
            method=method,
            headers={
                "Authorization": "Bearer " + self.token(),
                "Content-Type": "application/json",
            },
        )

        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                raw = response.read().decode("utf-8")
                payload = json.loads(raw) if raw else None
                return response.status, payload
        except urllib.error.HTTPError as error:
            raw = error.read().decode("utf-8", errors="replace")
            try:
                payload = json.loads(raw)
            except json.JSONDecodeError:
                payload = {"raw": raw}
            return error.code, payload

    def must(self, method, path, params=None, data=None, ok=(200, 201, 204)):
        status, payload = self.request(method, path, params=params, data=data, ok=ok)
        if status not in ok:
            raise RuntimeError(f"{method} {path} failed with HTTP {status}: {json.dumps(payload, ensure_ascii=False)}")
        return payload


def print_status(message):
    now = datetime.datetime.now().strftime("%H:%M:%S")
    print(f"{now} {message}", flush=True)


def prerelease_version(client, build):
    relation = build.get("relationships", {}).get("preReleaseVersion", {}).get("data")
    if not relation:
        return None
    payload = client.must("GET", f"/preReleaseVersions/{relation['id']}")
    return payload["data"]["attributes"].get("version")


def find_build(client, app_id, build_number, marketing_version):
    payload = client.must(
        "GET",
        "/builds",
        params={
            "filter[app]": app_id,
            "filter[version]": build_number,
            "include": "preReleaseVersion",
            "sort": "-uploadedDate",
            "limit": "10",
        },
    )

    for build in payload.get("data", []):
        attrs = build["attributes"]
        if attrs.get("version") != build_number or attrs.get("expired"):
            continue
        if marketing_version and prerelease_version(client, build) != marketing_version:
            continue
        return build
    return None


def wait_for_valid_build(client, app_id, build_number, marketing_version, attempts, interval):
    for _ in range(attempts):
        build = find_build(client, app_id, build_number, marketing_version)
        if not build:
            print_status(f"build {build_number} not visible yet")
            time.sleep(interval)
            continue

        attrs = build["attributes"]
        print_status(
            f"build_id={build['id']} uploaded={attrs.get('uploadedDate')} "
            f"processingState={attrs.get('processingState')} expired={attrs.get('expired')}"
        )
        if attrs.get("processingState") == "VALID":
            return build
        if attrs.get("processingState") in ("FAILED", "INVALID"):
            raise RuntimeError(f"ASC processing failed: {json.dumps(attrs, ensure_ascii=False)}")
        time.sleep(interval)

    raise RuntimeError(f"Timed out waiting for build {build_number} to become VALID in ASC")


def set_what_to_test(client, build_id, locale, whats_new):
    payload = client.must("GET", f"/builds/{build_id}/betaBuildLocalizations")
    for localization in payload.get("data", []):
        if localization["attributes"].get("locale") == locale:
            loc_id = localization["id"]
            client.must(
                "PATCH",
                f"/betaBuildLocalizations/{loc_id}",
                data={
                    "data": {
                        "type": "betaBuildLocalizations",
                        "id": loc_id,
                        "attributes": {"whatsNew": whats_new},
                    }
                },
            )
            print_status(f"updated What to Test localization {loc_id}")
            return loc_id

    created = client.must(
        "POST",
        "/betaBuildLocalizations",
        data={
            "data": {
                "type": "betaBuildLocalizations",
                "attributes": {"locale": locale, "whatsNew": whats_new},
                "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
            }
        },
    )
    loc_id = created["data"]["id"]
    print_status(f"created What to Test localization {loc_id}")
    return loc_id


def beta_detail(client, build_id):
    return client.must("GET", f"/builds/{build_id}/buildBetaDetail")["data"]


def review_submission(client, build_id):
    payload = client.must("GET", f"/builds/{build_id}/betaAppReviewSubmission")
    return payload.get("data")


def enable_auto_notify(client, build_id):
    detail = beta_detail(client, build_id)
    patched = client.must(
        "PATCH",
        f"/buildBetaDetails/{detail['id']}",
        data={
            "data": {
                "type": "buildBetaDetails",
                "id": detail["id"],
                "attributes": {"autoNotifyEnabled": True},
            }
        },
    )
    print_status(f"autoNotifyEnabled={patched['data']['attributes'].get('autoNotifyEnabled')}")


def add_external_group(client, build_id, group_id):
    status, payload = client.request(
        "POST",
        f"/betaGroups/{group_id}/relationships/builds",
        data={"data": [{"type": "builds", "id": build_id}]},
        ok=(204,),
    )
    if status == 204:
        print_status(f"added build to external group {group_id}")
        return
    if status == 409:
        print_status(f"external group relation already exists or is pending: {group_id}")
        return
    raise RuntimeError(f"Adding external group failed with HTTP {status}: {json.dumps(payload, ensure_ascii=False)}")


def submit_beta_review(client, build_id):
    status, payload = client.request(
        "POST",
        "/betaAppReviewSubmissions",
        data={
            "data": {
                "type": "betaAppReviewSubmissions",
                "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
            }
        },
        ok=(201,),
    )
    if status == 201:
        print_status(f"submitted beta review {payload['data']['id']}")
        return
    if status in (409, 422):
        print_status(f"beta review submission not needed or already pending: HTTP {status}")
        return
    raise RuntimeError(f"Beta review submission failed with HTTP {status}: {json.dumps(payload, ensure_ascii=False)}")


def wait_for_external_testing(client, build_id, attempts, interval):
    submitted = False
    for attempt in range(1, attempts + 1):
        detail_attrs = beta_detail(client, build_id)["attributes"]
        review = review_submission(client, build_id)
        review_state = review["attributes"].get("betaReviewState") if review else None
        external_state = detail_attrs.get("externalBuildState")
        print_status(
            f"state {attempt}: internal={detail_attrs.get('internalBuildState')} "
            f"external={external_state} review={review_state}"
        )

        if external_state == "IN_BETA_TESTING":
            return
        if external_state == "READY_FOR_BETA_SUBMISSION" and not submitted:
            submit_beta_review(client, build_id)
            submitted = True
        elif external_state in ("MISSING_EXPORT_COMPLIANCE", "BETA_REJECTED", "EXPIRED"):
            raise RuntimeError(f"External TestFlight cannot continue: {external_state}")

        time.sleep(interval)

    raise RuntimeError("Timed out waiting for externalBuildState=IN_BETA_TESTING")


def notify_testers(client, build_id):
    status, payload = client.request(
        "POST",
        "/buildBetaNotifications",
        data={
            "data": {
                "type": "buildBetaNotifications",
                "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
            }
        },
        ok=(201,),
    )
    if status == 201:
        print_status(f"manual notification sent {payload['data']['id']}")
        return "manual notification sent"

    details = json.dumps(payload, ensure_ascii=False)
    if status == 409 and "Auto-notify already enabled" in details:
        print_status("manual notification skipped because auto-notify is already enabled")
        return "auto-notify already enabled"

    raise RuntimeError(f"Tester notification failed with HTTP {status}: {details}")


def final_summary(client, build_id):
    build = client.must("GET", f"/builds/{build_id}")["data"]["attributes"]
    detail = beta_detail(client, build_id)["attributes"]
    review = review_submission(client, build_id)
    localizations = client.must("GET", f"/builds/{build_id}/betaBuildLocalizations")["data"]
    whats_new = None
    for localization in localizations:
        attrs = localization["attributes"]
        if attrs.get("locale") == "en-US":
            whats_new = attrs.get("whatsNew")
            break

    print("final:")
    print(f"  buildId={build_id}")
    print(f"  buildNumber={build.get('version')}")
    print(f"  processingState={build.get('processingState')}")
    print(f"  internalBuildState={detail.get('internalBuildState')}")
    print(f"  externalBuildState={detail.get('externalBuildState')}")
    print(f"  autoNotifyEnabled={detail.get('autoNotifyEnabled')}")
    print(f"  betaReviewState={review['attributes'].get('betaReviewState') if review else None}")
    print(f"  whatsNew={whats_new}")


def main():
    parser = argparse.ArgumentParser(description="Release an uploaded InstacastPlus build to external TestFlight testers.")
    parser.add_argument("--build-number", required=True, help="CFBundleVersion/CURRENT_PROJECT_VERSION to release")
    parser.add_argument("--marketing-version", required=True, help="CFBundleShortVersionString, for example 3.4")
    parser.add_argument("--what-to-test", required=True, help="German user-facing TestFlight note")
    parser.add_argument("--locale", default="en-US")
    parser.add_argument("--app-id", default=DEFAULT_APP_ID)
    parser.add_argument("--external-group-id", default=DEFAULT_GROUP_ID)
    parser.add_argument("--key-id", default=DEFAULT_KEY_ID)
    parser.add_argument("--issuer-id", default=DEFAULT_ISSUER_ID)
    parser.add_argument("--key-path", default=DEFAULT_KEY_PATH)
    parser.add_argument("--poll-attempts", type=int, default=60)
    parser.add_argument("--poll-interval", type=int, default=30)
    args = parser.parse_args()

    client = ASCClient(args.key_id, args.issuer_id, args.key_path)
    build = wait_for_valid_build(
        client,
        args.app_id,
        args.build_number,
        args.marketing_version,
        args.poll_attempts,
        args.poll_interval,
    )
    build_id = build["id"]
    set_what_to_test(client, build_id, args.locale, args.what_to_test)
    enable_auto_notify(client, build_id)
    add_external_group(client, build_id, args.external_group_id)
    wait_for_external_testing(client, build_id, args.poll_attempts, args.poll_interval)
    notify_testers(client, build_id)
    final_summary(client, build_id)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
