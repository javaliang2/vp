#!/bin/bash
# ============================================================
#  nginx-web-security.sh — Nginx 层 Web 安全加固 (无冲突版)
#  配合 nginx-gateway.sh 使用，专注通用 Web 安全
#  功能：安全头 / 路径防护 / 防盗链 / WAF / CSP / 爬虫封锁 / 隐藏版本
#  不包含 SSL 强化（主脚本已处理）和 WordPress 特殊规则（避免冲突）
# ============================================================
set -euo pipefail
shopt -s extglob

# ──────────────────────────────────────────────────────────
# 全局配置
# ──────────────────────────────────────────────────────────
NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx}"
SITES_AVAILABLE="${NGINX_CONF_DIR}/sites-available"
SITES_DIR="${SITES_DIR:-${NGINX_CONF_DIR}/sites-enabled}"
SNIPPET_DIR="${NGINX_CONF_DIR}/snippets"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/nginx-gateway}"
LOG_FILE="/var/log/nginx-web-security.log"

mkdir -p "$SNIPPET_DIR" "$BACKUP_DIR"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"

# ──────────────────────────────────────────────────────────
# 颜色 & 日志
# ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

_log() { echo -e "$*" | tee -a "$LOG_FILE" 1>&2; }
info()    { _log "${CYAN}[信息]${NC}  $*"; }
success() { _log "${GREEN}[成功]${NC}  $*"; }
warn()    { _log "${YELLOW}[警告]${NC}  $*"; }
error()   { _log "${RED}[错误]${NC}  $*"; }
die()     { error "$*"; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || die "请以 root 身份运行本脚本（sudo $0）"; }
safe_read() {
    set +e; read -r "$@"; local _rc=$?; set -e; return $_rc
}
confirm() {
    local _ans
    safe_read -rp "${YELLOW}$1 [y/N]${NC} " _ans
    [[ ${_ans,,} == "y" ]]
}

