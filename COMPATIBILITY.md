# Known Working / Not Working Devices

This file tracks compatibility reports for the F1TV UHD Patcher. If you are testing a device, consider contributing your findings here.

## Working ✅

| Device / Model | Status | Notes |
|---|---|---|
| NVIDIA Shield TV Pro (2019) | Working | Tested with arm64 build, outputs 4K SDR downconvert on HDR10 panel. |
| Chromecast with Google TV (4K) | Working | arm64 build works out of the box. |
| Xiaomi Mi Box S | Working | Requires `arm64_v8a` split; 4K playback confirmed. |
| Sony Google TV (XR series) | Working | Native 4K/HDR support; full HLG output on compatible displays. |

## Not Working / Known Issues ❌

| Device / Model | Status | Notes |
|---|---|---|
| NVIDIA Shield TV (2015) | Not Working | 32-bit SoC; cannot allocate secure HEVC decoder for 4K (`TM4014` error). |
| Amazon Fire TV Stick (4K Max) | Not Working | FireOS restricts ADB/side-loading patched apps; clearvr fails without native Google Play services integration. |
| Android TV boxes with Amlogic S905W | Partial / Laggy | Weak GPU drops frames on the GL path. Since the runtime render-path change the core should route these to its direct decoder→view path automatically (GPU has no BT2020 EGL colorspace) — **needs re-testing**, please report. |
| MediaTek TVs (Philips OLED 80x, Formovie / Hisense MT9629, Sony Bravia) | Needs testing | 32-bit (`armeabi-v7a`) Android TV. Up to 3.0.49.4 these hit `TM4014` / HDR flicker because the patched app forced the GL HDR path. Now reported honestly to the core → direct path (the shield-4k-hdr-unlock pre-release, which used direct-to-view, was reported working on a Formovie MT9629). Please report with `scripts/capture_logs.sh` output. |
| Older 32-bit Android TVs (armeabi-v7a only) | Not Working | F1TV requires arm64 for hardware-accelerated 4K decoding; app may crash or cap at 1080p. |

## How to Report

If you are using a device not listed above, please open a new issue with:
- **Device Model**
- **Android Version**
- **CPU ABI** (`adb shell getprop ro.product.cpu.abi`)
- **Display Type** (HDR10 / HLG / SDR)
- **Observed Behavior** (e.g., capped at 1620p, crashes, washed-out colours, frame drops)
