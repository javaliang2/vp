#!/bin/bash
# ============================================================
#  nginx-web-security.sh — Nginx Web 安全加固 (CDN 隔离完整版)
#  配合 nginx-gateway.sh 使用，专注通用 Web 安全
#  功能：安全头 / 路径防护 / 防盗链 / WAF / CSP / 爬虫封锁 / 隐藏版本
#        后台访问限制（支持 Cloudflare CDN 双 Server 隔离）
#  不包含 SSL 强化（主脚本已处理）和 WordPress 特殊规则（避免冲突）
# ============================================================
set -euo pipefail
shopt -s extglob

# ──────────────────────────────────────────────────────────
# 全局配置
# ──────────────────────────────────────────────────────────
NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx}"
SITES_AVAILABLE="${NGINX_CONF_DIR}/sites-available"
SITES_ENABLED="${SITES_DIR:-${NGINX_CONF_DIR}/sites-enabled}"
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
# 工具：列出所有站点，供用户选择（跳过系统保护配置和内网管理配置）
# ──────────────────────────────────────────────────────────
list_domains() {
    local -a domains=()
    for conf in "${SITES_AVAILABLE}"/*.conf; do
        [[ -f "$conf" ]] || continue
        local name; name=$(basename "$conf" .conf)
        # 跳过系统保护配置和内网专用 Server
        [[ "$name" == 00-* || "$name" == 10-* ]] && continue
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
    # 使用 # 作为 s 命令分隔符，地址范围也用 \#...# 避免转义斜杠
    if grep -qE '^[[:space:]]*location[[:space:]]+/[[:space:]]*{' "$conf"; then
        sed -i "\#^[[:space:]]*location[[:space:]]*/[[:space:]]*{# s##${marker}\n&#" "$conf"
    else
        sed -i "\$i ${marker}" "$conf"
    fi
    info "已将安全配置引入站点: $conf"
}

# ──────────────────────────────────────────────────────────
# 自动获取 WireGuard 接口 IPv4（取第一个）
# ──────────────────────────────────────────────────────────
get_wg_ip() {
    local ip
    ip=$(ip -4 addr show wg0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    echo "${ip:-10.0.0.1}"
}

# ──────────────────────────────────────────────────────────
# 从站点配置中提取 SSL 证书路径（假设只使用第一个 server 块的证书）
# ──────────────────────────────────────────────────────────
get_ssl_cert_paths() {
    local conf="$1"
    SSL_CERT=$(grep -m1 '^\s*ssl_certificate\s' "$conf" | sed -E 's/.*ssl_certificate\s+//;s/;//')
    SSL_KEY=$(grep -m1 '^\s*ssl_certificate_key\s' "$conf" | sed -E 's/.*ssl_certificate_key\s+//;s/;//')
    [[ -z "$SSL_CERT" || -z "$SSL_KEY" ]] && die "无法从 $conf 读取 SSL 证书路径，请手动指定"
    info "SSL 证书: $SSL_CERT"
    info "SSL 私钥: $SSL_KEY"
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

# ============================================================
# 新增：自动提取原站点配置中的后端处理指令
# ============================================================
extract_backend_block() {
    local conf="$1"
    EXTRACTED_BACKEND=""
    EXTRACTED_BACKEND=$(awk '
        /^[[:space:]]*location[[:space:]]/ && !inside {
            inside = 1; brace = 0; inner = ""
            # 计算当前行花括号数量
            line = $0; gsub(/[^{}]/, "", line)
            for (i = 1; i <= length(line); i++) {
                c = substr(line, i, 1)
                if (c == "{") brace++
                else if (c == "}") brace--
            }
            if (brace == 0) {
                # 单行 location / { ... }，提取 { 和 } 之间的内容
                split($0, parts, /{/)
                if (length(parts) > 1) {
                    inner = parts[2]
                    sub(/}[[:space:]]*$/, "", inner)
                }
                if (inner ~ /(proxy_pass|fastcgi_pass)/) {
                    print inner
                    exit
                }
                inside = 0
            } else {
                # 多行块：跳过当前行（只包含 {），下一行开始收集内部内容
                next
            }
        }
        inside {
            # 统计当前行的花括号，更新 brace 深度
            line = $0; gsub(/[^{}]/, "", line)
            for (i = 1; i <= length(line); i++) {
                c = substr(line, i, 1)
                if (c == "{") brace++
                else if (c == "}") brace--
            }
            # 如果已经到达闭合括号 (brace <= 0)，说明当前行包含结尾的 }
            if (brace <= 0) {
                # 去掉本行末尾的 } 及其后空白
                sub(/}[[:space:]]*$/, "", $0)
                inner = inner $0 "\n"
                # 去掉最终可能的换行
                sub(/[[:space:]]+$/, "", inner)
                if (inner ~ /(proxy_pass|fastcgi_pass)/) {
                    print inner
                    exit
                }
                inside = 0
                next
            }
            # 否则是正常内部行，直接追加
            inner = inner $0 "\n"
        }
    ' "$conf")

    if [[ -n "$EXTRACTED_BACKEND" ]]; then
        info "已自动提取后端配置（已去除花括号）："
        echo "$EXTRACTED_BACKEND" | sed 's/^/  /'
    else
        warn "未能自动提取后端配置，将进入手动输入模式"
    fi
}

# ============================================================
# 10. 后台访问限制（支持 CDN 双 Server 隔离 + 自动提取后端）
# ============================================================
add_admin_access_restriction() {
    local paths allowed_network
    echo -e "${CYAN}配置后台访问限制 – 仅允许 WireGuard 内网访问管理页面${NC}"
    safe_read -rp "请输入需要保护的后台路径（空格分隔）[默认: wp-admin wp-login.php xmlrpc.php]: " paths
    # 清理并应用默认值
    paths=$(echo "$paths" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g')
    [[ -z "$paths" ]] && paths="wp-admin wp-login.php xmlrpc.php"

    local use_cdn
    safe_read -rp "当前站点是否使用 Cloudflare CDN？[Y/n]: " use_cdn
    use_cdn="${use_cdn:-y}"
    if [[ "${use_cdn,,}" == "y" ]]; then
        echo -e "${YELLOW}检测到 CDN 环境，将创建内网专用 Server 隔离后台。${NC}"
        local wg_ip wg_port
        safe_read -rp "WireGuard 内网监听 IP [默认: $(get_wg_ip)]: " wg_ip
        wg_ip="${wg_ip:-$(get_wg_ip)}"
        safe_read -rp "内网 Server 监听端口 [默认: 443]: " wg_port
        wg_port="${wg_port:-443}"

        get_ssl_cert_paths "$SELECTED_CONF"

        # 公网封锁规则
        cat > "$SELECTED_SNIPPET" <<CDN_BLOCK
# ---- 后台路径公网封锁（CDN 环境） ----
# 使用 = 和 ^~ 确保最高优先级，不会被其他 location 绕过
location ^~ /wp-admin/ { deny all; }
location = /wp-admin  { deny all; }
location = /wp-login.php { deny all; }
location = /xmlrpc.php   { deny all; }
CDN_BLOCK
        inject_include "$SELECTED_CONF" "$SELECTED_SNIPPET"

        # 自动提取后端处理指令
        local auto_extract
        safe_read -rp "是否自动从原站配置提取后端处理指令？[Y/n]: " auto_extract
        auto_extract="${auto_extract:-y}"
        local backend_block=""
        if [[ "${auto_extract,,}" == "y" ]]; then
            extract_backend_block "$SELECTED_CONF"
            backend_block="$EXTRACTED_BACKEND"
        fi
        if [[ -z "$backend_block" ]]; then
            echo -e "${YELLOW}请手动输入后端处理指令（例如 proxy_pass http://wp_backend; 或 fastcgi_pass ...;）${NC}"
            echo "输入完成后在新行输入 END 结束："
            backend_block=""
            while IFS= read -r line; do
                [[ "$line" == "END" ]] && break
                backend_block+="$line"$'\n'
            done
        fi

        # 保证指令有合适的缩进（每行前加 8 个空格）
        backend_block=$(echo "$backend_block" | sed 's/^/        /')

        local internal_conf="${SITES_AVAILABLE}/10-admin-${SELECTED_DOMAIN}.conf"
        cat > "$internal_conf" <<INTERNAL_SERVER
# ---- 内网后台访问 Server (WireGuard 直连) ----
server {
    listen ${wg_ip}:${wg_port} ssl http2;
    server_name ${SELECTED_DOMAIN};

    ssl_certificate     ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
    # include snippets/ssl-params.conf;  # 若有可取消注释

    location ~ ^/(${paths// /|}) {
        allow 10.0.0.0/8;
        deny all;

${backend_block}
    }

    location / {
        return 404;
    }
}
INTERNAL_SERVER

        ln -sf "$internal_conf" "${SITES_ENABLED}/10-admin-${SELECTED_DOMAIN}.conf"
        success "内网专用 Server 已创建: $internal_conf"
        success "请确保管理设备通过 WireGuard 访问 https://${wg_ip}:${wg_port}/wp-admin"

    else
        # 非 CDN 直连模式
        safe_read -rp "允许访问的内网 IP 段 [默认: 10.0.0.0/8]: " allowed_network
        allowed_network="${allowed_network:-10.0.0.0/8}"
        cat > "$SELECTED_SNIPPET" <<DIRECT_IP
# ---- 后台访问限制 (直连模式) ----
location ^~ /wp-admin/ { allow ${allowed_network}; deny all; }
location = /wp-admin  { allow ${allowed_network}; deny all; }
location = /wp-login.php { allow ${allowed_network}; deny all; }
location = /xmlrpc.php   { allow ${allowed_network}; deny all; }
DIRECT_IP
        inject_include "$SELECTED_CONF" "$SELECTED_SNIPPET"
        success "已添加直连模式 IP 限制，仅 ${allowed_network} 可访问后台。"
    fi
}

# ──────────────────────────────────────────────────────────
# 一键全部加固（不包含后台访问限制，避免误操作）
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
    # 后台限制需手动执行，避免误封

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
# 移除安全配置（包括内网 Server）
# ──────────────────────────────────────────────────────────
remove_security() {
    list_domains
    # 移除公网 snippet 引用
    if [[ -f "$SELECTED_SNIPPET" ]]; then
        rm -f "$SELECTED_SNIPPET"
        success "已删除安全片段: $SELECTED_SNIPPET"
    fi
    if grep -qF "include ${SELECTED_SNIPPET};" "$SELECTED_CONF"; then
        sed -i "\|include ${SELECTED_SNIPPET};|d" "$SELECTED_CONF"
        success "已从站点配置中移除 include"
    fi
    # 移除可能的内网 Server
    local internal_conf="${SITES_AVAILABLE}/10-admin-${SELECTED_DOMAIN}.conf"
    if [[ -f "$internal_conf" ]]; then
        rm -f "$internal_conf"
        rm -f "${SITES_ENABLED}/10-admin-${SELECTED_DOMAIN}.conf"
        success "已删除内网后台 Server: $internal_conf"
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
        echo "  ║      Nginx Web 安全加固 (CDN 隔离版)          ║"
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
        echo -e " ${CYAN}10)${NC} 后台访问限制 (WordPress/CDN 双 Server 隔离)"
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
            10)
                list_domains
                add_admin_access_restriction
                nginx -t && systemctl reload nginx && success "后台限制已生效" || die "配置错误，请检查"
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
        headers)
            echo "# headers" > "$SELECTED_SNIPPET"
            add_security_headers
            ;;
        files)
            echo "# files" > "$SELECTED_SNIPPET"
            add_file_protection
            ;;
        methods)
            echo "# methods" > "$SELECTED_SNIPPET"
            add_method_restriction
            ;;
        hotlink)
            echo "# hotlink" > "$SELECTED_SNIPPET"
            add_hotlink_protection
            ;;
        waf)
            echo "# waf" > "$SELECTED_SNIPPET"
            add_basic_waf
            ;;
        bots)
            echo "# bots" > "$SELECTED_SNIPPET"
            add_bad_bot_blocking
            ;;
        csp)
            echo "# csp" > "$SELECTED_SNIPPET"
            add_csp
            ;;
        path)
            echo "# path" > "$SELECTED_SNIPPET"
            add_path_traversal_protection
            ;;
        admin-restrict)
            add_admin_access_restriction
            ;;
        all)
            apply_all_security
            ;;
        remove)
            remove_security
            ;;
        *)
            echo "未知动作: $action"
            echo "可用动作: headers files methods hotlink waf bots csp path admin-restrict all remove"
            exit 1
            ;;
    esac

    # admin-restrict 内部已自行 inject_include，无需再次注入
    if [[ "$action" != "admin-restrict" && "$action" != "remove" && "$action" != "all" ]]; then
        inject_include "$SELECTED_CONF" "$SELECTED_SNIPPET"
    fi

    nginx -t && systemctl reload nginx && success "已生效" || die "配置错误"
}

main "$@"
