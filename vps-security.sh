#!/usr/bin/env bash
# VPS Security Bootstrap v10.2.0
# 面向常用 systemd VPS Linux：全新 VPS 开荒 + 已部署业务服务器安全加固。
# 核心原则：不锁 SSH、不误关业务端口、不自动覆盖已有 DENY、关键改动可验证/可回滚。
(
set -Euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 077

VERSION="10.2.0"
APP_NAME="VPS Security Bootstrap v${VERSION}"
SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
CLI_AUDIT=0
if (( $# > 1 )); then
    printf 'ERROR: Only one option is accepted. Use --help.\n' >&2
    exit 2
fi

case "${1:-}" in
    --version|-V)
        printf '%s\n' "$APP_NAME"
        exit 0
        ;;
    --audit)
        CLI_AUDIT=1
        ;;
    --help|-h)
        cat <<'EOF'
VPS Security Bootstrap

用法：
  bash vps-security.sh          进入交互式菜单
  bash vps-security.sh --audit  执行只读安全检查
  bash vps-security.sh --version
  bash vps-security.sh --help

支持：Debian、Ubuntu、RHEL、CentOS Stream、Rocky Linux、AlmaLinux、
      Oracle Linux、Fedora、Amazon Linux（systemd）
EOF
        exit 0
        ;;
    "") ;;
    *) printf 'ERROR: Unknown option: %s\n' "$1" >&2; exit 2 ;;
esac

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        if [[ -r "$SCRIPT_PATH" && "$SCRIPT_PATH" != /dev/fd/* && "$SCRIPT_PATH" != /proc/*/fd/* ]]; then
            echo "检测到当前不是 root，已找到 sudo，正在自动提权重新运行..."
            exec sudo bash "$SCRIPT_PATH" "$@"
        fi
        echo "❌ 当前不是 root；当前运行方式无法自动重新执行脚本。"
        echo "请改用：sudo bash $SCRIPT_PATH"
        exit 1
    fi
    echo "❌ 当前用户不是 root，并且系统没有 sudo。"
    echo "请先执行 su - 切换到 root，再重新运行本脚本。"
    exit 1
fi

BASE_DIR="/root/vps-security"
STATE_FILE="$BASE_DIR/state.env"
INFO_FILE="$BASE_DIR/server-info.txt"
LOG_DIR="$BASE_DIR/logs"
LOG_FILE="$LOG_DIR/actions.log"
REPORT_DIR="$BASE_DIR/reports"
BACKUP_ROOT="$BASE_DIR/backups"
TXN_ROOT="$BASE_DIR/transactions"
PREFLIGHT_ROOT="$BASE_DIR/preflight"
PROTECTED_PORTS_FILE="$BASE_DIR/protected-ports.tsv"
LAST_PREFLIGHT_LINK="$PREFLIGHT_ROOT/latest"
IPV6_SYSCTL_FILE="/etc/sysctl.d/99-vps-security-ipv6.conf"
SSHD_CONFIG="/etc/ssh/sshd_config"
MANAGED_BEGIN="# BEGIN VPS-SECURITY-BOOTSTRAP"
MANAGED_END="# END VPS-SECURITY-BOOTSTRAP"
KEEPALIVE_ENABLED="0"
PREFLIGHT_DONE="0"
FULL_SKIP_PREFLIGHT="0"
LAST_PREFLIGHT=""
LAST_AUDIT=""
SSH_TXN_DIR=""
SSH_TXN_OLD_PORT=""
SSH_TXN_NEW_PORT=""

mkdir -p "$BASE_DIR" "$LOG_DIR" "$REPORT_DIR" "$BACKUP_ROOT" "$TXN_ROOT" "$PREFLIGHT_ROOT" || exit 1
chmod 700 "$BASE_DIR" "$LOG_DIR" "$REPORT_DIR" "$BACKUP_ROOT" "$TXN_ROOT" "$PREFLIGHT_ROOT" || exit 1
touch "$LOG_FILE" || exit 1
chmod 600 "$LOG_FILE" || exit 1
command -v flock >/dev/null 2>&1 || { echo "错误：请先安装 util-linux（flock）。"; exit 1; }
exec 9>"$BASE_DIR/.lock"
flock -n 9 || { echo "错误：已有工具实例正在运行，请先退出该实例。"; exit 1; }

if [[ "$CLI_AUDIT" == 1 ]]; then
    exec 3</dev/null 4>&1
elif ! { exec 3</dev/tty 4>/dev/tty; } 2>/dev/null; then
    echo "错误：需要在交互式终端中运行此脚本。"
    exit 1
fi

# Terminal presentation stays on fd 4; reports and command stdout remain plain.
ui_init() {
    UI_RESET=""; UI_BOLD=""; UI_ACCENT=""; UI_OK=""; UI_WARN=""; UI_FAIL=""; UI_MUTED=""
    UI_COLOR=0
    if [[ "${CLI_AUDIT:-0}" != 1 && ! ${NO_COLOR+x} && "${TERM:-dumb}" != dumb ]]; then
        case "${VPS_UI_COLOR:-auto}" in
            always) UI_COLOR=1 ;;
            auto) [[ -t 4 ]] && UI_COLOR=1 ;;
        esac
    fi
    if [[ "$UI_COLOR" == 1 ]]; then
        UI_RESET=$'\033[0m'; UI_BOLD=$'\033[1m'; UI_ACCENT=$'\033[36m'
        UI_OK=$'\033[32m'; UI_WARN=$'\033[33m'; UI_FAIL=$'\033[31m'; UI_MUTED=$'\033[2m'
    fi
    ui_size
}

ui_size() {
    local width="${COLUMNS:-80}"
    if [[ -t 4 && "${TERM:-dumb}" != dumb ]] && command -v tput >/dev/null 2>&1; then
        width="$(tput cols 2>/dev/null || printf 80)"
    fi
    [[ "$width" =~ ^[0-9]{1,3}$ ]] || width=80
    width=$((10#$width))
    (( width >= 24 )) || width=24
    (( width <= 88 )) || width=88
    UI_WIDTH="$width"
}

ui_text() {
    local text="$*"
    text="${text//✅/[OK]}"; text="${text//❌/[FAIL]}"
    text="${text//⚠️/[WARN]}"; text="${text//⚠/[WARN]}"
    text="${text//ℹ️/[INFO]}"; text="${text//ℹ/[INFO]}"
    # Strip terminal controls from host/process/user-supplied text. Never use %b.
    if [[ "$text" == *[$'\001'-$'\037'$'\177']* ]]; then
        printf '%s' "$text" | LC_ALL=C tr -d '\000-\010\013-\037\177'
    else
        printf '%s' "$text"
    fi
}

ui_write() {
    local tone="$1" text="$2" color=""
    case "$tone" in
        accent) color="${UI_ACCENT:-}" ;; ok) color="${UI_OK:-}" ;;
        warn) color="${UI_WARN:-}" ;; fail) color="${UI_FAIL:-}" ;;
        muted) color="${UI_MUTED:-}" ;;
    esac
    printf '%s%s%s\n' "$color" "$text" "${UI_RESET:-}" >&4
}

say() {
    local text tone=""
    text="$(ui_text "$*")"
    case "$text" in
        '[OK]'*) tone=ok ;; '[WARN]'*) tone=warn ;;
        '[FAIL]'*) tone=fail ;; '[INFO]'*) tone=accent ;;
    esac
    ui_write "$tone" "$text"
}

ui_rule() {
    local line
    printf -v line '%*s' "${UI_WIDTH:-80}" ''
    ui_write muted "${line// /-}"
}

ui_heading() {
    say
    printf '%s%s  %s%s\n' "${UI_BOLD:-}" "${UI_ACCENT:-}" "$(ui_text "$*")" "${UI_RESET:-}" >&4
    ui_rule
}

ui_section() {
    printf '%s%s  %s%s\n' "${UI_BOLD:-}" "${UI_ACCENT:-}" "$(ui_text "$*")" "${UI_RESET:-}" >&4
}

ui_item() {
    local key="$1" label="$2"
    printf '  %s[%2s]%s %s\n' "${UI_ACCENT:-}" "$key" "${UI_RESET:-}" "$(ui_text "$label")" >&4
}

ui_value() {
    printf '  %s  %s\n' "$(ui_text "$1")" "$(ui_text "$2")" >&4
}

ui_display_width() {
    # Decode UTF-8 bytes without changing the program's C locale or requiring
    # Python/wcwidth on a minimal VPS. CJK/fullwidth glyphs occupy two cells.
    local LC_ALL=C text="$1" offset=0 width=0 byte code count index next
    while (( offset < ${#text} )); do
        printf -v byte '%d' "'${text:offset:1}"
        count=1; code="$byte"
        if (( byte >= 194 && byte <= 223 )); then count=2; code=$((byte & 31))
        elif (( byte >= 224 && byte <= 239 )); then count=3; code=$((byte & 15))
        elif (( byte >= 240 && byte <= 244 )); then count=4; code=$((byte & 7))
        fi
        for ((index=1; index<count; index++)); do
            printf -v next '%d' "'${text:offset+index:1}"
            if (( next < 128 || next > 191 )); then count=1; code="$byte"; break; fi
            code=$(( (code << 6) | (next & 63) ))
        done
        if (( (code >= 0x300 && code <= 0x36f) || (code >= 0xfe00 && code <= 0xfe0f) || code == 0x200d )); then
            :
        elif (( (code >= 0x1100 && code <= 0x115f) || code == 0x2329 || code == 0x232a ||
                (code >= 0x2e80 && code <= 0xa4cf && code != 0x303f) ||
                (code >= 0xac00 && code <= 0xd7a3) || (code >= 0xf900 && code <= 0xfaff) ||
                (code >= 0xfe10 && code <= 0xfe19) || (code >= 0xfe30 && code <= 0xfe6f) ||
                (code >= 0xff00 && code <= 0xff60) || (code >= 0xffe0 && code <= 0xffe6) ||
                (code >= 0x1f300 && code <= 0x1faff) || (code >= 0x20000 && code <= 0x3fffd) )); then
            width=$((width+2))
        else
            width=$((width+1))
        fi
        offset=$((offset+count))
    done
    printf '%s' "$width"
}

ui_pair() {
    local left right left_width right_width column
    left="$(ui_text "$1")"; right="$(ui_text "$2")"
    left_width="$(ui_display_width "$left")"; right_width="$(ui_display_width "$right")"
    column=$(( (${UI_WIDTH:-80}-6)/2 ))
    if (( ${UI_WIDTH:-80} >= 76 && left_width <= column && right_width <= column )); then
        printf '  %s%*s  %s\n' "$left" "$((column-left_width))" '' "$right" >&4
    else
        say "  $left"
        say "  $right"
    fi
}

ui_menu_pair() {
    local first="$1" left second="$3" right left_width right_width column
    left="$(ui_text "$2")"; right="$(ui_text "$4")"
    left_width="$(ui_display_width "$left")"; right_width="$(ui_display_width "$right")"
    column=$(( (${UI_WIDTH:-80}-6)/2 ))
    if (( ${UI_WIDTH:-80} >= 76 && left_width+5 <= column && right_width+5 <= column )); then
        printf '  %s[%2s]%s %s%*s  %s[%2s]%s %s\n' \
            "${UI_ACCENT:-}" "$first" "${UI_RESET:-}" "$left" "$((column-left_width-5))" '' \
            "${UI_ACCENT:-}" "$second" "${UI_RESET:-}" "$right" >&4
    else
        ui_item "$first" "$left"; ui_item "$second" "$right"
    fi
}

ui_clear() {
    ui_size
    if [[ "${UI_COLOR:-0}" == 1 && -t 4 && "${VPS_UI_CLEAR:-1}" != 0 ]]; then
        printf '\033[2J\033[H' >&4
    else
        say
    fi
}

ask() {
    local __var="$1"
    shift
    printf '\n%s  > %s%s' "${UI_ACCENT:-}" "$(ui_text "$*")" "${UI_RESET:-}" >&4
    IFS= read -r "${__var?}" <&3 || { say "输入已断开，停止操作。"; exit 2; }
}
confirm_y() {
    local ans
    while true; do
        ask ans "$1 [Y/n]："
        case "$ans" in
            ""|y|Y) return 0 ;;
            n|N) return 1 ;;
            *) say "请输入 y 或 n；直接回车默认 = y。" ;;
        esac
    done
}
choose_num() {
    local __var="$1" prompt="$2" allowed="$3" def="${4:-}" ans
    while true; do
        ask ans "$prompt"
        [[ -n "$ans" ]] || ans="$def"
        case " $allowed " in
            *" $ans "*) printf -v "$__var" '%s' "$ans"; return 0 ;;
            *) say "❌ 无效选择，请输入：$allowed" ;;
        esac
    done
}
pause() { local _x; say; ask _x "按回车继续..."; }
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }

ui_init

OS_ID=""
OS_ID_LIKE=""
OS_VERSION_ID=""
OS_PRETTY_NAME="Unknown Linux"
OS_FAMILY=""
PKG_MANAGER=""

detect_platform() {
    local ID="" ID_LIKE="" VERSION_ID="" PRETTY_NAME="" VERSION=""
    [[ -r /etc/os-release ]] || { say "❌ 无法读取 /etc/os-release，不能识别系统。"; return 1; }
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_ID_LIKE="${ID_LIKE:-}"
    OS_VERSION_ID="${VERSION_ID:-unknown}"
    OS_PRETTY_NAME="${PRETTY_NAME:-$OS_ID}"

    case "$OS_ID" in
        debian|ubuntu) OS_FAMILY="debian" ;;
        rhel|centos|rocky|almalinux|ol|fedora|amzn) OS_FAMILY="rhel" ;;
        *)
            if [[ " $OS_ID_LIKE " == *" debian "* || " $OS_ID_LIKE " == *" ubuntu "* ]]; then
                OS_FAMILY="debian"
            elif [[ " $OS_ID_LIKE " == *" rhel "* || " $OS_ID_LIKE " == *" fedora "* || " $OS_ID_LIKE " == *" centos "* ]]; then
                OS_FAMILY="rhel"
            else
                say "❌ 暂不支持此系统：$OS_PRETTY_NAME"
                say "支持 Debian/Ubuntu 和 RHEL/Fedora 系的 systemd 发行版。"
                return 1
            fi
            ;;
    esac

    if [[ "$OS_FAMILY" == "debian" ]] && command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    elif [[ "$OS_FAMILY" == "rhel" ]] && command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
    else
        say "❌ 系统已识别为 $OS_PRETTY_NAME，但没有找到可用的 apt-get/dnf/yum。"
        return 1
    fi
}

pkg_refresh() {
    case "$PKG_MANAGER" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get update ;;
        dnf) dnf -y makecache ;;
        yum) yum -y makecache ;;
        *) return 1 ;;
    esac
}

pkg_install() {
    (($# > 0)) || return 0
    case "$PKG_MANAGER" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
        dnf) dnf -y install "$@" ;;
        yum) yum -y install "$@" ;;
        *) return 1 ;;
    esac
}

pkg_upgrade_system() {
    case "$PKG_MANAGER" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get update &&
                DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
            ;;
        dnf)
            if [[ "$OS_ID" == "amzn" && "$OS_VERSION_ID" == 2023* ]]; then
                dnf -y upgrade --releasever=latest
            else
                dnf -y upgrade --refresh
            fi
            ;;
        yum) yum -y update ;;
        *) return 1 ;;
    esac
}

package_installed() {
    local package="$1"
    case "$OS_FAMILY" in
        debian) dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'ok installed' ;;
        rhel) rpm -q "$package" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

detect_platform || exit 1

if ! command -v apt-get >/dev/null 2>&1; then
    [[ "$OS_FAMILY" != "debian" ]] || { say "❌ Debian/Ubuntu 系统未找到 apt-get。"; exit 1; }
fi
if ! command -v systemctl >/dev/null 2>&1; then
    say "❌ 当前系统未检测到 systemd/systemctl，本工具暂不支持。"
    exit 1
fi

check_dependencies() {
    local -A pkg_for=()
    if [[ "$OS_FAMILY" == "debian" ]]; then
        pkg_for=([ss]="iproute2" [ip]="iproute2" [shuf]="coreutils" [base64]="coreutils"
            [gzip]="gzip" [ssh-keygen]="openssh-client" [awk]="gawk" [sed]="sed"
            [grep]="grep" [sort]="coreutils" [tar]="tar" [hostname]="hostname" [sysctl]="procps")
    else
        pkg_for=([ss]="iproute" [ip]="iproute" [shuf]="coreutils" [base64]="coreutils"
            [gzip]="gzip" [ssh-keygen]="openssh-clients" [awk]="gawk" [sed]="sed"
            [grep]="grep" [sort]="coreutils" [tar]="tar" [hostname]="hostname" [sysctl]="procps-ng")
    fi
    local missing=() pkgs=() cmd pkg x seen=" "
    for cmd in "${!pkg_for[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    ((${#missing[@]} == 0)) && return 0
    say "检测到缺少基础依赖：${missing[*]}"
    [[ "$CLI_AUDIT" != 1 ]] || { say "只读审计不会安装依赖，请手工安装后重试。"; return 1; }
    for cmd in "${missing[@]}"; do
        pkg="${pkg_for[$cmd]}"
        if [[ "$seen" != *" $pkg "* ]]; then pkgs+=("$pkg"); seen+="$pkg "; fi
    done
    if ! confirm_y "是否自动安装缺少的依赖：${pkgs[*]}？"; then
        say "❌ 缺少必要依赖，已取消。"
        return 1
    fi
    pkg_refresh || return 1
    pkg_install "${pkgs[@]}" || return 1
}
check_dependencies || exit 1

SSHD_BIN="$(command -v sshd || true)"
[[ -n "$SSHD_BIN" ]] || SSHD_BIN="/usr/sbin/sshd"
if [[ ! -x "$SSHD_BIN" ]]; then
    say "❌ 未找到 sshd，请先安装 openssh-server。"
    exit 1
fi

systemd_unit_loaded() {
    local state
    state="$(systemctl show -p LoadState --value "$1" 2>/dev/null || true)"
    [[ "$state" == "loaded" ]]
}

if systemd_unit_loaded ssh.service; then
    SSH_SERVICE="ssh"
elif systemd_unit_loaded sshd.service; then
    SSH_SERVICE="sshd"
elif [[ -x /etc/init.d/ssh ]]; then
    SSH_SERVICE="ssh"
elif [[ -x /etc/init.d/sshd ]]; then
    SSH_SERVICE="sshd"
else
    say "❌ 未找到 ssh/sshd 服务。"
    say "请执行：systemctl status ssh --no-pager -l || systemctl status sshd --no-pager -l"
    exit 1
fi

SSH_PORT=""
PREVIOUS_SSH_PORT=""
PORT_BACKUP=""
KEY_TESTED="0"
PASSWORD_LOCKED="0"
LAST_BACKUP=""
LAST_REPORT=""
PORT_SOCKET_WAS_ENABLED=""
PORT_SOCKET_WAS_ACTIVE=""

declare -A PF_BINDS=()
declare -A PF_PROCS=()
declare -A PF_SOURCES=()

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$STATE_FILE" || true
    fi
}

save_state() {
    local tmp
    umask 077
    tmp="$(mktemp "$BASE_DIR/.state.XXXXXX")" || return 1
    {
        printf 'SSH_PORT=%q\n' "${SSH_PORT:-}"
        printf 'PREVIOUS_SSH_PORT=%q\n' "${PREVIOUS_SSH_PORT:-}"
        printf 'PORT_BACKUP=%q\n' "${PORT_BACKUP:-}"
        printf 'KEY_TESTED=%q\n' "${KEY_TESTED:-0}"
        printf 'PASSWORD_LOCKED=%q\n' "${PASSWORD_LOCKED:-0}"
        printf 'LAST_BACKUP=%q\n' "${LAST_BACKUP:-}"
        printf 'LAST_REPORT=%q\n' "${LAST_REPORT:-}"
        printf 'LAST_AUDIT=%q\n' "${LAST_AUDIT:-}"
        printf 'LAST_PREFLIGHT=%q\n' "${LAST_PREFLIGHT:-}"
        printf 'PORT_SOCKET_WAS_ENABLED=%q\n' "${PORT_SOCKET_WAS_ENABLED:-}"
        printf 'PORT_SOCKET_WAS_ACTIVE=%q\n' "${PORT_SOCKET_WAS_ACTIVE:-}"
        printf 'KEEPALIVE_ENABLED=%q\n' "${KEEPALIVE_ENABLED:-0}"
        printf 'SSH_TXN_DIR=%q\n' "${SSH_TXN_DIR:-}"
        printf 'SSH_TXN_OLD_PORT=%q\n' "${SSH_TXN_OLD_PORT:-}"
        printf 'SSH_TXN_NEW_PORT=%q\n' "${SSH_TXN_NEW_PORT:-}"
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$STATE_FILE" || { rm -f "$tmp"; return 1; }
}
load_state

get_server_ip() {
    local ip
    ip="$(printf '%s\n' "${SSH_CONNECTION:-}" | awk '{print $3}')"
    [[ -n "$ip" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -n "$ip" ]] || ip="你的服务器IP"
    printf '%s\n' "$ip"
}
get_ipv4() { ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}' || true; }
get_global_ipv6() { ip -6 addr show scope global 2>/dev/null | awk '/inet6/ {print $2; exit}' || true; }
has_global_ipv6() { [[ -n "$(get_global_ipv6)" ]]; }
get_os_pretty() { . /etc/os-release 2>/dev/null || true; printf '%s' "${PRETTY_NAME:-Unknown Linux}"; }
get_uptime_short() { uptime -p 2>/dev/null | sed 's/^up //' || printf '未知'; }

get_sshd_ports() {
    "$SSHD_BIN" -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null \
        | awk '$1=="port" {print $2}' | sort -nu
}
get_primary_ssh_port() {
    local p
    p="$(get_sshd_ports | head -n1 || true)"
    [[ -n "$p" ]] || p="$(printf '%s\n' "${SSH_CONNECTION:-}" | awk '{print $4}')"
    [[ -n "$p" ]] || p="22"
    printf '%s\n' "$p"
}
port_is_listening() {
    local port="$1" out
    out="$(ss -H -lnt "sport = :$port" 2>/dev/null || true)"
    [[ -n "$out" ]]
}
sshd_password_auth_disabled() {
    local eff
    eff="$($SSHD_BIN -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null || true)"
    grep -q '^passwordauthentication no$' <<<"$eff"
}

is_ufw_installed() { command -v ufw >/dev/null 2>&1; }
is_ufw_active() {
    local out
    is_ufw_installed || return 1
    out="$(ufw status 2>/dev/null || true)"
    grep -q '^Status: active' <<<"$out"
}
is_firewalld_active() { command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; }
is_custom_nftables_active() {
    command -v nft >/dev/null 2>&1 || return 1
    systemctl is-active --quiet nftables 2>/dev/null && return 0
    # 不因 Debian 默认但未启用的 /etc/nftables.conf 误判。
    # 只有当前实际 ruleset 存在 input hook 时，才按“自定义主机 nftables”处理。
    local rules
    rules="$(nft list ruleset 2>/dev/null || true)"
    grep -Eq 'hook[[:space:]]+input' <<<"$rules"
}
is_custom_iptables_active() {
    command -v iptables >/dev/null 2>&1 || return 1
    local policy rules
    policy="$(iptables -S INPUT 2>/dev/null | head -n1 || true)"
    if grep -Eq '^-P[[:space:]]+INPUT[[:space:]]+(DROP|REJECT)$' <<<"$policy"; then
        return 0
    fi
    rules="$(iptables -S INPUT 2>/dev/null \
        | grep '^-A INPUT ' \
        | grep -Ev ' -j (ufw-|f2b-|fail2ban)' \
        || true)"
    [[ -n "$rules" ]]
}

detect_firewall_backend() {
    if is_firewalld_active && is_ufw_active; then
        printf 'conflict'
    elif is_firewalld_active; then
        printf 'firewalld'
    elif is_ufw_active; then
        printf 'ufw'
    elif is_custom_nftables_active; then
        printf 'nftables'
    elif is_custom_iptables_active; then
        printf 'iptables'
    elif is_ufw_installed; then
        printf 'ufw-inactive'
    else
        printf 'none'
    fi
}

ufw_rule_state() {
    local spec="$1" proto="$2" out
    is_ufw_installed || { printf 'none'; return 0; }
    out="$(ufw status 2>/dev/null || true)"
    # Inspect saved simple rules too: `status` hides them while UFW is inactive.
    out+=$'\n'"$(ufw show added 2>/dev/null | awk -v spec="$spec" -v proto="$proto" '
        $1=="ufw" && $2 ~ /^(allow|deny|reject)$/ && $3 ~ /^[0-9:]+(\/(tcp|udp))?$/ {
            print $3, toupper($2), "IN Anywhere"
            next
        }
        $1=="ufw" && $2 ~ /^(deny|reject)$/ {
            # Unknown saved rule syntax: require manual review rather than
            # accidentally superseding a source/interface/application denial.
            print spec "/" proto, "DENY IN Anywhere"
        }' || true)"
    awk -v spec="$spec" -v proto="$proto" '
        function low(x, a) {split(x,a,":"); return a[1]+0}
        function high(x, a,n) {n=split(x,a,":"); return a[n]+0}
        {
            n=split($1,p,"/"); rule=p[1]
            if (rule !~ /^[0-9]+(:[0-9]+)?$/ || (n>1 && p[2]!=proto)) next
            if (low(rule)>high(spec) || high(rule)<low(spec)) next
            if ($0 ~ / (DENY|REJECT)( IN)? /) deny=1
            # A source-scoped ALLOW is not evidence of general reachability.
            if (rule==spec && $0 ~ / ALLOW IN Anywhere( \(v6\))?$/) allow=1
        }
        END {print deny ? "deny" : (allow ? "allow" : "none")}
    ' <<<"$out"
}

firewalld_zone() {
    local iface zone
    iface="$(ip -4 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')"
    [[ -n "$iface" ]] || iface="$(ip -6 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')"
    if [[ -n "$iface" ]]; then
        zone="$(firewall-cmd --get-zone-of-interface="$iface" 2>/dev/null || true)"
        if [[ -n "$zone" && "$zone" != "no zone" ]]; then
            printf '%s' "$zone"
            return 0
        fi
    fi
    zone="$(firewall-cmd --get-default-zone 2>/dev/null || true)"
    [[ -n "$zone" ]] || zone='public'
    printf '%s' "$zone"
}

run_step() {
    local title="$1" fn="$2" rc choice
    shift 2
    while true; do
        if ( set -Eeuo pipefail; "$fn" "$@" ); then
            load_state
            return 0
        else
            rc=$?
        fi
        load_state
        say
        say "❌ 本步骤执行失败"
        say "步骤：$title"
        say "返回码：$rc"
        say "日志：$LOG_FILE"
        ui_item 1 "重试"
        ui_item 0 "返回"
        choose_num choice "请选择 [1/0]：" "1 0" "0"
        [[ "$choice" == "1" ]] || return "$rc"
    done
}
merge_csv_unique() {
    local current="$1" value="$2" item
    [[ -n "$value" ]] || { printf '%s' "$current"; return 0; }
    if [[ -z "$current" ]]; then
        printf '%s' "$value"
        return 0
    fi
    IFS=',' read -ra _items <<< "$current"
    for item in "${_items[@]}"; do
        [[ "$item" == "$value" ]] && { printf '%s' "$current"; return 0; }
    done
    printf '%s,%s' "$current" "$value"
}

is_loopback_bind() {
    local a="$1"
    a="${a#[}"
    a="${a%]}"
    case "$a" in
        127.*|::1|localhost|::1%lo) return 0 ;;
        *) return 1 ;;
    esac
}

extract_process_name() {
    local rest="$1" p
    p="$(sed -n 's/.*users:(("\([^"]*\)".*/\1/p' <<< "$rest" | head -n1)"
    [[ -n "$p" ]] || p="unknown"
    printf '%s\n' "$p"
}

is_known_business_process() {
    local p="$1"
    case "$p" in
        nginx|openresty|caddy|apache2|httpd|x-ui|3x-ui|xray|xray-*|v2ray|v2ray-*|sing-box|hysteria|hysteria-*|trojan|trojan-*|tuic|tuic-*|1panel|1panel-*|komari|komari-*|mysql|mysqld|mariadbd|postgres|postgresql|redis-server|redis|mongod|minio|sftpgo|qinglong|ql|node|php-fpm*|php*)
            return 0
            ;;
        *) return 1 ;;
    esac
}
is_system_resolved_5355() {
    local port="$1" procs="$2" p
    [[ "$port" == "5355" ]] || return 1
    IFS=',' read -ra _ps <<< "$procs"
    for p in "${_ps[@]}"; do
        case "$p" in
            systemd-resolve|systemd-resolved|systemd-resolve*) return 0 ;;
        esac
    done
    return 1
}

