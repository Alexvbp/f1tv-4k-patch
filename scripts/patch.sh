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

# NOTE: the old "spoof Build.MODEL as Chromecast" patch was removed. It replaced
# the FIRST Build.MODEL read in TvApplication.smali, which lives in
# getDeviceType() (the Amazon Fire-Stick vs Fire-TV check), not in
# getRequestHeader() — so the x-f1-device-info header always carried the real
# model and the only effect was mis-detecting Amazon devices. The UHD whitelist
# is bypassed client-side (validateIsUhdSupportedDevice) so no spoof is needed.

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

# NOTE: the old opt-in F1TV_DIRECT_TO_VIEW patch (RenderAPIConfig.getNRPTextureBlitMode)
# was removed. ClearVR SDK ≥ SP164 (F1TV 3.0.49.x) no longer has an app-level
# blit-mode switch: the core now picks DIRECT vs GL rendering per view from the
# surface capabilities the SDK reports. We feed it honest capabilities instead —
# see "Surface HDR capability" below.

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

# ─── HDR advertise + real EGL probes (default ON — required for the 2160p tier) ─
#
# F1TV only serves the 2160p tier inside the HDR manifest; SDR is hard-capped at
# 1620p server-side. ClearVR reports which HDR transfer functions it can render
# to the F1TV backend via DeviceParameters -> addEglSupportedHDRTypes(PQ/HLG),
# and that call is gated SOLELY on EGLRenderTarget.getIsBt2020HlgExtensionSupported().
# Most Android TV GPUs (NVIDIA Shield included) do not expose the EGL BT2020 HLG
# colorspace extension, so unpatched the SDK reports "no EGL HDR" and the backend
# withholds EVERY 2160p tier. Forcing that method true makes the 2160p HDR tier
# be offered — this is REQUIRED for 4K.
#
# The forced answer must NOT leak into the render path though, so the original
# probe is preserved under new names and used by the patches below to pick the
# right path per device at runtime:
#   uhdRealHlgSupported()  — the stock HLG probe (EGL_EXT_gl_colorspace_bt2020_hlg)
#   uhdRealPqSupported()   — raw PQ probe (EGL_EXT_gl_colorspace_bt2020_pq), with
#                            no API-level gate (stock gates PQ on API 33+, which
#                            wrongly excludes the Shield on Android 11)
# Set F1TV_HLG_BYPASS=0 to skip (the 2160p tier will then NOT be offered).

if [[ "${F1TV_HLG_BYPASS:-1}" != "0" ]]; then
    info "Patching EGL HDR advertise + adding real HLG/PQ probes (required for the 2160p tier)..."
    EGL_RENDER="$(find "${DECOMPILED}" -name 'EGLRenderTarget.smali' -path '*/tiledmedia/*' -print -quit)"
    [[ -n "${EGL_RENDER}" ]] || die "EGLRenderTarget.smali not found — cannot unlock the 2160p tier"
    ok "Found: ${EGL_RENDER#${WORKDIR}/}"
    if ! python3 - "${EGL_RENDER}" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path) as f:
    content = f.read()

C = 'Lcom/tiledmedia/clearvrview/EGLRenderTarget;'

# 1. Keep the stock HLG probe, renamed to uhdRealHlgSupported().
pattern = r'\.method public static getIsBt2020HlgExtensionSupported\(\)Z\n(?P<body>.*?)\.end method'
m = re.search(pattern, content, flags=re.DOTALL)
if not m:
    print("ERROR: getIsBt2020HlgExtensionSupported not found", file=sys.stderr)
    sys.exit(1)
body = m.group('body')
if 'EGL_EXT_gl_colorspace_bt2020_hlg' not in body or '_getIsExtensionSupported' not in body:
    print("ERROR: getIsBt2020HlgExtensionSupported body does not look like the stock EGL probe", file=sys.stderr)
    sys.exit(1)

real_hlg = ".method public static uhdRealHlgSupported()Z\n" + body + ".end method"

# 2. Forced advertise — what DeviceParameters reports to the backend.
forced = """.method public static getIsBt2020HlgExtensionSupported()Z
    .locals 1

    # UHD Patch: always advertise HLG so the 2160p (HDR) tier is offered
    const/4 v0, 0x1

    return v0
.end method"""

