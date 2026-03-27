#!/usr/bin/env bash
set -euo pipefail

# F1TV UHD Patcher - Patches F1TV Android TV APKM bundle to enable UHD/4K
# Usage: ./patch.sh <input.apkm> <output-dir>
# Produces a patched .apkm bundle with all splits re-signed.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

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
    for cmd in apktool zipalign apksigner java python3 unzip zip; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        die "Missing required tools: ${missing[*]}"
    fi
    ok "All prerequisites found"
}

# ─── Parse arguments ─────────────────────────────────────────────────────────

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <path-to.apkm> <output-dir>"
    exit 1
fi

APKM_PATH="$(realpath "$1")"
OUTPUT_DIR="$(realpath "$2")"

[[ -f "${APKM_PATH}" ]] || die "File not found: ${APKM_PATH}"
mkdir -p "${OUTPUT_DIR}"

check_prereqs

# ─── Create temp working directory ────────────────────────────────────────────

WORKDIR="$(mktemp -d /tmp/f1tv-patch-XXXX)"
info "Working directory: ${WORKDIR}"

# ─── Extract .apkm ───────────────────────────────────────────────────────────

info "Extracting APKM bundle..."
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

# ─── Locate base APK ─────────────────────────────────────────────────────────

info "Bundle contents:"
ls -la "${WORKDIR}/bundle/"

BASE_APK="${WORKDIR}/bundle/base.apk"
if [[ ! -f "${BASE_APK}" ]]; then
    # XAPK bundles from APKPure name the main APK by package name
    ALT_APK="${WORKDIR}/bundle/${PACKAGE}.apk"
    if [[ -f "${ALT_APK}" ]]; then
        info "Found ${PACKAGE}.apk, using as base"
        BASE_APK="${ALT_APK}"
    else
        # Try finding any APK that isn't a split config
        FOUND_APK="$(find "${WORKDIR}/bundle" -maxdepth 1 -name '*.apk' ! -name 'split_*' ! -name 'config.*' -print -quit)"
        if [[ -n "${FOUND_APK}" ]]; then
            info "Using $(basename "${FOUND_APK}") as base"
            BASE_APK="${FOUND_APK}"
        else
            die "base.apk not found in bundle"
        fi
    fi
fi

DECOMPILED="${WORKDIR}/decompiled"
info "Decompiling base.apk with apktool..."
apktool d -f -o "${DECOMPILED}" "${BASE_APK}" >/dev/null 2>&1 || die "apktool decompile failed"
ok "Decompiled successfully"

# ─── Patch smali ──────────────────────────────────────────────────────────────

info "Searching for DeviceSupportImpl.smali..."
SMALI_FILE="$(find "${DECOMPILED}" -name 'DeviceSupportImpl.smali' -path '*/tiledmediaplayer/*' -print -quit)"
[[ -n "${SMALI_FILE}" ]] || die "DeviceSupportImpl.smali not found in decompiled output"
ok "Found: ${SMALI_FILE#${WORKDIR}/}"

info "Patching validateIsUhdSupportedDevice method..."
python3 - "${SMALI_FILE}" << 'PYEOF'
import sys, re

smali_path = sys.argv[1]
with open(smali_path, 'r') as f:
    content = f.read()

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

# ─── Patch video quality button ──────────────────────────────────────────────

info "Searching for DiagnosticsPreferenceManagerImpl.smali..."
DIAG_SMALI="$(find "${DECOMPILED}" -name 'DiagnosticsPreferenceManagerImpl.smali' -print -quit)"
if [[ -n "${DIAG_SMALI}" ]]; then
    ok "Found: ${DIAG_SMALI#${WORKDIR}/}"
    info "Patching isVideoQualityEnabled to always return true..."
    python3 - "${DIAG_SMALI}" << 'PYEOF'
import sys, re

smali_path = sys.argv[1]
with open(smali_path, 'r') as f:
    content = f.read()

pattern = (
    r'\.method public isVideoQualityEnabled\(\)Z'
    r'.*?'
    r'\.end method'
)

