# OnePlus 3T (pmOS) — remaining setup

Do these yourself, on the device. Get a shell with:

```
bin/op3t.sh        # → option 4 "Open terminal"
# or directly:
ssh user@172.16.42.1          # USB-net; password: changeme
```

The device uses **doas** for root (not sudo), **apk** for packages (Alpine-based),
**systemd** as init, **NetworkManager** for networking. Run privileged commands
with `doas <cmd>` (it will ask the password).

Order matters: change the password, bring up WiFi (for internet), then the rest.

---

## 1. Change the password (do this first)

```
passwd                  # changes the 'user' password (also used for ssh + doas/pkexec)
```

Note: root login is disabled; `user` + doas is the way in.

---

## 2. WiFi

```
doas nmcli radio wifi on
doas nmcli dev wifi list                       # find your SSID
doas nmcli dev wifi connect "YOUR_SSID" password "YOUR_WIFI_PASSWORD"
nmcli -g GENERAL.STATE dev status              # should show connected
ip -4 addr show wlan0 | grep inet              # note the LAN IP, e.g. 192.168.1.50
```

Make the connection auto-reconnect at boot (NetworkManager does this by default;
verify):

```
nmcli -g connection.autoconnect connection show "YOUR_SSID"   # should be yes
```

### Reach the device by WiFi from the Mac

The menu auto-detects USB first, then WiFi. Point it at the WiFi IP:

```
OP3T_WIFI=192.168.1.50 bin/op3t.sh
```

(Optional: for a stable `op3t.local` name instead of an IP, install mDNS:
`doas apk add avahi && doas systemctl enable --now avahi-daemon` — then the
default `OP3T_WIFI=op3t.local` works.)

---

## 3. Update package index (needs internet → WiFi up)

```
doas apk update
doas apk upgrade        # optional
```

---

## 4. Tailscale (remote access without a public IP)

```
doas apk add tailscale
doas systemctl enable --now tailscaled
doas tailscale up                # opens a login URL — authenticate in a browser
tailscale ip -4                  # your 100.x.y.z address
```

Then reach the box from anywhere:

```
OP3T_WIFI=100.x.y.z bin/op3t.sh
# or: ssh user@100.x.y.z
```

(Optional, set-and-forget: `doas tailscale up --ssh` to use Tailscale SSH.)

---

## 5. Deploy your service (generic example)

It's a normal headless Linux server — run whatever you like under systemd.
Example uses a Node app; swap for your runtime/app.

```
doas apk add nodejs npm git   # or python3, etc.
git clone <YOUR_REPO_URL> ~/app
cd ~/app
npm ci                      # or: npm install

# secrets / config — never commit these:
nano ~/app/.env
chmod 600 ~/app/.env
```

Run it under systemd so it survives reboots and restarts on crash:

```
doas tee /etc/systemd/system/myapp.service >/dev/null <<'EOF'
[Unit]
Description=My service
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/home/user/app
ExecStart=/usr/bin/node /home/user/app/index.js   # adjust to your entrypoint
EnvironmentFile=/home/user/app/.env
Restart=always
RestartSec=5
User=user

[Install]
WantedBy=multi-user.target
EOF

doas systemctl daemon-reload
doas systemctl enable --now myapp
journalctl -u myapp -f               # watch logs
```

Outbound-only services (long-poll bots, agents, schedulers) need just internet —
no public IP or port-forwarding (pairs well with Tailscale).

---

## 6. Battery (already set up)

`op3t-battery-guard` (systemd service) holds the charge near a target % to spare
the worn battery on 24/7 power. Change the target from the menu:

```
bin/op3t.sh   → 2) Battery: set hold target %   (e.g. 50, or 100 for full)
```

or by hand:

```
doas sed -i 's/^TARGET=.*/TARGET=50/' /etc/default/op3t-battery-guard
doas systemctl restart op3t-battery-guard
op3t-power charge status
```

---

## 7. Remove the leftover doas rule (optional cleanup)

I added `/etc/doas.d/20-op3t.conf` earlier (a passwordless rule for `op3t-power`);
auto-removal didn't go through. The menu does not need it. To delete:

```
doas rm /etc/doas.d/20-op3t.conf
```

---

## Quick reference

| What            | Command                                             |
|-----------------|-----------------------------------------------------|
| Menu            | `bin/op3t.sh`  (`OP3T_WIFI=<ip>` for WiFi/Tailscale)|
| Shell           | `ssh user@<ip>` (pw set in step 1)                  |
| Battery status  | `op3t-power charge status`                           |
| Service logs    | `journalctl -u <name> -f`                           |
| Service restart | `doas systemctl restart <name>`                     |
