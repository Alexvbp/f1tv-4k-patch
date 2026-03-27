#!/usr/bin/env bash
set -euo pipefail

# Live stream stats monitor for F1TV on Android TV via ADB.
# Shows decoder resolution, codec, and display info in real-time.
# Supports NVIDIA Shield TV, Amlogic-based devices (Xiaomi TV Box S, etc.),
# and generic Android TV devices.
# Usage: ./stream_stats.sh [device-ip:port] [refresh-interval]

DEVICE_ADDR="${1:-}"
INTERVAL="${2:-3}"

if [[ -n "${DEVICE_ADDR}" ]]; then
    adb connect "${DEVICE_ADDR}" >/dev/null 2>&1 || true
fi

adb devices 2>/dev/null | grep -qw 'device' || { echo "No ADB device connected" >&2; exit 1; }

# ── Detect device type ─────────────────────────────────────────────────────────
BOARD_PLATFORM="$(adb shell getprop ro.board.platform 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]' || echo "")"
DEVICE_MODEL="$(adb shell getprop ro.product.model 2>/dev/null | tr -d '[:space:][:cntrl:]' || echo "Unknown")"
IS_AMLOGIC=false
IS_NVIDIA=false
if [[ "${BOARD_PLATFORM}" == *meson* ]] || adb shell "test -e /sys/class/amhdmitx/amhdmitx0/attr" 2>/dev/null; then
    IS_AMLOGIC=true
elif [[ "${BOARD_PLATFORM}" == *tegra* ]]; then
    IS_NVIDIA=true
fi
DEVICE_TAG=""
[[ "${IS_AMLOGIC}" == true ]] && DEVICE_TAG=" [Amlogic]"
[[ "${IS_NVIDIA}" == true ]]  && DEVICE_TAG=" [NVIDIA]"

# Get display info once (doesn't change during playback)
DISPLAY_REAL="$(adb shell dumpsys display 2>/dev/null \
    | grep -oP 'mBaseDisplayInfo.*?real \K\d+ x \d+' \
    | head -1 || echo "n/a")"
DISPLAY_OVERRIDE="$(adb shell dumpsys display 2>/dev/null \
    | grep -oP 'mOverrideDisplayInfo.*?real \K\d+ x \d+' \
    | head -1 || echo "n/a")"
if [[ "${IS_NVIDIA}" == true ]]; then
    # NVIDIA: original source — keep unchanged to avoid regressions
    HDR_TYPES="$(adb shell dumpsys SurfaceFlinger 2>/dev/null \
        | grep -oP 'mSupportedHdrTypes=\[\K[^\]]+' \
        | head -1 || echo "")"
else
    HDR_TYPES="$(adb shell dumpsys display 2>/dev/null \
        | grep -oP 'mSupportedHdrTypes=\[\K[^\]]+' \
        | head -1 || echo "")"
fi
HDR_LIST=""
[[ "${HDR_TYPES}" == *2* ]] && HDR_LIST="${HDR_LIST}HDR10 "
[[ "${HDR_TYPES}" == *3* ]] && HDR_LIST="${HDR_LIST}HDR10+ "
[[ "${HDR_TYPES}" == *4* ]] && HDR_LIST="${HDR_LIST}DolbyVision "
[[ "${HDR_TYPES}" == *1* ]] && HDR_LIST="${HDR_LIST}HLG "
[[ -z "${HDR_LIST}" ]] && HDR_LIST="none"

clear
echo "F1TV Stream Stats Monitor (refresh: ${INTERVAL}s) — ${DEVICE_MODEL}${DEVICE_TAG}"
echo "Press Ctrl+C to stop"
echo "════════════════════════════════════════════════════"
echo ""

# Baseline counters for delta tracking
PREV_RX=0
PREV_TIME=0
PREV_HWC_MISSED=0
PREV_DECODER_RES=""
ABR_SWITCHES=0

