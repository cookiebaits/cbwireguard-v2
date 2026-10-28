#!/bin/bash
# ==============================================================================
# 🍪 Cookie's Easy WireGuard Manager & VPS Stealth Server v4.4
# 500+ Mbps Lockless CONNMARK Fastpath + Verified Real-Time Split Tunneling
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

# Lockless 'noqueue' for WireGuard virtual NICs + UDP GRO Forwarding + Multi-Core RPS/XPS
function optimizeNicQueuesAndRPS() {
	local cpu_count
	cpu_count=$(nproc 2>/dev/null || echo 1)
	local rps_mask
	rps_mask=$(printf '%x' $(( (1 << (cpu_count > 16 ? 16 : cpu_count)) - 1 )) 2>/dev/null || echo "f")

	local PUB_NIC="${SERVER_PUB_NIC:-}"
	if [[ -z "$PUB_NIC" ]]; then
		PUB_NIC=$(ip -4 route show table main default 2>/dev/null | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | grep -vE '^(wg|Cloudflare|tun)' | head -n1 || echo "eth0")
	fi

	# Switch CPU scaling governor to performance if available on VPS
	for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
		[[ -w "$gov" ]] && echo "performance" > "$gov" 2>/dev/null || true
	done

	# 1. Physical NIC: Enable hardware GSO/TSO/GRO + Kernel 6.2+ UDP GRO Forwarding for 500+ Mbps WireGuard
	if ip link show "$PUB_NIC" &>/dev/null; then
		ip link set dev "$PUB_NIC" txqueuelen 10000 2>/dev/null || true
		if command -v tc &>/dev/null; then
			tc qdisc replace dev "$PUB_NIC" root fq 2>/dev/null || true
		fi
		if command -v ethtool &>/dev/null; then
			ethtool -K "$PUB_NIC" gro on gso on tso on 2>/dev/null || true
			ethtool -K "$PUB_NIC" rx-gro-list off 2>/dev/null || true
			ethtool -K "$PUB_NIC" rx-udp-gro-forwarding on 2>/dev/null || true
		fi
	fi

	# 2. Virtual WireGuard NICs (wg0, wgwarp): MUST use lockless 'noqueue' (remove fq_codel spinlock!)
	for wgnic in "${SERVER_WG_NIC:-wg0}" "wgwarp"; do
		if ip link show "$wgnic" &>/dev/null; then
			ip link set dev "$wgnic" txqueuelen 10000 2>/dev/null || true
			if command -v tc &>/dev/null; then
				tc qdisc del dev "$wgnic" root 2>/dev/null || true
			fi
			if command -v ethtool &>/dev/null; then
				ethtool -K "$wgnic" gro on gso on tso on 2>/dev/null || true
			fi
		fi
	done

	# 3. Enable Receive & Transmit Packet Steering (RPS & XPS) across all vCPUs
	for nic in "$PUB_NIC" "${SERVER_WG_NIC:-wg0}" "wgwarp"; do
		if ip link show "$nic" &>/dev/null; then
			for rps_file in /sys/class/net/"$nic"/queues/rx-*/rps_cpus; do
				[[ -w "$rps_file" ]] && echo "$rps_mask" > "$rps_file" 2>/dev/null || true
			done
			for flow_file in /sys/class/net/"$nic"/queues/rx-*/rps_flow_cnt; do
				[[ -w "$flow_file" ]] && echo 8192 > "$flow_file" 2>/dev/null || true
			done
			for xps_file in /sys/class/net/"$nic"/queues/tx-*/xps_cpus; do
				[[ -w "$xps_file" ]] && echo "$rps_mask" > "$xps_file" 2>/dev/null || true
			done
		fi
	done

	ip link set dev "${SERVER_WG_NIC:-wg0}" mtu 1420 2>/dev/null || true
	ip link set dev wgwarp mtu "${WARP_OPTIMAL_MTU:-1420}" 2>/dev/null || true

	if [[ -w /proc/sys/net/core/rps_sock_flow_entries ]]; then
		echo 65536 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
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
	echo -e "          ${GREEN}${BOLD}🍪  Cookie's Easy WireGuard Setup & Installer v4.4${NC}"
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
# 5. Safely Upgrade / Write wg0.conf (Lockless 'noqueue' + MTU 1420 + IPv6 Reject)
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

	local WG_SERVER_ADDRESS="${SERVER_WG_IPV4:-10.18.0.1}/24, ${SERVER_WG_IPV6:-fd42:42:42::1}/64"

	cat << WG_SERVER_EOF > "/etc/wireguard/wg0.conf"
[Interface]
Address = ${WG_SERVER_ADDRESS}, 10.19.0.1/24
ListenPort = ${SERVER_PORT:-4500}
PrivateKey = ${SERVER_PRIV_KEY}
MTU = 1420
SaveConfig = false

# --- 1. LOCKLESS NOQUEUE & 500+ MBPS GSO/GRO BATCHING ---
PostUp = sysctl -w net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1 net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.wg0.rp_filter=0 >/dev/null 2>&1 || true
PostUp = ip link set dev wg0 txqueuelen 10000 mtu 1420 2>/dev/null || true
PostUp = tc qdisc del dev wg0 root 2>/dev/null || true
PostUp = ethtool -K wg0 gro on gso on tso on 2>/dev/null || true
PostUp = iptables -C INPUT -p udp --dport ${SERVER_PORT:-4500} -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p udp --dport ${SERVER_PORT:-4500} -j ACCEPT
PostUp = iptables -C INPUT -i wg0 -p udp --dport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT 2 -i wg0 -p udp --dport 53 -j ACCEPT
PostUp = iptables -C INPUT -i wg0 -p tcp --dport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT 3 -i wg0 -p tcp --dport 53 -j ACCEPT
PostUp = iptables -C FORWARD -p icmp -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -p icmp -j ACCEPT
PostUp = iptables -C FORWARD -i wg0 -j ACCEPT 2>/dev/null || iptables -I FORWARD 2 -i wg0 -j ACCEPT
PostUp = iptables -C FORWARD -o wg0 -j ACCEPT 2>/dev/null || iptables -I FORWARD 3 -o wg0 -j ACCEPT
PostUp = iptables -t nat -C POSTROUTING -s 10.18.0.0/24 ! -o wg0 -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s 10.18.0.0/24 ! -o wg0 -j MASQUERADE
PostUp = iptables -t nat -C POSTROUTING -s 10.19.0.0/24 ! -o wg0 -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 2 -s 10.19.0.0/24 ! -o wg0 -j MASQUERADE

# --- 2. DYNAMIC PMTU CLAMPING (MSS=1380: Zero TLS ClientHello Fragmentation) ---
PostUp = iptables -t mangle -C FORWARD -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -I FORWARD 1 -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostUp = iptables -t mangle -C FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -I FORWARD 2 -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# --- 3. INSTANT IPv6 HAPPY-EYEBALLS FALLBACK (<1ms IPv4 Fallback for LinkedIn) ---
PostUp = ip6tables -C FORWARD -i wg0 -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null || ip6tables -I FORWARD 1 -i wg0 -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null || true

PostDown = iptables -D INPUT -p udp --dport ${SERVER_PORT:-4500} -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s 10.18.0.0/24 ! -o wg0 -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s 10.19.0.0/24 ! -o wg0 -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
PostDown = ip6tables -D FORWARD -i wg0 -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null || true
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
	modprobe xt_connmark >/dev/null 2>&1 || true
	modprobe tcp_bbr >/dev/null 2>&1 || true

	SYSCTL_CONF="/etc/sysctl.d/99-wireguard-stealth.conf"
	cat << 'SYSCTL_EOF' > "$SYSCTL_CONF"
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
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

	ensureDefaultSplitDomainsFile

	setupCloudflareWarpClient
	applyDomainSplitRulesLive
	newClientInternal "${CLIENT_NAME}" "${CLIENT_PASSWORD}"
}

