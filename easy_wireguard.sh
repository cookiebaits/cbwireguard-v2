#!/bin/bash
# ==============================================================================
# 🍪 Cookie's Easy WireGuard Manager & VPS Stealth Server v4.2 (Full-Speed WARP)
# ==============================================================================

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
	fi
}

function initialCheck() {
	isRoot
	checkOS
	checkVirt
}

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

# Re-enable physical NIC hardware offloads while disabling only buggy UDP GRO forwarding
function optimizeNicQueuesAndRPS() {
	local cpu_count
	cpu_count=$(nproc 2>/dev/null || echo 1)
	local rps_mask
	rps_mask=$(printf '%x' $(( (1 << (cpu_count > 16 ? 16 : cpu_count)) - 1 )) 2>/dev/null || echo "f")

	local PUB_NIC="${SERVER_PUB_NIC:-}"
	if [[ -z "$PUB_NIC" ]]; then
		PUB_NIC=$(ip -4 route show table main default 2>/dev/null | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | grep -vE '^(wg|Cloudflare|tun)' | head -n1 || echo "eth0")
	fi

	# Restore hardware TSO/GSO/GRO on physical NIC (disabled in v4.1) and only disable buggy UDP GRO list forwarding
	if command -v ethtool &>/dev/null && [[ -n "$PUB_NIC" ]]; then
		ethtool -K "$PUB_NIC" gro on gso on tso on 2>/dev/null || true
		ethtool -K "$PUB_NIC" rx-gro-list off 2>/dev/null || true
		ethtool -K "$PUB_NIC" rx-udp-gro-forwarding off 2>/dev/null || true
	fi

	for nic in "$PUB_NIC" "${SERVER_WG_NIC:-wg0}" "wgwarp" "CloudflareWARP"; do
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

	# Keep wg0 at 1420 (accepts full frames from existing clients) and wgwarp at 1280 (Cloudflare WARP edge limit)
	ip link set dev "${SERVER_WG_NIC:-wg0}" mtu 1420 2>/dev/null || true
	ip link set dev wgwarp mtu 1280 2>/dev/null || true

	if [[ -w /proc/sys/net/core/rps_sock_flow_entries ]]; then
		echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
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
	while iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
	while iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
	while iptables -t mangle -D POSTROUTING -j TTL --ttl-set 64 2>/dev/null; do :; done
	while iptables -t mangle -D POSTROUTING -j TTL --ttl-set 128 2>/dev/null; do :; done

	echo -e "${GREEN}[✔] Cleaned old WireGuard instances.${NC}"
}

# ------------------------------------------------------------------------------
# 3. DNS Resolvers Selection Menu
# ------------------------------------------------------------------------------
function selectDNSResolvers() {
	echo -e "\n${CYAN}${BOLD}Select DNS Resolvers for Clients:${NC}"
	echo -e "   1) ${GREEN}Cloudflare Anycast Anti-Flag${NC} (1.1.1.1, 1.0.0.1) ${PURPLE}[RECOMMENDED SPEED]${NC}"
	echo -e "   2) ${GREEN}AdGuard Stealth${NC} (94.140.14.14, 94.140.15.15)"
	echo -e "   3) ${GREEN}Mullvad Privacy${NC} (194.242.2.2, 194.242.2.3)"
	echo -e "   4) ${GREEN}Quad9 Swiss Shield${NC} (9.9.9.9, 149.112.112.112)"
	echo -e "   5) ${GREEN}Control D Stealth${NC} (76.76.2.0, 76.76.10.0)"
	echo -e "   6) ${GREEN}Local Server Resolver${NC} (${SERVER_WG_IPV4:-10.18.0.1})"
	echo -e "   7) ${GREEN}Google Public DNS${NC} (8.8.8.8, 8.8.4.4)"
	echo -e "   8) ${GREEN}OpenDNS${NC} (208.67.222.222, 208.67.220.220)"
	echo -e "   9) Custom Primary & Secondary DNS Resolvers"

	read -rp "Select DNS Resolver option [1-9, default 1]: " DNS_OPTION
	DNS_OPTION=${DNS_OPTION:-1}
	case "${DNS_OPTION}" in
		2) CLIENT_DNS_1="94.140.14.14"; CLIENT_DNS_2="94.140.15.15" ;;
		3) CLIENT_DNS_1="194.242.2.2"; CLIENT_DNS_2="194.242.2.3" ;;
		4) CLIENT_DNS_1="9.9.9.9"; CLIENT_DNS_2="149.112.112.112" ;;
		5) CLIENT_DNS_1="76.76.2.0"; CLIENT_DNS_2="76.76.10.0" ;;
		6) CLIENT_DNS_1="${SERVER_WG_IPV4:-10.18.0.1}"; CLIENT_DNS_2="1.1.1.1" ;;
		7) CLIENT_DNS_1="8.8.8.8"; CLIENT_DNS_2="8.8.4.4" ;;
		8) CLIENT_DNS_1="208.67.222.222"; CLIENT_DNS_2="208.67.220.220" ;;
		9)
			read -rp "Enter Primary DNS resolver: " -e -i "1.1.1.1" CLIENT_DNS_1
			read -rp "Enter Secondary DNS resolver: " -e -i "1.0.0.1" CLIENT_DNS_2
			;;
		1|*) CLIENT_DNS_1="1.1.1.1"; CLIENT_DNS_2="1.0.0.1" ;;
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

	echo -e "\n${CYAN}${BOLD}Select WireGuard Port (Unified Port):${NC}"
	echo -e "   1) ${GREEN}4500${NC}  (IPsec NAT-Traversal UDP) ${PURPLE}[RECOMMENDED STEALTH]${NC}"
	echo -e "   2) ${GREEN}3478${NC}  (STUN / WebRTC Media UDP)"
	echo -e "   3) ${GREEN}500${NC}   (IKEv2 Signaling UDP)"
	echo -e "   4) ${GREEN}853${NC}   (DNS-over-QUIC UDP)"
	echo -e "   5) ${GREEN}51820${NC} (Official WireGuard Standard Port)"
	echo -e "   6) ${GREEN}41194${NC} (Disguised High Tunnel UDP)"
	echo -e "   7) Random High-Entropy Stealth Port (49152-65535)"
	echo -e "   8) Custom Port"

	while true; do
		read -rp "Select Port option [1-8, or type port directly, default 1 (4500)]: " PORT_OPTION
		PORT_OPTION=${PORT_OPTION:-1}

		if [[ "$PORT_OPTION" =~ ^[0-9]+$ ]] && [[ "$PORT_OPTION" -ge 1024 && "$PORT_OPTION" -le 65535 ]]; then
			if isSensitivePort "$PORT_OPTION"; then
				echo -e "${RED}[!] Sensitive port. Choose another.${NC}"
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
				SERVER_PORT=$(( (RANDOM % 16383) + 49152 ))
				break
				;;
			8)
				read -rp "Enter Custom WireGuard Port [1024-65535]: " -e -i "8008" SERVER_PORT
				break
				;;
			*) continue ;;
		esac
	done

	SERVER_PORT_CF="${SERVER_PORT}"
	selectDNSResolvers

	read -rp "First client device name: " -e -i "my-device" CLIENT_NAME
	CLIENT_NAME=$(echo "$CLIENT_NAME" | tr -cd '[:alnum:]_-')

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
		if [[ "$CLIENT_PASSWORD" == "$CLIENT_PASSWORD_CONFIRM" ]]; then
			break
		fi
		echo -e "${RED}[!] Passwords do not match.${NC}"
	done

	read -rp "Allowed IPs for generated clients: " -e -i "0.0.0.0/0, ::/0" ALLOWED_IPS

	CF_AUTO_ENABLE="y"
	WARP_GLOBAL_MODE="full"
	WEB_PORT=${WEB_PORT:-51821}
}

