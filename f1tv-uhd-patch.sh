#!/usr/bin/env bash
set -euo pipefail

# F1TV UHD Patcher - Patches F1TV Android TV app to enable UHD/4K on any device
# Usage: ./f1tv-uhd-patch.sh <path-to.apkm>

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

PACKAGE="com.formulaone.production"

info()  { echo -e "${CYAN}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

cleanup() {
    if [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]]; then
        info "Cleaning up ${WORKDIR}"
        rm -rf "${WORKDIR}"
    fi
}
trap cleanup EXIT

# ─── Prerequisites ────────────────────────────────────────────────────────────

check_prereqs() {
    local missing=()
    for cmd in apktool zipalign apksigner adb java python3 unzip zip; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        die "Missing required tools: ${missing[*]}\nInstall them before running this script."
    fi
    ok "All prerequisites found"
}

# ─── Parse arguments ─────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <path-to.apkm>"
    exit 1
fi

APKM_PATH="$(realpath "$1")"
[[ -f "${APKM_PATH}" ]] || die "File not found: ${APKM_PATH}"
[[ "${APKM_PATH}" == *.apkm ]] || die "Expected .apkm file, got: ${APKM_PATH}"

check_prereqs

# ─── Verify ADB device ───────────────────────────────────────────────────────

info "Checking for connected ADB device..."
ADB_DEVICES="$(adb devices 2>/dev/null | tail -n +2 | grep -w 'device' || true)"
[[ -n "${ADB_DEVICES}" ]] || die "No ADB device connected. Connect a device and enable USB debugging."

DEVICE_MODEL="$(adb shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
DEVICE_NAME="$(adb shell getprop ro.product.name 2>/dev/null | tr -d '\r')"
ok "Connected device: ${DEVICE_MODEL} (${DEVICE_NAME})"

# ─── Create temp working directory ────────────────────────────────────────────

WORKDIR="$(mktemp -d /tmp/f1tv-patch-XXXX)"
info "Working directory: ${WORKDIR}"

# ─── Extract .apkm ───────────────────────────────────────────────────────────

info "Extracting .apkm bundle..."
unzip -q "${APKM_PATH}" -d "${WORKDIR}/bundle"

# ─── Verify it's F1TV ─────────────────────────────────────────────────────────

INFO_JSON="${WORKDIR}/bundle/info.json"
if [[ -f "${INFO_JSON}" ]]; then
    PNAME="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['pname'])" "${INFO_JSON}" 2>/dev/null || true)"
    [[ "${PNAME}" == "${PACKAGE}" ]] || die "Not an F1TV package. Found pname: ${PNAME:-unknown}"
    ok "Verified F1TV package (${PACKAGE})"
else
    warn "No info.json found, proceeding anyway..."
fi

# ─── Decompile base.apk ──────────────────────────────────────────────────────

BASE_APK="${WORKDIR}/bundle/base.apk"
[[ -f "${BASE_APK}" ]] || die "base.apk not found in bundle"

DECOMPILED="${WORKDIR}/decompiled"
info "Decompiling base.apk with apktool (this may take a moment)..."
apktool d -f -o "${DECOMPILED}" "${BASE_APK}" >/dev/null 2>&1 || die "apktool decompile failed"
ok "Decompiled successfully"

# ─── Patch smali ──────────────────────────────────────────────────────────────

info "Searching for DeviceSupportImpl.smali..."
SMALI_FILE="$(find "${DECOMPILED}" -name 'DeviceSupportImpl.smali' -path '*/tiledmediaplayer/*' | head -1)"
[[ -n "${SMALI_FILE}" ]] || die "DeviceSupportImpl.smali not found in decompiled output"
ok "Found: ${SMALI_FILE#${WORKDIR}/}"

info "Patching validateIsUhdSupportedDevice method..."
python3 << 'PYEOF' "${SMALI_FILE}"
import sys, re

smali_path = sys.argv[1]
with open(smali_path, 'r') as f:
    content = f.read()

# Pattern to match the entire validateIsUhdSupportedDevice method
pattern = (
    r'\.method private final validateIsUhdSupportedDevice\('
    r'Lcom/avs/f1/ui/tiledmediaplayer/DeviceCapabilities;\)Lkotlin/Pair;'
    r'.*?'
    r'\.end method'
)

