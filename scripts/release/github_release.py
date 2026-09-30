#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import mimetypes
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


API = "https://api.github.com"


def request(token: str, method: str, url: str, data: bytes | None = None, content_type: str = "application/json"):
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if data is not None:
        req.add_header("Content-Type", content_type)
        req.add_header("Content-Length", str(len(data)))
    try:
        with urllib.request.urlopen(req) as response:
            payload = response.read()
            return response.status, json.loads(payload) if payload else None
    except urllib.error.HTTPError as exc:
        payload = exc.read().decode("utf-8", "replace")
        if exc.code == 404:
            return 404, None
        raise SystemExit(f"GitHub API {method} {url} failed ({exc.code}): {payload}") from exc


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--repo", required=True)
    p.add_argument("--tag", required=True)
    p.add_argument("--title", required=True)
    p.add_argument("--notes", type=Path, required=True)
    p.add_argument("--asset", type=Path, required=True)
    p.add_argument("--target", default="main")
    args = p.parse_args()

    token = os.environ.get("GITHUB_TOKEN", "")
    if not token:
        raise SystemExit("GITHUB_TOKEN is not set")

    encoded_tag = urllib.parse.quote(args.tag, safe="")
    status, release = request(token, "GET", f"{API}/repos/{args.repo}/releases/tags/{encoded_tag}")
    body = args.notes.read_text()
    payload = json.dumps(
        {
            "tag_name": args.tag,
            "target_commitish": args.target,
            "name": args.title,
            "body": body,
            "draft": False,
            "prerelease": False,
            "make_latest": "true",
        }
    ).encode()

    if status == 404:
        _, release = request(token, "POST", f"{API}/repos/{args.repo}/releases", payload)
    else:
        _, release = request(token, "PATCH", release["url"], payload)

    if not release:
        raise SystemExit("GitHub did not return a release object")

    _, assets = request(token, "GET", release["assets_url"])
    for asset in assets or []:
        if asset.get("name") == args.asset.name:
            request(token, "DELETE", asset["url"])

    upload_url = release["upload_url"].split("{", 1)[0]
    upload_url += "?name=" + urllib.parse.quote(args.asset.name)
    content_type = mimetypes.guess_type(args.asset.name)[0] or "application/octet-stream"
    data = args.asset.read_bytes()
    request(token, "POST", upload_url, data, content_type)
    print(release["html_url"])


if __name__ == "__main__":
    main()
