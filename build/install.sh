#!/usr/bin/env bash
# =============================================================================
# OnePlus 3T (oneplus-oneplus3t, msm8996) -> postmarketOS headless server
# End-to-end build + flash pipeline. Verified working 2026-06-27.
#
# Encodes the device-specific quirks that make it boot and get WiFi:
#   - KERNEL: 6.12.10 (6.3.1 boots but has no WiFi; 6.19.5 hangs pre-initramfs).
#   - SECTORS: build the image with 4096-byte sectors (--sector-size 4096) —
#     userdata is 4Kn UFS; a 512-sector GPT is unreadable by the initramfs kpartx.
#   - FLASH: stock `fastboot flash userdata` is a NO-OP here; flash the rootfs
#     from TWRP via adb + simg2img onto userdata, and boot (lk2nd + pmOS) via dd.
#   - WiFi: the QCA6174 PCIe link won't train under mainline ASPM/L1ss — add
#     pcie_aspm=off pci=nomsi to the kernel cmdline.
#
# Host: macOS (Apple Silicon) + Docker Desktop. pmbootstrap runs in a
# privileged Linux container (it cannot run natively on macOS).
#
# Usage:
#   ./install.sh build     # build images in Docker (no device needed)
#   ./install.sh combine   # build the combined lk2nd+boot image (no device)
#   ./install.sh flash     # flash from TWRP (device must be in TWRP recovery + adb)
#   ./install.sh all       # build + combine  (then run `flash` once in TWRP)
# =============================================================================
set -euo pipefail

# ---- config -----------------------------------------------------------------
PROJ="/Users/artem/Projects/OnePlus3t"
PMOS_DIR="$PROJ/pmos"
LK2ND="$PROJ/firmware/lk2nd/lk2nd-msm8996.img"
DOCKERFILE="$PROJ/build/Dockerfile.pmbootstrap"

IMAGE="pmos-build"             # docker image name
CONTAINER="pmos"              # docker container name
VOLUME="pmbootstrap-work"     # persistent pmbootstrap work dir (native ext4)
WORK="/home/build/pmos-work"  # work dir inside container (the volume)

CHANNEL="v25.12"              # base channel; bump_kernel then sets KERNELVER
VENDOR="oneplus"
CODENAME="oneplus3t"
DEVICE="oneplus-oneplus3t"
KERNEL="s6e3fa5"             # display panel variant (this unit; verify via lk2nd:panel)
UI="console"                 # 'console' for bring-up; 'none' for production
HOSTNAME="op3t"
PASSWORD="changeme"          # CHANGE after first boot via `passwd`
SECTOR=4096                  # userdata is 4Kn UFS
KERNELVER="6.12.10"          # msm8996-mainline fork tag: 6.3.1=no WiFi, 6.19.5=hangs, 6.12.10=boots+WiFi
CMDLINE_EXTRA="pcie_aspm=off pci=nomsi"  # ASPM/L1ss blocks QCA6174 PCIe link -> WiFi/BT

CHROOT_ROOTFS="$WORK/chroot_rootfs_${DEVICE}"
CHROOT_NATIVE="$WORK/chroot_native"
ROOTFS_SPARSE="$CHROOT_NATIVE/home/pmos/rootfs/${DEVICE}.img"   # Android sparse, 4K GPT inside
BOOT_IMG_SRC="$CHROOT_ROOTFS/boot/boot.img"                     # fastboot bootimg (kernel+initramfs)

