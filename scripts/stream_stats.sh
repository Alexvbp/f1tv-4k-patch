#!/usr/bin/env bash
set -euo pipefail

# Live stream stats monitor for F1TV on Android TV via ADB.
# Shows decoder resolution, codec, and display info in real-time.
# Usage: ./stream_stats.sh [device-ip:port] [refresh-interval]

DEVICE_ADDR="${1:-}"
INTERVAL="${2:-3}"

if [[ -n "${DEVICE_ADDR}" ]]; then
    adb connect "${DEVICE_ADDR}" >/dev/null 2>&1 || true
fi

adb devices 2>/dev/null | grep -qw 'device' || { echo "No ADB device connected" >&2; exit 1; }

# Get display info once (doesn't change during playback)
DISPLAY_REAL="$(adb shell dumpsys display 2>/dev/null \
    | grep -oP 'mBaseDisplayInfo.*?real \K\d+ x \d+' \
    | head -1 || echo "n/a")"
DISPLAY_OVERRIDE="$(adb shell dumpsys display 2>/dev/null \
    | grep -oP 'mOverrideDisplayInfo.*?real \K\d+ x \d+' \
    | head -1 || echo "n/a")"
HDR_TYPES="$(adb shell dumpsys SurfaceFlinger 2>/dev/null \
    | grep -oP 'mSupportedHdrTypes=\[\K[^\]]+' \
    | head -1 || echo "")"
HDR_LIST=""
[[ "${HDR_TYPES}" == *2* ]] && HDR_LIST="${HDR_LIST}HDR10 "
[[ "${HDR_TYPES}" == *3* ]] && HDR_LIST="${HDR_LIST}HDR10+ "
[[ "${HDR_TYPES}" == *4* ]] && HDR_LIST="${HDR_LIST}DolbyVision "
[[ "${HDR_TYPES}" == *1* ]] && HDR_LIST="${HDR_LIST}HLG "
[[ -z "${HDR_LIST}" ]] && HDR_LIST="none"

clear
echo "F1TV Stream Stats Monitor (refresh: ${INTERVAL}s)"
echo "Press Ctrl+C to stop"
echo "════════════════════════════════════════════════════"
echo ""

# Track network bytes for bandwidth calculation
PREV_RX=0
PREV_TIME=0

while true; do
    tput cup 4 0 2>/dev/null || true

    # ── Decoder resolution from NVMEDIA ──
    DECODER_RES="$(adb logcat -d -s NvOsDebugPrintf:D 2>/dev/null \
        | grep 'Display Resolution' \
        | tail -1 \
        | grep -oP '\(\K[0-9]+x[0-9]+' || echo "waiting...")"

    # ── Video codec from MediaCodec logs ──
    VIDEO_CODEC="$(adb logcat -d 2>/dev/null \
        | grep -oP 'OMX\.nvidia\.\S+' \
        | tail -1 || echo "")"
    if [[ -z "${VIDEO_CODEC}" ]]; then
        # Try to find codec from MediaCodecInfo lines
        VIDEO_CODEC="$(adb logcat -d 2>/dev/null \
            | grep 'MediaCodec' \
            | grep -oP 'video/\w+' \
            | tail -1 || echo "n/a")"
    fi

    # ── Resolution history (track adaptive changes) ──
    RES_HISTORY="$(adb logcat -d -s NvOsDebugPrintf:D 2>/dev/null \
        | grep 'Display Resolution' \
        | grep -oP '\(\K[0-9]+x[0-9]+' \
        | sort | uniq -c | sort -rn \
        | head -5 \
        | awk '{printf "%s (%dx) ", $2, $1}' || echo "")"

    # ── Network bandwidth (bytes received on eth0/wlan0) ──
    CUR_RX="$(adb shell cat /proc/net/dev 2>/dev/null \
        | grep -E 'eth0|wlan0' \
        | head -1 \
        | awk '{print $2}' || echo "0")"
    CUR_TIME="$(date +%s)"

    BANDWIDTH="n/a"
    if [[ "${PREV_RX}" -gt 0 && "${CUR_RX}" -gt "${PREV_RX}" ]]; then
        ELAPSED=$((CUR_TIME - PREV_TIME))
        if [[ "${ELAPSED}" -gt 0 ]]; then
            DIFF=$((CUR_RX - PREV_RX))
            MBPS="$(echo "scale=1; ${DIFF} * 8 / ${ELAPSED} / 1000000" | bc 2>/dev/null || echo "?")"
            BANDWIDTH="${MBPS} Mbps"
        fi
    fi
    PREV_RX="${CUR_RX}"
    PREV_TIME="${CUR_TIME}"

    # ── SuperRes / upscaling info ──
    SUPERRES="$(adb logcat -d -s hwcomposer:D 2>/dev/null \
        | grep 'SuperRes' \
        | tail -1 \
        | grep -oP 'Selecting filter \K\S+' || echo "n/a")"

    # ── Print stats ──
    printf "\033[K  %-24s %s\n" "Decoder Resolution:" "${DECODER_RES}"
    printf "\033[K  %-24s %s\n" "Video Codec:" "${VIDEO_CODEC}"
    printf "\033[K  %-24s %s\n" "Network Bandwidth:" "${BANDWIDTH}"
    printf "\033[K  %-24s %s\n" "Upscale Filter:" "${SUPERRES}"
    printf "\033[K\n"
    printf "\033[K  %-24s %s\n" "Display (native):" "${DISPLAY_REAL}"
    printf "\033[K  %-24s %s\n" "Display (rendered):" "${DISPLAY_OVERRIDE}"
    printf "\033[K  %-24s %s\n" "HDR Support:" "${HDR_LIST}"
    printf "\033[K\n"
    printf "\033[K  Resolution history:\n"
    printf "\033[K    %s\n" "${RES_HISTORY:-none yet}"
    printf "\033[K\n"
    printf "\033[K  Last update: $(date '+%H:%M:%S')\n"

    sleep "${INTERVAL}"
done
