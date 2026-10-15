#!/usr/bin/env bash
set -euo pipefail

# Collect the device info + player logs needed to debug a playback problem
# (video error pop-ups, TM40xx codes, HDR flicker, 1620p cap, missing audio
# tracks, no 4K...).
#
# Usage: ./scripts/capture_logs.sh [device-ip:5555] [seconds]
#
#   1. Run this script. It waits until F1TV is running, then records.
#   2. On the TV, start the stream that misbehaves and reproduce the problem
#      (open the audio/language menu too if that is the issue).
#   3. Press Ctrl+C (or wait for the timeout). Attach the printed .txt to the
#      GitHub issue. It contains the F1TV process log (player + ClearVR core)
#      plus the system decoder/display lines — nothing else.

DEVICE_ADDR="${1:-}"
DURATION="${2:-180}"
PACKAGE="com.formulaone.production"
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
    adb shell dumpsys package "${PACKAGE}" 2>/dev/null \
        | grep -E 'versionName|primaryCpuAbi|splits=' | sed 's/^ *//' || true
    echo
    echo "=== Display / HDR ==="
    adb shell dumpsys display 2>/dev/null | grep -oE 'DisplayDeviceInfo\{[^}]*' | head -3 || true
    adb shell dumpsys display 2>/dev/null | grep -oE 'HdrCapabilities\{[^}]*\}' | sort -u || true
    echo
    echo "=== EGL extensions (BT2020 colorspaces decide the HDR render path) ==="
    adb shell dumpsys SurfaceFlinger 2>/dev/null | grep -oE 'EGL_EXT_gl_colorspace[a-z0-9_]*' | sort -u || true
    echo
    echo "=== Decoders (HEVC video, AC-3 / E-AC3 audio) ==="
    adb shell dumpsys media.player 2>/dev/null \
        | grep -iE "Media type 'video/hevc'|Media type 'audio/(ac3|eac3|ac4)'|Decoder \"" \
        | grep -B1 -iE 'hevc|ac3|ac4' | grep -v '^--$' | sed 's/^ *//' | head -20 || true
    echo
    echo "=== Audio output (surround / passthrough encodings) ==="
    adb shell dumpsys audio 2>/dev/null | grep -iE 'encod|AC3|EAC3|DTS|surround|HDMI' | sed 's/^ *//' | sort -u | head -20 || true
    echo
} | tee "${OUT}"

echo "Waiting for ${PACKAGE} to run (open F1TV on the TV)..." | tee -a "${OUT}"
PID=""
for _ in $(seq 1 60); do
    PID="$(adb shell pidof "${PACKAGE}" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ -n "${PID}" ]] && break
    sleep 1
done
[[ -n "${PID}" ]] || { echo "F1TV is not running — open it and re-run." | tee -a "${OUT}"; exit 1; }
echo "F1TV pid ${PID}. Now play the stream; recording for ${DURATION}s max (Ctrl+C to stop early)..." | tee -a "${OUT}"

echo "=== Logcat ===" >> "${OUT}"
adb logcat -c 2>/dev/null || true
# Everything from the F1TV process (app, Tiledmedia player, ClearVR Go core) +
# the system-side decoder / DRM / display lines. The rest is dropped.
timeout "${DURATION}" adb logcat -v time 2>/dev/null \
    | grep -E --line-buffered \
        "\( *${PID}\)|MediaCodec|OMX|ACodec|CCodec|VCodec|VDEC|vdec|C2Mtk|codec2|Widevine|DrmHal|SurfaceFlinger|HWC|hdmi|HDR" \
    | grep -vE --line-buffered 'chatty|Firebase|Glide|OkHttp|Choreographer' \
    | tee -a "${OUT}" || true

# Debug (-UHD-dbg) builds make the native ClearVR core write its own log to the
# app's external files dir. Pull it too: it holds the audio-track / ABR / tier
# decisions that never reach logcat.
CORE_LOG="/sdcard/Android/data/${PACKAGE}/files/clearvr.tmlog"
if adb shell "test -f ${CORE_LOG}" 2>/dev/null; then
    CORE_OUT="${OUT%.txt}-core.tmlog"
    adb pull "${CORE_LOG}" "${CORE_OUT}" >/dev/null 2>&1 && echo "Core log:  ${CORE_OUT}  — attach this one as well."
fi

echo
echo "Saved: ${OUT}  — attach this file to the GitHub issue."
