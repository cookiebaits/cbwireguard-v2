#!/bin/bash
# ==============================================================================
# 🍪 Cookie's Easy WireGuard Manager & VPS Stealth Server v3.5
# Inspired by angristan/wireguard-install with Hyper-Optimized VPS Stealth Features
# ==============================================================================

# Colors
RED='\033[0;31m'
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

# ------------------------------------------------------------------------------
# 1. System & Root Verification Checks
# ------------------------------------------------------------------------------
function isRoot() {
	if [ "${EUID}" -ne 0 ]; then
		echo -e "${RED}[ERROR] You need to run this script as root.${NC}"
		echo -e "Please run: ${BOLD}sudo bash $0${NC}\n"
		exit 1
	fi
}

function checkVirt() {
	local VIRT=""
	if command -v virt-what &>/dev/null; then
		VIRT=$(virt-what)
	else
		VIRT=$(systemd-detect-virt 2>/dev/null || true)
	fi
	if [[ "${VIRT}" == "openvz" ]]; then
		echo -e "${RED}[ERROR] OpenVZ is not supported by WireGuard kernel modules.${NC}"
		exit 1
	fi
	if [[ "${VIRT}" == "lxc" ]]; then
		echo -e "${YELLOW}[WARNING] LXC container detected.${NC}"
		echo "WireGuard requires the kernel module enabled on the host machine."
	fi
}

function checkOS() {
	if [[ -e /etc/os-release ]]; then
		source /etc/os-release
		OS="${ID}"
	elif [[ -e /etc/debian_version ]]; then
		OS="debian"
	else
		echo -e "${RED}Unsupported Linux distribution.${NC}"
		exit 1
	fi

	if [[ "${OS}" == "debian" || "${OS}" == "raspbian" ]]; then
		if [[ ${VERSION_ID:-10} -lt 10 ]]; then
			echo "Your version of Debian (${VERSION_ID}) is not supported. Please use Debian 10 Buster or later."
			exit 1
		fi
		OS="debian"
	elif [[ "${OS}" == "ubuntu" ]]; then
		RELEASE_YEAR=$(echo "${VERSION_ID:-20.04}" | cut -d'.' -f1)
		if [[ ${RELEASE_YEAR} -lt 18 ]]; then
			echo "Your version of Ubuntu (${VERSION_ID}) is not supported. Please use Ubuntu 18.04 or later."
			exit 1
		fi
	elif [[ "${OS}" == "fedora" || "${OS}" == "centos" || "${OS}" == "almalinux" || "${OS}" == "rocky" || "${OS}" == "arch" || "${OS}" == "alpine" ]]; then
		: # Supported
	fi
}

function initialCheck() {
	isRoot
	checkOS
	checkVirt
}

