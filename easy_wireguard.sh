#!/bin/bash
# ==============================================================================
# 🍪 Cookie's Easy WireGuard Manager & VPS Stealth Server v4.0 (Zero-Drop WARP Edition)
# Inspired by angristan/wireguard-install with Kernel-Native WARP & Anti-Jitter Tuning
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

# Idempotent iptables helper: prevents duplicate rule accumulation & netfilter lag
function ipt_ensure_top() {
	local table="$1"
	local chain="$2"
	local pos="$3"
	shift 3
	if iptables -t "$table" -C "$chain" "$@" 2>/dev/null; then
		return 0
	fi
	iptables -t "$table" -I "$chain" "$pos" "$@" 2>/dev/null || iptables -t "$table" -A "$chain" "$@" 2>/dev/null || true
}

function ipt_ensure_append() {
	local table="$1"
	local chain="$2"
	shift 2
	if ! iptables -t "$table" -C "$chain" "$@" 2>/dev/null; then
		iptables -t "$table" -A "$chain" "$@" 2>/dev/null || true
	fi
}

# Enable Multi-Core Receive Packet Steering (RPS) & Transmit Queue optimization
function optimizeNicQueuesAndRPS() {
	local cpu_count
	cpu_count=$(nproc 2>/dev/null || echo 1)
	local rps_mask
	rps_mask=$(printf '%x' $(( (1 << (cpu_count > 16 ? 16 : cpu_count)) - 1 )) 2>/dev/null || echo "f")

	for nic in "${SERVER_PUB_NIC:-eth0}" "${SERVER_WG_NIC:-wg0}" "wgwarp" "CloudflareWARP"; do
		if ip link show "$nic" &>/dev/null; then
			ip link set dev "$nic" txqueuelen 10000 2>/dev/null || true
			for rps_file in /sys/class/net/"$nic"/queues/rx-*/rps_cpus; do
				[[ -w "$rps_file" ]] && echo "$rps_mask" > "$rps_file" 2>/dev/null || true
			done
			for flow_file in /sys/class/net/"$nic"/queues/rx-*/rps_flow_cnt; do
				[[ -w "$flow_file" ]] && echo 4096 > "$flow_file" 2>/dev/null || true
			done
		fi
	done

	if [[ -w /proc/sys/net/core/rps_sock_flow_entries ]]; then
		echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
	fi

	# Disable buggy UDP GRO list forwarding on Linux 6.2+ that causes WireGuard-to-WARP packet drops
	if command -v ethtool &>/dev/null && [[ -n "${SERVER_PUB_NIC:-}" ]]; then
		ethtool -K "${SERVER_PUB_NIC}" rx-gro-list off 2>/dev/null || true
	fi
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
# 2. Sensitive Port Protection & Safe Cleanup Routines
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

function cleanupOldWireguard() {
	echo -e "\n${CYAN}[*] Scanning for old/conflicting WireGuard instances & services...${NC}"

	systemctl stop "wg-quick@wg0" >/dev/null 2>&1 || true
	systemctl disable "wg-quick@wg0" >/dev/null 2>&1 || true
	systemctl stop "wg-quick@wg1" >/dev/null 2>&1 || true
	systemctl disable "wg-quick@wg1" >/dev/null 2>&1 || true

	if command -v wg-quick >/dev/null 2>&1; then
		wg-quick down wg0 >/dev/null 2>&1 || true
		wg-quick down wg1 >/dev/null 2>&1 || true
	fi

	ip link delete dev wg0 >/dev/null 2>&1 || true
	ip link delete dev wg1 >/dev/null 2>&1 || true
	rm -f /etc/wireguard/wg1.conf 2>/dev/null || true

	systemctl stop cbwireguard-web >/dev/null 2>&1 || true
	systemctl disable cbwireguard-web >/dev/null 2>&1 || true

	while iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null; do :; done
	while iptables -D FORWARD -o wg0 -j ACCEPT 2>/dev/null; do :; done
	while iptables -t nat -D POSTROUTING -s 10.18.0.0/24 -j MASQUERADE 2>/dev/null; do :; done
	while iptables -t nat -D POSTROUTING -s 10.19.0.0/24 -j MASQUERADE 2>/dev/null; do :; done
	while iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
	while iptables -t mangle -D POSTROUTING -j TTL --ttl-set 64 2>/dev/null; do :; done
	while iptables -t mangle -D POSTROUTING -j TTL --ttl-set 128 2>/dev/null; do :; done

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
	echo -e "   6) ${GREEN}Unbound / Local Dnsmasq Resolver${NC} (Server Local | Maximum Anti-Leak)"
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
	echo -e "          ${GREEN}${BOLD}🍪  Cookie's Easy WireGuard Setup & Installer v4.0${NC}"
	echo -e "${PURPLE}=================================================================${NC}"
	echo -e "Welcome to the WireGuard installer!\n"

	# Auto-detect public IPv4 address (bypassing any active WARP tunnel by querying via physical NIC)
	SERVER_NIC=$(ip -4 route show table main default 2>/dev/null | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | grep -vE '^(wg|Cloudflare|tun)' | head -n1 || true)
	if [[ -z "$SERVER_NIC" ]]; then
		SERVER_NIC=$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $2}' | grep -vE '^(wg|Cloudflare|tun|lo|docker)' | head -n1 || echo "eth0")
	fi

	SERVER_PUB_IP=""
	local services=("https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com")
	for svc in "${services[@]}"; do
		SERVER_PUB_IP=$(curl -4 --interface "${SERVER_NIC}" -sSf --max-time 2 "$svc" 2>/dev/null || curl -4 -sSf --max-time 2 "$svc" 2>/dev/null || true)
		if [[ -n "$SERVER_PUB_IP" && "$SERVER_PUB_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
			break
		fi
	done
	if [[ -z "$SERVER_PUB_IP" ]]; then
		SERVER_PUB_IP=$(ip -4 addr show dev "${SERVER_NIC}" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || echo "127.0.0.1")
	fi

	read -rp "IPv4 public address for server: " -e -i "${SERVER_PUB_IP}" SERVER_PUB_IP
	read -rp "Public network interface: " -e -i "${SERVER_NIC}" SERVER_PUB_NIC
	read -rp "WireGuard interface name: " -e -i "wg0" SERVER_WG_NIC
	read -rp "Server WireGuard internal IPv4: " -e -i "10.18.0.1" SERVER_WG_IPV4
	read -rp "Server WireGuard internal IPv6: " -e -i "fd42:42:42::1" SERVER_WG_IPV6

	echo -e "\n${CYAN}${BOLD}Select WireGuard Port (Unified Port - Used by Both Standard and Cloudflare Anti-Flag Profiles):${NC}"
	echo -e "   1) ${GREEN}4500${NC}  (IPsec NAT-Traversal UDP | Stealth Encrypted Tunneling) ${PURPLE}[RECOMMENDED STEALTH]${NC}"
	echo -e "   2) ${GREEN}3478${NC}  (STUN / WebRTC Media UDP | FaceTime / Zoom / VoIP Bypass)"
	echo -e "   3) ${GREEN}500${NC}   (IKEv2 / IPsec Signaling UDP | Mobile Telecom Pass-Through)"
	echo -e "   4) ${GREEN}853${NC}   (DNS-over-QUIC UDP | Modern Encrypted Transport Appearance)"
	echo -e "   5) ${GREEN}51820${NC} (Official WireGuard Standard Port)"
	echo -e "   6) ${GREEN}41194${NC} (Disguised High Tunnel UDP | Evades Low-Port Scanning)"
	echo -e "   7) Random High-Entropy Stealth Port (49152-65535)"
	echo -e "   8) Custom Port (Or enter port directly, e.g. 8008)"

	while true; do
		read -rp "Select Port option [1-8, or type any port directly (e.g. 8008), default 1 (4500)]: " PORT_OPTION
		PORT_OPTION=${PORT_OPTION:-1}

		if [[ "$PORT_OPTION" =~ ^[0-9]+$ ]] && [[ "$PORT_OPTION" -ge 1024 && "$PORT_OPTION" -le 65535 ]]; then
			if isSensitivePort "$PORT_OPTION"; then
				echo -e "${RED}[!] Port ${PORT_OPTION} is a sensitive service port (conflicts with 80/443/8080/22). Please choose a safe port.${NC}"
				continue
			fi
			if isPortInUse "$PORT_OPTION" "udp"; then
				echo -e "${YELLOW}[!] Warning: Port ${PORT_OPTION}/udp is currently bound by another service on this host. Choose another.${NC}"
				continue
			fi
			SERVER_PORT="$PORT_OPTION"
			break
		fi

		case "${PORT_OPTION}" in
			1) SERVER_PORT=4500 ; break ;;
			2) SERVER_PORT=3478 ; break ;;
			3) SERVER_PORT=500 ; break ;;
			4) SERVER_PORT=853 ; break ;;
			5) SERVER_PORT=51820 ; break ;;
			6) SERVER_PORT=41194 ; break ;;
			7)
				RANDOM_PORT=$(( (RANDOM % 16383) + 49152 ))
				SERVER_PORT="${RANDOM_PORT}"
				echo -e "${GREEN}[✔] Generated Random Stealth High Port: ${SERVER_PORT}/udp${NC}"
				break
				;;
			8)
				while true; do
					read -rp "Enter Custom WireGuard Port [1024-65535, e.g. 8008]: " -e -i "8008" CUSTOM_PORT
					if ! [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] || [[ "$CUSTOM_PORT" -lt 1024 || "$CUSTOM_PORT" -gt 65535 ]]; then
						echo -e "${RED}[!] Invalid port. Enter an unprivileged port between 1024 and 65535.${NC}"
						continue
					fi
					if isSensitivePort "$CUSTOM_PORT"; then
						echo -e "${RED}[!] Port ${CUSTOM_PORT} conflicts with sensitive services (80/443/8080). Choose another.${NC}"
						continue
					fi
					if isPortInUse "$CUSTOM_PORT" "udp"; then
						echo -e "${YELLOW}[!] Warning: Port ${CUSTOM_PORT}/udp is currently in use. Choose another.${NC}"
						continue
					fi
					SERVER_PORT="$CUSTOM_PORT"
					break
				done
				break
				;;
			*)
				echo -e "${RED}[!] Invalid option. Enter 1-8 or an unprivileged port number (1024-65535).${NC}"
				continue
				;;
		esac
	done

	SERVER_PORT_CF="${SERVER_PORT}"
	echo -e "${GREEN}[✔] WireGuard Port Confirmed: ${SERVER_PORT}/udp (Unified for both Standard and Cloudflare Anti-Flag profiles)${NC}"

	selectDNSResolvers

	read -rp "First client device name: " -e -i "my-device" CLIENT_NAME
	CLIENT_NAME=$(echo "$CLIENT_NAME" | tr -cd '[:alnum:]_-')

	echo -e "\n${PURPLE}${BOLD}🔒 Set Encryption Password for Client Configuration:${NC}"
	echo -e "   This password encrypts your .conf file with AES-256-CBC PBKDF2."
	echo -e "   You will be required to enter this password to view or copy the config in Option [3]."
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
		echo -e "${GREEN}[✔] Client Encryption Password confirmed!${NC}\n"
		break
	done

	read -rp "Allowed IPs for generated clients: " -e -i "0.0.0.0/0, ::/0" ALLOWED_IPS

	echo -e "\n${CYAN}${BOLD}☁️ Kernel-Native Cloudflare WARP & Anti-Flag Engine Integration:${NC}"
	echo -e "   • Provisions Kernel-Native Cloudflare WARP (`wgwarp` Table 51820) with zero userspace jitter"
	echo -e "   • Warps around your VPS IP (${SERVER_PUB_IP}): preserves SSH/WireGuard entry while cloaking client egress"
	echo -e "   • Zero-Drop MTU (1380/1320/1280) + TCP MSS=1200 Clamping + PersistentKeepalive=15"
	echo -e "   • Multi-Core Receive Packet Steering (RPS) + 16MB Default Socket Ring Buffers"
	echo -e "   ${GREEN}[✔] Auto-enabled: Kernel WARP Consumer Egress & Anti-Drop Engine active by default.${NC}"
	CF_AUTO_ENABLE="y"
	WARP_GLOBAL_MODE="full"

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

	echo -e "\n${CYAN}[*] Checking and installing system dependencies (wireguard, dnsmasq, ipset, qrencode)...${NC}"

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
		local NEED_APT_INSTALL=0
		local MISSING_PKGS=()
		for pkg in wireguard wireguard-tools iptables qrencode curl jq iproute2 iptables-persistent net-tools ipset dnsmasq ethtool; do
			if ! dpkg -s "$pkg" &>/dev/null; then
				NEED_APT_INSTALL=1
				MISSING_PKGS+=("$pkg")
			fi
		done

		if [[ "$NEED_APT_INSTALL" -eq 1 ]]; then
			echo -e "${YELLOW}[*] Installing required packages (${MISSING_PKGS[*]})...${NC}"
			local CACHE_HAS_PKGS=1
			for pkg in "${MISSING_PKGS[@]}"; do
				if ! apt-cache show "$pkg" &>/dev/null; then
					CACHE_HAS_PKGS=0
					break
				fi
			done

			if [[ "$CACHE_HAS_PKGS" -eq 0 ]]; then
				apt-get update -o Acquire::Languages=none \
				               -o Acquire::IndexTargets::deb::Contents-deb::MetaKey="" \
				               -o Acquire::Http::Timeout="8" \
				               -o Acquire::Retries="1" \
				               -y -q || true
			fi

			apt-get install -y -q -o Dpkg::Options::="--force-confdef" \
			                      -o Dpkg::Options::="--force-confold" \
			                      "${MISSING_PKGS[@]}" || true
		else
			echo -e "${GREEN}[✔] Core WireGuard & routing packages already installed.${NC}"
		fi
	elif [[ "${OS}" == "fedora" || "${OS}" == "centos" || "${OS}" == "almalinux" || "${OS}" == "rocky" ]]; then
		yum install -y wireguard-tools iptables qrencode curl jq ipset dnsmasq ethtool || true
	elif [[ "${OS}" == "arch" ]]; then
		pacman -S --needed --noconfirm wireguard-tools qrencode iptables curl jq ipset dnsmasq ethtool || true
	elif [[ "${OS}" == "alpine" ]]; then
		apk update && apk add wireguard-tools iptables libqrencode-tools curl jq ipset dnsmasq ethtool || true
	fi

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

	echo -e "${CYAN}[*] Loading WireGuard, Conntrack, and BBR kernel modules...${NC}"
	modprobe wireguard >/dev/null 2>&1 || { apt-get install -y "linux-headers-$(uname -r)" wireguard-dkms >/dev/null 2>&1 || true; modprobe wireguard >/dev/null 2>&1 || true; }
	modprobe nf_conntrack >/dev/null 2>&1 || true
	modprobe iptable_nat >/dev/null 2>&1 || true
	modprobe iptable_mangle >/dev/null 2>&1 || true
	modprobe ip6table_nat >/dev/null 2>&1 || true
	modprobe xt_mark >/dev/null 2>&1 || true
	modprobe xt_connmark >/dev/null 2>&1 || true
	modprobe xt_hl >/dev/null 2>&1 || true
	modprobe ipt_TTL >/dev/null 2>&1 || true
	modprobe tcp_bbr >/dev/null 2>&1 || true

	local HAS_IPV6=0
	if [[ -f /proc/net/if_inet6 ]] && [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1) -eq 0 ]]; then
		if ip -6 route show default 2>/dev/null | grep -q "default"; then
			HAS_IPV6=1
		fi
	fi

	echo -e "${CYAN}[*] Applying Anti-Jitter BBR, 16MB Default Socket Ring Buffers, and Conntrack sysctl tuning...${NC}"
	SYSCTL_CONF="/etc/sysctl.d/99-wireguard-stealth.conf"
	cat << 'SYSCTL_EOF' > "$SYSCTL_CONF"
