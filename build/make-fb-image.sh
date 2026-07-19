#!/usr/bin/env bash
# =============================================================================
# Turn a built boot.img into one we can `fastboot boot`, with the cmdline the
# live system actually uses — and with the initramfs debug shell ON by default.
#
# Debug shell is the default on purpose. A test image without it, when it fails
# to come up, tells you exactly one thing: "no ports". You cannot see why, so
# the cycle is wasted — and every cycle costs a manual reset of the phone. With
# pmos.debug-shell you get telnet on 23 and can read dmesg, the real cmdline,
# block devices and mounts. There is no case during debugging where the plain
# variant is worth booting.
#
# Pass --no-debug only for a final confirmation run, once the thing already
# works and you want to see it boot exactly as it will when flashed.
#
# Usage:
#   ./build/make-fb-image.sh pmos/boot-golden.img            -> ...-fb.img (debug on)
#   ./build/make-fb-image.sh pmos/boot-golden.img --no-debug
#   ./build/make-fb-image.sh in.img --out pmos/custom.img --extra 'cpuidle.off=1'
# =============================================================================
set -uo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC=""; OUT=""; EXTRA=""; DEBUG=1
while [ $# -gt 0 ]; do
	case "$1" in
		--no-debug) DEBUG=0; shift ;;
		--out)      OUT="$2"; shift 2 ;;
		--extra)    EXTRA="$2"; shift 2 ;;
		*)          SRC="$1"; shift ;;
	esac
done
[ -n "$SRC" ] || { echo "usage: make-fb-image.sh <boot.img> [--no-debug] [--out f] [--extra 'args']"; exit 2; }
[ -f "$SRC" ] || { echo "no such image: $SRC"; exit 2; }
[ -n "$OUT" ] || OUT="${SRC%.img}-fb.img"

# UUIDs of the flashed system: the kernel finds its rootfs by these, so they
# must match the installed system, not the one we just built.
BOOT_UUID="1beb8264-6150-4aa2-a94b-4fa8d57fcc8e"
ROOT_UUID="55052c95-9e45-423d-8f85-a5e929195f35"
CMD="pmos_boot_uuid=$BOOT_UUID pmos_root_uuid=$ROOT_UUID pmos_rootfsopts=defaults pcie_aspm=off pci=nomsi"
[ "$DEBUG" = 1 ] && CMD="$CMD pmos.debug-shell"
[ -n "$EXTRA" ] && CMD="$CMD $EXTRA"

python3 - "$SRC" "$OUT" "$CMD" <<'PY'
import sys
src, out, cmd = sys.argv[1], sys.argv[2], sys.argv[3].encode()
d = bytearray(open(src, 'rb').read())
assert d[:8] == b'ANDROID!', 'not an android boot image'
assert len(cmd) < 512, f'cmdline too long: {len(cmd)}'
d[64:64+512] = cmd + b'\x00' * (512 - len(cmd))
open(out, 'wb').write(d)
print(f"wrote {out}")
print(f"cmdline: {cmd.decode()}")
PY

echo
if [ "$DEBUG" = 1 ]; then
	echo "debug shell ON — if it stalls, get in with:  ./build/telnet-device.sh"
else
	echo "debug shell OFF — if it stalls you will learn nothing. Use this only for a final run."
fi
echo "gate it before booting:  ./build/check-kernel.sh $OUT"