is_current_ssh_port() {
    local wanted="$1" p
    while read -r p; do
        [[ -n "$p" && "$p" == "$wanted" ]] && return 0
    done < <(get_sshd_ports 2>/dev/null || true)
    [[ "$(printf '%s\n' "${SSH_CONNECTION:-}" | awk '{print $4}')" == "$wanted" ]]
}

pf_add_target() {
    local proto="$1" port="$2" bind="$3" proc="$4" source="$5" key
    [[ "$proto" == "tcp" || "$proto" == "udp" ]] || return 0
    [[ "$port" =~ ^[0-9]+$ ]] || return 0
    (( port >= 1 && port <= 65535 )) || return 0
    key="$proto:$port"
    PF_BINDS["$key"]="$(merge_csv_unique "${PF_BINDS[$key]:-}" "$bind")"
    PF_PROCS["$key"]="$(merge_csv_unique "${PF_PROCS[$key]:-}" "$proc")"
    PF_SOURCES["$key"]="$(merge_csv_unique "${PF_SOURCES[$key]:-}" "$source")"
}

collect_public_listeners() {
    local line proto state _recvq _sendq local_ep _peer_ep rest port bind proc
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        read -r proto state _recvq _sendq local_ep _peer_ep rest <<< "$line"
        [[ "$proto" == "tcp" || "$proto" == "udp" ]] || continue
        port="${local_ep##*:}"
        bind="${local_ep%:*}"
        bind="${bind#[}"
        bind="${bind%]}"
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        if is_loopback_bind "$bind"; then
            continue
        fi
        proc="$(extract_process_name "${rest:-}")"
        pf_add_target "$proto" "$port" "$bind" "$proc" "系统监听"
    done < <(ss -H -lntup 2>/dev/null || true)
}

collect_docker_published_ports() {
    command -v docker >/dev/null 2>&1 || return 0
    local cid name hostip hostport cport proto
    while read -r cid; do
        [[ -n "$cid" ]] || continue
        name="$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's#^/##' || true)"
        [[ -n "$name" ]] || name="$cid"
        while IFS='|' read -r hostip hostport cport; do
            [[ "$hostport" =~ ^[0-9]+$ ]] || continue
            proto="${cport##*/}"
            [[ "$proto" == "tcp" || "$proto" == "udp" ]] || continue
            [[ -n "$hostip" ]] || hostip="0.0.0.0"
            if is_loopback_bind "$hostip"; then
                continue
            fi
            pf_add_target "$proto" "$hostport" "$hostip" "docker:$name" "Docker映射"
        done < <(
            docker inspect --format '{{range $p,$v := .NetworkSettings.Ports}}{{if $v}}{{range $v}}{{printf "%s|%s|%s\\n" .HostIp .HostPort $p}}{{end}}{{end}}{{end}}' "$cid" 2>/dev/null || true
        )
    done < <(docker ps -q 2>/dev/null || true)
}

snapshot_preflight_state() {
    local dir="$1"
    mkdir -p "$dir"
    chmod 700 "$dir"
    ss -lntup > "$dir/listeners.txt" 2>&1 || true
    if is_ufw_installed; then
        ufw status numbered > "$dir/ufw.txt" 2>&1 || true
        ufw show added > "$dir/ufw-added.txt" 2>&1 || true
    else
        echo "UFW 未安装" > "$dir/ufw.txt"
    fi
    printf "%s\n" "$(detect_firewall_backend)" > "$dir/firewall-backend.txt"
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --list-all-zones > "$dir/firewalld-zones.txt" 2>&1 || true
    fi
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > "$dir/iptables-save.txt" 2>&1 || true
    fi
    if command -v nft >/dev/null 2>&1; then
        nft list ruleset > "$dir/nft-ruleset.txt" 2>&1 || true
    fi
    if command -v docker >/dev/null 2>&1; then
        docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' > "$dir/docker-ports.txt" 2>&1 || true
    else
        echo "Docker 未安装" > "$dir/docker-ports.txt"
    fi
}

business_port_preflight() {
    say
    ui_heading "开荒前业务端口保护检查"
    say "规则：SSH 自动保护；已识别业务自动保护；本机监听忽略；systemd-resolved 5355 自动忽略；未知公网监听逐项询问。"
    say "说明：选择 n 只代表不加入自动保护名单，不会主动删除已有防火墙规则。"
    say

    if ! command -v ss >/dev/null 2>&1; then
        say "未找到 ss，正在按当前系统安装网络工具..."
        pkg_refresh
        if [[ "$OS_FAMILY" == "debian" ]]; then pkg_install iproute2; else pkg_install iproute; fi
    fi

    PF_BINDS=()
    PF_PROCS=()
    PF_SOURCES=()

    local stamp dir decision_file tmp key proto port binds procs sources class p known count=0
    stamp="$(date +%Y%m%d-%H%M%S)"
    dir="$PREFLIGHT_ROOT/preflight-$stamp"
    decision_file="$dir/decisions.txt"
    tmp="$dir/protected-ports.tsv"
    mkdir -p "$dir"
    chmod 700 "$dir"
    : > "$decision_file"
    : > "$tmp"

    snapshot_preflight_state "$dir"
    collect_public_listeners
    collect_docker_published_ports

    say "当前 SSH 端口：$(get_sshd_ports | xargs || true)"
    say "当前主机防火墙：$(status_firewall)"
    say "原则：已有规则不会被 reset；已有 DENY/reject 不会被静默覆盖。"
    if command -v docker >/dev/null 2>&1; then
        say "Docker：已检测；发布到宿主机的端口会加入保护名单，但本脚本不会擅自改写 DOCKER-USER。"
    fi
    say

    if ((${#PF_BINDS[@]} == 0)); then
        say "未发现非回环 TCP/UDP 监听。"
    fi

    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        proto="${key%%:*}"
        port="${key##*:}"
        binds="${PF_BINDS[$key]:-未知}"
        procs="${PF_PROCS[$key]:-unknown}"
        sources="${PF_SOURCES[$key]:-系统监听}"
        class=""

        if [[ "$proto" == "tcp" ]] && is_current_ssh_port "$port"; then
            class="SSH"
            say "✅ 自动保护：$port/$proto  SSH  监听=$binds"
        elif is_system_resolved_5355 "$port" "$procs"; then
            say "⏭ 自动忽略：$port/$proto  systemd-resolved/LLMNR  程序=$procs"
            printf 'IGNORE\t%s\t%s\t%s\t%s\n' "$proto" "$port" "$procs" "$binds" >> "$decision_file"
            continue
        elif [[ "$sources" == *"Docker映射"* ]]; then
            class="BUSINESS-DOCKER"
            say "✅ 自动保护：$port/$proto  Docker业务  程序=$procs  监听=$binds"
        else
            known=0
            IFS=',' read -ra _proc_items <<< "$procs"
            for p in "${_proc_items[@]}"; do
                if is_known_business_process "$p"; then
                    known=1
                    break
                fi
            done
            if (( known == 1 )); then
                class="BUSINESS"
                say "✅ 自动保护：$port/$proto  已识别业务  程序=$procs  监听=$binds"
            else
                say
                say "⚠️ 发现未知公网/非回环监听：$port/$proto"
                say "   程序：$procs"
                say "   监听：$binds"
                say "   来源：$sources"
                if confirm_y "是否将 $port/$proto 加入业务保护名单？"; then
                    class="USER-KEEP"
                    say "✅ 已加入保护名单：$port/$proto"
                else
                    say "⏭ 未加入自动保护名单：$port/$proto（不会删除已有防火墙规则）"
                    printf 'SKIP\t%s\t%s\t%s\t%s\n' "$proto" "$port" "$procs" "$binds" >> "$decision_file"
                    continue
                fi
            fi
        fi

        printf '%s\t%s\t%s\t%s\t%s\n' "$proto" "$port" "$class" "$procs" "$binds" >> "$tmp"
        printf 'KEEP\t%s\t%s\t%s\t%s\n' "$proto" "$port" "$procs" "$binds" >> "$decision_file"
        ((count+=1))
    done < <(printf '%s\n' "${!PF_BINDS[@]}" | sort -t: -k2,2n -k1,1)

    sort -u "$tmp" -o "$tmp"
    cp -f "$tmp" "$PROTECTED_PORTS_FILE"
    chmod 600 "$PROTECTED_PORTS_FILE"
    cp -f "$PROTECTED_PORTS_FILE" "$dir/protected-ports.tsv"
    ln -sfn "$dir" "$LAST_PREFLIGHT_LINK"
    LAST_PREFLIGHT="$dir"
    PREFLIGHT_DONE="1"
    save_state

    say
    ui_rule
    say "业务保护检查完成"
    ui_rule
    say "保护名单：$PROTECTED_PORTS_FILE"
    say "开荒前快照：$dir"
    say "已加入保护的协议/端口：$count 项"
    say
    if [[ -s "$PROTECTED_PORTS_FILE" ]]; then
        while IFS=$'\t' read -r proto port class procs binds; do
            printf '  %-5s %-7s %-18s %s\n' "$proto" "$port" "$class" "$procs" >&4
        done < "$PROTECTED_PORTS_FILE"
    fi
    say
    say "ℹ️ 后续第 7 项只补齐保护名单和当前 SSH 所需规则；不会 reset 防火墙。"
    log "业务端口预检完成：$dir；保护 $count 项"
}

ensure_business_preflight() {
    if [[ "${FULL_SKIP_PREFLIGHT:-0}" == "1" ]]; then
        say "⚠️ 通用流程已按用户选择跳过业务端口预检。"
        return 0
    fi
    if [[ "${PREFLIGHT_DONE:-0}" != "1" ]]; then
        business_port_preflight
    fi
}

ufw_safe_allow() {
    local spec="$1" proto="$2" label="$3" required="${4:-0}" state choice
    state="$(ufw_rule_state "$spec" "$proto")"
    case "$state" in
        allow)
            say "ℹ️ 已存在 ALLOW，保持不变：$spec/$proto"
            return 0
            ;;
        deny)
            say
            say "⚠️ 发现已有防火墙 DENY 冲突"
            say "端口：$spec/$proto"
            say "用途：$label"
            say "本工具不会自动删除已有 DENY。"
            if [[ "$required" == "1" ]]; then
                ui_item 1 "保持 DENY，并取消本次端口变更（推荐）"
                ui_item 2 "删除简单 DENY 并改为 ALLOW"
                ui_item 0 "取消"
                choose_num choice "请选择 [默认1]：" "1 2 0" "1"
                case "$choice" in
                    2)
                        ufw delete deny "$spec/$proto" >/dev/null 2>&1 || true
                        if [[ "$(ufw_rule_state "$spec" "$proto")" == "deny" ]]; then
                            say "❌ 仍检测到 DENY，可能是带来源地址的复杂规则。为避免错误覆盖，请人工处理。"
                            return 2
                        fi
                        ufw allow "$spec/$proto" comment "$label" >/dev/null 2>&1 || ufw allow "$spec/$proto" >/dev/null || return 1
                        say "✅ 已改为 ALLOW：$spec/$proto"
                        return 0
                        ;;
                    *) return 2 ;;
                esac
            else
                ui_item 1 "保持 DENY（推荐）"
                ui_item 2 "删除简单 DENY 并改为 ALLOW"
                ui_item 0 "跳过"
                choose_num choice "请选择 [默认1]：" "1 2 0" "1"
                if [[ "$choice" == "2" ]]; then
                    ufw delete deny "$spec/$proto" >/dev/null 2>&1 || true
                    if [[ "$(ufw_rule_state "$spec" "$proto")" == "deny" ]]; then
                        say "⚠️ 仍存在 DENY，未自动覆盖复杂规则：$spec/$proto"
                        return 0
                    fi
                    ufw allow "$spec/$proto" comment "$label" >/dev/null 2>&1 || ufw allow "$spec/$proto" >/dev/null || return 1
                    say "✅ 已改为 ALLOW：$spec/$proto"
                else
                    say "✅ 已保留原 DENY：$spec/$proto"
                fi
                return 0
            fi
            ;;
        *)
            ufw allow "$spec/$proto" comment "$label" >/dev/null 2>&1 || ufw allow "$spec/$proto" >/dev/null || return 1
            say "✅ 已新增 ALLOW：$spec/$proto"
            return 0
            ;;
    esac
}

