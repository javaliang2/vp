#!/bin/bash
# ============================================================
#  nginx-harden.sh — Nginx 全局基础加固 + fail2ban 联动 v4.0
#  - 仅做全局、对各站点无副作用的基础加固
#  - CSP / HTTP方法限制 / 限流 等站点相关项已移除，
#    后续按站点(WordPress/AList/图床等)单独处理
# ============================================================
set -euo pipefail
umask 022

# ── 全局配置 ──
NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx}"
CONF_D_DIR="${NGINX_CONF_DIR}/conf.d"
SNIPPETS_DIR="${NGINX_CONF_DIR}/snippets"
BACKUP_DIR="/var/backups/nginx-harden"
LOG_FILE="/var/log/nginx-harden.log"
BLOCKED_LOG="/var/log/nginx/blocked.log"          # ★ 统一阻断日志（按站点手动接入）
TIMESTAMP=$(date +'%Y-%m-%d %H:%M:%S')
BACKUP_FILE="${BACKUP_DIR}/nginx-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
FAIL2BAN_FILTER="/etc/fail2ban/filter.d/nginx-harden.conf"
FAIL2BAN_JAIL="/etc/fail2ban/jail.d/nginx-harden.conf"

# ── 颜色与日志 ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

_log() {
    local msg="$*"
    echo -e "${msg}" 1>&2
    sed -r 's/\x1b\[[0-9;]*m//g' <<< "$msg" >> "$LOG_FILE" 2>/dev/null || true
}
info()    { _log "${CYAN}[信息]${NC}  $*"; }
success() { _log "${GREEN}[成功]${NC}  $*"; }
warn()    { _log "${YELLOW}[警告]${NC}  $*"; }
error()   { _log "${RED}[错误]${NC}  $*"; }
die()     { error "$*"; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || die "请以 root 身份运行（sudo $0）"; }
safe_read() { read -r "$@" || true; }
confirm() {
    local _ans
    safe_read -r -p "${YELLOW}$1 [y/N]${NC} " _ans
    [[ ${_ans,,} == "y" ]]
}

init_env() {
    mkdir -p "$CONF_D_DIR" "$SNIPPETS_DIR" "$BACKUP_DIR" "$(dirname "$LOG_FILE")" "$(dirname "$BLOCKED_LOG")"
    command -v nginx &>/dev/null || die "未检测到 Nginx，请先安装"
    touch "$BLOCKED_LOG"
    chmod 640 "$BLOCKED_LOG"
    # 确保 nginx 配置包含 conf.d
    if ! nginx -T 2>/dev/null | grep -q 'include.*conf\.d/\*\.conf'; then
        warn "主配置可能未包含 ${CONF_D_DIR}，请确认 nginx.conf 中存在 'include conf.d/*.conf;'"
    fi
}

backup_configs() {
    info "备份整个 Nginx 配置目录..."
    tar -czf "${BACKUP_FILE}" -C / etc/nginx 2>/dev/null || die "备份失败"
    success "备份完成 -> ${BACKUP_FILE}"
}

restore_backup() {
    [[ -f "${BACKUP_FILE}" ]] || die "未找到备份文件"
    warn "正在回滚配置..."
    tar -xzf "${BACKUP_FILE}" -C /
    success "已回滚"
    nginx -t 1>&2 && systemctl reload nginx && success "回滚后重载成功" || warn "回滚后仍异常，请手动检查"
}

safe_reload() {
    if nginx -t 1>&2; then
        systemctl reload nginx
        success "Nginx 已重载"
        return 0
    else
        error "配置语法错误！"
        confirm "是否立即回滚到备份？" && { restore_backup; return 1; }
        die "语法错误且未回滚，请手动修复"
    fi
}

# ── 全局基础加固模块（对所有站点安全、无业务副作用） ──

harden_server_tokens() {
    cat > "${CONF_D_DIR}/90-security-tokens.conf" <<'EOF'
server_tokens off;
EOF
    success "版本隐藏 -> ${CONF_D_DIR}/90-security-tokens.conf"
}

harden_security_headers() {
    cat > "${CONF_D_DIR}/91-security-headers.conf" <<'EOF'
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
EOF
    success "安全响应头 -> ${CONF_D_DIR}/91-security-headers.conf"
    info "注意：若各站点 server/location 块自行定义了 add_header，会覆盖此处的值（nginx 的 add_header 不会跨层级叠加），请按需检查。"
}

harden_permissions_policy() {
    local conf="${CONF_D_DIR}/94-permissions-policy.conf"
    if confirm "启用 Permissions-Policy（禁用摄像头/麦克风/地理位置等，对各站点基本无副作用）？"; then
        echo 'add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), interest-cohort=()" always;' > "$conf"
        success "Permissions-Policy -> $conf"
    else
        info "跳过 Permissions-Policy"
    fi
}