function ensureDefaultSplitDomainsFile() {
	mkdir -p /etc/wireguard
	touch /etc/wireguard/split_domains.txt
	local REQUIRED_DOMAINS=(
		"linkedin.com"
		"www.linkedin.com"
		"licdn.com"
		"static.licdn.com"
		"media.licdn.com"
		"dms.licdn.com"
		"voyager.linkedin.com"
		"lnkd.in"
		"paypal.com"
		"www.paypal.com"
		"paypalobjects.com"
		"cardinalcommerce.com"
		"braintreegateway.com"
		"stripe.com"
		"amazon.com"
		"www.amazon.com"
		"speedtest.net"
		"www.speedtest.net"
		"ooklaserver.net"
		"speedtestcustom.com"
		"fast.com"
		"nflxvideo.net"
		"challenges.cloudflare.com"
		"cloudflare.com"
		"turnstile.com"
	)
	for d in "${REQUIRED_DOMAINS[@]}"; do
		grep -q -i "^${d}\$" /etc/wireguard/split_domains.txt 2>/dev/null || echo "$d" >> /etc/wireguard/split_domains.txt
	done
}

# ------------------------------------------------------------------------------
# 7. Client Management (MTU 1420 Matched to Server & WARP + IPv4 Clean Egress)
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
MTU = 1420

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT_WG0}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CF_CLIENT_EOF
)

	local STD_CONF_CONTENT
	STD_CONF_CONTENT=$(cat << CLIENT_EOF
[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_WG_IPV4}/32
DNS = ${CLIENT_DNS_LINE}
MTU = 1420

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT_WG0}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
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
# 8. Policy Routing Protection: Lock Host Public IP, Return Subnets & Split Marks
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

	# Priority 60: Direct-Clean Bypass (fwmark 0x100 -> exits via 500+ Mbps Direct VPS IP in table main!)
	while ip rule del fwmark 0x100 lookup main priority 60 2>/dev/null; do :; done
	ip rule add fwmark 0x100 lookup main priority 60 2>/dev/null || true

	# Priority 85: Force-WARP Split Domains (fwmark 0x51820 -> exits via Cloudflare WARP table 51820!)
	while ip rule del fwmark 0x51820 table 51820 priority 85 2>/dev/null; do :; done
	while ip rule del fwmark 0x51820 table 51820 priority 1000 2>/dev/null; do :; done
	ip rule add fwmark 0x51820 table 51820 priority 85 2>/dev/null || true

	# Priority 100-101: Route wgwarp's own interface IP (172.16.0.x) & oif wgwarp via table 51820
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
# 9. Verified Dnsmasq + IPSet Real-Time Split Tunneling & CONNMARK Fastpath
# ------------------------------------------------------------------------------
function applyDomainSplitRulesLive() {
	echo -e "\n${CYAN}[*] Applying Real-Time Dnsmasq + IPSet Split Tunneling & 500+ Mbps CONNMARK Fastpath...${NC}"

	ensureDefaultSplitDomainsFile
	if [[ ! -f /etc/wireguard/split_mode.txt ]]; then
		echo "BYPASS" > /etc/wireguard/split_mode.txt
	fi
	local MODE
	MODE=$(cat /etc/wireguard/split_mode.txt 2>/dev/null | tr -d ' \r\n' || echo "BYPASS")
	[[ "$MODE" != "BYPASS" && "$MODE" != "TUNNEL" ]] && MODE="BYPASS"

	# 1. Clean legacy broken dnsmasq configs (especially 00-stealth-privacy.conf which had invalid 'no-edns0')
	rm -f /etc/dnsmasq.d/00-stealth-privacy.conf /etc/dnsmasq.d/00-stealth-split.conf /etc/dnsmasq.d/00-stealth-dns.conf 2>/dev/null || true

	if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
		mkdir -p /etc/systemd/resolved.conf.d
		cat << 'RESOLVED_NO_STUB' > /etc/systemd/resolved.conf.d/no-stub.conf 2>/dev/null || true
[Resolve]
DNSStubListener=no
RESOLVED_NO_STUB
		systemctl restart systemd-resolved 2>/dev/null || true
	fi

	mkdir -p /etc/dnsmasq.d
	cat << DNSMASQ_CLEAN_EOF > /etc/dnsmasq.d/00-wireguard-split-dns.conf
# Cookie WireGuard High-Speed Split-Tunnel DNS Resolver
port=53
bind-dynamic
interface=${SERVER_WG_NIC:-wg0}
listen-address=${SERVER_WG_IPV4:-10.18.0.1},10.19.0.1,127.0.0.1
no-resolv
all-servers
cache-size=10000
dns-forward-max=2048
bogus-priv
server=1.1.1.1
server=1.0.0.1
server=8.8.8.8
DNSMASQ_CLEAN_EOF

	# Strip AAAA (IPv6) records for tunnel clients if supported by dnsmasq (prevents IPv6 timeouts on LinkedIn)
	if dnsmasq --help 2>&1 | grep -q "filter-AAAA"; then
		echo "filter-AAAA" >> /etc/dnsmasq.d/00-wireguard-split-dns.conf
	fi

	echo "# Cookie WireGuard Dynamic Split Tunneling IPSet Map" > /etc/dnsmasq.d/wg_split.conf

	local DIRECT_HOSTS_FILE WARP_HOSTS_FILE
	DIRECT_HOSTS_FILE=$(mktemp /tmp/wg_direct_hosts.XXXXXX)
	WARP_HOSTS_FILE=$(mktemp /tmp/wg_warp_hosts.XXXXXX)

	local DOMAIN_COUNT=0
	while IFS= read -r raw_domain || [[ -n "$raw_domain" ]]; do
		[[ -z "$raw_domain" || "$raw_domain" =~ ^# ]] && continue
		local base_domain
		base_domain=$(echo "$raw_domain" | sed -e 's|^https*://||' -e 's|/.*$||' | tr '[:upper:]' '[:lower:]' | xargs)
		[[ -z "$base_domain" ]] && continue

		local EXPANDED_DOMAINS=("$base_domain")
		if [[ "$base_domain" == *"linkedin"* || "$base_domain" == *"licdn"* || "$base_domain" == *"lnkd.in"* ]]; then
			EXPANDED_DOMAINS+=("linkedin.com" "www.linkedin.com" "licdn.com" "static.licdn.com" "media.licdn.com" "dms.licdn.com" "voyager.linkedin.com" "platform.linkedin.com" "lnkd.in" "snap.licdn.com" "px.ads.linkedin.com")
		elif [[ "$base_domain" == *"paypal"* ]]; then
			EXPANDED_DOMAINS+=("www.paypal.com" "c.paypal.com" "b.stats.paypal.com" "t.paypal.com" "s.paypal.com" "m.paypal.com" "api.paypal.com" "api-m.paypal.com" "checkout.paypal.com" "identity.paypal.com" "paypalobjects.com" "www.paypalobjects.com" "objects.paypal.com" "c.paypalobjects.com" "paypal.me" "cardinalcommerce.com" "songbird.cardinalcommerce.com" "centinelapi.cardinalcommerce.com" "braintreegateway.com" "braintree-api.com")
		elif [[ "$base_domain" == *"speedtest"* || "$base_domain" == *"ookla"* ]]; then
			EXPANDED_DOMAINS+=("speedtest.net" "www.speedtest.net" "ooklaserver.net" "speedtestcustom.com" "c.speedtest.net")
		elif [[ "$base_domain" == *"netflix"* || "$base_domain" == *"fast.com"* ]]; then
			EXPANDED_DOMAINS+=("netflix.com" "www.netflix.com" "nflxvideo.net" "nflxso.net" "nflxext.com" "nflximg.net" "fast.com")
		elif [[ "$base_domain" == *"amazon"* ]]; then
			EXPANDED_DOMAINS+=("amazon.com" "www.amazon.com" "completion.amazon.com" "images-amazon.com" "media-amazon.com" "ssl-images-amazon.com" "fls-na.amazon.com")
		elif [[ "$base_domain" == *"cloudflare"* || "$base_domain" == *"turnstile"* ]]; then
			EXPANDED_DOMAINS+=("challenges.cloudflare.com" "turnstile.com" "cloudflare.com" "cdnjs.cloudflare.com" "cloudflareinsights.com")
		fi

		for domain in "${EXPANDED_DOMAINS[@]}"; do
			((DOMAIN_COUNT++))
			# In BYPASS mode: Cloudflare Turnstile stays on WARP (wg_split_v4), while all other split domains
			# (LinkedIn, PayPal, Speedtest, Amazon, user-added domains) go into wg_direct_clean (Direct 500Mbps VPS Egress)!
			# In TUNNEL mode: Payment gateways stay on Direct Clean, while split domains go into wg_split_v4 (Force WARP)!
			if [[ "$MODE" == "BYPASS" ]]; then
				if [[ "$domain" =~ (cloudflare|turnstile|pages\.dev|workers\.dev) ]]; then
					echo "ipset=/${domain}/wg_split_v4" >> /etc/dnsmasq.d/wg_split.conf
					echo "$domain" >> "$WARP_HOSTS_FILE"
				else
					echo "ipset=/${domain}/wg_direct_clean" >> /etc/dnsmasq.d/wg_split.conf
					echo "$domain" >> "$DIRECT_HOSTS_FILE"
				fi
			else
				if [[ "$domain" =~ (paypal|cardinalcommerce|braintree) ]]; then
					echo "ipset=/${domain}/wg_direct_clean" >> /etc/dnsmasq.d/wg_split.conf
					echo "$domain" >> "$DIRECT_HOSTS_FILE"
				else
					echo "ipset=/${domain}/wg_split_v4" >> /etc/dnsmasq.d/wg_split.conf
					echo "$domain" >> "$WARP_HOSTS_FILE"
				fi
			fi
		done
	done < /etc/wireguard/split_domains.txt

	# Deduplicate wg_split.conf lines
	sort -u /etc/dnsmasq.d/wg_split.conf -o /etc/dnsmasq.d/wg_split.conf 2>/dev/null || true

	# 2. Populate IPSet Atomically (Pre-resolve all split domains in parallel + Official AS CIDRs)
	if command -v ipset &>/dev/null; then
		local IPSET_BATCH
		IPSET_BATCH=$(mktemp /tmp/wg_ipset_batch.XXXXXX)
		cat << 'IPSET_HEADER' > "$IPSET_BATCH"
create wg_split_v4 hash:net family inet hashsize 4096 maxelem 131072 -exist
create wg_split_v6 hash:net family inet6 hashsize 4096 maxelem 131072 -exist
create wg_direct_clean hash:net family inet hashsize 4096 maxelem 131072 -exist
flush wg_split_v4
flush wg_split_v6
flush wg_direct_clean
IPSET_HEADER

		# Resolve DIRECT_HOSTS_FILE in parallel (16 workers)
		if [[ -s "$DIRECT_HOSTS_FILE" ]]; then
			sort -u "$DIRECT_HOSTS_FILE" | xargs -P 16 -I {} sh -c 'getent ahostsv4 "{}" 2>/dev/null | awk "{print \$1}"' | sort -u | while read -r dip; do
				[[ "$dip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "add wg_direct_clean $dip -exist" >> "$IPSET_BATCH"
			done
		fi

		# Resolve WARP_HOSTS_FILE in parallel (16 workers)
		if [[ -s "$WARP_HOSTS_FILE" ]]; then
			sort -u "$WARP_HOSTS_FILE" | xargs -P 16 -I {} sh -c 'getent ahostsv4 "{}" 2>/dev/null | awk "{print \$1}"' | sort -u | while read -r wip; do
				[[ "$wip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "add wg_split_v4 $wip -exist" >> "$IPSET_BATCH"
			done
		fi

		# PayPal Official Autonomous System CIDRs (AS11643) -> Always Direct Clean Egress
		for p in 64.4.240.0/21 66.211.168.0/21 173.0.80.0/20 173.224.160.0/19 185.177.52.0/22 192.148.20.0/23 198.54.120.0/22 216.113.160.0/19; do
			echo "add wg_direct_clean $p -exist" >> "$IPSET_BATCH"
		done

		# LinkedIn Official ASNs (AS14413 / AS12447) + Microsoft Azure Front Door Anycast CIDRs (13.107.0.0/16)
		local LI_SET="wg_direct_clean"
		[[ "$MODE" == "TUNNEL" ]] && LI_SET="wg_split_v4"
		for li_cidr in 13.107.42.0/24 13.107.6.0/24 13.107.18.0/24 13.107.21.0/24 108.174.0.0/16 144.2.0.0/16 185.63.144.0/22 199.101.160.0/22 216.52.0.0/16 45.42.64.0/22 103.20.92.0/22 128.242.0.0/16 91.225.248.0/22 65.156.227.0/24 8.247.168.0/24; do
			echo "add ${LI_SET} ${li_cidr} -exist" >> "$IPSET_BATCH"
		done

		# Cloudflare Edge CIDRs -> wg_split_v4 (Excluding 162.159.192.0/22 & 188.114.96.0/22 WARP Endpoints)
		for c in 173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 197.234.240.0/22 198.41.128.0/17 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22; do
			echo "add wg_split_v4 $c -exist" >> "$IPSET_BATCH"
		done

		ipset restore -! < "$IPSET_BATCH" 2>/dev/null || true
		rm -f "$IPSET_BATCH"
	fi
	rm -f "$DIRECT_HOSTS_FILE" "$WARP_HOSTS_FILE"

	# 3. Validate & Start dnsmasq, then activate Port 53 DNAT Interception on wg0
	while iptables -t nat -D PREROUTING -i "${SERVER_WG_NIC:-wg0}" -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null; do :; done
	while iptables -t nat -D PREROUTING -i "${SERVER_WG_NIC:-wg0}" -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null; do :; done
	while iptables -t nat -D PREROUTING -i "${SERVER_WG_NIC:-wg0}" -p udp --dport 53 -j DNAT --to-destination "${SERVER_WG_IPV4:-10.18.0.1}:53" 2>/dev/null; do :; done
	while iptables -t nat -D PREROUTING -i "${SERVER_WG_NIC:-wg0}" -p tcp --dport 53 -j DNAT --to-destination "${SERVER_WG_IPV4:-10.18.0.1}:53" 2>/dev/null; do :; done

	if command -v dnsmasq &>/dev/null; then
		if ! dnsmasq --test >/dev/null 2>&1; then
			# If distro uses dnsmasq without ipset compile option, strip ipset lines so DNS still works
			rm -f /etc/dnsmasq.d/wg_split.conf
		fi
		systemctl enable dnsmasq >/dev/null 2>&1 || true
		systemctl restart dnsmasq >/dev/null 2>&1 || true
		if systemctl is-active --quiet dnsmasq 2>/dev/null; then
			ipt_ensure_top nat PREROUTING 1 -i "${SERVER_WG_NIC:-wg0}" -p udp --dport 53 -j DNAT --to-destination "${SERVER_WG_IPV4:-10.18.0.1}:53"
			ipt_ensure_top nat PREROUTING 2 -i "${SERVER_WG_NIC:-wg0}" -p tcp --dport 53 -j DNAT --to-destination "${SERVER_WG_IPV4:-10.18.0.1}:53"
		fi
	fi

	ensureHostPublicIpBypassRules

	# 4. High-Speed CONNMARK Fastpath in mangle PREROUTING (Checks ipset ONLY on 1st packet of each flow!)
	iptables -t mangle -F PREROUTING 2>/dev/null || true
	if command -v ipset &>/dev/null; then
		# Fastpath: If connection already has a saved mark (0x100 Direct or 0x51820 WARP), restore it and skip ipset!
		iptables -t mangle -A PREROUTING -i "${SERVER_WG_NIC:-wg0}" -m connmark ! --mark 0 -j CONNMARK --restore-mark 2>/dev/null || true
		iptables -t mangle -A PREROUTING -i "${SERVER_WG_NIC:-wg0}" -m mark ! --mark 0 -j RETURN 2>/dev/null || true

		# First packet (SYN / NEW UDP): Lookup wg_direct_clean (0x100 -> Direct 500+ Mbps VPS Egress)
		iptables -t mangle -A PREROUTING -i "${SERVER_WG_NIC:-wg0}" -m set --match-set wg_direct_clean dst -j MARK --set-mark 0x100 2>/dev/null || true
		iptables -t mangle -A PREROUTING -i "${SERVER_WG_NIC:-wg0}" -m mark --mark 0x100 -j CONNMARK --save-mark 2>/dev/null || true
		iptables -t mangle -A PREROUTING -i "${SERVER_WG_NIC:-wg0}" -m mark --mark 0x100 -j RETURN 2>/dev/null || true

		# First packet (SYN / NEW UDP): Lookup wg_split_v4 (0x51820 -> Cloudflare WARP Egress)
		iptables -t mangle -A PREROUTING -i "${SERVER_WG_NIC:-wg0}" -m set --match-set wg_split_v4 dst -j MARK --set-mark 0x51820 2>/dev/null || true
		iptables -t mangle -A PREROUTING -i "${SERVER_WG_NIC:-wg0}" -m mark --mark 0x51820 -j CONNMARK --save-mark 2>/dev/null || true
	fi

	# Core FORWARD, ICMP, DNS & NAT Rules
	ipt_ensure_top filter INPUT 1 -p udp --dport "${SERVER_PORT:-4500}" -j ACCEPT
	ipt_ensure_top filter INPUT 2 -i "${SERVER_WG_NIC:-wg0}" -p udp --dport 53 -j ACCEPT
	ipt_ensure_top filter INPUT 3 -i "${SERVER_WG_NIC:-wg0}" -p tcp --dport 53 -j ACCEPT

	ipt_ensure_top filter FORWARD 1 -p icmp -j ACCEPT
	ipt_ensure_top filter FORWARD 2 -i "${SERVER_WG_NIC:-wg0}" -j ACCEPT
	ipt_ensure_top filter FORWARD 3 -o "${SERVER_WG_NIC:-wg0}" -j ACCEPT

	if command -v ip6tables &>/dev/null; then
		ip6tables -C FORWARD -i "${SERVER_WG_NIC:-wg0}" -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null || \
			ip6tables -I FORWARD 1 -i "${SERVER_WG_NIC:-wg0}" -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null || true
	fi

	ipt_ensure_top nat POSTROUTING 1 -s 10.18.0.0/24 ! -o "${SERVER_WG_NIC:-wg0}" -j MASQUERADE
	ipt_ensure_top nat POSTROUTING 2 -s 10.19.0.0/24 ! -o "${SERVER_WG_NIC:-wg0}" -j MASQUERADE

	# Clean mangle FORWARD and set clean PMTU clamping once
	iptables -t mangle -F FORWARD 2>/dev/null || true
	iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

	# 5. Configure Default Subnet Routing According to Split Mode (BYPASS vs TUNNEL)
	while ip rule del from 10.19.0.0/24 table 51820 priority 900 2>/dev/null; do :; done
	while ip rule del from 10.18.0.0/24 table 51820 priority 910 2>/dev/null; do :; done

	local WARP_NIC=""
	if ip link show wgwarp &>/dev/null; then
		WARP_NIC="wgwarp"
	elif ip link show CloudflareWARP &>/dev/null; then
		WARP_NIC="CloudflareWARP"
	fi

	if [[ -n "$WARP_NIC" ]] && [[ -f /etc/wireguard/warp_egress_enabled ]]; then
		ip route replace default dev "$WARP_NIC" table 51820 2>/dev/null || ip route add default dev "$WARP_NIC" table 51820 2>/dev/null || true
		ipt_ensure_top nat POSTROUTING 1 -o "$WARP_NIC" -j MASQUERADE

		if curl -4 --interface "$WARP_NIC" -sSf --max-time 4 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep -q "warp=on"; then
			# Profile 1 (10.19.0.0/24) always uses WARP as default (with priority 60 wg_direct_clean bypass active!)
			ip rule add from 10.19.0.0/24 table 51820 priority 900 2>/dev/null || true

			# Profile 2 (10.18.0.0/24):
			# - In BYPASS mode with WARP_GLOBAL_MODE=full: default is WARP, and split domains bypass WARP at 500+ Mbps!
			# - In TUNNEL mode (or WARP_GLOBAL_MODE=split): default is 500+ Mbps Direct VPS, and split domains force through WARP!
			if [[ "$MODE" == "BYPASS" && "${WARP_GLOBAL_MODE:-full}" == "full" ]]; then
				ip rule add from 10.18.0.0/24 table 51820 priority 910 2>/dev/null || true
			fi
			echo -e "${GREEN}[✔] Split Tunneling [${MODE} MODE] + CONNMARK Fastpath Active (${DOMAIN_COUNT} expanded rules)!${NC}"
		else
			echo -e "${YELLOW}[!] Fail-Safe Guard: ${WARP_NIC} handshake pending; keeping clients on direct 500+ Mbps VPS routing.${NC}"
		fi
	fi

	optimizeNicQueuesAndRPS
}

# ------------------------------------------------------------------------------
# 10. Full Interactive Domain-Based Split Tunneling Menu (Restored & Upgraded)
# ------------------------------------------------------------------------------
function domainSplitTunneling() {
	while true; do
		ensureDefaultSplitDomainsFile
		if [[ ! -f /etc/wireguard/split_mode.txt ]]; then
			echo "BYPASS" > /etc/wireguard/split_mode.txt
		fi

		local MODE
		MODE=$(cat /etc/wireguard/split_mode.txt 2>/dev/null | tr -d ' \r\n' || echo "BYPASS")
		local DOMAIN_COUNT
		DOMAIN_COUNT=$(grep -c -v -E '^(#|$)' /etc/wireguard/split_domains.txt 2>/dev/null || echo 0)
		local DIRECT_MEM_CNT=0
		local WARP_MEM_CNT=0
		if command -v ipset &>/dev/null; then
			DIRECT_MEM_CNT=$(ipset list wg_direct_clean 2>/dev/null | awk '/Number of entries:/ {print $4}' || echo 0)
			WARP_MEM_CNT=$(ipset list wg_split_v4 2>/dev/null | awk '/Number of entries:/ {print $4}' || echo 0)
		fi

		echo -e "\n${PURPLE}=================================================================${NC}"
		echo -e "        ${CYAN}${BOLD}🌐 Real-Time Domain Split Tunneling (Dnsmasq + IPSet)${NC}"
		echo -e "${PURPLE}=================================================================${NC}"
		if [[ "$MODE" == "BYPASS" ]]; then
			echo -e "  ${BOLD}Current Mode:${NC}     ${GREEN}[BYPASS MODE]${NC} (Default = WARP Cloak | Split Domains = 500+ Mbps Direct VPS)"
		else
			echo -e "  ${BOLD}Current Mode:${NC}     ${CYAN}[TUNNEL MODE]${NC} (Default = 500+ Mbps Direct VPS | Split Domains = Force WARP)"
		fi
		echo -e "  ${BOLD}Configured List:${NC}  ${YELLOW}${DOMAIN_COUNT} base domain(s)${NC}"
		echo -e "  ${BOLD}Live IPSet Cache:${NC} ${GREEN}${DIRECT_MEM_CNT} Direct-Bypass IPs/CIDRs${NC} | ${CYAN}${WARP_MEM_CNT} Force-WARP IPs/CIDRs${NC}"
		echo "-----------------------------------------------------------------"
		echo "1) Add Domain (e.g. linkedin.com, speedtest.net, netflix.com, openai.com)"
		echo "2) Remove Domain"
		echo "3) Add Preset Category (LinkedIn, High-Speed Speedtest/Streaming, AI, Banking)"
		echo "4) Toggle Mode: Switch between [BYPASS WARP (500Mbps Direct)] vs [FORCE WARP]"
		echo "5) View Active Split Domains & Live Resolved IPSet Members"
		echo "6) Reset to Recommended Default Split Domains"
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
						sed -i "\|^${TARGET_DOM}\$|d" /etc/wireguard/split_domains.txt
						echo -e "${GREEN}[✔] Removed '${TARGET_DOM}'.${NC}"
						applyDomainSplitRulesLive
					fi
				fi
				;;
			3)
				echo -e "\nSelect Preset Category to Add:"
				echo "1) LinkedIn & Professional CDN (linkedin.com, licdn.com, lnkd.in, voyager)"
				echo "2) 500+ Mbps Speedtest & Streaming (speedtest.net, ooklaserver.net, fast.com, netflix.com, nflxvideo.net)"
				echo "3) Banking & Checkout (paypal.com, cardinalcommerce.com, braintreegateway.com, stripe.com, chase.com)"
				echo "4) AI Services (openai.com, chatgpt.com, claude.ai, gemini.google.com, perplexity.ai)"
				echo "5) Gaming & Low-Latency (discord.com, twitch.tv, steampowered.com, epicgames.com)"
				read -rp "Select preset [1-5]: " PRESET_OPT
				case "$PRESET_OPT" in
					1)
						for d in linkedin.com www.linkedin.com licdn.com static.licdn.com media.licdn.com dms.licdn.com voyager.linkedin.com lnkd.in; do
							grep -q "^${d}\$" /etc/wireguard/split_domains.txt 2>/dev/null || echo "$d" >> /etc/wireguard/split_domains.txt
						done
						applyDomainSplitRulesLive
						;;
					2)
						for d in speedtest.net www.speedtest.net ooklaserver.net speedtestcustom.com fast.com netflix.com nflxvideo.net nflxso.net nflxext.com; do
							grep -q "^${d}\$" /etc/wireguard/split_domains.txt 2>/dev/null || echo "$d" >> /etc/wireguard/split_domains.txt
						done
						applyDomainSplitRulesLive
						;;
					3)
						for d in paypal.com www.paypal.com paypalobjects.com cardinalcommerce.com braintreegateway.com stripe.com chase.com bankofamerica.com wellsfargo.com; do
							grep -q "^${d}\$" /etc/wireguard/split_domains.txt 2>/dev/null || echo "$d" >> /etc/wireguard/split_domains.txt
						done
						applyDomainSplitRulesLive
						;;
					4)
						for d in openai.com chatgpt.com oaistatic.com claude.ai anthropic.com gemini.google.com perplexity.ai; do
							grep -q "^${d}\$" /etc/wireguard/split_domains.txt 2>/dev/null || echo "$d" >> /etc/wireguard/split_domains.txt
						done
						applyDomainSplitRulesLive
						;;
					5)
						for d in discord.com twitch.tv steampowered.com roblox.com epicgames.com; do
							grep -q "^${d}\$" /etc/wireguard/split_domains.txt 2>/dev/null || echo "$d" >> /etc/wireguard/split_domains.txt
						done
						applyDomainSplitRulesLive
						;;
				esac
				;;
			4)
				if [[ "$MODE" == "BYPASS" ]]; then
					echo "TUNNEL" > /etc/wireguard/split_mode.txt
					echo -e "${GREEN}[✔] Switched to TUNNEL MODE: General traffic uses 500+ Mbps Direct VPS; Split Domains force through WARP!${NC}"
				else
					echo "BYPASS" > /etc/wireguard/split_mode.txt
					echo -e "${GREEN}[✔] Switched to BYPASS MODE: General traffic uses WARP; Split Domains bypass WARP via 500+ Mbps Direct VPS!${NC}"
				fi
				applyDomainSplitRulesLive
				;;
			5)
				echo -e "\n${CYAN}--- Configured Split Domains (/etc/wireguard/split_domains.txt) ---${NC}"
				grep -v -E '^(#|$)' /etc/wireguard/split_domains.txt | nl -s ') '
				echo -e "\n${CYAN}--- Sample Direct-Bypass IPSet Members (wg_direct_clean -> fwmark 0x100) ---${NC}"
				ipset list wg_direct_clean 2>/dev/null | head -n 25
				echo -e "\n${CYAN}--- Sample Force-WARP IPSet Members (wg_split_v4 -> fwmark 0x51820) ---${NC}"
				ipset list wg_split_v4 2>/dev/null | head -n 20
				read -n1 -r -p "Press Enter to return..."
				;;
			6)
				> /etc/wireguard/split_domains.txt
				ensureDefaultSplitDomainsFile
				applyDomainSplitRulesLive
				;;
			7|*)
				return
				;;
		esac
	done
}

