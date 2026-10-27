#!/bin/bash
# ==============================================================================
# 🍪 Cookie's Easy WireGuard Manager & VPS Stealth Server v4.2 (Production Stable)
# Fail-Safe Anti-Detect Egress, Transparent WARP Bridge & Multi-Gigabit Tuning
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
# 2b. Hardware NIC Offloading & High-Speed Network Tuning
# ------------------------------------------------------------------------------
function optimizeNetworkThroughput() {
	local PUB_NIC="${1:-${SERVER_PUB_NIC:-}}"
	if [[ -z "$PUB_NIC" ]]; then
		PUB_NIC=$(ip -4 route show default 2>/dev/null | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | head -n1 || echo "eth0")
	fi
	local WG_NIC="${SERVER_WG_NIC:-wg0}"

	ip link set dev "$PUB_NIC" txqueuelen 10000 2>/dev/null || true
	ip link set dev "$WG_NIC" txqueuelen 10000 2>/dev/null || true

	if command -v ethtool &>/dev/null; then
		ethtool -K "$PUB_NIC" gro on gso on tso on 2>/dev/null || true
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

	# Clean transparent proxy chains
	iptables -t nat -D PREROUTING -i wg0 -p tcp -j WG_STEALTH_PROXY 2>/dev/null || true
	iptables -t nat -F WG_STEALTH_PROXY 2>/dev/null || true
	iptables -t nat -X WG_STEALTH_PROXY 2>/dev/null || true

	# Clean DNS redirects
	iptables -t nat -D PREROUTING -i wg0 -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || true
	iptables -t nat -D PREROUTING -i wg0 -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || true

	# Surgical rule cleanup
	iptables -D FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
	iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
	iptables -D FORWARD -o wg0 -j ACCEPT 2>/dev/null || true
	iptables -t nat -D POSTROUTING -s 10.18.0.0/24 -j MASQUERADE 2>/dev/null || true
	iptables -t nat -D POSTROUTING -s 10.19.0.0/24 -j MASQUERADE 2>/dev/null || true

	echo -e "${GREEN}[✔] Cleaned old WireGuard instances. Sensitive web & SSH ports protected.${NC}"
}

# ------------------------------------------------------------------------------
# 3. DNS Resolvers Selection Menu
# ------------------------------------------------------------------------------
function selectDNSResolvers() {
	echo -e "\n${CYAN}${BOLD}Select DNS Resolvers for Clients:${NC}"
	echo -e "   1) ${GREEN}Cloudflare Anycast Anti-Flag${NC} (Global Anycast | Ultra Fast) ${PURPLE}[RECOMMENDED]${NC}"
	echo -e "      IPv4: 1.1.1.1, 1.0.0.1  |  IPv6: 2606:4700:4700::1111, 2606:4700:4700::1001"
	echo -e "   2) ${GREEN}AdGuard Stealth${NC} (Global Anycast | Anti-Ad & Anti-Tracker)"
	echo -e "      IPv4: 94.140.14.14, 94.140.15.15"
	echo -e "   3) ${GREEN}Google Public DNS${NC} (Global Anycast | High Uptime)"
	echo -e "      IPv4: 8.8.8.8, 8.8.4.4"
	echo -e "   4) Custom Primary & Secondary DNS Resolvers"

	read -rp "Select DNS option [1-4, default 1]: " DNS_OPTION
	DNS_OPTION=${DNS_OPTION:-1}
	case "${DNS_OPTION}" in
		2)
			CLIENT_DNS_1="94.140.14.14"
			CLIENT_DNS_2="94.140.15.15"
			;;
		3)
			CLIENT_DNS_1="8.8.8.8"
			CLIENT_DNS_2="8.8.4.4"
			;;
		4)
			read -rp "Enter Primary DNS (IPv4): " -e -i "1.1.1.1" CLIENT_DNS_1
			read -rp "Enter Secondary DNS (IPv4): " -e -i "1.0.0.1" CLIENT_DNS_2
			;;
		1|*)
			CLIENT_DNS_1="1.1.1.1"
			CLIENT_DNS_2="1.0.0.1"
			;;
	esac
	echo -e "${GREEN}[✔] Selected DNS: ${CLIENT_DNS_1}, ${CLIENT_DNS_2}${NC}"
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
	echo -e "   1) ${GREEN}4500${NC}  (IPsec NAT-Traversal UDP | Stealth Encrypted Tunneling) ${PURPLE}[RECOMMENDED]${NC}"
	echo -e "   2) ${GREEN}3478${NC}  (STUN / WebRTC Media UDP | Media Pass-Through)"
	echo -e "   3) ${GREEN}51820${NC} (Official WireGuard Standard Port)"
	echo -e "   4) Custom Port (e.g. 8008)"

	while true; do
		read -rp "Select Port option [1-4, default 1 (4500)]: " PORT_OPTION
		PORT_OPTION=${PORT_OPTION:-1}

		if [[ "$PORT_OPTION" =~ ^[0-9]+$ ]] && [[ "$PORT_OPTION" -ge 1024 && "$PORT_OPTION" -le 65535 ]]; then
			if isSensitivePort "$PORT_OPTION"; then
				echo -e "${RED}[!] Port ${PORT_OPTION} is a sensitive service port. Please choose a safe port.${NC}"
				continue
			fi
			SERVER_PORT="$PORT_OPTION"
			break
		fi

		case "${PORT_OPTION}" in
			1) SERVER_PORT=4500 ; break ;;
			2) SERVER_PORT=3478 ; break ;;
			3) SERVER_PORT=51820 ; break ;;
			4)
				read -rp "Enter Custom WireGuard Port [1024-65535]: " -e -i "8008" CUSTOM_PORT
				SERVER_PORT="$CUSTOM_PORT"
				break
				;;
			*)
				echo -e "${RED}[!] Invalid option. Enter 1-4.${NC}"
				continue
				;;
		esac
	done

	SERVER_PORT_CF="${SERVER_PORT}"
	echo -e "${GREEN}[✔] WireGuard Port Confirmed: ${SERVER_PORT}/udp${NC}"

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
		echo -e "${GREEN}[✔] Client Encryption Password confirmed!${NC}\n"
		break
	done

	read -rp "Allowed IPs for generated clients: " -e -i "0.0.0.0/0" ALLOWED_IPS

	CF_AUTO_ENABLE="y"
	WEB_PORT=${WEB_PORT:-51821}

	echo -e "\n${GREEN}Setup parameters configured successfully.${NC}"
	read -n1 -r -p "Press any key to start WireGuard installation..."
	echo ""
}