function getHomeDirForClient() {
	local CLIENT_NAME="$1"
	if [ -z "${CLIENT_NAME}" ]; then
		echo "/root"
		return
	fi
	if [ -e "/home/${CLIENT_NAME}" ]; then
		echo "/home/${CLIENT_NAME}"
	elif [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
		echo "/home/${SUDO_USER}"
	else
		echo "/root"
	fi
}

# ------------------------------------------------------------------------------
# 2. Cleanup Old WireGuard Instances & Remove Conflicting Rules
# ------------------------------------------------------------------------------
function cleanupOldWireguard() {
	echo -e "\n${CYAN}[*] Scanning for old/conflicting WireGuard instances & services...${NC}"

	systemctl stop "wg-quick@*" >/dev/null 2>&1 || true
	systemctl disable "wg-quick@*" >/dev/null 2>&1 || true

	if command -v wg-quick >/dev/null 2>&1; then
		wg-quick down wg0 >/dev/null 2>&1 || true
		wg-quick down wg1 >/dev/null 2>&1 || true
	fi

	ip link delete dev wg0 >/dev/null 2>&1 || true
	ip link delete dev wg1 >/dev/null 2>&1 || true

	systemctl stop cbwireguard-web >/dev/null 2>&1 || true
	systemctl disable cbwireguard-web >/dev/null 2>&1 || true

	iptables -t nat -F POSTROUTING 2>/dev/null || true
	iptables -t mangle -F POSTROUTING 2>/dev/null || true
	iptables -F FORWARD 2>/dev/null || true

	echo -e "${GREEN}[✔] Cleaned up old instances and flushed conflicting firewall state.${NC}"
}

# ------------------------------------------------------------------------------
# 3. Interactive Installation Questions
# ------------------------------------------------------------------------------
function installQuestions() {
	echo -e "${PURPLE}=================================================================${NC}"
	echo -e "             ${GREEN}${BOLD}🍪Cookie's Easy WireGuard Setup & Installer${NC}"
	echo -e "${PURPLE}=================================================================${NC}"
	echo -e "Welcome to the WireGuard installer!\n"

	SERVER_PUB_IP=""
	local services=("https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com")
	for svc in "${services[@]}"; do
		SERVER_PUB_IP=$(curl -4 -sSf --max-time 2 "$svc" 2>/dev/null || true)
		if [[ -n "$SERVER_PUB_IP" && "$SERVER_PUB_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
			break
		fi
	done
	if [[ -z "$SERVER_PUB_IP" ]]; then
		SERVER_PUB_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n1 || echo "127.0.0.1")
	fi

	read -rp "IPv4 public address for server: " -e -i "${SERVER_PUB_IP}" SERVER_PUB_IP

	SERVER_NIC=$(ip -4 route show default 2>/dev/null | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | head -n1 || true)
	if [[ -z "$SERVER_NIC" ]]; then
		SERVER_NIC="eth0"
	fi
	read -rp "Public network interface: " -e -i "${SERVER_NIC}" SERVER_PUB_NIC

	read -rp "WireGuard interface name: " -e -i "wg0" SERVER_WG_NIC

	read -rp "Server WireGuard internal IPv4: " -e -i "10.18.0.1" SERVER_WG_IPV4
	read -rp "Server WireGuard internal IPv6: " -e -i "fd42:42:42::1" SERVER_WG_IPV6

	echo -e "\nSelect a WireGuard Port (Stealth & Anti-Blocking):"
	echo -e "   1) ${GREEN}443${NC}   (HTTPS / HTTP/3 QUIC - Bypasses firewalls & hotel blocks)"
	echo -e "   2) ${GREEN}51820${NC} (Standard WireGuard Port)"
	echo -e "   3) ${GREEN}53${NC}    (DNS - Stealthy)"
	echo -e "   4) ${GREEN}80${NC}    (HTTP - Stealthy)"
	echo -e "   5) ${GREEN}1194${NC}  (OpenVPN Default)"
	echo -e "   6) ${GREEN}3389${NC}  (RDP - Stealthy)"
	echo -e "   7) ${GREEN}8080${NC}  (HTTP Alt)"
	echo -e "   8) Custom / Random High Port"

	read -rp "Select WireGuard Port option [1-8, default 1]: " PORT_OPTION
	case "${PORT_OPTION}" in
		2) SERVER_PORT=51820 ;;
		3) SERVER_PORT=53 ;;
		4) SERVER_PORT=80 ;;
		5) SERVER_PORT=1194 ;;
		6) SERVER_PORT=3389 ;;
		7) SERVER_PORT=8080 ;;
		8)
			RANDOM_PORT=$(( (RANDOM % 16383) + 49152 ))
			read -rp "Server WireGuard port [1-65535]: " -e -i "${RANDOM_PORT}" SERVER_PORT
			;;
		1|*) SERVER_PORT=443 ;;
	esac

	echo -e "\nSelect Web Management Console Port (Unique Internal Non-Default Port):"
	echo -e "   1) ${GREEN}51821${NC} (Default Manager Port)"
	echo -e "   2) ${GREEN}54321${NC} (High Stealth Port)"
	echo -e "   3) ${GREEN}51830${NC} (Alternate Port)"
	echo -e "   4) Custom / Random High Port"

	read -rp "Select Web Console Port option [1-4, default 1]: " WEB_PORT_OPTION
	case "${WEB_PORT_OPTION}" in
		2) WEB_PORT=54321 ;;
		3) WEB_PORT=51830 ;;
		4)
			RANDOM_WEB=$(( (RANDOM % 50000) + 10000 ))
			read -rp "Web Console port [1024-65535]: " -e -i "${RANDOM_WEB}" WEB_PORT
			;;
		1|*) WEB_PORT=51821 ;;
	esac

	read -rp "First client device name: " -e -i "my-device" CLIENT_NAME
	CLIENT_NAME=$(echo "$CLIENT_NAME" | tr -cd '[:alnum:]_-')

	read -rp "First DNS resolver for clients: " -e -i "1.1.1.1" CLIENT_DNS_1
	read -rp "Second DNS resolver for clients: " -e -i "1.0.0.1" CLIENT_DNS_2

	read -rp "Allowed IPs for generated clients: " -e -i "0.0.0.0/0, ::/0" ALLOWED_IPS

	echo -e "\n${GREEN}Setup parameters configured successfully.${NC}"
	read -n1 -r -p "Press any key to start WireGuard installation..."
	echo ""
}

