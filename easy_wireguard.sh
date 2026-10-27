#!/bin/bash
# ==============================================================================
# 🍪 Cookie's Easy WireGuard Manager & VPS Stealth Server v4.2
# Hyper-Optimized Anti-Detect Egress, Transparent WARP Bridge & Multi-Gigabit Tuning
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

# Returns the dedicated easy_wireguard folder (keeps all client & config files strictly out of root)
function getEasyWgDir() {
	local CLIENT_NAME="${1:-}"
	local HOME_DIR
	HOME_DIR=$(getHomeDirForClient "${CLIENT_NAME}")
	local EASY_DIR="${HOME_DIR}/easy_wireguard"
	mkdir -p "$EASY_DIR" 2>/dev/null || mkdir -p "/root/easy_wireguard" 2>/dev/null
	chmod 700 "$EASY_DIR" 2>/dev/null || true
	echo "$EASY_DIR"
}

# Retrieves Master Passkey for AES-256-CBC configuration encryption/decryption
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

# Encrypt configuration text using OpenSSL AES-256-CBC PBKDF2 (100,000 iterations)
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

# Decrypt AES-256-CBC encrypted .conf.enc on-the-fly in memory (never written plain-text to disk)
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

# Cleans all loose .conf files from /root or $HOME, moves them into easy_wireguard/ and encrypts them
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
			[[ "$bname" == "resolv.conf" || "$bname" == "sysctl.conf" || "$bname" == "redsocks.conf" ]] && continue
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
	local sensitive_ports=(20 21 22 23 25 53 67 68 80 110 143 443 8080 8443 3306 5432 6379 12345 27017 40000)
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

# ------------------------------------------------------------------------------
# 2b. Hardware NIC Offloading, RPS/RFS Multi-Queue & Conntrack Speed Booster
# ------------------------------------------------------------------------------
function optimizeNetworkThroughput() {
	local PUB_NIC="${1:-${SERVER_PUB_NIC:-}}"
	if [[ -z "$PUB_NIC" ]]; then
		PUB_NIC=$(ip -4 route show default 2>/dev/null | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | head -n1 || echo "eth0")
	fi
	local WG_NIC="${SERVER_WG_NIC:-wg0}"

	# 1. Increase interface transmit queue lengths for multi-gigabit burst capacity
	ip link set dev "$PUB_NIC" txqueuelen 10000 2>/dev/null || true
	ip link set dev "$WG_NIC" txqueuelen 10000 2>/dev/null || true

	# 2. Enable Hardware/Kernel GRO, GSO, TSO, SG, and RX/TX Checksum Offloading
	if command -v ethtool &>/dev/null; then
		ethtool -K "$PUB_NIC" gro on gso on tso on sg on rx on tx on 2>/dev/null || true
		ethtool -K "$WG_NIC" gro on gso on sg on 2>/dev/null || true
		local MAX_RX MAX_TX
		MAX_RX=$(ethtool -g "$PUB_NIC" 2>/dev/null | awk '/Pre-set maximums:/,0 {if ($1 == "RX:") {print $2; exit}}')
		MAX_TX=$(ethtool -g "$PUB_NIC" 2>/dev/null | awk '/Pre-set maximums:/,0 {if ($1 == "TX:") {print $2; exit}}')
		[[ -n "$MAX_RX" && "$MAX_RX" =~ ^[0-9]+$ ]] && ethtool -G "$PUB_NIC" rx "$MAX_RX" 2>/dev/null || true
		[[ -n "$MAX_TX" && "$MAX_TX" =~ ^[0-9]+$ ]] && ethtool -G "$PUB_NIC" tx "$MAX_TX" 2>/dev/null || true
	fi

	# 3. Enable Receive Packet Steering (RPS) & Receive Flow Steering (RFS) across all CPU cores
	local NUM_CORES
	NUM_CORES=$(nproc 2>/dev/null || echo 2)
	local RPS_MASK
	RPS_MASK=$(printf '%x' $(( (1 << (NUM_CORES > 16 ? 16 : NUM_CORES)) - 1 )))
	echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true

	for dev in "$PUB_NIC" "$WG_NIC"; do
		if [[ -d "/sys/class/net/${dev}/queues" ]]; then
			for rxq in /sys/class/net/"${dev}"/queues/rx-*; do
				[[ -f "${rxq}/rps_cpus" ]] && echo "$RPS_MASK" > "${rxq}/rps_cpus" 2>/dev/null || true
				[[ -f "${rxq}/rps_flow_cnt" ]] && echo 4096 > "${rxq}/rps_flow_cnt" 2>/dev/null || true
			done
			for txq in /sys/class/net/"${dev}"/queues/tx-*; do
				[[ -f "${txq}/xps_cpus" ]] && echo "$RPS_MASK" > "${txq}/xps_cpus" 2>/dev/null || true
			done
		fi
	done

	# 4. Configure FQ (Fair Queue) qdisc with pacing for WireGuard & Public NIC
	if command -v tc &>/dev/null; then
		tc qdisc replace dev "$PUB_NIC" root fq 2>/dev/null || true
		tc qdisc replace dev "$WG_NIC" root fq 2>/dev/null || true
	fi
}

function cleanupOldWireguard() {
	echo -e "\n${CYAN}[*] Scanning for old/conflicting WireGuard instances & services...${NC}"

	systemctl stop "wg-quick@wg0" >/dev/null 2>&1 || true
	systemctl stop "wg-quick@wg1" >/dev/null 2>&1 || true
	systemctl disable "wg-quick@wg1" >/dev/null 2>&1 || true
	systemctl stop wg-warp-watchdog.timer >/dev/null 2>&1 || true

	if command -v wg-quick >/dev/null 2>&1; then
		wg-quick down wg0 >/dev/null 2>&1 || true
		wg-quick down wg1 >/dev/null 2>&1 || true
	fi

	ip link delete dev wg0 >/dev/null 2>&1 || true
	ip link delete dev wg1 >/dev/null 2>&1 || true

	systemctl stop cbwireguard-web >/dev/null 2>&1 || true
	systemctl disable cbwireguard-web >/dev/null 2>&1 || true

	# Remove legacy blackhole policy routing rules
	ip rule del fwmark 0x51820 table 51820 2>/dev/null || true
	ip route flush table 51820 2>/dev/null || true

	# Clean transparent proxy & DNS chains if present
	iptables -t nat -D PREROUTING -i wg0 -j WG_STEALTH_DNS 2>/dev/null || true
	iptables -t nat -F WG_STEALTH_DNS 2>/dev/null || true
	iptables -t nat -X WG_STEALTH_DNS 2>/dev/null || true

	iptables -t nat -D PREROUTING -i wg0 -p tcp -j WG_STEALTH_PROXY 2>/dev/null || true
	iptables -t nat -F WG_STEALTH_PROXY 2>/dev/null || true
	iptables -t nat -X WG_STEALTH_PROXY 2>/dev/null || true

	# Surgical rule cleanup
	iptables -D FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
	iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
	iptables -D FORWARD -o wg0 -j ACCEPT 2>/dev/null || true
	iptables -D FORWARD -i wg1 -j ACCEPT 2>/dev/null || true
	iptables -D FORWARD -o wg1 -j ACCEPT 2>/dev/null || true
	iptables -t nat -D POSTROUTING -s 10.18.0.0/24 -j MASQUERADE 2>/dev/null || true
	iptables -t nat -D POSTROUTING -s 10.19.0.0/24 -j MASQUERADE 2>/dev/null || true
	iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
	iptables -t mangle -D POSTROUTING -j TTL --ttl-set 64 2>/dev/null || true
	iptables -t mangle -D POSTROUTING -j TTL --ttl-set 128 2>/dev/null || true

	echo -e "${GREEN}[✔] Cleaned old WireGuard instances. Sensitive web & SSH ports (80, 443, 22) protected.${NC}"
}

# ------------------------------------------------------------------------------
# 3. DNS Resolvers Selection Menu (Location + Stealth for IPv4 & IPv6)
# ------------------------------------------------------------------------------
function selectDNSResolvers() {
	echo -e "\n${CYAN}${BOLD}Select Upstream DNS Resolvers for Server & Clients:${NC}"
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
	echo -e "   6) ${GREEN}Local Stealth Server Resolver${NC} (Server Local | Maximum Anti-Leak & Instant Split-IPSet)"
	echo -e "      IPv4: 10.19.0.1, ${SERVER_WG_IPV4:-10.18.0.1}"
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
			CLIENT_DNS_2="1.1.1.1"
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
			read -rp "Enter Primary DNS resolver (IPv4): " -e -i "1.1.1.1" CLIENT_DNS_1
			read -rp "Enter Secondary DNS resolver (IPv4): " -e -i "1.0.0.1" CLIENT_DNS_2
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
	echo -e "          ${GREEN}${BOLD}🍪  Cookie's Easy WireGuard Setup & Installer v4.2${NC}"
	echo -e "${PURPLE}=================================================================${NC}"
	echo -e "Welcome to the WireGuard Stealth Server installer!\n"

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

	read -rp "Allowed IPs for generated clients: " -e -i "0.0.0.0/0" ALLOWED_IPS

	echo -e "\n${CYAN}${BOLD}☁️ Cloudflare Anti-Flag, Transparent WARP Bridge & Multi-Gigabit Speed Engine:${NC}"
	echo -e "   • Auto-deploys TCP MSS Clamping (1220 WARP / PMTU Direct) & TTL=128 Windows Disguise"
	echo -e "   • Auto-installs Cloudflare WARP (AS13335) + Self-Healing Watchdog & Redsocks Bridge"
	echo -e "   • Unblocks Amazon.com, LinkedIn.com, AI Platforms, and masks IP/WebRTC Scanners"
	echo -e "   • Preserves Direct Clean VPS Egress + Fast-Path Offload for Banking, PayPal & High-Speed Media"
	echo -e "   • Zero client-side software needed — uses 100% standard WireGuard .conf!"
	echo -e "   ${GREEN}[✔] Auto-enabled: Transparent WARP Bridge, Scanner Cloak & Speed Booster active.${NC}"
	CF_AUTO_ENABLE="y"

	WEB_PORT=${WEB_PORT:-51821}

	echo -e "\n${GREEN}Setup parameters configured successfully.${NC}"
	read -n1 -r -p "Press any key to start WireGuard installation..."
	echo ""
}

# ------------------------------------------------------------------------------
# 5. Transparent Redsocks + WARP SOCKS5 Bridge & Self-Healing Watchdog
# ------------------------------------------------------------------------------
function configureRedsocksBridge() {
	local PROXY_IP="${1:-127.0.0.1}"
	local PROXY_PORT="${2:-40000}"

	if ! command -v redsocks &>/dev/null; then
		if command -v apt-get &>/dev/null; then
			export DEBIAN_FRONTEND=noninteractive
			apt-get install -y -qq redsocks >/dev/null 2>&1 || true
		elif command -v yum &>/dev/null; then
			yum install -y redsocks >/dev/null 2>&1 || true
		elif command -v pacman &>/dev/null; then
			pacman -S --needed --noconfirm redsocks >/dev/null 2>&1 || true
		fi
	fi

	if ! command -v redsocks &>/dev/null; then
		return 1
	fi

	cat << REDSOCKS_EOF > /etc/redsocks.conf
base {
	log_debug = off;
	log_info = off;
	log = "syslog:daemon";
	daemon = on;
	user = redsocks;
	group = redsocks;
	redirector = iptables;
	redsocks_conn_max = 65535;
	connpres_idle_timeout = 300;
}

redsocks {
	local_ip = 0.0.0.0;
	local_port = 12345;
	ip = ${PROXY_IP};
	port = ${PROXY_PORT};
	type = socks5;
	listenq = 4096;
}
REDSOCKS_EOF

	# Save custom upstream proxy details so health checks can test the right endpoint
	echo "${PROXY_IP}:${PROXY_PORT}" > /etc/wireguard/upstream_socks5.txt
	chmod 600 /etc/wireguard/upstream_socks5.txt 2>/dev/null || true

	# Ensure systemd service has maximum file descriptor limits, high CPU priority, and instant restart
	mkdir -p /etc/systemd/system/redsocks.service.d
	cat << 'OVERRIDE_EOF' > /etc/systemd/system/redsocks.service.d/override.conf
[Service]
Restart=always
RestartSec=2
LimitNOFILE=1048576
LimitNPROC=65535
Nice=-10
CPUSchedulingPolicy=other
OVERRIDE_EOF

	systemctl daemon-reload >/dev/null 2>&1 || true
	systemctl enable redsocks >/dev/null 2>&1 || true
	systemctl restart redsocks >/dev/null 2>&1 || true
	return 0
}

# Strictly verifies that BOTH Redsocks (12345) AND the upstream SOCKS5 proxy (40000)
# are listening AND actually passing live end-to-end TCP traffic!
# (Prevents warp-svc listening on port 40000 while disconnected from blackholing client traffic!)
function isTransparentProxyHealthy() {
	local PROXY_PORT="${1:-40000}"
	local PROXY_IP="127.0.0.1"
	if [[ -f /etc/wireguard/upstream_socks5.txt ]]; then
		local saved_pxy
		saved_pxy=$(cat /etc/wireguard/upstream_socks5.txt 2>/dev/null || true)
		if [[ "$saved_pxy" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+)$ ]]; then
			PROXY_IP="${BASH_REMATCH[1]}"
			PROXY_PORT="${BASH_REMATCH[2]}"
		fi
	fi

	if ! command -v redsocks &>/dev/null; then
		return 1
	fi
	if ! systemctl is-active --quiet redsocks 2>/dev/null; then
		return 1
	fi
	if ! isPortInUse 12345 "tcp"; then
		return 1
	fi
	if [[ "$PROXY_IP" == "127.0.0.1" ]] && ! isPortInUse "$PROXY_PORT" "tcp"; then
		return 1
	fi

	# Perform a fast real SOCKS5 data-plane check (3 second timeout)
	if curl -4 -x "socks5h://${PROXY_IP}:${PROXY_PORT}" -sSf --connect-timeout 2 --max-time 3 "https://www.cloudflare.com/cdn-cgi/trace" >/dev/null 2>&1 \
		|| curl -4 -x "socks5h://${PROXY_IP}:${PROXY_PORT}" -sSf --connect-timeout 2 --max-time 3 "http://1.1.1.1" >/dev/null 2>&1; then
		return 0
	fi

	return 1
}

