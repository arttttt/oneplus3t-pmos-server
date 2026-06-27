# OnePlus 3T → postmarketOS headless server

Turning a OnePlus 3T (`oneplus-oneplus3t`, msm8996 / Snapdragon 821, 6 GB RAM)
into a 24/7 headless Linux server.

> Images and binaries are **not** committed (see `.gitignore`) — they are large,
> device-specific, and rebuildable. This repo holds the **scripts, configs and
> docs** only.

## Layout

| Path | What |
|------|------|
| `bin/op3t.sh` | Host-side **menu** to manage the device. Auto-discovers it (scans the Mac's own subnets, identifies the phone by its SSH host key, self-heals after a reinstall) over USB-net / WiFi; one multiplexed SSH session. Status, battery target, WiFi connect, terminal, reboot/poweroff. |
| `build/install.sh` | End-to-end pipeline (Docker + pmbootstrap): `build` / `combine` / `flash` / `all`. Encodes the device quirks (kernel 6.12.10, 4Kn `--sector-size 4096`, PCIe cmdline) and a **verified flash** — sha256 of upload + read-back, detached write that survives USB drops, backup-GPT relocation, and an empty-image guard. |
| `build/Dockerfile.pmbootstrap` | Self-contained pmbootstrap build env (Alpine). Its entrypoint mounts a **devtmpfs over `/dev`** so `losetup -P` exposes the loop partitions — without it pmbootstrap writes a partition table but no filesystems (an empty image). |
| `build/bump-kernel.sh` | Bumps the msm8996-mainline kernel aport to 6.12.10 (adds `python3` to makedepends + `make olddefconfig`) and builds it. |
| `device/` | On-device helpers, installed into the rootfs: `op3t-power` (display/charge CLI), `op3t-battery-guard` (smart SoC-hold service) + its systemd unit / `/etc/default` / doas rule. |
| `docs/SETUP.md` | Manual post-install steps: password, WiFi, Tailscale, service deploy. |

## Prerequisites

- macOS (Apple Silicon) + Docker Desktop.
- `lk2nd-msm8996.img` in `firmware/lk2nd/` (bootloader; from lk2nd releases).
- Device unlocked, TWRP in recovery (used for flashing — stock `fastboot flash
  userdata` is a no-op on this device; `system`/`boot` flash fine via fastboot).

## Quickstart

```sh
./build/install.sh build      # build pmOS image in Docker (kernel + rootfs)
./build/install.sh combine    # lk2nd + pmOS boot → combined.img
./build/install.sh flash      # flash from TWRP (adb)
bin/op3t.sh                   # manage the running device
```

## Status / notes

- Boots: pmOS, kernel **6.12.10-msm8996** (msm8996-mainline fork). Console UI, systemd.
- Display, USB-net, charging, battery management: working.
- **WiFi + Bluetooth (QCA6174a): WORKING.** Required two things: kernel **6.12.10**
  (6.3.1 has the bug, 6.19.5 doesn't boot) **and** kernel cmdline
  **`pcie_aspm=off pci=nomsi`** — mainline's PCIe ASPM/L1ss handling
  otherwise blocks the QCA6174 link training (`Phy link never came up`).
  Both are baked into `build/install.sh`.
