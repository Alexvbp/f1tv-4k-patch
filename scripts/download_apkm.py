#!/usr/bin/env python3
"""Download F1TV Android TV APKM bundle from APKMirror using Playwright.

APKMirror download flow (3 pages):
  1. Release page   -> table of variants (APK, APK Bundle, etc.)
  2. Variant page    -> "Download APK Bundle" button with ?key= param
  3. Download page   -> countdown timer, then file download auto-starts

Screenshots are saved at each step for debugging CI failures.
"""

import argparse
import sys
import time
from pathlib import Path

from playwright.sync_api import sync_playwright, TimeoutError as PwTimeout

BASE = "https://www.apkmirror.com"

# Block ad/tracking domains at the network level.
AD_DOMAIN_KEYWORDS = [
    "doubleclick.net",
    "googlesyndication.com",
    "googleadservices.com",
    "google-analytics.com",
    "googletagmanager.com",
    "googletagservices.com",
    "adservice.google",
    "pagead2.googlesyndication",
    "tpc.googlesyndication",
    "fundingchoicesmessages.google",
    "amazon-adsystem.com",
    "adskeeper.co.uk",
    "adnxs.com",
    "adsrvr.org",
    "outbrain.com",
    "taboola.com",
    "criteo.com",
    "pubmatic.com",
    "rubiconproject.com",
    "openx.net",
    "casalemedia.com",
    "moatads.com",
    "serving-sys.com",
    "quantserve.com",
    "scorecardresearch.com",
    "hotjar.com",
    "facebook.net",
    "connect.facebook",
    "cdn.privacy-mgmt.com",
    "sp-prod.net",
    "consent.cookiebot",
    "consensu.org",
    "gstatic.com/adsense",
]

# JS to nuke ad overlays, modals, and consent banners from the DOM.
NUKE_ADS_JS = """
() => {
    // Remove elements by common ad selectors
    const selectors = [
        '[id*="google_ads"]', '[id*="aswift"]', '[id*="ad-"]', '[id*="ad_"]',
        '[class*="ad-overlay"]', '[class*="ad-container"]', '[class*="ad-wrapper"]',
        '[class*="interstitial"]', '[class*="modal-backdrop"]',
        'iframe[src*="doubleclick"]', 'iframe[src*="googlesyndication"]',
        'iframe[id*="aswift"]', 'iframe[id*="google_ads"]',
        '[id*="consent"]', '[class*="consent"]', '[class*="cookie-banner"]',
        '.fc-dialog-container', '.fc-consent-root', '#cmpbox', '#cmpbox2',
        '[id*="sp_message"]', '[class*="sp_message"]',
    ];
    let removed = 0;
    for (const sel of selectors) {
        for (const el of document.querySelectorAll(sel)) {
            el.remove();
            removed++;
        }
    }
    // Remove any fixed/sticky overlays covering the page
    for (const el of document.querySelectorAll('div, aside, section')) {
        const style = window.getComputedStyle(el);
        if ((style.position === 'fixed' || style.position === 'sticky') &&
            parseFloat(style.zIndex) > 999 &&
            el.offsetWidth > window.innerWidth * 0.5 &&
            el.offsetHeight > window.innerHeight * 0.3) {
            el.remove();
            removed++;
        }
    }
    // Reset body overflow in case ads locked scrolling
    document.body.style.overflow = 'auto';
    document.documentElement.style.overflow = 'auto';
    return removed;
}
"""


def log(msg: str):
    print(f"[download] {msg}", file=sys.stderr, flush=True)


def screenshot(page, output_dir: Path, name: str):
    path = output_dir / f"debug_{name}.png"
    page.screenshot(path=str(path), full_page=True)
    log(f"  screenshot: {path}")


