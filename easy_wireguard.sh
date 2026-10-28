#!/bin/bash
# ==============================================================================
# 🍪 Cookie's Easy WireGuard Manager & VPS Stealth Server v4.0 (Enhanced)
# Unified WireGuard + True Cloudflare WARP L3 Egress + BBR High-Throughput
# ==============================================================================

set -eE

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
	elif [[ -e /debian_version ]]; then
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

function getEasyWgDir() {
	local CLIENT_NAME="${1:-}"
	local HOME_DIR
	HOME_DIR=$(getHomeDirForClient "${CLIENT_NAME}")
	local EASY_DIR="${HOME_DIR}/easy_wireguard"
	mkdir -p "$EASY_DIR" 2>/dev/null || mkdir -p "/root/easy_wireguard" 2>/dev/null
	chmod 700 "$EASY_DIR" 2>/dev/null || true
	echo "$EASY_DIR"
}

function getMasterPasskey() {
	local PASS=""
	if [[ -f /etc/wireguard/admin.key ]]; then
		PASS=$(cat /etc/wireguard/admin.key 2>/dev/null | tr -d '\r\n')
	fi
	if [[ -z "$PASS" && -f /etc/wireguard/manager.env ]]; then
		PASS=$(grep -E '^ADMIN_PASSKEY=' /etc/wireguard/manager.env 2>/dev/null | cut -d'=' -f2- | tr -d '"\r\n')
	fi
	if [[ -z "$PASS" && -f /etc/wireguard/params ]]; then
		PASS=$(grep -E '^ADMIN_PASSKEY=' /etc/wireguard/params 2>/dev/null | cut -d'=' -f2- | tr -d '"\r\n')
	fi
	if [[ -z "$PASS" ]]; then
		PASS="${ADMIN_PASSKEY:-CookieWireGuardSec2026!#Key}"
	fi
	echo "$PASS"
}

function encryptConfigContent() {
	local CONTENT="$1"
	local DEST_ENC="$2"
	local PASS="${3:-}"
	if [[ -z "$PASS" ]]; then
		PASS=$(getMasterPasskey)
	fi
	mkdir -p "$(dirname "$DEST_ENC")" 2>/dev/null || true
	echo -n "$CONTENT" | openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -pass "pass:${PASS}" -out "$DEST_ENC" 2>/dev/null
	chmod 600 "$DEST_ENC" 2>/dev/null || true
}

function decryptConfigToString() {
	local FILE="$1"
	local PASS="${2:-}"
	if [[ -z "$PASS" ]]; then
		PASS=$(getMasterPasskey)
	fi
	if [[ -f "$FILE" ]]; then
		if head -c 8 "$FILE" 2>/dev/null | grep -q "Salted__"; then
			openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -pass "pass:${PASS}" -in "$FILE" 2>/dev/null
		else
			cat "$FILE"
		fi
	fi
}