replacement = """.method private final validateIsUhdSupportedDevice(Lcom/avs/f1/ui/tiledmediaplayer/DeviceCapabilities;)Lkotlin/Pair;
    .locals 2
    .annotation system Ldalvik/annotation/Signature;
        value = {
            "(",
            "Lcom/avs/f1/ui/tiledmediaplayer/DeviceCapabilities;",
            ")",
            "Lkotlin/Pair<",
            "Ljava/lang/Boolean;",
            "Ljava/lang/String;",
            ">;"
        }
    .end annotation

    # UHD patch: always return Pair(true, null)
    new-instance v0, Lkotlin/Pair;

    const/4 v1, 0x1

    invoke-static {v1}, Ljava/lang/Boolean;->valueOf(Z)Ljava/lang/Boolean;

    move-result-object v1

    const/4 p1, 0x0

    invoke-direct {v0, v1, p1}, Lkotlin/Pair;-><init>(Ljava/lang/Object;Ljava/lang/Object;)V

    return-object v0
.end method"""

new_content, count = re.subn(pattern, replacement, content, flags=re.DOTALL)

if count == 0:
    print("ERROR: Could not find validateIsUhdSupportedDevice method to patch!", file=sys.stderr)
    sys.exit(1)

with open(smali_path, 'w') as f:
    f.write(new_content)

print(f"Patched {count} method(s)")
PYEOF

[[ $? -eq 0 ]] || die "Smali patching failed"
ok "Smali patch applied"

# ─── Rebuild with apktool ────────────────────────────────────────────────────

REBUILT="${WORKDIR}/rebuilt"
info "Rebuilding with apktool..."
apktool b -f -o "${REBUILT}/base-rebuilt.apk" "${DECOMPILED}" >/dev/null 2>&1 || die "apktool build failed"
ok "Rebuild complete"

# ─── Inject patched dex into original base.apk ───────────────────────────────

info "Injecting patched dex files into original base.apk..."
PATCHED_BASE="${WORKDIR}/base-patched.apk"
cp "${BASE_APK}" "${PATCHED_BASE}"

# Remove old signatures and dex files from the copy
(cd "${WORKDIR}" && mkdir -p inject_tmp)
(cd "${WORKDIR}/inject_tmp" && unzip -q "${WORKDIR}/rebuilt/base-rebuilt.apk" 'classes*.dex')

# Delete META-INF and old dex from the patched base
zip -qd "${PATCHED_BASE}" 'META-INF/*' 2>/dev/null || true
zip -qd "${PATCHED_BASE}" 'classes*.dex' 2>/dev/null || true

# Add new dex files (stored/uncompressed with -0 to preserve alignment)
(cd "${WORKDIR}/inject_tmp" && zip -q -0 "${PATCHED_BASE}" classes*.dex)

ok "Dex injection complete"

# ─── Auto-detect device splits via adb ────────────────────────────────────────

info "Detecting device configuration for split APK selection..."

# Architecture
DEVICE_ABI="$(adb shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')"
info "Device ABI: ${DEVICE_ABI}"

# Map ABI to split name
case "${DEVICE_ABI}" in
    arm64-v8a)  ARCH_SPLIT="split_config.arm64_v8a.apk" ;;
    armeabi-v7a) ARCH_SPLIT="split_config.armeabi_v7a.apk" ;;
    x86_64)     ARCH_SPLIT="split_config.x86_64.apk" ;;
    x86)        ARCH_SPLIT="split_config.x86.apk" ;;
    *)          die "Unsupported ABI: ${DEVICE_ABI}" ;;
esac

# Locale
DEVICE_LOCALE="$(adb shell getprop persist.sys.locale 2>/dev/null | tr -d '\r')"
[[ -z "${DEVICE_LOCALE}" ]] && DEVICE_LOCALE="$(adb shell getprop ro.product.locale 2>/dev/null | tr -d '\r')"
[[ -z "${DEVICE_LOCALE}" ]] && DEVICE_LOCALE="en"
# Extract language code (first part before - or _)
LANG_CODE="$(echo "${DEVICE_LOCALE}" | cut -d'-' -f1 | cut -d'_' -f1)"
LANG_SPLIT="split_config.${LANG_CODE}.apk"
info "Device locale: ${DEVICE_LOCALE} -> language split: ${LANG_SPLIT}"

# DPI - only xhdpi available for TV
DPI_SPLIT="split_config.xhdpi.apk"

# Collect selected splits
SELECTED_SPLITS=()
BUNDLE_DIR="${WORKDIR}/bundle"

