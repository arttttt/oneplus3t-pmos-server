# OnePlus 3T → postmarketOS headless server

Turning a OnePlus 3T (`oneplus-oneplus3t`, msm8996 / Snapdragon 821, 6 GB RAM)
into a 24/7 headless Linux server.

> Images and binaries are **not** committed (see `.gitignore`) — they are large,
> device-specific, and rebuildable. This repo holds the **scripts, configs and
> docs** only.

## Layout

| Path | What |
|------|------|
| `bin/op3t.sh` | Host-side **menu** to manage the device over USB-net / WiFi (one SSH session, multiplexed). Status, battery target, display, terminal, reboot. |
| `build/install.sh` | End-to-end build+flash pipeline (Docker + pmbootstrap). Encodes the 3 fixes: kernel channel, `--sector-size 4096`, TWRP flashing. |
| `build/Dockerfile.pmbootstrap` | Linux build env for pmbootstrap on macOS. |
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
  **`pcie_aspm=off pci=nomsi`** (FIX 4) — mainline's PCIe ASPM/L1ss handling
  otherwise blocks the QCA6174 link training (`Phy link never came up`).
  Both are baked into `build/install.sh`.