replacement = """.method public isVideoQualityEnabled()Z
    .locals 1

    # Quality patch: always return true
    const/4 v0, 0x1

    return v0
.end method"""

new_content, count = re.subn(pattern, replacement, content, flags=re.DOTALL)

if count == 0:
    print("ERROR: Could not find isVideoQualityEnabled method to patch!", file=sys.stderr)
    sys.exit(1)

with open(smali_path, 'w') as f:
    f.write(new_content)

print(f"Patched isVideoQualityEnabled ({count} occurrence(s))")
PYEOF

    [[ $? -eq 0 ]] || die "Video quality patch failed"
    ok "Video quality patch applied"
else
    warn "DiagnosticsPreferenceManagerImpl.smali not found, skipping quality patch"
fi

# ─── Patch NRP blit mode to NATIVE_ANDROID_DIRECT_TO_VIEW ──────────────────
#
# Tiledmedia's default blit mode (AUTO_DETECT) routes decoded frames through
# GPU tile composition via SurfaceTexture → EGL → swapBuffers. On Amlogic
# devices (Xiaomi TV Box S, etc.) this path drops ~13% of frames.
# The SDK has a built-in NATIVE_ANDROID_DIRECT_TO_VIEW mode that bypasses
# GPU composition and outputs the decoder directly to the SurfaceView.
# Fix: on Amlogic devices, return NATIVE_ANDROID_DIRECT_TO_VIEW.
#      on other devices (NVIDIA Shield, etc.), use the original value.

info "Patching NRP blit mode to direct-to-view (Amlogic only)..."
RENDER_CONFIG="$(find "${DECOMPILED}" -name 'RenderAPIConfig.smali' -path '*/tiledmedia/*' -print -quit 2>/dev/null || true)"

if [[ -n "${RENDER_CONFIG}" && -f "${RENDER_CONFIG}" ]]; then
    python3 - "${RENDER_CONFIG}" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Patch getNRPTextureBlitMode() to return NATIVE_ANDROID_DIRECT_TO_VIEW on Amlogic,
# or the original configured value on other devices.
# Original (.locals 1):
#   iget-object v0, p0, ...->nrpTextureBlitMode
#   return-object v0
#
# Patched (.locals 2):
#   check Build.HARDWARE.contains("amlogic")
#   if true -> return NATIVE_ANDROID_DIRECT_TO_VIEW
#   else   -> return original nrpTextureBlitMode

old = """    iget-object v0, p0, Lcom/tiledmedia/clearvrview/RenderAPIConfig;->nrpTextureBlitMode:Lcom/tiledmedia/clearvrenums/NRPTextureBlitMode;

    return-object v0
.end method

.method public getNrpColorSpace"""

new = """    sget-object v0, Landroid/os/Build;->HARDWARE:Ljava/lang/String;

    const-string v1, "amlogic"

    invoke-virtual {v0, v1}, Ljava/lang/String;->contains(Ljava/lang/CharSequence;)Z

    move-result v0

    if-eqz v0, :use_default

    sget-object v0, Lcom/tiledmedia/clearvrenums/NRPTextureBlitMode;->NATIVE_ANDROID_DIRECT_TO_VIEW:Lcom/tiledmedia/clearvrenums/NRPTextureBlitMode;

    return-object v0

    :use_default
    iget-object v0, p0, Lcom/tiledmedia/clearvrview/RenderAPIConfig;->nrpTextureBlitMode:Lcom/tiledmedia/clearvrenums/NRPTextureBlitMode;

    return-object v0
.end method

.method public getNrpColorSpace"""

if old not in content:
    print(f"Could not find getNRPTextureBlitMode pattern in {path}", file=sys.stderr)
    sys.exit(1)

content = content.replace(old, new, 1)