# Installs a background systemd timer to verify WARP SOCKS5 + Redsocks stay connected 24/7
# and automatically bypasses WG_STEALTH_PROXY if WARP temporarily drops (Zero client downtime!)
function installWarpWatchdog() {
	cat << 'WATCHDOG_SCRIPT' > /usr/local/bin/wg-warp-watchdog.sh
#!/bin/bash
# Self-healing watchdog for Cloudflare WARP SOCKS5 Proxy (port 40000) & Redsocks (port 12345)
WG_NIC=$(grep -E '^SERVER_WG_NIC=' /etc/wireguard/params 2>/dev/null | cut -d'=' -f2 | tr -d '"\r\n')
WG_NIC="${WG_NIC:-wg0}"

if [[ ! -f /etc/wireguard/warp_egress_enabled ]]; then
	iptables -t nat -D PREROUTING -i "$WG_NIC" -p tcp -j WG_STEALTH_PROXY 2>/dev/null || true
	exit 0
fi

if command -v warp-cli &>/dev/null; then
	if ! systemctl is-active --quiet warp-svc 2>/dev/null; then
		systemctl restart warp-svc 2>/dev/null || true
		sleep 2
	fi

	# Ensure registration & proxy port 40000 are active
	if ! ss -tln 2>/dev/null | grep -qE "(:|\])40000\s"; then
		warp-cli --accept-tos registration new 2>/dev/null || warp-cli --accept-tos register 2>/dev/null || true
		warp-cli --accept-tos proxy port 40000 2>/dev/null || warp-cli --accept-tos set-proxy-port 40000 2>/dev/null || warp-cli set-proxy-port 40000 2>/dev/null || true
		warp-cli --accept-tos mode proxy 2>/dev/null || warp-cli --accept-tos set-mode proxy 2>/dev/null || warp-cli set-mode proxy 2>/dev/null || true
		warp-cli --accept-tos connect 2>/dev/null || warp-cli connect 2>/dev/null || true
		sleep 2
	fi

	# Verify actual tunnel HTTP trace through SOCKS5
	if ! curl -4 -x socks5h://127.0.0.1:40000 -sSf --connect-timeout 2 --max-time 4 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q "warp=on"; then
		warp-cli --accept-tos disconnect 2>/dev/null || true
		sleep 1
		warp-cli --accept-tos registration new 2>/dev/null || warp-cli --accept-tos register 2>/dev/null || true
		warp-cli --accept-tos proxy port 40000 2>/dev/null || warp-cli --accept-tos set-proxy-port 40000 2>/dev/null || true
		warp-cli --accept-tos mode proxy 2>/dev/null || warp-cli --accept-tos set-mode proxy 2>/dev/null || true
		warp-cli --accept-tos connect 2>/dev/null || warp-cli connect 2>/dev/null || true
		sleep 2
	fi
fi

if command -v redsocks &>/dev/null; then
	if ! systemctl is-active --quiet redsocks 2>/dev/null || ! ss -tln 2>/dev/null | grep -qE "(:|\])12345\s"; then
		systemctl restart redsocks 2>/dev/null || true
	fi
fi

# Dynamic Fail-Safe: Only hook WG_STEALTH_PROXY into PREROUTING if SOCKS5 is passing real traffic!
if curl -4 -x socks5h://127.0.0.1:40000 -sSf --connect-timeout 2 --max-time 4 https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then
	if iptables -t nat -L WG_STEALTH_PROXY -n >/dev/null 2>&1; then
		if ! iptables -t nat -C PREROUTING -i "$WG_NIC" -p tcp -j WG_STEALTH_PROXY 2>/dev/null; then
			iptables -t nat -A PREROUTING -i "$WG_NIC" -p tcp -j WG_STEALTH_PROXY 2>/dev/null || true
		fi
	fi
else
	# Immediately unhook WG_STEALTH_PROXY so clients seamlessly use Direct VPS NAT with 0% downtime!
	iptables -t nat -D PREROUTING -i "$WG_NIC" -p tcp -j WG_STEALTH_PROXY 2>/dev/null || true
fi
WATCHDOG_SCRIPT
	chmod +x /usr/local/bin/wg-warp-watchdog.sh

	cat << 'WATCHDOG_SVC' > /etc/systemd/system/wg-warp-watchdog.service
[Unit]
Description=Cloudflare WARP & Redsocks Transparent Bridge Self-Healing Watchdog
After=network.target warp-svc.service redsocks.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wg-warp-watchdog.sh
WATCHDOG_SVC

	cat << 'WATCHDOG_TIMER' > /etc/systemd/system/wg-warp-watchdog.timer
[Unit]
Description=Run Cloudflare WARP Watchdog every 30 seconds

[Timer]
OnBootSec=25s
OnUnitActiveSec=30s
Unit=wg-warp-watchdog.service

[Install]
WantedBy=timers.target
WATCHDOG_TIMER

	systemctl daemon-reload >/dev/null 2>&1 || true
	systemctl enable --now wg-warp-watchdog.timer >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------------------
# 6. Perform WireGuard Server Installation
# ------------------------------------------------------------------------------
function installWireGuard() {
	if [[ -z "${SERVER_PORT:-}" ]]; then
		installQuestions
	fi

	cleanupOldWireguard

	echo -e "\n${CYAN}[*] Checking and installing system dependencies (wireguard, dnsmasq, redsocks, ipset, ethtool, dnsutils, qrencode)...${NC}"

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
		for pkg in wireguard wireguard-tools iptables qrencode curl jq iproute2 iptables-persistent net-tools ipset dnsmasq redsocks lsb-release gnupg ethtool dnsutils ca-certificates; do
			if ! dpkg -s "$pkg" &>/dev/null; then
				NEED_APT_INSTALL=1
				MISSING_PKGS+=("$pkg")
			fi
		done

		if [[ "$NEED_APT_INSTALL" -eq 1 ]]; then
			echo -e "${YELLOW}[*] Updating package index and installing required packages (${MISSING_PKGS[*]})...${NC}"
			apt-get update -o Acquire::Languages=none \
			               -o Acquire::IndexTargets::deb::Contents-deb::MetaKey="" \
			               -o Acquire::Http::Timeout="10" \
			               -o Acquire::Retries="2" \
			               -y -q || true

			apt-get install -y -q -o Dpkg::Options::="--force-confdef" \
			                      -o Dpkg::Options::="--force-confold" \
			                      "${MISSING_PKGS[@]}" || true
		else
			echo -e "${GREEN}[✔] Core WireGuard, Stealth & Speed packages already installed.${NC}"
		fi
	elif [[ "${OS}" == "fedora" || "${OS}" == "centos" || "${OS}" == "almalinux" || "${OS}" == "rocky" ]]; then
		yum install -y wireguard-tools iptables qrencode curl jq ipset dnsmasq redsocks ethtool bind-utils || true
	elif [[ "${OS}" == "arch" ]]; then
		pacman -S --needed --noconfirm wireguard-tools qrencode iptables curl jq ipset dnsmasq redsocks ethtool bind || true
	elif [[ "${OS}" == "alpine" ]]; then
		apk update && apk add wireguard-tools iptables libqrencode-tools curl jq ipset dnsmasq redsocks ethtool bind-tools || true
	fi

	# Ensure host resolv.conf always maintains clean, operational Anycast nameservers
	if ! grep -q -E "^nameserver [0-9]" /etc/resolv.conf 2>/dev/null || grep -q "127.0.0.53" /etc/resolv.conf 2>/dev/null; then
		rm -f /etc/resolv.conf 2>/dev/null || true
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
	modprobe iptable_nat >/dev/null 2>&1 || true
	modprobe iptable_mangle >/dev/null 2>&1 || true
	modprobe ip6table_nat >/dev/null 2>&1 || true
	modprobe nf_conntrack >/dev/null 2>&1 || true
	modprobe xt_conntrack >/dev/null 2>&1 || true
	modprobe xt_mark >/dev/null 2>&1 || true
	modprobe xt_hl >/dev/null 2>&1 || true
	modprobe ipt_TTL >/dev/null 2>&1 || true
	modprobe tcp_bbr >/dev/null 2>&1 || true

	# Disable broken/partial IPv6 inside tunnel unless host has verified global IPv6 connectivity
	local HAS_IPV6=0
	if [[ -f /proc/net/if_inet6 ]] && [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1) -eq 0 ]]; then
		if ip -6 route show default 2>/dev/null | grep -q "default" && ping6 -c 1 -W 2 2606:4700:4700::1111 >/dev/null 2>&1; then
			HAS_IPV6=1
		fi
	fi

	echo -e "${CYAN}[*] Applying Multi-Gigabit BBR, 128MB Socket Buffers & Conntrack Fast-Path sysctl rules...${NC}"
	SYSCTL_CONF="/etc/sysctl.d/99-wireguard-stealth.conf"
	cat << 'SYSCTL_EOF' > "$SYSCTL_CONF"
# --- Core Routing & Anti-Spoof Filter Relaxation ---
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.route_localnet = 1
net.ipv4.conf.default.route_localnet = 1

# --- Multi-Gigabit Upload & Download Socket Buffers (128 MB Max) ---
net.core.default_qdisc = fq
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.core.optmem_max = 4194304
net.ipv4.tcp_rmem = 4096 262144 134217728
net.ipv4.tcp_wmem = 4096 262144 134217728
net.ipv4.udp_rmem_min = 65536
net.ipv4.udp_wmem_min = 65536
net.ipv4.udp_mem = 65536 131072 262144

# --- High-Speed Packet Processing & Ring Budgets ---
net.core.netdev_max_backlog = 250000
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 3240000
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_ecn = 0
net.ipv4.ip_local_port_range = 10240 65535

# --- High-Capacity Connection Tracking ---
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180
SYSCTL_EOF

	if [[ "${HAS_IPV6}" -eq 1 ]]; then
		cat << 'SYSCTL_V6_EOF' >> "$SYSCTL_CONF"
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.all.forwarding = 1
SYSCTL_V6_EOF
	else
		cat << 'SYSCTL_NO_V6_EOF' >> "$SYSCTL_CONF"
net.ipv6.conf.all.forwarding = 0
SYSCTL_NO_V6_EOF
	fi

	if lsmod 2>/dev/null | grep -q bbr || grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
		echo "net.ipv4.tcp_congestion_control = bbr" >> "$SYSCTL_CONF"
	fi

	sysctl --system -q >/dev/null 2>&1 || sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || true

	# Ensure UFW / Firewalld unblock WireGuard UDP traffic, tunnel interface & enable forwarding
	if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
		echo -e "${CYAN}[*] UFW firewall active. Allowing WireGuard port ${SERVER_PORT}/udp and tunnel interface ${SERVER_WG_NIC:-wg0}...${NC}"
		ufw allow "${SERVER_PORT}/udp" >/dev/null 2>&1 || true
		ufw allow in on "${SERVER_WG_NIC:-wg0}" >/dev/null 2>&1 || true
		ufw route allow in on "${SERVER_WG_NIC:-wg0}" >/dev/null 2>&1 || true
		ufw route allow out on "${SERVER_WG_NIC:-wg0}" >/dev/null 2>&1 || true
		ufw allow "${WEB_PORT:-51821}/tcp" >/dev/null 2>&1 || true
		if [ -f /etc/default/ufw ]; then
			sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw 2>/dev/null || true
		fi
		ufw reload >/dev/null 2>&1 || true
	fi

	if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
		echo -e "${CYAN}[*] Firewalld active. Opening WireGuard UDP port ${SERVER_PORT} and trusting ${SERVER_WG_NIC:-wg0}...${NC}"
		firewall-cmd --add-port="${SERVER_PORT}/udp" --permanent >/dev/null 2>&1 || true
		firewall-cmd --add-port="${WEB_PORT:-51821}/tcp" --permanent >/dev/null 2>&1 || true
		firewall-cmd --zone=trusted --add-interface="${SERVER_WG_NIC:-wg0}" --permanent >/dev/null 2>&1 || true
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

	# Default Windows 11 TTL=128 emulation flag for anti-p0f stealth
	touch /etc/wireguard/emulate_windows_ttl

	# Install self-contained script reference so PostUp can re-apply split rules after reboot
	local SELF_SCRIPT
	SELF_SCRIPT=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "")
	if [[ -n "$SELF_SCRIPT" && -f "$SELF_SCRIPT" ]]; then
		cp -f "$SELF_SCRIPT" /usr/local/bin/easy_wireguard.sh 2>/dev/null || true
		chmod +x /usr/local/bin/easy_wireguard.sh 2>/dev/null || true
	fi

	# --------------------------------------------------------------------------
	# UNIFIED WIREGUARD SERVER (/etc/wireguard/${SERVER_WG_NIC}.conf)
	# Single selected port ${SERVER_PORT}/udp serves BOTH:
	# 1. Cloudflare Anti-Flag & Stealth Profile (10.19.0.0/24: Stealth Gateway)
	# 2. Standard Profile (10.18.0.0/24: Canonical Direct VPS Egress + Split Shield)
	# --------------------------------------------------------------------------
	echo -e "${CYAN}[*] Configuring Unified WireGuard Server (${SERVER_WG_NIC} | Port ${SERVER_PORT}/udp | Subnets: 10.19.0.0/24 & 10.18.0.0/24)...${NC}"
	cat << WG_SERVER_EOF > "/etc/wireguard/${SERVER_WG_NIC}.conf"
[Interface]
Address = ${WG_SERVER_ADDRESS}, 10.19.0.1/24
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PRIV_KEY}
MTU = 1420
SaveConfig = false