harden_buffers_timeouts() {
    local conf="${CONF_D_DIR}/92-security-buffers.conf"
    while true; do
        safe_read -r -p "全局最大上传限制 (如 50M, 0不限) [默认50M，各站点可在自己的 server/location 块用 client_max_body_size 覆盖]: " max_body
        [[ -z "$max_body" ]] && max_body="50M"
        [[ $max_body =~ ^(0|[1-9][0-9]*[kKmMgG]?)$ ]] && break
        warn "格式无效，请重试"
    done
    cat > "$conf" <<EOF
client_body_buffer_size      128k;
client_header_buffer_size    1k;
large_client_header_buffers  4 8k;
client_max_body_size         ${max_body};
client_body_timeout   10;
client_header_timeout 10;
keepalive_timeout     15;
send_timeout          10;
EOF
    success "缓冲区与超时 -> $conf"
    info "提示：单个站点如需更大/更小的上传限制（如图床/AList），可在该站点 server 块内单独写 client_max_body_size 覆盖此全局值。"
}

harden_sensitive_files() {
    local conf="${SNIPPETS_DIR}/secure-files.conf"
    cat > "$conf" <<'EOF'
# 屏蔽隐藏文件及常见敏感后缀，阻断事件记录到统一日志
location ~ /\.(?!well-known\/) {
    deny all;
    access_log /var/log/nginx/blocked.log combined if=$blocked;
    log_not_found off;
}
location ~* (?:\.(?:bak|config|sql|fla|psd|ini|log|sh|inc|swp|dist)|~)$ {
    deny all;
    access_log /var/log/nginx/blocked.log combined if=$blocked;
    log_not_found off;
}
EOF
    success "敏感文件屏蔽 snippet 已生成 -> $conf"
    warn "此 snippet 不会自动注入到各站点，请按需手动在 sites-enabled 下对应站点的 server 块中添加："
    echo "    include snippets/secure-files.conf;"
}

# ── fail2ban 集成 ──
install_fail2ban() {
    if command -v fail2ban-server &>/dev/null; then
        info "fail2ban 已安装"
        return 0
    fi
    info "正在安装 fail2ban ..."
    if command -v apt &>/dev/null; then
        apt update && apt install -y fail2ban
    elif command -v yum &>/dev/null; then
        yum install -y epel-release && yum install -y fail2ban
    elif command -v dnf &>/dev/null; then
        dnf install -y fail2ban
    else
        die "无法自动安装 fail2ban，请手动安装"
    fi
    success "fail2ban 安装完成"
}

configure_fail2ban() {
    install_fail2ban

    # 过滤器：仅匹配统一阻断日志中已被标记为 403/405/503 的请求
    cat > "${FAIL2BAN_FILTER}" <<'EOF'
[Definition]
failregex = ^<HOST> .* "(GET|POST|HEAD|PUT|DELETE|MKCOL|PROPFIND|OPTIONS).*" (403|405|503) .*$
ignoreregex =
EOF

    # jail 配置
    cat > "${FAIL2BAN_JAIL}" <<EOF
[nginx-harden]
enabled = true
port    = http,https
filter  = nginx-harden
logpath = ${BLOCKED_LOG}
maxretry = 3
findtime = 60
bantime  = 3600
EOF

    systemctl enable fail2ban

    # 优先 reload，避免影响其他已存在的 jail 的当前 ban 状态
    if systemctl is-active --quiet fail2ban; then
        systemctl reload fail2ban || systemctl restart fail2ban
    else
        systemctl restart fail2ban
    fi
    success "fail2ban 联动规则已部署，监狱: nginx-harden"
    warn "blocked.log 当前只有在各站点手动 include secure-files.conf（及类似 access_log if=\$blocked 的规则）后才会产生数据，此前该 jail 不会触发。"
}

ensure_blocked_map() {
    # 定义 $blocked 条件变量（http 级别，覆盖写入避免重复定义）
    cat > "${CONF_D_DIR}/99-blocked-log.conf" <<'EOF'
# 为阻断日志定义条件变量（默认开启）
map $status $blocked {
    default 0;
    403 1;
    405 1;
    503 1;
}
EOF
    success "阻断日志条件变量 -> ${CONF_D_DIR}/99-blocked-log.conf"
}

# ── 一键全局基础加固 ──
apply_all_hardening() {
    backup_configs
    harden_server_tokens
    harden_security_headers
    harden_permissions_policy
    harden_buffers_timeouts
    harden_sensitive_files
    ensure_blocked_map
    configure_fail2ban

    safe_reload
    success "全局基础加固 + fail2ban 联动完成！"
    echo ""
    info "以下为站点相关项，本次未处理，留待按站点(WordPress/AList/图床等)单独配置："
    echo "    - Content-Security-Policy (CSP)"
    echo "    - HTTP 请求方法限制 (GET/HEAD/POST 严格模式 vs WebDAV 兼容)"
    echo "    - 请求/连接限流 (limit_req / limit_conn)"
    echo "    - secure-files.conf 的 include（屏蔽 .git/.env/.bak 等）"
}

