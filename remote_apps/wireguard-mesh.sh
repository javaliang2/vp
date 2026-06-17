#!/usr/bin/env bash
# ============================================================
# wireguard-mesh.sh — WireGuard 全互联组网
#
# 用法：
#   bash wireguard-mesh.sh <子命令> [参数...]
#
# 子命令：
#   install               安装 WireGuard
#   genkey                生成本机密钥对
#   init <WG_IP>          初始化 wg0 接口（仅 Interface 段）
#   add-peer <公钥> <允许IP/掩码> [公网Endpoint]
#             添加一个 Peer（无 Endpoint = 纯入站节点）
#   up                    启动 wg0
#   down                  停止 wg0
#   status                显示接口状态 + 各 Peer 连通性
#   pubkey                打印本机公钥
#   remove-peer <公钥>    移除一个 Peer
#
# 典型部署顺序（每台机器）：
#   1. bash wireguard-mesh.sh install
#   2. bash wireguard-mesh.sh genkey
#   3. bash wireguard-mesh.sh pubkey   ← 收集所有机器公钥
#   4. bash wireguard-mesh.sh init 10.10.0.2
#   5. bash wireguard-mesh.sh add-peer <其他机器公钥> <WG_IP/32> [公网IP:51820]
#      （重复第 5 步添加所有 peer）
#   6. bash wireguard-mesh.sh up
#   7. bash wireguard-mesh.sh status
# ============================================================
set -euo pipefail

# ── 常量 ────────────────────────────────────────────────────
WG_IFACE="${WG_IFACE:-wg0}"
WG_PORT="${WG_PORT:-51820}"
WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/${WG_IFACE}.conf"
WG_KEY_DIR="${WG_DIR}/keys"
PRIV_KEY_FILE="${WG_KEY_DIR}/privatekey"
PUB_KEY_FILE="${WG_KEY_DIR}/publickey"

# ── 颜色输出 ────────────────────────────────────────────────
_c() { printf "\e[${1}m${2}\e[0m\n"; }
log()    { _c "32" "[OK]  $*"; }
info()   { _c "36" "[..] $*"; }
warn()   { _c "33" "[!!] $*"; }
error()  { _c "31" "[EE] $*"; exit 1; }
header() { echo; _c "1;34" "══ $* ══"; }

require_root() {
    [[ $EUID -eq 0 ]] || error "需要 root 权限，请用 sudo 执行"
}

require_conf() {
    [[ -f "$WG_CONF" ]] || error "配置文件不存在: $WG_CONF，请先执行 init"
}

# ── install ─────────────────────────────────────────────────
cmd_install() {
    require_root
    header "安装 WireGuard"

    if command -v wg &>/dev/null; then
        log "WireGuard 已安装: $(wg --version)"
        return
    fi

    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y wireguard wireguard-tools
    elif command -v yum &>/dev/null; then
        # RHEL/CentOS 8+
        yum install -y epel-release
        yum install -y wireguard-tools
    elif command -v dnf &>/dev/null; then
        dnf install -y wireguard-tools
    else
        error "不支持的包管理器，请手动安装 wireguard-tools"
    fi

    # 加载内核模块
    modprobe wireguard 2>/dev/null || \
        warn "wireguard 内核模块加载失败（容器环境可忽略）"

    log "WireGuard 安装完成: $(wg --version)"
}

# ── genkey ──────────────────────────────────────────────────
cmd_genkey() {
    require_root
    header "生成密钥对"

    mkdir -p "$WG_KEY_DIR"
    chmod 700 "$WG_KEY_DIR"

    if [[ -f "$PRIV_KEY_FILE" ]]; then
        warn "密钥已存在: $PRIV_KEY_FILE"
        warn "如需重新生成请先删除旧密钥（会导致已有 Peer 失效）"
        echo "当前公钥: $(cat "$PUB_KEY_FILE")"
        return
    fi

    wg genkey | tee "$PRIV_KEY_FILE" | wg pubkey > "$PUB_KEY_FILE"
    chmod 600 "$PRIV_KEY_FILE"

    log "私钥: $PRIV_KEY_FILE"
    log "公钥: $(cat "$PUB_KEY_FILE")"
}

# ── pubkey ──────────────────────────────────────────────────
cmd_pubkey() {
    [[ -f "$PUB_KEY_FILE" ]] || error "公钥不存在，请先执行 genkey"
    cat "$PUB_KEY_FILE"
}

# ── init <WG_IP> ────────────────────────────────────────────
cmd_init() {
    require_root
    local MY_WG_IP="${1:?用法: init <WG_IP>  例: init 10.10.0.2}"
    [[ -f "$PRIV_KEY_FILE" ]] || error "私钥不存在，请先执行 genkey"

    header "初始化 ${WG_IFACE} (${MY_WG_IP}/24)"

    if [[ -f "$WG_CONF" ]]; then
        warn "配置文件已存在: $WG_CONF"
        read -rp "覆盖? [y/N] " CONFIRM
        [[ "${CONFIRM,,}" == "y" ]] || { info "已取消"; return; }
        # 先停止再覆盖
        systemctl is-active --quiet "wg-quick@${WG_IFACE}" && \
            systemctl stop "wg-quick@${WG_IFACE}" || true
    fi

    mkdir -p "$WG_DIR"
    chmod 700 "$WG_DIR"

    cat > "$WG_CONF" <<EOF
[Interface]
Address    = ${MY_WG_IP}/24
PrivateKey = $(cat "$PRIV_KEY_FILE")
ListenPort = ${WG_PORT}
# 启动/停止时维护路由
PostUp   = ip route add ${MY_WG_IP%.*}.0/24 dev ${WG_IFACE} 2>/dev/null || true
PostDown = ip route del ${MY_WG_IP%.*}.0/24 dev ${WG_IFACE} 2>/dev/null || true
EOF
    chmod 600 "$WG_CONF"

    log "配置已写入: $WG_CONF"
    info "接下来用 add-peer 添加对端节点，然后执行 up"
}