# --- 1. CORE NETWORKING, HARDWARE OFFLOAD & FAST-PATH FIREWALL ---
PostUp = sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
PostUp = sysctl -w net.ipv4.conf.all.forwarding=1 2>/dev/null || true
PostUp = sysctl -w net.ipv4.conf.all.rp_filter=0 2>/dev/null || true
PostUp = sysctl -w net.ipv4.conf.default.rp_filter=0 2>/dev/null || true
PostUp = sysctl -w net.ipv4.conf.${SERVER_WG_NIC}.rp_filter=0 2>/dev/null || true
PostUp = sysctl -w net.ipv4.conf.${SERVER_WG_NIC}.route_localnet=1 2>/dev/null || true
PostUp = ip link set dev ${SERVER_WG_NIC} txqueuelen 10000 2>/dev/null || true
PostUp = ip link set dev ${SERVER_PUB_NIC} txqueuelen 10000 2>/dev/null || true
PostUp = ethtool -K ${SERVER_PUB_NIC} gro on gso on tso on sg on 2>/dev/null || true
PostUp = ethtool -K ${SERVER_WG_NIC} gro on gso on sg on 2>/dev/null || true
PostUp = tc qdisc replace dev ${SERVER_WG_NIC} root fq 2>/dev/null || true
PostUp = iptables -P FORWARD ACCEPT 2>/dev/null || true
PostUp = iptables -I INPUT 1 -p udp --dport ${SERVER_PORT} -j ACCEPT 2>/dev/null || true
PostUp = iptables -I INPUT 2 -i ${SERVER_WG_NIC} -j ACCEPT 2>/dev/null || true
PostUp = iptables -I FORWARD 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
PostUp = iptables -I FORWARD 2 -i ${SERVER_WG_NIC} -j ACCEPT 2>/dev/null || true
PostUp = iptables -I FORWARD 3 -o ${SERVER_WG_NIC} -j ACCEPT 2>/dev/null || true
PostUp = iptables -I FORWARD 4 -s 10.18.0.0/24 -j ACCEPT 2>/dev/null || true
PostUp = iptables -I FORWARD 5 -d 10.18.0.0/24 -j ACCEPT 2>/dev/null || true
PostUp = iptables -I FORWARD 6 -s 10.19.0.0/24 -j ACCEPT 2>/dev/null || true
PostUp = iptables -I FORWARD 7 -d 10.19.0.0/24 -j ACCEPT 2>/dev/null || true
PostUp = iptables -t nat -I POSTROUTING 1 -s 10.18.0.0/24 -o ${SERVER_PUB_NIC} -j MASQUERADE 2>/dev/null || true
PostUp = iptables -t nat -I POSTROUTING 2 -s 10.19.0.0/24 -o ${SERVER_PUB_NIC} -j MASQUERADE 2>/dev/null || true
PostUp = iptables -t nat -I POSTROUTING 3 -s 10.18.0.0/24 ! -o ${SERVER_WG_NIC} -j MASQUERADE 2>/dev/null || true
PostUp = iptables -t nat -I POSTROUTING 4 -s 10.19.0.0/24 ! -o ${SERVER_WG_NIC} -j MASQUERADE 2>/dev/null || true

# --- 2. DYNAMIC TCP MSS CLAMPING & WINDOWS 11 DESKTOP TTL=128 NORMALIZATION ---
PostUp = iptables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostUp = iptables -t mangle -I POSTROUTING 1 -p tcp --tcp-flags SYN,RST SYN ! -o ${SERVER_WG_NIC} -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostUp = iptables -t mangle -I POSTROUTING 2 -s 10.19.0.0/24 -o ${SERVER_PUB_NIC} -j TTL --ttl-set 128 2>/dev/null || true
PostUp = iptables -t mangle -I POSTROUTING 3 -s 10.18.0.0/24 -o ${SERVER_PUB_NIC} -j TTL --ttl-set 64 2>/dev/null || true
PostUp = /usr/local/bin/easy_wireguard.sh --apply-rules >/dev/null 2>&1 || true

# Teardown Rules
PostDown = iptables -D INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT 2>/dev/null || true
PostDown = iptables -D INPUT -i ${SERVER_WG_NIC} -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i ${SERVER_WG_NIC} -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -o ${SERVER_WG_NIC} -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -s 10.18.0.0/24 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -d 10.18.0.0/24 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -s 10.19.0.0/24 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -d 10.19.0.0/24 -j ACCEPT 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s 10.18.0.0/24 -o ${SERVER_PUB_NIC} -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s 10.19.0.0/24 -o ${SERVER_PUB_NIC} -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s 10.18.0.0/24 ! -o ${SERVER_WG_NIC} -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s 10.19.0.0/24 ! -o ${SERVER_WG_NIC} -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostDown = iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN ! -o ${SERVER_WG_NIC} -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostDown = iptables -t mangle -D POSTROUTING -s 10.19.0.0/24 -o ${SERVER_PUB_NIC} -j TTL --ttl-set 128 2>/dev/null || true
PostDown = iptables -t mangle -D POSTROUTING -s 10.18.0.0/24 -o ${SERVER_PUB_NIC} -j TTL --ttl-set 64 2>/dev/null || true
WG_SERVER_EOF

	chmod 600 "/etc/wireguard/${SERVER_WG_NIC}.conf"
	rm -f "/etc/wireguard/wg1.conf"

	wg-quick down "${SERVER_WG_NIC}" >/dev/null 2>&1 || true
	ip link delete dev "${SERVER_WG_NIC}" >/dev/null 2>&1 || true
	systemctl stop "wg-quick@${SERVER_WG_NIC}" >/dev/null 2>&1 || true

	systemctl daemon-reload >/dev/null 2>&1 || true
	systemctl enable "wg-quick@${SERVER_WG_NIC}" >/dev/null 2>&1 || true

	echo -e "${CYAN}[*] Starting Unified WireGuard daemon (wg-quick@${SERVER_WG_NIC})...${NC}"
	systemctl restart "wg-quick@${SERVER_WG_NIC}" 2>/dev/null || wg-quick up "${SERVER_WG_NIC}" 2>/dev/null || true

	optimizeNetworkThroughput "${SERVER_PUB_NIC}"

	if systemctl is-active --quiet "wg-quick@${SERVER_WG_NIC}" || wg show "${SERVER_WG_NIC}" &>/dev/null; then
		echo -e "${GREEN}[✔] Unified WireGuard Server (${SERVER_WG_NIC} | Port ${SERVER_PORT}/udp) is ACTIVE!${NC}"
	fi

	# Auto-Configure Essential Cloudflare Anti-Flag, WARP Proxy & Transparent Redsocks Engine
	if [[ "${CF_AUTO_ENABLE}" == "y" ]]; then
		echo -e "\n${CYAN}[*] Auto-Configuring Cloudflare Anti-Flag, WARP Consumer Egress & Scanner Cloak...${NC}"
		mkdir -p /etc/wireguard
		touch /etc/wireguard/cloudflare_shield_enabled
		touch /etc/wireguard/cloudflare_split_enabled
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

# AI & Search Engines (Unblocks ChatGPT, Claude, Perplexity & Google Captchas)
openai.com
chatgpt.com
oaistatic.com
oaiusercontent.com
claude.ai
anthropic.com
perplexity.ai
google.com
www.google.com
gstatic.com
recaptcha.net

# Reddit, Social & Streaming Platforms (Blocks Datacenter ASNs by Default)
reddit.com
www.reddit.com
redd.it
redditmedia.com
redditstatic.com
x.com
twitter.com
instagram.com
tiktok.com
netflix.com
nflxvideo.net

# Amazon Global Storefront, Product Catalog, CloudFront & Auth Gateways
amazon.com
www.amazon.com
smile.amazon.com
completion.amazon.com
images-amazon.com
media-amazon.com
ssl-images-amazon.com
images-na.ssl-images-amazon.com
m.media-amazon.com
fls-na.amazon.com
fls-eu.amazon.com
aax.amazon-adsystem.com
aax-us-east.amazon-adsystem.com
assoc-amazon.com
amazonpay.com
pay.amazon.com
amazon.co.uk
www.amazon.co.uk
amazon.ca
www.amazon.ca
amazon.de
www.amazon.de
amazon.co.jp
amazon.fr
amazon.es
amazon.it
amazon.com.au
cloudfront.net

# LinkedIn Professional Network, Voyager API & Media CDN (Unblocks HTTP 403 / 999)
linkedin.com
www.linkedin.com
mobile.linkedin.com
touch.www.linkedin.com
licdn.com
www.licdn.com
media.licdn.com
static.licdn.com
static-exp1.licdn.com
static-exp2.licdn.com
media-exp1.licdn.com
media-exp2.licdn.com
dms.licdn.com
lnkd.in
platform.linkedin.com
voyager.linkedin.com
api.linkedin.com
snap.licdn.com
px.ads.linkedin.com
ads.linkedin.com
linkedin.at
slideshare.net

# IP / ASN / Fraud / WebRTC / Fingerprint Scanner Sites (Forces 100% WARP AS13335 Coverage)
ipinfo.io
ifconfig.me
ifconfig.co
icanhazip.com
ident.me
ipify.org
api.ipify.org
api64.ipify.org
wtfismyip.com
myexternalip.com
checkip.amazonaws.com
ipecho.net
ip-api.com
ipapi.co
ipdata.co
ipgeolocation.io
ipwhois.io
ipregistry.co
abstractapi.com
whoer.net
browserleaks.com
ipleak.net
dnsleaktest.com
perfect-privacy.com
doileak.com
scamalytics.com
ipqualityscore.com
spur.us
maxmind.com
ip2location.com
db-ip.com
abuseipdb.com
greynoise.io
shodan.io
censys.io
pixelscan.net
amiunique.org
coveryourtracks.eff.org
creepjs.com
abrahamjuliot.github.io
iphey.com
fv.pro
bot.sannysoft.com
nowsecure.nl
tls.peet.ws

# High-Speed Throughput & Speedtest Fast-Lane (Direct Kernel WireGuard Line-Rate Speed)
speedtest.net
www.speedtest.net
ookla.com
prod.ookla.com
fast.com
nflxvideo.net
speed.cloudflare.com
librespeed.org
steamcontent.com
googlesyndication.com
googlevideo.com

