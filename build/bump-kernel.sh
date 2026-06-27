#!/bin/sh
# Bump the msm8996-mainline kernel aport to a given fork version and build it.
# Run INSIDE the pmbootstrap container as the build user.
#   sh bump-kernel.sh 6.12.10
# The aport (linux-postmarketos-qcom-msm8996) is patch-free, so a version bump is
# just: pkgver + re-checksum + adapt the static .config to the new version
# (new Kconfig symbols default via `make olddefconfig`).
set -e
VER="${1:?usage: bump-kernel.sh <version, e.g. 6.12.10>}"
AK=$(find "$HOME"/pmos-work/cache_git/pmaports -name APKBUILD \
        -path '*linux-postmarketos-qcom-msm8996*' | head -1)
[ -n "$AK" ] || { echo "kernel APKBUILD not found"; exit 1; }

sed -i "s/^pkgver=.*/pkgver=$VER/" "$AK"

# Kernel 6.12 generates the DRM/MSM register headers at build time with a
# python3 script (drivers/gpu/drm/msm/registers/gen_header.py). The stock aport
# makedepends has no python3, so the build dies with "python3: not found"
# (Error 127) at GENHDR a2xx.xml.h. Add it (stdlib-only script -> python3 alone).
grep -q 'python3' "$AK" || \
  sed -i 's/^\(makedepends="[^"]*\)"/\1 python3"/' "$AK"

# Ensure prepare() migrates the config for the new kernel (idempotent).
if ! grep -q 'olddefconfig' "$AK"; then
  awk '1; /\.config$/ && !d {print "\tmake ARCH=\"$_carch\" olddefconfig"; d=1}' \
      "$AK" > "$AK.tmp" && mv "$AK.tmp" "$AK"
fi

pmbootstrap checksum linux-postmarketos-qcom-msm8996
pmbootstrap build --force linux-postmarketos-qcom-msm8996
echo "kernel $VER built."
