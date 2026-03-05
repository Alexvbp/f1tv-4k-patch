# F1TV UHD Patch Pipeline

Automated pipeline that patches the F1TV Android TV app to enable UHD/4K playback on any device.

## How it works

1. **Checks** the APKMirror RSS feed hourly for new F1TV Android TV releases
2. **Downloads** the APKM bundle automatically via headless browser
3. **Patches** the `validateIsUhdSupportedDevice` smali method to always return `true`
4. **Signs** all APKs with a consistent keystore
5. **Publishes** the patched bundle as a GitHub Release
6. **Notifies** via Pushover when a new patch is ready (or if it fails)

## Install a patched release

Download `f1tv-uhd-patched.apkm` from the [latest release](../../releases/latest), then:

```bash
# Unzip the bundle
mkdir f1tv && cd f1tv && unzip ../f1tv-uhd-patched.apkm

# Install via ADB (adjust splits for your device)
adb install-multiple base.apk \
  split_config.arm64_v8a.apk \
  split_config.en.apk \
  split_config.xhdpi.apk
```

Or use the helper script which auto-detects your device's architecture and locale:

```bash
./scripts/install.sh ./f1tv/
# With ADB over WiFi:
./scripts/install.sh ./f1tv/ 192.168.1.100:5555
```

## Setup your own pipeline

### 1. Fork and enable Actions

Fork this repo and enable GitHub Actions in the Actions tab.

### 2. Secrets (optional but recommended)

In **Settings > Secrets > Actions**, add:

| Secret | Purpose |
|---|---|
| `KEYSTORE_B64` | Base64-encoded signing keystore (persistent key across builds) |
| `KEYSTORE_PASS` | Keystore password |
| `KEYSTORE_ALIAS` | Key alias |
| `PUSHOVER_APP_TOKEN` | Pushover app token for notifications |
| `PUSHOVER_USER_KEY` | Pushover user key for notifications |

**Generate a persistent keystore:**

```bash
keytool -genkeypair -keystore f1tv.keystore -storepass yourpass \
  -keypass yourpass -alias f1tvpatch -keyalg RSA -keysize 2048 \
  -validity 10000 -dname "CN=F1TV UHD Patch"

# Encode and add as KEYSTORE_B64 secret
base64 -w0 f1tv.keystore
```

Without a persistent keystore, a new key is generated each build — you'll need to uninstall before each update.

### 3. Manual trigger

If the automatic APKMirror download fails (Cloudflare), you can trigger the workflow manually:

- **With direct URL**: Go to Actions > F1TV UHD Patch > Run workflow, paste an `.apkm` URL
- **Force rebuild**: Check the "Force rebuild" option to re-patch an existing version

## Project structure

```
.github/workflows/patch.yml  # CI pipeline (check, download, patch, release)
scripts/
  check_version.py            # RSS feed parser
  download_apkm.py            # Playwright-based APKMirror downloader
  patch.sh                    # Smali patching, signing, bundling
  install.sh                  # ADB install helper
```

## Requirements (local use)

Only needed if running scripts locally outside CI:

- Python 3.10+, Playwright (`pip install playwright && playwright install chromium`)
- Java, apktool, zipalign, apksigner
- ADB (for install.sh)
