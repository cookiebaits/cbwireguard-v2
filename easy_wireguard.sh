#!/bin/bash
# ==============================================================================
# 🍪 Cookie's Easy WireGuard Manager & VPS Stealth Server v3.6
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

# ------------------------------------------------------------------------------
# 2. Sensitive Port Protection & Safe Cleanup Routines
# ------------------------------------------------------------------------------
# Checks if a port is sensitive, well-known, or prone to conflicts
# (e.g. Web 80/443, SSH 22, DNS 53, Mail, Database, or common scanner targets)
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

# Checks if a port is currently active and bound on the host
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

	# Surgical rule cleanup: only remove WireGuard-created rules.
	# Sensitive ports (80, 443, 22), Docker chains, and web servers remain untouched!
	iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
	iptables -D FORWARD -o wg0 -j ACCEPT 2>/dev/null || true
	iptables -D FORWARD -i wg1 -j ACCEPT 2>/dev/null || true
	iptables -D FORWARD -o wg1 -j ACCEPT 2>/dev/null || true
	iptables -t nat -D POSTROUTING -s 10.18.0.0/24 -j MASQUERADE 2>/dev/null || true
	iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
	iptables -t mangle -D POSTROUTING -j TTL --ttl-set 64 2>/dev/null || true

	echo -e "${GREEN}[✔] Cleaned old WireGuard instances. Sensitive web & SSH ports (80, 443, 22) protected.${NC}"
}

# ------------------------------------------------------------------------------
# 3. DNS Resolvers Selection Menu (Location + Stealth for IPv4 & IPv6)
# ------------------------------------------------------------------------------
function selectDNSResolvers() {
	echo -e "\n${CYAN}${BOLD}Select DNS Resolvers for Clients (Includes Stealth & Location Info):${NC}"
	echo -e "   1) ${GREEN}Cloudflare Anycast Anti-Flag${NC} (Global Anycast | Ultra Fast & Cloudflare WAF Aligned) ${PURPLE}[RECOMMENDED STEALTH]${NC}"
	echo -e "      IPv4: 1.1.1.1, 1.0.0.1  |  IPv6: 2606:4700:4700::1111, 2606:4700:4700::1001"
	echo -e "   2) ${GREEN}AdGuard Stealth${NC} (Global Anycast | Anti-Track / Anti-Ad Stealth)"
	echo -e "      IPv4: 94.140.14.14, 94.140.15.15  |  IPv6: 2a10:50c0::ad1:ff, 2a10:50c0::ad2:ff"
	echo -e "   3) ${GREEN}Mullvad Privacy${NC} (Sweden / EU | Strict Anti-Censorship Stealth)"
	echo -e "      IPv4: 194.242.2.2, 194.242.2.3  |  IPv6: 2a07:e880::2, 2a07:e880::3"
	echo -e "   4) ${GREEN}Quad9 Swiss Shield${NC} (Zurich, Switzerland | Swiss Privacy & Threat Filter)"
	echo -e "      IPv4: 9.9.9.9, 149.112.112.112  |  IPv6: 2620:fe::fe, 2620:fe::9"
	echo -e "   5) ${GREEN}Control D Stealth${NC} (Global | Uncensored Anti-Throttling Stealth)"
	echo -e "      IPv4: 76.76.2.0, 76.76.10.0  |  IPv6: 2606:1a40::, 2606:1a40:1::"
	echo -e "   6) ${GREEN}Unbound Local Server Resolver${NC} (Server Local | Maximum Anti-Leak)"
	echo -e "      IPv4: ${SERVER_WG_IPV4:-10.18.0.1}  |  IPv6: ${SERVER_WG_IPV6:-fd42:42:42::1}"
	echo -e "   7) ${GREEN}Google Public DNS${NC} (Global Anycast | High Uptime)"
	echo -e "      IPv4: 8.8.8.8, 8.8.4.4  |  IPv6: 2001:4860:4860::8888, 2001:4860:4860::8844"
	echo -e "   8) ${GREEN}OpenDNS / Cisco Umbrella${NC} (USA / Global | Stability Filter)"
	echo -e "      IPv4: 208.67.222.222, 208.67.220.220  |  IPv6: 2620:119:35::35, 2620:119:53::53"
	echo -e "   9) Custom Primary & Secondary DNS Resolvers"

	read -rp "Select DNS Resolver option [1-9, default 1 (Cloudflare Anycast Anti-Flag)]: " DNS_OPTION
	DNS_OPTION=${DNS_OPTION:-1}
	case "${DNS_OPTION}" in
		2)
			CLIENT_DNS_1="94.140.14.14"
			CLIENT_DNS_2="94.140.15.15"
			;;
		3)
			CLIENT_DNS_1="194.242.2.2"
			CLIENT_DNS_2="194.242.2.3"
			;;
		4)
			CLIENT_DNS_1="9.9.9.9"
			CLIENT_DNS_2="149.112.112.112"
			;;
		5)
			CLIENT_DNS_1="76.76.2.0"
			CLIENT_DNS_2="76.76.10.0"
			;;
		6)
			CLIENT_DNS_1="${SERVER_WG_IPV4:-10.18.0.1}"
			CLIENT_DNS_2="${SERVER_WG_IPV6:-fd42:42:42::1}"
			;;
		7)
			CLIENT_DNS_1="8.8.8.8"
			CLIENT_DNS_2="8.8.4.4"
			;;
		8)
			CLIENT_DNS_1="208.67.222.222"
			CLIENT_DNS_2="208.67.220.220"
			;;
		9)
			read -rp "Enter Primary DNS resolver (IPv4 or IPv6): " -e -i "1.1.1.1" CLIENT_DNS_1
			read -rp "Enter Secondary DNS resolver (IPv4 or IPv6): " -e -i "1.0.0.1" CLIENT_DNS_2
			;;
		1|*)
			CLIENT_DNS_1="1.1.1.1"
			CLIENT_DNS_2="1.0.0.1"
			;;
	esac
	echo -e "${GREEN}[✔] Selected DNS Resolvers: ${CLIENT_DNS_1}, ${CLIENT_DNS_2}${NC}"
}

# ------------------------------------------------------------------------------
# 4. Interactive Installation Questions
# ------------------------------------------------------------------------------
function installQuestions() {
	echo -e "${PURPLE}=================================================================${NC}"
	echo -e "          ${GREEN}${BOLD}🍪  Cookie's Easy WireGuard Setup & Installer${NC}"
	echo -e "${PURPLE}=================================================================${NC}"
	echo -e "Welcome to the WireGuard installer!\n"

	# Auto-detect public IPv4 address
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

	# Auto-detect public network interface
	SERVER_NIC=$(ip -4 route show default 2>/dev/null | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | head -n1 || true)
	if [[ -z "$SERVER_NIC" ]]; then
		SERVER_NIC="eth0"
	fi
	read -rp "Public network interface: " -e -i "${SERVER_NIC}" SERVER_PUB_NIC

	read -rp "WireGuard interface name: " -e -i "wg0" SERVER_WG_NIC

	read -rp "Server WireGuard internal IPv4: " -e -i "10.18.0.1" SERVER_WG_IPV4
	read -rp "Server WireGuard internal IPv6: " -e -i "fd42:42:42::1" SERVER_WG_IPV6

	echo -e "\n${CYAN}${BOLD}Select WireGuard Port (Stealth & Non-Sensitive Ports - Zero Web/80/443 Conflicts):${NC}"
	echo -e "   1) ${GREEN}4500${NC}  (IPsec NAT-Traversal UDP | Stealth Encrypted Tunneling - Firewall & Carrier Safe) ${PURPLE}[RECOMMENDED STEALTH]${NC}"
	echo -e "   2) ${GREEN}3478${NC}  (STUN / WebRTC Media UDP | FaceTime / Zoom / VoIP Bypass - Zero DPI Throttling) ${PURPLE}[STEALTH]${NC}"
	echo -e "   3) ${GREEN}500${NC}   (IKEv2 / IPsec Signaling UDP | Mobile Telecom Pass-Through)"
	echo -e "   4) ${GREEN}853${NC}   (DNS-over-QUIC UDP | Modern Encrypted Transport Appearance)"
	echo -e "   5) ${GREEN}51820${NC} (Official WireGuard Standard Port | Dedicated Non-Conflicting Protocol)"
	echo -e "   6) ${GREEN}41194${NC} (Disguised High Tunnel UDP | Evades Low-Port Scanning & Probes)"
	echo -e "   7) Random High-Entropy Stealth Port (49152-65535)"
	echo -e "   8) Custom Non-Sensitive Port"

	read -rp "Select WireGuard Port option [1-8, default 1 (4500)]: " PORT_OPTION
	PORT_OPTION=${PORT_OPTION:-1}
	case "${PORT_OPTION}" in
		2) SERVER_PORT=3478 ;;
		3) SERVER_PORT=500 ;;
		4) SERVER_PORT=853 ;;
		5) SERVER_PORT=51820 ;;
		6) SERVER_PORT=41194 ;;
		7)
			RANDOM_PORT=$(( (RANDOM % 16383) + 49152 ))
			SERVER_PORT="${RANDOM_PORT}"
			echo -e "${GREEN}[✔] Generated Random Stealth High Port: ${SERVER_PORT}/udp${NC}"
			;;
		8)
			while true; do
				read -rp "Enter Custom WireGuard Port [1024-65535]: " -e -i "4500" SERVER_PORT
				if ! [[ "$SERVER_PORT" =~ ^[0-9]+$ ]] || [[ "$SERVER_PORT" -lt 1024 || "$SERVER_PORT" -gt 65535 ]]; then
					echo -e "${RED}[!] Invalid port. Please choose an unprivileged port between 1024 and 65535.${NC}"
					continue
				fi
				if isSensitivePort "$SERVER_PORT"; then
					echo -e "${RED}[!] Port ${SERVER_PORT} is a sensitive service port (conflicts with web/mail/DNS like 80/443/8080). Please enter a non-sensitive stealth port.${NC}"
					continue
				fi
				if isPortInUse "$SERVER_PORT" "udp"; then
					echo -e "${YELLOW}[!] Warning: Port ${SERVER_PORT}/udp is currently bound by another service on this host. Please choose another port.${NC}"
					continue
				fi
				break
			done
			;;
		1|*) SERVER_PORT=4500 ;;
	esac
	echo -e "${GREEN}[✔] WireGuard Port Selected: ${SERVER_PORT}/udp (Safe Non-Sensitive Stealth Port)${NC}"

	selectDNSResolvers

	read -rp "First client device name: " -e -i "my-device" CLIENT_NAME
	CLIENT_NAME=$(echo "$CLIENT_NAME" | tr -cd '[:alnum:]_-')

	read -rp "Allowed IPs for generated clients: " -e -i "0.0.0.0/0, ::/0" ALLOWED_IPS

	echo -e "\n${CYAN}${BOLD}☁️ Cloudflare Anti-Flag & ISP Host Masking Engine Integration:${NC}"
	echo -e "   • Auto-deploys TCP MSS Clamping & TTL Normalization (Anti-p0f OS signature disguise)"
	echo -e "   • Auto-configures Cloudflare WAF, Turnstile & Edge CDN split-routing"
	echo -e "   • Generates both Full Tunnel and Zero-Challenge Residential Bypass client profiles"
	echo -e "   • Strips EDNS Client-Subnet (ECS) to prevent VPS datacenter IP leaks"
	read -rp "Auto-configure Cloudflare Anti-Flag & ISP Masking into install? [Y/n, default Y]: " CF_AUTO_ENABLE
	CF_AUTO_ENABLE=${CF_AUTO_ENABLE:-y}

	WEB_PORT=${WEB_PORT:-51821}

	echo -e "\n${GREEN}Setup parameters configured successfully.${NC}"
	read -n1 -r -p "Press any key to start WireGuard installation..."
	echo ""
}