# ── add-peer <公钥> <允许IP> [Endpoint] ─────────────────────
cmd_add_peer() {
    require_root
    require_conf
    local PUB_KEY="${1:?用法: add-peer <公钥> <WG_IP/32> [公网IP:PORT]}"
    local ALLOWED_IPS="${2:?}"
    local ENDPOINT="${3:-}"

    header "添加 Peer: ${ALLOWED_IPS}"

    # 检查是否已存在
    if grep -q "^PublicKey *= *${PUB_KEY}$" "$WG_CONF" 2>/dev/null; then
        warn "Peer 已存在: ${PUB_KEY:0:20}..."
        return
    fi

    {
        echo ""
        echo "[Peer]"
        echo "PublicKey  = ${PUB_KEY}"
        echo "AllowedIPs = ${ALLOWED_IPS}"
        if [[ -n "$ENDPOINT" ]]; then
            echo "Endpoint            = ${ENDPOINT}"
            echo "PersistentKeepalive = 25"
        fi
    } >> "$WG_CONF"

    log "Peer 已追加到 ${WG_CONF}"

    # 如果 wg0 已运行，热添加（无需重启）
    if systemctl is-active --quiet "wg-quick@${WG_IFACE}"; then
        local CMD="wg set ${WG_IFACE} peer ${PUB_KEY} allowed-ips ${ALLOWED_IPS}"
        [[ -n "$ENDPOINT" ]] && CMD+=" endpoint ${ENDPOINT} persistent-keepalive 25"
        eval "$CMD"
        log "Peer 已热添加到运行中的 ${WG_IFACE}"
    fi
}

# ── remove-peer <公钥> ───────────────────────────────────────
cmd_remove_peer() {
    require_root
    require_conf
    local PUB_KEY="${1:?用法: remove-peer <公钥>}"

    header "移除 Peer: ${PUB_KEY:0:20}..."

    # 从配置文件移除对应 [Peer] 块
    python3 - "$WG_CONF" "$PUB_KEY" <<'PY'
import sys, re

conf_file = sys.argv[1]
target_key = sys.argv[2]

with open(conf_file) as f:
    content = f.read()

# 按 [Peer] 块分割，过滤掉匹配的
blocks = re.split(r'(?=\[Peer\])', content)
filtered = [b for b in blocks if target_key not in b]
result = ''.join(filtered).rstrip('\n') + '\n'

with open(conf_file, 'w') as f:
    f.write(result)

print(f"已从配置文件移除 Peer: {target_key[:20]}...")
PY

    # 如果 wg0 已运行，热移除
    if systemctl is-active --quiet "wg-quick@${WG_IFACE}"; then
        wg set "${WG_IFACE}" peer "$PUB_KEY" remove
        log "Peer 已从运行中的 ${WG_IFACE} 移除"
    fi
}

# ── up ──────────────────────────────────────────────────────
cmd_up() {
    require_root
    require_conf
    header "启动 ${WG_IFACE}"

    systemctl enable --now "wg-quick@${WG_IFACE}"
    sleep 1
    wg show "${WG_IFACE}"
    log "${WG_IFACE} 已启动"
}

# ── down ────────────────────────────────────────────────────
cmd_down() {
    require_root
    header "停止 ${WG_IFACE}"
    systemctl disable --now "wg-quick@${WG_IFACE}" || true
    log "${WG_IFACE} 已停止"
}

# ── status ──────────────────────────────────────────────────
cmd_status() {
    header "WireGuard 状态"

    if ! systemctl is-active --quiet "wg-quick@${WG_IFACE}"; then
        warn "${WG_IFACE} 未运行"
        return 1
    fi

    wg show "${WG_IFACE}"
    echo ""

    # ping 每个 Peer 的 AllowedIPs 第一个地址
    header "Peer 连通性"
    while IFS= read -r line; do
        if [[ "$line" =~ ^allowed\ ips:\ +([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
            local IP="${BASH_REMATCH[1]}"
            if ping -c1 -W2 "$IP" &>/dev/null; then
                log "✓ ${IP}"
            else
                warn "✗ ${IP} 不可达"
            fi
        fi
    done < <(wg show "${WG_IFACE}")
}

# ── 入口 ────────────────────────────────────────────────────
main() {
    local CMD="${1:-help}"
    shift || true

    case "$CMD" in
        install)     cmd_install ;;
        genkey)      cmd_genkey ;;
        pubkey)      cmd_pubkey ;;
        init)        cmd_init "$@" ;;
        add-peer)    cmd_add_peer "$@" ;;
        remove-peer) cmd_remove_peer "$@" ;;
        up)          cmd_up ;;
        down)        cmd_down ;;
        status)      cmd_status ;;
        help|--help|-h)
            grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,2\}//'
            ;;
        *) error "未知子命令: ${CMD}，执行 help 查看用法" ;;
    esac
}

main "$@"