# ------------------------------------------------------------------------------
# 5. Transparent Redsocks + WARP SOCKS5 Bridge Engine
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

	# Strictly valid redsocks syntax (NO invalid custom directives)
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
	ip = ${PROXY_IP};
	port = ${PROXY_PORT};
	type = socks5;
}
REDSOCKS_EOF

	mkdir -p /etc/systemd/system/redsocks.service.d
	cat << 'OVERRIDE_EOF' > /etc/systemd/system/redsocks.service.d/override.conf
[Service]
Restart=always
RestartSec=2
LimitNOFILE=65535
OVERRIDE_EOF

	systemctl daemon-reload >/dev/null 2>&1 || true
	systemctl enable redsocks >/dev/null 2>&1 || true
	systemctl restart redsocks >/dev/null 2>&1 || true
	return 0
}

# Checks if local SOCKS5 proxy + redsocks are both alive and able to pass traffic
function isTransparentProxyHealthy() {
	local PROXY_PORT="${1:-40000}"
	if ! command -v redsocks &>/dev/null; then
		return 1
	fi
	if ! systemctl is-active --quiet redsocks 2>/dev/null; then
		return 1
	fi
	if ! isPortInUse 12345 "tcp"; then
		return 1
	fi
	if ! isPortInUse "$PROXY_PORT" "tcp"; then
		return 1
	fi
	return 0
}

# Installs a background systemd timer to verify WARP SOCKS5 + Redsocks stay connected 24/7
function installWarpWatchdog() {
	cat << 'WATCHDOG_SCRIPT' > /usr/local/bin/wg-warp-watchdog.sh
#!/bin/bash
if [[ ! -f /etc/wireguard/warp_egress_enabled ]]; then
	exit 0
fi

if command -v warp-cli &>/dev/null; then
	if ! systemctl is-active --quiet warp-svc 2>/dev/null; then
		systemctl restart warp-svc 2>/dev/null || true
		sleep 2
	fi

	if ! ss -tln 2>/dev/null | grep -qE "(:|\])40000\s"; then
		warp-cli --accept-tos proxy port 40000 2>/dev/null || warp-cli --accept-tos set-proxy-port 40000 2>/dev/null || warp-cli set-proxy-port 40000 2>/dev/null || true
		warp-cli --accept-tos mode proxy 2>/dev/null || warp-cli --accept-tos set-mode proxy 2>/dev/null || warp-cli set-mode proxy 2>/dev/null || true
		warp-cli --accept-tos connect 2>/dev/null || warp-cli connect 2>/dev/null || true
		sleep 2
	fi
fi

if command -v redsocks &>/dev/null; then
	if ! systemctl is-active --quiet redsocks 2>/dev/null || ! ss -tln 2>/dev/null | grep -qE "(:|\])12345\s"; then
		systemctl restart redsocks 2>/dev/null || true
	fi
fi
WATCHDOG_SCRIPT
	chmod +x /usr/local/bin/wg-warp-watchdog.sh

	cat << 'WATCHDOG_SVC' > /etc/systemd/system/wg-warp-watchdog.service
[Unit]
Description=Cloudflare WARP & Redsocks Transparent Bridge Watchdog
After=network.target warp-svc.service redsocks.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wg-warp-watchdog.sh
WATCHDOG_SVC

	cat << 'WATCHDOG_TIMER' > /etc/systemd/system/wg-warp-watchdog.timer
[Unit]
Description=Run Cloudflare WARP Watchdog every 60 seconds

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
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

	echo -e "\n${CYAN}[*] Installing dependencies (wireguard, dnsmasq, redsocks, ipset, ethtool, qrencode)...${NC}"

	for i in {1..10}; do
		if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
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
		apt-get update -y -q || true
		apt-get install -y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
			wireguard wireguard-tools iptables qrencode curl jq iproute2 iptables-persistent net-tools ipset dnsmasq redsocks lsb-release gnupg ethtool dnsutils ca-certificates || true
	elif [[ "${OS}" == "fedora" || "${OS}" == "centos" || "${OS}" == "almalinux" || "${OS}" == "rocky" ]]; then
		yum install -y wireguard-tools iptables qrencode curl jq ipset dnsmasq redsocks ethtool bind-utils || true
	elif [[ "${OS}" == "arch" ]]; then
		pacman -S --needed --noconfirm wireguard-tools qrencode iptables curl jq ipset dnsmasq redsocks ethtool bind || true
	elif [[ "${OS}" == "alpine" ]]; then
		apk update && apk add wireguard-tools iptables libqrencode-tools curl jq ipset dnsmasq redsocks ethtool bind-tools || true
	fi

	# Ensure host resolv.conf always maintains clean, operational Anycast nameservers
	rm -f /etc/resolv.conf 2>/dev/null || true
	cat << 'RESOLV_INIT' > /etc/resolv.conf 2>/dev/null || true
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
RESOLV_INIT

	if ! command -v wg &>/dev/null; then
		echo -e "${RED}[ERROR] WireGuard installation failed. 'wg' tool not found.${NC}"
		exit 1
	fi

	echo -e "${CYAN}[*] Loading WireGuard and BBR kernel modules...${NC}"
	modprobe wireguard >/dev/null 2>&1 || true
	modprobe iptable_nat >/dev/null 2>&1 || true
	modprobe iptable_mangle >/dev/null 2>&1 || true
	modprobe ip6table_nat >/dev/null 2>&1 || true
	modprobe nf_conntrack >/dev/null 2>&1 || true
	modprobe tcp_bbr >/dev/null 2>&1 || true

	local HAS_IPV6=0
	if [[ -f /proc/net/if_inet6 ]] && [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1) -eq 0 ]]; then
		if ip -6 route show default 2>/dev/null | grep -q "default" && ping6 -c 1 -W 2 2606:4700:4700::1111 >/dev/null 2>&1; then
			HAS_IPV6=1
		fi
	fi

	echo -e "${CYAN}[*] Applying BBR, IP Forwarding & High-Speed Network sysctl rules...${NC}"
	SYSCTL_CONF="/etc/sysctl.d/99-wireguard-stealth.conf"
	cat << 'SYSCTL_EOF' > "$SYSCTL_CONF"
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.route_localnet = 1
net.ipv4.conf.default.route_localnet = 1

net.core.default_qdisc = fq
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 8388608
net.core.wmem_default = 8388608
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.netdev_max_backlog = 100000
net.ipv4.tcp_max_syn_backlog = 3240000
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1

