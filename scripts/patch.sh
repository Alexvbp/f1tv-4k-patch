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

info "Patching DeviceSupportImpl validators..."
python3 - "${SMALI_FILE}" << 'PYEOF'
import sys, re

smali_path = sys.argv[1]
with open(smali_path, 'r') as f:
    content = f.read()

# Both validators return Pair<Boolean, String> — patch to always return Pair(true, null).
# This is the same stub used by the APKPure modded APK.
TRUE_PAIR_STUB = """
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

    new-instance v0, Lkotlin/Pair;

    const/4 v1, 0x1

    invoke-static {v1}, Ljava/lang/Boolean;->valueOf(Z)Ljava/lang/Boolean;

    move-result-object v1

    const/4 p1, 0x0

    invoke-direct {v0, v1, p1}, Lkotlin/Pair;-><init>(Ljava/lang/Object;Ljava/lang/Object;)V

    return-object v0
.end method"""

patched = 0

# Patch all 4 validators to always return Pair(true, null):
#   1. validateTmSdkSupport — ClearVR SDK secure HEVC decoder capability check
#      (queries VideoCapabilities.areSizeAndRateSupported(3840, 2160, 50.0) on secure decoder)
#   2. validateLowRamDeviceSupport — ActivityManager.isLowRamDevice() check
#   3. validateApiLevelSupport — Android API level minimum check
#   4. validateIsUhdSupportedDevice — UHD device brand/product whitelist from configPROD.json
validators = [
    "validateTmSdkSupport",
    "validateLowRamDeviceSupport",
    "validateApiLevelSupport",
    "validateIsUhdSupportedDevice",
]

for name in validators:
    pattern = (
        r'\.method private final ' + name + r'\('
        r'Lcom/avs/f1/ui/tiledmediaplayer/DeviceCapabilities;\)Lkotlin/Pair;'
        r'.*?'
        r'\.end method'
    )
    replacement = (f".method private final {name}("
        "Lcom/avs/f1/ui/tiledmediaplayer/DeviceCapabilities;)Lkotlin/Pair;"
        + TRUE_PAIR_STUB)
    content, count = re.subn(pattern, replacement, content, flags=re.DOTALL)
    if count:
        print(f"  Patched {name} → always true")
        patched += count
    else:
        print(f"  WARNING: {name} not found")

if patched == 0:
    print("ERROR: No validators were patched!", file=sys.stderr)
    sys.exit(1)

with open(smali_path, 'w') as f:
    f.write(content)

print(f"Patched {patched} validator(s)")
PYEOF

[[ $? -eq 0 ]] || die "Smali patching failed"
ok "DeviceSupportImpl validators patched"

# ─── Patch diagnostics preferences ──────────────────────────────────────────

info "Searching for DiagnosticsPreferenceManagerImpl.smali..."
DIAG_SMALI="$(find "${DECOMPILED}" -name 'DiagnosticsPreferenceManagerImpl.smali' -print -quit)"
if [[ -n "${DIAG_SMALI}" ]]; then
    ok "Found: ${DIAG_SMALI#${WORKDIR}/}"
    info "Enabling the in-app quality selector..."
    python3 - "${DIAG_SMALI}" << 'PYEOF'
import sys, re

smali_path = sys.argv[1]
with open(smali_path, 'r') as f:
    content = f.read()

# Only enable the quality selector. The stream-type / player-type / logs
# overlays draw debug text on screen and are intentionally left off for a
# clean release (set them back here if you need on-screen diagnostics).
methods_to_enable = [
    "isVideoQualityEnabled",
]

total = 0
for method in methods_to_enable:
    pattern = (
        rf'\.method public {re.escape(method)}\(\)Z'
        r'.*?'
        r'\.end method'
    )

    replacement = f""".method public {method}()Z
    .locals 1

    # Diagnostics patch: always return true
    const/4 v0, 0x1

    return v0
.end method"""

    content, count = re.subn(pattern, replacement, content, flags=re.DOTALL)
    if count > 0:
        print(f"  Patched {method}")
        total += count
    else:
        print(f"  WARNING: {method} not found, skipping")

if total == 0:
    print("ERROR: No diagnostics methods were patched!", file=sys.stderr)
    sys.exit(1)

with open(smali_path, 'w') as f:
    f.write(content)