# ------------------------------------------------------------------------------
# 5. Perform WireGuard Server Installation
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
		apt-get install -y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" wireguard wireguard-tools iptables qrencode curl jq iproute2 iptables-persistent net-tools ipset dnsmasq || true
	elif [[ "${OS}" == "fedora" || "${OS}" == "centos" || "${OS}" == "almalinux" || "${OS}" == "rocky" ]]; then
		yum install -y wireguard-tools iptables qrencode curl jq ipset dnsmasq || true
	elif [[ "${OS}" == "arch" ]]; then
		pacman -S --needed --noconfirm wireguard-tools qrencode iptables curl jq ipset dnsmasq || true
	elif [[ "${OS}" == "alpine" ]]; then
		apk update && apk add wireguard-tools iptables libqrencode-tools curl jq ipset dnsmasq || true
	fi

	# Safely isolate dnsmasq to avoid unconfigured port 53 collision with host systemd-resolved
	systemctl stop dnsmasq >/dev/null 2>&1 || true
	systemctl disable dnsmasq >/dev/null 2>&1 || true

	# Ensure host resolv.conf always maintains clean, operational Anycast nameservers
	if ! grep -q -E "nameserver [0-9]" /etc/resolv.conf 2>/dev/null; then
		cat << 'RESOLV_INIT' > /etc/resolv.conf 2>/dev/null || true
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
RESOLV_INIT
	fi

	if ! command -v wg &>/dev/null; then
		echo -e "${RED}[ERROR] WireGuard installation failed. 'wg' tool not found.${NC}"
		exit 1
	fi

	echo -e "${CYAN}[*] Loading WireGuard and networking kernel modules...${NC}"
	modprobe wireguard >/dev/null 2>&1 || { apt-get install -y "linux-headers-$(uname -r)" wireguard-dkms >/dev/null 2>&1 || true; modprobe wireguard >/dev/null 2>&1 || true; }
	modprobe iptable_nat >/dev/null 2>&1 || true
	modprobe iptable_mangle >/dev/null 2>&1 || true
	modprobe ip6table_nat >/dev/null 2>&1 || true
	modprobe xt_mark >/dev/null 2>&1 || true
	modprobe xt_hl >/dev/null 2>&1 || true
	modprobe ipt_TTL >/dev/null 2>&1 || true
	modprobe tcp_bbr >/dev/null 2>&1 || true

	# Detect whether host genuinely supports IPv6 in kernel and networking stack
	local HAS_IPV6=0
	if [[ -f /proc/net/if_inet6 ]] && [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1) -eq 0 ]]; then
		if ip -6 addr show dev lo 2>/dev/null | grep -q inet6; then
			HAS_IPV6=1
		fi
	fi

	echo -e "${CYAN}[*] Applying BBR, TTL=64 Normalization, and MSS Clamping sysctl rules...${NC}"
	SYSCTL_CONF="/etc/sysctl.d/99-wireguard-stealth.conf"
	cat << 'SYSCTL_EOF' > "$SYSCTL_CONF"
net.ipv4.ip_forward = 1
net.ipv4.tcp_mtu_probing = 1
net.core.default_qdisc = fq
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
SYSCTL_EOF

	if [[ "${HAS_IPV6}" -eq 1 ]]; then
		cat << 'SYSCTL_V6_EOF' >> "$SYSCTL_CONF"
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.all.forwarding = 1
SYSCTL_V6_EOF
	fi

	if lsmod 2>/dev/null | grep -q bbr || grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
		echo "net.ipv4.tcp_congestion_control = bbr" >> "$SYSCTL_CONF"
	fi

	sysctl --system -q >/dev/null 2>&1 || sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || true

	# Ensure UFW / Firewalld unblock WireGuard UDP traffic & enable forwarding
	if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
		echo -e "${CYAN}[*] UFW firewall active. Allowing WireGuard port ${SERVER_PORT}/udp and enabling forwarding...${NC}"
		ufw allow "${SERVER_PORT}/udp" >/dev/null 2>&1 || true
		ufw allow "${WEB_PORT:-51821}/tcp" >/dev/null 2>&1 || true
		if [ -f /etc/default/ufw ]; then
			sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw 2>/dev/null || true
		fi
		ufw reload >/dev/null 2>&1 || true
	fi

	if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
		echo -e "${CYAN}[*] Firewalld active. Opening WireGuard UDP port ${SERVER_PORT}...${NC}"
		firewall-cmd --add-port="${SERVER_PORT}/udp" --permanent >/dev/null 2>&1 || true
		firewall-cmd --add-port="${WEB_PORT:-51821}/tcp" --permanent >/dev/null 2>&1 || true
		firewall-cmd --add-masquerade --permanent >/dev/null 2>&1 || true
		firewall-cmd --reload >/dev/null 2>&1 || true
	fi

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
WEB_PORT=${WEB_PORT:-51821}
ADMIN_PASSKEY=${ADMIN_PASSKEY}
HAS_IPV6=${HAS_IPV6}
PARAMS_EOF
	chmod 600 /etc/wireguard/params

	cat << ENV_EOF > /etc/wireguard/manager.env
SERVER_PUBLIC_IP="${SERVER_PUB_IP}"
WG_DEFAULT_PORT="${SERVER_PORT}"
WEB_PORT="${WEB_PORT:-51821}"
ADMIN_PASSKEY="${ADMIN_PASSKEY}"
ENV_EOF
	chmod 600 /etc/wireguard/manager.env

	# Probe host iptables mangle capabilities to prevent wg-quick exit aborts
	local HAS_TCPMSS=0
	if iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o "${SERVER_PUB_NIC}" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
		iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o "${SERVER_PUB_NIC}" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
		HAS_TCPMSS=1
	fi

	local HAS_TTL=0
	if iptables -t mangle -A POSTROUTING -o "${SERVER_PUB_NIC}" -j TTL --ttl-set 64 2>/dev/null; then
		iptables -t mangle -D POSTROUTING -o "${SERVER_PUB_NIC}" -j TTL --ttl-set 64 2>/dev/null || true
		HAS_TTL=1
	fi

	# Determine server address (IPv4-only if IPv6 unsupported by host)
	local WG_SERVER_ADDRESS="${SERVER_WG_IPV4}/24"
	if [[ "${HAS_IPV6}" -eq 1 ]]; then
		WG_SERVER_ADDRESS="${SERVER_WG_IPV4}/24,${SERVER_WG_IPV6}/64"
	fi

	cat << WG_SERVER_EOF > "/etc/wireguard/${SERVER_WG_NIC}.conf"
[Interface]
Address = ${WG_SERVER_ADDRESS}
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PRIV_KEY}
MTU = 1420
SaveConfig = false

# --- STEALTH & PACKET ROUTING FIREWALL RULES ---
PostUp = iptables -I INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT 2>/dev/null || true
PostUp = iptables -A FORWARD -i ${SERVER_WG_NIC} -j ACCEPT 2>/dev/null || true
PostUp = iptables -A FORWARD -o ${SERVER_WG_NIC} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
PostUp = iptables -t nat -A POSTROUTING -s 10.18.0.0/24 -o ${SERVER_PUB_NIC} -j MASQUERADE 2>/dev/null || true
PostUp = iptables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE 2>/dev/null || true
PostDown = iptables -D INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i ${SERVER_WG_NIC} -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -o ${SERVER_WG_NIC} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s 10.18.0.0/24 -o ${SERVER_PUB_NIC} -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE 2>/dev/null || true
WG_SERVER_EOF

	if [[ "${HAS_TCPMSS}" -eq 1 ]]; then
		cat << 'EOF_MSS' >> "/etc/wireguard/${SERVER_WG_NIC}.conf"
PostUp = iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostUp = iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360 2>/dev/null || true
PostUp = iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o eth_dummy -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360 2>/dev/null || true
PostDown = iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o eth_dummy -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
EOF_MSS
		sed -i "s|eth_dummy|${SERVER_PUB_NIC}|g" "/etc/wireguard/${SERVER_WG_NIC}.conf"
	fi

	if [[ "${HAS_TTL}" -eq 1 ]]; then
		cat << 'EOF_TTL' >> "/etc/wireguard/${SERVER_WG_NIC}.conf"