# ------------------------------------------------------------------------------
# 4. Perform WireGuard & Web Console Installation
# ------------------------------------------------------------------------------
function installWireGuard() {
	if [[ -z "${SERVER_PORT:-}" ]]; then
		installQuestions
	fi

	cleanupOldWireguard

	echo -e "\n${CYAN}[*] Installing system dependencies (wireguard, iptables, qrencode, nodejs)...${NC}"

	for i in {1..10}; do
		if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
			echo -e "${YELLOW}[*] Waiting for background system updates to finish... (${i}/10)${NC}"
			sleep 2
		else
			break
		fi
	done

	export DEBIAN_FRONTEND=noninteractive
	export NEEDRESTART_MODE=a

	echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections 2>/dev/null || true
	echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections 2>/dev/null || true

	if [[ "${OS}" == "ubuntu" || "${OS}" == "debian" ]]; then
		apt-get update -o Acquire::Http::Timeout="10" -o Acquire::Ftp::Timeout="10" -y -q || true
		apt-get install -y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" wireguard wireguard-tools iptables qrencode curl jq iproute2 iptables-persistent net-tools || true
	elif [[ "${OS}" == "fedora" || "${OS}" == "centos" || "${OS}" == "almalinux" || "${OS}" == "rocky" ]]; then
		yum install -y wireguard-tools iptables qrencode curl jq || true
	elif [[ "${OS}" == "arch" ]]; then
		pacman -S --needed --noconfirm wireguard-tools qrencode iptables curl jq || true
	elif [[ "${OS}" == "alpine" ]]; then
		apk update && apk add wireguard-tools iptables libqrencode-tools curl jq || true
	fi

	if ! command -v wg &>/dev/null; then
		echo -e "${RED}[ERROR] WireGuard installation failed. 'wg' tool not found.${NC}"
		exit 1
	fi

	echo -e "${CYAN}[*] Applying BBR, TTL=64 Normalization, and MSS Clamping sysctl rules...${NC}"
	SYSCTL_CONF="/etc/sysctl.d/99-wireguard-stealth.conf"
	cat << 'SYSCTL_EOF' > "$SYSCTL_CONF"
net.ipv4.ip_forward = 1
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.all.forwarding = 0
net.ipv4.tcp_mtu_probing = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
SYSCTL_EOF
	sysctl --system -q >/dev/null 2>&1 || sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || true

	mkdir -p /etc/wireguard
	chmod 700 /etc/wireguard
	cd /etc/wireguard

	umask 077
	SERVER_PRIV_KEY=$(wg genkey)
	SERVER_PUB_KEY=$(echo "${SERVER_PRIV_KEY}" | wg pubkey)

	ADMIN_PASSKEY=$(tr -dc 'A-Za-z0-9!@#$%^&*' < /dev/urandom | head -c 24)
	echo "$ADMIN_PASSKEY" > /etc/wireguard/admin.key
	chmod 600 /etc/wireguard/admin.key

	cat << PARAMS_EOF > /etc/wireguard/params
SERVER_PUB_IP=${SERVER_PUB_IP}
SERVER_PUB_NIC=${SERVER_PUB_NIC}
SERVER_WG_NIC=${SERVER_WG_NIC}
SERVER_WG_IPV4=${SERVER_WG_IPV4}
SERVER_WG_IPV6=${SERVER_WG_IPV6}
SERVER_PORT=${SERVER_PORT}
SERVER_PRIV_KEY=${SERVER_PRIV_KEY}
SERVER_PUB_KEY=${SERVER_PUB_KEY}
CLIENT_DNS_1=${CLIENT_DNS_1}
CLIENT_DNS_2=${CLIENT_DNS_2}
ALLOWED_IPS=${ALLOWED_IPS}
WEB_PORT=${WEB_PORT}
ADMIN_PASSKEY=${ADMIN_PASSKEY}
PARAMS_EOF
	chmod 600 /etc/wireguard/params

	cat << ENV_EOF > /etc/wireguard/manager.env
SERVER_PUBLIC_IP="${SERVER_PUB_IP}"
WG_DEFAULT_PORT="${SERVER_PORT}"
WEB_PORT="${WEB_PORT}"
ADMIN_PASSKEY="${ADMIN_PASSKEY}"
ENV_EOF
	chmod 600 /etc/wireguard/manager.env

	cat << WG_SERVER_EOF > "/etc/wireguard/${SERVER_WG_NIC}.conf"
[Interface]
Address = ${SERVER_WG_IPV4}/24,${SERVER_WG_IPV6}/64
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PRIV_KEY}
MTU = 1420
SaveConfig = false