log(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
dx(){ docker exec -u build -w /home/build "$CONTAINER" sh -lc "$*"; }     # as build user
dxr(){ docker exec "$CONTAINER" sh -lc "$*"; }                            # as root

# ---- docker env -------------------------------------------------------------
docker_up(){
  docker info >/dev/null 2>&1 && return 0
  log "starting Docker Desktop"; open -a Docker 2>/dev/null || true
  for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && return 0; sleep 3; done
  echo "Docker daemon not available" >&2; exit 1
}

ensure_container(){
  docker_up
  docker image inspect "$IMAGE" >/dev/null 2>&1 || {
    log "building docker image $IMAGE"; docker build -t "$IMAGE" -f "$DOCKERFILE" "$(dirname "$DOCKERFILE")"; }
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    log "starting container $CONTAINER"
    docker run -d --name "$CONTAINER" --privileged \
      -v "$VOLUME:$WORK" -v "$PROJ:/project" "$IMAGE" >/dev/null
    dxr "chown -R build:build /home/build 2>/dev/null || true"
  fi
  # FIX (container): real devtmpfs so loop-partition nodes appear (kpartx/mkfs)
  dxr "mountpoint -q /dev || mount -t devtmpfs devtmpfs /dev 2>/dev/null || true; [ -e /dev/loop-control ] || mount -t devtmpfs devtmpfs /dev 2>/dev/null || true; echo devtmpfs-ok"
}

# ---- kernel version bump (msm8996-mainline fork) ----------------------------
bump_kernel(){
  log "bump kernel aport -> $KERNELVER and build (see build/bump-kernel.sh)"
  dx "sh /project/build/bump-kernel.sh '$KERNELVER'"
}

# stage the local op3t-helpers aport (op3t-power + battery-guard) into pmaports
add_helpers_aport(){
  log "stage op3t-helpers aport + checksum"
  dx "rm -rf $WORK/cache_git/pmaports/temp/op3t-helpers; mkdir -p $WORK/cache_git/pmaports/temp; \
      cp -r /project/build/aports/op3t-helpers $WORK/cache_git/pmaports/temp/ && \
      pmbootstrap checksum op3t-helpers"
}

# ---- build ------------------------------------------------------------------
build_image(){
  ensure_container
  log "pmbootstrap init (channel=$CHANNEL device=$DEVICE kernel=$KERNEL ui=$UI)"
  # init wizard prompt order (v3.10.3, 18 prompts): work, pmaports, channel,
  # vendor, device, kernel/panel, user, audio, wifi, usb, UI, systemd, change?,
  # extra, locale, hostname, build-outdated?, zap?. Invalid answers re-prompt &
  # shift, so we also force the critical keys via `config` afterwards.
  dx "printf '%s\n\n%s\n%s\n%s\n%s\n\n\n\n\n%s\n\n\n\n\n%s\n\n\n\n\n' \
        '$WORK' '$CHANNEL' '$VENDOR' '$CODENAME' '$KERNEL' '$UI' '$HOSTNAME' \
        | pmbootstrap init --shallow-initial-clone 2>&1 | tail -3 || true"
  dx "pmbootstrap config device $DEVICE; pmbootstrap config kernel $KERNEL; \
      pmbootstrap config ui $UI; pmbootstrap config hostname $HOSTNAME"
  dx "echo 'pmaports branch:'; git -C $WORK/cache_git/pmaports branch --show-current"
  dx "pmbootstrap config | grep -iE 'device|kernel|^ui|hostname|is_default'"

  bump_kernel
  add_helpers_aport

  log "pmbootstrap install (--no-split --sector-size $SECTOR + op3t-helpers)"
  dx "pmbootstrap -y install --no-split --sector-size $SECTOR --password '$PASSWORD' --add op3t-helpers 2>&1 | tail -6"
  dx "pmbootstrap shutdown 2>&1 | tail -1 || true"

  log "export images -> $PMOS_DIR"
  mkdir -p "$PMOS_DIR"
  dxr "cp '$BOOT_IMG_SRC' /project/pmos/boot.img && cp '$ROOTFS_SPARSE' /project/pmos/rootfs.img"
  dx "echo 'installed kernel:'; awk '/^P:linux-postmarketos-qcom-msm8996/{p=1} p&&/^V:/{print;p=0}' $CHROOT_ROOTFS/lib/apk/db/installed"
  ls -lh "$PMOS_DIR/boot.img" "$PMOS_DIR/rootfs.img"
}

# ---- bake the PCIe cmdline workaround into boot.img -------------------------
# pmbootstrap ignores deviceinfo_kernel_cmdline here, so patch the Android boot
# header cmdline field (offset 64, 512 B) directly. UUID/kernel untouched.
patch_cmdline(){
  [ -n "$CMDLINE_EXTRA" ] || return 0
  log "patch boot.img cmdline += '$CMDLINE_EXTRA'"
  python3 - "$PMOS_DIR/boot.img" "$CMDLINE_EXTRA" <<'PY'
import sys
f, extra = sys.argv[1], sys.argv[2]
d = bytearray(open(f, "rb").read())
assert d[:8] == b"ANDROID!", "not an Android boot image"
cmd = d[64:64+512].split(b"\x00", 1)[0].decode("latin1")
if extra in cmd:
    print("cmdline already has it:", cmd); sys.exit(0)
new = (cmd + " " + extra).encode("latin1")
assert len(new) < 512, "cmdline too long for boot hdr field"
d[64:64+512] = new + b"\x00" * (512 - len(new))
open(f, "wb").write(d)
print("new cmdline:", new.decode())
PY
}

# ---- combined boot (lk2nd@0 + pmOS boot@512K), flashed raw to `boot` ---------
combine(){
  [ -f "$PMOS_DIR/boot.img" ] || { echo "run 'build' first" >&2; exit 1; }
  patch_cmdline
  log "build combined.img = lk2nd (padded 512K) + boot.img"
  dd if="$LK2ND" of="$PMOS_DIR/combined.img" bs=512k conv=sync 2>/dev/null
  cat "$PMOS_DIR/boot.img" >> "$PMOS_DIR/combined.img"
  # sanity: pmOS boot magic at the 512K offset
  if [ "$(dd if="$PMOS_DIR/combined.img" bs=1 skip=524288 count=8 2>/dev/null)" = "ANDROID!" ]; then
    echo "ok: ANDROID! @524288"; else echo "WARN: missing magic @524288" >&2; fi
  ls -lh "$PMOS_DIR/combined.img"
}

# ---- flash from TWRP (stock fastboot userdata is a no-op here) ---------------
# Device must be booted into TWRP recovery with `adb devices` showing 'recovery'.
flash(){
  [ -f "$PMOS_DIR/rootfs.img" ] && [ -f "$PMOS_DIR/combined.img" ] || {
    echo "missing images; run 'build' and 'combine' first" >&2; exit 1; }
  adb devices | grep -q recovery || { echo "Boot the device into TWRP (adb 'recovery') first" >&2; exit 1; }

  log "flash rootfs -> userdata (adb push + simg2img, raw onto block device)"
  adb push "$PMOS_DIR/rootfs.img" /tmp/r.simg
  adb shell 'simg2img /tmp/r.simg /dev/block/bootdevice/by-name/userdata; sync; rm -f /tmp/r.simg
             echo "userdata @4096:"; dd if=/dev/block/bootdevice/by-name/userdata bs=1 skip=4096 count=8 2>/dev/null | od -An -c'

  log "flash combined -> boot (dd; TWRP toybox: no conv=, no bs=4M)"
  adb push "$PMOS_DIR/combined.img" /tmp/b.img
  adb shell 'dd if=/tmp/b.img of=/dev/block/bootdevice/by-name/boot bs=1048576; sync; rm -f /tmp/b.img
             echo "boot @0:";      dd if=/dev/block/bootdevice/by-name/boot bs=1 count=8 2>/dev/null | od -An -c
             echo "boot @524288:"; dd if=/dev/block/bootdevice/by-name/boot bs=1 skip=524288 count=8 2>/dev/null | od -An -c'

  log "reboot to system"; adb reboot
  echo "After ~40s: ssh user@172.16.42.1 (password: $PASSWORD)  — then change it."
}

case "${1:-all}" in
  build)   build_image ;;
  combine) combine ;;
  flash)   flash ;;
  all)     build_image; combine; echo; echo "Now boot the device into TWRP and run: $0 flash" ;;
  *) echo "usage: $0 {build|combine|flash|all}" >&2; exit 1 ;;
esac