# 3. Raw PQ probe (cached), no API-level gate.
real_pq = f""".method public static uhdRealPqSupported()Z
    .locals 1

    sget-boolean v0, {C}->uhdPqDetected:Z

    if-nez v0, :cond_0

    const/4 v0, 0x1

    sput-boolean v0, {C}->uhdPqDetected:Z

    const-string v0, "EGL_EXT_gl_colorspace_bt2020_pq"

    invoke-static {{v0}}, {C}->_getIsExtensionSupported(Ljava/lang/String;)Z

    move-result v0

    sput-boolean v0, {C}->uhdPqSupported:Z

    :cond_0
    sget-boolean v0, {C}->uhdPqSupported:Z

    return v0
.end method"""

# 4. "Can this GL surface show HLG content correctly?" — natively, or via the
#    PQ reroute in RenderTargetConfig. Reported to the core as the surface's HLG
#    capability so devices with neither extension are routed off the GL HDR path.
hlg_renderable = f""".method public static uhdSurfaceHlgRenderable()Z
    .locals 1

    invoke-static {{}}, {C}->uhdRealHlgSupported()Z

    move-result v0

    if-eqz v0, :cond_0

    const/4 v0, 0x1

    return v0

    :cond_0
    invoke-static {{}}, {C}->uhdRealPqSupported()Z

    move-result v0

    return v0
.end method"""

content = content[:m.start()] + "\n\n".join([real_hlg, forced, real_pq, hlg_renderable]) + content[m.end():]

# Backing fields for the PQ cache.
anchor = '.field private static _isBt2020PqExtensionSupportedDetected:Z\n'
if anchor not in content:
    print("ERROR: field anchor _isBt2020PqExtensionSupportedDetected not found", file=sys.stderr)
    sys.exit(1)
content = content.replace(anchor, anchor + '\n.field private static uhdPqDetected:Z\n\n.field private static uhdPqSupported:Z\n', 1)

with open(path, 'w') as f:
    f.write(content)
print("getIsBt2020HlgExtensionSupported -> true; added uhdRealHlgSupported/uhdRealPqSupported/uhdSurfaceHlgRenderable")
PYEOF
    then
        die "HDR advertise patch failed"
    fi
    ok "HDR advertise patch applied"
else
    warn "F1TV_HLG_BYPASS=0 — skipping HDR advertise; the 2160p tier will NOT be offered (SDR caps at 1620p)"
fi

# ─── Runtime HLG→PQ reroute (only where the GPU lacks the HLG colorspace) ───
#
# F1TV's 2160p is HLG. On the GL render path ClearVR tags F1 content requireHLG
# and creates an HLG EGL surface. Devices like the NVIDIA Shield expose the EGL
# BT2020 *PQ* colorspace but not the *HLG* one, so that surface creation fails
# and playback drops to SDR 1620p. Rerouting HLG content through the PQ
# colorspace fixes the Shield — but doing it unconditionally (as releases up to
# 3.0.49.4 did) ALSO hits devices that DO support HLG (Homatics, Mi Box, HLG TVs):
# HLG-encoded pixels shown through a PQ-tagged surface come out dark with
# crushed blacks (issue #20).
#
# So decide at runtime, per device:
#   requireHLG()    = _requireHLG && uhdRealHlgSupported()      -> native HLG surface
#   require2020PQ() = _require2020PQ || (_requireHLG && !uhdRealHlgSupported())
#                                                                -> PQ reroute (Shield)
# SDR content (both flags false) is untouched.

if [[ "${F1TV_HLG_BYPASS:-1}" != "0" ]]; then
    info "Patching RenderTargetConfig for a per-device HLG/PQ render path..."
    RTC_SMALI="$(find "${DECOMPILED}" -name 'RenderTargetConfig.smali' -path '*/tiledmedia/*' -print -quit)"
    [[ -n "${RTC_SMALI}" ]] || die "RenderTargetConfig.smali not found"
    ok "Found: ${RTC_SMALI#${WORKDIR}/}"
    if ! python3 - "${RTC_SMALI}" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path) as f:
    content = f.read()

C = 'Lcom/tiledmedia/clearvrview/RenderTargetConfig;'
E = 'Lcom/tiledmedia/clearvrview/EGLRenderTarget;'

