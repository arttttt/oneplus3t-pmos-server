#!/usr/bin/env bash
# op3t — interactive menu to manage the OnePlus 3T pmOS server.
#
# Finds the device by DISCOVERY, not hardcoded addresses. It derives the Mac's
# own subnets, sweeps them, and identifies the phone by its SSH host key — which
# is stable across DHCP/IP changes (the WiFi MAC is randomized, so the key is the
# only reliable ID). The key is learned on first connect and cached; the
# last-good host is cached too for an instant reconnect. USB-net (172.16.42.1,
# the standard gadget gateway) and op3t.local (mDNS) are tried as fast
# candidates, but every candidate is still verified by host key before use.
# The cached key is self-healing: a reinstall regenerates the device's host key,
# so when the stored key matches nothing on the network the script re-learns it
# automatically (preferring USB/mDNS, which are reachable right after a flash).
#
# One SSH connection is opened and reused for the whole session (password once).
#
# Run:   bin/op3t.sh
# Env:   OP3T_HOST  pin an explicit host/IP and skip discovery
#        OP3T_USER  device user (default: user)
#        OP3T_PORT  ssh port    (default: 22)
set -uo pipefail

USER_="${OP3T_USER:-user}"
PORT="${OP3T_PORT:-22}"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}/op3t"
KEYFILE="$CFG/hostkey"      # the device's ed25519 host key: "ssh-ed25519 AAAA..."
LASTFILE="$CFG/last_host"   # last-good host/IP, tried first on the next run
mkdir -p "$CFG"

CTL="${TMPDIR:-/tmp}/op3t-ctl.$$"
SSHO=(-p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
      -o ControlMaster=auto -o ControlPath="$CTL" -o ControlPersist=600
      -o ConnectTimeout=5)

die(){ echo "op3t: $*" >&2; exit 1; }
note(){ printf '\033[2m%s\033[0m\n' "$*" >&2; }

# --- device discovery --------------------------------------------------------
up(){    nc -z -G "${1:-2}" "$2" "$PORT" >/dev/null 2>&1; }                 # port open?
keyfp(){ ssh-keyscan -t ed25519 -T 3 -p "$PORT" "$1" 2>/dev/null \
           | awk '/ssh-ed25519/{print $2,$3; exit}'; }                     # "ssh-ed25519 AAAA…"
known(){ [ -s "$KEYFILE" ] && cat "$KEYFILE"; }
matches(){ local k; k="$(known)" && [ -n "$k" ] && [ "$(keyfp "$1")" = "$k" ]; }
learn(){ local k; k="$(keyfp "$1")" && [ -n "$k" ] && printf '%s\n' "$k" >"$KEYFILE"; }

usb_peers(){  # USB-net gadget gateway, only when such an iface is actually up
  ifconfig 2>/dev/null | awk '/inet 172\.16\.42\./{print "172.16.42.1"}' | sort -u; }
subnets(){    # the Mac's own private /24s — this is the actual "detection"
  ifconfig 2>/dev/null | awk '/inet / && /netmask 0xffffff00/ {
      split($2,o,"."); if(o[1]==10||(o[1]==172&&o[2]>=16&&o[2]<=31)||(o[1]==192&&o[2]==168))
        print o[1]"."o[2]"."o[3]}' | sort -u; }

sweep(){  # $1=a.b.c -> print every host on that /24 with port $PORT open
  local net="$1" i
  for i in $(seq 1 254); do                          # 254 probes in parallel, ~1s total
    ( nc -z -G 1 "$net.$i" "$PORT" >/dev/null 2>&1 && echo "$net.$i" ) &
  done
  wait
}

candidates(){  # all reachable ssh hosts: USB + mDNS first, then each Mac subnet
  local c net
  for c in $(usb_peers) op3t.local; do up 2 "$c" && echo "$c"; done
  for net in $(subnets); do sweep "$net"; done
}