net.netfilter.nf_conntrack_max = 524288
SYSCTL_EOF

	if [[ "${HAS_IPV6}" -eq 1 ]]; then
		cat << 'SYSCTL_V6_EOF' >> "$SYSCTL_CONF"
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.all.forwarding = 1
SYSCTL_V6_EOF
	else
		echo "net.ipv6.conf.all.forwarding = 0" >> "$SYSCTL_CONF"
	fi

	if lsmod 2>/dev/null | grep -q bbr || grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
		echo "net.ipv4.tcp_congestion_control = bbr" >> "$SYSCTL_CONF"
	fi

	sysctl --system -q >/dev/null 2>&1 || sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || true

	if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
		ufw allow "${SERVER_PORT}/udp" >/dev/null 2>&1 || true
		ufw allow "${WEB_PORT:-51821}/tcp" >/dev/null 2>&1 || true
		if [ -f /etc/default/ufw ]; then
			sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw 2>/dev/null || true
		fi
		ufw reload >/dev/null 2>&1 || true
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

	touch /etc/wireguard/emulate_windows_ttl

	echo -e "${CYAN}[*] Configuring Unified WireGuard Server (wg0 | Port ${SERVER_PORT}/udp)...${NC}"
	cat << WG_SERVER_EOF > "/etc/wireguard/wg0.conf"
[Interface]
Address = ${WG_SERVER_ADDRESS}, 10.19.0.1/24
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PRIV_KEY}
MTU = 1420
SaveConfig = false

# --- 1. CORE NETWORKING & FIREWALL ---
PostUp = sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
PostUp = sysctl -w net.ipv4.conf.all.rp_filter=0 2>/dev/null || true
PostUp = sysctl -w net.ipv4.conf.default.rp_filter=0 2>/dev/null || true
PostUp = ip link set dev wg0 txqueuelen 10000 2>/dev/null || true
PostUp = iptables -I INPUT 1 -p udp --dport ${SERVER_PORT} -j ACCEPT 2>/dev/null || true
PostUp = iptables -I INPUT 2 -i wg0 -p udp --dport 53 -j ACCEPT 2>/dev/null || true
PostUp = iptables -I INPUT 3 -i wg0 -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
PostUp = iptables -I FORWARD 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
PostUp = iptables -I FORWARD 2 -i wg0 -j ACCEPT 2>/dev/null || true
PostUp = iptables -I FORWARD 3 -o wg0 -j ACCEPT 2>/dev/null || true
PostUp = iptables -t nat -I POSTROUTING 1 -s 10.18.0.0/24 ! -o wg0 -j MASQUERADE 2>/dev/null || true
PostUp = iptables -t nat -I POSTROUTING 2 -s 10.19.0.0/24 ! -o wg0 -j MASQUERADE 2>/dev/null || true

# --- 2. TCP MSS CLAMPING & TTL NORMALIZATION ---
PostUp = iptables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostUp = iptables -t mangle -I POSTROUTING 1 -p tcp --tcp-flags SYN,RST SYN ! -o wg0 -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostUp = iptables -t mangle -I POSTROUTING 2 -s 10.19.0.0/24 ! -o wg0 -j TTL --ttl-set 128 2>/dev/null || true

# Teardown Rules
PostDown = iptables -D INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT 2>/dev/null || true
PostDown = iptables -D INPUT -i wg0 -p udp --dport 53 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D INPUT -i wg0 -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s 10.18.0.0/24 ! -o wg0 -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s 10.19.0.0/24 ! -o wg0 -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostDown = iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN ! -o wg0 -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostDown = iptables -t mangle -D POSTROUTING -s 10.19.0.0/24 ! -o wg0 -j TTL --ttl-set 128 2>/dev/null || true
WG_SERVER_EOF

	chmod 600 "/etc/wireguard/wg0.conf"
	rm -f "/etc/wireguard/wg1.conf"

	wg-quick down wg0 >/dev/null 2>&1 || true
	ip link delete dev wg0 >/dev/null 2>&1 || true
	systemctl stop "wg-quick@wg0" >/dev/null 2>&1 || true

	systemctl daemon-reload >/dev/null 2>&1 || true
	systemctl enable "wg-quick@wg0" >/dev/null 2>&1 || true
	systemctl restart "wg-quick@wg0" 2>/dev/null || wg-quick up wg0 2>/dev/null || true

	optimizeNetworkThroughput "${SERVER_PUB_NIC}"

	if systemctl is-active --quiet "wg-quick@wg0" || wg show wg0 &>/dev/null; then
		echo -e "${GREEN}[✔] Unified WireGuard Server (wg0 | Port ${SERVER_PORT}/udp) is ACTIVE!${NC}"
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

# AI & Search Engines
openai.com
chatgpt.com
oaistatic.com
oaiusercontent.com
claude.ai
anthropic.com
perplexity.ai
google.com
www.google.com

# Social & Streaming Platforms
reddit.com
www.reddit.com
redd.it
redditmedia.com
x.com
twitter.com
instagram.com
tiktok.com
netflix.com

# Amazon Global Storefronts & CloudFront
amazon.com
www.amazon.com
completion.amazon.com
images-amazon.com
media-amazon.com
ssl-images-amazon.com
fls-na.amazon.com
aax.amazon-adsystem.com
amazon.co.uk
amazon.ca
amazon.de
cloudfront.net

# LinkedIn Professional Network & Media CDN
linkedin.com
www.linkedin.com
licdn.com
media.licdn.com
static.licdn.com
lnkd.in
platform.linkedin.com
voyager.linkedin.com
api.linkedin.com
dms.licdn.com

# IP / Fraud / WebRTC Scanners
ipinfo.io
ifconfig.me
ifconfig.co
icanhazip.com
ipify.org
api.ipify.org
wtfismyip.com
ip-api.com
ipapi.co
whoer.net
browserleaks.com
scamalytics.com
ipqualityscore.com
pixelscan.net
creepjs.com

# PayPal & Payment Gateways (Protected via wg_direct_clean)
paypal.com
www.paypal.com
paypalobjects.com
cardinalcommerce.com
braintreegateway.com
stripe.com
CF_INIT_DOMAINS

		setupCloudflareWarpClient
		installWarpWatchdog
		applyDomainSplitRulesLive

		echo -e "${GREEN}[✔] Cloudflare Anti-Flag Shield & WARP Scanner Cloak configured!${NC}"
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
	fi
}

