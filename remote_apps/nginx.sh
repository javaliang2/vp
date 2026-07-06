#!/bin/bash
# ============================================================
#  upgrade-nginx-official.sh — 切换到 nginx.org 官方仓库
#  支持首次安装 / 已有 Debian-Ubuntu 打包版本的升级
#  默认 stable 分支，可用 --mainline 切换到 mainline
# ============================================================
set -euo pipefail

# ──────────────────────────────────────────────────────────
# 颜色 & 日志（与 nginx-web-security.sh 保持一致）
# ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

_log() { echo -e "$*" 1>&2; }
info()    { _log "${CYAN}[信息]${NC}  $*"; }
success() { _log "${GREEN}[成功]${NC}  $*"; }
warn()    { _log "${YELLOW}[警告]${NC}  $*"; }
error()   { _log "${RED}[错误]${NC}  $*"; }
die()     { error "$*"; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || die "请以 root 身份运行本脚本（sudo $0）"; }
safe_read() { set +e; read -r "$@"; local _rc=$?; set -e; return $_rc; }
confirm() {
    local _ans
    safe_read -rp "${YELLOW}$1 [y/N]${NC} " _ans
    [[ ${_ans,,} == "y" ]]
}

BACKUP_DIR="${BACKUP_DIR:-/var/backups/nginx-upgrade}"
KEYRING="/usr/share/keyrings/nginx-archive-keyring.gpg"
REPO_LIST="/etc/apt/sources.list.d/nginx.list"
EXPECTED_FPR="573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62"
BRANCH="stable"   # 默认 stable，生产环境优先稳定

# ──────────────────────────────────────────────────────────
# 参数解析
# ──────────────────────────────────────────────────────────
usage() {
    cat <<USAGE
用法: $0 [选项]
  --mainline     使用 mainline 分支（默认 stable，生产环境推荐 stable）
  --dry-run      只打印将要执行的操作，不实际修改系统
  -h, --help     显示本帮助
USAGE
    exit 0
}

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --mainline) BRANCH="mainline" ;;
        --dry-run)  DRY_RUN=1 ;;
        -h|--help)  usage ;;
        *) die "未知参数: $arg（用 --help 查看用法）" ;;
    esac
done

run() {
    if (( DRY_RUN )); then
        echo "[dry-run] $*"
    else
        eval "$@"
    fi
}

# ──────────────────────────────────────────────────────────
# 前置检查
# ──────────────────────────────────────────────────────────
require_root
mkdir -p "$BACKUP_DIR"

[[ -f /etc/os-release ]] || die "找不到 /etc/os-release，无法识别发行版"
. /etc/os-release
DISTRO_ID="$ID"
CODENAME="$(lsb_release -cs 2>/dev/null || echo "$VERSION_CODENAME")"

if [[ "$DISTRO_ID" != "debian" && "$DISTRO_ID" != "ubuntu" ]]; then
    die "未识别的发行版: $DISTRO_ID，请手动参考 https://nginx.org/en/linux_packages.html"
fi
[[ -n "$CODENAME" ]] || die "无法识别发行版代号（codename），请手动检查 lsb_release -cs"

info "发行版: ${DISTRO_ID} ${CODENAME}，目标分支: ${BRANCH}"

# 检查 nginx.org 是否已支持该代号，避免 apt update 时才发现 404
if [[ "$BRANCH" == "mainline" ]]; then
    INDEX_URL="https://nginx.org/packages/mainline/${DISTRO_ID}/dists/${CODENAME}/"
else
    INDEX_URL="https://nginx.org/packages/${DISTRO_ID}/dists/${CODENAME}/"
fi
if ! curl -fsSL -o /dev/null "$INDEX_URL"; then
    warn "nginx.org 官方仓库目前似乎不支持 ${DISTRO_ID} ${CODENAME}（${INDEX_URL} 404）"
    confirm "仍要继续吗？（可能后面 apt update 会失败）" || die "已取消"
fi

# 记录升级前版本，方便对比
OLD_VERSION="未安装"
if command -v nginx >/dev/null 2>&1; then
    OLD_VERSION="$(nginx -v 2>&1 | grep -oP '(?<=nginx/)[0-9.]+' || echo '未知')"
fi
info "当前 nginx 版本: ${OLD_VERSION}"

# 提醒：如果之前装了发行版自带的扩展模块，切到官方包后这些模块不会自动跟过来
if dpkg -l 2>/dev/null | grep -qE '^ii[[:space:]]*libnginx-mod-'; then
    warn "检测到系统装有发行版的 libnginx-mod-* 扩展模块，切到官方包后这些模块【不会】自动生效："
    dpkg -l | awk '/^ii[[:space:]]*libnginx-mod-/{print "  - "$2}'
    warn "如果配置里用到了这些模块的指令，升级后 nginx -t 可能会报 unknown directive，需要另找官方对应的 nginx-module-* 包"
    confirm "了解风险，继续吗？" || die "已取消"
fi

# ──────────────────────────────────────────────────────────
# 幂等检查：仓库是否已经是官方源、且分支一致
# ──────────────────────────────────────────────────────────
ALREADY_CONFIGURED=0
if [[ -f "$REPO_LIST" ]] && grep -q "nginx.org/packages" "$REPO_LIST"; then
    if grep -q "packages/${BRANCH}" "$REPO_LIST" || { [[ "$BRANCH" == "stable" ]] && ! grep -q "packages/mainline" "$REPO_LIST"; }; then
        info "已经配置为 nginx.org 官方 ${BRANCH} 仓库，跳过仓库配置步骤"
        ALREADY_CONFIGURED=1
    else
        warn "检测到已配置官方仓库，但分支和目标（${BRANCH}）不一致，将切换"
    fi