ufw_allow_protected_business_ports() {
    [[ -f "$PROTECTED_PORTS_FILE" ]] || return 0
    local proto port class procs binds
    while IFS=$'\t' read -r proto port class procs binds; do
        [[ -n "$proto" && -n "$port" ]] || continue
        # SSH 永远以当前 sshd 配置为准，避免把旧 SSH 端口重新打开。
        [[ "$class" == "SSH" ]] && continue
        case "$proto" in
            tcp|udp)
                ufw_safe_allow "$port" "$proto" "Existing service - VPS Security" "0" || return 1
                ;;
        esac
    done < "$PROTECTED_PORTS_FILE"
}
status_preflight() {
    if [[ -f "$PROTECTED_PORTS_FILE" ]]; then
        local n
        n="$(wc -l < "$PROTECTED_PORTS_FILE" | tr -d ' ')"
        printf '已扫描（保护 %s 项）' "${n:-0}"
    else
        printf '未扫描'
    fi
}

status_system_update() {
    if grep -q '系统更新完成' "$LOG_FILE" 2>/dev/null; then
        printf '已执行'
    else
        printf '未记录'
    fi
}

status_root_password() {
    local st
    st="$(passwd -S root 2>/dev/null | awk '{print $2}' || true)"
    case "$st" in
        P) printf '已设置' ;;
        L|LK) printf '已锁定' ;;
        NP|'') printf '未设置/未知' ;;
        *) printf '%s' "$st" ;;
    esac
}

status_ssh_port() {
    local port
    port="$(get_primary_ssh_port 2>/dev/null || true)"
    [[ -n "$port" ]] || port="未知"
    if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1024 )); then
        printf '%s（高位）' "$port"
    else
        printf '%s' "$port"
    fi
}

status_ed25519_key() {
    local n
    n="$(grep -c '^ssh-ed25519 ' /root/.ssh/authorized_keys 2>/dev/null || true)"
    [[ -n "$n" ]] || n=0
    if (( n > 0 )); then
        printf '已配置（%s 把）' "$n"
    else
        printf '未配置'
    fi
}

status_key_test() {
    if [[ "${KEY_TESTED:-0}" == "1" ]]; then
        printf '已确认成功'
    else
        printf '未确认'
    fi
}

status_password_auth() {
    local eff
    eff="$($SSHD_BIN -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null || true)"
    if grep -q '^passwordauthentication no$' <<<"$eff" \
       && grep -q '^kbdinteractiveauthentication no$' <<<"$eff"; then
        printf '已关闭'
    else
        printf '仍开启'
    fi
}

status_firewall() {
    local b
    b="$(detect_firewall_backend)"
    case "$b" in
        ufw) printf 'UFW 已启用' ;;
        ufw-inactive) printf 'UFW 已安装/未启用' ;;
        firewalld) printf 'firewalld 运行中（zone=%s）' "$(firewalld_zone)" ;;
        nftables) printf '自定义 nftables（只读）' ;;
        iptables) printf '自定义 iptables（只读）' ;;
        conflict) printf '⚠ UFW + firewalld 同时启用' ;;
        none) printf '未检测到主机防火墙' ;;
    esac
}
status_ufw() { status_firewall; }

status_fail2ban() {
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        printf '运行中'
    elif command -v fail2ban-client >/dev/null 2>&1; then
        printf '已安装/未运行'
    else
        printf '未安装'
    fi
}

status_auto_updates() {
    if [[ "$OS_FAMILY" == "debian" ]]; then
        if package_installed unattended-upgrades \
           && grep -Eq 'APT::Periodic::Unattended-Upgrade[[:space:]]+"1";' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; then
            printf '已开启（unattended-upgrades）'
        elif package_installed unattended-upgrades; then
            printf '已安装/未开启'
        else
            printf '未安装'
        fi
    elif systemctl is-enabled --quiet dnf-automatic-install.timer 2>/dev/null; then
        printf '已开启（dnf-automatic）'
    elif package_installed dnf-automatic; then
        printf '已安装/未开启'
    elif systemctl is-enabled --quiet yum-cron.service 2>/dev/null; then
        printf '已开启（yum-cron）'
    else
        printf '未安装'
    fi
}

status_public_listeners() {
    local n
    n="$(ss -lntupH 2>/dev/null | awk '$1 ~ /^(tcp|udp)/ && $5 !~ /^(127\.|\[::1\]:|::1:)/ {n++} END{print n+0}')"
    printf '%s 项' "${n:-0}"
}

docker_public_mapping_count() {
    command -v docker >/dev/null 2>&1 || { printf '0'; return; }
    local n
    n="$(docker ps --format '{{.Ports}}' 2>/dev/null | tr ',' '\n' | grep -Ec '(^|[[:space:]])(0\.0\.0\.0:|\[::\]:|:::)[0-9]+' || true)"
    printf '%s' "${n:-0}"
}
status_docker() {
    if ! command -v docker >/dev/null 2>&1; then printf '未安装'; return; fi
    if ! systemctl is-active --quiet docker 2>/dev/null; then printf '已安装/未运行'; return; fi
    printf '运行中；公网映射 %s 项' "$(docker_public_mapping_count)"
}
status_docker_firewall() {
    command -v docker >/dev/null 2>&1 || { printf '不适用'; return; }
    if command -v iptables >/dev/null 2>&1 && iptables -S DOCKER-USER >/dev/null 2>&1; then
        local n
        n="$(iptables -S DOCKER-USER 2>/dev/null | grep -vc '^-N ' || true)"
        if (( n > 1 )); then printf '存在自定义规则（请审计）'; else printf '未配置额外保护 ⚠'; fi
    else
        printf '未检测到 DOCKER-USER'
    fi
}
ipv6_kernel_disabled() {
    [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || true)" == "1" ]]
}
status_ipv6() {
    if ipv6_kernel_disabled; then
        printf '已关闭（内核网络栈）'
    elif has_global_ipv6; then
        printf '已启用（%s）' "$(get_global_ipv6)"
    else
        printf '已启用；无公网 IPv6 地址'
    fi
}
status_ipv6_firewall() {
    if ! has_global_ipv6; then printf '不适用'; return; fi
    case "$(detect_firewall_backend)" in
        ufw)
            if grep -Eq '^IPV6=yes' /etc/default/ufw 2>/dev/null; then
                printf 'UFW 已启用并覆盖 IPv6'
            else
                printf '⚠ UFW 已启用，但 IPv6 未覆盖'
            fi
            ;;
        ufw-inactive) printf '⚠ UFW 未启用，IPv6 未受 UFW 实际保护' ;;
        firewalld) printf 'firewalld 双栈管理（需结合 zone 规则确认）' ;;
        nftables) printf '自定义 nftables（需人工确认）' ;;
        iptables) printf '自定义 iptables（IPv6 需另查 ip6tables/nftables）' ;;
        conflict) printf '⚠ 防火墙后端冲突' ;;
        none) printf '⚠ 未检测到主机防火墙' ;;
    esac
}
status_keepalive() {
    local eff
    eff="$($SSHD_BIN -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null || true)"
    if grep -q '^clientaliveinterval 60$' <<<"$eff" && grep -q '^clientalivecountmax 3$' <<<"$eff"; then
        printf '已开启'
    else
        printf '默认/未配置'
    fi
}
status_report() {
    local latest="${LAST_REPORT:-}"
    if [[ -n "$latest" && -f "$latest" ]]; then
        printf '已生成'
    elif compgen -G "$REPORT_DIR/security-report-*.txt" >/dev/null 2>&1; then
        printf '已生成'
    else
        printf '未生成'
    fi
}
status_audit() {
    if [[ -n "${LAST_AUDIT:-}" && -f "${LAST_AUDIT:-}" ]]; then printf '已执行';
    elif compgen -G "$REPORT_DIR/audit-*.txt" >/dev/null 2>&1; then printf '已执行'; else printf '未执行'; fi
}
status_backup() {
    local latest="${LAST_BACKUP:-}"
    if [[ -n "$latest" && -d "$latest" ]]; then
        printf '已保存'
    elif compgen -G "$BACKUP_ROOT/ssh-*" >/dev/null 2>&1; then
        printf '已保存'
    else
        printf '未保存'
    fi
}
status_port_manager() {
    case "$(detect_firewall_backend)" in
        ufw) printf 'UFW 可用' ;;
        ufw-inactive) printf 'UFW 待启用' ;;
        firewalld) printf 'firewalld 可用' ;;
        nftables) printf '自定义 nftables：只读' ;;
        iptables) printf '自定义 iptables：只读' ;;
        conflict) printf '⚠ UFW/firewalld 冲突' ;;
        none) printf '未配置' ;;
    esac
}
reboot_required() {
    local rc
    [[ -f /var/run/reboot-required || -f /run/smart-restart/reboot-hint-marker ]] && return 0
    if command -v needs-restarting >/dev/null 2>&1; then
        rc=0
        needs-restarting -r >/dev/null 2>&1 || rc=$?
        (( rc == 1 )) && return 0
    fi
    return 1
}
status_reboot_required() {
    reboot_required && printf '需要重启' || printf '当前无需重启'
}
show_security_status() {
    say
    ui_section "登录与认证"
    ui_pair "SSH 端口：$(status_ssh_port)" "SSH 密码认证：$(status_password_auth)"
    ui_pair "ED25519 公钥：$(status_ed25519_key)" "root 密码：$(status_root_password)"
    ui_pair "密钥登录测试：$(status_key_test)" "SSH KeepAlive：$(status_keepalive)"
    say
    ui_section "网络与系统"
    ui_pair "主机防火墙：$(status_firewall)" "Fail2ban：$(status_fail2ban)"
    ui_pair "系统更新：$(status_system_update)" "自动安全更新：$(status_auto_updates)"
    ui_pair "公网监听：$(status_public_listeners)" "业务端口保护：$(status_preflight)"
    ui_pair "Docker：$(status_docker)" "Docker 防火墙：$(status_docker_firewall)"
    ui_value "IPv6 防火墙：" "$(status_ipv6_firewall)"
    say
    ui_section "报告与维护"
    ui_pair "安全检查报告：$(status_report)" "只读安全审计：$(status_audit)"
    ui_pair "配置备份：$(status_backup)" "端口防火墙管理：$(status_port_manager)"
    ui_value "系统重启：" "$(status_reboot_required)"
}
backup_ssh() {
    local dir
    dir="$BACKUP_ROOT/ssh-$(date +%Y%m%d-%H%M%S)-$RANDOM"
    mkdir -p "$dir"
    chmod 700 "$dir"
    cp -a "$SSHD_CONFIG" "$dir/sshd_config"
    [[ -d /etc/ssh/sshd_config.d ]] && cp -a /etc/ssh/sshd_config.d "$dir/" || true
    [[ -f /root/.ssh/authorized_keys ]] && cp -a /root/.ssh/authorized_keys "$dir/authorized_keys" || true
    [[ -f /etc/fail2ban/jail.d/vps-security-sshd.local ]] && cp -a /etc/fail2ban/jail.d/vps-security-sshd.local "$dir/" || true
    if is_ufw_installed; then
        tar -C / -czf "$dir/ufw-config.tgz" etc/ufw etc/default/ufw 2>/dev/null || true
        ufw status numbered > "$dir/ufw-status.txt" 2>&1 || true
    fi
    if is_firewalld_active || [[ -d /etc/firewalld ]]; then
        tar -C / -czf "$dir/firewalld-config.tgz" etc/firewalld 2>/dev/null || true
        firewall-cmd --list-all-zones > "$dir/firewalld-zones.txt" 2>&1 || true
    fi
    LAST_BACKUP="$dir"
    save_state
    printf '%s\n' "$dir"
}

_unit_enabled_state() {
    local state
    state="$(systemctl is-enabled "$1" 2>/dev/null || true)"
    printf '%s' "${state:-disabled}"
}
_unit_active_state() {
    local state
    state="$(systemctl is-active "$1" 2>/dev/null || true)"
    printf '%s' "${state:-inactive}"
}

begin_ssh_transaction() {
    local old_port="$1" new_port="$2" dir
    if [[ -n "${SSH_TXN_DIR:-}" && -d "$SSH_TXN_DIR" && ! -f "$SSH_TXN_DIR/COMMITTED" && ! -f "$SSH_TXN_DIR/ROLLED_BACK" ]]; then
        say "❌ 存在未完成的 SSH 事务，请先执行第 5 项确认或回滚。"
        return 1
    fi
    dir="$TXN_ROOT/ssh-$(date +%Y%m%d-%H%M%S)-$RANDOM"
    mkdir -p "$dir" || return 1
    chmod 700 "$dir" || return 1

    cp -a "$SSHD_CONFIG" "$dir/sshd_config" || return 1
    if [[ -d /etc/ssh/sshd_config.d ]]; then
        cp -a /etc/ssh/sshd_config.d "$dir/" || return 1
        printf '1\n' > "$dir/had-sshd-config-d"
    fi
    if [[ -d /root/.ssh ]]; then
        printf '1\n' > "$dir/had-root-ssh-dir"
    fi
    if [[ -f /root/.ssh/authorized_keys ]]; then
        mkdir -p "$dir/root-ssh"
        cp -a /root/.ssh/authorized_keys "$dir/root-ssh/authorized_keys" || return 1
        printf '1\n' > "$dir/had-authorized-keys"
    else
        printf '1\n' > "$dir/had-no-authorized-keys"
    fi
    if [[ -f "$STATE_FILE" ]]; then cp -a "$STATE_FILE" "$dir/state.env" || return 1; fi

    if [[ -f /etc/fail2ban/jail.d/vps-security-sshd.local ]]; then
        cp -a /etc/fail2ban/jail.d/vps-security-sshd.local "$dir/fail2ban-sshd.local" || return 1
        printf '1\n' > "$dir/had-fail2ban-file"
    fi

    if is_ufw_installed; then
        tar -C / -czf "$dir/ufw-config.tgz" etc/ufw etc/default/ufw 2>/dev/null || return 1
        ufw status numbered > "$dir/ufw-status.txt" 2>&1 || true
        printf '1\n' > "$dir/had-ufw"
    fi
    if command -v firewall-cmd >/dev/null 2>&1 || [[ -d /etc/firewalld ]]; then
        if [[ -d /etc/firewalld ]]; then
            tar -C / -czf "$dir/firewalld-config.tgz" etc/firewalld 2>/dev/null || return 1
        fi
        command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --list-all-zones > "$dir/firewalld-zones.txt" 2>&1 || true
        printf '1\n' > "$dir/had-firewalld"
    fi
    command -v iptables-save >/dev/null 2>&1 && iptables-save > "$dir/iptables-save.txt" 2>&1 || true
    command -v nft >/dev/null 2>&1 && nft list ruleset > "$dir/nft-ruleset.txt" 2>&1 || true

    cat > "$dir/meta.env" <<EOF || return 1
OLD_PORT=$(printf '%q' "$old_port")
NEW_PORT=$(printf '%q' "$new_port")
SSH_SERVICE_ENABLED=$(printf '%q' "$(_unit_enabled_state "$SSH_SERVICE.service")")
SSH_SERVICE_ACTIVE=$(printf '%q' "$(_unit_active_state "$SSH_SERVICE.service")")
SSH_SOCKET_ENABLED=$(printf '%q' "$(_unit_enabled_state ssh.socket)")
SSH_SOCKET_ACTIVE=$(printf '%q' "$(_unit_active_state ssh.socket)")
FAIL2BAN_ENABLED=$(printf '%q' "$(_unit_enabled_state fail2ban.service)")
FAIL2BAN_ACTIVE=$(printf '%q' "$(_unit_active_state fail2ban.service)")
UFW_ACTIVE=$(is_ufw_active && printf yes || printf no)
FIREWALLD_ACTIVE=$(is_firewalld_active && printf yes || printf no)
EOF
    [[ -s "$dir/meta.env" ]] || return 1
    chmod 600 "$dir/meta.env" || return 1
    SSH_TXN_DIR="$dir"
    SSH_TXN_OLD_PORT="$old_port"
    SSH_TXN_NEW_PORT="$new_port"
    PORT_BACKUP="$dir"
    save_state || return 1
    log "开始 SSH 事务：$old_port -> $new_port；事务目录 $dir"
    printf '%s\n' "$dir"
}

_restore_enable_state() {
    local unit="$1" wanted="$2"
    case "$wanted" in
        enabled|enabled-runtime|linked|linked-runtime|alias) systemctl enable "$unit" >/dev/null 2>&1 || true ;;
        masked|masked-runtime) systemctl mask "$unit" >/dev/null 2>&1 || true ;;
        *) systemctl disable "$unit" >/dev/null 2>&1 || true ;;
    esac
}

restore_ssh_config() {
    local dir="$1"
    [[ -f "$dir/sshd_config" ]] || { say "❌ 找不到 SSH 备份：$dir"; return 1; }
    cp -a "$dir/sshd_config" "$SSHD_CONFIG" || return 1
    if [[ -d "$dir/sshd_config.d" ]]; then
        rm -rf /etc/ssh/sshd_config.d
        cp -a "$dir/sshd_config.d" /etc/ssh/
    fi
    "$SSHD_BIN" -t || return 1
    systemctl enable "$SSH_SERVICE" >/dev/null 2>&1 || true
    systemctl restart "$SSH_SERVICE"
}

