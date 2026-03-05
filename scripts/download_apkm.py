#!/usr/bin/env python3
"""Download F1TV Android TV APKM bundle from APKMirror using Playwright.

APKMirror download flow (3 pages):
  1. Release page   → table of variants (APK, APK Bundle, etc.)
  2. Variant page    → "Download APK Bundle" button with ?key= param
  3. Download page   → countdown timer, then file download auto-starts

Screenshots are saved at each step for debugging CI failures.
"""

import argparse
import sys
import time
from pathlib import Path

from playwright.sync_api import sync_playwright, TimeoutError as PwTimeout

BASE = "https://www.apkmirror.com"


def log(msg: str):
    print(f"[download] {msg}", file=sys.stderr, flush=True)


def screenshot(page, output_dir: Path, name: str):
    path = output_dir / f"debug_{name}.png"
    page.screenshot(path=str(path), full_page=True)
    log(f"  screenshot: {path}")


def wait_for_cloudflare(page, timeout: int = 15):
    """Wait for Cloudflare challenge to resolve if present."""
    for i in range(timeout):
        title = page.title().lower()
        if "just a moment" in title or "checking" in title or "cloudflare" in title:
            if i == 0:
                log("  Cloudflare challenge detected, waiting...")
            time.sleep(1)
        else:
            return
    log("  WARN: Cloudflare may not have resolved")


def find_bundle_variant_url(page) -> str | None:
    """On the release page, find the APK Bundle variant link."""

    # APKMirror release pages have a variants table.
    # Each row has: badge (APK/BUNDLE), architecture, DPI, minAPI, and a download icon link.
    # We want the row with "BUNDLE" badge.

    # Strategy 1: find rows containing "BUNDLE" or "APK Bundle" text
    rows = page.query_selector_all(".variants-table .table-row, .variants-table tr")
    for row in rows:
        text = row.inner_text().upper()
        if "BUNDLE" in text:
            link = row.query_selector("a[href*='apk-download']")
            if link:
                return link.get_attribute("href")

    # Strategy 2: broader search — any link near "BUNDLE" text
    all_links = page.query_selector_all("a[href*='apk-download']")
    for link in all_links:
        parent_text = link.evaluate(
            "el => (el.closest('.table-row, tr, .list-widget') || el.parentElement).textContent || ''"
        )
        if "BUNDLE" in parent_text.upper():
            return link.get_attribute("href")

    # Strategy 3: if the page itself has a downloadButton (we may already be on the variant page)
    btn = page.query_selector("a.downloadButton[href*='download/?key=']")
    if btn:
        return None  # Signal that we're already on the variant page

    return None


def find_download_button(page) -> str | None:
    """On the variant page, find the download button href (with ?key= param)."""

    # The exact selector from the user's HTML:
    # <a rel="nofollow" class="accent_bg btn btn-flat downloadButton wST"
    #    href="/.../download/?key=...">Download APK Bundle</a>
    selectors = [
        "a.downloadButton[href*='download/?key=']",
        "a.downloadButton[href*='key=']",
        "a.downloadButton",
    ]
    for sel in selectors:
        btn = page.query_selector(sel)
        if btn:
            href = btn.get_attribute("href")
            if href:
                return href

    return None


def download_from_trigger_page(page, output_dir: Path, timeout: int = 120) -> Path | None:
    """On the download trigger page (/download/?key=...), wait for file download.

    APKMirror shows a countdown, then auto-starts the download via JS.
    Sometimes there's also a manual "click here" fallback link.
    """

    log("  Waiting for download to start (auto-trigger via JS)...")
    download_path = None

    # Try to catch auto-triggered download
    try:
        with page.expect_download(timeout=timeout * 1000) as dl_info:
            # The download trigger page may need us to wait — the JS on the page
            # will start the download after a countdown. We just need to be patient.
            # If there's a manual link, click it after a short wait as a nudge.
            time.sleep(10)

            # If download hasn't started yet, look for a manual trigger
            manual = page.query_selector(
                "a[href*='.apkm'], a[href*='.apks'], "
                "a#safeDownloadButton, "
                "a.downloadButton, "
                "a[data-google-vignette][href*='key=']"
            )
            if manual:
                log("  Found manual download link, clicking...")
                manual.click()

        download = dl_info.value
        filename = download.suggested_filename or "f1tv-android-tv.apkm"
        save_path = output_dir / filename
        download.save_as(str(save_path))
        size_mb = save_path.stat().st_size / (1024 * 1024)
        log(f"  Downloaded: {filename} ({size_mb:.1f} MB)")
        return save_path

    except PwTimeout:
        log("  WARN: expect_download timed out")
        screenshot(page, output_dir, "download_timeout")
        return None