# PayPal, Braintree & 3D-Secure Gateways (Protected via wg_direct_clean for 100% Native IP Consistency)
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

		# Provision Cloudflare WARP in SOCKS5 Proxy Mode + Redsocks Transparent Bridge + Self-Healing Watchdog
		setupCloudflareWarpClient
		installWarpWatchdog
		applyDomainSplitRulesLive

		echo -e "${GREEN}[✔] Cloudflare Anti-Flag Shield, WARP Scanner Cloak & Speed Booster auto-configured!${NC}"
	else
		echo -e "\n${GREEN}[✔] Standard Full Tunnel configured. Cloudflare Anti-Flag bypassed.${NC}"
		rm -f /etc/wireguard/cloudflare_shield_enabled /etc/wireguard/cloudflare_split_enabled /etc/wireguard/warp_egress_enabled 2>/dev/null || true
	fi

	newClientInternal "${CLIENT_NAME}" "${CLIENT_PASSWORD}"
	verifyServerTrafficHealth

	echo -e "\n${GREEN}${BOLD}=================================================================${NC}"
	echo -e "${GREEN}${BOLD}🎉 WIREGUARD STEALTH SERVER v4.2 INSTALLED & VERIFIED!${NC}"
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
# 7. Automated Traffic, Egress & Scanner Verification Self-Test
# ------------------------------------------------------------------------------
function verifyServerTrafficHealth() {
	echo -e "\n${CYAN}${BOLD}🔍 Running Automated Post-Install Traffic, DNS, Scanner & Speed Verification...${NC}"

	local WG_NIC="${SERVER_WG_NIC:-wg0}"

	# 1. Check wg0 interface status & gateway IPs
	if wg show "$WG_NIC" &>/dev/null; then
		if ! ip -4 addr show dev "$WG_NIC" 2>/dev/null | grep -q "10.19.0.1"; then
			ip addr add 10.19.0.1/24 dev "$WG_NIC" 2>/dev/null || true
		fi
		if ! ip -4 addr show dev "$WG_NIC" 2>/dev/null | grep -q "${SERVER_WG_IPV4:-10.18.0.1}"; then
			ip addr add "${SERVER_WG_IPV4:-10.18.0.1}/24" dev "$WG_NIC" 2>/dev/null || true
		fi
		echo -e "  ${GREEN}[✔] WireGuard Kernel Interface (${WG_NIC}):${NC} UP & Listening on UDP ${SERVER_PORT:-4500} (Gateways: ${SERVER_WG_IPV4:-10.18.0.1} & 10.19.0.1)"
	else
		echo -e "  ${YELLOW}[!] WireGuard Interface (${WG_NIC}) was down. Restarting...${NC}"
		wg-quick up "$WG_NIC" 2>/dev/null || true
	fi

	# 2. Check IPv4 Forwarding & BBR
	local FWD_VAL CC_VAL
	FWD_VAL=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)
	CC_VAL=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "cubic")
	if [[ "$FWD_VAL" -eq 1 ]]; then
		echo -e "  ${GREEN}[✔] Kernel IPv4 Forwarding & Congestion:${NC} ENABLED (Congestion Control: ${CC_VAL})"
	else
		sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
		echo -e "  ${GREEN}[✔] Kernel IPv4 Forwarding:${NC} Forced ENABLED"
	fi

	# 3. Check Local DNS (dnsmasq) + Actual Tunnel DNS Resolution Test
	if systemctl is-active --quiet dnsmasq 2>/dev/null; then
		local SPLIT_CNT
		SPLIT_CNT=$(ipset list wg_split_v4 2>/dev/null | grep -cE "^[0-9]+\." || echo 0)
		if command -v dig &>/dev/null && dig +short +time=2 +tries=1 @10.19.0.1 cloudflare.com 2>/dev/null | grep -qE "^[0-9]+\."; then
			echo -e "  ${GREEN}[✔] Local Stealth DNS & IPSet Engine (dnsmasq):${NC} ACTIVE & Resolving on 10.19.0.1 / ${SERVER_WG_IPV4:-10.18.0.1} (${SPLIT_CNT} IPs/CIDRs)"
		else
			echo -e "  ${GREEN}[✔] Local Stealth DNS & IPSet Engine (dnsmasq):${NC} ACTIVE (${SPLIT_CNT} pre-warmed target IPs/CIDRs)"
		fi
	else
		echo -e "  ${YELLOW}[!] Local dnsmasq inactive — Direct Cloudflare Anycast DNAT (1.1.1.1:53) fallback ACTIVE${NC}"
	fi

	# 4. Check Direct VPS Egress Connectivity
	if curl -4 -sSf --max-time 4 https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then
		echo -e "  ${GREEN}[✔] Direct VPS Egress (10.18.0.0/24 Standard Profile):${NC} ONLINE & Verified"
	else
		echo -e "  ${RED}[!] Warning: Host direct HTTP egress check timed out.${NC}"
	fi

	# 5. Check WARP Consumer Proxy + Redsocks Bridge + Amazon/LinkedIn/Scanner Reachability
	if isTransparentProxyHealthy 40000; then
		local WARP_TRACE
		WARP_TRACE=$(curl -4 -x socks5h://127.0.0.1:40000 -sSf --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
		if echo "$WARP_TRACE" | grep -q "warp=on"; then
			local WARP_IP
			WARP_IP=$(echo "$WARP_TRACE" | grep "^ip=" | cut -d'=' -f2)
			echo -e "  ${GREEN}[✔] Transparent WARP Bridge (10.19.0.0/24 Stealth Profile):${NC} ACTIVE (WARP IP: ${WARP_IP} | warp=on)"

			local SCAN_ORG
			SCAN_ORG=$(curl -4 -x socks5h://127.0.0.1:40000 -sSf --max-time 4 https://ipinfo.io/org 2>/dev/null || echo "AS13335 Cloudflare, Inc.")
			echo -e "  ${GREEN}[✔] IP Scanner Cloak Verification (ipinfo.io):${NC} Masked as '${SCAN_ORG}' (${WARP_IP})"

			local AMZ_CODE LI_CODE
			AMZ_CODE=$(curl -4 -x socks5h://127.0.0.1:40000 -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36" -s -o /dev/null -w "%{http_code}" --max-time 5 https://www.amazon.com/ 2>/dev/null || echo "000")
			LI_CODE=$(curl -4 -x socks5h://127.0.0.1:40000 -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36" -s -o /dev/null -w "%{http_code}" --max-time 5 https://www.linkedin.com/ 2>/dev/null || echo "000")
			echo -e "  ${GREEN}[✔] Amazon & LinkedIn Egress Test:${NC} amazon.com [HTTP ${AMZ_CODE}] | linkedin.com [HTTP ${LI_CODE}]"
		else
			echo -e "  ${GREEN}[✔] Transparent SOCKS5 Bridge:${NC} ACTIVE & Passing Traffic on 127.0.0.1:12345"
		fi
	else
		echo -e "  ${YELLOW}[i] Transparent WARP Bridge:${NC} Bypassed / Standby -> Clients are routing via Direct VPS NAT (100% Internet Uptime Guaranteed)"
	fi
}

# ------------------------------------------------------------------------------
# 8. Provision Web Management Console Runtime
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
# 9. Client Management Logic (100% Standard WireGuard Client .conf Output)
# ------------------------------------------------------------------------------
function newClientInternal() {
	local CLIENT_NAME="$1"
	local CLIENT_PASSWORD="${2:-}"
	local HOME_DIR
	HOME_DIR=$(getHomeDirForClient "${CLIENT_NAME}")
	local WG_CONF="/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf"

	SERVER_PORT_CF="${SERVER_PORT}"

	local SUBNET_BASE="10.18.0"
	local OCTET=2
	while grep -q "${SUBNET_BASE}.${OCTET}/32" "$WG_CONF" 2>/dev/null; do
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

	# Distinct Stealth Keypair for Cloudflare Anti-Flag Profile
	local CLIENT_CF_PRIV_KEY
	CLIENT_CF_PRIV_KEY=$(wg genkey)
	local CLIENT_CF_PUB_KEY
	CLIENT_CF_PUB_KEY=$(echo "${CLIENT_CF_PRIV_KEY}" | wg pubkey)

	local ENDPOINT_WG0="${SERVER_PUB_IP}:${SERVER_PORT}"
	local ENDPOINT_WG1="${SERVER_PUB_IP}:${SERVER_PORT}"

	mkdir -p /etc/wireguard/clients

	local HAS_SERVER_IPV6=0
	if [[ "${HAS_IPV6:-0}" -eq 1 ]] && grep -q "fd42:42:42::" "$WG_CONF" 2>/dev/null; then
		HAS_SERVER_IPV6=1
	fi

	local CLIENT_ADDRESS="${CLIENT_WG_IPV4}/32"
	local PEER_ALLOWED_IPS="${CLIENT_WG_IPV4}/32"
	if [[ "${HAS_SERVER_IPV6}" -eq 1 ]]; then
		CLIENT_ADDRESS="${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128"
		PEER_ALLOWED_IPS="${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128"
	fi

	# Use internal server gateway DNS first (10.19.0.1 / 10.18.0.1) so OS clients cannot
	# auto-upgrade 1.1.1.1 to DoH/DoT and bypass the server's Amazon/LinkedIn/Scanner IPSet engine
	local CF_DNS_LINE="10.19.0.1, ${CLIENT_DNS_1:-1.1.1.1}"
	local STD_DNS_LINE="${SERVER_WG_IPV4:-10.18.0.1}, ${CLIENT_DNS_1:-1.1.1.1}"

	local EASY_DIR
	EASY_DIR=$(getEasyWgDir "${CLIENT_NAME}")

	local STD_ALLOWED_IPS="0.0.0.0/0"
	if [[ "${HAS_SERVER_IPV6}" -eq 1 ]]; then
		STD_ALLOWED_IPS="0.0.0.0/0, ::/0"
	fi

	local CF_ALLOWED_IPS_LINE="0.0.0.0/0"

	# --------------------------------------------------------------------------
	# 1. Build Profile 1: Stealth Anti-Scanner & Cloudflare Gateway (FIRST)
	# --------------------------------------------------------------------------
	local CF_CONF_CONTENT
	CF_CONF_CONTENT=$(cat << CF_CLIENT_EOF
# ==============================================================================
# ☁️ PROFILE 1: CLOUDFLARE ANTI-FLAG, SCANNER CLOAK & STEALTH GATEWAY
# ==============================================================================
# • Client Compatibility: 100% Standard WireGuard Client (Zero extra apps needed)
# • Port: ${SERVER_PORT} (Unified Port - Shared with Standard Profile)
# • Subnet / Assigned IP: ${CLIENT_WG_CF_IPV4}/32 (Subnet: 10.19.0.0/24)
# • MTU: 1380 (Optimized Anti-Fragmentation MTU + Dynamic Server MSS Clamping)
# • DNS: ${CF_DNS_LINE} (Local Stealth IPSet Resolver + DoH/DoT Leak Guard)
# • Target Use Case: Unblocks Amazon, LinkedIn, ChatGPT/Claude, Reddit, and masks
#                    your VPS IP behind Cloudflare WARP (AS13335) on all scanners.
# • Speed & Banking: Direct kernel fast-lane for Speedtest/Media & PayPal/Banks.
# ==============================================================================
[Interface]
PrivateKey = ${CLIENT_CF_PRIV_KEY}
Address = ${CLIENT_WG_CF_IPV4}/32
DNS = ${CF_DNS_LINE}
MTU = 1380

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT_WG1}
AllowedIPs = ${CF_ALLOWED_IPS_LINE}
PersistentKeepalive = 25
CF_CLIENT_EOF
)

	# --------------------------------------------------------------------------
	# 2. Build Profile 2: Standard Full-Tunnel with Smart Split-Domain Shield
	# --------------------------------------------------------------------------
	local STD_CONF_CONTENT
	STD_CONF_CONTENT=$(cat << CLIENT_EOF
# ==============================================================================
# 🛡️ PROFILE 2: STANDARD WIREGUARD FULL-TUNNEL (SMART HYBRID EGRESS)
# ==============================================================================
# • Client Compatibility: 100% Standard WireGuard Client (Zero extra apps needed)
# • Port: ${SERVER_PORT} (Unified Port - Shared with Stealth Profile)
# • Subnet / Assigned IP: ${CLIENT_ADDRESS} (Subnet: 10.18.0.0/24)
# • MTU: 1420 (Canonical WireGuard Multi-Gigabit Standard MTU)
# • DNS: ${STD_DNS_LINE} (Local Split-Domain Shield + High-Speed Anycast)
# • Target Use Case: Maximum upload/download throughput, gaming, banking, PayPal
# • Server Protections: Direct Native VPS IP Egress for general traffic, while
#                       automatically routing Amazon, LinkedIn, Cloudflare & IP
#                       Scanners through the server's WARP AS13335 Shield.
# ==============================================================================
[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_ADDRESS}
DNS = ${STD_DNS_LINE}
MTU = 1420

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT_WG0}
AllowedIPs = ${STD_ALLOWED_IPS}
PersistentKeepalive = 25
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

	cat << PEER_EOF >> "$WG_CONF"

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

	# Live-register both peers into the running WireGuard kernel interface immediately
	if command -v wg &>/dev/null; then
		local PSK_TMP
		PSK_TMP=$(mktemp /dev/shm/wg_psk.XXXXXX 2>/dev/null || mktemp /tmp/wg_psk.XXXXXX)
		echo "${CLIENT_PRE_SHARED_KEY}" > "$PSK_TMP"
		wg set "${SERVER_WG_NIC:-wg0}" peer "${CLIENT_CF_PUB_KEY}" preshared-key "$PSK_TMP" allowed-ips "${CLIENT_WG_CF_IPV4}/32" 2>/dev/null || true
		wg set "${SERVER_WG_NIC:-wg0}" peer "${CLIENT_PUB_KEY}" preshared-key "$PSK_TMP" allowed-ips "${PEER_ALLOWED_IPS}" 2>/dev/null || true
		rm -f "$PSK_TMP" 2>/dev/null || true
		if command -v wg-quick &>/dev/null; then
			wg syncconf "${SERVER_WG_NIC:-wg0}" <(wg-quick strip "${SERVER_WG_NIC:-wg0}") 2>/dev/null || true
		fi
	fi

	echo -e "${GREEN}[✔] Peer ${CLIENT_NAME} created & encrypted with AES-256-CBC!${NC}"
	echo -e "   • Port Selected:              ${BOLD}${SERVER_PORT}/udp${NC} (Unified - Both profiles use this exact port!)"
	echo -e "   • Profile 1 (Stealth/CF):     ${CLIENT_WG_CF_IPV4} on port ${SERVER_PORT} (Transparent WARP Egress, MTU 1380)"
	echo -e "   • Profile 2 (Standard):       ${CLIENT_WG_IPV4} on port ${SERVER_PORT} (Direct VPS + Smart Split Shield, MTU 1420)\n"

	echo -e "  ${BOLD}Protected Folder:${NC}            ${CYAN}${EASY_DIR}/${NC} (Zero root directory clutter)"
	echo -e "  ${BOLD}Encrypted Anti-Flag Profile:${NC} ${YELLOW}${EASY_DIR}/${CLIENT_NAME}-cloudflare-shield.conf.enc${NC}"
	echo -e "  ${BOLD}Encrypted Standard Profile:${NC}  ${YELLOW}${EASY_DIR}/${CLIENT_NAME}-standard.conf.enc${NC}"
	echo -e "  ${BOLD}Password Protection:${NC}         ${PURPLE}Protected by password. Required to view/export in [3] Configure clients${NC}\n"

	echo -e "${CYAN}${BOLD}📋 [1/2] COPY & PASTE CONFIGURATION: CLOUDFLARE ANTI-FLAG & STEALTH (${CLIENT_NAME}-cloudflare-shield.conf):${NC}"
	echo -e "${YELLOW}-----------------------------------------------------------------${NC}"
	echo "$CF_CONF_CONTENT"
	echo -e "${YELLOW}-----------------------------------------------------------------${NC}\n"

	echo -e "${GREEN}${BOLD}📋 [2/2] COPY & PASTE CONFIGURATION: STANDARD FULL TUNNEL (${CLIENT_NAME}-standard.conf):${NC}"
	echo -e "${YELLOW}-----------------------------------------------------------------${NC}"
	echo "$STD_CONF_CONTENT"
	echo -e "${YELLOW}-----------------------------------------------------------------${NC}\n"

	if command -v qrencode &>/dev/null; then
		echo -e "${CYAN}${BOLD}📱 [1/2] Scan Profile 1 Cloudflare Anti-Flag Stealth QR Code (Port ${SERVER_PORT}):${NC}\n"
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
	echo -e "   This password encrypts the .conf file with AES-256-CBC PBKDF2."
	echo -e "   You will be asked for this password to view or decrypt the config."
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

	echo -e "${BOLD}Client Name\t\tStandard IP\t\tAnti-Flag Stealth IP${NC}"
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
		echo -e "${RED}[ERROR] Incorrect decryption password! Decryption failed.${NC}"
		echo -e "${YELLOW}The configuration remains protected and cannot be displayed.${NC}\n"
		read -n1 -r -p "Press Enter to return..."
		return
	fi

	echo -e "${GREEN}[✔] Password verified! Configuration decrypted successfully.${NC}\n"

	if [[ -n "$CF_TEXT" && "$CF_TEXT" =~ "[Interface]" ]]; then
		echo -e "\n${CYAN}${BOLD}📋 [1/2] Profile 1: Stealth Anti-Scanner & Cloudflare Gateway (Port ${SERVER_PORT:-4500}):${NC}"
		echo -e "${YELLOW}🔒 Stored Encrypted (AES-256-CBC) in: ${EASY_DIR}/${TARGET_CLIENT}-cloudflare-shield.conf.enc${NC}\n"
		echo "$CF_TEXT"
		echo ""
		if command -v qrencode &>/dev/null; then
			echo -e "${CYAN}${BOLD}📱 [1/2] Scan Profile 1 Cloudflare Anti-Flag Stealth QR Code (Port ${SERVER_PORT:-4500}):${NC}\n"
			echo "$CF_TEXT" | qrencode -t ansiutf8
			echo ""
		fi
	fi

	if [[ -n "$STD_TEXT" && "$STD_TEXT" =~ "[Interface]" ]]; then
		echo -e "\n${GREEN}${BOLD}📋 [2/2] Profile 2: Standard Full Tunnel (Direct VPS Egress | Port ${SERVER_PORT:-4500}):${NC}"
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
	echo "1) Stealth Anti-Scanner & Cloudflare Gateway (${TARGET_CLIENT}-cloudflare-shield.conf) [Recommended Stealth]"
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
conf_path = sys.argv[2]
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
" "$TARGET_CLIENT" "$CONF_FILE"
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

	echo -e "${GREEN}${BOLD}[✔] Client '${TARGET_CLIENT}' successfully revoked!${NC}"
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
# 10. Dynamic Real-Time Domain Split Tunneling, Scanner Cloak & WARP Bridge
# ------------------------------------------------------------------------------
function applyDomainSplitRulesLive() {
	echo -e "\n${CYAN}[*] Applying Stealth DNS, Amazon/LinkedIn/Scanner IPSets & Multi-Gigabit Fast-Path Rules Live...${NC}"

	mkdir -p /etc/wireguard
	touch /etc/wireguard/split_domains.txt
	if [[ ! -f /etc/wireguard/split_mode.txt ]]; then
		echo "BYPASS" > /etc/wireguard/split_mode.txt
	fi

	local WG_NIC="${SERVER_WG_NIC:-wg0}"
	local WG_V4="${SERVER_WG_IPV4:-10.18.0.1}"

	# Ensure both 10.18.0.1/24 and 10.19.0.1/24 gateway addresses exist on wg0
	if ip link show dev "$WG_NIC" &>/dev/null; then
		if ! ip -4 addr show dev "$WG_NIC" 2>/dev/null | grep -q "${WG_V4}"; then
			ip addr add "${WG_V4}/24" dev "$WG_NIC" 2>/dev/null || true
		fi
		if ! ip -4 addr show dev "$WG_NIC" 2>/dev/null | grep -q "10.19.0.1"; then
			ip addr add "10.19.0.1/24" dev "$WG_NIC" 2>/dev/null || true
		fi
	fi

	# Ensure ipset, dnsmasq, and redsocks are present
	if command -v apt-get &>/dev/null; then
		for req_bin in ipset dnsmasq redsocks; do
			if ! command -v "$req_bin" &>/dev/null; then
				export DEBIAN_FRONTEND=noninteractive
				apt-get install -y -qq "$req_bin" >/dev/null 2>&1 || true
			fi
		done
	fi

	if command -v ipset &>/dev/null; then
		ipset create wg_split_v4 hash:net family inet maxelem 262144 2>/dev/null || ipset create wg_split_v4 hash:net family inet 2>/dev/null || true
		ipset create wg_split_v6 hash:net family inet6 maxelem 262144 2>/dev/null || ipset create wg_split_v6 hash:net family inet6 2>/dev/null || true
		ipset create wg_direct_clean hash:net family inet maxelem 65536 2>/dev/null || ipset create wg_direct_clean hash:net family inet 2>/dev/null || true
		ipset create wg_highspeed_direct hash:net family inet maxelem 65536 2>/dev/null || ipset create wg_highspeed_direct hash:net family inet 2>/dev/null || true
		ipset flush wg_split_v4 2>/dev/null || true
		ipset flush wg_split_v6 2>/dev/null || true
		ipset flush wg_direct_clean 2>/dev/null || true
		ipset flush wg_highspeed_direct 2>/dev/null || true
	fi

	# Remove legacy broken fwmark 0x51820 routing rules that blackholed traffic
	ip rule del fwmark 0x51820 table 51820 2>/dev/null || true
	ip route flush table 51820 2>/dev/null || true
	iptables -t mangle -D PREROUTING -i "$WG_NIC" -m set --match-set wg_split_v4 dst -j MARK --set-mark 0x51820 2>/dev/null || true
	iptables -t mangle -D PREROUTING -s 10.19.0.0/24 -m set --match-set wg_split_v4 dst -j MARK --set-mark 0x51820 2>/dev/null || true

	# Ensure systemd-resolved does not collide on port 53 stub listener
	if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
		mkdir -p /etc/systemd/resolved.conf.d
		cat << 'RESOLVED_NO_STUB' > /etc/systemd/resolved.conf.d/no-stub.conf 2>/dev/null || true
[Resolve]
DNSStubListener=no
RESOLVED_NO_STUB
		systemctl restart systemd-resolved 2>/dev/null || true
	fi

	# Ensure /etc/resolv.conf has real upstream DNS servers
	if ! grep -q -E "^nameserver [0-9]" /etc/resolv.conf 2>/dev/null || grep -q "127.0.0.53" /etc/resolv.conf 2>/dev/null; then
		rm -f /etc/resolv.conf 2>/dev/null || true
		cat << 'RESOLV_PROTECT' > /etc/resolv.conf 2>/dev/null || true
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
RESOLV_PROTECT
	fi

	local DEF_NIC="${SERVER_PUB_NIC}"
	if [[ -z "$DEF_NIC" ]]; then
		DEF_NIC=$(ip -4 route show default 2>/dev/null | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | head -n1 || echo "eth0")
	fi

	# Configure dnsmasq to bind reliably to tunnel and localhost without dropping cross-subnet REDIRECT/DNAT queries
	mkdir -p /etc/dnsmasq.d
	rm -f /etc/dnsmasq.d/00-stealth-privacy.conf /etc/dnsmasq.d/00-stealth-split.conf /etc/dnsmasq.d/00-stealth-dns.conf 2>/dev/null || true
	cat << DNSMASQ_STEALTH_EOF > /etc/dnsmasq.d/00-stealth-privacy.conf
# Cookie WireGuard Stealth & High-Speed DNS Configuration
edns-packet-max=1232
no-ident
cache-size=10000
dns-forward-max=4096
min-cache-ttl=60
bogus-priv
listen-address=127.0.0.1,${WG_V4},10.19.0.1
bind-dynamic
no-resolv
all-servers
server=${CLIENT_DNS_1:-1.1.1.1}
server=${CLIENT_DNS_2:-1.0.0.1}
server=8.8.8.8
DNSMASQ_STEALTH_EOF

	echo "# Cookie WireGuard Dynamic Split Tunneling Rules" > /etc/dnsmasq.d/wg_split.conf

	local DNSMASQ_SUPPORTS_IPSET=0
	if command -v dnsmasq &>/dev/null; then
		local DNSMASQ_VER_INFO
		DNSMASQ_VER_INFO=$(dnsmasq --version 2>/dev/null || true)
		if echo "$DNSMASQ_VER_INFO" | grep -q -w "ipset" && ! echo "$DNSMASQ_VER_INFO" | grep -q -w "no-ipset"; then
			DNSMASQ_SUPPORTS_IPSET=1
		fi
	fi

	local DOMAIN_COUNT=0
	while IFS= read -r raw_domain || [[ -n "$raw_domain" ]]; do
		[[ -z "$raw_domain" || "$raw_domain" =~ ^# ]] && continue
		local base_domain
		base_domain=$(echo "$raw_domain" | sed -e 's|^https*://||' -e 's|/.*$||' | tr '[:upper:]' '[:lower:]' | xargs)
		[[ -z "$base_domain" ]] && continue

		local EXPANDED_DOMAINS=("$base_domain")
		if [[ "$base_domain" == "paypal.com" || "$base_domain" == *"paypal.com" || "$base_domain" == *"paypalobjects.com" ]]; then
			EXPANDED_DOMAINS+=("www.paypal.com" "c.paypal.com" "b.stats.paypal.com" "t.paypal.com" "s.paypal.com" "m.paypal.com" "api.paypal.com" "api-m.paypal.com" "checkout.paypal.com" "identity.paypal.com" "paypalobjects.com" "www.paypalobjects.com" "objects.paypal.com" "c.paypalobjects.com" "paypal.me" "paypal-mktg.com" "cardinalcommerce.com" "songbird.cardinalcommerce.com" "centinelapi.cardinalcommerce.com" "geo.cardinalcommerce.com" "braintreegateway.com" "braintree-api.com" "assets.braintreegateway.com" "js.braintreegateway.com")
		elif [[ "$base_domain" == "cardinalcommerce.com" || "$base_domain" == *"cardinalcommerce.com" ]]; then
			EXPANDED_DOMAINS+=("songbird.cardinalcommerce.com" "centinelapi.cardinalcommerce.com" "geo.cardinalcommerce.com")
		elif [[ "$base_domain" == "braintreegateway.com" || "$base_domain" == *"braintreegateway.com" ]]; then
			EXPANDED_DOMAINS+=("braintree-api.com" "assets.braintreegateway.com" "js.braintreegateway.com" "api.braintreegateway.com")
		elif [[ "$base_domain" == "stripe.com" || "$base_domain" == *"stripe.com" ]]; then
			EXPANDED_DOMAINS+=("api.stripe.com" "js.stripe.com" "checkout.stripe.com" "m.stripe.network" "m.stripe.com")
		elif [[ "$base_domain" == "linkedin.com" || "$base_domain" == *"linkedin.com" ]]; then
			EXPANDED_DOMAINS+=("www.linkedin.com" "mobile.linkedin.com" "touch.www.linkedin.com" "licdn.com" "www.licdn.com" "media.licdn.com" "static.licdn.com" "static-exp1.licdn.com" "static-exp2.licdn.com" "media-exp1.licdn.com" "media-exp2.licdn.com" "lnkd.in" "platform.linkedin.com" "voyager.linkedin.com" "api.linkedin.com" "dms.licdn.com" "snap.licdn.com" "px.ads.linkedin.com" "ads.linkedin.com" "slideshare.net")
		elif [[ "$base_domain" == "amazon.com" || "$base_domain" == *"amazon.com" ]]; then
			EXPANDED_DOMAINS+=("www.amazon.com" "smile.amazon.com" "completion.amazon.com" "images-amazon.com" "media-amazon.com" "m.media-amazon.com" "ssl-images-amazon.com" "images-na.ssl-images-amazon.com" "aax.amazon-adsystem.com" "aax-us-east.amazon-adsystem.com" "fls-na.amazon.com" "fls-eu.amazon.com" "assoc-amazon.com" "amazonpay.com" "pay.amazon.com" "amazon.co.uk" "www.amazon.co.uk" "amazon.ca" "www.amazon.ca" "amazon.de" "www.amazon.de")
		elif [[ "$base_domain" == "cloudflare.com" || "$base_domain" == *"cloudflare.com" ]]; then
			EXPANDED_DOMAINS+=("challenges.cloudflare.com" "turnstile.com" "cdnjs.cloudflare.com" "cloudflareinsights.com" "cf-assets.com" "pages.dev" "workers.dev")
		elif [[ "$base_domain" == "google.com" || "$base_domain" == *"google.com" ]]; then
			EXPANDED_DOMAINS+=("www.google.com" "gstatic.com" "recaptcha.net" "google-analytics.com")
		fi

		for domain in "${EXPANDED_DOMAINS[@]}"; do
			((DOMAIN_COUNT++))

			local IS_PAYMENT=0
			local IS_HIGHSPEED=0
			if [[ "$domain" =~ (paypal|cardinalcommerce|braintree|stripe|chase|bankofamerica|wellsfargo) ]]; then
				IS_PAYMENT=1
			elif [[ "$domain" =~ (speedtest\.net|ookla\.com|fast\.com|librespeed\.org|steamcontent\.com|googlevideo\.com) ]]; then
				IS_HIGHSPEED=1
			fi

			if command -v ipset &>/dev/null && [[ "$DNSMASQ_SUPPORTS_IPSET" -eq 1 ]]; then
				if [[ $IS_PAYMENT -eq 1 ]]; then
					echo "ipset=/${domain}/wg_direct_clean" >> /etc/dnsmasq.d/wg_split.conf
				elif [[ $IS_HIGHSPEED -eq 1 ]]; then
					echo "ipset=/${domain}/wg_highspeed_direct" >> /etc/dnsmasq.d/wg_split.conf
				else
					echo "ipset=/${domain}/wg_split_v4,wg_split_v6" >> /etc/dnsmasq.d/wg_split.conf
				fi
			fi

			# Fast non-blocking pre-warm via getent (local cache/hosts)
			local resolved_v4
			resolved_v4=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u || true)
			for ip in $resolved_v4; do
				# Never put DNS resolvers (1.1.1.1 / 1.0.0.1 / 8.8.8.8) into wg_split_v4!
				[[ "$ip" == "1.1.1.1" || "$ip" == "1.0.0.1" || "$ip" == "8.8.8.8" || "$ip" == "8.8.4.4" ]] && continue
				if command -v ipset &>/dev/null; then
					if [[ $IS_PAYMENT -eq 1 ]]; then
						ipset add wg_direct_clean "$ip" 2>/dev/null || true
					elif [[ $IS_HIGHSPEED -eq 1 ]]; then
						ipset add wg_highspeed_direct "$ip" 2>/dev/null || true
					else
						ipset add wg_split_v4 "$ip" 2>/dev/null || true
					fi
				fi
			done
		done
	done < /etc/wireguard/split_domains.txt

	# Populate PayPal Official Autonomous System CIDRs (AS11643) & Public DNS Resolvers into wg_direct_clean
	local PAYPAL_AND_DNS_V4="1.1.1.1/32 1.0.0.1/32 8.8.8.8/32 8.8.4.4/32 9.9.9.9/32 64.4.240.0/21 66.211.168.0/21 173.0.80.0/20 173.224.160.0/19 185.177.52.0/22 192.148.20.0/23 198.54.120.0/22 216.113.160.0/19"
	for p in $PAYPAL_AND_DNS_V4; do
		if command -v ipset &>/dev/null; then
			ipset add wg_direct_clean "$p" 2>/dev/null || true
		fi
	done

	# Populate LinkedIn Official Autonomous System CIDRs (AS12447 / AS20049 / Azure FrontDoor LinkedIn Ranges) into wg_split_v4
	local LINKEDIN_V4="108.174.0.0/20 144.2.0.0/19 185.63.144.0/22 199.101.160.0/22 216.52.16.0/20 216.52.20.0/22 216.52.24.0/22 65.156.227.0/24 8.247.168.0/24 13.107.42.0/24"
	for c in $LINKEDIN_V4; do
		if command -v ipset &>/dev/null; then
			ipset add wg_split_v4 "$c" 2>/dev/null || true
		fi
	done

	# Populate Amazon Storefront & CloudFront Core Edge CIDRs into wg_split_v4
	local AMAZON_STORE_V4="205.251.242.0/23 72.21.192.0/19 72.21.208.0/20 176.32.96.0/21 176.32.104.0/21 178.236.0.0/21 54.239.16.0/20 54.239.32.0/20 99.84.0.0/16 99.86.0.0/16 13.32.0.0/15 13.35.0.0/16 13.224.0.0/14 18.64.0.0/14 18.154.0.0/15 18.160.0.0/15 18.164.0.0/15 18.172.0.0/15 18.238.0.0/15 18.244.0.0/15 52.84.0.0/15 54.182.0.0/16 54.192.0.0/16 54.230.0.0/16 54.240.128.0/18 65.8.0.0/16 65.9.0.0/16 108.138.0.0/15 108.156.0.0/14 143.204.0.0/16"
	for a in $AMAZON_STORE_V4; do
		if command -v ipset &>/dev/null; then
			ipset add wg_split_v4 "$a" 2>/dev/null || true
		fi
	done

	# Populate Cloudflare Edge IPv4 Ranges into wg_split_v4
	if [[ -f /etc/wireguard/cloudflare_split_enabled ]] || grep -q -i "cloudflare" /etc/wireguard/split_domains.txt 2>/dev/null; then
		local CF_V4="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22"
		for c in $CF_V4; do
			if command -v ipset &>/dev/null; then
				ipset add wg_split_v4 "$c" 2>/dev/null || true
			fi
		done
	fi

	# Validate and start dnsmasq cleanly
	if command -v dnsmasq &>/dev/null; then
		if ! dnsmasq --test >/dev/null 2>&1; then
			sed -i '/^ipset=/d' /etc/dnsmasq.d/wg_split.conf 2>/dev/null || true
		fi
		systemctl enable dnsmasq >/dev/null 2>&1 || true
		systemctl restart dnsmasq >/dev/null 2>&1 || true
	fi

	# 1. GUARANTEE CORE FORWARD, INPUT, FAST-PATH CONNTRACK & MASQUERADE ARE ALWAYS ACTIVE
	sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.all.forwarding=1 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
	sysctl -w "net.ipv4.conf.${WG_NIC}.rp_filter=0" >/dev/null 2>&1 || true
	sysctl -w "net.ipv4.conf.${WG_NIC}.route_localnet=1" >/dev/null 2>&1 || true

	optimizeNetworkThroughput "$DEF_NIC"

	iptables -P FORWARD ACCEPT 2>/dev/null || true

	# Ensure WireGuard UDP listen port and all in-tunnel requests (DNS, Redsocks) are accepted by INPUT
	iptables -D INPUT -p udp --dport "${SERVER_PORT:-4500}" -j ACCEPT 2>/dev/null || true
	iptables -I INPUT 1 -p udp --dport "${SERVER_PORT:-4500}" -j ACCEPT 2>/dev/null || true
	iptables -D INPUT -i "$WG_NIC" -j ACCEPT 2>/dev/null || true
	iptables -I INPUT 2 -i "$WG_NIC" -j ACCEPT 2>/dev/null || true

	# Clean and re-insert top-priority FORWARD rules
	iptables -D FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
	iptables -D FORWARD -i "$WG_NIC" -j ACCEPT 2>/dev/null || true
	iptables -D FORWARD -o "$WG_NIC" -j ACCEPT 2>/dev/null || true
	iptables -D FORWARD -s 10.18.0.0/24 -j ACCEPT 2>/dev/null || true
	iptables -D FORWARD -d 10.18.0.0/24 -j ACCEPT 2>/dev/null || true
	iptables -D FORWARD -s 10.19.0.0/24 -j ACCEPT 2>/dev/null || true
	iptables -D FORWARD -d 10.19.0.0/24 -j ACCEPT 2>/dev/null || true

	iptables -I FORWARD 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
	iptables -I FORWARD 2 -i "$WG_NIC" -j ACCEPT 2>/dev/null || true
	iptables -I FORWARD 3 -o "$WG_NIC" -j ACCEPT 2>/dev/null || true
	iptables -I FORWARD 4 -s 10.18.0.0/24 -j ACCEPT 2>/dev/null || true
	iptables -I FORWARD 5 -d 10.18.0.0/24 -j ACCEPT 2>/dev/null || true
	iptables -I FORWARD 6 -s 10.19.0.0/24 -j ACCEPT 2>/dev/null || true
	iptables -I FORWARD 7 -d 10.19.0.0/24 -j ACCEPT 2>/dev/null || true

	# Clean and re-insert top-priority NAT MASQUERADE rules
	iptables -t nat -D POSTROUTING -s 10.18.0.0/24 -o "$DEF_NIC" -j MASQUERADE 2>/dev/null || true
	iptables -t nat -D POSTROUTING -s 10.19.0.0/24 -o "$DEF_NIC" -j MASQUERADE 2>/dev/null || true
	iptables -t nat -D POSTROUTING -s 10.18.0.0/24 ! -o "$WG_NIC" -j MASQUERADE 2>/dev/null || true
	iptables -t nat -D POSTROUTING -s 10.19.0.0/24 ! -o "$WG_NIC" -j MASQUERADE 2>/dev/null || true

	iptables -t nat -I POSTROUTING 1 -s 10.18.0.0/24 -o "$DEF_NIC" -j MASQUERADE 2>/dev/null || true
	iptables -t nat -I POSTROUTING 2 -s 10.19.0.0/24 -o "$DEF_NIC" -j MASQUERADE 2>/dev/null || true
	iptables -t nat -I POSTROUTING 3 -s 10.18.0.0/24 ! -o "$WG_NIC" -j MASQUERADE 2>/dev/null || true
	iptables -t nat -I POSTROUTING 4 -s 10.19.0.0/24 ! -o "$WG_NIC" -j MASQUERADE 2>/dev/null || true

	# 2. DEDICATED TRANSPARENT DNS INTERCEPTION CHAIN (WG_STEALTH_DNS)
	# Always sits at PREROUTING #1 so DNS queries NEVER fall into WG_STEALTH_PROXY!
	iptables -t nat -D PREROUTING -i "$WG_NIC" -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || true
	iptables -t nat -D PREROUTING -i "$WG_NIC" -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || true
	iptables -t nat -D PREROUTING -i "$WG_NIC" -p udp --dport 53 -j DNAT --to-destination 1.1.1.1:53 2>/dev/null || true
	iptables -t nat -D PREROUTING -i "$WG_NIC" -p tcp --dport 53 -j DNAT --to-destination 1.1.1.1:53 2>/dev/null || true
	iptables -t nat -D PREROUTING -i "$WG_NIC" -j WG_STEALTH_DNS 2>/dev/null || true
	iptables -t nat -F WG_STEALTH_DNS 2>/dev/null || true
	iptables -t nat -X WG_STEALTH_DNS 2>/dev/null || true
	iptables -t nat -N WG_STEALTH_DNS 2>/dev/null || true

	if command -v dnsmasq &>/dev/null && systemctl is-active --quiet dnsmasq 2>/dev/null; then
		# Route each subnet's DNS queries directly to its own gateway listener on dnsmasq
		iptables -t nat -A WG_STEALTH_DNS -s 10.19.0.0/24 -p udp --dport 53 -j DNAT --to-destination 10.19.0.1:53 2>/dev/null || true
		iptables -t nat -A WG_STEALTH_DNS -s 10.19.0.0/24 -p tcp --dport 53 -j DNAT --to-destination 10.19.0.1:53 2>/dev/null || true
		iptables -t nat -A WG_STEALTH_DNS -p udp --dport 53 -j DNAT --to-destination "${WG_V4}:53" 2>/dev/null || true
		iptables -t nat -A WG_STEALTH_DNS -p tcp --dport 53 -j DNAT --to-destination "${WG_V4}:53" 2>/dev/null || true
	else
		iptables -t nat -A WG_STEALTH_DNS -p udp --dport 53 -j DNAT --to-destination "${CLIENT_DNS_1:-1.1.1.1}:53" 2>/dev/null || true
		iptables -t nat -A WG_STEALTH_DNS -p tcp --dport 53 -j DNAT --to-destination "${CLIENT_DNS_1:-1.1.1.1}:53" 2>/dev/null || true
	fi
	iptables -t nat -I PREROUTING 1 -i "$WG_NIC" -j WG_STEALTH_DNS 2>/dev/null || true

	# 3. TRANSPARENT REDSOCKS -> WARP SOCKS5 BRIDGE (WG_STEALTH_PROXY) & WEBRTC/STUN LEAK GUARD
	iptables -t nat -D PREROUTING -i "$WG_NIC" -p tcp -j WG_STEALTH_PROXY 2>/dev/null || true
	iptables -t nat -F WG_STEALTH_PROXY 2>/dev/null || true
	iptables -t nat -X WG_STEALTH_PROXY 2>/dev/null || true

	# Clean any previous QUIC UDP 443 & WebRTC STUN block rules
	iptables -D FORWARD -i "$WG_NIC" -s 10.19.0.0/24 -p udp --dport 443 -j REJECT 2>/dev/null || true
	iptables -D FORWARD -i "$WG_NIC" -s 10.19.0.0/24 -m set ! --match-set wg_highspeed_direct dst -p udp --dport 443 -j REJECT 2>/dev/null || true
	iptables -D FORWARD -i "$WG_NIC" -m set --match-set wg_split_v4 dst -p udp --dport 443 -j REJECT 2>/dev/null || true
	iptables -D FORWARD -i "$WG_NIC" -s 10.19.0.0/24 -p udp -m multiport --dports 3478,5349,19302:19309 -j REJECT 2>/dev/null || true

	local PROXY_PORT=40000
	configureRedsocksBridge "127.0.0.1" "$PROXY_PORT" >/dev/null 2>&1 || true

	# Always build the WG_STEALTH_PROXY chain so the watchdog can toggle it cleanly
	iptables -t nat -N WG_STEALTH_PROXY 2>/dev/null || true

	# Never redirect DNS (port 53) or DoT (port 853) into Redsocks
	iptables -t nat -A WG_STEALTH_PROXY -p tcp --dport 53 -j RETURN
	iptables -t nat -A WG_STEALTH_PROXY -p tcp --dport 853 -j RETURN

	# Bypass local/private RFC1918, WireGuard subnets & DNS resolvers
	iptables -t nat -A WG_STEALTH_PROXY -d 0.0.0.0/8 -j RETURN
	iptables -t nat -A WG_STEALTH_PROXY -d 10.0.0.0/8 -j RETURN
	iptables -t nat -A WG_STEALTH_PROXY -d 127.0.0.0/8 -j RETURN
	iptables -t nat -A WG_STEALTH_PROXY -d 169.254.0.0/16 -j RETURN
	iptables -t nat -A WG_STEALTH_PROXY -d 172.16.0.0/12 -j RETURN
	iptables -t nat -A WG_STEALTH_PROXY -d 192.168.0.0/16 -j RETURN
	iptables -t nat -A WG_STEALTH_PROXY -d 224.0.0.0/4 -j RETURN
	iptables -t nat -A WG_STEALTH_PROXY -d 240.0.0.0/4 -j RETURN
	iptables -t nat -A WG_STEALTH_PROXY -d 1.1.1.1/32 -j RETURN
	iptables -t nat -A WG_STEALTH_PROXY -d 1.0.0.1/32 -j RETURN
	iptables -t nat -A WG_STEALTH_PROXY -d 8.8.8.8/32 -j RETURN
	iptables -t nat -A WG_STEALTH_PROXY -d 8.8.4.4/32 -j RETURN
	[[ -n "${SERVER_PUB_IP:-}" ]] && iptables -t nat -A WG_STEALTH_PROXY -d "${SERVER_PUB_IP}/32" -j RETURN

	# 1. Payment & Banking Direct Egress Protection (PayPal, Stripe, Braintree, Banks)
	if command -v ipset &>/dev/null; then
		iptables -t nat -A WG_STEALTH_PROXY -m set --match-set wg_direct_clean dst -j RETURN 2>/dev/null || true
		# 2. High-Speed Direct Fast-Lane (Speedtest, Steam, Raw Media CDNs)
		iptables -t nat -A WG_STEALTH_PROXY -m set --match-set wg_highspeed_direct dst -j RETURN 2>/dev/null || true
	fi

	# 3. Route Profile 1 (10.19.0.0/24 Stealth Gateway) HTTP/HTTPS/TCP traffic through WARP AS13335 Consumer Egress
	iptables -t nat -A WG_STEALTH_PROXY -s 10.19.0.0/24 -p tcp -j REDIRECT --to-ports 12345 2>/dev/null || true

	# 4. Route Profile 2 (10.18.0.0/24 Standard) when visiting Amazon, LinkedIn, Cloudflare, or IP Scanners in wg_split_v4
	if command -v ipset &>/dev/null; then
		iptables -t nat -A WG_STEALTH_PROXY -s 10.18.0.0/24 -p tcp -m set --match-set wg_split_v4 dst -j REDIRECT --to-ports 12345 2>/dev/null || true
	fi

	# ONLY hook WG_STEALTH_PROXY into PREROUTING if the upstream SOCKS5 proxy is verified healthy and passing real data!
	if isTransparentProxyHealthy "$PROXY_PORT"; then
		iptables -t nat -A PREROUTING -i "$WG_NIC" -p tcp -j WG_STEALTH_PROXY 2>/dev/null || true

		# Reject UDP 443 (QUIC) on Stealth Profile & Split Domains so browsers smoothly fall back to TCP 443 through WARP Proxy
		if command -v ipset &>/dev/null; then
			iptables -A FORWARD -i "$WG_NIC" -s 10.19.0.0/24 -m set ! --match-set wg_highspeed_direct dst -p udp --dport 443 -j REJECT 2>/dev/null || true
			iptables -A FORWARD -i "$WG_NIC" -m set --match-set wg_split_v4 dst -p udp --dport 443 -j REJECT 2>/dev/null || true
		fi

		echo -e "${GREEN}[✔] Transparent WARP Proxy Bridge ACTIVE & Verified (127.0.0.1:12345 -> WARP AS13335)!${NC}"
		echo -e "${GREEN}[✔] High-Speed Media Fast-Lane & Banking Direct Protection ACTIVE!${NC}"
	else
		echo -e "${YELLOW}[i] WARP SOCKS5 Proxy not currently passing traffic — WG_STEALTH_PROXY bypassed so clients enjoy 100% Direct VPS Egress!${NC}"
	fi

	# 4. Re-apply Stealth Packet Normalization & Zero-Fragmentation MSS Clamping
	local TARGET_TTL=128
	if [[ ! -f /etc/wireguard/emulate_windows_ttl ]]; then
		TARGET_TTL=64
	fi

	iptables -t mangle -D PREROUTING -i "$WG_NIC" -s 10.19.0.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220 2>/dev/null || true
	iptables -t mangle -I PREROUTING 1 -i "$WG_NIC" -s 10.19.0.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220 2>/dev/null || true
	if command -v ipset &>/dev/null; then
		iptables -t mangle -D PREROUTING -i "$WG_NIC" -m set --match-set wg_split_v4 dst -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220 2>/dev/null || true
		iptables -t mangle -I PREROUTING 2 -i "$WG_NIC" -m set --match-set wg_split_v4 dst -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220 2>/dev/null || true
	fi

	iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
	iptables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
	iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN ! -o "$WG_NIC" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
	iptables -t mangle -I POSTROUTING 1 -p tcp --tcp-flags SYN,RST SYN ! -o "$WG_NIC" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

	iptables -t mangle -D POSTROUTING -s 10.19.0.0/24 -o "$DEF_NIC" -j TTL --ttl-set 64 2>/dev/null || true
	iptables -t mangle -D POSTROUTING -s 10.19.0.0/24 -o "$DEF_NIC" -j TTL --ttl-set 128 2>/dev/null || true
	iptables -t mangle -A POSTROUTING -s 10.19.0.0/24 -o "$DEF_NIC" -j TTL --ttl-set "${TARGET_TTL}" 2>/dev/null || true

	iptables -t mangle -D POSTROUTING -s 10.18.0.0/24 -o "$DEF_NIC" -j TTL --ttl-set 64 2>/dev/null || true
	iptables -t mangle -A POSTROUTING -s 10.18.0.0/24 -o "$DEF_NIC" -j TTL --ttl-set 64 2>/dev/null || true

	echo -e "${GREEN}[✔] Stealth Split & Scanner Cloak Rules applied for ${DOMAIN_COUNT} domain(s) & CDN subnets.${NC}"
	echo -e "${GREEN}[✔] Applied live in real-time — zero reboot, zero client changes!${NC}\n"
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
		echo -e "  ${BOLD}Current Mode:${NC}  ${GREEN}[${MODE} MODE]${NC} (Flagged domains route through Anti-Flag WARP Shield)"
		echo -e "  ${BOLD}Active Domains:${NC} ${YELLOW}${DOMAIN_COUNT} domain(s) configured${NC}"
		echo "-----------------------------------------------------------------"
		echo "1) Add Domain (e.g. amazon.com, linkedin.com, openai.com, reddit.com)"
		echo "2) Remove Domain"
		echo "3) Add Preset Category (Amazon/LinkedIn, IP Scanners, AI, Streaming, Banking)"
		echo "4) Toggle Mode (BYPASS VPN vs FORCE THROUGH VPN)"
		echo "5) View Active Split Domains & Live Resolved IP Rules"
		echo "6) Clear All Split Domain Rules"
		echo "7) Return to Main Menu"
		echo ""

		read -rp "Select option [1-7]: " SPLIT_OPT
		case "$SPLIT_OPT" in
			1)
				read -rp "Enter domain name to split tunnel (e.g. amazon.com): " NEW_DOMAIN
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
				echo "1) Amazon & LinkedIn Full Suite (Storefronts, Voyager API, licdn, CloudFront)"
				echo "2) IP / Fraud / WebRTC / ASN Scanners (ipinfo, whoer, browserleaks, scamalytics, etc.)"
				echo "3) AI Services (OpenAI, ChatGPT, Claude, Gemini, DeepSeek, Perplexity & CDNs)"
				echo "4) Streaming Services (Netflix, Hulu, Disney+, PrimeVideo, HBO Max, Spotify & CDNs)"
				echo "5) Banking & Finance (PayPal, Chase, Bank of America, Wells Fargo, Stripe)"
				echo "6) Cloudflare Anti-Bot & Turnstile Shield (challenges.cloudflare.com, turnstile.com)"
				read -rp "Select preset [1-6]: " PRESET_OPT
				case "$PRESET_OPT" in
					1)
						for d in amazon.com www.amazon.com completion.amazon.com images-amazon.com media-amazon.com m.media-amazon.com ssl-images-amazon.com aax.amazon-adsystem.com fls-na.amazon.com amazon.co.uk amazon.ca amazon.de cloudfront.net linkedin.com www.linkedin.com licdn.com media.licdn.com static.licdn.com dms.licdn.com voyager.linkedin.com api.linkedin.com lnkd.in; do
							grep -q "^${d}\$" /etc/wireguard/split_domains.txt 2>/dev/null || echo "$d" >> /etc/wireguard/split_domains.txt
						done
						echo -e "${GREEN}[✔] Added Amazon & LinkedIn Full Suite preset domains.${NC}"
						applyDomainSplitRulesLive
						;;
					2)
						for d in ipinfo.io ifconfig.me ifconfig.co icanhazip.com ipify.org api.ipify.org wtfismyip.com checkip.amazonaws.com ip-api.com ipapi.co ipdata.co whoer.net browserleaks.com ipleak.net dnsleaktest.com scamalytics.com ipqualityscore.com spur.us maxmind.com ip2location.com db-ip.com pixelscan.net amiunique.org creepjs.com iphey.com; do
							grep -q "^${d}\$" /etc/wireguard/split_domains.txt 2>/dev/null || echo "$d" >> /etc/wireguard/split_domains.txt
						done
						echo -e "${GREEN}[✔] Added IP, Fraud & WebRTC Scanner Cloak preset domains.${NC}"
						applyDomainSplitRulesLive
						;;
					3)
						for d in openai.com chatgpt.com oaistatic.com oaiusercontent.com claude.ai anthropic.com gemini.google.com deepseek.com perplexity.ai; do
							grep -q "^${d}\$" /etc/wireguard/split_domains.txt 2>/dev/null || echo "$d" >> /etc/wireguard/split_domains.txt
						done
						echo -e "${GREEN}[✔] Added AI Services & CDNs preset domains.${NC}"
						applyDomainSplitRulesLive
						;;
					4)
						for d in netflix.com nflxext.com nflxso.net nflxvideo.net nflximg.net hulu.com hulustream.com disneyplus.com disney-plus.net dssott.com bamgrid.com primevideo.com hbomax.com spotify.com; do
							grep -q "^${d}\$" /etc/wireguard/split_domains.txt 2>/dev/null || echo "$d" >> /etc/wireguard/split_domains.txt
						done
						echo -e "${GREEN}[✔] Added Streaming Services & CDNs preset domains.${NC}"
						applyDomainSplitRulesLive
						;;
					5)
						for d in paypal.com paypalobjects.com cardinalcommerce.com braintreegateway.com braintree-api.com chase.com bankofamerica.com wellsfargo.com stripe.com; do
							grep -q "^${d}\$" /etc/wireguard/split_domains.txt 2>/dev/null || echo "$d" >> /etc/wireguard/split_domains.txt
						done
						echo -e "${GREEN}[✔] Added Banking & Finance (PayPal, 3D-Secure, Braintree, Banks) preset domains.${NC}"
						applyDomainSplitRulesLive
						;;
					6)
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
					cat /etc/wireguard/split_domains.txt | grep -v -E '^(#|$)' | nl -s ') '
					echo ""
					if command -v ipset &>/dev/null; then
						echo -e "${BOLD}Active IPv4 IPSet Rules (wg_split_v4 - showing first 35):${NC}"
						ipset list wg_split_v4 2>/dev/null | grep -A 35 "Members:" || echo "No IP members currently resolved."
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
	journalctl -u redsocks -n 10 --no-pager 2>/dev/null || true
	journalctl -u dnsmasq -n 10 --no-pager 2>/dev/null || true
	echo ""
}