# ------------------------------------------------------------------------------
# 7. Automated Traffic, Egress & Scanner Verification Self-Test
# ------------------------------------------------------------------------------
function verifyServerTrafficHealth() {
	echo -e "\n${CYAN}${BOLD}🔍 Running Automated Post-Install Traffic Verification...${NC}"

	if wg show "${SERVER_WG_NIC:-wg0}" &>/dev/null; then
		echo -e "  ${GREEN}[✔] WireGuard Kernel Interface (${SERVER_WG_NIC:-wg0}):${NC} UP & Listening on UDP ${SERVER_PORT:-4500}"
	else
		echo -e "  ${YELLOW}[!] WireGuard Interface (${SERVER_WG_NIC:-wg0}) was down. Restarting...${NC}"
		wg-quick up "${SERVER_WG_NIC:-wg0}" 2>/dev/null || true
	fi

	local FWD_VAL
	FWD_VAL=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)
	if [[ "$FWD_VAL" -eq 1 ]]; then
		echo -e "  ${GREEN}[✔] Kernel IPv4 Forwarding:${NC} ENABLED"
	else
		sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
		echo -e "  ${GREEN}[✔] Kernel IPv4 Forwarding:${NC} Forced ENABLED"
	fi

	if curl -4 -sSf --max-time 4 https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then
		echo -e "  ${GREEN}[✔] Direct VPS Egress (Standard Profile):${NC} ONLINE"
	else
		echo -e "  ${RED}[!] Warning: Host direct HTTP egress check timed out.${NC}"
	fi

	if isTransparentProxyHealthy 40000; then
		local WARP_TRACE
		WARP_TRACE=$(curl -4 -x socks5h://127.0.0.1:40000 -sSf --max-time 6 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
		if echo "$WARP_TRACE" | grep -q "warp=on"; then
			local WARP_IP
			WARP_IP=$(echo "$WARP_TRACE" | grep "^ip=" | cut -d'=' -f2)
			echo -e "  ${GREEN}[✔] Transparent WARP Bridge (Stealth Profile):${NC} ACTIVE (WARP IP: ${WARP_IP} | warp=on)"
		fi
	else
		echo -e "  ${YELLOW}[i] Transparent WARP Bridge:${NC} Standby (Direct VPS Egress Active with Fail-Safe)"
	fi
}

# ------------------------------------------------------------------------------
# 8. Provision Web Management Console Runtime
# ------------------------------------------------------------------------------
function provisionWebConsole() {
	echo -e "\n${CYAN}[*] Setting up Web Management Console...${NC}"
	if [[ -z "${ADMIN_PASSKEY:-}" ]]; then
		ADMIN_PASSKEY=$(tr -dc 'A-Za-z0-9!@#$%^&*' < /dev/urandom | head -c 24)
	fi

	cat << ENV_EOF > /etc/wireguard/manager.env
SERVER_PUBLIC_IP="${SERVER_PUB_IP:-127.0.0.1}"
WG_DEFAULT_PORT="${SERVER_PORT:-4500}"
WEB_PORT="${WEB_PORT:-51821}"
ADMIN_PASSKEY="${ADMIN_PASSKEY}"
ENV_EOF
	chmod 600 /etc/wireguard/manager.env

	if ! command -v node >/dev/null 2>&1; then
		apt-get update -y -q >/dev/null 2>&1 || true
		apt-get install -y -q nodejs npm git >/dev/null 2>&1 || true
	fi

	mkdir -p /opt/cbwireguard
	git clone https://github.com/cookiebaits/cbwireguard-v2.git /opt/cbwireguard 2>/dev/null || true

	cd /opt/cbwireguard
	npm install --omit=dev --no-audit --no-fund --legacy-peer-deps >/dev/null 2>&1 || true

	cat << SERVICE_EOF > /etc/systemd/system/cbwireguard-web.service
[Unit]
Description=Cookie WireGuard Web Management Console
After=network.target wg-quick@${SERVER_WG_NIC:-wg0}.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/cbwireguard
EnvironmentFile=/etc/wireguard/manager.env
ExecStart=/usr/bin/npm start
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE_EOF

	systemctl daemon-reload
	systemctl enable cbwireguard-web >/dev/null 2>&1 || true
	systemctl restart cbwireguard-web >/dev/null 2>&1 || true
	echo -e "${GREEN}[✔] Web Management Console active on port ${WEB_PORT:-51821}${NC}"
}

# ------------------------------------------------------------------------------
# 9. Client Management Logic (Fail-Safe DNS & Standard .conf Output)
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
	if [[ "${HAS_IPV6:-0}" -eq 1 ]] && grep -q "fd42:42:42::" "/etc/wireguard/wg0.conf" 2>/dev/null; then
		HAS_SERVER_IPV6=1
	fi

	local CLIENT_ADDRESS="${CLIENT_WG_IPV4}/32"
	local PEER_ALLOWED_IPS="${CLIENT_WG_IPV4}/32"
	if [[ "${HAS_SERVER_IPV6}" -eq 1 ]]; then
		CLIENT_ADDRESS="${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128"
		PEER_ALLOWED_IPS="${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128"
	fi

	# FAIL-SAFE DNS: Always include standard public DNS so clients never freeze
	local CLIENT_DNS_LINE="${CLIENT_DNS_1:-1.1.1.1}, ${CLIENT_DNS_2:-1.0.0.1}"

	local EASY_DIR
	EASY_DIR=$(getEasyWgDir "${CLIENT_NAME}")

	local STD_ALLOWED_IPS="0.0.0.0/0"
	if [[ "${HAS_SERVER_IPV6}" -eq 1 ]]; then
		STD_ALLOWED_IPS="0.0.0.0/0, ::/0"
	fi

	local CF_ALLOWED_IPS_LINE="0.0.0.0/0"

	# Profile 1: Stealth Gateway (10.19.0.x | MTU: 1380)
	local CF_CONF_CONTENT
	CF_CONF_CONTENT=$(cat << CF_CLIENT_EOF
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

	# Profile 2: Standard Full Tunnel (10.18.0.x | MTU: 1420)
	local STD_CONF_CONTENT
	STD_CONF_CONTENT=$(cat << CLIENT_EOF
[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_ADDRESS}
DNS = ${CLIENT_DNS_LINE}
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
	echo -e "   • Port: ${SERVER_PORT}/udp"
	echo -e "   • Profile 1 (Stealth):  ${CLIENT_WG_CF_IPV4} (WARP Egress)"
	echo -e "   • Profile 2 (Standard): ${CLIENT_WG_IPV4} (Direct VPS Egress)\n"

	echo -e "${CYAN}${BOLD}📋 Profile 1 Configuration (Stealth Gateway):${NC}"
	echo "$CF_CONF_CONTENT"
	echo ""

	echo -e "${GREEN}${BOLD}📋 Profile 2 Configuration (Standard Full Tunnel):${NC}"
	echo "$STD_CONF_CONTENT"
	echo ""
}

function newClient() {
	echo -e "\n${CYAN}--- Add a New WireGuard Client ---${NC}"
	local CLIENT_NAME=""
	until [[ -n "$CLIENT_NAME" && "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; do
		read -rp "Enter client device name: " CLIENT_NAME
		CLIENT_NAME=$(echo "$CLIENT_NAME" | tr -cd '[:alnum:]_-')
		if grep -q "### Client ${CLIENT_NAME}" "/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf" 2>/dev/null; then
			echo -e "${ORANGE}Client already exists! Choose another.${NC}"
			CLIENT_NAME=""
		fi
	done

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
			echo -e "${RED}[!] Passwords do not match.${NC}"
			continue
		fi
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

	echo -e "${BOLD}Client Name\t\tStandard IP\t\tStealth IP${NC}"
	echo "------------------------------------------------------------------------"
	for name in "${CLIENT_LIST[@]}"; do
		local std_ip cf_ip
		std_ip=$(grep -A 5 "### Client ${name} \[Standard Profile" "$CONF_FILE" 2>/dev/null | grep "AllowedIPs" | awk '{print $3}' | cut -d',' -f1)
		cf_ip=$(grep -A 5 "### Client ${name} \[Cloudflare Anti-Flag" "$CONF_FILE" 2>/dev/null | grep "AllowedIPs" | awk '{print $3}' | cut -d',' -f1)
		echo -e "   - ${BOLD}${name}${NC}\t\t${std_ip:-N/A}\t\t${cf_ip:-N/A}"
	done
	echo ""
}

function configureClients() {
	echo -e "\n${CYAN}--- Configure Clients ---${NC}"
	echo "1) View Client QR Code & Configuration"
	echo "2) Export / Decrypt Client Configuration"
	echo "3) Clean Root Directory & Re-Encrypt All Configs"
	echo "4) Remove / Revoke a Client"
	echo "5) Back to Main Menu"

	read -rp "Select an option [1-5]: " SUB_OPT
	case "$SUB_OPT" in
		1) showClientQr ;;
		2) exportDecryptedClientConfig ;;
		3) cleanupAndSecureRootFolder ;;
		4) revokeClient ;;
		5|*) return ;;
	esac
}

