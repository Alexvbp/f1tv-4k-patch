#!/usr/bin/env bash
set -euo pipefail

# Dump device properties from an Android TV via ADB in rs-google-play format.
# Usage: ./dump_device_props.sh [device-ip:port]
#
# Run this with your Shield (or any Android TV) connected via ADB.
# Output goes to stdout in the exact INI format needed for device.properties.

DEVICE_ADDR="${1:-}"

if [[ -n "${DEVICE_ADDR}" ]]; then
    adb connect "${DEVICE_ADDR}" >/dev/null 2>&1 || true
fi

# Verify device
adb devices 2>/dev/null | grep -qw 'device' || { echo "No ADB device connected" >&2; exit 1; }

prop() { adb shell getprop "$1" 2>/dev/null | tr -d '\r'; }

MODEL="$(prop ro.product.model)"
BRAND="$(prop ro.product.brand)"
DEVICE="$(prop ro.product.device)"
PRODUCT="$(prop ro.product.name)"
MANUFACTURER="$(prop ro.product.manufacturer)"
FINGERPRINT="$(prop ro.build.fingerprint)"
HARDWARE="$(prop ro.hardware)"
BOOTLOADER="$(prop ro.bootloader)"
RADIO="$(prop gsm.version.baseband)"
BUILD_ID="$(prop ro.build.id)"
SDK_INT="$(prop ro.build.version.sdk)"
VERSION_RELEASE="$(prop ro.build.version.release)"

# ABI list
PLATFORMS="$(prop ro.product.cpu.abilist)"
[[ -z "${PLATFORMS}" ]] && PLATFORMS="$(prop ro.product.cpu.abi)"

# Screen
DENSITY="$(prop ro.sf.lcd_density)"
[[ -z "${DENSITY}" ]] && DENSITY="$(adb shell wm density 2>/dev/null | grep -oP '\d+' | tail -1)"
SCREEN_SIZE="$(adb shell wm size 2>/dev/null | grep -oP '\d+x\d+' | tail -1)"
SCREEN_WIDTH="${SCREEN_SIZE%x*}"
SCREEN_HEIGHT="${SCREEN_SIZE#*x}"

# Features
FEATURES="$(adb shell pm list features 2>/dev/null | sed 's/^feature://' | tr -d '\r' | sort -u | paste -sd',')"

# Shared libraries
SHARED_LIBS="$(adb shell pm list libraries 2>/dev/null | sed 's/^library://' | tr -d '\r' | sort -u | paste -sd',')"

# GL info
GL_VERSION_HEX="$(adb shell getprop ro.opengles.version 2>/dev/null | tr -d '\r')"
[[ -z "${GL_VERSION_HEX}" ]] && GL_VERSION_HEX="196610"

# GL extensions - dumpsys can be verbose, try to extract
GL_EXTENSIONS="$(adb shell dumpsys SurfaceFlinger 2>/dev/null | grep -oP 'GL_[A-Z_a-z0-9]+' | sort -u | paste -sd',')"
[[ -z "${GL_EXTENSIONS}" ]] && GL_EXTENSIONS="GL_OES_EGL_image"

# GSF version (Google Services Framework)
GSF_VERSION="$(adb shell dumpsys package com.google.android.gsf 2>/dev/null | grep -oP 'versionCode=\K\d+' | head -1)"
[[ -z "${GSF_VERSION}" ]] && GSF_VERSION="203615037"

# Play Store version
VENDING_VERSION="$(adb shell dumpsys package com.android.vending 2>/dev/null | grep -oP 'versionCode=\K\d+' | head -1)"
VENDING_VERSION_STRING="$(adb shell dumpsys package com.android.vending 2>/dev/null | grep -oP 'versionName=\K\S+' | head -1)"
[[ -z "${VENDING_VERSION}" ]] && VENDING_VERSION="82201710"
[[ -z "${VENDING_VERSION_STRING}" ]] && VENDING_VERSION_STRING="unknown"

# Cell/SIM (usually empty on TV)
CELL_OP="$(prop gsm.operator.numeric)"
[[ -z "${CELL_OP}" ]] && CELL_OP="310"
SIM_OP="$(prop gsm.sim.operator.numeric)"
[[ -z "${SIM_OP}" ]] && SIM_OP="38"

# Locales
LOCALES="$(prop ro.product.locale)"
[[ -z "${LOCALES}" ]] && LOCALES="en,en_US"

# Keyboard/nav/touch (TV defaults)
TOUCHSCREEN="1"  # NOTOUCH for TVs
KEYBOARD="1"     # NOKEYS
NAVIGATION="2"   # DPAD (remote)
SCREEN_LAYOUT="3" # LARGE
HAS_HARD_KEYBOARD="false"
HAS_FIVE_WAY_NAV="true"

# Sanitize codename for section name
CODENAME="$(echo "${MANUFACTURER}_${DEVICE}" | tr '[:upper:]' '[:lower:]' | tr ' ' '_' | tr -cd 'a-z0-9_')"

# Escape colons in fingerprint for INI format
FINGERPRINT_ESC="${FINGERPRINT//:/\\:}"

cat << EOF
[gplayapi_${CODENAME}.properties]
#
# Auto-generated device profile: ${MODEL}
#

Build.BOOTLOADER=${BOOTLOADER:-unknown}
Build.BRAND=${BRAND}
Build.DEVICE=${DEVICE}
Build.FINGERPRINT=${FINGERPRINT_ESC}
Build.HARDWARE=${HARDWARE}
Build.ID=${BUILD_ID}
Build.MANUFACTURER=${MANUFACTURER}
Build.MODEL=${MODEL}
Build.PRODUCT=${PRODUCT}
Build.RADIO=${RADIO:-unknown}
Build.VERSION.RELEASE=${VERSION_RELEASE}
Build.VERSION.SDK_INT=${SDK_INT}
CellOperator=${CELL_OP}
Client=android-google
Features=${FEATURES}
GL.Extensions=${GL_EXTENSIONS}
GL.Version=${GL_VERSION_HEX}
GSF.version=${GSF_VERSION}
HasFiveWayNavigation=${HAS_FIVE_WAY_NAV}
HasHardKeyboard=${HAS_HARD_KEYBOARD}
Keyboard=${KEYBOARD}
Locales=${LOCALES}
Navigation=${NAVIGATION}
Platforms=${PLATFORMS}
Roaming=mobile-notroaming
Screen.Density=${DENSITY}
Screen.Height=${SCREEN_HEIGHT}
Screen.Width=${SCREEN_WIDTH}
ScreenLayout=${SCREEN_LAYOUT}
SharedLibraries=${SHARED_LIBS}
SimOperator=${SIM_OP}
TimeZone=UTC
TouchScreen=${TOUCHSCREEN}
UserReadableName=${MODEL}
Vending.version=${VENDING_VERSION}
Vending.versionString=${VENDING_VERSION_STRING}
EOF

echo "" >&2
echo "Done! Device codename: ${CODENAME}" >&2
echo "Use with: apkeep -o device=${CODENAME}" >&2
