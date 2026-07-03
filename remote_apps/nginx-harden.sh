#!/bin/bash
# ============================================================
#  nginx-harden.sh — Nginx 全局基础加固 + fail2ban 联动 v4.2
#  - 适合宿主机 Nginx 反向代理容器化站点的场景
#  - CSP/方法限制/限流等站点相关项已移除，请按站点单独处理
#  - 全局阻断日志自动接入 fail2ban，无需手动配置
#  v4.2 更新:
#    - HSTS 拆分为独立分阶段模块（检测HTTPS存在 + 显式确认 + 短max-age起步）
#    - 新增 real_ip 模块（Cloudflare），修正 CDN 场景下 fail2ban 误封代理IP
#    - 新增 WordPress 安全 snippet（uploads禁PHP/屏蔽隐藏文件/xmlrpc等）
#    - fail2ban 规则扩展支持 444 状态码
# ============================================================
set -euo pipefail
umask 022

# ── 全局配置 ──
NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx}"
CONF_D_DIR="${NGINX_CONF_DIR}/conf.d"
SNIPPETS_DIR="${NGINX_CONF_DIR}/snippets"
BACKUP_DIR="/var/backups/nginx-harden"
LOG_FILE="/var/log/nginx-harden.log"
BLOCKED_LOG="/var/log/nginx/blocked.log"
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
    # 创建阻断日志并设置权限（nginx 用户可写）
    touch "$BLOCKED_LOG"
    local nginx_user pid_file
    pid_file=$( [[ -f /var/run/nginx.pid ]] && echo /var/run/nginx.pid || echo /run/nginx.pid )
    nginx_user=$(ps -o user= -p "$(cat "$pid_file" 2>/dev/null || echo 1)" 2>/dev/null || echo "www-data")
    chown "${nginx_user}:adm" "$BLOCKED_LOG" 2>/dev/null || chown root:adm "$BLOCKED_LOG"
    chmod 640 "$BLOCKED_LOG"
    # 确保 nginx 配置包含 conf.d
    if ! nginx -T 2>/dev/null | grep -q 'include.*conf\.d/\*\.conf'; then
        warn "主配置可能未包含 ${CONF_D_DIR}，请确认 nginx.conf 中存在 'include conf.d/*.conf;'"
    fi
}

backup_configs() {
    info "备份整个 Nginx 配置目录..."
    tar -czf "${BACKUP_FILE}" -C / etc/nginx && chmod 600 "${BACKUP_FILE}" || die "备份失败"
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
        if [[ -f "${BACKUP_FILE}" ]]; then
            confirm "是否立即回滚到备份？" && { restore_backup; return 1; }
        else
            warn "备份文件不存在，无法自动回滚"
        fi
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
add_header X-XSS-Protection "1; mode=block" always;  # 现代浏览器已忽略此指令，保留仅为兼容旧版
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
EOF
    success "安全响应头 (不含HSTS，见单独模块) -> ${CONF_D_DIR}/91-security-headers.conf"
    info "注意：若各站点 server/location 块自行定义了 add_header，会覆盖此处的值（nginx 的 add_header 不会跨层级叠加），请按需检查。"
}

