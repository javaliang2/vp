#!/bin/bash
# ============================================================
#  nginx-harden.sh — Nginx 自动化安全加固脚本 v2.0
#  功能：版本隐藏 / 安全头 / 方法限制 / 缓冲区防溢出 / 敏感文件防护
#        自动备份回滚 / 自动注入 / CSP / 限流 / 命令行非交互
#  系统：Ubuntu / Debian / CentOS / RHEL / Arch
# ============================================================
set -euo pipefail
umask 022

# ── 全局配置 ──
NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx}"
CONF_D_DIR="${NGINX_CONF_DIR}/conf.d"
SNIPPETS_DIR="${NGINX_CONF_DIR}/snippets"
BACKUP_DIR="/var/backups/nginx-harden"
LOG_FILE="/var/log/nginx-harden.log"
TIMESTAMP=$(date +'%Y-%m-%d %H:%M:%S')
BACKUP_FILE="${BACKUP_DIR}/nginx-backup-$(date +%Y%m%d-%H%M%S).tar.gz"

# ── 颜色与日志 ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

_log() {
    local msg="$*"
    echo -e "${msg}" 1>&2
    # 写入日志（去除颜色）
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
    mkdir -p "$CONF_D_DIR" "$SNIPPETS_DIR" "$BACKUP_DIR" "$(dirname "$LOG_FILE")"
    command -v nginx &>/dev/null || die "未检测到 Nginx，请先安装"
    if ! nginx -T 2>/dev/null | grep -q 'include.*conf\.d/\*\.conf'; then
        warn "主配置可能未包含 ${CONF_D_DIR}，请确认 nginx.conf 中存在 'include conf.d/*.conf;'"
    fi
    # 确保 nginx 版本支持 limit_req_zone 等（nginx 1.1.4+ 均支持）
}

# ── 备份与回滚 ──
backup_configs() {
    info "正在备份整个 Nginx 配置目录到 ${BACKUP_FILE} ..."
    tar -czf "${BACKUP_FILE}" -C / etc/nginx 2>/dev/null || die "备份失败，请检查磁盘空间或权限"
    success "配置已备份"
}

restore_backup() {
    if [[ -f "${BACKUP_FILE}" ]]; then
        warn "配置检查失败，正在回滚到备份..."
        tar -xzf "${BACKUP_FILE}" -C / || die "回滚失败，请手动检查"
        success "已回滚到备份"
        nginx -t 1>&2 && systemctl reload nginx && success "回滚后 Nginx 已重载" || warn "回滚后 Nginx 仍存在问题，请手动排查"
    else
        die "未找到备份文件，无法回滚"
    fi
}

# ── 安全测试包装 ──
safe_reload() {
    if nginx -t 1>&2; then
        systemctl reload nginx
        success "Nginx 配置重载成功"
    else
        error "Nginx 配置语法错误！"
        if confirm "是否立即回滚到刚才的备份？"; then
            restore_backup
        else
            die "语法错误且未回滚，请手动修复后重载"
        fi
        false
    fi
}

# ── 加固模块 ──

harden_server_tokens() {
    local conf="${CONF_D_DIR}/90-security-tokens.conf"
    echo "server_tokens off;" > "$conf"
    success "已隐藏版本号 -> $conf"
}

harden_security_headers() {
    local conf="${CONF_D_DIR}/91-security-headers.conf"
    cat > "$conf" <<'EOF'
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
EOF
    success "基础安全头已配置 -> $conf"
}

# 可选 CSP
harden_csp() {
    local conf="${CONF_D_DIR}/93-csp.conf"
    if confirm "是否启用 Content-Security-Policy (CSP)？"; then
        warn "CSP 配置不当可能阻止合法资源加载，推荐使用 report-only 模式先观察"
        echo "  1) 严格模式（阻止未知资源）"
        echo "  2) 仅报告模式（不影响页面）"
        safe_read -r -p "请选择 [1-2，默认2]: " csp_mode
        local policy="default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline';"
        if [[ "$csp_mode" == "1" ]]; then
            echo "add_header Content-Security-Policy \"${policy}\" always;" > "$conf"
        else
            echo "add_header Content-Security-Policy-Report-Only \"${policy}\" always;" > "$conf"
        fi
        success "CSP 头已配置 -> $conf"
    else
        info "已跳过 CSP 配置"
    fi
}

