#!/usr/bin/env bash
# ============================================================
# wireguard-mesh.sh — WireGuard 全互联组网管理脚本
# 版本：2.0.0
#
# 用法：
#   bash wireguard-mesh.sh [子命令] [参数...]
#   不带参数时进入交互菜单
#
# 子命令：
#   install               安装 WireGuard
#   genkey                生成本机密钥对
#   pubkey                打印本机公钥
#   init   <WG_IP[/掩码]> 初始化 wg0 接口
#   add-peer <公钥> <WG_IP/掩码> [Endpoint]
#   remove-peer <公钥>    移除一个 Peer
#   up                    启动 wg0
#   down                  停止 wg0
#   status                显示接口状态 + 连通性测试
#   help                  显示帮助
#
# 环境变量：
#   WG_IFACE   接口名（默认 wg0）
#   WG_PORT    监听端口（默认 51820）
# ============================================================
set -euo pipefail

# ── 常量 ────────────────────────────────────────────────────
readonly WG_IFACE="${WG_IFACE:-wg0}"
readonly WG_PORT="${WG_PORT:-51820}"
readonly WG_DIR="/etc/wireguard"
readonly WG_CONF="${WG_DIR}/${WG_IFACE}.conf"
readonly WG_KEY_DIR="${WG_DIR}/keys"
readonly PRIV_KEY_FILE="${WG_KEY_DIR}/privatekey"
readonly PUB_KEY_FILE="${WG_KEY_DIR}/publickey"

# ── 颜色输出 ────────────────────────────────────────────────
_has_color() { [[ -t 1 ]] && command -v tput &>/dev/null && tput colors &>/dev/null; }

if _has_color; then
    C_OK="\e[32m"; C_INFO="\e[36m"; C_WARN="\e[33m"; C_ERR="\e[31m"
    C_BOLD="\e[1;34m"; C_RESET="\e[0m"
else
    C_OK=""; C_INFO=""; C_WARN=""; C_ERR=""; C_BOLD=""; C_RESET=""
fi

log()    { printf "${C_OK}[OK]  %s${C_RESET}\n" "$*"; }
info()   { printf "${C_INFO}[..] %s${C_RESET}\n" "$*"; }
warn()   { printf "${C_WARN}[!!] %s${C_RESET}\n" "$*" >&2; }
error()  { printf "${C_ERR}[EE] %s${C_RESET}\n" "$*" >&2; exit 1; }
header() { printf "\n${C_BOLD}══ %s ══${C_RESET}\n" "$*"; }

# ── 前置检查 ────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || error "需要 root 权限，请用 sudo 执行"
}

require_conf() {
    [[ -f "$WG_CONF" ]] || error "配置文件不存在: $WG_CONF，请先执行 init"
}

require_keys() {
    [[ -f "$PRIV_KEY_FILE" ]] || error "私钥不存在，请先执行 genkey"
    [[ -f "$PUB_KEY_FILE"  ]] || error "公钥不存在，请先执行 genkey"
}