# ──────────────────────────────────────────────────────────
# 工具：列出所有站点，供用户选择
# ──────────────────────────────────────────────────────────
list_domains() {
    local -a domains=()
    for conf in "${SITES_AVAILABLE}"/*.conf; do
        [[ -f "$conf" ]] || continue
        local name; name=$(basename "$conf" .conf)
        [[ "$name" == 00-* ]] && continue   # 跳过系统保护配置
        domains+=("$name")
    done

    if [[ ${#domains[@]} -eq 0 ]]; then
        die "未找到任何站点配置，请先用 nginx-gateway.sh 创建站点"
    fi

    echo -e "\n${BOLD}已配置的站点:${NC}"
    local i=1
    for d in "${domains[@]}"; do
        printf "  %2d) %s\n" "$i" "$d"
        (( i++ ))
    done
    echo ""
    safe_read -rp "请选择站点序号 [1-${#domains[@]}]: " _idx
    if ! [[ "$_idx" =~ ^[0-9]+$ ]] || (( _idx < 1 || _idx > ${#domains[@]} )); then
        die "无效序号"
    fi
    SELECTED_DOMAIN="${domains[$(( _idx - 1 ))]}"
    SELECTED_CONF="${SITES_AVAILABLE}/${SELECTED_DOMAIN}.conf"
    SELECTED_SNIPPET="${SNIPPET_DIR}/security-${SELECTED_DOMAIN}.conf"
    info "已选择站点: $SELECTED_DOMAIN"
}

# ──────────────────────────────────────────────────────────
# 辅助：将安全片段 include 注入站点配置
# ──────────────────────────────────────────────────────────
inject_include() {
    local conf="$1"
    local snippet_path="$2"
    local marker="include ${snippet_path};"
    if grep -qF "$marker" "$conf"; then
        return
    fi
    if grep -qE '^[[:space:]]*location[[:space:]]+/[[:space:]]*{' "$conf"; then
        sed -i "0,/^[[:space:]]*location[[:space:]]*\/[[:space:]]*{/ s//${marker}\n&/" "$conf"
    else
        sed -i "\$i ${marker}" "$conf"
    fi
    info "已将安全配置引入站点: $conf"
}

# ──────────────────────────────────────────────────────────
# 1. 安全响应头
# ──────────────────────────────────────────────────────────
add_security_headers() {
    cat > "$SELECTED_SNIPPET" <<'HEADERS'
# ---- 安全响应头 ----
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
HEADERS
    success "安全响应头已生成"
}

# ──────────────────────────────────────────────────────────
# 2. 敏感文件封锁
# ──────────────────────────────────────────────────────────
add_file_protection() {
    cat >> "$SELECTED_SNIPPET" <<'FILEBLOCK'

# ---- 敏感文件保护 ----
location ~ /\. {
    deny all;
    access_log off;
    log_not_found off;
}
location ~* \.(bak|config|sql|fla|psd|ini|log|sh|inc|swp|dist)$ {
    deny all;
    access_log off;
    log_not_found off;
}
location ~* (\.git|\.svn|\.hg|\.env|\.htpasswd|composer\.(json|lock)|package\.json|yarn\.lock)$ {
    deny all;
    access_log off;
    log_not_found off;
}
FILEBLOCK
    success "敏感文件封锁规则已添加"
}

# ──────────────────────────────────────────────────────────
# 3. 请求方法限制
# ──────────────────────────────────────────────────────────
add_method_restriction() {
    cat >> "$SELECTED_SNIPPET" <<'METHODS'

# ---- HTTP 方法限制 ----
if ($request_method !~ ^(GET|HEAD|POST|OPTIONS)$ ) {
    return 405;
}
METHODS
    success "请求方法已限制"
}

# ──────────────────────────────────────────────────────────
# 4. 防盗链
# ──────────────────────────────────────────────────────────
add_hotlink_protection() {
    local allowed_domains=""
    echo -e "${CYAN}请输入允许引用资源的域名（多个用空格分隔，留空则只允许本站）${NC}"
    echo "示例: yoursite.com cdn.yoursite.com"
    safe_read -rp "允许的域名: " allowed_domains
    [[ -z "$allowed_domains" ]] && allowed_domains="none"

    cat >> "$SELECTED_SNIPPET" <<HOTLINK

# ---- 防盗链 (图片/视频) ----
location ~* \.(gif|png|jpe?g|svg|webp|bmp|ico|mp4|webm|ogg)$ {
    valid_referers none blocked server_names ${allowed_domains};
    if (\$invalid_referer) {
        return 403;
    }
}
HOTLINK
    success "防盗链规则已应用（允许: ${allowed_domains}）"
}

# ──────────────────────────────────────────────────────────
# 5. 基础 WAF
# ──────────────────────────────────────────────────────────
add_basic_waf() {
    cat >> "$SELECTED_SNIPPET" <<'WAF'

# ---- 简单 WAF 过滤 ----
set $block_request 0;
if ($query_string ~* "(<|>|'|%3C|%3E|%27|%22|%28|%29|%0A|%0D|%09|union.*select|select.*from|insert.*into|drop.*table|update.*set|delete.*from|script|alert|onmouseover|onerror|onload|eval\(|document\.cookie|\.\.\/)") {
    set $block_request 1;
}
if ($request_uri ~* "(<|>|'|%3C|%3E|%27|%22|%28|%29|%0A|%0D|%09|%00|\.\.\/|\.\.\\\|\/\.\/)") {
    set $block_request 1;
}
if ($block_request = 1) {
    return 403;
}
WAF
    success "基础 WAF 过滤规则已添加"
}

# ──────────────────────────────────────────────────────────
# 6. 恶意爬虫封锁
# ──────────────────────────────────────────────────────────
add_bad_bot_blocking() {
    cat >> "$SELECTED_SNIPPET" <<'BOTBLOCK'

# ---- 恶意爬虫封锁 ----
if ($http_user_agent ~* (scrapy|curl|wget|python-requests|libwww|perl|nikto|sqlmap|masscan|nmap|zgrab|gobuster|dirbuster|nessus|openvas|acunetix|burp|whatweb|wpscan|joomscan|havij|netsparker|AppScan|WebInspect|ZAP|Vega|Arachni|Skipfish|Wfuzz|Brutus|Hydra|Medusa|JohnTheRipper|Hashcat)) {
    return 403;
}
BOTBLOCK
    success "恶意爬虫 User-Agent 封锁已添加"
}

# ──────────────────────────────────────────────────────────
# 7. 内容安全策略 (CSP)
# ──────────────────────────────────────────────────────────
add_csp() {
    echo -e "${CYAN}配置内容安全策略 (CSP)${NC}"
    local default_src="'self'"
    safe_read -rp "默认加载源 (default-src) [默认 'self']: " _ds
    [[ -n "$_ds" ]] && default_src="$_ds"

    local script_src="'self' 'unsafe-inline' 'unsafe-eval'"
    safe_read -rp "脚本加载源 (script-src) [默认 'self' 'unsafe-inline' 'unsafe-eval']: " _ss
    [[ -n "$_ss" ]] && script_src="$_ss"

    local style_src="'self' 'unsafe-inline'"
    safe_read -rp "样式加载源 (style-src) [默认 'self' 'unsafe-inline']: " _st
    [[ -n "$_st" ]] && style_src="$_st"

    cat >> "$SELECTED_SNIPPET" <<CSP

# ---- 内容安全策略 ----
add_header Content-Security-Policy "default-src ${default_src}; script-src ${script_src}; style-src ${style_src}; img-src * data:; font-src 'self' data:; connect-src 'self'; frame-ancestors 'self'; form-action 'self';" always;
CSP
    success "CSP 策略已添加"
}

# ──────────────────────────────────────────────────────────
# 8. 路径遍历防护
# ──────────────────────────────────────────────────────────
add_path_traversal_protection() {
    cat >> "$SELECTED_SNIPPET" <<'PATHSAFE'

# ---- 路径安全 ----
if ($request_uri ~* "\.\." ) {
    return 403;
}
autoindex off;
PATHSAFE
    success "路径遍历防护已启用"
}

# ──────────────────────────────────────────────────────────
# 9. 隐藏 Nginx 版本号（全局）
# ──────────────────────────────────────────────────────────
hide_nginx_version() {
    local conf="${NGINX_CONF_DIR}/nginx.conf"
    [[ -f "$conf" ]] || die "找不到 $conf"
    # 备份
    local ts; ts=$(date +%Y%m%d_%H%M%S)
    cp "$conf" "${BACKUP_DIR}/nginx.conf.bak-${ts}"
    info "已备份 $conf -> ${BACKUP_DIR}/nginx.conf.bak-${ts}"

    if grep -qE "^\s*server_tokens\s+off;" "$conf"; then
        success "server_tokens 已经是 off，无需修改"
        return
    fi
    if grep -q "server_tokens" "$conf"; then
        sed -i 's/^\s*server_tokens\s.*/    server_tokens off;/' "$conf"
    else
        sed -i '/^http {/a\    server_tokens off;' "$conf"
    fi
    nginx -t && systemctl reload nginx && success "已隐藏 Nginx 版本号，server_tokens 已设为 off" || die "配置错误"
}