# 可选 Permissions-Policy
harden_permissions_policy() {
    local conf="${CONF_D_DIR}/94-permissions-policy.conf"
    if confirm "是否启用 Permissions-Policy（限制 API 权限）？"; then
        local policy="camera=(), microphone=(), geolocation=(), interest-cohort=()"
        echo "add_header Permissions-Policy \"${policy}\" always;" > "$conf"
        success "Permissions-Policy 已配置 -> $conf"
    else
        info "已跳过 Permissions-Policy"
    fi
}

# 限制请求方法（严格 / WebDAV）
harden_http_methods() {
    local conf="${SNIPPETS_DIR}/secure-methods.conf"
    echo ""
    warn "严格限制请求方法可以防范非法探测"
    echo "  1) 严格模式: 仅 GET, HEAD, POST"
    echo "  2) WebDAV 兼容: 增加 PUT, DELETE, MKCOL 等"
    safe_read -r -p "请选择 [1-2，默认1]: " method_choice

    if [[ "${method_choice}" == "2" ]]; then
        cat > "$conf" <<'EOF'
if ($request_method !~ ^(GET|HEAD|POST|PUT|DELETE|MKCOL|COPY|MOVE|PROPFIND|OPTIONS)$) { return 405; }
EOF
        success "已生成 WebDAV 兼容请求拦截规则 -> $conf"
    else
        cat > "$conf" <<'EOF'
if ($request_method !~ ^(GET|HEAD|POST)$) { return 405; }
EOF
        success "已生成严格请求拦截规则 -> $conf"
    fi
    warn "需在 server {} 块中手动 include 或使用自动注入功能"
}

harden_buffers_timeouts() {
    local conf="${CONF_D_DIR}/92-security-buffers.conf"
    while true; do
        safe_read -r -p "全局最大上传限制 (例: 50M, 0不限) [默认50M]: " max_body
        [[ -z "$max_body" ]] && max_body="50M"
        if [[ $max_body =~ ^(0|[1-9][0-9]*[kKmMgG]?)$ ]]; then break
        else warn "格式无效，请输入 10M、1G 或 0"; fi
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
    success "缓冲区与超时限制已配置 -> $conf"
}

harden_sensitive_files() {
    local conf="${SNIPPETS_DIR}/secure-files.conf"
    cat > "$conf" <<'EOF'
location ~ /\.(?!well-known\/) { deny all; access_log off; log_not_found off; }
location ~* (?:\.(?:bak|config|sql|fla|psd|ini|log|sh|inc|swp|dist)|~)$ { deny all; access_log off; log_not_found off; }
EOF
    success "敏感文件屏蔽规则 -> $conf"
}

# 连接/请求限流
harden_rate_limit() {
    if confirm "是否启用请求/连接限流（防CC、防爬虫）？"; then
        local zone_conf="${CONF_D_DIR}/95-rate-limit.conf"
        safe_read -r -p "单IP请求速率限制 (r/s, 如 10r/s) [默认 10r/s]: " rate
        [[ -z "$rate" ]] && rate="10r/s"
        local burst="${rate%%r/s}"   # 简单提取数字
        burst=$(( burst * 2 ))
        cat > "$zone_conf" <<EOF
# 共享内存区域，10m 可存储约 16 万个 IP
limit_req_zone \$binary_remote_addr zone=req_limit:10m rate=${rate};
limit_conn_zone \$binary_remote_addr zone=conn_limit:10m;

# 应用到所有 server，可在需要时 include 或继承
EOF
        # 生成一个 snippet 供 server 块使用
        local snippet="${SNIPPETS_DIR}/rate-limit.conf"
        cat > "$snippet" <<EOF
limit_req zone=req_limit burst=${burst} nodelay;
limit_conn conn_limit 10;
EOF
        success "限流全局配置已生成 -> ${zone_conf}，Snippet -> ${snippet}"
        warn "需在 server/location 块中 include snippets/rate-limit.conf;"
    else
        info "已跳过限流配置"
    fi
}

