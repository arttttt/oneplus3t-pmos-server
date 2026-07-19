#!/usr/bin/env bash
# =============================================================================
# What state is the phone actually in?
#
# Exists because "no SSH" was repeatedly mistaken for "the kernel hung". It is
# not the same thing. pmOS boots in two stages and they answer on DIFFERENT
# ports:
#
#   initramfs   — network is already up (unudhcpd hands out 172.16.42.x, the
#                 device answers ping) but the real system is NOT running, so
#                 there is NO sshd. With pmos.debug-shell on the cmdline it
#                 offers TELNET on port 23 instead.
#   full system — sshd on port 22.
#
# So: ping + port 23  = booted, sitting in initramfs (usually rootfs trouble)
#     ping + port 22  = fully booted
#     ping, no ports  = kernel alive, stalled before any service started
#     no ping at all  = genuinely dead / no USB gadget
#
# Judging a test by port 22 alone silently turns three different outcomes into
# one wrong verdict. Several results in this project were misread that way.
#
# Usage:  ./build/probe-device.sh [ip]        (default 172.16.42.1)
#         ./build/probe-device.sh --wait 120  wait up to N seconds for a verdict
# =============================================================================
set -uo pipefail

IP="172.16.42.1"
WIFI="192.168.10.49"
WAIT=0
while [ $# -gt 0 ]; do
	case "$1" in
		--wait) WAIT="${2:-120}"; shift 2 ;;
		*) IP="$1"; shift ;;
	esac
done

open() { nc -z -G2 "$1" "$2" >/dev/null 2>&1; }
alive() { ping -c1 -t2 "$1" >/dev/null 2>&1; }

verdict() {
	local ip="$1"
	if open "$ip" 22; then echo "FULL"; return; fi
	if open "$ip" 23; then echo "INITRAMFS"; return; fi
	if alive "$ip"; then echo "STALLED"; return; fi
	echo "DEAD"
}

deadline=$(( $(date +%s) + WAIT ))
while :; do
	v=$(verdict "$IP")
	[ "$v" = FULL ] || [ "$v" = INITRAMFS ] && break
	[ "$(date +%s)" -ge "$deadline" ] && break
	sleep 4
done

# also look at WiFi, the full system may only be reachable there
wifi_ssh=no; open "$WIFI" 22 && wifi_ssh=yes

echo "== device probe ($IP) =="
printf '  ping        : %s\n' "$(alive "$IP" && echo yes || echo no)"
printf '  port 22 ssh : %s\n' "$(open "$IP" 22 && echo OPEN || echo closed)"
printf '  port 23 tel : %s\n' "$(open "$IP" 23 && echo OPEN || echo closed)"
printf '  wifi ssh    : %s (%s)\n' "$wifi_ssh" "$WIFI"
printf '  fastboot    : %s\n' "$(fastboot devices 2>/dev/null | tr -d '\n' | sed 's/^$/none/')"
echo

case "$v" in
	FULL)
		echo "VERDICT: FULL SYSTEM — booted all the way, sshd is up."
		;;
	INITRAMFS)
		echo "VERDICT: INITRAMFS — the kernel booted fine and network is up, but the"
		echo "         real system never started. This is NOT a kernel hang."
		echo "         Get in and look:  telnet $IP"
		echo "         Usual cause: rootfs could not be mounted (wrong UUID in cmdline,"
		echo "         missing driver/module, damaged filesystem)."
		;;
	STALLED)
		echo "VERDICT: STALLED — kernel is alive (it answers ping, so the USB gadget and"
		echo "         network stack came up) but no service is listening."
		echo "         Re-run with pmos.debug-shell on the cmdline to get telnet on 23"
		echo "         and read what the initramfs is doing."
		;;
	DEAD)
		echo "VERDICT: DEAD — no ping, no USB network. Either a real early hang, or the"
		echo "         device is in fastboot/off. Check the fastboot line above."
		;;
esac

[ "$v" = FULL ] && exit 0 || exit 1