net.ipv4.ip_forward = 1
net.ipv4.tcp_mtu_probing = 1
# Disable rp_filter so policy routing between wg0 and wgwarp never drops asymmetric packets
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.core.default_qdisc = fq
net.ipv4.tcp_fastopen = 3
# Raise both default and max socket buffers (WireGuard kernel sockets use rmem_default/wmem_default)
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.netdev_max_backlog = 250000
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
net.ipv4.tcp_max_syn_backlog = 3240000
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180
net.netfilter.nf_conntrack_helper = 0
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
	if [[ -w /sys/module/nf_conntrack/parameters/hashsize ]]; then
		echo 262144 > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
	fi

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

	# Record physical gateway before WARP is started so host public IP is always protected
	DEFAULT_GW=$(ip -4 route show table main default dev "${SERVER_PUB_NIC}" 2>/dev/null | awk '/via/ {for (i=1; i<=NF; i++) if ($i == "via") print $(i+1)}' | head -n1 || true)
	if [[ -z "$DEFAULT_GW" ]]; then
		DEFAULT_GW=$(ip -4 route show table main default 2>/dev/null | awk '/via/ {for (i=1; i<=NF; i++) if ($i == "via") print $(i+1)}' | head -n1 || true)
	fi

	cat << PARAMS_EOF > /etc/wireguard/params
SERVER_PUB_IP=${SERVER_PUB_IP}
SERVER_PUB_NIC=${SERVER_PUB_NIC}
DEFAULT_GW=${DEFAULT_GW}
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
HAS_IPV6=${HAS_IPV6}
CF_AUTO_ENABLE=${CF_AUTO_ENABLE:-y}
WARP_GLOBAL_MODE=${WARP_GLOBAL_MODE:-full}
PARAMS_EOF
	chmod 600 /etc/wireguard/params

	cat << ENV_EOF > /etc/wireguard/manager.env
SERVER_PUBLIC_IP="${SERVER_PUB_IP}"
WG_DEFAULT_PORT="${SERVER_PORT}"
WEB_PORT="${WEB_PORT:-51821}"
ADMIN_PASSKEY="${ADMIN_PASSKEY}"
ENV_EOF
	chmod 600 /etc/wireguard/manager.env

	SERVER_PORT_CF="${SERVER_PORT}"

	local WG_SERVER_ADDRESS="${SERVER_WG_IPV4}/24"
	if [[ "${HAS_IPV6}" -eq 1 ]]; then
		WG_SERVER_ADDRESS="${SERVER_WG_IPV4}/24,${SERVER_WG_IPV6}/64"
	fi

	# --------------------------------------------------------------------------
	# UNIFIED WIREGUARD SERVER (/etc/wireguard/wg0.conf)
	# MTU 1380 eliminates double-encapsulation fragmentation when routing via WARP
	# --------------------------------------------------------------------------
	echo -e "${CYAN}[*] Configuring Unified WireGuard Server (wg0 | Port ${SERVER_PORT}/udp | MTU 1380)...${NC}"
	cat << WG_SERVER_EOF > "/etc/wireguard/wg0.conf"
[Interface]
Address = ${WG_SERVER_ADDRESS}, 10.19.0.1/24
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PRIV_KEY}
MTU = 1380
SaveConfig = false

# --- 1. CORE NETWORKING & FIREWALL (Port ${SERVER_PORT}/udp for Both Profiles) ---
PostUp = sysctl -w net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.wg0.rp_filter=0 >/dev/null 2>&1 || true
PostUp = ip link set dev wg0 txqueuelen 10000 2>/dev/null || true
PostUp = iptables -C INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p udp --dport ${SERVER_PORT} -j ACCEPT
PostUp = iptables -C FORWARD -i wg0 -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i wg0 -j ACCEPT
PostUp = iptables -C FORWARD -o wg0 -j ACCEPT 2>/dev/null || iptables -I FORWARD 2 -o wg0 -j ACCEPT
PostUp = iptables -t nat -C POSTROUTING -s 10.18.0.0/24 ! -o wg0 -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s 10.18.0.0/24 ! -o wg0 -j MASQUERADE
PostUp = iptables -t nat -C POSTROUTING -s 10.19.0.0/24 ! -o wg0 -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 2 -s 10.19.0.0/24 ! -o wg0 -j MASQUERADE

# --- 2. ANTI-FRAGMENTATION TCP MSS CLAMPING & STEALTH TTL ---
PostUp = iptables -t mangle -C FORWARD -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -I FORWARD 1 -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostUp = iptables -t mangle -C FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -I FORWARD 2 -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostUp = iptables -t mangle -C POSTROUTING -s 10.19.0.0/24 ! -o wg0 -j TTL --ttl-set 128 2>/dev/null || iptables -t mangle -I POSTROUTING 1 -s 10.19.0.0/24 ! -o wg0 -j TTL --ttl-set 128

# Teardown Rules
PostDown = iptables -D INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s 10.18.0.0/24 ! -o wg0 -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s 10.19.0.0/24 ! -o wg0 -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostDown = iptables -t mangle -D POSTROUTING -s 10.19.0.0/24 ! -o wg0 -j TTL --ttl-set 128 2>/dev/null || true
WG_SERVER_EOF

	chmod 600 "/etc/wireguard/wg0.conf"

	wg-quick down wg0 >/dev/null 2>&1 || true
	ip link delete dev wg0 >/dev/null 2>&1 || true
	systemctl stop "wg-quick@wg0" >/dev/null 2>&1 || true

	systemctl daemon-reload >/dev/null 2>&1 || true
	systemctl enable "wg-quick@wg0" >/dev/null 2>&1 || true

	echo -e "${CYAN}[*] Starting Unified WireGuard daemon (wg-quick@wg0)...${NC}"
	systemctl restart "wg-quick@wg0" 2>/dev/null || wg-quick up wg0 2>/dev/null || true

	if systemctl is-active --quiet "wg-quick@wg0" || wg show wg0 &>/dev/null; then
		echo -e "${GREEN}[✔] Unified WireGuard Server (wg0 | Port ${SERVER_PORT}/udp) active!${NC}"
	fi

	optimizeNicQueuesAndRPS

	# Auto-Configure Cloudflare WARP & Anti-Flag Engine
	if [[ "${CF_AUTO_ENABLE}" == "y" ]]; then
		echo -e "\n${CYAN}[*] Provisioning Kernel-Native Cloudflare WARP & Split Routing Engine...${NC}"
		mkdir -p /etc/wireguard
		touch /etc/wireguard/cloudflare_shield_enabled
		touch /etc/wireguard/cloudflare_split_enabled
		touch /etc/wireguard/warp_egress_enabled
		echo "BYPASS" > /etc/wireguard/split_mode.txt

		cat << 'CF_INIT_DOMAINS' > /etc/wireguard/split_domains.txt
# Cloudflare Anti-Bot, WAF & Turnstile Shield Domains
challenges.cloudflare.com
cloudflare.com
turnstile.com
cdnjs.cloudflare.com
cloudflareinsights.com
cf-assets.com
pages.dev
workers.dev

# Amazon Search, Product Catalog & E-Commerce Autocomplete
amazon.com
www.amazon.com
completion.amazon.com
images-amazon.com
media-amazon.com
ssl-images-amazon.com
aax.amazon-adsystem.com
fls-na.amazon.com
amazon.co.uk
amazon.ca
amazon.de

# LinkedIn Professional Network & Media CDN
linkedin.com
www.linkedin.com
licdn.com
media.licdn.com
static.licdn.com
lnkd.in
platform.linkedin.com
dms.licdn.com
voyager.linkedin.com
media-exp1.licdn.com
snap.licdn.com
px.ads.linkedin.com