function showClientQr() {
	local CONF_FILE="/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf"
	local CLIENT_LIST=()
	while IFS= read -r cname; do
		[[ -n "$cname" ]] && CLIENT_LIST+=("$cname")
	done < <(grep -E "^### Client" "$CONF_FILE" 2>/dev/null | awk '{print $3}' | sort -u)

	local CLIENT_COUNT=${#CLIENT_LIST[@]}
	if [[ ${CLIENT_COUNT} -eq 0 ]]; then
		echo -e "${YELLOW}No clients registered.${NC}\n"
		return
	fi

	for i in "${!CLIENT_LIST[@]}"; do
		echo "  $((i+1))) ${CLIENT_LIST[$i]}"
	done
	read -rp "Select client [1-${CLIENT_COUNT}]: " CLIENT_NUMBER
	local TARGET_CLIENT="${CLIENT_LIST[$((CLIENT_NUMBER-1))]}"
	local EASY_DIR
	EASY_DIR=$(getEasyWgDir "${TARGET_CLIENT}")

	read -s -rp "Enter decryption password for '${TARGET_CLIENT}': " ATTEMPT_PASS
	echo ""

	local STD_TEXT="" CF_TEXT=""
	local CONF_CF_ENC="${EASY_DIR}/${TARGET_CLIENT}-cloudflare-shield.conf.enc"
	local CONF_STD_ENC="${EASY_DIR}/${TARGET_CLIENT}-standard.conf.enc"

	[[ -f "$CONF_CF_ENC" ]] && CF_TEXT=$(decryptConfigToString "$CONF_CF_ENC" "$ATTEMPT_PASS")
	[[ -f "$CONF_STD_ENC" ]] && STD_TEXT=$(decryptConfigToString "$CONF_STD_ENC" "$ATTEMPT_PASS")

	if [[ -n "$CF_TEXT" && "$CF_TEXT" =~ "[Interface]" ]]; then
		echo -e "\n${CYAN}${BOLD}Profile 1: Stealth Gateway:${NC}\n$CF_TEXT\n"
		command -v qrencode &>/dev/null && echo "$CF_TEXT" | qrencode -t ansiutf8
	fi
	if [[ -n "$STD_TEXT" && "$STD_TEXT" =~ "[Interface]" ]]; then
		echo -e "\n${GREEN}${BOLD}Profile 2: Standard Full Tunnel:${NC}\n$STD_TEXT\n"
		command -v qrencode &>/dev/null && echo "$STD_TEXT" | qrencode -t ansiutf8
	fi
}

function exportDecryptedClientConfig() {
	echo -e "\n${CYAN}--- Export Decrypted Config ---${NC}"
	listClients
	read -rp "Enter client name to export: " TARGET_CLIENT
	local EASY_DIR
	EASY_DIR=$(getEasyWgDir "${TARGET_CLIENT}")
	read -s -rp "Enter decryption password: " ATTEMPT_PASS
	echo ""

	local CONF_CF_ENC="${EASY_DIR}/${TARGET_CLIENT}-cloudflare-shield.conf.enc"
	local CONF_STD_ENC="${EASY_DIR}/${TARGET_CLIENT}-standard.conf.enc"
	local DEST_DIR="${EASY_DIR}/export"
	mkdir -p "$DEST_DIR"

	local cf_txt="" std_txt=""
	[[ -f "$CONF_CF_ENC" ]] && cf_txt=$(decryptConfigToString "$CONF_CF_ENC" "$ATTEMPT_PASS")
	[[ -f "$CONF_STD_ENC" ]] && std_txt=$(decryptConfigToString "$CONF_STD_ENC" "$ATTEMPT_PASS")

	if [[ -n "$cf_txt" && "$cf_txt" =~ "[Interface]" ]]; then
		echo "$cf_txt" > "${DEST_DIR}/${TARGET_CLIENT}-cloudflare-shield.conf"
		echo -e "${GREEN}[✔] Exported: ${DEST_DIR}/${TARGET_CLIENT}-cloudflare-shield.conf${NC}"
	fi
	if [[ -n "$std_txt" && "$std_txt" =~ "[Interface]" ]]; then
		echo "$std_txt" > "${DEST_DIR}/${TARGET_CLIENT}-standard.conf"
		echo -e "${GREEN}[✔] Exported: ${DEST_DIR}/${TARGET_CLIENT}-standard.conf${NC}"
	fi
}

function revokeClient() {
	local CONF_FILE="/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf"
	listClients
	read -rp "Enter client name to revoke: " TARGET_CLIENT
	[[ -z "$TARGET_CLIENT" ]] && return

	local PUB_KEYS
	PUB_KEYS=$(grep -A 5 -E "^### Client ${TARGET_CLIENT}\b" "$CONF_FILE" 2>/dev/null | grep -E "^\s*PublicKey\s*=" | awk '{print $3}')
	for pk in $PUB_KEYS; do
		[[ -n "$pk" ]] && wg set "${SERVER_WG_NIC:-wg0}" peer "$pk" remove 2>/dev/null || true
	done

	sed -i "/^### Client ${TARGET_CLIENT}\b/,/^$/d" "$CONF_FILE" 2>/dev/null || true
	echo -e "${GREEN}[✔] Client revoked.${NC}"
}

function backupRestoreManager() {
	echo -e "\n${CYAN}--- Backup & Restore ---${NC}"
	echo "1) Backup"
	echo "2) Restore"
	read -rp "Select [1-2]: " BR_OPT
	if [[ "$BR_OPT" == "1" ]]; then
		tar -czf "/root/wg_backup_$(date +%s).tar.gz" -C /etc wireguard 2>/dev/null
		echo -e "${GREEN}[✔] Backup created in /root${NC}"
	fi
}

# ------------------------------------------------------------------------------
# 10. Real-Time Domain Split Tunneling & Transparent WARP Bridge
# ------------------------------------------------------------------------------
function applyDomainSplitRulesLive() {
	echo -e "\n${CYAN}[*] Applying Fail-Safe DNS, Amazon/LinkedIn/Scanner IPSets & WARP Bridge...${NC}"

	mkdir -p /etc/wireguard
	touch /etc/wireguard/split_domains.txt

	if command -v ipset &>/dev/null; then
		ipset create wg_split_v4 hash:net family inet maxelem 262144 2>/dev/null || ipset create wg_split_v4 hash:net family inet 2>/dev/null || true
		ipset create wg_direct_clean hash:net family inet maxelem 65536 2>/dev/null || ipset create wg_direct_clean hash:net family inet 2>/dev/null || true
		ipset flush wg_split_v4 2>/dev/null || true
		ipset flush wg_direct_clean 2>/dev/null || true
	fi

	# Ensure systemd-resolved does not block port 53
	if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
		mkdir -p /etc/systemd/resolved.conf.d
		cat << 'RESOLVED_NO_STUB' > /etc/systemd/resolved.conf.d/no-stub.conf 2>/dev/null || true
[Resolve]
DNSStubListener=no
RESOLVED_NO_STUB
		systemctl restart systemd-resolved 2>/dev/null || true
	fi

	# Clean & strictly valid dnsmasq configuration (NO invalid directives)
	mkdir -p /etc/dnsmasq.d
	rm -f /etc/dnsmasq.d/00-stealth-privacy.conf /etc/dnsmasq.d/wg_split.conf 2>/dev/null || true
	cat << DNSMASQ_STEALTH_EOF > /etc/dnsmasq.d/00-stealth-privacy.conf
edns-packet-max=1232
cache-size=10000
dns-forward-max=4096
bogus-priv
filterwin2k
interface=${SERVER_WG_NIC:-wg0}
listen-address=${SERVER_WG_IPV4:-10.18.0.1},10.19.0.1,127.0.0.1
bind-dynamic
no-resolv
server=1.1.1.1
server=1.0.0.1
server=8.8.8.8
DNSMASQ_STEALTH_EOF

	echo "# Split Tunneling IPSets" > /etc/dnsmasq.d/wg_split.conf

	local DNSMASQ_SUPPORTS_IPSET=0
	if command -v dnsmasq &>/dev/null; then
		local DNSMASQ_VER_INFO
		DNSMASQ_VER_INFO=$(dnsmasq --version 2>/dev/null || true)
		if echo "$DNSMASQ_VER_INFO" | grep -q -w "ipset"; then
			DNSMASQ_SUPPORTS_IPSET=1
		fi
	fi

	while IFS= read -r raw_domain || [[ -n "$raw_domain" ]]; do
		[[ -z "$raw_domain" || "$raw_domain" =~ ^# ]] && continue
		local domain
		domain=$(echo "$raw_domain" | sed -e 's|^https*://||' -e 's|/.*$||' | tr '[:upper:]' '[:lower:]' | xargs)
		[[ -z "$domain" ]] && continue

		local IS_PAYMENT=0
		if [[ "$domain" =~ (paypal|cardinalcommerce|braintree|stripe|chase) ]]; then
			IS_PAYMENT=1
		fi

		if command -v ipset &>/dev/null && [[ "$DNSMASQ_SUPPORTS_IPSET" -eq 1 ]]; then
			if [[ $IS_PAYMENT -eq 1 ]]; then
				echo "ipset=/${domain}/wg_direct_clean" >> /etc/dnsmasq.d/wg_split.conf
			else
				echo "ipset=/${domain}/wg_split_v4" >> /etc/dnsmasq.d/wg_split.conf
			fi
		fi

		local resolved_v4
		resolved_v4=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u || true)
		for ip in $resolved_v4; do
			if command -v ipset &>/dev/null; then
				if [[ $IS_PAYMENT -eq 1 ]]; then
					ipset add wg_direct_clean "$ip" 2>/dev/null || true
				else
					ipset add wg_split_v4 "$ip" 2>/dev/null || true
				fi
			fi
		done
	done < /etc/wireguard/split_domains.txt

	# Pre-populate known Amazon & LinkedIn CIDRs into wg_split_v4
	local CORE_CIDRS="108.174.0.0/20 144.2.0.0/19 185.63.144.0/22 199.101.160.0/22 216.52.16.0/20 205.251.242.0/23 72.21.192.0/19 54.239.16.0/20 99.84.0.0/16 13.32.0.0/15"
	for c in $CORE_CIDRS; do
		command -v ipset &>/dev/null && ipset add wg_split_v4 "$c" 2>/dev/null || true
	done

	if command -v dnsmasq &>/dev/null; then
		systemctl restart dnsmasq 2>/dev/null || true
	fi

	# 1. CORE FORWARD & MASQUERADE (Guarantee unconditional baseline flow)
	sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
	iptables -I FORWARD 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
	iptables -I FORWARD 2 -i "${SERVER_WG_NIC:-wg0}" -j ACCEPT 2>/dev/null || true
	iptables -I FORWARD 3 -o "${SERVER_WG_NIC:-wg0}" -j ACCEPT 2>/dev/null || true
	iptables -t nat -I POSTROUTING 1 -s 10.18.0.0/24 ! -o "${SERVER_WG_NIC:-wg0}" -j MASQUERADE 2>/dev/null || true
	iptables -t nat -I POSTROUTING 2 -s 10.19.0.0/24 ! -o "${SERVER_WG_NIC:-wg0}" -j MASQUERADE 2>/dev/null || true

	# 2. TRANSPARENT REDSOCKS -> WARP BRIDGE (Fail-safe: Only engaged if proxy is 100% active)
	iptables -t nat -D PREROUTING -i "${SERVER_WG_NIC:-wg0}" -p tcp -j WG_STEALTH_PROXY 2>/dev/null || true
	iptables -t nat -F WG_STEALTH_PROXY 2>/dev/null || true
	iptables -t nat -X WG_STEALTH_PROXY 2>/dev/null || true

	configureRedsocksBridge "127.0.0.1" 40000 >/dev/null 2>&1 || true

	if isTransparentProxyHealthy 40000; then
		iptables -t nat -N WG_STEALTH_PROXY 2>/dev/null || true
		iptables -t nat -A WG_STEALTH_PROXY -d 10.0.0.0/8 -j RETURN
		iptables -t nat -A WG_STEALTH_PROXY -d 127.0.0.0/8 -j RETURN
		iptables -t nat -A WG_STEALTH_PROXY -d 172.16.0.0/12 -j RETURN
		iptables -t nat -A WG_STEALTH_PROXY -d 192.168.0.0/16 -j RETURN

		command -v ipset &>/dev/null && iptables -t nat -A WG_STEALTH_PROXY -m set --match-set wg_direct_clean dst -j RETURN 2>/dev/null || true

		# Stealth profile (10.19.0.0/24) routes TCP via WARP
		iptables -t nat -A WG_STEALTH_PROXY -s 10.19.0.0/24 -p tcp -j REDIRECT --to-ports 12345 2>/dev/null || true

		# Standard profile (10.18.0.0/24) routes flagged domains via WARP
		command -v ipset &>/dev/null && iptables -t nat -A WG_STEALTH_PROXY -s 10.18.0.0/24 -p tcp -m set --match-set wg_split_v4 dst -j REDIRECT --to-ports 12345 2>/dev/null || true

		iptables -I INPUT 1 -i "${SERVER_WG_NIC:-wg0}" -p tcp --dport 12345 -j ACCEPT 2>/dev/null || true
		iptables -t nat -A PREROUTING -i "${SERVER_WG_NIC:-wg0}" -p tcp -j WG_STEALTH_PROXY 2>/dev/null || true
		echo -e "${GREEN}[✔] Transparent WARP Proxy Bridge ACTIVE!${NC}"
	else
		echo -e "${YELLOW}[i] WARP Proxy in standby — Direct VPS Egress active (Fail-safe, 0% drop).${NC}"
	fi

	# 3. Dynamic MSS Clamping (Strictly placed in valid FORWARD/POSTROUTING chains)
	iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
	iptables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
	iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN ! -o "${SERVER_WG_NIC:-wg0}" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
	iptables -t mangle -I POSTROUTING 1 -p tcp --tcp-flags SYN,RST SYN ! -o "${SERVER_WG_NIC:-wg0}" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

	echo -e "${GREEN}[✔] Network rules applied successfully!${NC}\n"
}

function domainSplitTunneling() {
	echo -e "\n${CYAN}--- Split Domains List ---${NC}"
	cat /etc/wireguard/split_domains.txt 2>/dev/null | grep -v -E '^(#|$)' | nl -s ') '
	echo ""
	read -rp "Press Enter to return..."
}

function realTimeLogging() {
	echo -e "\n${CYAN}--- Real-Time Interface Status ---${NC}"
	wg show "${SERVER_WG_NIC:-wg0}" 2>/dev/null || echo "WireGuard inactive."
	echo ""
}

function geoIpAntiVpnShield() {
	echo -e "\n${CYAN}--- Geo-IP & Shield Status ---${NC}"
	echo -e "  - Transparent WARP Bridge: $(isTransparentProxyHealthy 40000 && echo -e "${GREEN}ONLINE${NC}" || echo -e "${YELLOW}STANDBY (Direct Egress)${NC}")"
	echo -e "  - TCP MSS Clamping:        ${GREEN}ACTIVE${NC}"
	echo -e "  - IP Forwarding:           ${GREEN}ACTIVE${NC}"
	echo ""
}

function settingsManager() {
	echo -e "\n${CYAN}--- Settings ---${NC}"
	echo "Public IP:   ${SERVER_PUB_IP}"
	echo "Port:        ${SERVER_PORT}/udp"
	echo "Web Console: ${WEB_PORT:-51821}/tcp"
}

function autoRepairNetwork() {
	echo -e "\n${CYAN}${BOLD}🛠️ Starting Automated Health & Network Auto-Repair...${NC}"

	rm -f /etc/resolv.conf 2>/dev/null || true
	cat << 'RESOLV_CLEAN_EOF' > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
RESOLV_CLEAN_EOF

	sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.all.forwarding=1 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true

	ip rule del fwmark 0x51820 table 51820 2>/dev/null || true
	ip route flush table 51820 2>/dev/null || true

	if command -v wg-quick &>/dev/null; then
		wg-quick down "${SERVER_WG_NIC:-wg0}" >/dev/null 2>&1 || true
		systemctl restart "wg-quick@${SERVER_WG_NIC:-wg0}" 2>/dev/null || wg-quick up "${SERVER_WG_NIC:-wg0}" 2>/dev/null || true
	fi

	if command -v warp-cli &>/dev/null; then
		systemctl restart warp-svc 2>/dev/null || true
		sleep 1
		warp-cli --accept-tos proxy port 40000 2>/dev/null || warp-cli --accept-tos set-proxy-port 40000 2>/dev/null || warp-cli set-proxy-port 40000 2>/dev/null || true
		warp-cli --accept-tos mode proxy 2>/dev/null || warp-cli --accept-tos set-mode proxy 2>/dev/null || warp-cli set-mode proxy 2>/dev/null || true
		warp-cli --accept-tos connect 2>/dev/null || warp-cli connect 2>/dev/null || true
	fi

	configureRedsocksBridge "127.0.0.1" 40000 >/dev/null 2>&1 || true
	applyDomainSplitRulesLive >/dev/null 2>&1 || true

	verifyServerTrafficHealth
}

function setupCloudflareWarpClient() {
	echo -e "\n${CYAN}${BOLD}⚡ Initializing Cloudflare WARP...${NC}"
	mkdir -p /etc/wireguard
	touch /etc/wireguard/warp_egress_enabled

	if ! command -v warp-cli &>/dev/null && command -v apt-get &>/dev/null; then
		export DEBIAN_FRONTEND=noninteractive
		local ARCH
		ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
		local CODENAME=""
		[[ -f /etc/os-release ]] && . /etc/os-release && CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
		[[ -z "$CODENAME" ]] && CODENAME=$(lsb_release -cs 2>/dev/null || echo "jammy")
		case "$CODENAME" in
			noble|jammy|focal|bookworm|bullseye) ;;
			*) CODENAME="jammy" ;;
		esac

		mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
		curl -fsSL --connect-timeout 8 https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null || true
		echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${CODENAME} main" > /etc/apt/sources.list.d/cloudflare-client.list 2>/dev/null || true
		apt-get update -o Acquire::Timeout="10" -qq >/dev/null 2>&1 || true
		apt-get install -y -qq cloudflare-warp redsocks >/dev/null 2>&1 || true
	fi

	if command -v warp-cli &>/dev/null; then
		systemctl enable --now warp-svc >/dev/null 2>&1 || true
		sleep 1

		warp-cli --accept-tos registration new 2>/dev/null || warp-cli --accept-tos register 2>/dev/null || true
		warp-cli --accept-tos proxy port 40000 2>/dev/null || warp-cli --accept-tos set-proxy-port 40000 2>/dev/null || warp-cli set-proxy-port 40000 2>/dev/null || true
		warp-cli --accept-tos mode proxy 2>/dev/null || warp-cli --accept-tos set-mode proxy 2>/dev/null || warp-cli set-mode proxy 2>/dev/null || true
		warp-cli --accept-tos connect 2>/dev/null || warp-cli connect 2>/dev/null || true
		sleep 1

		configureRedsocksBridge "127.0.0.1" 40000 >/dev/null 2>&1 || true
		installWarpWatchdog
		echo -e "${GREEN}[✔] Cloudflare WARP client configured!${NC}"
	fi
}