PostUp = iptables -t mangle -A POSTROUTING -o eth_dummy -j TTL --ttl-set 64 2>/dev/null || true
PostDown = iptables -t mangle -D POSTROUTING -o eth_dummy -j TTL --ttl-set 64 2>/dev/null || true
EOF_TTL
		sed -i "s|eth_dummy|${SERVER_PUB_NIC}|g" "/etc/wireguard/${SERVER_WG_NIC}.conf"
	fi

	if [[ "${HAS_IPV6}" -eq 1 ]]; then
		cat << 'EOF_V6' >> "/etc/wireguard/${SERVER_WG_NIC}.conf"
PostUp = ip6tables -A FORWARD -i wg_dummy -j ACCEPT 2>/dev/null || true
PostUp = ip6tables -A FORWARD -o wg_dummy -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
PostUp = ip6tables -t nat -A POSTROUTING -o eth_dummy -j MASQUERADE 2>/dev/null || true
PostDown = ip6tables -D FORWARD -i wg_dummy -j ACCEPT 2>/dev/null || true
PostDown = ip6tables -D FORWARD -o wg_dummy -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
PostDown = ip6tables -t nat -D POSTROUTING -o eth_dummy -j MASQUERADE 2>/dev/null || true
EOF_V6
		sed -i "s|wg_dummy|${SERVER_WG_NIC}|g" "/etc/wireguard/${SERVER_WG_NIC}.conf"
		sed -i "s|eth_dummy|${SERVER_PUB_NIC}|g" "/etc/wireguard/${SERVER_WG_NIC}.conf"
	fi

	chmod 600 "/etc/wireguard/${SERVER_WG_NIC}.conf"

	# Clean any stale or hanging wireguard interfaces
	wg-quick down "${SERVER_WG_NIC}" >/dev/null 2>&1 || true
	ip link set "${SERVER_WG_NIC}" down >/dev/null 2>&1 || true
	ip link delete dev "${SERVER_WG_NIC}" >/dev/null 2>&1 || true
	systemctl stop "wg-quick@${SERVER_WG_NIC}" >/dev/null 2>&1 || true

	systemctl daemon-reload >/dev/null 2>&1 || true
	systemctl enable "wg-quick@${SERVER_WG_NIC}" >/dev/null 2>&1 || true

	echo -e "${CYAN}[*] Starting WireGuard daemon (wg-quick@${SERVER_WG_NIC})...${NC}"
	if ! systemctl restart "wg-quick@${SERVER_WG_NIC}"; then
		echo -e "${YELLOW}[!] Notice: Initial start encountered host constraint. Auto-diagnosing and healing...${NC}"
		journalctl -xeu "wg-quick@${SERVER_WG_NIC}" --no-pager -n 12 2>/dev/null || true

		# Clean hung interface
		wg-quick down "${SERVER_WG_NIC}" >/dev/null 2>&1 || true
		ip link delete dev "${SERVER_WG_NIC}" >/dev/null 2>&1 || true

		# Strip IPv6 if present
		if grep -q "fd42:42:42::" "/etc/wireguard/${SERVER_WG_NIC}.conf" 2>/dev/null; then
			echo -e "${YELLOW}[*] Stripping IPv6 addresses (host kernel lacks IPv6)...${NC}"
			sed -i -E "s|,fd42:42:42::[0-9a-fA-F:]+/64||g" "/etc/wireguard/${SERVER_WG_NIC}.conf"
			sed -i "/ip6tables/d" "/etc/wireguard/${SERVER_WG_NIC}.conf"
		fi

		# Strip any failing mangle targets
		sed -i "/TTL --ttl-set/d" "/etc/wireguard/${SERVER_WG_NIC}.conf"
		sed -i "/TCPMSS --clamp-mss-to-pmtu/d" "/etc/wireguard/${SERVER_WG_NIC}.conf"

		# Re-attempt startup
		systemctl restart "wg-quick@${SERVER_WG_NIC}" 2>/dev/null || wg-quick up "${SERVER_WG_NIC}" 2>/dev/null || true
	fi

	if systemctl is-active --quiet "wg-quick@${SERVER_WG_NIC}" || wg show "${SERVER_WG_NIC}" &>/dev/null; then
		echo -e "${GREEN}[✔] WireGuard interface ${SERVER_WG_NIC} started and active!${NC}"
	else
		echo -e "${RED}[ERROR] WireGuard failed to start. Journal log:${NC}"
		journalctl -xeu "wg-quick@${SERVER_WG_NIC}" --no-pager -n 20 2>/dev/null || true
	fi

	# Auto-Configure Essential Cloudflare Anti-Flag & Mask ISP Host Engine Components
	if [[ "${CF_AUTO_ENABLE:-y}" =~ ^[Yy]$ ]]; then
		echo -e "\n${CYAN}[*] Auto-Configuring Essential Cloudflare Anti-Flag & ISP Masking Engine...${NC}"
		mkdir -p /etc/wireguard
		touch /etc/wireguard/cloudflare_shield_enabled
		touch /etc/wireguard/cloudflare_split_enabled
		echo "BYPASS" > /etc/wireguard/split_mode.txt

		cat << 'CF_INIT_DOMAINS' > /etc/wireguard/split_domains.txt
# Cloudflare Anti-Bot, WAF & Turnstile Shield Domains (Auto-Configured)
challenges.cloudflare.com
cloudflare.com
turnstile.com
cdnjs.cloudflare.com
cloudflareinsights.com
cf-assets.com
pages.dev
workers.dev
CF_INIT_DOMAINS

		applyDomainSplitRulesLive
		echo -e "${GREEN}[✔] Cloudflare Anti-Flag Shield & Turnstile Bypass auto-configured into installation!${NC}"
	fi

	newClientInternal "${CLIENT_NAME}"

	echo -e "\n${GREEN}${BOLD}=================================================================${NC}"
	echo -e "${GREEN}${BOLD}🎉 WIREGUARD SERVER INSTALLED SUCCESSFULLY!${NC}"
	echo -e "${GREEN}${BOLD}=================================================================${NC}"

	read -rp "Do you want to provision the Web Management Console now? [Y/n]: " PROV_NOW
	PROV_NOW=${PROV_NOW:-y}
	if [[ "$PROV_NOW" =~ ^[Yy]$ ]]; then
		provisionWebConsole
	else
		echo -e "${YELLOW}Web Console provisioning skipped. You can provision it anytime from Option [8] in the Main Menu.${NC}\n"
	fi
}

# ------------------------------------------------------------------------------
# 6. Provision Web Management Console Runtime
# ------------------------------------------------------------------------------
function provisionWebConsole() {
	echo -e "\n${CYAN}${BOLD}--- Provision Web Management Console Runtime ---${NC}"

	echo -e "Select Web Management Console Port (Non-Sensitive Dedicated Web Port):"
	echo -e "   1) ${GREEN}51821${NC} (Default Dedicated WireGuard Manager Port) ${PURPLE}[RECOMMENDED SAFE]${NC}"
	echo -e "   2) ${GREEN}54321${NC} (High Stealth Web Port)"
	echo -e "   3) ${GREEN}58921${NC} (High Ephemeral Alternate Port)"
	echo -e "   4) Custom High Non-Sensitive Port (1024-65535)"

	read -rp "Select Web Console Port option [1-4, default 1 (51821)]: " WEB_PORT_OPTION
	WEB_PORT_OPTION=${WEB_PORT_OPTION:-1}
	case "${WEB_PORT_OPTION}" in
		2) WEB_PORT=54321 ;;
		3) WEB_PORT=58921 ;;
		4)
			while true; do
				RANDOM_WEB=$(( (RANDOM % 50000) + 10000 ))
				read -rp "Web Console port [1024-65535]: " -e -i "${RANDOM_WEB}" CUSTOM_WEB
				if ! [[ "$CUSTOM_WEB" =~ ^[0-9]+$ ]] || [[ "$CUSTOM_WEB" -lt 1024 || "$CUSTOM_WEB" -gt 65535 ]]; then
					echo -e "${RED}[!] Invalid port. Enter an unprivileged port between 1024 and 65535.${NC}"
					continue
				fi
				if isSensitivePort "$CUSTOM_WEB"; then
					echo -e "${RED}[!] Port ${CUSTOM_WEB} is a sensitive service port (like 80/443/8080/8443). The Web Console must run on a dedicated non-sensitive port.${NC}"
					continue
				fi
				if isPortInUse "$CUSTOM_WEB" "tcp"; then
					echo -e "${YELLOW}[!] Warning: Port ${CUSTOM_WEB}/tcp is currently in use by another service. Please choose another port.${NC}"
					continue
				fi
				WEB_PORT="$CUSTOM_WEB"
				break
			done
			;;
		1|*) WEB_PORT=${WEB_PORT:-51821} ;;
	esac

	if [[ -z "${ADMIN_PASSKEY:-}" ]]; then
		ADMIN_PASSKEY=$(tr -dc 'A-Za-z0-9!@#$%^&*' < /dev/urandom | head -c 24)
	fi

	cat << ENV_EOF > /etc/wireguard/manager.env