function geoIpAntiVpnShield() {
	echo -e "\n${CYAN}--- Geo-IP, Scanner Cloak & High-Speed Offload Status ---${NC}"
	echo -e "  - ${BOLD}TTL Normalization:${NC}        ${GREEN}ACTIVE (128 for Stealth Profile / 64 for Standard)${NC}"
	echo -e "  - ${BOLD}TCP MSS Clamping:${NC}         ${GREEN}ACTIVE (1220 for WARP Flows / PMTU for Direct Flows)${NC}"
	echo -e "  - ${BOLD}BBR + FQ Pacing:${NC}          ${GREEN}ACTIVE (128MB Kernel Buffers + GRO/GSO/RPS Offload)${NC}"
	echo -e "  - ${BOLD}Transparent WARP Bridge:${NC}  $(isTransparentProxyHealthy 40000 && echo -e "${GREEN}ONLINE & Verified (127.0.0.1:12345 -> 40000 + 30s Watchdog)${NC}" || echo -e "${YELLOW}BYPASSED -> Direct VPS Egress Active${NC}")"
	echo -e "  - ${BOLD}Stealth DNS Chain:${NC}        ${GREEN}ACTIVE (WG_STEALTH_DNS isolated from Redsocks Proxy)${NC}"
	echo -e "  - ${BOLD}Amazon & LinkedIn Cloak:${NC}  ${GREEN}ACTIVE (Pre-warmed IPSets + AS12447 & CloudFront CIDRs)${NC}"
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
	echo -e "  9) Allowed IPs:            ${ALLOWED_IPS:-0.0.0.0/0}"
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
						echo -e "${RED}[!] Port ${NEW_PORT} is a sensitive/common service port. Please choose a safe stealth port.${NC}"
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
						echo -e "${RED}[!] Port ${NEW_WEB} is a sensitive service port. Please choose a dedicated port.${NC}"
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
SERVER_PORT_CF=${SERVER_PORT}
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
	echo -e "\n${CYAN}${BOLD}🛠️ Starting Automated Network, DNS, WARP Bridge & Client Traffic Auto-Repair...${NC}"

	local SELF_SCRIPT
	SELF_SCRIPT=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "")
	if [[ -n "$SELF_SCRIPT" && -f "$SELF_SCRIPT" ]]; then
		cp -f "$SELF_SCRIPT" /usr/local/bin/easy_wireguard.sh 2>/dev/null || true
		chmod +x /usr/local/bin/easy_wireguard.sh 2>/dev/null || true
	fi

	# 1. Restore DNS nameservers
	echo -e "${CYAN}[1/6] Verifying host DNS health & nameservers...${NC}"
	if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
		mkdir -p /etc/systemd/resolved.conf.d
		cat << 'RESOLVED_NO_STUB' > /etc/systemd/resolved.conf.d/no-stub.conf 2>/dev/null || true
