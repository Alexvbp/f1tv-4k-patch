# F1TV UHD Patcher

Automated pipeline that patches the F1TV Android TV app to enable UHD/4K playback on any device.

## How it works

1. **Checks** the APKMirror RSS feed hourly for new F1TV Android TV releases
2. **Downloads** the APKM bundle automatically via headless browser
3. **Patches** the `validateIsUhdSupportedDevice` smali method to always return `true`
4. **Signs** all APKs with a consistent keystore
5. **Publishes** the patched bundle as a GitHub Release
6. **Notifies** via Pushover when a new patch is ready (or if it fails)

## Installing on your Android TV

### Prerequisites: Enable Developer Options & ADB

1. On your Android TV, go to **Settings > Device Preferences > About**
2. Scroll to **Build** and click it **7 times** to enable Developer Options
3. Go back to **Settings > Device Preferences > Developer Options**
4. Enable **USB debugging** (and **ADB over network** if installing wirelessly)
5. Note the **IP address** shown under Settings > Network & Internet, or Device Preferences > About > Status

### Option 1: ADB from a computer (recommended)

Install ADB on your computer ([download platform-tools](https://developer.android.com/tools/releases/platform-tools)) and add it to your PATH.

**Via USB:**
```bash
# Connect your Android TV via USB cable, then:
adb devices  # Confirm it shows up — approve the prompt on your TV
```

**Via WiFi:**
```bash
adb connect 192.168.1.100:5555  # Replace with your TV's IP
# Approve the connection prompt on your TV
```

Then download `f1tv-uhd-patched.apkm` from the [latest release](../../releases/latest) and install:

```bash
# Unzip the bundle
mkdir f1tv && cd f1tv && unzip ../f1tv-uhd-patched.apkm

# Uninstall the original F1TV first (required — different signing key)
adb uninstall com.formulaone.production

# Install (adjust splits for your device — most Android TVs are arm64)
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

### Option 2: Send & install directly on the TV

No computer needed after the initial download.

1. Download `f1tv-uhd-patched.apkm` from the [latest release](../../releases/latest) on your phone
2. Install [Split APKs Installer (SAI)](https://play.google.com/store/apps/details?id=com.aefyr.sai) on your Android TV (available on Play Store)
3. Transfer the `.apkm` file to your TV via:
   - **USB drive** — copy the file to a USB stick, plug it into the TV
   - **Send Files to TV** — install [this app](https://play.google.com/store/apps/details?id=com.yablio.sendfilestotv) on both your phone and TV, send the file over WiFi
   - **Google Drive / cloud** — upload to Drive, open it from the TV's file manager
4. Open SAI on the TV, select the `.apkm` file, and install

### Option 3: Wireless ADB apps

If you don't have a computer but want a one-tap solution:

1. Install [Bugjaeger](https://play.google.com/store/apps/details?id=eu.sisik.hackendebug) on your Android phone
2. Enable ADB over network on your TV (see prerequisites above)
3. Connect Bugjaeger to your TV via its IP address
4. Use Bugjaeger to install the individual APK files

### Common split APKs

| Split | When to include |
|---|---|
| `split_config.arm64_v8a.apk` | Most modern Android TVs (NVIDIA Shield, Chromecast, etc.) |
| `split_config.armeabi_v7a.apk` | Older 32-bit devices |
| `split_config.x86.apk` | Some emulators |
| `split_config.en.apk` | English — replace `en` with your language code |
| `split_config.xhdpi.apk` | Standard TV density — almost always needed |

> **Note:** You must uninstall the original F1TV app before installing the patched version (different signing key). This means you'll need to log in again.

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

## License

For personal/educational use only.
