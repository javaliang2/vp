#!/bin/bash
# ============================================================
#  cloudflare-firewall.sh — 只允许 Cloudflare + 指定内网段访问 80/443
#  自动检测 ufw / iptables，二选一使用；不触碰 22 端口和其他规则
#  用法:
#    sudo ./cloudflare-firewall.sh apply  [--allow-net CIDR ...]
#    sudo ./cloudflare-firewall.sh status
#    sudo ./cloudflare-firewall.sh remove
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[信息]${NC}  $*" 1>&2; }
success() { echo -e "${GREEN}[成功]${NC}  $*" 1>&2; }
warn()    { echo -e "${YELLOW}[警告]${NC}  $*" 1>&2; }
error()   { echo -e "${RED}[错误]${NC}  $*" 1>&2; }
die()     { error "$*"; exit 1; }

[[ $EUID -eq 0 ]] || die "请以 root 身份运行本脚本（sudo $0 ...）"

COMMENT_TAG="cf-fw"
CHAIN_V4="CF_HTTP"
CHAIN_V6="CF_HTTP6"
PORTS="80,443"

# ──────────────────────────────────────────────────────────
# 自动获取 WireGuard 接口 IPv4 网段（默认额外放行）
# ──────────────────────────────────────────────────────────
get_wg_net() {
    local ip
    ip=$(ip -4 addr show wg0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1)
    echo "${ip:-}"
}

fetch_cloudflare_ranges() {
    command -v curl >/dev/null 2>&1 || die "需要 curl，请先安装：apt install curl"
    info "正在从 Cloudflare 官方地址获取最新 IP 段..."
    CF_IPV4=$(curl -fsSL --max-time 10 "https://www.cloudflare.com/ips-v4") \
        || die "无法获取 Cloudflare IPv4 列表，请检查网络"
    CF_IPV6=$(curl -fsSL --max-time 10 "https://www.cloudflare.com/ips-v6") \
        || die "无法获取 Cloudflare IPv6 列表，请检查网络"
    [[ -z "$CF_IPV4" || -z "$CF_IPV6" ]] && die "获取到的 Cloudflare IP 列表为空"
}

detect_backend() {
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi "^Status: active"; then
        BACKEND="ufw"
    elif command -v iptables >/dev/null 2>&1; then
        BACKEND="iptables"
    else
        die "既没有启用的 ufw，也没有 iptables，无法配置"
    fi
    info "使用后端: $BACKEND"
}

# ──────────────────────────────────────────────────────────
# ufw 实现
# ──────────────────────────────────────────────────────────
ufw_apply() {
    local -a nets=("$@")
    info "清理旧的 ${COMMENT_TAG} 规则..."
    ufw_remove_quiet

    local net
    for net in "${nets[@]}"; do
        ufw allow proto tcp from "$net" to any port "$PORTS" comment "$COMMENT_TAG" >/dev/null
    done
    while IFS= read -r net; do
        [[ -z "$net" ]] && continue
        ufw allow proto tcp from "$net" to any port "$PORTS" comment "$COMMENT_TAG" >/dev/null
    done <<< "$CF_IPV4"
    while IFS= read -r net; do
        [[ -z "$net" ]] && continue
        ufw allow proto tcp from "$net" to any port "$PORTS" comment "$COMMENT_TAG" >/dev/null
    done <<< "$CF_IPV6"

    # 最后加一条兜底 deny，必须排在所有 allow 规则之后
    ufw deny proto tcp to any port "$PORTS" comment "$COMMENT_TAG" >/dev/null

    success "ufw 规则已应用（80/443 仅允许 Cloudflare + 指定内网段）"
    ufw reload >/dev/null
}

ufw_remove_quiet() {
    # 反向删除，避免编号在删除过程中前移导致漏删
    local nums
    nums=$(ufw status numbered | grep "$COMMENT_TAG" | grep -oP '^\[\s*\K[0-9]+' | sort -rn)
    local n
    for n in $nums; do
        yes | ufw delete "$n" >/dev/null 2>&1 || true
    done
}

ufw_remove() {
    ufw_remove_quiet
    ufw reload >/dev/null
    success "已移除所有 ${COMMENT_TAG} 相关 ufw 规则"
}

ufw_status() {
    ufw status numbered | grep "$COMMENT_TAG" || info "没有找到 ${COMMENT_TAG} 相关规则"
}