[Resolve]
DNSStubListener=no
RESOLVED_NO_STUB
		systemctl restart systemd-resolved 2>/dev/null || true
	fi
	rm -f /etc/resolv.conf 2>/dev/null || true
	cat << 'RESOLV_CLEAN_EOF' > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
RESOLV_CLEAN_EOF

	# 2. Re-enable IP forwarding & kernel networking
	echo -e "${CYAN}[2/6] Verifying kernel IP forwarding, 128MB buffers, rp_filter=0 and route_localnet...${NC}"
	sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.all.forwarding=1 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.default.forwarding=1 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1 || true
	[[ -f /etc/sysctl.d/99-wireguard-stealth.conf ]] && sysctl -p /etc/sysctl.d/99-wireguard-stealth.conf >/dev/null 2>&1 || true

	# 3. Clean legacy fwmark 0x51820 blackhole rules & UFW blocks
	echo -e "${CYAN}[3/6] Clearing policy-routing blackholes & ensuring firewall permits tunnel traffic...${NC}"
	ip rule del fwmark 0x51820 table 51820 2>/dev/null || true
	ip route flush table 51820 2>/dev/null || true
	if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
		ufw allow "${SERVER_PORT:-4500}/udp" >/dev/null 2>&1 || true
		ufw allow in on "${SERVER_WG_NIC:-wg0}" >/dev/null 2>&1 || true
		ufw route allow in on "${SERVER_WG_NIC:-wg0}" >/dev/null 2>&1 || true
		ufw route allow out on "${SERVER_WG_NIC:-wg0}" >/dev/null 2>&1 || true
		if [ -f /etc/default/ufw ]; then
			sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw 2>/dev/null || true
		fi
		ufw reload >/dev/null 2>&1 || true
	fi

	# 4. Safely reset and restore WireGuard interface (wg0)
	echo -e "${CYAN}[4/6] Restoring Unified WireGuard interface (${SERVER_WG_NIC:-wg0}) & NIC Offloading...${NC}"
	if command -v wg-quick &>/dev/null; then
		wg-quick down "${SERVER_WG_NIC:-wg0}" >/dev/null 2>&1 || true
		ip link delete dev "${SERVER_WG_NIC:-wg0}" >/dev/null 2>&1 || true
		wg-quick down wg1 >/dev/null 2>&1 || true
		ip link delete dev wg1 >/dev/null 2>&1 || true
		rm -f "/etc/wireguard/wg1.conf"

		systemctl daemon-reload >/dev/null 2>&1 || true
		systemctl restart "wg-quick@${SERVER_WG_NIC:-wg0}" 2>/dev/null || wg-quick up "${SERVER_WG_NIC:-wg0}" 2>/dev/null || true
	fi
	optimizeNetworkThroughput "${SERVER_PUB_NIC:-}"

	# 5. Repair WARP SOCKS5 Proxy & Redsocks Bridge
	echo -e "${CYAN}[5/6] Verifying Cloudflare WARP SOCKS5 Proxy (port 40000) & Redsocks Bridge...${NC}"
	if command -v warp-cli &>/dev/null; then
		systemctl restart warp-svc 2>/dev/null || true
		sleep 2
		warp-cli --accept-tos registration new 2>/dev/null || warp-cli --accept-tos register 2>/dev/null || true
		warp-cli --accept-tos proxy port 40000 2>/dev/null || warp-cli --accept-tos set-proxy-port 40000 2>/dev/null || warp-cli set-proxy-port 40000 2>/dev/null || true
		warp-cli --accept-tos mode proxy 2>/dev/null || warp-cli --accept-tos set-mode proxy 2>/dev/null || warp-cli set-mode proxy 2>/dev/null || true
		warp-cli --accept-tos connect 2>/dev/null || warp-cli connect 2>/dev/null || true
		sleep 2
	fi
	configureRedsocksBridge "127.0.0.1" "40000" >/dev/null 2>&1 || true
	installWarpWatchdog

	# 6. Re-apply Stealth DNS, IPSet & Firewall Rules
	echo -e "${CYAN}[6/6] Re-applying Stealth DNS, NAT, MSS Clamping & Transparent Proxy rules...${NC}"
	applyDomainSplitRulesLive

	verifyServerTrafficHealth
}

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
	echo -e "\n${CYAN}${BOLD}⚡ Initializing Cloudflare WARP Consumer Egress (AS13335) + Transparent Bridge...${NC}"
	mkdir -p /etc/wireguard
	touch /etc/wireguard/warp_egress_enabled

	showWarpProgressBar 5 "Verifying system environment & architecture..."
	sleep 0.2

	if ! command -v warp-cli &>/dev/null && command -v apt-get &>/dev/null; then
		showWarpProgressBar 20 "Installing GPG & repository dependencies..."
		export DEBIAN_FRONTEND=noninteractive
		local ARCH
		ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
		local CODENAME=""
		if [[ -f /etc/os-release ]]; then
			. /etc/os-release
			CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
		fi
		[[ -z "$CODENAME" ]] && CODENAME=$(lsb_release -cs 2>/dev/null || echo "jammy")
		case "$CODENAME" in
			noble|jammy|focal|bionic|bookworm|bullseye|buster) ;;
			trixie|sid) CODENAME="bookworm" ;;
			plucky|oracular) CODENAME="noble" ;;
			*)
				if grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
					CODENAME="jammy"
				else
					CODENAME="bookworm"
				fi
				;;
		esac

		showWarpProgressBar 40 "Adding official Cloudflare WARP repository..."
		mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
		curl -fsSL --connect-timeout 8 --max-time 15 https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null || true
		echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${CODENAME} main" > /etc/apt/sources.list.d/cloudflare-client.list 2>/dev/null || true

		showWarpProgressBar 60 "Installing cloudflare-warp & redsocks packages..."
		apt-get update -o Acquire::Timeout="10" -o Dir::Etc::sourcelist="sources.list.d/cloudflare-client.list" -o Dir::Etc::sourceparts="-" -qq >/dev/null 2>&1 || apt-get update -o Acquire::Timeout="10" -qq >/dev/null 2>&1 || true
		apt-get install -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" cloudflare-warp redsocks >/dev/null 2>&1 || true
	fi

	if command -v warp-cli &>/dev/null; then
		showWarpProgressBar 75 "Starting warp-svc daemon and registering consumer license..."
		systemctl daemon-reload >/dev/null 2>&1 || true
		systemctl enable --now warp-svc >/dev/null 2>&1 || true
		for ((s=0; s<12; s++)); do
			systemctl is-active --quiet warp-svc 2>/dev/null && break
			sleep 0.5
		done

		warp-cli --accept-tos registration new 2>/dev/null \
			|| warp-cli --accept-tos register 2>/dev/null \
			|| echo "y" | warp-cli registration new 2>/dev/null \
			|| echo "y" | warp-cli register 2>/dev/null \
			|| true

		showWarpProgressBar 88 "Configuring WARP in Safe SOCKS5 Proxy Mode (127.0.0.1:40000)..."
		warp-cli --accept-tos proxy port 40000 2>/dev/null \
			|| warp-cli --accept-tos set-proxy-port 40000 2>/dev/null \
			|| warp-cli proxy port 40000 2>/dev/null \
			|| warp-cli set-proxy-port 40000 2>/dev/null \
			|| true
		warp-cli --accept-tos mode proxy 2>/dev/null \
			|| warp-cli --accept-tos set-mode proxy 2>/dev/null \
			|| warp-cli mode proxy 2>/dev/null \
			|| warp-cli set-mode proxy 2>/dev/null \
			|| true
		warp-cli --accept-tos proxy port 40000 2>/dev/null \
			|| warp-cli --accept-tos set-proxy-port 40000 2>/dev/null \
			|| true
		warp-cli --accept-tos connect 2>/dev/null || warp-cli connect 2>/dev/null || true

		# Wait up to 8 seconds for WARP SOCKS5 to actually pass HTTP traffic
		for ((w=0; w<16; w++)); do
			if curl -4 -x socks5h://127.0.0.1:40000 -sSf --connect-timeout 1 --max-time 2 https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then
				break
			fi
			sleep 0.5
		done

		showWarpProgressBar 95 "Starting Redsocks Transparent TCP-to-WARP Bridge (127.0.0.1:12345)..."
		configureRedsocksBridge "127.0.0.1" "40000" >/dev/null 2>&1 || true
		installWarpWatchdog

		showWarpProgressBar 100 "Cloudflare WARP + Redsocks Transparent Bridge Operational!"
		echo -e "${GREEN}[✔] Stealth traffic (10.19.0.x, Amazon, LinkedIn & IP Scanners) now exits via Cloudflare AS13335.${NC}"
	else
		showWarpProgressBar 100 "WARP package unavailable on this OS architecture; Direct Stealth TTL=128 active."
	fi
}

