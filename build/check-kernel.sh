#!/usr/bin/env bash
# =============================================================================
# Gate: does this boot.img match the known-good kernel?
#
# Exists because of a real failure: the repo carried a config generated for
# kernel 7.2-rc1 while we build 6.12.95. `make olddefconfig` silently dropped
# the ~450 symbols that don't exist in 6.12 and filled in defaults for the
# rest, which among other things lost CONFIG_LOCALVERSION="-msm8996". The
# resulting kernel called itself 6.12.95 instead of 6.12.95-msm8996, so it
# looked for modules in /lib/modules/6.12.95 — a directory that does not
# exist on the device — and came up with ZERO modules: no USB gadget, no
# WiFi, no SSH. On every probe that looked exactly like a hang, and five
# consecutive "cpuidle" experiments were misattributed to PSCI, StateIDs,
# bit30 and the GIC before anyone compared the artifact to the working one.
#
# So: never interpret device behaviour before this passes.
#
# Usage:  ./build/check-kernel.sh <boot.img> [expected-config]
# Exit:   0 = matches the reference, non-zero = do NOT test this on device
# =============================================================================
set -uo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOLDEN="$PROJ/build/golden-kernel.json"
IMG="${1:?usage: check-kernel.sh <boot.img> [config]}"
CFG="${2:-$PROJ/build/aports/linux-op3t/config-op3t.aarch64}"

RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; OFF=$'\033[0m'
fail=0
ok()   { printf '  %sOK%s    %s\n'   "$GRN" "$OFF" "$*"; }
bad()  { printf '  %sFAIL%s  %s\n'   "$RED" "$OFF" "$*"; fail=1; }
warn() { printf '  %sWARN%s  %s\n'   "$YEL" "$OFF" "$*"; }

[ -f "$GOLDEN" ] || { echo "no reference: $GOLDEN"; exit 2; }
[ -f "$IMG" ]    || { echo "no image: $IMG"; exit 2; }

echo "== checking $(basename "$IMG") against the known-good kernel =="

# --- 1. the artifact itself: release string and section sizes ---------------
eval "$(python3 - "$IMG" "$GOLDEN" <<'PY'
import struct, zlib, re, sys, json
img, golden = sys.argv[1], sys.argv[2]
d = open(img, 'rb').read()
if d[:8] != b'ANDROID!':
    print("ERR='not an android boot image'"); raise SystemExit
ks, = struct.unpack('<I', d[8:12])
rs, = struct.unpack('<I', d[16:20])
pg, = struct.unpack('<I', d[36:40])
try:
    raw = zlib.decompressobj(31).decompress(d[pg:pg+ks])
    m = re.search(rb'Linux version ([^\s]+)', raw)
    rel = m.group(1).decode() if m else '?'
except Exception as e:
    rel = '?'
g = json.load(open(golden))
print(f"REL={rel!r}; KS={ks}; RS={rs}")
print(f"G_REL={g['kernel_release']!r}; G_KS={g['kernel_size']}; G_RS={g['ramdisk_size']}")
PY
)"

if [ -n "${ERR:-}" ]; then bad "$ERR"; exit 1; fi

# The release string is the load-bearing check: it is what the module path is
# derived from, so a mismatch here means the kernel will find no modules.
if [ "$REL" = "$G_REL" ]; then
	ok "kernel release: $REL"
else
	bad "kernel release: got '$REL', expected '$G_REL'"
	bad "  => modules live in /lib/modules/$G_REL; this kernel would look in /lib/modules/$REL and find nothing"
	bad "  => usual cause: CONFIG_LOCALVERSION lost, i.e. the wrong config was used"
fi

# initramfs carries the modules, so a big shrink means modules went missing
rs_delta=$(( (RS - G_RS) * 100 / G_RS ))
if [ "${rs_delta#-}" -le 5 ]; then
	ok "initramfs size: $RS (reference $G_RS, ${rs_delta}%)"
else
	bad "initramfs size: $RS vs reference $G_RS (${rs_delta}%) — modules likely missing"
fi

# kernel size moves legitimately with config, so this is advisory only
ks_delta=$(( (KS - G_KS) * 100 / G_KS ))
if [ "${ks_delta#-}" -le 10 ]; then
	ok "kernel size: $KS (reference $G_KS, ${ks_delta}%)"
else
	warn "kernel size: $KS vs reference $G_KS (${ks_delta}%) — expected if you changed the config a lot"
fi

# --- 2. the config that produced it -----------------------------------------
if [ -f "$CFG" ]; then
	lv=$(grep -E '^CONFIG_LOCALVERSION=' "$CFG" | head -1 | cut -d= -f2-)
	if [ "$lv" = '"-msm8996"' ]; then
		ok "config LOCALVERSION: $lv"
	else
		bad "config LOCALVERSION: $lv (must be \"-msm8996\")"
	fi

	# Symbols that only exist in far newer kernels are the fingerprint of the
	# 7.2-rc1 config that caused this whole mess.
	strays=$(grep -cE '^# CONFIG_(AD3530R|AD4030|AD4080|ADE9000|ALIBABA_EEA|AIR_AN8801_PHY) ' "$CFG" 2>/dev/null || true)
	if [ "${strays:-0}" -eq 0 ]; then
		ok "config vintage: no symbols from newer kernels"
	else
		bad "config vintage: $strays symbols that don't exist in 6.12 — this config is from a newer kernel"
	fi
else
	warn "config not found at $CFG — skipped config checks"
fi

echo
if [ "$fail" -eq 0 ]; then
	printf '%sPASS%s — artifact matches the reference; safe to test on device\n' "$GRN" "$OFF"
else
	printf '%sSTOP%s — do NOT test this on device and do NOT interpret its behaviour.\n' "$RED" "$OFF"
	printf '       Fix the build first, otherwise the result means nothing.\n'
fi
exit "$fail"
