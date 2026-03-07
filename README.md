# F1TV UHD Patcher

Automated pipeline that patches the F1TV Android TV app to enable UHD/4K playback on any device. (only tested on my own Nvidia Shield TV Pro)

## How it works

1. **Checks** APKPure every 3 hours for new F1TV Android TV releases
2. **Downloads** the app bundle — Google Play primary (arm64 native via NVIDIA Shield profile), APKPure and APKMirror as fallbacks
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

### Option 1: ADB from a computer (recommended and tested)

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
# Uninstall the original F1TV first (required — different signing key)
adb uninstall com.formulaone.production

# Use the install script (auto-extracts and auto-detects device config)
./scripts/install.sh f1tv-uhd-patched.apkm
# With ADB over WiFi:
./scripts/install.sh f1tv-uhd-patched.apkm 192.168.1.100:5555
```

Or install manually:

```bash
# Unzip the bundle
mkdir f1tv && cd f1tv && unzip ../f1tv-uhd-patched.apkm

# Install (adjust splits for your device — most Android TVs are arm64)
adb install-multiple base.apk \
  config.armeabi_v7a.apk \
  config.en.apk \
  config.xhdpi.apk
```

The install script accepts `.apkm`, `.xapk` files, or a directory of extracted APKs.

### Option 2: Send & install directly on the TV (not tested yet)

No computer needed after the initial download.

1. Download `f1tv-uhd-patched.apkm` from the [latest release](../../releases/latest) on your phone
2. Install [Split APKs Installer (SAI)](https://play.google.com/store/apps/details?id=com.mtv.sai&hl=en) on your Android TV (available on Play Store)
3. Transfer the `.apkm` file to your TV via:
   - **USB drive** — copy the file to a USB stick, plug it into the TV
   - **Send Files to TV** — install [this app](https://play.google.com/store/apps/details?id=com.yablio.sendfilestotv) on both your phone and TV, send the file over WiFi
   - **Google Drive / cloud** — upload to Drive, open it from the TV's file manager
4. Open SAI on the TV, select the `.apkm` file, and install

### Option 3: Wireless ADB apps (not tested yet)

If you don't have a computer but want a one-tap solution:

1. Install [Bugjaeger](https://play.google.com/store/apps/details?id=eu.sisik.hackendebug) on your Android phone
2. Enable ADB over network on your TV (see prerequisites above)
3. Connect Bugjaeger to your TV via its IP address
4. Use Bugjaeger to install the individual APK files

### Common split APKs

The bundle contains split APKs for different device configurations. You need `base.apk` plus the correct splits. Split names vary by source (`config.*` from APKPure, `split_config.*` from APKMirror, `com.formulaone.production.config.*` from Google Play):

| Split (any prefix) | When to include |
|---|---|
| `*.arm64_v8a.apk` | Most modern Android TVs (NVIDIA Shield, Chromecast, etc.) |
| `*.armeabi_v7a.apk` | Older 32-bit devices |
| `*.x86.apk` | Some emulators |
| `*.en.apk` | English — replace `en` with your language code |
| `*.xhdpi.apk` | Standard TV density — almost always needed |

> **Note:** You must uninstall the original F1TV app before installing the patched version (different signing key). This means you'll need to log in again.

## Setup your own pipeline

### 1. Fork and enable Actions

Fork this repo and enable GitHub Actions in the Actions tab.

### 2. Custom apkeep fork

The pipeline uses a custom build of [apkeep](https://github.com/EFForg/apkeep) with an NVIDIA Shield TV device profile added to [rs-google-play](https://github.com/EFForg/rs-google-play). This allows downloading the arm64 native variant directly from Google Play.

To set up your own:

1. Fork [EFForg/rs-google-play](https://github.com/EFForg/rs-google-play), add your device profile to `gpapi/device.properties`, delete `gpapi/src/device_properties.bin`, commit & push
2. Fork [EFForg/apkeep](https://github.com/EFForg/apkeep), change `Cargo.toml` to point `gpapi` at your rs-google-play fork, commit & push
3. Tag a release (`git tag v0.18.0-shield && git push origin v0.18.0-shield`) — the included workflow builds the binary automatically
4. Update `APKEEP_CUSTOM_TAG` in `patch.yml` to match your tag

A device profile dump script is included at `scripts/dump_device_props.sh` — connect your Android TV via ADB and run it to generate the profile.

### 3. Secrets

In **Settings > Secrets > Actions**, add:

| Secret | Purpose | Required |
|---|---|---|
| `GOOGLE_EMAIL` | Google account email for Play Store downloads | For Google Play |
| `GOOGLE_AAS_TOKEN` | Google AAS token ([how to obtain](https://github.com/EFForg/apkeep/blob/master/USAGE-google-play.md)) | For Google Play |
| `KEYSTORE_B64` | Base64-encoded signing keystore (persistent key across builds) | Recommended |
| `KEYSTORE_PASS` | Keystore password | Recommended |
| `KEYSTORE_ALIAS` | Key alias | Recommended |
| `PUSHOVER_APP_TOKEN` | Pushover app token for notifications | Optional |
| `PUSHOVER_USER_KEY` | Pushover user key for notifications | Optional |

Without Google Play credentials, the pipeline falls back to APKPure (armeabi-v7a only) and APKMirror automatically.

**Generate a persistent keystore:**

```bash
keytool -genkeypair -keystore f1tv.keystore -storepass yourpass \
  -keypass yourpass -alias f1tvpatch -keyalg RSA -keysize 2048 \
  -validity 10000 -dname "CN=F1TV UHD Patch"

# Encode and add as KEYSTORE_B64 secret
base64 -w0 f1tv.keystore
```

Without a persistent keystore, a new key is generated each build — you'll need to uninstall before each update.

### 4. Manual trigger

If the automatic download fails, you can trigger the workflow manually:

- **With direct URL**: Go to Actions > F1TV UHD Patch > Run workflow, paste an `.apkm` URL
- **Force rebuild**: Check the "Force rebuild" option to re-patch an existing version

## Project structure

```
.github/workflows/patch.yml   # CI pipeline (check, download, patch, release)
scripts/
  check_version.py             # APKMirror RSS parser (fallback version check)
  download_apkm.py             # Playwright-based APKMirror downloader (fallback)
  patch.sh                     # Smali patching, signing, bundling
  install.sh                   # ADB install helper (accepts .apkm, .xapk, or directory)
  dump_device_props.sh         # Dump Android TV device profile for rs-google-play
device_profiles/
  nvidia_shield_tv.properties  # NVIDIA Shield TV profile for Google Play downloads
```

## Requirements (local use)

Only needed if running scripts locally outside CI:

- Python 3.10+, Playwright (`pip install playwright && playwright install chromium`)
- Java, apktool, zipalign, apksigner
- ADB (for install.sh)

## License

For personal/educational use only.
