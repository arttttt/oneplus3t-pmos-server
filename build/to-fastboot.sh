#!/usr/bin/env bash
# =============================================================================
# Get the device into fastboot, whatever state it is in right now.
#
# A test cycle leaves the phone in one of several states and each needs a
# different route, which is easy to get wrong by hand:
#
#   already in fastboot -> nothing to do
#   full system (ssh)   -> set the systemd reboot parameter, reboot
#   initramfs (telnet)  -> no systemd there, so reboot into the flashed system
#                          first, then take the ssh route
#   dead                -> only a human can revive it
#
# Assuming "ssh is up" and reaching for the ssh route regardless is how a cycle
# silently stalls: the reboot never happens and the wait for fastboot times out
# looking like a hang.
#
# Usage:  ./build/to-fastboot.sh
# Exit:   0 = in fastboot, 1 = could not get there (device needs a hand)
# =============================================================================
set -uo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IP="172.16.42.1"

in_fastboot() { fastboot devices 2>/dev/null | grep -q fastboot; }
have_ssh()    { nc -z -G2 "$IP" 22 >/dev/null 2>&1; }
have_telnet() { nc -z -G2 "$IP" 23 >/dev/null 2>&1; }

wait_fastboot() {
	local n=0
	# The phone can take well over a minute; a short wait here is what makes
	# a working reboot look like a failed one.
	until in_fastboot || [ $n -ge 60 ]; do n=$((n+1)); sleep 2; done
	in_fastboot
}

wait_ssh() {
	local n=0
	until have_ssh || [ $n -ge 60 ]; do n=$((n+1)); sleep 3; done
	have_ssh
}

if in_fastboot; then
	echo "already in fastboot"
	exit 0
fi

if have_telnet && ! have_ssh; then
	echo "in initramfs — rebooting into the flashed system first"
	"$PROJ/build/telnet-device.sh" 'busybox reboot -f' >/dev/null 2>&1
	sleep 10
	wait_ssh || { echo "system did not come back up"; exit 1; }
fi

if have_ssh; then
	echo "in the full system — rebooting to the bootloader"
	"$PROJ/build/root-cmd.sh" --quiet \
		'echo bootloader > /run/systemd/reboot-param; systemctl reboot' >/dev/null 2>&1
	wait_fastboot && { echo "in fastboot"; exit 0; }
	echo "reboot did not reach fastboot"
	exit 1
fi

echo "device is unreachable (no fastboot, no ssh, no telnet) — needs a manual reset"
exit 1