discover(){
  [ -n "${OP3T_HOST:-}" ] && { echo "$OP3T_HOST"; return 0; }
  if [ -s "$LASTFILE" ]; then                       # fast path: is last-good still ours?
    local h; h="$(cat "$LASTFILE")"
    if up 2 "$h" && { [ -z "$(known)" ] || matches "$h"; }; then echo "$h"; return 0; fi
  fi
  note "discovering device on $(subnets | tr '\n' ' ')…"
  local list h n; list="$(candidates | awk 'NF&&!s[$0]++')"
  [ -n "$list" ] || return 1
  if [ -n "$(known)" ]; then                         # known key -> try to match it
    for h in $list; do matches "$h" && { echo "$h"; return 0; }; done
    note "stored host key matched nothing — reinstalled? re-learning the new key."
  fi
  # bootstrap / re-learn: a lone ssh host is unambiguous; otherwise USB & mDNS
  # are device-specific (and what's reachable right after a flash), so prefer them.
  n="$(printf '%s\n' "$list" | wc -l | tr -d ' ')"
  if [ "$n" = 1 ]; then learn "$list"; echo "$list"; return 0; fi
  for h in $(usb_peers) op3t.local; do
    printf '%s\n' "$list" | grep -qx "$h" && { learn "$h"; echo "$h"; return 0; }
  done
  echo "Several SSH hosts found — which is the OnePlus 3T?" >&2
  local i=1; for h in $list; do echo "  $i) $h" >&2; i=$((i+1)); done
  printf '  pick [1]: ' >&2; read -r p </dev/tty; p="${p:-1}"
  h="$(printf '%s\n' "$list" | sed -n "${p}p")"; [ -n "$h" ] || return 1
  learn "$h"; echo "$h"
}

HOST="$(discover)" || die "device not found (USB, op3t.local, scan of $(subnets|tr '\n' ' ')). Pin it with OP3T_HOST=<ip>."
printf '%s\n' "$HOST" >"$LASTFILE"
case "$HOST" in 172.16.42.*) PROTO=USB;; op3t.local) PROTO=mDNS;; *) PROTO=LAN;; esac

# --- session -----------------------------------------------------------------
R(){  ssh "${SSHO[@]}" "$USER_@$HOST" "$@"; }       # run, capture
RT(){ ssh "${SSHO[@]}" -t "$USER_@$HOST" "$@"; }    # run with a tty (pkexec / shell)
pause(){ printf '\n(Enter to continue) '; read -r _; }
cleanup(){ ssh "${SSHO[@]}" -O exit "$USER_@$HOST" 2>/dev/null; rm -f "$CTL"; }
trap cleanup EXIT

# open the shared connection once (this is where you type the password)
echo "Connecting to $HOST ($PROTO) — enter the device password if prompted…"
ssh "${SSHO[@]}" -o ControlMaster=yes -fN "$USER_@$HOST" || die "connection failed"
[ -n "$(known)" ] || learn "$HOST"                  # remember key after first good connect

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
  echo "  3) WiFi          connect to a network"
  echo "  4) Open terminal (shell on the device)"
  echo "  5) Reboot device"
  echo "  6) Power off device"
  echo "  0) Quit"
  echo "=================================================="
  printf "  choose: "
  read -r c || break
  case "$c" in
    1) R 'echo "uptime:$(uptime)"; echo; free -m | head -2; echo; op3t-power charge status'; pause ;;
    2) printf "  target SoC %% [50]: "; read -r t; set_target "${t:-50}"; pause ;;
    3) echo "  available networks:"; R 'nmcli -f SSID,SIGNAL,SECURITY dev wifi list 2>/dev/null | head -20'
       printf "  SSID: "; read -r ssid
       if [ -n "$ssid" ]; then
         printf "  password: "; read -rs pass; echo
         RT "doas nmcli dev wifi connect \"$ssid\" password \"$pass\"; nmcli -g IP4.ADDRESS dev show wlan0"
       fi; pause ;;
    4) RT ;;
    5) printf "  reboot device? [y/N] "; read -r y; [ "$y" = y ] && priv "reboot" ;;
    6) printf "  power OFF device? [y/N] "; read -r y; [ "$y" = y ] && priv "poweroff" ;;
    0) break ;;
    *) ;;
  esac
done