hlg_new = f""".method public requireHLG()Z
    .locals 1

    # UHD Patch: only ask for an HLG EGL surface when the GPU really has it
    iget-boolean v0, p0, {C}->_requireHLG:Z

    if-nez v0, :cond_0

    const/4 v0, 0x0

    return v0

    :cond_0
    invoke-static {{}}, {E}->uhdRealHlgSupported()Z

    move-result v0

    return v0
.end method"""
content, n1 = re.subn(r'\.method public requireHLG\(\)Z.*?\.end method', hlg_new, content, flags=re.DOTALL)

pq_new = f""".method public require2020PQ()Z
    .locals 2

    # UHD Patch: route HLG content through PQ when the GPU lacks the HLG colorspace
    iget-boolean v0, p0, {C}->_require2020PQ:Z

    if-eqz v0, :cond_0

    const/4 v0, 0x1

    return v0

    :cond_0
    iget-boolean v0, p0, {C}->_requireHLG:Z

    if-nez v0, :cond_1

    const/4 v0, 0x0

    return v0

    :cond_1
    invoke-static {{}}, {E}->uhdRealHlgSupported()Z

    move-result v1

    if-eqz v1, :cond_2

    const/4 v0, 0x0

    :cond_2
    return v0
.end method"""
content, n2 = re.subn(r'\.method public require2020PQ\(\)Z.*?\.end method', pq_new, content, flags=re.DOTALL)

if n1 != 1 or n2 != 1:
    print(f"ERROR: RenderTargetConfig pattern miss (requireHLG={n1}, require2020PQ={n2})", file=sys.stderr)
    sys.exit(1)

with open(path, 'w') as f:
    f.write(content)
print("requireHLG -> HLG && realHlg; require2020PQ -> PQ || (HLG && !realHlg)")
PYEOF
    then
        die "Runtime HLG/PQ reroute patch failed"
    fi
    ok "Runtime HLG/PQ reroute patch applied"
fi

# ─── Surface HDR capability (SDK ≥ SP164): honest answer to the core ─────────
#
# Newer ClearVR SDKs (F1TV 3.0.49.x+) report, per view, whether the GL surface
# can show PQ / HLG (TMViewModel -> DisplayObjectMapping.SurfaceCapabilities) and
# the core picks the render path from that. With getIsBt2020HlgExtensionSupported()
# forced true, every device claimed an HLG-capable GL surface — including
# MediaTek / Amlogic TVs with neither EGL colorspace, which then fail or stutter
# on the GL HDR path (issues #5, #11, #17). Report what we can actually render:
#   HLG-capable surface = real HLG extension OR real PQ extension (via reroute).
# Devices with neither are routed by the core to its non-GL (direct) path, where
# the TV's own video pipeline handles HLG. Older SDKs have no such call: skipped.

TMVM_SMALI="$(find "${DECOMPILED}" -name 'TMViewModel.smali' -path '*/tiledmedia/*' -print -quit)"
if [[ "${F1TV_HLG_BYPASS:-1}" != "0" && -n "${TMVM_SMALI}" ]] \
   && grep -q 'EGLRenderTarget;->getIsBt2020HlgExtensionSupported()Z' "${TMVM_SMALI}"; then
    info "Patching TMViewModel surface HDR capability report..."
    if ! python3 - "${TMVM_SMALI}" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    content = f.read()

old = 'invoke-static {}, Lcom/tiledmedia/clearvrview/EGLRenderTarget;->getIsBt2020HlgExtensionSupported()Z'
new = 'invoke-static {}, Lcom/tiledmedia/clearvrview/EGLRenderTarget;->uhdSurfaceHlgRenderable()Z'
n = content.count(old)
if n != 1:
    print(f"ERROR: expected exactly 1 HLG capability call in TMViewModel, found {n}", file=sys.stderr)
    sys.exit(1)
content = content.replace(old, new, 1)

with open(path, 'w') as f:
    f.write(content)
print("SurfaceCapabilities.supportsHDRHlg -> uhdSurfaceHlgRenderable()")
PYEOF
    then
        die "Surface HDR capability patch failed"
    fi
    ok "Surface HDR capability patch applied"
else
    info "TMViewModel has no surface HDR capability call (older SDK) — nothing to patch"
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