print(f"Patched {total} diagnostics method(s)")
PYEOF

    [[ $? -eq 0 ]] || die "Diagnostics patch failed"
    ok "Diagnostics patch applied"
else
    warn "DiagnosticsPreferenceManagerImpl.smali not found, skipping diagnostics patch"
fi

# ─── Spoof device model in request header ────────────────────────────────────

info "Searching for TvApplication.smali..."
TVAPP_SMALI="$(find "${DECOMPILED}" -name 'TvApplication.smali' -path '*/avs/f1/*' -print -quit)"
if [[ -n "${TVAPP_SMALI}" ]]; then
    ok "Found: ${TVAPP_SMALI#${WORKDIR}/}"
    info "Spoofing device model as Chromecast in request header..."
    python3 - "${TVAPP_SMALI}" << 'PYEOF'
import sys

smali_path = sys.argv[1]
with open(smali_path, 'r') as f:
    content = f.read()

# Replace Build.MODEL read with hardcoded "chromecast" string
# Original: sget-object v1, Landroid/os/Build;->MODEL:Ljava/lang/String;
# We replace the MODEL read + toLowerCase block with a const-string
old = '    sget-object v1, Landroid/os/Build;->MODEL:Ljava/lang/String;'
new = '    const-string v1, "Chromecast"'

if old not in content:
    print("ERROR: Could not find Build.MODEL in getRequestHeader!", file=sys.stderr)
    sys.exit(1)

content = content.replace(old, new, 1)

with open(smali_path, 'w') as f:
    f.write(content)

print("Spoofed Build.MODEL as 'Chromecast' in request header")
PYEOF

    [[ $? -eq 0 ]] || die "Model spoof patch failed"
    ok "Model spoof patch applied"
else
    warn "TvApplication.smali not found, skipping model spoof"
fi

# ─── Patch ClearVR decoder capabilities (force 4K tiled streaming) ─────────

info "Searching for DecoderCapability.smali..."
DECODER_CAP_SMALI="$(find "${DECOMPILED}" -name 'DecoderCapability.smali' -path '*/tiledmedia/*' -print -quit)"
if [[ -n "${DECODER_CAP_SMALI}" ]]; then
    ok "Found: ${DECODER_CAP_SMALI#${WORKDIR}/}"
    info "Patching ClearVR decoder capability reporting..."
    python3 - "${DECODER_CAP_SMALI}" << 'PYEOF'
import sys

smali_path = sys.argv[1]
with open(smali_path, 'r') as f:
    content = f.read()

# In getAsCoreProtobuf(), override the values sent to the ClearVR backend.
# The SDK probes local hardware and reports capabilities via protobuf.
# Devices without a ClearVR quirk profile report 0 for tile slots/rows/cols,
# causing the backend to serve a lower resolution tier (2880x1620 instead of 3840x2160).

patches = [
    # Override secureDecoderMaximumTileSlotCount: 0 → 16 (matches Oculus Go/Quest profiles)
    (
        '    iget v2, p0, Lcom/tiledmedia/clearvrdecoder/util/DecoderCapability;->maxNumberOfSecureHEVCSamples:I',
        '    const/16 v2, 0x10',
        'secureDecoderMaximumTileSlotCount → 16'
    ),
    # Override maxTileRows: 0 → 5 (matches Chromecast/Google TV profile)
    (
        '    iget v2, p0, Lcom/tiledmedia/clearvrdecoder/util/DecoderCapability;->maxTileRows:I',
        '    const/4 v2, 0x5',
        'maxTileRows → 5'
    ),
    # Override maxTileColumns: 0 → 5 (matches Chromecast/Google TV profile)
    (
        '    iget v2, p0, Lcom/tiledmedia/clearvrdecoder/util/DecoderCapability;->maxTileColumns:I',
        '    const/4 v2, 0x5',
        'maxTileColumns → 5'
    ),
]

patched = 0
for old, new, desc in patches:
    if old in content:
        content = content.replace(old, new, 1)
        print(f"  Patched {desc}")
        patched += 1
    else:
        print(f"  WARNING: Could not find pattern for {desc}, skipping")

if patched == 0:
    print("ERROR: No ClearVR capability patches applied!", file=sys.stderr)
    sys.exit(1)

with open(smali_path, 'w') as f:
    f.write(content)

