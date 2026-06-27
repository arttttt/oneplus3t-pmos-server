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
  # The image's entrypoint mounts a devtmpfs over /dev (needed so pmbootstrap's
  # `losetup -P` creates loopNp1 nodes during install). Verify it took — without
  # it, install silently produces an EMPTY image.
  if ! dxr "mount | grep -q 'devtmpfs on /dev '"; then
    echo "ERROR: /dev is not devtmpfs in the container (entrypoint failed?)." >&2
    echo "Rebuild the image: docker rm -f $CONTAINER; docker rmi $IMAGE; then re-run." >&2
    exit 1
  fi
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
  # `set -o pipefail` inside the inner sh so a pmbootstrap failure isn't masked by
  # the `| tail` (the outer pipefail does NOT apply inside `docker exec sh -lc`).
  dx "set -o pipefail; pmbootstrap -y install --no-split --sector-size $SECTOR --password '$PASSWORD' --add op3t-helpers 2>&1 | tail -12"
  dx "pmbootstrap shutdown 2>&1 | tail -1 || true"

  log "export images -> $PMOS_DIR"
  mkdir -p "$PMOS_DIR"
  dxr "cp '$BOOT_IMG_SRC' /project/pmos/boot.img && cp '$ROOTFS_SPARSE' /project/pmos/rootfs.img"
  dx "echo 'installed kernel:'; awk '/^P:linux-postmarketos-qcom-msm8996/{p=1} p&&/^V:/{print;p=0}' $CHROOT_ROOTFS/lib/apk/db/installed"
  ls -lh "$PMOS_DIR/boot.img" "$PMOS_DIR/rootfs.img"

  # Sanity: the rootfs image MUST contain real filesystems. If install couldn't
  # create the loop-partition nodes it writes only a GPT (all zeros) and pmOS
  # boots to the initramfs "failed to mount subpartitions" debug shell. Catch
  # that empty image here instead of flashing a brick.
  log "verify rootfs image is populated (not an empty GPT shell)"
  if ! LC_ALL=C grep -qa -m1 -E 'postmarketos|alpine-baselayout|/bin/busybox' "$PMOS_DIR/rootfs.img"; then
    echo "ERROR: built rootfs.img has NO filesystem content — pmbootstrap install did not" >&2
    echo "populate the subpartitions (loop-partition/devtmpfs issue in the container)." >&2
    echo "Do NOT flash this image. Rebuild the container image and retry." >&2
    exit 1
  fi
  echo "ok: rootfs.img contains a real filesystem"
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
# Device must be in TWRP recovery (`adb devices` shows 'recovery'). This is hard
# in three ways, all handled here:
#   1. FORMAT: pmbootstrap's image here is a RAW 4Kn GPT image (no Android-sparse
#      wrapper), so it must be dd'd, not simg2img'd. We auto-detect on-device by
#      the sparse magic, so either format works.
#   2. USB DROPS: adbd/USB drops under the multi-GB userdata write. So the write
#      runs DETACHED on the device and we poll, reconnecting adb as needed.
#   3. INTEGRITY: a push can corrupt while still reporting the right byte count,
#      so we verify the upload AND the written bytes by sha256 (read-back).
adb_recover(){ local n; for n in $(seq 1 15); do
  adb devices 2>/dev/null | grep -qw recovery && return 0
  adb reconnect >/dev/null 2>&1; adb kill-server >/dev/null 2>&1; adb start-server >/dev/null 2>&1
  sleep 2; done; return 1; }