function cloudflareAntiFlagEngine() {
	echo -e "\n${CYAN}--- Cloudflare Anti-Flag Engine ---${NC}"
	echo "1) Re-install / Repair WARP & Redsocks Bridge"
	echo "2) Run Egress Diagnostic Test"
	echo "3) Revert to Direct VPS Egress"
	read -rp "Select option [1-3]: " CF_OPT
	case "$CF_OPT" in
		1) setupCloudflareWarpClient ; applyDomainSplitRulesLive ;;
		2) verifyServerTrafficHealth ;;
		3)
			systemctl stop redsocks 2>/dev/null || true
			iptables -t nat -D PREROUTING -i "${SERVER_WG_NIC:-wg0}" -p tcp -j WG_STEALTH_PROXY 2>/dev/null || true
			echo -e "${GREEN}[✔] Reverted to Direct VPS Egress.${NC}"
			;;
	esac
}

function uninstallWg() {
	read -rp "Are you sure you want to uninstall WireGuard? [y/N]: " REMOVE
	if [[ "$REMOVE" =~ ^[Yy]$ ]]; then
		systemctl stop "wg-quick@${SERVER_WG_NIC:-wg0}" cbwireguard-web redsocks wg-warp-watchdog.timer 2>/dev/null || true
		systemctl disable "wg-quick@${SERVER_WG_NIC:-wg0}" cbwireguard-web wg-warp-watchdog.timer 2>/dev/null || true
		wg-quick down "${SERVER_WG_NIC:-wg0}" 2>/dev/null || true
		ip link delete dev "${SERVER_WG_NIC:-wg0}" 2>/dev/null || true

		iptables -t nat -D PREROUTING -i "${SERVER_WG_NIC:-wg0}" -p tcp -j WG_STEALTH_PROXY 2>/dev/null || true
		iptables -D FORWARD -i "${SERVER_WG_NIC:-wg0}" -j ACCEPT 2>/dev/null || true
		iptables -D FORWARD -o "${SERVER_WG_NIC:-wg0}" -j ACCEPT 2>/dev/null || true

		rm -rf /etc/wireguard /etc/dnsmasq.d/00-stealth-privacy.conf /etc/dnsmasq.d/wg_split.conf
		echo -e "${GREEN}[✔] WireGuard uninstalled safely.${NC}"
		exit 0
	fi
}