# ── 自动注入 include 片段到所有 server 块 ──
auto_include_snippets() {
    if ! confirm "是否自动将所有站点配置注入 security snippets（secure-methods / secure-files 等）？"; then
        info "跳过自动注入，请手动添加"
        return
    fi

    local snippet_methods="snippets/secure-methods.conf"
    local snippet_files="snippets/secure-files.conf"
    local snippet_rate="snippets/rate-limit.conf"   # 可选

    # 查找所有包含 'server {' 且不在注释中的配置文件（排除 snippets 和 conf.d 全局）
    mapfile -t server_files < <(grep -rnIl '^\s*server\s*{' "${NGINX_CONF_DIR}" \
        --include="*.conf" --exclude-dir=snippets | grep -v "${CONF_D_DIR}/9[0-9]") || true

    if [[ ${#server_files[@]} -eq 0 ]]; then
        warn "未找到任何 server {} 块，跳过注入"
        return
    fi

    info "发现以下站点配置文件："
    printf '  %s\n' "${server_files[@]}"

    for f in "${server_files[@]}"; do
        info "处理 $f ..."
        # 备份单个文件
        cp "$f" "${f}.bak-$(date +%Y%m%d%H%M%S)"
        
        # 在第一个 server { 后插入（注意可能有多行）
        if ! grep -q "include ${snippet_methods};" "$f"; then
            sed -i "/^\s*server\s*{/a\    include ${snippet_methods};" "$f"
            success "  ✓ 已注入 ${snippet_methods}"
        else
            info "  - ${snippet_methods} 已存在"
        fi
        if ! grep -q "include ${snippet_files};" "$f"; then
            sed -i "/^\s*server\s*{/a\    include ${snippet_files};" "$f"
            success "  ✓ 已注入 ${snippet_files}"
        else
            info "  - ${snippet_files} 已存在"
        fi
        if [[ -f "${SNIPPETS_DIR}/rate-limit.conf" ]] && ! grep -q "include ${snippet_rate};" "$f"; then
            if confirm "是否为 $f 注入限流规则？"; then
                sed -i "/^\s*server\s*{/a\    include ${snippet_rate};" "$f"
                success "  ✓ 已注入 ${snippet_rate}"
            fi
        fi
    done
}

# ── 一键加固（完整流程） ──
apply_all_hardening() {
    backup_configs

    harden_server_tokens
    harden_security_headers
    harden_buffers_timeouts
    harden_csp
    harden_permissions_policy

    # 生成 snippet（严格方法 + 敏感文件，可选限流）
    info "生成请求方法限制（严格模式）"
    cat > "${SNIPPETS_DIR}/secure-methods.conf" <<'EOF'
if ($request_method !~ ^(GET|HEAD|POST)$) { return 405; }
EOF
    harden_sensitive_files   # 会创建 secure-files.conf
    harden_rate_limit

    # 自动注入
    auto_include_snippets

    echo ""
    info "所有配置已生成，即将检查语法并重载"
    if safe_reload; then
        success "一键加固完成！"
    else
        die "重载失败，已尝试回滚"
    fi
}

# 撤销所有配置
revert_hardening() {
    confirm "是否移除本脚本生成的所有配置并回滚到最近备份？" || return
    local files=(
        "${CONF_D_DIR}/90-security-tokens.conf"
        "${CONF_D_DIR}/91-security-headers.conf"
        "${CONF_D_DIR}/92-security-buffers.conf"
        "${CONF_D_DIR}/93-csp.conf"
        "${CONF_D_DIR}/94-permissions-policy.conf"
        "${CONF_D_DIR}/95-rate-limit.conf"
        "${SNIPPETS_DIR}/secure-methods.conf"
        "${SNIPPETS_DIR}/secure-files.conf"
        "${SNIPPETS_DIR}/rate-limit.conf"
    )
    for f in "${files[@]}"; do rm -f "$f"; done
    success "已删除所有加固配置"

    # 恢复备份（如果有）
    local latest_backup=$(ls -1t "${BACKUP_DIR}"/nginx-backup-*.tar.gz 2>/dev/null | head -1)
    if [[ -f "$latest_backup" ]]; then
        if confirm "检测到备份 ${latest_backup##*/}，是否恢复？"; then
            tar -xzf "$latest_backup" -C /
            success "已从备份恢复"
        fi
    fi

    info "建议手动检查 sites-enabled 中的 include 行并移除，然后重载 Nginx"
    if confirm "是否现在重载 Nginx？"; then
        safe_reload
    fi
}

# ── 命令行解析与主流程 ──
usage() {
    echo -e "${BOLD}用法:${NC} $0 [选项]"
    echo "  -a, --all     一键应用所有推荐加固"
    echo "  -r, --revert  撤销所有加固并恢复备份"
    echo "  --dry-run     仅生成配置不重载"
    echo "  -h, --help    显示帮助"
    echo "  无参数        进入交互式菜单"
    exit 0
}

DRY_RUN=false
CMD="menu"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--all) CMD="all"; shift ;;
        -r|--revert) CMD="revert"; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage ;;
        *) echo "未知参数: $1"; usage ;;
    esac
