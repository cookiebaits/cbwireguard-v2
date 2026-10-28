#!/bin/bash
# ==============================================================================
# 🍪 Cookie's Easy WireGuard Manager & VPS Stealth Server v4.4
#    500Mbps NoQueue + Working Dynamic Split Tunneling + LinkedIn Fix
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

# ------------------------------------------------------------------------------
# High-Throughput 500Mbps+ Kernel Queue, Offload & Multi-Core RPS/XPS Optimizer
# ------------------------------------------------------------------------------
function optimizeNicQueuesAndRPS() {
	local cpu_count
	cpu_count=$(nproc 2>/dev/null || echo 1)
	local rps_mask
	rps_mask=$(printf '%x' $(( (1 << (cpu_count > 16 ? 16 : cpu_count)) - 1 )) 2>/dev/null || echo "f")

	local PUB_NIC="${SERVER_PUB_NIC:-}"
	if [[ -z "$PUB_NIC" ]]; then
		PUB_NIC=$(ip -4 route show table main default 2>/dev/null | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | grep -vE '^(wg|Cloudflare|tun)' | head -n1 || echo "eth0")
	fi

	# 1. Physical NIC: Enable hardware GRO/GSO/TSO + Kernel 6.2+ UDP GRO Forwarding + fq pacing
	if ip link show "$PUB_NIC" &>/dev/null; then
		ip link set dev "$PUB_NIC" txqueuelen 10000 2>/dev/null || true
		if command -v tc &>/dev/null; then
			tc qdisc replace dev "$PUB_NIC" root fq 2>/dev/null || true
		fi
		if command -v ethtool &>/dev/null; then
			ethtool -K "$PUB_NIC" gro on gso on tso on 2>/dev/null || true
			ethtool -K "$PUB_NIC" rx-udp-gro-forwarding on 2>/dev/null || true
			ethtool -K "$PUB_NIC" rx-gro-list off 2>/dev/null || true
		fi
	fi

	# 2. WireGuard Virtual Interfaces (wg0, wgwarp): MUST use lockless 'noqueue' (NOT fq_codel!)
	#    Removing fq_codel from wg0/wgwarp eliminates the global qdisc spinlock & 5ms drop cap (~154Mbps)!
	for wgnic in "${SERVER_WG_NIC:-wg0}" "wgwarp"; do
		if ip link show "$wgnic" &>/dev/null; then
			ip link set dev "$wgnic" txqueuelen 10000 2>/dev/null || true
			if command -v tc &>/dev/null; then
				tc qdisc del dev "$wgnic" root 2>/dev/null || true
			fi
			if command -v ethtool &>/dev/null; then
				ethtool -K "$wgnic" gro on gso on tso on 2>/dev/null || true
				ethtool -K "$wgnic" rx-gro-list off 2>/dev/null || true
			fi
		fi
	done

	# 3. Enable Multi-Core RPS and XPS across all interfaces
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

	# 4. Set CPU scaling governor to performance if available so vCPUs don't throttle during bursts
	for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
		[[ -w "$gov" ]] && echo "performance" > "$gov" 2>/dev/null || true
	done

	ip link set dev "${SERVER_WG_NIC:-wg0}" mtu 1420 2>/dev/null || true
	ip link set dev wgwarp mtu "${WARP_OPTIMAL_MTU:-1380}" 2>/dev/null || true

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

	iptables -t mangle -F PREROUTING 2>/dev/null || true
	iptables -t mangle -F FORWARD 2>/dev/null || true
	iptables -t mangle -F POSTROUTING 2>/dev/null || true

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
	echo -e "   6) ${GREEN}Local Split-Tunnel Dnsmasq Resolver${NC} (${SERVER_WG_IPV4:-10.18.0.1}, 1.1.1.1)"
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
		echo -e "${RED}[!] Passwords do not match