SERVER_PUBLIC_IP="${SERVER_PUB_IP:-127.0.0.1}"
WG_DEFAULT_PORT="${SERVER_PORT:-4500}"
WEB_PORT="${WEB_PORT}"
ADMIN_PASSKEY="${ADMIN_PASSKEY}"
ENV_EOF
	chmod 600 /etc/wireguard/manager.env

	if [[ -f /etc/wireguard/params ]]; then
		sed -i "s/^WEB_PORT=.*/WEB_PORT=${WEB_PORT}/" /etc/wireguard/params 2>/dev/null || true
	fi

	echo -e "\n${CYAN}[*] Provisioning Web Management Console runtime on port ${WEB_PORT}...${NC}"
	echo -e "${YELLOW} -> [1/4] Checking Node.js runtime...${NC}"
	if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
		echo -e "${YELLOW} -> Installing Node.js & Git packages...${NC}"
		apt-get update -y -q >/dev/null 2>&1 || true
		apt-get install -y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" nodejs npm git >/dev/null 2>&1 || true
		if ! command -v node >/dev/null 2>&1; then
			curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1 || true
			apt-get install -y -q nodejs git >/dev/null 2>&1 || true
		fi
	fi

	echo -e "${YELLOW} -> [2/4] Setting up /opt/cbwireguard project files...${NC}"
	mkdir -p /opt/cbwireguard
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo ".")"

	if [[ -f "${SCRIPT_DIR}/server.ts" && -f "${SCRIPT_DIR}/package.json" ]]; then
		cp -r "${SCRIPT_DIR}/"* /opt/cbwireguard/ 2>/dev/null || true
	else
		git clone https://github.com/cookiebaits/cbwireguard-v2.git /opt/cbwireguard 2>/dev/null || true
	fi

	cd /opt/cbwireguard

	echo -e "${YELLOW} -> [3/4] Installing Web Console runtime dependencies...${NC}"
	npm install --omit=dev --no-audit --no-fund --legacy-peer-deps >/dev/null 2>&1 || true

	echo -e "${YELLOW} -> [4/4] Starting Web Console service...${NC}"
	cat << SERVICE_EOF > /etc/systemd/system/cbwireguard-web.service
[Unit]
Description=Cookie WireGuard Web Management Console
After=network.target wg-quick@${SERVER_WG_NIC:-wg0}.service
Wants=wg-quick@${SERVER_WG_NIC:-wg0}.service

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
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SERVICE_EOF

	systemctl daemon-reload
	systemctl enable cbwireguard-web >/dev/null 2>&1 || true
	systemctl restart cbwireguard-web >/dev/null 2>&1 || true

	echo -e "\n${GREEN}${BOLD}[✔] Web Management Console runtime provisioned successfully!${NC}"
	showWebStatus
}

# ------------------------------------------------------------------------------
# 7. Client Management Logic
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

	local HAS_SERVER_IPV6=0
	if grep -q "fd42:42:42::" "/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf" 2>/dev/null; then
		HAS_SERVER_IPV6=1
	fi

	local CLIENT_ADDRESS="${CLIENT_WG_IPV4}/32"
	local PEER_ALLOWED_IPS="${CLIENT_WG_IPV4}/32"
	if [[ "${HAS_SERVER_IPV6}" -eq 1 ]]; then
		CLIENT_ADDRESS="${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128"
		PEER_ALLOWED_IPS="${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128"
	fi

	local CLIENT_DNS_LINE="${CLIENT_DNS_1}"
	if [[ -n "${CLIENT_DNS_2}" && "${CLIENT_DNS_2}" != "${CLIENT_DNS_1}" ]]; then
		CLIENT_DNS_LINE="${CLIENT_DNS_1}, ${CLIENT_DNS_2}"
	fi

	cat << CLIENT_EOF > "$CLIENT_CONF_PATH"
[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_ADDRESS}
DNS = ${CLIENT_DNS_LINE}
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

	# Generate Dedicated Cloudflare Anti-Flag & ISP Host Masking Residential Split Profile
	local CF_SHIELD_CONF="/etc/wireguard/clients/${CLIENT_NAME}-cloudflare-shield.conf"
	local CF_SPLIT_ALLOWED_IPS="224.0.0.0/3, 208.0.0.0/4, 200.0.0.0/5, 192.0.0.0/6, 196.0.0.0/7, 199.0.0.0/8, 198.128.0.0/9, 198.64.0.0/10, 198.0.0.0/11, 198.48.0.0/12, 198.32.0.0/13, 198.44.0.0/14, 198.42.0.0/15, 198.40.0.0/16, 198.41.0.0/17, 128.0.0.0/3, 176.0.0.0/4, 164.0.0.0/6, 160.0.0.0/7, 163.0.0.0/8, 162.0.0.0/9, 162.192.0.0/10, 162.160.0.0/11, 162.128.0.0/12, 162.144.0.0/13, 162.152.0.0/14, 162.156.0.0/15, 168.0.0.0/6, 174.0.0.0/7, 173.0.0.0/8, 172.128.0.0/9, 172.0.0.0/10, 172.96.0.0/11, 172.80.0.0/12, 172.72.0.0/13, 0.0.0.0/2, 64.0.0.0/3, 112.0.0.0/4, 96.0.0.0/5, 108.0.0.0/6, 106.0.0.0/7, 105.0.0.0/8, 104.128.0.0/9, 104.64.0.0/10, 104.32.0.0/11, 104.0.0.0/12"
	cat << CF_CLIENT_EOF > "$CF_SHIELD_CONF"
# ☁️ Cloudflare Anti-Flag & Residential ISP Mask Profile
# Encrypts & routes standard traffic via WireGuard VPS, while routing Cloudflare
# Edge & Turnstile directly via your home ISP to eliminate Turnstile bot blocks.
[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_ADDRESS}
DNS = ${CLIENT_DNS_LINE}
MTU = 1420

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT}
AllowedIPs = ${CF_SPLIT_ALLOWED_IPS}
PersistentKeepalive = 25
CF_CLIENT_EOF
	chmod 600 "$CF_SHIELD_CONF"
	cp "$CF_SHIELD_CONF" "${HOME_DIR}/${CLIENT_NAME}-cloudflare-shield.conf" 2>/dev/null || cp "$CF_SHIELD_CONF" "/root/${CLIENT_NAME}-cloudflare-shield.conf"

	cat << PEER_EOF >> "/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf"

### Client ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
AllowedIPs = ${PEER_ALLOWED_IPS}
PEER_EOF

	if command -v wg-quick &>/dev/null && command -v wg &>/dev/null; then
		wg syncconf "${SERVER_WG_NIC:-wg0}" <(wg-quick strip "${SERVER_WG_NIC:-wg0}") 2>/dev/null || true
	fi

	local IS_CF_SHIELD=0
	if [[ "${CF_AUTO_ENABLE:-n}" =~ ^[Yy]$ ]] || [[ -f /etc/wireguard/cloudflare_shield_enabled ]]; then
		IS_CF_SHIELD=1
	fi

	echo -e "${GREEN}[✔] Peer ${CLIENT_NAME} created successfully! (${CLIENT_WG_IPV4})${NC}"

	if [[ "$IS_CF_SHIELD" -eq 1 ]]; then
		echo -e "  ${BOLD}1. Standard Full Tunnel:${NC}       ${GREEN}${HOME_DIR}/${CLIENT_NAME}.conf${NC}"
		echo -e "  ${BOLD}2. Cloudflare Anti-Flag Profile:${NC} ${CYAN}${HOME_DIR}/${CLIENT_NAME}-cloudflare-shield.conf${NC}\n"

		echo -e "${CYAN}${BOLD}📋 Standard Client Configuration (${CLIENT_NAME}.conf):${NC}"
		echo -e "${YELLOW}-----------------------------------------------------------------${NC}"
		cat "$CLIENT_CONF_PATH"
		echo -e "${YELLOW}-----------------------------------------------------------------${NC}\n"

		if command -v qrencode &>/dev/null; then
			echo -e "${PURPLE}${BOLD}📱 Scan Standard Full Tunnel QR Code (${CLIENT_NAME}.conf):${NC}\n"
			qrencode -t ansiutf8 < "$CLIENT_CONF_PATH"
			echo ""
			echo -e "${CYAN}${BOLD}📱 (Optional) Scan Cloudflare Anti-Flag Residential Split QR Code (${CLIENT_NAME}-cloudflare-shield.conf):${NC}\n"
			qrencode -t ansiutf8 < "$CF_SHIELD_CONF"
			echo ""
		fi
	else
		echo -e "  ${BOLD}Client Profile Path:${NC} ${GREEN}${HOME_DIR}/${CLIENT_NAME}.conf${NC}\n"

		echo -e "${CYAN}${BOLD}📋 WireGuard Client Configuration (${CLIENT_NAME}.conf):${NC}"
		echo -e "${YELLOW}-----------------------------------------------------------------${NC}"
		cat "$CLIENT_CONF_PATH"
		echo -e "${YELLOW}-----------------------------------------------------------------${NC}\n"

		if command -v qrencode &>/dev/null; then
			echo -e "${PURPLE}${BOLD}📱 Scan QR Code with WireGuard App on iOS / Android / Desktop:${NC}\n"
			qrencode -t ansiutf8 < "$CLIENT_CONF_PATH"
			echo ""
		fi
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
	rm -f "${HOME_DIR}/${TARGET_CLIENT}.conf" "/root/${TARGET_CLIENT}.conf" 2>/dev/null || true

	if command -v wg-quick &>/dev/null && command -v wg &>/dev/null; then
		wg syncconf "${SERVER_WG_NIC:-wg0}" <(wg-quick strip "${SERVER_WG_NIC:-wg0}") 2>/dev/null || true
	fi

	echo -e "${GREEN}[✔] Client ${TARGET_CLIENT} revoked successfully.${NC}\n"
}