rollback_ssh_transaction() {
    local dir="${1:-${SSH_TXN_DIR:-}}"
    [[ -n "$dir" && -d "$dir" && -f "$dir/meta.env" ]] || { say "❌ 没有找到可回滚的 SSH 事务。"; return 1; }
    # shellcheck disable=SC1090
    source "$dir/meta.env"
    say "正在完整回滚 SSH 事务：$dir"

    cp -a "$dir/sshd_config" "$SSHD_CONFIG" || return 1
    if [[ -f "$dir/had-sshd-config-d" && -d "$dir/sshd_config.d" ]]; then
        rm -rf /etc/ssh/sshd_config.d
        cp -a "$dir/sshd_config.d" /etc/ssh/ || return 1
    fi

    if [[ -f "$dir/had-authorized-keys" ]]; then
        mkdir -p /root/.ssh
        cp -a "$dir/root-ssh/authorized_keys" /root/.ssh/authorized_keys
        chmod 700 /root/.ssh
        chmod 600 /root/.ssh/authorized_keys
        chown -R root:root /root/.ssh
    elif [[ -f "$dir/had-no-authorized-keys" ]]; then
        rm -f /root/.ssh/authorized_keys
        if [[ ! -f "$dir/had-root-ssh-dir" ]]; then
            rmdir /root/.ssh 2>/dev/null || true
        fi
    fi

    if [[ -f "$dir/had-fail2ban-file" ]]; then
        mkdir -p /etc/fail2ban/jail.d
        cp -a "$dir/fail2ban-sshd.local" /etc/fail2ban/jail.d/vps-security-sshd.local
    else
        rm -f /etc/fail2ban/jail.d/vps-security-sshd.local 2>/dev/null || true
    fi

    if [[ -f "$dir/ufw-config.tgz" && -x "$(command -v ufw 2>/dev/null || true)" ]]; then
        tar -tzf "$dir/ufw-config.tgz" >/dev/null 2>&1 || { say "❌ UFW 备份损坏，停止恢复。"; return 1; }
        rm -rf /etc/ufw
        tar -C / -xzf "$dir/ufw-config.tgz" 2>/dev/null || return 1
        if [[ "${UFW_ACTIVE:-no}" == "yes" ]]; then
            ufw --force enable >/dev/null 2>&1 || return 1
            ufw reload >/dev/null 2>&1 || return 1
        else
            ufw --force disable >/dev/null 2>&1 || return 1
        fi
    fi

    # Undo only the added SSH allow; a reload would destroy unrelated runtime rules.
    if [[ -f "$dir/firewalld-zone" ]] && command -v firewall-cmd >/dev/null 2>&1; then
        local fw_zone fw_port
        fw_zone="$(cat "$dir/firewalld-zone")"
        fw_port="${NEW_PORT}/tcp"
        if [[ ! -f "$dir/firewalld-had-runtime-port" ]]; then
            firewall-cmd --zone="$fw_zone" --remove-port="$fw_port" >/dev/null || return 1
        fi
        if [[ ! -f "$dir/firewalld-had-permanent-port" ]]; then
            firewall-cmd --permanent --zone="$fw_zone" --remove-port="$fw_port" >/dev/null || return 1
        fi
    fi

    "$SSHD_BIN" -t || { say "❌ 备份 SSH 配置校验失败，停止自动重启 SSH。"; return 1; }

    _restore_enable_state "$SSH_SERVICE.service" "${SSH_SERVICE_ENABLED:-enabled}"
    _restore_enable_state ssh.socket "${SSH_SOCKET_ENABLED:-disabled}"

    if [[ "${SSH_SOCKET_ACTIVE:-inactive}" == "active" ]]; then
        systemctl start ssh.socket >/dev/null 2>&1 || true
    else
        systemctl stop ssh.socket >/dev/null 2>&1 || true
    fi

    if [[ "${SSH_SERVICE_ACTIVE:-active}" == "active" ]]; then
        systemctl restart "$SSH_SERVICE" >/dev/null 2>&1 || return 1
    elif [[ "${SSH_SOCKET_ACTIVE:-inactive}" == "active" ]]; then
        systemctl stop "$SSH_SERVICE" >/dev/null 2>&1 || true
    else
        # 安全优先：即使原服务状态记录异常，也保持一个可用 SSH 监听。
        systemctl restart "$SSH_SERVICE" >/dev/null 2>&1 || return 1
    fi

    if command -v fail2ban-client >/dev/null 2>&1; then
        _restore_enable_state fail2ban.service "${FAIL2BAN_ENABLED:-disabled}"
        if [[ "${FAIL2BAN_ACTIVE:-inactive}" == "active" ]]; then
            systemctl restart fail2ban >/dev/null 2>&1 || true
        else
            systemctl stop fail2ban >/dev/null 2>&1 || true
        fi
    fi

    if [[ -f "$dir/selinux-added-ssh-port" ]] && command -v semanage >/dev/null 2>&1; then
        semanage port -d -t ssh_port_t -p tcp "$(cat "$dir/selinux-added-ssh-port")" >/dev/null 2>&1 || true
    fi

    if [[ -f "$dir/state.env" ]]; then cp -a "$dir/state.env" "$STATE_FILE"; fi
    load_state
    SSH_TXN_DIR=""
    SSH_TXN_OLD_PORT=""
    SSH_TXN_NEW_PORT=""
    PORT_BACKUP=""
    SSH_PORT="${OLD_PORT:-$(get_primary_ssh_port)}"
    KEY_TESTED="0"
    save_state
    printf '%s\n' "ROLLED_BACK $(date '+%F %T')" > "$dir/ROLLED_BACK"
    log "SSH 事务已完整回滚：$dir"
    say "✅ SSH 配置已完整回滚。"
    say "SSH：$(get_primary_ssh_port)"
    say "ssh.socket：${SSH_SOCKET_ACTIVE:-unknown}/${SSH_SOCKET_ENABLED:-unknown}"
    say "Fail2ban：已恢复原配置/状态"
    say "防火墙：已尝试恢复事务前状态"
}

commit_ssh_transaction() {
    local dir="${1:-${SSH_TXN_DIR:-}}"
    [[ -n "$dir" && -d "$dir" ]] || return 0
    printf '%s\n' "COMMITTED $(date '+%F %T')" > "$dir/COMMITTED" || return 1
    log "SSH 事务提交：$dir"
    SSH_TXN_DIR=""
    SSH_TXN_OLD_PORT=""
    SSH_TXN_NEW_PORT=""
    PORT_BACKUP=""
    save_state
}
remove_managed_block() {
    local tmp
    tmp="$(mktemp)" || return 1
    awk -v b="$MANAGED_BEGIN" -v e="$MANAGED_END" '
        $0==b {skip=1; next}
        $0==e {skip=0; next}
        !skip {print}
    ' "$SSHD_CONFIG" > "$tmp" || { rm -f "$tmp"; return 1; }
    cat "$tmp" > "$SSHD_CONFIG" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
}

