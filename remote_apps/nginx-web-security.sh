#!/bin/bash
# ============================================================
#  nginx-admin-restrict.sh — 后台访问限制（支持 Cloudflare CDN 双 Server 隔离）
#  从 nginx-web-security.sh 精简而来，只保留后台访问限制这一项功能
#  配合 nginx-gateway.sh 使用
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
LOG_FILE="/var/log/nginx-admin-restrict.log"
CONF_D_DIR="${NGINX_CONF_DIR}/conf.d"
CF_REALIP_CONF="${CONF_D_DIR}/00-cloudflare-realip.conf"

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
require_root

mkdir -p "$SNIPPET_DIR" "$BACKUP_DIR"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"

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

# ============================================================
# Cloudflare Real IP 还原（全局生效，与具体站点无关）
# ============================================================
fetch_cloudflare_ranges() {
    command -v curl >/dev/null 2>&1 || die "需要 curl，请先安装：apt install curl"
    info "正在从 Cloudflare 官方地址获取最新 IP 段..."
    CF_IPV4=$(curl -fsSL --max-time 10 "https://www.cloudflare.com/ips-v4") \
        || die "无法获取 Cloudflare IPv4 列表，请检查网络（是否可访问 cloudflare.com）"
    CF_IPV6=$(curl -fsSL --max-time 10 "https://www.cloudflare.com/ips-v6") \
        || die "无法获取 Cloudflare IPv6 列表，请检查网络（是否可访问 cloudflare.com）"
    [[ -z "$CF_IPV4" || -z "$CF_IPV6" ]] && die "获取到的 Cloudflare IP 列表为空，请稍后重试"
}

configure_cloudflare_realip() {
    echo -e "${CYAN}配置 Cloudflare Real IP 还原（全局生效，写入 ${CONF_D_DIR}）${NC}"
    echo -e "${YELLOW}提示：仅当站点确实经过 Cloudflare 代理（橙色云朵）时才需要此项。${NC}"

    mkdir -p "$CONF_D_DIR"
    fetch_cloudflare_ranges

    local header_choice real_ip_header
    safe_read -rp "识别真实 IP 使用哪个请求头？[1: CF-Connecting-IP(默认,推荐) 2: X-Forwarded-For]: " header_choice
    real_ip_header="CF-Connecting-IP"
    [[ "$header_choice" == "2" ]] && real_ip_header="X-Forwarded-For"

    if [[ -f "$CF_REALIP_CONF" ]]; then
        mkdir -p "$BACKUP_DIR"
        local backup_file="${BACKUP_DIR}/00-cloudflare-realip.conf.$(date +%Y%m%d%H%M%S).bak"
        cp -a "$CF_REALIP_CONF" "$backup_file"
        info "已备份旧配置到: $backup_file"
    fi

    {
        echo "# ---- Cloudflare Real IP 还原（自动生成，请勿手动编辑） ----"
        echo "# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# 来源: https://www.cloudflare.com/ips-v4  https://www.cloudflare.com/ips-v6"
        echo ""
        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            echo "set_real_ip_from ${ip};"
        done <<< "$CF_IPV4"
        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            echo "set_real_ip_from ${ip};"
        done <<< "$CF_IPV6"
        echo ""
        echo "real_ip_header ${real_ip_header};"
        echo "real_ip_recursive on;"
    } > "$CF_REALIP_CONF"

    success "已写入: $CF_REALIP_CONF"

    if ! grep -rqE "include\s+.*conf\.d/\*\.conf" "${NGINX_CONF_DIR}/nginx.conf" 2>/dev/null; then
        warn "未在 nginx.conf 的 http {} 块中检测到 'include ${CONF_D_DIR}/*.conf;'"
        warn "请手动在 nginx.conf 的 http {} 块内添加该 include，否则此配置不会生效"
    fi

    warn "重要：Real IP 还原信任该请求头来自 Cloudflare。务必确保源服务器的公网入口"
    warn "（防火墙/安全组）只放行 Cloudflare 出口 IP 段和你自己的管理网络，"
    warn "否则任何人都可以直接访问源站并伪造 ${real_ip_header} 头，绕过还原机制。"

    nginx -t && systemctl reload nginx && success "Cloudflare Real IP 还原已生效" || die "配置检查失败，请手动排查"
}

remove_cloudflare_realip() {
    if [[ -f "$CF_REALIP_CONF" ]]; then
        rm -f "$CF_REALIP_CONF"
        success "已删除: $CF_REALIP_CONF"
        nginx -t && systemctl reload nginx && success "Nginx 重载完成" || warn "配置检查失败，请手动处理"
    else
        warn "未找到 Cloudflare Real IP 配置文件: $CF_REALIP_CONF"
    fi
}

