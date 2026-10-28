# Oracle Cloud Free Tier — Self-Hosted Stack

[![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04-E95420)](https://ubuntu.com/)
[![RAM](https://img.shields.io/badge/RAM-1GB%20%2B%202GB%20swap-blue)]()
[![License](https://img.shields.io/badge/License-MIT-green)]()

One-command setup for a **1 GB / 45 GB Oracle Cloud Free Tier VPS** that deploys:

| Service | Purpose | RAM |
|---------|---------|-----|
| **WireGuard** | Encrypted VPN (routes all traffic through VPS) | ~20 MB |
| **Pi-hole** | Network-wide DNS ad & tracker blocking | ~100 MB |
| **Uptime Kuma** | Self-hosted uptime monitoring & alerts | ~150 MB |
| **Vaultwarden** | Bitwarden-compatible password manager | ~80 MB |
| **Swap (2 GB)** | Safety net against OOM kills | — |

**Total steady-state RAM: ~550 MB** (well within 1 GB + 2 GB swap)

---

## Requirements

- **Oracle Cloud Free Tier** VPS (Ampere A1, 1 GB RAM, 45 GB disk)
- **Ubuntu 22.04 or 24.04** (ARM)
- Root or `sudo` access
- ~2 GB free disk space
- ~15 minutes of your time

> Works on other 1 GB VPS providers (Hetzner, DigitalOcean, etc.) but the iptables REJECT fix and MTU 1280 are Oracle-specific.

---

## Prerequisites (Manual — Cannot Be Automated)

### 1. Open Ports in Oracle Security List

Go to **Oracle Cloud Console → Networking → VCN → Public Subnet → Security List → Add Ingress Rule**:

| Protocol | Destination Port Range | Source CIDR | Description |
|----------|----------------------|-------------|-------------|
| UDP | `51820` | `0.0.0.0/0` | WireGuard |
| TCP | `80` | `0.0.0.0/0` | Pi-hole admin |
| TCP | `8081` | `0.0.0.0/0` | Uptime Kuma |
| TCP | `8082` | `0.0.0.0/0` | Vaultwarden |

> ⚠️ **This is the #1 reason people think the script "didn't work."** The script cannot modify Oracle's cloud-level firewall.

### 2. (Optional) Restrict Access

For better security, replace `0.0.0.0/0` with your home IP for ports 80, 8081, and 8082:

```
Source CIDR: YOUR_HOME_IP/32
```

Keep `0.0.0.0/0` for UDP 51820 (WireGuard) so you can connect from anywhere.

---

## Installation

```bash
# On your local machine:
scp setup.sh ubuntu@YOUR_ORACLE_IP:~/

# SSH in:
ssh ubuntu@YOUR_ORACLE_IP

# Run (MUST use bash, not sh):
sudo bash ~/setup.sh
```

The script will:
1. Create a 2 GB swap file
2. Install system dependencies
3. Fix Oracle's iptables REJECT rule
4. Enable IP forwarding
5. Configure WireGuard (server + 1 client)
6. Install and configure Pi-hole
7. Install Docker + Uptime Kuma + Vaultwarden
8. Enable unattended security updates

**Estimated time:** 5–10 minutes (depending on your internet speed).

---

## Post-Setup

### Reboot (required)

```bash
sudo reboot
```

A kernel upgrade is applied during the script. Reboot to load it.

### Verify Services

After reboot, re-SSH and run:

```bash
systemctl status wg-quick@wg0    # WireGuard
systemctl status pihole           # Pi-hole
docker ps                         # Uptime Kuma + Vaultwarden
```

All should show **active (running)**.

### Get Your Credentials

```bash
# Public IP
curl -s4 ifconfig.me

# Pi-hole admin password
grep PASSWORD /etc/pihole/setupVars.conf

# WireGuard client config
cat ~/wg-configs/client1.conf
```

**Save these somewhere safe.** You'll need them to connect.

---

## Connecting Your Devices

### WireGuard (Phone / Laptop / Tablet)

1. Install the **WireGuard** app (iOS / Android / Windows / macOS / Linux)
2. Import `~/wg-configs/client1.conf` (scan QR or paste config)
3. Connect

Once connected, **all your traffic** routes through the VPS and Pi-hole filters DNS.

### Pi-hole Admin

While connected to WireGuard:

```
http://10.8.0.1/admin
```

Enter the password from `setupVars.conf`.

### Uptime Kuma

```
http://YOUR_PUBLIC_IP:8081
```

Create your admin account on first visit. Add monitors for your websites, APIs, etc.

### Vaultwarden

```
http://YOUR_PUBLIC_IP:8082
```

Create your master account on first visit. Then import into any Bitwarden client (browser extension, mobile app, desktop app).

> **Note:** Uptime Kuma and Vaultwarden are accessible from anywhere (not just through VPN). For production use, put them behind a reverse proxy with TLS (see below).

---

## Adding More WireGuard Clients

```bash
# Generate keys for new client
NEW_PRIV=$(wg genkey)
NEW_PUB=$(echo "$NEW_PRIV" | wg pubkey)
NEW_PSK=$(wg genkey)

# Append to server config (use next IP: 10.8.0.3, 10.8.0.4, etc.)
cat >> /etc/wireguard/wg0.conf <<EOF

[Peer]
PublicKey = ${NEW_PUB}
PresharedKey = ${NEW_PSK}
AllowedIPs = 10.8.0.3/32
EOF

sudo systemctl restart wg-quick@wg0
```

Then create a client config file with the new private key, address `10.8.0.3/24`, and the same server public key / endpoint.

---

## Optional: TLS with Caddy (Reverse Proxy)

For Vaultwarden and Uptime Kuma, plain HTTP is fine on a private network, but for internet-facing access you want TLS:

```bash
# Install Caddy
sudo apt install -y caddy

# /etc/caddy/Caddyfile
sudo tee /etc/caddy/Caddyfile <<EOF
vaultwarden.yourdomain.com {
    reverse_proxy 127.0.0.1:8082
}

uptime.yourdomain.com {
    reverse_proxy 127.0.0.1:8081
}
EOF

sudo systemctl reload caddy
```

> Requires a domain name and DNS A record pointing to your VPS IP. Caddy auto-provisions Let's Encrypt certificates.

---

## Useful Commands

| Command | What it does |
|---------|-------------|
| `pihole -s` | Open Pi-hole admin |
| `pihole -t` | Live DNS query log |
| `pihole -c` | Console summary (blocked %, total queries) |
| `pihole -g` | Rebuild blocklist (run after adding new lists) |
| `wg show wg0` | Show connected WireGuard peers |
| `docker ps` | List running containers |
| `docker logs uptime-kuma` | View Uptime Kuma logs |
| `docker logs vaultwarden` | View Vaultwarden logs |
| `free -h` | Check RAM / swap usage |
| `df -h` | Check disk usage |

---

## Maintenance

| Task | Frequency | Command |
|------|-----------|---------|
| Update Pi-hole blocklist | Weekly (or auto) | `sudo pihole -g` |
| Update Pi-hole | Monthly | `sudo pihole -up` |
| Update Docker images | Monthly | `cd /opt/stack/uptime-kuma && sudo docker compose pull && sudo docker compose up -d` |
| Update OS packages | Auto (unattended-upgrades) | — |
| Reboot (kernel updates) | Monthly | `sudo reboot` |
| Check disk usage | Monthly | `df -h` |

### Auto-update Pi-hole blocklist (cron)

```bash
sudo crontab -e
# Add:
0 3 * * 1 /usr/local/bin/pihole -g
```

---

## Troubleshooting

### "Connection timed out" when connecting to WireGuard
- **Check Oracle Security List** — UDP 51820 must be open (most common issue)
- Verify the endpoint IP in your client config matches `curl -s4 ifconfig.me`
- Check `sudo systemctl status wg-quick@wg0` is active

### Pi-hole not blocking ads
- Make sure your device is **connected to WireGuard**
- Verify DNS is set to `10.8.0.1` (it's in the client config under `DNS =`)
- Run `sudo pihole -t` and check if queries are hitting it
- Some apps use hardcoded IPs or DoH/DoT — Pi-hole can't block those

### Uptime Kuma / Vaultwarden not reachable
- Check `docker ps` — are containers running?
- Check `sudo iptables -L INPUT -n` — is the port ACCEPTed?
- Check Oracle Security List again

### High swap usage
- Run `free -h` to check
- If swap is consistently > 500 MB, remove a service (Uptime Kuma is the heaviest)
- `sudo docker stop uptime-kuma` to free ~150 MB

### Script failed at `sysctl-tools`
- This is a **non-existent package** on Ubuntu. If you're using an older version of the script, remove it from the apt install line and re-run.

### `sh` vs `bash`
- **Always run with `bash`**, not `sh`. The script uses bash-specific features (brace expansion, etc.).
- `sudo bash setup.sh` ✅
- `sudo sh setup.sh` ❌

---

## Uninstall

```bash
# Stop and remove containers
cd /opt/stack/uptime-kuma && sudo docker compose down
cd /opt/stack/vaultwarden && sudo docker compose down

# Remove Docker
sudo apt remove -y docker.io docker-compose
sudo rm -rf /var/lib/docker /opt/stack

# Remove Pi-hole
sudo pihole uninstall

# Remove WireGuard
sudo systemctl stop wg-quick@wg0
sudo rm -rf /etc/wireguard/wg0.conf

# Remove swap
sudo swapoff /swapfile
sudo rm /swapfile
sudo sed -i '/swapfile/d' /etc/fstab

# Clean up iptables
sudo netfilter-persistent flush
sudo netfilter-persistent save
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Your Devices (phone, laptop, tablet, ...)             │
│                                                         │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐            │
│  │  WireGuard App  │  │  WireGuard App  │  │  ...     │            │
│  └─────┬────┘  └─────┬────┘  └─────┬───┘            │
└────────┼──────────────┼──────────────┼────────────────┘
         │              │              │
         │   Encrypted (WireGuard / UDP 51820)          │
         ▼              ▼              ▼
┌─────────────────────────────────────────────────────────┐
│  Oracle VPS (10.8.0.1)                                  │
│                                                         │
│  ┌────────────┐  ┌────────────┐  ┌────────────────┐  │
│  │  WireGuard  │  │  Pi-hole   │  │  Docker        │  │
│  │  (wg0)     │──│  (DNS:53)  │  │  ┌──────────┐  │  │
│  └────────────┘  └────────────┘  │  │Uptime    │  │  │
│                                  │  │Kuma:8081 │  │  │
│                                  │  ├──────────┤  │  │
│                                  │  │Vaultwarden│  │  │
│                                  │  │  :8082   │  │  │
│                                  │  └──────────┘  │  │
│                                  └────────────────┘  │
│                                                         │
│  Upstream DNS: Cloudflare (1.1.1.1) + Google (8.8.8.8) │
└─────────────────────────────────────────────────────────┘
```

---