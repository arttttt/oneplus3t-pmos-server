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

Nothing to configure — `bin/op3t.sh` discovers the phone automatically: it sweeps
the Mac's own subnets (USB-net and WiFi) and identifies the device by its SSH
host key, so it follows the phone across DHCP/IP changes. To pin an explicit
address and skip discovery:

```
OP3T_HOST=192.168.1.50 bin/op3t.sh
```

(Optional: install mDNS for a stable `op3t.local` name —
`doas apk add avahi && doas systemctl enable --now avahi-daemon` — which the menu
then picks up as a fast discovery candidate.)

---

## 3. Update package index (needs internet → WiFi up)

```
doas apk update
doas apk upgrade        # optional
```

---

## 4. Mesh-only HTTPS URL for a web service — Tailscale serve (no public export)

Single-user setup: the service's web pages (the links it sends) are exposed
**only inside your Tailscale mesh — never to the public internet**. Use
`tailscale serve` (NOT `funnel`): the service is reachable at
`https://op3t.<tailnet>.ts.net` by your own tailnet devices only. No domain, no
static/public IP, no port-forwarding.

```
doas apk add tailscale
doas systemctl enable --now tailscaled
doas tailscale up                # one-time browser login
```

In the Tailscale admin console (login.tailscale.com), enable **MagicDNS** +
**HTTPS certificates** for the tailnet (required for a valid `…ts.net` cert).

You don't run `tailscale serve` by hand — `build/setup-host.sh` (next section)
publishes both Portainer (`https://op3t.<tailnet>.ts.net`, 443→9443) and the bot
(`…ts.net:8443` → `127.0.0.1:8000`) over the tailnet. `serve` is mesh-only and can
stay on permanently — no funnel, no public surface, no port-forwarding.

**Opening the links:** the device you tap a link from (your phone) must be on the
tailnet — run the Tailscale app there (you can keep it on only while confirming an
action). That's the trade-off of mesh-only vs. a public URL.

> Admin (ssh): the home LAN is enough — `ssh user@op3t.local` (install mDNS:
> `doas apk add avahi && doas systemctl enable --now avahi-daemon`) or the LAN IP
> (reserve it in your router). Away from home, ssh over the same tailnet.

---

## 5. Container platform + deploy the bot (Docker + Portainer)

The whole host setup is scripted in **`build/setup-host.sh`** — copy it over and
run it once:

```
scp build/setup-host.sh user@<ip>:/tmp/
ssh -t user@<ip> 'doas sh /tmp/setup-host.sh'
```

Idempotent; it installs Docker + the compose plugin, fixes the containerd unit
(the pmOS package ships a wrong `ExecStart` path → `203/EXEC`, so dockerd hangs),
gives containers a public DNS resolver and opens nftables forwarding for Docker
bridges (without both, a container starts but can't reach the internet), brings up
**Portainer** on `127.0.0.1:9443`, and publishes Portainer (443→9443) + the bot
(8443→8000) over `tailscale serve`.

Then the inherently-manual steps (secrets / UI / one-time — never scripted):

1. **Portainer admin** — open `https://op3t.<tailnet>.ts.net` and create the admin
   user within 5 min. If it timed out: `doas docker restart portainer`, then paste
   the token from `doas docker logs portainer 2>&1 | grep -i token`.
2. **Publish the image** (once) — GitHub → your **Packages** → `cmidcabot` →
   *Package settings* → *Change visibility* → **Public**. (CI at
   `arttttt/CMIDCABot` builds & pushes `ghcr.io/arttttt/cmidcabot` on every push to
   `main` / `v*` tag — the device never builds anything.)
3. **Deploy the bot stack** — Portainer → *Stacks* → *Add stack* → paste the bot
   repo's `deploy/compose.yaml` → fill the env vars (`TELEGRAM_BOT_TOKEN`,
   `OWNER_TELEGRAM_ID`, `MASTER_ENCRYPTION_KEY`, `SOLANA_RPC_URL`,
   `JUPITER_API_KEY`, `PUBLIC_URL=https://op3t.<tailnet>.ts.net:8443`) → Deploy.
4. ⚠️ **Back up `MASTER_ENCRYPTION_KEY` and the `cmidcabot_data` volume** off the
   device — losing the key means losing every encrypted wallet.

**Updates:** push to the bot repo → CI publishes a new tag → in Portainer pick the
tag and redeploy. No on-device build = no CPU/heat/flash spike on deploy.

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
| Menu            | `bin/op3t.sh`  (auto-discovers; `OP3T_HOST=<ip>` to pin)|
| Shell           | `ssh user@<ip>` (pw set in step 1)                  |
| Battery status  | `op3t-power charge status`                           |
| Service logs    | `journalctl -u <name> -f`                           |
| Service restart | `doas systemctl restart <name>`                     |