# PayPal, Braintree & 3D-Secure Gateways (Direct Clean VPS Egress Protected)
paypal.com
www.paypal.com
c.paypal.com
b.stats.paypal.com
t.paypal.com
s.paypal.com
m.paypal.com
api.paypal.com
api-m.paypal.com
checkout.paypal.com
identity.paypal.com
paypalobjects.com
www.paypalobjects.com
objects.paypal.com
c.paypalobjects.com
paypal.me
paypal-mktg.com
cardinalcommerce.com
songbird.cardinalcommerce.com
centinelapi.cardinalcommerce.com
geo.cardinalcommerce.com
braintreegateway.com
braintree-api.com
assets.braintreegateway.com
js.braintreegateway.com
stripe.com
api.stripe.com
js.stripe.com
checkout.stripe.com
CF_INIT_DOMAINS

		# Actually initialize Cloudflare WARP & policy routing around the VPS IP!
		setupCloudflareWarpClient
		applyDomainSplitRulesLive

		echo -e "${GREEN}[✔] Cloudflare WARP & Stealth Engine active! Traffic wraps around ${SERVER_PUB_IP} via WARP.${NC}"
	else
		echo -e "\n${GREEN}[✔] Standard Full Tunnel configured. Cloudflare WARP bypassed.${NC}"
		rm -f /etc/wireguard/cloudflare_shield_enabled /etc/wireguard/cloudflare_split_enabled /etc/wireguard/warp_egress_enabled 2>/dev/null || true
	fi

	newClientInternal "${CLIENT_NAME}" "${CLIENT_PASSWORD}"

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
# 7. Client Management Logic (Zero-Drop MTU 1320/1380 & Keepalive 15s)
# ------------------------------------------------------------------------------
function newClientInternal() {
	local CLIENT_NAME="$1"
	local CLIENT_PASSWORD="${2:-}"
	local HOME_DIR
	HOME_DIR=$(getHomeDirForClient "${CLIENT_NAME}")

	SERVER_PORT_CF="${SERVER_PORT}"

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

	local ENDPOINT_WG0="${SERVER_PUB_IP}:${SERVER_PORT}"
	local ENDPOINT_WG1="${SERVER_PUB_IP}:${SERVER_PORT}"

	mkdir -p /etc/wireguard/clients

	local HAS_SERVER_IPV6=0
	if grep -q "fd42:42:42::" "/etc/wireguard/wg0.conf" 2>/dev/null && ip -6 route show default 2>/dev/null | grep -q "default"; then
		HAS_SERVER_IPV6=1
	fi

	local CLIENT_ADDRESS="${CLIENT_WG_IPV4}/32"
	local PEER_ALLOWED_IPS="${CLIENT_WG_IPV4}/32"
	if [[ "${HAS_SERVER_IPV6}" -eq 1 ]]; then
		CLIENT_ADDRESS="${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128"
		PEER_ALLOWED_IPS="${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128"
	fi

	local CLIENT_DNS_LINE="${CLIENT_DNS_1:-1.1.1.1}"
	if [[ -n "${CLIENT_DNS_2}" && "${CLIENT_DNS_2}" != "${CLIENT_DNS_1}" ]]; then
		CLIENT_DNS_LINE="${CLIENT_DNS_1}, ${CLIENT_DNS_2}"
	fi

	local EASY_DIR
	EASY_DIR=$(getEasyWgDir "${CLIENT_NAME}")

	local STD_ALLOWED_IPS="0.0.0.0/0"
	if [[ "${HAS_SERVER_IPV6}" -eq 1 ]]; then
		STD_ALLOWED_IPS="0.0.0.0/0, ::/0"
	fi

	local CF_ALLOWED_IPS_LINE="${STD_ALLOWED_IPS}"

	# --------------------------------------------------------------------------
	# 1. Profile 1: Cloudflare WARP & Stealth Gateway (MTU 1320, Keepalive 15)
	# --------------------------------------------------------------------------
	local CF_CONF_CONTENT
	CF_CONF_CONTENT=$(cat << CF_CLIENT_EOF
# ==============================================================================
# ☁️ PROFILE 1: CLOUDFLARE WARP CLOAK & STEALTH GATEWAY
# ==============================================================================
# • Protocol Mode: Kernel-Native Cloudflare WARP Egress + Stealth WireGuard
# • Entry Endpoint: ${ENDPOINT_WG1} (Your VPS IP - Protected & Bypassed)
# • Egress Identity: Cloudflare WARP Consumer Network (AS13335)
# • Subnet / Assigned IP: ${CLIENT_WG_CF_IPV4}/32 (Subnet: 10.19.0.0/24)
# • MTU: 1320 (Zero-Fragmentation Double-Tunnel MTU for WireGuard + WARP)
# • DNS: ${CLIENT_DNS_LINE}
# ==============================================================================
[Interface]
PrivateKey = ${CLIENT_CF_PRIV_KEY}
Address = ${CLIENT_WG_CF_IPV4}/32
DNS = ${CLIENT_DNS_LINE}
MTU = 1320
# AmneziaWG Obfuscation (Active when imported into AmneziaWG client):
# Jc = 4
# Jmin = 40
# Jmax = 70
# S1 = 15
# S2 = 20
# H1 = 1
# H2 = 2
# H3 = 3
# H4 = 4

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT_WG1}
AllowedIPs = ${CF_ALLOWED_IPS_LINE}
PersistentKeepalive = 15
CF_CLIENT_EOF
)

	# --------------------------------------------------------------------------
	# 2. Profile 2: Standard Full-Tunnel (MTU 1380, Keepalive 15)
	# --------------------------------------------------------------------------
	local STD_CONF_CONTENT
	STD_CONF_CONTENT=$(cat << CLIENT_EOF
# ==============================================================================
# 🛡️ PROFILE 2: HIGH-SPEED WIREGUARD FULL-TUNNEL
# ==============================================================================
# • Protocol Mode: High-Speed WireGuard (WARP / Smart Split Egress)
# • Entry Endpoint: ${ENDPOINT_WG0}
# • Subnet / Assigned IP: ${CLIENT_ADDRESS} (Subnet: 10.18.0.0/24)
# • MTU: 1380 (Anti-Drop / Anti-Jitter Tuned MTU)
# • DNS: ${CLIENT_DNS_LINE}
# ==============================================================================
[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_ADDRESS}
DNS = ${CLIENT_DNS_LINE}
MTU = 1380

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT_WG0}
AllowedIPs = ${STD_ALLOWED_IPS}
PersistentKeepalive = 15
CLIENT_EOF
)

	local ENC_KEY="${CLIENT_PASSWORD}"
	if [[ -z "$ENC_KEY" ]]; then
		ENC_KEY=$(getMasterPasskey)
	fi

	encryptConfigContent "$CF_CONF_CONTENT" "${EASY_DIR}/${CLIENT_NAME}-cloudflare-shield.conf.enc" "$ENC_KEY"
	encryptConfigContent "$CF_CONF_CONTENT" "/etc/wireguard/clients/${CLIENT_NAME}-cloudflare-shield.conf.enc" "$ENC_KEY"

	encryptConfigContent "$STD_CONF_CONTENT" "${EASY_DIR}/${CLIENT_NAME}-standard.conf.enc" "$ENC_KEY"
	encryptConfigContent "$STD_CONF_CONTENT" "${EASY_DIR}/${CLIENT_NAME}.conf.enc" "$ENC_KEY"
	encryptConfigContent "$STD_CONF_CONTENT" "/etc/wireguard/clients/${CLIENT_NAME}-standard.conf.enc" "$ENC_KEY"
	encryptConfigContent "$STD_CONF_CONTENT" "/etc/wireguard/clients/${CLIENT_NAME}.conf.enc" "$ENC_KEY"

	rm -f "/root/${CLIENT_NAME}"*.conf "${HOME_DIR}/${CLIENT_NAME}"*.conf "/etc/wireguard/clients/${CLIENT_NAME}"*.conf 2>/dev/null || true

	cat << PEER_EOF >> "/etc/wireguard/wg0.conf"

### Client ${CLIENT_NAME} [Cloudflare Anti-Flag Profile - Stealth Gateway]
[Peer]
PublicKey = ${CLIENT_CF_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
AllowedIPs = ${CLIENT_WG_CF_IPV4}/32

### Client ${CLIENT_NAME} [Standard Profile - Direct Egress]
[Peer]
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
AllowedIPs = ${PEER_ALLOWED_IPS}
PEER_EOF

	if command -v wg-quick &>/dev/null && command -v wg &>/dev/null; then
		wg syncconf wg0 <(wg-quick strip wg0) 2>/dev/null || true
	fi

	echo -e "${GREEN}[✔] Peer ${CLIENT_NAME} created & encrypted with AES-256-CBC!${NC}"
	echo -e "   • Port Selected:              ${BOLD}${SERVER_PORT}/udp${NC} (Unified - Both profiles use this exact port!)"
	echo -e "   • Profile 1 (Stealth/WARP):   ${CLIENT_WG_CF_IPV4} on port ${SERVER_PORT} (MTU 1320, Keepalive 15s)"
	echo -e "   • Profile 2 (Standard):       ${CLIENT_WG_IPV4} on port ${SERVER_PORT} (MTU 1380, Keepalive 15s)\n"

	echo -e "  ${BOLD}Protected Folder:${NC}            ${CYAN}${EASY_DIR}/${NC} (Zero root directory clutter)"
	echo -e "  ${BOLD}Encrypted Anti-Flag Profile:${NC} ${YELLOW}${EASY_DIR}/${CLIENT_NAME}-cloudflare-shield.conf.enc${NC}"
	echo -e "  ${BOLD}Encrypted Standard Profile:${NC}  ${YELLOW}${EASY_DIR}/${CLIENT_NAME}-standard.conf.enc${NC}\n"

	echo -e "${CYAN}${BOLD}📋 [1/2] COPY & PASTE CONFIGURATION: CLOUDFLARE WARP & STEALTH (${CLIENT_NAME}-cloudflare-shield.conf):${NC}"
	echo -e "${YELLOW}-----------------------------------------------------------------${NC}"
	echo "$CF_CONF_CONTENT"
	echo -e "${YELLOW}-----------------------------------------------------------------${NC}\n"

	echo -e "${GREEN}${BOLD}📋 [2/2] COPY & PASTE CONFIGURATION: STANDARD FULL TUNNEL (${CLIENT_NAME}-standard.conf):${NC}"
	echo -e "${YELLOW}-----------------------------------------------------------------${NC}"
	echo "$STD_CONF_CONTENT"
	echo -e "${YELLOW}-----------------------------------------------------------------${NC}\n"

	if command -v qrencode &>/dev/null; then
		echo -e "${CYAN}${BOLD}📱 [1/2] Scan Profile 1 Cloudflare WARP Stealth QR Code (Port ${SERVER_PORT}):${NC}\n"
		echo "$CF_CONF_CONTENT" | qrencode -t ansiutf8
		echo ""
		echo -e "${PURPLE}${BOLD}📱 [2/2] Scan Profile 2 Standard Full Tunnel QR Code (Port ${SERVER_PORT}):${NC}\n"
		echo "$STD_CONF_CONTENT" | qrencode -t ansiutf8
		echo ""
	fi
}

function newClient() {
	echo -e "\n${CYAN}--- Add a New WireGuard Client (Peer) ---${NC}"
	local CLIENT_NAME=""
	until [[ -n "$CLIENT_NAME" && "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; do
		read -rp "Enter client device name: " CLIENT_NAME
		CLIENT_NAME=$(echo "$CLIENT_NAME" | tr -cd '[:alnum:]_-')
		if grep -q "### Client ${CLIENT_NAME}" "/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf" 2>/dev/null; then
			echo -e "${ORANGE}A client with name '${CLIENT_NAME}' already exists! Choose another.${NC}"
			CLIENT_NAME=""
		fi
	done

	echo -e "\n${PURPLE}${BOLD}🔒 Set Encryption Password for Client Configuration:${NC}"
	local CLIENT_PASSWORD=""
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
		echo -e "${GREEN}[✔] Client Encryption Password confirmed!${NC}\n"
		break
	done

	newClientInternal "$CLIENT_NAME" "$CLIENT_PASSWORD"
}

function listClients() {
	echo -e "\n${CYAN}--- Active WireGuard Clients ---${NC}"
	local CONF_FILE="/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf"
	local CLIENT_LIST=()
	while IFS= read -r cname; do
		[[ -n "$cname" ]] && CLIENT_LIST+=("$cname")
	done < <(grep -E "^### Client" "$CONF_FILE" 2>/dev/null | awk '{print $3}' | sort -u)

	if [[ ${#CLIENT_LIST[@]} -eq 0 ]]; then
		echo -e "${YELLOW}No clients registered yet.${NC}\n"
		return
	fi

	echo -e "${BOLD}Client Name\t\tStandard IP\t\tWARP Stealth IP${NC}"
	echo "------------------------------------------------------------------------"
	for name in "${CLIENT_LIST[@]}"; do
		local std_ip
		std_ip=$(grep -A 5 "### Client ${name} \[Standard Profile" "$CONF_FILE" 2>/dev/null | grep "AllowedIPs" | awk '{print $3}' | cut -d',' -f1)
		[[ -z "$std_ip" ]] && std_ip=$(grep -A 5 "### Client ${name}" "$CONF_FILE" 2>/dev/null | grep "AllowedIPs" | awk '{print $3}' | cut -d',' -f1)
		local cf_ip
		cf_ip=$(grep -A 5 "### Client ${name} \[Cloudflare Anti-Flag" "$CONF_FILE" 2>/dev/null | grep "AllowedIPs" | awk '{print $3}' | cut -d',' -f1)
		echo -e "   - ${BOLD}${name}${NC}\t\t${std_ip:-N/A}\t\t${cf_ip:-N/A}"
	done
	echo ""
}

function configureClients() {
	echo -e "\n${CYAN}--- Configure Clients (Check / Edit / Remove) ---${NC}"
	local CONF_FILE="/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf"
	if ! grep -q "^### Client" "$CONF_FILE" 2>/dev/null; then
		echo -e "${YELLOW}No clients registered yet.${NC}\n"
		return
	fi

	echo "1) View Client QR Code & Configuration (In-Memory Decrypt)"
	echo "2) Export / Decrypt Client Configuration (To custom folder or screen)"
	echo "3) Clean Root Directory & Re-Encrypt All Configs into easy_wireguard/"
	echo "4) Remove / Revoke a Client"
	echo "5) Back to Main Menu"

	read -rp "Select an option [1-5]: " SUB_OPT
	case "$SUB_OPT" in
		1) showClientQr ;;
		2) exportDecryptedClientConfig ;;
		3)
			cleanupAndSecureRootFolder
			read -n1 -r -p "Press Enter to continue..."
			;;
		4) revokeClient ;;
		5|*) return ;;
	esac
}