# ── HSTS：单独模块，分阶段启用，避免"生效后无法撤销"的风险 ──
harden_hsts() {
    local conf="${CONF_D_DIR}/91b-hsts.conf"

    local https_sites
    https_sites=$(nginx -T 2>/dev/null | grep -cE 'listen[[:space:]]+.*443.*ssl') || https_sites=0

    if [[ "$https_sites" -eq 0 ]]; then
        warn "未检测到任何 'listen 443 ssl' 配置，跳过 HSTS（避免站点尚未支持 HTTPS 时被强制跳转导致不可访问）"
        return 0
    fi

    if [[ "${ENABLE_HSTS:-}" != "1" ]]; then
        if [[ -t 0 ]]; then
            warn "HSTS 生效后（尤其带 includeSubDomains），浏览器会在 max-age 时间内强制该域名及所有子域走 HTTPS。"
            warn "若某个子域/路径证书或HTTPS配置有问题，用户在缓存期内将完全无法通过 HTTP 访问，且客户端无法手动撤销。"
            confirm "已确认所有相关站点及子域的 HTTPS 均可正常访问，继续启用 HSTS？" || { info "跳过 HSTS"; return 0; }
        else
            info "非交互模式默认跳过 HSTS（设置 ENABLE_HSTS=1 显式启用）"
            return 0
        fi
    fi

    local max_age="${HSTS_MAX_AGE:-300}"
    cat > "$conf" <<EOF
# 首次启用建议短 max-age 观察（当前: ${max_age}s）。
# 确认稳定运行几天无异常后，建议依次调大: 300(5分钟) -> 86400(1天) -> 31536000(1年)
# 调整方法: HSTS_MAX_AGE=31536000 ENABLE_HSTS=1 $0 --fine-tune 或重新执行本项
add_header Strict-Transport-Security "max-age=${max_age}; includeSubDomains" always;
EOF
    success "HSTS -> $conf (max-age=${max_age}s)"
    if [[ "$max_age" -lt 31536000 ]]; then
        info "当前为测试期短周期设置，稳定后请调大 max-age 并考虑提交 HSTS preload。"
    fi
}

harden_permissions_policy() {
    local conf="${CONF_D_DIR}/94-permissions-policy.conf"
    # 无交互直接启用，因为该项对反向代理无害
    echo 'add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), interest-cohort=()" always;' > "$conf"
    success "Permissions-Policy -> $conf"
}

harden_buffers_timeouts() {
    local conf="${CONF_D_DIR}/92-security-buffers.conf"
    local max_body="${NGINX_MAX_BODY_SIZE:-100M}"

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
    success "缓冲区与超时 -> $conf (最大上传: ${max_body})"
    info "提示：可通过环境变量 NGINX_MAX_BODY_SIZE 自定义，单个站点可在 server/location 中覆盖。"
}

# ── real_ip：CDN/反代场景下修正 fail2ban 误封代理节点IP ──
harden_real_ip() {
    local conf="${CONF_D_DIR}/89-real-ip.conf"

    if [[ "${ENABLE_REAL_IP:-}" != "1" ]]; then
        if [[ -t 0 ]]; then
            echo ""
            info "real_ip 检测：若站点前面有 Cloudflare 等 CDN/反代，nginx 看到的 \$remote_addr 是 CDN 节点 IP，"
            info "fail2ban 封禁将作用在 CDN IP 而非真实攻击者，等同无效。"
            confirm "站点是否使用 Cloudflare？" || { info "跳过 real_ip 配置"; return 0; }
        else
            info "非交互模式跳过 real_ip 配置（设置 ENABLE_REAL_IP=1 启用）"
            return 0
        fi
    fi

    info "拉取 Cloudflare IP 段..."
    {
        echo "# Cloudflare real IP ranges — 由 nginx-harden.sh 自动生成，请勿手动编辑"
        echo "# 更新时间: ${TIMESTAMP}"
        for url in https://www.cloudflare.com/ips-v4 https://www.cloudflare.com/ips-v6; do
            curl -fsSL "$url" 2>/dev/null | sed 's/^/set_real_ip_from /; s/$/;/'
        done
        echo "real_ip_header CF-Connecting-IP;"
        echo "real_ip_recursive on;"
    } > "$conf"

    if [[ $(grep -c 'set_real_ip_from' "$conf") -lt 2 ]]; then
        warn "获取 Cloudflare IP 段失败或不完整，请检查网络连接后重试"
        rm -f "$conf"
        return 1
    fi
    success "real_ip (Cloudflare) -> $conf"
    warn "Cloudflare IP 段会变化，建议加入 cron 定期重新执行本项（例如每月一次）以保持更新。"
}

