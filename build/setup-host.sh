#!/bin/sh
# setup-host.sh — turn the OnePlus 3T pmOS server into a Docker host running
# Portainer, reachable ONLY over the tailnet (never the public internet).
#
# Reproduces every manual step we did by hand, idempotently (safe to re-run):
#   1. install Docker engine + CLI + compose plugin
#   2. fix the containerd.service ExecStart path bug (pmOS packaging: 203/EXEC)
#   3. Docker networking: public DNS for containers + allow forwarding for
#      Docker compose bridges (br-*) through the pmOS nftables firewall
#   4. enable + start containerd and docker under systemd
#   5. bring up Portainer (bound to 127.0.0.1 only) via compose
#   6. expose Portainer over the tailnet with `tailscale serve` (NOT funnel)
#
# Run it on the device, as root (a wheel user via doas):
#   scp build/setup-host.sh user@op3t:/tmp/
#   ssh -t user@op3t 'doas sh /tmp/setup-host.sh'
#
# Note: pmOS v25.12 is systemd; the device shell is busybox ash. POSIX sh only.
set -eu

PORTAINER_IMAGE="portainer/portainer-ce:lts"   # pin to LTS; bump deliberately
COMPOSE_DIR="/opt/op3t/portainer"
PORT="127.0.0.1:9443"                           # localhost-only; tailscale fronts it

echo ">> [1/6] install docker engine + cli + compose plugin"
# Pulls a batteries-included stack on pmOS: docker-systemd, containerd-systemd,
# iptables, postmarketos-config-nftables-docker, runc, buildx, compose.
apk add docker docker-cli-compose

echo ">> [2/6] fix containerd.service ExecStart (pkg points at /usr/local/bin)"
# The shipped containerd.service has ExecStart=/usr/local/bin/containerd, but the
# Alpine binary is /usr/bin/containerd -> status=203/EXEC -> containerd never
# starts -> dockerd hangs forever in "activating". A drop-in override fixes it.
CBIN="$(command -v containerd 2>/dev/null || echo /usr/bin/containerd)"
mkdir -p /etc/systemd/system/containerd.service.d
cat > /etc/systemd/system/containerd.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=$CBIN
EOF

echo ">> [3/6] docker networking: container DNS + nftables forward for compose bridges"
# Without these a container starts but hangs on its first outbound call
# (healthcheck fails -> "unhealthy"), because container egress is broken.
#
# DNS: Docker copies the host's resolv.conf nameserver into containers, which on
# a tailnet host is tailscale's magicDNS (100.100.100.100) — unreachable from a
# container. Give containers a public resolver instead.
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "dns": ["1.1.1.1", "8.8.8.8"]
}
EOF
# Forwarding: the pmOS firewall (table inet filter, chain forward, policy drop)
# drops forwarded traffic. postmarketos-config-nftables-docker ships
# 51_docker.nft which accepts iifname "docker*" but NOT compose bridges (br-*),
# so containers in a compose network can't reach the internet. Add br-*.
# (In nftables any base chain that drops kills the packet, so docker's masquerade
# in 'ip nat' is never even reached.)
cat > /etc/nftables.d/52_docker_bridges.nft <<'EOF'
#!/usr/sbin/nft -f
table inet filter {
	chain forward {
		iifname "br-*" accept comment "Docker compose bridges egress"
	}
}
EOF
systemctl restart nftables   # apply 51_docker.nft (just dropped by apk) + 52

echo ">> [4/6] enable + (re)start containerd and docker"
systemctl daemon-reload
systemctl reset-failed containerd.service docker.service 2>/dev/null || true
systemctl enable containerd.service docker.service
# Use restart (not just enable --now): re-applies docker's runtime nft rules
# after the nftables reload above, picks up /etc/docker/daemon.json (dns), and
# makes re-running this script safe even when the daemons are already up.
systemctl restart containerd.service
systemctl restart docker.service

echo ">> [5/6] bring up Portainer (compose; published only on $PORT)"
mkdir -p "$COMPOSE_DIR"
cat > "$COMPOSE_DIR/compose.yaml" <<EOF
# Portainer CE — Docker management UI. Has full control of the Docker socket
# (root-equivalent), so it is published on 127.0.0.1 only and reached solely
# over the tailnet via \`tailscale serve\`. NEVER expose it with funnel.
name: portainer
services:
  portainer:
    image: $PORTAINER_IMAGE
    container_name: portainer
    restart: always
    ports:
      - "$PORT:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
volumes:
  portainer_data:
EOF
docker compose -f "$COMPOSE_DIR/compose.yaml" up -d

echo ">> [6/6] expose services over the tailnet (mesh-only, NOT funnel)"
if command -v tailscale >/dev/null 2>&1; then
  # Portainer UI on the tailnet root: https/443 -> 9443 (self-signed -> insecure).
  tailscale serve --bg "https+insecure://$PORT" \
    || echo "   tailscale serve failed — enable Serve + HTTPS Certificates in the admin console, then re-run."
  # Bot HTTP (health + one-time secret links) on a separate tailnet port:
  # https/8443 -> host 127.0.0.1:8000. Set PUBLIC_URL of the bot stack to
  # https://<host>.<tailnet>.ts.net:8443. Harmless if the bot isn't deployed yet.
  tailscale serve --bg --https=8443 http://127.0.0.1:8000 \
    || echo "   bot tailscale serve failed — re-run after the bot stack is up."
  tailscale serve status || true
else
  echo "   tailscale not installed — skipping (install + 'tailscale up' first)"
fi

cat <<'EOF'

>> done.
   Open the tailnet URL shown above and create the Portainer admin within
   5 minutes. If the setup window timed out:
       doas docker restart portainer
   then read the one-time security token from the logs and paste it in the UI:
       doas docker logs portainer 2>&1 | grep -i token
EOF