fi

if (( ! ALREADY_CONFIGURED )); then
    run "apt update"
    run "apt install -y curl gnupg2 ca-certificates lsb-release debian-archive-keyring"

    # 官方签名 key
    run "curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor | tee '$KEYRING' >/dev/null"

    # 校验指纹（keyring 里可能同时含多把 nginx 签名 key，逐一比对，
    # 只要目标指纹出现在其中任意一把即可，不能只取第一个）
    if (( ! DRY_RUN )); then
        KEYRING_OUTPUT=$(gpg --dry-run --quiet --no-keyring --import --import-options import-show "$KEYRING")
        if echo "$KEYRING_OUTPUT" | tr -d ' \n' | grep -qF "$EXPECTED_FPR"; then
            success "密钥指纹校验通过（匹配官方 signing-key@nginx.com: ${EXPECTED_FPR}）"
        else
            error "keyring 中未找到官方指纹 ${EXPECTED_FPR}，请勿继续，手动核实！"
            echo "$KEYRING_OUTPUT"
            exit 1
        fi
    fi

    # 备份旧的仓库配置（如果有）
    if [[ -f "$REPO_LIST" ]]; then
        cp "$REPO_LIST" "${BACKUP_DIR}/nginx.list.bak-$(date +%Y%m%d_%H%M%S)"
    fi

    BRANCH_PATH="${DISTRO_ID}"
    [[ "$BRANCH" == "mainline" ]] && BRANCH_PATH="mainline/${DISTRO_ID}"

    run "echo 'deb [signed-by=${KEYRING}] https://nginx.org/packages/${BRANCH_PATH} ${CODENAME} nginx' | tee '$REPO_LIST'"

    # 仓库优先级：确保 apt 用官方包而不是系统自带的旧包
    run "printf 'Package: *\\nPin: origin nginx.org\\nPin: release o=nginx\\nPin-Priority: 900\\n' | tee /etc/apt/preferences.d/99nginx"
fi

run "apt update"
run "apt install -y nginx"

if (( DRY_RUN )); then
    success "dry-run 完成，未对系统做任何实际修改"
    exit 0
fi

NEW_VERSION="$(nginx -v 2>&1 | grep -oP '(?<=nginx/)[0-9.]+' || echo '未知')"
success "安装完成: ${OLD_VERSION} → ${NEW_VERSION}"

# ── 关键：官方 nginx.org 包不带 sites-available/sites-enabled 这套约定，
# 只有 conf.d/。而 nginx-gateway.sh / nginx-web-security.sh 都硬编码依赖
# sites-available/sites-enabled，需要单独校验：
#   1) 目录是否存在（首次安装场景）
#   2) nginx.conf 里 include 那行是否存在 —— 即使目录已存在（升级场景），
#      dpkg 处理 conffile 时也可能把 nginx.conf 直接换成官方包的默认模板
#      （如果本地文件跟旧包默认模板完全一致，dpkg 判断“无本地修改”会静默覆盖），
#      导致目录还在但 include 行被冲掉，只检查目录存在与否会漏掉这种情况。
NEED_FIX=0
[[ -d /etc/nginx/sites-available ]] || NEED_FIX=1
grep -qE 'include[[:space:]]+/etc/nginx/sites-enabled/\*' /etc/nginx/nginx.conf 2>/dev/null || NEED_FIX=1

if (( NEED_FIX )); then
    info "检测到 sites-available/sites-enabled 缺失或 nginx.conf 未 include，正在补齐..."

    ts=$(date +%Y%m%d_%H%M%S)
    cp /etc/nginx/nginx.conf "${BACKUP_DIR}/nginx.conf.bak-${ts}"
    chmod 600 "${BACKUP_DIR}/nginx.conf.bak-${ts}"
    info "已备份 nginx.conf -> ${BACKUP_DIR}/nginx.conf.bak-${ts}"

    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

    if ! grep -qE 'include[[:space:]]+/etc/nginx/sites-enabled/\*' /etc/nginx/nginx.conf; then
        if grep -qE 'include\s+/etc/nginx/conf\.d/\*\.conf;' /etc/nginx/nginx.conf; then
            sed -i '/include\s*\/etc\/nginx\/conf\.d\/\*\.conf;/a\    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
        else
            # 找不到 conf.d include，退而求其次，插到 http {} 块开头
            sed -i '/^http\s*{/a\    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
        fi
    fi

    if nginx -t 2>&1; then
        success "已补齐 sites-available/sites-enabled 结构，nginx -t 通过"
    else
        error "补齐后 nginx -t 失败，正在回滚 nginx.conf"
        cp "${BACKUP_DIR}/nginx.conf.bak-${ts}" /etc/nginx/nginx.conf
        die "已回滚，请手动检查 /etc/nginx/nginx.conf 后重新运行本脚本"
    fi
else
    info "sites-available/sites-enabled 及 nginx.conf include 均已就绪，无需处理"
    nginx -t || warn "现有配置 nginx -t 未通过，请在重启 nginx 前手动排查，不要贸然重启"
fi

echo ""
success "全部完成：${OLD_VERSION} → ${NEW_VERSION}（${BRANCH} 分支）"
warn "换了二进制，reload 不生效，需要 restart 才能真正切换到新版本（会有极短暂中断）"
if confirm "现在执行 systemctl restart nginx 吗？"; then
    if systemctl restart nginx && systemctl is-active --quiet nginx; then
        success "nginx 已重启并正常运行"
    else
        error "nginx 重启后未能正常运行，请立即执行: systemctl status nginx -l 和 journalctl -xeu nginx 排查"
        exit 1
    fi
else
    info "请自行选择低峰期执行: systemctl restart nginx"
fi
