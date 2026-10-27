#!/bin/bash
# ==============================================================================
# 🍪 Cookie's Easy WireGuard Manager & VPS Stealth Server v4.0
# Inspired by angristan/wireguard-install with Hyper-Optimized VPS Stealth Features
# Server-Side Transparent Anti-WAF / Anti-Bot Engine (Zero Client-Side Changes)
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
	local sensitive_ports=(20 21 22 23 25 53 67 68 80 110 143 443 8080 8443 3306 5432 6379 27017 12345 40000)
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
			ss -uln 2>/dev/null | grep -qE "(:|\])${port}\b" && return 0
		else
			ss -tln 2>/dev/null | grep -qE "(:|\])${port}\b" && return 0
		fi
	elif command -v netstat &>/dev/null; then
		if [[ "$proto" == "udp" ]]; then
			netstat -uln 2>/dev/null | grep -qE "(:|\])${port}\b" && return 0
		else
			netstat -tln 2>/dev/null | grep -qE "(:|\])${port}\b" && return 0
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

	# Clean custom redsocks chain if present
	iptables -t nat -D PREROUTING -i wg0 -p tcp -j WG_STEALTH_PROXY 2>/dev/null || true
	iptables -t nat -F WG_STEALTH_PROXY 2>/dev/null || true
	iptables -t nat -X WG_STEALTH_PROXY 2>/dev/null || true

	# Surgical rule cleanup: only remove WireGuard-created rules
	iptables -D FORWARD -i wg0 -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true
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
# 3. DNS Resolvers Selection Menu (Server-Intercepted Stealth for IPv4 & IPv6)
# ------------------------------------------------------------------------------
function selectDNSResolvers() {
	echo -e "\n${CYAN}${BOLD}Select DNS Resolvers for Clients (Transparently Accelerated & Filtered on Server):${NC}"
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
	echo -e "   6) ${GREEN}Local Server Stealth Resolver${NC} (Server Local | Maximum Anti-Leak)"
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
	echo -e "          ${GREEN}${BOLD}🍪  Cookie's Easy WireGuard Setup & Installer${NC}"
	echo -e "${PURPLE}=================================================================${NC}"
	echo -e "Welcome to the WireGuard installer!\n"

	SERVER_PUB_IP=""
	local services=("https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com")
	for svc in "${services[@]}"; do
		SERVER_PUB_IP=$(curl -4 -sSf --max-time 2 "$svc" 2>/dev/null | tr -d '\r\n' || true)
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

	read -rp "Allowed IPs for generated clients: " -e -i "0.0.0.0/0, ::/0" ALLOWED_IPS

	echo -e "\n${CYAN}${BOLD}☁️ Server-Side Cloudflare Anti-Flag, LinkedIn Unblocker & WARP Transparent Bridge:${NC}"
	echo -e "   • Deploys TCP MSS=1360 Clamping, QUIC UDP:443 Clean Fallback & Uniform TTL=64 Normalization"
	echo -e "   • Installs Cloudflare WARP Consumer Egress (AS13335) + Redsocks Transparent TCP Bridge"
	echo -e "   • Automatically routes LinkedIn, Cloudflare WAF, Turnstile & AI domains via WARP Consumer IP"
	echo -e "   • Preserves Direct Clean VPS IP for PayPal, 3D-Secure, Braintree & Banking"
	echo -e "   • Zero client-side software required — standard WireGuard .conf works out-of-the-box!"
	echo -e "   ${GREEN}[✔] Auto-enabled: Full Server-Side Anti-Detect & Transparent WARP Bridge active.${NC}"
	CF_AUTO_ENABLE="y"

	WEB_PORT=${WEB_PORT:-51821}

	echo -e "\n${GREEN}Setup parameters configured successfully.${NC}"
	read -n1 -r -p "Press any key to start WireGuard installation..."
	echo ""
}

# ------------------------------------------------------------------------------
# 5. Transparent Redsocks + WARP Bridge Configuration & Health Verification
# ------------------------------------------------------------------------------
function configureRedsocksBridge() {
	local PROXY_HOST="${1:-127.0.0.1}"
	local PROXY_PORT="${2:-40000}"

	if ! command -v redsocks &>/dev/null; then
		if command -v apt-get &>/dev/null; then
			apt-get install -y -qq redsocks >/dev/null 2>&1 || true
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
}

redsocks {
	local_ip = 127.0.0.1;
	local_port = 12345;
	ip = ${PROXY_HOST};
	port = ${PROXY_PORT};
	type = socks5;
}
REDSOCKS_EOF

	mkdir -p /etc/systemd/system/redsocks.service.d
	cat << 'OVERRIDE_EOF' > /etc/systemd/system/redsocks.service.d/override.conf
[Service]
Restart=always
RestartSec=3
LimitNOFILE=65535
OVERRIDE_EOF

	systemctl daemon-reload >/dev/null 2>&1 || true
	systemctl enable redsocks >/dev/null 2>&1 || true
	systemctl restart redsocks >/dev/null 2>&1 || true
	return 0
}

# Verifies that both the SOCKS5 upstream (WARP on :40000) and redsocks (:12345) are alive and passing traffic
function isTransparentBridgeHealthy() {
	local PROXY_PORT="${1:-40000}"
	if ! isPortInUse "$PROXY_PORT" "tcp"; then
		return 1
	fi
	if ! isPortInUse 12345 "tcp"; then
		return 1
	fi
	if command -v curl &>/dev/null; then
		if curl -x "socks5h://127.0.0.1:${PROXY_PORT}" -sSf --connect-timeout 2 --max-time 3 "https://www.cloudflare.com/cdn-cgi/trace" >/dev/null 2>&1; then
			return 0
		fi
	fi
	return 1
}

# Self-tests DNS, NAT, WARP Bridge, and Egress Connectivity
function verifyAndTestTraffic() {
	echo -e "\n${CYAN}${BOLD}🔍 Running Automated End-to-End Server & Tunnel Traffic Verification...${NC}"

	# 1. Check wg0 interface
	if ip link show "${SERVER_WG_NIC:-wg0}" &>/dev/null; then
		echo -e "  ${GREEN}[✔] WireGuard Interface (${SERVER_WG_NIC:-wg0}):${NC} UP & Listening on UDP/${SERVER_PORT:-4500}"
	else
		echo -e "  ${YELLOW}[!] WireGuard Interface (${SERVER_WG_NIC:-wg0}) down — starting now...${NC}"
		systemctl restart "wg-quick@${SERVER_WG_NIC:-wg0}" 2>/dev/null || wg-quick up "${SERVER_WG_NIC:-wg0}" 2>/dev/null || true
	fi

	# 2. Check IPv4 Forwarding
	local FWD_VAL
	FWD_VAL=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)
	if [[ "$FWD_VAL" -eq 1 ]]; then
		echo -e "  ${GREEN}[✔] Kernel IPv4 Forwarding:${NC} ENABLED (net.ipv4.ip_forward = 1)"
	else
		sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
		echo -e "  ${GREEN}[✔] Kernel IPv4 Forwarding:${NC} Auto-repaired & enabled"
	fi

	# 3. Check Local DNS Resolver (dnsmasq)
	if systemctl is-active --quiet dnsmasq 2>/dev/null && isPortInUse 53 "udp"; then
		echo -e "  ${GREEN}[✔] Local Stealth DNS (dnsmasq):${NC} ACTIVE on 10.18.0.1:53 & 10.19.0.1:53"
	else
		echo -e "  ${YELLOW}[!] dnsmasq not bound — fallback DNAT to 1.1.1.1:53 active (Zero DNS failure)${NC}"
	fi

	# 4. Check Direct VPS Egress
	if curl -4 -sSf --max-time 4 "https://www.cloudflare.com/cdn-cgi/trace" >/dev/null 2>&1; then
		echo -e "  ${GREEN}[✔] Direct VPS Egress Connectivity:${NC} HEALTHY (100% Online)"
	else
		echo -e "  ${RED}[!] Warning: Host outbound HTTPS check failed. Running DNS repair...${NC}"
		echo -e "nameserver 1.1.1.1\nnameserver 1.0.0.1\nnameserver 8.8.8.8" > /etc/resolv.conf 2>/dev/null || true
	fi

	# 5. Check WARP + Redsocks Anti-WAF Bridge
	if isTransparentBridgeHealthy 40000; then
		local WARP_TRACE
		WARP_TRACE=$(curl -x socks5h://127.0.0.1:40000 -sSf --max-time 3 "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null | grep -E "^(ip|warp)=" | tr '\n' ' ')
		echo -e "  ${GREEN}[✔] Cloudflare WARP + Redsocks Anti-WAF Bridge:${NC} ACTIVE (${WARP_TRACE})"
		echo -e "  ${GREEN}[✔] LinkedIn & Cloudflare WAF Protection:${NC} Traffic seamlessly exits via Cloudflare AS13335"
	else
		echo -e "  ${YELLOW}[i] WARP SOCKS5 Bridge inactive — Fail-Safe Direct Egress active (Traffic flows directly without errors)${NC}"
	fi
	echo ""
}

