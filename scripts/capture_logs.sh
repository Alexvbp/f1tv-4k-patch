#!/usr/bin/env bash
set -euo pipefail

# Collect the device info + player logs needed to debug a playback problem
# (video error pop-ups, TM40xx codes, HDR flicker, 1620p cap, no 4K...).
#
# Usage: ./scripts/capture_logs.sh [device-ip:5555] [seconds]
#
#   1. Run this script, then start the stream that misbehaves on the TV.
#   2. Reproduce the problem (wait for the error / flicker / cap).
#   3. Press Ctrl+C (or wait for the timeout). Attach the printed .txt to the
#      GitHub issue. It contains only player/decoder/display log lines.

DEVICE_ADDR="${1:-}"
DURATION="${2:-120}"
OUT="f1tv-logs-$(date +%Y%m%d-%H%M%S).txt"

if [[ -n "${DEVICE_ADDR}" ]]; then
    adb connect "${DEVICE_ADDR}" >/dev/null 2>&1 || true
fi
adb devices 2>/dev/null | grep -qw 'device' || { echo "No ADB device connected" >&2; exit 1; }

{
    echo "=== Device ==="
    for p in ro.product.manufacturer ro.product.model ro.product.device ro.board.platform \
             ro.build.version.release ro.build.version.sdk ro.product.cpu.abilist; do
        printf '%-32s %s\n' "$p" "$(adb shell getprop "$p" 2>/dev/null | tr -d '\r')"
    done
    echo
    echo "=== F1TV package ==="
    adb shell dumpsys package com.formulaone.production 2>/dev/null \
        | grep -E 'versionName|primaryCpuAbi|splits=' | sed 's/^ *//' || true
    echo
    echo "=== Display / HDR ==="
    adb shell dumpsys display 2>/dev/null | grep -oE 'DisplayDeviceInfo\{[^}]*' | head -3 || true
    adb shell dumpsys display 2>/dev/null | grep -oE 'HdrCapabilities\{[^}]*\}' | sort -u || true
    echo
    echo "=== EGL extensions (BT2020 colorspaces decide the HDR render path) ==="
    adb shell dumpsys SurfaceFlinger 2>/dev/null | grep -oE 'EGL_EXT_gl_colorspace[a-z0-9_]*' | sort -u || true
    echo
    echo "=== HEVC decoders ==="
    adb shell dumpsys media.player 2>/dev/null | grep -iE 'hevc' | head -5 || true
    echo
} | tee "${OUT}"

echo "=== Logcat (${DURATION}s max, Ctrl+C to stop early) ===" | tee -a "${OUT}"
adb logcat -c 2>/dev/null || true
# Player / decoder / display subsystems only; everything else is dropped.
timeout "${DURATION}" adb logcat -v time 2>/dev/null \
    | grep -E --line-buffered \
        'ClearVR|Tiledmedia|TMLogger|TiledPlayer|tiledmedia|MediaCodec|OMX|VCodec|VDEC|vdec|C2Mtk|codec2|DRM|Widevine|EGL|SurfaceFlinger|HDR|hdr|HLG|formulaone|AndroidRuntime|FATAL' \
    | tee -a "${OUT}" || true

echo
echo "Saved: ${OUT}  — attach this file to the GitHub issue."
