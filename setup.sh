#!/bin/bash
#===============================================================================
# Oracle Cloud Free Tier — Full Self-Hosted Stack
# Stack: WireGuard + Pi-hole + Uptime Kuma + Vaultwarden
# Target: Ubuntu 22.04/24.04 ARM (Ampere A1), 1GB RAM, 45GB disk
#
# Run as: sudo bash setup.sh
#===============================================================================

set -e

# ─── CONFIG ───────────────────────────────────────────────────────────────────
WG_SUBNET="10.8.0.0/24"
WG_IFACE="10.8.0.1"
WG_PORT="51820"
WG_MTU="1280"
PUBLIC_IFACE="ens3"
PUBLIC_IP=$(curl -s4 ifconfig.me || echo "127.0.0.1")
UPTIME_KUMA_PORT="8081"
VAULTWARDEN_PORT="8082"
PIHOLE_ADMIN_PORT="80"
SWAP_SIZE="2G"

echo "=============================================="
echo " Oracle Cloud Free Tier — Stack Setup"
echo " Public IP: ${PUBLIC_IP}"
echo "=============================================="

# ─── 1. SWAP (critical for 1GB RAM) ──────────────────────────────────────────
echo ""
echo "[1/8] Setting up swap (${SWAP_SIZE})..."
if [ ! -f /swapfile ]; then
  fallocate -l ${SWAP_SIZE} /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >>/etc/fstab
  # Reduce swap usage tendency
  sysctl vm.swappiness=10
  echo 'vm.swappiness=10' >>/etc/sysctl.d/99-swap.conf
  echo "  Swap enabled: ${SWAP_SIZE}"
else
  echo "  Swap already exists, skipping."
fi

# ─── 2. SYSTEM UPDATE + DEPENDENCIES ─────────────────────────────────────────
echo ""
echo "[2/8] Updating system and installing dependencies..."
apt update -y
apt upgrade -y
apt install -y \
  wireguard \
  qrencode \
  curl \
  ca-certificates \
  iptables-persistent \
  unattended-upgrades

# ─── 3. FIX ORACLE CLOUD IPTABLES (the silent killer) ────────────────────────
echo ""
echo "[3/8] Fixing Oracle Cloud iptables REJECT rule..."
# Oracle's Ubuntu images end INPUT with a REJECT-all rule.
# We must insert ACCEPT rules BEFORE it.

# Find the REJECT line number
REJECT_LINE=$(iptables -L INPUT --line-numbers 2>/dev/null | awk '$2 == "REJECT" {print $1; exit}')

if [ -n "$REJECT_LINE" ]; then
  echo "  Found REJECT at line ${REJECT_LINE}, inserting rules before it..."
  # Insert in reverse order (each -I goes to the same position)
  iptables -I INPUT "$REJECT_LINE" -p tcp --dport $VAULTWARDEN_PORT -m state --state NEW -j ACCEPT
  iptables -I INPUT "$REJECT_LINE" -p tcp --dport $UPTIME_KUMA_PORT -m state --state NEW -j ACCEPT
  iptables -I INPUT "$REJECT_LINE" -p tcp --dport $PIHOLE_ADMIN_PORT -m state --state NEW -j ACCEPT
  iptables -I INPUT "$REJECT_LINE" -p udp --dport $WG_PORT -j ACCEPT
  iptables -I INPUT "$REJECT_LINE" -p tcp --dport 22 -m state --state NEW -j ACCEPT
  # Allow established/related
  iptables -I INPUT "$REJECT_LINE" -m state --state ESTABLISHED,RELATED -j ACCEPT
  # Allow loopback
  iptables -I INPUT "$REJECT_LINE" -i lo -j ACCEPT
  # Allow WireGuard subnet
  iptables -I INPUT "$REJECT_LINE" -s $WG_SUBNET -j ACCEPT
  # Allow DNS from WireGuard subnet only
  iptables -I INPUT "$REJECT_LINE" -s $WG_SUBNET -p udp --dport 53 -j ACCEPT
  iptables -I INPUT "$REJECT_LINE" -s $WG_SUBNET -p tcp --dport 53 -j ACCEPT

  netfilter-persistent save
  echo "  iptables rules saved."