# ──────────────────────────────────────────────────────────
# 一键全部加固（不包含 SSL 强化和 WordPress）
# ──────────────────────────────────────────────────────────
apply_all_security() {
    info "开始为 ${SELECTED_DOMAIN} 执行全面安全加固..."
    echo "# Nginx Web 安全加固: ${SELECTED_DOMAIN} (生成时间: $(date))" > "$SELECTED_SNIPPET"
    add_security_headers
    add_file_protection
    add_method_restriction
    add_hotlink_protection
    add_basic_waf
    add_bad_bot_blocking
    add_csp
    add_path_traversal_protection
    # 不包含 SSL 强化和 WordPress，避免冲突

    inject_include "$SELECTED_CONF" "$SELECTED_SNIPPET"
    if nginx -t; then
        systemctl reload nginx
        success "全部安全规则已应用，Nginx 重载成功"
    else
        error "Nginx 配置测试失败！已自动移除引入，请检查"
        sed -i "\|include ${SELECTED_SNIPPET};|d" "$SELECTED_CONF"
    fi
}

# ──────────────────────────────────────────────────────────
# 移除安全配置
# ──────────────────────────────────────────────────────────
remove_security() {
    list_domains
    if [[ -f "$SELECTED_SNIPPET" ]]; then
        rm -f "$SELECTED_SNIPPET"
        success "已删除安全片段: $SELECTED_SNIPPET"
    fi
    if grep -qF "include ${SELECTED_SNIPPET};" "$SELECTED_CONF"; then
        sed -i "\|include ${SELECTED_SNIPPET};|d" "$SELECTED_CONF"
        success "已从站点配置中移除 include"
    fi
    nginx -t && systemctl reload nginx && success "Nginx 重载完成" || warn "配置检查失败，请手动处理"
}