# ── WordPress 安全 snippet（站点级，需各站点手动 include） ──
harden_wordpress_snippet() {
    local conf="${SNIPPETS_DIR}/wordpress-security.conf"
    cat > "$conf" <<'EOF'
# WordPress 安全片段 — 由 nginx-harden.sh 生成
# 使用方法：在各 WP 站点的 server {} 块中加入:
#   include snippets/wordpress-security.conf;
# 请按站点实际情况删改（例如是否使用 Jetpack / REST API 依赖等）

# 禁止执行 wp-content/uploads 目录下的 PHP（防止利用上传漏洞放置 webshell）
location ~* ^/wp-content/uploads/.*\.php$ {
    deny all;
    return 444;
}

# 屏蔽隐藏文件（.git .env .htaccess 等），保留 /.well-known 用于证书验证等用途
location ~ /\.(?!well-known) {
    deny all;
    return 444;
}

# 屏蔽敏感文件直接访问
location ~* ^/(wp-config\.php|readme\.html|license\.txt|wp-content/debug\.log)$ {
    deny all;
    return 444;
}

# xmlrpc.php 是暴力破解 / DDoS 放大攻击的常见入口，多数站点用不到，默认屏蔽
# 若依赖 Jetpack 或远程发布 (XML-RPC) 功能，请注释掉这一段
location = /xmlrpc.php {
    deny all;
    return 444;
}

# 可选：屏蔽 REST API 用户名枚举端点，视是否有插件依赖该接口决定是否启用
#location ~* ^/wp-json/wp/v2/users {
#    deny all;
#    return 444;
#}
EOF
    success "WordPress 安全片段 -> $conf"
    warn "该片段不会自动生效，需在各 WP 站点的 server {} 块中手动加入: include snippets/wordpress-security.conf;"
}

# ── 全局阻断日志（接入 fail2ban） ──
ensure_blocked_map() {
    cat > "${CONF_D_DIR}/99-blocked-log.conf" <<'EOF'
# 为阻断日志定义条件变量，并全局记录所有被拒绝的请求
map $status $blocked {
    default 0;
    403 1;
    405 1;
    444 1;
    503 1;
}

access_log /var/log/nginx/blocked.log combined if=$blocked;
EOF
    success "全局阻断日志配置 -> ${CONF_D_DIR}/99-blocked-log.conf"
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

    # 过滤器（含 444，用于 WordPress snippet 等 deny 场景）
    cat > "${FAIL2BAN_FILTER}" <<'EOF'
[Definition]
failregex = ^<HOST> - .* "(GET|POST|HEAD|PUT|DELETE|MKCOL|PROPFIND|OPTIONS) [^"]* HTTP/[0-9.]+" (403|405|444|503) .*$
ignoreregex =
EOF

    # jail：不写死 bantime/findtime/maxretry/banaction，继承 jail.local 的 [DEFAULT]，
    # 这样若日后通过其它工具（如 firewall_fail2ban.sh 的"基础参数配置"）调整全局阈值，
    # 本 jail 会自动保持一致，无需两边分别维护
    cat > "${FAIL2BAN_JAIL}" <<EOF
[nginx-harden]
enabled = true
port    = http,https
filter  = nginx-harden
logpath = ${BLOCKED_LOG}
EOF

    systemctl enable fail2ban

    # 优先 reload，避免影响其他已存在的 jail 的当前 ban 状态
    if systemctl is-active --quiet fail2ban; then
        systemctl reload fail2ban || systemctl restart fail2ban
    else
        systemctl restart fail2ban
    fi
    success "fail2ban 联动规则已部署，监狱: nginx-harden"
    info "现在任何返回 403/405/444/503 的请求都会被记录，触发封禁的阈值/时长继承自 jail.local 的 [DEFAULT]。"
}

# ── 一键全局基础加固 ──
apply_all_hardening() {
    backup_configs
    harden_real_ip
    harden_server_tokens
    harden_security_headers
    harden_hsts
    harden_permissions_policy
    harden_buffers_timeouts
    harden_wordpress_snippet
    ensure_blocked_map
    configure_fail2ban

    safe_reload
    success "全局基础加固 + fail2ban 联动完成！"
    echo ""
    info "以下为站点相关项，本次未处理，留待按站点(WordPress/AList/图床等)单独配置："
    echo "    - Content-Security-Policy (CSP)"
    echo "    - HTTP 请求方法限制 (GET/HEAD/POST 严格模式 vs WebDAV 兼容)"
    echo "    - 请求/连接限流 (limit_req / limit_conn)"
    echo ""
    info "WordPress 站点请在各自 server {} 块中加入: include snippets/wordpress-security.conf;"
}

