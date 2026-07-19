#!/usr/bin/env bash
# =============================================================================
# Talk to the pmOS initramfs debug shell over telnet, non-interactively.
#
# When a test kernel stops in the initramfs there is no sshd — the only way in
# is telnet on port 23, which pmOS starts when `pmos.debug-shell` is on the
# kernel cmdline. That shell is where the answer usually is: dmesg, whether the
# rootfs partition was even found, which modules loaded.
#
# Without this we were reduced to "port 22 is closed, therefore it hung", which
# is how several working boots got written off as crashes.
#
# Usage:
#   ./build/telnet-device.sh                  # default diagnostic bundle
#   ./build/telnet-device.sh 'dmesg | tail -40'
#   ./build/telnet-device.sh --ip 172.16.42.1 'blkid'
#
# Requires the image to be booted with `pmos.debug-shell` in its cmdline; see
# prepare-dbg-image in the build notes. Exit 2 = port 23 not open.
# =============================================================================
set -uo pipefail

IP="172.16.42.1"
while [ $# -gt 0 ]; do
	case "$1" in
		--ip) IP="$2"; shift 2 ;;
		*) break ;;
	esac
done

# The default bundle answers "why is it still in the initramfs?"
DEFAULT_CMDS='echo "--- uname ---"; uname -a
echo "--- cmdline ---"; cat /proc/cmdline
echo "--- block devices ---"; ls /dev/disk/by-partlabel/ 2>/dev/null; ls /dev/mmcblk* /dev/sd* 2>/dev/null
echo "--- blkid ---"; blkid 2>/dev/null
echo "--- mounts ---"; cat /proc/mounts
echo "--- modules dir ---"; ls /lib/modules/ 2>/dev/null
echo "--- loaded modules ---"; lsmod 2>/dev/null | head -20
echo "--- dmesg tail ---"; dmesg 2>/dev/null | tail -50'

CMDS="${1:-$DEFAULT_CMDS}"
# Tcl's send takes one line: fold any multi-line bundle into a single command.
CMDS="$(printf '%s' "$CMDS" | tr '\n' ';')"
# Anything Tcl treats specially inside "..." must be escaped, or the heredoc
# below turns a shell command into a Tcl syntax error.
CMDS="$(printf '%s' "$CMDS" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\[/\\[/g; s/\]/\\]/g; s/\$/\\$/g')"

if ! nc -z -G2 "$IP" 23 >/dev/null 2>&1; then
	echo "port 23 is closed on $IP." >&2
	echo "The device is not in a debug shell. Either it is fully booted (use ssh)," >&2
	echo "or the image was booted without 'pmos.debug-shell' on the cmdline." >&2
	exit 2
fi

command -v expect >/dev/null 2>&1 || { echo "expect is required" >&2; exit 2; }

# Telnet negotiation and colour codes arrive as raw bytes; BSD sed refuses to
# touch them ("illegal byte sequence"), so filter in Python instead.
clean() { python3 -c '
import sys, re
data = sys.stdin.buffer.read()
data = re.sub(rb"\x1b\[[0-9;]*[a-zA-Z]", b"", data)   # ANSI escapes
data = bytes(b for b in data if b < 0x80 or b in b"\n\t")  # telnet IAC etc
sys.stdout.write(data.decode("utf-8", "replace").replace("\r", ""))
'; }

expect <<EOF 2>&1 | clean
log_user 1
set timeout 25
spawn nc $IP 23
# busybox telnetd negotiates first; just wait for anything that looks like a prompt
expect {
	-re {[#\$] $}  {}
	-re {[#\$]}    {}
	timeout        { send_user "\n(no prompt seen, sending anyway)\n" }
}
send "$CMDS\r"
expect {
	-re {[#\$] $} {}
	timeout       {}
}
# Do NOT send "exit": leaving the debug shell tells the initramfs to carry on
# booting, which tears the shell down and — with no framebuffer — kills the
# device outright. Just drop the connection; telnetd keeps serving, so the
# shell stays available for the next command.
close
wait
EOF