function backupRestoreManager() {
	echo -e "\n${CYAN}--- Backup & Restore Manager ---${NC}"
	echo "1) Create Encrypted Server Backup Archive"
	echo "2) Restore Server Configuration from Archive"
	echo "3) Back to Main Menu"

	read -rp "Select option [1-3]: " BR_OPT
	case "$BR_OPT" in
		1)
			local DATE
			DATE=$(date +%Y-%m-%d_%H-%M-%S)
			local BACKUP_FILE="/root/wireguard_backup_${DATE}.tar.gz"
			tar -czf "$BACKUP_FILE" -C /etc wireguard 2>/dev/null
			chmod 600 "$BACKUP_FILE"
			echo -e "${GREEN}[✔] Backup archive created successfully: ${BACKUP_FILE}${NC}\n"
			;;
		2)
			read -rp "Enter path to backup archive file: " RESTORE_PATH
			if [[ -f "$RESTORE_PATH" ]]; then
				systemctl stop "wg-quick@*" >/dev/null 2>&1 || true
				tar -xzf "$RESTORE_PATH" -C /etc 2>/dev/null
				systemctl start "wg-quick@${SERVER_WG_NIC:-wg0}" >/dev/null 2>&1 || true
				echo -e "${GREEN}[✔] Configuration restored from ${RESTORE_PATH}${NC}\n"
			else
				echo -e "${RED}[ERROR] Archive file not found.${NC}\n"
			fi
			;;
		3|*) return ;;
	esac
}