while true; do
    tput cup 4 0 2>/dev/null || true

    # ── Snapshot logcat once per iteration (avoid repeated downloads) ──
    LOGCAT="$(adb logcat -d 2>/dev/null)"

    # ── Decoder resolution ──
    if [[ "${IS_AMLOGIC}" == true ]]; then
        # Amlogic kernel driver: v4l_res_change logs "Pic Width/Height Change (old)=>(new)"
        DECODER_RES="$(echo "${LOGCAT}" \
            | grep -E '\[(h265|h264|vp9|av1|mpeg2)\]' \
            | grep 'v4l_res_change' \
            | tail -1 \
            | grep -oP '=>\(\K[0-9,]+' \
            | tr ',' 'x' || echo "")"
        if [[ -z "${DECODER_RES}" ]]; then
            # Fallback: init_buf_spec2 logs the active buffer dimensions
            DECODER_RES="$(echo "${LOGCAT}" \
                | grep -E '\[(h265|h264|vp9|av1|mpeg2)\]' \
                | grep 'init_buf_spec2' \
                | tail -1 \
                | grep -oP 'init_buf_spec2 \K[0-9]+ [0-9]+' \
                | tr ' ' 'x' || echo "")"
        fi
        [[ -z "${DECODER_RES}" ]] && DECODER_RES="waiting..."
    elif [[ "${IS_NVIDIA}" == true ]]; then
        # NVIDIA: NvOsDebugPrintf logs display resolution
        DECODER_RES="$(echo "${LOGCAT}" \
            | grep 'NvOsDebugPrintf' \
            | grep 'Display Resolution' \
            | tail -1 \
            | grep -oP '\(\K[0-9]+x[0-9]+' || echo "")"
        [[ -z "${DECODER_RES}" ]] && DECODER_RES="waiting..."
    else
        # Generic: MediaCodec reports resolution in logcat
        DECODER_RES="$(echo "${LOGCAT}" \
            | grep -oP 'video-size=\K[0-9]+x[0-9]+' \
            | tail -1 || echo "")"
        [[ -z "${DECODER_RES}" ]] && DECODER_RES="n/a"
    fi

    # ── Detect ABR switch (resolution changed since last interval) ──
    ABR_EVENT=""
    if [[ -n "${PREV_DECODER_RES}" && "${DECODER_RES}" != "${PREV_DECODER_RES}" && "${DECODER_RES}" != "waiting..." ]]; then
        ABR_SWITCHES=$((ABR_SWITCHES + 1))
        ABR_EVENT=" *** SWITCH #${ABR_SWITCHES}: ${PREV_DECODER_RES} -> ${DECODER_RES} ***"
    fi
    PREV_DECODER_RES="${DECODER_RES}"

    # ── Video codec ──
    if [[ "${IS_AMLOGIC}" == true ]]; then
        # Amlogic kernel decoder tags: [h265], [h264], etc.
        CODEC_TAG="$(echo "${LOGCAT}" \
            | grep -oP '\[(h265|h264|vp9|av1|mpeg2|mpeg4)\]' \
            | tail -1 \
            | tr -d '[]' || echo "")"
    elif [[ "${IS_NVIDIA}" == true ]]; then
        # NVIDIA: show full OMX component name (original format)
        CODEC_TAG="$(echo "${LOGCAT}" \
            | grep -oP 'OMX\.nvidia\.\S+' \
            | tail -1 || echo "")"
        if [[ -n "${CODEC_TAG}" ]]; then
            VIDEO_CODEC="${CODEC_TAG}"
            CODEC_TAG="nvidia_done"  # skip the generic case below
        fi
    else
        # Generic: MediaCodec mime type in logcat
        CODEC_TAG="$(echo "${LOGCAT}" \
            | grep -oP 'mime=video/\K(avc|hevc|vp9|av01|mp4v|mp2v)' \
            | tail -1 || echo "")"
        case "${CODEC_TAG}" in
            avc)  CODEC_TAG="h264" ;;
            hevc) CODEC_TAG="h265" ;;
            av01) CODEC_TAG="av1" ;;
            mp4v) CODEC_TAG="mpeg4" ;;
            mp2v) CODEC_TAG="mpeg2" ;;
        esac
    fi
    if [[ "${CODEC_TAG}" != "nvidia_done" ]]; then
        case "${CODEC_TAG}" in
            h265)  VIDEO_CODEC="H.265/HEVC" ;;
            h264)  VIDEO_CODEC="H.264/AVC" ;;
            vp9)   VIDEO_CODEC="VP9" ;;
            av1)   VIDEO_CODEC="AV1" ;;
            mpeg2) VIDEO_CODEC="MPEG-2" ;;
            mpeg4) VIDEO_CODEC="MPEG-4" ;;
            *)     VIDEO_CODEC="n/a" ;;
        esac
    fi

    # ── Resolution history (track adaptive bitrate changes) ──
    if [[ "${IS_AMLOGIC}" == true ]]; then
        RES_HISTORY="$(echo "${LOGCAT}" \
            | grep -E '\[(h265|h264|vp9|av1|mpeg2)\]' \
            | grep 'v4l_res_change' \
            | grep -oP '=>\(\K[0-9,]+' \
            | tr ',' 'x' \
            | sort | uniq -c | sort -rn \
            | head -5 \
            | awk '{printf "%s (%dx) ", $2, $1}' || echo "")"
    elif [[ "${IS_NVIDIA}" == true ]]; then
        RES_HISTORY="$(echo "${LOGCAT}" \
            | grep 'NvOsDebugPrintf' \
            | grep 'Display Resolution' \
            | grep -oP '\(\K[0-9]+x[0-9]+' \
            | sort | uniq -c | sort -rn \
            | head -5 \
            | awk '{printf "%s (%dx) ", $2, $1}' || echo "")"
    else
        RES_HISTORY="$(echo "${LOGCAT}" \
            | grep -oP 'video-size=\K[0-9]+x[0-9]+' \
            | sort | uniq -c | sort -rn \
            | head -5 \
            | awk '{printf "%s (%dx) ", $2, $1}' || echo "")"
    fi

    # ── Network bandwidth (auto-detect active interface) ──
    NET_DEV="$(adb shell cat /proc/net/dev 2>/dev/null \
        | awk 'NR>2 && $2+0>0 && $1~/eth|wlan/ {gsub(/:/, "", $1); print $1; exit}')"
    [[ -z "${NET_DEV}" ]] && NET_DEV="wlan0"
    CUR_RX="$(adb shell cat /proc/net/dev 2>/dev/null \
        | awk -v dev="${NET_DEV}:" '$1==dev {print $2}' || echo "0")"
    CUR_TIME="$(date +%s)"

    BANDWIDTH="n/a"
    if [[ "${PREV_RX}" -gt 0 && "${CUR_RX}" -gt "${PREV_RX}" ]]; then
        ELAPSED=$((CUR_TIME - PREV_TIME))
        if [[ "${ELAPSED}" -gt 0 ]]; then
            DIFF=$((CUR_RX - PREV_RX))
            MBPS="$(echo "scale=1; ${DIFF} * 8 / ${ELAPSED} / 1000000" | bc 2>/dev/null || echo "?")"
            BANDWIDTH="${MBPS} Mbps (${NET_DEV})"
        fi
    fi
    PREV_RX="${CUR_RX}"
    PREV_TIME="${CUR_TIME}"

    # ── Frame drops: delta of HWC missed frames since last interval ──
    CUR_HWC_MISSED="$(adb shell dumpsys SurfaceFlinger 2>/dev/null \
        | grep -oP 'HWC missed frame count: \K\d+' \
        | head -1 || echo "0")"
    FRAME_DROPS="n/a"
    if [[ "${PREV_HWC_MISSED}" -gt 0 && "${CUR_HWC_MISSED}" -ge "${PREV_HWC_MISSED}" ]]; then
        DROPS=$((CUR_HWC_MISSED - PREV_HWC_MISSED))
        FRAME_DROPS="${DROPS} in ${INTERVAL}s"
        [[ "${DROPS}" -gt 0 ]] && FRAME_DROPS="${FRAME_DROPS} !"
    fi
    PREV_HWC_MISSED="${CUR_HWC_MISSED}"

    # ── Memory pressure ──
    MEM_INFO="$(adb shell cat /proc/meminfo 2>/dev/null)"
    MEM_AVAIL="$(echo "${MEM_INFO}" | awk '/MemAvailable/ {printf "%.0fMB", $2/1024}')"
    SWAP_USED="$(echo "${MEM_INFO}" | awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{if(t>0) printf "%.0fMB used", (t-f)/1024; else print "none"}')"

    # ── HDMI output format / upscale filter (device-specific) ──
    if [[ "${IS_AMLOGIC}" == true ]]; then
        # Amlogic sysfs: color subsampling + bit depth
        HDMI_ATTR="$(adb shell cat /sys/class/amhdmitx/amhdmitx0/attr 2>/dev/null \
            | tr -d '\n' || echo "n/a")"
        SUPERRES="n/a"
    elif [[ "${IS_NVIDIA}" == true ]]; then
        HDMI_ATTR="n/a"
        # NVIDIA Shield: HWC upscaling filter selection
        SUPERRES="$(echo "${LOGCAT}" \
            | grep -s 'hwcomposer' \
            | grep 'SuperRes' \
            | tail -1 \
            | grep -oP 'Selecting filter \K\S+' || echo "n/a")"
        [[ -z "${SUPERRES}" ]] && SUPERRES="n/a"
    else
        HDMI_ATTR="n/a"
        SUPERRES="n/a"
    fi

    # ── Active HDR mode ──
    HDR_ACTIVE="$(adb shell dumpsys SurfaceFlinger 2>/dev/null \
        | grep -oP 'HDR current type: \K\S+' \
        | head -1 || echo "n/a")"
    [[ -z "${HDR_ACTIVE}" ]] && HDR_ACTIVE="n/a"

    # ── Refresh rate from display override ──
    REFRESH_RATE="$(adb shell dumpsys display 2>/dev/null \
        | grep -oP 'mOverrideDisplayInfo.*?refreshRateOverride \K[\d.]+' \
        | head -1 || echo "")"
    if [[ -n "${REFRESH_RATE}" && "${REFRESH_RATE}" != "0.0" ]]; then
        REFRESH_RATE="${REFRESH_RATE} Hz"
    else
        REFRESH_RATE="n/a"
    fi

    # ── Print stats ──
    printf "\033[K  %-24s %s%s\n" "Decoder Resolution:" "${DECODER_RES}" "${ABR_EVENT}"
    printf "\033[K  %-24s %s\n"   "Video Codec:"        "${VIDEO_CODEC}"
    printf "\033[K  %-24s %s\n"   "Network Bandwidth:"  "${BANDWIDTH}"
    printf "\033[K  %-24s %s\n"   "Frame Drops:"        "${FRAME_DROPS}"
    printf "\033[K  %-24s %s\n"   "HDMI Output Format:" "${HDMI_ATTR}"
    [[ "${IS_NVIDIA}" == true ]] && \
    printf "\033[K  %-24s %s\n"   "Upscale Filter:"     "${SUPERRES}"
    printf "\033[K\n"
    printf "\033[K  %-24s %s\n"   "Memory Available:"   "${MEM_AVAIL}"
    printf "\033[K  %-24s %s\n"   "Swap:"               "${SWAP_USED}"
    printf "\033[K\n"
    printf "\033[K  %-24s %s\n"   "Display (native):"   "${DISPLAY_REAL}"
    printf "\033[K  %-24s %s\n"   "Display (rendered):" "${DISPLAY_OVERRIDE}"
    printf "\033[K  %-24s %s\n"   "Refresh Rate:"       "${REFRESH_RATE}"
    printf "\033[K  %-24s %s\n"   "Active HDR Mode:"    "${HDR_ACTIVE}"
    printf "\033[K  %-24s %s\n"   "HDR Support:"        "${HDR_LIST}"
    printf "\033[K\n"
    printf "\033[K  Resolution history:\n"
    printf "\033[K    %s\n" "${RES_HISTORY:-none yet}"
    printf "\033[K\n"
    printf "\033[K  Last update: $(date '+%H:%M:%S')\n"

    sleep "${INTERVAL}"
done