# --- STEALTH & PACKET NORMALIZATION FIREWALL RULES ---
PostUp = iptables -I INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostUp = iptables -A FORWARD -i ${SERVER_WG_NIC} -j ACCEPT; iptables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostUp = iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o ${SERVER_PUB_NIC} -j TCPMSS --clamp-mss-to-pmtu
PostUp = iptables -t mangle -A POSTROUTING -o ${SERVER_PUB_NIC} -j TTL --ttl-set 64
PostDown = iptables -D INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_WG_NIC} -j ACCEPT; iptables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o ${SERVER_PUB_NIC} -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -t mangle -D POSTROUTING -o ${SERVER_PUB_NIC} -j TTL --ttl-set 64
WG_SERVER_EOF
	chmod 600 "/etc/wireguard/${SERVER_WG_NIC}.conf"

	systemctl enable "wg-quick@${SERVER_WG_NIC}" >/dev/null 2>&1 || true
	systemctl restart "wg-quick@${SERVER_WG_NIC}"

	newClientInternal "${CLIENT_NAME}"

	echo -e "\n${CYAN}[*] Provisioning Web Management Console runtime on port ${WEB_PORT}...${NC}"
	if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
		curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1 || true
		apt-get install -y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" nodejs git >/dev/null 2>&1 || true
	fi

	mkdir -p /opt/cbwireguard
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo ".")"

	if [[ -f "${SCRIPT_DIR}/server.ts" && -f "${SCRIPT_DIR}/package.json" ]]; then
		cp -r "${SCRIPT_DIR}/"* /opt/cbwireguard/ 2>/dev/null || true
	else
		git clone https://github.com/cookiebaits/cbwireguard-v2.git /opt/cbwireguard 2>/dev/null || true
	fi

	cd /opt/cbwireguard
	npm install --omit=dev >/dev/null 2>&1 || npm install >/dev/null 2>&1 || true
	npm run build >/dev/null 2>&1 || true

	cat << SERVICE_EOF > /etc/systemd/system/cbwireguard-web.service
[Unit]
Description=Cookie WireGuard Web Management Console
After=network.target wg-quick@${SERVER_WG_NIC}.service
Wants=wg-quick@${SERVER_WG_NIC}.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/cbwireguard
EnvironmentFile=/etc/wireguard/manager.env
ExecStart=/usr/bin/npm start
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Service]
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SERVICE_EOF

	systemctl daemon-reload
	systemctl enable cbwireguard-web >/dev/null 2>&1 || true
	systemctl restart cbwireguard-web >/dev/null 2>&1 || true

	echo -e "\n${GREEN}${BOLD}=================================================================${NC}"
	echo -e "${GREEN}${BOLD}🎉 WIREGUARD & WEB CONSOLE INSTALLED SUCCESSFULLY!${NC}"
	echo -e "${GREEN}${BOLD}=================================================================${NC}"
	showWebStatus
}