# ------------------------------------------------------------------------------
# 5. Safely Upgrade / Write wg0.conf (Preserving Existing Key & All Peers)
# ------------------------------------------------------------------------------
function writeUnifiedWg0Config() {
	local EXISTING_PEERS=""
	local EXISTING_PRIV_KEY=""
	local EXISTING_PORT=""

	if [[ -f /etc/wireguard/wg0.conf ]]; then
		EXISTING_PEERS=$(awk '/^### Client|^\[Peer\]/{flag=1} flag{print}' /etc/wireguard/wg0.conf 2>/dev/null || true)
		EXISTING_PRIV_KEY=$(grep -E '^\s*PrivateKey\s*=' /etc/wireguard/wg0.conf 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d ' \r\n' || true)
		EXISTING_PORT=$(grep -E '^\s*ListenPort\s*=' /etc/wireguard/wg0.conf 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d ' \r\n' || true)
	fi

	[[ -n "$EXISTING_PRIV_KEY" ]] && SERVER_PRIV_KEY="$EXISTING_PRIV_KEY"
	[[ -n "$EXISTING_PORT" && -z "${SERVER_PORT:-}" ]] && SERVER_PORT="$EXISTING_PORT"

	local WG_SERVER_ADDRESS="${SERVER_WG_IPV4:-10.18.0.1}/24"
	if [[ "${HAS_IPV6:-0}" -eq 1 ]]; then
		WG_SERVER_ADDRESS="${SERVER_WG_IPV4:-10.18.0.1}/24,${SERVER_WG_IPV6:-fd42:42:42::1}/64"
	fi

	cat << WG_SERVER_EOF > "/etc/wireguard/wg0.conf"
[Interface]
Address = ${WG_SERVER_ADDRESS}, 10.19.0.1/24
ListenPort = ${SERVER_PORT:-4500}
PrivateKey = ${SERVER_PRIV_KEY}
MTU = 1420
SaveConfig = false

# --- 1. CORE HIGH-SPEED FORWARDING & NAT ---
PostUp = sysctl -w net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.wg0.rp_filter=0 >/dev/null 2>&1 || true
PostUp = ip link set dev wg0 txqueuelen 10000 mtu 1420 2>/dev/null || true
PostUp = iptables -C INPUT -p udp --dport ${SERVER_PORT:-4500} -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p udp --dport ${SERVER_PORT:-4500} -j ACCEPT
PostUp = iptables -C INPUT -i wg0 -p udp --dport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT 2 -i wg0 -p udp --dport 53 -j ACCEPT
PostUp = iptables -C INPUT -i wg0 -p tcp --dport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT 3 -i wg0 -p tcp --dport 53 -j ACCEPT
PostUp = iptables -C FORWARD -p icmp -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -p icmp -j ACCEPT
PostUp = iptables -C FORWARD -i wg0 -j ACCEPT 2>/dev/null || iptables -I FORWARD 2 -i wg0 -j ACCEPT
PostUp = iptables -C FORWARD -o wg0 -j ACCEPT 2>/dev/null || iptables -I FORWARD 3 -o wg0 -j ACCEPT
PostUp = iptables -t nat -C POSTROUTING -s 10.18.0.0/24 ! -o wg0 -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s 10.18.0.0/24 ! -o wg0 -j MASQUERADE
PostUp = iptables -t nat -C POSTROUTING -s 10.19.0.0/24 ! -o wg0 -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 2 -s 10.19.0.0/24 ! -o wg0 -j MASQUERADE

# --- 2. BIDIRECTIONAL MSS=1200 CLAMPING (Fits inside 1280 MTU WARP with Zero Drops) ---
PostUp = iptables -t mangle -C FORWARD -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200 2>/dev/null || iptables -t mangle -I FORWARD 1 -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200
PostUp = iptables -t mangle -C FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200 2>/dev/null || iptables -t mangle -I FORWARD 2 -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200
PostUp = iptables -t mangle -C POSTROUTING -s 10.19.0.0/24 ! -o wg0 -j TTL --ttl-set 128 2>/dev/null || iptables -t mangle -I POSTROUTING 1 -s 10.19.0.0/24 ! -o wg0 -j TTL --ttl-set 128

PostDown = iptables -D INPUT -p udp --dport ${SERVER_PORT:-4500} -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s 10.18.0.0/24 ! -o wg0 -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s 10.19.0.0/24 ! -o wg0 -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200 2>/dev/null || true
PostDown = iptables -t mangle -D POSTROUTING -s 10.19.0.0/24 ! -o wg0 -j TTL --ttl-set 128 2>/dev/null || true
WG_SERVER_EOF

	if [[ -n "$EXISTING_PEERS" ]]; then
		printf "\n%s\n" "$EXISTING_PEERS" >> "/etc/wireguard/wg0.conf"
	fi
	chmod 600 "/etc/wireguard/wg0.conf"
}

