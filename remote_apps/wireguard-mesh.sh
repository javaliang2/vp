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
    elif command -v dnf &>/dev/null; then
        dnf install -y wireguard-tools
    elif command -v yum &>/dev/null; then
        # RHEL/CentOS 8+
        yum install -y epel-release
        yum install -y wireguard-tools
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

    # FIX(Bug 3): 移除手动 PostUp/PostDown 路由规则。
    # wg-quick 会依据各 Peer 的 AllowedIPs 自动维护路由，手动添加 /24
    # 路由会与之冲突，在多网卡环境下可能劫持非 VPN 流量。
    cat > "$WG_CONF" <<EOF
[Interface]
Address    = ${MY_WG_IP}/24
PrivateKey = $(cat "$PRIV_KEY_FILE")
ListenPort = ${WG_PORT}
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

    # FIX(Bug 1): 原代码用 eval 拼接用户输入，存在命令注入风险。
    # 改用数组直接传参，彻底消除 eval。
    if systemctl is-active --quiet "wg-quick@${WG_IFACE}"; then
        local WG_ARGS=(
            set "${WG_IFACE}"
            peer "${PUB_KEY}"
            allowed-ips "${ALLOWED_IPS}"
        )
        if [[ -n "$ENDPOINT" ]]; then
            WG_ARGS+=(endpoint "${ENDPOINT}" persistent-keepalive 25)
        fi
        wg "${WG_ARGS[@]}"
        log "Peer 已热添加到运行中的 ${WG_IFACE}"
    fi
}

# ── remove-peer <公钥> ───────────────────────────────────────
cmd_remove_peer() {
    require_root
    require_conf
    local PUB_KEY="${1:-}"
    # 去除所有空白字符，避免复制时带入的换行、空格
    PUB_KEY="$(tr -d '[:space:]' <<< "$PUB_KEY")"
    [[ -z "$PUB_KEY" ]] && { warn "公钥为空"; return 1; }

    header "移除 Peer: ${PUB_KEY:0:20}..."

    # 先检查是否存在该 Peer
    if ! grep -qF "$PUB_KEY" "$WG_CONF"; then
        warn "配置文件中未找到该公钥: ${PUB_KEY:0:20}..."
        return 1
    fi

    # Python 精确删除，失败时仅警告而不退出脚本
    python3 - "$WG_CONF" "$PUB_KEY" <<'PY' || {
        warn "移除失败：Peer 可能不存在或配置格式异常"
        return 1
    }
import sys, re

conf_file = sys.argv[1]
target_key = sys.argv[2].strip()

with open(conf_file) as f:
    content = f.read()

blocks = re.split(r'(?=\[Peer\])', content)

def peer_matches(block, key):
    for line in block.splitlines():
        m = re.match(r'^\s*PublicKey\s*=\s*(\S+)', line)
        if m and m.group(1) == key:
            return True
    return False

filtered = [b for b in blocks if not peer_matches(b, target_key)]

if len(filtered) == len(blocks):
    print(f"未找到 Peer: {target_key[:20]}...", file=sys.stderr)
    sys.exit(1)

result = ''.join(filtered).rstrip('\n') + '\n'

with open(conf_file, 'w') as f:
    f.write(result)

print(f"已从配置文件移除 Peer: {target_key[:20]}...")
PY

    # 如果 wg0 已运行，热移除
    if systemctl is-active --quiet "wg-quick@${WG_IFACE}"; then
        wg set "${WG_IFACE}" peer "$PUB_KEY" remove 2>/dev/null || \
            warn "运行时移除失败（可能对端已不存在），配置文件已更新"
        log "Peer 已从运行中的 ${WG_IFACE} 移除"
    fi
}

# ── up ──────────────────────────────────────────────────────
cmd_up() {
    require_root
    require_conf
    header "启动 ${WG_IFACE}"

    # 清理残留接口，防止 "already exists" 报错
    if ip link show "${WG_IFACE}" &>/dev/null; then
        warn "${WG_IFACE} 接口已存在，先清理残留..."
        wg-quick down "${WG_IFACE}" 2>/dev/null || ip link delete "${WG_IFACE}" 2>/dev/null || true
        sleep 1
    fi

    systemctl enable --now "wg-quick@${WG_IFACE}"
    sleep 1
    wg show "${WG_IFACE}"
    log "${WG_IFACE} 已启动"
}

