#!/bin/bash
# ============================================================
#  nginx-harden.sh — Nginx 自动化安全加固脚本
#  功能：隐藏版本 / 安全响应头 / 请求方法限制 / 缓冲区防溢出 / 防爬虫
#  系统：Ubuntu / Debian / CentOS / RHEL / Arch
# ============================================================
set -euo pipefail
shopt -s extglob

# ──────────────────────────────────────────────────────────
# 全局配置
# ──────────────────────────────────────────────────────────
NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx}"
CONF_D_DIR="${NGINX_CONF_DIR}/conf.d"
SNIPPETS_DIR="${NGINX_CONF_DIR}/snippets"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/nginx-harden}"
LOG_FILE="/var/log/nginx-harden.log"

# ──────────────────────────────────────────────────────────
# 颜色 & 日志工具
# ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

_log() { echo -e "$*" | tee -a "$LOG_FILE" 1>&2; }
info()    { _log "${CYAN}[信息]${NC}  $*"; }
success() { _log "${GREEN}[成功]${NC}  $*"; }
warn()    { _log "${YELLOW}[警告]${NC}  $*"; }
error()   { _log "${RED}[错误]${NC}  $*"; }
die()     { error "$*"; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "请以 root 身份运行本脚本（sudo $0）"
}

safe_read() {
    set +e
    read -r "$@"
    local _rc=$?
    set -e
    return $_rc
}

confirm() {
    local _ans
    safe_read -rp "${YELLOW}$1 [y/N]${NC} " _ans
    [[ ${_ans,,} == "y" ]]
}

init_env() {
    mkdir -p "$CONF_D_DIR" "$SNIPPETS_DIR" "$BACKUP_DIR" "$(dirname "$LOG_FILE")"
    if ! command -v nginx &>/dev/null; then
        die "未检测到 Nginx，请先安装 Nginx"
    fi
}

nginx_reload() {
    info "检查 Nginx 配置语法..."
    nginx -t 2>&1 >&2 || die "Nginx 配置检查失败，请检查刚刚生成的配置"
    systemctl reload nginx
    success "Nginx 已重载"
}

# ──────────────────────────────────────────────────────────
# 加固模块
# ──────────────────────────────────────────────────────────

# 1. 隐藏 Nginx 版本号
harden_server_tokens() {
    local conf="${CONF_D_DIR}/90-security-tokens.conf"
    echo "server_tokens off;" > "$conf"
    success "已隐藏 Nginx 版本号 (server_tokens off) -> $conf"
}

# 2. 添加全局安全响应头
harden_security_headers() {
    local conf="${CONF_D_DIR}/91-security-headers.conf"
    cat > "$conf" <<'EOF'
# X-Frame-Options: 防止点击劫持 (Clickjacking)
add_header X-Frame-Options "SAMEORIGIN" always;

# X-XSS-Protection: 启用浏览器内置 XSS 过滤
add_header X-XSS-Protection "1; mode=block" always;

# X-Content-Type-Options: 禁止浏览器 MIME 类型嗅探
add_header X-Content-Type-Options "nosniff" always;

# Referrer-Policy: 跨域时仅发送同源 Referrer，保护隐私
add_header Referrer-Policy "strict-origin-when-cross-origin" always;

# Strict-Transport-Security: 强制 HTTPS (HSTS)，仅在 HTTPS 协议下生效
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
EOF
    success "全局安全响应头已配置 -> $conf"
}

# 3. 限制 HTTP 请求方法 (需区分是否使用 WebDAV)
harden_http_methods() {
    local conf="${SNIPPETS_DIR}/secure-methods.conf"
    
    echo ""
    warn "严格限制请求方法可以有效防范非法探测。"
    info "如果此服务器运行了 Alist 等依赖 WebDAV 的应用，请务必选择兼容模式。"
    echo "  1) 严格模式: 仅允许 GET, HEAD, POST"
    echo "  2) WebDAV 兼容模式: 允许 GET, POST, PUT, DELETE, MKCOL, PROPFIND, OPTIONS 等"
    safe_read -rp "请选择 [1-2，默认 1]: " _method_choice

    if [[ "${_method_choice}" == "2" ]]; then
        cat > "$conf" <<'EOF'
# WebDAV 兼容模式：拦截除 WebDAV 常用方法外的未知请求
if ($request_method !~ ^(GET|HEAD|POST|PUT|DELETE|MKCOL|COPY|MOVE|PROPFIND|OPTIONS)$) {
    return 405;
}
EOF
        success "已生成 WebDAV 兼容请求拦截规则 -> $conf"
    else
        cat > "$conf" <<'EOF'
# 严格模式：仅允许常规网页请求方法
if ($request_method !~ ^(GET|HEAD|POST)$) {
    return 405;
}
EOF
        success "已生成严格 HTTP 请求拦截规则 -> $conf"
    fi
    warn "注意: 你需要在具体站点的 server {} 块中添加 'include snippets/secure-methods.conf;' 才能生效"
}

# 4. 缓冲区与超时限制 (防范 Slowloris 和缓冲区溢出攻击)
harden_buffers_timeouts() {
    local conf="${CONF_D_DIR}/92-security-buffers.conf"
    
    echo ""
    info "如果您的站点(如 WordPress)经常需要上传大文件，请根据实际情况调整 client_max_body_size。"
    safe_read -rp "全局最大上传限制 (例如: 50M, 0为不限) [默认 50M]: " _max_body
    [[ -z "$_max_body" ]] && _max_body="50M"

    cat > "$conf" <<EOF
# 缓冲区与超时安全限制
client_body_buffer_size      128k;
client_header_buffer_size    1k;
large_client_header_buffers  4 8k;
client_max_body_size         ${_max_body};

# 降低超时时间，释放空闲连接，防范慢速攻击
client_body_timeout   10;
client_header_timeout 10;
keepalive_timeout     15;
send_timeout          10;
EOF
    success "缓冲区与超时安全限制已配置 -> $conf"
}