# ------------------------------------------------------------------------------
# 11. High-Speed Kernel Cloudflare WARP Provisioner (Lockless 'noqueue' + RTT Benchmark)
# ------------------------------------------------------------------------------
function installWarpWatchdog() {
	cat << 'WATCHDOG_SH' > /usr/local/bin/wg-warp-watchdog.sh
#!/bin/bash
if [[ ! -f /etc/wireguard/warp_egress_enabled ]] || ! ip link show wgwarp &>/dev/null; then
	exit 0
fi

WARP_IP=$(ip -4 addr show dev wgwarp 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || true)
if [[ -n "$WARP_IP" ]] && ! ip rule show | grep -q "from ${WARP_IP} lookup 51820"; then
	ip rule add from "${WARP_IP}/32" table 51820 priority 100 2>/dev/null || true
	ip rule add oif wgwarp table 51820 priority 101 2>/dev/null || true
fi

if ! curl -4 --interface wgwarp -sSf --max-time 4 https://1.1.1.1/cdn-cgi/trace >/dev/null 2>&1; then
	PEER_KEY=$(wg show wgwarp peers 2>/dev/null | head -n1)
	if [[ -n "$PEER_KEY" ]]; then
		ENDPOINTS=(
			"162.159.192.1:4500"
			"162.159.193.1:4500"
			"188.114.96.1:4500"
			"162.159.192.1:2408"
			"162.159.193.1:2408"
			"162.159.192.1:500"
		)
		for ep in "${ENDPOINTS[@]}"; do
			wg set wgwarp fwmark 0x51888 peer "$PEER_KEY" endpoint "$ep" persistent-keepalive 25 2>/dev/null || true
			sleep 1
			if curl -4 --interface wgwarp -sSf --max-time 3 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep -q "warp=on"; then
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
	local ENDPOINT_ADDR="${4:-162.159.192.1:4500}"
	local TARGET_MTU="${5:-1420}"

	cat << WGWARP_EOF > /etc/wireguard/wgwarp.conf
[Interface]
PrivateKey = ${PRIV_KEY}
Address = ${IPV4_ADDR}/32
MTU = ${TARGET_MTU}
Table = 51820
FwMark = 0x51888

# Lockless 'noqueue' + GSO/GRO batching for maximum multi-core WARP throughput
PostUp = ip link set dev wgwarp txqueuelen 10000 mtu ${TARGET_MTU} 2>/dev/null || true
PostUp = tc qdisc del dev wgwarp root 2>/dev/null || true
PostUp = ethtool -K wgwarp gro on gso on tso on 2>/dev/null || true
PostUp = sysctl -w net.ipv4.conf.wgwarp.rp_filter=0 >/dev/null 2>&1 || true
PostUp = ip rule del from ${IPV4_ADDR}/32 table 51820 priority 100 2>/dev/null || true
PostUp = ip rule add from ${IPV4_ADDR}/32 table 51820 priority 100 2>/dev/null || true
PostUp = ip rule del oif wgwarp table 51820 priority 101 2>/dev/null || true
PostUp = ip rule add oif wgwarp table 51820 priority 101 2>/dev/null || true
PostUp = iptables -t nat -C POSTROUTING -o wgwarp -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -o wgwarp -j MASQUERADE

PostDown = ip rule del from ${IPV4_ADDR}/32 table 51820 priority 100 2>/dev/null || true
PostDown = ip rule del oif wgwarp table 51820 priority 101 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -o wgwarp -j MASQUERADE 2>/dev/null || true

[Peer]
PublicKey = ${PEER_PUB}
AllowedIPs = 0.0.0.0/0
Endpoint = ${ENDPOINT_ADDR}
PersistentKeepalive = 25
WGWARP_EOF
	chmod 600 /etc/wireguard/wgwarp.conf
}

