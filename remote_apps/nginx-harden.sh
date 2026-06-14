#!/bin/bash
# ============================================================
#  nginx-harden.sh — Nginx 安全加固 + fail2ban 协同套装 v3.0
#  - 自动备份、回滚、注入、限流、CSP、fail2ban 联动
# ============================================================
set -euo pipefail
umask 022

# ── 全局配置 ──
NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx}"
CONF_D_DIR="${NGINX_CONF_DIR}/conf.d"
SNIPPETS_DIR="${NGINX_CONF_DIR}/snippets"
BACKUP_DIR="/var/backups/nginx-harden"
LOG_FILE="/var/log/nginx-harden.log"
BLOCKED_LOG="/var/log/nginx/blocked.log"          # ★ 统一阻断日志
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

# ── 加固模块（关键点：统一阻断日志） ──

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
}

harden_csp() {
    local conf="${CONF_D_DIR}/93-csp.conf"
    if confirm "启用 Content-Security-Policy？"; then
        local policy="default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline';"
        echo "add_header Content-Security-Policy \"${policy}\" always;" > "$conf"
        success "CSP 已配置 -> $conf"
    else
        info "跳过 CSP"
    fi
}

harden_permissions_policy() {
    local conf="${CONF_D_DIR}/94-permissions-policy.conf"
    if confirm "启用 Permissions-Policy？"; then
        echo 'add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), interest-cohort=()" always;' > "$conf"
        success "Permissions-Policy -> $conf"
    else
        info "跳过 Permissions-Policy"
    fi
}

harden_http_methods() {
    local conf="${SNIPPETS_DIR}/secure-methods.conf"
    echo ""
    warn "严格限制请求方法"
    echo "  1) 严格模式 (GET/HEAD/POST)"
    echo "  2) WebDAV 兼容"
    safe_read -r -p "选择 [1-2，默认1]: " choice
    if [[ "$choice" == "2" ]]; then
        cat > "$conf" <<'EOF'
if ($request_method !~ ^(GET|HEAD|POST|PUT|DELETE|MKCOL|COPY|MOVE|PROPFIND|OPTIONS)$) {
    return 405;
}
EOF
        success "WebDAV 兼容请求拦截 -> $conf"
    else
        cat > "$conf" <<'EOF'
if ($request_method !~ ^(GET|HEAD|POST)$) {
    return 405;
}
EOF
        success "严格请求拦截 -> $conf"
    fi
    # ★ 阻断写入统一日志
    echo 'access_log /var/log/nginx/blocked.log combined if=$blocked;' >> "$conf"
    warn "需在 server 块中 include"
}

harden_buffers_timeouts() {
    local conf="${CONF_D_DIR}/92-security-buffers.conf"
    while true; do
        safe_read -r -p "全局最大上传限制 (如 50M, 0不限) [默认50M]: " max_body
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
}

harden_sensitive_files() {
    local conf="${SNIPPETS_DIR}/secure-files.conf"
    cat > "$conf" <<'EOF'
# 记录屏蔽事件到统一日志
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
    success "敏感文件屏蔽 -> $conf"
}

harden_rate_limit() {
    if confirm "启用请求/连接限流？"; then
        local zone_conf="${CONF_D_DIR}/95-rate-limit.conf"
        safe_read -r -p "单IP请求速率 (如 10r/s) [默认10r/s]: " rate
        [[ -z "$rate" ]] && rate="10r/s"
        local burst=$(( ${rate%%r/s} * 2 ))
        cat > "$zone_conf" <<EOF
limit_req_zone \$binary_remote_addr zone=req_limit:10m rate=${rate};
limit_conn_zone \$binary_remote_addr zone=conn_limit:10m;
EOF
        cat > "${SNIPPETS_DIR}/rate-limit.conf" <<EOF
limit_req zone=req_limit burst=${burst} nodelay;
limit_conn conn_limit 10;
# 限流拒绝记录到统一日志
access_log /var/log/nginx/blocked.log combined if=\$limit_req_status;
EOF
        success "限流规则已生成"
    else
        info "跳过限流"
    fi
}