def download_apkm(release_url: str, variant_url: str | None, output_dir: str) -> Path:
    output_path = Path(output_dir)
    output_path.mkdir(parents=True, exist_ok=True)

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context(
            user_agent=(
                "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
            ),
            viewport={"width": 1920, "height": 1080},
            accept_downloads=True,
        )
        page = context.new_page()

        # ── Step 1: Navigate to release page ──────────────────────────
        log(f"Step 1: Loading release page: {release_url}")
        page.goto(release_url, wait_until="domcontentloaded", timeout=60000)
        wait_for_cloudflare(page)
        page.wait_for_load_state("networkidle", timeout=30000)
        screenshot(page, output_path, "01_release_page")
        log(f"  Page title: {page.title()}")

        # ── Step 2: Find the APK Bundle variant ───────────────────────
        log("Step 2: Looking for APK Bundle variant...")
        bundle_href = find_bundle_variant_url(page)
        already_on_variant_page = False

        if bundle_href is None:
            # Check if we're already on the variant page (download button present)
            if page.query_selector("a.downloadButton[href*='key=']"):
                log("  Already on variant page (download button found)")
                already_on_variant_page = True
            else:
                screenshot(page, output_path, "02_no_bundle_found")
                # Try the direct variant URL from RSS as fallback
                if variant_url:
                    log(f"  Falling back to RSS variant URL: {variant_url}")
                    bundle_href = variant_url
                else:
                    log("ERROR: Could not find APK Bundle variant on release page")
                    sys.exit(1)
        else:
            log(f"  Found variant link: {bundle_href}")

        # ── Step 3: Navigate to variant page ──────────────────────────
        if not already_on_variant_page:
            if bundle_href and bundle_href.startswith("/"):
                bundle_href = BASE + bundle_href

            log(f"Step 3: Loading variant page: {bundle_href}")
            page.goto(bundle_href, wait_until="domcontentloaded", timeout=60000)
            wait_for_cloudflare(page)
            page.wait_for_load_state("networkidle", timeout=30000)
        else:
            log("Step 3: Skipped (already on variant page)")

        screenshot(page, output_path, "03_variant_page")
        log(f"  Page title: {page.title()}")

        # ── Step 4: Find the download button ──────────────────────────
        log("Step 4: Looking for download button...")
        key_href = find_download_button(page)

        if not key_href:
            screenshot(page, output_path, "04_no_download_btn")
            log("ERROR: Could not find download button (a.downloadButton with ?key=)")
            sys.exit(1)

        if key_href.startswith("/"):
            key_href = BASE + key_href

        log(f"  Download button URL: {key_href}")

        # ── Step 5: Navigate to download trigger page ─────────────────
        log("Step 5: Loading download trigger page...")
        page.goto(key_href, wait_until="domcontentloaded", timeout=60000)
        wait_for_cloudflare(page)
        page.wait_for_load_state("networkidle", timeout=30000)
        screenshot(page, output_path, "05_download_trigger_page")
        log(f"  Page title: {page.title()}")

        # ── Step 6: Wait for the actual file download ─────────────────
        log("Step 6: Waiting for file download...")
        save_path = download_from_trigger_page(page, output_path, timeout=120)

        if not save_path:
            # Last resort: dump the page for manual debugging
            debug_html = output_path / "debug_trigger_page.html"
            debug_html.write_text(page.content())
            log(f"ERROR: Download did not start. HTML saved to {debug_html}")
            log("Hint: trigger the workflow manually with a direct APKM URL instead.")
            sys.exit(1)

        browser.close()

    return save_path


def main():
    parser = argparse.ArgumentParser(description="Download F1TV APKM from APKMirror")
    parser.add_argument("release_url", help="APKMirror release page URL")
    parser.add_argument(
        "--variant-url",
        default=None,
        help="Direct variant page URL (fallback if bundle not found on release page)",
    )
    parser.add_argument(
        "-o", "--output-dir", default=".", help="Output directory (default: cwd)"
    )
    args = parser.parse_args()

    path = download_apkm(args.release_url, args.variant_url, args.output_dir)
    # Print path to stdout for CI consumption
    print(str(path))


if __name__ == "__main__":
    main()