# ── down ────────────────────────────────────────────────────
cmd_down() {
    require_root
    header "停止 ${WG_IFACE}"
    systemctl disable --now "wg-quick@${WG_IFACE}" 2>/dev/null || true

    # 兜底：systemd 停止失败时直接删除接口
    if ip link show "${WG_IFACE}" &>/dev/null; then
        warn "接口仍存在，强制删除..."
        ip link delete "${WG_IFACE}" 2>/dev/null || true
    fi

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
    # FIX(Bug 2/代码清理): local 移到循环外，语义更清晰
    local IP
    while IFS= read -r line; do
        if [[ "$line" =~ ^allowed\ ips:\ +([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
            IP="${BASH_REMATCH[1]}"
            if ping -c1 -W2 "$IP" &>/dev/null; then
                log "✓ ${IP}"
            else
                warn "✗ ${IP} 不可达"
            fi
        fi
    done < <(wg show "${WG_IFACE}")
}

# ════════════════════════════════════════════════════════════
# 交互菜单
# ════════════════════════════════════════════════════════════

_pause() { echo; read -rp "  按 Enter 返回菜单..." _; }

_ask() {
    local PROMPT="$1" VAR="$2" DEFAULT="${3:-}"
    local HINT=""
    [[ -n "$DEFAULT" ]] && HINT=" [默认: ${DEFAULT}]"
    read -rp "  ${PROMPT}${HINT}: " "${VAR?}"
    if [[ -z "${!VAR}" && -n "$DEFAULT" ]]; then
        printf -v "$VAR" '%s' "$DEFAULT"
    fi
}

_menu_header() {
    clear
    echo
    _c "1;34" "╔══════════════════════════════════════════════════╗"
    _c "1;34" "║        wireguard-mesh  —  WireGuard 全互联       ║"
    _c "1;34" "╚══════════════════════════════════════════════════╝"
    echo
}

# ── 主菜单 ───────────────────────────────────────────────────
menu_main() {
    while true; do
        _menu_header

        local STATE_WG STATE_KEY STATE_CONF
        if [[ -f "$PUB_KEY_FILE" ]]; then
            STATE_KEY="$(cut -c1-16 "$PUB_KEY_FILE")..."
        else
            STATE_KEY="（未生成）"
        fi
        if [[ -f "$WG_CONF" ]]; then
            STATE_CONF="${WG_CONF}"
        else
            STATE_CONF="（未初始化）"
        fi
        if systemctl is-active --quiet "wg-quick@${WG_IFACE}" 2>/dev/null; then
            STATE_WG="运行中 ✓"
        else
            STATE_WG="已停止"
        fi

        printf "  本机公钥: \e[36m%s\e[0m\n" "$STATE_KEY"
        printf "  配置文件: \e[36m%s\e[0m\n" "$STATE_CONF"
        printf "  接口状态: \e[36m%s\e[0m\n" "$STATE_WG"
        echo
        echo "  ─────────────── 初始化向导 ───────────────"
        echo "  1)  安装 WireGuard"
        echo "  2)  生成本机密钥对"
        echo "  3)  显示本机公钥（分发给其他节点）"
        echo "  4)  初始化 wg0 接口"
        echo "  ─────────────── 节点管理 ─────────────────"
        echo "  5)  添加对端节点（Peer）"
        echo "  6)  移除对端节点"
        echo "  7)  列出所有 Peer"
        echo "  ─────────────── 服务控制 ─────────────────"
        echo "  8)  启动 WireGuard"
        echo "  9)  停止 WireGuard"
        echo "  10) 查看状态 + 连通性测试"
        echo "  ─────────────────────────────────────────"
        echo "  g)  新节点部署向导（一键引导）"
        echo "  0)  退出"
        echo
        read -rp "  请选择: " CHOICE
        case "$CHOICE" in
            1)  _menu_install    ;;
            2)  _menu_genkey     ;;
            3)  _menu_pubkey     ;;
            4)  _menu_init       ;;
            5)  _menu_add_peer   ;;
            6)  _menu_remove_peer;;
            7)  _menu_list_peers ;;
            8)  _menu_up         ;;
            9)  _menu_down       ;;
            10) _menu_status     ;;
            g|G) _menu_wizard    ;;
            0)  echo; info "再见！"; exit 0 ;;
            *)  warn "无效选项"; sleep 1 ;;
        esac
    done
}

# ── 1. 安装 ──────────────────────────────────────────────────
_menu_install() {
    _menu_header
    _c "1;33" "  ▶ 安装 WireGuard"
    echo
    cmd_install
    _pause
}

# ── 2. 生成密钥 ──────────────────────────────────────────────
_menu_genkey() {
    _menu_header
    _c "1;33" "  ▶ 生成密钥对"
    echo
    cmd_genkey
    _pause
}

# ── 3. 显示公钥 ──────────────────────────────────────────────
_menu_pubkey() {
    _menu_header
    _c "1;33" "  ▶ 本机公钥"
    echo
    if [[ ! -f "$PUB_KEY_FILE" ]]; then
        warn "公钥不存在，请先执行「生成密钥对」"
        _pause; return
    fi
    local PK; PK=$(cat "$PUB_KEY_FILE")
    echo "  ┌──────────────────────────────────────────────────┐"
    printf "  │  %s  │\n" "$PK"
    echo "  └──────────────────────────────────────────────────┘"
    echo
    info "将此公钥复制给其他节点，用于 add-peer"
    _pause
}

