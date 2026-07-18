#!/bin/bash
# ============================================================
#  nginx-gateway.sh — Nginx 全功能网关管理脚本 (修复版)
#  融合：站点管理 / 证书申请 / 反向代理 / 镜像聚合 / 正向代理
#  系统：Ubuntu / Debian / CentOS / RHEL / Arch
# ============================================================
set -euo pipefail
shopt -s extglob

# ──────────────────────────────────────────────────────────
# 全局配置（可通过环境变量覆盖）
# ──────────────────────────────────────────────────────────
NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx}"
SITES_AVAILABLE="${NGINX_CONF_DIR}/sites-available"
SITES_DIR="${SITES_DIR:-${NGINX_CONF_DIR}/sites-enabled}"
CERT_DIR="${CERT_DIR:-${NGINX_CONF_DIR}/certs}"
SELF_CERT_DIR="${SELF_CERT_DIR:-${NGINX_CONF_DIR}/ssl}"
WEBROOT_BASE="${WEBROOT_BASE:-/var/www}"
LE_CERT_BASE="/etc/letsencrypt/live"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/nginx-gateway}"
LOG_FILE="/var/log/nginx-gateway.log"
SNIPPET_DIR="${NGINX_CONF_DIR}/snippets"
# FIX: 共享 ACME HTTP-01 验证目录。裸 IP 拦截块（00-block-ip.conf）默认会把
# 所有 Host 不匹配的请求 444 掉，这会连带把还没建站的新域名的验证请求也拦截，
# 导致 webroot / nginx 方式申请证书必然失败。让默认拦截块单独放行这个目录，
# 证书申请统一使用该目录作为 webroot，即可在建站前就完成验证。
ACME_WEBROOT="${ACME_WEBROOT:-${WEBROOT_BASE}/_acme-challenge}"
mkdir -p "$SNIPPET_DIR"
mkdir -p "${ACME_WEBROOT}/.well-known/acme-challenge" 2>/dev/null || true
chmod -R 755 "$ACME_WEBROOT" 2>/dev/null || true

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

# 安全读取用户输入（临时关闭 errexit，避免 read 遇到 EOF 退出）
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

init_dirs() {
    mkdir -p "$SITES_AVAILABLE" "$SITES_DIR" "$CERT_DIR" "$SELF_CERT_DIR" || true
    if ! touch "$LOG_FILE" 2>/dev/null; then
        warn "无法写入日志文件 $LOG_FILE，请检查权限或设置环境变量 LOG_FILE"
        LOG_FILE="/var/log/nginx-gateway.log"  # 不降级到 /tmp
    fi
    ensure_sites_enabled_include
    ensure_server_tokens_off
    ensure_slow_attack_protection
    _ensure_block_ip
    _ensure_gzip_conf
}

# 确保 nginx.conf 引入 sites-enabled（nginx.org 官方包默认不带这个约定，
# 只有 conf.d；缺失时脚本生成的所有站点配置和防扫描拦截都不会被加载，
# 且 nginx -t 不会报错——是最容易被忽略的一种"静默失败"，因此这里直接自动修复）
ensure_sites_enabled_include() {
    local ngxconf="${NGINX_CONF_DIR}/nginx.conf"
    [[ -f "$ngxconf" ]] || return 0
    grep -q "sites-enabled" "$ngxconf" && return 0
    if grep -qE '^\s*http\s*\{' "$ngxconf"; then
        cp "$ngxconf" "${ngxconf}.bak.$(date +%s)"
        sed -i '/^\s*http\s*{/a\    include /etc/nginx/sites-enabled/*;' "$ngxconf"
        # FIX: 保留 nginx -t 的真实输出。原来 &>/dev/null 吞掉报错，回滚后
        # 用户只看到"语法检查未通过"，看不出到底是这次改动的问题，还是
        # 系统里其它站点配置本来就是坏的（和这次改动无关）。
        local test_output
        if test_output=$(nginx -t 2>&1); then
            info "已在 nginx.conf 中添加 include /etc/nginx/sites-enabled/*;（原文件已备份）"
        else
            # 修改后语法检查不过，回滚，避免留下一个无法启动的 nginx.conf
            cp "${ngxconf}.bak."* "$ngxconf" 2>/dev/null
            warn "自动添加 sites-enabled include 后语法检查未通过，已回滚，请手动添加: include /etc/nginx/sites-enabled/*;"
            warn "nginx -t 真实报错如下（也可能是其它站点配置本身有问题，与本次改动无关）:"
            echo "$test_output" | tee -a "$LOG_FILE" 1>&2
        fi
    else
        warn "未能在 nginx.conf 中定位 http{} 块，请手动添加: include /etc/nginx/sites-enabled/*;"
    fi
}

# 防止路径为系统关键目录（防 rm -rf / 等误操作）
validate_safe_path() {
    local path="$1"
    local normalized
    if command -v realpath &>/dev/null; then
        normalized=$(realpath -m "$path")
    else
        normalized="$path"
    fi
    # 禁止的目录列表
    local forbidden=("/" "/bin" "/boot" "/dev" "/etc" "/lib" "/lib64" "/proc" "/root" "/sbin" "/sys" "/usr")
    for dir in "${forbidden[@]}"; do
        if [[ "$normalized" == "$dir" || "$normalized" == "$dir/"* && "$normalized" != "$WEBROOT_BASE/"* ]]; then
            # 只允许在 WEBROOT_BASE 内进行危险操作
            die "拒绝操作系统关键路径: $path"
        fi
    done
}

# FIX: normalize_url 增加空字符串守卫
normalize_url() {
    local url="${1%/}"
    [[ -z "$url" ]] && die "目标 URL 不能为空"
    [[ ! "$url" =~ ^https?:// ]] && url="http://$url"
    echo "$url"
}

# ──────────────────────────────────────────────────────────
# 内部工具函数
# ──────────────────────────────────────────────────────────

_check_port_conflict() {
    local port=$1
    if grep -rq "listen[[:space:]]\+${port}[; ]" "${SITES_AVAILABLE}/" 2>/dev/null; then
        warn "端口 ${port} 已在其他配置中使用，可能产生冲突"
    fi
}

_ensure_upgrade_map() {
    local map_conf="${NGINX_CONF_DIR}/conf.d/00-map-upgrade.conf"
    [[ -f "$map_conf" ]] && return 0
    mkdir -p "${NGINX_CONF_DIR}/conf.d" || true
    cat > "$map_conf" <<'EOF'
map $http_upgrade $connection_upgrade {
    default  upgrade;
    ''       close;
}
EOF
    info "已生成 WebSocket map 配置: $map_conf"
}

# 全局 gzip 压缩（conf.d 默认在 http{} 内被 include，无需逐站点写入）
_ensure_gzip_conf() {
    local gzip_conf="${NGINX_CONF_DIR}/conf.d/01-gzip.conf"
    [[ -f "$gzip_conf" ]] && return 0
    mkdir -p "${NGINX_CONF_DIR}/conf.d" || true
    cat > "$gzip_conf" <<'EOF'
gzip on;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 6;
gzip_min_length 256;
gzip_disable "msie6";
gzip_types
    text/plain
    text/css
    text/xml
    text/javascript
    application/javascript
    application/x-javascript
    application/json
    application/xml
    application/rss+xml
    application/atom+xml
    application/xml+rss
    application/vnd.ms-fontobject
    application/wasm
    font/ttf
    font/otf
    image/svg+xml;
EOF
    # FIX: 原来用 `nginx -t &>/dev/null` 做全局校验，一旦系统里有任何
    # 其它站点配置本身就是坏的（和这份 gzip 配置毫无关系），也会被判定
    # 为"gzip 校验未通过"并把这份完全正常的文件删掉，且看不到真实报错。
    # 现在：保留 nginx -t 的完整输出；只有报错明确指向这个文件本身时才
    # 删除它，否则保留文件、把真实错误打印出来，避免误判和信息丢失。
    local test_output
    if test_output=$(nginx -t 2>&1); then
        info "已生成全局 gzip 压缩配置: $gzip_conf"
    elif echo "$test_output" | grep -qF "$gzip_conf"; then
        # 极少数极旧版本 nginx 不识别个别 gzip_types，错误确实指向本文件才移除
        rm -f "$gzip_conf"
        warn "gzip 配置校验未通过，已跳过（不影响其他功能）:"
        echo "$test_output" | tee -a "$LOG_FILE" 1>&2
    else
        # 报错与 gzip 配置无关，说明是其它站点配置本身有问题；保留该文件，
        # 把真实的 nginx -t 报错打印出来，方便定位
        warn "nginx -t 校验失败，但错误与 gzip 配置无关（已保留该文件），请检查下方报错定位真实原因:"
        echo "$test_output" | tee -a "$LOG_FILE" 1>&2
    fi
}

# ──────────────────────────────────────────────────────────
# Nginx 安装与检测
# ──────────────────────────────────────────────────────────
detect_pkg_manager() {
    if   command -v apt-get &>/dev/null; then echo "apt"
    elif command -v dnf     &>/dev/null; then echo "dnf"
    elif command -v yum     &>/dev/null; then echo "yum"
    elif command -v pacman  &>/dev/null; then echo "pacman"
    else die "不支持的包管理器，请手动安装依赖"; fi
}

install_pkg() {
    local pkg="$1"
    local mgr; mgr=$(detect_pkg_manager)
    info "安装 ${pkg}..."
    case $mgr in
        apt)    apt-get install -y "$pkg" ;;
        dnf)    dnf install -y "$pkg" ;;
        yum)    yum install -y "$pkg" ;;
        pacman) pacman -Sy --noconfirm "$pkg" ;;
    esac
}

check_and_install_nginx() {
    info "检查 Nginx 安装状态..."
    if command -v nginx &>/dev/null; then
        success "Nginx 已安装: $(nginx -v 2>&1)"
        return 0
    fi
    warn "未检测到 Nginx，正在尝试自动安装..."
    local mgr; mgr=$(detect_pkg_manager)
    case $mgr in
        apt)        apt-get update -qq && apt-get install -y nginx ;;
        dnf|yum)    $mgr install -y nginx ;;
        pacman)     pacman -Sy --noconfirm nginx ;;
    esac
    systemctl enable nginx
    success "Nginx 安装成功: $(nginx -v 2>&1)"
}

nginx_reload() {
    info "检查 Nginx 配置语法..."
    nginx -t 2>&1 >&2 || die "Nginx 配置检查失败，请修正后重试"
    systemctl reload nginx
    success "Nginx 已重载"
}

nginx_restart() { require_root; systemctl restart nginx && success "Nginx 已重启"; }
nginx_status()  { systemctl status nginx; }

nginx_update() {
    require_root
    command -v nginx &>/dev/null || die "未检测到 Nginx，请先执行: $0 nginx install"
    local old_ver; old_ver=$(nginx -v 2>&1)
    info "当前版本: ${old_ver}"
    info "正在检查更新..."
    local mgr; mgr=$(detect_pkg_manager)
    case $mgr in
        apt)     apt-get update -qq && apt-get install --only-upgrade -y nginx ;;
        dnf|yum) $mgr update -y nginx ;;
        pacman)  pacman -Sy --noconfirm nginx ;;
    esac
    nginx -t 2>&1 >&2 || die "更新后配置检查失败，请检查兼容性后再重启"
    systemctl restart nginx
    local new_ver; new_ver=$(nginx -v 2>&1)
    if [[ "$old_ver" == "$new_ver" ]]; then
        success "Nginx 已是最新版本: ${new_ver}"
    else
        success "Nginx 已更新: ${old_ver} → ${new_ver}"
    fi
}

check_sub_filter_module() {
    if ! nginx -V 2>&1 | grep -q "http_sub_module"; then
        warn "当前 Nginx 未编译 http_sub_module，镜像模式的内容替换功能不可用。"
        warn "Debian/Ubuntu 可执行: apt install nginx-full"
        safe_read -rp "是否仍继续生成配置？[y/N]: " _c
        [[ "${_c,,}" == "y" ]] || exit 0
    fi
}

# ──────────────────────────────────────────────────────────
# Cloudflare 真实 IP
# set_real_ip_from 只信任来自 Cloudflare 官方 IP 段的连接，非 Cloudflare
# 直连请求不受影响，因此全局启用是安全的；不启用时，凡是站点在 Cloudflare
# 之后，limit_req / ACL / access_log 拿到的都是 CF 边缘节点 IP 而非真实访客 IP。
# ──────────────────────────────────────────────────────────
CF_REALIP_CONF="${NGINX_CONF_DIR}/conf.d/02-cf-realip.conf"

ensure_curl() { command -v curl &>/dev/null || install_pkg curl; }

check_realip_module() {
    if ! nginx -V 2>&1 | grep -q "http_realip_module"; then
        warn "当前 Nginx 未编译 http_realip_module，无法识别 Cloudflare 真实 IP。"
        warn "Debian/Ubuntu 可执行: apt install nginx-full"
        return 1
    fi
    return 0
}

# 内置一份 Cloudflare IP 段快照（生成于脚本编写时），仅在抓取官方接口失败时
# 兜底使用，可能滞后，网络恢复后建议重新执行 cf-realip 刷新
_cf_ip_fallback_v4() {
    cat <<'EOF'
173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
108.162.192.0/18
190.93.240.0/20
188.114.96.0/20
197.234.240.0/22
198.41.128.0/17
162.158.0.0/15
104.16.0.0/13
104.24.0.0/14
172.64.0.0/13
131.0.72.0/22
EOF
}

_cf_ip_fallback_v6() {
    cat <<'EOF'
2400:cb00::/32
2606:4700::/32
2803:f800::/32
2405:b500::/32
2405:8100::/32
2a06:98c0::/29
2c0f:f248::/32
EOF
}