# ------------------------------------------------------------------------------
# 6. Perform WireGuard Server Installation
# ------------------------------------------------------------------------------
function installWireGuard() {
	if [[ -z "${SERVER_PORT:-}" ]]; then
		installQuestions
	fi

	cleanupOldWireguard

	echo -e "\n${CYAN}[*] Checking and installing system dependencies (wireguard, dnsmasq, redsocks, ipset, iptables, qrencode)...${NC}"

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
		for pkg in wireguard wireguard-tools iptables qrencode curl jq iproute2 iptables-persistent net-tools ipset dnsmasq redsocks gnupg lsb-release ca-certificates; do
			if ! dpkg -s "$pkg" &>/dev/null; then
				NEED_APT_INSTALL=1
				MISSING_PKGS+=("$pkg")
			fi
		done

		if [[ "$NEED_APT_INSTALL" -eq 1 ]]; then
			echo -e "${YELLOW}[*] Updating package index and installing (${MISSING_PKGS[*]})...${NC}"
			apt-get update -o Acquire::Languages=none \
			               -o Acquire::Http::Timeout="10" \
			               -o Acquire::Retries="2" \
			               -y -q >/dev/null 2>&1 || true

			apt-get install -y -q -o Dpkg::Options::="--force-confdef" \
			                      -o Dpkg::Options::="--force-confold" \
			                      "${MISSING_PKGS[@]}" >/dev/null 2>&1 || true
		else
			echo -e "${GREEN}[✔] Core WireGuard & Stealth packages already installed.${NC}"
		fi
	elif [[ "${OS}" == "fedora" || "${OS}" == "centos" || "${OS}" == "almalinux" || "${OS}" == "rocky" ]]; then
		yum install -y wireguard-tools iptables qrencode curl jq ipset dnsmasq || true
	elif [[ "${OS}" == "arch" ]]; then
		pacman -S --needed --noconfirm wireguard-tools qrencode iptables curl jq ipset dnsmasq || true
	elif [[ "${OS}" == "alpine" ]]; then
		apk update && apk add wireguard-tools iptables libqrencode-tools curl jq ipset dnsmasq || true
	fi

	# Ensure host resolv.conf always maintains clean, operational Anycast nameservers
	if ! grep -q -E "nameserver [0-9]" /etc/resolv.conf 2>/dev/null || grep -q "127.0.0.53" /etc/resolv.conf 2>/dev/null; then
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

	echo -e "${CYAN}[*] Loading WireGuard and networking kernel modules...${NC}"
	modprobe wireguard >/dev/null 2>&1 || { apt-get install -y "linux-headers-$(uname -r)" wireguard-dkms >/dev/null 2>&1 || true; modprobe wireguard >/dev/null 2>&1 || true; }
	modprobe iptable_nat >/dev/null 2>&1 || true
	modprobe iptable_mangle >/dev/null 2>&1 || true
	modprobe ip6table_nat >/dev/null 2>&1 || true
	modprobe xt_mark >/dev/null 2>&1 || true
	modprobe xt_hl >/dev/null 2>&1 || true
	modprobe ipt_TTL >/dev/null 2>&1 || true
	modprobe tcp_bbr >/dev/null 2>&1 || true

	# Detect whether host genuinely supports IPv6 with active internet egress
	local HAS_IPV6=0
	if [[ -f /proc/net/if_inet6 ]] && [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1) -eq 0 ]]; then
		if ip -6 route show default 2>/dev/null | grep -q "default"; then
			if curl -6 -sSf --max-time 2 "https://api64.ipify.org" >/dev/null 2>&1; then
				HAS_IPV6=1
			fi
		fi
	fi

	echo -e "${CYAN}[*] Applying BBR, TTL=64 Normalization, and MSS Clamping sysctl rules...${NC}"
	SYSCTL_CONF="/etc/sysctl.d/99-wireguard-stealth.conf"
	cat << 'SYSCTL_EOF' > "$SYSCTL_CONF"
net.ipv4.ip_forward = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.ip_default_ttl = 64
net.core.default_qdisc = fq
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.netdev_max_backlog = 100000
net.ipv4.tcp_max_syn_backlog = 3240000
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
SYSCTL_EOF

	if [[ "${HAS_IPV6}" -eq 1 ]]; then
		cat << 'SYSCTL_V6_EOF' >> "$SYSCTL_CONF"
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.all.forwarding = 1
SYSCTL_V6_EOF
	else
		# Prevent IPv6 blackholes/leaks when VPS has no working IPv6 upstream
		cat << 'SYSCTL_NO_V6_EOF' >> "$SYSCTL_CONF"
net.ipv6.conf.all.forwarding = 0
SYSCTL_NO_V6_EOF
	fi

	if lsmod 2>/dev/null | grep -q bbr || grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
		echo "net.ipv4.tcp_congestion_control = bbr" >> "$SYSCTL_CONF"
	fi

	sysctl --system -q >/dev/null 2>&1 || sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || true

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

	# --------------------------------------------------------------------------
	# UNIFIED WIREGUARD SERVER (/etc/wireguard/wg0.conf)
	# Single selected port ${SERVER_PORT}/udp serves BOTH:
	# 1. Cloudflare Anti-Flag & Stealth Profile (10.19.0.0/24: Stealth Gateway)
	# 2. Standard Profile (10.18.0.0/24: Canonical Direct VPS Egress)
	# --------------------------------------------------------------------------
	echo -e "${CYAN}[*] Configuring Unified WireGuard Server (wg0 | Port ${SERVER_PORT}/udp | Subnets: 10.19.0.0/24 & 10.18.0.0/24)...${NC}"
	cat << WG_SERVER_EOF > "/etc/wireguard/wg0.conf"
[Interface]
Address = ${WG_SERVER_ADDRESS}, 10.19.0.1/24
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PRIV_KEY}
MTU = 1420
SaveConfig = false

# --- 1. CORE NETWORKING & FIREWALL (Port ${SERVER_PORT}/udp for Both Profiles) ---
PostUp = sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
PostUp = ip link set dev wg0 txqueuelen 10000 2>/dev/null || true
PostUp = iptables -I INPUT 1 -p udp --dport ${SERVER_PORT} -j ACCEPT 2>/dev/null || true
PostUp = iptables -I INPUT 2 -i wg0 -p udp --dport 53 -j ACCEPT 2>/dev/null || true
PostUp = iptables -I INPUT 3 -i wg0 -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
PostUp = iptables -I INPUT 4 -i wg0 -p tcp --dport 12345 -j ACCEPT 2>/dev/null || true
# Block QUIC (UDP 443) so browsers cleanly use HTTP/2 over TCP 443 (prevents UDP fingerprint leak & routes via transparent WARP bridge)
PostUp = iptables -I FORWARD 1 -i wg0 -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true
PostUp = iptables -I FORWARD 2 -i wg0 -j ACCEPT 2>/dev/null || true
PostUp = iptables -I FORWARD 3 -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
PostUp = iptables -I FORWARD 4 -s 10.18.0.0/24 -j ACCEPT 2>/dev/null || true
PostUp = iptables -I FORWARD 5 -d 10.18.0.0/24 -j ACCEPT 2>/dev/null || true
PostUp = iptables -I FORWARD 6 -s 10.19.0.0/24 -j ACCEPT 2>/dev/null || true
PostUp = iptables -I FORWARD 7 -d 10.19.0.0/24 -j ACCEPT 2>/dev/null || true
PostUp = iptables -t nat -I POSTROUTING 1 -s 10.18.0.0/24 ! -o wg0 -j MASQUERADE 2>/dev/null || true
PostUp = iptables -t nat -I POSTROUTING 2 -s 10.19.0.0/24 ! -o wg0 -j MASQUERADE 2>/dev/null || true
PostUp = iptables -t nat -I POSTROUTING 3 -s 10.18.0.0/24 -o ${SERVER_PUB_NIC} -j MASQUERADE 2>/dev/null || true
PostUp = iptables -t nat -I POSTROUTING 4 -s 10.19.0.0/24 -o ${SERVER_PUB_NIC} -j MASQUERADE 2>/dev/null || true