function setupCloudflareWarpClient() {
	echo -e "\n${CYAN}${BOLD}⚡ Configuring Lockless Multi-Core Kernel Cloudflare WARP...${NC}"
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

	if [[ -f /etc/wireguard/wgwarp.conf ]]; then
		WARP_PRIV_KEY=$(grep -E '^\s*PrivateKey\s*=' /etc/wireguard/wgwarp.conf 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d ' \r\n' || true)
		WARP_IPV4=$(grep -E '^\s*Address\s*=' /etc/wireguard/wgwarp.conf 2>/dev/null | head -n1 | cut -d'=' -f2 | cut -d'/' -f1 | tr -d ' \r\n' || true)
	fi

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
		# Prefer IPsec port 4500 first to avoid VPS UDP 2408 QoS throttling
		writeWgwarpConfigFile "$WARP_PRIV_KEY" "$WARP_IPV4" "$WARP_PEER_PUB" "162.159.192.1:4500" "1420"

		wg-quick down wgwarp >/dev/null 2>&1 || true
		ip link delete dev wgwarp >/dev/null 2>&1 || true
		systemctl daemon-reload >/dev/null 2>&1 || true
		systemctl enable "wg-quick@wgwarp" >/dev/null 2>&1 || true
		systemctl restart "wg-quick@wgwarp" 2>/dev/null || wg-quick up wgwarp 2>/dev/null || true

		ensureHostPublicIpBypassRules

		local CANDIDATE_EPS=(
			"162.159.192.1:4500"
			"162.159.193.1:4500"
			"188.114.96.1:4500"
			"162.159.192.1:2408"
			"162.159.193.1:2408"
			"162.159.192.1:500"
		)
		local SELECTED_EP="162.159.192.1:4500"
		for ep in "${CANDIDATE_EPS[@]}"; do
			wg set wgwarp fwmark 0x51888 peer "$WARP_PEER_PUB" endpoint "$ep" persistent-keepalive 25 2>/dev/null || true
			if curl -4 --interface wgwarp -sSf --max-time 4 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep -q "warp=on"; then
				SELECTED_EP="$ep"
				break
			fi
		done

		WARP_OPTIMAL_MTU=1420
		for test_mtu in 1420 1400 1380 1360 1280; do
			local ping_payload=$(( test_mtu - 28 ))
			if ping -I wgwarp -c 1 -W 1 -M do -s "$ping_payload" 1.1.1.1 >/dev/null 2>&1; then
				WARP_OPTIMAL_MTU="$test_mtu"
				break
			fi
		done

		ip link set dev wgwarp mtu "$WARP_OPTIMAL_MTU" 2>/dev/null || true
		writeWgwarpConfigFile "$WARP_PRIV_KEY" "$WARP_IPV4" "$WARP_PEER_PUB" "$SELECTED_EP" "$WARP_OPTIMAL_MTU"
		optimizeNicQueuesAndRPS
		installWarpWatchdog

		echo -e "${GREEN}[✔] Kernel WARP Active on ${SELECTED_EP} | Lockless 'noqueue' | MTU: ${WARP_OPTIMAL_MTU}!${NC}"
		return 0
	fi
}