# ------------------------------------------------------------------------------
# 6. Perform WireGuard Server Installation
# ------------------------------------------------------------------------------
function installWireGuard() {
	if [[ -z "${SERVER_PORT:-}" ]]; then
		installQuestions
	fi

	cleanupOldWireguard

	export DEBIAN_FRONTEND=noninteractive
	export NEEDRESTART_MODE=a

	if [[ "${OS}" == "ubuntu" || "${OS}" == "debian" ]]; then
		local MISSING_PKGS=()
		for pkg in wireguard wireguard-tools iptables qrencode curl jq iproute2 iptables-persistent net-tools ipset dnsmasq ethtool; do
			if ! dpkg -s "$pkg" &>/dev/null; then
				MISSING_PKGS+=("$pkg")
			fi
		done
		if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
			apt-get update -o Acquire::Languages=none -y -q || true
			apt-get install -y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" "${MISSING_PKGS[@]}" || true
		fi
	elif [[ "${OS}" == "fedora" || "${OS}" == "centos" || "${OS}" == "almalinux" || "${OS}" == "rocky" ]]; then
		yum install -y wireguard-tools iptables qrencode curl jq ipset dnsmasq ethtool || true
	elif [[ "${OS}" == "arch" ]]; then
		pacman -S --needed --noconfirm wireguard-tools qrencode iptables curl jq ipset dnsmasq ethtool || true
	elif [[ "${OS}" == "alpine" ]]; then
		apk update && apk add wireguard-tools iptables libqrencode-tools curl jq ipset dnsmasq ethtool || true
	fi

	modprobe wireguard >/dev/null 2>&1 || true
	modprobe nf_conntrack >/dev/null 2>&1 || true
	modprobe iptable_nat >/dev/null 2>&1 || true
	modprobe iptable_mangle >/dev/null 2>&1 || true
	modprobe xt_mark >/dev/null 2>&1 || true
	modprobe ipt_TTL >/dev/null 2>&1 || true
	modprobe tcp_bbr >/dev/null 2>&1 || true

	local HAS_IPV6=0
	if [[ -f /proc/net/if_inet6 ]] && [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1) -eq 0 ]]; then
		if ip -6 route show default 2>/dev/null | grep -q "default"; then
			HAS_IPV6=1
		fi
	fi

	SYSCTL_CONF="/etc/sysctl.d/99-wireguard-stealth.conf"
	cat << 'SYSCTL_EOF' > "$SYSCTL_CONF"
net.ipv4.ip_forward = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.core.default_qdisc = fq
net.ipv4.tcp_fastopen = 3
net.core.rmem_default = 33554432
net.core.wmem_default = 33554432
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 131072 67108864
net.core.netdev_max_backlog = 250000
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
net.ipv4.tcp_max_syn_backlog = 3240000
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180
net.netfilter.nf_conntrack_helper = 0
SYSCTL_EOF

	if lsmod 2>/dev/null | grep -q bbr || grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
		echo "net.ipv4.tcp_congestion_control = bbr" >> "$SYSCTL_CONF"
	fi
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

	writeUnifiedWg0Config

	systemctl daemon-reload >/dev/null 2>&1 || true
	systemctl enable "wg-quick@wg0" >/dev/null 2>&1 || true
	systemctl restart "wg-quick@wg0" 2>/dev/null || wg-quick up wg0 2>/dev/null || true

	touch /etc/wireguard/cloudflare_shield_enabled
	touch /etc/wireguard/cloudflare_split_enabled
	touch /etc/wireguard/warp_egress_enabled
	echo "BYPASS" > /etc/wireguard/split_mode.txt

	cat << 'CF_INIT_DOMAINS' > /etc/wireguard/split_domains.txt
challenges.cloudflare.com
cloudflare.com
turnstile.com
amazon.com
www.amazon.com
linkedin.com
www.linkedin.com
licdn.com
paypal.com
www.paypal.com
paypalobjects.com
cardinalcommerce.com
braintreegateway.com
stripe.com
CF_INIT_DOMAINS

	setupCloudflareWarpClient
	applyDomainSplitRulesLive
	newClientInternal "${CLIENT_NAME}" "${CLIENT_PASSWORD}"
}

# ------------------------------------------------------------------------------
# 7. Client Management (MTU 1280 for Zero-Fragmentation WARP + Keepalive 15)
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
	local CLIENT_DNS_LINE="${CLIENT_DNS_1:-1.1.1.1}"
	if [[ -n "${CLIENT_DNS_2}" && "${CLIENT_DNS_2}" != "${CLIENT_DNS_1}" ]]; then
		CLIENT_DNS_LINE="${CLIENT_DNS_1}, ${CLIENT_DNS_2}"
	fi

	local EASY_DIR
	EASY_DIR=$(getEasyWgDir "${CLIENT_NAME}")

	local CF_CONF_CONTENT
	CF_CONF_CONTENT=$(cat << CF_CLIENT_EOF
[Interface]
PrivateKey = ${CLIENT_CF_PRIV_KEY}
Address = ${CLIENT_WG_CF_IPV4}/32
DNS = ${CLIENT_DNS_LINE}
MTU = 1280

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT_WG0}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 15
CF_CLIENT_EOF
)

	local STD_CONF_CONTENT
	STD_CONF_CONTENT=$(cat << CLIENT_EOF
[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_WG_IPV4}/32
DNS = ${CLIENT_DNS_LINE}
MTU = 1280

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT_WG0}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 15
CLIENT_EOF
)

	local ENC_KEY="${CLIENT_PASSWORD:-$(getMasterPasskey)}"
	encryptConfigContent "$CF_CONF_CONTENT" "${EASY_DIR}/${CLIENT_NAME}-cloudflare-shield.conf.enc" "$ENC_KEY"
	encryptConfigContent "$CF_CONF_CONTENT" "/etc/wireguard/clients/${CLIENT_NAME}-cloudflare-shield.conf.enc" "$ENC_KEY"
	encryptConfigContent "$STD_CONF_CONTENT" "${EASY_DIR}/${CLIENT_NAME}-standard.conf.enc" "$ENC_KEY"
	encryptConfigContent "$STD_CONF_CONTENT" "${EASY_DIR}/${CLIENT_NAME}.conf.enc" "$ENC_KEY"
	encryptConfigContent "$STD_CONF_CONTENT" "/etc/wireguard/clients/${CLIENT_NAME}-standard.conf.enc" "$ENC_KEY"
	encryptConfigContent "$STD_CONF_CONTENT" "/etc/wireguard/clients/${CLIENT_NAME}.conf.enc" "$ENC_KEY"

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
AllowedIPs = ${CLIENT_WG_IPV4}/32
PEER_EOF

	wg syncconf wg0 <(wg-quick strip wg0) 2>/dev/null || true

	echo -e "\n${CYAN}${BOLD}📋 [1/2] PROFILE 1: WARP & STEALTH (${CLIENT_NAME}-cloudflare-shield.conf):${NC}"
	echo "$CF_CONF_CONTENT"
	echo -e "\n${GREEN}${BOLD}📋 [2/2] PROFILE 2: STANDARD (${CLIENT_NAME}-standard.conf):${NC}"
	echo "$STD_CONF_CONTENT"

	if command -v qrencode &>/dev/null; then
		echo "$CF_CONF_CONTENT" | qrencode -t ansiutf8
		echo "$STD_CONF_CONTENT" | qrencode -t ansiutf8
	fi
}