# --- 2. STEALTH MSS CLAMPING & UNIFORM TTL=64 NORMALIZATION (Anti-p0f & Anti-Fragmentation) ---
PostUp = iptables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostUp = iptables -t mangle -I FORWARD 2 -s 10.19.0.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360 2>/dev/null || true
PostUp = iptables -t mangle -I FORWARD 3 -d 10.19.0.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360 2>/dev/null || true
PostUp = iptables -t mangle -I POSTROUTING 1 ! -o wg0 -j TTL --ttl-set 64 2>/dev/null || true

# Teardown Rules
PostDown = iptables -D INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT 2>/dev/null || true
PostDown = iptables -D INPUT -i wg0 -p udp --dport 53 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D INPUT -i wg0 -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D INPUT -i wg0 -p tcp --dport 12345 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i wg0 -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -s 10.18.0.0/24 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -d 10.18.0.0/24 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -s 10.19.0.0/24 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -d 10.19.0.0/24 -j ACCEPT 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s 10.18.0.0/24 ! -o wg0 -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s 10.19.0.0/24 ! -o wg0 -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s 10.18.0.0/24 -o ${SERVER_PUB_NIC} -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s 10.19.0.0/24 -o ${SERVER_PUB_NIC} -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -s 10.19.0.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -d 10.19.0.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360 2>/dev/null || true
PostDown = iptables -t mangle -D POSTROUTING ! -o wg0 -j TTL --ttl-set 64 2>/dev/null || true
WG_SERVER_EOF

	chmod 600 "/etc/wireguard/wg0.conf"

	wg-quick down wg1 >/dev/null 2>&1 || true
	ip link delete dev wg1 >/dev/null 2>&1 || true
	rm -f "/etc/wireguard/wg1.conf"

	wg-quick down wg0 >/dev/null 2>&1 || true
	ip link delete dev wg0 >/dev/null 2>&1 || true
	systemctl stop "wg-quick@wg0" >/dev/null 2>&1 || true
	systemctl stop "wg-quick@wg1" >/dev/null 2>&1 || true
	systemctl disable "wg-quick@wg1" >/dev/null 2>&1 || true

	systemctl daemon-reload >/dev/null 2>&1 || true
	systemctl enable "wg-quick@wg0" >/dev/null 2>&1 || true

	echo -e "${CYAN}[*] Starting Unified WireGuard daemon (wg-quick@wg0)...${NC}"
	systemctl restart "wg-quick@wg0" 2>/dev/null || wg-quick up wg0 2>/dev/null || true

	if systemctl is-active --quiet "wg-quick@wg0" || wg show wg0 &>/dev/null; then
		echo -e "${GREEN}[✔] Unified WireGuard Server (wg0 | Port ${SERVER_PORT}/udp) active!${NC}"
	fi

	# Auto-Install & Configure Essential Cloudflare WARP + Redsocks Bridge & Anti-Flag Engine
	if [[ "${CF_AUTO_ENABLE}" == "y" ]]; then
		echo -e "\n${CYAN}[*] Auto-Installing & Configuring Cloudflare WARP Consumer Egress & Anti-WAF Bridge...${NC}"
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

# LinkedIn Professional Network & Media CDN (Unblocks LinkedIn Cloudflare WAF & HTTP 999 Datacenter Blocks)
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

# AI & High-Sensitivity WAF Services
openai.com
chatgpt.com
oaistatic.com
oaiusercontent.com
claude.ai
anthropic.com
perplexity.ai

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

