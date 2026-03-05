#!/usr/bin/env bash
set -euo pipefail

# Convenience script to install patched F1TV APKs via ADB.
# Usage: ./install.sh <directory-with-apks> [device-ip:port]
#
# If a device IP is provided, connects via ADB WiFi first.
# Auto-detects the correct splits for the connected device.

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

PACKAGE="com.formulaone.production"

info()  { echo -e "${CYAN}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[+]${NC} $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <apk-directory> [device-ip:port]"
    exit 1
fi

APK_DIR="$(realpath "$1")"
DEVICE_ADDR="${2:-}"

[[ -d "${APK_DIR}" ]] || die "Directory not found: ${APK_DIR}"
[[ -f "${APK_DIR}/base.apk" ]] || die "base.apk not found in ${APK_DIR}"
command -v adb &>/dev/null || die "adb not found"

# Connect via WiFi if address provided
if [[ -n "${DEVICE_ADDR}" ]]; then
    info "Connecting to ${DEVICE_ADDR}..."
    adb connect "${DEVICE_ADDR}" || die "Failed to connect"
fi

# Verify device
ADB_DEVICES="$(adb devices 2>/dev/null | tail -n +2 | grep -w 'device' || true)"
[[ -n "${ADB_DEVICES}" ]] || die "No ADB device connected"

DEVICE_MODEL="$(adb shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
ok "Connected: ${DEVICE_MODEL}"

# Detect correct splits
DEVICE_ABI="$(adb shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')"
case "${DEVICE_ABI}" in
    arm64-v8a)   ARCH_SPLIT="split_config.arm64_v8a.apk" ;;
    armeabi-v7a) ARCH_SPLIT="split_config.armeabi_v7a.apk" ;;
    x86_64)      ARCH_SPLIT="split_config.x86_64.apk" ;;
    x86)         ARCH_SPLIT="split_config.x86.apk" ;;
    *)           die "Unsupported ABI: ${DEVICE_ABI}" ;;
esac

DEVICE_LOCALE="$(adb shell getprop persist.sys.locale 2>/dev/null | tr -d '\r')"
[[ -z "${DEVICE_LOCALE}" ]] && DEVICE_LOCALE="$(adb shell getprop ro.product.locale 2>/dev/null | tr -d '\r')"
[[ -z "${DEVICE_LOCALE}" ]] && DEVICE_LOCALE="en"
LANG_CODE="$(echo "${DEVICE_LOCALE}" | cut -d'-' -f1 | cut -d'_' -f1)"
LANG_SPLIT="split_config.${LANG_CODE}.apk"
DPI_SPLIT="split_config.xhdpi.apk"

# Collect APKs to install
INSTALL_FILES=("${APK_DIR}/base.apk")
for split in "${ARCH_SPLIT}" "${LANG_SPLIT}" "${DPI_SPLIT}"; do
    if [[ -f "${APK_DIR}/${split}" ]]; then
        INSTALL_FILES+=("${APK_DIR}/${split}")
        ok "Selected: ${split}"
    fi
done

# Uninstall existing
if adb shell pm list packages 2>/dev/null | grep -q "${PACKAGE}"; then
    info "Uninstalling existing F1TV..."
    adb uninstall "${PACKAGE}" >/dev/null 2>&1 || true
fi

# Install
info "Installing ${#INSTALL_FILES[@]} APK(s)..."
adb install-multiple "${INSTALL_FILES[@]}" || die "Installation failed"

ok "F1TV UHD patched app installed successfully!"
info "Open F1TV and check Settings for the UHD option."