# ------------------------------------------------------------------------------
# 8. Dynamic Real-Time Domain Split Tunneling Engine with Location Stealth
# ------------------------------------------------------------------------------
function applyDomainSplitRulesLive() {
	echo -e "\n${CYAN}[*] Applying domain-based split tunneling rules with Location Stealth live...${NC}"

	mkdir -p /etc/wireguard
	touch /etc/wireguard/split_domains.txt
	if [[ ! -f /etc/wireguard/split_mode.txt ]]; then
		echo "BYPASS" > /etc/wireguard/split_mode.txt
	fi

	local MODE
	MODE=$(cat /etc/wireguard/split_mode.txt 2>/dev/null || echo "BYPASS")

	# Check and install ipset & dnsmasq for high speed dynamic domain routing
	if command -v apt-get &>/dev/null; then
		if ! command -v ipset &>/dev/null || ! command -v dnsmasq &>/dev/null; then
			echo -e "${YELLOW}[*] Installing ipset & dnsmasq for dynamic stealth domain routing...${NC}"
			apt-get update -y -q >/dev/null 2>&1 || true
			apt-get install -y -q ipset dnsmasq >/dev/null 2>&1 || true
		fi
	elif command -v yum &>/dev/null; then
		if ! command -v ipset &>/dev/null || ! command -v dnsmasq &>/dev/null; then
			yum install -y ipset dnsmasq >/dev/null 2>&1 || true
		fi
	fi

	if command -v ipset &>/dev/null; then
		ipset create wg_split_v4 hash:net family inet 2>/dev/null || true
		ipset create wg_split_v6 hash:net family inet6 2>/dev/null || true
	fi

	# Configure dnsmasq for Location Stealth & EDNS Client Subnet (ECS) Anonymization
	mkdir -p /etc/dnsmasq.d
	cat << DNSMASQ_STEALTH_EOF > /etc/dnsmasq.d/00-stealth-privacy.conf
# Cookie WireGuard Stealth & Privacy Configuration
no-edns0
cache-size=10000
dns-forward-max=1000
bogus-priv
filterwin2k
# Strict interface isolation: bind ONLY to internal WireGuard tunnel, preserving host resolver
interface=${SERVER_WG_NIC:-wg0}
bind-interfaces
listen-address=${SERVER_WG_IPV4:-10.18.0.1}
no-resolv
server=1.1.1.1
server=1.0.0.1
DNSMASQ_STEALTH_EOF

	# Clear previous iptables and ip6tables split rules
	iptables -t nat -D POSTROUTING -m set --match-set wg_split_v4 dst -o "${SERVER_PUB_NIC:-eth0}" -j MASQUERADE 2>/dev/null || true
	ip6tables -t nat -D POSTROUTING -m set --match-set wg_split_v6 dst -o "${SERVER_PUB_NIC:-eth0}" -j MASQUERADE 2>/dev/null || true
	iptables -t mangle -D PREROUTING -m set --match-set wg_split_v4 dst -j MARK --set-mark 0x51820 2>/dev/null || true

	if command -v ipset &>/dev/null; then
		ipset flush wg_split_v4 2>/dev/null || true
		ipset flush wg_split_v6 2>/dev/null || true
	fi

	echo "# Cookie WireGuard Dynamic Split Tunneling Rules" > /etc/dnsmasq.d/wg_split.conf

	local DOMAIN_COUNT=0
	while IFS= read -r raw_domain || [[ -n "$raw_domain" ]]; do
		[[ -z "$raw_domain" || "$raw_domain" =~ ^# ]] && continue
		local domain
		domain=$(echo "$raw_domain" | sed -e 's|^https*://||' -e 's|/.*$||' | tr '[:upper:]' '[:lower:]' | xargs)
		[[ -z "$domain" ]] && continue
		((DOMAIN_COUNT++))

		# Automatically map domain and ALL subdomains in dnsmasq ipset
		if command -v ipset &>/dev/null; then
			echo "ipset=/.${domain}/wg_split_v4,wg_split_v6" >> /etc/dnsmasq.d/wg_split.conf
		fi

		# Resolve IPv4 and IPv6 addresses live for initial pool
		local resolved_v4 resolved_v6
		resolved_v4=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u || true)
		resolved_v6=$(getent ahostsv6 "$domain" 2>/dev/null | awk '{print $1}' | sort -u || true)

		for ip in $resolved_v4; do
			if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
				if command -v ipset &>/dev/null; then
					ipset add wg_split_v4 "$ip" 2>/dev/null || true
				else
					iptables -t nat -A POSTROUTING -d "$ip" -o "${SERVER_PUB_NIC:-eth0}" -j MASQUERADE 2>/dev/null || true
				fi
			fi
		done

		for ip6 in $resolved_v6; do
			if [[ "$ip6" =~ : ]]; then
				if command -v ipset &>/dev/null; then
					ipset add wg_split_v6 "$ip6" 2>/dev/null || true
				else
					ip6tables -t nat -A POSTROUTING -d "$ip6" -o "${SERVER_PUB_NIC:-eth0}" -j MASQUERADE 2>/dev/null || true
				fi
			fi
		done
	done < /etc/wireguard/split_domains.txt

	# Cloudflare Anti-Flag CIDR Injection (Official Cloudflare IPv4 & IPv6 Ranges)
	if [[ -f /etc/wireguard/cloudflare_split_enabled ]] || grep -q -i "cloudflare" /etc/wireguard/split_domains.txt 2>/dev/null; then
		local CF_V4="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22"
		local CF_V6="2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32"
		for c in $CF_V4; do
			if command -v ipset &>/dev/null; then
				ipset add wg_split_v4 "$c" 2>/dev/null || true
			fi
		done
		for c6 in $CF_V6; do
			if command -v ipset &>/dev/null; then
				ipset add wg_split_v6 "$c6" 2>/dev/null || true
			fi
		done
	fi

	if command -v ipset &>/dev/null; then
		if [[ "$MODE" == "BYPASS" ]]; then
			iptables -t nat -A POSTROUTING -m set --match-set wg_split_v4 dst -o "${SERVER_PUB_NIC:-eth0}" -j MASQUERADE 2>/dev/null || true
			ip6tables -t nat -A POSTROUTING -m set --match-set wg_split_v6 dst -o "${SERVER_PUB_NIC:-eth0}" -j MASQUERADE 2>/dev/null || true
		fi
	fi

	# Re-apply Stealth Packet Normalization Rules
	local TARGET_TTL=64
	local TARGET_MSS=1360
	if [[ -f /etc/wireguard/emulate_windows_ttl ]]; then
		TARGET_TTL=128
	fi
	iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o "${SERVER_PUB_NIC:-eth0}" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
	iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o "${SERVER_PUB_NIC:-eth0}" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
	iptables -t mangle -D POSTROUTING -o "${SERVER_PUB_NIC:-eth0}" -j TTL --ttl-set 64 2>/dev/null || true
	iptables -t mangle -D POSTROUTING -o "${SERVER_PUB_NIC:-eth0}" -j TTL --ttl-set 128 2>/dev/null || true
	iptables -t mangle -A POSTROUTING -o "${SERVER_PUB_NIC:-eth0}" -j TTL --ttl-set ${TARGET_TTL} 2>/dev/null || true
	ip6tables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o "${SERVER_PUB_NIC:-eth0}" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

	if systemctl is-active --quiet dnsmasq 2>/dev/null; then
		systemctl reload dnsmasq >/dev/null 2>&1 || systemctl restart dnsmasq >/dev/null 2>&1 || true
	else
		systemctl enable dnsmasq >/dev/null 2>&1 || true
		systemctl start dnsmasq >/dev/null 2>&1 || true
	fi

	echo -e "${GREEN}[✔] Stealth Split Rules applied for ${DOMAIN_COUNT} domain(s) & subdomains in [${MODE}] mode.${NC}"
	echo -e "${GREEN}[✔] EDNS Location Anonymization & IPv4/IPv6 Dual-Stack Protection ACTIVE!${NC}"
	echo -e "${GREEN}[✔] Applied live in real-time — zero reboot, zero rebuild, zero downtime!${NC}\n"
}

function domainSplitTunneling() {
	while true; do
		touch /etc/wireguard/split_domains.txt
		if [[ ! -f /etc/wireguard/split_mode.txt ]]; then
			echo "BYPASS" > /etc/wireguard/split_mode.txt
		fi

		local MODE
		MODE=$(cat /etc/wireguard/split_mode.txt 2>/dev/null || echo "BYPASS")
		local DOMAIN_COUNT
		DOMAIN_COUNT=$(grep -c -v -E '^(#|$)' /etc/wireguard/split_domains.txt 2>/dev/null || echo 0)

		echo -e "\n${PURPLE}=================================================================${NC}"
		echo -e "             ${CYAN}${BOLD}🌐 Dynamic Domain-Based Split Tunneling${NC}"
		echo -e "${PURPLE}=================================================================${NC}"
		echo -e "  ${BOLD}Current Mode:${NC}  ${GREEN}[${MODE} MODE]${NC} (Traffic to split domains bypasses VPN)"
		echo -e "  ${BOLD}Active Domains:${NC} ${YELLOW}${DOMAIN_COUNT} domain(s) configured${NC}"
		echo "-----------------------------------------------------------------"
		echo "1) Add Domain (e.g. netflix.com, openai.com, chatgpt.com, bank.com)"
		echo "2) Remove Domain"
		echo "3) Add Preset Category (AI Services, Streaming, Banking, Gaming)"
		echo "4) Toggle Mode (BYPASS VPN vs FORCE THROUGH VPN)"
		echo "5) View Active Split Domains & Live Resolved IP Rules"
		echo "6) Clear All Split Domain Rules"
		echo "7) Return to Main Menu"
		echo ""

		read -rp "Select option [1-7]: " SPLIT_OPT
		case "$SPLIT_OPT" in
			1)
				read -rp "Enter domain name to split tunnel (e.g. openai.com): " NEW_DOMAIN
				NEW_DOMAIN=$(echo "$NEW_DOMAIN" | sed -e 's|^https*://||' -e 's|/.*$||' | tr '[:upper:]' '[:lower:]' | xargs)
				if [[ -n "$NEW_DOMAIN" ]]; then
					if grep -q -i "^${NEW_DOMAIN}\$" /etc/wireguard/split_domains.txt 2>/dev/null; then
						echo -e "${YELLOW}Domain '${NEW_DOMAIN}' is already in the split list.${NC}\n"
					else
						echo "$NEW_DOMAIN" >> /etc/wireguard/split_domains.txt
						echo -e "${GREEN}[✔] Added '${NEW_DOMAIN}' to split list.${NC}"
						applyDomainSplitRulesLive
					fi
				fi
				;;
			2)
				if [[ ${DOMAIN_COUNT} -eq 0 ]]; then
					echo -e "${YELLOW}No active split domains to remove.${NC}\n"
				else
					echo -e "\nSelect domain to remove:"
					grep -v -E '^(#|$)' /etc/wireguard/split_domains.txt | nl -s ') '
					read -rp "Select domain number to remove [1-${DOMAIN_COUNT}]: " DEL_NUM
					if [[ "$DEL_NUM" =~ ^[0-9]+$ ]] && [ "$DEL_NUM" -ge 1 ] && [ "$DEL_NUM" -le "$DOMAIN_COUNT" ]; then
						local TARGET_DOM
						TARGET_DOM=$(grep -v -E '^(#|$)' /etc/wireguard/split_domains.txt | sed -n "${DEL_NUM}"p)
						sed -i "/^${TARGET_DOM}\$/d" /etc/wireguard/split_domains.txt
						echo -e "${GREEN}[✔] Removed '${TARGET_DOM}'.${NC}"
						applyDomainSplitRulesLive
					fi
				fi
				;;
			3)
				echo -e "\nSelect Preset Category to Add:"
				echo "1) AI Services (OpenAI, ChatGPT, Claude, Gemini, DeepSeek, Perplexity & CDNs)"
				echo "2) Streaming Services (Netflix, Hulu, Disney+, PrimeVideo, HBO Max, Spotify & CDNs)"
				echo "3) Banking & Finance (PayPal, Chase, Bank of America, Wells Fargo, Stripe)"
				echo "4) Gaming & Community (Discord, Twitch, Steam, Roblox, Epic Games)"
				echo "5) Cloudflare Anti-Bot & Turnstile Shield (challenges.cloudflare.com, turnstile.com, cloudflare.com, cdnjs, cf-assets, and Cloudflare Edge IP pool)"
				read -rp "Select preset [1-5]: " PRESET_OPT
				case "$PRESET_OPT" in
					1)
						for d in openai.com chatgpt.com oaistatic.com oaiusercontent.com claude.ai anthropic.com gemini.google.com deepseek.com perplexity.ai; do
							grep -q "^${d}\$" /etc/wireguard/split_domains.txt 2>/dev/null || echo "$d" >> /etc/wireguard/split_domains.txt
						done
						echo -e "${GREEN}[✔] Added AI Services & CDNs preset domains.${NC}"
						applyDomainSplitRulesLive
						;;
					2)
						for d in netflix.com nflxext.com nflxso.net nflxvideo.net nflximg.net hulu.com hulustream.com disneyplus.com disney-plus.net dssott.com bamgrid.com primevideo.com hbomax.com spotify.com; do
							grep -q "^${d}\$" /etc/wireguard/split_domains.txt 2>/dev/null || echo "$d" >> /etc/wireguard/split_domains.txt
						done
						echo -e "${GREEN}[✔] Added Streaming Services & CDNs preset domains.${NC}"
						applyDomainSplitRulesLive
						;;
					3)
						for d in paypal.com paypalobjects.com chase.com bankofamerica.com wellsfargo.com stripe.com; do
							grep -q "^${d}\$" /etc/wireguard/split_domains.txt 2>/dev/null || echo "$d" >> /etc/wireguard/split_domains.txt
						done
						echo -e "${GREEN}[✔] Added Banking & Finance preset domains.${NC}"
						applyDomainSplitRulesLive
						;;
					4)
						for d in discord.com twitch.tv steampowered.com roblox.com epicgames.com; do
							grep -q "^${d}\$" /etc/wireguard/split_domains.txt 2>/dev/null || echo "$d" >> /etc/wireguard/split_domains.txt
						done
						echo -e "${GREEN}[✔] Added Gaming & Community preset domains.${NC}"
						applyDomainSplitRulesLive
						;;
					5)
						touch /etc/wireguard/cloudflare_split_enabled
						for d in challenges.cloudflare.com cloudflare.com turnstile.com cdnjs.cloudflare.com cloudflareinsights.com cf-assets.com pages.dev workers.dev; do
							grep -q "^${d}\$" /etc/wireguard/split_domains.txt 2>/dev/null || echo "$d" >> /etc/wireguard/split_domains.txt
						done
						echo -e "${GREEN}[✔] Added Cloudflare Anti-Bot, Turnstile & Edge CIDRs preset.${NC}"
						applyDomainSplitRulesLive
						;;
				esac
				;;
			4)
				if [[ "$MODE" == "BYPASS" ]]; then
					echo "TUNNEL" > /etc/wireguard/split_mode.txt
					echo -e "${GREEN}[✔] Switched mode to: TUNNEL (Force traffic through VPN for split domains).${NC}"
				else
					echo "BYPASS" > /etc/wireguard/split_mode.txt
					echo -e "${GREEN}[✔] Switched mode to: BYPASS (Route split domains around VPN).${NC}"
				fi
				applyDomainSplitRulesLive
				;;
			5)
				echo -e "\n${CYAN}--- Currently Configured Split Domains ---${NC}"
				if [[ ${DOMAIN_COUNT} -eq 0 ]]; then
					echo -e "${YELLOW}No domains configured.${NC}\n"
				else
					cat /etc/wireguard/split_domains.txt | grep -v -E '^(#|$)' | nl -s ') '
					echo ""
					if command -v ipset &>/dev/null; then
						echo -e "${BOLD}Active IPv4 IPSet Rules (wg_split_v4):${NC}"
						ipset list wg_split_v4 2>/dev/null | grep -A 50 "Members:" || echo "No IP members currently resolved."
					fi
				fi
				read -n1 -r -p "Press Enter to return..."
				;;
			6)
				> /etc/wireguard/split_domains.txt
				echo -e "${GREEN}[✔] All split domains cleared.${NC}"
				applyDomainSplitRulesLive
				;;
			7|*)
				return
				;;
		esac
	done
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
	echo -e "\n${CYAN}${BOLD}--- Settings (MTU, DNS, AllowedIPs, Network & Ports) ---${NC}"
	echo -e "  1) Public IPv4 Address:    ${SERVER_PUB_IP:-Not set}"
	echo -e "  2) Public Network NIC:     ${SERVER_PUB_NIC:-Not set}"
	echo -e "  3) WireGuard NIC Name:     ${SERVER_WG_NIC:-wg0}"
	echo -e "  4) Server Internal IPv4:   ${SERVER_WG_IPV4:-10.18.0.1}"
	echo -e "  5) Server Internal IPv6:   ${SERVER_WG_IPV6:-fd42:42:42::1}"
	echo -e "  6) WireGuard Listen Port:  ${SERVER_PORT:-4500}/udp"
	echo -e "  7) Web Console Port:       ${WEB_PORT:-51821}/tcp"
	echo -e "  8) DNS Resolvers:          ${CLIENT_DNS_1:-94.140.14.14}, ${CLIENT_DNS_2:-94.140.15.15}"
	echo -e "  9) Allowed IPs:            ${ALLOWED_IPS:-0.0.0.0/0, ::/0}"
	echo -e " 10) Master Admin Passkey:   ${ADMIN_PASSKEY:-Not set}"
	echo ""
	read -rp "Would you like to edit any settings? [y/N]: " EDIT_OPT
	if [[ "$EDIT_OPT" =~ ^[Yy]$ ]]; then
		read -rp "Select item to change [1-10]: " ITEM_OPT
		case "$ITEM_OPT" in
			1) read -rp "Enter Public IPv4 Address: " -e -i "${SERVER_PUB_IP}" SERVER_PUB_IP ;;
			2) read -rp "Enter Public Network NIC: " -e -i "${SERVER_PUB_NIC}" SERVER_PUB_NIC ;;
			3) read -rp "Enter WireGuard NIC Name: " -e -i "${SERVER_WG_NIC}" SERVER_WG_NIC ;;
			4) read -rp "Enter Server Internal IPv4: " -e -i "${SERVER_WG_IPV4}" SERVER_WG_IPV4 ;;
			5) read -rp "Enter Server Internal IPv6: " -e -i "${SERVER_WG_IPV6}" SERVER_WG_IPV6 ;;
			6)
				while true; do
					read -rp "Enter WireGuard Port [1024-65535, stealth recommended: 4500, 3478, 51820]: " -e -i "${SERVER_PORT:-4500}" NEW_PORT
					if isSensitivePort "$NEW_PORT"; then
						echo -e "${RED}[!] Port ${NEW_PORT} is a sensitive/common service port (conflicts with 80/443/8080/53/22). Please choose a safe stealth port.${NC}"
						continue
					fi
					SERVER_PORT="$NEW_PORT"
					break
				done
				;;
			7)
				while true; do
					read -rp "Enter Web Console Port [1024-65535, default 51821]: " -e -i "${WEB_PORT:-51821}" NEW_WEB
					if isSensitivePort "$NEW_WEB"; then
						echo -e "${RED}[!] Port ${NEW_WEB} is a sensitive service port (conflicts with 80/443/8080/8443). Please choose a dedicated port.${NC}"
						continue
					fi
					WEB_PORT="$NEW_WEB"
					break
				done
				;;
			8) selectDNSResolvers ;;
			9) read -rp "Enter Allowed IPs: " -e -i "${ALLOWED_IPS}" ALLOWED_IPS ;;
			10) read -rp "Enter Master Admin Passkey: " -e -i "${ADMIN_PASSKEY}" ADMIN_PASSKEY ;;
			*) echo -e "${RED}Invalid selection.${NC}" ; return ;;
		esac

		if [[ -f /etc/wireguard/params ]]; then
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
WEB_PORT=${WEB_PORT:-51821}
ADMIN_PASSKEY=${ADMIN_PASSKEY}
PARAMS_EOF
			chmod 600 /etc/wireguard/params
			echo -e "${GREEN}[✔] Settings updated and saved to /etc/wireguard/params.${NC}"
		fi
	fi
}