comment_existing_port_directives() {
    local f
    shopt -s nullglob
    local files=("$SSHD_CONFIG" /etc/ssh/sshd_config.d/*.conf)
    for f in "${files[@]}"; do
        [[ -f "$f" ]] || continue
        sed -Ei 's/^([[:space:]]*)Port[[:space:]]+([0-9]+)([[:space:]]*(#.*)?)$/\1# VPS-SECURITY disabled previous Port \2\3/' "$f" || return 1
    done
    shopt -u nullglob
}

write_sshd_managed_block() {
    local port="$1" locked="$2"
    local tmp
    remove_managed_block || return 1
    comment_existing_port_directives || return 1
    tmp="$(mktemp)" || return 1
    {
        echo "$MANAGED_BEGIN"
        echo "Port $port"
        echo "PubkeyAuthentication yes"
        if [[ "$locked" == "1" ]]; then
            echo "PasswordAuthentication no"
            echo "KbdInteractiveAuthentication no"
            echo "ChallengeResponseAuthentication no"
            echo "PermitEmptyPasswords no"
            # Preserve the administrator's existing PermitRootLogin policy.
        fi
        if [[ "${KEEPALIVE_ENABLED:-0}" == "1" ]]; then
            echo "ClientAliveInterval 60"
            echo "ClientAliveCountMax 3"
            echo "TCPKeepAlive yes"
        fi
        echo "$MANAGED_END"
        echo
        cat "$SSHD_CONFIG"
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    cat "$tmp" > "$SSHD_CONFIG" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
}
prepare_ssh_service_mode() {
    PORT_SOCKET_WAS_ENABLED="$(systemctl is-enabled ssh.socket 2>/dev/null || true)"
    PORT_SOCKET_WAS_ACTIVE="$(systemctl is-active ssh.socket 2>/dev/null || true)"
    if systemd_unit_loaded ssh.socket; then
        if systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
            say "检测到 ssh.socket，切换为 ssh.service 常驻监听模式..."
            systemctl disable --now ssh.socket >/dev/null 2>&1 || true
            systemctl enable "$SSH_SERVICE" >/dev/null 2>&1 || true
        fi
    fi
}

allow_ssh_port_in_firewall() {
    local port="$1" backend zone rc
    backend="$(detect_firewall_backend)"
    case "$backend" in
        ufw|ufw-inactive)
            rc=0
            ufw_safe_allow "$port" tcp "SSH - VPS Security" "1" || rc=$?
            (( rc == 0 )) || return "$rc"
            if is_ufw_active; then
                say "✅ UFW 已放行新的 SSH 端口：$port/tcp"
            else
                say "✅ 已预写 UFW 放行规则：$port/tcp（UFW 当前未启用）"
            fi
            ;;
        firewalld)
            zone="$(firewalld_zone)"
            if [[ -n "${SSH_TXN_DIR:-}" ]]; then
                printf '%s\n' "$zone" > "$SSH_TXN_DIR/firewalld-zone" || return 1
                if firewall-cmd --zone="$zone" --query-port="$port/tcp" >/dev/null 2>&1; then
                    touch "$SSH_TXN_DIR/firewalld-had-runtime-port" || return 1
                fi
                if firewall-cmd --permanent --zone="$zone" --query-port="$port/tcp" >/dev/null 2>&1; then
                    touch "$SSH_TXN_DIR/firewalld-had-permanent-port" || return 1
                fi
            fi
            firewalld_allow_safe "$port" tcp "SSH - VPS Security" || return 1
            say "✅ firewalld 已放行新的 SSH 端口：$port/tcp（zone=$zone）"
            ;;
        nftables|iptables)
            say "⚠️ 检测到自定义 $backend。本工具不会自动修改自定义规则。"
            say "请确认你的 $backend/外部防火墙已允许 TCP $port，否则修改 SSH 后可能无法新建连接。"
            if ! confirm_y "你已经确认 $backend/外部防火墙允许 TCP $port，并继续？"; then
                return 2
            fi
            ;;
        conflict)
            say "❌ 检测到 UFW 与 firewalld 同时启用。请先人工停用其中一个，再修改 SSH 端口。"
            return 2
            ;;
        none)
            say "ℹ️ 未检测到 UFW/firewalld，本机没有由本工具管理的主机防火墙。"
            say "如果云厂商有安全组/外部防火墙，请同时开放 TCP $port。"
            ;;
    esac
}

allow_ssh_port_in_selinux() {
    local port="$1" txn="$2" semanage_pkg
    command -v getenforce >/dev/null 2>&1 || return 0
    [[ "$(getenforce 2>/dev/null || true)" != "Disabled" ]] || return 0

    if ! command -v semanage >/dev/null 2>&1; then
        say "SELinux 已启用，正在安装 SSH 端口管理工具..."
        if [[ "$OS_ID" == "centos" && "$OS_VERSION_ID" == 7* ]]; then
            semanage_pkg="policycoreutils-python"
        else
            semanage_pkg="policycoreutils-python-utils"
        fi
        pkg_refresh || return 1
        pkg_install "$semanage_pkg" || return 1
    fi

    if semanage port -l 2>/dev/null | awk '$1=="ssh_port_t" && $2=="tcp" {for(i=3;i<=NF;i++) print $i}' \
        | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -Fxq "$port"; then
        say "ℹ️ SELinux 已允许 SSH 端口：$port/tcp"
        return 0
    fi
    if semanage port -a -t ssh_port_t -p tcp "$port" >/dev/null 2>&1; then
        printf '%s\n' "$port" > "$txn/selinux-added-ssh-port"
        say "✅ SELinux 已登记 SSH 端口：$port/tcp"
        return 0
    fi
    say "❌ SELinux 无法登记 SSH 端口 $port/tcp。"
    return 1
}

remove_old_ssh_firewall_rule() {
    local old="$1" new="$2" backend zone choice
    [[ -n "$old" && "$old" != "$new" ]] || return 0
    backend="$(detect_firewall_backend)"
    case "$backend" in
        ufw|ufw-inactive)
            if [[ "$(ufw_rule_state "$old" tcp)" == 'allow' ]]; then
                say
                say "旧 SSH 端口 $old/tcp 仍存在 ALLOW 规则。"
                say "为避免误删你原本手工创建的规则，本工具不会静默删除。"
                ui_item 1 '保留旧端口规则（默认）'
                ui_item 2 '删除简单 ALLOW 规则'
                choose_num choice '请选择 [默认1]：' '1 2' '1'
                if [[ "$choice" == '2' ]]; then
                    ufw delete allow "$old/tcp" >/dev/null 2>&1 || true
                    say "✅ 已尝试删除旧 SSH 端口 ALLOW：$old/tcp"
                else
                    say "ℹ️ 已保留旧 SSH 端口防火墙规则：$old/tcp"
                fi
            fi
            ;;
        firewalld)
            zone="$(firewalld_zone)"
            if firewall-cmd --zone="$zone" --query-port="$old/tcp" >/dev/null 2>&1; then
                say
                say "旧 SSH 端口 $old/tcp 仍在 firewalld zone=$zone 中放行。"
                ui_item 1 '保留旧端口规则（默认）'
                ui_item 2 '删除旧端口放行'
                choose_num choice '请选择 [默认1]：' '1 2' '1'
                if [[ "$choice" == '2' ]]; then
                    firewall-cmd --zone="$zone" --remove-port="$old/tcp" >/dev/null 2>&1 || true
                    firewall-cmd --permanent --zone="$zone" --remove-port="$old/tcp" >/dev/null 2>&1 || true
                    say "✅ 已删除旧 SSH 端口放行：$old/tcp"
                else
                    say "ℹ️ 已保留旧 SSH 端口防火墙规则：$old/tcp"
                fi
            fi
            ;;
        *) : ;;
    esac
}
update_fail2ban_ssh_port() {
    local port="$1"
    if ! command -v fail2ban-client >/dev/null 2>&1 || [[ ! -d /etc/fail2ban ]]; then
        return 0
    fi
    mkdir -p /etc/fail2ban/jail.d
    cat > /etc/fail2ban/jail.d/vps-security-sshd.local <<EOF
[sshd]
enabled = true
backend = systemd
port = $port
maxretry = 5
findtime = 10m
bantime = 1h
EOF
    if ! fail2ban-client -t >/dev/null 2>&1; then
        say '❌ Fail2ban 配置检查失败。'
        return 1
    fi
    if ! systemctl restart fail2ban >/dev/null 2>&1; then
        say '❌ Fail2ban 重启失败。'
        return 1
    fi
    sleep 1
    if ! fail2ban-client status sshd >/dev/null 2>&1; then
        say '❌ Fail2ban sshd jail 未正常运行。'
        return 1
    fi
    say "✅ Fail2ban 配置检查通过，sshd jail 已加载端口：$port"
}

detect_business_services() {
    local services_found=()
    command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null && services_found+=("Docker")
    { systemctl is-active --quiet nginx 2>/dev/null || pgrep -x nginx >/dev/null 2>&1; } && services_found+=("Nginx")
    pgrep -x openresty >/dev/null 2>&1 && services_found+=("OpenResty")
    [[ -d /opt/1panel || -d /opt/1Panel ]] && services_found+=("1Panel")
    { systemctl is-active --quiet x-ui 2>/dev/null || systemctl is-active --quiet 3x-ui 2>/dev/null; } && services_found+=("x-ui/3x-ui")
    { pgrep -x mysqld >/dev/null 2>&1 || pgrep -x mariadbd >/dev/null 2>&1; } && services_found+=("MySQL/MariaDB")
    pgrep -x postgres >/dev/null 2>&1 && services_found+=("PostgreSQL")
    pgrep -x redis-server >/dev/null 2>&1 && services_found+=("Redis")
    pgrep -f '[k]omari' >/dev/null 2>&1 && services_found+=("Komari")
    pgrep -f '[q]inglong' >/dev/null 2>&1 && services_found+=("QingLong")
    printf '%s\n' "${services_found[@]}" | awk 'NF&&!seen[$0]++'
}

step1_update_system() {
    say
    ui_heading "1. 更新系统"
    say "系统：$OS_PRETTY_NAME"
    say "包管理器：$PKG_MANAGER"
    say

    local business choice mode="normal"
    business="$(detect_business_services || true)"
    if [[ -n "$business" ]]; then
        say "检测到本机已有业务："
        while IFS= read -r x; do [[ -n "$x" ]] && say "  - $x"; done <<< "$business"
        say
        ui_item 1 "安全更新模式（推荐；Debian 避免 needrestart 自动重启业务服务）"
        ui_item 2 "正常系统更新"
        ui_item 0 "跳过本次更新"
        choose_num choice "请选择 [默认1]：" "1 2 0" "1"
        case "$choice" in
            0) say "已跳过系统更新。"; return 0 ;;
            1) mode="safe" ;;
            2) mode="normal" ;;
        esac
    fi

    if [[ "$OS_FAMILY" == "debian" && "$mode" == "safe" ]]; then
        export NEEDRESTART_MODE=l
    elif [[ "$OS_FAMILY" == "debian" ]]; then
        export NEEDRESTART_MODE=a
    fi
    pkg_upgrade_system || return 1
    log "系统更新完成；系统=$OS_ID $OS_VERSION_ID；包管理器=$PKG_MANAGER；模式=$mode"
    say "✅ 系统更新完成。"

    if [[ "$OS_FAMILY" == "debian" ]] && command -v needrestart >/dev/null 2>&1; then
        say
        say "服务重启建议（只读）："
        NEEDRESTART_MODE=l needrestart -r l 2>/dev/null >&4 || true
    fi
    if reboot_required; then
        say "⚠️ 系统提示需要重启；建议全部开荒完成并确认 SSH 正常后，再从主菜单选择重启。"
    fi
}
step2_change_root_password() {
    say
    ui_heading "2. 修改 root 密码"
    say "下面会让你输入两次新的 root 密码，输入时不会显示字符。"
    passwd root </dev/tty
    log "root 密码已修改"
    say "✅ root 密码修改完成。"
}

step3_random_ssh_port() {
    say
    ui_heading "3. 随机 SSH 高位端口"

    local current new input locked server_ip txn rc
    current="$(get_primary_ssh_port)"
    server_ip="$(get_server_ip)"

    if [[ -n "${SSH_TXN_DIR:-}" && -d "${SSH_TXN_DIR:-}" && ! -f "$SSH_TXN_DIR/COMMITTED" && ! -f "$SSH_TXN_DIR/ROLLED_BACK" ]]; then
        say "⚠️ 检测到尚未完成的 SSH 事务：$SSH_TXN_DIR"
        say "请先执行第 5 项测试新窗口，确认成功或回滚后再修改端口。"
        return 1
    fi

    say "当前 SSH 端口：$current"
    say "防火墙后端：$(detect_firewall_backend)"
    say

    if [[ "$current" =~ ^[0-9]+$ ]] && (( current >= 20000 && current <= 65535 )); then
        if confirm_y "当前 SSH 已是高位端口 $current，是否保持不变？"; then
            say "✅ 保持当前 SSH 端口：$current"
            return 0
        fi
    fi

    while true; do
        while true; do
            new="$(shuf -i 20000-60000 -n 1)"
            port_is_listening "$new" || break
        done
        say "随机生成端口：$new"
        if confirm_y "使用这个随机端口？"; then
            break
        fi
        ask input "请输入自定义端口；直接回车=重新随机："
        if [[ -z "$input" ]]; then
            continue
        elif input="$(normalize_decimal_port "$input")" && (( input >= 1024 )); then
            if port_is_listening "$input"; then
                say "❌ 端口 $input 已被占用。"
                continue
            fi
            new="$input"
            break
        else
            say "❌ 输入无效，只能输入 1024-65535 的端口号。"
        fi
    done

    [[ "$new" != "$current" ]] || { say "ℹ️ 新端口与当前端口相同，无需修改。"; return 0; }

    begin_ssh_transaction "$current" "$new" >/dev/null || return 1
    txn="$SSH_TXN_DIR"
    PREVIOUS_SSH_PORT="$current"
    PORT_BACKUP="$txn"
    KEY_TESTED="0"
    SSH_TXN_OLD_PORT="$current"
    SSH_TXN_NEW_PORT="$new"
    save_state

    rc=0
    allow_ssh_port_in_firewall "$new" || rc=$?
    if (( rc != 0 )); then
        say "❌ 新 SSH 端口未能安全通过防火墙预检，正在回滚。"
        rollback_ssh_transaction "$txn" || true
        return 1
    fi
    if ! allow_ssh_port_in_selinux "$new" "$txn"; then
        say "❌ 新 SSH 端口未能通过 SELinux 检查，正在回滚。"
        rollback_ssh_transaction "$txn" || true
        return 1
    fi

    locked="0"
    sshd_password_auth_disabled && locked="1"
    if ! write_sshd_managed_block "$new" "$locked"; then
        rollback_ssh_transaction "$txn"
        return 1
    fi
    prepare_ssh_service_mode

    if ! "$SSHD_BIN" -t; then
        say "❌ sshd 配置检查失败，正在完整回滚..."
        rollback_ssh_transaction "$txn"
        return 1
    fi
    if ! systemctl restart "$SSH_SERVICE"; then
        say "❌ SSH 服务重启失败，正在完整回滚..."
        rollback_ssh_transaction "$txn"
        return 1
    fi
    sleep 1
    if ! port_is_listening "$new"; then
        say "❌ SSH 没有监听新端口 $new，正在完整回滚..."
        rollback_ssh_transaction "$txn"
        return 1
    fi

    SSH_PORT="$new"
    PASSWORD_LOCKED="$locked"
    save_state
    if ! update_fail2ban_ssh_port "$new"; then
        say "❌ Fail2ban 未能同步到新的 SSH 端口，正在完整回滚..."
        rollback_ssh_transaction "$txn"
        return 1
    fi
    log "SSH 端口从 $current 修改为 $new；等待新窗口测试；事务 $txn"

    say
    say "✅ SSH 新端口已启用：$new"
    say "✅ 主机防火墙已按当前后端处理新 SSH 端口。"
    say "⚠️ 当前 SSH 窗口先不要关闭。"
    say "⚠️ 如果 VPS 商家有安全组/云防火墙，还需要在商家后台放行 TCP $new。"
    say "新连接：ssh -p $new root@$server_ip"
    say "事务备份：$txn"
}
step4_add_ed25519_key() {
    say
    ui_heading "4. 添加 ED25519 公钥"
    say "只粘贴【公钥】，不要粘贴私钥。"
    say "公钥应以 ssh-ed25519 开头，并且完整内容必须是一整行。"
    say

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    chown -R root:root /root/.ssh

    local pub tmp fp
    while true; do
        ask pub "请粘贴 ED25519 公钥，然后按回车："
        pub="${pub%$'\r'}"
        if [[ -z "$pub" ]]; then
            say "❌ 没有检测到输入，请重新粘贴。"
            continue
        fi
        if [[ "$pub" == *"PRIVATE KEY"* ]]; then
            say "❌ 你粘贴的是私钥。私钥绝对不要上传服务器。"
            continue
        fi
        if [[ "$pub" != ssh-ed25519\ * ]]; then
            say "❌ 本工具要求 ED25519 公钥，应以 ssh-ed25519 开头。"
            continue
        fi
        tmp="$(mktemp)"
        printf '%s\n' "$pub" > "$tmp"
        if ssh-keygen -lf "$tmp" >/dev/null 2>&1; then
            fp="$(ssh-keygen -lf "$tmp" 2>/dev/null || true)"
            rm -f "$tmp"
            break
        fi
        rm -f "$tmp"
        say "❌ 公钥无效或复制不完整，请重新复制完整一行。"
    done

    if grep -Fxq "$pub" /root/.ssh/authorized_keys; then
        say "ℹ️ 该公钥已经存在，无需重复添加。"
    else
        cp -a /root/.ssh/authorized_keys "$BASE_DIR/authorized_keys-before-$(date +%Y%m%d-%H%M%S).bak"
        printf '%s\n' "$pub" >> /root/.ssh/authorized_keys
        say "✅ 公钥添加成功。"
    fi
    chmod 600 /root/.ssh/authorized_keys
    chown root:root /root/.ssh/authorized_keys
    KEY_TESTED="0"
    save_state
    log "ED25519 公钥已添加：$fp"
    say "密钥指纹：$fp"
}

step5_test_key() {
    say
    ui_heading "5. 新窗口测试密钥"

    local port server_ip choice old new txn
    port="$(get_primary_ssh_port)"
    server_ip="$(get_server_ip)"
    txn="${SSH_TXN_DIR:-}"
    old="${SSH_TXN_OLD_PORT:-${PREVIOUS_SSH_PORT:-}}"
    new="${SSH_TXN_NEW_PORT:-$port}"

    if [[ ! -s /root/.ssh/authorized_keys ]]; then
        say "❌ /root/.ssh/authorized_keys 为空，请先执行第 4 项。"
        return 1
    fi

    say "保持当前窗口不要关闭。"
    say "请在新窗口使用以下信息登录："
    say "  主机：$server_ip"
    say "  端口：$port"
    say "  用户：root"
    say "  认证：ED25519 私钥"
    say
    ui_item 1 "密钥登录成功，提交 SSH 修改"
    ui_item 2 "登录失败，完整回滚 SSH 修改"
    ui_item 0 "暂不处理，返回"
    say

    while true; do
        choose_num choice "请选择 [1/2/0]：" "1 2 0" "0"
        case "$choice" in
            1)
                KEY_TESTED="1"
                SSH_PORT="$port"
                save_state
                if [[ -n "$old" && "$old" != "$new" ]]; then
                    remove_old_ssh_firewall_rule "$old" "$new" || true
                fi
                [[ -n "$txn" ]] && commit_ssh_transaction "$txn"
                log "用户确认 SSH 密钥新窗口登录成功，端口 $port"
                say "✅ 密钥登录测试成功，SSH 事务已提交。"
                return 0
                ;;
            2)
                KEY_TESTED="0"
                save_state
                if [[ -n "$txn" && -d "$txn" ]]; then
                    rollback_ssh_transaction "$txn"
                    say "✅ 已恢复事务前 SSH / 防火墙 / Fail2ban / ssh.socket 状态。"
                    return 2
                fi
                say "⚠️ 没有检测到待回滚 SSH 事务。"
                return 1
                ;;
            0)
                say "已返回。当前待提交事务不会自动删除，请稍后重新执行第 5 项。"
                return 1
                ;;
        esac
    done
}
step6_disable_password_auth() {
    say
    ui_heading "6. 关闭 SSH 密码认证"

    local port txn eff
    port="$(get_primary_ssh_port)"

    if [[ ! -s /root/.ssh/authorized_keys ]]; then
        say "❌ 没有检测到 root SSH 公钥，拒绝关闭密码登录。"
        return 1
    fi
    if [[ "${KEY_TESTED:-0}" != "1" ]]; then
        say "❌ 请先执行第 5 项，在新窗口验证密钥登录成功，再关闭密码认证。"
        return 1
    fi

    begin_ssh_transaction "$port" "$port" >/dev/null || return 1
    txn="$SSH_TXN_DIR"
    if ! write_sshd_managed_block "$port" "1"; then
        rollback_ssh_transaction "$txn"
        return 1
    fi

    if ! "$SSHD_BIN" -t; then
        say "❌ SSH 配置无效，正在回滚。"
        rollback_ssh_transaction "$txn"
        return 1
    fi
    if ! systemctl restart "$SSH_SERVICE"; then
        say "❌ SSH 重启失败，正在回滚。"
        rollback_ssh_transaction "$txn"
        return 1
    fi
    sleep 1

    eff="$($SSHD_BIN -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null || true)"
    if ! grep -q '^passwordauthentication no$' <<<"$eff" || ! grep -q '^kbdinteractiveauthentication no$' <<<"$eff"; then
        say "❌ 实际 SSH 配置没有完全关闭密码认证，正在回滚。"
        rollback_ssh_transaction "$txn"
        return 1
    fi

    PASSWORD_LOCKED="1"
    SSH_PORT="$port"
    KEY_TESTED="0"
    save_state
    log "SSH 密码认证已关闭；等待第 5 项新窗口确认，事务 $txn"
    say "✅ PasswordAuthentication no"
    say "✅ KbdInteractiveAuthentication no"
    say "✅ 保留原有 PermitRootLogin 策略"
    say "⚠️ 当前窗口先别关，再新开一个窗口用密钥测试，然后执行第 5 项提交或回滚。"
}
firewalld_rich_conflict() {
    local zone rules
    zone="$(firewalld_zone)"
    rules="$(firewall-cmd --zone="$zone" --list-rich-rules 2>/dev/null)" || return 0
    local permanent_rules
    permanent_rules="$(firewall-cmd --permanent --zone="$zone" --list-rich-rules 2>/dev/null)" || return 0
    rules+=$'\n'"$permanent_rules"
    # Source, service, range, and inverted rules need a real policy evaluator.
    # Fail closed when any rich rejection exists instead of claiming reachability.
    grep -Eiq '(^|[[:space:]])(reject|drop)([[:space:]]|$)' <<<"$rules"
}

firewalld_allow_safe() {
    local port="$1" proto="$2" label="$3" zone choice
    zone="$(firewalld_zone)"
    if firewalld_rich_conflict "$port" "$proto"; then
        say "⚠️ firewalld 存在 rich-rule reject/drop 或规则不可读取，无法安全确认 $port/$proto。"
        say "本工具不会自动删除复杂拒绝规则。"
        ui_item 1 "保持拒绝规则（推荐）"
        ui_item 0 "跳过"
        choose_num choice "请选择 [默认1]：" "1 0" "1"
        return 2
    fi
    if firewall-cmd --zone="$zone" --query-port="$port/$proto" >/dev/null 2>&1; then
        say "ℹ️ firewalld 已放行：$port/$proto"
    fi
    firewall-cmd --zone="$zone" --add-port="$port/$proto" >/dev/null || return 1
    firewall-cmd --permanent --zone="$zone" --add-port="$port/$proto" >/dev/null || return 1
    say "✅ firewalld 已放行：$port/$proto（$label）"
}

step7_configure_ufw() {
    say
    ui_heading "7. 安装/配置主机防火墙"

    ensure_business_preflight || return 1
    local backend ports p zone proto port class procs binds
    backend="$(detect_firewall_backend)"
    say "检测到防火墙后端：$backend"

    if [[ "$backend" == "none" && "$OS_FAMILY" == "rhel" ]]; then
        say "当前 RPM 系统未检测到主机防火墙，正在安装 firewalld..."
        pkg_refresh || return 1
        pkg_install firewalld || return 1
        say "为避免先启动默认拒绝策略导致 SSH/业务中断，本工具不会自动启动未运行的 firewalld。"
        say "请通过控制台使用 firewall-offline-cmd 预先配置 SSH/业务端口及接口 zone，再启动 firewalld 并重试。"
        return 1
    fi

    case "$backend" in
        conflict)
            say "❌ UFW 与 firewalld 同时启用，自动配置已停止。请先选择并保留一个防火墙后端。"
            return 1
            ;;
        firewalld)
            zone="$(firewalld_zone)"
            say "使用现有 firewalld，不安装/启用 UFW。默认 zone：$zone"
            ports="$(get_sshd_ports)"; [[ -n "$ports" ]] || ports="$(get_primary_ssh_port)"
            while read -r p; do
                [[ -n "$p" ]] || continue
                firewalld_allow_safe "$p" tcp "SSH - VPS Security" || return 1
            done <<< "$ports"
            if [[ -f "$PROTECTED_PORTS_FILE" ]]; then
                while IFS=$'\t' read -r proto port class procs binds; do
                    [[ -n "$port" && "$class" != "SSH" ]] || continue
                    firewalld_allow_safe "$port" "$proto" "Existing service - VPS Security" || return 1
                done < "$PROTECTED_PORTS_FILE"
            fi
            log "firewalld 已补齐 SSH 与确认保留的业务端口；zone=$zone"
            say "✅ firewalld 配置完成；未覆盖已有 rich-rule 拒绝规则。"
            firewall-cmd --zone="$zone" --list-all >&4 || true
            return 0
            ;;
        nftables|iptables)
            say "⚠️ 检测到自定义 $backend。"
            say '为避免破坏已有规则，本工具不会自动修改该防火墙。'
            say '你可以使用“只读安全检查”查看当前风险，并人工维护现有规则。'
            log "检测到自定义 $backend，跳过自动防火墙修改"
            return 0
            ;;
        none|ufw-inactive|ufw)
            ;;
    esac

    if ! is_ufw_installed; then
        say "未安装 UFW，正在安装..."
        pkg_refresh || return 1
        pkg_install ufw || return 1
    fi

    # Stage SSH and business allows before a live default policy can take effect.
    ports="$(get_sshd_ports)"; [[ -n "$ports" ]] || ports="$(get_primary_ssh_port)"
    while read -r p; do
        [[ -n "$p" ]] || continue
        if ! ufw_safe_allow "$p" tcp "SSH - VPS Security" "1"; then
            say "❌ 当前 SSH 端口 $p 存在未解决的 DENY 冲突，拒绝启用/重载 UFW。"
            return 1
        fi
    done <<< "$ports"

    ufw_allow_protected_business_ports || return 1
    ufw default deny incoming >/dev/null || return 1
    ufw default allow outgoing >/dev/null || return 1

    if ! is_ufw_active; then
        ufw --force enable >/dev/null || return 1
    else
        ufw reload >/dev/null || return 1
    fi

    log "UFW 已配置并启用；SSH：$(echo "$ports" | xargs)；业务保护：$PROTECTED_PORTS_FILE"
    say "✅ UFW 已启用。"
    say "✅ 默认入站：拒绝"
    say "✅ 默认出站：允许"
    say "✅ 已保留已有 DENY；冲突规则不会被静默覆盖。"
    say "✅ 原有 UFW 规则没有被 reset/清空。"
    say
    ufw status verbose >&4
    say
    say "ℹ️ 云厂商安全组/外部防火墙仍需在厂商后台单独设置。"
    if command -v docker >/dev/null 2>&1; then
        say "⚠️ 检测到 Docker：Docker NAT 可能绕过普通 UFW INPUT，请使用 Docker 安全检查查看。"
    fi
}
step8_install_fail2ban() {
    say
    ui_heading '8. 安装 Fail2ban'
    local port
    port="$(get_primary_ssh_port)"
    pkg_refresh || return 1
    if ! pkg_install fail2ban; then
        if [[ "$OS_FAMILY" == "rhel" && "$OS_ID" != "fedora" ]]; then
            say "默认软件源未提供 Fail2ban，尝试安装 EPEL 后重试..."
            pkg_install epel-release || return 1
            pkg_refresh || return 1
            pkg_install fail2ban || return 1
        else
            return 1
        fi
    fi
    systemctl enable fail2ban >/dev/null 2>&1 || true
    if ! update_fail2ban_ssh_port "$port"; then
        say '❌ Fail2ban 已安装，但 sshd jail 未通过端口验证。'
        return 1
    fi
    log "Fail2ban 已启用并验证，SSH 端口 $port"
    say '✅ Fail2ban 已安装、启用并验证。'
    fail2ban-client status sshd >&4 2>/dev/null || true
}

step9_enable_auto_updates() {
    say
    ui_heading "9. 开启自动安全更新"

    if [[ "$OS_FAMILY" == "debian" ]]; then
        pkg_refresh || return 1
        pkg_install unattended-upgrades || return 1
        cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
        systemctl enable --now unattended-upgrades.service >/dev/null 2>&1 || true
        log "unattended-upgrades 已启用"
        say "✅ 自动安全更新已启用：unattended-upgrades"
        say "配置：/etc/apt/apt.conf.d/20auto-upgrades"
    elif [[ "$PKG_MANAGER" == "dnf" ]]; then
        pkg_refresh || return 1
        pkg_install dnf-automatic || return 1
        [[ -f /etc/dnf/automatic.conf ]] || { say "❌ 未找到 /etc/dnf/automatic.conf"; return 1; }
        sed -Ei 's/^[[:space:]]*upgrade_type[[:space:]]*=.*/upgrade_type = security/' /etc/dnf/automatic.conf
        systemctl enable --now dnf-automatic-install.timer >/dev/null 2>&1 || return 1
        log "dnf-automatic 安全更新已启用"
        say "✅ 自动安全更新已启用：dnf-automatic-install.timer"
        say "配置：/etc/dnf/automatic.conf（upgrade_type = security）"
    else
        pkg_refresh || return 1
        pkg_install yum-cron || return 1
        [[ -f /etc/yum/yum-cron.conf ]] || { say "❌ 未找到 /etc/yum/yum-cron.conf"; return 1; }
        sed -Ei 's/^[[:space:]]*update_cmd[[:space:]]*=.*/update_cmd = security/' /etc/yum/yum-cron.conf
        sed -Ei 's/^[[:space:]]*apply_updates[[:space:]]*=.*/apply_updates = yes/' /etc/yum/yum-cron.conf
        systemctl enable --now yum-cron.service >/dev/null 2>&1 || return 1
        log "yum-cron 安全更新已启用"
        say "✅ 自动安全更新已启用：yum-cron"
        say "配置：/etc/yum/yum-cron.conf"
    fi
}

step10_scan_public_ports() {
    say
    ui_heading "10. 扫描公网监听端口"
    say "下面列出所有非回环 TCP/UDP 监听；127.0.0.1 / ::1 不视为公网业务端口。"
    say
    local line proto state _recvq _sendq local_ep _peer_ep rest bind
    local found=0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        read -r proto state _recvq _sendq local_ep _peer_ep rest <<< "$line"
        bind="${local_ep%:*}"
        bind="${bind#[}"
        bind="${bind%]}"
        if is_loopback_bind "$bind"; then
            continue
        fi
        printf '%s\n' "$line" >&4
        found=1
    done < <(ss -H -lntup 2>/dev/null || true)
    (( found == 1 )) || say "未发现非回环 TCP/UDP 监听。"
    say
    say "业务保护名单：$PROTECTED_PORTS_FILE"
    say "提示：监听公网 ≠ 一定能从互联网访问，还要结合 UFW、云安全组和 Docker 规则判断。"
    log "已执行公网监听端口扫描"
}

step11_security_report() {
    say
    ui_heading "11. 输出最终安全检查报告"

    local report
    report="$REPORT_DIR/security-report-$(date +%Y%m%d-%H%M%S).txt"
    local eff backend
    eff="$($SSHD_BIN -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null || true)"
    backend="$(detect_firewall_backend)"

    {
        echo "=================================================="
        echo "VPS Security Bootstrap 安全检查报告"
        echo "版本：$VERSION"
        echo "生成时间：$(date '+%F %T %Z')"
        echo "主机名：$(hostname)"
        echo "系统：$(get_os_pretty)"
        echo "系统家族：$OS_FAMILY"
        echo "包管理器：$PKG_MANAGER"
        echo "IPv4：$(get_ipv4)"
        echo "IPv6：$(get_global_ipv6)"
        echo "运行时间：$(get_uptime_short)"
        echo "=================================================="
        echo
        echo "[SSH]"
        echo "$eff" | grep -E '^(port|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|permitemptypasswords|permitrootlogin|clientaliveinterval|clientalivecountmax|tcpkeepalive) ' || true
        echo "root 密码状态：$(passwd -S root 2>/dev/null | awk '{print $2}' || echo unknown)"
        echo "authorized_keys 有效行数：$(grep -cE '^(ssh-ed25519|ssh-rsa|ecdsa-|sk-)' /root/.ssh/authorized_keys 2>/dev/null || true)"
        echo
        echo "[SSH 监听]"
        ss -lntp 2>/dev/null | grep -E 'sshd|ssh' || true
        echo
        echo "[主机防火墙]"
        echo "backend=$backend"
        case "$backend" in
            ufw|ufw-inactive) ufw status verbose 2>/dev/null || true ;;
            firewalld) firewall-cmd --list-all-zones 2>/dev/null || true ;;
            nftables) nft list ruleset 2>/dev/null || true ;;
            none) echo "未检测到由本工具管理的主机防火墙" ;;
        esac
        echo
        echo "[Fail2ban]"
        if command -v fail2ban-client >/dev/null 2>&1; then
            systemctl is-active fail2ban 2>/dev/null || true
            fail2ban-client status sshd 2>/dev/null || true
        else
            echo "未安装"
        fi
        echo
        echo "[自动安全更新]"
        echo "状态：$(status_auto_updates)"
        if [[ "$OS_FAMILY" == "debian" ]]; then
            cat /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null || true
        elif [[ "$PKG_MANAGER" == "dnf" ]]; then
            grep -E '^[[:space:]]*(upgrade_type|apply_updates)[[:space:]]*=' /etc/dnf/automatic.conf 2>/dev/null || true
            systemctl status dnf-automatic-install.timer --no-pager 2>/dev/null || true
        else
            grep -E '^[[:space:]]*(update_cmd|apply_updates)[[:space:]]*=' /etc/yum/yum-cron.conf 2>/dev/null || true
            systemctl status yum-cron.service --no-pager 2>/dev/null || true
        fi
        echo
        echo "[公网/非回环监听]"
        ss -H -lntup 2>/dev/null || true
        echo
        echo "[业务端口保护名单]"
        [[ -f "$PROTECTED_PORTS_FILE" ]] && cat "$PROTECTED_PORTS_FILE" || echo "尚未生成"
        echo
        echo "[Docker]"
        echo "状态：$(status_docker)"
        echo "防火墙：$(status_docker_firewall)"
        if command -v docker >/dev/null 2>&1; then
            docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
            echo
            command -v iptables >/dev/null 2>&1 && iptables -S DOCKER-USER 2>/dev/null || true
        fi
        echo
        echo "[IPv6]"
        echo "IPv6：$(status_ipv6)"
        echo "IPv6 防火墙：$(status_ipv6_firewall)"
        ip -6 addr show scope global 2>/dev/null || true
        echo
        echo "[重启提示]"
        reboot_required && echo "需要重启" || echo "当前没有重启提示"
        echo
        echo "[说明]"
        echo "云厂商安全组、NAT、WAF、Docker 端口映射不完全由本脚本控制。"
        echo "本工具不会自动清空现有防火墙规则，也不会默认改写 DOCKER-USER。"
    } | tee "$report" >&4

    LAST_REPORT="$report"
    save_state
    log "已生成安全报告：$report"
    say
    say "✅ 报告已保存：$report"
}
step12_save_info_and_backup() {
    say
    ui_heading "12. 保存端口和配置备份位置"

    local backup port server_ip
    backup="$(backup_ssh)"
    port="$(get_primary_ssh_port)"
    server_ip="$(get_server_ip)"
    SSH_PORT="$port"
    LAST_BACKUP="$backup"
    save_state

    umask 077
    {
        echo "VPS Security Bootstrap 信息"
        echo "版本：$VERSION"
        echo "更新时间：$(date '+%F %T %Z')"
        echo "主机：$server_ip"
        echo "SSH 用户：root"
        echo "SSH 端口：$port"
        echo "连接命令：ssh -p $port root@$server_ip"
        echo "最新 SSH 配置备份：$backup"
        echo "最新安全报告：${LAST_REPORT:-尚未生成}"
        echo "最新只读审计：${LAST_AUDIT:-尚未执行}"
        echo "最新开荒前快照：${LAST_PREFLIGHT:-尚未生成}"
        echo "业务端口保护名单：$PROTECTED_PORTS_FILE"
        echo "状态文件：$STATE_FILE"
        echo "操作日志：$LOG_FILE"
        echo "报告目录：$REPORT_DIR"
        echo "备份目录：$BACKUP_ROOT"
        echo "SSH事务目录：$TXN_ROOT"
    } > "$INFO_FILE"

    say "✅ 已保存：$INFO_FILE"
    say "✅ 最新 SSH 配置备份：$backup"
    say
    cat "$INFO_FILE" >&4
}