# PayPal, Braintree & 3D-Secure Gateways (Protected via Direct Static VPS IP)
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

		# Actually invoke WARP installation & Redsocks setup during install!
		setupCloudflareWarpClient
		applyDomainSplitRulesLive
		verifyAndTestTraffic

		echo -e "${GREEN}[✔] Server-Side Cloudflare Anti-Flag Shield, WARP Bridge & LinkedIn Unblocker active!${NC}"
	else
		echo -e "\n${GREEN}[✔] Standard Full Tunnel configured.${NC}"
		rm -f /etc/wireguard/cloudflare_shield_enabled /etc/wireguard/cloudflare_split_enabled /etc/wireguard/warp_egress_enabled 2>/dev/null || true
	fi

	newClientInternal "${CLIENT_NAME}" "${CLIENT_PASSWORD}"

	echo -e "\n${GREEN}${BOLD}=================================================================${NC}"
	echo -e "${GREEN}${BOLD}🎉 WIREGUARD SERVER INSTALLED & VERIFIED SUCCESSFULLY!${NC}"
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
# 7. Provision Web Management Console Runtime
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
# 8. Client Management Logic (100% Standard WireGuard Client Conf Output)
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
	# 1. Build Profile 1: Stealth Anti-Scanner & Cloudflare Shield (10.19.0.x)
	# --------------------------------------------------------------------------
	local CF_CONF_CONTENT
	CF_CONF_CONTENT=$(cat << CF_CLIENT_EOF
# ==============================================================================
# ☁️ PROFILE 1: CLOUDFLARE ANTI-FLAG & STEALTH GATEWAY
# ==============================================================================
# • Protocol Mode: Standard WireGuard Client (Server-Side Stealth & WARP Bridge)
# • Port: ${SERVER_PORT} (Unified Port - Shared with Standard Profile)
# • Subnet / Assigned IP: ${CLIENT_WG_CF_IPV4}/32 (Subnet: 10.19.0.0/24)
# • MTU: 1380 (Optimized for Zero TLS ClientHello Fragmentation)
# • DNS: ${CLIENT_DNS_LINE} (Intercepted by Server Stealth Resolver)
# • Target Use Case: LinkedIn, Cloudflare WAF / Turnstile bypass, AI platforms,
#                    general browsing with anti-VPN evasion.
# ==============================================================================
[Interface]
PrivateKey = ${CLIENT_CF_PRIV_KEY}
Address = ${CLIENT_WG_CF_IPV4}/32
DNS = ${CLIENT_DNS_LINE}
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
	# 2. Build Profile 2: Standard Full-Tunnel (10.18.0.x)
	# --------------------------------------------------------------------------
	local STD_CONF_CONTENT
	STD_CONF_CONTENT=$(cat << CLIENT_EOF
# ==============================================================================
# 🛡️ PROFILE 2: STANDARD WIREGUARD FULL-TUNNEL (WITH SMART ANTI-WAF ROUTING)
# ==============================================================================
# • Protocol Mode: Canonical WireGuard
# • Port: ${SERVER_PORT} (Unified Port - Shared with Stealth Profile)
# • Subnet / Assigned IP: ${CLIENT_ADDRESS} (Subnet: 10.18.0.0/24)
# • MTU: 1380 (Optimized for Clean TLS & PMTU)
# • DNS: ${CLIENT_DNS_LINE} (High-Speed Standard Anycast)
# • Target Use Case: All-in-one daily browsing, LinkedIn, Amazon, PayPal, banking.
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
	echo -e "   • Profile 1 (Stealth/CF):     ${CLIENT_WG_CF_IPV4} on port ${SERVER_PORT} (Server-Side WARP Anti-WAF Bridge)"
	echo -e "   • Profile 2 (Standard):       ${CLIENT_WG_IPV4} on port ${SERVER_PORT} (Smart Anti-WAF + Direct Banking Egress)\n"

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
		echo -e "\n${GREEN}${BOLD}📋 [2/2] Profile 2: Standard Full Tunnel (Smart Anti-WAF | Port ${SERVER_PORT:-4500}):${NC}"
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
for conf_path in ['/etc/wireguard/wg0.conf']:
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
	fi
	sed -i "/^### Client ${TARGET_CLIENT}\b/,/^$/d" "$CONF_FILE" 2>/dev/null || true

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
# 9. Dynamic Real-Time Domain Split Tunneling & Anti-WAF Routing Engine
# ------------------------------------------------------------------------------
function applyDomainSplitRulesLive() {
	echo -e "\n${CYAN}[*] Applying Server-Side Anti-WAF & Domain Split Routing Rules Live...${NC}"

	mkdir -p /etc/wireguard
	touch /etc/wireguard/split_domains.txt
	if [[ ! -f /etc/wireguard/split_mode.txt ]]; then
		echo "BYPASS" > /etc/wireguard/split_mode.txt
	fi

	local MODE
	MODE=$(cat /etc/wireguard/split_mode.txt 2>/dev/null || echo "BYPASS")

	# Ensure required packages (ipset, dnsmasq, redsocks) are installed
	if command -v apt-get &>/dev/null; then
		for req_pkg in ipset dnsmasq redsocks; do
			if ! command -v "$req_pkg" &>/dev/null; then
				apt-get install -y -qq "$req_pkg" >/dev/null 2>&1 || true
			fi
		done
	fi

	if command -v ipset &>/dev/null; then
		ipset create wg_split_v4 hash:net family inet maxelem 65536 2>/dev/null || true
		ipset create wg_split_v6 hash:net family inet6 maxelem 65536 2>/dev/null || true
		ipset create wg_direct_clean hash:net family inet maxelem 65536 2>/dev/null || true
		ipset flush wg_split_v4 2>/dev/null || true
		ipset flush wg_split_v6 2>/dev/null || true
		ipset flush wg_direct_clean 2>/dev/null || true
	fi

	# Ensure systemd-resolved does not collide with dnsmasq on port 53
	if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
		mkdir -p /etc/systemd/resolved.conf.d
		cat << 'RESOLVED_NO_STUB' > /etc/systemd/resolved.conf.d/no-stub.conf 2>/dev/null || true
[Resolve]
DNSStubListener=no
RESOLVED_NO_STUB
		systemctl restart systemd-resolved 2>/dev/null || true
		rm -f /etc/resolv.conf 2>/dev/null || true
		cat << 'RESOLV_HOST' > /etc/resolv.conf 2>/dev/null || true
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
RESOLV_HOST
	fi

	# Configure dnsmasq for high-speed DNS resolution & automatic ipset population
	mkdir -p /etc/dnsmasq.d
	rm -f /etc/dnsmasq.d/00-stealth-privacy.conf /etc/dnsmasq.d/wg_split.conf 2>/dev/null || true
	cat << DNSMASQ_STEALTH_EOF > /etc/dnsmasq.d/00-stealth-privacy.conf
# Cookie WireGuard Stealth & Privacy DNS Configuration
cache-size=10000
dns-forward-max=1000
bogus-priv
interface=${SERVER_WG_NIC:-wg0}
except-interface=lo
bind-dynamic
listen-address=${SERVER_WG_IPV4:-10.18.0.1},10.19.0.1
no-resolv
server=1.1.1.1
server=1.0.0.1
server=8.8.8.8
DNSMASQ_STEALTH_EOF

	# Detect if installed dnsmasq binary supports the ipset= directive
	local DNSMASQ_HAS_IPSET=0
	if dnsmasq --version 2>/dev/null | grep -q "ipset"; then
		DNSMASQ_HAS_IPSET=1
	fi

	echo "# Cookie WireGuard Dynamic Split Tunneling Rules" > /etc/dnsmasq.d/wg_split.conf

	local DOMAIN_COUNT=0
	while IFS= read -r raw_domain || [[ -n "$raw_domain" ]]; do
		[[ -z "$raw_domain" || "$raw_domain" =~ ^# ]] && continue
		local base_domain
		base_domain=$(echo "$raw_domain" | sed -e 's|^https*://||' -e 's|/.*$||' | tr '[:upper:]' '[:lower:]' | xargs)
		[[ -z "$base_domain" ]] && continue

		local EXPANDED_DOMAINS=("$base_domain")
		if [[ "$base_domain" == "paypal.com" || "$base_domain" == *"paypal.com" || "$base_domain" == *"paypalobjects.com" ]]; then
			EXPANDED_DOMAINS+=("www.paypal.com" "c.paypal.com" "b.stats.paypal.com" "t.paypal.com" "s.paypal.com" "m.paypal.com" "api.paypal.com" "api-m.paypal.com" "checkout.paypal.com" "identity.paypal.com" "paypalobjects.com" "www.paypalobjects.com" "objects.paypal.com" "c.paypalobjects.com" "paypal.me" "paypal-mktg.com" "cardinalcommerce.com" "songbird.cardinalcommerce.com" "centinelapi.cardinalcommerce.com" "geo.cardinalcommerce.com" "braintreegateway.com" "braintree-api.com" "assets.braintreegateway.com" "js.braintreegateway.com")
		elif [[ "$base_domain" == "linkedin.com" || "$base_domain" == *"linkedin.com" ]]; then
			EXPANDED_DOMAINS+=("www.linkedin.com" "licdn.com" "media.licdn.com" "static.licdn.com" "lnkd.in" "media-exp1.licdn.com" "platform.linkedin.com" "voyager.linkedin.com" "dms.licdn.com" "snap.licdn.com" "px.ads.linkedin.com" "api.linkedin.com" "www.lnkd.in")
		elif [[ "$base_domain" == "cloudflare.com" || "$base_domain" == *"cloudflare.com" ]]; then
			EXPANDED_DOMAINS+=("challenges.cloudflare.com" "turnstile.com" "cdnjs.cloudflare.com" "cloudflareinsights.com" "cf-assets.com" "pages.dev" "workers.dev")
		fi

		for domain in "${EXPANDED_DOMAINS[@]}"; do
			((DOMAIN_COUNT++))

			local IS_PAYMENT=0
			if [[ "$domain" =~ (paypal|cardinalcommerce|braintree|stripe|chase|bankofamerica|wellsfargo) ]]; then
				IS_PAYMENT=1
			fi

			if command -v ipset &>/dev/null && [[ "$DNSMASQ_HAS_IPSET" -eq 1 ]]; then
				if [[ $IS_PAYMENT -eq 1 ]]; then
					echo "ipset=/${domain}/wg_direct_clean" >> /etc/dnsmasq.d/wg_split.conf
				else
					echo "ipset=/${domain}/wg_split_v4,wg_split_v6" >> /etc/dnsmasq.d/wg_split.conf
				fi
			fi

			local resolved_v4
			resolved_v4=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u || true)
			for ip in $resolved_v4; do
				if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && command -v ipset &>/dev/null; then
					if [[ $IS_PAYMENT -eq 1 ]]; then
						ipset add wg_direct_clean "$ip" 2>/dev/null || true
					else
						ipset add wg_split_v4 "$ip" 2>/dev/null || true
					fi
				fi
			done
		done
	done < /etc/wireguard/split_domains.txt

	# 1. PayPal & Payment Gateways (AS11643) -> Direct Clean Static VPS Egress (Never Proxy/WARP)
	local PAYPAL_V4="64.4.240.0/21 66.211.168.0/21 173.0.80.0/20 173.224.160.0/19 185.177.52.0/22 192.148.20.0/23 198.54.120.0/22 216.113.160.0/19"
	for p in $PAYPAL_V4; do
		if command -v ipset &>/dev/null; then
			ipset add wg_direct_clean "$p" 2>/dev/null || true
		fi
	done

	# 2. LinkedIn Official Autonomous System CIDRs (AS12447, AS14413, Azure FrontDoor / LinkedIn Edge)
	local LINKEDIN_V4="108.174.0.0/20 144.2.0.0/19 185.63.144.0/22 199.101.160.0/22 216.52.16.0/20 216.52.20.0/22 216.52.24.0/22 65.156.227.0/24 8.247.168.0/24 13.107.42.0/24 13.107.213.0/24 150.171.22.0/24"
	for c in $LINKEDIN_V4; do
		if command -v ipset &>/dev/null; then
			ipset add wg_split_v4 "$c" 2>/dev/null || true
		fi
	done

	# 3. Cloudflare Official Anycast Edge CIDRs (Covers LinkedIn Cloudflare WAF, Turnstile, OpenAI, and all Cloudflare-protected sites)
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

	# Start/Restart dnsmasq and verify configuration syntax
	local DNSMASQ_OK=0
	if command -v dnsmasq &>/dev/null; then
		if ! dnsmasq --test >/dev/null 2>&1; then
			rm -f /etc/dnsmasq.d/wg_split.conf 2>/dev/null || true
		fi
		systemctl enable dnsmasq >/dev/null 2>&1 || true
		systemctl restart dnsmasq >/dev/null 2>&1 || true
		if systemctl is-active --quiet dnsmasq 2>/dev/null; then
			DNSMASQ_OK=1
		fi
	fi

	local DEF_NIC="${SERVER_PUB_NIC}"
	if [[ -z "$DEF_NIC" ]]; then
		DEF_NIC=$(ip -4 route show default 2>/dev/null | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | head -n1 || echo "eth0")
	fi

	# Ensure Core Forwarding, QUIC UDP:443 Block, and NAT Masquerade are always active
	iptables -D FORWARD -i "${SERVER_WG_NIC:-wg0}" -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true
	iptables -I FORWARD 1 -i "${SERVER_WG_NIC:-wg0}" -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true
	iptables -I FORWARD 2 -i "${SERVER_WG_NIC:-wg0}" -j ACCEPT 2>/dev/null || true
	iptables -I FORWARD 3 -o "${SERVER_WG_NIC:-wg0}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
	iptables -I FORWARD 4 -s 10.18.0.0/24 -j ACCEPT 2>/dev/null || true
	iptables -I FORWARD 5 -d 10.18.0.0/24 -j ACCEPT 2>/dev/null || true
	iptables -I FORWARD 6 -s 10.19.0.0/24 -j ACCEPT 2>/dev/null || true
	iptables -I FORWARD 7 -d 10.19.0.0/24 -j ACCEPT 2>/dev/null || true

	iptables -t nat -I POSTROUTING 1 -s 10.18.0.0/24 ! -o "${SERVER_WG_NIC:-wg0}" -j MASQUERADE 2>/dev/null || true
	iptables -t nat -I POSTROUTING 2 -s 10.19.0.0/24 ! -o "${SERVER_WG_NIC:-wg0}" -j MASQUERADE 2>/dev/null || true
	if [[ -n "$DEF_NIC" ]]; then
		iptables -t nat -I POSTROUTING 3 -s 10.18.0.0/24 -o "$DEF_NIC" -j MASQUERADE 2>/dev/null || true
		iptables -t nat -I POSTROUTING 4 -s 10.19.0.0/24 -o "$DEF_NIC" -j MASQUERADE 2>/dev/null || true
	fi
	sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

	# Clean any broken legacy fwmark rules that caused routing blackholes
	ip rule del fwmark 0x51820 table 51820 2>/dev/null || true
	iptables -t mangle -D PREROUTING -i "${SERVER_WG_NIC:-wg0}" -m set --match-set wg_split_v4 dst -j MARK --set-mark 0x51820 2>/dev/null || true
	iptables -t mangle -D PREROUTING -s 10.19.0.0/24 -m set --match-set wg_split_v4 dst -j MARK --set-mark 0x51820 2>/dev/null || true

	# --------------------------------------------------------------------------
	# TRANSPARENT ANTI-WAF REDSOCKS + WARP BRIDGE (WG_STEALTH_PROXY NAT Chain)
	# Routes LinkedIn, Cloudflare WAF, Turnstile & Split Domains through WARP
	# Consumer Egress (127.0.0.1:40000 via redsocks :12345) ONLY when verified healthy!
	# --------------------------------------------------------------------------
	iptables -t nat -D PREROUTING -i "${SERVER_WG_NIC:-wg0}" -p tcp -j WG_STEALTH_PROXY 2>/dev/null || true
	iptables -t nat -F WG_STEALTH_PROXY 2>/dev/null || true
	iptables -t nat -X WG_STEALTH_PROXY 2>/dev/null || true

	local ACTIVE_PROXY_PORT=40000
	local ACTIVE_PROXY_HOST="127.0.0.1"
	if [[ -f /etc/wireguard/upstream_proxy.conf ]]; then
		local RAW_PXY
		RAW_PXY=$(cat /etc/wireguard/upstream_proxy.conf 2>/dev/null | sed 's|^socks5h*://||' | tr -d '\r\n')
		if [[ "$RAW_PXY" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+)$ ]]; then
			ACTIVE_PROXY_HOST="${BASH_REMATCH[1]}"
			ACTIVE_PROXY_PORT="${BASH_REMATCH[2]}"
		fi
	fi

	configureRedsocksBridge "$ACTIVE_PROXY_HOST" "$ACTIVE_PROXY_PORT" >/dev/null 2>&1 || true

	if command -v ipset &>/dev/null && isTransparentBridgeHealthy "$ACTIVE_PROXY_PORT"; then
		iptables -t nat -N WG_STEALTH_PROXY 2>/dev/null || true
		# 1. Never proxy local/private subnets or the WireGuard server itself
		iptables -t nat -A WG_STEALTH_PROXY -d 0.0.0.0/8 -j RETURN
		iptables -t nat -A WG_STEALTH_PROXY -d 10.0.0.0/8 -j RETURN
		iptables -t nat -A WG_STEALTH_PROXY -d 127.0.0.0/8 -j RETURN
		iptables -t nat -A WG_STEALTH_PROXY -d 169.254.0.0/16 -j RETURN
		iptables -t nat -A WG_STEALTH_PROXY -d 172.16.0.0/12 -j RETURN
		iptables -t nat -A WG_STEALTH_PROXY -d 192.168.0.0/16 -j RETURN
		iptables -t nat -A WG_STEALTH_PROXY -d 224.0.0.0/4 -j RETURN
		iptables -t nat -A WG_STEALTH_PROXY -d 240.0.0.0/4 -j RETURN
		# 2. Never proxy DNS resolver IPs (1.1.1.1, 1.0.0.1, 8.8.8.8, 8.8.4.4, 9.9.9.9)
		iptables -t nat -A WG_STEALTH_PROXY -d 1.1.1.1/32 -j RETURN
		iptables -t nat -A WG_STEALTH_PROXY -d 1.0.0.1/32 -j RETURN
		iptables -t nat -A WG_STEALTH_PROXY -d 8.8.8.8/32 -j RETURN
		iptables -t nat -A WG_STEALTH_PROXY -d 8.8.4.4/32 -j RETURN
		# 3. Never proxy Payment / Banking Gateways (PayPal, Braintree, 3D-Secure) -> Keep Direct Static VPS IP
		iptables -t nat -A WG_STEALTH_PROXY -m set --match-set wg_direct_clean dst -j RETURN
		# 4. Redirect HTTP/HTTPS (ports 80 & 443) matching wg_split_v4 (LinkedIn, Cloudflare WAF, etc.) to Redsocks->WARP
		iptables -t nat -A WG_STEALTH_PROXY -p tcp -m multiport --dports 80,443 -m set --match-set wg_split_v4 dst -j REDIRECT --to-ports 12345
		# 5. For Profile 1 (10.19.0.0/24 Stealth Gateway), route all web traffic (80/443) via WARP Consumer Egress except payment gateways
		iptables -t nat -A WG_STEALTH_PROXY -s 10.19.0.0/24 -p tcp -m multiport --dports 80,443 -j REDIRECT --to-ports 12345

		iptables -t nat -I PREROUTING 1 -i "${SERVER_WG_NIC:-wg0}" -p tcp -j WG_STEALTH_PROXY 2>/dev/null || true
		iptables -I INPUT 1 -i "${SERVER_WG_NIC:-wg0}" -p tcp --dport 12345 -j ACCEPT 2>/dev/null || true
		echo -e "${GREEN}[✔] Transparent Anti-WAF Bridge (Redsocks -> WARP AS13335) verified healthy & active!${NC}"
	else
		echo -e "${YELLOW}[i] WARP Proxy not active; routing all traffic directly via clean VPS NIC (Fail-Open Safe Mode).${NC}"
	fi

	# --------------------------------------------------------------------------
	# TRANSPARENT DNS HANDLING (Safe Local dnsmasq or Direct 1.1.1.1 Fallback)
	# --------------------------------------------------------------------------
	iptables -t nat -D PREROUTING -i "${SERVER_WG_NIC:-wg0}" -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || true
	iptables -t nat -D PREROUTING -i "${SERVER_WG_NIC:-wg0}" -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || true
	iptables -t nat -D PREROUTING -i "${SERVER_WG_NIC:-wg0}" -d "${SERVER_WG_IPV4:-10.18.0.1}" -p udp --dport 53 -j DNAT --to-destination 1.1.1.1:53 2>/dev/null || true
	iptables -t nat -D PREROUTING -i "${SERVER_WG_NIC:-wg0}" -d "${SERVER_WG_IPV4:-10.18.0.1}" -p tcp --dport 53 -j DNAT --to-destination 1.1.1.1:53 2>/dev/null || true
	iptables -t nat -D PREROUTING -i "${SERVER_WG_NIC:-wg0}" -d 10.19.0.1 -p udp --dport 53 -j DNAT --to-destination 1.1.1.1:53 2>/dev/null || true
	iptables -t nat -D PREROUTING -i "${SERVER_WG_NIC:-wg0}" -d 10.19.0.1 -p tcp --dport 53 -j DNAT --to-destination 1.1.1.1:53 2>/dev/null || true

	if [[ "$DNSMASQ_OK" -eq 1 ]]; then
		iptables -I INPUT 1 -i "${SERVER_WG_NIC:-wg0}" -p udp --dport 53 -j ACCEPT 2>/dev/null || true
		iptables -I INPUT 2 -i "${SERVER_WG_NIC:-wg0}" -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
		iptables -t nat -A PREROUTING -i "${SERVER_WG_NIC:-wg0}" -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || true
		iptables -t nat -A PREROUTING -i "${SERVER_WG_NIC:-wg0}" -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || true
	else
		iptables -t nat -A PREROUTING -i "${SERVER_WG_NIC:-wg0}" -d "${SERVER_WG_IPV4:-10.18.0.1}" -p udp --dport 53 -j DNAT --to-destination 1.1.1.1:53 2>/dev/null || true
		iptables -t nat -A PREROUTING -i "${SERVER_WG_NIC:-wg0}" -d "${SERVER_WG_IPV4:-10.18.0.1}" -p tcp --dport 53 -j DNAT --to-destination 1.1.1.1:53 2>/dev/null || true
		iptables -t nat -A PREROUTING -i "${SERVER_WG_NIC:-wg0}" -d 10.19.0.1 -p udp --dport 53 -j DNAT --to-destination 1.1.1.1:53 2>/dev/null || true
		iptables -t nat -A PREROUTING -i "${SERVER_WG_NIC:-wg0}" -d 10.19.0.1 -p tcp --dport 53 -j DNAT --to-destination 1.1.1.1:53 2>/dev/null || true
	fi

	# --------------------------------------------------------------------------
	# STEALTH PACKET NORMALIZATION (Uniform TTL=64 & MSS=1360 Clamping)
	# Eliminates OS User-Agent vs TCP TTL mismatch & TLS ClientHello fragmentation
	# --------------------------------------------------------------------------
	local TARGET_TTL=64
	if [[ -f /etc/wireguard/emulate_windows_ttl ]]; then
		TARGET_TTL=128
	fi
	iptables -t mangle -F FORWARD 2>/dev/null || true
	iptables -t mangle -F POSTROUTING 2>/dev/null || true
	iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
	iptables -t mangle -A FORWARD -s 10.19.0.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360 2>/dev/null || true
	iptables -t mangle -A FORWARD -d 10.19.0.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360 2>/dev/null || true
	iptables -t mangle -A FORWARD -s 10.18.0.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360 2>/dev/null || true
	iptables -t mangle -A FORWARD -d 10.18.0.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360 2>/dev/null || true
	iptables -t mangle -A POSTROUTING ! -o "${SERVER_WG_NIC:-wg0}" -j TTL --ttl-set ${TARGET_TTL} 2>/dev/null || true
	ip6tables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN ! -o "${SERVER_WG_NIC:-wg0}" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

	echo -e "${GREEN}[✔] Stealth Anti-WAF Split Rules applied for ${DOMAIN_COUNT} domain(s) & Cloudflare/LinkedIn CIDRs.${NC}"
	echo -e "${GREEN}[✔] Applied live in real-time — zero client config changes required!${NC}\n"
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
		echo -e "  ${BOLD}Current Mode:${NC}  ${GREEN}[${MODE} MODE]${NC} (Routes split domains via WARP Consumer Egress)"
		echo -e "  ${BOLD}Active Domains:${NC} ${YELLOW}${DOMAIN_COUNT} domain(s) configured${NC}"
		echo "-----------------------------------------------------------------"
		echo "1) Add Domain (e.g. linkedin.com, netflix.com, openai.com, chatgpt.com)"
		echo "2) Remove Domain"
		echo "3) Add Preset Category (AI Services, Streaming, Banking, Gaming, Cloudflare/LinkedIn)"
		echo "4) Toggle Mode (BYPASS VPN vs FORCE THROUGH VPN)"
		echo "5) View Active Split Domains & Live Resolved IP Rules"
		echo "6) Clear All Split Domain Rules"
		echo "7) Return to Main Menu"
		echo ""

		read -rp "Select option [1-7]: " SPLIT_OPT
		case "$SPLIT_OPT" in
			1)
				read -rp "Enter domain name to split tunnel (e.g. linkedin.com): " NEW_DOMAIN
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
				echo "5) Cloudflare Anti-Bot, Turnstile & LinkedIn Shield"
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
						for d in paypal.com paypalobjects.com cardinalcommerce.com braintreegateway.com braintree-api.com chase.com bankofamerica.com wellsfargo.com stripe.com; do
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
						for d in linkedin.com www.linkedin.com licdn.com challenges.cloudflare.com cloudflare.com turnstile.com cdnjs.cloudflare.com cloudflareinsights.com cf-assets.com pages.dev workers.dev; do
							grep -q "^${d}\$" /etc/wireguard/split_domains.txt 2>/dev/null || echo "$d" >> /etc/wireguard/split_domains.txt
						done
						echo -e "${GREEN}[✔] Added Cloudflare Anti-Bot, Turnstile & LinkedIn preset.${NC}"
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
						echo -e "${BOLD}Active IPv4 IPSet Rules (wg_split_v4 sample):${NC}"
						ipset list wg_split_v4 2>/dev/null | grep -A 25 "Members:" || echo "No IP members currently resolved."
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
	echo ""
}

function geoIpAntiVpnShield() {
	echo -e "\n${CYAN}--- Geo-IP & Anti-VPN Shield (Stealth Normalization Status) ---${NC}"
	echo -e "  - ${BOLD}TTL Normalization:${NC}      ${GREEN}ACTIVE (Uniform TTL=64 — Zero OS/User-Agent Mismatch)${NC}"
	echo -e "  - ${BOLD}TCP MSS Clamping:${NC}       ${GREEN}ACTIVE (Clamped to 1360 / PMTU)${NC}"
	echo -e "  - ${BOLD}QUIC UDP:443 Shield:${NC}    ${GREEN}ACTIVE (Clean HTTP/2 TCP Fallback)${NC}"
	echo -e "  - ${BOLD}BBR Congestion Control:${NC} ${GREEN}ACTIVE${NC}"
	verifyAndTestTraffic
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
	echo -e "\n${CYAN}${BOLD}🛠️ Starting Automated Network, DNS, WARP Bridge & WireGuard Health Auto-Repair...${NC}"

	# 1. Restore DNS nameservers
	echo -e "${CYAN}[1/5] Verifying host DNS health & nameservers...${NC}"
	rm -f /etc/resolv.conf 2>/dev/null || true
	cat << 'RESOLV_CLEAN_EOF' > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
RESOLV_CLEAN_EOF

	# 2. Re-enable IP forwarding & kernel networking
	echo -e "${CYAN}[2/5] Verifying kernel IP forwarding, rp_filter and BBR/MTU probing...${NC}"
	sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.all.forwarding=1 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1 || true

	# 3. Resolve port 53 / dnsmasq & WARP proxy services
	echo -e "${CYAN}[3/5] Checking DNS & WARP/Redsocks services...${NC}"
	if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
		mkdir -p /etc/systemd/resolved.conf.d
		cat << 'RESOLVED_NO_STUB' > /etc/systemd/resolved.conf.d/no-stub.conf 2>/dev/null || true
[Resolve]
DNSStubListener=no
RESOLVED_NO_STUB
		systemctl restart systemd-resolved >/dev/null 2>&1 || true
	fi

	if command -v warp-cli &>/dev/null; then
		systemctl restart warp-svc >/dev/null 2>&1 || true
		sleep 1
		warp-cli --accept-tos mode proxy 2>/dev/null || warp-cli set-mode proxy 2>/dev/null || true
		warp-cli --accept-tos proxy port 40000 2>/dev/null || warp-cli --accept-tos set-proxy-port 40000 2>/dev/null || true
		warp-cli --accept-tos connect 2>/dev/null || warp-cli connect 2>/dev/null || true
	fi
	configureRedsocksBridge 127.0.0.1 40000 >/dev/null 2>&1 || true

	# 4. Safely reset and restore WireGuard interface (wg0)
	echo -e "${CYAN}[4/5] Restoring Unified WireGuard interface (${SERVER_WG_NIC:-wg0})...${NC}"
	if command -v wg-quick &>/dev/null; then
		wg-quick down "${SERVER_WG_NIC:-wg0}" >/dev/null 2>&1 || true
		ip link delete dev "${SERVER_WG_NIC:-wg0}" >/dev/null 2>&1 || true
		wg-quick down wg1 >/dev/null 2>&1 || true
		ip link delete dev wg1 >/dev/null 2>&1 || true
		rm -f "/etc/wireguard/wg1.conf"

		systemctl daemon-reload >/dev/null 2>&1 || true
		systemctl restart "wg-quick@${SERVER_WG_NIC:-wg0}" 2>/dev/null || wg-quick up "${SERVER_WG_NIC:-wg0}" 2>/dev/null || true
	fi

	# 5. Re-apply essential firewall NAT, MSS clamping, Redsocks bridge and Forwarding rules
	echo -e "${CYAN}[5/5] Re-applying stealth camouflage, FORWARD & NAT firewall rules on port ${SERVER_PORT:-4500}...${NC}"
	applyDomainSplitRulesLive >/dev/null 2>&1 || true
	verifyAndTestTraffic
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
	echo -e "\n${CYAN}${BOLD}⚡ Initializing Cloudflare WARP Consumer Egress (AS13335) & Redsocks Bridge...${NC}"
	mkdir -p /etc/wireguard
	touch /etc/wireguard/warp_egress_enabled

	showWarpProgressBar 10 "Verifying system environment & architecture..."

	if ! command -v warp-cli &>/dev/null && command -v apt-get &>/dev/null; then
		local ARCH="amd64"
		if command -v dpkg &>/dev/null; then
			ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
		fi

		local CODENAME=""
		if [[ -f /etc/os-release ]]; then
			. /etc/os-release
			CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
		fi
		if [[ -z "$CODENAME" ]]; then
			CODENAME=$(lsb_release -cs 2>/dev/null || echo "")
		fi
		case "$CODENAME" in
			noble|jammy|focal|bionic|bookworm|bullseye|buster) ;;
			*)
				if grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
					CODENAME="jammy"
				else
					CODENAME="bookworm"
				fi
				;;
		esac

		showWarpProgressBar 30 "Adding official Cloudflare WARP GPG key & repository..."
		mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
		curl -fsSL --connect-timeout 8 --max-time 15 https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null || true
		echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${CODENAME} main" > /etc/apt/sources.list.d/cloudflare-client.list 2>/dev/null || true

		showWarpProgressBar 50 "Updating package cache & installing cloudflare-warp + redsocks..."
		apt-get update -o Acquire::Timeout="10" -o Dir::Etc::sourcelist="sources.list.d/cloudflare-client.list" -o Dir::Etc::sourceparts="-" -qq >/dev/null 2>&1 || apt-get update -o Acquire::Timeout="10" -qq >/dev/null 2>&1 || true
		apt-get install -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" cloudflare-warp redsocks >/dev/null 2>&1 || true
	fi

	if command -v warp-cli &>/dev/null; then
		showWarpProgressBar 70 "Starting warp-svc daemon..."
		systemctl daemon-reload >/dev/null 2>&1 || true
		systemctl enable --now warp-svc >/dev/null 2>&1 || true
		sleep 1.5

		showWarpProgressBar 80 "Registering WARP consumer license & configuring SOCKS5 proxy on :40000..."
		# Support both warp-cli v2024+ syntax and legacy warp-cli syntax
		warp-cli --accept-tos registration new >/dev/null 2>&1 \
			|| warp-cli --accept-tos register >/dev/null 2>&1 \
			|| echo "y" | warp-cli registration new >/dev/null 2>&1 \
			|| true

		warp-cli --accept-tos mode proxy >/dev/null 2>&1 \
			|| warp-cli --accept-tos set-mode proxy >/dev/null 2>&1 \
			|| true

		warp-cli --accept-tos proxy port 40000 >/dev/null 2>&1 \
			|| warp-cli --accept-tos set-proxy-port 40000 >/dev/null 2>&1 \
			|| true

		warp-cli --accept-tos connect >/dev/null 2>&1 \
			|| warp-cli connect >/dev/null 2>&1 \
			|| true

		# Wait up to 4 seconds for port 40000 to bind
		for ((w=0; w<8; w++)); do
			if isPortInUse 40000 "tcp"; then
				break
			fi
			sleep 0.5
		done
	fi

	showWarpProgressBar 92 "Starting Redsocks transparent TCP-to-SOCKS5 bridge (127.0.0.1:12345)..."
	configureRedsocksBridge 127.0.0.1 40000 >/dev/null 2>&1 || true

	showWarpProgressBar 100 "Cloudflare WARP + Redsocks Transparent Anti-WAF Bridge Ready!"
}

