#!/usr/bin/env python3
"""Check APKMirror RSS feed for new F1TV Android TV versions."""

import json
import os
import re
import sys
import xml.etree.ElementTree as ET
from urllib.request import Request, urlopen

FEED_URL = (
    "https://www.apkmirror.com/apk/formula-one-digital-media-limited/"
    "f1-tv-android-tv/variant-%7B%22minapi_slug%22%3A%22minapi-25%22%7D/feed/"
)

def fetch_feed(retries: int = 3):
    for attempt in range(retries):
        try:
            req = Request(FEED_URL, headers={"User-Agent": "Mozilla/5.0"})
            with urlopen(req, timeout=30) as resp:
                return resp.read().decode()
        except Exception as e:
            if attempt < retries - 1:
                wait = 5 * (attempt + 1)
                print(f"Attempt {attempt + 1} failed: {e}, retrying in {wait}s...", file=sys.stderr)
                import time
                time.sleep(wait)
            else:
                raise


def parse_latest(xml_text: str) -> dict | None:
    root = ET.fromstring(xml_text)
    item = root.find(".//channel/item")
    if item is None:
        return None

    title = item.findtext("title", "").strip()
    link = item.findtext("link", "").strip()
    pub_date = item.findtext("pubDate", "").strip()

    # Extract version string from title
    # e.g. "F1 TV (Android TV) 3.0.47.1-SP153.10.0-release-r51-tv ..."
    m = re.search(r"F1 TV \(Android TV\)\s+([\d.]+-\S+?-tv)", title)
    version = m.group(1) if m else None

    # Short version for the release tag (e.g. "3.0.47.1")
    m2 = re.search(r"([\d]+(?:\.[\d]+)+)", version) if version else None
    version_short = m2.group(1) if m2 else None

    # Derive release page URL (strip variant-specific suffix)
    # RSS link: .../f1-tv-...-release/f1-tv-...-android-apk-download/
    # Release page: .../f1-tv-...-release/
    release_url = link
    if link.count("/") > 6:
        parts = link.rstrip("/").rsplit("/", 1)
        release_url = parts[0] + "/"

    return {
        "title": title,
        "link": link,
        "release_url": release_url,
        "pub_date": pub_date,
        "version": version,
        "version_short": version_short,
    }


def main():
    xml_text = fetch_feed()
    latest = parse_latest(xml_text)
    if not latest or not latest["version"]:
        print("ERROR: Could not parse latest version from feed", file=sys.stderr)
        sys.exit(1)

    print(f"Latest: {latest['version']}", file=sys.stderr)
    print(f"Release URL: {latest['release_url']}", file=sys.stderr)

    # Write to GITHUB_OUTPUT if running in CI
    github_output = os.environ.get("GITHUB_OUTPUT")
    if github_output:
        with open(github_output, "a") as f:
            f.write(f"version={latest['version']}\n")
            f.write(f"version_short={latest['version_short']}\n")
            f.write(f"release_url={latest['release_url']}\n")
            f.write(f"variant_url={latest['link']}\n")
            f.write(f"title={latest['title']}\n")
    else:
        # Print JSON for local use
        print(json.dumps(latest, indent=2))


if __name__ == "__main__":
    main()