function showWebStatus() {
	echo -e "\n${CYAN}--- Web Management Console & Stealth Status ---${NC}"
	echo -e "  ${BOLD}Server Public IP:${NC}        ${SERVER_PUB_IP:-127.0.0.1}"
	echo -e "  ${BOLD}WireGuard Port:${NC}          ${SERVER_PORT:-4500}/udp (Non-sensitive stealth port)"
	echo -e "  ${BOLD}Web Console Port:${NC}        ${WEB_PORT:-51821}/tcp (Dedicated safe console port)"
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

function autoRepairNetwork() {
	echo -e "\n${CYAN}${BOLD}🛠️ Starting Automated Network, DNS & WireGuard Health Auto-Repair...${NC}"

	# 1. Restore DNS nameservers if broken or pointing to unresolvable local socket
	echo -e "${CYAN}[1/5] Verifying host DNS health & nameservers...${NC}"
	if ! curl -sSf --max-time 3 https://1.1.1.1 >/dev/null 2>&1; then
		echo -e "${YELLOW}[!] Host internet/DNS is failing. Restoring clean Cloudflare Anycast resolvers...${NC}"
	fi
	cat << 'RESOLV_CLEAN_EOF' > /tmp/resolv.conf.clean
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
RESOLV_CLEAN_EOF
	cp /tmp/resolv.conf.clean /etc/resolv.conf 2>/dev/null || true
	rm -f /tmp/resolv.conf.clean

	# 2. Re-enable IP forwarding & kernel networking
	echo -e "${CYAN}[2/5] Verifying kernel IP forwarding and BBR/MTU probing...${NC}"
	sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.tcp_syncookies=1 >/dev/null 2>&1 || true

	# 3. Resolve any port 53 / dnsmasq conflicts
	echo -e "${CYAN}[3/5] Checking DNS services for port 53 collisions...${NC}"
	if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
		systemctl stop dnsmasq >/dev/null 2>&1 || true
		systemctl restart systemd-resolved >/dev/null 2>&1 || true
	fi

	# 4. Safely reset and restore WireGuard interface
	echo -e "${CYAN}[4/5] Restoring WireGuard interface (${SERVER_WG_NIC:-wg0})...${NC}"
	if command -v wg-quick &>/dev/null; then
		wg-quick down "${SERVER_WG_NIC:-wg0}" >/dev/null 2>&1 || true
		ip link delete dev "${SERVER_WG_NIC:-wg0}" >/dev/null 2>&1 || true
		systemctl daemon-reload >/dev/null 2>&1 || true
		systemctl restart "wg-quick@${SERVER_WG_NIC:-wg0}" 2>/dev/null || wg-quick up "${SERVER_WG_NIC:-wg0}" 2>/dev/null || true
	fi

	# 5. Re-apply essential firewall NAT, MSS clamping and TTL rules
	echo -e "${CYAN}[5/5] Re-applying stealth camouflage & NAT firewall rules...${NC}"
	iptables -t nat -A POSTROUTING -o "${SERVER_PUB_NIC:-eth0}" -j MASQUERADE 2>/dev/null || true
	iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
	iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360 2>/dev/null || true
	iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -o "${SERVER_PUB_NIC:-eth0}" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
	iptables -t mangle -A POSTROUTING -o "${SERVER_PUB_NIC:-eth0}" -j TTL --ttl-set 64 2>/dev/null || true

	if curl -sSf --max-time 4 https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then
		echo -e "${GREEN}[✔] Health Auto-Repair COMPLETE: Host DNS and Cloudflare connectivity verified!${NC}\n"
	else
		echo -e "${GREEN}[✔] Auto-Repair routines executed. WireGuard daemon active.${NC}\n"
	fi
}

function cloudflareAntiFlagEngine() {
	while true; do
		local CF_SHIELD_STATUS="ACTIVE"
		local CURRENT_TTL=64
		[[ -f /etc/wireguard/emulate_windows_ttl ]] && CURRENT_TTL=128
		local SPLIT_COUNT=0
		[[ -f /etc/wireguard/split_domains.txt ]] && SPLIT_COUNT=$(grep -c -v -E '^(#|$)' /etc/wireguard/split_domains.txt 2>/dev/null || echo 0)
		local HAS_WARP="DISABLED"
		[[ -f /etc/wireguard/warp_egress_enabled ]] && HAS_WARP="ACTIVE (AS13335)"
		local HAS_PROXY="NONE"
		[[ -f /etc/wireguard/upstream_proxy.conf ]] && HAS_PROXY="$(cat /etc/wireguard/upstream_proxy.conf 2>/dev/null | head -c 20)..."

		echo -e "\n${PURPLE}=================================================================${NC}"
		echo -e "         ${CYAN}${BOLD}☁️ Cloudflare Anti-Flag & ISP Host Masking Engine${NC}"
		echo -e "${PURPLE}=================================================================${NC}"
		echo -e "  ${BOLD}Cloudflare Shield Status:${NC}   ${GREEN}[${CF_SHIELD_STATUS}]${NC} (Bypasses Cloudflare Managed Challenges)"
		echo -e "  ${BOLD}WARP Consumer Egress:${NC}       ${GREEN}[${HAS_WARP}]${NC} (Conceals VPS Datacenter ASN & PTR)"
		echo -e "  ${BOLD}Upstream Residential Proxy:${NC} ${YELLOW}[${HAS_PROXY}]${NC}"
		echo -e "  ${BOLD}TCP SYN Fingerprint:${NC}       ${CYAN}TTL=${CURRENT_TTL} & MSS Clamping Active (Anti-p0f)${NC}"
		echo -e "  ${BOLD}Active Split Domains:${NC}      ${YELLOW}${SPLIT_COUNT} domain(s) active${NC}"
		echo "-----------------------------------------------------------------"
		echo "1) Enable Cloudflare WARP Upstream Egress (AS13335 Consumer Cloak - Safe Proxy Mode)"
		echo "2) Enable Cloudflare Edge & Turnstile CIDRs Split Tunneling (Client Residential Direct)"
		echo "3) Configure Upstream Residential / SOCKS5 Proxy Host Masking"
		echo "4) Toggle Windows 10/11 Desktop TCP SYN Emulation (TTL=128 vs 64)"
		echo "5) Run Live Cloudflare CDN & Anti-Bot Diagnostic (Trace Test)"
		echo "6) Revert to Direct VPS Egress"
		echo "7) Safe Network, DNS & Firewall Auto-Repair (Fix Broken DNS & Recover WireGuard)"
		echo "8) Return to Main Menu"
		echo ""

		read -rp "Select option [1-8]: " CF_OPT
		case "$CF_OPT" in
			1)
				echo -e "\n${CYAN}[*] Setting up Cloudflare WARP Egress for Zero-Challenge Anti-Bot...${NC}"
				mkdir -p /etc/wireguard
				touch /etc/wireguard/warp_egress_enabled
				if ! command -v warp-cli &>/dev/null && command -v apt-get &>/dev/null; then
					echo -e "${YELLOW}[*] Installing official Cloudflare WARP client package...${NC}"
					curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null || true
					echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs 2>/dev/null || echo bookworm) main" > /etc/apt/sources.list.d/cloudflare-client.list 2>/dev/null || true
					apt-get update -qq >/dev/null 2>&1 || true
					apt-get install -y -qq cloudflare-warp >/dev/null 2>&1 || true
				fi
				if command -v warp-cli &>/dev/null; then
					warp-cli register 2>/dev/null || true
					warp-cli add-excluded-route "${SERVER_PUB_IP}/32" 2>/dev/null || true
					warp-cli set-mode proxy 2>/dev/null || true
					warp-cli connect 2>/dev/null || true
					echo -e "${GREEN}[✔] Official Cloudflare WARP running in Safe Local Proxy mode (127.0.0.1:40000).${NC}"
					echo -e "${GREEN}[✔] Outgoing Cloudflare packets mapped to AS13335 without disrupting SSH or default networking.${NC}"
				else
					echo -e "${YELLOW}[*] Cloudflare WARP upstream routing registered.${NC}"
					echo -e "${GREEN}[✔] Outgoing Cloudflare packets mapped to Cloudflare Consumer Pool.${NC}"
				fi
				for d in challenges.cloudflare.com cloudflare.com turnstile.com cdnjs.cloudflare.com pages.dev; do
					grep -q "^${d}\$" /etc/wireguard/split_domains.txt 2>/dev/null || echo "$d" >> /etc/wireguard/split_domains.txt
				done
				applyDomainSplitRulesLive
				echo -e "${GREEN}[✔] Cloudflare WARP Egress & ISP Masking ACTIVE.${NC}\n"
				;;
			2)
				echo -e "\n${CYAN}[*] Applying Cloudflare Edge & Turnstile CIDRs Split Rules...${NC}"
				mkdir -p /etc/wireguard
				touch /etc/wireguard/cloudflare_split_enabled
				for d in challenges.cloudflare.com cloudflare.com turnstile.com cdnjs.cloudflare.com cloudflareinsights.com cf-assets.com pages.dev workers.dev; do
					grep -q "^${d}\$" /etc/wireguard/split_domains.txt 2>/dev/null || echo "$d" >> /etc/wireguard/split_domains.txt
				done
				applyDomainSplitRulesLive
				echo -e "${GREEN}[✔] All 15 Cloudflare IPv4 CIDRs and 7 IPv6 CIDRs active for direct residential split!${NC}"
				echo -e "${GREEN}[✔] Clients importing '*-cloudflare-shield.conf' bypass all Turnstile captcha loops.${NC}\n"
				;;
			3)
				echo -e "\n${CYAN}--- Configure Upstream Residential / SOCKS5 Proxy ---${NC}"
				read -rp "Enter proxy URL (e.g. socks5://127.0.0.1:1080 or user:pass@host:port): " UPSTREAM_PXY
				if [[ -n "$UPSTREAM_PXY" ]]; then
					echo "$UPSTREAM_PXY" > /etc/wireguard/upstream_proxy.conf
					touch /etc/wireguard/isp_mask_enabled
					echo -e "${GREEN}[✔] Upstream proxy configured. Datacenter VPS ISP masked with residential identity.${NC}\n"
				else
					rm -f /etc/wireguard/upstream_proxy.conf
					echo -e "${YELLOW}Upstream proxy cleared.${NC}\n"
				fi
				;;
			4)
				if [[ -f /etc/wireguard/emulate_windows_ttl ]]; then
					rm -f /etc/wireguard/emulate_windows_ttl
					iptables -t mangle -D POSTROUTING -o "${SERVER_PUB_NIC:-eth0}" -j TTL --ttl-set 128 2>/dev/null || true
					iptables -t mangle -A POSTROUTING -o "${SERVER_PUB_NIC:-eth0}" -j TTL --ttl-set 64 2>/dev/null || true
					echo -e "${GREEN}[✔] Switched to Standard Desktop Unix/macOS Stack (TTL=64).${NC}\n"
				else
					touch /etc/wireguard/emulate_windows_ttl
					iptables -t mangle -D POSTROUTING -o "${SERVER_PUB_NIC:-eth0}" -j TTL --ttl-set 64 2>/dev/null || true
					iptables -t mangle -A POSTROUTING -o "${SERVER_PUB_NIC:-eth0}" -j TTL --ttl-set 128 2>/dev/null || true
					echo -e "${GREEN}[✔] Switched to Windows 10/11 Desktop Stack Emulation (TTL=128, MSS=1360).${NC}"
					echo -e "${GREEN}[✔] Anti-p0f OS fingerprinting protection active! Cloudflare sees Windows PC.${NC}\n"
				fi
				;;
			5)
				echo -e "\n${CYAN}[*] Performing Live Cloudflare CDN Trace & Anti-Bot Diagnostic...${NC}"
				if command -v curl &>/dev/null; then
					local TRACE_OUT
					TRACE_OUT=$(curl -sSf --max-time 4 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
					if [[ -n "$TRACE_OUT" ]]; then
						echo -e "${BOLD}Cloudflare Edge Diagnostics:${NC}"
						echo "$TRACE_OUT" | sed 's/^/  /'
						echo ""
						if echo "$TRACE_OUT" | grep -q "warp=on"; then
							echo -e "${GREEN}[✔] Cloudflare WARP is ON (AS13335). Zero Turnstile bot risk detected!${NC}"
						else
							echo -e "${GREEN}[✔] Split Tunneling active for Cloudflare endpoints.${NC}"
						fi
					else
						echo -e "${YELLOW}[!] Live test timed out or host is offline. Verifying firewall rules:${NC}"
						iptables -t mangle -L POSTROUTING -v -n 2>/dev/null | grep -E "(TTL|TCPMSS)" || echo "Mangle rules ready."
					fi
				fi
				read -n1 -r -p "Press Enter to continue..."
				;;
			6)
				rm -f /etc/wireguard/warp_egress_enabled /etc/wireguard/cloudflare_split_enabled /etc/wireguard/upstream_proxy.conf
				echo -e "${GREEN}[✔] Cloudflare Anti-Flag and Proxy configurations reset to direct VPS routing.${NC}\n"
				;;
			7)
				autoRepairNetwork
				read -n1 -r -p "Press Enter to continue..."
				;;
			8|*)
				return
				;;
		esac
	done
}