print(f"Patched {patched}/3 ClearVR decoder capabilities")
PYEOF

    [[ $? -eq 0 ]] || die "ClearVR capability patch failed"
    ok "ClearVR capability patch applied"
else
    warn "DecoderCapability.smali not found, skipping ClearVR patch"
fi

# ─── Disable NVIDIA post-process workaround in ClearVR ────────────────────

info "Searching for Quirks.smali..."
QUIRKS_SMALI="$(find "${DECOMPILED}" -name 'Quirks.smali' -path '*/tiledmedia/clearvrdecoder/*' -print -quit)"
if [[ -n "${QUIRKS_SMALI}" ]]; then
    ok "Found: ${QUIRKS_SMALI#${WORKDIR}/}"
    info "Disabling NVIDIA no-post-process workaround..."
    python3 - "${QUIRKS_SMALI}" << 'PYEOF'
import sys, re

smali_path = sys.argv[1]
with open(smali_path, 'r') as f:
    content = f.read()

# Patch deviceNeedsNoPostProcessWorkaround() to always return false.
# On NVIDIA devices this sets "no-post-process"=1 on the decoder MediaFormat,
# which may cause ClearVR to select a lower quality tile tier.
pattern = (
    r'\.method public static deviceNeedsNoPostProcessWorkaround\(\)Z'
    r'.*?'
    r'\.end method'
)

replacement = """.method public static deviceNeedsNoPostProcessWorkaround()Z
    .locals 1

    const/4 v0, 0x0

    return v0
.end method"""

content, count = re.subn(pattern, replacement, content, flags=re.DOTALL)

if count == 0:
    print("WARNING: deviceNeedsNoPostProcessWorkaround not found, skipping")
else:
    print(f"Patched deviceNeedsNoPostProcessWorkaround → always false")

with open(smali_path, 'w') as f:
    f.write(content)
PYEOF

    [[ $? -eq 0 ]] || die "NVIDIA workaround patch failed"
    ok "NVIDIA workaround patch applied"
else
    warn "Quirks.smali not found, skipping NVIDIA workaround patch"
fi

# ─── Patch NRP blit mode to NATIVE_ANDROID_DIRECT_TO_VIEW ──────────────────
#
# Tiledmedia's default blit mode (AUTO_DETECT) routes decoded frames through
# GPU tile composition via SurfaceTexture → EGL → swapBuffers. This causes
# frame drops on weaker GPUs and may fail on devices that don't support
# intermediate resolutions during the quality ramp (e.g. 2560x1620).
# The SDK has a built-in NATIVE_ANDROID_DIRECT_TO_VIEW mode that bypasses
# GPU composition and outputs the decoder directly to the SurfaceView.
#
# DEFAULT OFF. direct-to-view tags the output surface with the CONTENT's transfer
# (HLG for F1 UHD) and does no gamut conversion. On a panel that accepts HDR10 but
# not HLG the compositor can't switch modes and shows the BT.2020 frames through
# an SDR/Rec.709 surface with no conversion — i.e. washed-out colours. The default
# EGL/GL render path (this patch skipped) composites the tiles and does a correct
# BT.2020→Rec.709 conversion, giving accurate 4K. Set F1TV_DIRECT_TO_VIEW=1 to
# force direct-to-view on weak/Amlogic GPUs that drop frames on the GL path
# (accepting the washed-out HDR look as the tradeoff).

RENDER_CONFIG="$(find "${DECOMPILED}" -name 'RenderAPIConfig.smali' -path '*/tiledmedia/*' -print -quit 2>/dev/null || true)"

if [[ "${F1TV_DIRECT_TO_VIEW:-0}" == "0" ]]; then
    info "Using the EGL/GL render path for correct 4K colours (set F1TV_DIRECT_TO_VIEW=1 for weak/Amlogic GPUs)"
elif [[ -n "${RENDER_CONFIG}" && -f "${RENDER_CONFIG}" ]]; then
    info "Patching NRP blit mode to direct-to-view (opt-in, for weak/Amlogic GPUs)..."
    python3 - "${RENDER_CONFIG}" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Patch getNRPTextureBlitMode() to always return NATIVE_ANDROID_DIRECT_TO_VIEW.
# Original:
#   iget-object v0, p0, ...->nrpTextureBlitMode
#   return-object v0
#
# Patched:
#   return NATIVE_ANDROID_DIRECT_TO_VIEW unconditionally