cf_realip_update() {
    require_root
    check_realip_module || { confirm "是否仍继续生成配置（重载时可能报错）？" || exit 0; }
    ensure_curl

    info "正在获取 Cloudflare 官方 IP 段..."
    local v4 v6 source
    v4=$(curl -fsSL --max-time 8 https://www.cloudflare.com/ips-v4 2>/dev/null || true)
    v6=$(curl -fsSL --max-time 8 https://www.cloudflare.com/ips-v6 2>/dev/null || true)

    if [[ -z "$v4" || -z "$v6" ]]; then
        warn "获取 Cloudflare 官方 IP 段失败（网络不通？），使用内置快照兜底"
        warn "建议网络恢复后重新执行: $0 security cf-realip"
        v4=$(_cf_ip_fallback_v4)
        v6=$(_cf_ip_fallback_v6)
        source="内置快照（可能滞后）"
    else
        source="官方接口 (cloudflare.com/ips-v4, ips-v6)"
    fi

    mkdir -p "${NGINX_CONF_DIR}/conf.d" || true
    {
        echo "# Cloudflare 真实 IP 配置 — 数据来源: ${source}"
        echo "# 生成时间: $(date)"
        echo "# 仅信任来自以下 Cloudflare 官方 IP 段的 CF-Connecting-IP 头，"
        echo "# 非 Cloudflare 直连请求不受影响。手动刷新: $0 security cf-realip"
        while IFS= read -r ip; do
            [[ -n "$ip" ]] && echo "set_real_ip_from ${ip};"
        done <<< "$v4"
        while IFS= read -r ip; do
            [[ -n "$ip" ]] && echo "set_real_ip_from ${ip};"
        done <<< "$v6"
        echo "real_ip_header CF-Connecting-IP;"
        echo "real_ip_recursive on;"
    } > "$CF_REALIP_CONF"

    local test_output
    if test_output=$(nginx -t 2>&1); then
        success "Cloudflare 真实 IP 配置已生成: $CF_REALIP_CONF"
        nginx_reload
        info "limit_req / ACL / access_log 现在会基于访客真实 IP 生效（而非 Cloudflare 边缘 IP）"
    else
        rm -f "$CF_REALIP_CONF"
        error "配置校验未通过，已回滚（也可能是其它站点配置本身有问题，与本次改动无关），真实报错如下:"
        echo "$test_output" | tee -a "$LOG_FILE" 1>&2
        die "请确认 Nginx 已编译 http_realip_module，或先排查上方报错"
    fi
}

cf_realip_remove() {
    require_root
    if [[ -f "$CF_REALIP_CONF" ]]; then
        rm -f "$CF_REALIP_CONF"
        nginx_reload
        success "已移除 Cloudflare 真实 IP 配置"
    else
        info "未找到 Cloudflare 真实 IP 配置，无需移除"
    fi
}

cmd_cf_realip() {
    require_root; init_dirs
    local action="${1:-status}"
    case "$action" in
        install)
            warn "该操作会让本机所有站点信任 CF-Connecting-IP 头，请确认本机所有对外站点均已接入 Cloudflare"
            confirm "确认启用 Cloudflare 真实 IP 还原？" || { info "已取消"; return 0; }
            cf_realip_update
            ;;
        refresh)
            [[ -f "$CF_REALIP_CONF" ]] || die "尚未安装，请先执行: $0 cf-realip install"
            cf_realip_update
            ;;
        remove) cf_realip_remove ;;
        status)
            if [[ -f "$CF_REALIP_CONF" ]]; then
                success "已启用，配置文件: $CF_REALIP_CONF（生成时间: $(stat -c %y "$CF_REALIP_CONF" 2>/dev/null || stat -f %Sm "$CF_REALIP_CONF" 2>/dev/null)）"
            else
                info "未启用。执行 $0 cf-realip install 以启用"
            fi
            ;;
        *) die "用法: $0 cf-realip <install|refresh|remove|status>" ;;
    esac
}

# 供基于 IP 的 ACL / 限流调用：若站点在 Cloudflare 后面而真实 IP 还原
# 未启用，$remote_addr 拿到的是 CF 边缘 IP，白名单/黑名单/限流全部失效。
_maybe_prompt_cf_realip() {
    [[ -f "$CF_REALIP_CONF" ]] && return 0

    local _ans=""
    safe_read -rp "该站点是否经由 Cloudflare 代理? (y/N): " _ans
    if [[ "${_ans,,}" == "y" || "${_ans,,}" == "yes" ]]; then
        warn "未启用 Cloudflare 真实 IP 还原：当前 IP 白/黑名单和限流会按 Cloudflare 边缘 IP 生效，起不到实际限制作用"
        if confirm "是否现在启用真实 IP 还原（全局生效，影响本机所有站点，请确认均已接入 Cloudflare）？"; then
            cf_realip_update
        else
            warn "已跳过，可稍后执行: $0 cf-realip install"
        fi
    fi
}

# ──────────────────────────────────────────────────────────
# 智能证书扫描（改进版：验证证书与域名的匹配）
# ──────────────────────────────────────────────────────────
CERT_PATH=""
KEY_PATH=""

find_certs_advanced() {
    local domain="$1"
    CERT_PATH=""; KEY_PATH=""

    local search_dirs=(
        "${CERT_DIR}/${domain}"
        "${LE_CERT_BASE}/${domain}"
        "/root/.acme.sh/${domain}_ecc"
        "/root/.acme.sh/${domain}"
        "${SELF_CERT_DIR}/${domain}"
        "/etc/ssl/${domain}"
        "/etc/nginx/certs/${domain}"
    )

    local c_names=("fullchain.pem" "fullchain.cer" "server.crt" "${domain}.cer" "cert.pem")
    local k_names=("privkey.pem" "server.key" "${domain}.key" "cert.key" "key.pem")

    for dir in "${search_dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        # 证书查找
        for f in "${c_names[@]}"; do
            if [[ -f "${dir}/${f}" ]]; then
                CERT_PATH="${dir}/${f}"
                break
            fi
        done
        # 私钥查找
        for f in "${k_names[@]}"; do
            if [[ -f "${dir}/${f}" ]]; then
                KEY_PATH="${dir}/${f}"
                break
            fi
        done
        # 未找到则尝试 grep 扫描
        if [[ -z "$CERT_PATH" ]]; then
            CERT_PATH=$(grep -rl "BEGIN CERTIFICATE" "$dir" 2>/dev/null \
                        | grep -E '\.(pem|crt|cer)$' | head -n 1 || true)
        fi
        if [[ -z "$KEY_PATH" ]]; then
            KEY_PATH=$(grep -rl "PRIVATE KEY" "$dir" 2>/dev/null \
                       | grep -E '\.(pem|key)$' | head -n 1 || true)
        fi

        # 验证证书是否与域名匹配（仅当找到证书时）
        if [[ -n "$CERT_PATH" && -n "$KEY_PATH" ]]; then
            local cert_cn
            cert_cn=$(openssl x509 -noout -subject -in "$CERT_PATH" 2>/dev/null \
                      | sed -n 's/.*CN *= *//p')
            if [[ "$cert_cn" != "$domain" && "$cert_cn" != *".${domain}" ]]; then
                warn "证书 CN=$cert_cn 与域名 $domain 不匹配，忽略此路径"
                CERT_PATH=""; KEY_PATH=""
                continue
            fi
            return 0
        fi
    done
    return 1
}

# ──────────────────────────────────────────────────────────
# 通用安全响应头（server 级，随 ssl_block 一并写入）
# 注意：若某 location 自身也用了 add_header（如静态资源的
# Cache-Control），该 location 会丢失此处继承的头，需在那里
# 重复声明，避免重现 gateway/harden 脚本间的 add_header 覆盖问题。
# ──────────────────────────────────────────────────────────
security_headers_lines() {
    cat <<'EOF'
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
EOF
}

# 拒绝非常规 HTTP 方法（TRACE/CONNECT/自定义方法等），常用于探测/扫描
deny_dangerous_methods_lines() {
    cat <<'EOF'
    if ($request_method !~ ^(GET|HEAD|POST|PUT|DELETE|PATCH)$) { return 444; }
EOF
}

# 拦截备份/临时文件（.bak/.sql/编辑器交换文件/波浪号结尾等），
# 与已有的 `location ~ /\.` （点开头隐藏文件）互补
deny_sensitive_files_lines() {
    cat <<'EOF'
    location ~* \.(bak|backup|sql|sqlite|swp|swo|save|old|orig|dist)$ { deny all; }
    location ~ ~$ { deny all; }
EOF
}

# 反代场景隐藏后端技术栈信息，避免暴露后端框架/中间件版本
proxy_hide_backend_headers_lines() {
    cat <<'EOF'
        proxy_hide_header X-Powered-By;
        proxy_hide_header Server;
EOF
}

# 大文件上传/下载优化（网盘、文件管理类应用，如 AList/Nextcloud）：
# 默认 60s 的 proxy_read_timeout/proxy_send_timeout 在传输大文件时容易触发
# 504；同时关闭 proxy_request_buffering，避免 nginx 把整个请求体落盘缓冲
# 后再转发给后端，减少一次磁盘 I/O、加快断点续传/分片上传的响应速度。
ask_large_upload_optimization() {
    local _ans=""
    safe_read -rp "是否针对大文件上传/下载优化（网盘、文件管理类应用，如 AList）？[y/N]: " _ans
    if [[ "${_ans,,}" == "y" || "${_ans,,}" == "yes" ]]; then
        _LARGE_UPLOAD=true
    else
        _LARGE_UPLOAD=false
    fi
}

large_upload_lines() {
    [[ "${_LARGE_UPLOAD:-false}" == true ]] || return 0
    cat <<'EOF'
        proxy_request_buffering  off;
        proxy_read_timeout       7200s;
        proxy_send_timeout       7200s;
        client_body_timeout      7200s;
EOF
}

# 隐藏 Nginx 版本号（server_tokens off，写入 nginx.conf 的 http{} 块）
ensure_server_tokens_off() {
    local ngxconf="${NGINX_CONF_DIR}/nginx.conf"
    [[ -f "$ngxconf" ]] || return 0
    grep -qE '^\s*server_tokens\s+off\s*;' "$ngxconf" && return 0
    if grep -qE '^\s*http\s*\{' "$ngxconf"; then
        sed -i '/^\s*http\s*{/a\    server_tokens off;' "$ngxconf"
        info "已在 nginx.conf 中添加 server_tokens off;（隐藏版本号）"
    else
        warn "未能在 nginx.conf 中定位 http{} 块，请手动添加: server_tokens off;"
    fi
}

# 防慢速攻击（Slowloris 等）+ 请求体大小限制，写入 nginx.conf 的 http{} 块
ensure_slow_attack_protection() {
    local ngxconf="${NGINX_CONF_DIR}/nginx.conf"
    [[ -f "$ngxconf" ]] || return 0
    grep -qE '^\s*client_body_timeout\s' "$ngxconf" && return 0
    if grep -qE '^\s*http\s*\{' "$ngxconf"; then
        sed -i '/^\s*http\s*{/a\
    client_body_timeout 10s;\
    client_header_timeout 10s;\
    send_timeout 10s;\
    client_max_body_size 50m;' "$ngxconf"
        info "已在 nginx.conf 中添加慢速攻击防护参数（超时 10s + 请求体上限 50m）"
        warn "client_max_body_size 默认 50m，若某站点需要更大上传（如 WordPress 媒体库），可在该站点配置里单独覆盖此指令"
    else
        warn "未能在 nginx.conf 中定位 http{} 块，请手动添加防慢速攻击参数"
    fi
}

# 注：裸 IP / 未知 Host 的兜底拦截统一由 _ensure_block_ip() 负责
# （原 ensure_default_catchall 已移除——两者都声明 default_server，
#  同时存在会导致 nginx -t 报 "duplicate default server" 而重载失败）

# ──────────────────────────────────────────────────────────
# HTTP/2（1.25.1+ 用独立的 http2 on; 指令；旧版仍用 listen ... http2;
#  两种语法混用会导致 nginx -t 报 "invalid parameter http2" 或告警，
#  必须按实际版本二选一）
# ──────────────────────────────────────────────────────────
_http2_new_syntax() {
    local ver maj min patch
    ver=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [[ -z "$ver" ]] && return 1
    IFS='.' read -r maj min patch <<< "$ver"
    (( maj > 1 )) && return 0
    (( maj == 1 && min > 25 )) && return 0
    (( maj == 1 && min == 25 && patch >= 1 )) && return 0
    return 1
}

# FIX: resolver 去重。proxy/mirror 站点原来固定写死一行 resolver 用于
# 动态解析后端域名，但当 SSL 模式非 none/self 时，ssl_block() 为了 OCSP
# stapling 也会再输出一次 resolver，两条指令落在同一个 server{} 块里，
# 会导致 nginx -t 报 "resolver" directive is duplicate 而失败。
# 这里统一只输出一次：SSL 模式为 none/self（ssl_block 不会输出 resolver）
# 时才在这里输出；其余情况交给 ssl_block 输出的那一条即可。
emit_resolver_line() {
    if [[ "$_SSL_MODE" == "none" || "$_SSL_MODE" == "self" ]]; then
        echo "    resolver    1.1.1.1 8.8.8.8 valid=300s;"
    fi
}

# 输出一对 SSL 监听指令并按版本自动开启 HTTP/2
emit_ssl_listen_lines() {
    local port="$1"
    if _http2_new_syntax; then
        echo "    listen ${port} ssl;"
        echo "    listen [::]:${port} ssl;"
        echo "    http2 on;"
    else
        echo "    listen ${port} ssl http2;"
        echo "    listen [::]:${port} ssl http2;"
    fi
}

# ──────────────────────────────────────────────────────────
# 通用 SSL 安全配置块
# ──────────────────────────────────────────────────────────
ssl_block() {
    local cert="$1" key="$2" hsts="${3:-}" mode="${4:-}"
    cat <<EOF
    ssl_certificate     $cert;
    ssl_certificate_key $key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:CHACHA20;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache   shared:SSL:10m;
EOF
    # 自签名证书没有 OCSP 响应地址，开启会导致 worker 报错刷屏，故跳过
    if [[ "$mode" != "self" ]]; then
        cat <<'EOF'
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;
EOF
    fi
    [[ -n "$hsts" ]] && echo "    add_header Strict-Transport-Security \"${hsts}\" always;"
    security_headers_lines
}