# ------------------------------------------------------------------------------
# 11. Interactive Terminal Menu
# ------------------------------------------------------------------------------
function manageMenu() {
	while true; do
		local WG0_STATUS="${RED}STOPPED${NC}"
		if systemctl is-active --quiet wg-quick@wg0 2>/dev/null || wg show wg0 &>/dev/null; then
			WG0_STATUS="${GREEN}ACTIVE${NC}"
		fi

		local BRIDGE_STATUS="${YELLOW}DIRECT VPS EGRESS (FAIL-SAFE)${NC}"
		if isTransparentProxyHealthy 40000; then
			BRIDGE_STATUS="${GREEN}WARP AS13335 BRIDGE ACTIVE${NC}"
		fi

		echo -e "\n${PURPLE}=================================================================${NC}"
		echo -e "              ${GREEN}${BOLD}🍪  Cookie's Easy WireGuard Manager v4.2${NC}"
		echo -e "${PURPLE}=================================================================${NC}"
		echo -e "  ${BOLD}Server Daemon:${NC}        wg0 | Port ${SERVER_PORT:-4500}/udp [${WG0_STATUS}]"
		echo -e "  ${BOLD}Stealth Engine:${NC}       [${BRIDGE_STATUS}]"
		echo -e "  ${BOLD}Profile 1 (Stealth):${NC}  10.19.0.0/24 (WARP Consumer Cloak, MTU 1380)"
		echo -e "  ${BOLD}Profile 2 (Standard):${NC} 10.18.0.0/24 (Direct VPS + Shield, MTU 1420)"
		echo -e "${PURPLE}┌──────────────────────────────────────────────────────────────┐${NC}"
		echo -e "${PURPLE}│${NC}                      ${CYAN}${BOLD}Main Menu Actions${NC}                       ${PURPLE}│${NC}"
		echo -e "${PURPLE}├──────────────────────────────────────────────────────────────┤${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[1]${NC} Setup WireGuard server                                    ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[2]${NC} Add new client                                            ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[3]${NC} Configure clients (Check/Edit/Export/Remove)             ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[4]${NC} Backup & Restore Manager                                 ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[5]${NC} View Domain Split List                                    ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[6]${NC} Real-Time Status                                          ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[7]${NC} Geo-IP & Shield Status                                    ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[8]${NC} Provision Web Management Console                         ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[9]${NC} Stealth Anti-Scanner & WARP Engine                        ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[10]${NC} Auto-Repair Network, DNS & Firewall                     ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[s]${NC} Settings                                                  ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${RED}${BOLD}[r] Remove WireGuard server${NC}                                   ${PURPLE}│${NC}"
		echo -e "${PURPLE}│${NC} ${BOLD}[q]${NC} Exit                                                     ${PURPLE}│${NC}"
		echo -e "${PURPLE}└──────────────────────────────────────────────────────────────┘${NC}"
		echo ""

		read -rp "Option: " MENU_OPTION

		case "${MENU_OPTION}" in
			1) installQuestions ; installWireGuard ;;
			2) newClient ;;
			3) configureClients ;;
			4) backupRestoreManager ;;
			5) domainSplitTunneling ;;
			6) realTimeLogging ;;
			7) geoIpAntiVpnShield ;;
			8) provisionWebConsole ;;
			9) cloudflareAntiFlagEngine ;;
			10) autoRepairNetwork ;;
			s|S) settingsManager ;;
			r|R) uninstallWg ;;
			q|Q) echo -e "${GREEN}Goodbye!${NC}\n" ; exit 0 ;;
			*) echo -e "${RED}Invalid option.${NC}" ; sleep 1 ;;
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

	if [[ "${1:-}" == "--repair" || "${1:-}" == "-r" || "${1:-}" == "repair" ]]; then
		autoRepairNetwork
		exit 0
	fi

	if [[ "${1:-}" == "--clean" || "${1:-}" == "-c" ]]; then
		cleanupAndSecureRootFolder
		exit 0
	fi

	cleanupAndSecureRootFolder
	manageMenu
fi