# ── 自动注入 ──
auto_include_snippets() {
    confirm "自动注入安全片段到所有 server 块？" || return
    mapfile -t files < <(grep -rnIl '^\s*server\s*{' "${NGINX_CONF_DIR}" --include="*.conf" | grep -v snippets | grep -v "${CONF_D_DIR}/9[0-9]") || true
    for f in "${files[@]}"; do
        cp "$f" "${f}.bak-$(date +%Y%m%d%H%M%S)"
        for snippet in secure-methods.conf secure-files.conf rate-limit.conf; do
            [[ -f "${SNIPPETS_DIR}/${snippet}" ]] || continue
            grep -q "include snippets/${snippet};" "$f" && continue
            sed -i "/^\s*server\s*{/a\    include snippets/${snippet};" "$f"
            success "  ✓ $f ← ${snippet}"
        done
    done
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

    # 生成过滤器（匹配统一日志中的 403/405/503）
    cat > "${FAIL2BAN_FILTER}" <<'EOF'
[Definition]
failregex = ^<HOST> .* "(GET|POST|HEAD|PUT|DELETE|MKCOL|PROPFIND|OPTIONS).*" (403|405|503) .*$
            ^<HOST> .* "(GET|POST|HEAD).*\.(git|env|bak|sql|log).*" .*$
ignoreregex =
EOF

    # 生成 jail 配置
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
    systemctl restart fail2ban
    success "fail2ban 协同规则已部署，监狱: nginx-harden"
}

# ── 一键协同加固 ──
apply_all_hardening() {
    backup_configs
    harden_server_tokens
    harden_security_headers
    harden_csp
    harden_permissions_policy
    harden_buffers_timeouts

    # 生成 snippet（严格模式、敏感文件、限流）
    echo 'if ($request_method !~ ^(GET|HEAD|POST)$) { return 405; }' > "${SNIPPETS_DIR}/secure-methods.conf"
    echo 'access_log /var/log/nginx/blocked.log combined if=$blocked;' >> "${SNIPPETS_DIR}/secure-methods.conf"
    harden_sensitive_files
    harden_rate_limit

    auto_include_snippets

    # ★ fail2ban 联动
    configure_fail2ban

    # 定义 blocked 变量并启用统一日志
    cat >> "${CONF_D_DIR}/99-blocked-log.conf" <<'EOF'
# 为阻断日志定义条件变量（默认开启）
map $status $blocked {
    default 0;
    403 1;
    405 1;
    503 1;
}
EOF

    safe_reload
    success "Nginx 加固 + fail2ban 联动全部完成！"
}

# 撤销
revert_hardening() {
    confirm "移除所有加固配置并恢复备份？" || return
    rm -f "${CONF_D_DIR}/90-security-tokens.conf" \
          "${CONF_D_DIR}/91-security-headers.conf" \
          "${CONF_D_DIR}/92-security-buffers.conf" \
          "${CONF_D_DIR}/93-csp.conf" \
          "${CONF_D_DIR}/94-permissions-policy.conf" \
          "${CONF_D_DIR}/95-rate-limit.conf" \
          "${CONF_D_DIR}/99-blocked-log.conf" \
          "${SNIPPETS_DIR}/secure-methods.conf" \
          "${SNIPPETS_DIR}/secure-files.conf" \
          "${SNIPPETS_DIR}/rate-limit.conf"
    rm -f "${FAIL2BAN_FILTER}" "${FAIL2BAN_JAIL}"
    systemctl stop fail2ban || true
    info "已移除所有规则，fail2ban 已停止"
    local latest=$(ls -1t "${BACKUP_DIR}"/nginx-backup-*.tar.gz 2>/dev/null | head -1)
    if [[ -f "$latest" ]] && confirm "恢复备份 ${latest##*/}？"; then
        tar -xzf "$latest" -C /
        success "已恢复"
    fi
    safe_reload || true
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
            echo "用法: $0 [-a 全加固 | -f 仅部署fail2ban联动 | -r 撤销 | --dry-run 预览]"
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
        echo "  ║        Nginx 安全加固 + fail2ban v3.0         ║"
        echo "  ╚════════════════════════════════════════════════╝"
        echo -e "${NC}"
        echo "  1) 一键协同加固 (推荐)"
        echo "  2) 仅部署 fail2ban 联动规则"
        echo "  3) 撤销所有加固及 fail2ban"
        echo "  4) 精细配置 (版本头/方法/限流等)"
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
        echo -e "${CYAN}精细配置:${NC}"
        echo "  1) 隐藏版本  2) 安全头  3) CSP/权限策略"
        echo "  4) 请求方法  5) 缓冲区  6) 敏感文件"
        echo "  7) 限流      8) 自动注入  9) fail2ban部署"
        echo "  0) 返回"
        safe_read -r -p "选择: " c
        case "$c" in
            1) harden_server_tokens; safe_reload ;;
            2) harden_security_headers; safe_reload ;;
            3) harden_csp; harden_permissions_policy; safe_reload ;;
            4) harden_http_methods ;;
            5) harden_buffers_timeouts; safe_reload ;;
            6) harden_sensitive_files ;;
            7) harden_rate_limit ;;
            8) auto_include_snippets; safe_reload ;;
            9) configure_fail2ban ;;
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
