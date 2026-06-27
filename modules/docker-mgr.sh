#!/usr/bin/env bash
# docker-mgr.sh — Docker 安装 / 更新 / 容器管理脚本
# 用法: bash docker-mgr.sh

set -uo pipefail

# ─── 颜色 ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[0;33m'
CYN='\033[0;36m'; BLD='\033[1m';    RST='\033[0m'

# ─── 工具函数 ─────────────────────────────────────────────────────────────────
info()  { echo -e "${CYN}[INFO]${RST}  $*"; }
ok()    { echo -e "${GRN}[OK]${RST}    $*"; }
warn()  { echo -e "${YLW}[WARN]${RST}  $*"; }
die()   { echo -e "${RED}[ERR]${RST}   $*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "请以 root 或 sudo 运行"; }
pause() { read -rp $'\n按 Enter 返回...' _; }

hr() { echo -e "${BLD}────────────────────────────────────────────────────${RST}"; }

# ─── Docker 安装 ──────────────────────────────────────────────────────────────
install_docker() {
    need_root
    if command -v docker &>/dev/null; then
        warn "Docker 已安装: $(docker --version)"
        pause
        return
    fi

    info "检测发行版..."
    local os
    os=$(. /etc/os-release && echo "$ID")
    info "发行版: $os"

    case "$os" in
        ubuntu|debian)
            apt-get update -qq
            apt-get install -y -qq ca-certificates curl
            install -m 0755 -d /etc/apt/keyrings
            # 使用现代 Docker 官方推荐的 asc 格式，避免 gpg 覆盖确认的问题
            curl -fsSL "https://download.docker.com/linux/${os}/gpg" -o /etc/apt/keyrings/docker.asc
            chmod a+r /etc/apt/keyrings/docker.asc
            
            # 引入 VERSION_CODENAME 替代 lsb_release，减少依赖
            . /etc/os-release
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${os} ${VERSION_CODENAME} stable" \
                > /etc/apt/sources.list.d/docker.list
            
            apt-get update -qq
            apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        centos|rhel|fedora|rocky|almalinux)
            dnf -y install dnf-plugins-core
            dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        *)
            info "未匹配到原生包管理器，尝试通用脚本安装..."
            curl -fsSL https://get.docker.com | sh
            ;;
    esac

    systemctl enable --now docker
    ok "Docker 安装完成: $(docker --version)"

    # 加当前用户到 docker 组
    if [[ -n "${SUDO_USER:-}" ]]; then
        usermod -aG docker "$SUDO_USER"
        ok "已将 $SUDO_USER 加入 docker 组 (重新登录后生效)"
    fi
    pause
}

# ─── Docker 更新 ──────────────────────────────────────────────────────────────
update_docker() {
    need_root
    info "当前版本: $(docker --version 2>/dev/null || echo '未安装')"
    local os
    os=$(. /etc/os-release && echo "$ID")
    case "$os" in
        ubuntu|debian)
            apt-get update -qq
            apt-get install -y --only-upgrade docker-ce docker-ce-cli containerd.io \
                docker-buildx-plugin docker-compose-plugin
            ;;
        centos|rhel|fedora|rocky|almalinux)
            dnf -y upgrade docker-ce docker-ce-cli containerd.io \
                docker-buildx-plugin docker-compose-plugin
            ;;
        *) warn "不支持自动更新，请手动更新或重新安装"; pause; return ;;
    esac
    systemctl restart docker
    ok "更新完成: $(docker --version)"
    pause
}

# ─── 容器列表 ─────────────────────────────────────────────────────────────────
list_containers() {
    hr
    echo -e "${BLD}所有容器${RST}"
    hr
    docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
    pause
}