# ──────────────────────────────────────────────────────────
# SSL 参数交互（每次调用前重置全局变量）
# ──────────────────────────────────────────────────────────
ask_ssl_params() {
    # 重置所有 SSL 相关全局变量
    _SSL_MODE="" _SSL_PORT="" _SSL_CERT="" _SSL_KEY="" _SSL_301="no" _SSL_HTTP_PORT="80" _HSTS_HEADER=""

    echo ""
    echo -e "${CYAN}── SSL / 证书配置 ──${NC}"
    echo "  1) 自动扫描证书"
    echo "  2) 手动指定证书路径"
    echo "  3) 申请 Let's Encrypt 证书"
    echo "  4) 生成自签名证书"
    echo "  5) 纯 HTTP，不使用 SSL"
    echo ""
    safe_read -rp "请选择 [1-5，默认 1]: " _ssl_choice
    [[ -z "$_ssl_choice" ]] && _ssl_choice="1"

    _ask_301_and_ports() {
        safe_read -rp "HTTPS 监听端口 [默认 443]: " _SSL_PORT
        [[ -z "$_SSL_PORT" ]] && _SSL_PORT="443"
        safe_read -rp "开启 HTTP→HTTPS 301 强转？[Y/n]: " _r
        if [[ "${_r,,}" != "n" ]]; then
            _SSL_301="yes"
            safe_read -rp "HTTP 来源端口（强转监听端口）[默认 80]: " _SSL_HTTP_PORT
            [[ -z "$_SSL_HTTP_PORT" ]] && _SSL_HTTP_PORT="80"
            if [[ "$_SSL_HTTP_PORT" != "80" ]]; then
                warn "非标准 HTTP 端口 ${_SSL_HTTP_PORT}：客户端须先访问 http://域名:${_SSL_HTTP_PORT}/ 才会触发 301 跳转"
            fi
            _ask_hsts_level
        else
            warn "未开启 301 强转，将不发送 HSTS（避免声明与实际行为不符，导致回滚困难）"
        fi
    }

    _ask_hsts_level() {
        _HSTS_HEADER=""
        if [[ "$_SSL_MODE" == "self" ]]; then
            warn "自签名证书场景下不建议启用 HSTS（客户端本就不信任证书，启用后出问题更难恢复访问），已默认关闭"
            return
        fi
        echo ""
        echo -e "${CYAN}── HSTS 强度 ──${NC}"
        echo "  1) 不启用"
        echo "  2) 观察期（max-age=5分钟，先验证全站 HTTPS 无异常）"
        echo "  3) 标准（max-age=6个月 + includeSubDomains，推荐）"
        echo "  4) 严格（max-age=2年 + includeSubDomains + preload）"
        safe_read -rp "请选择 [1-4，默认 3]: " _hsts_choice
        [[ -z "$_hsts_choice" ]] && _hsts_choice="3"
        case "$_hsts_choice" in
            1) _HSTS_HEADER="" ;;
            2) _HSTS_HEADER="max-age=300" ;;
            3) _HSTS_HEADER="max-age=15552000; includeSubDomains" ;;
            4) _HSTS_HEADER="max-age=63072000; includeSubDomains; preload"
               warn "preload 需自行提交到 hstspreload.org 且极难撤销，请确认所有子域名均已支持 HTTPS 后再选" ;;
            *) die "无效选项" ;;
        esac
    }

    case "$_ssl_choice" in
        1) _SSL_MODE="auto";        _ask_301_and_ports ;;
        2)
            _SSL_MODE="manual"
            safe_read -rp "证书文件路径 (fullchain.pem): " _SSL_CERT
            [[ -z "$_SSL_CERT" || ! -f "$_SSL_CERT" ]] && die "证书文件不存在: $_SSL_CERT"
            safe_read -rp "私钥文件路径 (privkey.pem): " _SSL_KEY
            [[ -z "$_SSL_KEY"  || ! -f "$_SSL_KEY"  ]] && die "私钥文件不存在: $_SSL_KEY"
            _ask_301_and_ports
            ;;
        3) _SSL_MODE="letsencrypt"; _ask_301_and_ports ;;
        4) _SSL_MODE="self";        _ask_301_and_ports ;;
        5)
            _SSL_MODE="none"
            safe_read -rp "HTTP 监听端口 [默认 80]: " _SSL_PORT
            [[ -z "$_SSL_PORT" ]] && _SSL_PORT="80"
            ;;
        *) die "无效选项" ;;
    esac
}

resolve_ssl_cert() {
    local domain="$1"
    case "$_SSL_MODE" in
        auto)
            if find_certs_advanced "$domain"; then
                _SSL_CERT="$CERT_PATH"; _SSL_KEY="$KEY_PATH"
                success "自动发现证书: $_SSL_CERT"
            else
                die "未找到任何证书，请改用手动、Let's Encrypt 或自签名模式。"
            fi
            ;;
        letsencrypt)
            cert_issue_auto "$domain"
            _SSL_CERT="${LE_CERT_BASE}/${domain}/fullchain.pem"
            _SSL_KEY="${LE_CERT_BASE}/${domain}/privkey.pem"
            ;;
        self)
            cert_self_signed_auto "$domain"
            _SSL_CERT="${SELF_CERT_DIR}/${domain}/fullchain.pem"
            _SSL_KEY="${SELF_CERT_DIR}/${domain}/privkey.pem"
            ;;
        manual) : ;;
        none)   _SSL_CERT=""; _SSL_KEY="" ;;
    esac
}

# ──────────────────────────────────────────────────────────
# HTTP→HTTPS 重定向块
# ──────────────────────────────────────────────────────────
write_redirect_block() {
    local domain="$1"
    local https_port="$2"
    local http_port="${3:-80}"

    if [[ "$http_port" == "80" ]]; then
        local target_url
        if [[ "$https_port" == "443" ]]; then
            target_url="https://\$host\$request_uri"
        else
            target_url="https://\$host:${https_port}\$request_uri"
        fi
        cat <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    return 301 ${target_url};
}

EOF
    else
        cat <<EOF
server {
    listen ${http_port};
    server_name $domain;
    return 444;
}

EOF
        warn "HTTP:${http_port} 已设为 444 拒绝，请直接访问 https://${domain}:${https_port}/"
    fi
}

# ──────────────────────────────────────────────────────────
# 证书管理
# ──────────────────────────────────────────────────────────
ensure_certbot() {
    command -v certbot &>/dev/null && return
    warn "未检测到 certbot，尝试安装..."
    local mgr; mgr=$(detect_pkg_manager)
    case $mgr in
        apt)        apt-get install -y certbot python3-certbot-nginx ;;
        dnf|yum)    $mgr install -y epel-release; $mgr install -y certbot python3-certbot-nginx ;;
        pacman)     pacman -Sy --noconfirm certbot certbot-nginx ;;
    esac
    command -v certbot &>/dev/null || die "certbot 安装失败，请手动安装"
    success "certbot 安装完成"
}

ensure_openssl() { command -v openssl &>/dev/null || install_pkg openssl; }

cert_issue_auto() {
    local domain="$1"
    [[ -z "$domain" ]] && die "错误: 未提供域名参数"

    ensure_certbot
    _ensure_block_ip   # 确保裸 IP 拦截块已放行 /.well-known/acme-challenge/
    local email
    safe_read -rp "请输入邮箱（用于证书到期通知）: " email
    [[ -z "$email" ]] && die "邮箱不能为空"

    info "申请 Let's Encrypt 证书: ${domain}..."

    # FIX: 优先用共享 webroot 方式（00-block-ip.conf 已放行该目录），
    # 不需要停止/依赖 nginx 已有站点配置，新域名建站前也能直接申请成功，
    # 且不会像 standalone 那样导致本机其它站点短暂中断
    if systemctl is-active --quiet nginx && nginx -t &>/dev/null; then
        mkdir -p "${ACME_WEBROOT}/.well-known/acme-challenge"
        if certbot certonly --webroot -w "$ACME_WEBROOT" -d "$domain" \
            --agree-tos --email "$email" --no-eff-email --non-interactive; then
            success "证书申请成功: ${LE_CERT_BASE}/${domain}/"
            return 0
        fi
        warn "Webroot 方式申请失败，尝试 Nginx 插件方式..."
    fi

    if certbot certonly --nginx -d "$domain" \
        --agree-tos --email "$email" --no-eff-email --non-interactive; then
        success "证书申请成功: ${LE_CERT_BASE}/${domain}/"
        return 0
    fi

    warn "Nginx 插件申请失败，尝试回退到 Standalone 模式..."
    local nginx_was_active=false
    if systemctl is-active --quiet nginx; then
        nginx_was_active=true
        info "检测到 Nginx 正在运行，正在暂时停止以释放 80 端口..."
        systemctl stop nginx 2>/dev/null || true
    fi

    if certbot certonly --standalone -d "$domain" \
        --agree-tos --email "$email" --no-eff-email --non-interactive; then
        if $nginx_was_active; then
            info "正在恢复 Nginx 服务..."
            systemctl start nginx 2>/dev/null || true
        fi
        success "证书申请成功: ${LE_CERT_BASE}/${domain}/"
        return 0
    else
        if $nginx_was_active; then
            info "申请失败，正在尝试恢复 Nginx 服务..."
            systemctl start nginx 2>/dev/null || true
        fi
        die "证书申请彻底失败！请检查域名解析、防火墙 80 端口是否开放，或查看上方 Certbot 日志。"
    fi
}

cert_self_signed_auto() {
    local domain="$1" days="${2:-3650}"
    ensure_openssl
    local cert_dir="${SELF_CERT_DIR}/${domain}"
    mkdir -p "$cert_dir"
    if [[ -f "${cert_dir}/fullchain.pem" ]]; then
        success "自签名证书已存在: ${cert_dir}/"; return
    fi
    info "生成自签名证书（有效期 ${days} 天）..."
    openssl req -x509 -nodes -days "$days" \
        -newkey rsa:2048 \
        -keyout "${cert_dir}/privkey.pem" \
        -out    "${cert_dir}/fullchain.pem" \
        -subj   "/CN=${domain}/O=Self-Signed/C=CN" \
        -addext "subjectAltName=DNS:${domain},DNS:www.${domain}" 2>/dev/null
    chmod 600 "${cert_dir}/privkey.pem"
    success "自签名证书已生成: ${cert_dir}/"
}

_cert_issue_standalone() {
    local domain="$1" email="$2"
    local nginx_was_active=false
    if systemctl is-active --quiet nginx; then
        nginx_was_active=true
        info "检测到 Nginx 正在运行，正在暂时停止以释放 80 端口（本机其它站点会短暂中断）..."
        systemctl stop nginx 2>/dev/null || true
    fi

    local rc=1
    if certbot certonly --standalone -d "$domain" \
        --agree-tos --email "$email" --no-eff-email --non-interactive; then
        rc=0
    fi

    if $nginx_was_active; then
        info "正在恢复 Nginx 服务..."
        systemctl start nginx 2>/dev/null || true
    fi
    return $rc
}

cmd_cert_issue() {
    require_root
    ensure_certbot
    _ensure_block_ip   # FIX: 确保裸 IP 拦截块已放行 /.well-known/acme-challenge/，
                        # 否则新域名建站前申请证书（webroot / nginx 方式）必然被 444 拦截失败
    local domain="" email="" method="nginx" wildcard=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--domain)  domain="$2";   shift 2 ;;
            -e|--email)   email="$2";    shift 2 ;;
            -m|--method)  method="$2";   shift 2 ;;
            --wildcard)   wildcard=true; shift ;;
            *) die "未知参数: $1" ;;
        esac
    done

    [[ -n "$domain" ]] || safe_read -rp "域名: " domain
    [[ -n "$email"  ]] || safe_read -rp "邮箱: " email
    [[ -n "$domain" && -n "$email" ]] || die "域名和邮箱不能为空"

    local success_flag=false

    if $wildcard; then
        echo ""
        info "准备申请泛域名证书，将进入交互式 DNS 手动验证模式..."
        warn "注意：请仔细阅读接下来的终端提示，前往您的 DNS 服务商添加对应的 TXT 解析记录。"
        echo ""
        if certbot certonly --manual --preferred-challenges dns \
            -d "${domain}" -d "*.${domain}" \
            --agree-tos --email "$email" --no-eff-email; then
            success_flag=true
        fi
    else
        case $method in
            nginx)
                if certbot certonly --nginx -d "$domain" --agree-tos --email "$email" \
                    --no-eff-email --non-interactive; then
                    success_flag=true
                else
                    # FIX: 域名还没建站时，nginx 插件大概率找不到匹配的 server 块而失败，
                    # 原来直接报错退出；现在自动回退到 standalone，避免用户申请失败
                    warn "Nginx 插件方式失败（该域名可能尚未建站，找不到匹配的 server 块），尝试回退到 Standalone 模式..."
                    _cert_issue_standalone "$domain" "$email" && success_flag=true
                fi
                ;;
            webroot)
                # FIX: 改用 00-block-ip.conf 已放行的共享 ACME 目录，而不是 /var/www/html。
                # 原来的 /var/www/html 在域名尚未建站时，请求会被裸 IP 拦截块 444 掉，
                # 验证文件永远无法被 Let's Encrypt 访问到，webroot 方式必然失败。
                mkdir -p "${ACME_WEBROOT}/.well-known/acme-challenge"
                if certbot certonly --webroot -w "$ACME_WEBROOT" -d "$domain" \
                    --agree-tos --email "$email" --no-eff-email --non-interactive; then
                    success_flag=true
                else
                    warn "Webroot 方式失败，尝试回退到 Standalone 模式..."
                    _cert_issue_standalone "$domain" "$email" && success_flag=true
                fi
                ;;
            standalone)
                _cert_issue_standalone "$domain" "$email" && success_flag=true
                ;;
            *) die "未知验证方式: $method" ;;
        esac
    fi

    if $success_flag; then
        success "证书申请并生成成功！"
        success "证书路径: ${LE_CERT_BASE}/${domain}/"
        if $wildcard; then
            warn "泛域名证书使用手动 DNS 验证获取，certbot renew 无法非交互式自动续期此证书；"
            warn "到期前（约 90 天）需要重新手动执行本次申请流程，或自行配置 --manual-auth-hook 实现自动化。"
        fi
    else
        die "证书申请失败，未生成新证书。请检查域名解析是否已指向本机公网 IP、80 端口是否对外开放，并查看上方 Certbot 错误日志。"
    fi
}

cmd_cert_self_signed() {
    require_root
    local domain="" days=3650
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--domain) domain="$2"; shift 2 ;;
            --days)      days="$2";   shift 2 ;;
            *) die "未知参数: $1" ;;
        esac
    done
    [[ -n "$domain" ]] || safe_read -rp "域名: " domain
    cert_self_signed_auto "$domain" "$days"
}

cmd_cert_renew() {
    require_root; ensure_certbot
    local domain="${1:-}"
    if [[ -n "$domain" ]]; then
        certbot renew --cert-name "$domain" --non-interactive
    else
        certbot renew --non-interactive
    fi
    nginx_reload
    success "证书续期完成"
}