else
  echo "  No REJECT rule found (non-Oracle image?). Adding rules anyway..."
  iptables -A INPUT -p udp --dport $WG_PORT -j ACCEPT
  iptables -A INPUT -p tcp --dport $PIHOLE_ADMIN_PORT -j ACCEPT
  iptables -A INPUT -p tcp --dport $UPTIME_KUMA_PORT -j ACCEPT
  iptables -A INPUT -p tcp --dport $VAULTWARDEN_PORT -j ACCEPT
  netfilter-persistent save
fi

# ─── 4. ENABLE IP FORWARDING ─────────────────────────────────────────────────
echo ""
echo "[4/8] Enabling IP forwarding..."
cat >/etc/sysctl.d/99-forwarding.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl --system >/dev/null

# ─── 5. WIREGUARD ─────────────────────────────────────────────────────────────
echo ""
echo "[5/8] Setting up WireGuard..."

mkdir -p /etc/wireguard
cd /etc/wireguard

# Generate server keys
SERVER_PRIVKEY=$(wg genkey)
SERVER_PUBKEY=$(echo "$SERVER_PRIVKEY" | wg pubkey)

# Create server config
cat >wg0.conf <<EOF
[Interface]
PrivateKey = ${SERVER_PRIVKEY}
Address = ${WG_IFACE}/24
ListenPort = ${WG_PORT}
MTU = ${WG_MTU}
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${PUBLIC_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${PUBLIC_IFACE} -j MASQUERADE
EOF

# Generate one client (add more later)
CLIENT_PRIVKEY=$(wg genkey)
CLIENT_PUBKEY=$(echo "$CLIENT_PRIVKEY" | wg pubkey)
PRESHARED_KEY=$(wg genkey)

# Append client to server config
cat >>wg0.conf <<EOF

[Peer]
PublicKey = ${CLIENT_PUBKEY}
PresharedKey = ${PRESHARED_KEY}
AllowedIPs = 10.8.0.2/32
EOF

chmod 600 wg0.conf

# Start WireGuard
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

# Generate client config
mkdir -p ~/wg-configs
tee ~/wg-configs/client1.conf > /dev/null <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVKEY}
Address = 10.8.0.2/24
MTU = ${WG_MTU}
DNS = ${WG_IFACE}