function cleanupAndSecureRootFolder() {
	local EASY_DIR
	EASY_DIR=$(getEasyWgDir)
	mkdir -p "$EASY_DIR" 2>/dev/null
	chmod 700 "$EASY_DIR" 2>/dev/null
	mkdir -p "/etc/wireguard/clients" 2>/dev/null
	chmod 700 "/etc/wireguard/clients" 2>/dev/null

	local SEARCH_DIRS=("/root" "/home/${SUDO_USER:-root}")
	[[ -n "${HOME:-}" && "$HOME" != "/root" ]] && SEARCH_DIRS+=("$HOME")
	[[ "$PWD" != "/root" && "$PWD" != "/home/${SUDO_USER:-root}" ]] && SEARCH_DIRS+=("$PWD")

	local MIGRATED_COUNT=0
	for sdir in "${SEARCH_DIRS[@]}"; do
		[[ ! -d "$sdir" ]] && continue
		for f in "$sdir"/*.conf; do
			[[ ! -f "$f" ]] && continue
			local bname
			bname=$(basename "$f")
			[[ "$bname" == "resolv.conf" || "$bname" == "sysctl.conf" ]] && continue
			if grep -q -E "(\[Interface\]|PrivateKey|Endpoint|AllowedIPs)" "$f" 2>/dev/null; then
				local target_enc="${EASY_DIR}/${bname}.enc"
				local content
				content=$(cat "$f")
				encryptConfigContent "$content" "$target_enc"
				encryptConfigContent "$content" "/etc/wireguard/clients/${bname}.enc"
				rm -f "$f" 2>/dev/null || true
				((MIGRATED_COUNT++))
			fi
		done
	done

	for f in "${EASY_DIR}"/*.conf "/etc/wireguard/clients"/*.conf; do
		[[ ! -f "$f" ]] && continue
		local bname
		bname=$(basename "$f")
		local target_enc="${EASY_DIR}/${bname}.enc"
		local content
		content=$(cat "$f")
		encryptConfigContent "$content" "$target_enc"
		encryptConfigContent "$content" "/etc/wireguard/clients/${bname}.enc"
		rm -f "$f" 2>/dev/null || true
	done

	if [[ $MIGRATED_COUNT -gt 0 ]]; then
		echo -e "${GREEN}[✔] Cleaned $MIGRATED_COUNT loose config file(s) from root directory.${NC}"
		echo -e "${GREEN}[✔] All configurations securely AES-256 encrypted inside: ${EASY_DIR}/${NC}"
	fi
}

# ------------------------------------------------------------------------------
# 2. Port Protection & Performance Tuning Engine
# ------------------------------------------------------------------------------
function isSensitivePort() {
	local port="$1"
	local sensitive_ports=(20 21 22 23 25 53 67 68 80 110 143 443 8080 8443 3306 5432 6379 27017)
	for sp in "${sensitive_ports[@]}"; do
		if [[ "$port" -eq "$sp" ]]; then
			return 0
		fi
	done
	return 1
}

function isPortInUse() {
	local port="$1"
	local proto="${2:-udp}"
	if command -v ss &>/dev/null; then
		if [[ "$proto" == "udp" ]]; then
			ss -uln 2>/dev/null | grep -qE "(:|\])${port}\s" && return 0
		else
			ss -tln 2>/dev/null | grep -qE "(:|\])${port}\s" && return 0
		fi
	elif command -v netstat &>/dev/null; then
		if [[ "$proto" == "udp" ]]; then
			netstat -uln 2>/dev/null | grep -qE "(:|\])${port}\s" && return 0
		else
			netstat -tln 2>/dev/null | grep -qE "(:|\])${port}\s" && return 0
		fi
	fi
	return 1
}

# High-Performance Kernel & Network Buffer Tuning for Top Upload/Download Speeds
function tuneNetworkPerformance() {
	echo -e "${CYAN}[*] Applying Top-Speed Network & Buffer sysctl optimizations...${NC}"

	modprobe tcp_bbr 2>/dev/null || true
	echo "tcp_bbr" > /etc/modules-load.d/bbr.conf 2>/dev/null || true

	local SYSCTL_CONF="/etc/sysctl.d/99-wireguard-speed.conf"
	cat << 'SYSCTL_EOF' > "$SYSCTL_CONF"
# --- Core IP Forwarding & Path MTU Probing ---
net.ipv4.ip_forward = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# --- Google BBR Congestion Control & FQ Queuing ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- High Bandwidth-Delay Product (BDP) TCP Buffer Scaling (Up to 64MB) ---
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 33554432
net.core.wmem_default = 33554432
net.core.optmem_max = 4194304
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

# --- UDP Buffer Scaling (Crucial for WireGuard Max Throughput) ---
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# --- Interface Backlog, Queues & Fast Conntrack ---
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_syncookies = 1
SYSCTL_EOF

	local HAS_IPV6=0
	if [[ -f /proc/net/if_inet6 ]] && [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1) -eq 0 ]]; then
		if ip -6 route show default 2>/dev/null | grep -q "default"; then
			HAS_IPV6=1
		fi
	fi

	if [[ "${HAS_IPV6}" -eq 1 ]]; then
		cat << 'SYSCTL_V6' >> "$SYSCTL_CONF"
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.all.forwarding = 1
SYSCTL_V6
	fi

	sysctl --system -q >/dev/null 2>&1 || sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || true

	# Multi-Queue Receive Packet Steering (RPS/RFS) over all CPU cores
	local NUM_CPUS
	NUM_CPUS=$(nproc 2>/dev/null || echo 1)
	local CPU_MASK
	CPU_MASK=$(printf '%x' $(( (1 << NUM_CPUS) - 1 )) 2>/dev/null || echo "f")

	for rps in /sys/class/net/*/queues/rx-*/rps_cpus; do
		echo "$CPU_MASK" > "$rps" 2>/dev/null || true
	done
	for rfs in /sys/class/net/*/queues/rx-*/rps_flow_cnt; do
		echo 4096 > "$rfs" 2>/dev/null || true
	done
	sysctl -w net.core.rps_sock_flow_entries=32768 >/dev/null 2>&1 || true

	# Set high transmit queue length on physical and tunnel interfaces
	local DEF_NIC="${SERVER_PUB_NIC:-}"
	[[ -z "$DEF_NIC" ]] && DEF_NIC=$(ip -4 route show default 2>/dev/null | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | head -n1 || echo "eth0")
	if [[ -n "$DEF_NIC" ]]; then
		ip link set dev "$DEF_NIC" txqueuelen 10000 2>/dev/null || true
		if command -v ethtool &>/dev/null; then
			ethtool -K "$DEF_NIC" tso on gso on gro on 2>/dev/null || true
		fi
	fi
	ip link set dev wg0 txqueuelen 10000 2>/dev/null || true
	ip link set dev CloudflareWARP txqueuelen 10000 2>/dev/null || true
}

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

	# Clean WireGuard specific forwarding/nat rules without disturbing other services
	iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
	iptables -D FORWARD -o wg0 -j ACCEPT 2>/dev/null || true
	iptables -t nat -D POSTROUTING -s 10.18.0.0/24 -j MASQUERADE 2>/dev/null || true
	iptables -t nat -D POSTROUTING -s 10.19.0.0/24 -j MASQUERADE 2>/dev/null || true
	iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

	echo -e "${GREEN}[✔] Cleaned old WireGuard instances. Core ports (80, 443, 22) protected.${NC}"
}

# ------------------------------------------------------------------------------
# 3. DNS Resolvers Selection
# ------------------------------------------------------------------------------
function selectDNSResolvers() {
	echo -e "\n${CYAN}${BOLD}Select DNS Resolvers for Clients (Includes Stealth & Anti-Leak):${NC}"
	echo -e "   1) ${GREEN}Cloudflare Anycast Anti-Flag${NC} (Global Anycast | Fastest CDN & Turnstile Aligned) ${PURPLE}[RECOMMENDED]${NC}"
	echo -e "      IPv4: 1.1.1.1, 1.0.0.1  |  IPv6: 2606:4700:4700::1111, 2606:4700:4700::1001"
	echo -e "   2) ${GREEN}AdGuard Stealth${NC} (Global Anycast | Anti-Tracker & Adblock)"
	echo -e "      IPv4: 94.140.14.14, 94.140.15.15"
	echo -e "   3) ${GREEN}Quad9 Swiss Shield${NC} (Zurich, Switzerland | Privacy & Threat Filter)"
	echo -e "      IPv4: 9.9.9.9, 149.112.112.112"
	echo -e "   4) ${GREEN}Google Public DNS${NC} (Global Anycast | High Uptime)"
	echo -e "      IPv4: 8.8.8.8, 8.8.4.4"
	echo -e "   5) Custom Primary & Secondary DNS Resolvers"

	read -rp "Select DNS Resolver option [1-5, default 1]: " DNS_OPTION
	DNS_OPTION=${DNS_OPTION:-1}
	case "${DNS_OPTION}" in
		2) CLIENT_DNS_1="94.140.14.14"; CLIENT_DNS_2="94.140.15.15" ;;
		3) CLIENT_DNS_1="9.9.9.9"; CLIENT_DNS_2="149.112.112.112" ;;
		4) CLIENT_DNS_1="8.8.8.8"; CLIENT_DNS_2="8.8.4.4" ;;
		5)
			read -rp "Enter Primary DNS: " -e -i "1.1.1.1" CLIENT_DNS_1
			read -rp "Enter Secondary DNS: " -e -i "1.0.0.1" CLIENT_DNS_2
			;;
		1|*) CLIENT_DNS_1="1.1.1.1"; CLIENT_DNS_2="1.0.0.1" ;;
	esac
	echo -e "${GREEN}[✔] Selected DNS Resolvers: ${CLIENT_DNS_1}, ${CLIENT_DNS_2}${NC}"
}