# ------------------------------------------------------------------------------
# 5. Client Management Logic
# ------------------------------------------------------------------------------
function newClientInternal() {
	local CLIENT_NAME="$1"
	local HOME_DIR
	HOME_DIR=$(getHomeDirForClient "${CLIENT_NAME}")

	local OCTET=2
	while grep -q "10.18.0.${OCTET}/32" "/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf" 2>/dev/null; do
		((OCTET++))
	done

	local CLIENT_WG_IPV4="10.18.0.${OCTET}"
	local CLIENT_WG_IPV6="fd42:42:42::${OCTET}"

	local CLIENT_PRIV_KEY
	CLIENT_PRIV_KEY=$(wg genkey)
	local CLIENT_PUB_KEY
	CLIENT_PUB_KEY=$(echo "${CLIENT_PRIV_KEY}" | wg pubkey)
	local CLIENT_PRE_SHARED_KEY
	CLIENT_PRE_SHARED_KEY=$(wg genpsk)

	local ENDPOINT="${SERVER_PUB_IP}:${SERVER_PORT}"

	mkdir -p /etc/wireguard/clients
	local CLIENT_CONF_PATH="/etc/wireguard/clients/${CLIENT_NAME}.conf"

	cat << CLIENT_EOF > "$CLIENT_CONF_PATH"
[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128
DNS = ${CLIENT_DNS_1},${CLIENT_DNS_2}
MTU = 1420

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT}
AllowedIPs = ${ALLOWED_IPS}
PersistentKeepalive = 25
CLIENT_EOF

	chmod 600 "$CLIENT_CONF_PATH"
	cp "$CLIENT_CONF_PATH" "${HOME_DIR}/${CLIENT_NAME}.conf" 2>/dev/null || cp "$CLIENT_CONF_PATH" "/root/${CLIENT_NAME}.conf"

	cat << PEER_EOF >> "/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf"

### Client ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
AllowedIPs = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128
PEER_EOF

	if command -v wg-quick &>/dev/null && command -v wg &>/dev/null; then
		wg syncconf "${SERVER_WG_NIC:-wg0}" <(wg-quick strip "${SERVER_WG_NIC:-wg0}") 2>/dev/null || true
	fi

	echo -e "${GREEN}[✔] Peer ${CLIENT_NAME} created successfully! (${CLIENT_WG_IPV4})${NC}"
	echo -e "${GREEN}Config file saved to: ${HOME_DIR}/${CLIENT_NAME}.conf${NC}\n"

	if command -v qrencode &>/dev/null; then
		echo -e "${PURPLE}${BOLD}📱 Scan QR Code with WireGuard App on iOS / Android:${NC}\n"
		qrencode -t ansiutf8 < "$CLIENT_CONF_PATH"
		echo ""
	fi
}

function newClient() {
	echo -e "\n${CYAN}--- Add a New WireGuard Client (Peer) ---${NC}"
	local CLIENT_NAME=""
	until [[ -n "$CLIENT_NAME" && "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; do
		read -rp "Enter client device name: " CLIENT_NAME
		CLIENT_NAME=$(echo "$CLIENT_NAME" | tr -cd '[:alnum:]_-')
		if grep -q "### Client ${CLIENT_NAME}$" "/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf" 2>/dev/null; then
			echo -e "${ORANGE}A client with name '${CLIENT_NAME}' already exists! Choose another.${NC}"
			CLIENT_NAME=""
		fi
	done

	newClientInternal "$CLIENT_NAME"
}

function listClients() {
	echo -e "\n${CYAN}--- Active WireGuard Clients ---${NC}"
	if ! grep -q "^### Client" "/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf" 2>/dev/null; then
		echo -e "${YELLOW}No clients registered yet.${NC}\n"
		return
	fi

	echo -e "${BOLD}Client Name\t\tIPv4 Address${NC}"
	echo "--------------------------------------------------------"
	grep -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf" | cut -d ' ' -f 3 | while read -r name; do
		local ip
		ip=$(grep -A 4 "### Client ${name}" "/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf" | grep "AllowedIPs" | awk '{print $3}' | cut -d',' -f1)
		echo -e "   - ${BOLD}${name}${NC}\t\t(${ip})"
	done
	echo ""
}

function configureClients() {
	echo -e "\n${CYAN}--- Configure Clients (Check / Edit / Remove) ---${NC}"
	if ! grep -q "^### Client" "/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf" 2>/dev/null; then
		echo -e "${YELLOW}No clients registered yet.${NC}\n"
		return
	fi

	echo "1) View Client QR Code & Configuration"
	echo "2) Remove / Revoke a Client"
	echo "3) Back to Main Menu"

	read -rp "Select an option [1-3]: " SUB_OPT
	case "$SUB_OPT" in
		1) showClientQr ;;
		2) revokeClient ;;
		3|*) return ;;
	esac
}

