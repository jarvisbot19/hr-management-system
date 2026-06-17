#!/bin/bash
# === DigitalOcean Droplet startup script for the HR Tool (hardened) ===
# Paste into: Create Droplet -> Advanced/Additional Options -> "Startup scripts"
# (also labelled "User data" / "Add Initialization scripts" in some UI versions)
# -> the box that appears.  Runs ONCE on first boot, as root.
#
# Result: the app comes up at  http://<your-droplet-public-ip>  with NO SSH.
# Use a 2 GB+ Droplet. First build takes ~3-5 minutes after the Droplet is created.
#
# IMPORTANT: paste as PLAIN TEXT. The first line must be exactly #!/bin/bash with no
# leading spaces or blank line. Pasting via Windows Notepad/Word can corrupt the
# shebang (CRLF) so cloud-init runs nothing.

# NOTE: intentionally NO bare `set -e`. One early failure (apt lock at boot, the
# Docker daemon not being ready yet) would otherwise silently abort the whole
# script before the app ever starts. We log everything to the log DigitalOcean
# surfaces (/var/log/cloud-init-output.log) AND our own file, and keep going.
exec > >(tee -a /var/log/hr-tool-setup.log /var/log/cloud-init-output.log) 2>&1
echo "=== HR Tool setup START $(date -u) ==="

export DEBIAN_FRONTEND=noninteractive

# 0. Add swap so `composer install` (wants ~1.5 GB) won't get OOM-killed on a small box.
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# 1. Ensure Docker + Compose v2. Give apt a lock timeout so we survive the boot-time race.
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
if ! docker compose version >/dev/null 2>&1; then
  apt-get -o DPkg::Lock::Timeout=300 update -y
  apt-get -o DPkg::Lock::Timeout=300 install -y docker-compose-plugin
fi

# 2. Make sure the daemon is enabled and actually RUNNING before any docker command.
systemctl enable --now docker || true
for i in $(seq 1 30); do
  docker info >/dev/null 2>&1 && break
  echo "waiting for docker daemon... ($i)"; sleep 2
done

# 3. Open the web port (this Docker image ships with the ufw firewall enabled).
ufw allow OpenSSH || true
ufw allow 80/tcp  || true

# 4. Find this Droplet's public IP from DO metadata (timeout + retry, with fallback).
PUBLIC_IP="$(curl -s --max-time 5 --retry 3 \
  http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address)"
[ -z "$PUBLIC_IP" ] && PUBLIC_IP="localhost"   # never leave APP_URL=http:// empty

# 5. Clone the project and write deployment settings (host port 80 -> container 8000).
install -d /opt
cd /opt || exit 1
[ -d hr-tool ] || git clone https://github.com/bilalmbt/hr-management-system.git hr-tool
cd /opt/hr-tool || exit 1
cat > .env <<EOF
APP_PORT=80
APP_URL=http://${PUBLIC_IP}
DB_PASSWORD=$(openssl rand -hex 16)
EOF

# 6. Build and launch everything in the background.
docker compose up -d --build

echo "=== HR Tool setup DONE $(date -u) -> http://${PUBLIC_IP} (give it a few minutes) ==="