cmd_cert_list() {
    require_root
    echo -e "\n${BOLD}=== Let's Encrypt 证书 ===${NC}"
    if command -v certbot &>/dev/null; then
        certbot certificates 2>/dev/null || warn "暂无 LE 证书"
    else warn "certbot 未安装"; fi

    echo -e "\n${BOLD}=== 自签名证书 ===${NC}"
    local found=false
    for dir in "${SELF_CERT_DIR}"/*/; do
        [[ -d "$dir" ]] || continue; found=true
        local dom; dom=$(basename "$dir")
        local cert="${dir}fullchain.pem"
        if [[ -f "$cert" ]]; then
            local exp; exp=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
            echo -e "  ${CYAN}${dom}${NC}  到期: ${exp}"
        fi
    done
    $found || echo "  暂无自签名证书"
}

cmd_cert_auto_renew() {
    require_root

    # FIX: manual 方式（泛域名证书）获取的证书无法非交互续期，提前提示，
    # 避免用户误以为配置了自动续期后所有证书都能自动续上
    local manual_certs=""
    if command -v certbot &>/dev/null; then
        for renewal_conf in /etc/letsencrypt/renewal/*.conf; do
            [[ -f "$renewal_conf" ]] || continue
            if grep -q "^authenticator = manual" "$renewal_conf" 2>/dev/null; then
                manual_certs+="  - $(basename "$renewal_conf" .conf)\n"
            fi
        done
    fi
    if [[ -n "$manual_certs" ]]; then
        warn "以下证书是通过手动 DNS 验证（泛域名）获取的，无法被自动续期任务非交互式续期："
        echo -e "$manual_certs"
        warn "到期前请手动重新执行: $0 cert issue -d <域名> -e <邮箱> --wildcard"
    fi

    if systemctl list-timers 2>/dev/null | grep -q "certbot"; then
        info "检测到系统已自带 Certbot systemd 定时任务。"
        info "正在为您配置 Nginx 自动重载钩子 (Deploy Hook)..."

        mkdir -p /etc/letsencrypt/renewal-hooks/deploy
        cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/bash
systemctl reload nginx
EOF
        chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
        success "系统 Timer 钩子配置成功！未来证书自动续期后，Nginx 将无缝重载。"
        return 0
    fi

    if [[ ! -d /etc/cron.d ]]; then
        warn "/etc/cron.d 目录不存在，尝试创建..."
        mkdir -p /etc/cron.d || die "无法创建 /etc/cron.d，请手动配置续期任务"
    fi

    local cron_file="/etc/cron.d/nginx-gateway-certbot"
    echo "0 3 * * * root certbot renew --quiet --post-hook 'systemctl reload nginx'" > "$cron_file"
    chmod 644 "$cron_file"
    success "Cron 自动续期任务已配置（每天凌晨 3:00 执行检查）: $cron_file"
}

# ══════════════════════════════════════════════════════════════════
# 模式 A — 静态网站（可选 PHP-FPM）
# ══════════════════════════════════════════════════════════════════
site_create_static() {
    require_root
    init_dirs

    local domain="" web_dir="" php=false

    safe_read -rp "域名或 server_name: " domain
    [[ -z "$domain" ]] && die "域名不能为空"

    safe_read -rp "网站根目录（绝对路径）[默认 ${WEBROOT_BASE}/${domain}/public]: " web_dir
    [[ -z "$web_dir" ]] && web_dir="${WEBROOT_BASE}/${domain}/public"

    # 安全检查：web_dir 不能在系统关键路径
    validate_safe_path "$web_dir"

    safe_read -rp "是否启用 PHP-FPM？[y/N]: " _php
    [[ "${_php,,}" == "y" ]] && php=true

    ask_ssl_params
    resolve_ssl_cert "$domain"
    _check_port_conflict "$_SSL_PORT"

    mkdir -p "$web_dir"
    if [[ ! -f "${web_dir}/index.html" ]]; then
        cat > "${web_dir}/index.html" <<HTML
<!DOCTYPE html>
<html><head><meta charset="UTF-8"><title>${domain}</title></head>
<body><h1>Welcome to ${domain}</h1><p>站点已就绪。</p></body></html>
HTML
    fi
    # 仅在 web_dir 在 WEBROOT_BASE 下时才执行 chown
    if [[ "$web_dir" == "$WEBROOT_BASE"/* ]]; then
        chown -R www-data:www-data "$(dirname "$web_dir")" 2>/dev/null \
            || chown -R nginx:nginx "$(dirname "$web_dir")" 2>/dev/null \
            || true
    fi

    local index_directive="index.html index.htm"
    $php && index_directive="$index_directive index.php"

    local conf_file="${SITES_AVAILABLE}/${domain}.conf"
    {
        [[ "$_SSL_301" == "yes" ]] && write_redirect_block "$domain" "$_SSL_PORT" "$_SSL_HTTP_PORT"

        echo "server {"
        if [[ "$_SSL_MODE" != "none" ]]; then
            emit_ssl_listen_lines "$_SSL_PORT"
        else
            echo "    listen ${_SSL_PORT};"
            echo "    listen [::]:${_SSL_PORT};"
        fi

        cat <<CONF
    server_name ${domain};
    root        ${web_dir};
    index       ${index_directive};

    access_log /var/log/nginx/${domain}.access.log;
    error_log  /var/log/nginx/${domain}.error.log;

CONF
        deny_dangerous_methods_lines
        [[ "$_SSL_MODE" != "none" ]] && ssl_block "$_SSL_CERT" "$_SSL_KEY" "$_HSTS_HEADER" "$_SSL_MODE" && echo ""

        cat <<'CONF2'
    location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
        add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
    }

    location ~ /\. { deny all; }
CONF2
        deny_sensitive_files_lines
        if $php; then
            cat <<'PHP'

    location ~ \.php$ {
        include        snippets/fastcgi-php.conf;
        fastcgi_pass   unix:/run/php/php-fpm.sock;
        fastcgi_param  SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include        fastcgi_params;
    }
PHP
        fi
        echo "}"
    } > "$conf_file"

    _site_activate "$domain"
}

# ══════════════════════════════════════════════════════════════════
# 模式 B — 反向代理
# ══════════════════════════════════════════════════════════════════
site_create_proxy() {
    require_root
    init_dirs
    local domain="" backend=""
    safe_read -rp "域名或 server_name: " domain
    [[ -z "$domain" ]] && die "域名不能为空"
    safe_read -rp "后端目标地址（如 127.0.0.1:3000 或 http://10.0.0.5:8080）: " backend
    [[ -z "$backend" ]] && die "后端地址不能为空"
    backend=$(normalize_url "$backend")
    ask_ssl_params
    resolve_ssl_cert "$domain"
    _check_port_conflict "$_SSL_PORT"
    _ensure_upgrade_map
    ask_large_upload_optimization

    # ── 推断后端是否为 HTTPS ─────────────────────────────────────
    local backend_is_https=false
    [[ "$backend" == https://* ]] && backend_is_https=true

    local conf_file="${SITES_AVAILABLE}/${domain}.conf"
    {
        # 仅在 SSL 模式下才生成 301 重定向块
        [[ "$_SSL_MODE" != "none" && "$_SSL_301" == "yes" ]] && \
            write_redirect_block "$domain" "$_SSL_PORT" "$_SSL_HTTP_PORT"

        echo "server {"
        if [[ "$_SSL_MODE" != "none" ]]; then
            emit_ssl_listen_lines "$_SSL_PORT"
        else
            echo "    listen ${_SSL_PORT};"
            echo "    listen [::]:${_SSL_PORT};"
        fi
        cat <<CONF
    server_name ${domain};
    access_log /var/log/nginx/${domain}.access.log;
    error_log  /var/log/nginx/${domain}.error.log;

    client_max_body_size 0;
CONF
        emit_resolver_line
        deny_dangerous_methods_lines
        [[ "$_SSL_MODE" != "none" ]] && ssl_block "$_SSL_CERT" "$_SSL_KEY" "$_HSTS_HEADER" "$_SSL_MODE" && echo ""

        cat <<CONF
    location / {
        proxy_pass          ${backend};
        proxy_http_version  1.1;
        proxy_set_header    Upgrade           \$http_upgrade;
        proxy_set_header    Connection        \$connection_upgrade;
        proxy_set_header    Host              \$host;
        proxy_set_header    X-Real-IP         \$remote_addr;
        proxy_set_header    X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header    X-Forwarded-Proto \$scheme;
        proxy_cache_bypass  \$http_upgrade;
CONF
        large_upload_lines
        proxy_hide_backend_headers_lines
        # 仅后端为 HTTPS 时才加 proxy_ssl 指令
        if [[ "$backend_is_https" == true ]]; then
            cat <<CONF
        proxy_ssl_server_name on;
        proxy_ssl_verify      off;
CONF
        fi

        cat <<CONF
    }

    # 允许 ACME webroot 验证，屏蔽其他隐藏路径
    location ~ /\.well-known { allow all; }
    location ~ /\.           { deny all; }
CONF
        deny_sensitive_files_lines
        echo "}"
    } > "$conf_file"
    _site_activate "$domain"
}

# ══════════════════════════════════════════════════════════════════
# 模式 C — 外部域名代理
# ══════════════════════════════════════════════════════════════════
site_create_mirror() {
    require_root
    init_dirs

    local domain="" target_url="" target_host=""

    safe_read -rp "域名或 server_name: " domain
    [[ -z "$domain" ]] && die "域名不能为空"

    safe_read -rp "外部目标 URL（如 https://api.example.com）: " target_url
    [[ -z "$target_url" ]] && die "目标 URL 不能为空"
    target_url=$(normalize_url "$target_url")
    target_host=$(awk -F/ '{print $3}' <<< "$target_url")

    echo ""
    echo -e "${CYAN}── 代理模式 ──${NC}"
    echo "  1) 透传  — 原样转发响应，不改写内容"
    echo "  2) 镜像  — sub_filter 替换页面内域名引用"
    local _mode=""
    safe_read -rp "选择 [1-2，默认 1]: " _mode
    local rewrite=false
    [[ "${_mode:-1}" == "2" ]] && rewrite=true

    $rewrite && check_sub_filter_module

    ask_ssl_params
    resolve_ssl_cert "$domain"
    _check_port_conflict "$_SSL_PORT"
    _ensure_upgrade_map

    local -a extra_locs=()
    if $rewrite; then
        echo ""
        info "可添加额外的静态资源/CDN 域名（作为子路径代理，回车结束）"
        local count=1
        while true; do
            local res_url=""
            safe_read -rp "额外资源 URL（回车跳过）: " res_url
            [[ -z "$res_url" ]] && break

            res_url=$(normalize_url "$res_url")
            local res_host
            res_host=$(awk -F/ '{print $3}' <<< "$res_url")
            local key="_res_${count}"

            extra_locs+=("$(cat <<LOCEOF

    location /${key}/ {
        rewrite ^/${key}/(.*) /\$1 break;
        proxy_pass         ${res_url};
        proxy_set_header   Host            ${res_host};
        proxy_set_header   Referer         ${res_url};
        proxy_set_header   Accept-Encoding "";
        proxy_ssl_server_name on;
        proxy_hide_header  X-Powered-By;
        proxy_hide_header  Server;
    }
LOCEOF
)")
            (( count++ ))
        done
    fi

    local conf_file="${SITES_AVAILABLE}/${domain}.conf"
    {
        [[ "$_SSL_301" == "yes" ]] && write_redirect_block "$domain" "$_SSL_PORT" "$_SSL_HTTP_PORT"

        echo "server {"
        if [[ "$_SSL_MODE" != "none" ]]; then
            emit_ssl_listen_lines "$_SSL_PORT"
        else
            echo "    listen ${_SSL_PORT};"
            echo "    listen [::]:${_SSL_PORT};"
        fi

        cat <<CONF
    server_name ${domain};

    access_log /var/log/nginx/${domain}.access.log;
    error_log  /var/log/nginx/${domain}.error.log;

CONF
        emit_resolver_line
        deny_dangerous_methods_lines
        [[ "$_SSL_MODE" != "none" ]] && ssl_block "$_SSL_CERT" "$_SSL_KEY" "$_HSTS_HEADER" "$_SSL_MODE" && echo ""

        if $rewrite; then
            cat <<CONF
    location / {
        proxy_pass         ${target_url};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        \$connection_upgrade;
        proxy_set_header   Host              ${target_host};
        proxy_set_header   Referer           ${target_url};
        proxy_set_header   Accept-Encoding   "";
        proxy_ssl_server_name on;
CONF
            printf '%s\n' "$(proxy_hide_backend_headers_lines)"
            cat <<CONF

        sub_filter "</head>"                 "<meta name='referrer' content='no-referrer'></head>";
        sub_filter "//${target_host}"         "//${domain}";
        sub_filter "https://${target_host}"  "https://${domain}";
        sub_filter "http://${target_host}"   "https://${domain}";
        sub_filter_once  off;
        sub_filter_types *;
    }
CONF
            [[ ${#extra_locs[@]} -gt 0 ]] && printf '%s\n' "${extra_locs[@]}"
        else
            cat <<CONF
    location / {
        proxy_pass          ${target_url};
        proxy_http_version  1.1;
        proxy_set_header    Upgrade           \$http_upgrade;
        proxy_set_header    Connection        \$connection_upgrade;
        proxy_set_header    Host              ${target_host};
        proxy_set_header    X-Real-IP         \$remote_addr;
        proxy_set_header    X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header    X-Forwarded-Proto \$scheme;
        proxy_cache_bypass  \$http_upgrade;
        proxy_ssl_server_name on;
CONF
            printf '%s\n' "$(proxy_hide_backend_headers_lines)"
            echo "    }"
        fi

        echo ""
        echo "    location ~ /\. { deny all; }"
        deny_sensitive_files_lines
        echo "}"
    } > "$conf_file"

    _site_activate "$domain"
}

# ══════════════════════════════════════════════════════════════════
# 模式 D — HTTP 正向代理
# ══════════════════════════════════════════════════════════════════
site_create_forward_proxy() {
    require_root
    init_dirs

    local port=""
    safe_read -rp "正向代理监听端口 [默认 8888]: " port
    [[ -z "$port" ]] && port="8888"

    warn "Nginx 原生仅支持 HTTP 正向代理，不支持 HTTPS CONNECT 隧道。"
    warn "如需完整 HTTPS 支持，请改用 Squid 或 3proxy。"
    if confirm "是否继续创建 HTTP 正向代理？"; then
        :  # 继续
    else
        return
    fi

    echo ""
    info "请输入允许使用此代理的 IP 或网段，回车跳过使用默认内网段"
    local -a allow_list=()
    while true; do
        local _ip=""
        safe_read -rp "允许的 IP/网段（回车结束）: " _ip
        [[ -z "$_ip" ]] && break
        allow_list+=("    allow ${_ip};")
    done

    if [[ ${#allow_list[@]} -eq 0 ]]; then
        allow_list=(
            "    allow 10.0.0.0/8;"
            "    allow 172.16.0.0/12;"
            "    allow 192.168.0.0/16;"
            "    allow 127.0.0.1;"
        )
    fi

    local conf_file="${SITES_AVAILABLE}/forward-proxy-${port}.conf"
    cat > "$conf_file" <<EOF
# Nginx HTTP 正向代理（不支持 HTTPS CONNECT 隧道）
server {
    listen ${port};
    server_name _;
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;

    location / {
$(printf '%s\n' "${allow_list[@]}")
        deny all;

        proxy_pass               \$scheme://\$http_host\$request_uri;
        proxy_set_header         Host             \$http_host;
        proxy_set_header         X-Real-IP        \$remote_addr;
        proxy_set_header         X-Forwarded-For  \$proxy_add_x_forwarded_for;
        proxy_buffers            256 4k;
        proxy_max_temp_file_size 0;
        proxy_connect_timeout    30s;
    }
}
EOF

    _site_activate "forward-proxy-${port}"
}

# ══════════════════════════════════════════════════════════════════
# 模式 E — TCP/UDP 流代理（stream 模块，生成 server 块而非完整 stream{}）
# ══════════════════════════════════════════════════════════════════
site_create_stream_proxy() {
    require_root

    local nginx_v
    nginx_v=$(nginx -V 2>&1)
    if ! grep -q "with-stream" <<< "$nginx_v"; then
        die "当前 Nginx 未编译 stream 模块。\nDebian/Ubuntu 可执行: apt install nginx-full"
    fi

    local listen_port="" backend_host="" backend_port="" proto="tcp"
    safe_read -rp "本地监听端口: " listen_port
    [[ -z "$listen_port" ]] && die "端口不能为空"
    safe_read -rp "后端 IP/域名: " backend_host
    [[ -z "$backend_host" ]] && die "后端地址不能为空"
    safe_read -rp "后端端口: " backend_port
    [[ -z "$backend_port" ]] && die "后端端口不能为空"
    safe_read -rp "协议 [tcp/udp，默认 tcp]: " proto
    [[ -z "$proto" ]] && proto="tcp"

    local stream_dir="${NGINX_CONF_DIR}/stream.d"
    mkdir -p "$stream_dir"
    local stream_conf="${stream_dir}/stream-${listen_port}.conf"

    local udp_flag=""
    [[ "$proto" == "udp" ]] && udp_flag=" udp"

    # 注意：这里只生成 server 块，不包裹 stream{}，需要用户确保 nginx.conf 的 stream 块中 include 此目录
    cat > "$stream_conf" <<EOF
# TCP/UDP 流代理 — 端口 ${listen_port}${udp_flag:+/$proto} → ${backend_host}:${backend_port}
server {
    listen ${listen_port}${udp_flag};
    proxy_pass            ${backend_host}:${backend_port};
    proxy_connect_timeout 10s;
    proxy_timeout         60s;
}
EOF

    warn "流代理配置已生成为独立的 server 块。"
    warn "请确保您的 nginx.conf 顶层包含如下配置（与 http{} 平级）:"
    echo ""
    echo -e "  ${BOLD}stream {${NC}"
    echo "      include ${stream_dir}/*.conf;"
    echo -e "  ${BOLD}}${NC}"
    echo ""
    # 自动在 nginx.conf 中插入 stream 块（若不存在）
    if ! grep -q "stream.d" "${NGINX_CONF_DIR}/nginx.conf" 2>/dev/null; then
        if ! grep -q "^stream" "${NGINX_CONF_DIR}/nginx.conf" 2>/dev/null; then
            cat >> "${NGINX_CONF_DIR}/nginx.conf" <<STREAMEOF

stream {
    include ${NGINX_CONF_DIR}/stream.d/*.conf;
}
STREAMEOF
            info "已在 nginx.conf 末尾追加 stream{} 块"
        else
            warn "nginx.conf 中已有 stream 块但未包含 stream.d，请手动确认"
        fi
    fi

    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        success "流代理 server 配置已写入并生效: $stream_conf"
    else
        warn "nginx 配置检查失败，请手动检查: $stream_conf"
        warn "并确认 nginx.conf 已包含: stream { include ${NGINX_CONF_DIR}/stream.d/*.conf; }"
    fi
}

# ══════════════════════════════════════════════════════════════════
# 模式 F — 域名跳转（Redirect）
# ══════════════════════════════════════════════════════════════════
site_create_redirect() {
    require_root
    init_dirs

    local src_domain="" target_url="" code="301"

    safe_read -rp "来源域名（如 old.example.com）: " src_domain
    [[ -z "$src_domain" ]] && die "来源域名不能为空"

    safe_read -rp "跳转目标 URL（如 https://new.example.com）: " target_url
    [[ -z "$target_url" ]] && die "目标 URL 不能为空"
    target_url="${target_url%/}"

    echo ""
    echo -e "${CYAN}── 跳转类型 ──${NC}"
    echo "  1) 301 — 永久"
    echo "  2) 302 — 临时"
    echo "  3) 307 — 临时 + 保留 Method"
    echo "  4) 308 — 永久 + 保留 Method"
    safe_read -rp "选择 [1-4，默认 1]: " _code_choice
    case "${_code_choice:-1}" in
        1) code=301 ;; 2) code=302 ;; 3) code=307 ;; 4) code=308 ;;
        *) die "无效选项" ;;
    esac

    echo ""
    echo -e "${CYAN}── 路径处理 ──${NC}"
    echo "  1) 保留路径"
    echo "  2) 整站跳转到固定 URL"
    echo "  3) 自定义 location 规则"
    safe_read -rp "选择 [1-3，默认 1]: " _path_choice

    local -a rules=()
    if [[ "${_path_choice:-1}" == "3" ]]; then
        echo ""
        echo -e "${CYAN}请输入自定义路径规则，回车空行结束${NC}"
        while true; do
            local _rule=""
            safe_read -rp "location 规则（回车结束）: " _rule
            [[ -z "$_rule" ]] && break
            rules+=("    ${_rule}")
        done
    fi

    echo ""
    echo -e "${CYAN}── 监听配置 ──${NC}"
    echo "  1) 仅 HTTP 80"
    echo "  2) HTTP 80 + HTTPS 443"
    safe_read -rp "选择 [1-2，默认 1]: " _listen_choice

    local has_ssl=false
    if [[ "${_listen_choice:-1}" == "2" ]]; then
        has_ssl=true
        ask_ssl_params
        resolve_ssl_cert "$src_domain"
    fi

    _redirect_return() {
        local c=$1
        case "${_path_choice:-1}" in
            1) echo "    return ${c} ${target_url}\$request_uri;" ;;
            2) echo "    return ${c} ${target_url}/;" ;;
            3)
                if [[ ${#rules[@]} -gt 0 ]]; then
                    printf '%s\n' "${rules[@]}"
                else
                    echo "    return ${c} ${target_url}\$request_uri;"
                fi
                ;;
        esac
    }

    local conf_file="${SITES_AVAILABLE}/${src_domain}-redirect.conf"
    {
        echo "# 跳转规则: ${src_domain} → ${target_url} [${code}]"
        echo "# 生成时间: $(date)"
        echo ""

        echo "server {"
        echo "    listen 80;"
        echo "    listen [::]:80;"
        echo "    server_name ${src_domain};"
        echo ""
        echo "    access_log /var/log/nginx/${src_domain}-redirect.access.log;"
        echo "    error_log  /var/log/nginx/${src_domain}-redirect.error.log;"
        echo ""
        _redirect_return "$code"
        echo "}"

        if $has_ssl; then
            echo ""
            echo "server {"
            emit_ssl_listen_lines "$_SSL_PORT"
            echo "    server_name ${src_domain};"
            echo ""
            ssl_block "$_SSL_CERT" "$_SSL_KEY" "$_HSTS_HEADER" "$_SSL_MODE"
            echo ""
            echo "    access_log /var/log/nginx/${src_domain}-redirect.access.log;"
            echo "    error_log  /var/log/nginx/${src_domain}-redirect.error.log;"
            echo ""
            _redirect_return "$code"
            echo "}"
        fi
    } > "$conf_file"

    _site_activate "${src_domain}-redirect"

    echo ""
    info "跳转规则预览："
    echo -e "  ${CYAN}${src_domain}${NC}  ──[${code}]──▶  ${target_url}"
}

# ══════════════════════════════════════════════════════════════════
# 模式 G — 负载均衡（upstream）
# ══════════════════════════════════════════════════════════════════
site_create_loadbalance() {
    require_root
    init_dirs

    local domain=""
    safe_read -rp "域名或 server_name: " domain
    [[ -z "$domain" ]] && die "域名不能为空"

    echo ""
    echo -e "${CYAN}── 负载均衡算法 ──${NC}"
    echo "  1) round-robin 轮询 (推荐：后端无状态/内容完全相同)"
    echo "  2) least_conn  最少连接"
    echo "  3) ip_hash     IP 哈希 (适合需要保持 Session 登录状态的项目)"
    safe_read -rp "选择 [1-3，默认 1]: " _lb_algo
    local lb_directive=""
    case "${_lb_algo:-1}" in
        1) lb_directive="" ;;
        2) lb_directive="    least_conn;" ;;
        3) lb_directive="    ip_hash;" ;;
        *) lb_directive="" ;;
    esac

    # 循环读取 B、C、D 多个节点的网卡 IP/端口
    echo ""
    info "请输入后端节点地址（例如：10.0.0.2:80 或 10.0.0.3:8080）"
    local -a backend_list=()
    while true; do
        local node=""
        safe_read -rp "添加后端源站节点 (直接回车结束): " node
        [[ -z "$node" ]] && break
        
        # 增加被动健康检查参数：
        # max_fails=2 fail_timeout=10s 表示 10 秒内如果该节点连续失败 2 次，将其摘除 10 秒
        backend_list+=("    server ${node} max_fails=2 fail_timeout=10s;")
    done

    [[ ${#backend_list[@]} -eq 0 ]] && die "至少需要添加一个后端节点！"

    # ── 后台路径固定节点（WordPress wp-admin 等）────────────────────
    echo ""
    echo -e "${CYAN}── 后台路径固定节点（可选）──${NC}"
    info "用于将 wp-admin / wp-login.php 等后台请求固定路由到指定节点"
    info "若所有节点内容完全一致可跳过，留空则不启用"
    local master_node=""
    safe_read -rp "后台固定节点地址（如 10.0.0.2:80，留空跳过）: " master_node

    # 自定义后台路径正则（默认覆盖 WordPress 后台）
    local admin_regex="^/(wp-admin|wp-login\\.php|xmlrpc\\.php)"
    if [[ -n "$master_node" ]]; then
        local _custom_regex=""
        safe_read -rp "自定义后台路径正则（留空使用默认 wp-admin|wp-login.php|xmlrpc.php）: " _custom_regex
        [[ -n "$_custom_regex" ]] && admin_regex="$_custom_regex"
    fi

    ask_ssl_params
    resolve_ssl_cert "$domain"
    _check_port_conflict "$_SSL_PORT"
    _ensure_upgrade_map
    ask_large_upload_optimization

    local upstream_name="upstream_${domain//./_}"
    local upstream_master="${upstream_name}_master"
    local conf_file="${SITES_AVAILABLE}/${domain}.conf"

    {
        # 生成通用 upstream 块
        echo "upstream ${upstream_name} {"
        echo "    zone ${upstream_name} 64k;"
        [[ -n "$lb_directive" ]] && echo "$lb_directive"
        printf '%s\n' "${backend_list[@]}"
        echo "}"
        echo ""

        # 生成主节点专用 upstream 块（若启用）
        if [[ -n "$master_node" ]]; then
            echo "# 后台请求固定节点"
            echo "upstream ${upstream_master} {"
            echo "    zone ${upstream_master} 64k;"
            echo "    server ${master_node};"
            echo "}"
            echo ""
        fi

        # 生成 301 强转块
        [[ "$_SSL_MODE" != "none" && "$_SSL_301" == "yes" ]] && \
            write_redirect_block "$domain" "$_SSL_PORT" "$_SSL_HTTP_PORT"

        # 主 server 块
        echo "server {"
        if [[ "$_SSL_MODE" != "none" ]]; then
            emit_ssl_listen_lines "$_SSL_PORT"
        else
            echo "    listen ${_SSL_PORT};"
            echo "    listen [::]:${_SSL_PORT};"
        fi

        cat <<CONF
    server_name ${domain};
    client_max_body_size 0;

    access_log /var/log/nginx/${domain}.access.log;
    error_log  /var/log/nginx/${domain}.error.log;
CONF

        deny_dangerous_methods_lines
        [[ "$_SSL_MODE" != "none" ]] && ssl_block "$_SSL_CERT" "$_SSL_KEY" "$_HSTS_HEADER" "$_SSL_MODE" && echo ""

        # 后台路径固定 location（精确匹配，优先于 location /）
        if [[ -n "$master_node" ]]; then
            cat <<CONF

    # 后台路径固定到主节点: ${master_node}
    location ~* ${admin_regex} {
        proxy_pass          http://${upstream_master};
        proxy_http_version  1.1;
        proxy_set_header    Host              \$host;
        proxy_set_header    X-Real-IP         \$remote_addr;
        proxy_set_header    X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header    X-Forwarded-Proto \$scheme;
        proxy_set_header    X-Forwarded-Host  \$host;
        proxy_read_timeout  300s;
        proxy_send_timeout  300s;
CONF
            printf '%s\n' "$(proxy_hide_backend_headers_lines)"
            echo "    }"
        fi

        cat <<CONF
    location / {
        proxy_pass          http://${upstream_name};
        proxy_http_version  1.1;
        proxy_set_header    Upgrade           \$http_upgrade;
        proxy_set_header    Connection        \$connection_upgrade;
        proxy_set_header    Host              \$host;
        proxy_set_header    X-Real-IP         \$remote_addr;
        proxy_set_header    X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header    X-Forwarded-Proto \$scheme;
        proxy_set_header    X-Forwarded-Host  \$host;

        # 核心：当主节点返回 502/504/超时时，立即无感将请求转给下一个健康的节点
        proxy_next_upstream error timeout invalid_header http_502 http_503 http_504;
        proxy_next_upstream_timeout 5s;
        proxy_next_upstream_tries 3;
CONF
        large_upload_lines
        printf '%s\n' "$(proxy_hide_backend_headers_lines)"
        echo "    }"

        cat <<CONF

    location ~ /\.well-known { allow all; }
    location ~ /\.           { deny all; }
CONF
        deny_sensitive_files_lines
        echo "}"
    } > "$conf_file"

    _site_activate "$domain"

    if [[ -n "$master_node" ]]; then
        echo ""
        success "后台路径已固定到: ${master_node}"
        info "匹配规则: ${admin_regex}"
        info "如需修改固定节点，执行: site edit ${domain}"
    fi
}

# ══════════════════════════════════════════════════════════════════
# 负载均衡节点管理
# ══════════════════════════════════════════════════════════════════
site_lb_node() {
    require_root

    local domain=""
    safe_read -rp "负载均衡域名: " domain
    [[ -z "$domain" ]] && die "域名不能为空"

    local conf="${SITES_AVAILABLE}/${domain}.conf"
    [[ -f "$conf" ]] || die "配置不存在: $conf"
    grep -q "^upstream " "$conf" || die "${domain} 不是负载均衡站点"

    local upstream_name="upstream_${domain//./_}"

    echo ""
    echo -e "${CYAN}── 节点管理: ${domain} ──${NC}"
    echo "  1) 添加节点"
    echo "  2) 删除节点"
    echo "  3) 列出节点"
    safe_read -rp "选择 [1-3]: " _action

    case "${_action}" in
        1)
            local node=""
            safe_read -rp "新节点地址（如 10.0.0.4:8080）: " node
            [[ -z "$node" ]] && die "节点地址不能为空"

            if grep -qE "^\s+server ${node//./\\.}( |$)" "$conf"; then
                die "节点 ${node} 已存在"
            fi

            sed -i "/^upstream ${upstream_name} {/,/^}/ {
                /^}/ i\\    server ${node} max_fails=2 fail_timeout=10s;
            }" "$conf"

            success "节点 ${node} 已添加"
            ;;

        2)
            local -a nodes=()
            while IFS= read -r line; do
                nodes+=("$(echo "$line" | awk '{print $2}')")
            done < <(grep -E "^\s+server .+ max_fails" "$conf")

            [[ ${#nodes[@]} -eq 0 ]] && die "未找到节点"
            [[ ${#nodes[@]} -eq 1 ]] && die "只剩一个节点，无法删除"

            echo ""
            echo -e "${CYAN}当前节点:${NC}"
            local i=1
            for node in "${nodes[@]}"; do
                printf "  %d) %s\n" "$i" "$node"
                (( i++ ))
            done

            safe_read -rp "选择要删除的节点序号 [1-${#nodes[@]}]: " _idx
            if ! [[ "$_idx" =~ ^[0-9]+$ ]] || (( _idx < 1 || _idx > ${#nodes[@]} )); then
                die "无效序号"
            fi

            local target="${nodes[$(( _idx - 1 ))]}"
            # 只删除通用 upstream 块中的节点，不碰 _master upstream
            # 使用 python3 做精确块级删除，避免误删主节点 upstream 中同 IP 的行
            if python3 - "$conf" "$target" <<'PYDEL'
import sys, re
path, target = sys.argv[1], sys.argv[2]
txt = open(path).read()
# 找到第一个不含 _master 的 upstream 块，在其中删除匹配行
def del_in_main_upstream(m):
    block = m.group(0)
    lines = block.splitlines(keepends=True)
    filtered = [l for l in lines if not re.search(
        r'\s+server\s+' + re.escape(target) + r'\s', l)]
    return ''.join(filtered)
new_txt = re.sub(
    r'upstream [^_][^{]*\{[^}]*\}',
    del_in_main_upstream, txt, count=1, flags=re.DOTALL)
open(path, 'w').write(new_txt)
PYDEL
            then
                success "节点 ${target} 已删除"
            else
                # fallback: 兼容无 python3 的环境
                sed -i "/[[:space:]]\+server[[:space:]]\+${target//./\.}[[:space:]]/d" "$conf"
                success "节点 ${target} 已删除（fallback）"
            fi
            ;;

        3)
            echo ""
            echo -e "${CYAN}当前节点列表 — ${domain}:${NC}"
            local found=false
            while IFS= read -r line; do
                found=true
                local addr fails timeout
                addr=$(echo "$line" | awk '{print $2}')
                fails=$(echo "$line" | grep -oP 'max_fails=\K[0-9]+')
                timeout=$(echo "$line" | grep -oP 'fail_timeout=\K\S+')
                printf "  • %-25s  max_fails=%-3s fail_timeout=%s\n" \
                    "$addr" "$fails" "$timeout"
            done < <(grep -E "^\s+server .+ max_fails" "$conf")
            $found || warn "未找到节点"
            echo ""
            return
            ;;

        *) die "无效选项" ;;
    esac

    nginx -t || die "配置检查失败，请手动检查: $conf"
    systemctl reload nginx
    success "Nginx 已重载，节点变更生效"
}

# ──────────────────────────────────────────────────────────
# 访问控制
# ──────────────────────────────────────────────────────────
site_add_acl() {
    require_root; init_dirs

    local domain=""
    safe_read -rp "要添加访问控制的域名: " domain
    [[ -z "$domain" ]] && die "域名不能为空"

    local conf="${SITES_AVAILABLE}/${domain}.conf"
    [[ ! -f "$conf" ]] && conf="${SITES_AVAILABLE}/${domain}-redirect.conf"
    [[ ! -f "$conf" ]] && die "找不到站点配置: ${domain}，请先创建站点"

    echo ""
    echo -e "${CYAN}── 访问控制类型 ──${NC}"
    echo "  1) IP 白名单"
    echo "  2) IP 黑名单"
    echo "  3) Basic Auth (账号密码)"
    echo "  4) IP 白名单 + Basic Auth"
    echo "  5) 地区/国家 白名单 (仅允许特定国家)"
    echo "  6) 地区/国家 黑名单 (拒绝特定国家)"
    safe_read -rp "选择 [1-6]: " _acl_type

    # IP 白/黑名单及组合类型都依赖 $remote_addr，Cloudflare 后面若未还原真实
    # IP 会导致这些规则失效，这里提前提醒（地区 ACL 5/6 已用 CF 专属头，不受影响）
    [[ "${_acl_type:-1}" =~ ^(1|2|4)$ ]] && _maybe_prompt_cf_realip

    local acl_conf_file="${NGINX_CONF_DIR}/conf.d/acl-${domain}.conf"
    local snippet_file="${SNIPPET_DIR}/acl-location-${domain}.conf"

    case "${_acl_type:-1}" in
        1|2)
            local -a ips=()
            local action="" default_action=""
            if [[ "${_acl_type}" == "1" ]]; then
                action="0"; default_action="1"
                info "请逐行输入允许的 IP 或 CIDR，空行结束:"
            else
                action="1"; default_action="0"
                info "请逐行输入要拒绝的 IP 或 CIDR，空行结束:"
            fi
            
            while true; do
                local _ip=""
                safe_read -rp "IP/CIDR: " _ip
                [[ -z "$_ip" ]] && break
                ips+=("$_ip")
            done
            [[ ${#ips[@]} -eq 0 ]] && die "至少输入一个 IP"

            # 生成 geo 文件
            {
                echo "# IP ACL — 生成时间: $(date)"
                echo "geo \$ip_blocked {"
                echo "    default ${default_action};"
                for ip in "${ips[@]}"; do
                    echo "    ${ip} ${action};"
                done
                echo "}"
            } > "$acl_conf_file"
            success "ACL geo 规则写入: $acl_conf_file"

            # 生成 location snippet
            echo "if (\$ip_blocked = 1) { return 403; }" > "$snippet_file"

            # 自动注入 include
            _acl_inject_include "$conf" "$snippet_file"
            ;;

        3|4)
            command -v htpasswd &>/dev/null \
                || install_pkg apache2-utils 2>/dev/null \
                || install_pkg httpd-tools 2>/dev/null \
                || die "无法安装 htpasswd，请手动安装 apache2-utils/httpd-tools"

            local auth_file="${NGINX_CONF_DIR}/.htpasswd-${domain}"
            local username=""
            safe_read -rp "用户名: " username
            [[ -z "$username" ]] && die "用户名不能为空"
            if [[ -f "$auth_file" ]]; then
                info "密码文件已存在，追加用户 ${username}..."
                htpasswd "$auth_file" "$username"
            else
                htpasswd -c "$auth_file" "$username"
            fi
            chmod 640 "$auth_file"
            success "密码文件已更新: $auth_file"

            # 生成 location snippet
            > "$snippet_file"
            if [[ "${_acl_type}" == "4" ]]; then
                local -a ips=()
                info "请逐行输入允许的 IP 或 CIDR，空行结束:"
                while true; do
                    local _ip=""
                    safe_read -rp "IP/CIDR: " _ip
                    [[ -z "$_ip" ]] && break
                    echo "    allow ${_ip};" >> "$snippet_file"
                done
                echo "    deny all;" >> "$snippet_file"
            fi
            cat >> "$snippet_file" <<EOF
    auth_basic "Restricted";
    auth_basic_user_file ${auth_file};
EOF
            success "Basic Auth 规则已生成: $snippet_file"

            # 自动注入 include
            _acl_inject_include "$conf" "$snippet_file"
            ;;

        5|6)
            local -a countries=()
            local action="" default_action=""

            if [[ "${_acl_type}" == "5" ]]; then
                action="0"; default_action="1"
                info "请逐行输入允许访问的国家代码 (ISO标准 两位字母, 如 CN, US)，空行结束:"
            else
                action="1"; default_action="0"
                info "请逐行输入要拒绝访问的国家代码 (ISO标准 两位字母, 如 CN, US)，空行结束:"
            fi

            while true; do
                local _cc=""
                safe_read -rp "国家代码: " _cc
                [[ -z "$_cc" ]] && break
                countries+=("$(echo "$_cc" | tr '[:lower:]' '[:upper:]')")
            done
            [[ ${#countries[@]} -eq 0 ]] && die "至少输入一个国家代码"

            local geo_var="\$geoip2_data_country_iso_code"
            safe_read -rp "该站点是否使用了 Cloudflare 代理? (y/n) [n]: " _use_cf
            if [[ "${_use_cf,,}" == "y" || "${_use_cf,,}" == "yes" ]]; then
                geo_var="\$http_cf_ipcountry"
            fi

            # 生成 map 文件
            {
                echo "# 地区 ACL — 生成时间: $(date)"
                echo "# 变量使用: ${geo_var}"
                echo "map ${geo_var} \$country_blocked {"
                echo "    default ${default_action};"
                for cc in "${countries[@]}"; do
                    echo "    ${cc} ${action};"
                done
                echo "}"
            } > "$acl_conf_file"
            success "地区 ACL map 规则写入: $acl_conf_file"

            # 生成 location snippet
            echo "if (\$country_blocked = 1) { return 403; }" > "$snippet_file"

            # 自动注入 include
            _acl_inject_include "$conf" "$snippet_file"

            if [[ "$geo_var" == "\$geoip2_data_country_iso_code" ]]; then
                warn "注意: 未使用 Cloudflare 的站点，需要确保你的 Nginx 已安装并配置好 geoip2 模块，否则会报错！"
            fi
            ;;

        *) die "无效选项" ;;
    esac

    # 测试配置并重载
    if nginx -t; then
        systemctl reload nginx
        success "Nginx 配置测试通过并已重载，ACL 生效"
    else
        die "Nginx 配置测试失败！请检查配置文件"
    fi
}

# -------------------------------------------------------------------
# 辅助函数：将 include 指令注入到站点的 location / 块中
# 参数: $1 = 站点配置文件路径
#       $2 = 要 include 的 snippet 文件路径
# -------------------------------------------------------------------
_acl_inject_include() {
    local conf="$1"
    local snippet="$2"
    local marker="include ${snippet};"

    # 防止重复注入
    if grep -qF "$marker" "$conf"; then
        info "include 指令已存在，跳过注入"
        return
    fi

    # 用 python3 精确匹配第一个 "location / {" 整行并注入
    # 避免 sed 误匹配 "location ~* /wp-admin" 等后台路径 location
    if command -v python3 &>/dev/null; then
        python3 - "$conf" "$marker" <<'PYINJECT'
import sys, re
path, marker = sys.argv[1], sys.argv[2]
txt = open(path).read()
# 只匹配独立的 location / { 行（/ 两侧只允许空白）
pattern = r'([ \t]*location\s+/\s*\{)'
new_txt, n = re.subn(pattern, r'\1' + '\n        ' + marker, txt, count=1)
if n:
    open(path, 'w').write(new_txt)
    sys.exit(0)
sys.exit(1)
PYINJECT
        if [[ $? -eq 0 ]]; then
            success "已将 include 指令注入到 location / 块"
            return
        fi
    fi

    # fallback：python3 不可用，用 sed 处理（仅限简单单 location / 场景）
    if grep -qE '^[[:space:]]*location[[:space:]]*/[[:space:]]*\{' "$conf"; then
        sed -i "0,/^[[:space:]]*location[[:space:]]*\/[[:space:]]*{/ \
            s//&\n        ${marker//\//\\/}/" "$conf"
        success "已将 include 指令注入到 location / 块（sed fallback）"
    else
        # 没有 location /，在最后一个 } 前追加
        printf '\n    location / {\n        %s\n    }\n' "$marker" >> "$conf"
        success "未找到 location /，已在配置末尾追加 location / 块"
    fi
}

site_remove_acl() {
    require_root; init_dirs

    local domain=""
    safe_read -rp "要解除访问控制的域名: " domain
    [[ -z "$domain" ]] && die "域名不能为空"

    local acl_conf_file="${NGINX_CONF_DIR}/conf.d/acl-${domain}.conf"
    local snippet_file="${SNIPPET_DIR}/acl-location-${domain}.conf"
    local old_snippet_file="${NGINX_CONF_DIR}/conf.d/acl-location-${domain}.conf"   # 兼容旧版路径
    local auth_file="${NGINX_CONF_DIR}/.htpasswd-${domain}"
    local removed=0

    echo -e "${CYAN}── 开始清理 ${domain} 的限制 ──${NC}"

    # 删除 geo/map 文件
    if [[ -f "$acl_conf_file" ]]; then
        rm -f "$acl_conf_file"
        success "已删除 geo/map 配置文件: $acl_conf_file"
        removed=1
    fi

    # 删除 snippet 文件（新路径 + 兼容旧路径）
    for f in "$snippet_file" "$old_snippet_file"; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
            success "已删除 location 片段文件: $f"
            removed=1
        fi
    done

    # 从站点配置中移除 include 指令（新旧路径都处理）
    local conf=""
    for candidate in "${SITES_AVAILABLE}/${domain}.conf" "${SITES_AVAILABLE}/${domain}-redirect.conf"; do
        if [[ -f "$candidate" ]]; then
            if grep -qF "include ${snippet_file};" "$candidate" || grep -qF "include ${old_snippet_file};" "$candidate"; then
                conf="$candidate"
                break
            fi
        fi
    done

    if [[ -n "$conf" ]]; then
        # 删除包含对应 include 的行（新旧路径）
        sed -i "\|include ${snippet_file};|d" "$conf"
        sed -i "\|include ${old_snippet_file};|d" "$conf"
        success "已从 ${conf} 中移除 include 指令"
        removed=1
    else
        warn "未在站点配置中找到 include 指令，若之前手动添加请自行清理"
    fi

    # 删除 Basic Auth 密码文件
    if [[ -f "$auth_file" ]]; then
        rm -f "$auth_file"
        success "已删除 Basic Auth 密码文件: $auth_file"
        removed=1
    fi

    if [[ $removed -eq 1 ]]; then
        if nginx -t; then
            systemctl reload nginx
            success "Nginx 配置已通过测试并重载，访问控制已完全解除"
        else
            die "Nginx 配置测试失败，请检查并手动修复！"
        fi
    else
        info "未在系统中找到与域名 ${domain} 相关的 ACL 配置、片段或密码文件。"
    fi
}

# ──────────────────────────────────────────────────────────
# 限流
# ──────────────────────────────────────────────────────────
site_add_ratelimit() {
    require_root; init_dirs

    local domain=""
    safe_read -rp "要添加限流的域名: " domain
    [[ -z "$domain" ]] && die "域名不能为空"

    local conf="${SITES_AVAILABLE}/${domain}.conf"
    [[ ! -f "$conf" ]] && die "站点配置不存在，请先创建站点"

    # limit_req/limit_conn 都按 $binary_remote_addr 计数，Cloudflare 后面
    # 若未还原真实 IP，全站请求会被算成同一个边缘 IP，限流直接失效或误伤
    _maybe_prompt_cf_realip

    echo ""
    echo -e "${CYAN}── 请求速率限流（limit_req，防刷接口）──${NC}"
    safe_read -rp "每秒最大请求数（rate，默认 10）: " _rate
    safe_read -rp "内存区大小（zone size，默认 10m）: " _zone_size
    safe_read -rp "突发请求容量（burst，默认 20）: " _burst
    safe_read -rp "启用 nodelay（超出 burst 直接 503）？[Y/n]: " _nodelay

    [[ -z "$_rate"      ]] && _rate=10
    [[ -z "$_zone_size" ]] && _zone_size="10m"
    [[ -z "$_burst"     ]] && _burst=20
    local nodelay_flag=""
    [[ "${_nodelay,,}" != "n" ]] && nodelay_flag=" nodelay"

    echo ""
    echo -e "${CYAN}── 并发连接数限流（limit_conn，防单 IP 占满 worker 连接）──${NC}"
    safe_read -rp "是否同时启用？[y/N]: " _use_conn
    local conn_limit=""
    if [[ "${_use_conn,,}" == "y" || "${_use_conn,,}" == "yes" ]]; then
        safe_read -rp "单 IP 最大并发连接数（默认 20）: " conn_limit
        [[ -z "$conn_limit" ]] && conn_limit=20
    fi

    local zone_name="limit_${domain//./_}"
    local conn_zone_name="conn_${domain//./_}"
    local rl_conf="${NGINX_CONF_DIR}/conf.d/ratelimit-${domain}.conf"

    {
        echo "# 限流配置: ${domain}  生成时间: $(date)"
        echo "limit_req_zone \$binary_remote_addr zone=${zone_name}:${_zone_size} rate=${_rate}r/s;"
        echo "limit_req_status 429;"
        if [[ -n "$conn_limit" ]]; then
            echo "limit_conn_zone \$binary_remote_addr zone=${conn_zone_name}:10m;"
            echo "limit_conn_status 429;"
        fi
    } > "$rl_conf"
    success "限流 zone 配置写入: $rl_conf"

    # 自动将 limit_req / limit_conn 注入到站点 location / 块（避免手动编辑）
    local inject_lines="limit_req zone=${zone_name} burst=${_burst}${nodelay_flag};"
    [[ -n "$conn_limit" ]] && inject_lines="${inject_lines}\n        limit_conn zone=${conn_zone_name} ${conn_limit};"

    local marker="limit_req zone=${zone_name}"
    if grep -qF "$marker" "$conf"; then
        info "limit_req 指令已存在，跳过注入（如需补充 limit_conn 请手动添加）"
    elif grep -q 'location[[:space:]]*/[[:space:]]*{' "$conf"; then
        sed -i "0,/location[[:space:]]*\/[[:space:]]*{/ s//&\n        ${inject_lines}/" "$conf"
        success "已自动注入限流指令到 location / 块"
    else
        warn "未找到 location / 块，请手动添加: ${inject_lines}"
    fi

    warn "请确认 nginx.conf 的 http{} 中已 include /etc/nginx/conf.d/*.conf"
    nginx_reload
}

# ──────────────────────────────────────────────────────────
# 配置备份 & 还原（安全增强）
# ──────────────────────────────────────────────────────────
config_backup() {
    require_root
    mkdir -p "$BACKUP_DIR"

    local ts; ts=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_DIR}/nginx-backup-${ts}.tar.gz"

    info "正在备份 Nginx 配置..."

    local -a items=()
    [[ -d "$SITES_AVAILABLE"              ]] && items+=("$SITES_AVAILABLE")
    [[ -d "$SITES_DIR"                    ]] && items+=("$SITES_DIR")
    [[ -d "$SELF_CERT_DIR"                ]] && items+=("$SELF_CERT_DIR")
    [[ -d "${NGINX_CONF_DIR}/conf.d"      ]] && items+=("${NGINX_CONF_DIR}/conf.d")
    [[ -d "${NGINX_CONF_DIR}/stream.d"    ]] && items+=("${NGINX_CONF_DIR}/stream.d")
    [[ -f "${NGINX_CONF_DIR}/nginx.conf"  ]] && items+=("${NGINX_CONF_DIR}/nginx.conf")

    tar -czf "$backup_file" "${items[@]}" 2>/dev/null || true

    local size; size=$(du -sh "$backup_file" 2>/dev/null | cut -f1)
    success "备份完成: ${backup_file} (${size})"
    echo ""
    info "备份内容:"
    tar -tzf "$backup_file" 2>/dev/null | head -30 || true
}