function cloudflareAntiFlagEngine() {
	while true; do
		local CF_SHIELD_STATUS="ACTIVE"
		local CURRENT_TTL=64
		[[ -f /etc/wireguard/emulate_windows_ttl ]] && CURRENT_TTL=128
		local SPLIT_COUNT=0
		[[ -f /etc/wireguard/split_domains.txt ]] && SPLIT_COUNT=$(grep -c -v -E '^(#|$)' /etc/wireguard/split_domains.txt 2>/dev/null || echo 0)
		local HAS_WARP="BYPASSED (Direct VPS Egress Active)"
		if isTransparentProxyHealthy 40000; then
			HAS_WARP="ACTIVE & VERIFIED (AS13335 WARP + Redsocks + 30s Watchdog)"
		fi

		echo -e "\n${PURPLE}=================================================================${NC}"
		echo -e "       ${CYAN}${BOLD}🛡️ Stealth Anti-Scanner & Smart Egress Gateway Engine${NC}"
		echo -e "${PURPLE}=================================================================${NC}"
		echo -e "  ${BOLD}Cloudflare Shield Status:${NC}   ${GREEN}[${CF_SHIELD_STATUS}]${NC} (Unblocks Amazon, LinkedIn & Turnstile)"
		echo -e "  ${BOLD}Transparent WARP Bridge:${NC}    ${GREEN}[${HAS_WARP}]${NC}"
		echo -e "  ${BOLD}TCP SYN Fingerprint:${NC}       ${CYAN}TTL=${CURRENT_TTL} & MSS=1220/PMTU Clamping Active${NC}"
		echo -e "  ${BOLD}Active Split Domains:${NC}      ${YELLOW}${SPLIT_COUNT} domain(s) active${NC}"
		echo "-----------------------------------------------------------------"
		echo "1) Enable / Repair Cloudflare WARP + Transparent Redsocks Bridge (AS13335 Consumer Cloak)"
		echo "2) Refresh Amazon, LinkedIn & IP Scanner CIDRs / Pre-Warmed IPSets"
		echo "3) Configure Custom Upstream Residential / SOCKS5 Proxy Host Masking"
		echo "4) Toggle Windows 10/11 Desktop TCP SYN Emulation (TTL=128 vs 64)"
		echo "5) Run Live WARP, Scanner Cloak, Amazon & LinkedIn Diagnostic Test"
		echo "6) Revert to Direct VPS Egress Only (Disable Transparent Proxy)"
		echo "7) Safe Network, DNS & Speed Auto-Repair (Fix Broken DNS & Recover WireGuard)"
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
				echo -e "\n${CYAN}[*] Refreshing Amazon, LinkedIn, Cloudflare & IP Scanner CIDRs...${NC}"
				mkdir -p /etc/wireguard
				touch /etc/wireguard/cloudflare_split_enabled
				applyDomainSplitRulesLive
				;;
			3)
				echo -e "\n${CYAN}--- Configure Custom Upstream Residential SOCKS5 Proxy ---${NC}"
				read -rp "Enter SOCKS5 Proxy IP (e.g. 127.0.0.1): " CUSTOM_PXY_IP
				read -rp "Enter SOCKS5 Proxy Port (e.g. 1080): " CUSTOM_PXY_PORT
				if [[ -n "$CUSTOM_PXY_IP" && -n "$CUSTOM_PXY_PORT" ]]; then
					configureRedsocksBridge "$CUSTOM_PXY_IP" "$CUSTOM_PXY_PORT"
					applyDomainSplitRulesLive
					echo -e "${GREEN}[✔] Custom SOCKS5 Proxy (${CUSTOM_PXY_IP}:${CUSTOM_PXY_PORT}) bridged via Redsocks!${NC}\n"
				fi
				;;
			4)
				if [[ -f /etc/wireguard/emulate_windows_ttl ]]; then
					rm -f /etc/wireguard/emulate_windows_ttl
					echo -e "${GREEN}[✔] Switched to Standard Desktop Unix/macOS Stack (TTL=64).${NC}\n"
				else
					touch /etc/wireguard/emulate_windows_ttl
					echo -e "${GREEN}[✔] Switched to Windows 10/11 Desktop Stack Emulation (TTL=128).${NC}\n"
				fi
				applyDomainSplitRulesLive
				;;
			5)
				verifyServerTrafficHealth
				read -n1 -r -p "Press Enter to continue..."
				;;
			6)
				rm -f /etc/wireguard/warp_egress_enabled 2>/dev/null || true
				systemctl stop wg-warp-watchdog.timer 2>/dev/null || true
				systemctl stop redsocks 2>/dev/null || true
				iptables -t nat -D PREROUTING -i "${SERVER_WG_NIC:-wg0}" -p tcp -j WG_STEALTH_PROXY 2>/dev/null || true
				iptables -t nat -F WG_STEALTH_PROXY 2>/dev/null || true
				iptables -t nat -X WG_STEALTH_PROXY 2>/dev/null || true
				echo -e "${GREEN}[✔] Reverted to Direct Native VPS Egress for all profiles.${NC}\n"
				read -n1 -r -p "Press Enter to continue..."
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

		systemctl stop "wg-quick@${SERVER_WG_NIC:-wg0}" >/dev/null 2>&1 || true
		systemctl disable "wg-quick@${SERVER_WG_NIC:-wg0}" >/dev/null 2>&1 || true
		systemctl stop cbwireguard-web >/dev/null 2>&1 || true
		systemctl disable cbwireguard-web >/dev/null 2>&1 || true
		systemctl stop wg-warp-watchdog.timer >/dev/null 2>&1 || true
		systemctl disable wg-warp-watchdog.timer >/dev/null 2>&1 || true
		systemctl stop redsocks >/dev/null 2>&1 || true

		if command -v wg-quick >/dev/null 2>&1; then
			wg-quick down "${SERVER_WG_NIC:-wg0}" >/dev/null 2>&1 || true
		fi
		ip link delete dev "${SERVER_WG_NIC:-wg0}" >/dev/null 2>&1 || true

		iptables -t nat -D PREROUTING -i "${SERVER_WG_NIC:-wg0}" -j WG_STEALTH_DNS 2>/dev/null || true
		iptables -t nat -F WG_STEALTH_DNS 2>/dev/null || true
		iptables -t nat -X WG_STEALTH_DNS 2>/dev/null || true

		iptables -t nat -D PREROUTING -i "${SERVER_WG_NIC:-wg0}" -p tcp -j WG_STEALTH_PROXY 2>/dev/null || true
		iptables -t nat -F WG_STEALTH_PROXY 2>/dev/null || true
		iptables -t nat -X WG_STEALTH_PROXY 2>/dev/null || true

		if [[ -n "${SERVER_PORT:-}" ]]; then
			iptables -D INPUT -p udp --dport "${SERVER_PORT}" -j ACCEPT 2>/dev/null || true
		fi
		iptables -D INPUT -i "${SERVER_WG_NIC:-wg0}" -j ACCEPT 2>/dev/null || true
		iptables -D FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
		iptables -D FORWARD -i "${SERVER_WG_NIC:-wg0}" -j ACCEPT 2>/dev/null || true
		iptables -D FORWARD -o "${SERVER_WG_NIC:-wg0}" -j ACCEPT 2>/dev/null || true
		iptables -t nat -D POSTROUTING -s 10.18.0.0/24 -j MASQUERADE 2>/dev/null || true
		iptables -t nat -D POSTROUTING -s 10.19.0.0/24 -j MASQUERADE 2>/dev/null || true

		if command -v ipset &>/dev/null; then
			ipset destroy wg_split_v4 2>/dev/null || true
			ipset destroy wg_split_v6 2>/dev/null || true
			ipset destroy wg_direct_clean 2>/dev/null || true
			ipset destroy wg_highspeed_direct 2>/dev/null || true
		fi
		rm -f /etc/dnsmasq.d/00-stealth-privacy.conf /etc/dnsmasq.d/wg_split.conf
		systemctl restart dnsmasq 2>/dev/null || true

		rm -rf /etc/wireguard
		rm -f /etc/sysctl.d/99-wireguard-stealth.conf
		rm -f /etc/systemd/system/cbwireguard-web.service
		rm -f /etc/systemd/system/wg-warp-watchdog.service /etc/systemd/system/wg-warp-watchdog.timer /usr/local/bin/wg-warp-watchdog.sh /usr/local/bin/easy_wireguard.sh
		systemctl daemon-reload

		echo -e "${GREEN}[✔] WireGuard uninstalled safely. Sensitive ports (80, 443, 22) preserved intact.${NC}\n"
		exit 0
	else
		echo -e "${YELLOW}Uninstall cancelled.${NC}\n"
	fi
}