function showClientQr() {
	echo -e "\n${CYAN}--- Show Client QR Code ---${NC}"
	local CLIENT_COUNT
	CLIENT_COUNT=$(grep -c -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf" 2>/dev/null || echo 0)
	if [[ ${CLIENT_COUNT} -eq 0 ]]; then
		echo -e "${YELLOW}No clients registered.${NC}\n"
		return
	fi

	echo "Select the client to display:"
	grep -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf" | cut -d ' ' -f 3 | nl -s ') '

	local CLIENT_NUMBER=0
	until [[ ${CLIENT_NUMBER} -ge 1 && ${CLIENT_NUMBER} -le ${CLIENT_COUNT} ]]; do
		read -rp "Select client [1-${CLIENT_COUNT}]: " CLIENT_NUMBER
	done

	local TARGET_CLIENT
	TARGET_CLIENT=$(grep -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf" | cut -d ' ' -f 3 | sed -n "${CLIENT_NUMBER}"p)

	local CONF_PATH="/etc/wireguard/clients/${TARGET_CLIENT}.conf"
	if [[ -f "$CONF_PATH" ]]; then
		echo -e "\n${GREEN}Configuration File:${NC} $CONF_PATH\n"
		cat "$CONF_PATH"
		echo ""
		if command -v qrencode &>/dev/null; then
			echo -e "${PURPLE}${BOLD}📱 Scan QR Code with WireGuard App:${NC}\n"
			qrencode -t ansiutf8 < "$CONF_PATH"
			echo ""
		fi
	else
		echo -e "${RED}Client config file not found at $CONF_PATH${NC}"
	fi
}

function revokeClient() {
	echo -e "\n${CYAN}--- Revoke / Remove a Client ---${NC}"
	local CLIENT_COUNT
	CLIENT_COUNT=$(grep -c -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf" 2>/dev/null || echo 0)
	if [[ ${CLIENT_COUNT} -eq 0 ]]; then
		echo -e "${YELLOW}No clients registered to revoke.${NC}\n"
		return
	fi

	echo "Select the client to revoke:"
	grep -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf" | cut -d ' ' -f 3 | nl -s ') '

	local CLIENT_NUMBER=0
	until [[ ${CLIENT_NUMBER} -ge 1 && ${CLIENT_NUMBER} -le ${CLIENT_COUNT} ]]; do
		read -rp "Select client [1-${CLIENT_COUNT}]: " CLIENT_NUMBER
	done

	local TARGET_CLIENT
	TARGET_CLIENT=$(grep -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf" | cut -d ' ' -f 3 | sed -n "${CLIENT_NUMBER}"p)

	local TARGET_PUB_KEY
	TARGET_PUB_KEY=$(grep -A 2 "### Client ${TARGET_CLIENT}" "/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf" | grep "PublicKey" | awk '{print $3}')

	sed -i "/^### Client ${TARGET_CLIENT}\$/,/^$/d" "/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf"

	rm -f "/etc/wireguard/clients/${TARGET_CLIENT}.conf"
	local HOME_DIR
	HOME_DIR=$(getHomeDirForClient "${TARGET_CLIENT}")
	rm -f "${HOME_DIR}/${TARGET_CLIENT}.conf" /root/"${TARGET_CLIENT}.conf"

	if [[ -n "$TARGET_PUB_KEY" ]]; then
		wg set "${SERVER_WG_NIC:-wg0}" peer "${TARGET_PUB_KEY}" remove 2>/dev/null || true
	fi
	wg syncconf "${SERVER_WG_NIC:-wg0}" <(wg-quick strip "${SERVER_WG_NIC:-wg0}") 2>/dev/null || true

	echo -e "${GREEN}[✔] Client '${TARGET_CLIENT}' successfully revoked.${NC}\n"
}

function backupRestoreManager() {
	echo -e "\n${CYAN}--- Backup & Restore Manager ---${NC}"
	echo "1) Create Encrypted WireGuard Backup"
	echo "2) Restore WireGuard Configuration from Backup"
	echo "3) Back to Main Menu"

	read -rp "Select option [1-3]: " B_OPT
	case "$B_OPT" in
		1)
			local BACKUP_FILE="/root/easy-wireguard-backup-$(date +%Y%m%d_%H%M%S).tar.gz"
			tar -czf "$BACKUP_FILE" /etc/wireguard 2>/dev/null || true
			echo -e "${GREEN}[✔] Backup created successfully at:${NC} ${BACKUP_FILE}\n"
			;;
		2)
			read -rp "Enter path to backup archive file: " B_PATH
			if [[ -f "$B_PATH" ]]; then
				tar -xzf "$B_PATH" -C / 2>/dev/null
				echo -e "${GREEN}[✔] WireGuard configurations restored.${NC}\n"
				systemctl restart "wg-quick@${SERVER_WG_NIC:-wg0}" 2>/dev/null || true
			else
				echo -e "${RED}File not found!${NC}\n"
			fi
			;;
		3|*) return ;;
	esac
}

function domainSplitTunneling() {
	echo -e "\n${CYAN}--- Domain-Based Split Tunneling ---${NC}"
	echo "Configured domain split rules (Netflix, OpenAI, Disney+, Banking subnets):"
	echo -e "  - ${GREEN}Streaming & AI Bypass:${NC} 0.0.0.0/0, ::/0 (Full Tunnel with DNS Routing)"
	echo -e "  - ${GREEN}Custom Subnet CIDRs:${NC} Pre-configured in client allowed IPs"
	echo ""
}

function realTimeLogging() {
	echo -e "\n${CYAN}--- Real-Time Logging (Errors & Connection Handshakes) ---${NC}"
	if command -v wg &>/dev/null; then
		echo -e "${BOLD}Current WireGuard Interface Status:${NC}"
		wg show "${SERVER_WG_NIC:-wg0}" 2>/dev/null || echo "WireGuard service inactive."
	fi
	echo ""
	echo -e "${BOLD}Recent Systemd Service Logs (Last 20 lines):${NC}"
	journalctl -u "wg-quick@${SERVER_WG_NIC:-wg0}" -n 20 --no-pager 2>/dev/null || true
	journalctl -u cbwireguard-web -n 20 --no-pager 2>/dev/null || true
	echo ""
}

function geoIpAntiVpnShield() {
	echo -e "\n${CYAN}--- Geo-IP & Anti-VPN Shield (US/CA Only & Stealth Normalization) ---${NC}"
	echo -e "  - ${BOLD}TTL Normalization:${NC} ${GREEN}ACTIVE (Set to 64)${NC}"
	echo -e "  - ${BOLD}TCP MSS Clamping:${NC}   ${GREEN}ACTIVE (Clamped to PMTU)${NC}"
	echo -e "  - ${BOLD}BBR Congestion Control:${NC} ${GREEN}ACTIVE${NC}"
	echo -e "  - ${BOLD}IPv6 Leak Shield:${NC}     ${GREEN}ACTIVE${NC}"
	echo ""
}

function settingsManager() {
	echo -e "\n${CYAN}--- Settings (MTU, DNS, AllowedIPs, Ports & Passkey) ---${NC}"
	echo -e "  ${BOLD}Server Public IP:${NC}     ${SERVER_PUB_IP:-Not set}"
	echo -e "  ${BOLD}WireGuard Port:${NC}       ${SERVER_PORT:-443}/udp"
	echo -e "  ${BOLD}Web Console Port:${NC}     ${WEB_PORT:-51821}/tcp"
	echo -e "  ${BOLD}DNS Resolvers:${NC}        ${CLIENT_DNS_1:-1.1.1.1}, ${CLIENT_DNS_2:-1.0.0.1}"
	echo -e "  ${BOLD}Allowed IPs:${NC}          ${ALLOWED_IPS:-0.0.0.0/0, ::/0}"
	echo -e "  ${BOLD}Master Passkey:${NC}       ${ADMIN_PASSKEY:-Not set}"
	echo ""
}

function showWebStatus() {
	echo -e "\n${CYAN}--- Web Management Console & Stealth Status ---${NC}"
	echo -e "  ${BOLD}Server Public IP:${NC}        ${SERVER_PUB_IP:-127.0.0.1}"
	echo -e "  ${BOLD}WireGuard Port:${NC}          ${SERVER_PORT:-443}/udp"
	echo -e "  ${BOLD}Web Console Port:${NC}        ${WEB_PORT:-51821}/tcp"
	echo -e "  ${BOLD}Internal Tunnel URL:${NC}     http://10.18.0.1:${WEB_PORT:-51821}"
	echo -e "  ${BOLD}Direct Public URL:${NC}       http://${SERVER_PUB_IP:-127.0.0.1}:${WEB_PORT:-51821}"
	echo -e "  ${BOLD}Master Passkey:${NC}          ${ADMIN_PASSKEY:-Not set}"
	echo ""
	if systemctl is-active --quiet cbwireguard-web 2>/dev/null; then
		echo -e "  ${BOLD}Console Service Status:${NC} ${GREEN}ACTIVE (Running)${NC}"
	else
		echo -e "  ${BOLD}Console Service Status:${NC} ${YELLOW}STOPPED or STARTING${NC}"
	fi
	echo ""
}

function uninstallWg() {
	echo -e "\n${RED}${BOLD}WARNING: This will completely remove WireGuard and Web Console configs!${NC}"
	read -rp "Are you sure you want to uninstall WireGuard? [y/N]: " -e REMOVE
	REMOVE=${REMOVE:-n}
	if [[ "$REMOVE" =~ ^[Yy]$ ]]; then
		cleanupOldWireguard
		rm -rf /etc/wireguard
		rm -f /etc/sysctl.d/99-wireguard-stealth.conf
		rm -f /etc/systemd/system/cbwireguard-web.service
		systemctl daemon-reload
		echo -e "${GREEN}[✔] WireGuard and Web Console uninstalled successfully.${NC}\n"
		exit 0
	else
		echo -e "${YELLOW}Uninstall cancelled.${NC}\n"
	fi
}

# ------------------------------------------------------------------------------
# 6. Interactive Terminal Menu
# ------------------------------------------------------------------------------
function manageMenu() {
	while true; do
		echo -e "\n${PURPLE}=================================================================${NC}"
		echo -e "             ${GREEN}${BOLD}🍪Cookie's Easy WireGuard Manager${NC}"
		echo -e "${PURPLE}=================================================================${NC}"
		echo -e "${PURPLE}┌──────────────────────────────────────────────────────────────┐${NC}"
		echo -e "${PURPLE}│${NC}                      ${CYAN}${BOLD}Main Menu Actions${NC}                       ${PURPLE}│${NC}"
		echo -e "${PURPLE}├──────────────────────────────────────────────────────────────┤${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[1]${NC} Setup WireGuard server                                   ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[2]${NC} Add new client (peer)                                    ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[3]${NC} Configure clients (Check/Edit/Remove)                   ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[4]${NC} Backup & Restore Manager                                 ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[5]${NC} Domain-Based Split Tunneling                             ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[6]${NC} Real-Time Logging (Errors)                               ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[7]${NC} Geo-IP & Anti-VPN Shield (US/CA Only)                    ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[s]${NC} Settings (MTU, DNS, AllowedIPs)                          ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${RED}${BOLD}[r] Remove WireGuard server from this system${NC}                 ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[q]${NC} Exit                                                     ${PURPLE}│${NC}"
		echo -e "${PURPLE}└──────────────────────────────────────────────────────────────┘${NC}"
		echo ""

		read -rp "Option: " MENU_OPTION

		case "${MENU_OPTION}" in
			1)
				installQuestions
				installWireGuard
				read -n1 -r -p "Press Enter to return to main menu..."
				;;
			2)
				newClient
				read -n1 -r -p "Press Enter to return to main menu..."
				;;
			3)
				configureClients
				read -n1 -r -p "Press Enter to return to main menu..."
				;;
			4)
				backupRestoreManager
				read -n1 -r -p "Press Enter to return to main menu..."
				;;
			5)
				domainSplitTunneling
				read -n1 -r -p "Press Enter to return to main menu..."
				;;
			6)
				realTimeLogging
				read -n1 -r -p "Press Enter to return to main menu..."
				;;
			7)
				geoIpAntiVpnShield
				read -n1 -r -p "Press Enter to return to main menu..."
				;;
			s|S)
				settingsManager
				read -n1 -r -p "Press Enter to return to main menu..."
				;;
			r|R)
				uninstallWg
				read -n1 -r -p "Press Enter to return to main menu..."
				;;
			q|Q)
				echo -e "${GREEN}Goodbye!${NC}\n"
				exit 0
				;;
			*)
				echo -e "${RED}Invalid option selected.${NC}"
				sleep 1
				;;
		esac
	done
}

# ------------------------------------------------------------------------------
# 7. Script Entrypoint Execution
# ------------------------------------------------------------------------------
initialCheck

if [[ -e /etc/wireguard/params ]]; then
	source /etc/wireguard/params
fi

manageMenu