# 撤销
revert_hardening() {
    confirm "移除全局基础加固配置并恢复备份？" || return
    rm -f "${CONF_D_DIR}/89-real-ip.conf" \
          "${CONF_D_DIR}/90-security-tokens.conf" \
          "${CONF_D_DIR}/91-security-headers.conf" \
          "${CONF_D_DIR}/91b-hsts.conf" \
          "${CONF_D_DIR}/92-security-buffers.conf" \
          "${CONF_D_DIR}/94-permissions-policy.conf" \
          "${CONF_D_DIR}/99-blocked-log.conf"
    rm -f "${SNIPPETS_DIR}/wordpress-security.conf"
    rm -f "${FAIL2BAN_FILTER}" "${FAIL2BAN_JAIL}"
    if command -v fail2ban-server &>/dev/null && systemctl is-active --quiet fail2ban; then
        systemctl reload fail2ban || systemctl restart fail2ban
        info "已移除 nginx-harden 规则，fail2ban 已重新加载"
    fi
    local latest
    latest=$(ls -1t "${BACKUP_DIR}"/nginx-backup-*.tar.gz 2>/dev/null | head -1)
    if [[ -f "$latest" ]] && confirm "恢复备份 ${latest##*/}？"; then
        tar -xzf "$latest" -C /
        success "已恢复"
    fi
    safe_reload || true
    warn "若曾在 WP 站点 server 块中手动 include 过 wordpress-security.conf，请自行移除该行。"
    warn "若曾手动在某些站点 server 块中添加过阻断相关配置，请手动清理对应 conf 文件。"
}

# ── 命令行参数 ──
CMD="menu"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--all) CMD="all"; shift ;;
        -f|--fail2ban) CMD="fail2ban"; shift ;;
        -r|--revert) CMD="revert"; shift ;;
        -h|--help)
            echo "用法: $0 [-a 全局基础加固 | -f 仅部署fail2ban联动 | -r 撤销]"
            echo ""
            echo "环境变量:"
            echo "  ENABLE_HSTS=1           非交互模式下启用 HSTS (默认跳过)"
            echo "  HSTS_MAX_AGE=<秒数>     HSTS max-age，默认 300（测试期短周期）"
            echo "  ENABLE_REAL_IP=1        非交互模式下启用 Cloudflare real_ip (默认跳过)"
            echo "  NGINX_MAX_BODY_SIZE=<值> 客户端最大上传大小，默认 100M"
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
        echo "  ║     Nginx 全局基础加固 + fail2ban v4.2        ║"
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
        echo "  1) real_ip (Cloudflare)"
        echo "  2) 隐藏版本号 (server_tokens off)"
        echo "  3) 安全响应头 (不含HSTS)"
        echo "  4) HSTS (分阶段启用)"
        echo "  5) Permissions-Policy"
        echo "  6) 缓冲区/超时/上传限制"
        echo "  7) WordPress 安全片段"
        echo "  8) 定义 \$blocked 条件变量 + 全局阻断日志"
        echo "  9) 部署 fail2ban 联动"
        echo "  0) 返回"
        safe_read -r -p "选择: " c
        case "$c" in
            1) harden_real_ip; safe_reload ;;
            2) harden_server_tokens; safe_reload ;;
            3) harden_security_headers; safe_reload ;;
            4) harden_hsts; safe_reload ;;
            5) harden_permissions_policy; safe_reload ;;
            6) harden_buffers_timeouts; safe_reload ;;
            7) harden_wordpress_snippet ;;
            8) ensure_blocked_map; safe_reload ;;
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
    case "$CMD" in
        all) apply_all_hardening ;;
        fail2ban) configure_fail2ban ;;
        revert) revert_hardening ;;
        menu) interactive_menu ;;
    esac
}

main "$@"