def nuke_ads(page):
    """Remove ad overlays and modals from the DOM."""
    try:
        removed = page.evaluate(NUKE_ADS_JS)
        if removed:
            log(f"  Removed {removed} ad/overlay elements")
    except Exception:
        pass  # Page may be navigating


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

    # Strategy 1: find rows containing "BUNDLE" text in the variants table
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

        # Block ad/tracking requests at the network level
        def block_ads(route):
            route.abort()

        for domain in AD_DOMAIN_KEYWORDS:
            page.route(f"**/*{domain}*", block_ads)
        log("Ad blocker active (network-level)")

        # ── Step 1: Navigate to release page ──────────────────────────
        log(f"Step 1: Loading release page: {release_url}")
        page.goto(release_url, wait_until="domcontentloaded", timeout=60000)
        wait_for_cloudflare(page)
        page.wait_for_load_state("networkidle", timeout=30000)
        nuke_ads(page)
        screenshot(page, output_path, "01_release_page")
        log(f"  Page title: {page.title()}")

        # ── Step 2: Find the APK Bundle variant ───────────────────────
        log("Step 2: Looking for APK Bundle variant...")
        already_on_variant = bool(
            page.query_selector("a.downloadButton[href*='key=']")
        )

        if already_on_variant:
            log("  Already on variant page (download button present)")
        else:
            bundle_href = find_bundle_variant_url(page)
            if not bundle_href:
                screenshot(page, output_path, "02_no_bundle_found")
                if variant_url:
                    log(f"  Bundle variant not found, falling back to RSS variant URL")
                    bundle_href = variant_url
                else:
                    log("ERROR: Could not find APK Bundle variant on release page")
                    sys.exit(1)

            if bundle_href.startswith("/"):
                bundle_href = BASE + bundle_href

            log(f"  Navigating to variant page: {bundle_href}")
            page.goto(bundle_href, wait_until="domcontentloaded", timeout=60000)
            wait_for_cloudflare(page)
            page.wait_for_load_state("networkidle", timeout=30000)

        nuke_ads(page)
        screenshot(page, output_path, "03_variant_page")
        log(f"  Page title: {page.title()}")

        # ── Step 3: Find the download button ──────────────────────────
        # The button:
        #   <a rel="nofollow" class="accent_bg btn btn-flat downloadButton wST"
        #      href="/.../download/?key=...">Download APK Bundle</a>
        log("Step 3: Finding download button...")

        btn_selector = "a.downloadButton"
        try:
            page.wait_for_selector(btn_selector, timeout=15000)
        except PwTimeout:
            screenshot(page, output_path, "04_no_download_btn")
            links = page.evaluate("""
                () => Array.from(document.querySelectorAll('a')).slice(0, 30).map(
                    a => ({class: a.className, href: a.href, text: a.textContent.trim().substring(0, 80)})
                )
            """)
            log(f"  Page has these links: {links}")
            log("ERROR: Download button not found (a.downloadButton)")
            sys.exit(1)

        # Extract the href via JS to confirm we have the right element
        btn_info = page.evaluate("""
            () => {
                const btn = document.querySelector('a.downloadButton');
                if (!btn) return null;
                return { href: btn.href, text: btn.textContent.trim(), classes: btn.className };
            }
        """)
        log(f"  Found button: {btn_info}")

        # ── Step 4: Navigate to download trigger page ─────────────────
        #   page.click() fails when ad overlays intercept the click event,
        #   even after removing them (new ones can spawn).
        #   Instead, extract the href and navigate via JS (window.location),
        #   which is immune to overlay interception.
        log("Step 4: Navigating to download trigger page via JS...")

        # Set up download listener BEFORE navigating
        download_event = None

        def on_download(dl):
            nonlocal download_event
            download_event = dl
            log("  >> Download event received!")

        page.on("download", on_download)

        # Extract href first, then navigate properly with expect_navigation
        key_href = page.evaluate("""
            () => {
                const btn = document.querySelector('a.downloadButton');
                return btn ? btn.href : null;
            }
        """)

        if not key_href:
            log("ERROR: Could not extract download button href")
            sys.exit(1)

        log(f"  Navigating to: {key_href}")

        # Use page.goto instead of window.location to avoid context destruction
        page.goto(key_href, wait_until="domcontentloaded", timeout=60000)
        wait_for_cloudflare(page)
        nuke_ads(page)

        screenshot(page, output_path, "05_trigger_page")
        log(f"  Trigger page title: {page.title()}")

        # ── Step 5: Wait for auto-download ────────────────────────────
        # The trigger page runs a JS countdown, then auto-starts download.
        # We poll for the download event with a generous timeout.
        log("Step 5: Waiting for file download to start...")

        timeout_secs = 120
        poll_interval = 1
        elapsed = 0
        while download_event is None and elapsed < timeout_secs:
            time.sleep(poll_interval)
            elapsed += poll_interval
            if elapsed % 10 == 0:
                log(f"  Still waiting... ({elapsed}s elapsed)")

            # After 15s, try clicking any manual/fallback download link
            if elapsed == 15 and download_event is None:
                manual_selectors = [
                    "a#safeDownloadButton",
                    "a.downloadButton",
                    "a[href*='.apkm']",
                    "a[href*='.apks']",
                ]
                for sel in manual_selectors:
                    manual = page.query_selector(sel)
                    if manual:
                        log(f"  Clicking fallback link: {sel}")
                        manual.click()
                        break

        if download_event is None:
            screenshot(page, output_path, "06_download_timeout")
            debug_html = output_path / "debug_trigger_page.html"
            debug_html.write_text(page.content())
            log(f"ERROR: Download did not start after {timeout_secs}s")
            log(f"  Trigger page HTML saved to {debug_html}")
            log("Hint: re-run the workflow with a direct APKM URL instead.")
            sys.exit(1)

        # Save the downloaded file
        filename = download_event.suggested_filename or "f1tv-android-tv.apkm"
        save_path = output_path / filename
        download_event.save_as(str(save_path))
        size_mb = save_path.stat().st_size / (1024 * 1024)
        log(f"  Saved: {filename} ({size_mb:.1f} MB)")

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
