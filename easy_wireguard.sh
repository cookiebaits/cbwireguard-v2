cat << 'EOF' > easy_wireguard.sh
#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${PURPLE}=================================================================${NC}"
echo -e "${GREEN}${BOLD}     🍪 Cookie's WireGuard VPS Stealth Installer v3.0${NC}"
echo -e "${CYAN}        Hyper-Optimized for Unblocking & Stealth Personal VPS${NC}"
echo -e "${PURPLE}=================================================================${NC}"

if [[ "$EUID" -ne 0 ]]; then
    echo -e "\n${RED}[ERROR] This installer must be run as root.${NC}"
    echo -e "Please run: ${BOLD}sudo bash $0${NC}\n"
    exit 1
fi

get_public_ip() {
    local services=("https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com" "https://ident.me")
    for svc in "${services[@]}"; do
        local ip
        ip=$(curl -4 -sSf --max-time 3 "$svc" 2>/dev/null || true)
        if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    echo "127.0.0.1"
}

SERVER_IP=${SERVER_IP:-$(get_public_ip)}
echo -e "${CYAN}[*] Auto-detected server public IP:${NC} ${BOLD}$SERVER_IP${NC}"

WG_PORT=${PORT:-${WG_PORT:-"443"}}
WEB_PORT=${WEB_PORT:-"51821"}
CLIENT_NAME=${CLIENT_NAME:-"my-phone"}

export DEBIAN_FRONTEND=noninteractive
apt-get update -y -q
apt-get install -y -q wireguard wireguard-tools iptables qrencode curl jq iproute2 net-tools

mkdir -p /etc/wireguard
chmod 700 /etc/wireguard
cd /etc/wireguard
umask 077

if [[ ! -f /etc/wireguard/server_private.key ]]; then
    wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
fi

SERVER_PRIV=$(cat /etc/wireguard/server_private.key)
SERVER_PUB=$(cat /etc/wireguard/server_public.key)

if [[ ! -f /etc/wireguard/admin.key ]]; then
    ADMIN_PASSKEY=$(tr -dc 'A-Za-z0-9!@#$%^&*' < /dev/urandom | head -c 24)
    echo "$ADMIN_PASSKEY" > /etc/wireguard/admin.key
    chmod 600 /etc/wireguard/admin.key
else
    ADMIN_PASSKEY=$(cat /etc/wireguard/admin.key)
fi

cat << ENV_EOF > /etc/wireguard/manager.env
SERVER_PUBLIC_IP="${SERVER_IP}"
WG_DEFAULT_PORT="${WG_PORT}"
WEB_PORT="${WEB_PORT}"
ADMIN_PASSKEY="${ADMIN_PASSKEY}"
ENV_EOF
chmod 600 /etc/wireguard/manager.env

CLIENT_PRIV=$(wg genkey)
CLIENT_PUB=$(echo "$CLIENT_PRIV" | wg pubkey)
CLIENT_PSK=$(wg genpsk)

CLIENT_IP="10.18.0.2"
SERVER_TUNNEL_IP="10.18.0.1/24"

NIC=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n1 || echo "eth0")

cat << WG_SERVER_EOF > /etc/wireguard/wg0.conf
[Interface]
Address = ${SERVER_TUNNEL_IP}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}
MTU = 1420
SaveConfig = false

PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${NIC} -j MASQUERADE
PostUp = iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o ${NIC} -j TCPMSS --clamp-mss-to-pmtu
PostUp = iptables -t mangle -A POSTROUTING -o ${NIC} -j TTL --ttl-set 64

PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${NIC} -j MASQUERADE
PostDown = iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o ${NIC} -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -t mangle -D POSTROUTING -o ${NIC} -j TTL --ttl-set 64

[Peer]
PublicKey = ${CLIENT_PUB}
PresharedKey = ${CLIENT_PSK}
AllowedIPs = ${CLIENT_IP}/32
WG_SERVER_EOF

chmod 600 /etc/wireguard/wg0.conf

mkdir -p /etc/wireguard/clients
CLIENT_CONF_PATH="/etc/wireguard/clients/${CLIENT_NAME}.conf"
cat << WG_CLIENT_EOF > "$CLIENT_CONF_PATH"
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = ${CLIENT_IP}/24
DNS = 94.140.14.49, 9.9.9.9
MTU = 1420

[Peer]
PublicKey = ${SERVER_PUB}
PresharedKey = ${CLIENT_PSK}
Endpoint = ${SERVER_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/1, 128.0.0.0/1, ::/1, 8000::/1
PersistentKeepalive = 25
WG_CLIENT_EOF

chmod 600 "$CLIENT_CONF_PATH"
cp "$CLIENT_CONF_PATH" "/root/${CLIENT_NAME}.conf"

systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
systemctl restart wg-quick@wg0

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow "${WG_PORT}/udp" >/dev/null 2>&1 || true
    ufw allow "${WEB_PORT}/tcp" >/dev/null 2>&1 || true
fi

echo -e "\n${GREEN}=================================================================${NC}"
echo -e "${GREEN}${BOLD}   🎉 WireGuard VPS Stealth Server Successfully Installed!${NC}"
echo -e "${GREEN}=================================================================${NC}"
echo -e "  ${BOLD}Auto-Detected Public IP:${NC} ${SERVER_IP}"
echo -e "  ${BOLD}WireGuard Port:${NC}          ${WG_PORT}/udp"
echo -e "  ${BOLD}Web Console Port:${NC}        ${WEB_PORT}/tcp"
echo -e "  ${BOLD}Initial Peer Created:${NC}    ${CLIENT_NAME} (10.18.0.2)"
echo -e "${GREEN}=================================================================${NC}\n"

qrencode -t ansiutf8 < "$CLIENT_CONF_PATH"

echo -e "\n${CYAN}=================================================================${NC}"
echo -e "  ${BOLD}Internal Tunnel URL:${NC} http://10.18.0.1:${WEB_PORT}"
echo -e "  ${BOLD}Passkey:${NC} ${ADMIN_PASSKEY}"
echo -e "${CYAN}=================================================================${NC}\n"
EOF

chmod +x easy_wireguard.sh
sudo ./easy_wireguard.sh