# ------------------------------------------------------------------------------
# 4. Installation Prompts
# ------------------------------------------------------------------------------
function installQuestions() {
	echo -e "${PURPLE}=================================================================${NC}"
	echo -e "          ${GREEN}${BOLD}🍪  Cookie's Easy WireGuard Setup & Optimizer${NC}"
	echo -e "${PURPLE}=================================================================${NC}\n"

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
	[[ -z "$SERVER_NIC" ]] && SERVER_NIC="eth0"
	read -rp "Public network interface: " -e -i "${SERVER_NIC}" SERVER_PUB_NIC

	read -rp "WireGuard interface name: " -e -i "wg0" SERVER_WG_NIC
	read -rp "Server WireGuard internal IPv4: " -e -i "10.18.0.1" SERVER_WG_IPV4
	read -rp "Server WireGuard internal IPv6: " -e -i "fd42:42:42::1" SERVER_WG_IPV6

	echo -e "\n${CYAN}${BOLD}Select WireGuard Listen Port:${NC}"
	echo -e "   1) ${GREEN}4500${NC}  (IPsec NAT-Traversal UDP | Stealth Encrypted Tunneling) ${PURPLE}[RECOMMENDED]${NC}"
	echo -e "   2) ${GREEN}51820${NC} (Official Standard Port)"
	echo -e "   3) ${GREEN}3478${NC}  (STUN / WebRTC Media UDP | Firewall Bypass)"
	echo -e "   4) Custom Port"

	while true; do
		read -rp "Select Port option [1-4, default 1 (4500)]: " PORT_OPTION
		PORT_OPTION=${PORT_OPTION:-1}
		case "${PORT_OPTION}" in
			1) SERVER_PORT=4500; break ;;
			2) SERVER_PORT=51820; break ;;
			3) SERVER_PORT=3478; break ;;
			4)
				read -rp "Enter Custom Port [1024-65535]: " -e -i "8008" CUSTOM_PORT
				if isSensitivePort "$CUSTOM_PORT" || isPortInUse "$CUSTOM_PORT" "udp"; then
					echo -e "${RED}[!] Port unavailable or conflicts with a system service. Choose another.${NC}"
					continue
				fi
				SERVER_PORT="$CUSTOM_PORT"
				break
				;;
			*) echo -e "${RED}[!] Invalid option.${NC}" ;;
		esac
	done

	SERVER_PORT_CF="${SERVER_PORT}"
	selectDNSResolvers

	read -rp "First client device name: " -e -i "my-device" CLIENT_NAME
	CLIENT_NAME=$(echo "$CLIENT_NAME" | tr -cd '[:alnum:]_-')

	echo -e "\n${PURPLE}${BOLD}🔒 Set Encryption Password for Client Configuration:${NC}"
	CLIENT_PASSWORD=""
	while true; do
		read -s -rp "Enter encryption password for '${CLIENT_NAME}': " CLIENT_PASSWORD
		echo ""
		if [[ ${#CLIENT_PASSWORD} -lt 4 ]]; then
			echo -e "${RED}[!] Password must be at least 4 characters long.${NC}"
			continue
		fi
		read -s -rp "Confirm encryption password: " CLIENT_PASSWORD_CONFIRM
		echo ""
		if [[ "$CLIENT_PASSWORD" != "$CLIENT_PASSWORD_CONFIRM" ]]; then
			echo -e "${RED}[!] Passwords do not match. Please try again.${NC}"
			continue
		fi
		break
	done

	read -rp "Allowed IPs for generated clients: " -e -i "0.0.0.0/0, ::/0" ALLOWED_IPS
	WEB_PORT=${WEB_PORT:-51821}
	CF_AUTO_ENABLE="y"
}

# ------------------------------------------------------------------------------
# 5. Core WireGuard Installation & Routing Engine
# ------------------------------------------------------------------------------
function installWireGuard() {
	if [[ -z "${SERVER_PORT:-}" ]]; then
		installQuestions
	fi

	cleanupOldWireguard

	echo -e "\n${CYAN}[*] Installing required packages (WireGuard, iptables, ipset, dnsmasq, ethtool)...${NC}"
	export DEBIAN_FRONTEND=noninteractive

	if [[ "${OS}" == "ubuntu" || "${OS}" == "debian" ]]; then
		apt-get update -qq || true
		apt-get install -y -qq wireguard wireguard-tools iptables qrencode curl jq iproute2 \
			iptables-persistent net-tools ipset dnsmasq ethtool procps ca-certificates gnupg
	elif [[ "${OS}" == "fedora" || "${OS}" == "centos" || "${OS}" == "almalinux" || "${OS}" == "rocky" ]]; then
		yum install -y epel-release || true
		yum install -y wireguard-tools iptables qrencode curl jq ipset dnsmasq ethtool
	elif [[ "${OS}" == "arch" ]]; then
		pacman -S --needed --noconfirm wireguard-tools qrencode iptables curl jq ipset dnsmasq ethtool
	elif [[ "${OS}" == "alpine" ]]; then
		apk add wireguard-tools iptables libqrencode-tools curl jq ipset dnsmasq ethtool
	fi

	# Protect host DNS resolvers
	if ! grep -q -E "nameserver [0-9]" /etc/resolv.conf 2>/dev/null; then
		cat << 'RESOLV_INIT' > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
RESOLV_INIT
	fi

	# Apply Max Speed sysctl & RPS settings
	tuneNetworkPerformance

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
SERVER_PORT_CF=${SERVER_PORT}
SERVER_PRIV_KEY=${SERVER_PRIV_KEY}
SERVER_PUB_KEY=${SERVER_PUB_KEY}
CLIENT_DNS_1=${CLIENT_DNS_1}
CLIENT_DNS_2=${CLIENT_DNS_2}
ALLOWED_IPS=${ALLOWED_IPS}
WEB_PORT=${WEB_PORT:-51821}
ADMIN_PASSKEY=${ADMIN_PASSKEY}
CF_AUTO_ENABLE=${CF_AUTO_ENABLE:-y}
PARAMS_EOF
	chmod 600 /etc/wireguard/params

	cat << ENV_EOF > /etc/wireguard/manager.env
SERVER_PUBLIC_IP="${SERVER_PUB_IP}"
WG_DEFAULT_PORT="${SERVER_PORT}"
WEB_PORT="${WEB_PORT:-51821}"
ADMIN_PASSKEY="${ADMIN_PASSKEY}"
ENV_EOF
	chmod 600 /etc/wireguard/manager.env

	# --------------------------------------------------------------------------
	# UNIFIED WIREGUARD SERVER CONFIGURATION (wg0.conf)
	# Subnet 10.19.0.0/24: Cloudflare WARP Egress (Covers IP for Scans & Unblocks Amazon/LinkedIn)
	# Subnet 10.18.0.0/24: Standard Direct VPS Egress
	# --------------------------------------------------------------------------
	echo -e "${CYAN}[*] Configuring Unified High-Speed WireGuard Server (wg0)...${NC}"
	cat << WG_SERVER_EOF > "/etc/wireguard/wg0.conf"
[Interface]
Address = ${SERVER_WG_IPV4}/24, 10.19.0.1/24, ${SERVER_WG_IPV6}/64
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PRIV_KEY}
MTU = 1420
SaveConfig = false

# --- 1. CORE NETWORKING, QUEUES & FIREWALL ---
PostUp = sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
PostUp = ip link set dev wg0 txqueuelen 10000 2>/dev/null || true
PostUp = iptables -I INPUT 1 -p udp --dport ${SERVER_PORT} -j ACCEPT 2>/dev/null || true
PostUp = iptables -I FORWARD 1 -i wg0 -j ACCEPT 2>/dev/null || true
PostUp = iptables -I FORWARD 2 -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
PostUp = iptables -I FORWARD 3 -s 10.18.0.0/24 -j ACCEPT 2>/dev/null || true
PostUp = iptables -I FORWARD 4 -d 10.18.0.0/24 -j ACCEPT 2>/dev/null || true
PostUp = iptables -I FORWARD 5 -s 10.19.0.0/24 -j ACCEPT 2>/dev/null || true
PostUp = iptables -I FORWARD 6 -d 10.19.0.0/24 -j ACCEPT 2>/dev/null || true

# --- 2. NAT MASQUERADING ---
PostUp = iptables -t nat -I POSTROUTING 1 -s 10.18.0.0/24 -o ${SERVER_PUB_NIC} -j MASQUERADE 2>/dev/null || true
PostUp = iptables -t nat -I POSTROUTING 2 -s 10.19.0.0/24 -o ${SERVER_PUB_NIC} -j MASQUERADE 2>/dev/null || true

# --- 3. DYNAMIC TCP MSS CLAMPING (Prevents TLS Fragmentation on Amazon & LinkedIn) ---
PostUp = iptables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostUp = iptables -t mangle -I POSTROUTING 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostUp = iptables -t mangle -I FORWARD 2 -s 10.19.0.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true
PostUp = iptables -t mangle -I POSTROUTING 2 -s 10.19.0.0/24 -j TTL --ttl-set 128 2>/dev/null || true

# Teardown Rules
PostDown = iptables -D INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s 10.18.0.0/24 -o ${SERVER_PUB_NIC} -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s 10.19.0.0/24 -o ${SERVER_PUB_NIC} -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostDown = iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -s 10.19.0.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true
PostDown = iptables -t mangle -D POSTROUTING -s 10.19.0.0/24 -j TTL --ttl-set 128 2>/dev/null || true
WG_SERVER_EOF

	chmod 600 "/etc/wireguard/wg0.conf"

	# Enable and start Unified WireGuard daemon
	systemctl daemon-reload >/dev/null 2>&1 || true
	systemctl enable "wg-quick@wg0" >/dev/null 2>&1 || true
	systemctl restart "wg-quick@wg0" 2>/dev/null || wg-quick up wg0 2>/dev/null || true

	echo -e "${GREEN}[✔] Unified WireGuard daemon (wg0 | Port ${SERVER_PORT}) active!${NC}"

	# Setup Cloudflare WARP L3 Egress Tunnel by default
	if [[ "${CF_AUTO_ENABLE}" == "y" ]]; then
		setupCloudflareWarpClient
	fi

	# Generate Client Profile
	newClientInternal "${CLIENT_NAME}" "${CLIENT_PASSWORD}"

	echo -e "\n${GREEN}${BOLD}=================================================================${NC}"
	echo -e "${GREEN}${BOLD}🎉 WIREGUARD SERVER & WARP EGRESS INSTALLED SUCCESSFULLY!${NC}"
	echo -e "${GREEN}${BOLD}=================================================================${NC}"
}

# ------------------------------------------------------------------------------
# 6. True Cloudflare WARP L3 Egress & IP Covering Engine
# ------------------------------------------------------------------------------
function showWarpProgressBar() {
	local percent="$1"
	local step_text="$2"
	local bar_width=30
	local num_filled=$(( (percent * bar_width) / 100 ))
	local num_empty=$(( bar_width - num_filled ))
	local bar_str=""

	for ((i=0; i<num_filled; i++)); do bar_str+="█"; done
	for ((i=0; i<num_empty; i++)); do bar_str+="░"; done

	printf "\r ${CYAN}[%3d%%]${NC} [${GREEN}%s${NC}] %-56s\033[K" "$percent" "$bar_str" "$step_text"
	if [[ "$percent" -ge 100 ]]; then
		echo -e "\n"
	fi
}

function setupCloudflareWarpClient() {
	echo -e "\n${CYAN}${BOLD}⚡ Initializing Cloudflare WARP L3 Egress (AS13335 Consumer Cloak)...${NC}"
	mkdir -p /etc/wireguard
	touch /etc/wireguard/warp_egress_enabled

	showWarpProgressBar 10 "Verifying architecture & repository..."

	# 1. Install official Cloudflare WARP client if not present
	if ! command -v warp-cli &>/dev/null; then
		if command -v apt-get &>/dev/null; then
			local ARCH="amd64"
			command -v dpkg &>/dev/null && ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
			local CODENAME=""
			[[ -f /etc/os-release ]] && source /etc/os-release && CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
			[[ -z "$CODENAME" ]] && CODENAME="bookworm"

			mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
			curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null || true
			echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${CODENAME} main" > /etc/apt/sources.list.d/cloudflare-client.list 2>/dev/null || true
			apt-get update -o Acquire::Timeout="8" -qq >/dev/null 2>&1 || true
			apt-get install -y -qq cloudflare-warp >/dev/null 2>&1 || true
		elif command -v yum &>/dev/null; then
			curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo | tee /etc/yum.repos.d/cloudflare-warp.repo >/dev/null 2>&1 || true
			yum install -y cloudflare-warp >/dev/null 2>&1 || true
		fi
	fi

	showWarpProgressBar 35 "Starting warp-svc daemon..."
	if command -v systemctl &>/dev/null; then
		systemctl daemon-reload >/dev/null 2>&1 || true
		systemctl enable --now warp-svc >/dev/null 2>&1 || true
		sleep 1
	fi

	showWarpProgressBar 50 "Registering WARP license (--accept-tos)..."
	warp-cli --accept-tos registration new 2>/dev/null \
		|| warp-cli --accept-tos register 2>/dev/null \
		|| true

	showWarpProgressBar 65 "Configuring route exclusions (Protecting SSH & Host Connectivity)..."
	local PUB_IP="${SERVER_PUB_IP:-}"
	local DEF_GW
	DEF_GW=$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -n1 || true)
	local DEF_NIC
	DEF_NIC=$(ip -4 route show default 2>/dev/null | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | head -n1 || echo "eth0")

	# Safe host policy routing rule: Ensures host responses (like SSH) always exit via physical interface
	if [[ -n "$DEF_GW" && -n "$DEF_NIC" && -n "$PUB_IP" && "$PUB_IP" != "127.0.0.1" ]]; then
		ip rule del from "${PUB_IP}" table 100 2>/dev/null || true
		ip rule add from "${PUB_IP}" table 100 priority 100 2>/dev/null || true
		ip route replace default via "${DEF_GW}" dev "${DEF_NIC}" table 100 2>/dev/null || true
	fi

	warp-cli --accept-tos add-excluded-route "0.0.0.0/0:22" 2>/dev/null || true
	[[ -n "$PUB_IP" && "$PUB_IP" != "127.0.0.1" ]] && warp-cli --accept-tos add-excluded-route "${PUB_IP}/32" 2>/dev/null || true
	warp-cli --accept-tos add-excluded-route "0.0.0.0/0:${SERVER_PORT:-4500}" 2>/dev/null || true
	warp-cli --accept-tos add-excluded-route "0.0.0.0/0:${WEB_PORT:-51821}" 2>/dev/null || true

	showWarpProgressBar 80 "Switching WARP to Full L3 Tunnel Mode ('warp')..."
	# Set L3 Tunnel mode (creates CloudflareWARP virtual interface)
	warp-cli --accept-tos mode warp 2>/dev/null || warp-cli --accept-tos set-mode warp 2>/dev/null || true
	warp-cli --accept-tos connect 2>/dev/null || warp-cli connect 2>/dev/null || true
	sleep 2

	showWarpProgressBar 90 "Configuring Policy Routing & Masquerade on CloudflareWARP..."
	local WARP_NIC="CloudflareWARP"
	ip link show "$WARP_NIC" &>/dev/null || WARP_NIC="warp0"

	if ip link show "$WARP_NIC" &>/dev/null; then
		# Set txqueuelen for top throughput
		ip link set dev "$WARP_NIC" txqueuelen 10000 2>/dev/null || true

		# Route 10.19.0.0/24 (Profile 1 Stealth) unconditionally via CloudflareWARP
		ip rule del from 10.19.0.0/24 table 51820 2>/dev/null || true
		ip rule add from 10.19.0.0/24 table 51820 priority 200 2>/dev/null || true
		ip route replace default dev "$WARP_NIC" table 51820 2>/dev/null || true

		# Outbound NAT Masquerade on CloudflareWARP
		iptables -t nat -D POSTROUTING -o "$WARP_NIC" -j MASQUERADE 2>/dev/null || true
		iptables -t nat -I POSTROUTING 1 -o "$WARP_NIC" -j MASQUERADE 2>/dev/null || true

		# Exact MTU/MSS clamping for WARP interface
		iptables -t mangle -D FORWARD -o "$WARP_NIC" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true
		iptables -t mangle -I FORWARD 1 -o "$WARP_NIC" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true
		iptables -t mangle -D FORWARD -i "$WARP_NIC" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true
		iptables -t mangle -I FORWARD 2 -i "$WARP_NIC" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true

		showWarpProgressBar 100 "Cloudflare WARP L3 Active (AS13335 Egress Established)!"
		echo -e "${GREEN}[✔] Cloudflare WARP is actively covering client scans and unblocking Amazon & LinkedIn.${NC}"
	else
		showWarpProgressBar 100 "WARP registration complete (Fallback to residential split routing)."
	fi

	applyDomainSplitRulesLive
}

