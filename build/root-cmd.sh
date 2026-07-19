#!/usr/bin/env bash
# =============================================================================
# Run a command as root on the device, reliably.
#
# pkexec asks for the password on the tty, and driving that with a bare
# `expect { -re "assword:" { send ... } }` is flaky here: sometimes the send
# never lands, pkexec times out unauthenticated, and the command silently does
# not run. That failure is invisible — the script prints its usual success
# message while nothing happened. It cost us a "flash" that never wrote
# anything, and several "the bootloader ignores X" conclusions drawn from
# commands that had never executed.
#
# So: every invocation must PROVE it ran. The command is wrapped with a marker
# that is echoed only on success; if the marker is absent the whole attempt is
# retried, and after the last try we exit non-zero instead of pretending.
#
# Usage:  ./build/root-cmd.sh 'dd if=... of=...'
#         ./build/root-cmd.sh --quiet 'reboot'      # marker may be lost
# Exit:   0 = ran and confirmed, 1 = could not confirm
# =============================================================================
set -uo pipefail

IP="172.16.42.1"
KEY="$HOME/.ssh/op3t_ed25519"
PW="changeme"
TRIES=3
QUIET=0

while [ $# -gt 0 ]; do
	case "$1" in
		--ip)    IP="$2"; shift 2 ;;
		--quiet) QUIET=1; shift ;;   # for reboot/poweroff: the marker cannot come back
		*) break ;;
	esac
done
CMD="${1:?usage: root-cmd.sh [--ip X] [--quiet] '<command>'}"

MARK="__ROOTCMD_OK_$$__"
out=""
for try in $(seq 1 "$TRIES"); do
	out=$(expect <<EOF 2>&1
log_user 1
set timeout 45
set sent 0
spawn ssh -tt -i $KEY -o IdentitiesOnly=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ConnectTimeout=10 user@$IP {pkexec sh -c '$CMD; echo $MARK'}
expect {
	-re "assword" { if {\$sent==0} { set sent 1; send "$PW\r" }; exp_continue }
	timeout       { if {\$sent==0} { set sent 1; send "$PW\r"; exp_continue } }
	eof
}
EOF
	)
	if [ "$QUIET" = 1 ] || printf '%s' "$out" | grep -q "$MARK"; then
		# Strip the colour codes pkexec emits as well as its own chatter:
		# callers parse this output, and a stray "[0m" turns a number like
		# 10491133 into 010491133 and breaks an otherwise correct comparison.
		printf '%s\n' "$out" \
			| sed $'s/\x1b\\[[0-9;]*[a-zA-Z]//g' \
			| grep -vE "spawn ssh|Warning: Permanently|AUTHENTICATING FOR|Authentication is needed|Authenticating as|^Password:|AUTHENTICATION COMPLETE|$MARK|Connection to .* closed" \
			| sed '/^[[:space:]]*$/d'
		exit 0
	fi
	echo "  (attempt $try/$TRIES: root command did not confirm, retrying)" >&2
	sleep 3
done

echo "root command FAILED to run after $TRIES attempts — do not assume it did anything" >&2
printf '%s\n' "$out" | tail -5 >&2
exit 1