flash(){
  # This function does its own explicit error checks (sha verify, rc, exit 1).
  # Disable errexit: the retry/poll control flow uses `test && action`, which
  # returns 1 when the test is false and would otherwise abort under `set -e`.
  set +e
  [ -f "$PMOS_DIR/rootfs.img" ] && [ -f "$PMOS_DIR/combined.img" ] || {
    echo "missing images; run 'build' and 'combine' first" >&2; exit 1; }
  command -v adb >/dev/null 2>&1 || { echo "adb not found" >&2; exit 1; }
  adb_recover || { echo "Boot the device into TWRP recovery (adb shows 'recovery') first" >&2; exit 1; }

  local R="$PMOS_DIR/rootfs.img" C="$PMOS_DIR/combined.img" rsha csha rbytes rblocks
  rsha=$(shasum -a 256 "$R" | awk '{print $1}')
  csha=$(shasum -a 256 "$C" | awk '{print $1}')
  rbytes=$(wc -c < "$R" | tr -d ' '); rblocks=$(( (rbytes + 1048575) / 1048576 ))

  # on-device writer: detect raw vs sparse, write, read-back-hash the image region
  local UD; UD="$(mktemp -t op3t_ud.XXXXXX)"
  cat > "$UD" <<'UDEOF'
#!/sbin/sh
B="$1"; D=/dev/block/bootdevice/by-name/userdata
rm -f /tmp/ud.done /tmp/ud.err /tmp/ud.fmt /tmp/ud.hash
umount /data 2>/dev/null; umount "$D" 2>/dev/null
magic=$(dd if=/tmp/r.img bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' ')
if [ "$magic" = "ed26ff3a" ]; then
  echo sparse > /tmp/ud.fmt; simg2img /tmp/r.img "$D" 2>/tmp/ud.err; rc=$?
else
  echo raw > /tmp/ud.fmt; dd if=/tmp/r.img of="$D" bs=1048576 2>/tmp/ud.err; rc=$?
fi
sync
n=$(wc -c < /tmp/r.img)
dd if="$D" bs=1048576 count="$B" 2>/dev/null | head -c "$n" | sha256sum | awk '{print $1}' > /tmp/ud.hash
echo "rc=$rc" > /tmp/ud.done
UDEOF

  log "stage rootfs -> /tmp/r.img, verify sha256 (a push can corrupt at full byte count)"
  local ok=0 try dh h
  for try in 1 2 3; do
    adb_recover; adb push "$R" /tmp/r.img >/dev/null 2>&1 || true
    dh=""; for h in 1 2 3; do adb_recover >/dev/null 2>&1
      dh=$(adb shell 'sha256sum /tmp/r.img 2>/dev/null' 2>/dev/null | awk '{print $1}' | tr -d '\r')
      [ -n "$dh" ] && break; sleep 2; done
    echo "  upload try$try: $dh"
    [ "$dh" = "$rsha" ] && { ok=1; break; }
    echo "  mismatch (want $rsha) -> re-push"
  done
  [ "$ok" = 1 ] || { rm -f "$UD"; echo "ABORT: rootfs not staged intact" >&2; exit 1; }

  log "write userdata DETACHED (survives USB drops) + read-back verify"
  adb_recover; adb push "$UD" /tmp/flash_ud.sh >/dev/null 2>&1; rm -f "$UD"
  adb shell "rm -f /tmp/ud.done; nohup sh /tmp/flash_ud.sh $rblocks >/dev/null 2>&1 & echo launched"
  local res="" i d
  for i in $(seq 1 180); do
    adb_recover >/dev/null 2>&1
    d=$(adb shell 'cat /tmp/ud.done 2>/dev/null' 2>/dev/null | tr -d '\r\n ')
    [ -n "$d" ] && { res="$d"; break; }
    [ $(( i % 6 )) -eq 0 ] && echo "  …writing (${i}x5s elapsed)"
    sleep 5
  done
  [ "$res" = "rc=0" ] || { echo "USERDATA WRITE FAILED ($res):" >&2; adb shell 'cat /tmp/ud.err 2>/dev/null' >&2; exit 1; }
  local fmt wsha; fmt=$(adb shell 'cat /tmp/ud.fmt 2>/dev/null' 2>/dev/null | tr -d '\r\n ')
  wsha=$(adb shell 'cat /tmp/ud.hash 2>/dev/null' 2>/dev/null | tr -d '\r\n ')
  if [ "$fmt" = raw ]; then
    [ "$wsha" = "$rsha" ] || { echo "VERIFY FAILED: userdata sha $wsha != image $rsha" >&2; exit 1; }
    echo "  ✓ userdata byte-identical to rootfs.img"
  else
    echo -n "  (sparse) userdata GPT @4096: "; adb shell 'dd if=/dev/block/bootdevice/by-name/userdata bs=1 skip=4096 count=8 2>/dev/null | od -An -c'
  fi

  log "flash combined -> boot (verify upload sha + boot magics)"
  adb_recover; adb push "$C" /tmp/b.img >/dev/null 2>&1
  local bdh; bdh=$(adb shell 'sha256sum /tmp/b.img 2>/dev/null' 2>/dev/null | awk '{print $1}' | tr -d '\r')
  [ "$bdh" = "$csha" ] || { echo "combined upload sha mismatch ($bdh != $csha)" >&2; exit 1; }
  adb shell 'dd if=/tmp/b.img of=/dev/block/bootdevice/by-name/boot bs=1048576; sync'
  echo -n "  boot @0:      "; adb shell 'dd if=/dev/block/bootdevice/by-name/boot bs=1 count=8 2>/dev/null | od -An -c'
  echo -n "  boot @524288: "; adb shell 'dd if=/dev/block/bootdevice/by-name/boot bs=1 skip=524288 count=8 2>/dev/null | od -An -c'

  log "cleanup staged files + reboot"
  adb shell 'rm -f /tmp/r.img /tmp/b.img /tmp/flash_ud.sh /tmp/ud.done /tmp/ud.err /tmp/ud.fmt /tmp/ud.hash; sync'
  adb reboot
  echo "Flashed + verified. After ~40s the new system boots; reach it with bin/op3t.sh (password: $PASSWORD)."
}

case "${1:-all}" in
  build)   build_image ;;
  combine) combine ;;
  flash)   flash ;;
  all)     build_image; combine; echo; echo "Now boot the device into TWRP and run: $0 flash" ;;
  *) echo "usage: $0 {build|combine|flash|all}" >&2; exit 1 ;;
esac