# ──────────────────────────────────────────────────────────
# 交互式菜单
# ──────────────────────────────────────────────────────────
interactive_menu() {
    require_root
    while true; do
        clear
        echo -e "${BOLD}${GREEN}"
        echo "  ╔════════════════════════════════════════════════╗"
        echo "  ║      Nginx Web 安全加固 (通用版)              ║"
        echo "  ╚════════════════════════════════════════════════╝"
        echo -e "${NC}"
        echo -e " ${CYAN}1)${NC} 添加安全响应头"
        echo -e " ${CYAN}2)${NC} 敏感文件保护"
        echo -e " ${CYAN}3)${NC} 限制请求方法"
        echo -e " ${CYAN}4)${NC} 防盗链"
        echo -e " ${CYAN}5)${NC} 基础 WAF 规则"
        echo -e " ${CYAN}6)${NC} 恶意爬虫封锁"
        echo -e " ${CYAN}7)${NC} 配置 CSP"
        echo -e " ${CYAN}8)${NC} 路径遍历防护"
        echo -e " ${CYAN}9)${NC} 隐藏 Nginx 版本号 (全局)"
        echo ""
        echo -e " ${GREEN}A)${NC} 一键全部加固 (推荐)"
        echo -e " ${RED}R)${NC} 移除站点的安全配置"
        echo -e " ${CYAN}Q)${NC} 退出"
        echo ""
        safe_read -rp "请选择: " choice

        case "$choice" in
            1)
                list_domains
                echo "# 安全头" > "$SELECTED_SNIPPET"
                add_security_headers
                inject_include "$SELECTED_CONF" "$SELECTED_SNIPPET"
                nginx -t && systemctl reload nginx && success "已生效" || die "配置错误"
                ;;
            2)
                list_domains
                echo "# 文件保护" > "$SELECTED_SNIPPET"
                add_file_protection
                inject_include "$SELECTED_CONF" "$SELECTED_SNIPPET"
                nginx -t && systemctl reload nginx && success "已生效" || die "配置错误"
                ;;
            3)
                list_domains
                echo "# 方法限制" > "$SELECTED_SNIPPET"
                add_method_restriction
                inject_include "$SELECTED_CONF" "$SELECTED_SNIPPET"
                nginx -t && systemctl reload nginx && success "已生效" || die "配置错误"
                ;;
            4)
                list_domains
                echo "# 防盗链" > "$SELECTED_SNIPPET"
                add_hotlink_protection
                inject_include "$SELECTED_CONF" "$SELECTED_SNIPPET"
                nginx -t && systemctl reload nginx && success "已生效" || die "配置错误"
                ;;
            5)
                list_domains
                echo "# WAF" > "$SELECTED_SNIPPET"
                add_basic_waf
                inject_include "$SELECTED_CONF" "$SELECTED_SNIPPET"
                nginx -t && systemctl reload nginx && success "已生效" || die "配置错误"
                ;;
            6)
                list_domains
                echo "# 爬虫封锁" > "$SELECTED_SNIPPET"
                add_bad_bot_blocking
                inject_include "$SELECTED_CONF" "$SELECTED_SNIPPET"
                nginx -t && systemctl reload nginx && success "已生效" || die "配置错误"
                ;;
            7)
                list_domains
                echo "# CSP" > "$SELECTED_SNIPPET"
                add_csp
                inject_include "$SELECTED_CONF" "$SELECTED_SNIPPET"
                nginx -t && systemctl reload nginx && success "已生效" || die "配置错误"
                ;;
            8)
                list_domains
                echo "# 路径安全" > "$SELECTED_SNIPPET"
                add_path_traversal_protection
                inject_include "$SELECTED_CONF" "$SELECTED_SNIPPET"
                nginx -t && systemctl reload nginx && success "已生效" || die "配置错误"
                ;;
            9)
                hide_nginx_version
                ;;
            [Aa])
                list_domains
                apply_all_security
                ;;
            [Rr])
                remove_security
                ;;
            [Qq])
                echo "再见！"; exit 0
                ;;
            *)
                warn "无效选项"
                ;;
        esac
        safe_read -rp "按回车继续..." _
    done
}

# ──────────────────────────────────────────────────────────
# 命令行入口
# ──────────────────────────────────────────────────────────
main() {
    if [[ $# -eq 0 ]]; then
        interactive_menu
        exit 0
    fi
    local domain="${1}"
    local action="${2:-all}"

    if [[ "$domain" == "hide-version" ]]; then
        hide_nginx_version
        exit 0
    fi

    SELECTED_DOMAIN="$domain"
    SELECTED_CONF="${SITES_AVAILABLE}/${SELECTED_DOMAIN}.conf"
    SELECTED_SNIPPET="${SNIPPET_DIR}/security-${SELECTED_DOMAIN}.conf"
    [[ -f "$SELECTED_CONF" ]] || die "站点配置不存在: $SELECTED_CONF"

    case "$action" in
        headers)    add_security_headers ;;
        files)      add_file_protection ;;
        methods)    add_method_restriction ;;
        hotlink)    add_hotlink_protection ;;
        waf)        add_basic_waf ;;
        bots)       add_bad_bot_blocking ;;
        csp)        add_csp ;;
        path)       add_path_traversal_protection ;;
        all)        apply_all_security ;;
        remove)     remove_security ;;
        *)          echo "未知动作: $action"; exit 1 ;;
    esac
    inject_include "$SELECTED_CONF" "$SELECTED_SNIPPET"
    nginx -t && systemctl reload nginx && success "已生效" || die "配置错误"
}

main "$@"
