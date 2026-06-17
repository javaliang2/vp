#!/usr/bin/env bash
# ============================================================
# wireguard-mesh.sh — WireGuard 全互联组网工具（小白交互菜单版）
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

# 标记是否为菜单模式，用于判断执行完是否需要暂停
IS_MENU_MODE=0

# ── 颜色输出 ────────────────────────────────────────────────
_c() { printf "\e[${1}m${2}\e[0m\n"; }
log()    { _c "32" "[OK]  $*"; }
info()   { _c "36" "[..] $*"; }
warn()   { _c "33" "[!!] $*"; }
error()  { _c "31" "[EE] $*"; exit 1; }
header() { echo; _c "1;34" "══ $* ══"; }

require_root() {
    [[ $EUID -eq 0 ]] || {
        warn "需要 root 权限执行此操作"
        [[ $IS_MENU_MODE -eq 1 ]] && return 1 || exit 1
    }
}

require_conf() {
    [[ -f "$WG_CONF" ]] || {
        warn "配置文件不存在: $WG_CONF，请先执行初始化(选项 4)"
        [[ $IS_MENU_MODE -eq 1 ]] && return 1 || exit 1
    }
}

pause() {
    if [[ $IS_MENU_MODE -eq 1 ]]; then
        echo
        read -rp "按回车键返回主菜单..."
    fi
}

# ── 核心功能实现 ────────────────────────────────────────────

cmd_install() {
    require_root || return
    header "安装 WireGuard"

    if command -v wg &>/dev/null; then
        log "WireGuard 已安装: $(wg --version)"
        return
    fi

    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "${ID:-}" in
            ubuntu|debian)
                apt-get update -qq
                apt-get install -y wireguard wireguard-tools
                ;;
            centos|rhel|rocky|almalinux)
                if command -v dnf &>/dev/null; then
                    dnf install -y epel-release
                    dnf install -y wireguard-tools
                else
                    yum install -y epel-release
                    yum install -y wireguard-tools
                fi
                ;;
            fedora)
                dnf install -y wireguard-tools
                ;;
            *)
                warn "暂不支持的系统类型: ${ID:-未知}，请手动安装 wireguard-tools"
                return
                ;;
        esac
    else
        warn "无法识别系统环境（缺失 /etc/os-release），请手动安装 wireguard-tools"
        return
    fi

    modprobe wireguard 2>/dev/null || info "wireguard 内核模块加载失败（容器环境可忽略）"
    log "WireGuard 安装成功: $(wg --version)"
}

cmd_genkey() {
    require_root || return
    header "生成密钥对"

    mkdir -p "$WG_KEY_DIR"
    chmod 700 "$WG_KEY_DIR"

    if [[ -f "$PRIV_KEY_FILE" ]]; then
        warn "密钥已存在: $PRIV_KEY_FILE"
        echo "当前公钥: $(cat "$PUB_KEY_FILE")"
        return
    fi

    wg genkey | tee "$PRIV_KEY_FILE" | wg pubkey > "$PUB_KEY_FILE"
    chmod 600 "$PRIV_KEY_FILE"

    log "私钥已保存"
    log "本机公钥: $(cat "$PUB_KEY_FILE")"
}

cmd_pubkey() {
    if [[ ! -f "$PUB_KEY_FILE" ]]; then
         warn "公钥不存在，请先生成密钥对(选项 2)"
         return
    fi
    header "本机公钥"
    cat "$PUB_KEY_FILE"
    echo
}

cmd_init() {
    require_root || return
    local MY_WG_IP="${1:-}"
    
    if [[ ! -f "$PRIV_KEY_FILE" ]]; then
        warn "私钥不存在，请先生成密钥对(选项 2)"
        return
    fi

    if [[ -z "$MY_WG_IP" ]]; then
        read -rp "请输入本机在 WireGuard 中的 IP (例如 10.10.0.1): " MY_WG_IP
    fi
    [[ -z "$MY_WG_IP" ]] && { warn "IP 不能为空"; return; }

    header "初始化 ${WG_IFACE} (${MY_WG_IP}/24)"

    if [[ -f "$WG_CONF" ]]; then
        warn "配置文件已存在: $WG_CONF"
        read -rp "是否覆盖已有的配置? [y/N]: " CONFIRM
        [[ "${CONFIRM,,}" == "y" ]] || { info "已取消覆盖"; return; }
        
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
EOF
    chmod 600 "$WG_CONF"

    log "配置已写入: $WG_CONF"
    info "提示：接下来可添加对端节点(选项 5)，然后启动网络(选项 7)"
}

cmd_add_peer() {
    require_root || return
    require_conf || return
    local PUB_KEY="${1:-}"
    local ALLOWED_IPS="${2:-}"
    local ENDPOINT="${3:-}"

    if [[ -z "$PUB_KEY" ]]; then
        read -rp "请输入对端 [公钥 (PublicKey)]: " PUB_KEY
    fi
    if [[ -z "$ALLOWED_IPS" ]]; then
        read -rp "请输入对端 [内网IP/掩码] (例如 10.10.0.2/32): " ALLOWED_IPS
    fi
    if [[ -z "$ENDPOINT" && -t 0 ]]; then
        read -rp "请输入对端 [公网 Endpoint] (可选, 格式 IP:端口, 纯入站请直接回车): " ENDPOINT
    fi

    [[ -z "$PUB_KEY" || -z "$ALLOWED_IPS" ]] && { warn "公钥和允许的内网 IP 不能为空"; return; }

    header "添加 Peer: ${ALLOWED_IPS}"

    if grep -q "^PublicKey *= *${PUB_KEY}$" "$WG_CONF" 2>/dev/null; then
        warn "该 Peer 已经存在于配置文件中: ${PUB_KEY:0:20}..."
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

    log "Peer 已成功追加到 ${WG_CONF}"

    if systemctl is-active --quiet "wg-quick@${WG_IFACE}"; then
        local CMD="wg set ${WG_IFACE} peer ${PUB_KEY} allowed-ips ${ALLOWED_IPS}"
        [[ -n "$ENDPOINT" ]] && CMD+=" endpoint ${ENDPOINT} persistent-keepalive 25"
        eval "$CMD"
        log "检测到网络正在运行，Peer 已热添加到当前的 ${WG_IFACE}"
    fi
}