# ─── 选择容器 ─────────────────────────────────────────────────────────────────
pick_container() {
    local prompt="${1:-选择容器}"
    local -a names
    mapfile -t names < <(docker ps -a --format '{{.Names}}')
    [[ ${#names[@]} -eq 0 ]] && { warn "没有容器"; return 1; }

    echo ""
    local i=1
    for n in "${names[@]}"; do
        local st
        st=$(docker inspect --format '{{.State.Status}}' "$n" 2>/dev/null || echo "未知")
        printf "  %2d) %-30s %s\n" "$i" "$n" "$st"
        (( i++ ))
    done
    echo ""
    read -rp "$prompt [1-${#names[@]}]: " idx
    [[ "$idx" =~ ^[0-9]+$ && "$idx" -ge 1 && "$idx" -le "${#names[@]}" ]] || { warn "无效选择"; return 1; }
    CNAME="${names[$((idx-1))]}"
    # shellcheck disable=SC2034
    CID=$(docker inspect --format '{{.Id}}' "$CNAME")
}

# ─── 容器操作 ─────────────────────────────────────────────────────────────────
container_ops() {
    pick_container "选择要操作的容器" || { pause; return; }
    local st
    st=$(docker inspect --format '{{.State.Status}}' "$CNAME" 2>/dev/null || echo "已删除")

    while true; do
        echo ""
        hr
        echo -e "${BLD}容器: ${CYN}${CNAME}${RST}  状态: ${YLW}${st}${RST}"
        hr
        echo "  1) 启动        2) 停止        3) 重启"
        echo "  4) 删除        5) 进入 Shell  6) 查看日志"
        echo "  7) 详细信息    8) 暂停/恢复   0) 返回"
        echo ""
        read -rp "操作: " op
        case "$op" in
            1) docker start  "$CNAME" && ok "已启动" || warn "启动失败" ;;
            2) docker stop   "$CNAME" && ok "已停止" || warn "停止失败" ;;
            3) docker restart "$CNAME" && ok "已重启" || warn "重启失败" ;;
            4) read -rp "确认删除 $CNAME? [y/N]: " yn
               [[ "$yn" =~ ^[Yy]$ ]] && docker rm -f "$CNAME" && ok "已删除" && pause && return ;;
            5) local shell_found=0
               for s in bash sh ash; do
                   if docker exec -it "$CNAME" "$s" 2>/dev/null; then
                       shell_found=1
                       break
                   fi
               done
               [[ $shell_found -eq 0 ]] && warn "无法进入容器，未找到 bash, sh 或 ash (可能是精简镜像或容器未启动)" 
               ;;
            6) read -rp "行数 [默认100]: " lines; lines=${lines:-100}
               docker logs --tail "$lines" -f "$CNAME" || true ;;
            7) docker inspect "$CNAME" | less ;;
            8) if [[ "$st" == "paused" ]]; then
                   docker unpause "$CNAME" && ok "已恢复" || warn "恢复失败"
               else
                   docker pause   "$CNAME" && ok "已暂停" || warn "暂停失败"
               fi ;;
            0) return ;;
            *) warn "无效输入" ;;
        esac
        # 操作后刷新状态
        st=$(docker inspect --format '{{.State.Status}}' "$CNAME" 2>/dev/null || echo "已删除")
    done
}

# ─── 镜像管理 ─────────────────────────────────────────────────────────────────
image_mgr() {
    while true; do
        hr
        echo -e "${BLD}镜像管理${RST}"
        hr
        echo "  1) 列出镜像    2) 拉取镜像    3) 删除镜像"
        echo "  4) 清理悬空镜像              0) 返回"
        echo ""
        read -rp "操作: " op
        case "$op" in
            1) docker images; pause ;;
            2) read -rp "镜像名[:tag]: " img
               [[ -z "$img" ]] && continue
               docker pull "$img" && ok "拉取完成" || warn "拉取失败"
               pause ;;
            3) docker images --format "table {{.ID}}\t{{.Repository}}:{{.Tag}}\t{{.Size}}"
               echo ""
               read -rp "镜像 ID 或名称: " img
               [[ -z "$img" ]] && continue
               docker rmi "$img" && ok "已删除" || warn "删除失败，可能正被容器使用"
               pause ;;
            4) docker image prune -f && ok "清理完成"; pause ;;
            0) return ;;
            *) warn "无效输入" ;;
        esac
    done
}

# ─── 系统信息 ─────────────────────────────────────────────────────────────────
sys_info() {
    hr
    echo -e "${BLD}Docker 系统信息${RST}"
    hr
    docker version 2>/dev/null || warn "Docker 未运行"
    echo ""
    docker system df 2>/dev/null || true
    pause
}

# ─── 系统清理 ─────────────────────────────────────────────────────────────────
sys_prune() {
    echo ""
    warn "将清理: 已停止容器、悬空镜像、未使用网络、未使用 volume"
    read -rp "确认? [y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] || return
    docker system prune -f --volumes && ok "清理完成" || warn "清理时发生错误"
    pause
}

# ─── 主菜单 ───────────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        clear
        hr
        echo -e "  ${BLD}🐳  Docker 管理脚本${RST}"
        hr
        echo "  1) 安装 Docker"
        echo "  2) 更新 Docker"
        echo "  3) 容器列表"
        echo "  4) 容器操作 (启/停/删/日志/Shell)"
        echo "  5) 镜像管理"
        echo "  6) 系统信息"
        echo "  7) 系统清理 (prune)"
        echo "  0) 退出"
        hr
        read -rp "选择: " opt
        case "$opt" in
            1) install_docker ;;
            2) update_docker  ;;
            3) list_containers ;;
            4) container_ops  ;;
            5) image_mgr      ;;
            6) sys_info       ;;
            7) sys_prune      ;;
            0) echo "Bye."; exit 0 ;;
            *) warn "无效输入"; sleep 1 ;;
        esac
    done
}

# ─── 入口 ─────────────────────────────────────────────────────────────────────
main_menu