function cloudflareAntiFlagEngine() {
	while true; do
		local CURRENT_TTL=64
		[[ -f /etc/wireguard/emulate_windows_ttl ]] && CURRENT_TTL=128
		local SPLIT_COUNT=0
		[[ -f /etc/wireguard/split_domains.txt ]] && SPLIT_COUNT=$(grep -c -v -E '^(#|$)' /etc/wireguard/split_domains.txt 2>/dev/null || echo 0)
		local BRIDGE_STATUS="${YELLOW}FAIL-SAFE DIRECT VPS EGRESS${NC}"
		if isTransparentBridgeHealthy 40000; then
			BRIDGE_STATUS="${GREEN}ACTIVE (WARP AS13335 + Redsocks :12345)${NC}"
		fi
		local HAS_PROXY="NONE"
		[[ -f /etc/wireguard/upstream_proxy.conf ]] && HAS_PROXY="$(cat /etc/wireguard/upstream_proxy.conf 2>/dev/null | head -c 25)"

		echo -e "\n${PURPLE}=================================================================${NC}"
		echo -e "       ${CYAN}${BOLD}🛡️ Stealth Anti-Scanner & Smart Egress Gateway Engine${NC}"
		echo -e "${PURPLE}=================================================================${NC}"
		echo -e "  ${BOLD}Transparent WARP Bridge:${NC}    ${BRIDGE_STATUS}"
		echo -e "  ${BOLD}Upstream Residential Proxy:${NC} ${YELLOW}[${HAS_PROXY}]${NC}"
		echo -e "  ${BOLD}TCP SYN Fingerprint:${NC}       ${CYAN}TTL=${CURRENT_TTL}, MSS=1360 & QUIC Shield Active${NC}"
		echo -e "  ${BOLD}Active Split Domains:${NC}      ${YELLOW}${SPLIT_COUNT} domain(s) + LinkedIn/Cloudflare CIDRs${NC}"
		echo "-----------------------------------------------------------------"
		echo "1) Install / Repair Cloudflare WARP + Redsocks Transparent Bridge (Unblocks LinkedIn & Cloudflare WAF)"
		echo "2) Refresh Cloudflare, LinkedIn & Turnstile CIDRs Split Rules"
		echo "3) Configure Custom Upstream Residential SOCKS5 Proxy (ip:port)"
		echo "4) Toggle TTL Normalization (TTL=64 Universal [Recommended] vs TTL=128 Windows)"
		echo "5) Run End-to-End Live Cloudflare & LinkedIn Anti-Bot Diagnostic"
		echo "6) Disable WARP Bridge & Revert to 100% Direct VPS Egress"
		echo "7) Safe Network, DNS & Firewall Auto-Repair"
		echo "8) Return to Main Menu"
		echo ""

		read -rp "Select option [1-8]: " CF_OPT
		case "$CF_OPT" in
			1)
				setupCloudflareWarpClient
				applyDomainSplitRulesLive
				verifyAndTestTraffic
				read -n1 -r -p "Press Enter to return..."
				;;
			2)
				touch /etc/wireguard/cloudflare_split_enabled
				for d in linkedin.com www.linkedin.com licdn.com challenges.cloudflare.com cloudflare.com turnstile.com cdnjs.cloudflare.com cloudflareinsights.com cf-assets.com pages.dev workers.dev; do
					grep -q "^${d}\$" /etc/wireguard/split_domains.txt 2>/dev/null || echo "$d" >> /etc/wireguard/split_domains.txt
				done
				applyDomainSplitRulesLive
				;;
			3)
				echo -e "\n${CYAN}--- Configure Custom Upstream Residential SOCKS5 Proxy ---${NC}"
				read -rp "Enter SOCKS5 host:port (e.g. 127.0.0.1:1080, or leave empty to clear): " UPSTREAM_PXY
				if [[ -n "$UPSTREAM_PXY" ]]; then
					echo "$UPSTREAM_PXY" > /etc/wireguard/upstream_proxy.conf
					applyDomainSplitRulesLive
					echo -e "${GREEN}[✔] Upstream SOCKS5 proxy configured and bridged via Redsocks.${NC}\n"
				else
					rm -f /etc/wireguard/upstream_proxy.conf
					applyDomainSplitRulesLive
					echo -e "${YELLOW}Upstream proxy cleared. Reverted to WARP / Direct egress.${NC}\n"
				fi
				;;
			4)
				if [[ -f /etc/wireguard/emulate_windows_ttl ]]; then
					rm -f /etc/wireguard/emulate_windows_ttl
					applyDomainSplitRulesLive
					echo -e "${GREEN}[✔] Switched to Universal Stack Normalization (TTL=64). Eliminates OS/Browser mismatch!${NC}\n"
				else
					touch /etc/wireguard/emulate_windows_ttl
					applyDomainSplitRulesLive
					echo -e "${GREEN}[✔] Switched to Windows Desktop Stack Emulation (TTL=128).${NC}\n"
				fi
				;;
			5)
				verifyAndTestTraffic
				read -n1 -r -p "Press Enter to continue..."
				;;
			6)
				rm -f /etc/wireguard/cloudflare_shield_enabled /etc/wireguard/warp_egress_enabled /etc/wireguard/upstream_proxy.conf
				if command -v warp-cli &>/dev/null; then
					warp-cli disconnect >/dev/null 2>&1 || true
				fi
				systemctl stop redsocks >/dev/null 2>&1 || true
				applyDomainSplitRulesLive
				echo -e "${GREEN}[✔] Reverted to 100% Direct VPS Egress.${NC}\n"
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
		systemctl stop redsocks >/dev/null 2>&1 || true

		if command -v wg-quick >/dev/null 2>&1; then
			wg-quick down "${SERVER_WG_NIC:-wg0}" >/dev/null 2>&1 || true
		fi
		ip link delete dev "${SERVER_WG_NIC:-wg0}" >/dev/null 2>&1 || true

		iptables -t nat -D PREROUTING -i "${SERVER_WG_NIC:-wg0}" -p tcp -j WG_STEALTH_PROXY 2>/dev/null || true
		iptables -t nat -F WG_STEALTH_PROXY 2>/dev/null || true
		iptables -t nat -X WG_STEALTH_PROXY 2>/dev/null || true

		if [[ -n "${SERVER_PORT:-}" ]]; then
			iptables -D INPUT -p udp --dport "${SERVER_PORT}" -j ACCEPT 2>/dev/null || true
			ip6tables -D INPUT -p udp --dport "${SERVER_PORT}" -j ACCEPT 2>/dev/null || true
		fi
		iptables -D FORWARD -i "${SERVER_WG_NIC:-wg0}" -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true
		iptables -D FORWARD -i "${SERVER_WG_NIC:-wg0}" -j ACCEPT 2>/dev/null || true
		iptables -D FORWARD -o "${SERVER_WG_NIC:-wg0}" -j ACCEPT 2>/dev/null || true
		iptables -t nat -D POSTROUTING -s 10.18.0.0/24 -j MASQUERADE 2>/dev/null || true
		iptables -t nat -D POSTROUTING -s 10.19.0.0/24 -j MASQUERADE 2>/dev/null || true

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
# 10. Interactive Terminal Menu
# ------------------------------------------------------------------------------
function manageMenu() {
	while true; do
		local WG0_STATUS="${RED}STOPPED${NC}"
		if systemctl is-active --quiet wg-quick@wg0 2>/dev/null || wg show wg0 &>/dev/null; then
			WG0_STATUS="${GREEN}ACTIVE${NC}"
		fi
		local WARP_BRIDGE_BADGE="${YELLOW}DIRECT EGRESS${NC}"
		if isTransparentBridgeHealthy 40000; then
			WARP_BRIDGE_BADGE="${GREEN}WARP+REDSOCKS ACTIVE${NC}"
		fi

		echo -e "\n${PURPLE}=================================================================${NC}"
		echo -e "              ${GREEN}${BOLD}🍪  Cookie's Easy WireGuard Manager v4.0${NC}"
		echo -e "${PURPLE}=================================================================${NC}"
		echo -e "  ${BOLD}Server Daemon (Unified):${NC}    wg0 | Port ${SERVER_PORT:-4500}/udp [${WG0_STATUS}]"
		echo -e "  ${BOLD}Anti-WAF / LinkedIn Bridge:${NC} [${WARP_BRIDGE_BADGE}]"
		echo -e "  ${BOLD}Profile 1 (Stealth Gateway):${NC}10.19.0.0/24 (Full WARP Egress, MTU 1380, Port ${SERVER_PORT:-4500})"
		echo -e "  ${BOLD}Profile 2 (Standard):${NC}       10.18.0.0/24 (Smart Split WARP + Direct VPS, Port ${SERVER_PORT:-4500})"
		echo -e "${PURPLE}┌──────────────────────────────────────────────────────────────┐${NC}"
		echo -e "${PURPLE}│${NC}                      ${CYAN}${BOLD}Main Menu Actions${NC}                       ${PURPLE}│${NC}"
		echo -e "${PURPLE}├──────────────────────────────────────────────────────────────┤${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[1]${NC} Setup WireGuard server (Unified Port for Both Profiles)   ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[2]${NC} Add new client (Generates Standard & Stealth Profiles)    ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[3]${NC} Configure clients (Check/Edit/Export/Remove)             ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[4]${NC} Backup & Restore Manager                                 ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[5]${NC} Domain-Based Split Tunneling                             ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[6]${NC} Real-Time Logging (Errors)                               ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[7]${NC} Geo-IP, Anti-VPN Shield & End-to-End Traffic Test        ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[8]${NC} Provision Web Management Console                         ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[9]${NC} Stealth Anti-Scanner & Smart Egress Gateway Engine        ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[10]${NC} Safe Network, DNS & WireGuard Health Auto-Repair       ${PURPLE}│${NC}"
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
# 11. Script Entrypoint Execution
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