config_restore() {
    require_root

    echo ""
    info "可用的备份文件:"
    local -a backups=()
    while IFS= read -r f; do
        backups+=("$f")
    done < <(ls -1t "${BACKUP_DIR}"/*.tar.gz 2>/dev/null || true)

    if [[ ${#backups[@]} -eq 0 ]]; then
        warn "暂无备份文件（目录: ${BACKUP_DIR}）"; return
    fi

    local i=1
    for f in "${backups[@]}"; do
        local ts size
        ts=$(basename "$f" .tar.gz | sed 's/nginx-backup-//')
        size=$(du -sh "$f" 2>/dev/null | cut -f1)
        printf "  %2d) %s  [%s]\n" "$i" "$ts" "$size"
        (( i++ ))
    done
    echo ""
    safe_read -rp "选择备份序号 [1-${#backups[@]}]: " _idx

    local count="${#backups[@]}"
    if ! [[ "$_idx" =~ ^[0-9]+$ ]] || (( _idx < 1 || _idx > count )); then
        die "无效序号 '$_idx'，请输入 1 到 ${count} 之间的数字"
    fi

    local chosen="${backups[$(( _idx - 1 ))]}"
    [[ -z "$chosen" || ! -f "$chosen" ]] && die "无效序号"

    # 展示备份内容让用户确认
    echo ""
    warn "即将还原以下文件（从 $chosen）："
    tar -tzf "$chosen" 2>/dev/null | head -20 || true
    echo "  ... (共 $(tar -tzf "$chosen" 2>/dev/null | wc -l) 个文件)"
    confirm "此操作将覆盖当前配置文件，是否继续？" || { info "已取消"; return; }

    info "先备份当前配置..."
    config_backup

    info "正在还原..."
    # 安全解压到临时目录，再移动到 /，避免直接覆盖系统文件
    local tmpdir; tmpdir=$(mktemp -d /tmp/nginx-restore.XXXXXX)
    tar -xzf "$chosen" -C "$tmpdir" 2>/dev/null || die "解压备份失败"
    # 将 etc/nginx 下的内容复制回原处
    if [[ -d "$tmpdir/etc/nginx" ]]; then
        cp -a "$tmpdir/etc/nginx/"* /etc/nginx/ 2>/dev/null || warn "部分文件复制失败，请检查权限"
    else
        warn "备份包中未包含 /etc/nginx 结构，跳过自动还原"
    fi
    rm -rf "$tmpdir"
    nginx_reload
    success "配置已还原自: $(basename "$chosen")"
}

config_backup_list() {
    echo -e "\n${BOLD}=== 备份文件列表 ===${NC}"
    if ls "${BACKUP_DIR}"/*.tar.gz &>/dev/null; then
        ls -lht "${BACKUP_DIR}"/*.tar.gz \
            | awk '{printf "  %-40s %s %s\n", $9, $5, $6" "$7}'
    else
        echo "  暂无备份（目录: ${BACKUP_DIR}）"
    fi
    echo ""
}

# ──────────────────────────────────────────────────────────
# 站点生命周期
# ──────────────────────────────────────────────────────────
# ──────────────────────────────────────────────────────────
# 裸 IP 访问拦截（每次建站后自动确保存在）
# 原理：nginx 匹配无 server_name 的请求时，优先使用标记了
#       default_server 的 vhost；本函数确保该 vhost 始终存在
#       且文件名 00- 排在所有站点配置之前。
# ──────────────────────────────────────────────────────────
_ensure_block_ip() {
    local block_conf="${SITES_AVAILABLE}/00-block-ip.conf"
    local block_link="${SITES_DIR}/00-block-ip.conf"

    # 检测 nginx 是否支持 ssl_reject_handshake（1.19.4+）
    local support_reject=true
    if nginx -V 2>&1 | grep -qE "nginx/1\.(1[0-8]|[0-9])\."; then
        support_reject=false
    fi

    mkdir -p "${ACME_WEBROOT}/.well-known/acme-challenge" 2>/dev/null || true

    # 若文件已存在，检查内容是否与当前 nginx 能力匹配 且已包含 ACME 放行规则，
    # 否则重新生成（FIX: 旧版本文件没有 acme-challenge 例外，需要强制刷新一次）
    if [[ -f "$block_conf" ]] && [[ -L "$block_link" ]]; then
        if grep -q "acme-challenge" "$block_conf"; then
            if $support_reject && grep -q "ssl_reject_handshake" "$block_conf"; then
                return 0
            elif ! $support_reject && ! grep -q "ssl_reject_handshake" "$block_conf"; then
                return 0
            fi
        fi
        info "检测到裸 IP 拦截配置需要更新（nginx 版本变化 / ACME 放行规则），重新生成..."
    fi

    # 自签名证书目录（旧版 nginx 兜底用）
    local fallback_cert="${SELF_CERT_DIR}/_default/fullchain.pem"
    local fallback_key="${SELF_CERT_DIR}/_default/privkey.pem"

    if $support_reject; then
        # 新版：ssl_reject_handshake，无需证书
        cat > "$block_conf" <<BLOCKEOF
# 自动生成 — 拦截裸 IP 访问，勿手动删除
# 生成时间: $(date)
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    # FIX: 放行 ACME HTTP-01 验证请求，避免挡住尚未建站的新域名申请证书
    location ^~ /.well-known/acme-challenge/ {
        default_type "text/plain";
        root ${ACME_WEBROOT};
    }

    return 444;
}

server {
    listen 443 default_server ssl;
    listen [::]:443 default_server ssl;
    server_name _;
    ssl_reject_handshake on;
}
BLOCKEOF
    else
        # 旧版：生成自签名证书兜底，让 443 能启动
        warn "当前 Nginx 版本不支持 ssl_reject_handshake，将使用自签名证书兜底"
        if [[ ! -f "$fallback_cert" ]]; then
            mkdir -p "${SELF_CERT_DIR}/_default"
            openssl req -x509 -nodes -days 3650 -newkey rsa:2048                 -keyout "$fallback_key"                 -out    "$fallback_cert"                 -subj   "/CN=_default/O=Block/C=CN" 2>/dev/null             && info "已生成兜底自签名证书: $fallback_cert"             || { warn "自签名证书生成失败，跳过 443 拦截块"; fallback_cert=""; }
        fi

        if [[ -n "$fallback_cert" ]]; then
            cat > "$block_conf" <<BLOCKEOF
# 自动生成 — 拦截裸 IP 访问，勿手动删除
# 生成时间: $(date)
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    # FIX: 放行 ACME HTTP-01 验证请求，避免挡住尚未建站的新域名申请证书
    location ^~ /.well-known/acme-challenge/ {
        default_type "text/plain";
        root ${ACME_WEBROOT};
    }

    return 444;
}

server {
    listen 443 default_server ssl;
    listen [::]:443 default_server ssl;
    server_name _;
    ssl_certificate     ${fallback_cert};
    ssl_certificate_key ${fallback_key};
    return 444;
}
BLOCKEOF
        else
            cat > "$block_conf" <<BLOCKEOF
# 自动生成 — 拦截裸 IP 访问，勿手动删除
# 生成时间: $(date)
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    # FIX: 放行 ACME HTTP-01 验证请求，避免挡住尚未建站的新域名申请证书
    location ^~ /.well-known/acme-challenge/ {
        default_type "text/plain";
        root ${ACME_WEBROOT};
    }

    return 444;
}
BLOCKEOF
        fi
    fi

    ln -sf "$block_conf" "$block_link"
    info "已生成裸 IP 拦截配置: $block_conf"
}

_site_activate() {
    local domain="$1"
    local avail="${SITES_AVAILABLE}/${domain}.conf"
    local enabled="${SITES_DIR}/${domain}.conf"

    if [[ -e "${SITES_DIR}/default" ]]; then
        rm -f "${SITES_DIR}/default"
        info "已移除默认站点 default"
    fi

    # 确保裸 IP 拦截始终存在
    _ensure_block_ip

    ln -sf "$avail" "$enabled"
    success "配置已写入: $avail"
    nginx_reload
    echo ""
    success "✓ 站点 ${domain} 已就绪"
}

site_enable() {
    require_root
    local domain="${1:-}"
    [[ -z "$domain" ]] && safe_read -rp "域名: " domain
    local conf="${SITES_AVAILABLE}/${domain}.conf"
    [[ -f "$conf" ]] || die "配置不存在: $conf"
    ln -sf "$conf" "${SITES_DIR}/${domain}.conf"
    nginx_reload
    success "站点已启用: $domain"
}

site_disable() {
    require_root
    local domain="${1:-}"
    [[ -z "$domain" ]] && safe_read -rp "域名: " domain
    local link="${SITES_DIR}/${domain}.conf"
    [[ -L "$link" ]] || die "站点未启用: $domain"
    rm -f "$link"
    nginx_reload
    success "站点已禁用: $domain"
}

site_delete() {
    require_root
    local domain="${1:-}"
    [[ -z "$domain" ]] && safe_read -rp "域名: " domain
    confirm "确认删除站点 ${domain} 的配置？" || { info "已取消"; return; }

    # 主配置文件（普通站点 / redirect）
    rm -f "${SITES_DIR}/${domain}.conf"           "${SITES_AVAILABLE}/${domain}.conf"           "${SITES_DIR}/${domain}-redirect.conf"           "${SITES_AVAILABLE}/${domain}-redirect.conf"

    # ACL 附属文件
    local acl_conf="${NGINX_CONF_DIR}/conf.d/acl-${domain}.conf"
    local acl_snippet="${SNIPPET_DIR}/acl-location-${domain}.conf"
    local acl_snippet_old="${NGINX_CONF_DIR}/conf.d/acl-location-${domain}.conf"
    local auth_file="${NGINX_CONF_DIR}/.htpasswd-${domain}"
    for f in "$acl_conf" "$acl_snippet" "$acl_snippet_old" "$auth_file"; do
        [[ -f "$f" ]] && { rm -f "$f"; info "已清理: $f"; }
    done

    # 限流附属文件
    local rl_conf="${NGINX_CONF_DIR}/conf.d/ratelimit-${domain}.conf"
    [[ -f "$rl_conf" ]] && { rm -f "$rl_conf"; info "已清理: $rl_conf"; }

    if confirm "是否同时删除网站文件（${WEBROOT_BASE}/${domain}）？"; then
        if [[ -d "${WEBROOT_BASE:?}/${domain:?}" ]]; then
            validate_safe_path "${WEBROOT_BASE}/${domain}"
            rm -rf "${WEBROOT_BASE:?}/${domain:?}"
            info "网站文件已删除"
        fi
    fi
    nginx_reload
    success "站点 $domain 已删除"
}

site_list() {
    init_dirs
    echo -e "\n${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    printf  "${BOLD}║${NC}  %-28s %-4s  %-14s  ${BOLD}║${NC}\n" "域名/配置" "状态" "类型"
    echo -e "${BOLD}╠══════════════════════════════════════════════════╣${NC}"

    local found=false
    for conf in "${SITES_AVAILABLE}"/*.conf \
                "${NGINX_CONF_DIR}"/stream.d/stream-*.conf; do
        [[ -f "$conf" ]] || continue
        found=true
        local name; name=$(basename "$conf" .conf)

        local status_text status_color
        if [[ -L "${SITES_DIR}/${name}.conf" ]]; then
            status_text="启用"; status_color="$GREEN"
        else
            status_text="禁用"; status_color="$RED"
        fi

        local type="静态文件"
        grep -q "upstream"    "$conf" 2>/dev/null && type="负载均衡"
        grep -q "sub_filter"  "$conf" 2>/dev/null && [[ "$type" == "静态文件" ]] && type="镜像聚合"
        grep -q "proxy_pass"  "$conf" 2>/dev/null && [[ "$type" == "静态文件" ]] && type="反向代理"
        grep -q "stream {"    "$conf" 2>/dev/null && type="流代理"
        [[ "$name" == forward-proxy-* ]]           && type="正向代理"
        grep -qE "return [0-9]{3}" "$conf" 2>/dev/null             && ! grep -q "proxy_pass\|root " "$conf" 2>/dev/null             && type="跳转重定向"
        grep -q "ssl_certificate" "$conf" 2>/dev/null && type+=" [SSL]"

        printf "${BOLD}║${NC}  %-28s ${status_color}%-4s${NC}  %-14s  ${BOLD}║${NC}
"             "$name" "$status_text" "$type"

        # 负载均衡：显示节点列表和后台固定节点
        if grep -q "^upstream" "$conf" 2>/dev/null; then
            # 通用节点
            while IFS= read -r line; do
                local addr; addr=$(echo "$line" | awk '{print $2}')
                printf "${BOLD}║${NC}    %-26s %-4s  %-14s  ${BOLD}║${NC}
"                     "  ↳ $addr" "" "节点"
            done < <(grep -E "^[[:space:]]+server .+ max_fails" "$conf" 2>/dev/null || true)
            # 后台固定节点
            local master_addr
            master_addr=$(grep -A2 "_master" "$conf" 2>/dev/null                 | grep -E "^[[:space:]]+server " | awk '{print $2}' | head -1 || true)
            [[ -n "$master_addr" ]] &&                 printf "${BOLD}║${NC}    %-26s %-4s  %-14s  ${BOLD}║${NC}
"                     "  ⭐ $master_addr" "" "后台固定"
        fi
    done
    $found || echo "  暂无站点配置"
    echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}\n"
}

site_info() {
    local domain="${1:-}"
    [[ -z "$domain" ]] && safe_read -rp "域名: " domain

    local conf="${SITES_AVAILABLE}/${domain}.conf"
    [[ ! -f "$conf" ]] && conf="${SITES_AVAILABLE}/forward-proxy-${domain}.conf"
    [[ ! -f "$conf" ]] && conf="${NGINX_CONF_DIR}/stream.d/stream-${domain}.conf"
    [[ ! -f "$conf" ]] && die "配置不存在"

    echo -e "\n${BOLD}=== $domain ===${NC}"
    cat "$conf"
}

site_edit() {
    require_root
    local domain="${1:-}"
    [[ -z "$domain" ]] && safe_read -rp "域名: " domain
    local conf="${SITES_AVAILABLE}/${domain}.conf"
    [[ -f "$conf" ]] || die "配置不存在: $conf"
    local editor="${EDITOR:-vi}"
    "$editor" "$conf"
    nginx_reload
}

# ──────────────────────────────────────────────────────────
# 帮助
# ──────────────────────────────────────────────────────────
show_help() {
    cat <<HELP
${BOLD}nginx-gateway.sh — Nginx 全功能网关管理工具${NC}
 
${BOLD}用法:${NC}
  $0 <命令> [子命令] [选项]
  $0                      （无参数，进入交互式主菜单）
 
${BOLD}站点创建:${NC}
  site static             静态文件托管（可选 PHP / 自定义端口 / 多种 SSL 模式）
  site proxy              反向代理（内网 IP:端口，WebSocket 自适应）
  site mirror             外部域名代理（透传 / 镜像两种子模式）
  site forward            HTTP 正向代理（含 IP 白名单）
  site stream             TCP/UDP 流代理（需 stream 模块）
  site redirect           域名跳转（301/302/307/308，多种路径策略）
  site loadbalance        负载均衡（upstream 多节点，含健康检查）
  site lb-node            负载均衡节点管理（添加/删除/列出）
  
 
${BOLD}站点管理:${NC}
  site enable  <域名>     启用站点
  site disable <域名>     禁用站点
  site delete  <域名>     删除站点（可选同时删除文件）
  site list               列出所有站点及类型/状态
  site info    <域名>     查看配置内容
  site edit    <域名>     编辑配置文件
 
${BOLD}安全增强:${NC}
  site acl                为站点添加 IP 白/黑名单 或 Basic Auth 认证
  site ratelimit          为站点添加限流（limit_req_zone，防刷接口）
 
${BOLD}证书管理:${NC}
  cert issue              申请 Let's Encrypt 证书
    -d <域名> -e <邮箱>  [-m nginx|webroot|standalone]  [--wildcard]
  cert self-signed        生成自签名证书
    -d <域名>  [--days <天数，默认3650>]
  cert renew  [域名]      手动续期（不填则续期全部）
  cert list               列出所有证书及到期时间
  cert auto-renew         配置 cron/systemd 自动续期
 
${BOLD}配置备份:${NC}
  backup create           备份 Nginx 所有配置到 ${BACKUP_DIR}/
  backup restore          从备份还原配置（自动先备份当前）
  backup list             列出所有备份文件
 
${BOLD}Nginx 控制:${NC}
  nginx install           安装 Nginx（自动检测包管理器）
  nginx update            检查并更新 Nginx 到最新版本（自动重启生效）
  nginx reload            检查语法并重载配置
  nginx restart           重启 Nginx
  nginx status            查看运行状态
 
${BOLD}Cloudflare 真实 IP（全局，影响本机所有站点，谨慎启用）:${NC}
  cf-realip install       启用：拉取 CF IP 段并信任 CF-Connecting-IP 头
  cf-realip refresh       刷新 IP 段（CF 段极少变动，非必需但可定期执行）
  cf-realip remove        关闭
  cf-realip status        查看状态
 
${BOLD}示例:${NC}
  sudo $0                                           # 进入交互式菜单
  sudo $0 site proxy                                # 创建反向代理
  sudo $0 site mirror                               # 外部域名透传或镜像
  sudo $0 site redirect                             # 创建跳转规则
  sudo $0 site acl                                  # 添加 IP 访问控制
  sudo $0 cert issue -d example.com -e me@a.com    # 申请 LE 证书
  sudo $0 cert issue -d example.com -e me@a.com --wildcard
  sudo $0 backup create                             # 备份配置
 
HELP
}

# ──────────────────────────────────────────────────────────
# 交互式主菜单
# ──────────────────────────────────────────────────────────
interactive_menu() {
    require_root
    while true; do
        clear
        echo -e "${BOLD}${GREEN}"
        echo "  ╔════════════════════════════════════════════════╗"
        echo "  ║        Nginx 全功能网关管理工具                 ║"
        echo "  ╚════════════════════════════════════════════════╝"
        echo -e "${NC}"
        # ... 菜单项与原脚本相同，所有 read 改为 safe_read
        echo -e " ${CYAN}── 站点创建 ──${NC}"
        echo "  1) 静态文件托管"
        echo "  2) 反向代理"
        echo "  3) 外部域名代理"
        echo "  4) HTTP 正向代理"
        echo "  5) TCP/UDP 流代理"
        echo "  6) 域名跳转"
        echo "  7) 负载均衡"
        echo ""
        echo -e " ${CYAN}── 站点管理 ──${NC}"
        echo "  8) 列出所有站点"
        echo "  9) 启用站点"
        echo " 10) 禁用站点"
        echo " 11) 删除站点"
        echo " 12) 查看 / 编辑配置"
        echo ""
        echo -e " ${CYAN}── 安全增强 ──${NC}"
        echo " 13) 添加访问控制"
        echo " 14) 添加限流规则"
        echo ""
        echo -e " ${CYAN}── 证书管理 ──${NC}"
        echo " 15) 申请 Let's Encrypt"
        echo " 16) 生成自签名证书"
        echo " 17) 续期证书"
        echo " 18) 列出所有证书"
        echo " 19) 配置自动续期"
        echo ""
        echo -e " ${CYAN}── 配置备份 ──${NC}"
        echo " 20) 备份配置"
        echo " 21) 还原配置"
        echo " 22) 查看备份列表"
        echo ""
        echo -e " ${CYAN}── Nginx ──${NC}"
        echo " 23) 重载配置"
        echo " 24) 重启 Nginx"
        echo " 25) 解除限制访问"
        echo " 26) 负载均衡节点管理"
        echo " 27) 查看状态"
        echo " 28) 检查并更新 Nginx"
        echo " 29) Cloudflare 真实 IP 管理"
        echo "  0) 退出"
        echo ""
        safe_read -rp "请选择 [0-29]: " choice

        case "$choice" in
             1) site_create_static ;;
             2) site_create_proxy ;;
             3) site_create_mirror ;;
             4) site_create_forward_proxy ;;
             5) site_create_stream_proxy ;;
             6) site_create_redirect ;;
             7) site_create_loadbalance ;;
             8) site_list ;;
             9) site_enable ;;
            10) site_disable ;;
            11) site_delete ;;
            12)
                echo "  v) 查看配置    e) 编辑配置"
                safe_read -rp "选择 [v/e]: " _act
                safe_read -rp "域名: " _d
                [[ "${_act,,}" == "e" ]] && site_edit "$_d" || site_info "$_d"
                ;;
            13) site_add_acl ;;
            14) site_add_ratelimit ;;
            15) cmd_cert_issue ;;
            16) cmd_cert_self_signed ;;
            17) safe_read -rp "域名（留空续期全部）: " _d; cmd_cert_renew "${_d:-}" ;;
            18) cmd_cert_list ;;
            19) cmd_cert_auto_renew ;;
            20) config_backup ;;
            21) config_restore ;;
            22) config_backup_list ;;
            23) nginx_reload ;;
            24) nginx_restart ;;
            25) site_remove_acl ;;
            26) site_lb_node ;;
            27) nginx_status ;;
            28) nginx_update ;;
            29)
                echo "  i) 启用   r) 刷新   d) 关闭   s) 状态"
                safe_read -rp "选择 [i/r/d/s]: " _cfa
                case "${_cfa,,}" in
                    i) cmd_cf_realip install ;;
                    r) cmd_cf_realip refresh ;;
                    d) cmd_cf_realip remove ;;
                    *) cmd_cf_realip status ;;
                esac
                ;;
             0) echo "再见！"; exit 0 ;;
             *) warn "无效选项，请重试" ;;
        esac
        safe_read -rp "按回车继续..." _
        echo ""
    done
}

# ──────────────────────────────────────────────────────────
# 命令行入口
# ──────────────────────────────────────────────────────────
main() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    if ! touch "$LOG_FILE" 2>/dev/null; then
        echo "警告: 无法写入日志文件 $LOG_FILE，将仅输出到终端。" >&2
        LOG_FILE="/dev/null"
    fi

    [[ $# -eq 0 ]] && { check_and_install_nginx; init_dirs; interactive_menu; exit 0; }

    local cmd="${1}"; shift || true
    local sub="${1:-}"; [[ $# -gt 0 ]] && shift || true

    case "${cmd}" in
        site)
            case "${sub}" in
                static)      site_create_static ;;
                proxy)       site_create_proxy ;;
                mirror)      site_create_mirror ;;
                forward)     site_create_forward_proxy ;;
                stream)      site_create_stream_proxy ;;
                redirect)    site_create_redirect ;;
                loadbalance) site_create_loadbalance ;;
                acl)         site_add_acl ;;
                ratelimit)   site_add_ratelimit ;;
                enable)      site_enable "${1:-}" ;;
                disable)     site_disable "${1:-}" ;;
                delete)      site_delete "${1:-}" ;;
                list)        site_list ;;
                info)        site_info "${1:-}" ;;
                edit)        site_edit "${1:-}" ;;
                lb-node)     site_lb_node ;;
                *)           show_help ;;
            esac ;;
        cert)
            case "${sub}" in
                issue)       cmd_cert_issue "$@" ;;
                self-signed) cmd_cert_self_signed "$@" ;;
                renew)       cmd_cert_renew "${1:-}" ;;
                list)        cmd_cert_list ;;
                auto-renew)  cmd_cert_auto_renew ;;
                *)           show_help ;;
            esac ;;
        backup)
            case "${sub}" in
                create)      config_backup ;;
                restore)     config_restore ;;
                list)        config_backup_list ;;
                *)           show_help ;;
            esac ;;
        nginx)
            case "${sub}" in
                install)     check_and_install_nginx ;;
                update)      nginx_update ;;
                reload)      nginx_reload ;;
                restart)     nginx_restart ;;
                status)      nginx_status ;;
                *)           show_help ;;
            esac ;;
        cf-realip)
            cmd_cf_realip "${sub:-status}"
            ;;
        help|--help|-h) show_help ;;
        *) show_help ;;
    esac
}

main "$@"