# 5. 阻止访问敏感文件 (.git, .env等)
harden_sensitive_files() {
    local conf="${SNIPPETS_DIR}/secure-files.conf"
    cat > "$conf" <<'EOF'
# 禁止访问隐藏文件和目录 (如 .git, .env, .htpasswd)
location ~ /\.(?!well-known\/) {
    deny all;
    access_log off;
    log_not_found off;
}

# 禁止访问常见的备份和配置敏感文件
location ~* (?:\.(?:bak|config|sql|fla|psd|ini|log|sh|inc|swp|dist)|~)$ {
    deny all;
    access_log off;
    log_not_found off;
}
EOF
    success "敏感文件屏蔽规则已生成 -> $conf"
    warn "注意: 你需要在具体站点的 server {} 块中添加 'include snippets/secure-files.conf;' 才能生效"
}

# 6. 一键应用所有默认安全配置
apply_all_hardening() {
    info "正在应用推荐的全局安全加固..."
    harden_server_tokens
    harden_security_headers
    harden_buffers_timeouts
    
    info "正在生成 Server 级引用片段..."
    # 模拟默认选 1 (或传入参数免交互) 
    echo 'if ($request_method !~ ^(GET|HEAD|POST|PUT|DELETE|MKCOL|COPY|MOVE|PROPFIND|OPTIONS)$) { return 405; }' > "${SNIPPETS_DIR}/secure-methods.conf"
    success "已生成默认请求拦截规则 (兼容WebDAV) -> ${SNIPPETS_DIR}/secure-methods.conf"
    
    cat > "${SNIPPETS_DIR}/secure-files.conf" <<'EOF'
location ~ /\.(?!well-known\/) { deny all; access_log off; log_not_found off; }
location ~* (?:\.(?:bak|config|sql|fla|psd|ini|log|sh|inc|swp|dist)|~)$ { deny all; access_log off; log_not_found off; }
EOF
    success "敏感文件屏蔽规则已生成 -> ${SNIPPETS_DIR}/secure-files.conf"
    
    echo ""
    info "全局配置已自动生效。对于各个站点，请编辑其配置文件并注入以下代码："
    echo -e "${CYAN}    include snippets/secure-methods.conf;${NC}"
    echo -e "${CYAN}    include snippets/secure-files.conf;${NC}"
    
    nginx_reload
}

# 撤销加固
revert_hardening() {
    confirm "是否移除由本脚本生成的所有全局 Nginx 安全配置文件？" || return
    rm -f "${CONF_D_DIR}/90-security-tokens.conf"
    rm -f "${CONF_D_DIR}/91-security-headers.conf"
    rm -f "${CONF_D_DIR}/92-security-buffers.conf"
    rm -f "${SNIPPETS_DIR}/secure-methods.conf"
    rm -f "${SNIPPETS_DIR}/secure-files.conf"
    success "加固配置已移除。"
    nginx_reload
}


# ──────────────────────────────────────────────────────────
# 交互式主菜单
# ──────────────────────────────────────────────────────────
interactive_menu() {
    while true; do
        clear
        echo -e "${BOLD}${GREEN}"
        echo "  ╔════════════════════════════════════════════════╗"
        echo "  ║             Nginx 安全加固工具                 ║"
        echo "  ╚════════════════════════════════════════════════╝"
        echo -e "${NC}"
        echo -e " ${CYAN}── 自动加固 ──${NC}"
        echo "  1) 一键应用推荐安全配置 (全局+片段)"
        echo ""
        echo -e " ${CYAN}── 精细配置 ──${NC}"
        echo "  2) 隐藏版本号 (server_tokens off)"
        echo "  3) 配置安全响应头 (HSTS, XSS防护等)"
        echo "  4) 生成限制请求方法规则"
        echo "  5) 调整缓冲区大小与超时 (防慢速攻击)"
        echo "  6) 生成禁止访问隐藏文件/敏感文件规则"
        echo ""
        echo -e " ${CYAN}── 维护 ──${NC}"
        echo "  7) 重载 Nginx 配置"
        echo "  8) 撤销所有加固配置"
        echo "  0) 退出"
        echo ""
        safe_read -rp "请选择 [0-8]: " choice

        case "$choice" in
            1) apply_all_hardening; safe_read -rp "按回车继续..." _ ;;
            2) harden_server_tokens; nginx_reload; safe_read -rp "按回车继续..." _ ;;
            3) harden_security_headers; nginx_reload; safe_read -rp "按回车继续..." _ ;;
            4) harden_http_methods; safe_read -rp "按回车继续..." _ ;;
            5) harden_buffers_timeouts; nginx_reload; safe_read -rp "按回车继续..." _ ;;
            6) harden_sensitive_files; safe_read -rp "按回车继续..." _ ;;
            7) nginx_reload; safe_read -rp "按回车继续..." _ ;;
            8) revert_hardening; safe_read -rp "按回车继续..." _ ;;
            0) echo "再见！"; exit 0 ;;
            *) warn "无效选项，请重试" ;;
        esac
    done
}

main() {
    require_root
    init_env
    
    if [[ $# -eq 0 ]]; then
        interactive_menu
        exit 0
    fi
}

main "$@"