old = """    iget-object v0, p0, Lcom/tiledmedia/clearvrview/RenderAPIConfig;->nrpTextureBlitMode:Lcom/tiledmedia/clearvrenums/NRPTextureBlitMode;

    return-object v0"""

new = """    sget-object v0, Lcom/tiledmedia/clearvrenums/NRPTextureBlitMode;->NATIVE_ANDROID_DIRECT_TO_VIEW:Lcom/tiledmedia/clearvrenums/NRPTextureBlitMode;

    return-object v0"""

if old not in content:
    print(f"Could not find getNRPTextureBlitMode pattern in {path}", file=sys.stderr)
    sys.exit(1)

content = content.replace(old, new, 1)

with open(path, 'w') as f:
    f.write(content)
print(f"  Patched {path}")
PYEOF

    [[ $? -eq 0 ]] && ok "NRP direct-to-view patch applied (all devices)" || warn "NRP direct-to-view patch failed"
else
    warn "RenderAPIConfig.smali not found, skipping direct-to-view patch"
fi

# ─── Force 4K display detection (lifts the 1.5x resolution cap) ─────────────
#
# Tiledmedia caps streaming resolution at ~1.5x the display size it detects.
# On NVIDIA Shield (and similar) the SDK reads the 1080p UI surface, so it caps
# tiles at 2880x1620 instead of 3840x2160 — the "can only select up to
# 2880x1620" symptom (issue #9). Force getDefaultDisplaySize() to report a
# 3840x2160 panel so the cap allows full 2160p.

info "Searching for TrueTVDisplaySizeHelper.smali..."
TRUE_TV_HELPER="$(find "${DECOMPILED}" -name 'TrueTVDisplaySizeHelper.smali' -path '*/tiledmedia/*' -print -quit)"
if [[ -n "${TRUE_TV_HELPER}" ]]; then
    ok "Found: ${TRUE_TV_HELPER#${WORKDIR}/}"
    info "Forcing display size to 3840x2160..."
    python3 - "${TRUE_TV_HELPER}" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Replace getDefaultDisplaySize() body with a hardcoded 3840x2160 Point.
# Preserve its modifiers and support both Context- and Activity-based SDK versions.
# 0xf00 = 3840, 0x870 = 2160. Result is also cached in trueDisplaySize.
pattern = (
    r'(?P<declaration>\.method [^\n]*\bgetDefaultDisplaySize\(Landroid/(?:app/Activity|content/Context);\)Landroid/graphics/Point;)'
    r'.*?'
    r'\.end method'
)
replacement = r"""\g<declaration>
    .locals 3

    # UHD Patch: always report a 3840x2160 panel
    new-instance v0, Landroid/graphics/Point;

    const/16 v1, 0xf00

    const/16 v2, 0x870

    invoke-direct {v0, v1, v2}, Landroid/graphics/Point;-><init>(II)V

    sput-object v0, Lcom/tiledmedia/clearvrview/TrueTVDisplaySizeHelper;->trueDisplaySize:Landroid/graphics/Point;

    return-object v0
.end method"""

content, count = re.subn(pattern, replacement, content, flags=re.DOTALL)
if count == 0:
    print("ERROR: getDefaultDisplaySize not found", file=sys.stderr)
    sys.exit(1)

with open(path, 'w') as f:
    f.write(content)
print(f"Patched getDefaultDisplaySize -> 3840x2160")
PYEOF

    [[ $? -eq 0 ]] || die "4K display patch failed"
    ok "4K display detection patch applied"
else
    warn "TrueTVDisplaySizeHelper.smali not found, skipping 4K display patch"
fi

# ─── HLG/HDR unlock (default ON — required for the 2160p tier) ──────────────
#
# F1TV only serves the 2160p tier inside the HDR manifest; SDR is hard-capped at
# 1620p server-side. ClearVR reports which HDR transfer functions it can render
# to the F1TV backend via DeviceParameters -> addEglSupportedHDRTypes(PQ/HLG),
# and that call is gated SOLELY on getIsBt2020HlgExtensionSupported(). The NVIDIA
# Shield's EGL does not expose the BT2020 colorspace extension, so unpatched the
# SDK reports "no EGL HDR" and the backend withholds EVERY 2160p tier (they are
# all HDR). Forcing the check true makes ClearVR report PQ+HLG, so the 2160p HDR
# tier is offered — this is REQUIRED for 4K, not a fallback.
#
# The direct-to-view blit patch above is what makes this safe: the decoder
# outputs straight to the SurfaceView, so Android's display pipeline handles HLG
# instead of the EGL colorspace path that would otherwise fail on the Shield. The
# real display-capability probe (doesDisplaySupport) still runs, so SDR-only
# panels fall back to SDR automatically. Set F1TV_HLG_BYPASS=0 to skip this patch.