cmd_remove_peer() {
    require_root || return
    require_conf || return
    local PUB_KEY="${1:-}"

    if [[ -z "$PUB_KEY" ]]; then
        read -rp "请输入要移除的 Peer [公钥]: " PUB_KEY
    fi
    [[ -z "$PUB_KEY" ]] && { warn "公钥不能为空"; return; }

    header "移除 Peer: ${PUB_KEY:0:20}..."

    if ! grep -q "$PUB_KEY" "$WG_CONF"; then
        warn "配置文件中未找到匹配该公钥的 Peer"
        return
    fi

    local TMP_CONF
    TMP_CONF=$(mktemp)
    awk -v key="$PUB_KEY" '
    BEGIN { block = "" }
    /^\[/ {
        if (block ~ "PublicKey") {
            if (block !~ key) printf "%s", block
        } else {
            printf "%s", block
        }
        block = $0 "\n"
        next
    }
    { block = block $0 "\n" }
    END {
        if (block ~ "PublicKey") {
            if (block !~ key) printf "%s", block
        } else {
            printf "%s", block
        }
    }
    ' "$WG_CONF" > "$TMP_CONF"

    mv "$TMP_CONF" "$WG_CONF"
    chmod 600 "$WG_CONF"
    log "已从配置文件中成功移除"

    if systemctl is-active --quiet "wg-quick@${WG_IFACE}"; then
        wg set "${WG_IFACE}" peer "$PUB_KEY" remove
        log "Peer 已从运行中的 ${WG_IFACE} 热移除"
    fi
}

cmd_up() {
    require_root || return
    require_conf || return
    header "启动 ${WG_IFACE}"
    systemctl enable --now "wg-quick@${WG_IFACE}"
    sleep 1
    log "${WG_IFACE} 已启动"
}

cmd_down() {
    require_root || return
    header "停止 ${WG_IFACE}"
    systemctl disable --now "wg-quick@${WG_IFACE}" || true
    log "${WG_IFACE} 已停止"
}

cmd_status() {
    header "WireGuard 状态"

    if ! systemctl is-active --quiet "wg-quick@${WG_IFACE}"; then
        warn "${WG_IFACE} 当前未运行"
        return 0
    fi

    wg show "${WG_IFACE}"
    echo ""

    header "Peer 连通性测试"
    local HAS_PEER=0
    while IFS= read -r line; do
        if [[ "$line" =~ ^allowed\ ips:\ +([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
            HAS_PEER=1
            local IP="${BASH_REMATCH[1]}"
            if ping -c1 -W2 "$IP" &>/dev/null; then
                log "✓ 对端 IP ${IP} -> 正常连通"
            else
                warn "✗ 对端 IP ${IP} -> 无法断定或不可达"
            fi
        fi
    done < <(wg show "${WG_IFACE}")
    
    [[ $HAS_PEER -eq 0 ]] && info "当前接口尚未添加任何 Peer"
}

# ── 交互式菜单 ──────────────────────────────────────────────
interactive_menu() {
    IS_MENU_MODE=1
    while true; do
        clear
        _c "1;32" "================================================="
        _c "1;32" "     WireGuard 全互联组网助手 (小白菜单版)     "
        _c "1;32" "================================================="
        echo -e " \e[36m1.\e[0m 安装 WireGuard 环境"
        echo -e " \e[36m2.\e[0m 生成本机密钥对"
        echo -e " \e[36m3.\e[0m 查看本机公钥"
        echo -e " \e[36m4.\e[0m 初始化本机节点 (配置本机 IP)"
        echo -e " \e[36m5.\e[0m 添加对端节点 (Add Peer)"
        echo -e " \e[36m6.\e[0m 移除对端节点 (Remove Peer)"
        echo -e " \e[36m7.\e[0m 启动 WireGuard"
        echo -e " \e[36m8.\e[0m 停止 WireGuard"
        echo -e " \e[36m9.\e[0m 查看运行状态与连通性"
        echo -e " \e[31m0.\e[0m 退出"
        _c "1;32" "================================================="
        
        read -rp "请输入对应的数字并回车 [0-9]: " choice
        
        case "$choice" in
            1) cmd_install ; pause ;;
            2) cmd_genkey  ; pause ;;
            3) cmd_pubkey  ; pause ;;
            4) cmd_init    ; pause ;;
            5) cmd_add_peer; pause ;;
            6) cmd_remove_peer; pause ;;
            7) cmd_up      ; pause ;;
            8) cmd_down    ; pause ;;
            9) cmd_status  ; pause ;;
            0) echo "感谢使用，再见！"; exit 0 ;;
            *) warn "无效的输入，请重新选择" ; sleep 1 ;;
        esac
    done
}

# ── 入口 ────────────────────────────────────────────────────
main() {
    # 如果没有传递任何参数，则进入交互式菜单
    if [[ $# -eq 0 ]]; then
        interactive_menu
    else
        # 否则走传统命令行模式
        local CMD="${1}"
        shift
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
            *) error "未知子命令: ${CMD}，直接运行脚本无参数可进入菜单" ;;
        esac
    fi
}

main "$@"