# ── 4. 初始化 ────────────────────────────────────────────────
_menu_init() {
    _menu_header
    _c "1;33" "  ▶ 初始化 wg0 接口"
    echo
    if [[ ! -f "$PRIV_KEY_FILE" ]]; then
        warn "私钥不存在，请先执行「生成密钥对」"
        _pause; return
    fi
    echo "  提示：每台机器使用不同的 WireGuard IP，例如："
    echo "    服务器: 10.10.0.1    节点2: 10.10.0.2    节点3: 10.10.0.3"
    echo
    _ask "本机 WireGuard IP（如 10.10.0.2）" WG_IP ""
    [[ -n "$WG_IP" ]] || { warn "IP 不能为空"; _pause; return; }
    echo
    cmd_init "$WG_IP"
    _pause
}

# ── 5. 添加 Peer ─────────────────────────────────────────────
_menu_add_peer() {
    _menu_header
    _c "1;33" "  ▶ 添加对端节点（Peer）"
    echo
    if [[ ! -f "$WG_CONF" ]]; then
        warn "配置文件不存在，请先执行「初始化 wg0 接口」"
        _pause; return
    fi

    echo "  需要填写对端节点的信息（从对端机器执行 pubkey/选项3 获取公钥）"
    echo
    _ask "对端公钥（Base64 字符串）" PEER_PK ""
    [[ -n "$PEER_PK" ]] || { warn "公钥不能为空"; _pause; return; }

    _ask "对端 WireGuard IP（如 10.10.0.1/32）" PEER_IP ""
    [[ -n "$PEER_IP" ]] || { warn "IP 不能为空"; _pause; return; }

    echo
    echo "  Endpoint 为对端的公网 IP 和端口，格式: 1.2.3.4:51820"
    echo "  如果对端无公网 IP（纯内网/被动节点），直接回车跳过"
    _ask "对端公网 Endpoint（可选）" PEER_EP ""

    echo
    cmd_add_peer "$PEER_PK" "$PEER_IP" "$PEER_EP"
    _pause
}

# ── 6. 移除 Peer ─────────────────────────────────────────────
_menu_remove_peer() {
    _menu_header
    _c "1;33" "  ▶ 移除对端节点"
    echo
    if [[ ! -f "$WG_CONF" ]]; then
        warn "配置文件不存在"; _pause; return
    fi

    _menu_list_peers_inline
    echo

    _ask "要移除的 Peer 公钥（完整 Base64）" PEER_PK ""
    # 去除所有空白字符，防止复制时带入空格或换行
    PEER_PK="$(tr -d '[:space:]' <<< "$PEER_PK")"
    [[ -n "$PEER_PK" ]] || { warn "公钥不能为空"; _pause; return; }

    warn "即将移除 Peer: ${PEER_PK:0:20}..."
    read -rp "  确认? [y/N] " C
    [[ "${C,,}" == "y" ]] || { info "已取消"; _pause; return; }
    echo

    # 调用删除函数，并用返回值给用户明确反馈
    if cmd_remove_peer "$PEER_PK"; then
        log "Peer 已成功移除"
    else
        warn "移除失败，请检查公钥是否正确"
    fi
    _pause
}

# ── 7. 列出 Peer（内联版，无 pause）────────────────────────
_menu_list_peers_inline() {
    if [[ ! -f "$WG_CONF" ]]; then
        warn "配置文件不存在"; return
    fi
    # FIX(Bug 4): 原代码 (( IDX++ )) 在 IDX=0 时返回值为 0（假），
    # 在 set -euo pipefail 下会直接退出脚本。改为 IDX=$(( IDX + 1 )) 或 (( ++IDX ))。
    # 使用 (( ++IDX )) 前置自增，初始值为 0 时结果为 1，返回值为真，安全。
    local IDX=0
    local PK="" IPS="" EP=""
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"  # ltrim
        if [[ "$line" == "[Peer]" ]]; then
            if [[ -n "$PK" ]]; then
                (( ++IDX ))
                printf "  [%d] %s\n      AllowedIPs: %s\n      Endpoint:   %s\n\n" \
                    "$IDX" "${PK:0:32}..." "$IPS" "${EP:-（无）}"
            fi
            PK=""; IPS=""; EP=""
        elif [[ "$line" =~ ^PublicKey[[:space:]]*=[[:space:]]*(.*) ]];  then PK="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^AllowedIPs[[:space:]]*=[[:space:]]*(.*) ]]; then IPS="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^Endpoint[[:space:]]*=[[:space:]]*(.*) ]];   then EP="${BASH_REMATCH[1]}"
        fi
    done < "$WG_CONF"
    # 最后一个 Peer
    if [[ -n "$PK" ]]; then
        (( ++IDX ))
        printf "  [%d] %s\n      AllowedIPs: %s\n      Endpoint:   %s\n\n" \
            "$IDX" "${PK:0:32}..." "$IPS" "${EP:-（无）}"
    fi
    [[ $IDX -eq 0 ]] && info "暂无 Peer"
}