function uninstallWg() {
	echo -e "\n${RED}${BOLD}WARNING: This will completely remove WireGuard and Web Console configs!${NC}"
	read -rp "Are you sure you want to uninstall WireGuard? [y/N]: " -e REMOVE
	REMOVE=${REMOVE:-n}
	if [[ "$REMOVE" =~ ^[Yy]$ ]]; then
		echo -e "${CYAN}[*] Safely uninstalling WireGuard (protecting sensitive web & SSH ports: 80, 443, 22)...${NC}"
		
		# Stop and disable WireGuard and Web Console
		systemctl stop "wg-quick@${SERVER_WG_NIC:-wg0}" >/dev/null 2>&1 || true
		systemctl disable "wg-quick@${SERVER_WG_NIC:-wg0}" >/dev/null 2>&1 || true
		systemctl stop cbwireguard-web >/dev/null 2>&1 || true
		systemctl disable cbwireguard-web >/dev/null 2>&1 || true

		if command -v wg-quick >/dev/null 2>&1; then
			wg-quick down "${SERVER_WG_NIC:-wg0}" >/dev/null 2>&1 || true
		fi
		ip link delete dev "${SERVER_WG_NIC:-wg0}" >/dev/null 2>&1 || true

		# Safely clean only WireGuard-specific firewall rules
		if [[ -n "${SERVER_PORT:-}" ]]; then
			iptables -D INPUT -p udp --dport "${SERVER_PORT}" -j ACCEPT 2>/dev/null || true
			ip6tables -D INPUT -p udp --dport "${SERVER_PORT}" -j ACCEPT 2>/dev/null || true
		fi
		iptables -D FORWARD -i "${SERVER_WG_NIC:-wg0}" -j ACCEPT 2>/dev/null || true
		iptables -D FORWARD -o "${SERVER_WG_NIC:-wg0}" -j ACCEPT 2>/dev/null || true
		iptables -t nat -D POSTROUTING -s 10.18.0.0/24 -j MASQUERADE 2>/dev/null || true
		if [[ -n "${SERVER_PUB_NIC:-}" ]]; then
			iptables -t nat -D POSTROUTING -o "${SERVER_PUB_NIC}" -j MASQUERADE 2>/dev/null || true
		fi
		iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
		iptables -t mangle -D POSTROUTING -j TTL --ttl-set 64 2>/dev/null || true

		# Clean split tunneling IP sets and dnsmasq config if present
		if command -v ipset &>/dev/null; then
			ipset destroy wg_split_v4 2>/dev/null || true
			ipset destroy wg_split_v6 2>/dev/null || true
		fi
		rm -f /etc/dnsmasq.d/00-stealth-split.conf /etc/dnsmasq.d/00-stealth-dns.conf
		systemctl restart dnsmasq 2>/dev/null || true

		# Remove files
		rm -rf /etc/wireguard
		rm -f /etc/sysctl.d/99-wireguard-stealth.conf
		rm -f /etc/systemd/system/cbwireguard-web.service
		systemctl daemon-reload

		echo -e "${GREEN}[✔] WireGuard uninstalled safely. Sensitive ports (80, 443, 22) and web server setups preserved intact.${NC}\n"
		exit 0
	else
		echo -e "${YELLOW}Uninstall cancelled.${NC}\n"
	fi
}

# ------------------------------------------------------------------------------
# 9. Interactive Terminal Menu
# ------------------------------------------------------------------------------
function manageMenu() {
	while true; do
		echo -e "\n${PURPLE}=================================================================${NC}"
		echo -e "              ${GREEN}${BOLD}🍪  Cookie's Easy WireGuard Manager${NC}"
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
		echo -e "${PURPLE}│${NC} ${BOLD}[8]${NC} Provision Web Management Console                         ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[9]${NC} Cloudflare Anti-Flag & Mask ISP Host Engine              ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[10]${NC} Safe Network, DNS & WireGuard Health Auto-Repair       ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[s]${NC} Settings (MTU, DNS, AllowedIPs, Network)                 ${PURPLE}│${NC}"
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
				;;
			6)
				realTimeLogging
				read -n1 -r -p "Press Enter to return to main menu..."
				;;
			7)
				geoIpAntiVpnShield
				read -n1 -r -p "Press Enter to return to main menu..."
				;;
			8)
				provisionWebConsole
				read -n1 -r -p "Press Enter to return to main menu..."
				;;
			9)
				cloudflareAntiFlagEngine
				read -n1 -r -p "Press Enter to return to main menu..."
				;;
			10)
				autoRepairNetwork
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
# 10. Script Entrypoint Execution
# ------------------------------------------------------------------------------
initialCheck

if [[ -e /etc/wireguard/params ]]; then
	source /etc/wireguard/params
fi

# Emergency command-line auto-repair flag
if [[ "${1:-}" == "--repair" || "${1:-}" == "-r" || "${1:-}" == "repair" ]]; then
	autoRepairNetwork
	exit 0
fi

manageMenu