if [[ "${F1TV_HLG_BYPASS:-1}" != "0" ]]; then
    info "Patching HLG extension support (required for the 2160p HDR tier)..."
    EGL_RENDER="$(find "${DECOMPILED}" -name 'EGLRenderTarget.smali' -path '*/tiledmedia/*' -print -quit)"
    if [[ -n "${EGL_RENDER}" ]]; then
        ok "Found: ${EGL_RENDER#${WORKDIR}/}"
        python3 - "${EGL_RENDER}" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Force getIsBt2020HlgExtensionSupported() to always return true.
pattern = (
    r'\.method public static getIsBt2020HlgExtensionSupported\(\)Z'
    r'.*?'
    r'\.end method'
)
replacement = """.method public static getIsBt2020HlgExtensionSupported()Z
    .locals 1

    # UHD Patch: always advertise HLG support
    const/4 v0, 0x1

    return v0
.end method"""

content, count = re.subn(pattern, replacement, content, flags=re.DOTALL)
if count == 0:
    print("ERROR: getIsBt2020HlgExtensionSupported not found", file=sys.stderr)
    sys.exit(1)

with open(path, 'w') as f:
    f.write(content)
print(f"Patched getIsBt2020HlgExtensionSupported -> true")
PYEOF

        [[ $? -eq 0 ]] || die "HLG bypass patch failed"
        ok "HLG bypass patch applied"
    else
        warn "EGLRenderTarget.smali not found, skipping HLG bypass"
    fi
else
    warn "F1TV_HLG_BYPASS=0 — skipping HLG unlock; the 2160p tier will NOT be offered (SDR caps at 1620p)"
fi

# ─── Reroute HLG content to the PQ render path (default ON) ─────────────────
#
# F1TV's 2160p is HLG. Many devices (notably the NVIDIA Shield) expose the EGL
# BT2020 *PQ* colorspace (EGL_EXT_gl_colorspace_bt2020_pq) but NOT the *HLG* one.
# On the EGL/GL render path ClearVR tags F1 content requireHLG and tries to create
# an HLG EGL surface (EGLRenderTarget surface-creation reads
# RenderTargetConfig.requireHLG()/require2020PQ()), which fails on those devices
# and drops to SDR 1620p.
#
# This reroutes the render path: requireHLG() -> false, require2020PQ() -> (PQ||HLG),
# so the HDR tiles are rendered through the PQ colorspace the device DOES support
# and correctly gamut-converted for output. SDR content (both flags false) is
# unaffected. Pairs with the default EGL path (F1TV_DIRECT_TO_VIEW=0); it is inert
# under direct-to-view. Set F1TV_PQ_REROUTE=0 to disable.
if [[ "${F1TV_PQ_REROUTE:-1}" != "0" ]]; then
    info "Rerouting HLG render path to the PQ colorspace (correct 4K colours)..."
    RTC_SMALI="$(find "${DECOMPILED}" -name 'RenderTargetConfig.smali' -path '*/tiledmedia/*' -print -quit)"
    if [[ -n "${RTC_SMALI}" ]]; then
        ok "Found: ${RTC_SMALI#${WORKDIR}/}"
        python3 - "${RTC_SMALI}" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path) as f:
    content = f.read()

C = 'Lcom/tiledmedia/clearvrview/RenderTargetConfig;'

# requireHLG() -> always false (device can't create an HLG EGL surface)
hlg_new = f""".method public requireHLG()Z
    .locals 1

    const/4 v0, 0x0

    return v0
.end method"""
content, n1 = re.subn(r'\.method public requireHLG\(\)Z.*?\.end method', hlg_new, content, flags=re.DOTALL)