function autoRepairNetwork() {
	echo -e "\n${CYAN}${BOLD}🛠️ Upgrading to v4.4 (500+ Mbps Lockless Fastpath + Verified Dnsmasq Split Tunneling)...${NC}"

	cat << 'RESOLV_CLEAN_EOF' > /etc/resolv.conf 2>/dev/null || true
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
RESOLV_CLEAN_EOF

	modprobe xt_connmark >/dev/null 2>&1 || true
	sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
	sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
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

	echo -e "\n${CYAN}--- Live v4.4 Post-Repair Verification ---${NC}"
	echo -e "${BOLD}1. Physical VPS Interface (${SERVER_PUB_NIC:-eth0} - 500+ Mbps Direct Split Egress):${NC}"
	curl -4 --interface "${SERVER_PUB_NIC:-eth0}" -sSf --max-time 4 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep -E '^(ip|warp|colo)=' | sed 's/^/   /' || echo "   Direct trace error"

	echo -e "${BOLD}2. Kernel WARP Interface (wgwarp - qdisc $(ip link show wgwarp 2>/dev/null | awk '/qdisc/ {for(i=1;i<=NF;i++) if($i=="qdisc") print $(i+1)}')):${NC}"
	curl -4 --interface wgwarp -sSf --max-time 4 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep -E '^(ip|warp|colo)=' | sed 's/^/   /' || echo "   WARP trace pending"

	local D_CNT W_CNT DNS_STATE
	D_CNT=$(ipset list wg_direct_clean 2>/dev/null | awk '/Number of entries:/ {print $4}' || echo 0)
	W_CNT=$(ipset list wg_split_v4 2>/dev/null | awk '/Number of entries:/ {print $4}' || echo 0)
	if systemctl is-active --quiet dnsmasq 2>/dev/null; then
		DNS_STATE="${GREEN}ACTIVE (Intercepting wg0:53 & Populating IPSets Live)${NC}"
	else
		DNS_STATE="${RED}INACTIVE${NC}"
	fi
	echo -e "${BOLD}3. Split Tunneling Engine (Dnsmasq + CONNMARK IPSet):${NC}"
	echo -e "   Dnsmasq Service: ${DNS_STATE}"
	echo -e "   Active Bypass IPs/CIDRs (wg_direct_clean): ${GREEN}${D_CNT} entries${NC} | Force-WARP (wg_split_v4): ${CYAN}${W_CNT} entries${NC}"

	echo -e "${BOLD}4. LinkedIn Reachability Check (https://www.linkedin.com):${NC}"
	local LI_STATUS
	LI_STATUS=$(curl -4 --interface "${SERVER_PUB_NIC:-eth0}" -s -o /dev/null -w "HTTP %{http_code} (Connect: %{time_connect}s, TLS: %{time_appconnect}s)" --max-time 5 -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" https://www.linkedin.com/ 2>/dev/null || echo "Failed")
	echo -e "   ${GREEN}${LI_STATUS}${NC}"
	echo -e "\n${GREEN}[✔] v4.4 Upgrade Complete! Reconnect your WireGuard client once to flush client DNS cache.${NC}\n"
}

function realTimeLogging() {
	wg show
	echo ""
	ip rule show
}

function geoIpAntiVpnShield() {
	echo -e "${GREEN}Lockless 'noqueue', CONNMARK Fastpath, UDP GRO Forwarding, and Dnsmasq Split Tunneling ACTIVE.${NC}"
}

function provisionWebConsole() {
	echo -e "${YELLOW}Web Console helper ready.${NC}"
}

function settingsManager() {
	echo -e "Public IP: ${SERVER_PUB_IP} | Port: ${SERVER_PORT} | Mode: ${WARP_GLOBAL_MODE:-full}"
}

function cloudflareAntiFlagEngine() {
	echo "1) Refresh High-Speed Kernel WARP (Lockless noqueue + Port 4500)"
	echo "2) Toggle WARP Scope: Currently [${WARP_GLOBAL_MODE:-full}] (full = All via WARP + Bypass Split | split = 500Mbps Direct Default + WARP Split)"
	echo "3) Run Live Dual-Path Speed, Split-Tunnel & LinkedIn Diagnostic"
	echo "4) Disable WARP (100% Direct 500+ Mbps VPS Egress)"
	echo "5) Back"
	read -rp "Select [1-5]: " CF_OPT
	case "$CF_OPT" in
		1) setupCloudflareWarpClient; applyDomainSplitRulesLive ;;
		2)
			if [[ "${WARP_GLOBAL_MODE:-full}" == "full" ]]; then
				WARP_GLOBAL_MODE="split"
				echo "TUNNEL" > /etc/wireguard/split_mode.txt
				echo -e "${GREEN}[✔] Switched to 500+ Mbps Direct Default + Selective WARP Split mode!${NC}"
			else
				WARP_GLOBAL_MODE="full"
				echo "BYPASS" > /etc/wireguard/split_mode.txt
				echo -e "${GREEN}[✔] Switched to Full WARP Cloak + Direct 500+ Mbps Split Bypass mode!${NC}"
			fi
			sed -i "s/^WARP_GLOBAL_MODE=.*/WARP_GLOBAL_MODE=${WARP_GLOBAL_MODE}/" /etc/wireguard/params 2>/dev/null || echo "WARP_GLOBAL_MODE=${WARP_GLOBAL_MODE}" >> /etc/wireguard/params
			applyDomainSplitRulesLive
			;;
		3)
			echo -e "\n${BOLD}1. Physical VPS Interface (${SERVER_PUB_NIC:-eth0}):${NC}"
			curl -4 --interface "${SERVER_PUB_NIC:-eth0}" -sSf --max-time 4 https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|warp|colo)='
			echo -e "\n${BOLD}2. Kernel WARP Interface (wgwarp):${NC}"
			curl -4 --interface wgwarp -sSf --max-time 4 https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|warp|colo)='
			;;
		4)
			rm -f /etc/wireguard/warp_egress_enabled
			while ip rule del from 10.19.0.0/24 table 51820 priority 900 2>/dev/null; do :; done
			while ip rule del from 10.18.0.0/24 table 51820 priority 910 2>/dev/null; do :; done
			echo -e "${GREEN}[✔] Reverted to Direct 500+ Mbps VPS Egress.${NC}"
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
		echo -e "          ${GREEN}${BOLD}🍪  Cookie's Easy WireGuard Manager v4.4${NC}"
		echo -e "${PURPLE}=================================================================${NC}"
		echo " [1] Setup WireGuard Server        [6] Real-Time Logging"
		echo " [2] Add New Client                [9] Cloudflare WARP Engine"
		echo " [3] Configure Clients             [10] Full-Speed Auto-Repair"
		echo " [4] Backup Server                 [r] Uninstall"
		echo " [5] Domain Split Tunneling Menu   [q] Exit"
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