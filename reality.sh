#!/usr/bin/env bash
set -euo pipefail
DEFAULT_XRAY_VERSION='latest version'
DEFAULT_SNI='play-apps-features.googleusercontent.com'
DEFAULT_PORT='8443'
DEFAULT_FINGERPRINT='edge'
MODE='manual'
INSTALLER=''
CONFIG_TMP=''
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
cleanup() {
    [[ -z "$INSTALLER" ]] || rm -f -- "$INSTALLER"
    [[ -z "$CONFIG_TMP" ]] || rm -f -- "$CONFIG_TMP"
    return 0
}
trap cleanup EXIT
ask() {
    local answer
    printf '%s [%s]: ' "$1" "$2" >&2
    IFS= read -r answer <&3 || die 'Interactive input is required. Run this script in a terminal.'
    REPLY=${answer:-$2}
}
select_version() {
    printf '%s\n' 'Press Enter to use the latest Xray-core release. If you prefer a specific version, we recommend 26.6.27.'
    while true; do
        ask 'Enter the desired Xray-core version' "$DEFAULT_XRAY_VERSION"
        case "${REPLY,,}" in
            'latest version'|latest|last) XRAY_VERSION='latest'; break ;;
        esac
        XRAY_VERSION=${REPLY#v}
        [[ "$XRAY_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
        printf "Enter a version such as 26.6.27, type 'latest', or press Enter for the latest version.\n" >&2
    done
}
select_settings() {
    SNI=$DEFAULT_SNI
    PORT=$DEFAULT_PORT
    FINGERPRINT=$DEFAULT_FINGERPRINT
    [[ "$MODE" == 'manual' ]] || return 0
    while true; do
        ask 'REALITY SNI' "$DEFAULT_SNI"
        SNI=$REPLY
        if [[ ${#SNI} -le 253 && "$SNI" == *.* && "$SNI" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ && "$SNI" != *..* ]]; then
            break
        fi
        printf 'Enter a hostname only, without https://, a path, or a port.\n' >&2
    done
    while true; do
        ask 'Listening port' "$DEFAULT_PORT"
        if [[ "$REPLY" =~ ^[0-9]{1,5}$ ]] && (( 10#$REPLY >= 1 && 10#$REPLY <= 65535 )); then
            PORT=$((10#$REPLY))
            break
        fi
        printf 'Enter a port between 1 and 65535.\n' >&2
    done
    printf '%s\n' 'uTLS fingerprint:' '  1) chrome' '  2) firefox' '  3) edge (default)' '  4) ios' '  5) android' '  6) qq' '  7) 360'
    while true; do
        ask 'Choose a uTLS fingerprint number (default: edge)' '3'
        case "$REPLY" in
            1) FINGERPRINT='chrome'; break ;;
            2) FINGERPRINT='firefox'; break ;;
            3) FINGERPRINT='edge'; break ;;
            4) FINGERPRINT='ios'; break ;;
            5) FINGERPRINT='android'; break ;;
            6) FINGERPRINT='qq'; break ;;
            7) FINGERPRINT='360'; break ;;
            *) printf 'Enter a number from 1 to 7.\n' >&2 ;;
        esac
    done
}
install_dependencies() {
    local packages=() package
    for package in curl openssl qrencode; do
        command -v "$package" >/dev/null 2>&1 || packages+=("$package")
    done
    command -v awk >/dev/null 2>&1 || packages+=('gawk')
    [[ ${#packages[@]} -gt 0 ]] || return 0
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}" ca-certificates
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "${packages[@]}" ca-certificates
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "${packages[@]}" ca-certificates
    else
        die 'Unsupported package manager. Install curl, openssl, qrencode, awk and ca-certificates first.'
    fi
}
valid_ip() {
    local octet
    local octets=()
    if [[ "$1" == *:* ]]; then
        [[ "$1" =~ ^[0-9a-fA-F:]+$ ]]
        return
    fi
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a octets <<< "$1"
    for octet in "${octets[@]}"; do
        (( 10#$octet <= 255 )) || return 1
    done
}
get_ip() {
    local server_ip='' endpoint
    for endpoint in 'https://ipv4.ip.sb' 'https://ipv6.ip.sb'; do
        server_ip=$(curl -fsS --connect-timeout 5 --max-time 10 "$endpoint" 2>/dev/null) || { server_ip=''; continue; }
        valid_ip "$server_ip" && break
        server_ip=''
    done
    if [[ -z "$server_ip" ]] && command -v ip >/dev/null 2>&1; then
        server_ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") {print $(i+1); exit}}') || server_ip=''
        if [[ -z "$server_ip" ]]; then
            server_ip=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") {print $(i+1); exit}}') || server_ip=''
        fi
    fi
    valid_ip "$server_ip" || die 'Could not determine the server IP address.'
    if [[ "$server_ip" == *:* ]]; then
        printf '[%s]' "$server_ip"
    else
        printf '%s' "$server_ip"
    fi
}
install_xray() {
    INSTALLER=$(mktemp)
    curl -fL --retry 3 --connect-timeout 15 -o "$INSTALLER" 'https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh'
    if [[ "$XRAY_VERSION" == 'latest' ]]; then
        bash "$INSTALLER" install --beta
    else
        bash "$INSTALLER" install --version "v$XRAY_VERSION"
    fi
    [[ -x /usr/local/bin/xray ]] || die 'Xray-core installation failed.'
    /usr/local/bin/xray version
}
reconfig() {
    local output private_key public_key short_id config_path
    output=$(/usr/local/bin/xray x25519)
    private_key=$(printf '%s\n' "$output" | awk -F ': *' '/^(PrivateKey|Private key):/ {print $2; exit}' | tr -d '\r')
    public_key=$(printf '%s\n' "$output" | awk -F ': *' '/^(Password \(PublicKey\)|PublicKey|Public key|Password):/ {print $2; exit}' | tr -d '\r')
    [[ "$private_key" =~ ^[A-Za-z0-9_-]{43}$ && "$public_key" =~ ^[A-Za-z0-9_-]{43}$ ]] || die 'Could not read the REALITY private/public keys from Xray-core.'
    short_id=$(openssl rand -hex 8)
    config_path='/usr/local/etc/xray/config.json'
    mkdir -p /usr/local/etc/xray
    CONFIG_TMP=$(mktemp /usr/local/etc/xray/config.json.XXXXXX)
    cat >"$CONFIG_TMP" <<EOF
{
    "inbounds": [
        {
            "port": $PORT,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$UUID",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "${SNI}:443",
                    "xver": 0,
                    "serverNames": ["$SNI"],
                    "privateKey": "$private_key",
                    "minClientVer": "",
                    "maxClientVer": "",
                    "maxTimeDiff": 0,
                    "shortIds": ["$short_id"]
                }
            }
        }
    ],
    "outbounds": [
        {"protocol": "freedom", "tag": "direct"},
        {"protocol": "blackhole", "tag": "blocked"}
    ]
}
EOF
    /usr/local/bin/xray run -test -format json -config "$CONFIG_TMP"
    [[ ! -f "$config_path" ]] || cp -p -- "$config_path" "$config_path.bak"
    chmod 644 "$CONFIG_TMP"
    mv -f -- "$CONFIG_TMP" "$config_path"
    CONFIG_TMP=''
    systemctl enable xray.service
    systemctl restart xray.service
    systemctl is-active --quiet xray.service || die 'Xray failed to start. Check: journalctl -u xray -n 50 --no-pager'
    local isp url
    isp=$(curl -fsS --max-time 5 -H 'User-Agent: Mozilla/5.0' 'https://api.ip.sb/geoip' 2>/dev/null | awk -F '"' '{c="";i="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="isp")i=$(x+2)};if(c&&i)print c"-"i}') || isp=''
    isp=$(printf '%s' "${isp:-VLESS-TCP-REALITY}" | LC_ALL=C tr -cs 'A-Za-z0-9._~-' '_')
    url="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=${FINGERPRINT}&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#${isp}"
    printf '\nVLESS TCP REALITY installed successfully.\n\n%s\n\n' "$url"
    qrencode -t ANSIUTF8 -m 2 -s 2 -o - "$url"
    printf '\nAllow inbound TCP port %s in your server/provider firewall if needed.\n' "$PORT"
}
main() {
    case "${1:-}" in
        '') ;;
        --auto) MODE='auto' ;;
        --help|-h) printf 'Usage: sudo bash reality.sh [--auto]\nManual: ask for Xray version, SNI, port and fingerprint.\nAuto: ask only for Xray version; use the default connection settings.\n'; return 0 ;;
        *) die 'Usage: sudo bash reality.sh [--auto]' ;;
    esac
    [[ $# -le 1 ]] || die 'Usage: sudo bash reality.sh [--auto]'
    [[ $EUID -eq 0 ]] || die 'Run this script as root: sudo bash reality.sh [--auto]'
    command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]] || die 'A Linux server running systemd is required.'
    if [[ -t 0 ]]; then
        exec 3<&0
    elif { exec 3</dev/tty; } 2>/dev/null; then
        :
    else
        die 'A terminal is required for the Xray version question, including in --auto mode.'
    fi
    select_version
    select_settings
    exec 3<&-
    UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
    [[ "$UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die 'UUID must be a standard UUID.'
    install_dependencies
    IP=$(get_ip)
    install_xray
    reconfig
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