ensure_firewall_manager_ready() {
    local b
    b="$(detect_firewall_backend)"
    case "$b" in
        conflict) say '❌ UFW 与 firewalld 同时启用，拒绝自动端口修改。'; return 1 ;;
        ufw|firewalld) return 0 ;;
        ufw-inactive)
            say 'UFW 已安装但未启用。'
            if confirm_y '现在安全启用 UFW，并先保护当前 SSH/业务端口？'; then
                step7_configure_ufw
            else
                return 1
            fi
            ;;
        nftables|iptables)
            say "⚠️ 检测到自定义 $b。为避免破坏规则，端口管理只提供查看，不自动增删。"
            return 2
            ;;
        none)
            say '未检测到主机防火墙。'
            if confirm_y '是否安装并启用 UFW？'; then
                step7_configure_ufw
            else
                return 1
            fi
            ;;
    esac
}
ensure_ufw_ready_for_port_manager() { ensure_firewall_manager_ready; }

normalize_decimal_port() {
    local x="$1"
    [[ "$x" =~ ^[0-9]+$ ]] || return 1
    while [[ ${#x} -gt 1 && "$x" == 0* ]]; do x="${x#0}"; done
    [[ ${#x} -le 5 ]] || return 1
    (( 10#$x >= 1 && 10#$x <= 65535 )) || return 1
    printf '%d' "$((10#$x))"
}

normalize_port_spec() {
    local x="$1"
    x="${x// /}"
    if [[ "$x" =~ ^[0-9]+$ ]]; then
        normalize_decimal_port "$x" || return 1
        return 0
    fi
    if [[ "$x" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
        a="$(normalize_decimal_port "$a")" || return 1
        b="$(normalize_decimal_port "$b")" || return 1
        (( a <= b )) || return 1
        printf '%s:%s\n' "$a" "$b"
        return 0
    fi
    return 1
}

port_spec_contains() {
    local spec="$1" port="$2"
    if [[ "$spec" =~ ^[0-9]+$ ]]; then
        [[ "$spec" == "$port" ]]
    elif [[ "$spec" =~ ^([0-9]+):([0-9]+)$ ]]; then
        (( port >= BASH_REMATCH[1] && port <= BASH_REMATCH[2] ))
    else
        return 1
    fi
}

protected_port_matches() {
    local spec="$1" proto="$2" p pr class procs binds
    [[ -f "$PROTECTED_PORTS_FILE" ]] || return 1
    while IFS=$'\t' read -r pr p class procs binds; do
        [[ "$pr" == "$proto" ]] || continue
        port_spec_contains "$spec" "$p" && return 0
    done < "$PROTECTED_PORTS_FILE"
    return 1
}

apply_port_rule() {
    local action="$1" raw="$2" proto="$3"
    local item spec p current_ports backend zone fw_spec rc
    raw="${raw//,/ }"
    current_ports="$(get_sshd_ports)"
    backend="$(detect_firewall_backend)"
    zone="$(firewalld_zone 2>/dev/null || true)"

    for item in $raw; do
        if ! spec="$(normalize_port_spec "$item")"; then
            say "❌ 无效端口：$item（支持 443、20000-20100，多端口用逗号分隔）"
            continue
        fi

        if [[ "$action" == "close" ]]; then
            while read -r p; do
                [[ -n "$p" ]] || continue
                if port_spec_contains "$spec" "$p"; then
                    say "❌ 为防止锁机，拒绝关闭当前 SSH 端口 $p。请先修改 SSH 端口。"
                    spec=""
                    break
                fi
            done <<< "$current_ports"
            [[ -n "$spec" ]] || continue
            if protected_port_matches "$spec" "$proto"; then
                say "⚠️ $item/$proto 位于业务保护名单中。"
                confirm_y "仍然继续关闭这个业务端口？" || { say "已跳过。"; continue; }
            fi
        fi

        case "$backend" in
            ufw|ufw-inactive)
                case "$proto" in
                    tcp|udp)
                        if [[ "$action" == "allow" ]]; then
                            rc=0; ufw_safe_allow "$spec" "$proto" "Manual allow - VPS Security" "1" || rc=$?
                            (( rc == 0 )) || { say "已保留 DENY/取消：$spec/$proto"; continue; }
                        else
                            ufw delete allow "$spec/$proto" >/dev/null 2>&1 || true
                            ufw deny "$spec/$proto" >/dev/null || return 1
                            say "✅ 已添加入站 DENY：$spec/$proto；更早的范围/来源 ALLOW 仍需人工复核。"
                        fi
                        ;;
                    both)
                        apply_port_rule "$action" "$item" tcp
                        apply_port_rule "$action" "$item" udp
                        ;;
                esac
                ;;
            firewalld)
                fw_spec="${spec/:/-}"
                case "$proto" in
                    tcp|udp)
                        if [[ "$action" == "allow" ]]; then
                            firewalld_allow_safe "$fw_spec" "$proto" "Manual allow - VPS Security" || return 1
                        else
                            firewall-cmd --zone="$zone" --remove-port="$fw_spec/$proto" >/dev/null 2>&1 || true
                            firewall-cmd --permanent --zone="$zone" --remove-port="$fw_spec/$proto" >/dev/null 2>&1 || true
                            say "✅ 已移除 firewalld 显式端口放行：$fw_spec/$proto；service/rich/policy 仍可能放行。"
                            if firewalld_rich_conflict "$fw_spec" "$proto"; then :; fi
                        fi
                        ;;
                    both)
                        apply_port_rule "$action" "$item" tcp
                        apply_port_rule "$action" "$item" udp
                        ;;
                esac
                ;;
            *)
                say "❌ 当前防火墙后端 $backend 不支持自动端口修改。"
                return 1
                ;;
        esac
    done

    case "$backend" in
        ufw|ufw-inactive) ufw reload >/dev/null 2>&1 || true ;;
        firewalld) : ;; # runtime + permanent rules were updated individually
    esac
}

step13_port_firewall_manager() {
    local ready=0 b c ports psel proto
    ensure_firewall_manager_ready || ready=$?
    b="$(detect_firewall_backend)"
    if (( ready == 2 )) || [[ "$b" == "nftables" || "$b" == "iptables" ]]; then
        say
        ui_heading "自定义 $b（只读）"
        if [[ "$b" == 'nftables' ]]; then
            nft list ruleset >&4 2>/dev/null || true
        else
            iptables -S >&4 2>/dev/null || true
            command -v ip6tables >/dev/null 2>&1 && ip6tables -S >&4 2>/dev/null || true
        fi
        pause
        return 0
    elif (( ready != 0 )); then
        return 1
    fi

    while true; do
        b="$(detect_firewall_backend)"
        say
        ui_heading "防火墙端口管理（当前：$b）"
        ui_item 1 "放行端口"
        ui_item 2 "关闭入站端口（不会停止对应服务）"
        ui_item 3 "查看当前规则"
        ui_item 0 "返回"
        say
        choose_num c "请选择：" "1 2 3 0" "0"
        case "$c" in
            1|2)
                say "支持：443 或 80,443,8080 或 20000-20100"
                ask ports "请输入端口："
                say "协议：1=TCP  2=UDP  3=TCP+UDP"
                choose_num psel "请选择协议 [默认1]：" "1 2 3" "1"
                case "$psel" in 2) proto="udp";; 3) proto="both";; *) proto="tcp";; esac
                [[ "$c" == "1" ]] && apply_port_rule allow "$ports" "$proto" || apply_port_rule close "$ports" "$proto"
                ;;
            3)
                case "$b" in
                    ufw|ufw-inactive) ufw status numbered >&4 ;;
                    firewalld) firewall-cmd --list-all-zones >&4 ;;
                    nftables) nft list ruleset >&4 ;;
                    iptables) iptables -S >&4; command -v ip6tables >/dev/null 2>&1 && ip6tables -S >&4 2>/dev/null || true ;;
                    *) say "未配置主机防火墙。" ;;
                esac
                ;;
            0) return 0 ;;
        esac
    done
}

# ------------------------------
# 只读安全审计
# ------------------------------
intrusion_note() {
    local level="$1"
    shift
    case "$level" in
        WARN) INTRUSION_WARN=$((INTRUSION_WARN+1)) ;;
        UNAVAILABLE) INTRUSION_UNAVAILABLE=$((INTRUSION_UNAVAILABLE+1)) ;;
    esac
    printf '[%s] %s\n' "$level" "$*"
}

intrusion_section() {
    printf '\n---------- %s. %s ----------\n' "$1" "$2"
}

intrusion_run() {
    local label="$1" lines="$2" remaining bytes rc
    shift 2
    INTRUSION_LAST_RC=0
    printf '\n--- %s ---\n' "$label"
    : > "$INTRUSION_WORK/output" || { INTRUSION_FATAL=1; INTRUSION_LAST_RC=1; intrusion_note UNAVAILABLE "无法创建临时采集文件。"; return 0; }
    if ! command -v "$1" >/dev/null 2>&1; then
        INTRUSION_LAST_RC=127
        intrusion_note UNAVAILABLE "未安装/不支持 $1，此项未检查。"
        return 0
    fi
    remaining=$((INTRUSION_DEADLINE-SECONDS))
    if (( remaining <= 0 )); then
        INTRUSION_LAST_RC=124
        intrusion_note UNAVAILABLE "总采集时间预算已用尽，此项未检查。"
        return 0
    fi
    (( remaining <= 20 )) || remaining=20
    # Bound both runtime and bytes. Only the audit's own child command is timed out.
    timeout -k 2s "${remaining}s" "$@" 2>&1 | head -c 262144 > "$INTRUSION_WORK/output"
    local -a results=("${PIPESTATUS[@]}")
    rc="${results[0]}"
    if (( results[1] != 0 )); then
        INTRUSION_FATAL=1; INTRUSION_LAST_RC=1
        intrusion_note UNAVAILABLE "临时采集文件写入失败。"
        return 0
    fi
    INTRUSION_LAST_RC="$rc"
    sed -n "1,${lines}p" "$INTRUSION_WORK/output"
    bytes="$(wc -c < "$INTRUSION_WORK/output")"
    if (( bytes >= 262144 )); then
        intrusion_note UNAVAILABLE "输出达到 256 KiB 上限，内容不完整。"
    fi
    if (( rc == 1 )) && [[ "$1" == grep ]]; then
        printf '[INFO] 此模式未匹配；不表示系统无入侵。\n'
    elif (( rc == 1 )) && [[ "$1" == crontab ]] && grep -q '^no crontab for ' "$INTRUSION_WORK/output"; then
        printf '[INFO] 此账户没有 crontab。\n'
    elif (( rc != 0 && rc != 141 )); then
        intrusion_note UNAVAILABLE "命令失败/超时（返回码 $rc），不得当作未发现异常。"
    fi
    if (( $(wc -l < "$INTRUSION_WORK/output") > lines )); then
        printf '[INFO] 仅显示前 %s 行。\n' "$lines"
    fi
}

intrusion_file() {
    local file="$1" lines="${2:-80}"
    if [[ -L "$file" ]]; then
        intrusion_note UNAVAILABLE "符号链接未读取内容：$file"
    elif [[ -f "$file" && -r "$file" ]]; then
        intrusion_run "文件：$file" "$lines" head -c 262144 -- "$file"
    else
        printf '[INFO] 文件不存在/不可读取：%s\n' "$file"
    fi
}