# ──────────────────────────────────────────────────────────
# iptables / ip6tables 实现
# ──────────────────────────────────────────────────────────
iptables_apply() {
    local -a nets=("$@")

    iptables -N "$CHAIN_V4" 2>/dev/null || iptables -F "$CHAIN_V4"
    ip6tables -N "$CHAIN_V6" 2>/dev/null || ip6tables -F "$CHAIN_V6"

    # 确保 INPUT 里只有一条跳转，避免重复插入
    iptables -D INPUT -p tcp -m multiport --dports "$PORTS" -j "$CHAIN_V4" 2>/dev/null || true
    ip6tables -D INPUT -p tcp -m multiport --dports "$PORTS" -j "$CHAIN_V6" 2>/dev/null || true
    iptables -I INPUT -p tcp -m multiport --dports "$PORTS" -j "$CHAIN_V4"
    ip6tables -I INPUT -p tcp -m multiport --dports "$PORTS" -j "$CHAIN_V6"

    local net
    for net in "${nets[@]}"; do
        if [[ "$net" == *:* ]]; then
            ip6tables -A "$CHAIN_V6" -s "$net" -j ACCEPT
        else
            iptables -A "$CHAIN_V4" -s "$net" -j ACCEPT
        fi
    done
    while IFS= read -r net; do
        [[ -z "$net" ]] && continue
        iptables -A "$CHAIN_V4" -s "$net" -j ACCEPT
    done <<< "$CF_IPV4"
    while IFS= read -r net; do
        [[ -z "$net" ]] && continue
        ip6tables -A "$CHAIN_V6" -s "$net" -j ACCEPT
    done <<< "$CF_IPV6"

    iptables -A "$CHAIN_V4" -j DROP
    ip6tables -A "$CHAIN_V6" -j DROP

    success "iptables/ip6tables 规则已应用（80/443 仅允许 Cloudflare + 指定内网段）"
    warn "规则重启后会丢失，请安装 iptables-persistent 并执行:"
    warn "  apt install iptables-persistent && netfilter-persistent save"
}

iptables_remove() {
    iptables -D INPUT -p tcp -m multiport --dports "$PORTS" -j "$CHAIN_V4" 2>/dev/null || true
    ip6tables -D INPUT -p tcp -m multiport --dports "$PORTS" -j "$CHAIN_V6" 2>/dev/null || true
    iptables -F "$CHAIN_V4" 2>/dev/null || true
    ip6tables -F "$CHAIN_V6" 2>/dev/null || true
    iptables -X "$CHAIN_V4" 2>/dev/null || true
    ip6tables -X "$CHAIN_V6" 2>/dev/null || true
    success "已移除 ${CHAIN_V4}/${CHAIN_V6} 相关 iptables/ip6tables 规则"
    warn "如果之前执行过 netfilter-persistent save，记得重新 save 一次以固化本次移除"
}

iptables_status() {
    echo -e "${BOLD}--- IPv4 (${CHAIN_V4}) ---${NC}"
    iptables -L "$CHAIN_V4" -n --line-numbers 2>/dev/null || info "链 ${CHAIN_V4} 不存在"
    echo -e "${BOLD}--- IPv6 (${CHAIN_V6}) ---${NC}"
    ip6tables -L "$CHAIN_V6" -n --line-numbers 2>/dev/null || info "链 ${CHAIN_V6} 不存在"
}

# ──────────────────────────────────────────────────────────
# 主流程
# ──────────────────────────────────────────────────────────
usage() {
    cat <<EOF
用法:
  sudo $0 apply  [--allow-net CIDR ...]   # 应用规则，可多次指定额外放行网段
  sudo $0 status                          # 查看当前规则
  sudo $0 remove                          # 移除全部相关规则
EOF
}

main() {
    local action="${1:-}"
    [[ -z "$action" ]] && { usage; exit 1; }
    shift || true

    case "$action" in
        apply)
            local -a extra_nets=()
            local wg_net
            wg_net=$(get_wg_net)
            [[ -n "$wg_net" ]] && extra_nets+=("$wg_net") && info "检测到 WireGuard 网段: $wg_net（自动放行）"

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --allow-net)
                        [[ -n "${2:-}" ]] || die "--allow-net 需要跟一个 CIDR"
                        extra_nets+=("$2"); shift 2 ;;
                    *) die "未知参数: $1" ;;
                esac
            done

            warn "本操作只影响 80/443 端口，不会改动 22(SSH) 或其他现有规则。"
            warn "应用后如果发现站点无法访问，请立即执行: sudo $0 remove"

            fetch_cloudflare_ranges
            detect_backend
            if [[ "$BACKEND" == "ufw" ]]; then
                ufw_apply "${extra_nets[@]}"
            else
                iptables_apply "${extra_nets[@]}"
            fi
            ;;
        status)
            detect_backend
            [[ "$BACKEND" == "ufw" ]] && ufw_status || iptables_status
            ;;
        remove)
            detect_backend
            [[ "$BACKEND" == "ufw" ]] && ufw_remove || iptables_remove
            ;;
        *)
            usage; exit 1 ;;
    esac
}

main "$@"
