#!/usr/bin/env bash
# VPS Security Bootstrap v10.0.1
# 面向 Debian / Ubuntu：全新 VPS 开荒 + 已部署业务服务器安全加固。
# 核心原则：不锁 SSH、不误关业务端口、不自动覆盖已有 DENY、关键改动可验证/可回滚。
(
set -Euo pipefail

VERSION="10.0.1"
APP_NAME="VPS Security Bootstrap v${VERSION}"
SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
CLI_AUDIT=0

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

支持：Debian / Ubuntu（apt 系）
EOF
        exit 0
        ;;
esac

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        if [[ -r "$SCRIPT_PATH" && "$SCRIPT_PATH" != /dev/fd/* && "$SCRIPT_PATH" != /proc/*/fd/* ]]; then
            echo "检测到当前不是 root，已找到 sudo，正在自动提权重新运行..."
            exec sudo -E bash "$SCRIPT_PATH" "$@"
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
SSHD_CONFIG="/etc/ssh/sshd_config"
MANAGED_BEGIN="# BEGIN VPS-SECURITY-BOOTSTRAP"
MANAGED_END="# END VPS-SECURITY-BOOTSTRAP"
KEEPALIVE_ENABLED="0"
PREFLIGHT_DONE="0"
LAST_PREFLIGHT=""
LAST_AUDIT=""
SSH_TXN_DIR=""
SSH_TXN_OLD_PORT=""
SSH_TXN_NEW_PORT=""

mkdir -p "$BASE_DIR" "$LOG_DIR" "$REPORT_DIR" "$BACKUP_ROOT" "$TXN_ROOT" "$PREFLIGHT_ROOT"
chmod 700 "$BASE_DIR" "$LOG_DIR" "$REPORT_DIR" "$BACKUP_ROOT" "$TXN_ROOT" "$PREFLIGHT_ROOT"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
    echo "错误：需要在交互式终端中运行此脚本。"
    exit 1
fi
exec 3</dev/tty 4>/dev/tty

say() { printf '%s\n' "$*" >&4; }
ask() { local __var="$1"; shift; printf '%s' "$*" >&4; IFS= read -r "$__var" <&3; }
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

if ! command -v apt-get >/dev/null 2>&1; then
    say "❌ 当前版本仅支持 Debian/Ubuntu（apt 系）。"
    exit 1
fi
if ! command -v systemctl >/dev/null 2>&1; then
    say "❌ 当前系统未检测到 systemd/systemctl，本工具暂不支持。"
    exit 1
fi

check_dependencies() {
    local -A pkg_for=(
        [ss]="iproute2" [ip]="iproute2" [shuf]="coreutils" [base64]="coreutils"
        [gzip]="gzip" [ssh-keygen]="openssh-client" [awk]="gawk" [sed]="sed"
        [grep]="grep" [sort]="coreutils" [tar]="tar" [hostname]="hostname"
    )
    local missing=() pkgs=() cmd pkg x seen=" "
    for cmd in "${!pkg_for[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    ((${#missing[@]} == 0)) && return 0
    say "检测到缺少基础依赖：${missing[*]}"
    for cmd in "${missing[@]}"; do
        pkg="${pkg_for[$cmd]}"
        if [[ "$seen" != *" $pkg "* ]]; then pkgs+=("$pkg"); seen+="$pkg "; fi
    done
    if ! confirm_y "是否自动安装缺少的依赖：${pkgs[*]}？"; then
        say "❌ 缺少必要依赖，已取消。"
        return 1
    fi
    DEBIAN_FRONTEND=noninteractive apt-get update || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" || return 1
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
    umask 077
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
    } > "$STATE_FILE"
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
    if grep -Eiq "^[[:space:]]*${spec}/${proto}([[:space:]]|$).*DENY" <<<"$out"; then
        printf 'deny'
    elif grep -Eiq "^[[:space:]]*${spec}/${proto}([[:space:]]|$).*ALLOW" <<<"$out"; then
        printf 'allow'
    else
        printf 'none'
    fi
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
        say "1. 重试"
        say "0. 返回"
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
        127.*|::1|localhost|127.*%lo|::1%lo) return 0 ;;
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
    local line proto state recvq sendq local_ep peer_ep rest port bind proc
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        read -r proto state recvq sendq local_ep peer_ep rest <<< "$line"
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
    say "=================================================="
    say "开荒前业务端口保护检查"
    say "=================================================="
    say "规则：SSH 自动保护；已识别业务自动保护；本机监听忽略；systemd-resolved 5355 自动忽略；未知公网监听逐项询问。"
    say "说明：选择 n 只代表不加入自动保护名单，不会主动删除已有防火墙规则。"
    say

    if ! command -v ss >/dev/null 2>&1; then
        say "未找到 ss，正在安装 iproute2..."
        apt update
        apt install -y iproute2
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
    say "--------------------------------------------------"
    say "业务保护检查完成"
    say "--------------------------------------------------"
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
                say "1. 保持 DENY，并取消本次端口变更（推荐）"
                say "2. 删除简单 DENY 并改为 ALLOW"
                say "0. 取消"
                choose_num choice "请选择 [默认1]：" "1 2 0" "1"
                case "$choice" in
                    2)
                        ufw delete deny "$spec/$proto" >/dev/null 2>&1 || true
                        if [[ "$(ufw_rule_state "$spec" "$proto")" == "deny" ]]; then
                            say "❌ 仍检测到 DENY，可能是带来源地址的复杂规则。为避免错误覆盖，请人工处理。"
                            return 2
                        fi
                        ufw allow "$spec/$proto" comment "$label" >/dev/null 2>&1 || ufw allow "$spec/$proto" >/dev/null
                        say "✅ 已改为 ALLOW：$spec/$proto"
                        return 0
                        ;;
                    *) return 2 ;;
                esac
            else
                say "1. 保持 DENY（推荐）"
                say "2. 删除简单 DENY 并改为 ALLOW"
                say "0. 跳过"
                choose_num choice "请选择 [默认1]：" "1 2 0" "1"
                if [[ "$choice" == "2" ]]; then
                    ufw delete deny "$spec/$proto" >/dev/null 2>&1 || true
                    if [[ "$(ufw_rule_state "$spec" "$proto")" == "deny" ]]; then
                        say "⚠️ 仍存在 DENY，未自动覆盖复杂规则：$spec/$proto"
                        return 0
                    fi
                    ufw allow "$spec/$proto" comment "$label" >/dev/null 2>&1 || ufw allow "$spec/$proto" >/dev/null
                    say "✅ 已改为 ALLOW：$spec/$proto"
                else
                    say "✅ 已保留原 DENY：$spec/$proto"
                fi
                return 0
            fi
            ;;
        *)
            ufw allow "$spec/$proto" comment "$label" >/dev/null 2>&1 || ufw allow "$spec/$proto" >/dev/null
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
                ufw_safe_allow "$port" "$proto" "Existing service - VPS Security" "0" || true
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
    if dpkg -s unattended-upgrades >/dev/null 2>&1 \
       && grep -Eq 'APT::Periodic::Unattended-Upgrade[[:space:]]+"1";' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; then
        printf '已开启'
    elif dpkg -s unattended-upgrades >/dev/null 2>&1; then
        printf '已安装/未开启'
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
status_ipv6() {
    if has_global_ipv6; then printf '已启用（%s）' "$(get_global_ipv6)"; else printf '无公网 IPv6'; fi
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
status_reboot_required() {
    [[ -f /var/run/reboot-required ]] && printf '需要重启' || printf '当前无需重启'
}
show_security_status() {
    say "当前安全状态："
    say "1.  系统更新：$(status_system_update)"
    say "2.  root 密码：$(status_root_password)"
    say "3.  SSH 端口：$(status_ssh_port)"
    say "4.  ED25519 公钥：$(status_ed25519_key)"
    say "5.  密钥登录测试：$(status_key_test)"
    say "6.  SSH 密码认证：$(status_password_auth)"
    say "7.  主机防火墙：$(status_firewall)"
    say "8.  Fail2ban：$(status_fail2ban)"
    say "9.  自动安全更新：$(status_auto_updates)"
    say "10. 公网监听：$(status_public_listeners)"
    say "    业务端口保护：$(status_preflight)"
    say "    Docker：$(status_docker)"
    say "    Docker 防火墙：$(status_docker_firewall)"
    say "    IPv6：$(status_ipv6)"
    say "    IPv6 防火墙：$(status_ipv6_firewall)"
    say "    SSH KeepAlive：$(status_keepalive)"
    say "11. 安全检查报告：$(status_report)"
    say "    只读安全审计：$(status_audit)"
    say "12. 配置备份：$(status_backup)"
    say "    端口防火墙管理：$(status_port_manager)"
    say "    系统重启：$(status_reboot_required)"
}
backup_ssh() {
    local dir="$BACKUP_ROOT/ssh-$(date +%Y%m%d-%H%M%S)-$RANDOM"
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

_unit_enabled_state() { systemctl is-enabled "$1" 2>/dev/null || printf 'disabled'; }
_unit_active_state() { systemctl is-active "$1" 2>/dev/null || printf 'inactive'; }

begin_ssh_transaction() {
    local old_port="$1" new_port="$2" dir
    dir="$TXN_ROOT/ssh-$(date +%Y%m%d-%H%M%S)-$RANDOM"
    mkdir -p "$dir"
    chmod 700 "$dir"

    cp -a "$SSHD_CONFIG" "$dir/sshd_config"
    if [[ -d /etc/ssh/sshd_config.d ]]; then
        cp -a /etc/ssh/sshd_config.d "$dir/"
        printf '1\n' > "$dir/had-sshd-config-d"
    fi
    if [[ -d /root/.ssh ]]; then
        printf '1\n' > "$dir/had-root-ssh-dir"
    fi
    if [[ -f /root/.ssh/authorized_keys ]]; then
        mkdir -p "$dir/root-ssh"
        cp -a /root/.ssh/authorized_keys "$dir/root-ssh/authorized_keys"
        printf '1\n' > "$dir/had-authorized-keys"
    else
        printf '1\n' > "$dir/had-no-authorized-keys"
    fi
    if [[ -f "$STATE_FILE" ]]; then cp -a "$STATE_FILE" "$dir/state.env"; fi

    if [[ -f /etc/fail2ban/jail.d/vps-security-sshd.local ]]; then
        cp -a /etc/fail2ban/jail.d/vps-security-sshd.local "$dir/fail2ban-sshd.local"
        printf '1\n' > "$dir/had-fail2ban-file"
    fi

    if is_ufw_installed; then
        tar -C / -czf "$dir/ufw-config.tgz" etc/ufw etc/default/ufw 2>/dev/null || true
        ufw status numbered > "$dir/ufw-status.txt" 2>&1 || true
        printf '1\n' > "$dir/had-ufw"
    fi
    if command -v firewall-cmd >/dev/null 2>&1 || [[ -d /etc/firewalld ]]; then
        tar -C / -czf "$dir/firewalld-config.tgz" etc/firewalld 2>/dev/null || true
        command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --list-all-zones > "$dir/firewalld-zones.txt" 2>&1 || true
        printf '1\n' > "$dir/had-firewalld"
    fi
    command -v iptables-save >/dev/null 2>&1 && iptables-save > "$dir/iptables-save.txt" 2>&1 || true
    command -v nft >/dev/null 2>&1 && nft list ruleset > "$dir/nft-ruleset.txt" 2>&1 || true

    cat > "$dir/meta.env" <<EOF
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
    chmod 600 "$dir/meta.env"
    SSH_TXN_DIR="$dir"
    SSH_TXN_OLD_PORT="$old_port"
    SSH_TXN_NEW_PORT="$new_port"
    PORT_BACKUP="$dir"
    save_state
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
    cp -a "$dir/sshd_config" "$SSHD_CONFIG"
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

    cp -a "$dir/sshd_config" "$SSHD_CONFIG"
    if [[ -f "$dir/had-sshd-config-d" && -d "$dir/sshd_config.d" ]]; then
        rm -rf /etc/ssh/sshd_config.d
        cp -a "$dir/sshd_config.d" /etc/ssh/
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
        rm -rf /etc/ufw
        tar -C / -xzf "$dir/ufw-config.tgz" 2>/dev/null || true
        if [[ "${UFW_ACTIVE:-no}" == "yes" ]]; then
            ufw --force enable >/dev/null 2>&1 || true
            ufw reload >/dev/null 2>&1 || true
        else
            ufw --force disable >/dev/null 2>&1 || true
        fi
    fi

    if [[ -f "$dir/firewalld-config.tgz" && -d /etc ]]; then
        rm -rf /etc/firewalld
        tar -C / -xzf "$dir/firewalld-config.tgz" 2>/dev/null || true
        if command -v firewall-cmd >/dev/null 2>&1; then
            if [[ "${FIREWALLD_ACTIVE:-no}" == "yes" ]]; then
                systemctl start firewalld >/dev/null 2>&1 || true
                firewall-cmd --reload >/dev/null 2>&1 || true
            fi
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
    printf '%s\n' "COMMITTED $(date '+%F %T')" > "$dir/COMMITTED"
    log "SSH 事务提交：$dir"
    SSH_TXN_DIR=""
    SSH_TXN_OLD_PORT=""
    SSH_TXN_NEW_PORT=""
    PORT_BACKUP=""
    save_state
}
remove_managed_block() {
    local tmp
    tmp="$(mktemp)"
    awk -v b="$MANAGED_BEGIN" -v e="$MANAGED_END" '
        $0==b {skip=1; next}
        $0==e {skip=0; next}
        !skip {print}
    ' "$SSHD_CONFIG" > "$tmp"
    cat "$tmp" > "$SSHD_CONFIG"
    rm -f "$tmp"
}

comment_existing_port_directives() {
    local f
    shopt -s nullglob
    local files=("$SSHD_CONFIG" /etc/ssh/sshd_config.d/*.conf)
    for f in "${files[@]}"; do
        [[ -f "$f" ]] || continue
        sed -Ei 's/^([[:space:]]*)Port[[:space:]]+([0-9]+)([[:space:]]*(#.*)?)$/\1# VPS-SECURITY disabled previous Port \2\3/' "$f"
    done
    shopt -u nullglob
}

write_sshd_managed_block() {
    local port="$1" locked="$2"
    local tmp
    remove_managed_block
    comment_existing_port_directives
    tmp="$(mktemp)"
    {
        echo "$MANAGED_BEGIN"
        echo "Port $port"
        echo "PubkeyAuthentication yes"
        if [[ "$locked" == "1" ]]; then
            echo "PasswordAuthentication no"
            echo "KbdInteractiveAuthentication no"
            echo "ChallengeResponseAuthentication no"
            echo "PermitEmptyPasswords no"
            echo "PermitRootLogin prohibit-password"
        fi
        if [[ "${KEEPALIVE_ENABLED:-0}" == "1" ]]; then
            echo "ClientAliveInterval 60"
            echo "ClientAliveCountMax 3"
            echo "TCPKeepAlive yes"
        fi
        echo "$MANAGED_END"
        echo
        cat "$SSHD_CONFIG"
    } > "$tmp"
    cat "$tmp" > "$SSHD_CONFIG"
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
            firewall-cmd --zone="$zone" --add-port="$port/tcp" >/dev/null || return 1
            firewall-cmd --permanent --zone="$zone" --add-port="$port/tcp" >/dev/null || return 1
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
                say '1. 保留旧端口规则（默认）'
                say '2. 删除简单 ALLOW 规则'
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
                say '1. 保留旧端口规则（默认）'
                say '2. 删除旧端口放行'
                choose_num choice '请选择 [默认1]：' '1 2' '1'
                if [[ "$choice" == '2' ]]; then
                    firewall-cmd --zone="$zone" --remove-port="$old/tcp" >/dev/null 2>&1 || true
                    firewall-cmd --permanent --zone="$zone" --remove-port="$old/tcp" >/dev/null 2>&1 || true
                    firewall-cmd --reload >/dev/null 2>&1 || true
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
    local port="$1" actual
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
    if ! systemctl restart fail2ban >/dev/null 2>&1; then
        say '❌ Fail2ban 重启失败。'
        return 1
    fi
    sleep 1
    if ! fail2ban-client status sshd >/dev/null 2>&1; then
        say '❌ Fail2ban sshd jail 未正常运行。'
        return 1
    fi
    actual="$(fail2ban-client get sshd port 2>/dev/null || true)"
    if ! grep -Eq "(^|[ ,])${port}([ ,]|$)" <<<"$actual"; then
        say "❌ Fail2ban sshd jail 端口校验失败：期望 $port，实际 ${actual:-未知}"
        return 1
    fi
    say "✅ Fail2ban sshd jail 已验证使用端口：$port"
}

detect_business_services() {
    local found=()
    command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null && found+=("Docker")
    { systemctl is-active --quiet nginx 2>/dev/null || pgrep -x nginx >/dev/null 2>&1; } && found+=("Nginx")
    pgrep -x openresty >/dev/null 2>&1 && found+=("OpenResty")
    [[ -d /opt/1panel || -d /opt/1Panel ]] && found+=("1Panel")
    { systemctl is-active --quiet x-ui 2>/dev/null || systemctl is-active --quiet 3x-ui 2>/dev/null; } && found+=("x-ui/3x-ui")
    { pgrep -x mysqld >/dev/null 2>&1 || pgrep -x mariadbd >/dev/null 2>&1; } && found+=("MySQL/MariaDB")
    pgrep -x postgres >/dev/null 2>&1 && found+=("PostgreSQL")
    pgrep -x redis-server >/dev/null 2>&1 && found+=("Redis")
    pgrep -f '[k]omari' >/dev/null 2>&1 && found+=("Komari")
    pgrep -f '[q]inglong' >/dev/null 2>&1 && found+=("QingLong")
    printf '%s\n' "${found[@]}" | awk 'NF&&!seen[$0]++'
}

step1_update_system() {
    say
    say "=================================================="
    say "1. 更新系统"
    say "=================================================="
    say "基础命令：apt update && apt upgrade -y"
    say

    local business choice mode="normal"
    business="$(detect_business_services || true)"
    if [[ -n "$business" ]]; then
        say "检测到本机已有业务："
        while IFS= read -r x; do [[ -n "$x" ]] && say "  - $x"; done <<< "$business"
        say
        say "1. 安全更新模式（推荐，避免 needrestart 自动重启业务服务）"
        say "2. 正常系统更新"
        say "0. 跳过本次更新"
        choose_num choice "请选择 [默认1]：" "1 2 0" "1"
        case "$choice" in
            0) say "已跳过系统更新。"; return 0 ;;
            1) mode="safe" ;;
            2) mode="normal" ;;
        esac
    fi

    export DEBIAN_FRONTEND=noninteractive
    if [[ "$mode" == "safe" ]]; then
        export NEEDRESTART_MODE=l
    else
        export NEEDRESTART_MODE=a
    fi
    apt update || return 1
    apt upgrade -y || return 1
    log "系统更新完成：apt update && apt upgrade -y；模式=$mode"
    say "✅ 系统更新完成。"

    if command -v needrestart >/dev/null 2>&1; then
        say
        say "服务重启建议（只读）："
        NEEDRESTART_MODE=l needrestart -r l 2>/dev/null >&4 || true
    fi
    if [[ -f /var/run/reboot-required ]]; then
        say "⚠️ 系统提示需要重启；建议全部开荒完成并确认 SSH 正常后，再从主菜单选择重启。"
    fi
}
step2_change_root_password() {
    say
    say "=================================================="
    say "2. 修改 root 密码"
    say "=================================================="
    say "下面会让你输入两次新的 root 密码，输入时不会显示字符。"
    passwd root </dev/tty
    log "root 密码已修改"
    say "✅ root 密码修改完成。"
}

step3_random_ssh_port() {
    say
    say "=================================================="
    say "3. 随机 SSH 高位端口"
    say "=================================================="

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
        elif [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1024 && input <= 65535 )); then
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

    begin_ssh_transaction "$current" "$new" >/dev/null
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

    locked="0"
    sshd_password_auth_disabled && locked="1"
    write_sshd_managed_block "$new" "$locked"
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
    say "=================================================="
    say "4. 添加 ED25519 公钥"
    say "=================================================="
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
    say "=================================================="
    say "5. 新窗口测试密钥"
    say "=================================================="

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
    say "1. 密钥登录成功，提交 SSH 修改"
    say "2. 登录失败，完整回滚 SSH 修改"
    say "0. 暂不处理，返回"
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
    say "=================================================="
    say "6. 关闭 SSH 密码认证"
    say "=================================================="

    local port txn eff
    port="$(get_primary_ssh_port)"

    if [[ ! -s /root/.ssh/authorized_keys ]]; then
        say "❌ 没有检测到 root SSH 公钥，拒绝关闭密码登录。"
        return 1
    fi
    if [[ "${KEY_TESTED:-0}" != "1" ]]; then
        say "⚠️ 没有记录到‘新窗口密钥登录成功’。"
        if ! confirm_y "你是否已经亲自测试密钥登录成功，并继续？"; then
            say "已取消。"
            return 1
        fi
        KEY_TESTED="1"
        save_state
    fi

    begin_ssh_transaction "$port" "$port" >/dev/null
    txn="$SSH_TXN_DIR"
    write_sshd_managed_block "$port" "1"

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
    save_state
    commit_ssh_transaction "$txn"
    log "SSH 密码认证已关闭，root 仅允许非密码方式登录"
    say "✅ PasswordAuthentication no"
    say "✅ KbdInteractiveAuthentication no"
    say "✅ PermitRootLogin prohibit-password"
    say "⚠️ 当前窗口先别关，再新开一个窗口用密钥测试一次。"
}
firewalld_rich_conflict() {
    local port="$1" proto="$2" zone rules
    zone="$(firewalld_zone)"
    rules="$(firewall-cmd --zone="$zone" --list-rich-rules 2>/dev/null || true)"
    grep -Eiq "port port=\"?${port}\"? protocol=\"?${proto}\"?.*(reject|drop)" <<<"$rules"
}

firewalld_allow_safe() {
    local port="$1" proto="$2" label="$3" zone choice
    zone="$(firewalld_zone)"
    if firewalld_rich_conflict "$port" "$proto"; then
        say "⚠️ firewalld 检测到针对 $port/$proto 的 rich-rule reject/drop。"
        say "本工具不会自动删除复杂拒绝规则。"
        say "1. 保持拒绝规则（推荐）"
        say "0. 跳过"
        choose_num choice "请选择 [默认1]：" "1 0" "1"
        return 0
    fi
    if firewall-cmd --zone="$zone" --query-port="$port/$proto" >/dev/null 2>&1; then
        say "ℹ️ firewalld 已放行：$port/$proto"
        return 0
    fi
    firewall-cmd --zone="$zone" --add-port="$port/$proto" >/dev/null || return 1
    firewall-cmd --permanent --zone="$zone" --add-port="$port/$proto" >/dev/null || return 1
    say "✅ firewalld 已放行：$port/$proto（$label）"
}

step7_configure_ufw() {
    say
    say "=================================================="
    say "7. 安装/配置主机防火墙"
    say "=================================================="

    ensure_business_preflight
    local backend ports p zone proto port class procs binds
    backend="$(detect_firewall_backend)"
    say "检测到防火墙后端：$backend"

    case "$backend" in
        conflict)
            say "❌ UFW 与 firewalld 同时启用，自动配置已停止。请先选择并保留一个防火墙后端。"
            return 1
            ;;
        firewalld)
            zone="$(firewalld_zone)"
            say "使用现有 firewalld，不安装/启用 UFW。默认 zone：$zone"
            ports="$(get_sshd_ports)"; [[ -n "$ports" ]] || ports="$(get_primary_ssh_port)"
            while read -r p; do [[ -n "$p" ]] && firewalld_allow_safe "$p" tcp "SSH - VPS Security"; done <<< "$ports"
            if [[ -f "$PROTECTED_PORTS_FILE" ]]; then
                while IFS=$'\t' read -r proto port class procs binds; do
                    [[ -n "$port" && "$class" != "SSH" ]] || continue
                    firewalld_allow_safe "$port" "$proto" "Existing service - VPS Security"
                done < "$PROTECTED_PORTS_FILE"
            fi
            firewall-cmd --reload >/dev/null || return 1
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
        DEBIAN_FRONTEND=noninteractive apt-get update || return 1
        DEBIAN_FRONTEND=noninteractive apt-get install -y ufw || return 1
    fi

    # 不 reset。只设置默认策略，并补齐当前 SSH + 业务保护端口。
    ufw default deny incoming >/dev/null || return 1
    ufw default allow outgoing >/dev/null || return 1

    ports="$(get_sshd_ports)"; [[ -n "$ports" ]] || ports="$(get_primary_ssh_port)"
    while read -r p; do
        [[ -n "$p" ]] || continue
        if ! ufw_safe_allow "$p" tcp "SSH - VPS Security" "1"; then
            say "❌ 当前 SSH 端口 $p 存在未解决的 DENY 冲突，拒绝启用/重载 UFW。"
            return 1
        fi
    done <<< "$ports"

    ufw_allow_protected_business_ports

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
    say '=================================================='
    say '8. 安装 Fail2ban'
    say '=================================================='
    local port
    port="$(get_primary_ssh_port)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update || return 1
    apt-get install -y fail2ban || return 1
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
    say "=================================================="
    say "9. 开启自动安全更新"
    say "=================================================="

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y unattended-upgrades
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    systemctl enable --now unattended-upgrades.service >/dev/null 2>&1 || true
    log "unattended-upgrades 已启用"
    say "✅ 自动安全更新已启用。"
    say "配置：/etc/apt/apt.conf.d/20auto-upgrades"
}

step10_scan_public_ports() {
    say
    say "=================================================="
    say "10. 扫描公网监听端口"
    say "=================================================="
    say "下面列出所有非回环 TCP/UDP 监听；127.0.0.1 / ::1 不视为公网业务端口。"
    say
    local line proto state recvq sendq local_ep peer_ep rest bind
    local found=0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        read -r proto state recvq sendq local_ep peer_ep rest <<< "$line"
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
    say "=================================================="
    say "11. 输出最终安全检查报告"
    say "=================================================="

    local report="$REPORT_DIR/security-report-$(date +%Y%m%d-%H%M%S).txt"
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
        if dpkg -s unattended-upgrades >/dev/null 2>&1; then
            echo "unattended-upgrades：已安装"
            cat /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null || true
        else
            echo "unattended-upgrades：未安装"
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
        [[ -f /var/run/reboot-required ]] && echo "需要重启" || echo "当前没有 reboot-required 标记"
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
    say "=================================================="
    say "12. 保存端口和配置备份位置"
    say "=================================================="

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

normalize_port_spec() {
    local x="$1"
    x="${x// /}"
    if [[ "$x" =~ ^[0-9]+$ ]]; then
        (( x >= 1 && x <= 65535 )) || return 1
        printf '%s\n' "$x"
        return 0
    fi
    if [[ "$x" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
        (( a >= 1 && a <= 65535 && b >= 1 && b <= 65535 && a <= b )) || return 1
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
                            say "✅ 已封禁入站：$spec/$proto"
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
                            say "✅ 已移除 firewalld 放行：$fw_spec/$proto"
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
        firewalld) firewall-cmd --reload >/dev/null 2>&1 || true ;;
    esac
}

step13_port_firewall_manager() {
    local ready=0 b c ports psel proto
    ensure_firewall_manager_ready || ready=$?
    b="$(detect_firewall_backend)"
    if (( ready == 2 )) || [[ "$b" == "nftables" || "$b" == "iptables" ]]; then
        say
        say '=================================================='
        say "自定义 $b（只读）"
        say '=================================================='
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
        say "=================================================="
        say "防火墙端口管理（当前：$b）"
        say "=================================================="
        say "1. 放行端口"
        say "2. 关闭入站端口（不会停止对应服务）"
        say "3. 查看当前规则"
        say "0. 返回"
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

    audit_emit PASS "系统支持" "Debian/Ubuntu apt 系"
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
    if dpkg -s unattended-upgrades >/dev/null 2>&1 && grep -Eq 'Unattended-Upgrade[[:space:]]+"1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; then
        audit_emit PASS "自动安全更新" "已开启"
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
    [[ -f /var/run/reboot-required ]] && audit_emit INFO "系统重启" "需要重启" || audit_emit INFO "系统重启" "当前无需重启"

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
    local dir="$BACKUP_ROOT/docker-firewall-$(date +%Y%m%d-%H%M%S)-$RANDOM"
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
        clear
        say "=================================================="
        say "Docker 安全检查（默认只读）"
        say "=================================================="
        say "状态：$(status_docker)"
        say "DOCKER-USER：$(status_docker_firewall)"
        say
        say "1. 查看 Docker 端口映射"
        say "2. 查看 DOCKER-USER"
        say "3. 备份 Docker/iptables/nftables 当前状态"
        say "4. 查看 Docker 防火墙说明"
        say "0. 返回"
        choose_num c "请选择：" "1 2 3 4 0" "0"
        case "$c" in
            1) print_docker_mappings; pause ;;
            2) show_docker_user_chain; pause ;;
            3) docker_firewall_backup; pause ;;
            4)
                say
                say "Docker 发布端口可能绕过普通 UFW INPUT。"
                say "v10.0.0 默认只审计，不自动写入 DOCKER-USER，避免破坏 1Panel、青龙、Komari、x-ui 等现有业务。"
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
    say "1. 开启推荐配置（60 秒心跳，3 次失败）"
    say "2. 关闭本工具管理的 KeepAlive"
    say "0. 返回"
    choose_num c "请选择：" "1 2 0" "0"
    [[ "$c" != "0" ]] || return 0
    port="$(get_primary_ssh_port)"; locked=0; sshd_password_auth_disabled && locked=1
    begin_ssh_transaction "$port" "$port" >/dev/null; txn="$SSH_TXN_DIR"
    [[ "$c" == "1" ]] && KEEPALIVE_ENABLED="1" || KEEPALIVE_ENABLED="0"
    save_state
    write_sshd_managed_block "$port" "$locked"
    if ! "$SSHD_BIN" -t || ! systemctl restart "$SSH_SERVICE"; then
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
        clear
        say "=================================================="
        say "高级设置"
        say "=================================================="
        say "1. SSH KeepAlive"
        say "2. IPv6 防火墙检查 / 修复"
        say "3. Docker 防火墙高级检查"
        say "4. 查看备份"
        say "5. 查看操作日志"
        say "6. 历史报告 / 备份清理"
        say "0. 返回"
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
    local rc=0
    if ! confirm_y "开始通用安全开荒？"; then
        say "已取消，返回主菜单。"
        return 0
    fi

    run_step "业务端口保护预检" business_port_preflight || { say "预检未完成，已停止完整开荒。"; pause; return 0; }
    run_step "1. 更新系统" step1_update_system || { pause; return 0; }
    run_step "2. 修改 root 密码" step2_change_root_password || { pause; return 0; }
    run_step "3. 随机 SSH 高位端口" step3_random_ssh_port || { pause; return 0; }
    run_step "4. 添加 ED25519 公钥" step4_add_ed25519_key || { pause; return 0; }

    if step5_test_key; then
        rc=0
    else
        rc=$?
    fi
    load_state
    if (( rc != 0 )); then
        say
        say "⚠️ 密钥测试未确认成功，完整流程已安全停止。"
        say "不会关闭 SSH 密码认证，也不会继续修改后续安全配置。"
        say "开荒前快照：${LAST_PREFLIGHT:-$PREFLIGHT_ROOT}"
        pause
        return 0
    fi

    run_step "6. 关闭 SSH 密码认证" step6_disable_password_auth || { pause; return 0; }
    run_step "7. 配置主机防火墙" step7_configure_ufw || { pause; return 0; }
    run_step "8. 安装 Fail2ban" step8_install_fail2ban || { pause; return 0; }
    run_step "9. 开启自动安全更新" step9_enable_auto_updates || { pause; return 0; }
    run_step "10. 扫描公网监听端口" step10_scan_public_ports || true
    run_step "11. 输出安全检查报告" step11_security_report || true
    run_step "12. 保存端口和配置备份" step12_save_info_and_backup || true

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
    [[ -f /var/run/reboot-required ]] && say "⚠️ 系统更新提示需要重启，可回主菜单选择 8。"
    pause
}

single_menu() {
    local c rc
    while true; do
        clear
        say "=================================================="
        say " $APP_NAME"
        say " —— 单项安全优化"
        say "=================================================="
        say "1. 更新系统"
        say "2. 修改 root 密码"
        say "3. 随机 SSH 高位端口"
        say "4. 添加 ED25519 公钥"
        say "5. 新窗口测试密钥"
        say "6. 关闭 SSH 密码认证"
        say "7. 安装/配置主机防火墙"
        say "8. 安装 Fail2ban"
        say "9. 开启自动安全更新"
        say "10. 扫描公网监听端口"
        say "11. 输出最终安全检查报告"
        say "12. 保存端口和配置备份位置"
        say "0. 返回主菜单"
        say
        choose_num c "请输入数字：" "1 2 3 4 5 6 7 8 9 10 11 12 0" "0"
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
            0) return 0 ;;
        esac
    done
}

reboot_server() {
    say
    say "=================================================="
    say "重启服务器"
    say "=================================================="
    [[ -f /var/run/reboot-required ]] && say "系统状态：当前更新提示需要重启。" || say "系统状态：当前没有 reboot-required 提示。"
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
    say "=================================================="
    say "              $APP_NAME"
    say "=================================================="
    say "系统：$(get_os_pretty)"
    say "主机：$(hostname)"
    say "IPv4：$(get_ipv4)"
    say "IPv6：$(status_ipv6)"
    say "运行时间：$(get_uptime_short)"
    say
}

main_menu() {
    local c
    while true; do
        clear
        show_header
        say "1. 通用安全开荒"
        say "2. 单项安全优化"
        say "3. 业务端口保护预检 / 重新扫描"
        say "4. 防火墙端口管理"
        say "5. 只读安全检查"
        say "6. Docker 安全检查"
        say "7. 高级设置"
        say "8. 重启服务器"
        say "0. 退出工具"
        say
        show_security_status
        say
        choose_num c "请选择：" "1 2 3 4 5 6 7 8 0" "0"
        case "$c" in
            1) run_full_setup ;;
            2) single_menu ;;
            3) run_step "业务端口保护预检" business_port_preflight || true; pause ;;
            4) step13_port_firewall_manager || true ;;
            5) audit_readonly; pause ;;
            6) docker_security_menu ;;
            7) advanced_menu ;;
            8) reboot_server || true ;;
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