[Peer]
PublicKey = ${SERVER_PUBKEY}
PresharedKey = ${PRESHARED_KEY}
Endpoint = ${PUBLIC_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

# QR code for mobile
qrencode -t ansiutf8 <~/wg-configs/client1.conf | tee ~/wg-configs/client1.qr
echo "  WireGuard running. Client config: ~/wg-configs/client1.conf"
echo "  QR code: ~/wg-configs/client1.qr"

# ─── 6. PI-HOLE ───────────────────────────────────────────────────────────────
echo ""
echo "[6/8] Installing Pi-hole..."

echo "  Disabling systemd-resolved to avoid conflicts..."
# Disable systemd-resolved entirely
sudo systemctl disable --now systemd-resolved
sudo systemctl mask systemd-resolved

# Create static resolv.conf
echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf
echo "nameserver 8.8.8.8" | sudo tee -a /etc/resolv.conf

# Prevent NetworkManager or netplan from overwriting it
sudo chattr +i /etc/resolv.conf

# Verify
curl -s4 ifconfig.me
ping -c 3 google.com

PIHOLE_PASS=$(openssl rand -base64 16)

export INSTALL_SKIP_RESTART=true
export OVERWRITE_EXISTING_FILE=n
export PRIVACY_MODE=2
export DNS1=1.1.1.1
export DNS2=8.8.8.8
export DNSMASQ_LISTENING=local
export WEBPASSWORD="${PIHOLE_PASS}"
export REUSE_EXISTING_IPV4_ADDRESS=

curl -sSL https://install.pi-hole.net | bash -s -- -up

# Configure Pi-hole to also listen on WireGuard subnet
# Edit /etc/dnsmasq.conf to add the WireGuard interface
echo "listen-address=127.0.0.1,${WG_IFACE}" >/etc/dnsmasq.d/wireguard.conf
echo "bind-interfaces" >>/etc/dnsmasq.d/wireguard.conf

systemctl restart pihole
systemctl restart pihole-FTL.service
echo "  Pi-hole installed. Admin password: ${PIHOLE_PASS}"
echo "  Access via: http://${WG_IFACE}/admin (when connected to VPN)"

# ─── 7. DOCKER + UPTIME KUMA + VAULTWARDEN ───────────────────────────────────
echo ""
echo "[7/8] Installing Docker and containers..."

# Install Docker
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker

# Create data directory
mkdir -p /opt/stack/{uptime-kuma,vaultwarden}

# Uptime Kuma
cat >/opt/stack/uptime-kuma/docker-compose.yml <<EOF
version: "3"
services:
  uptime-kuma:
    image: louislam/uptime-kuma:1
    container_name: uptime-kuma
    restart: unless-stopped
    ports:
      - "${UPTIME_KUMA_PORT}:3001"
    volumes:
      - ./data:/app/data
    mem_limit: 256m
EOF

# Vaultwarden
cat >/opt/stack/vaultwarden/docker-compose.yml <<EOF
version: "3"
services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    ports:
      - "${VAULTWARDEN_PORT}:80"
    environment:
      - SIGNUPS_ALLOWED=false
      - DOMAIN=https://${PUBLIC_IP}
    volumes:
      - ./data:/data
    mem_limit: 128m
EOF

# Start both
cd /opt/stack/uptime-kuma && docker compose up -d
cd /opt/stack/vaultwarden && docker compose up -d

echo "  Uptime Kuma: http://${PUBLIC_IP}:${UPTIME_KUMA_PORT}"
echo "  Vaultwarden: http://${PUBLIC_IP}:${VAULTWARDEN_PORT}"

# ─── 8. AUTO-UPDATES + SUMMARY ───────────────────────────────────────────────
echo ""
echo "[8/8] Enabling unattended security updates..."
echo 'Unattended-Upgrade::Allowed-Origins {"Ubuntu": "22.04*";};' >/etc/apt/apt.conf.d/52unattended-autofix
echo 'Unattended-Upgrade::Automatic-Reboot "true";' >>/etc/apt/apt.conf.d/52unattended-autofix

# ─── FINAL SUMMARY ────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  SETUP COMPLETE                                       ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                        ║"
echo "║  WireGuard VPN                                        ║"
echo "║    Port: ${WG_PORT}/udp                                ║"
echo "║    Client config: ~/wg-configs/client1.conf           ║"
echo "║    QR: ~/wg-configs/client1.qr                        ║"
echo "║                                                        ║"
echo "║  Pi-hole (via VPN)                                    ║"
echo "║    Admin: http://${WG_IFACE}/admin                  ║"
echo "║    Password: ${PIHOLE_PASS}                      ║"
echo "║                                                        ║"
echo "║  Uptime Kuma                                          ║"
echo "║    URL: http://${PUBLIC_IP}:${UPTIME_KUMA_PORT}                 ║"
echo "║                                                        ║"
echo "║  Vaultwarden                                          ║"
echo "║    URL: http://${PUBLIC_IP}:${VAULTWARDEN_PORT}                 ║"
echo "║    (Create admin account on first visit)              ║"
echo "║                                                        ║"
echo "║  ⚠️  DO NOT FORGET:                                   ║"
echo "║  1. Open ports in Oracle Security List (see top)      ║"
echo "║  2. Save the Pi-hole admin password                   ║"
echo "║  3. Import ~/wg-configs/client1.conf into your device ║"
echo "║                                                        ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "Estimated RAM usage: ~500-650MB (with 2GB swap as safety net)"
echo ""