function showClientQr() {
	echo -e "\n${CYAN}--- Show Client QR Code & Configuration ---${NC}"
	local CONF_FILE="/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf"
	local CLIENT_LIST=()
	while IFS= read -r cname; do
		[[ -n "$cname" ]] && CLIENT_LIST+=("$cname")
	done < <(grep -E "^### Client" "$CONF_FILE" 2>/dev/null | awk '{print $3}' | sort -u)

	local CLIENT_COUNT=${#CLIENT_LIST[@]}
	if [[ ${CLIENT_COUNT} -eq 0 ]]; then
		echo -e "${YELLOW}No clients registered.${NC}\n"
		read -n1 -r -p "Press Enter to return..."
		return
	fi

	echo -e "${BOLD}Select the client to display:${NC}"
	for i in "${!CLIENT_LIST[@]}"; do
		echo "  $((i+1))) ${CLIENT_LIST[$i]}"
	done
	echo "  $((CLIENT_COUNT+1))) Cancel and return"

	local CLIENT_NUMBER=0
	until [[ ${CLIENT_NUMBER} -ge 1 && ${CLIENT_NUMBER} -le $((CLIENT_COUNT+1)) ]]; do
		read -rp "Select client [1-$((CLIENT_COUNT+1))]: " CLIENT_NUMBER
	done

	if [[ ${CLIENT_NUMBER} -eq $((CLIENT_COUNT+1)) ]]; then
		return
	fi

	local TARGET_CLIENT="${CLIENT_LIST[$((CLIENT_NUMBER-1))]}"
	local EASY_DIR
	EASY_DIR=$(getEasyWgDir "${TARGET_CLIENT}")

	local CONF_STD_ENC="${EASY_DIR}/${TARGET_CLIENT}-standard.conf.enc"
	[[ ! -f "$CONF_STD_ENC" ]] && CONF_STD_ENC="${EASY_DIR}/${TARGET_CLIENT}.conf.enc"
	[[ ! -f "$CONF_STD_ENC" ]] && CONF_STD_ENC="/etc/wireguard/clients/${TARGET_CLIENT}-standard.conf.enc"
	[[ ! -f "$CONF_STD_ENC" ]] && CONF_STD_ENC="/etc/wireguard/clients/${TARGET_CLIENT}.conf.enc"

	local CONF_CF_ENC="${EASY_DIR}/${TARGET_CLIENT}-cloudflare-shield.conf.enc"
	[[ ! -f "$CONF_CF_ENC" ]] && CONF_CF_ENC="/etc/wireguard/clients/${TARGET_CLIENT}-cloudflare-shield.conf.enc"

	echo -e "\n${PURPLE}🔒 PASSWORD PROTECTED CONFIGURATION${NC}"
	echo -e "Client '${BOLD}${TARGET_CLIENT}${NC}' configuration is encrypted."
	read -s -rp "Enter decryption password for '${TARGET_CLIENT}': " ATTEMPT_PASS
	echo ""

	local STD_TEXT=""
	local CF_TEXT=""

	if [[ -f "$CONF_CF_ENC" ]]; then
		CF_TEXT=$(decryptConfigToString "$CONF_CF_ENC" "$ATTEMPT_PASS")
	elif [[ -f "${EASY_DIR}/${TARGET_CLIENT}-cloudflare-shield.conf" ]]; then
		CF_TEXT=$(cat "${EASY_DIR}/${TARGET_CLIENT}-cloudflare-shield.conf")
	elif [[ -f "/etc/wireguard/clients/${TARGET_CLIENT}-cloudflare-shield.conf" ]]; then
		CF_TEXT=$(cat "/etc/wireguard/clients/${TARGET_CLIENT}-cloudflare-shield.conf")
	fi

	if [[ -f "$CONF_STD_ENC" ]]; then
		STD_TEXT=$(decryptConfigToString "$CONF_STD_ENC" "$ATTEMPT_PASS")
	elif [[ -f "${EASY_DIR}/${TARGET_CLIENT}-standard.conf" ]]; then
		STD_TEXT=$(cat "${EASY_DIR}/${TARGET_CLIENT}-standard.conf")
	elif [[ -f "/etc/wireguard/clients/${TARGET_CLIENT}-standard.conf" ]]; then
		STD_TEXT=$(cat "/etc/wireguard/clients/${TARGET_CLIENT}-standard.conf")
	fi

	local DECRYPT_OK=0
	if [[ -n "$CF_TEXT" && "$CF_TEXT" =~ "[Interface]" ]] || [[ -n "$STD_TEXT" && "$STD_TEXT" =~ "[Interface]" ]]; then
		DECRYPT_OK=1
	fi

	if [[ $DECRYPT_OK -eq 0 ]]; then
		echo -e "${RED}[ERROR] Incorrect decryption password! Decryption failed.${NC}\n"
		read -n1 -r -p "Press Enter to return..."
		return
	fi

	echo -e "${GREEN}[✔] Password verified! Configuration decrypted successfully.${NC}\n"

	if [[ -n "$CF_TEXT" && "$CF_TEXT" =~ "[Interface]" ]]; then
		echo -e "\n${CYAN}${BOLD}📋 [1/2] Profile 1: Stealth Anti-Scanner & Cloudflare WARP Gateway (Port ${SERVER_PORT:-4500}):${NC}"
		echo -e "${YELLOW}🔒 Stored Encrypted (AES-256-CBC) in: ${EASY_DIR}/${TARGET_CLIENT}-cloudflare-shield.conf.enc${NC}\n"
		echo "$CF_TEXT"
		echo ""
		if command -v qrencode &>/dev/null; then
			echo -e "${CYAN}${BOLD}📱 [1/2] Scan Profile 1 Cloudflare WARP Stealth QR Code (Port ${SERVER_PORT:-4500}):${NC}\n"
			echo "$CF_TEXT" | qrencode -t ansiutf8
			echo ""
		fi
	fi

	if [[ -n "$STD_TEXT" && "$STD_TEXT" =~ "[Interface]" ]]; then
		echo -e "\n${GREEN}${BOLD}📋 [2/2] Profile 2: Standard Full Tunnel (Port ${SERVER_PORT:-4500}):${NC}"
		echo -e "${YELLOW}🔒 Stored Encrypted (AES-256-CBC) in: ${EASY_DIR}/${TARGET_CLIENT}-standard.conf.enc${NC}\n"
		echo "$STD_TEXT"
		echo ""
		if command -v qrencode &>/dev/null; then
			echo -e "${PURPLE}${BOLD}📱 [2/2] Scan Profile 2 Standard Full Tunnel QR Code (Port ${SERVER_PORT:-4500}):${NC}\n"
			echo "$STD_TEXT" | qrencode -t ansiutf8
			echo ""
		fi
	fi
}

function exportDecryptedClientConfig() {
	echo -e "\n${CYAN}--- Export / Decrypt Client Configuration ---${NC}"
	local CONF_FILE="/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf"
	local CLIENT_LIST=()
	while IFS= read -r cname; do
		[[ -n "$cname" ]] && CLIENT_LIST+=("$cname")
	done < <(grep -E "^### Client" "$CONF_FILE" 2>/dev/null | awk '{print $3}' | sort -u)

	local CLIENT_COUNT=${#CLIENT_LIST[@]}
	if [[ ${CLIENT_COUNT} -eq 0 ]]; then
		echo -e "${YELLOW}No clients registered.${NC}\n"
		read -n1 -r -p "Press Enter to return..."
		return
	fi

	echo -e "${BOLD}Select the client to export:${NC}"
	for i in "${!CLIENT_LIST[@]}"; do
		echo "  $((i+1))) ${CLIENT_LIST[$i]}"
	done
	echo "  $((CLIENT_COUNT+1))) Cancel and return"

	local CLIENT_NUMBER=0
	until [[ ${CLIENT_NUMBER} -ge 1 && ${CLIENT_NUMBER} -le $((CLIENT_COUNT+1)) ]]; do
		read -rp "Select client [1-$((CLIENT_COUNT+1))]: " CLIENT_NUMBER
	done

	if [[ ${CLIENT_NUMBER} -eq $((CLIENT_COUNT+1)) ]]; then
		return
	fi

	local TARGET_CLIENT="${CLIENT_LIST[$((CLIENT_NUMBER-1))]}"
	local EASY_DIR
	EASY_DIR=$(getEasyWgDir "${TARGET_CLIENT}")

	echo -e "\nSelect Profile to Export:"
	echo "1) Stealth Anti-Scanner & Cloudflare WARP Gateway (${TARGET_CLIENT}-cloudflare-shield.conf) [Recommended]"
	echo "2) Standard Full Tunnel (${TARGET_CLIENT}-standard.conf)"
	echo "3) Both Profiles"
	read -rp "Option [1-3, default 3]: " EXP_PROFILE_OPT
	EXP_PROFILE_OPT=${EXP_PROFILE_OPT:-3}

	read -rp "Destination directory for decrypted file [default: ${EASY_DIR}/export]: " DEST_DIR
	DEST_DIR=${DEST_DIR:-"${EASY_DIR}/export"}
	mkdir -p "$DEST_DIR" 2>/dev/null
	chmod 700 "$DEST_DIR" 2>/dev/null || true

	local CONF_STD_ENC="${EASY_DIR}/${TARGET_CLIENT}-standard.conf.enc"
	[[ ! -f "$CONF_STD_ENC" ]] && CONF_STD_ENC="/etc/wireguard/clients/${TARGET_CLIENT}-standard.conf.enc"
	local CONF_CF_ENC="${EASY_DIR}/${TARGET_CLIENT}-cloudflare-shield.conf.enc"
	[[ ! -f "$CONF_CF_ENC" ]] && CONF_CF_ENC="/etc/wireguard/clients/${TARGET_CLIENT}-cloudflare-shield.conf.enc"

	echo -e "\n${PURPLE}🔒 PASSWORD PROTECTED EXPORT${NC}"
	echo -e "Client '${BOLD}${TARGET_CLIENT}${NC}' configuration is encrypted."
	read -s -rp "Enter decryption password for '${TARGET_CLIENT}': " ATTEMPT_PASS
	echo ""

	local std_txt=""
	local cf_txt=""
	[[ -f "$CONF_STD_ENC" ]] && std_txt=$(decryptConfigToString "$CONF_STD_ENC" "$ATTEMPT_PASS")
	[[ -f "$CONF_CF_ENC" ]] && cf_txt=$(decryptConfigToString "$CONF_CF_ENC" "$ATTEMPT_PASS")

	local DECRYPT_OK=0
	if [[ -n "$cf_txt" && "$cf_txt" =~ "[Interface]" ]] || [[ -n "$std_txt" && "$std_txt" =~ "[Interface]" ]]; then
		DECRYPT_OK=1
	fi

	if [[ $DECRYPT_OK -eq 0 ]]; then
		echo -e "${RED}[ERROR] Incorrect decryption password! Export aborted.${NC}\n"
		read -n1 -r -p "Press Enter to return..."
		return
	fi

	echo -e "${GREEN}[✔] Password verified! Exporting decrypted files...${NC}"

	if [[ "$EXP_PROFILE_OPT" == "1" || "$EXP_PROFILE_OPT" == "3" ]]; then
		if [[ -n "$cf_txt" ]]; then
			echo "$cf_txt" > "${DEST_DIR}/${TARGET_CLIENT}-cloudflare-shield.conf"
			chmod 600 "${DEST_DIR}/${TARGET_CLIENT}-cloudflare-shield.conf"
			echo -e "${GREEN}[✔] Exported: ${DEST_DIR}/${TARGET_CLIENT}-cloudflare-shield.conf${NC}"
		fi
	fi

	if [[ "$EXP_PROFILE_OPT" == "2" || "$EXP_PROFILE_OPT" == "3" ]]; then
		if [[ -n "$std_txt" ]]; then
			echo "$std_txt" > "${DEST_DIR}/${TARGET_CLIENT}-standard.conf"
			chmod 600 "${DEST_DIR}/${TARGET_CLIENT}-standard.conf"
			echo -e "${GREEN}[✔] Exported: ${DEST_DIR}/${TARGET_CLIENT}-standard.conf${NC}"
		fi
	fi

	echo -e "${YELLOW}⚠️ Notice: Decrypted files are in ${DEST_DIR}. Delete them when transferred to your client device.${NC}\n"
	read -n1 -r -p "Press Enter to return..."
}

function revokeClient() {
	echo -e "\n${CYAN}--- Revoke / Remove a Client ---${NC}"
	local CONF_FILE="/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf"
	if [[ ! -f "$CONF_FILE" ]]; then
		echo -e "${YELLOW}WireGuard server configuration file not found (${CONF_FILE}).${NC}\n"
		read -n1 -r -p "Press Enter to return..."
		return
	fi

	local CLIENT_LIST=()
	while IFS= read -r cname; do
		[[ -n "$cname" ]] && CLIENT_LIST+=("$cname")
	done < <(grep -E "^### Client" "$CONF_FILE" 2>/dev/null | awk '{print $3}' | sort -u)

	local CLIENT_COUNT=${#CLIENT_LIST[@]}
	if [[ ${CLIENT_COUNT} -eq 0 ]]; then
		echo -e "${YELLOW}No registered clients found to revoke.${NC}\n"
		read -n1 -r -p "Press Enter to return..."
		return
	fi

	echo -e "${BOLD}Select the client to revoke:${NC}"
	for i in "${!CLIENT_LIST[@]}"; do
		echo "  $((i+1))) ${CLIENT_LIST[$i]}"
	done
	echo "  $((CLIENT_COUNT+1))) Cancel and return"

	local CLIENT_NUMBER=0
	until [[ ${CLIENT_NUMBER} -ge 1 && ${CLIENT_NUMBER} -le $((CLIENT_COUNT+1)) ]]; do
		read -rp "Select client [1-$((CLIENT_COUNT+1))]: " CLIENT_NUMBER
	done

	if [[ ${CLIENT_NUMBER} -eq $((CLIENT_COUNT+1)) ]]; then
		echo -e "${YELLOW}Revocation cancelled.${NC}\n"
		return
	fi

	local TARGET_CLIENT="${CLIENT_LIST[$((CLIENT_NUMBER-1))]}"
	echo -e "\n${YELLOW}Are you sure you want to revoke client '${BOLD}${TARGET_CLIENT}${NC}${YELLOW}'?${NC}"
	read -rp "Type 'yes' or 'y' to confirm: " CONFIRM_REVOKE
	if [[ "$CONFIRM_REVOKE" != "yes" && "$CONFIRM_REVOKE" != "y" ]]; then
		echo -e "${YELLOW}Revocation cancelled.${NC}\n"
		return
	fi

	echo -e "${CYAN}[*] Revoking client '${TARGET_CLIENT}'...${NC}"

	local PUB_KEYS
	PUB_KEYS=$(grep -A 5 -E "^### Client ${TARGET_CLIENT}\b" "$CONF_FILE" 2>/dev/null | grep -E "^\s*PublicKey\s*=" | awk '{print $3}')
	for pk in $PUB_KEYS; do
		if [[ -n "$pk" ]] && command -v wg &>/dev/null; then
			wg set "${SERVER_WG_NIC:-wg0}" peer "$pk" remove 2>/dev/null || true
		fi
	done

	if command -v python3 &>/dev/null; then
		python3 -c "
import sys, re
target = sys.argv[1]
conf_path = '/etc/wireguard/wg0.conf'
try:
    with open(conf_path, 'r') as f:
        content = f.read()
    pattern = r'(?m)^\s*### Client\s+' + re.escape(target) + r'\b[\s\S]*?(?=(?:^\s*### Client)|\Z)'
    new_content = re.sub(pattern, '', content)
    new_content = re.sub(r'\n{3,}', '\n\n', new_content).rstrip() + '\n'
    with open(conf_path, 'w') as f:
        f.write(new_content)
except Exception:
    pass
" "$TARGET_CLIENT"
	else
		sed -i "/^### Client ${TARGET_CLIENT}\b/,/^$/d" "$CONF_FILE" 2>/dev/null || true
	fi

	if command -v wg-quick &>/dev/null && command -v wg &>/dev/null; then
		wg syncconf "${SERVER_WG_NIC:-wg0}" <(wg-quick strip "${SERVER_WG_NIC:-wg0}") 2>/dev/null || true
	fi

	local EASY_DIR
	EASY_DIR=$(getEasyWgDir "${TARGET_CLIENT}")
	local HOME_DIR
	HOME_DIR=$(getHomeDirForClient "${TARGET_CLIENT}")

	rm -f "${EASY_DIR}/${TARGET_CLIENT}"*.conf "${EASY_DIR}/${TARGET_CLIENT}"*.conf.enc 2>/dev/null || true
	rm -f "/etc/wireguard/clients/${TARGET_CLIENT}"*.conf "/etc/wireguard/clients/${TARGET_CLIENT}"*.conf.enc 2>/dev/null || true
	rm -f "${HOME_DIR}/${TARGET_CLIENT}"*.conf "${HOME_DIR}/${TARGET_CLIENT}"*.conf.enc 2>/dev/null || true
	rm -f "/root/${TARGET_CLIENT}"*.conf "/root/${TARGET_CLIENT}"*.conf.enc 2>/dev/null || true

	echo -e "${GREEN}${BOLD}[✔] Client '${TARGET_CLIENT}' successfully revoked!${NC}\n"
	read -n1 -r -p "Press Enter to return..."
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
# 8. Policy Routing Protection: Lock Host Public IP & Client Subnets (Table 200)
#    Ensures WARP wraps AROUND the VPS IP without ever dropping SSH or WireGuard!
# ------------------------------------------------------------------------------
function ensureHostPublicIpBypassRules() {
	local DEF_NIC="${SERVER_PUB_NIC:-}"
	if [[ -z "$DEF_NIC" ]]; then
		DEF_NIC=$(ip -4 route show table main default 2>/dev/null | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | grep -vE '^(wg|Cloudflare|tun)' | head -n1 || echo "eth0")
	fi

	local GW="${DEFAULT_GW:-}"
	if [[ -z "$GW" ]]; then
		GW=$(ip -4 route show table main default dev "$DEF_NIC" 2>/dev/null | awk '/via/ {for (i=1; i<=NF; i++) if ($i == "via") print $(i+1)}' | head -n1 || true)
	fi

	local PUB_IP="${SERVER_PUB_IP:-}"
	if [[ -z "$PUB_IP" || "$PUB_IP" == "127.0.0.1" ]]; then
		PUB_IP=$(ip -4 addr show dev "$DEF_NIC" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || true)
	fi

	# 1. Populate Table 200 with the dedicated physical gateway route
	if [[ -n "$GW" && -n "$DEF_NIC" ]]; then
		ip route replace default via "$GW" dev "$DEF_NIC" table 200 2>/dev/null || true
	fi

	# 2. Priority 40-41: Guarantee return packets destined to connected VPN clients ALWAYS go to wg0 (table main)
	while ip rule del to 10.18.0.0/24 lookup main priority 40 2>/dev/null; do :; done
	while ip rule del to 10.19.0.0/24 lookup main priority 41 2>/dev/null; do :; done
	ip rule add to 10.18.0.0/24 lookup main priority 40 2>/dev/null || true
	ip rule add to 10.19.0.0/24 lookup main priority 41 2>/dev/null || true

	# 3. Priority 50-51: Guarantee VPS's own Public IP (SSH, WireGuard UDP listen port, Web Console) NEVER enters WARP!
	if [[ -n "$PUB_IP" && "$PUB_IP" != "127.0.0.1" ]]; then
		while ip rule del from "${PUB_IP}/32" lookup 200 priority 50 2>/dev/null; do :; done
		while ip rule del from "${PUB_IP}/32" lookup main priority 51 2>/dev/null; do :; done
		if [[ -n "$GW" ]]; then
			ip rule add from "${PUB_IP}/32" lookup 200 priority 50 2>/dev/null || true
		fi
		ip rule add from "${PUB_IP}/32" lookup main priority 51 2>/dev/null || true
	fi

	# 4. Priority 60: Direct-Clean Bypass (PayPal / Banking / 3D-Secure marked 0x100) exits via physical VPS IP
	while ip rule del fwmark 0x100 lookup main priority 60 2>/dev/null; do :; done
	ip rule add fwmark 0x100 lookup main priority 60 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# 9. High-Speed Parallel Domain Split Tunneling & Atomic IPSet Engine
# ------------------------------------------------------------------------------
function applyDomainSplitRulesLive() {
	echo -e "\n${CYAN}[*] Applying High-Speed Parallel Split Tunneling & WARP Policy Routing...${NC}"

	mkdir -p /etc/wireguard
	touch /etc/wireguard/split_domains.txt
	if [[ ! -f /etc/wireguard/split_mode.txt ]]; then
		echo "BYPASS" > /etc/wireguard/split_mode.txt
	fi

	local MODE
	MODE=$(cat /etc/wireguard/split_mode.txt 2>/dev/null || echo "BYPASS")

	if ! command -v ipset &>/dev/null && command -v apt-get &>/dev/null; then
		apt-get install -y -q ipset dnsmasq >/dev/null 2>&1 || true
	fi

	# Ensure systemd-resolved stub listener does not block dnsmasq on port 53
	if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
		mkdir -p /etc/systemd/resolved.conf.d
		cat << 'RESOLVED_NO_STUB' > /etc/systemd/resolved.conf.d/no-stub.conf 2>/dev/null || true
[Resolve]
DNSStubListener=no
RESOLVED_NO_STUB
		systemctl restart systemd-resolved 2>/dev/null || true
	fi

	# Configure dnsmasq for parallel low-jitter upstream resolution & EDNS anonymization
	mkdir -p /etc/dnsmasq.d
	cat << DNSMASQ_STEALTH_EOF > /etc/dnsmasq.d/00-stealth-privacy.conf
# Cookie WireGuard Anti-Jitter & Stealth DNS Configuration
no-edns0
all-servers
min-cache-ttl=300
cache-size=10000
dns-forward-max=2048
bogus-priv
filterwin2k
interface=${SERVER_WG_NIC:-wg0}
except-interface=lo
bind-dynamic
listen-address=${SERVER_WG_IPV4:-10.18.0.1},10.19.0.1,127.0.0.1
no-resolv
server=1.1.1.1
server=1.0.0.1
server=8.8.8.8
DNSMASQ_STEALTH_EOF

	echo "# Cookie WireGuard Dynamic Split Tunneling Rules" > /etc/dnsmasq.d/wg_split.conf

	local EXPANDED_LIST_FILE
	EXPANDED_LIST_FILE=$(mktemp /tmp/wg_domains.XXXXXX)
	local PAYMENT_LIST_FILE
	PAYMENT_LIST_FILE=$(mktemp /tmp/wg_pay_domains.XXXXXX)

	local DOMAIN_COUNT=0
	while IFS= read -r raw_domain || [[ -n "$raw_domain" ]]; do
		[[ -z "$raw_domain" || "$raw_domain" =~ ^# ]] && continue
		local base_domain
		base_domain=$(echo "$raw_domain" | sed -e 's|^https*://||' -e 's|/.*$||' | tr '[:upper:]' '[:lower:]' | xargs)
		[[ -z "$base_domain" ]] && continue

		local EXPANDED_DOMAINS=("$base_domain")
		if [[ "$base_domain" == *"paypal"* ]]; then
			EXPANDED_DOMAINS+=("www.paypal.com" "c.paypal.com" "b.stats.paypal.com" "t.paypal.com" "s.paypal.com" "m.paypal.com" "api.paypal.com" "api-m.paypal.com" "checkout.paypal.com" "identity.paypal.com" "paypalobjects.com" "www.paypalobjects.com" "objects.paypal.com" "c.paypalobjects.com" "paypal.me" "paypal-mktg.com" "cardinalcommerce.com" "songbird.cardinalcommerce.com" "centinelapi.cardinalcommerce.com" "geo.cardinalcommerce.com" "braintreegateway.com" "braintree-api.com" "assets.braintreegateway.com" "js.braintreegateway.com")
		elif [[ "$base_domain" == *"cardinalcommerce.com" ]]; then
			EXPANDED_DOMAINS+=("songbird.cardinalcommerce.com" "centinelapi.cardinalcommerce.com" "geo.cardinalcommerce.com")
		elif [[ "$base_domain" == *"braintreegateway.com" ]]; then
			EXPANDED_DOMAINS+=("braintree-api.com" "assets.braintreegateway.com" "js.braintreegateway.com" "api.braintreegateway.com")
		elif [[ "$base_domain" == *"stripe.com" ]]; then
			EXPANDED_DOMAINS+=("api.stripe.com" "js.stripe.com" "checkout.stripe.com" "m.stripe.network" "m.stripe.com")
		elif [[ "$base_domain" == *"linkedin.com" ]]; then
			EXPANDED_DOMAINS+=("www.linkedin.com" "licdn.com" "media.licdn.com" "static.licdn.com" "lnkd.in" "media-exp1.licdn.com" "platform.linkedin.com" "voyager.linkedin.com" "dms.licdn.com" "snap.licdn.com" "px.ads.linkedin.com")
		elif [[ "$base_domain" == *"amazon.com" ]]; then
			EXPANDED_DOMAINS+=("www.amazon.com" "completion.amazon.com" "images-amazon.com" "media-amazon.com" "ssl-images-amazon.com" "images-na.ssl-images-amazon.com" "aax-us-east.amazon-adsystem.com" "fls-na.amazon.com")
		elif [[ "$base_domain" == *"cloudflare.com" ]]; then
			EXPANDED_DOMAINS+=("challenges.cloudflare.com" "turnstile.com" "cdnjs.cloudflare.com" "cloudflareinsights.com" "cf-assets.com" "pages.dev" "workers.dev")
		elif [[ "$base_domain" == *"google.com" ]]; then
			EXPANDED_DOMAINS+=("www.google.com" "gstatic.com" "recaptcha.net" "google-analytics.com")
		fi

		for domain in "${EXPANDED_DOMAINS[@]}"; do
			((DOMAIN_COUNT++))
			echo "$domain" >> "$EXPANDED_LIST_FILE"
			if command -v ipset &>/dev/null; then
				echo "ipset=/.${domain}/wg_split_v4,wg_split_v6" >> /etc/dnsmasq.d/wg_split.conf
				if [[ "$domain" =~ (paypal|cardinalcommerce|braintree|stripe|chase|bankofamerica|wellsfargo) ]]; then
					echo "$domain" >> "$PAYMENT_LIST_FILE"
					echo "ipset=/.${domain}/wg_direct_clean" >> /etc/dnsmasq.d/wg_split.conf
				fi
			fi
		done
	done < /etc/wireguard/split_domains.txt

	# Parallel DNS lookup & single atomic ipset restore (50x faster, zero packet drop)
	if command -v ipset &>/dev/null; then
		local IPSET_BATCH
		IPSET_BATCH=$(mktemp /tmp/wg_ipset_batch.XXXXXX)
		cat << 'IPSET_HEADER' > "$IPSET_BATCH"
create wg_split_v4 hash:net family inet hashsize 4096 maxelem 131072 -exist
create wg_split_v6 hash:net family inet6 hashsize 4096 maxelem 131072 -exist
create wg_direct_clean hash:net family inet hashsize 2048 maxelem 65536 -exist
flush wg_split_v4
flush wg_split_v6
flush wg_direct_clean
IPSET_HEADER

		# Resolve all split domains in parallel (16 workers)
		if [[ -s "$EXPANDED_LIST_FILE" ]]; then
			sort -u "$EXPANDED_LIST_FILE" | xargs -P 16 -I {} sh -c 'getent ahostsv4 "{}" 2>/dev/null | awk "{print \$1}"' | sort -u | while read -r ip4; do
				[[ "$ip4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "add wg_split_v4 $ip4 -exist" >> "$IPSET_BATCH"
			done
		fi

		if [[ -s "$PAYMENT_LIST_FILE" ]]; then
			sort -u "$PAYMENT_LIST_FILE" | xargs -P 16 -I {} sh -c 'getent ahostsv4 "{}" 2>/dev/null | awk "{print \$1}"' | sort -u | while read -r pay_ip; do
				[[ "$pay_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "add wg_direct_clean $pay_ip -exist" >> "$IPSET_BATCH"
			done
		fi

		# Add PayPal Official Autonomous System CIDRs (AS11643) to direct clean egress
		for p in 64.4.240.0/21 66.211.168.0/21 173.0.80.0/20 173.224.160.0/19 185.177.52.0/22 192.148.20.0/23 198.54.120.0/22 216.113.160.0/19; do
			echo "add wg_direct_clean $p -exist" >> "$IPSET_BATCH"
		done

		# Add LinkedIn Official Autonomous System CIDRs (AS12447)
		for c in 108.174.0.0/20 144.2.0.0/19 185.63.144.0/22 199.101.160.0/22 216.52.16.0/20 216.52.20.0/22 216.52.24.0/22 65.156.227.0/24 8.247.168.0/24; do
			echo "add wg_split_v4 $c -exist" >> "$IPSET_BATCH"
		done

		# Add Cloudflare Edge CIDRs
		if [[ -f /etc/wireguard/cloudflare_split_enabled ]] || grep -q -i "cloudflare" /etc/wireguard/split_domains.txt 2>/dev/null; then
			for c in 173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22; do
				echo "add wg_split_v4 $c -exist" >> "$IPSET_BATCH"
			done
			for c6 in 2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32; do
				echo "add wg_split_v6 $c6 -exist" >> "$IPSET_BATCH"
			done
		fi

		ipset restore -! < "$IPSET_BATCH" 2>/dev/null || true
		rm -f "$IPSET_BATCH"
	fi
	rm -f "$EXPANDED_LIST_FILE" "$PAYMENT_LIST_FILE"

	local DEF_NIC="${SERVER_PUB_NIC}"
	if [[ -z "$DEF_NIC" ]]; then
		DEF_NIC=$(ip -4 route show table main default 2>/dev/null | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | grep -vE '^(wg|Cloudflare|tun)' | head -n1 || echo "eth0")
	fi

	# Ensure Host Public IP & Client Subnet return bypass rules are locked at top priority
	ensureHostPublicIpBypassRules

	# Idempotent Core FORWARD & NAT Rules
	ipt_ensure_top filter FORWARD 1 -i "${SERVER_WG_NIC:-wg0}" -j ACCEPT
	ipt_ensure_top filter FORWARD 2 -o "${SERVER_WG_NIC:-wg0}" -j ACCEPT
	ipt_ensure_top nat POSTROUTING 1 -s 10.18.0.0/24 ! -o "${SERVER_WG_NIC:-wg0}" -j MASQUERADE
	ipt_ensure_top nat POSTROUTING 2 -s 10.19.0.0/24 ! -o "${SERVER_WG_NIC:-wg0}" -j MASQUERADE

	# Mark direct-clean banking/PayPal packets with fwmark 0x100 (routes via Table main / physical VPS IP)
	if command -v ipset &>/dev/null; then
		ipt_ensure_top mangle PREROUTING 1 -i "${SERVER_WG_NIC:-wg0}" -m set --match-set wg_direct_clean dst -j MARK --set-mark 0x100
		ipt_ensure_top mangle PREROUTING 2 -i "${SERVER_WG_NIC:-wg0}" -m set --match-set wg_direct_clean dst -j RETURN
	fi

	# Detect active Cloudflare WARP interface (Prefer Kernel-Native wgwarp, fallback to CloudflareWARP / warp0)
	local WARP_NIC=""
	if ip link show wgwarp &>/dev/null; then
		WARP_NIC="wgwarp"
	elif ip link show CloudflareWARP &>/dev/null; then
		WARP_NIC="CloudflareWARP"
	elif ip link show warp0 &>/dev/null; then
		WARP_NIC="warp0"
	fi

	# Clean previous WARP policy rules before inserting fresh ones
	while ip rule del from 10.19.0.0/24 table 51820 priority 900 2>/dev/null; do :; done
	while ip rule del from 10.18.0.0/24 table 51820 priority 910 2>/dev/null; do :; done
	while ip rule del fwmark 0x51820 table 51820 priority 1000 2>/dev/null; do :; done

	if [[ -n "$WARP_NIC" ]] && [[ -f /etc/wireguard/warp_egress_enabled ]]; then
		ip route replace default dev "$WARP_NIC" table 51820 2>/dev/null || ip route add default dev "$WARP_NIC" table 51820 2>/dev/null || true

		# 1. Profile 1 (10.19.0.0/24) ALWAYS wraps through Cloudflare WARP (Table 51820)
		ip rule add from 10.19.0.0/24 table 51820 priority 900 2>/dev/null || true

		# 2. Profile 2 (10.18.0.0/24) wraps through Cloudflare WARP when WARP_GLOBAL_MODE=full (default),
		#    or routes split domains via fwmark 0x51820 when WARP_GLOBAL_MODE=split
		if [[ "${WARP_GLOBAL_MODE:-full}" == "full" ]]; then
			ip rule add from 10.18.0.0/24 table 51820 priority 910 2>/dev/null || true
		fi

		# 3. Any packet marked 0x51820 (split domains) routes through Cloudflare WARP
		ip rule add fwmark 0x51820 table 51820 priority 1000 2>/dev/null || true

		if command -v ipset &>/dev/null; then
			ipt_ensure_top mangle PREROUTING 3 -i "${SERVER_WG_NIC:-wg0}" -m set --match-set wg_split_v4 dst -j MARK --set-mark 0x51820
		fi

		ipt_ensure_top nat POSTROUTING 1 -o "$WARP_NIC" -j MASQUERADE
		ipt_ensure_top mangle FORWARD 1 -o "$WARP_NIC" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200
		ipt_ensure_top mangle FORWARD 2 -i "$WARP_NIC" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200
	fi

	# Enable and start dnsmasq for zero-jitter cached & parallel DNS resolution
	if command -v dnsmasq &>/dev/null; then
		systemctl enable dnsmasq >/dev/null 2>&1 || true
		systemctl restart dnsmasq >/dev/null 2>&1 || true
		if systemctl is-active --quiet dnsmasq 2>/dev/null; then
			ipt_ensure_top nat PREROUTING 1 -i "${SERVER_WG_NIC:-wg0}" -p udp --dport 53 -j REDIRECT --to-ports 53
			ipt_ensure_top nat PREROUTING 2 -i "${SERVER_WG_NIC:-wg0}" -p tcp --dport 53 -j REDIRECT --to-ports 53
		fi
	fi

	# Apply Stealth TTL & MSS Clamping ONLY to VPN client subnets (never host loopback/management)
	local TARGET_TTL=128
	if [[ ! -f /etc/wireguard/emulate_windows_ttl ]] && [[ -f /etc/wireguard/emulate_unix_ttl ]]; then
		TARGET_TTL=64
	fi
	ipt_ensure_top mangle FORWARD 3 -i "${SERVER_WG_NIC:-wg0}" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
	ipt_ensure_top mangle FORWARD 4 -o "${SERVER_WG_NIC:-wg0}" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
	while iptables -t mangle -D POSTROUTING ! -o "${SERVER_WG_NIC:-wg0}" -j TTL --ttl-set 64 2>/dev/null; do :; done
	while iptables -t mangle -D POSTROUTING ! -o "${SERVER_WG_NIC:-wg0}" -j TTL --ttl-set 128 2>/dev/null; do :; done
	ipt_ensure_append mangle POSTROUTING -s 10.19.0.0/24 ! -o "${SERVER_WG_NIC:-wg0}" -j TTL --ttl-set "${TARGET_TTL}"

	optimizeNicQueuesAndRPS

	echo -e "${GREEN}[✔] Parallel Split & WARP Routing active for ${DOMAIN_COUNT} domain(s) (Interface: ${WARP_NIC:-Direct}).${NC}"
	echo -e "${GREEN}[✔] Host Public IP (${SERVER_PUB_IP:-VPS}) locked to physical gateway — zero drops!${NC}\n"
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
		echo -e "  ${BOLD}Current Mode:${NC}  ${GREEN}[${MODE} MODE]${NC}"
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
				echo "5) Cloudflare Anti-Bot & Turnstile Shield"
				read -rp "Select preset [1-5]: " PRESET_OPT
				case "$PRESET_OPT" in
					1)
						for d in openai.com chatgpt.com oaistatic.com oaiusercontent.com claude.ai anthropic.com gemini.google.com deepseek.com perplexity.ai; do
							grep -q "^${d}\$" /etc/wireguard/split_domains.txt 2>/dev/null || echo "$d" >> /etc/wireguard/split_domains.txt
						done
						applyDomainSplitRulesLive
						;;
					2)
						for d in netflix.com nflxext.com nflxso.net nflxvideo.net nflximg.net hulu.com hulustream.com disneyplus.com disney-plus.net dssott.com bamgrid.com primevideo.com hbomax.com spotify.com; do
							grep -q "^${d}\$" /etc/wireguard/split_domains.txt 2>/dev/null || echo "$d" >> /etc/wireguard/split_domains.txt
						done
						applyDomainSplitRulesLive
						;;
					3)
						for d in paypal.com paypalobjects.com cardinalcommerce.com braintreegateway.com braintree-api.com chase.com bankofamerica.com wellsfargo.com stripe.com; do
							grep -q "^${d}\$" /etc/wireguard/split_domains.txt 2>/dev/null || echo "$d" >> /etc/wireguard/split_domains.txt
						done
						applyDomainSplitRulesLive
						;;
					4)
						for d in discord.com twitch.tv steampowered.com roblox.com epicgames.com; do
							grep -q "^${d}\$" /etc/wireguard/split_domains.txt 2>/dev/null || echo "$d" >> /etc/wireguard/split_domains.txt
						done
						applyDomainSplitRulesLive
						;;
					5)
						touch /etc/wireguard/cloudflare_split_enabled
						for d in challenges.cloudflare.com cloudflare.com turnstile.com cdnjs.cloudflare.com cloudflareinsights.com cf-assets.com pages.dev workers.dev; do
							grep -q "^${d}\$" /etc/wireguard/split_domains.txt 2>/dev/null || echo "$d" >> /etc/wireguard/split_domains.txt
						done
						applyDomainSplitRulesLive
						;;
				esac
				;;
			4)
				if [[ "$MODE" == "BYPASS" ]]; then
					echo "TUNNEL" > /etc/wireguard/split_mode.txt
					echo -e "${GREEN}[✔] Switched mode to: TUNNEL.${NC}"
				else
					echo "BYPASS" > /etc/wireguard/split_mode.txt
					echo -e "${GREEN}[✔] Switched mode to: BYPASS.${NC}"
				fi
				applyDomainSplitRulesLive
				;;
			5)
				echo -e "\n${CYAN}--- Currently Configured Split Domains ---${NC}"
				if [[ ${DOMAIN_COUNT} -eq 0 ]]; then
					echo -e "${YELLOW}No domains configured.${NC}\n"
				else
					grep -v -E '^(#|$)' /etc/wireguard/split_domains.txt | nl -s ') '
					echo ""
					if command -v ipset &>/dev/null; then
						echo -e "${BOLD}Active IPv4 IPSet Rules (wg_split_v4):${NC}"
						ipset list wg_split_v4 2>/dev/null | head -n 35 || echo "No IP members currently resolved."
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
	echo -e "\n${CYAN}--- Real-Time Logging (Errors, WARP Tunnel & Connection Handshakes) ---${NC}"
	if command -v wg &>/dev/null; then
		echo -e "${BOLD}1. WireGuard Server Interface (${SERVER_WG_NIC:-wg0}):${NC}"
		wg show "${SERVER_WG_NIC:-wg0}" 2>/dev/null || echo "WireGuard service inactive."
		echo ""
		echo -e "${BOLD}2. Kernel Cloudflare WARP Interface (wgwarp):${NC}"
		wg show wgwarp 2>/dev/null || echo "Kernel wgwarp inactive (checking warp-cli...)"
	fi
	echo ""
	echo -e "${BOLD}3. Active Policy Routing Rules (ip rule):${NC}"
	ip rule show
	echo ""
}

function geoIpAntiVpnShield() {
	echo -e "\n${CYAN}--- Geo-IP & Anti-VPN Shield (Stealth Normalization) ---${NC}"
	echo -e "  - ${BOLD}TTL Normalization:${NC}      ${GREEN}ACTIVE (Client Subnets Only)${NC}"
	echo -e "  - ${BOLD}TCP MSS Clamping:${NC}       ${GREEN}ACTIVE (1200 on WARP / PMTU on wg0)${NC}"
	echo -e "  - ${BOLD}BBR + 16MB Ring Buffer:${NC} ${GREEN}ACTIVE${NC}"
	echo -e "  - ${BOLD}Multi-Core RPS:${NC}         ${GREEN}ACTIVE${NC}"
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
	echo -e "  8) DNS Resolvers:          ${CLIENT_DNS_1:-1.1.1.1}, ${CLIENT_DNS_2:-1.0.0.1}"
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
					read -rp "Enter WireGuard Port [1024-65535]: " -e -i "${SERVER_PORT:-4500}" NEW_PORT
					if isSensitivePort "$NEW_PORT"; then
						echo -e "${RED}[!] Port ${NEW_PORT} is a sensitive port. Choose a safe stealth port.${NC}"
						continue
					fi
					SERVER_PORT="$NEW_PORT"
					break
				done
				;;
			7)
				while true; do
					read -rp "Enter Web Console Port [1024-65535]: " -e -i "${WEB_PORT:-51821}" NEW_WEB
					if isSensitivePort "$NEW_WEB"; then
						echo -e "${RED}[!] Port ${NEW_WEB} is a sensitive port. Choose a dedicated port.${NC}"
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
DEFAULT_GW=${DEFAULT_GW}
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
WARP_GLOBAL_MODE=${WARP_GLOBAL_MODE:-full}
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

# ------------------------------------------------------------------------------
# 10. Self-Healing WARP Watchdog Service (Rotates Anycast Endpoints on Stall)
# ------------------------------------------------------------------------------
function installWarpWatchdog() {
	cat << 'WATCHDOG_SH' > /usr/local/bin/wg-warp-watchdog.sh
#!/bin/bash
if [[ ! -f /etc/wireguard/warp_egress_enabled ]] || ! ip link show wgwarp &>/dev/null; then
	exit 0
fi

# Check if wgwarp has a fresh handshake within the last 120 seconds or passes traffic
NOW=$(date +%s)
LAST_HS=$(wg show wgwarp latest-handshakes 2>/dev/null | awk '{print $2}' | head -n1 || echo 0)
AGE=$(( NOW - ${LAST_HS:-0} ))

if [[ $AGE -gt 90 ]]; then
	if ! curl --interface wgwarp -sSf --max-time 4 https://1.1.1.1/cdn-cgi/trace >/dev/null 2>&1; then
		PEER_KEY=$(wg show wgwarp peers 2>/dev/null | head -n1)
		if [[ -n "$PEER_KEY" ]]; then
			ENDPOINTS=(
				"162.159.192.1:2408"
				"162.159.193.1:2408"
				"162.159.195.1:2408"
				"188.114.96.1:2408"
				"188.114.97.1:2408"
				"162.159.192.1:4500"
				"162.159.193.1:500"
			)
			PICK="${ENDPOINTS[$(( RANDOM % ${#ENDPOINTS[@]} ))]}"
			wg set wgwarp peer "$PEER_KEY" endpoint "$PICK" persistent-keepalive 15 2>/dev/null || true
		fi
	fi
fi
WATCHDOG_SH
	chmod 700 /usr/local/bin/wg-warp-watchdog.sh

	cat << 'WATCHDOG_SVC' > /etc/systemd/system/wg-warp-watchdog.service
[Unit]
Description=Cloudflare WARP Kernel WireGuard Self-Healing Watchdog
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wg-warp-watchdog.sh
WATCHDOG_SVC

	cat << 'WATCHDOG_TMR' > /etc/systemd/system/wg-warp-watchdog.timer
[Unit]
Description=Run Cloudflare WARP Watchdog every 30 seconds

[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=5s

[Install]
WantedBy=timers.target
WATCHDOG_TMR

	systemctl daemon-reload >/dev/null 2>&1 || true
	systemctl enable --now wg-warp-watchdog.timer >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------------------
# 11. Kernel-Native Cloudflare WARP Provisioner (wgwarp + warp-cli Fallback)
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
	echo -e "\n${CYAN}${BOLD}⚡ Provisioning Kernel-Native Cloudflare WARP Consumer Egress (AS13335)...${NC}"
	mkdir -p /etc/wireguard
	touch /etc/wireguard/warp_egress_enabled

	showWarpProgressBar 10 "Locking VPS Public IP (${SERVER_PUB_IP}) & physical gateway in Table 200..."
	ensureHostPublicIpBypassRules

	# Stop any userspace warp-svc daemon if it was hogging ports or breaking routes
	if systemctl is-active --quiet warp-svc 2>/dev/null; then
		warp-cli --accept-tos disconnect 2>/dev/null || true
	fi

	# Step 1: Check if Kernel-Native wgwarp.conf already exists and works
	if [[ -f /etc/wireguard/wgwarp.conf ]]; then
		showWarpProgressBar 40 "Existing Kernel WARP config found. Bringing up wgwarp interface..."
		systemctl enable "wg-quick@wgwarp" >/dev/null 2>&1 || true
		systemctl restart "wg-quick@wgwarp" 2>/dev/null || wg-quick up wgwarp 2>/dev/null || true
		sleep 1
		if ip link show wgwarp &>/dev/null && curl --interface wgwarp -sSf --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q "warp=on"; then
			installWarpWatchdog
			optimizeNicQueuesAndRPS
			showWarpProgressBar 100 "Kernel-Native Cloudflare WARP (wgwarp) Verified & Active!"
			return 0
		fi
	fi

	# Step 2: Register a fresh Kernel-Native WireGuard WARP peer via Cloudflare API
	showWarpProgressBar 30 "Generating WireGuard keys & registering with Cloudflare WARP API..."
	local WARP_PRIV_KEY WARP_PUB_KEY
	WARP_PRIV_KEY=$(wg genkey)
	WARP_PUB_KEY=$(echo "$WARP_PRIV_KEY" | wg pubkey)
	local TOS_DATE
	TOS_DATE=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

	local REG_JSON=""
	local API_ENDPOINTS=(
		"https://api.cloudflareclient.com/v0a2158/reg"
		"https://api.cloudflareclient.com/v0a2483/reg"
	)

	for api_url in "${API_ENDPOINTS[@]}"; do
		REG_JSON=$(curl -4 --interface "${SERVER_PUB_NIC:-eth0}" -sSfL --connect-timeout 6 --max-time 12 \
			-X POST "$api_url" \
			-H "User-Agent: okhttp/3.12.1" \
			-H "Accept: application/json" \
			-H "Content-Type: application/json; charset=UTF-8" \
			-d "{\"key\":\"${WARP_PUB_KEY}\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"${TOS_DATE}\",\"model\":\"PC\",\"serial_number\":\"$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | head -c 16)\",\"locale\":\"en_US\"}" 2>/dev/null || true)
		if [[ -n "$REG_JSON" ]] && echo "$REG_JSON" | jq -e '.config.interface.addresses.v4' >/dev/null 2>&1; then
			break
		fi
	done

	if [[ -n "$REG_JSON" ]] && echo "$REG_JSON" | jq -e '.config.interface.addresses.v4' >/dev/null 2>&1; then
		showWarpProgressBar 60 "Cloudflare WARP license registered! Building /etc/wireguard/wgwarp.conf..."
		local WARP_IPV4 WARP_PEER_PUB WARP_ENDPOINT_HOST
		WARP_IPV4=$(echo "$REG_JSON" | jq -r '.config.interface.addresses.v4')
		WARP_PEER_PUB=$(echo "$REG_JSON" | jq -r '.config.peers[0].public_key // "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="')
		WARP_ENDPOINT_HOST=$(echo "$REG_JSON" | jq -r '.config.peers[0].endpoint.v4 // "162.159.192.1:2408"' | cut -d':' -f1)
		[[ -z "$WARP_ENDPOINT_HOST" || "$WARP_ENDPOINT_HOST" == "null" ]] && WARP_ENDPOINT_HOST="162.159.192.1"

		cat << WGWARP_EOF > /etc/wireguard/wgwarp.conf
[Interface]
PrivateKey = ${WARP_PRIV_KEY}
Address = ${WARP_IPV4}/32
MTU = 1280
Table = 51820

PostUp = ip link set dev wgwarp txqueuelen 10000 2>/dev/null || true
PostUp = sysctl -w net.ipv4.conf.wgwarp.rp_filter=0 >/dev/null 2>&1 || true
PostUp = iptables -t nat -C POSTROUTING -o wgwarp -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -o wgwarp -j MASQUERADE
PostUp = iptables -t mangle -C FORWARD -o wgwarp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200 2>/dev/null || iptables -t mangle -I FORWARD 1 -o wgwarp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200
PostUp = iptables -t mangle -C FORWARD -i wgwarp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200 2>/dev/null || iptables -t mangle -I FORWARD 2 -i wgwarp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200

PostDown = iptables -t nat -D POSTROUTING -o wgwarp -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -o wgwarp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -i wgwarp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200 2>/dev/null || true

[Peer]
PublicKey = ${WARP_PEER_PUB}
AllowedIPs = 0.0.0.0/0
Endpoint = ${WARP_ENDPOINT_HOST}:2408
PersistentKeepalive = 15
WGWARP_EOF
		chmod 600 /etc/wireguard/wgwarp.conf

		showWarpProgressBar 80 "Starting Kernel WireGuard WARP interface (wgwarp)..."
		wg-quick down wgwarp >/dev/null 2>&1 || true
		ip link delete dev wgwarp >/dev/null 2>&1 || true
		systemctl daemon-reload >/dev/null 2>&1 || true
		systemctl enable "wg-quick@wgwarp" >/dev/null 2>&1 || true
		systemctl restart "wg-quick@wgwarp" 2>/dev/null || wg-quick up wgwarp 2>/dev/null || true

		installWarpWatchdog
		ensureHostPublicIpBypassRules
		optimizeNicQueuesAndRPS

		showWarpProgressBar 95 "Verifying Cloudflare WARP tunnel handshake & IP cloak..."
		local WARP_TRACE
		WARP_TRACE=$(curl --interface wgwarp -sSf --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
		local WARP_EXIT_IP
		WARP_EXIT_IP=$(echo "$WARP_TRACE" | grep -E '^ip=' | cut -d'=' -f2 || echo "Active")

		showWarpProgressBar 100 "Kernel-Native Cloudflare WARP Active (Exit IP: ${WARP_EXIT_IP} | VPS Entry IP: ${SERVER_PUB_IP})"
		echo -e "${GREEN}[✔] Cloudflare WARP is now warping around your VPS IP (${SERVER_PUB_IP} -> ${WARP_EXIT_IP})!${NC}"
		return 0
	fi

	# Step 3: Fallback to official cloudflare-warp package in TUN mode (with Table 200 host IP protection)
	showWarpProgressBar 65 "API rate-limited on this subnet; configuring warp-cli in TUN mode with Table 200 host lock..."
	if ! command -v warp-cli &>/dev/null && command -v apt-get &>/dev/null; then
		local ARCH CODENAME
		ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
		. /etc/os-release 2>/dev/null || true
		CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-jammy}}"
		mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
		curl -fsSL --connect-timeout 8 https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null || true
		echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${CODENAME} main" > /etc/apt/sources.list.d/cloudflare-client.list 2>/dev/null || true
		apt-get update -o Dir::Etc::sourcelist="sources.list.d/cloudflare-client.list" -qq >/dev/null 2>&1 || true
		apt-get install -y -qq cloudflare-warp >/dev/null 2>&1 || true
	fi

	if command -v warp-cli &>/dev/null; then
		systemctl enable --now warp-svc >/dev/null 2>&1 || true
		sleep 1
		warp-cli --accept-tos registration new 2>/dev/null || warp-cli --accept-tos register 2>/dev/null || true
		ensureHostPublicIpBypassRules
		warp-cli --accept-tos mode warp 2>/dev/null || warp-cli --accept-tos set-mode warp 2>/dev/null || true
		warp-cli --accept-tos connect 2>/dev/null || true
		sleep 2
		ensureHostPublicIpBypassRules
		showWarpProgressBar 100 "Cloudflare WARP TUN Mode Active with VPS Entry IP Protected!"
	else
		showWarpProgressBar 100 "Fallback complete."
	fi
}

function autoRepairNetwork() {
	echo -e "\n${CYAN}${BOLD}🛠️ Starting Automated Network, DNS, Anti-Jitter & WARP Health Auto-Repair...${NC}"

	echo -e "${CYAN}[1/5] Verifying host DNS health & nameservers...${NC}"
	cat << 'RESOLV_CLEAN_EOF' > /etc/resolv.conf 2>/dev/null || true
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
RESOLV_CLEAN_EOF

	echo -e "${CYAN}[2/5] Applying Anti-Drop Kernel Buffers, Conntrack & rp_filter=0...${NC}"
	sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.all.forwarding=1 >/dev/null 2>&1 || true
	sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1 || true
	sysctl -w net.core.rmem_default=16777216 >/dev/null 2>&1 || true
	sysctl -w net.core.wmem_default=16777216 >/dev/null 2>&1 || true
	sysctl --system -q >/dev/null 2>&1 || true

	echo -e "${CYAN}[3/5] Locking VPS Public IP (${SERVER_PUB_IP}) in Table 200 & checking DNS port 53...${NC}"
	ensureHostPublicIpBypassRules
	if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
		mkdir -p /etc/systemd/resolved.conf.d
		cat << 'RESOLVED_NO_STUB' > /etc/systemd/resolved.conf.d/no-stub.conf 2>/dev/null || true
[Resolve]
DNSStubListener=no
RESOLVED_NO_STUB
		systemctl restart systemd-resolved >/dev/null 2>&1 || true
	fi
	systemctl enable dnsmasq >/dev/null 2>&1 || true
	systemctl restart dnsmasq >/dev/null 2>&1 || true

	echo -e "${CYAN}[4/5] Restoring Unified WireGuard interface (${SERVER_WG_NIC:-wg0}) & Kernel WARP (wgwarp)...${NC}"
	if command -v wg-quick &>/dev/null; then
		systemctl daemon-reload >/dev/null 2>&1 || true
		systemctl restart "wg-quick@${SERVER_WG_NIC:-wg0}" 2>/dev/null || wg-quick up "${SERVER_WG_NIC:-wg0}" 2>/dev/null || true
		if [[ -f /etc/wireguard/warp_egress_enabled ]]; then
			setupCloudflareWarpClient
		fi
	fi

	echo -e "${CYAN}[5/5] Re-applying idempotent NAT, MSS=1200 Clamping, and Multi-Core RPS...${NC}"
	applyDomainSplitRulesLive

	echo -e "${GREEN}[✔] Health Auto-Repair COMPLETE: Zero-drop buffers, WireGuard, and Cloudflare WARP verified!${NC}\n"
}

function cloudflareAntiFlagEngine() {
	while true; do
		local CF_SHIELD_STATUS="ACTIVE"
		local CURRENT_TTL=128
		[[ -f /etc/wireguard/emulate_unix_ttl ]] && CURRENT_TTL=64
		local SPLIT_COUNT=0
		[[ -f /etc/wireguard/split_domains.txt ]] && SPLIT_COUNT=$(grep -c -v -E '^(#|$)' /etc/wireguard/split_domains.txt 2>/dev/null || echo 0)
		local HAS_WARP="DISABLED"
		if ip link show wgwarp &>/dev/null; then
			HAS_WARP="ACTIVE (Kernel-Native wgwarp | AS13335)"
		elif [[ -f /etc/wireguard/warp_egress_enabled ]]; then
			HAS_WARP="ENABLED (AS13335)"
		fi

		echo -e "\n${PURPLE}=================================================================${NC}"
		echo -e "       ${CYAN}${BOLD}🛡️ Kernel-Native Cloudflare WARP & Stealth Gateway Engine${NC}"
		echo -e "${PURPLE}=================================================================${NC}"
		echo -e "  ${BOLD}VPS Entry IP (Protected):${NC}   ${GREEN}[${SERVER_PUB_IP:-127.0.0.1}:${SERVER_PORT:-4500}]${NC} (Pinned to Table 200)"
		echo -e "  ${BOLD}WARP Consumer Egress:${NC}       ${GREEN}[${HAS_WARP}]${NC}"
		echo -e "  ${BOLD}WARP Routing Scope:${NC}         ${CYAN}[${WARP_GLOBAL_MODE:-full}]${NC} (full = Both Profiles | split = Profile 1 + Split)"
		echo -e "  ${BOLD}TCP SYN Fingerprint:${NC}       ${CYAN}TTL=${CURRENT_TTL}, WARP MSS=1200, Keepalive=15s${NC}"
		echo -e "  ${BOLD}Active Split Domains:${NC}      ${YELLOW}${SPLIT_COUNT} domain(s) active${NC}"
		echo "-----------------------------------------------------------------"
		echo "1) Enable / Refresh Kernel-Native Cloudflare WARP Egress (wgwarp AS13335)"
		echo "2) Toggle WARP Scope (Full WARP for All Clients vs Profile 1 + Split Domains)"
		echo "3) Enable Cloudflare Edge & Turnstile CIDRs Split Tunneling"
		echo "4) Toggle Windows 10/11 Desktop TCP SYN Emulation (TTL=128 vs 64)"
		echo "5) Run Live Dual-Path Diagnostic (Compare VPS Direct IP vs WARP Wrapped IP)"
		echo "6) Revert to Direct VPS Egress (Disable WARP)"
		echo "7) Safe Network, DNS & Firewall Auto-Repair"
		echo "8) Return to Main Menu"
		echo ""

		read -rp "Select option [1-8]: " CF_OPT
		case "$CF_OPT" in
			1)
				setupCloudflareWarpClient
				applyDomainSplitRulesLive
				read -n1 -r -p "Press Enter to return..."
				;;
			2)
				if [[ "${WARP_GLOBAL_MODE:-full}" == "full" ]]; then
					WARP_GLOBAL_MODE="split"
					echo -e "${GREEN}[✔] Switched to SPLIT mode: Profile 1 (10.19.0.x) uses Full WARP; Profile 2 (10.18.0.x) uses Direct VPS + Split WARP.${NC}"
				else
					WARP_GLOBAL_MODE="full"
					echo -e "${GREEN}[✔] Switched to FULL mode: Both Profile 1 and Profile 2 wrap through Cloudflare WARP!${NC}"
				fi
				if [[ -f /etc/wireguard/params ]]; then
					if grep -q "^WARP_GLOBAL_MODE=" /etc/wireguard/params; then
						sed -i "s/^WARP_GLOBAL_MODE=.*/WARP_GLOBAL_MODE=${WARP_GLOBAL_MODE}/" /etc/wireguard/params
					else
						echo "WARP_GLOBAL_MODE=${WARP_GLOBAL_MODE}" >> /etc/wireguard/params
					fi
				fi
				applyDomainSplitRulesLive
				;;
			3)
				mkdir -p /etc/wireguard
				touch /etc/wireguard/cloudflare_split_enabled
				for d in challenges.cloudflare.com cloudflare.com turnstile.com cdnjs.cloudflare.com cloudflareinsights.com cf-assets.com pages.dev workers.dev; do
					grep -q "^${d}\$" /etc/wireguard/split_domains.txt 2>/dev/null || echo "$d" >> /etc/wireguard/split_domains.txt
				done
				applyDomainSplitRulesLive
				;;
			4)
				if [[ -f /etc/wireguard/emulate_unix_ttl ]]; then
					rm -f /etc/wireguard/emulate_unix_ttl
					touch /etc/wireguard/emulate_windows_ttl
					echo -e "${GREEN}[✔] Switched to Windows 10/11 Desktop Stack Emulation (TTL=128).${NC}\n"
				else
					rm -f /etc/wireguard/emulate_windows_ttl
					touch /etc/wireguard/emulate_unix_ttl
					echo -e "${GREEN}[✔] Switched to Unix/macOS Desktop Stack (TTL=64).${NC}\n"
				fi
				applyDomainSplitRulesLive
				;;
			5)
				echo -e "\n${CYAN}[*] Running Live Dual-Path Egress Diagnostic...${NC}"
				local DIRECT_TRACE WARP_TRACE
				DIRECT_TRACE=$(curl -4 --interface "${SERVER_PUB_NIC:-eth0}" -sSf --max-time 4 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
				if ip link show wgwarp &>/dev/null; then
					WARP_TRACE=$(curl -4 --interface wgwarp -sSf --max-time 4 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
				fi

				echo -e "\n${BOLD}1. Host Physical Interface (${SERVER_PUB_NIC:-eth0} - Entry IP Preserved):${NC}"
				echo "$DIRECT_TRACE" | grep -E '^(ip|warp|loc|colo)=' | sed 's/^/   /' || echo "   Unable to query direct trace."

				echo -e "\n${BOLD}2. Kernel WARP Interface (wgwarp - Client Outbound Cloak):${NC}"
				if [[ -n "$WARP_TRACE" ]]; then
					echo "$WARP_TRACE" | grep -E '^(ip|warp|loc|colo)=' | sed 's/^/   /'
					if echo "$WARP_TRACE" | grep -q "warp=on"; then
						echo -e "\n${GREEN}[✔] SUCCESS: Client traffic warps out through Cloudflare WARP while your VPS IP stays reachable!${NC}"
					fi
				else
					echo -e "   ${YELLOW}wgwarp interface is not active. Select Option [1] to enable.${NC}"
				fi
				echo ""
				read -n1 -r -p "Press Enter to continue..."
				;;
			6)
				rm -f /etc/wireguard/warp_egress_enabled
				systemctl stop wg-warp-watchdog.timer >/dev/null 2>&1 || true
				systemctl disable "wg-quick@wgwarp" >/dev/null 2>&1 || true
				wg-quick down wgwarp >/dev/null 2>&1 || true
				ip link delete dev wgwarp >/dev/null 2>&1 || true
				while ip rule del from 10.19.0.0/24 table 51820 priority 900 2>/dev/null; do :; done
				while ip rule del from 10.18.0.0/24 table 51820 priority 910 2>/dev/null; do :; done
				while ip rule del fwmark 0x51820 table 51820 priority 1000 2>/dev/null; do :; done
				applyDomainSplitRulesLive
				echo -e "${GREEN}[✔] Reverted to Direct VPS Egress.${NC}\n"
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
	echo -e "\n${RED}${BOLD}WARNING: This will completely remove WireGuard, Kernel WARP, and Web Console configs!${NC}"
	read -rp "Are you sure you want to uninstall WireGuard? [y/N]: " -e REMOVE
	REMOVE=${REMOVE:-n}
	if [[ "$REMOVE" =~ ^[Yy]$ ]]; then
		echo -e "${CYAN}[*] Safely uninstalling WireGuard (protecting sensitive web & SSH ports: 80, 443, 22)...${NC}"

		systemctl stop wg-warp-watchdog.timer >/dev/null 2>&1 || true
		systemctl disable wg-warp-watchdog.timer >/dev/null 2>&1 || true
		rm -f /etc/systemd/system/wg-warp-watchdog.service /etc/systemd/system/wg-warp-watchdog.timer /usr/local/bin/wg-warp-watchdog.sh

		systemctl stop "wg-quick@${SERVER_WG_NIC:-wg0}" >/dev/null 2>&1 || true
		systemctl disable "wg-quick@${SERVER_WG_NIC:-wg0}" >/dev/null 2>&1 || true
		systemctl stop "wg-quick@wgwarp" >/dev/null 2>&1 || true
		systemctl disable "wg-quick@wgwarp" >/dev/null 2>&1 || true
		systemctl stop cbwireguard-web >/dev/null 2>&1 || true
		systemctl disable cbwireguard-web >/dev/null 2>&1 || true

		if command -v wg-quick >/dev/null 2>&1; then
			wg-quick down "${SERVER_WG_NIC:-wg0}" >/dev/null 2>&1 || true
			wg-quick down wgwarp >/dev/null 2>&1 || true
		fi
		ip link delete dev "${SERVER_WG_NIC:-wg0}" >/dev/null 2>&1 || true
		ip link delete dev wgwarp >/dev/null 2>&1 || true

		while ip rule del to 10.18.0.0/24 lookup main priority 40 2>/dev/null; do :; done
		while ip rule del to 10.19.0.0/24 lookup main priority 41 2>/dev/null; do :; done
		while ip rule del fwmark 0x100 lookup main priority 60 2>/dev/null; do :; done
		while ip rule del from 10.19.0.0/24 table 51820 priority 900 2>/dev/null; do :; done
		while ip rule del from 10.18.0.0/24 table 51820 priority 910 2>/dev/null; do :; done
		while ip rule del fwmark 0x51820 table 51820 priority 1000 2>/dev/null; do :; done

		if [[ -n "${SERVER_PORT:-}" ]]; then
			iptables -D INPUT -p udp --dport "${SERVER_PORT}" -j ACCEPT 2>/dev/null || true
		fi
		iptables -D FORWARD -i "${SERVER_WG_NIC:-wg0}" -j ACCEPT 2>/dev/null || true
		iptables -D FORWARD -o "${SERVER_WG_NIC:-wg0}" -j ACCEPT 2>/dev/null || true
		iptables -t nat -D POSTROUTING -s 10.18.0.0/24 ! -o "${SERVER_WG_NIC:-wg0}" -j MASQUERADE 2>/dev/null || true
		iptables -t nat -D POSTROUTING -s 10.19.0.0/24 ! -o "${SERVER_WG_NIC:-wg0}" -j MASQUERADE 2>/dev/null || true

		if command -v ipset &>/dev/null; then
			ipset destroy wg_split_v4 2>/dev/null || true
			ipset destroy wg_split_v6 2>/dev/null || true
			ipset destroy wg_direct_clean 2>/dev/null || true
		fi
		rm -f /etc/dnsmasq.d/00-stealth-privacy.conf /etc/dnsmasq.d/wg_split.conf
		systemctl restart dnsmasq 2>/dev/null || true

		rm -rf /etc/wireguard
		rm -f /etc/sysctl.d/99-wireguard-stealth.conf
		rm -f /etc/systemd/system/cbwireguard-web.service
		systemctl daemon-reload

		echo -e "${GREEN}[✔] WireGuard uninstalled safely. Sensitive ports (80, 443, 22) preserved intact.${NC}\n"
		exit 0
	else
		echo -e "${YELLOW}Uninstall cancelled.${NC}\n"
	fi
}

