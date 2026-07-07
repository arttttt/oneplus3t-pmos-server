#!/usr/bin/env bash
# =============================================================================
# OnePlus 3T — LIGHTWEIGHT kernel update (boot.img + modules) over SSH.
#
# Updates ONLY the kernel: writes the fresh boot.img into the `boot` partition
# (after lk2nd) and drops the matching /lib/modules/<ver> into the running
# rootfs, then reboots. No TWRP, no multi-GB userdata rewrite — seconds, not
# minutes. Use this for kernel iteration (e.g. baseline <-> a power patch) once
# a full system is already flashed (see install.sh for the one-time full flash).
#
# Prereqs:
#   - device booted into pmOS and reachable at $DEV_IP (USB gadget net), root
#     via pkexec (password $PW)
#   - a fresh build present in the container (run install.sh build, or a manual
#     pmbootstrap build+install; this script reads its boot.img + modules)
#
# Usage:  ./build/install-kernel.sh            # push container's current build
#         ./build/install-kernel.sh <boot.img> # push a specific host boot.img
#                                               # (modules still come from container)
# =============================================================================
set -euo pipefail

PROJ="/Users/artem/Projects/OnePlus3t"
CONTAINER="pmos"
DEVICE="oneplus-oneplus3t"
CHROOT_ROOTFS="/home/build/pmos-work/chroot_rootfs_${DEVICE}"
DEV_IP="172.16.42.1"
SSH_USER="user"
SSH_KEY="$HOME/.ssh/op3t_ed25519"
PW="changeme"
CMDLINE_EXTRA="pcie_aspm=off pci=nomsi"   # QCA6174 PCIe link needs this
BOOT_PART="/dev/disk/by-partlabel/boot"
BOOT_SEEK=128                              # 128 * 4096 = 512K = lk2nd size (keep it)
STAGE="$(mktemp -d -t op3t_kupd.XXXXXX)"
SSHOPTS=(-i "$SSH_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8)

log(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
cleanup(){ rm -rf "$STAGE"; }; trap cleanup EXIT

ssh_dev(){ ssh "${SSHOPTS[@]}" "$SSH_USER@$DEV_IP" "$@"; }
scp_dev(){ scp "${SSHOPTS[@]}" "$1" "$SSH_USER@$DEV_IP:$2"; }

# run a command as root on the device via pkexec (password over expect)
root_dev(){
  expect <<EOF
log_user 0
spawn ssh -tt ${SSHOPTS[*]} $SSH_USER@$DEV_IP pkexec sh -c {$1}
expect { -re "assword:" { send "$PW\r"; exp_continue } eof }
EOF
}

ssh_dev true 2>/dev/null || { echo "device not reachable at $DEV_IP (boot it into pmOS first)" >&2; exit 1; }

# ---- 1. gather fresh boot.img + modules from the container ------------------
log "export boot.img + modules from container build"
if [ $# -ge 1 ]; then cp "$1" "$STAGE/boot.img"; else
  docker exec "$CONTAINER" sh -lc "cat $CHROOT_ROOTFS/boot/boot.img" > "$STAGE/boot.img"
fi
[ -s "$STAGE/boot.img" ] || { echo "no boot.img" >&2; exit 1; }

KVER=$(docker exec "$CONTAINER" sh -lc "ls $CHROOT_ROOTFS/lib/modules | tail -1" | tr -d '\r')
[ -n "$KVER" ] || { echo "no /lib/modules in container rootfs" >&2; exit 1; }
log "kernel version: $KVER — tar its modules"
docker exec "$CONTAINER" sh -lc "tar -C / -czf - lib/modules/$KVER" > "$STAGE/modules.tar.gz"

# banner sanity
python3 - "$STAGE/boot.img" <<'PY'
import sys,struct,zlib,re
d=open(sys.argv[1],'rb').read(); assert d[:8]==b'ANDROID!'
ks,=struct.unpack('<I',d[8:12]); pg,=struct.unpack('<I',d[36:40])
raw=zlib.decompressobj(31).decompress(d[pg:pg+ks]); m=re.search(rb'Linux version [0-9][^\x00]*',raw)
print('  boot banner:', (m.group(0).decode()[:70] if m else '??'))
PY

# ---- 2. patch boot.img cmdline to the RUNNING system's UUIDs ----------------
# The kernel finds its rootfs by pmos_root_uuid; a fresh build has fresh UUIDs,
# so re-point the new boot.img at whatever the live system actually uses.
log "adopt live system's root/boot UUID into the new boot.img cmdline"
LIVE_CMD=$(ssh_dev cat /proc/cmdline)
BUUID=$(printf '%s' "$LIVE_CMD" | grep -oE 'pmos_boot_uuid=[0-9a-f-]+' | cut -d= -f2)
RUUID=$(printf '%s' "$LIVE_CMD" | grep -oE 'pmos_root_uuid=[0-9a-f-]+' | cut -d= -f2)
[ -n "$RUUID" ] && [ -n "$BUUID" ] || { echo "could not read live UUIDs from /proc/cmdline" >&2; exit 1; }
echo "  live boot_uuid=$BUUID root_uuid=$RUUID"
python3 - "$STAGE/boot.img" "$BUUID" "$RUUID" "$CMDLINE_EXTRA" <<'PY'
import sys
f,bu,ru,extra=sys.argv[1:5]
d=bytearray(open(f,'rb').read()); assert d[:8]==b'ANDROID!'
cmd=(f"pmos_boot_uuid={bu} pmos_root_uuid={ru} pmos_rootfsopts=defaults {extra}").encode()
assert len(cmd)<512
d[64:64+512]=cmd+b'\x00'*(512-len(cmd))
open(f,'wb').write(d)
print("  new cmdline:", cmd.decode())
PY

# ---- 3. push + install + reboot --------------------------------------------
log "scp boot.img (`du -h "$STAGE/boot.img" | cut -f1`) + modules (`du -h "$STAGE/modules.tar.gz" | cut -f1`)"
scp_dev "$STAGE/boot.img"      /tmp/k.img
scp_dev "$STAGE/modules.tar.gz" /tmp/k-mods.tar.gz

log "write boot@512K (keep lk2nd), install modules, reboot"
root_dev "set -e; \
  dd if=/tmp/k.img of=$BOOT_PART bs=4096 seek=$BOOT_SEEK conv=fsync; \
  tar -C / -xzf /tmp/k-mods.tar.gz; \
  rm -f /tmp/k.img /tmp/k-mods.tar.gz; sync; \
  ( sleep 1; reboot ) &"
echo
echo "Pushed kernel $KVER. Device is rebooting; reach it at $DEV_IP in ~40s."