for split in "${ARCH_SPLIT}" "${LANG_SPLIT}" "${DPI_SPLIT}"; do
    if [[ -f "${BUNDLE_DIR}/${split}" ]]; then
        SELECTED_SPLITS+=("${split}")
        ok "Selected split: ${split}"
    else
        warn "Split not found: ${split} (skipping)"
    fi
done

[[ ${#SELECTED_SPLITS[@]} -gt 0 ]] || die "No matching splits found for device"

# ─── Prepare splits (remove signatures) ──────────────────────────────────────

info "Removing signatures from selected splits..."
for split in "${SELECTED_SPLITS[@]}"; do
    zip -qd "${BUNDLE_DIR}/${split}" 'META-INF/*' 2>/dev/null || true
done
ok "Split signatures removed"

# ─── Keystore ─────────────────────────────────────────────────────────────────

KEYSTORE="${HOME}/.android/debug.keystore"
KS_PASS="android"
KEY_ALIAS="androiddebugkey"

if [[ ! -f "${KEYSTORE}" ]]; then
    info "Creating debug keystore at ${KEYSTORE}..."
    mkdir -p "$(dirname "${KEYSTORE}")"
    keytool -genkeypair \
        -keystore "${KEYSTORE}" \
        -storepass "${KS_PASS}" \
        -keypass "${KS_PASS}" \
        -alias "${KEY_ALIAS}" \
        -keyalg RSA \
        -keysize 2048 \
        -validity 10000 \
        -dname "CN=Android Debug,O=Android,C=US" 2>/dev/null
    ok "Debug keystore created"
else
    ok "Using existing debug keystore"
fi

# ─── Zipalign all APKs ───────────────────────────────────────────────────────

ALIGNED_DIR="${WORKDIR}/aligned"
mkdir -p "${ALIGNED_DIR}"

info "Zipaligning APKs..."

# Align base
zipalign -f 4 "${PATCHED_BASE}" "${ALIGNED_DIR}/base.apk"
ok "Aligned: base.apk"

# Align splits
for split in "${SELECTED_SPLITS[@]}"; do
    zipalign -f 4 "${BUNDLE_DIR}/${split}" "${ALIGNED_DIR}/${split}"
    ok "Aligned: ${split}"
done

# ─── Sign all APKs ───────────────────────────────────────────────────────────

info "Signing APKs..."

SIGN_ARGS=(
    --ks "${KEYSTORE}"
    --ks-pass "pass:${KS_PASS}"
    --ks-key-alias "${KEY_ALIAS}"
    --key-pass "pass:${KS_PASS}"
)

apksigner sign "${SIGN_ARGS[@]}" "${ALIGNED_DIR}/base.apk"
ok "Signed: base.apk"

for split in "${SELECTED_SPLITS[@]}"; do
    apksigner sign "${SIGN_ARGS[@]}" "${ALIGNED_DIR}/${split}"
    ok "Signed: ${split}"
done

# ─── Uninstall existing F1TV ──────────────────────────────────────────────────

info "Checking for existing F1TV installation..."
if adb shell pm list packages 2>/dev/null | grep -q "${PACKAGE}"; then
    info "Uninstalling existing F1TV..."
    adb uninstall "${PACKAGE}" >/dev/null 2>&1 || warn "Uninstall returned non-zero (may not have been installed)"
    ok "Existing installation removed"
else
    info "F1TV not currently installed"
fi

# ─── Install via adb install-multiple ─────────────────────────────────────────

info "Installing patched F1TV..."

INSTALL_FILES=("${ALIGNED_DIR}/base.apk")
for split in "${SELECTED_SPLITS[@]}"; do
    INSTALL_FILES+=("${ALIGNED_DIR}/${split}")
done

info "Installing ${#INSTALL_FILES[@]} APK(s):"
for f in "${INSTALL_FILES[@]}"; do
    info "  $(basename "$f")"
done

adb install-multiple "${INSTALL_FILES[@]}" || die "adb install-multiple failed"

# ─── Done ─────────────────────────────────────────────────────────────────────

echo ""
ok "======================================"
ok "  F1TV UHD patch installed successfully!"
ok "======================================"
echo ""
info "Device: ${DEVICE_MODEL} (${DEVICE_NAME})"
info "ABI: ${DEVICE_ABI}"
info "Locale: ${DEVICE_LOCALE}"
info "Package: ${PACKAGE}"
echo ""
info "Open the F1TV app and check Settings for the UHD option."