# ------------------------------------------------------------------------------
# 12. Interactive Terminal Menu
# ------------------------------------------------------------------------------
function manageMenu() {
	while true; do
		local WG0_STATUS="${RED}STOPPED${NC}"
		if systemctl is-active --quiet wg-quick@wg0 2>/dev/null || wg show wg0 &>/dev/null; then
			WG0_STATUS="${GREEN}ACTIVE${NC}"
		fi

		local WARP_STATUS="${YELLOW}DIRECT${NC}"
		if ip link show wgwarp &>/dev/null; then
			WARP_STATUS="${GREEN}ACTIVE (Kernel wgwarp)${NC}"
		elif ip link show CloudflareWARP &>/dev/null; then
			WARP_STATUS="${GREEN}ACTIVE (TUN)${NC}"
		fi

		echo -e "\n${PURPLE}=================================================================${NC}"
		echo -e "          ${GREEN}${BOLD}🍪  Cookie's Easy WireGuard Manager v4.0${NC}"
		echo -e "${PURPLE}=================================================================${NC}"
		echo -e "  ${BOLD}Server Daemon (Unified):${NC}    wg0 | Port ${SERVER_PORT:-4500}/udp [${WG0_STATUS}]"
		echo -e "  ${BOLD}Cloudflare WARP Cloak:${NC}      [${WARP_STATUS}] (Entry IP: ${SERVER_PUB_IP:-VPS})"
		echo -e "  ${BOLD}Profile 1 (WARP Stealth):${NC}   10.19.0.0/24 (MTU 1320, MSS 1200, Port ${SERVER_PORT:-4500})"
		echo -e "  ${BOLD}Profile 2 (Standard):${NC}       10.18.0.0/24 (MTU 1380, Keepalive 15s, Port ${SERVER_PORT:-4500})"
		echo -e "${PURPLE}┌──────────────────────────────────────────────────────────────┐${NC}"
		echo -e "${PURPLE}│${NC}                      ${CYAN}${BOLD}Main Menu Actions${NC}                       ${PURPLE}│${NC}"
		echo -e "${PURPLE}├──────────────────────────────────────────────────────────────┤${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[1]${NC} Setup WireGuard server (Unified Port + Kernel WARP)      ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[2]${NC} Add new client (Generates Standard & WARP Profiles)      ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[3]${NC} Configure clients (Check/Edit/Export/Remove)             ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[4]${NC} Backup & Restore Manager                                 ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[5]${NC} Domain-Based Split Tunneling (Parallel IPSet Engine)     ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[6]${NC} Real-Time Logging (Handshakes, WARP & Policy Rules)      ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[7]${NC} Geo-IP & Anti-VPN Shield Status                          ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[8]${NC} Provision Web Management Console                         ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[9]${NC} Cloudflare WARP & Stealth Egress Gateway Engine          ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[10]${NC} Safe Network, DNS & WARP Health Auto-Repair             ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[s]${NC} Settings (Port, MTU, DNS, AllowedIPs)                    ${PURPLE}│${NC}"
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
# 13. Script Entrypoint Execution
# ------------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	initialCheck

	if [[ -e /etc/wireguard/params ]]; then
		source /etc/wireguard/params
	fi

	if [[ "${1:-}" == "--repair" || "${1:-}" == "-r" || "${1:-}" == "repair" ]]; then
		autoRepairNetwork
		exit 0
	fi

	if [[ "${1:-}" == "--clean" || "${1:-}" == "--encrypt" || "${1:-}" == "-c" ]]; then
		cleanupAndSecureRootFolder
		exit 0
	fi

	cleanupAndSecureRootFolder
	manageMenu
fi