# Also bump .locals 1 to .locals 2 in this method (need v1 for the "amlogic" string)
method_header = '.method public getNRPTextureBlitMode()Lcom/tiledmedia/clearvrenums/NRPTextureBlitMode;\n    .locals 1'
method_header_new = '.method public getNRPTextureBlitMode()Lcom/tiledmedia/clearvrenums/NRPTextureBlitMode;\n    .locals 2'
if method_header in content:
    content = content.replace(method_header, method_header_new, 1)
else:
    print(f"  Warning: could not bump .locals in getNRPTextureBlitMode", file=sys.stderr)

with open(path, 'w') as f:
    f.write(content)
print(f"  Patched {path}")
PYEOF

    [[ $? -eq 0 ]] && ok "NRP direct-to-view patch applied (Amlogic only)" || warn "NRP direct-to-view patch failed"
else
    warn "RenderAPIConfig.smali not found, skipping direct-to-view patch"
fi

# ─── Patch version name ─────────────────────────────────────────────────────

info "Patching version name..."

# Patch apktool.yml (manifest versionName)
APKTOOL_YML="${DECOMPILED}/apktool.yml"
if [[ -f "${APKTOOL_YML}" ]]; then
    sed -i 's/\(versionName: .*\)/\1-UHD/' "${APKTOOL_YML}"
    ok "Manifest versionName updated"
fi

# Patch BuildConfig.smali (in-app version string)
BUILDCONFIG="$(find "${DECOMPILED}" -name 'BuildConfig.smali' -path '*/formulaone/*' -print -quit)"
if [[ -n "${BUILDCONFIG}" ]]; then
    # VERSION_NAME is a const-string like: const-string v0, "3.0.47.1-SP153..."
    sed -i '/:->VERSION_NAME:Ljava\/lang\/String;/,/const-string/{s/\(const-string [^,]*, "\)\([^"]*\)"/\1\2-UHD"/}' "${BUILDCONFIG}"
    ok "BuildConfig VERSION_NAME updated"
else
    # Fallback: search all BuildConfig.smali files
    BUILDCONFIG="$(find "${DECOMPILED}" -name 'BuildConfig.smali' -print -quit)"
    if [[ -n "${BUILDCONFIG}" ]]; then
        sed -i '/VERSION_NAME/s/\(const-string [^,]*, "\)\([^"]*\)"/\1\2-UHD"/' "${BUILDCONFIG}"
        ok "BuildConfig VERSION_NAME updated (fallback)"
    else
        warn "BuildConfig.smali not found, skipping in-app version patch"
    fi
fi

# ─── Rebuild with apktool ────────────────────────────────────────────────────

REBUILT="${WORKDIR}/rebuilt"
info "Rebuilding with apktool..."
apktool b -f -o "${REBUILT}/base-rebuilt.apk" "${DECOMPILED}" >/dev/null 2>&1 || die "apktool build failed"
ok "Rebuild complete"

# ─── Inject patched dex into original base.apk ───────────────────────────────

info "Injecting patched dex files into original base.apk..."
PATCHED_BASE="${WORKDIR}/base-patched.apk"
cp "${BASE_APK}" "${PATCHED_BASE}"

mkdir -p "${WORKDIR}/inject_tmp"
(cd "${WORKDIR}/inject_tmp" && unzip -q "${WORKDIR}/rebuilt/base-rebuilt.apk" 'classes*.dex' 'AndroidManifest.xml')

zip -qd "${PATCHED_BASE}" 'META-INF/*' 2>/dev/null || true
zip -qd "${PATCHED_BASE}" 'classes*.dex' 2>/dev/null || true
zip -qd "${PATCHED_BASE}" 'AndroidManifest.xml' 2>/dev/null || true
(cd "${WORKDIR}/inject_tmp" && zip -q -0 "${PATCHED_BASE}" classes*.dex AndroidManifest.xml)

ok "Dex injection complete"

# ─── Collect all APKs ────────────────────────────────────────────────────────

BUNDLE_DIR="${WORKDIR}/bundle"
ALL_APKS=("${PATCHED_BASE}")
while IFS= read -r -d '' split; do
    # Skip the original base APK (already replaced by patched version)
    [[ "$(realpath "${split}")" == "$(realpath "${BASE_APK}")" ]] && continue
    ALL_APKS+=("${split}")