# ─── Self-check: every patch left its marker in the smali ───────────────────
#
# Catches silent pattern misses when F1TV ships a new ClearVR SDK (a miss here
# must fail the build rather than publish a half-patched bundle).
# (No `grep -q` at the end of pipes here: with pipefail, an early exit can kill
# awk with SIGPIPE and turn a hit into a failure.)

info "Verifying patched smali..."
VERIFY_FAILED=0
verify_marker() {   # <file-glob-name> <path-filter> <grep -E pattern> <description>
    local f
    f="$(find "${DECOMPILED}" -name "$1" -path "$2" -print -quit)"
    if [[ -z "${f}" ]]; then
        warn "  MISSING FILE: $1 ($4)"; VERIFY_FAILED=1; return
    fi
    if grep -qE -- "$3" "${f}"; then
        ok "  $4"
    else
        warn "  NOT APPLIED: $4"; VERIFY_FAILED=1
    fi
}
if f="$(find "${DECOMPILED}" -name 'DeviceSupportImpl.smali' -path '*/tiledmediaplayer/*' -print -quit)"; then
    n="$(awk '/\.method private final validate(TmSdkSupport|LowRamDeviceSupport|ApiLevelSupport|IsUhdSupportedDevice)\(/,/\.end method/' "${f}" | grep -c 'const/4 p1, 0x0' || true)"
    if [[ "${n}" == "4" ]]; then ok "  UHD validators stubbed (4/4)"; else warn "  NOT APPLIED: UHD validators ($n/4)"; VERIFY_FAILED=1; fi
fi
verify_marker 'DiagnosticsPreferenceManagerImpl.smali' '*' 'Diagnostics patch: always return true' 'quality selector enabled'
verify_marker 'DecoderCapability.smali'   '*/tiledmedia/*' 'const/16 v2, 0x10'                         'decoder tile capability spoof'
verify_marker 'TrueTVDisplaySizeHelper.smali' '*/tiledmedia/*' 'UHD Patch: always report a 3840x2160' '4K display size'
if [[ "${F1TV_HLG_BYPASS:-1}" != "0" ]]; then
    verify_marker 'EGLRenderTarget.smali'    '*/tiledmedia/*' 'UHD Patch: always advertise HLG'          'HDR advertise'
    verify_marker 'EGLRenderTarget.smali'    '*/tiledmedia/*' '^\.method public static uhdRealHlgSupported\(\)Z' 'real HLG probe'
    verify_marker 'EGLRenderTarget.smali'    '*/tiledmedia/*' '^\.method public static uhdRealPqSupported\(\)Z'  'real PQ probe'
    verify_marker 'RenderTargetConfig.smali' '*/tiledmedia/*' 'uhdRealHlgSupported'                      'runtime HLG/PQ reroute'
    if [[ -n "${TMVM_SMALI:-}" ]] && grep -qE 'uhdSurfaceHlgRenderable|getIsBt2020HlgExtensionSupported' "${TMVM_SMALI}"; then
        verify_marker 'TMViewModel.smali'    '*/tiledmedia/*' 'uhdSurfaceHlgRenderable'                  'surface HDR capability report'
    fi
fi
if [[ "${F1TV_DISPLAY_HDR_SPOOF:-1}" != "0" ]]; then
    if f="$(find "${DECOMPILED}" -name 'DeviceParameters.smali' -path '*/tiledmedia/*' -print -quit)"; then
        if awk '/doesDisplaySupport\(Landroid\/content\/Context;I\)Z/,/\.end method/' "${f}" | grep 'const/4 v0, 0x1' >/dev/null; then ok "  display HDR spoof"; else warn "  NOT APPLIED: display HDR spoof"; VERIFY_FAILED=1; fi
    fi
fi
# The removed model spoof must stay removed: Build.MODEL must still be read in getRequestHeader.
if f="$(find "${DECOMPILED}" -name 'TvApplication.smali' -path '*/avs/f1/*' -print -quit)"; then
    if awk '/\.method public getRequestHeader/,/\.end method/' "${f}" | grep 'Landroid/os/Build;->MODEL' >/dev/null; then ok "  request header untouched (real model)"; else warn "  UNEXPECTED: getRequestHeader no longer reads Build.MODEL"; VERIFY_FAILED=1; fi
fi
[[ "${VERIFY_FAILED}" == "0" ]] || die "Patch verification failed — refusing to build a half-patched bundle"
ok "All patches verified"

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