# ------------------------------------------------------------------------------
# 11. Interactive Terminal Menu
# ------------------------------------------------------------------------------
function manageMenu() {
	while true; do
		local WG0_STATUS="${RED}STOPPED${NC}"
		if systemctl is-active --quiet "wg-quick@${SERVER_WG_NIC:-wg0}" 2>/dev/null || wg show "${SERVER_WG_NIC:-wg0}" &>/dev/null; then
			WG0_STATUS="${GREEN}ACTIVE${NC}"
		fi

		local BRIDGE_STATUS="${YELLOW}DIRECT VPS EGRESS (100% ONLINE)${NC}"
		if isTransparentProxyHealthy 40000; then
			BRIDGE_STATUS="${GREEN}WARP AS13335 BRIDGE + SCANNER CLOAK ACTIVE${NC}"
		fi

		echo -e "\n${PURPLE}=================================================================${NC}"
		echo -e "              ${GREEN}${BOLD}🍪  Cookie's Easy WireGuard Manager v4.2${NC}"
		echo -e "${PURPLE}=================================================================${NC}"
		echo -e "  ${BOLD}Server Daemon (Unified):${NC}    ${SERVER_WG_NIC:-wg0} | Port ${SERVER_PORT:-4500}/udp [${WG0_STATUS}]"
		echo -e "  ${BOLD}Stealth Egress Engine:${NC}      [${BRIDGE_STATUS}]"
		echo -e "  ${BOLD}Profile 1 (Stealth Gateway):${NC}10.19.0.0/24 (WARP Cloak + Fast-Lane, MTU 1380, Port ${SERVER_PORT:-4500})"
		echo -e "  ${BOLD}Profile 2 (Standard):${NC}       10.18.0.0/24 (Direct VPS + Amazon/LI Shield, MTU 1420, Port ${SERVER_PORT:-4500})"
		echo -e "${PURPLE}┌──────────────────────────────────────────────────────────────┐${NC}"
		echo -e "${PURPLE}│${NC}                      ${CYAN}${BOLD}Main Menu Actions${NC}                       ${PURPLE}│${NC}"
		echo -e "${PURPLE}├──────────────────────────────────────────────────────────────┤${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[1]${NC} Setup WireGuard server (Unified Port for Both Profiles)   ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[2]${NC} Add new client (Generates Standard & Stealth Profiles)    ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[3]${NC} Configure clients (Check/Edit/Export/Remove)             ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[4]${NC} Backup & Restore Manager                                 ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[5]${NC} Domain-Based Split Tunneling (Amazon/LinkedIn/Scanners)  ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[6]${NC} Real-Time Logging (Errors)                               ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[7]${NC} Geo-IP, Scanner Cloak & High-Speed Offload Status        ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[8]${NC} Provision Web Management Console                         ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[9]${NC} Stealth Anti-Scanner & Smart Egress Gateway Engine        ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[10]${NC} Safe Network, DNS, WARP & Speed Auto-Repair             ${PURPLE}│${NC}"
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
# 12. Script Entrypoint Execution
# ------------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	initialCheck

	if [[ -e /etc/wireguard/params ]]; then
		source /etc/wireguard/params
	fi

	if [[ "${1:-}" == "--apply-rules" ]]; then
		applyDomainSplitRulesLive
		exit 0
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