#!/usr/bin/env bash
# op3t — interactive menu to manage the OnePlus 3T pmOS server.
#
# Auto-detects the device on USB-net or WiFi and opens ONE SSH connection that
# is reused for the whole session (you type the device password once). Every
# menu item runs over that connection; "Open terminal" is just one of them.
#
# Run:   bin/op3t.sh
# Env:   OP3T_USER (default user), OP3T_USB (default 172.16.42.1),
#        OP3T_WIFI (default op3t-bot.local — set to the phone's LAN IP/name
#        once WiFi is configured), OP3T_PORT (default 22).
set -uo pipefail

USER_="${OP3T_USER:-user}"
USB="${OP3T_USB:-172.16.42.1}"
WIFI="${OP3T_WIFI:-op3t-bot.local}"
PORT="${OP3T_PORT:-22}"
CTL="${TMPDIR:-/tmp}/op3t-ctl.$$"
SSHO=(-p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
      -o ControlMaster=auto -o ControlPath="$CTL" -o ControlPersist=600
      -o ConnectTimeout=5)

die(){ echo "op3t: $*" >&2; exit 1; }
find_host(){ local h; for h in "$USB" "$WIFI"; do
  [ -n "$h" ] && nc -z -G 2 "$h" "$PORT" 2>/dev/null && { echo "$h"; return 0; }
done; return 1; }

HOST="$(find_host)" || die "device not reachable on USB ($USB) or WiFi ($WIFI:$PORT)"
PROTO=USB; [ "$HOST" = "$USB" ] || PROTO=WiFi
R(){  ssh "${SSHO[@]}" "$USER_@$HOST" "$@"; }       # run, capture
RT(){ ssh "${SSHO[@]}" -t "$USER_@$HOST" "$@"; }    # run with a tty (for pkexec / shell)
pause(){ printf '\n(Enter to continue) '; read -r _; }
cleanup(){ ssh "${SSHO[@]}" -O exit "$USER_@$HOST" 2>/dev/null; rm -f "$CTL"; }
trap cleanup EXIT

# open the shared connection once (this is where you type the password)
echo "Connecting to $HOST ($PROTO) — enter the device password if prompted…"
ssh "${SSHO[@]}" -o ControlMaster=yes -fN "$USER_@$HOST" || die "connection failed"

# privileged one-liner via polkit (asks the password once, then caches ~5 min)
priv(){ RT "pkexec /bin/sh -c '$1'"; }

set_target(){ priv "sed -i \"s/^TARGET=.*/TARGET=$1/\" /etc/default/op3t-battery-guard && systemctl restart op3t-battery-guard && echo \"battery target set to $1%\""; }

while :; do
  clear
  status="$(R 'op3t-power charge status 2>/dev/null')"
  echo "=================================================="
  echo "  OnePlus 3T  —  $HOST ($PROTO)"
  echo "  ${status:-<status unavailable>}"
  echo "=================================================="
  echo "  1) Status        (uptime / load / mem / battery)"
  echo "  2) Battery       set hold target % (100 = full)"
  echo "  3) Display ON"
  echo "  4) Display OFF"
  echo "  5) Open terminal (shell on the device)"
  echo "  6) Reboot device"
  echo "  7) Power off device"
  echo "  8) Quit"
  echo "=================================================="
  printf "  choose: "
  read -r c || break
  case "$c" in
    1) R 'echo "uptime:$(uptime)"; echo; free -m | head -2; echo; op3t-power charge status'; pause ;;
    2) printf "  target SoC %% [50]: "; read -r t; set_target "${t:-50}"; pause ;;
    3) priv "/usr/local/bin/op3t-power display on";  pause ;;
    4) priv "/usr/local/bin/op3t-power display off"; pause ;;
    5) RT ;;
    6) printf "  reboot device? [y/N] "; read -r y; [ "$y" = y ] && priv "reboot" ;;
    7) printf "  power OFF device? [y/N] "; read -r y; [ "$y" = y ] && priv "poweroff" ;;
    8) break ;;
    *) ;;
  esac
done
