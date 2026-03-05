#!/usr/bin/env python3
"""Download F1TV Android TV APKM bundle from APKMirror using Playwright."""

import argparse
import sys
import time
from pathlib import Path

from playwright.sync_api import sync_playwright, TimeoutError as PwTimeout


def download_apkm(release_url: str, output_dir: str) -> Path:
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
        )
        page = context.new_page()

        # Step 1: Navigate to release page
        print(f"Navigating to release page: {release_url}", file=sys.stderr)
        page.goto(release_url, wait_until="domcontentloaded", timeout=60000)
        # Wait for Cloudflare challenge if present
        page.wait_for_load_state("networkidle", timeout=30000)
        time.sleep(2)

        # Step 2: Find the APK bundle variant (APKM)
        # APKMirror lists variants in a table. Look for "APK Bundle" badge/text.
        # The variant rows contain links to the download page.
        print("Looking for APK Bundle variant...", file=sys.stderr)

        # Try to find a row/link that indicates an APK bundle
        bundle_link = None

        # Strategy 1: Look for a link near "APK Bundle" or "BUNDLE" text
        bundle_selectors = [
            # Table row containing "BUNDLE" with a download link
            "a.accent_color[href*='apk-download']",
            "a[href*='apk-bundle-download']",
        ]

        for selector in bundle_selectors:
            elements = page.query_selector_all(selector)
            for el in elements:
                href = el.get_attribute("href") or ""
                # Check if the parent row contains "BUNDLE" text
                row = el.evaluate(
                    "el => el.closest('tr, .table-row, .listWidget')?.textContent || ''"
                )
                if "BUNDLE" in row.upper() or "bundle" in href:
                    bundle_link = href
                    break
            if bundle_link:
                break

        # Strategy 2: Look for any download link with "bundle" in it
        if not bundle_link:
            all_links = page.query_selector_all("a[href]")
            for link in all_links:
                href = link.get_attribute("href") or ""
                text = link.inner_text().strip()
                if "bundle" in href.lower() or "bundle" in text.lower():
                    bundle_link = href
                    break

        # Strategy 3: Fall back to looking for the main download button
        # Sometimes the release page IS the bundle page already
        if not bundle_link:
            print(
                "WARN: Could not find bundle-specific link, trying generic download...",
                file=sys.stderr,
            )
            dl_btn = page.query_selector(
                "a.downloadButton, a[href*='download'], .download-button a"
            )
            if dl_btn:
                bundle_link = dl_btn.get_attribute("href")

        if not bundle_link:
            # Dump page for debugging
            debug_path = output_path / "debug_release_page.html"
            debug_path.write_text(page.content())
            print(f"ERROR: Could not find download link. Page saved to {debug_path}", file=sys.stderr)
            sys.exit(1)

        # Make absolute URL
        if bundle_link.startswith("/"):
            bundle_link = "https://www.apkmirror.com" + bundle_link

        # Step 3: Navigate to the download page
        print(f"Navigating to download page: {bundle_link}", file=sys.stderr)
        page.goto(bundle_link, wait_until="domcontentloaded", timeout=60000)
        page.wait_for_load_state("networkidle", timeout=30000)
        time.sleep(2)

        # Step 4: Find the actual download button
        # APKMirror download pages have a prominent download button
        download_btn = None
        download_selectors = [
            "a.downloadButton",
            "a[rel='nofollow'][data-google-vignette]",
            "#download-button",
            "a[href*='download.php']",
            "a[href*='wp-content']",
            ".card-with-tabs a[href*='download']",
            "a[rel='nofollow'][href*='key=']",
        ]

        for selector in download_selectors:
            download_btn = page.query_selector(selector)
            if download_btn:
                break

        # Broader search: any large/prominent link with "download" text
        if not download_btn:
            all_links = page.query_selector_all("a[href]")
            for link in all_links:
                text = link.inner_text().strip().lower()
                href = (link.get_attribute("href") or "").lower()
                if (
                    "download" in text
                    and "apk" in text
                    and "key=" not in href  # Skip already-visited links
                ):
                    download_btn = link
                    break

        if not download_btn:
            debug_path = output_path / "debug_download_page.html"
            debug_path.write_text(page.content())
            print(
                f"ERROR: Could not find download button. Page saved to {debug_path}",
                file=sys.stderr,
            )
            sys.exit(1)

        # Step 5: Click and wait for download
        print("Starting download...", file=sys.stderr)
        with page.expect_download(timeout=120000) as download_info:
            download_btn.click()

        download = download_info.value
        filename = download.suggested_filename or "f1tv-android-tv.apkm"
        save_path = output_path / filename
        download.save_as(str(save_path))

        print(f"Downloaded: {save_path} ({save_path.stat().st_size} bytes)", file=sys.stderr)
        browser.close()

    return save_path


def main():
    parser = argparse.ArgumentParser(description="Download F1TV APKM from APKMirror")
    parser.add_argument("release_url", help="APKMirror release page URL")
    parser.add_argument(
        "-o", "--output-dir", default=".", help="Output directory (default: cwd)"
    )
    args = parser.parse_args()

    path = download_apkm(args.release_url, args.output_dir)
    # Print the path for CI consumption
    print(str(path))


if __name__ == "__main__":
    main()