# ── IP 格式验证 ──────────────────────────────────────────────
# 返回 0=合法，1=非法
is_valid_ipv4() {
    local ip="${1%%/*}"   # 去掉可能带的掩码
    local IFS='.'
    read -ra octets <<< "$ip"
    [[ ${#octets[@]} -eq 4 ]] || return 1
    local o
    for o in "${octets[@]}"; do
        [[ "$o" =~ ^[0-9]+$ ]] || return 1
        (( o >= 0 && o <= 255 ))  || return 1
    done
    return 0
}

is_valid_cidr() {
    local addr="${1%%/*}"
    local mask="${1##*/}"
    is_valid_ipv4 "$addr" || return 1
    [[ "$mask" =~ ^[0-9]+$ ]] && (( mask >= 0 && mask <= 32 )) || return 1
    return 0
}

is_valid_endpoint() {
    # host:port 或 ip:port
    local ep="$1"
    [[ "$ep" =~ ^.+:[0-9]{1,5}$ ]] || return 1
    local port="${ep##*:}"
    (( port >= 1 && port <= 65535 )) || return 1
    return 0
}

# ── Base64 公钥格式粗校验（44 字符，Base64 字符集）──────────
is_valid_pubkey() {
    [[ "${#1}" -eq 44 ]] && [[ "$1" =~ ^[A-Za-z0-9+/]{43}=$ ]]
}

# ═══════════════════════════════════════════════════════════
# 功能函数
# ═══════════════════════════════════════════════════════════

# ── install ─────────────────────────────────────────────────
cmd_install() {
    require_root
    header "安装 WireGuard"

    if command -v wg &>/dev/null; then
        log "WireGuard 已安装: $(wg --version 2>&1 | head -1)"
        return 0
    fi

    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard wireguard-tools
    elif command -v dnf &>/dev/null; then
        dnf install -y wireguard-tools
    elif command -v yum &>/dev/null; then
        yum install -y epel-release
        yum install -y wireguard-tools
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm wireguard-tools
    else
        error "不支持的包管理器，请手动安装 wireguard-tools"
    fi

    # 尝试加载内核模块（容器环境可能失败，非致命）
    modprobe wireguard 2>/dev/null \
        || warn "wireguard 内核模块加载失败（容器环境可忽略）"

    command -v wg &>/dev/null || error "安装后仍找不到 wg 命令，请检查安装日志"
    log "WireGuard 安装完成: $(wg --version 2>&1 | head -1)"
}

# ── genkey ──────────────────────────────────────────────────
cmd_genkey() {
    require_root
    header "生成密钥对"

    mkdir -p "$WG_KEY_DIR"
    chmod 700 "$WG_KEY_DIR"

    if [[ -f "$PRIV_KEY_FILE" ]]; then
        warn "密钥已存在: $PRIV_KEY_FILE"
        warn "如需重新生成请先手动删除旧密钥（会导致已有 Peer 失效）"
        echo "当前公钥: $(cat "$PUB_KEY_FILE")"
        return 0
    fi

    # 原子写入：先生成到临时文件，再 mv
    local tmp_priv; tmp_priv=$(mktemp "${WG_KEY_DIR}/privatekey.XXXXXX")
    local tmp_pub;  tmp_pub=$(mktemp  "${WG_KEY_DIR}/publickey.XXXXXX")
    trap 'rm -f "$tmp_priv" "$tmp_pub"' EXIT

    wg genkey > "$tmp_priv"
    wg pubkey  < "$tmp_priv" > "$tmp_pub"

    chmod 600 "$tmp_priv"
    chmod 644 "$tmp_pub"
    mv "$tmp_priv" "$PRIV_KEY_FILE"
    mv "$tmp_pub"  "$PUB_KEY_FILE"
    trap - EXIT

    log "私钥已写入: $PRIV_KEY_FILE"
    log "公钥: $(cat "$PUB_KEY_FILE")"
}

# ── pubkey ──────────────────────────────────────────────────
cmd_pubkey() {
    [[ -f "$PUB_KEY_FILE" ]] || error "公钥不存在，请先执行 genkey"
    cat "$PUB_KEY_FILE"
}

# ── init <WG_IP[/mask]> ─────────────────────────────────────
cmd_init() {
    require_root
    local RAW_IP="${1:?用法: init <WG_IP[/掩码]>  例: init 10.10.0.2 或 init 10.10.0.2/24}"
    require_keys

    # 规范化：若未带掩码则补 /24
    local WG_ADDR
    if [[ "$RAW_IP" == */* ]]; then
        is_valid_cidr "$RAW_IP" || error "IP/掩码格式无效: $RAW_IP"
        WG_ADDR="$RAW_IP"
    else
        is_valid_ipv4 "$RAW_IP" || error "IP 格式无效: $RAW_IP"
        WG_ADDR="${RAW_IP}/24"
    fi

    header "初始化 ${WG_IFACE} (${WG_ADDR})"

    if [[ -f "$WG_CONF" ]]; then
        warn "配置文件已存在: $WG_CONF"
        read -rp "覆盖? [y/N] " CONFIRM
        [[ "${CONFIRM,,}" == "y" ]] || { info "已取消"; return 0; }
        # 先停止服务，再覆盖
        _stop_iface_safe
    fi

    mkdir -p "$WG_DIR"
    chmod 700 "$WG_DIR"

    # 使用 install 保证权限一次到位
    install -m 600 /dev/null "$WG_CONF"
    cat > "$WG_CONF" <<EOF
[Interface]
Address    = ${WG_ADDR}
PrivateKey = $(cat "$PRIV_KEY_FILE")
ListenPort = ${WG_PORT}
EOF

    log "配置已写入: $WG_CONF"
    info "接下来用 add-peer 添加对端节点，然后执行 up"
}

# ── add-peer <公钥> <AllowedIPs> [Endpoint] ─────────────────
cmd_add_peer() {
    require_root
    require_conf

    local PUB_KEY="${1:?用法: add-peer <公钥> <WG_IP/掩码> [公网IP:PORT]}"
    local ALLOWED_IPS="${2:?}"
    local ENDPOINT="${3:-}"

    # 输入校验
    is_valid_pubkey "$PUB_KEY"   || error "公钥格式无效（应为 44 字符 Base64）: ${PUB_KEY:0:20}..."
    is_valid_cidr   "$ALLOWED_IPS" || error "AllowedIPs 格式无效: $ALLOWED_IPS"
    if [[ -n "$ENDPOINT" ]]; then
        is_valid_endpoint "$ENDPOINT" || error "Endpoint 格式无效（应为 host:port）: $ENDPOINT"
    fi

    header "添加 Peer: ${ALLOWED_IPS}"

    # 精确匹配 PublicKey 行，防止子串误判
    if grep -qE "^\s*PublicKey\s*=\s*${PUB_KEY}\s*$" "$WG_CONF"; then
        warn "Peer 已存在: ${PUB_KEY:0:20}..."
        return 0
    fi

    # 备份后追加
    _backup_conf
    {
        printf '\n[Peer]\n'
        printf 'PublicKey  = %s\n' "$PUB_KEY"
        printf 'AllowedIPs = %s\n' "$ALLOWED_IPS"
        if [[ -n "$ENDPOINT" ]]; then
            printf 'Endpoint            = %s\n' "$ENDPOINT"
            printf 'PersistentKeepalive = 25\n'
        fi
    } >> "$WG_CONF"

    log "Peer 已追加到 $WG_CONF"

    # 热添加（接口运行中才执行）
    if _iface_is_up; then
        local -a args=(set "${WG_IFACE}" peer "${PUB_KEY}" allowed-ips "${ALLOWED_IPS}")
        [[ -n "$ENDPOINT" ]] && args+=(endpoint "${ENDPOINT}" persistent-keepalive 25)
        wg "${args[@]}" && log "Peer 已热添加到运行中的 ${WG_IFACE}"
    fi
}

# ── remove-peer <公钥> ───────────────────────────────────────
cmd_remove_peer() {
    require_root
    require_conf

    local PUB_KEY="${1:-}"
    PUB_KEY="$(tr -d '[:space:]' <<< "$PUB_KEY")"
    [[ -n "$PUB_KEY" ]] || error "公钥不能为空"
    is_valid_pubkey "$PUB_KEY" || error "公钥格式无效: ${PUB_KEY:0:20}..."

    header "移除 Peer: ${PUB_KEY:0:20}..."

    if ! grep -qE "^\s*PublicKey\s*=\s*${PUB_KEY}\s*$" "$WG_CONF"; then
        warn "配置文件中未找到该 Peer: ${PUB_KEY:0:20}..."
        return 1
    fi

    _backup_conf
    _remove_peer_block "$PUB_KEY"

    if _iface_is_up; then
        wg set "${WG_IFACE}" peer "$PUB_KEY" remove 2>/dev/null \
            && log "Peer 已从运行中的 ${WG_IFACE} 移除" \
            || warn "运行时移除失败，配置文件已更新，重启后生效"
    fi
}

# ── up ──────────────────────────────────────────────────────
cmd_up() {
    require_root
    require_conf
    header "启动 ${WG_IFACE}"

    # 清理残留接口
    if ip link show "${WG_IFACE}" &>/dev/null; then
        warn "${WG_IFACE} 接口已存在，先清理..."
        _stop_iface_safe
        sleep 1
    fi

    # 重置 failed 状态，避免 systemd 拒绝启动
    systemctl reset-failed "wg-quick@${WG_IFACE}" 2>/dev/null || true

    systemctl enable --now "wg-quick@${WG_IFACE}"
    sleep 1

    if _iface_is_up; then
        wg show "${WG_IFACE}"
        log "${WG_IFACE} 已启动"
    else
        error "${WG_IFACE} 启动后接口不存在，请检查日志: journalctl -u wg-quick@${WG_IFACE}"
    fi
}

# ── down ────────────────────────────────────────────────────
cmd_down() {
    require_root
    header "停止 ${WG_IFACE}"

    systemctl disable --now "wg-quick@${WG_IFACE}" 2>/dev/null || true
    systemctl reset-failed "wg-quick@${WG_IFACE}" 2>/dev/null || true

    # 兜底：接口仍存在则强制删除
    if ip link show "${WG_IFACE}" &>/dev/null; then
        warn "接口仍存在，强制删除..."
        ip link delete "${WG_IFACE}" 2>/dev/null || true
    fi

    log "${WG_IFACE} 已停止"
}

# ── status ──────────────────────────────────────────────────
cmd_status() {
    header "WireGuard 状态"

    if ! _iface_is_up; then
        warn "${WG_IFACE} 未运行"
        return 1
    fi

    wg show "${WG_IFACE}"
    echo ""
    header "Peer 连通性"

    # 从 wg show 输出中提取所有 AllowedIPs，支持多 IP/CIDR
    local any=0
    while IFS= read -r line; do
        # 匹配 "  allowed ips: 1.2.3.4/32, 5.6.7.8/32, ..."
        if [[ "$line" =~ ^[[:space:]]*allowed\ ips:[[:space:]]*(.+)$ ]]; then
            local ips_field="${BASH_REMATCH[1]}"
            # 逐个 CIDR 处理
            IFS=',' read -ra cidr_list <<< "$ips_field"
            local cidr
            for cidr in "${cidr_list[@]}"; do
                cidr="${cidr// /}"                  # 去空格
                [[ "$cidr" == "(none)" ]] && continue
                local ip="${cidr%%/*}"
                is_valid_ipv4 "$ip" || continue
                (( any++ ))
                if ping -c1 -W2 "$ip" &>/dev/null; then
                    log "✓ ${ip}"
                else
                    warn "✗ ${ip} 不可达"
                fi
            done
        fi
    done < <(wg show "${WG_IFACE}")

    [[ $any -eq 0 ]] && info "暂无可测试的 Peer IP"
    return 0
}

# ═══════════════════════════════════════════════════════════
# 内部工具函数
# ═══════════════════════════════════════════════════════════

# 接口是否运行
_iface_is_up() {
    ip link show "${WG_IFACE}" &>/dev/null
}

# 安全停止接口（systemd + 兜底）
_stop_iface_safe() {
    systemctl stop "wg-quick@${WG_IFACE}" 2>/dev/null || true
    systemctl reset-failed "wg-quick@${WG_IFACE}" 2>/dev/null || true
    if ip link show "${WG_IFACE}" &>/dev/null; then
        wg-quick down "${WG_IFACE}" 2>/dev/null \
            || ip link delete "${WG_IFACE}" 2>/dev/null \
            || true
    fi
}

# 备份配置文件（带时间戳）
_backup_conf() {
    local bak="${WG_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$WG_CONF" "$bak"
    info "配置已备份至: $bak"
}

# 从配置文件中精确删除一个 [Peer] 块（Python 实现，避免 sed 多行复杂性）
_remove_peer_block() {
    local target_key="$1"
    python3 - "$WG_CONF" "$target_key" <<'PY'
import sys, re, os

conf_path  = sys.argv[1]
target_key = sys.argv[2].strip()

with open(conf_path) as f:
    text = f.read()

# 按 [Interface] / [Peer] 分块，保留分隔符
blocks = re.split(r'(?=\[\s*(?:Interface|Peer)\s*\])', text)

def is_target_peer(block):
    if not re.match(r'\[\s*Peer\s*\]', block.lstrip()):
        return False
    for line in block.splitlines():
        m = re.match(r'^\s*PublicKey\s*=\s*(\S+)', line)
        if m and m.group(1) == target_key:
            return True
    return False

original_count = sum(1 for b in blocks if re.match(r'\[\s*Peer\s*\]', b.lstrip()))
filtered = [b for b in blocks if not is_target_peer(b)]
new_count = sum(1 for b in filtered if re.match(r'\[\s*Peer\s*\]', b.lstrip()))

if new_count == original_count:
    print(f"[EE] 未找到 Peer: {target_key[:20]}...", file=sys.stderr)
    sys.exit(1)

# 原子写入
tmp_path = conf_path + ".tmp"
result = ''.join(filtered)
# 保证末尾只有一个换行
result = result.rstrip('\n') + '\n'

with open(tmp_path, 'w') as f:
    f.write(result)

os.replace(tmp_path, conf_path)
print(f"[OK]  已从配置移除 Peer: {target_key[:20]}...")
PY
}

# ═══════════════════════════════════════════════════════════
# 交互菜单
# ═══════════════════════════════════════════════════════════

_pause() { echo; read -rp "  按 Enter 返回菜单..." _; }

# 读取输入，支持默认值；结果存入 $2 指定的变量名
_ask() {
    local prompt="$1" varname="$2" default="${3:-}"
    local hint=""
    [[ -n "$default" ]] && hint=" [默认: ${default}]"
    local val
    read -rp "  ${prompt}${hint}: " val
    if [[ -z "$val" && -n "$default" ]]; then
        val="$default"
    fi
    printf -v "$varname" '%s' "$val"
}

_menu_header() {
    clear
    printf "\n${C_BOLD}"
    echo "  ╔══════════════════════════════════════════════════╗"
    echo "  ║       wireguard-mesh  —  WireGuard 全互联        ║"
    echo "  ╚══════════════════════════════════════════════════╝"
    printf "${C_RESET}\n"
}

# ── 状态栏 ──────────────────────────────────────────────────
_print_status_bar() {
    local key_disp conf_disp wg_disp

    if [[ -f "$PUB_KEY_FILE" ]]; then
        key_disp="$(cut -c1-16 "$PUB_KEY_FILE")..."
    else
        key_disp="（未生成）"
    fi

    if [[ -f "$WG_CONF" ]]; then
        local peer_count
        peer_count=$(grep -c '^\[Peer\]' "$WG_CONF" 2>/dev/null || echo 0)
        conf_disp="${WG_CONF}  (${peer_count} peers)"
    else
        conf_disp="（未初始化）"
    fi

    if _iface_is_up 2>/dev/null; then
        wg_disp="${C_OK}运行中 ✓${C_RESET}"
    else
        wg_disp="${C_WARN}已停止${C_RESET}"
    fi

    printf "  本机公钥: ${C_INFO}%s${C_RESET}\n" "$key_disp"
    printf "  配置文件: ${C_INFO}%s${C_RESET}\n" "$conf_disp"
    printf "  接口状态: %b\n"   "$wg_disp"
    echo
}

# ── 主菜单 ───────────────────────────────────────────────────
menu_main() {
    while true; do
        _menu_header
        _print_status_bar
        echo "  ─────────────── 初始化 ────────────────────"
        echo "  1)  安装 WireGuard"
        echo "  2)  生成本机密钥对"
        echo "  3)  显示本机公钥"
        echo "  4)  初始化接口配置"
        echo "  ─────────────── 节点管理 ─────────────────"
        echo "  5)  添加对端节点（Peer）"
        echo "  6)  移除对端节点"
        echo "  7)  列出所有 Peer"
        echo "  ─────────────── 服务控制 ─────────────────"
        echo "  8)  启动 WireGuard"
        echo "  9)  停止 WireGuard"
        echo "  10) 查看状态 + 连通性测试"
        echo "  ─────────────────────────────────────────"
        echo "  g)  新节点部署向导"
        echo "  0)  退出"
        echo
        read -rp "  请选择: " CHOICE
        case "$CHOICE" in
            1)  _run_cmd "安装 WireGuard"           cmd_install ;;
            2)  _run_cmd "生成密钥对"               cmd_genkey ;;
            3)  _menu_show_pubkey ;;
            4)  _menu_init ;;
            5)  _menu_add_peer ;;
            6)  _menu_remove_peer ;;
            7)  _menu_list_peers ;;
            8)  _run_cmd "启动 WireGuard"           cmd_up ;;
            9)  _menu_confirm_down ;;
            10) _run_cmd "状态 + 连通性测试"        cmd_status ;;
            g|G) _menu_wizard ;;
            0)  echo; info "再见！"; exit 0 ;;
            *)  warn "无效选项"; sleep 1 ;;
        esac
    done
}

# 通用：显示标题 → 执行命令 → pause
_run_cmd() {
    local title="$1"; shift
    _menu_header
    printf "  ${C_WARN}▶ %s${C_RESET}\n\n" "$title"
    "$@" || true
    _pause
}

# ── 3. 显示公钥 ──────────────────────────────────────────────
_menu_show_pubkey() {
    _menu_header
    printf "  ${C_WARN}▶ 本机公钥${C_RESET}\n\n"
    if [[ ! -f "$PUB_KEY_FILE" ]]; then
        warn "公钥不存在，请先执行「生成密钥对」"
        _pause; return
    fi
    local pk; pk=$(cat "$PUB_KEY_FILE")
    echo "  ┌──────────────────────────────────────────────────────┐"
    printf "  │  %s  │\n" "$pk"
    echo "  └──────────────────────────────────────────────────────┘"
    echo
    info "将此公钥复制给其他节点用于 add-peer"
    _pause
}

# ── 4. 初始化 ────────────────────────────────────────────────
_menu_init() {
    _menu_header
    printf "  ${C_WARN}▶ 初始化接口配置${C_RESET}\n\n"
    if [[ ! -f "$PRIV_KEY_FILE" ]]; then
        warn "私钥不存在，请先执行「生成密钥对」"
        _pause; return
    fi
    echo "  建议网段: 10.10.0.x/24"
    echo "  主服务器用 .1，其余节点依次 .2 .3 ..."
    echo
    _ask "本机 WireGuard IP（如 10.10.0.2 或 10.10.0.2/24）" WG_IP ""
    if [[ -z "$WG_IP" ]]; then
        warn "IP 不能为空"; _pause; return
    fi
    echo
    cmd_init "$WG_IP" || true
    _pause
}

# ── 5. 添加 Peer ─────────────────────────────────────────────
_menu_add_peer() {
    _menu_header
    printf "  ${C_WARN}▶ 添加对端节点${C_RESET}\n\n"
    if [[ ! -f "$WG_CONF" ]]; then
        warn "配置文件不存在，请先执行「初始化接口配置」"
        _pause; return
    fi

    echo "  从对端机器执行 pubkey（或选项3）可获取对端公钥"
    echo
    _ask "对端公钥（Base64，44字符）" PEER_PK ""
    [[ -n "$PEER_PK" ]] || { warn "公钥不能为空"; _pause; return; }

    _ask "对端 WireGuard IP（如 10.10.0.1/32）" PEER_IP ""
    [[ -n "$PEER_IP" ]] || { warn "IP 不能为空"; _pause; return; }

    echo
    echo "  Endpoint 格式: 1.2.3.4:51820"
    echo "  无公网 IP 的被动节点直接回车跳过"
    _ask "对端公网 Endpoint（可选）" PEER_EP ""

    echo
    cmd_add_peer "$PEER_PK" "$PEER_IP" "$PEER_EP" || true
    _pause
}

# ── 6. 移除 Peer ─────────────────────────────────────────────
_menu_remove_peer() {
    _menu_header
    printf "  ${C_WARN}▶ 移除对端节点${C_RESET}\n\n"
    if [[ ! -f "$WG_CONF" ]]; then
        warn "配置文件不存在"; _pause; return
    fi

    _list_peers_inline
    echo

    _ask "要移除的 Peer 公钥（完整 Base64）" PEER_PK ""
    PEER_PK="$(tr -d '[:space:]' <<< "$PEER_PK")"
    [[ -n "$PEER_PK" ]] || { warn "公钥不能为空"; _pause; return; }

    warn "即将移除 Peer: ${PEER_PK:0:20}..."
    read -rp "  确认? [y/N] " C
    [[ "${C,,}" == "y" ]] || { info "已取消"; _pause; return; }
    echo

    if cmd_remove_peer "$PEER_PK"; then
        log "Peer 已成功移除"
    else
        warn "移除失败，请检查公钥是否正确"
    fi
    _pause
}

# ── 7. 列出 Peer ─────────────────────────────────────────────
_list_peers_inline() {
    [[ -f "$WG_CONF" ]] || { warn "配置文件不存在"; return; }

    local idx=0 in_peer=0
    local pk="" ips="" ep=""

    _flush_peer() {
        [[ -z "$pk" ]] && return
        (( idx++ )) || true
        printf "  [%d] %-44s\n      AllowedIPs : %s\n      Endpoint   : %s\n\n" \
            "$idx" "$pk" "$ips" "${ep:-（无）}"
    }

    while IFS= read -r raw; do
        local line="${raw#"${raw%%[![:space:]]*}"}"  # ltrim

        if [[ "$line" =~ ^\[Interface\] ]]; then
            in_peer=0
        elif [[ "$line" =~ ^\[Peer\] ]]; then
            _flush_peer
            in_peer=1; pk=""; ips=""; ep=""
        elif [[ $in_peer -eq 1 ]]; then
            if   [[ "$line" =~ ^PublicKey[[:space:]]*=[[:space:]]*(.*) ]];  then pk="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^AllowedIPs[[:space:]]*=[[:space:]]*(.*) ]]; then ips="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^Endpoint[[:space:]]*=[[:space:]]*(.*) ]];   then ep="${BASH_REMATCH[1]}"
            fi
        fi
    done < "$WG_CONF"
    _flush_peer

    [[ $idx -eq 0 ]] && info "暂无 Peer"
}

_menu_list_peers() {
    _menu_header
    printf "  ${C_WARN}▶ 当前所有 Peer${C_RESET}\n\n"
    _list_peers_inline
    _pause
}

# ── 9. 确认停止 ──────────────────────────────────────────────
_menu_confirm_down() {
    _menu_header
    printf "  ${C_WARN}▶ 停止 WireGuard${C_RESET}\n\n"
    warn "即将停止 ${WG_IFACE} 并禁用开机自启"
    read -rp "  确认? [y/N] " C
    if [[ "${C,,}" == "y" ]]; then
        echo
        cmd_down || true
    else
        info "已取消"
    fi
    _pause
}

# ── g. 新节点部署向导 ────────────────────────────────────────
_menu_wizard() {
    _menu_header
    printf "  ${C_WARN}▶ 新节点部署向导${C_RESET}\n\n"
    echo "  本向导将引导您在这台机器上完成 WireGuard 全互联初始化。"
    echo "  完成后请把本机公钥发给其他节点，并将其他节点公钥填入此处。"
    echo
    read -rp "  准备好? [y/N] " C
    [[ "${C,,}" == "y" ]] || { info "已取消"; _pause; return; }

    # step 1
    printf "\n  ${C_BOLD}── 步骤 1/4：安装 WireGuard ──${C_RESET}\n\n"
    cmd_install || { warn "安装失败，向导中止"; _pause; return; }

    # step 2
    printf "\n  ${C_BOLD}── 步骤 2/4：生成密钥对 ──${C_RESET}\n\n"
    cmd_genkey || { warn "密钥生成失败，向导中止"; _pause; return; }

    # step 3
    printf "\n  ${C_BOLD}── 步骤 3/4：本机公钥（请复制给其他节点）──${C_RESET}\n\n"
    local pk; pk=$(cat "$PUB_KEY_FILE" 2>/dev/null || echo "")
    if [[ -n "$pk" ]]; then
        echo "  ┌──────────────────────────────────────────────────────┐"
        printf "  │  %s  │\n" "$pk"
        echo "  └──────────────────────────────────────────────────────┘"
    fi
    echo
    read -rp "  已复制公钥，按 Enter 继续..." _

    # step 4
    printf "\n  ${C_BOLD}── 步骤 4/4：初始化接口 ──${C_RESET}\n\n"
    echo "  建议网段: 10.10.0.x/24（主服务器 .1，其余节点 .2 .3 ...）"
    echo
    _ask "本机 WireGuard IP（如 10.10.0.2）" MY_IP ""
    if [[ -z "$MY_IP" ]]; then
        warn "IP 不能为空，向导中止"; _pause; return
    fi
    cmd_init "$MY_IP" || { warn "初始化失败，向导中止"; _pause; return; }

    # 添加 Peer 循环
    printf "\n  ${C_BOLD}── 添加其他节点 Peer ──${C_RESET}\n"
    while true; do
        echo
        read -rp "  添加一个 Peer? [y/N] " ADD
        [[ "${ADD,,}" == "y" ]] || break

        _ask "对端公钥" P_PK ""
        _ask "对端 WireGuard IP（如 10.10.0.1/32）" P_IP ""
        _ask "对端公网 Endpoint（无则回车跳过）" P_EP ""

        if [[ -z "$P_PK" || -z "$P_IP" ]]; then
            warn "公钥和 IP 均不能为空，已跳过"; continue
        fi
        cmd_add_peer "$P_PK" "$P_IP" "$P_EP" || warn "添加失败，请稍后手动添加"
    done

    echo
    read -rp "  现在启动 WireGuard? [Y/n] " START
    if [[ "${START,,}" != "n" ]]; then
        cmd_up || warn "启动失败，请检查配置后手动执行 up"
    fi

    echo
    log "向导完成！可在主菜单选「查看状态」确认连通性。"
    _pause
}

# ═══════════════════════════════════════════════════════════
# 入口
# ═══════════════════════════════════════════════════════════
main() {
    if [[ $# -eq 0 ]]; then
        menu_main
        return
    fi

    local CMD="$1"; shift
    case "$CMD" in
        install)      cmd_install ;;
        genkey)       cmd_genkey ;;
        pubkey)       cmd_pubkey ;;
        init)         cmd_init "$@" ;;
        add-peer)     cmd_add_peer "$@" ;;
        remove-peer)  cmd_remove_peer "$@" ;;
        up)           cmd_up ;;
        down)         cmd_down ;;
        status)       cmd_status ;;
        help|--help|-h)
            sed -n '/^# ====/,/^# ===/{ /^#/{ s/^# \{0,2\}//; p } }' "$0" | head -30
            ;;
        *) error "未知子命令: ${CMD}，执行 help 查看用法" ;;
    esac
}

main "$@"