function newClient() {
	local CLIENT_NAME=""
	until [[ -n "$CLIENT_NAME" && "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; do
		read -rp "Enter client device name: " CLIENT_NAME
		CLIENT_NAME=$(echo "$CLIENT_NAME" | tr -cd '[:alnum:]_-')
		if grep -q "### Client ${CLIENT_NAME}" "/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf" 2>/dev/null; then
			echo -e "${ORANGE}Client '${CLIENT_NAME}' already exists.${NC}"
			CLIENT_NAME=""
		fi
	done

	local CLIENT_PASSWORD=""
	while true; do
		read -s -rp "Enter encryption password for '${CLIENT_NAME}': " CLIENT_PASSWORD
		echo ""
		[[ ${#CLIENT_PASSWORD} -lt 4 ]] && continue
		read -s -rp "Confirm encryption password: " CLIENT_PASSWORD_CONFIRM
		echo ""
		[[ "$CLIENT_PASSWORD" == "$CLIENT_PASSWORD_CONFIRM" ]] && break
	done
	newClientInternal "$CLIENT_NAME" "$CLIENT_PASSWORD"
}

function configureClients() {
	echo "1) View Client QR Code & Configuration"
	echo "2) Export / Decrypt Client Configuration"
	echo "3) Clean Root Directory & Re-Encrypt All Configs"
	echo "4) Remove / Revoke a Client"
	echo "5) Back"
	read -rp "Select [1-5]: " SUB_OPT
	case "$SUB_OPT" in
		1) showClientQr ;;
		2) exportDecryptedClientConfig ;;
		3) cleanupAndSecureRootFolder ;;
		4) revokeClient ;;
		*) return ;;
	esac
}