intrusion_directory_files() {
    local dir="$1" file count=0
    for file in "$dir"/*; do
        [[ -f "$file" || -L "$file" ]] || continue
        count=$((count+1))
        if (( count > 50 )); then
            intrusion_note UNAVAILABLE "$dir 超过 50 个文件，剩余未检查。"
            break
        fi
        intrusion_file "$file" 60
    done
}

intrusion_process_matches() {
    local snapshot="$1" mode="$2" pattern matches
    if [[ "$mode" == names ]]; then
        pattern='(^|[^[:alnum:]_])(xmrig|minerd|cpuminer|cryptonight|kinsing|kdevtmpfsi|watchbog|perfcc|kerberods|hiddenwasp|masscan|zmap|pnscan)([^[:alnum:]_]|$)'
    else
        pattern='(/dev/tcp|bash[[:space:]]+-i|sh[[:space:]]+-i|nc .* -e|netcat .* -e|socat .*exec|base64[[:space:]]+-d|curl .*[|].*sh|wget .*[|].*sh|python.*socket|perl.*socket)'
    fi
    matches="$(awk -v pattern="$pattern" 'tolower($0) ~ pattern' "$snapshot")"
    if [[ -n "$matches" ]]; then
        intrusion_note WARN "以下仅为需人工确认的进程特征，合法工具也可能匹配："
        printf '%s\n' "$matches"
    else
        printf '[INFO] 已采集的进程快照中未匹配此模式；名称可伪装。\n'
    fi
}

intrusion_proc_scan() {
    local root="$1" proc pid exe count=0 unreadable=0 suspicious=0
    for proc in "$root"/[0-9]*; do
        [[ -d "$proc" ]] || continue
        count=$((count+1))
        if (( count > 5000 || SECONDS >= INTRUSION_DEADLINE )); then
            intrusion_note UNAVAILABLE "进程遍历达到数量/时间上限，剩余未检查。"
            break
        fi
        pid="${proc##*/}"
        exe="$(readlink "$proc/exe" 2>/dev/null || true)"
        [[ -n "$exe" ]] || { unreadable=$((unreadable+1)); continue; }
        case "$exe" in
            /tmp/*|/var/tmp/*|/dev/shm/*|*' (deleted)')
                suspicious=$((suspicious+1))
                if (( suspicious > 100 )); then
                    (( suspicious != 101 )) || intrusion_note UNAVAILABLE "可疑进程仅显示前 100 项。"
                    continue
                fi
                intrusion_note WARN "PID=$pid EXE=$exe（临时路径或已删除；更新软件也可能造成 deleted）"
                printf 'CMD: '
                { head -c 4096 -- "$proc/cmdline" | tr '\0' ' '; } 2>/dev/null || true
                printf '\n'
                ;;
        esac
    done
    printf '[INFO] 遍历 %s 项；待复核 %s 项；无法读取 exe %s 项（内核线程/权限/退出竞争均可能）。\n' "$count" "$suspicious" "$unreadable"
}

intrusion_accounts() {
    local passwd_file="$1" uid0
    if [[ ! -r "$passwd_file" ]]; then
        intrusion_note UNAVAILABLE "无法读取账户文件。"
        return 0
    fi
    printf '%s\n' '--- UID=0 账户 ---'
    awk -F: '$3==0 {print $1 ":" $3 ":" $6 ":" $7}' "$passwd_file"
    uid0="$(awk -F: '$3==0 && $1!="root" {print $1}' "$passwd_file")"
    [[ -z "$uid0" ]] || intrusion_note WARN "发现非 root 名称的 UID=0 账户：$uid0；需人工确认。"
    printf '%s\n' '--- 可登录 Shell 账户 ---'
    awk -F: '$7 !~ /(nologin|false)$/ {printf "%s UID=%s HOME=%s SHELL=%s\n",$1,$3,$6,$7}' "$passwd_file"
}

intrusion_collect() {
    INTRUSION_WARN=0; INTRUSION_UNAVAILABLE=0; INTRUSION_FATAL=0
    INTRUSION_DEADLINE=$((SECONDS+180))
    local file dir user home cid count=0 container_count=0
    local -a ids=()
    printf 'VPS Security Bootstrap v%s - 入侵痕迹排查\n时间：%s\n' "$VERSION" "$(date '+%F %T %Z')"
    printf '只读采集：不执行被检查文件、不删除文件、不停止服务、不修改系统配置、不安装软件。\n'
    printf '每命令最多 20 秒/256 KiB，总预算约 180 秒；各项另有行数限制。\n'
    printf '报告含账户、IP、命令行和配置，可能包含凭据；分享前请脱敏。\n'
    printf '未匹配不代表无入侵；合法更新/管理员操作也会触发待复核项。\n'

    intrusion_section 1 "系统基本信息"
    intrusion_run 内核 10 uname -a
    intrusion_run 系统版本 30 cat /etc/os-release
    intrusion_run 运行时间 5 uptime
    intrusion_run 内存 10 free -h
    intrusion_run 文件系统 40 df -hT
    intrusion_section 2 "资源占用最高的进程"
    intrusion_run "CPU TOP 30" 31 ps axww -o pid,ppid,user,%cpu,%mem,etime,lstart,args --sort=-%cpu
    intrusion_run "内存 TOP 30" 31 ps axww -o pid,ppid,user,%cpu,%mem,etime,lstart,args --sort=-%mem
    intrusion_run "进程快照（以下特征检查的依据）" 150 ps axww -o pid,ppid,user,%cpu,%mem,args
    cp "$INTRUSION_WORK/output" "$INTRUSION_WORK/processes" || return 1
    local process_rc="$INTRUSION_LAST_RC"
    intrusion_section 3 "矿工/扫描器等进程关键词（人工复核）"
    if (( process_rc == 0 )); then intrusion_process_matches "$INTRUSION_WORK/processes" names
    else intrusion_note UNAVAILABLE "进程快照采集失败，此项未检查。"; fi
    intrusion_section 4 "临时目录运行的可执行文件"
    intrusion_section 5 "已删除但仍运行的可执行文件（合并遍历 /proc）"
    intrusion_proc_scan /proc
    intrusion_section 6 "当前监听端口"
    intrusion_run 监听端口 200 ss -lntup
    intrusion_section 7 "当前网络连接"
    intrusion_run "TCP/UDP" 200 ss -tunap
    intrusion_run "ESTABLISHED TCP" 100 ss -tnp state established
    intrusion_section 8 "SSH 实际配置"
    intrusion_run "sshd -T（配置路径与本工具一致）" 150 "$SSHD_BIN" -T -f "$SSHD_CONFIG"
    cp "$INTRUSION_WORK/output" "$INTRUSION_WORK/sshd" || return 1
    intrusion_section 9 "最近 30 天 SSH 成功登录（日志最多 20000 条）"
    intrusion_run "ssh/sshd 服务日志（新到旧）" 5 journalctl -u ssh.service -u sshd.service --since "30 days ago" -n 20000 --reverse --no-pager -o short-iso
    cp "$INTRUSION_WORK/output" "$INTRUSION_WORK/ssh-log" || return 1
    local journal_rc="$INTRUSION_LAST_RC"
    if (( journal_rc == 0 )); then
        grep -E 'Accepted (password|publickey)' "$INTRUSION_WORK/ssh-log" | head -100 || true
        printf '\n--- 成功登录账号/IP汇总（仅基于已采集日志）---\n'
        sed -nE 's/.*Accepted [^ ]+ for ([^ ]+) from ([0-9a-fA-F:.]+) port.*/\1 \2/p' "$INTRUSION_WORK/ssh-log" | sort | uniq -c | sort -nr | head -50
        printf '[INFO] 日志为空、已轮转或不在这些 unit 中均可能造成遗漏。\n'
    fi
    intrusion_section 10 "SSH 失败登录（与第 9 项同一日志快照）"
    if (( journal_rc == 0 )); then
        grep -E 'Failed password|Invalid user|authentication failure' "$INTRUSION_WORK/ssh-log" | head -100 || true
        printf '\n--- 来源 IP 汇总 ---\n'
        sed -nE 's/.* (Failed password|Invalid user).* from ([0-9a-fA-F:.]+) port.*/\2/p' "$INTRUSION_WORK/ssh-log" | sort | uniq -c | sort -nr | head -50
    else intrusion_note UNAVAILABLE "SSH 日志不可用，此项未检查。"; fi
    intrusion_section 11 "登录历史"
    intrusion_run 最近登录 100 last -a -n 100
    intrusion_run 失败登录 100 lastb -a -n 100
    intrusion_section 12 "系统账户"
    intrusion_run "账户快照（最多 256 KiB）" 5 head -c 262144 -- /etc/passwd
    cp "$INTRUSION_WORK/output" "$INTRUSION_WORK/passwd" || return 1
    intrusion_accounts "$INTRUSION_WORK/passwd"
    intrusion_section 13 "authorized_keys 元数据及指纹（不显示公钥内容）"
    while IFS=: read -r user _ _ _ _ home _; do
        [[ "$home" == /* ]] || continue
        file="$home/.ssh/authorized_keys"
        [[ -f "$file" && ! -L "$file" ]] || continue
        count=$((count+1)); (( count <= 100 )) || { intrusion_note UNAVAILABLE "密钥文件超过 100 项，剩余未检查。"; break; }
        intrusion_run "权限：$file" 12 stat -- "$file"
        intrusion_run "指纹：$file" 40 ssh-keygen -lf "$file"
    done < "$INTRUSION_WORK/passwd"
    intrusion_section 14 "Sudoers（敏感配置）"
    intrusion_file /etc/sudoers 120
    intrusion_directory_files /etc/sudoers.d
    intrusion_section 15 "用户 Crontab"
    count=0
    while IFS=: read -r user _; do
        count=$((count+1)); (( count <= 100 )) || { intrusion_note UNAVAILABLE "账户超过 100 项，剩余 crontab 未检查。"; break; }
        intrusion_run "用户：$user" 60 crontab -u "$user" -l
    done < "$INTRUSION_WORK/passwd"
    intrusion_section 16 "系统 Cron"
    intrusion_file /etc/crontab 100
    for dir in /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly; do
        intrusion_run "$dir 文件清单" 80 find "$dir" -maxdepth 1 -type f -printf '%TY-%Tm-%Td %TH:%TM %u %m %p\n'
    done
    intrusion_directory_files /etc/cron.d
    intrusion_section 17 "Systemd 定时任务"
    intrusion_run 定时任务 150 systemctl list-timers --all --no-pager
    intrusion_section 18 "已启用的 Systemd 服务"
    intrusion_run 启用服务 200 systemctl list-unit-files --type=service --state=enabled --no-pager
    intrusion_section 19 "本地 Systemd 单元元数据"
    intrusion_run 单元文件 150 find /etc/systemd/system -xdev -maxdepth 4 -type f -printf '%TY-%Tm-%Td %TH:%TM %p\n'
    intrusion_section 20 "启动项/Shell 持久化特征（不执行内容）"
    for file in /etc/rc.local /etc/profile /etc/bash.bashrc /etc/bashrc /root/.bashrc /root/.profile /root/.bash_profile; do
        [[ -f "$file" && ! -L "$file" ]] || continue
        intrusion_run "$file 特征" 80 grep -nEi 'curl|wget|/tmp/|/var/tmp/|/dev/shm/|base64|nohup|nc |netcat|socat|python.*http|perl.*socket|bash.*tcp' -- "$file"
    done
    intrusion_run profile.d文件 100 find /etc/profile.d -maxdepth 1 -type f -printf '%TY-%Tm-%Td %TH:%TM %p\n'
    intrusion_directory_files /etc/profile.d
    intrusion_section 21 "ld.so.preload（合法软件也可能使用）"
    if [[ -s /etc/ld.so.preload ]]; then
        intrusion_note WARN "ld.so.preload 非空，需确认库来源，不能直接判定 rootkit。"
        intrusion_file /etc/ld.so.preload 80
    else printf '[INFO] ld.so.preload 不存在或为空；不能排除 rootkit。\n'; fi
    intrusion_section 22 "临时目录近 30 天可执行/脚本文件（最多 4 层）"
    for dir in /tmp /var/tmp /dev/shm; do
        intrusion_run "$dir" 100 find "$dir" -xdev -maxdepth 4 -type f -mtime -30 '(' -perm /111 -o -name '*.sh' -o -name '*.py' -o -name '*.pl' ')' -printf '%TY-%Tm-%Td %TH:%TM %u %m %s %p\n'
    done
    intrusion_section 23 "临时目录 SUID/SGID（最多 4 层）"
    intrusion_run SUID/SGID 100 find /tmp /var/tmp /dev/shm -xdev -maxdepth 4 -type f -perm /6000 -ls
    [[ ! -s "$INTRUSION_WORK/output" || "$INTRUSION_LAST_RC" != 0 ]] || intrusion_note WARN "临时目录存在 SUID/SGID 文件，需人工复核。"
    intrusion_section 24 "usr/local 可执行目录近 30 天文件"
    intrusion_run 本地文件 100 find /usr/local/bin /usr/local/sbin -maxdepth 1 -type f -mtime -30 -printf '%TY-%Tm-%Td %TH:%TM %u %m %s %p\n'
    intrusion_section 25 "Docker 容器、权限与挂载（不读取 Env）"
    intrusion_run 容器列表 100 docker ps -a --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
    if (( INTRUSION_LAST_RC == 0 )); then
        while read -r cid _; do
            [[ "$cid" =~ ^[0-9a-f]{12,64}$ ]] || continue
            ids+=("$cid"); container_count=$((container_count+1)); (( container_count < 100 )) || break
        done < "$INTRUSION_WORK/output"
        (( container_count < 100 )) || intrusion_note UNAVAILABLE "容器检查达到 100 个上限，未保证覆盖全部容器。"
        if (( container_count > 0 )); then
            intrusion_run "容器权限（最多 100 个）" 100 docker inspect --type container -f 'Name={{.Name}} Privileged={{.HostConfig.Privileged}} Network={{.HostConfig.NetworkMode}} Pid={{.HostConfig.PidMode}} Restart={{.HostConfig.RestartPolicy.Name}}' "${ids[@]}"
            intrusion_run "容器挂载（最多 100 个）" 200 docker inspect --type container -f 'Name={{.Name}} {{range .Mounts}}{{println .Source " -> " .Destination}}{{end}}' "${ids[@]}"
        fi
    fi
    intrusion_section 26 "主机防火墙（只读）"
    intrusion_run UFW 150 ufw status verbose
    intrusion_run firewalld 150 firewall-cmd --list-all-zones
    intrusion_run nftables 300 nft list ruleset
    intrusion_run iptables 200 iptables -S
    intrusion_section 27 "内核模块"
    intrusion_run 模块列表 150 lsmod
    intrusion_section 28 "关键目录近 30 天修改（最多 4 层）"
    intrusion_run 修改清单 200 find /etc/cron.d /etc/profile.d /etc/systemd/system /root/.ssh -xdev -maxdepth 4 -type f -mtime -30 -printf '%TY-%Tm-%Td %TH:%TM %u %m %p\n'
    intrusion_section 29 "可疑命令行特征（人工复核）"
    if (( process_rc == 0 )); then intrusion_process_matches "$INTRUSION_WORK/processes" commands
    else intrusion_note UNAVAILABLE "进程快照不可用。"; fi
    intrusion_section 30 "SSH/业务端口动态复核（无硬编码面板端口）"
    awk '$1=="port" {print "SSH 配置端口：" $2}' "$INTRUSION_WORK/sshd"
    intrusion_run 所有当前监听 150 ss -lntup
    printf '\n采集结束：%s\n待人工复核：%s；未完整采集：%s\n' "$(date '+%F %T %Z')" "$INTRUSION_WARN" "$INTRUSION_UNAVAILABLE"
    printf '本报告不提供“未被入侵”保证。不要仅凭关键词、deleted 或 preload 删除文件/进程。\n'
    (( INTRUSION_FATAL == 0 ))
}

intrusion_audit() {
    (
        ui_heading "入侵痕迹排查（只读）"
        say "检查进程、登录、账户、持久化、文件和容器等 30 组信息，采集时间预算 3 分钟。"
        say "报告可能包含凭据和业务信息，仅保存在 root 可读目录；分享前请脱敏。"
        say "此项不会清理或修复系统；待复核不等于已入侵，未匹配不等于安全。"
        confirm_y "开始只读采集？" || return 0
        local required INTRUSION_WORK report
        for required in timeout head tee tr mktemp; do
            command -v "$required" >/dev/null 2>&1 || { say "❌ 缺少 $required，未安装任何软件，已取消。"; return 1; }
        done
        umask 077
        INTRUSION_WORK="$(mktemp -d "$BASE_DIR/.intrusion.XXXXXX")" || return 1
        trap 'rm -rf -- "$INTRUSION_WORK"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        report="$(mktemp "$REPORT_DIR/intrusion-$(date +%Y%m%d-%H%M%S)-XXXXXX.txt")" || return 1
        chmod 600 "$report" || return 1
        if ! intrusion_collect 2>&1 | LC_ALL=C tr -d '\000-\010\013-\037\177' | tee "$report" >&4; then
            say "❌ 采集或报告写入失败，报告可能不完整：$report"
            return 1
        fi
        log "入侵痕迹只读采集完成：$report"
        say "✅ 采集报告：$report"
        say "请结合报告中的 WARN / UNAVAILABLE 人工核实，勿直接删除未知文件。"
    )
}

AUDIT_PASS=0; AUDIT_WARN=0; AUDIT_FAIL=0; AUDIT_INFO=0; AUDIT_OUT=""
audit_emit() {
    local level="$1" item="$2" detail="$3"
    case "$level" in
        PASS) ((AUDIT_PASS+=1)) ;;
        WARN) ((AUDIT_WARN+=1)) ;;
        FAIL) ((AUDIT_FAIL+=1)) ;;
        INFO) ((AUDIT_INFO+=1)) ;;
    esac
    printf '[%-4s] %-24s %s\n' "$level" "$item" "$detail" | tee -a "$AUDIT_OUT" >&4
}

audit_readonly() {
    local port eff keys backend rootuse syncv dockn ipv6fw sshsock
    AUDIT_PASS=0; AUDIT_WARN=0; AUDIT_FAIL=0; AUDIT_INFO=0
    AUDIT_OUT="$REPORT_DIR/audit-$(date +%Y%m%d-%H%M%S).txt"
    : > "$AUDIT_OUT"; chmod 600 "$AUDIT_OUT"

    {
        echo "VPS Security Bootstrap v$VERSION - Security Audit"
        echo "时间：$(date '+%F %T %Z')"
        echo "系统：$(get_os_pretty)"
        echo "主机：$(hostname)"
        echo "IPv4：$(get_ipv4)"
        echo "IPv6：$(get_global_ipv6)"
        echo
    } | tee -a "$AUDIT_OUT" >&4

    audit_emit PASS "系统支持" "$OS_PRETTY_NAME；$PKG_MANAGER"
    port="$(get_primary_ssh_port)"
    if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1024 )); then
        audit_emit PASS "SSH 端口" "$port（非低位）"
    else
        audit_emit WARN "SSH 端口" "$port（仍为低位/默认端口不代表漏洞，但更容易被扫描）"
    fi

    eff="$($SSHD_BIN -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null || true)"
    keys="$(grep -c '^ssh-ed25519 ' /root/.ssh/authorized_keys 2>/dev/null || true)"; keys="${keys:-0}"
    (( keys > 0 )) && audit_emit PASS "ED25519 公钥" "$keys 把" || audit_emit WARN "ED25519 公钥" "未检测到"
    grep -q '^passwordauthentication no$' <<<"$eff" && audit_emit PASS "SSH 密码认证" "已关闭" || audit_emit WARN "SSH 密码认证" "仍开启"
    if grep -q '^permitrootlogin prohibit-password$' <<<"$eff" || grep -q '^permitrootlogin no$' <<<"$eff"; then
        audit_emit PASS "root SSH 策略" "$(grep '^permitrootlogin ' <<<"$eff" | head -n1)"
    else
        audit_emit WARN "root SSH 策略" "$(grep '^permitrootlogin ' <<<"$eff" | head -n1)"
    fi

    sshsock="$(_unit_active_state ssh.socket)/$(_unit_enabled_state ssh.socket)"
    audit_emit INFO "ssh.socket" "$sshsock"

    backend="$(detect_firewall_backend)"
    case "$backend" in
        ufw) audit_emit PASS "主机防火墙" "UFW 已启用" ;;
        firewalld) audit_emit PASS "主机防火墙" "firewalld 运行中" ;;
        ufw-inactive) audit_emit WARN "主机防火墙" "UFW 已安装但未启用" ;;
        nftables) audit_emit INFO "主机防火墙" "自定义 nftables，需人工审计" ;;
        iptables) audit_emit INFO "主机防火墙" "自定义 iptables，需人工审计" ;;
        conflict) audit_emit FAIL "主机防火墙" "UFW 与 firewalld 同时启用，存在策略冲突风险" ;;
        none) audit_emit WARN "主机防火墙" "未检测到 UFW/firewalld" ;;
    esac

    systemctl is-active --quiet fail2ban 2>/dev/null && audit_emit PASS "Fail2ban" "运行中" || audit_emit WARN "Fail2ban" "未运行"
    if [[ "$(status_auto_updates)" == 已开启* ]]; then
        audit_emit PASS "自动安全更新" "$(status_auto_updates)"
    else
        audit_emit WARN "自动安全更新" "未开启/未配置"
    fi

    if has_global_ipv6; then
        ipv6fw="$(status_ipv6_firewall)"
        [[ "$ipv6fw" == *"⚠"* ]] && audit_emit WARN "IPv6 防火墙" "$ipv6fw" || audit_emit PASS "IPv6 防火墙" "$ipv6fw"
    else
        audit_emit INFO "IPv6" "无公网 IPv6"
    fi

    dockn="$(docker_public_mapping_count)"
    if command -v docker >/dev/null 2>&1; then
        if (( dockn > 0 )); then
            audit_emit WARN "Docker 公网映射" "$dockn 项；请逐项确认是否需要公网开放"
        else
            audit_emit PASS "Docker 公网映射" "未发现公网映射"
        fi
        audit_emit INFO "DOCKER-USER" "$(status_docker_firewall)"
    else
        audit_emit INFO "Docker" "未安装"
    fi

    audit_emit INFO "公网监听" "$(status_public_listeners)"
    rootuse="$(df -P / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}' || true)"
    if [[ "$rootuse" =~ ^[0-9]+$ ]] && (( rootuse >= 90 )); then
        audit_emit WARN "根分区使用率" "${rootuse}%"
    else
        audit_emit PASS "根分区使用率" "${rootuse:-未知}%"
    fi

    syncv="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
    [[ "$syncv" == "yes" ]] && audit_emit PASS "时间同步" "NTP 已同步" || audit_emit WARN "时间同步" "NTP 未确认同步"
    reboot_required && audit_emit INFO "系统重启" "需要重启" || audit_emit INFO "系统重启" "当前无需重启"

    {
        echo
        echo "统计：PASS=$AUDIT_PASS WARN=$AUDIT_WARN FAIL=$AUDIT_FAIL INFO=$AUDIT_INFO"
        echo "说明：WARN 不等于漏洞；需要结合业务用途、云安全组和网络架构判断。"
    } | tee -a "$AUDIT_OUT" >&4

    LAST_AUDIT="$AUDIT_OUT"
    save_state
    log "只读安全审计完成：$AUDIT_OUT；PASS=$AUDIT_PASS WARN=$AUDIT_WARN FAIL=$AUDIT_FAIL INFO=$AUDIT_INFO"
    say
    say "✅ 审计报告：$AUDIT_OUT"
}

# ------------------------------
# Docker 安全检查（默认只读）
# ------------------------------
print_docker_mappings() {
    if ! command -v docker >/dev/null 2>&1; then say "Docker 未安装。"; return 0; fi
    local cid name hip hp cp proto scope found=0
    printf '%-24s %-18s %-10s %-10s %-8s\n' "容器" "宿主绑定" "容器端口" "协议" "范围" >&4
    printf '%-24s %-18s %-10s %-10s %-8s\n' "------------------------" "------------------" "----------" "----------" "--------" >&4
    while read -r cid; do
        [[ -n "$cid" ]] || continue
        name="$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's#^/##' || true)"; [[ -n "$name" ]] || name="$cid"
        while IFS='|' read -r hip hp cp; do
            [[ -n "$hp" ]] || continue
            proto="${cp##*/}"; cp="${cp%%/*}"
            [[ -n "$hip" ]] || hip="0.0.0.0"
            if is_loopback_bind "$hip"; then scope="本机"; else scope="公网/非回环"; fi
            printf '%-24s %-18s %-10s %-10s %-8s\n' "$name" "$hip:$hp" "$cp" "$proto" "$scope" >&4
            found=1
        done < <(docker inspect --format '{{range $p,$v := .NetworkSettings.Ports}}{{if $v}}{{range $v}}{{printf "%s|%s|%s\\n" .HostIp .HostPort $p}}{{end}}{{end}}{{end}}' "$cid" 2>/dev/null || true)
    done < <(docker ps -q 2>/dev/null || true)
    (( found == 1 )) || say "未发现 Docker 发布端口。"
}

docker_firewall_backup() {
    local dir
    dir="$BACKUP_ROOT/docker-firewall-$(date +%Y%m%d-%H%M%S)-$RANDOM"
    mkdir -p "$dir"; chmod 700 "$dir"
    command -v iptables-save >/dev/null 2>&1 && iptables-save > "$dir/iptables-save.txt" 2>&1 || true
    command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save > "$dir/ip6tables-save.txt" 2>&1 || true
    command -v nft >/dev/null 2>&1 && nft list ruleset > "$dir/nft-ruleset.txt" 2>&1 || true
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' > "$dir/docker-ports.txt" 2>&1 || true
    say "✅ Docker 防火墙快照：$dir"
    log "Docker 防火墙快照：$dir"
}

show_docker_user_chain() {
    if command -v iptables >/dev/null 2>&1 && iptables -S DOCKER-USER >/dev/null 2>&1; then
        iptables -S DOCKER-USER >&4
    else
        say "未检测到 iptables DOCKER-USER 链（Docker 可能使用其他后端/尚未运行）。"
    fi
}

docker_security_menu() {
    local c
    while true; do
        ui_clear
        ui_heading "Docker 安全检查（默认只读）"
        say "状态：$(status_docker)"
        say "DOCKER-USER：$(status_docker_firewall)"
        say
        ui_item 1 "查看 Docker 端口映射"
        ui_item 2 "查看 DOCKER-USER"
        ui_item 3 "备份 Docker/iptables/nftables 当前状态"
        ui_item 4 "查看 Docker 防火墙说明"
        ui_item 0 "返回"
        choose_num c "请选择：" "1 2 3 4 0" "0"
        case "$c" in
            1) print_docker_mappings; pause ;;
            2) show_docker_user_chain; pause ;;
            3) docker_firewall_backup; pause ;;
            4)
                say
                say "Docker 发布端口可能绕过普通 UFW INPUT。"
                say "本版本默认只审计，不自动写入 DOCKER-USER，避免破坏 1Panel、青龙、Komari、x-ui 等现有业务。"
                say "如需限制 Docker 公网访问，建议先备份，再按实际业务设计 DOCKER-USER 或仅绑定 127.0.0.1。"
                pause
                ;;
            0) return 0 ;;
        esac
    done
}

# ------------------------------
# 高级设置
# ------------------------------
ssh_keepalive_manager() {
    local c port locked txn
    say "当前 SSH KeepAlive：$(status_keepalive)"
    ui_item 1 "开启推荐配置（60 秒心跳，3 次失败）"
    ui_item 2 "关闭本工具管理的 KeepAlive"
    ui_item 0 "返回"
    choose_num c "请选择：" "1 2 0" "0"
    [[ "$c" != "0" ]] || return 0
    port="$(get_primary_ssh_port)"; locked=0; sshd_password_auth_disabled && locked=1
    begin_ssh_transaction "$port" "$port" >/dev/null || return 1
    txn="$SSH_TXN_DIR"
    [[ "$c" == "1" ]] && KEEPALIVE_ENABLED="1" || KEEPALIVE_ENABLED="0"
    save_state
    if ! write_sshd_managed_block "$port" "$locked" || ! "$SSHD_BIN" -t || ! systemctl restart "$SSH_SERVICE"; then
        say "❌ KeepAlive 修改失败，正在回滚。"
        rollback_ssh_transaction "$txn"
        return 1
    fi
    commit_ssh_transaction "$txn"
    say "✅ SSH KeepAlive 已更新：$(status_keepalive)"
}

ipv6_firewall_manager() {
    local b backup
    say "IPv6：$(status_ipv6)"
    say "IPv6 防火墙：$(status_ipv6_firewall)"
    has_global_ipv6 || { say "当前无公网 IPv6，无需修复。"; return 0; }
    b="$(detect_firewall_backend)"
    case "$b" in
        ufw|ufw-inactive)
            if grep -Eq '^IPV6=yes' /etc/default/ufw 2>/dev/null; then
                say "✅ UFW 已启用 IPv6 支持。"
                return 0
            fi
            say "⚠️ UFW 当前 IPV6!=yes。"
            confirm_y "是否备份配置并开启 UFW IPv6 支持？" || return 0
            backup="$BACKUP_ROOT/ufw-ipv6-$(date +%Y%m%d-%H%M%S)"
            mkdir -p "$backup"; cp -a /etc/default/ufw "$backup/ufw.default" 2>/dev/null || true
            if grep -Eq '^IPV6=' /etc/default/ufw; then sed -Ei 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw; else echo 'IPV6=yes' >> /etc/default/ufw; fi
            if is_ufw_active; then
                ufw --force disable >/dev/null || true
                ufw --force enable >/dev/null || { cp -a "$backup/ufw.default" /etc/default/ufw; ufw --force enable >/dev/null 2>&1 || true; return 1; }
            fi
            say "✅ UFW IPv6 支持已开启。备份：$backup"
            ;;
        firewalld) say "firewalld 通常同时管理 IPv4/IPv6；请使用只读审计确认 zone/rich rules。" ;;
        nftables) say "自定义 nftables：本工具不自动修改 IPv6 规则。" ;;
        iptables) say "自定义 iptables：请同时人工检查 ip6tables/nftables 的 IPv6 规则。" ;;
        none) say "⚠️ 没有主机防火墙。可先从第 7 项配置 UFW。" ;;
    esac
}

restore_ipv6_sysctl_backup() {
    local backup="$1" key value rc=0
    if [[ -f "$backup/had-config" ]]; then
        cp -a "$backup/ipv6.conf" "$IPV6_SYSCTL_FILE" || return 1
    else
        rm -f "$IPV6_SYSCTL_FILE" || return 1
    fi
    # Restore runtime values too, even when no managed file existed before.
    while IFS='=' read -r key value; do
        [[ -n "$key" ]] || continue
        sysctl -w "$key=$value" >/dev/null 2>&1 || rc=1
    done < "$backup/runtime.conf"
    return "$rc"
}

set_ipv6_enabled() {
    local enabled="$1" value backup
    backup="$BACKUP_ROOT/ipv6-$(date +%Y%m%d-%H%M%S)-$RANDOM"
    mkdir -p "$backup"
    chmod 700 "$backup"
    sysctl -a 2>/dev/null | awk -F ' = ' '
        $1 ~ /^net\.ipv6\.conf\.[^.]+\.disable_ipv6$/ {print $1 "=" $2}
    ' > "$backup/runtime.conf"
    [[ -s "$backup/runtime.conf" ]] || { say "❌ 无法备份 IPv6 内核运行状态。"; return 1; }
    if [[ -f "$IPV6_SYSCTL_FILE" ]]; then
        cp -a "$IPV6_SYSCTL_FILE" "$backup/ipv6.conf" || return 1
        printf '1\n' > "$backup/had-config"
    fi

    if [[ "$enabled" == "1" ]]; then
        if grep -Eq '(^|[[:space:]])ipv6\.disable=1([[:space:]]|$)' /proc/cmdline 2>/dev/null; then
            say "❌ 内核启动参数包含 ipv6.disable=1，sysctl 无法重新开启 IPv6。"
            say "请先人工移除启动参数并重启服务器。"
            return 1
        fi
        value=0
    else
        value=1
    fi

    cat > "$IPV6_SYSCTL_FILE" <<EOF
# Managed by VPS Security Bootstrap
net.ipv6.conf.all.disable_ipv6 = $value
net.ipv6.conf.default.disable_ipv6 = $value
net.ipv6.conf.lo.disable_ipv6 = $value
EOF
    chmod 600 "$IPV6_SYSCTL_FILE"

    if ! sysctl -p "$IPV6_SYSCTL_FILE" >/dev/null 2>&1; then
        say "❌ 应用 IPv6 sysctl 配置失败，正在恢复。"
        restore_ipv6_sysctl_backup "$backup"
        return 1
    fi
    if [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || true)" != "$value" ]]; then
        say "❌ IPv6 实际状态未达到预期，正在恢复。"
        restore_ipv6_sysctl_backup "$backup"
        return 1
    fi

    if [[ "$enabled" == "1" ]]; then
        log "IPv6 网络栈已开启；备份=$backup"
        say "✅ IPv6 网络栈已开启。"
        say "ℹ️ 公网 IPv6 地址由云厂商和网络配置决定，必要时重启网络或服务器。"
    else
        log "IPv6 网络栈已关闭；备份=$backup"
        say "✅ IPv6 网络栈已关闭，现有 IPv6 地址和连接将不可用。"
        say "ℹ️ 这不会删除云厂商分配的 IPv6，只会禁止本机使用。"
    fi
    say "配置：$IPV6_SYSCTL_FILE"
    say "备份：$backup"
}

ipv6_toggle_menu() {
    local c
    while true; do
        say
        ui_heading "IPv6 开启 / 关闭"
        say "当前状态：$(status_ipv6)"
        ui_item 1 "开启 IPv6"
        ui_item 2 "关闭 IPv6"
        ui_item 0 "返回"
        choose_num c "请选择：" "1 2 0" "0"
        case "$c" in
            1)
                confirm_y "确认开启服务器 IPv6 网络栈？" && set_ipv6_enabled 1
                pause
                ;;
            2)
                say "⚠️ 关闭 IPv6 会立即中断所有 IPv6 连接，并可能影响依赖 IPv6 的服务。"
                confirm_y "确认关闭服务器 IPv6 网络栈？" && set_ipv6_enabled 0
                pause
                ;;
            0) return 0 ;;
        esac
    done
}

show_backups() {
    say "备份目录：$BACKUP_ROOT"
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%TY-%Tm-%Td %TH:%TM  %p\n' 2>/dev/null | sort -r | head -30 >&4 || true
    say
    say "SSH 事务目录：$TXN_ROOT"
    find "$TXN_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%TY-%Tm-%Td %TH:%TM  %p\n' 2>/dev/null | sort -r | head -30 >&4 || true
}

show_logs() { tail -n 120 "$LOG_FILE" >&4 2>/dev/null || true; }

cleanup_history() {
    local days
    ask days "删除多少天以前的报告/普通备份？[默认30]："
    [[ -n "$days" ]] || days=30
    [[ "$days" =~ ^[0-9]+$ ]] || { say "❌ 请输入数字。"; return 1; }
    confirm_y "确认删除 $days 天以前的报告和普通备份？SSH transaction 不自动删除" || return 0
    find "$REPORT_DIR" -type f -mtime "+$days" -delete 2>/dev/null || true
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime "+$days" -exec rm -rf -- {} + 2>/dev/null || true
    say "✅ 清理完成。"
}

advanced_menu() {
    local c
    while true; do
        ui_clear
        ui_heading "高级设置"
        ui_item 1 "SSH KeepAlive"
        ui_item 2 "IPv6 防火墙检查 / 修复"
        ui_item 3 "Docker 防火墙高级检查"
        ui_item 4 "查看备份"
        ui_item 5 "查看操作日志"
        ui_item 6 "历史报告 / 备份清理"
        ui_item 0 "返回"
        choose_num c "请选择：" "1 2 3 4 5 6 0" "0"
        case "$c" in
            1) ssh_keepalive_manager; pause ;;
            2) ipv6_firewall_manager; pause ;;
            3) docker_security_menu ;;
            4) show_backups; pause ;;
            5) show_logs; pause ;;
            6) cleanup_history; pause ;;
            0) return 0 ;;
        esac
    done
}

choose_full_step_action() {
    local __var="$1" title="$2" choice
    say
    ui_rule
    say "下一步：$title"
    ui_item 1 "执行（默认）"
    ui_item 2 "跳过"
    ui_item 0 "停止通用流程并返回"
    choose_num choice "请选择 [默认1]：" "1 2 0" "1"
    printf -v "$__var" '%s' "$choice"
}

run_full_optional_step() {
    local title="$1" fn="$2" action
    choose_full_step_action action "$title"
    case "$action" in
        1) run_step "$title" "$fn" ;;
        2)
            if [[ "$title" == "业务端口保护预检" ]]; then
                FULL_SKIP_PREFLIGHT="1"
                say "⚠️ 后续若启用默认拒绝防火墙，未在现有规则中放行的业务端口可能无法访问。"
            fi
            log "通用流程已跳过：$title"
            say "⏭ 已跳过：$title"
            return 0
            ;;
        0) return 10 ;;
    esac
}

run_full_setup() {
    say
    say "##################################################"
    say "       通用安全开荒：新机 / 已部署业务机"
    say "##################################################"
    say "开始前先扫描监听、Docker 映射和防火墙，并建立业务端口保护名单。"
    say "已有 DENY 不会被静默覆盖；SSH 修改采用事务备份/验证/回滚。"
    say "之后按顺序执行 1-12。"
    say "确认提示：[Y/n]；直接回车或 y=是，n=否。"
    say "整个过程中不要关闭当前 SSH 窗口。"
    say
    local rc=0 action spec
    if ! confirm_y "开始通用安全开荒？"; then
        say "已取消，返回主菜单。"
        return 0
    fi
    FULL_SKIP_PREFLIGHT="0"

    for spec in \
        "业务端口保护预检|business_port_preflight" \
        "1. 更新系统|step1_update_system" \
        "2. 修改 root 密码|step2_change_root_password" \
        "3. 随机 SSH 高位端口|step3_random_ssh_port" \
        "4. 添加 ED25519 公钥|step4_add_ed25519_key"
    do
        rc=0
        run_full_optional_step "${spec%%|*}" "${spec##*|}" || rc=$?
        if (( rc == 10 )); then say "已停止通用流程。"; pause; return 0; fi
        if (( rc != 0 )); then pause; return 0; fi
    done

    choose_full_step_action action "5. 新窗口测试密钥"
    case "$action" in
        1)
            rc=0
            step5_test_key || rc=$?
            load_state
            if (( rc != 0 )); then
                say
                say "⚠️ 密钥测试未确认成功，完整流程已安全停止。"
                say "不会关闭 SSH 密码认证，也不会继续修改后续安全配置。"
                say "开荒前快照：${LAST_PREFLIGHT:-$PREFLIGHT_ROOT}"
                pause
                return 0
            fi
            ;;
        2)
            log "通用流程已跳过：5. 新窗口测试密钥"
            say "⏭ 已跳过密钥测试；关闭密码认证步骤仍会进行独立安全检查。"
            ;;
        0) say "已停止通用流程。"; pause; return 0 ;;
    esac

    for spec in \
        "6. 关闭 SSH 密码认证|step6_disable_password_auth" \
        "7. 配置主机防火墙|step7_configure_ufw" \
        "8. 安装 Fail2ban|step8_install_fail2ban" \
        "9. 开启自动安全更新|step9_enable_auto_updates" \
        "10. 扫描公网监听端口|step10_scan_public_ports" \
        "11. 输出安全检查报告|step11_security_report" \
        "12. 保存端口和配置备份|step12_save_info_and_backup"
    do
        rc=0
        run_full_optional_step "${spec%%|*}" "${spec##*|}" || rc=$?
        if (( rc == 10 )); then say "已停止通用流程。"; pause; return 0; fi
        if (( rc != 0 )); then pause; return 0; fi
    done

    say
    say "##################################################"
    say "✅ VPS Security Bootstrap v$VERSION 开荒完成"
    say "##################################################"
    say "SSH：$(get_server_ip):$(get_primary_ssh_port)"
    say "防火墙：$(status_firewall)"
    say "业务端口保护：$PROTECTED_PORTS_FILE"
    say "开荒前快照：${LAST_PREFLIGHT:-$PREFLIGHT_ROOT}"
    say "信息文件：$INFO_FILE"
    say "最新报告：${LAST_REPORT:-$REPORT_DIR}"
    reboot_required && say "⚠️ 系统更新提示需要重启，可回主菜单选择 9。"
    pause
}

single_menu() {
    local c rc
    while true; do
        ui_clear
        ui_heading "单项安全优化"
        ui_write muted "  $APP_NAME"
        ui_item 1 "更新系统"
        ui_item 2 "修改 root 密码"
        ui_item 3 "随机 SSH 高位端口"
        ui_item 4 "添加 ED25519 公钥"
        ui_item 5 "新窗口测试密钥"
        ui_item 6 "关闭 SSH 密码认证"
        ui_item 7 "安装/配置主机防火墙"
        ui_item 8 "安装 Fail2ban"
        ui_item 9 "开启自动安全更新"
        ui_item 10 "扫描公网监听端口"
        ui_item 11 "输出最终安全检查报告"
        ui_item 12 "保存端口和配置备份位置"
        ui_item 13 "入侵痕迹排查（只读）"
        ui_item 0 "返回主菜单"
        say
        choose_num c "请输入数字：" "1 2 3 4 5 6 7 8 9 10 11 12 13 0" "0"
        case "$c" in
            1) run_step "更新系统" step1_update_system || true; pause ;;
            2) run_step "修改 root 密码" step2_change_root_password || true; pause ;;
            3) run_step "SSH 高位端口" step3_random_ssh_port || true; pause ;;
            4) run_step "添加 ED25519 公钥" step4_add_ed25519_key || true; pause ;;
            5) rc=0; step5_test_key || rc=$?; load_state; pause ;;
            6) run_step "关闭 SSH 密码认证" step6_disable_password_auth || true; pause ;;
            7) run_step "配置主机防火墙" step7_configure_ufw || true; pause ;;
            8) run_step "安装 Fail2ban" step8_install_fail2ban || true; pause ;;
            9) run_step "自动安全更新" step9_enable_auto_updates || true; pause ;;
            10) run_step "公网端口扫描" step10_scan_public_ports || true; pause ;;
            11) run_step "安全检查报告" step11_security_report || true; pause ;;
            12) run_step "保存信息和备份" step12_save_info_and_backup || true; pause ;;
            13) run_step "入侵痕迹排查" intrusion_audit || true; pause ;;
            0) return 0 ;;
        esac
    done
}

reboot_server() {
    say
    ui_heading "重启服务器"
    reboot_required && say "系统状态：当前更新提示需要重启。" || say "系统状态：当前没有重启提示。"
    say "执行重启后当前 SSH 会正常断开，服务器启动完成后重新连接。"
    say
    if confirm_y "确认现在重启服务器？"; then
        log "用户从主菜单执行服务器重启"
        sync
        say "正在重启..."
        systemctl reboot || { say "❌ systemctl reboot 执行失败。"; pause; return 1; }
    else
        say "已取消重启。"
        sleep 1
    fi
}

show_header() {
    ui_heading "$APP_NAME"
    ui_pair "系统：$(get_os_pretty)" "包管理器：$PKG_MANAGER"
    ui_pair "主机：$(hostname)" "运行时间：$(get_uptime_short)"
    ui_pair "IPv4：$(get_ipv4)" "IPv6：$(status_ipv6)"
}

main_menu() {
    local c
    while true; do
        ui_clear
        show_header
        show_security_status
        say
        ui_section "操作菜单"
        ui_rule
        ui_menu_pair 1 "通用安全开荒" 2 "单项安全优化"
        ui_menu_pair 3 "业务端口保护预检 / 重新扫描" 4 "防火墙端口管理"
        ui_menu_pair 5 "只读安全检查" 6 "Docker 安全检查"
        ui_menu_pair 7 "高级设置" 8 "IPv6 开启 / 关闭"
        ui_menu_pair 9 "重启服务器" 0 "退出工具"
        ui_rule
        ui_write muted "  输入数字后回车；0 仅退出工具。"
        choose_num c "请选择：" "1 2 3 4 5 6 7 8 9 0" "0"
        case "$c" in
            1) run_full_setup ;;
            2) single_menu ;;
            3) run_step "业务端口保护预检" business_port_preflight || true; pause ;;
            4) step13_port_firewall_manager || true ;;
            5) audit_readonly; pause ;;
            6) docker_security_menu ;;
            7) advanced_menu ;;
            8) ipv6_toggle_menu ;;
            9) reboot_server || true ;;
            0)
                say "已退出安全开荒工具。"
                say "当前 SSH 连接保持开启，可继续输入其他命令。"
                return 0
                ;;
        esac
    done
}

if [[ "${CLI_AUDIT:-0}" == "1" ]]; then
    audit_readonly
    exit 0
fi

main_menu

)