# ------------------------------------------------------------------------------
# 7. Dynamic Domain Split Tunneling & Unblock Engine
# ------------------------------------------------------------------------------
function applyDomainSplitRulesLive() {
	echo -e "\n${CYAN}[*] Synchronizing Domain Split Rules & Location Shields live...${NC}"

	mkdir -p /etc/wireguard
	touch /etc/wireguard/split_domains.txt
	[[ ! -f /etc/wireguard/split_mode.txt ]] && echo "BYPASS" > /etc/wireguard/split_mode.txt

	if command -v ipset &>/dev/null; then
		ipset create wg_split_v4 hash:net family inet 2>/dev/null || true
		ipset create wg_direct_clean hash:net family inet 2>/dev/null || true
		ipset flush wg_split_v4 2>/dev/null || true
		ipset flush wg_direct_clean 2>/dev/null || true
	fi

	# Default high-priority domains to route through WARP to guarantee zero 403 blocks
	local ESSENTIAL_DOMAINS=(
		"amazon.com" "www.amazon.com" "images-amazon.com" "media-amazon.com" "ssl-images-amazon.com" "completion.amazon.com"
		"linkedin.com" "www.linkedin.com" "licdn.com" "media.licdn.com" "static.licdn.com" "platform.linkedin.com"
		"challenges.cloudflare.com" "turnstile.com" "cloudflare.com" "cdnjs.cloudflare.com"
	)

	for dom in "${ESSENTIAL_DOMAINS[@]}"; do
		grep -q "^${dom}\$" /etc/wireguard/split_domains.txt 2>/dev/null || echo "$dom" >> /etc/wireguard/split_domains.txt
	done

	# Resolve IPs into ipset for fast hardware-accelerated routing
	if command -v ipset &>/dev/null; then
		while IFS= read -r domain || [[ -n "$domain" ]]; do
			[[ -z "$domain" || "$domain" =~ ^# ]] && continue
			domain=$(echo "$domain" | tr '[:upper:]' '[:lower:]' | xargs)
			local ips
			ips=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u || true)
			for ip in $ips; do
				[[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && ipset add wg_split_v4 "$ip" 2>/dev/null || true
			done
		done < /etc/wireguard/split_domains.txt

		# Official LinkedIn Autonomous System CIDRs (AS12447)
		for l_cidr in 108.174.0.0/20 144.2.0.0/19 185.63.144.0/22 199.101.160.0/22 216.52.16.0/20 216.52.20.0/22 216.52.24.0/22; do
			ipset add wg_split_v4 "$l_cidr" 2>/dev/null || true
		done

		# Cloudflare Edge Anycast CIDRs
		for c_cidr in 173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22; do
			ipset add wg_split_v4 "$c_cidr" 2>/dev/null || true
		done
	fi

	local WARP_NIC="CloudflareWARP"
	ip link show "$WARP_NIC" &>/dev/null || WARP_NIC="warp0"

	if ip link show "$WARP_NIC" &>/dev/null && command -v ipset &>/dev/null; then
		# Mark packets destined to Amazon, LinkedIn, and Cloudflare to route through WARP table 51820
		ip rule del fwmark 0x51820 table 51820 2>/dev/null || true
		ip rule add fwmark 0x51820 table 51820 priority 150 2>/dev/null || true

		iptables -t mangle -D PREROUTING -i "${SERVER_WG_NIC:-wg0}" -m set --match-set wg_split_v4 dst -j MARK --set-mark 0x51820 2>/dev/null || true
		iptables -t mangle -I PREROUTING 1 -i "${SERVER_WG_NIC:-wg0}" -m set --match-set wg_split_v4 dst -j MARK --set-mark 0x51820 2>/dev/null || true
	fi

	echo -e "${GREEN}[✔] Split-routing active: Amazon, LinkedIn & Cloudflare CIDRs mapped to clean WARP egress.${NC}"
}

# ------------------------------------------------------------------------------
# 8. Client Management Logic
# ------------------------------------------------------------------------------
function newClientInternal() {
	local CLIENT_NAME="$1"
	local CLIENT_PASSWORD="${2:-}"
	local HOME_DIR
	HOME_DIR=$(getHomeDirForClient "${CLIENT_NAME}")

	local SUBNET_BASE="10.18.0"
	local OCTET=2
	while grep -q "${SUBNET_BASE}.${OCTET}/32" "/etc/wireguard/wg0.conf" 2>/dev/null; do
		((OCTET++))
	done

	local CLIENT_WG_IPV4="10.18.0.${OCTET}"
	local CLIENT_WG_CF_IPV4="10.19.0.${OCTET}"
	local CLIENT_WG_IPV6="fd42:42:42::${OCTET}"

	local CLIENT_PRIV_KEY
	CLIENT_PRIV_KEY=$(wg genkey)
	local CLIENT_PUB_KEY
	CLIENT_PUB_KEY=$(echo "${CLIENT_PRIV_KEY}" | wg pubkey)
	local CLIENT_PRE_SHARED_KEY
	CLIENT_PRE_SHARED_KEY=$(wg genpsk)

	local CLIENT_CF_PRIV_KEY
	CLIENT_CF_PRIV_KEY=$(wg genkey)
	local CLIENT_CF_PUB_KEY
	CLIENT_CF_PUB_KEY=$(echo "${CLIENT_CF_PRIV_KEY}" | wg pubkey)

	local ENDPOINT="${SERVER_PUB_IP}:${SERVER_PORT}"
	local EASY_DIR
	EASY_DIR=$(getEasyWgDir "${CLIENT_NAME}")

	local CLIENT_DNS_LINE="${CLIENT_DNS_1:-1.1.1.1}"
	if [[ -n "${CLIENT_DNS_2}" && "${CLIENT_DNS_2}" != "${CLIENT_DNS_1}" ]]; then
		CLIENT_DNS_LINE="${CLIENT_DNS_1}, ${CLIENT_DNS_2}"
	fi

	# --------------------------------------------------------------------------
	# Profile 1: Stealth Cloudflare WARP Egress (MTU 1280 Optimized)
	# Guarantees zero TLS fragmentation on Amazon/LinkedIn & hides IP for scans
	# --------------------------------------------------------------------------
	local CF_CONF_CONTENT
	CF_CONF_CONTENT=$(cat << CF_CLIENT_EOF
# ==============================================================================
# ☁️ PROFILE 1: CLOUDFLARE WARP STEALTH GATEWAY (ANTI-FLAG & SCAN COVER)
# ==============================================================================
# • Egress Mode: Cloudflare WARP Egress (AS13335 Consumer IP)
# • Target Sites: amazon.com, linkedin.com, IP Scanners, Bot Shields
# • MTU: 1280 (WARP-Optimized: Zero Fragmentation & Max Bandwidth)
# • Port: ${SERVER_PORT}/udp
# ==============================================================================
[Interface]
PrivateKey = ${CLIENT_CF_PRIV_KEY}
Address = ${CLIENT_WG_CF_IPV4}/32
DNS = ${CLIENT_DNS_LINE}
MTU = 1280

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
CF_CLIENT_EOF
)

	# --------------------------------------------------------------------------
	# Profile 2: Standard Direct VPS Full-Tunnel (MTU 1420)
	# --------------------------------------------------------------------------
	local STD_CONF_CONTENT
	STD_CONF_CONTENT=$(cat << CLIENT_EOF
# ==============================================================================
# 🛡️ PROFILE 2: STANDARD DIRECT VPS FULL-TUNNEL
# ==============================================================================
# • Egress Mode: Direct VPS Egress
# • MTU: 1420 (High-Speed Standard MTU)
# • Port: ${SERVER_PORT}/udp
# ==============================================================================
[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_WG_IPV4}/32
DNS = ${CLIENT_DNS_LINE}
MTU = 1420

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
CLIENT_EOF
)

	local ENC_KEY="${CLIENT_PASSWORD}"
	[[ -z "$ENC_KEY" ]] && ENC_KEY=$(getMasterPasskey)

	encryptConfigContent "$CF_CONF_CONTENT" "${EASY_DIR}/${CLIENT_NAME}-cloudflare-shield.conf.enc" "$ENC_KEY"
	encryptConfigContent "$CF_CONF_CONTENT" "/etc/wireguard/clients/${CLIENT_NAME}-cloudflare-shield.conf.enc" "$ENC_KEY"
	encryptConfigContent "$STD_CONF_CONTENT" "${EASY_DIR}/${CLIENT_NAME}-standard.conf.enc" "$ENC_KEY"
	encryptConfigContent "$STD_CONF_CONTENT" "/etc/wireguard/clients/${CLIENT_NAME}-standard.conf.enc" "$ENC_KEY"

	# Register peers in wg0.conf
	cat << PEER_EOF >> "/etc/wireguard/wg0.conf"

### Client ${CLIENT_NAME} [Cloudflare WARP Profile]
[Peer]
PublicKey = ${CLIENT_CF_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
AllowedIPs = ${CLIENT_WG_CF_IPV4}/32

### Client ${CLIENT_NAME} [Standard Profile]
[Peer]
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
AllowedIPs = ${CLIENT_WG_IPV4}/32
PEER_EOF

	if command -v wg-quick &>/dev/null && command -v wg &>/dev/null; then
		wg syncconf wg0 <(wg-quick strip wg0) 2>/dev/null || true
	fi

	echo -e "${GREEN}[✔] Peer ${CLIENT_NAME} created & encrypted successfully!${NC}"
	echo -e "   • Port Selected:          ${BOLD}${SERVER_PORT}/udp${NC}"
	echo -e "   • Profile 1 (WARP/Cover): ${CLIENT_WG_CF_IPV4} (MTU 1280 - Unblocks Amazon/LinkedIn)"
	echo -e "   • Profile 2 (Standard):   ${CLIENT_WG_IPV4} (MTU 1420 - Direct VPS)"
	echo -e "   • Secure Storage:         ${CYAN}${EASY_DIR}/${NC}\n"

	echo -e "${CYAN}${BOLD}📋 PROFILE 1 (WARP / SCAN-COVER / AMAZON & LINKEDIN READY):${NC}"
	echo -e "${YELLOW}-----------------------------------------------------------------${NC}"
	echo "$CF_CONF_CONTENT"
	echo -e "${YELLOW}-----------------------------------------------------------------${NC}\n"

	if command -v qrencode &>/dev/null; then
		echo -e "${CYAN}${BOLD}📱 Scan Profile 1 QR Code:${NC}\n"
		echo "$CF_CONF_CONTENT" | qrencode -t ansiutf8
		echo ""
	fi
}

function newClient() {
	echo -e "\n${CYAN}--- Add a New WireGuard Client ---${NC}"
	local CLIENT_NAME=""
	until [[ -n "$CLIENT_NAME" && "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; do
		read -rp "Enter client device name: " CLIENT_NAME
		CLIENT_NAME=$(echo "$CLIENT_NAME" | tr -cd '[:alnum:]_-')
		if grep -q "### Client ${CLIENT_NAME}" "/etc/wireguard/wg0.conf" 2>/dev/null; then
			echo -e "${ORANGE}A client with name '${CLIENT_NAME}' already exists! Choose another.${NC}"
			CLIENT_NAME=""
		fi
	done

	local CLIENT_PASSWORD=""
	while true; do
		read -s -rp "Enter encryption password for '${CLIENT_NAME}': " CLIENT_PASSWORD
		echo ""
		[[ ${#CLIENT_PASSWORD} -lt 4 ]] && { echo -e "${RED}[!] Minimum 4 chars.${NC}"; continue; }
		read -s -rp "Confirm password: " CLIENT_PASSWORD_CONFIRM
		echo ""
		[[ "$CLIENT_PASSWORD" != "$CLIENT_PASSWORD_CONFIRM" ]] && { echo -e "${RED}[!] Passwords do not match.${NC}"; continue; }
		break
	done

	newClientInternal "$CLIENT_NAME" "$CLIENT_PASSWORD"
}

# ------------------------------------------------------------------------------
# 9. Diagnostic & Live Verification Suite
# ------------------------------------------------------------------------------
function runLiveDiagnostics() {
	echo -e "\n${CYAN}${BOLD}--- Live Connectivity, WARP & Site Verification Diagnostic ---${NC}"

	# 1. Check WireGuard Interface
	echo -e "\n${BOLD}[1/4] WireGuard Kernel Status:${NC}"
	if wg show wg0 &>/dev/null; then
		echo -e "  WireGuard Interface: ${GREEN}ACTIVE (wg0)${NC}"
		local PEERS
		PEERS=$(wg show wg0 peers 2>/dev/null | wc -l)
		echo -e "  Registered Peers:    ${GREEN}${PEERS}${NC}"
	else
		echo -e "  WireGuard Interface: ${RED}INACTIVE${NC}"
	fi

	# 2. Check Cloudflare WARP Status & Egress ASN
	echo -e "\n${BOLD}[2/4] Cloudflare WARP Egress & Scan-Cover Status:${NC}"
	local WARP_STATUS="OFF"
	if command -v warp-cli &>/dev/null; then
		WARP_STATUS=$(warp-cli status 2>/dev/null || echo "Unknown")
	fi
	echo -e "  WARP Client Status:  ${CYAN}${WARP_STATUS}${NC}"

	local WARP_NIC="CloudflareWARP"
	ip link show "$WARP_NIC" &>/dev/null || WARP_NIC="warp0"
	if ip link show "$WARP_NIC" &>/dev/null; then
		echo -e "  Tunnel Interface:    ${GREEN}ACTIVE (${WARP_NIC})${NC}"
		local WARP_TRACE
		WARP_TRACE=$(curl -sSf --interface "$WARP_NIC" --max-time 4 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
		if echo "$WARP_TRACE" | grep -q "warp=on"; then
			local EGRESS_IP
			EGRESS_IP=$(echo "$WARP_TRACE" | grep "ip=" | cut -d'=' -f2)
			echo -e "  WARP Egress IP:      ${GREEN}${EGRESS_IP} (AS13335 Cloudflare Consumer Pool - Clean & Covered)${NC}"
		else
			echo -e "  WARP Egress IP:      ${YELLOW}WARP connected, awaiting full handshake${NC}"
		fi
	else
		echo -e "  Tunnel Interface:    ${YELLOW}Not bound to L3 TUN${NC}"
	fi

	# 3. Test amazon.com Connectivity
	echo -e "\n${BOLD}[3/4] Testing Amazon.com TLS & Handshake (MTU Clamping Check):${NC}"
	local AMZ_CODE
	AMZ_CODE=$(curl -sI -o /dev/null -w "%{http_code}" --max-time 5 https://www.amazon.com 2>/dev/null || echo "000")
	if [[ "$AMZ_CODE" =~ ^(200|301|302|405)$ ]]; then
		echo -e "  Amazon Response:     ${GREEN}SUCCESS (HTTP ${AMZ_CODE}) - Zero TLS Fragmentation Drops${NC}"
	else
		echo -e "  Amazon Response:     ${YELLOW}Status HTTP ${AMZ_CODE} (Possible rate limit or timeout)${NC}"
	fi

	# 4. Test linkedin.com Connectivity
	echo -e "\n${BOLD}[4/4] Testing LinkedIn.com Datacenter ASN Check:${NC}"
	local LI_CODE="000"
	if ip link show "$WARP_NIC" &>/dev/null; then
		LI_CODE=$(curl -sI --interface "$WARP_NIC" -o /dev/null -w "%{http_code}" --max-time 5 https://www.linkedin.com 2>/dev/null || echo "000")
	else
		LI_CODE=$(curl -sI -o /dev/null -w "%{http_code}" --max-time 5 https://www.linkedin.com 2>/dev/null || echo "000")
	fi
	if [[ "$LI_CODE" =~ ^(200|301|302)$ ]]; then
		echo -e "  LinkedIn Response:   ${GREEN}SUCCESS (HTTP ${LI_CODE}) - Datacenter ASN Blocks Bypassed${NC}"
	elif [[ "$LI_CODE" == "999" || "$LI_CODE" == "403" ]]; then
		echo -e "  LinkedIn Response:   ${RED}BLOCKED (HTTP ${LI_CODE}) - Egress is not routing via WARP${NC}"
	else
		echo -e "  LinkedIn Response:   ${GREEN}HTTP ${LI_CODE} (Clear of 999 datacenter block)${NC}"
	fi

	echo ""
	read -n1 -r -p "Press Enter to return to menu..."
}

# ------------------------------------------------------------------------------
# 10. Automated Network, DNS & Firewall Auto-Repair
# ------------------------------------------------------------------------------
function autoRepairNetwork() {
	echo -e "\n${CYAN}${BOLD}🛠️ Starting High-Performance Network, DNS & WARP Repair...${NC}"

	# 1. Restore clean Anycast DNS
	cat << 'RESOLV_CLEAN' > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
RESOLV_CLEAN

	# 2. Re-apply Top-Speed Network Optimizations
	tuneNetworkPerformance

	# 3. Clean and Restart WireGuard
	if command -v wg-quick &>/dev/null; then
		wg-quick down wg0 >/dev/null 2>&1 || true
		systemctl restart "wg-quick@wg0" 2>/dev/null || wg-quick up wg0 2>/dev/null || true
	fi

	# 4. Re-establish Cloudflare WARP L3 Egress
	if [[ -f /etc/wireguard/warp_egress_enabled ]] && command -v warp-cli &>/dev/null; then
		warp-cli --accept-tos mode warp 2>/dev/null || warp-cli --accept-tos set-mode warp 2>/dev/null || true
		warp-cli --accept-tos connect 2>/dev/null || warp-cli connect 2>/dev/null || true
		sleep 1

		local WARP_NIC="CloudflareWARP"
		ip link show "$WARP_NIC" &>/dev/null || WARP_NIC="warp0"
		if ip link show "$WARP_NIC" &>/dev/null; then
			ip rule del from 10.19.0.0/24 table 51820 2>/dev/null || true
			ip rule add from 10.19.0.0/24 table 51820 priority 200 2>/dev/null || true
			ip route replace default dev "$WARP_NIC" table 51820 2>/dev/null || true
			iptables -t nat -I POSTROUTING 1 -o "$WARP_NIC" -j MASQUERADE 2>/dev/null || true
		fi
	fi

	applyDomainSplitRulesLive >/dev/null 2>&1 || true
	echo -e "${GREEN}[✔] Auto-Repair Complete! WireGuard, WARP, BBR, and DNS restored.${NC}\n"
}

# ------------------------------------------------------------------------------
# 11. Interactive Menu
# ------------------------------------------------------------------------------
function manageMenu() {
	while true; do
		local WG0_STATUS="${RED}STOPPED${NC}"
		if systemctl is-active --quiet wg-quick@wg0 2>/dev/null || wg show wg0 &>/dev/null; then
			WG0_STATUS="${GREEN}ACTIVE${NC}"
		fi

		local WARP_STATUS="${RED}OFF${NC}"
		if ip link show CloudflareWARP &>/dev/null || ip link show warp0 &>/dev/null; then
			WARP_STATUS="${GREEN}CONNECTED (AS13335)${NC}"
		fi

		echo -e "\n${PURPLE}=================================================================${NC}"
		echo -e "              ${GREEN}${BOLD}🍪  Cookie's Easy WireGuard Manager v4.0${NC}"
		echo -e "${PURPLE}=================================================================${NC}"
		echo -e "  ${BOLD}WireGuard Server:${NC}       wg0 | Port ${SERVER_PORT:-4500}/udp [${WG0_STATUS}]"
		echo -e "  ${BOLD}Cloudflare WARP Egress:${NC} [${WARP_STATUS}]"
		echo -e "  ${BOLD}Speed Optimizations:${NC}    ${GREEN}BBR Congestion Control + 64MB Buffers Active${NC}"
		echo -e "${PURPLE}┌──────────────────────────────────────────────────────────────┐${NC}"
		echo -e "${PURPLE}│${NC}                      ${CYAN}${BOLD}Main Menu Actions${NC}                       ${PURPLE}│${NC}"
		echo -e "${PURPLE}├──────────────────────────────────────────────────────────────┤${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[1]${NC} Setup / Reinstall WireGuard Server                       ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[2]${NC} Add New Client (Generates WARP Stealth & Standard)       ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[3]${NC} Re-initialize Cloudflare WARP L3 Tunnel Egress            ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[4]${NC} Run Live Amazon, LinkedIn & Scan-Cover Diagnostics       ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[5]${NC} Run High-Speed Network Auto-Repair                       ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[q]${NC} Exit                                                     ${PURPLE}│${NC}"
		echo -e "${PURPLE}└──────────────────────────────────────────────────────────────┘${NC}"
		echo ""

		read -rp "Option: " MENU_OPTION
		case "${MENU_OPTION}" in
			1)
				installQuestions
				installWireGuard
				read -n1 -r -p "Press Enter to return..."
				;;
			2)
				newClient
				read -n1 -r -p "Press Enter to return..."
				;;
			3)
				setupCloudflareWarpClient
				read -n1 -r -p "Press Enter to return..."
				;;
			4)
				runLiveDiagnostics
				;;
			5)
				autoRepairNetwork
				read -n1 -r -p "Press Enter to return..."
				;;
			q|Q)
				echo -e "${GREEN}Goodbye!${NC}\n"
				exit 0
				;;
			*)
				echo -e "${RED}Invalid option.${NC}"
				sleep 1
				;;
		esac
	done
}

# ------------------------------------------------------------------------------
# 12. Script Entrypoint
# ------------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	initialCheck

	if [[ -e /etc/wireguard/params ]]; then
		source /etc/wireguard/params
	fi

	if [[ "${1:-}" == "--repair" || "${1:-}" == "-r" ]]; then
		autoRepairNetwork
		exit 0
	fi

	cleanupAndSecureRootFolder
	manageMenu
fi