done < <(find "${BUNDLE_DIR}" -maxdepth 1 -name '*.apk' -print0)

info "Found ${#ALL_APKS[@]} APK(s) to process (base + ${#ALL_APKS[@]}-1 splits)"

# ─── Remove signatures from all splits ───────────────────────────────────────

info "Removing existing signatures..."
for apk in "${ALL_APKS[@]}"; do
    zip -qd "${apk}" 'META-INF/*' 2>/dev/null || true
done
ok "Signatures removed"

# ─── Keystore ─────────────────────────────────────────────────────────────────

KEYSTORE="${KEYSTORE_PATH:-${WORKDIR}/patch.keystore}"
KS_PASS="${KEYSTORE_PASS:-android}"
KEY_ALIAS="${KEYSTORE_ALIAS:-f1tvpatch}"

if [[ ! -f "${KEYSTORE}" ]]; then
    info "Generating signing keystore..."
    keytool -genkeypair \
        -keystore "${KEYSTORE}" \
        -storepass "${KS_PASS}" \
        -keypass "${KS_PASS}" \
        -alias "${KEY_ALIAS}" \
        -keyalg RSA \
        -keysize 2048 \
        -validity 10000 \
        -dname "CN=F1TV UHD Patch,O=f1pipeline,C=US" 2>/dev/null
    ok "Keystore created"
else
    ok "Using provided keystore"
fi

# ─── Zipalign all APKs ───────────────────────────────────────────────────────

ALIGNED_DIR="${WORKDIR}/aligned"
mkdir -p "${ALIGNED_DIR}"

info "Zipaligning APKs..."
zipalign -f 4 "${PATCHED_BASE}" "${ALIGNED_DIR}/base.apk"
ok "Aligned: base.apk"

for apk in "${ALL_APKS[@]}"; do
    name="$(basename "${apk}")"
    [[ "${apk}" == "${PATCHED_BASE}" ]] && continue
    zipalign -f 4 "${apk}" "${ALIGNED_DIR}/${name}"
    ok "Aligned: ${name}"
done

# ─── Sign all APKs ───────────────────────────────────────────────────────────

info "Signing APKs..."

SIGN_ARGS=(
    --ks "${KEYSTORE}"
    --ks-pass "pass:${KS_PASS}"
    --ks-key-alias "${KEY_ALIAS}"
    --key-pass "pass:${KS_PASS}"
)

for apk in "${ALIGNED_DIR}"/*.apk; do
    apksigner sign "${SIGN_ARGS[@]}" "${apk}"
    ok "Signed: $(basename "${apk}")"
done

# ─── Package output ──────────────────────────────────────────────────────────

# Copy aligned/signed APKs to output
info "Copying patched APKs to output..."
cp "${ALIGNED_DIR}"/*.apk "${OUTPUT_DIR}/"

# Also copy info.json if it exists (useful for metadata)
[[ -f "${INFO_JSON}" ]] && cp "${INFO_JSON}" "${OUTPUT_DIR}/"

# Create a .apkm bundle (zip of all APKs + info.json)
APKM_OUTPUT="${OUTPUT_DIR}/f1tv-uhd-patched.apkm"
(cd "${OUTPUT_DIR}" && zip -q "${APKM_OUTPUT}" *.apk info.json 2>/dev/null || zip -q "${APKM_OUTPUT}" *.apk)
ok "Created patched bundle: ${APKM_OUTPUT}"

# ─── Done ─────────────────────────────────────────────────────────────────────

echo ""
ok "======================================"
ok "  F1TV UHD patch complete!"
ok "======================================"
echo ""
info "Output directory: ${OUTPUT_DIR}"
info "Patched bundle:   ${APKM_OUTPUT}"
echo ""
info "To install on your device:"
info "  ./scripts/install.sh ${APKM_OUTPUT} [device-ip:5555]"