function showClientQr() {
	local CONF_FILE="/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf"
	local CLIENT_LIST=()
	while IFS= read -r cname; do
		[[ -n "$cname" ]] && CLIENT_LIST+=("$cname")
	done < <(grep -E "^### Client" "$CONF_FILE" 2>/dev/null | awk '{print $3}' | sort -u)
	[[ ${#CLIENT_LIST[@]} -eq 0 ]] && return

	for i in "${!CLIENT_LIST[@]}"; do echo "  $((i+1))) ${CLIENT_LIST[$i]}"; done
	local CLIENT_NUMBER=0
	read -rp "Select client: " CLIENT_NUMBER
	local TARGET_CLIENT="${CLIENT_LIST[$((CLIENT_NUMBER-1))]}"
	local EASY_DIR
	EASY_DIR=$(getEasyWgDir "${TARGET_CLIENT}")
	read -s -rp "Enter decryption password for '${TARGET_CLIENT}': " ATTEMPT_PASS
	echo ""
	local CF_TEXT STD_TEXT
	CF_TEXT=$(decryptConfigToString "${EASY_DIR}/${TARGET_CLIENT}-cloudflare-shield.conf.enc" "$ATTEMPT_PASS")
	STD_TEXT=$(decryptConfigToString "${EASY_DIR}/${TARGET_CLIENT}-standard.conf.enc" "$ATTEMPT_PASS")
	echo "$CF_TEXT"
	command -v qrencode &>/dev/null && echo "$CF_TEXT" | qrencode -t ansiutf8
	echo "$STD_TEXT"
	command -v qrencode &>/dev/null && echo "$STD_TEXT" | qrencode -t ansiutf8
}

function exportDecryptedClientConfig() {
	showClientQr
}

function revokeClient() {
	local CONF_FILE="/etc/wireguard/${SERVER_WG_NIC:-wg0}.conf"
	local CLIENT_LIST=()
	while IFS= read -r cname; do
		[[ -n "$cname" ]] && CLIENT_LIST+=("$cname")
	done < <(grep -E "^### Client" "$CONF_FILE" 2>/dev/null | awk '{print $3}' | sort -u)
	[[ ${#CLIENT_LIST[@]} -eq 0 ]] && return
	for i in "${!CLIENT_LIST[@]}"; do echo "  $((i+1))) ${CLIENT_LIST[$i]}"; done
	local CLIENT_NUMBER=0
	read -rp "Select client to revoke: " CLIENT_NUMBER
	local TARGET_CLIENT="${CLIENT_LIST[$((CLIENT_NUMBER-1))]}"
	local PUB_KEYS
	PUB_KEYS=$(grep -A 5 -E "^### Client ${TARGET_CLIENT}\b" "$CONF_FILE" 2>/dev/null | grep -E "^\s*PublicKey\s*=" | awk '{print $3}')
	for pk in $PUB_KEYS; do wg set "${SERVER_WG_NIC:-wg0}" peer "$pk" remove 2>/dev/null || true; done
	sed -i "/^### Client ${TARGET_CLIENT}\b/,/^$/d" "$CONF_FILE" 2>/dev/null || true
	wg syncconf "${SERVER_WG_NIC:-wg0}" <(wg-quick strip "${SERVER_WG_NIC:-wg0}") 2>/dev/null || true
}

function backupRestoreManager() {
	local DATE
	DATE=$(date +%Y-%m-%d_%H-%M-%S)
	tar -czf "/root/wireguard_backup_${DATE}.tar.gz" -C /etc wireguard 2>/dev/null
	echo -e "${GREEN}[✔] Backup saved to /root/wireguard_backup_${DATE}.tar.gz${NC}"
}

# ------------------------------------------------------------------------------
# 8. Policy Routing Protection: Lock Host Public IP, Return Subnets & wgwarp IP
# ------------------------------------------------------------------------------
function ensureHostPublicIpBypassRules() {
	local DEF_NIC="${SERVER_PUB_NIC:-}"
	if [[ -z "$DEF_NIC" ]]; then
		DEF_NIC=$(ip -4 route show table main default 2>/dev/null | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | grep -vE '^(wg|Cloudflare|tun)' | head -n1 || echo "eth0")
	fi

	local PUB_IP="${SERVER_PUB_IP:-}"
	if [[ -z "$PUB_IP" || "$PUB_IP" == "127.0.0.1" ]]; then
		PUB_IP=$(ip -4 addr show dev "$DEF_NIC" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || true)
	fi

	# Clean up any broken table 200 rules or warp-svc nftables killswitches from earlier runs
	while ip rule del lookup 200 2>/dev/null; do :; done
	ip route flush table 200 2>/dev/null || true
	if command -v nft &>/dev/null; then
		nft delete table inet cloudflare-warp 2>/dev/null || true
	fi

	# Priority 25-30: Outer WARP UDP transport (FwMark 0x51888) & Cloudflare WARP Endpoint IPs stay on physical NIC (table main)
	while ip rule del fwmark 0x51888 lookup main priority 25 2>/dev/null; do :; done
	ip rule add fwmark 0x51888 lookup main priority 25 2>/dev/null || true

	for warp_ep in 162.159.192.0/24 162.159.193.0/24 162.159.195.0/24 188.114.96.0/22; do
		while ip rule del to "$warp_ep" lookup main priority 30 2>/dev/null; do :; done
		ip rule add to "$warp_ep" lookup main priority 30 2>/dev/null || true
	done

	# Priority 40-41: Return packets to VPN clients ALWAYS route to wg0 (table main)
	while ip rule del to 10.18.0.0/24 lookup main priority 40 2>/dev/null; do :; done
	while ip rule del to 10.19.0.0/24 lookup main priority 41 2>/dev/null; do :; done
	ip rule add to 10.18.0.0/24 lookup main priority 40 2>/dev/null || true
	ip rule add to 10.19.0.0/24 lookup main priority 41 2>/dev/null || true

	# Priority 50: VPS Public IP (SSH, WireGuard listen port, Web Console) uses native table main
	if [[ -n "$PUB_IP" && "$PUB_IP" != "127.0.0.1" ]]; then
		while ip rule del from "${PUB_IP}/32" lookup main priority 50 2>/dev/null; do :; done
		while ip rule del from "${PUB_IP}/32" lookup main priority 51 2>/dev/null; do :; done
		ip rule add from "${PUB_IP}/32" lookup main priority 50 2>/dev/null || true
	fi

	# Priority 60: Direct-Clean Bypass (PayPal / Banking marked 0x100)
	while ip rule del fwmark 0x100 lookup main priority 60 2>/dev/null; do :; done
	ip rule add fwmark 0x100 lookup main priority 60 2>/dev/null || true

	# Priority 100-101: Route wgwarp's own interface IP (172.16.0.x) & oif wgwarp via table 51820 so curl --interface wgwarp works!
	local WARP_LOCAL_IP=""
	if ip link show wgwarp &>/dev/null; then
		WARP_LOCAL_IP=$(ip -4 addr show dev wgwarp 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || true)
		ip route replace default dev wgwarp table 51820 2>/dev/null || true
	fi
	if [[ -z "$WARP_LOCAL_IP" && -f /etc/wireguard/wgwarp.conf ]]; then
		WARP_LOCAL_IP=$(grep -E '^\s*Address\s*=' /etc/wireguard/wgwarp.conf 2>/dev/null | head -n1 | cut -d'=' -f2 | cut -d'/' -f1 | tr -d ' \r\n' || true)
	fi
	while ip rule del table 51820 priority 100 2>/dev/null; do :; done
	while ip rule del table 51820 priority 101 2>/dev/null; do :; done
	if [[ -n "$WARP_LOCAL_IP" ]]; then
		ip rule add from "${WARP_LOCAL_IP}/32" table 51820 priority 100 2>/dev/null || true
	fi
	ip rule add oif wgwarp table 51820 priority 101 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# 9. High-Speed Split Tunneling, QUIC Blackhole Fix & Fail-Safe WARP Routing
# ------------------------------------------------------------------------------
function applyDomainSplitRulesLive() {
	echo -e "\n${CYAN}[*] Applying Bidirectional MSS=1200, Instant QUIC Fallback & WARP Policy Routing...${NC}"

	mkdir -p /etc/wireguard
	touch /etc/wireguard/split_domains.txt

	# Clean legacy port 53 redirects and conflicting MSS rules
	while iptables -t nat -D PREROUTING -i "${SERVER_WG_NIC:-wg0}" -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null; do :; done
	while iptables -t nat -D PREROUTING -i "${SERVER_WG_NIC:-wg0}" -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null; do :; done
	while iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
	while iptables -t mangle -D FORWARD -i "${SERVER_WG_NIC:-wg0}" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
	while iptables -t mangle -D FORWARD -o "${SERVER_WG_NIC:-wg0}" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
	while iptables -t mangle -D FORWARD -i "${SERVER_WG_NIC:-wg0}" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1280 2>/dev/null; do :; done
	while iptables -t mangle -D FORWARD -o "${SERVER_WG_NIC:-wg0}" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1280 2>/dev/null; do :; done
	while iptables -t mangle -D FORWARD -o wgwarp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1280 2>/dev/null; do :; done
	while iptables -t mangle -D FORWARD -i wgwarp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1280 2>/dev/null; do :; done

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

		for p in 64.4.240.0/21 66.211.168.0/21 173.0.80.0/20 173.224.160.0/19 185.177.52.0/22 192.148.20.0/23 198.54.120.0/22 216.113.160.0/19; do
			echo "add wg_direct_clean $p -exist" >> "$IPSET_BATCH"
		done

		for c in 108.174.0.0/20 144.2.0.0/19 185.63.144.0/22 199.101.160.0/22 216.52.16.0/20 65.156.227.0/24 8.247.168.0/24; do
			echo "add wg_split_v4 $c -exist" >> "$IPSET_BATCH"
		done

		for c in 173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 197.234.240.0/22 198.41.128.0/17 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22; do
			echo "add wg_split_v4 $c -exist" >> "$IPSET_BATCH"
		done

		ipset restore -! < "$IPSET_BATCH" 2>/dev/null || true
		rm -f "$IPSET_BATCH"
	fi

	ensureHostPublicIpBypassRules

	# Core FORWARD, ICMP, DNS & NAT Rules
	ipt_ensure_top filter INPUT 1 -p udp --dport "${SERVER_PORT:-4500}" -j ACCEPT
	ipt_ensure_top filter INPUT 2 -i "${SERVER_WG_NIC:-wg0}" -p udp --dport 53 -j ACCEPT
	ipt_ensure_top filter INPUT 3 -i "${SERVER_WG_NIC:-wg0}" -p tcp --dport 53 -j ACCEPT

	# Instant QUIC (>1280B UDP/443) Fallback: prevents 15-second HTTP/3 browser stalls when client MTU is 1420
	ipt_ensure_top filter FORWARD 1 -i "${SERVER_WG_NIC:-wg0}" -p udp --dport 443 -m length --length 1281:65535 -j REJECT --reject-with icmp-port-unreachable
	ipt_ensure_top filter FORWARD 2 -p icmp -j ACCEPT
	ipt_ensure_top filter FORWARD 3 -i "${SERVER_WG_NIC:-wg0}" -j ACCEPT
	ipt_ensure_top filter FORWARD 4 -o "${SERVER_WG_NIC:-wg0}" -j ACCEPT

	ipt_ensure_top nat POSTROUTING 1 -s 10.18.0.0/24 ! -o "${SERVER_WG_NIC:-wg0}" -j MASQUERADE
	ipt_ensure_top nat POSTROUTING 2 -s 10.19.0.0/24 ! -o "${SERVER_WG_NIC:-wg0}" -j MASQUERADE

	# If a client uses Local Server DNS (10.18.0.1 or 10.19.0.1), forward directly to 1.1.1.1 if local dnsmasq isn't bound
	if ! ss -uln 2>/dev/null | grep -q ":53 "; then
		ipt_ensure_top nat PREROUTING 1 -i "${SERVER_WG_NIC:-wg0}" -d 10.18.0.1 -p udp --dport 53 -j DNAT --to-destination 1.1.1.1:53
		ipt_ensure_top nat PREROUTING 2 -i "${SERVER_WG_NIC:-wg0}" -d 10.19.0.1 -p udp --dport 53 -j DNAT --to-destination 1.1.1.1:53
	fi

	# Force TCP MSS to 1200 in BOTH directions on wg0 (1200 MSS = 1240B IP packet <= 1280B WARP MTU)
	ipt_ensure_top mangle FORWARD 1 -i "${SERVER_WG_NIC:-wg0}" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200
	ipt_ensure_top mangle FORWARD 2 -o "${SERVER_WG_NIC:-wg0}" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200

	if command -v ipset &>/dev/null; then
		ipt_ensure_top mangle PREROUTING 1 -i "${SERVER_WG_NIC:-wg0}" -m set --match-set wg_direct_clean dst -j MARK --set-mark 0x100
		ipt_ensure_top mangle PREROUTING 2 -i "${SERVER_WG_NIC:-wg0}" -m set --match-set wg_direct_clean dst -j RETURN
	fi

	# Clear client WARP policy rules before live connectivity verification
	while ip rule del from 10.19.0.0/24 table 51820 priority 900 2>/dev/null; do :; done
	while ip rule del from 10.18.0.0/24 table 51820 priority 910 2>/dev/null; do :; done
	while ip rule del fwmark 0x51820 table 51820 priority 1000 2>/dev/null; do :; done

	local WARP_NIC=""
	if ip link show wgwarp &>/dev/null; then
		WARP_NIC="wgwarp"
	elif ip link show CloudflareWARP &>/dev/null; then
		WARP_NIC="CloudflareWARP"
	fi

	if [[ -n "$WARP_NIC" ]] && [[ -f /etc/wireguard/warp_egress_enabled ]]; then
		ip route replace default dev "$WARP_NIC" table 51820 2>/dev/null || ip route add default dev "$WARP_NIC" table 51820 2>/dev/null || true
		ipt_ensure_top nat POSTROUTING 1 -o "$WARP_NIC" -j MASQUERADE
		ipt_ensure_top mangle FORWARD 1 -o "$WARP_NIC" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200
		ipt_ensure_top mangle FORWARD 2 -i "$WARP_NIC" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200

		# FAIL-SAFE GUARD: Verify WARP actually passes traffic before routing clients into table 51820!
		if curl -4 --interface "$WARP_NIC" -sSf --max-time 4 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep -q "warp=on"; then
			ip rule add from 10.19.0.0/24 table 51820 priority 900 2>/dev/null || true
			if [[ "${WARP_GLOBAL_MODE:-full}" == "full" ]]; then
				ip rule add from 10.18.0.0/24 table 51820 priority 910 2>/dev/null || true
			fi
			ip rule add fwmark 0x51820 table 51820 priority 1000 2>/dev/null || true

			if command -v ipset &>/dev/null; then
				ipt_ensure_top mangle PREROUTING 3 -i "${SERVER_WG_NIC:-wg0}" -m set --match-set wg_split_v4 dst -j MARK --set-mark 0x51820
			fi
			echo -e "${GREEN}[✔] Verified live WARP tunnel (warp=on)! Client traffic is now warping around ${SERVER_PUB_IP}.${NC}"
		else
			echo -e "${YELLOW}[!] Fail-Safe Guard: ${WARP_NIC} handshake pending; keeping clients on direct VPS routing so traffic never blackholes.${NC}"
		fi
	fi

	optimizeNicQueuesAndRPS
}

# ------------------------------------------------------------------------------
# 10. Self-Healing Kernel Cloudflare WARP Provisioner (MTU 1280 + Multi-Endpoint)
# ------------------------------------------------------------------------------
function installWarpWatchdog() {
	cat << 'WATCHDOG_SH' > /usr/local/bin/wg-warp-watchdog.sh
#!/bin/bash
if [[ ! -f /etc/wireguard/warp_egress_enabled ]] || ! ip link show wgwarp &>/dev/null; then
	exit 0
fi

# Ensure wgwarp self-routing rules (priority 100/101) are present before testing curl
WARP_IP=$(ip -4 addr show dev wgwarp 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || true)
if [[ -n "$WARP_IP" ]] && ! ip rule show | grep -q "from ${WARP_IP} lookup 51820"; then
	ip rule add from "${WARP_IP}/32" table 51820 priority 100 2>/dev/null || true
	ip rule add oif wgwarp table 51820 priority 101 2>/dev/null || true
fi

if ! curl -4 --interface wgwarp -sSf --max-time 4 https://1.1.1.1/cdn-cgi/trace >/dev/null 2>&1; then
	PEER_KEY=$(wg show wgwarp peers 2>/dev/null | head -n1)
	if [[ -n "$PEER_KEY" ]]; then
		ENDPOINTS=(
			"162.159.192.1:2408"
			"162.159.193.1:2408"
			"188.114.96.1:2408"
			"162.159.192.1:500"
			"162.159.192.1:1701"
			"162.159.192.1:4500"
		)
		for ep in "${ENDPOINTS[@]}"; do
			wg set wgwarp fwmark 0x51888 peer "$PEER_KEY" endpoint "$ep" persistent-keepalive 15 2>/dev/null || true
			sleep 1
			if curl -4 --interface wgwarp -sSf --max-time 3 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep -q "warp=on"; then
				ip rule show | grep -q "from 10.19.0.0/24 lookup 51820" || ip rule add from 10.19.0.0/24 table 51820 priority 900 2>/dev/null || true
				ip rule show | grep -q "from 10.18.0.0/24 lookup 51820" || ip rule add from 10.18.0.0/24 table 51820 priority 910 2>/dev/null || true
				exit 0
			fi
		done
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

function writeWgwarpConfigFile() {
	local PRIV_KEY="$1"
	local IPV4_ADDR="$2"
	local PEER_PUB="$3"
	local ENDPOINT_ADDR="${4:-162.159.192.1:2408}"

	cat << WGWARP_EOF > /etc/wireguard/wgwarp.conf
[Interface]
PrivateKey = ${PRIV_KEY}
Address = ${IPV4_ADDR}/32
MTU = 1280
Table = 51820
FwMark = 0x51888

PostUp = ip link set dev wgwarp txqueuelen 10000 mtu 1280 2>/dev/null || true
PostUp = sysctl -w net.ipv4.conf.wgwarp.rp_filter=0 >/dev/null 2>&1 || true
PostUp = ip rule del from ${IPV4_ADDR}/32 table 51820 priority 100 2>/dev/null || true
PostUp = ip rule add from ${IPV4_ADDR}/32 table 51820 priority 100 2>/dev/null || true
PostUp = ip rule del oif wgwarp table 51820 priority 101 2>/dev/null || true
PostUp = ip rule add oif wgwarp table 51820 priority 101 2>/dev/null || true
PostUp = iptables -t nat -C POSTROUTING -o wgwarp -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -o wgwarp -j MASQUERADE
PostUp = iptables -t mangle -C FORWARD -o wgwarp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200 2>/dev/null || iptables -t mangle -I FORWARD 1 -o wgwarp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200
PostUp = iptables -t mangle -C FORWARD -i wgwarp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200 2>/dev/null || iptables -t mangle -I FORWARD 2 -i wgwarp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200

PostDown = ip rule del from ${IPV4_ADDR}/32 table 51820 priority 100 2>/dev/null || true
PostDown = ip rule del oif wgwarp table 51820 priority 101 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -o wgwarp -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -o wgwarp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -i wgwarp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200 2>/dev/null || true

[Peer]
PublicKey = ${PEER_PUB}
AllowedIPs = 0.0.0.0/0
Endpoint = ${ENDPOINT_ADDR}
PersistentKeepalive = 15
WGWARP_EOF
	chmod 600 /etc/wireguard/wgwarp.conf
}

function setupCloudflareWarpClient() {
	echo -e "\n${CYAN}${BOLD}⚡ Configuring Kernel-Native Cloudflare WARP (MTU 1280 | MSS 1200 | FwMark 0x51888)...${NC}"
	mkdir -p /etc/wireguard
	touch /etc/wireguard/warp_egress_enabled

	if systemctl is-active --quiet warp-svc 2>/dev/null; then
		warp-cli --accept-tos disconnect 2>/dev/null || true
		systemctl stop warp-svc 2>/dev/null || true
		systemctl disable warp-svc 2>/dev/null || true
	fi

	ensureHostPublicIpBypassRules

	local WARP_PRIV_KEY=""
	local WARP_IPV4=""
	local WARP_PEER_PUB="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="

	# 1. Preserve existing registered WARP keypair if present (avoids Cloudflare API 429 rate-limit!)
	if [[ -f /etc/wireguard/wgwarp.conf ]]; then
		WARP_PRIV_KEY=$(grep -E '^\s*PrivateKey\s*=' /etc/wireguard/wgwarp.conf 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d ' \r\n' || true)
		WARP_IPV4=$(grep -E '^\s*Address\s*=' /etc/wireguard/wgwarp.conf 2>/dev/null | head -n1 | cut -d'=' -f2 | cut -d'/' -f1 | tr -d ' \r\n' || true)
	fi

	# 2. Only call Cloudflare registration API if we don't already have a keypair
	if [[ -z "$WARP_PRIV_KEY" || -z "$WARP_IPV4" ]]; then
		echo -e "${CYAN}[*] Registering new Cloudflare WARP WireGuard keypair...${NC}"
		WARP_PRIV_KEY=$(wg genkey)
		local WARP_PUB_KEY
		WARP_PUB_KEY=$(echo "$WARP_PRIV_KEY" | wg pubkey)
		local TOS_DATE
		TOS_DATE=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

		local REG_JSON=""
		for api_url in "https://api.cloudflareclient.com/v0a2158/reg" "https://api.cloudflareclient.com/v0a2483/reg"; do
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
			WARP_IPV4=$(echo "$REG_JSON" | jq -r '.config.interface.addresses.v4')
			WARP_PEER_PUB=$(echo "$REG_JSON" | jq -r '.config.peers[0].public_key // "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="')
		fi
	fi

	if [[ -n "$WARP_PRIV_KEY" && -n "$WARP_IPV4" ]]; then
		writeWgwarpConfigFile "$WARP_PRIV_KEY" "$WARP_IPV4" "$WARP_PEER_PUB" "162.159.192.1:2408"

		wg-quick down wgwarp >/dev/null 2>&1 || true
		ip link delete dev wgwarp >/dev/null 2>&1 || true
		systemctl daemon-reload >/dev/null 2>&1 || true
		systemctl enable "wg-quick@wgwarp" >/dev/null 2>&1 || true
		systemctl restart "wg-quick@wgwarp" 2>/dev/null || wg-quick up wgwarp 2>/dev/null || true

		ensureHostPublicIpBypassRules
		optimizeNicQueuesAndRPS

		# Multi-endpoint verification loop (tests 2408, 500, 1701, 4500 until warp=on succeeds)
		local CANDIDATE_EPS=(
			"162.159.192.1:2408"
			"162.159.193.1:2408"
			"188.114.96.1:2408"
			"162.159.192.1:500"
			"162.159.192.1:1701"
			"162.159.192.1:4500"
		)
		local WARP_OK=0
		for ep in "${CANDIDATE_EPS[@]}"; do
			wg set wgwarp fwmark 0x51888 peer "$WARP_PEER_PUB" endpoint "$ep" persistent-keepalive 15 2>/dev/null || true
			if curl -4 --interface wgwarp -sSf --max-time 4 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep -q "warp=on"; then
				sed -i "s|^Endpoint\s*=.*|Endpoint = ${ep}|" /etc/wireguard/wgwarp.conf 2>/dev/null || true
				echo -e "${GREEN}[✔] Kernel WARP Connected on Endpoint ${ep} (Address: ${WARP_IPV4} | MTU: 1280)!${NC}"
				WARP_OK=1
				break
			fi
		done

		installWarpWatchdog
		[[ $WARP_OK -eq 1 ]] && return 0
	fi
	echo -e "${YELLOW}[!] Could not verify WARP handshake yet; watchdog will retry in background.${NC}"
}

function autoRepairNetwork() {
	echo -e "\n${CYAN}${BOLD}🛠️ Upgrading & Repairing WireGuard + Cloudflare WARP (v4.2)...${NC}"

	cat << 'RESOLV_CLEAN_EOF' > /etc/resolv.conf 2>/dev/null || true
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
RESOLV_CLEAN_EOF

	sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
	sysctl -w net.core.rmem_default=33554432 >/dev/null 2>&1 || true
	sysctl -w net.core.wmem_default=33554432 >/dev/null 2>&1 || true
	sysctl --system -q >/dev/null 2>&1 || true

	if [[ -f /etc/wireguard/params ]]; then
		source /etc/wireguard/params
	fi
	writeUnifiedWg0Config

	ensureHostPublicIpBypassRules

	systemctl daemon-reload >/dev/null 2>&1 || true
	systemctl restart "wg-quick@${SERVER_WG_NIC:-wg0}" 2>/dev/null || wg-quick up "${SERVER_WG_NIC:-wg0}" 2>/dev/null || true

	touch /etc/wireguard/warp_egress_enabled
	setupCloudflareWarpClient
	applyDomainSplitRulesLive

	echo -e "${CYAN}--- Live Post-Repair Connectivity Verification ---${NC}"
	echo -e "${BOLD}1. Physical VPS Interface (${SERVER_PUB_NIC:-eth0}):${NC}"
	curl -4 --interface "${SERVER_PUB_NIC:-eth0}" -sSf --max-time 4 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep -E '^(ip|warp|colo)=' | sed 's/^/   /' || echo "   Direct trace error"
	echo -e "${BOLD}2. Kernel WARP Interface (wgwarp):${NC}"
	curl -4 --interface wgwarp -sSf --max-time 4 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep -E '^(ip|warp|colo)=' | sed 's/^/   /' || echo "   WARP trace pending"
	echo -e "\n${GREEN}[✔] v4.2 Auto-Repair Complete!${NC}\n"
}

function domainSplitTunneling() {
	applyDomainSplitRulesLive
}

function realTimeLogging() {
	wg show
	echo ""
	ip rule show
}

function geoIpAntiVpnShield() {
	echo -e "${GREEN}Bidirectional MSS=1200, WARP MTU=1280, QUIC Fallback, and Hardware Offloads ACTIVE.${NC}"
}

function provisionWebConsole() {
	echo -e "${YELLOW}Web Console helper ready.${NC}"
}

function settingsManager() {
	echo -e "Public IP: ${SERVER_PUB_IP} | Port: ${SERVER_PORT} | Mode: ${WARP_GLOBAL_MODE:-full}"
}

function cloudflareAntiFlagEngine() {
	echo "1) Refresh High-Speed Kernel WARP (wgwarp MTU 1280)"
	echo "2) Toggle WARP Scope (Full WARP vs Split WARP)"
	echo "3) Run Live Dual-Path Speed & IP Diagnostic"
	echo "4) Disable WARP (Direct VPS Egress Only)"
	echo "5) Back"
	read -rp "Select [1-5]: " CF_OPT
	case "$CF_OPT" in
		1) setupCloudflareWarpClient; applyDomainSplitRulesLive ;;
		2)
			if [[ "${WARP_GLOBAL_MODE:-full}" == "full" ]]; then
				WARP_GLOBAL_MODE="split"
			else
				WARP_GLOBAL_MODE="full"
			fi
			sed -i "s/^WARP_GLOBAL_MODE=.*/WARP_GLOBAL_MODE=${WARP_GLOBAL_MODE}/" /etc/wireguard/params 2>/dev/null || echo "WARP_GLOBAL_MODE=${WARP_GLOBAL_MODE}" >> /etc/wireguard/params
			applyDomainSplitRulesLive
			;;
		3)
			echo -e "\n${BOLD}1. Physical VPS Interface (${SERVER_PUB_NIC:-eth0}):${NC}"
			curl -4 --interface "${SERVER_PUB_NIC:-eth0}" -sSf --max-time 4 https://1.1.1.1/cdn-cgi/trace | grep -E '^(ip|warp|colo)='
			echo -e "\n${BOLD}2. Kernel WARP Interface (wgwarp):${NC}"
			curl -4 --interface wgwarp -sSf --max-time 4 https://1.1.1.1/cdn-cgi/trace | grep -E '^(ip|warp|colo)='
			;;
		4)
			rm -f /etc/wireguard/warp_egress_enabled
			while ip rule del from 10.19.0.0/24 table 51820 priority 900 2>/dev/null; do :; done
			while ip rule del from 10.18.0.0/24 table 51820 priority 910 2>/dev/null; do :; done
			while ip rule del fwmark 0x51820 table 51820 priority 1000 2>/dev/null; do :; done
			echo -e "${GREEN}[✔] Reverted to Direct VPS Egress.${NC}"
			;;
	esac
}

function uninstallWg() {
	systemctl stop "wg-quick@${SERVER_WG_NIC:-wg0}" "wg-quick@wgwarp" wg-warp-watchdog.timer 2>/dev/null || true
	wg-quick down "${SERVER_WG_NIC:-wg0}" 2>/dev/null || true
	wg-quick down wgwarp 2>/dev/null || true
	rm -rf /etc/wireguard
	exit 0
}

function manageMenu() {
	while true; do
		echo -e "\n${PURPLE}=================================================================${NC}"
		echo -e "          ${GREEN}${BOLD}🍪  Cookie's Easy WireGuard Manager v4.2${NC}"
		echo -e "${PURPLE}=================================================================${NC}"
		echo " [1] Setup WireGuard Server        [6] Real-Time Logging"
		echo " [2] Add New Client                [9] Cloudflare WARP Engine"
		echo " [3] Configure Clients             [10] Full-Speed Auto-Repair"
		echo " [4] Backup Server                 [r] Uninstall"
		echo " [5] Re-apply Split/Speed Rules    [q] Exit"
		read -rp "Option: " MENU_OPTION
		case "${MENU_OPTION}" in
			1) installQuestions; installWireGuard ;;
			2) newClient ;;
			3) configureClients ;;
			4) backupRestoreManager ;;
			5) domainSplitTunneling ;;
			6) realTimeLogging ;;
			9) cloudflareAntiFlagEngine ;;
			10) autoRepairNetwork ;;
			r|R) uninstallWg ;;
			q|Q) exit 0 ;;
		esac
	done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	initialCheck
	[[ -e /etc/wireguard/params ]] && source /etc/wireguard/params
	if [[ "${1:-}" == "--repair" || "${1:-}" == "-r" || "${1:-}" == "repair" ]]; then
		autoRepairNetwork
		exit 0
	fi
	cleanupAndSecureRootFolder
	manageMenu
fi