# ── 7. 列出 Peer（菜单项） ───────────────────────────────────
_menu_list_peers() {
    _menu_header
    _c "1;33" "  ▶ 当前所有 Peer"
    echo
    _menu_list_peers_inline
    _pause
}

# ── 8. 启动 ──────────────────────────────────────────────────
_menu_up() {
    _menu_header
    _c "1;33" "  ▶ 启动 WireGuard"
    echo
    cmd_up
    _pause
}

# ── 9. 停止 ──────────────────────────────────────────────────
_menu_down() {
    _menu_header
    _c "1;33" "  ▶ 停止 WireGuard"
    echo
    warn "即将停止 ${WG_IFACE} 并禁用开机自启"
    read -rp "  确认? [y/N] " C
    [[ "${C,,}" == "y" ]] || { info "已取消"; _pause; return; }
    cmd_down
    _pause
}

# ── 10. 状态 ─────────────────────────────────────────────────
_menu_status() {
    _menu_header
    _c "1;33" "  ▶ 状态 + 连通性测试"
    echo
    cmd_status || true
    _pause
}

# ── g. 新节点部署向导 ────────────────────────────────────────
_menu_wizard() {
    _menu_header
    _c "1;33" "  ▶ 新节点部署向导"
    echo
    echo "  本向导将引导您在「这台机器」上完成 WireGuard 初始化。"
    echo "  完成后，您需要把本机公钥发给其他节点，并把其他节点的公钥填入此处。"
    echo
    read -rp "  准备好了吗? [y/N] " C
    [[ "${C,,}" == "y" ]] || { info "已取消"; _pause; return; }

    # 步骤 1：安装
    echo
    _c "1;36" "  ── 步骤 1/4：安装 WireGuard ──"
    cmd_install

    # 步骤 2：生成密钥
    echo
    _c "1;36" "  ── 步骤 2/4：生成密钥对 ──"
    cmd_genkey

    # 步骤 3：显示公钥
    echo
    _c "1;36" "  ── 步骤 3/4：本机公钥（请复制给其他节点）──"
    echo
    local PK; PK=$(cat "$PUB_KEY_FILE" 2>/dev/null || echo "")
    if [[ -n "$PK" ]]; then
        echo "  ┌──────────────────────────────────────────────────┐"
        printf "  │  %s  │\n" "$PK"
        echo "  └──────────────────────────────────────────────────┘"
    fi
    echo
    read -rp "  已复制公钥，按 Enter 继续..." _

    # 步骤 4：初始化接口
    echo
    _c "1;36" "  ── 步骤 4/4：初始化 wg0 接口 ──"
    echo
    echo "  常用网段规划示例：10.10.0.x/24"
    echo "  建议：主服务器用 .1，其余节点依次 .2 .3 ..."
    echo
    _ask "本机 WireGuard IP（如 10.10.0.2）" MY_IP ""
    [[ -n "$MY_IP" ]] || { warn "IP 不能为空"; _pause; return; }
    cmd_init "$MY_IP"

    # 添加 Peer 循环
    echo
    _c "1;36" "  ── 添加其他节点 Peer（可多次添加）──"
    while true; do
        echo
        read -rp "  添加一个 Peer? [y/N] " ADD
        [[ "${ADD,,}" == "y" ]] || break

        _ask "对端公钥" P_PK ""
        _ask "对端 WireGuard IP（如 10.10.0.1/32）" P_IP ""
        _ask "对端公网 Endpoint（无则回车跳过）" P_EP ""
        [[ -n "$P_PK" && -n "$P_IP" ]] || { warn "公钥和 IP 不能为空，跳过"; continue; }
        cmd_add_peer "$P_PK" "$P_IP" "$P_EP"
    done

    # 启动
    echo
    read -rp "  现在启动 WireGuard? [Y/n] " START
    if [[ "${START,,}" != "n" ]]; then
        cmd_up
    fi

    echo
    log "向导完成！可在主菜单选「查看状态」确认连通性。"
    _pause
}

# ── 入口 ────────────────────────────────────────────────────
main() {
    if [[ $# -eq 0 ]]; then
        menu_main
        return
    fi

    local CMD="$1"; shift

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