done

main() {
    require_root
    init_env

    # 若处于 dry-run，重载函数直接跳过
    if $DRY_RUN; then
        safe_reload() { info "Dry-run 模式，跳过重载"; true; }
    fi

    case "$CMD" in
        all) apply_all_hardening ;;
        revert) revert_hardening ;;
        menu) interactive_menu ;;
    esac
}

# 交互菜单（保留原有风格，稍作增强）
interactive_menu() {
    while true; do
        clear
        echo -e "${BOLD}${GREEN}"
        echo "  ╔════════════════════════════════════════════════╗"
        echo "  ║        Nginx 安全加固工具 v2.0                ║"
        echo "  ╚════════════════════════════════════════════════╝"
        echo -e "${NC}"
        echo -e " ${CYAN}── 快速操作 ──${NC}"
        echo "  1) 一键加固 + 自动注入 (推荐)"
        echo "  2) 撤销所有加固配置"
        echo ""
        echo -e " ${CYAN}── 精细配置 ──${NC}"
        echo "  3) 隐藏版本号"
        echo "  4) 基础安全头"
        echo "  5) 高级安全头 (CSP / Permissions-Policy)"
        echo "  6) 请求方法限制"
        echo "  7) 缓冲区与超时"
        echo "  8) 敏感文件屏蔽"
        echo "  9) 请求/连接限流"
        echo " 10) 自动注入 snippets 到站点"
        echo " 11) 重载 Nginx"
        echo "  0) 退出"
        echo ""
        safe_read -r -p "请选择 [0-11]: " choice

        case "$choice" in
            1) backup_configs; harden_server_tokens; harden_security_headers; harden_buffers_timeouts
               harden_csp; harden_permissions_policy; harden_rate_limit
               harden_http_methods; harden_sensitive_files
               auto_include_snippets; safe_reload
               safe_read -r -p "按回车继续..." _ ;;
            2) revert_hardening; safe_read -r -p "按回车继续..." _ ;;
            3) harden_server_tokens; safe_reload; safe_read -r -p "按回车继续..." _ ;;
            4) harden_security_headers; safe_reload; safe_read -r -p "按回车继续..." _ ;;
            5) harden_csp; harden_permissions_policy; safe_reload; safe_read -r -p "按回车继续..." _ ;;
            6) harden_http_methods; safe_read -r -p "按回车继续..." _ ;;
            7) harden_buffers_timeouts; safe_reload; safe_read -r -p "按回车继续..." _ ;;
            8) harden_sensitive_files; safe_read -r -p "按回车继续..." _ ;;
            9) harden_rate_limit; safe_read -r -p "按回车继续..." _ ;;
            10) auto_include_snippets; safe_reload; safe_read -r -p "按回车继续..." _ ;;
            11) safe_reload; safe_read -r -p "按回车继续..." _ ;;
            0) echo "再见！"; exit 0 ;;
            *) warn "无效选项" ;;
        esac
    done
}

main "$@"
