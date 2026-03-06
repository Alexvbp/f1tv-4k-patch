#!/usr/bin/env bash
set -euo pipefail

# Convenience script to install patched F1TV APKs via ADB.
# Usage: ./install.sh <apkm/xapk file or directory-with-apks> [device-ip:port]
#
# Accepts:
#   - .apkm or .xapk file (auto-extracts to temp dir)
#   - Directory containing base.apk + split APKs
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

cleanup() {
    if [[ -n "${TMPDIR_CREATED:-}" && -d "${TMPDIR_CREATED}" ]]; then
        rm -rf "${TMPDIR_CREATED}"
    fi
}
trap cleanup EXIT

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <apkm/xapk file or apk-directory> [device-ip:port]"
    exit 1
fi

INPUT="$(realpath "$1")"
DEVICE_ADDR="${2:-}"

# Handle .apkm / .xapk files — extract to temp directory
if [[ -f "${INPUT}" ]]; then
    case "${INPUT}" in
        *.apkm|*.xapk)
            TMPDIR_CREATED="$(mktemp -d /tmp/f1tv-install-XXXX)"
            info "Extracting $(basename "${INPUT}")..."
            unzip -q "${INPUT}" -d "${TMPDIR_CREATED}"
            APK_DIR="${TMPDIR_CREATED}"
            ;;
        *)
            die "Unsupported file type: ${INPUT} (expected .apkm or .xapk)"
            ;;
    esac
elif [[ -d "${INPUT}" ]]; then
    APK_DIR="${INPUT}"
else
    die "Not found: ${INPUT}"
fi

[[ -f "${APK_DIR}/base.apk" || -f "${APK_DIR}/${PACKAGE}.apk" ]] || die "No base APK found in ${APK_DIR}"
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
    arm64-v8a)   ABI_KEY="arm64_v8a" ;;
    armeabi-v7a) ABI_KEY="armeabi_v7a" ;;
    x86_64)      ABI_KEY="x86_64" ;;
    x86)         ABI_KEY="x86" ;;
    *)           die "Unsupported ABI: ${DEVICE_ABI}" ;;
esac

DEVICE_LOCALE="$(adb shell getprop persist.sys.locale 2>/dev/null | tr -d '\r')"
[[ -z "${DEVICE_LOCALE}" ]] && DEVICE_LOCALE="$(adb shell getprop ro.product.locale 2>/dev/null | tr -d '\r')"
[[ -z "${DEVICE_LOCALE}" ]] && DEVICE_LOCALE="en"
LANG_CODE="$(echo "${DEVICE_LOCALE}" | cut -d'-' -f1 | cut -d'_' -f1)"

# Find the base APK (supports both naming conventions)
if [[ -f "${APK_DIR}/base.apk" ]]; then
    BASE="${APK_DIR}/base.apk"
else
    BASE="${APK_DIR}/${PACKAGE}.apk"
fi

# Collect APKs to install (supports both split_config.* and config.* naming)
INSTALL_FILES=("${BASE}")
for key in "${ABI_KEY}" "${LANG_CODE}" "xhdpi"; do
    for prefix in "split_config" "config"; do
        SPLIT="${APK_DIR}/${prefix}.${key}.apk"
        if [[ -f "${SPLIT}" ]]; then
            INSTALL_FILES+=("${SPLIT}")
            ok "Selected: ${prefix}.${key}.apk"
            break
        fi
    done
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