# ============================================================
# 自动提取原站点配置中的后端处理指令
# ============================================================
extract_backend_block() {
    local conf="$1"
    EXTRACTED_BACKEND=""
    EXTRACTED_BACKEND=$(awk '
        /^[[:space:]]*location[[:space:]]/ && !inside {
            inside = 1; brace = 0; inner = ""
            line = $0; gsub(/[^{}]/, "", line)
            for (i = 1; i <= length(line); i++) {
                c = substr(line, i, 1)
                if (c == "{") brace++
                else if (c == "}") brace--
            }
            if (brace == 0) {
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
                next
            }
        }
        inside {
            line = $0; gsub(/[^{}]/, "", line)
            for (i = 1; i <= length(line); i++) {
                c = substr(line, i, 1)
                if (c == "{") brace++
                else if (c == "}") brace--
            }
            if (brace <= 0) {
                sub(/}[[:space:]]*$/, "", $0)
                inner = inner $0 "\n"
                sub(/[[:space:]]+$/, "", inner)
                if (inner ~ /(proxy_pass|fastcgi_pass)/) {
                    print inner
                    exit
                }
                inside = 0
                next
            }
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
# 后台访问限制（支持 CDN 双 Server 隔离 + 自动提取后端）
# ============================================================
add_admin_access_restriction() {
    local paths_input allowed_network
    echo -e "${CYAN}配置后台访问限制 – 仅允许受信任网络访问管理页面${NC}"
    safe_read -rp "请输入需要保护的后台路径（空格分隔）[默认: wp-admin wp-login.php xmlrpc.php]: " paths_input
    paths_input=$(echo "$paths_input" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g')
    [[ -z "$paths_input" ]] && paths_input="wp-admin wp-login.php xmlrpc.php"

    local -a paths_arr esc_paths
    read -r -a paths_arr <<< "$paths_input"
    local p
    for p in "${paths_arr[@]}"; do
        esc_paths+=("${p//./\\.}")   # 转义 . ，避免 wp-login.php 里的点被当成正则任意字符
    done
    local paths_regex
    paths_regex=$(IFS='|'; echo "${esc_paths[*]}")

    # wp-admin 下的 admin-ajax.php 是 WordPress 前台（未登录访客）常用的公开接口，
    # 如果整体封锁 /wp-admin/ 会连它一起挡掉，导致前台功能（搜索/购物车/表单等）失效
    local expose_ajax="n"
    if printf '%s\n' "${paths_arr[@]}" | grep -qx "wp-admin"; then
        safe_read -rp "检测到 wp-admin，是否放行 /wp-admin/admin-ajax.php 供前台 AJAX 使用（多数 WordPress 站点需要）？[Y/n]: " expose_ajax
        expose_ajax="${expose_ajax:-y}"
    fi

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
        safe_read -rp "允许访问内网 Server 的网段 [默认: 10.0.0.0/8]: " allowed_network
        allowed_network="${allowed_network:-10.0.0.0/8}"

        get_ssl_cert_paths "$SELECTED_CONF"

        # 先拿到后端处理指令（admin-ajax 例外规则需要复用同一套 proxy_pass/fastcgi_pass）
        local auto_extract backend_block=""
        safe_read -rp "是否自动从原站配置提取后端处理指令？[Y/n]: " auto_extract
        auto_extract="${auto_extract:-y}"
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

        # 公网封锁规则：按用户实际输入的路径动态生成（不再硬编码固定三项）
        {
            echo "# ---- 后台路径公网封锁（CDN 环境） ----"
            echo "# 使用 = 和 ^~ 确保最高优先级，不会被其他 location 绕过"
            if [[ "${expose_ajax,,}" == "y" ]]; then
                echo "location = /wp-admin/admin-ajax.php {"
                echo "$backend_block" | sed 's/^/    /'
                echo "}"
            fi
            for p in "${paths_arr[@]}"; do
                if [[ "$p" == *.* ]]; then
                    echo "location = /${p} { deny all; }"
                else
                    echo "location ^~ /${p}/ { deny all; }"
                    echo "location = /${p}  { deny all; }"
                fi
            done
        } > "$SELECTED_SNIPPET"
        inject_include "$SELECTED_CONF" "$SELECTED_SNIPPET"

        local backend_indented
        backend_indented=$(echo "$backend_block" | sed 's/^/        /')

        local internal_conf="${SITES_AVAILABLE}/10-admin-${SELECTED_DOMAIN}.conf"
        # 用「引号包裹」的 heredoc（不做变量展开），占位符 + sed 替换标量值；
        # backend_block 单独以 printf 原样写入，避免其中的 nginx 变量（如 $host）
        # 被 bash 提前展开（脚本开了 set -u，未定义变量会直接报错退出）。
        {
            cat <<'TEMPLATE_HEAD'
# ---- 内网后台访问 Server (受信任网络直连) ----
server {
    listen __LISTEN__ ssl;
    http2 on;
    server_name __DOMAIN__;

    ssl_certificate     __SSL_CERT__;
    ssl_certificate_key __SSL_KEY__;

    location ~ ^/(__PATHS__)(/|$) {
        allow __ALLOWED_NET__;
        deny all;

TEMPLATE_HEAD
            printf '%s\n' "$backend_indented"
            cat <<'TEMPLATE_TAIL'
    }

    location / {
        return 404;
    }
}
TEMPLATE_TAIL
        } > "$internal_conf"

        # 用 # 做 sed 分隔符，避免证书路径/网段里的 / 冲突
        sed -i \
            -e "s#__LISTEN__#${wg_ip}:${wg_port}#" \
            -e "s#__DOMAIN__#${SELECTED_DOMAIN}#" \
            -e "s#__SSL_CERT__#${SSL_CERT}#" \
            -e "s#__SSL_KEY__#${SSL_KEY}#" \
            -e "s#__PATHS__#${paths_regex}#" \
            -e "s#__ALLOWED_NET__#${allowed_network}#" \
            "$internal_conf"

        ln -sf "$internal_conf" "${SITES_ENABLED}/10-admin-${SELECTED_DOMAIN}.conf"
        success "内网专用 Server 已创建: $internal_conf"
        success "请确保管理设备通过受信任网络访问 https://${wg_ip}:${wg_port}/${paths_arr[0]}"
        [[ "${expose_ajax,,}" == "y" ]] && info "已放行 /wp-admin/admin-ajax.php 公网访问（前台 AJAX 所需）"

    else
        # 非 CDN 直连模式
        safe_read -rp "允许访问的内网 IP 段 [默认: 10.0.0.0/8]: " allowed_network
        allowed_network="${allowed_network:-10.0.0.0/8}"
        {
            echo "# ---- 后台访问限制 (直连模式) ----"
            for p in "${paths_arr[@]}"; do
                if [[ "$p" == *.* ]]; then
                    echo "location = /${p} { allow ${allowed_network}; deny all; }"
                else
                    echo "location ^~ /${p}/ { allow ${allowed_network}; deny all; }"
                    echo "location = /${p}  { allow ${allowed_network}; deny all; }"
                fi
            done
        } > "$SELECTED_SNIPPET"
        inject_include "$SELECTED_CONF" "$SELECTED_SNIPPET"
        success "已添加直连模式 IP 限制，仅 ${allowed_network} 可访问后台。"
    fi
}

# ──────────────────────────────────────────────────────────
# 移除安全配置（包括内网 Server）
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
    while true; do
        clear
        echo -e "${BOLD}${GREEN}"
        echo "  ╔════════════════════════════════════════════════╗"
        echo "  ║   Nginx 后台访问限制 (CDN 双 Server 隔离)       ║"
        echo "  ╚════════════════════════════════════════════════╝"
        echo -e "${NC}"
        echo -e " ${CYAN}1)${NC} 后台访问限制 (WordPress/CDN 双 Server 隔离)"
        echo -e " ${CYAN}2)${NC} 配置 Cloudflare Real IP 还原 (全局，与站点无关)"
        echo -e " ${CYAN}3)${NC} 移除 Cloudflare Real IP 配置"
        echo -e " ${RED}R)${NC} 移除站点的安全配置"
        echo -e " ${CYAN}Q)${NC} 退出"
        echo ""
        safe_read -rp "请选择: " choice

        case "$choice" in
            1)
                list_domains
                add_admin_access_restriction
                nginx -t && systemctl reload nginx && success "后台限制已生效" || die "配置错误，请检查"
                ;;
            2)
                configure_cloudflare_realip
                ;;
            3)
                remove_cloudflare_realip
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

    # 与具体站点无关的全局动作，直接处理，不走站点校验
    case "${1}" in
        cloudflare-realip)
            configure_cloudflare_realip
            exit 0
            ;;
        remove-cloudflare-realip)
            remove_cloudflare_realip
            exit 0
            ;;
    esac

    local domain="${1}"
    local action="${2:-admin-restrict}"

    SELECTED_DOMAIN="$domain"
    SELECTED_CONF="${SITES_AVAILABLE}/${SELECTED_DOMAIN}.conf"
    SELECTED_SNIPPET="${SNIPPET_DIR}/security-${SELECTED_DOMAIN}.conf"
    [[ -f "$SELECTED_CONF" ]] || die "站点配置不存在: $SELECTED_CONF"

    case "$action" in
        admin-restrict)
            add_admin_access_restriction
            nginx -t && systemctl reload nginx && success "已生效" || die "配置错误"
            ;;
        remove)
            remove_security
            ;;
        *)
            echo "未知动作: $action"
            echo "可用动作: admin-restrict remove"
            echo "全局动作（第一个参数）: cloudflare-realip remove-cloudflare-realip"
            exit 1
            ;;
    esac
}

main "$@"