# 撤销
revert_hardening() {
    confirm "移除全局基础加固配置并恢复备份？" || return
    rm -f "${CONF_D_DIR}/90-security-tokens.conf" \
          "${CONF_D_DIR}/91-security-headers.conf" \
          "${CONF_D_DIR}/92-security-buffers.conf" \
          "${CONF_D_DIR}/94-permissions-policy.conf" \
          "${CONF_D_DIR}/99-blocked-log.conf" \
          "${SNIPPETS_DIR}/secure-files.conf"
    rm -f "${FAIL2BAN_FILTER}" "${FAIL2BAN_JAIL}"
    if command -v fail2ban-server &>/dev/null && systemctl is-active --quiet fail2ban; then
        systemctl reload fail2ban || systemctl restart fail2ban
        info "已移除 nginx-harden 规则，fail2ban 已重新加载（其他 jail 不受影响）"
    else
        info "已移除 nginx-harden 规则（fail2ban 未运行，无需重载）"
    fi
    local latest
    latest=$(ls -1t "${BACKUP_DIR}"/nginx-backup-*.tar.gz 2>/dev/null | head -1)
    if [[ -f "$latest" ]] && confirm "恢复备份 ${latest##*/}？"; then
        tar -xzf "$latest" -C /
        success "已恢复"
    fi
    safe_reload || true

    if [[ -f "${SNIPPETS_DIR}/secure-files.conf.removed-notice" ]]; then
        :
    fi
    warn "若曾手动在某些站点 server 块中 include secure-files.conf，该 include 行不会自动移除，请手动检查对应站点的 conf 文件，否则 reload 可能因找不到该文件而失败。"
}

# ── 命令行参数 ──
CMD="menu"
DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--all) CMD="all"; shift ;;
        -f|--fail2ban) CMD="fail2ban"; shift ;;
        -r|--revert) CMD="revert"; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help)
            echo "用法: $0 [-a 全局基础加固 | -f 仅部署fail2ban联动 | -r 撤销 | --dry-run 预览]"
            exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
done

# 菜单
interactive_menu() {
    while true; do
        clear
        echo -e "${BOLD}${GREEN}"
        echo "  ╔════════════════════════════════════════════════╗"
        echo "  ║     Nginx 全局基础加固 + fail2ban v4.0        ║"
        echo "  ║     (CSP/方法限制/限流请按站点单独处理)        ║"
        echo "  ╚════════════════════════════════════════════════╝"
        echo -e "${NC}"
        echo "  1) 一键全局基础加固 (推荐)"
        echo "  2) 仅部署 fail2ban 联动规则"
        echo "  3) 撤销全局基础加固"
        echo "  4) 精细配置 (单项执行)"
        echo "  5) 重载 Nginx"
        echo "  0) 退出"
        safe_read -r -p "选择: " choice
        case "$choice" in
            1) apply_all_hardening; safe_read -r -p "按回车继续..." _ ;;
            2) configure_fail2ban; safe_read -r -p "按回车继续..." _ ;;
            3) revert_hardening; safe_read -r -p "按回车继续..." _ ;;
            4) fine_tune_menu ;;
            5) safe_reload; safe_read -r -p "按回车继续..." _ ;;
            0) echo "再见"; exit 0 ;;
            *) warn "无效" ;;
        esac
    done
}

fine_tune_menu() {
    while true; do
        clear
        echo -e "${CYAN}精细配置（全局基础项）:${NC}"
        echo "  1) 隐藏版本号 (server_tokens off)"
        echo "  2) 安全响应头"
        echo "  3) Permissions-Policy"
        echo "  4) 缓冲区/超时/上传限制"
        echo "  5) 生成敏感文件屏蔽 snippet (需手动 include)"
        echo "  6) 定义 \$blocked 条件变量"
        echo "  7) 部署 fail2ban 联动"
        echo "  0) 返回"
        safe_read -r -p "选择: " c
        case "$c" in
            1) harden_server_tokens; safe_reload ;;
            2) harden_security_headers; safe_reload ;;
            3) harden_permissions_policy; safe_reload ;;
            4) harden_buffers_timeouts; safe_reload ;;
            5) harden_sensitive_files ;;
            6) ensure_blocked_map; safe_reload ;;
            7) configure_fail2ban ;;
            0) return ;;
            *) warn "无效" ;;
        esac
        safe_read -r -p "按回车继续..." _
    done
}

main() {
    require_root
    init_env
    if $DRY_RUN; then
        safe_reload() { info "Dry-run 跳过重载"; true; }
    fi
    case "$CMD" in
        all) apply_all_hardening ;;
        fail2ban) configure_fail2ban ;;
        revert) revert_hardening ;;
        menu) interactive_menu ;;
    esac
}

main "$@"