# require2020PQ() -> (_require2020PQ OR _requireHLG): route HLG content through PQ
pq_new = f""".method public require2020PQ()Z
    .locals 2

    iget-boolean v0, p0, {C}->_require2020PQ:Z

    iget-boolean v1, p0, {C}->_requireHLG:Z

    or-int/2addr v0, v1

    return v0
.end method"""
content, n2 = re.subn(r'\.method public require2020PQ\(\)Z.*?\.end method', pq_new, content, flags=re.DOTALL)

if n1 != 1 or n2 != 1:
    print(f"ERROR: PQ reroute pattern miss (requireHLG={n1}, require2020PQ={n2})", file=sys.stderr)
    sys.exit(1)

with open(path, 'w') as f:
    f.write(content)
print("PQ reroute applied (requireHLG->false, require2020PQ->PQ||HLG)")
PYEOF
        [[ $? -eq 0 ]] || die "PQ reroute patch failed"
        ok "PQ reroute patch applied"
    else
        warn "RenderTargetConfig.smali not found, skipping PQ reroute"
    fi
fi

# ─── Spoof display HDR capability (default ON — the 2160p unlock) ───────────
#
# This is what actually gets 2160p onto the NVIDIA Shield and other HDR10-only
# panels. ClearVR's DeviceParameters.doesDisplaySupport() reads
# Display.getHdrCapabilities().getSupportedHdrTypes() and reports it to the core.
# The core only serves an HDR tier whose type is in BOTH the EGL-supported AND
# the DISPLAY-supported sets. F1's 2160p is HLG (type 3); a panel that reports
# only HDR10 (type 2) makes the core reject HLG upstream and fall back to the SDR
# 1620p tile before any render target is created.
#
# Forcing doesDisplaySupport() -> true makes the core serve the 2160p (HLG) tiles.
# The device's video pipeline then converts HLG to whatever the panel accepts
# (HDR10, or a clean SDR downconvert), the same path YouTube HLG uses on an HDR10
# TV. On genuinely HDR-capable devices this is a no-op. Set F1TV_DISPLAY_HDR_SPOOF=0
# to disable and fall back to stock behaviour (SDR-capable devices cap at 1620p).
if [[ "${F1TV_DISPLAY_HDR_SPOOF:-1}" != "0" ]]; then
    info "Forcing display HDR-type support (unlocks the 2160p tier)..."
    DEVPARAMS="$(find "${DECOMPILED}" -name 'DeviceParameters.smali' -path '*/tiledmedia/*' -print -quit)"
    if [[ -n "${DEVPARAMS}" ]]; then
        ok "Found: ${DEVPARAMS#${WORKDIR}/}"
        python3 - "${DEVPARAMS}" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    content = f.read()
new = """.method private static doesDisplaySupport(Landroid/content/Context;I)Z
    .locals 1

    const/4 v0, 0x1

    return v0
.end method"""
content, n = re.subn(r'\.method private static doesDisplaySupport\(Landroid/content/Context;I\)Z.*?\.end method', new, content, flags=re.DOTALL)
if n != 1:
    print(f"ERROR: doesDisplaySupport not found ({n})", file=sys.stderr); sys.exit(1)
with open(path, 'w') as f:
    f.write(content)
print("doesDisplaySupport -> always true (display reports all HDR types)")
PYEOF
        [[ $? -eq 0 ]] || die "Display HDR spoof patch failed"
        ok "Display HDR spoof patch applied"
    else
        warn "DeviceParameters.smali not found, skipping display HDR spoof"
    fi
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

# ─── ABI sanity check (arm64 needed for reliable 4K on modern TVs) ──────────
# The ClearVR native decoder/renderer ships per-ABI. On an arm64 device the app
# runs whichever native split is installed; a bundle with only armeabi-v7a forces
# ClearVR to run 32-bit, which commonly can't sustain 4K secure HEVC (TM4014 /
# "acquireVdecResource not enough" errors). Warn loudly so v7a-only builds don't
# masquerade as full 4K bundles.
if ! printf '%s\n' "${ALL_APKS[@]}" | grep -q 'arm64_v8a'; then
    warn "No arm64-v8a split in this bundle — ClearVR will run 32-bit on arm64 devices (NVIDIA Shield, etc.)."
    warn "32-bit often can't sustain 4K secure HEVC. For full 4K, build from the Google Play (arm64) source."
else
    ok "arm64-v8a split present (native 64-bit ClearVR — required for reliable 4K)"
fi

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
