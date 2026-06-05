#!/bin/bash
# ============================================================
#  Docker + Docker Compose 安装 & 热门应用一键部署脚本
#  支持：WordPress / Nextcloud / Gitea / Uptime Kuma /
#        Portainer / phpMyAdmin / Redis Commander / MinIO /
#        Lsky Pro / EasyImage / AList
#  支持多实例：通过 --deploy APP --instance NAME 或交互菜单指定
#  用法：sudo bash setup-docker-apps.sh [选项]
# ------------------------------------------------------------
#  修复记录：
#  [1] set -euo pipefail：补加 -e，命令失败立即退出
#  [2] net_name()：修复原函数两行输出 bug，统一各 deploy 调用
#  [3] find_free_port：改用 find 替代 glob，避免 nullglob 问题
#  [4] Portainer HTTPS 端口：改用 find_free_port 动态分配
#  [5] Gitea SSH 端口：改用 find_free_port，避免多实例冲突
#  [6] backup_app：停止失败时显式警告，不再静默吞掉错误
#  [7] print_summary：从 .env 读取实际端口，不再硬用默认值
#  [8] check_system：改为检测 apt-get，兼容所有 apt 系发行版
#  [9] randpw：改用 dd 替代 head -c，避免 SIGPIPE 触发 pipefail
# ============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()    { echo -e "${GREEN}[✔]${NC} $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }
error()  { echo -e "${RED}[✘]${NC} $*"; exit 1; }
info()   { echo -e "${BLUE}[i]${NC} $*"; }
header() { echo -e "\n${CYAN}${BOLD}━━━ $* ━━━${NC}\n"; }

BASE_DIR="/opt/docker-apps"
mkdir -p "$BASE_DIR"

[[ $EUID -ne 0 ]] && error "请使用 root 或 sudo 运行此脚本"

ALL_APPS=(
    wordpress
    nextcloud
    gitea
    uptime-kuma
    portainer
    phpmyadmin
    redis-commander
    minio
    lskypro
    easyimage
    alist
)

declare -A APP_DESC=(
    [wordpress]="WordPress          博客/CMS（含 MariaDB + Redis）"
    [nextcloud]="Nextcloud          私有网盘（含 MariaDB + Redis）"
    [gitea]="Gitea              Git 代码托管（含 PostgreSQL）"
    [uptime-kuma]="Uptime Kuma        服务监控面板"
    [portainer]="Portainer CE       Docker 可视化管理"
    [phpmyadmin]="phpMyAdmin         MySQL/MariaDB Web 管理"
    [redis-commander]="Redis Commander    Redis GUI"
    [minio]="MinIO              S3 兼容对象存储"
    [lskypro]="Lsky Pro           兰空图床（含 MariaDB）"
    [easyimage]="EasyImage          轻量图床"
    [alist]="AList              多存储文件列表/网盘挂载"
)

# 默认端口（用于首个实例或单实例）
declare -A APP_DEFAULT_PORT=(
    [wordpress]=8080
    [nextcloud]=8081
    [gitea]=3000
    [uptime-kuma]=3001
    [portainer]=9000
    [phpmyadmin]=8082
    [redis-commander]=8083
    [minio]=9001
    [lskypro]=8085
    [easyimage]=8086
    [alist]=5244
)

# ── 根据实例目录名推算访问地址（读取 .env 中的 PORT） ────────
get_instance_url() {
    local inst_dir="$1" app="$2"
    local port=""
    [[ -f "$inst_dir/.env" ]] && port=$(grep -oP '(?<=HOST_PORT=)\d+' "$inst_dir/.env" | head -1)
    [[ -z "$port" ]] && port="${APP_DEFAULT_PORT[$app]:-0}"
    case "$app" in
        minio)         echo "http://127.0.0.1:${port} (控制台)" ;;
        portainer)     echo "http://127.0.0.1:${port}" ;;
        gitea)         echo "http://127.0.0.1:${port}" ;;
        *)             echo "http://127.0.0.1:${port}" ;;
    esac
}

# ── 列出某应用的全部实例目录 ─────────────────────────────────
list_instances() {
    local app="$1"
    # 主实例
    [[ -f "$BASE_DIR/$app/docker-compose.yml" ]] && echo "$BASE_DIR/$app"
    # 多实例（命名实例）
    for d in "$BASE_DIR/${app}__"*/; do
        [[ -f "${d}docker-compose.yml" ]] && echo "${d%/}"
    done
}

# ── 将实例目录名转为可读标签 ─────────────────────────────────
inst_label() {
    local dir="$1" app="$2"
    local name
    name=$(basename "$dir")
    if [[ "$name" == "$app" ]]; then
        echo "默认实例"
    else
        echo "${name#${app}__}"
    fi
}

# ============================================================
# 交互式主菜单
# ============================================================
interactive_menu() {
    while true; do
        echo ""
        echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗"
        echo -e "║          🐳  Docker 应用部署管理工具                        ║"
        echo -e "╠══════════════════════════════════════════════════════════════╣"
        echo -e "║  1) 安装 / 更新 Docker                                       ║"
        echo -e "║  2) 选择应用部署（多选）                                     ║"
        echo -e "║  3) 部署全部应用                                              ║"
        echo -e "║  4) 卸载应用                                                  ║"
        echo -e "║  5) 备份应用                                                  ║"
        echo -e "║  6) 查看已部署应用状态                                        ║"
        echo -e "║  7) 更新应用镜像                                              ║"
        echo -e "║  8) 更新应用组件（PHP/DB/Redis 等）                          ║"
        echo -e "║  9) 部署额外实例（同一应用多开）                             ║"
        echo -e "║  0) 退出                                                      ║"
        echo -e "╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        read -rp "请选择操作 [0-9]: " choice

        case "$choice" in
            1) check_system; install_docker ;;
            2) ensure_docker; menu_select_apps ;;
            3) check_system; ensure_docker; deploy_all_apps ;;
            4) menu_uninstall_app ;;
            5) menu_backup_app ;;
            6) list_apps ;;
            7) menu_update_images ;;
            8) menu_update_components ;;
            9) ensure_docker; menu_deploy_extra_instance ;;
            0) echo "再见！"; exit 0 ;;
            *) warn "无效选项，请输入 0-9" ;;
        esac
    done
}

ensure_docker() {
    if ! command -v docker &>/dev/null; then
        warn "未检测到 Docker，自动执行安装..."
        check_system
        install_docker
    fi
}

# ── 辅助：安全遍历可能为空的数组 ────────────────────────────
# 用法：safe_array_for <arrayname_ref> callback
# 直接用 "${arr[@]:+${arr[@]}}" 展开即可，此处定义为宏注释
# 正确写法：[[ ${#arr[@]} -gt 0 ]] && for x in "${arr[@]}"; do ...

menu_select_apps() {
    local -a selected=()
    while true; do
        echo ""
        echo -e "${CYAN}${BOLD}── 选择要部署的应用（输入编号切换选中，支持多选）──${NC}"
        echo ""
        local i=1
        for app in "${ALL_APPS[@]}"; do
            local mark=" "
            # FIX: 用长度判断，避免空数组 "${arr[@]:-}" 展开为空字符串的陷阱
            if [[ ${#selected[@]} -gt 0 ]]; then
                for s in "${selected[@]}"; do
                    [[ "$s" == "$app" ]] && mark="${GREEN}✔${NC}" && break
                done
            fi
            printf "  %2d) [%b] %s\n" "$i" "$mark" "${APP_DESC[$app]}"
            ((i++))
        done
        echo ""
        echo -e "   a) 全选    c) 清空选择    d) 开始部署    q) 返回"
        echo ""
        read -rp "请输入编号或操作: " input

        case "$input" in
            [0-9]|[0-9][0-9])
                local idx=$((input - 1))
                if [[ $idx -ge 0 && $idx -lt ${#ALL_APPS[@]} ]]; then
                    local app="${ALL_APPS[$idx]}"
                    local found=0
                    local -a new_selected=()
                    # FIX: 用长度判断，避免空数组展开为空字符串后写入 new_selected
                    if [[ ${#selected[@]} -gt 0 ]]; then
                        for s in "${selected[@]}"; do
                            if [[ "$s" == "$app" ]]; then
                                found=1
                            else
                                new_selected+=("$s")
                            fi
                        done
                    fi
                    if [[ $found -eq 0 ]]; then
                        selected+=("$app")
                        info "已选中: $app"
                    else
                        # FIX: 同样用长度判断再赋值，避免 new_selected 为空时 [@]:-  产生空元素
                        if [[ ${#new_selected[@]} -gt 0 ]]; then
                            selected=("${new_selected[@]}")
                        else
                            selected=()
                        fi
                        info "已取消: $app"
                    fi
                else
                    warn "编号超出范围"
                fi
                ;;
            a) selected=("${ALL_APPS[@]}"); info "已全选 ${#ALL_APPS[@]} 个应用" ;;
            c) selected=(); info "已清空选择" ;;
            d)
                # FIX: 直接用 ${#selected[@]} 而非 ${#selected[@]:-0}（后者语法无效）
                if [[ ${#selected[@]} -eq 0 ]]; then
                    warn "请至少选择一个应用"
                else
                    echo ""
                    echo -e "${CYAN}即将部署以下应用:${NC}"
                    for app in "${selected[@]}"; do echo "  - ${APP_DESC[$app]}"; done
                    echo ""
                    read -rp "确认部署？[y/N]: " confirm
                    if [[ "${confirm,,}" == "y" ]]; then
                        for app in "${selected[@]}"; do
                            "deploy_${app//-/_}" "$BASE_DIR/$app" \
                                || warn "$app 部署失败，继续下一个..."
                        done
                        print_summary "${selected[@]}"
                    fi
                    return
                fi
                ;;
            q) return ;;
            *) warn "无效输入" ;;
        esac
    done
}

# ============================================================
# 部署额外实例（多实例菜单）
# ============================================================
menu_deploy_extra_instance() {
    echo ""
    echo -e "${CYAN}${BOLD}── 部署额外实例（同一应用多开）──${NC}"
    echo ""
    echo -e "  说明: 为已有应用新增一个命名实例，数据目录与端口相互独立。"
    echo -e "        实例目录: /opt/docker-apps/<app>__<name>"
    echo ""
    local i=1
    for app in "${ALL_APPS[@]}"; do
        printf "  %2d) %s\n" "$i" "${APP_DESC[$app]}"
        ((i++))
    done
    echo ""
    read -rp "请输入应用编号（0 返回）: " idx_input
    [[ "$idx_input" == "0" ]] && return
    local idx=$((idx_input - 1))
    if [[ $idx -lt 0 || $idx -ge ${#ALL_APPS[@]} ]]; then
        warn "编号无效"; return
    fi
    local app="${ALL_APPS[$idx]}"

    echo ""
    echo -e "  现有实例:"
    local inst_list
    mapfile -t inst_list < <(list_instances "$app")
    if [[ ${#inst_list[@]} -gt 0 ]]; then
        for d in "${inst_list[@]}"; do
            local lbl port=""
            lbl=$(inst_label "$d" "$app")
            [[ -f "$d/.env" ]] && port=$(grep -oP '(?<=HOST_PORT=)\d+' "$d/.env" | head -1)
            echo "    - $lbl  (目录: $d, 端口: ${port:-默认})"
        done
    else
        echo "    （尚无实例）"
    fi

    echo ""
    read -rp "  输入新实例名称（字母数字和-，如 site2）: " inst_name
    inst_name="${inst_name// /_}"
    if [[ -z "$inst_name" || ! "$inst_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        warn "实例名称无效，只允许字母、数字、- 和 _"; return
    fi

    local inst_dir="$BASE_DIR/${app}__${inst_name}"
    if [[ -d "$inst_dir" ]]; then
        warn "实例 $inst_name 已存在（$inst_dir）"; return
    fi

    # 自动找一个未被占用的端口
    local base_port="${APP_DEFAULT_PORT[$app]}"
    local host_port
    host_port=$(find_free_port "$base_port")
    echo ""
    echo -e "  建议端口: ${CYAN}${host_port}${NC}"
    read -rp "  确认端口（直接回车接受，或输入自定义端口）: " custom_port
    [[ -n "$custom_port" ]] && host_port="$custom_port"

    echo ""
    read -rp "确认创建实例 ${app}__${inst_name}（端口 ${host_port}）？[y/N]: " confirm
    [[ "${confirm,,}" != "y" ]] && { info "已取消"; return; }

    "deploy_${app//-/_}" "$inst_dir" "$host_port" \
        && log "实例 ${app}__${inst_name} 已部署 → http://127.0.0.1:${host_port}" \
        || warn "实例部署失败"
}

# ── 找一个未被 /opt/docker-apps 中任何 .env 使用的空闲端口 ──
find_free_port() {
    local base="$1"
    local port=$base
    while true; do
        # 检查是否被任何已部署实例的 .env 占用
        local in_use=0
        while IFS= read -r env_file; do
            grep -qP "HOST_PORT=${port}$" "$env_file" && in_use=1 && break
        done < <(find "$BASE_DIR" -name ".env" -maxdepth 3 2>/dev/null)
        # 也检查系统端口占用
        if [[ $in_use -eq 0 ]] && ! ss -tlnH "sport = :${port}" 2>/dev/null | grep -q .; then
            echo "$port"; return
        fi
        ((port++))
    done
}

menu_uninstall_app() {
    echo ""
    echo -e "${CYAN}${BOLD}── 选择要卸载的实例 ──${NC}"
    local -a deployed_dirs=()
    local -a deployed_labels=()
    for app in "${ALL_APPS[@]}"; do
        while IFS= read -r dir; do
            deployed_dirs+=("$dir")
            deployed_labels+=("$app  [$(inst_label "$dir" "$app")]")
        done < <(list_instances "$app")
    done
    if [[ ${#deployed_dirs[@]} -eq 0 ]]; then warn "没有已部署的应用"; return; fi
    local i=1
    for lbl in "${deployed_labels[@]}"; do printf "  %2d) %s\n" "$i" "$lbl"; ((i++)); done
    echo ""
    read -rp "请输入要卸载的编号（0 返回）: " input
    [[ "$input" == "0" ]] && return
    local idx=$((input - 1))
    if [[ $idx -ge 0 && $idx -lt ${#deployed_dirs[@]} ]]; then
        local dir="${deployed_dirs[$idx]}"
        read -rp "确认卸载 $(basename "$dir") 并删除所有数据？[y/N]: " confirm
        [[ "${confirm,,}" == "y" ]] && uninstall_app "$dir" || info "已取消"
    else
        warn "编号无效"
    fi
}

menu_backup_app() {
    echo ""
    echo -e "${CYAN}${BOLD}── 选择要备份的实例 ──${NC}"
    local -a deployed_dirs=()
    local -a deployed_labels=()
    for app in "${ALL_APPS[@]}"; do
        while IFS= read -r dir; do
            deployed_dirs+=("$dir")
            deployed_labels+=("$app  [$(inst_label "$dir" "$app")]")
        done < <(list_instances "$app")
    done
    if [[ ${#deployed_dirs[@]} -eq 0 ]]; then warn "没有已部署的应用"; return; fi
    local i=1
    for lbl in "${deployed_labels[@]}"; do printf "  %2d) %s\n" "$i" "$lbl"; ((i++)); done
    echo ""
    read -rp "请输入要备份的编号（0 返回）: " input
    [[ "$input" == "0" ]] && return
    local idx=$((input - 1))
    if [[ $idx -ge 0 && $idx -lt ${#deployed_dirs[@]} ]]; then
        backup_app "${deployed_dirs[$idx]}"
    else
        warn "编号无效"
    fi
}

# ============================================================
# 更新镜像菜单
# ============================================================
menu_update_images() {
    echo ""
    echo -e "${CYAN}${BOLD}── 更新应用镜像 ──${NC}"
    echo ""
    echo -e "  1) 更新指定实例镜像"
    echo -e "  2) 更新全部已部署实例镜像"
    echo -e "  0) 返回"
    echo ""
    read -rp "请选择 [0-2]: " choice

    case "$choice" in
        1)
            local -a deployed_dirs=()
            local -a deployed_labels=()
            for app in "${ALL_APPS[@]}"; do
                while IFS= read -r dir; do
                    deployed_dirs+=("$dir")
                    deployed_labels+=("$app  [$(inst_label "$dir" "$app")]")
                done < <(list_instances "$app")
            done
            if [[ ${#deployed_dirs[@]} -eq 0 ]]; then warn "没有已部署的应用"; return; fi
            local i=1
            for lbl in "${deployed_labels[@]}"; do printf "  %2d) %s\n" "$i" "$lbl"; ((i++)); done
            echo ""
            read -rp "请输入要更新的编号（0 返回）: " input
            [[ "$input" == "0" ]] && return
            local idx=$((input - 1))
            if [[ $idx -ge 0 && $idx -lt ${#deployed_dirs[@]} ]]; then
                update_app_images "${deployed_dirs[$idx]}"
            else
                warn "编号无效"
            fi
            ;;
        2)
            local updated=0
            for app in "${ALL_APPS[@]}"; do
                while IFS= read -r dir; do
                    update_app_images "$dir"
                    ((updated++))
                done < <(list_instances "$app")
            done
            [[ $updated -eq 0 ]] && warn "没有已部署的应用"
            ;;
        0) return ;;
        *) warn "无效输入" ;;
    esac
}

# ── 更新单个实例的所有镜像并重启 ────────────────────────────
update_app_images() {
    local dir="$1"
    [[ ! -f "$dir/docker-compose.yml" ]] && warn "$dir 未部署，跳过" && return

    header "更新 $(basename "$dir") 镜像"
    info "拉取最新镜像..."
    cd "$dir"
    if docker compose pull; then
        info "镜像拉取完成，重启服务..."
        if docker compose up -d --remove-orphans; then
            log "$(basename "$dir") 已使用最新镜像重启"
        else
            warn "$(basename "$dir") 重启失败，请手动检查"
        fi
    else
        warn "$(basename "$dir") 镜像拉取失败，保持当前版本运行"
    fi
    cd - > /dev/null

    local dangling
    dangling=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l)
    if [[ "$dangling" -gt 0 ]]; then
        info "清理 $dangling 个悬空旧镜像..."
        docker image prune -f > /dev/null
    fi
}

# ============================================================
# 更新组件菜单
# ============================================================
menu_update_components() {
    echo ""
    echo -e "${CYAN}${BOLD}── 更新应用组件（PHP / MariaDB / PostgreSQL / Redis / Nginx）──${NC}"
    echo ""
    echo -e "  说明: 修改 docker-compose.yml 中的镜像标签后自动拉取并重启。"
    echo -e "        PostgreSQL 大版本升级需手动迁移数据，脚本会提示确认。"
    echo ""
    echo -e "  1) 升级 WordPress PHP（php8.3 → php8.4-fpm-alpine）"
    echo -e "  2) 升级 Nextcloud（production → stable-fpm-alpine）"
    echo -e "  3) 统一所有 MariaDB → mariadb:11"
    echo -e "  4) 升级所有 PostgreSQL → postgres:17-alpine（需手动迁移）"
    echo -e "  5) 统一所有 Redis → redis:7-alpine"
    echo -e "  6) 统一所有 Nginx → nginx:alpine"
    echo -e "  7) 批量执行以上全部"
    echo -e "  0) 返回"
    echo ""
    read -rp "请选择 [0-7]: " choice

    case "$choice" in
        1) update_component_php_wordpress ;;
        2) update_component_nextcloud ;;
        3) update_component_mariadb ;;
        4) update_component_postgres ;;
        5) update_component_redis ;;
        6) update_component_nginx ;;
        7)
            update_component_php_wordpress
            update_component_nextcloud
            update_component_mariadb
            update_component_postgres
            update_component_redis
            update_component_nginx
            log "全部组件更新操作完成"
            ;;
        0) return ;;
        *) warn "无效输入" ;;
    esac
}

# ── 通用：在某目录的 compose 文件中替换镜像标签并重启 ───────
_replace_image_and_restart() {
    local dir="$1" old_tag="$2" new_tag="$3"
    local services=("${@:4}")   # 可选：只重启指定 service
    sed -i "s|${old_tag}|${new_tag}|g" "$dir/docker-compose.yml"
    cd "$dir"
    if [[ ${#services[@]} -gt 0 ]]; then
        # 只拉取 & 重启指定服务，忽略不存在的服务名
        docker compose pull "${services[@]}" 2>/dev/null || true
        docker compose up -d "${services[@]}" 2>/dev/null || warn "$(basename "$dir") 部分服务重启失败"
    else
        docker compose pull 2>/dev/null || true
        docker compose up -d --remove-orphans 2>/dev/null || warn "$(basename "$dir") 重启失败"
    fi
    cd - > /dev/null
}

update_component_php_wordpress() {
    local new_tag="wordpress:php8.4-fpm-alpine"
    header "升级 WordPress PHP 版本 → php8.4-fpm-alpine"
    local updated=0
    # 遍历所有 wordpress 实例（含多实例）
    while IFS= read -r dir; do
        local current
        current=$(grep -oP 'wordpress:php[\d.]+-fpm-alpine' "$dir/docker-compose.yml" | head -1)
        [[ -z "$current" ]] && continue
        if [[ "$current" == "$new_tag" ]]; then
            info "[$(basename "$dir")] 已是 $new_tag，跳过"; continue
        fi
        info "[$(basename "$dir")] $current → $new_tag"
        read -rp "  确认升级？[y/N]: " confirm
        [[ "${confirm,,}" != "y" ]] && { info "已取消"; continue; }
        _replace_image_and_restart "$dir" "$current" "$new_tag" "wordpress"
        log "[$(basename "$dir")] PHP 已升级到 php8.4-fpm-alpine"
        ((updated++))
    done < <(list_instances "wordpress")
    [[ $updated -eq 0 ]] && info "无 WordPress 实例需要更新"
}

update_component_nextcloud() {
    local new_tag="nextcloud:stable-fpm-alpine"
    header "升级 Nextcloud 镜像标签 → stable-fpm-alpine"
    local updated=0
    while IFS= read -r dir; do
        local current
        current=$(grep -oP 'nextcloud:[a-z0-9.\-]+-fpm-alpine' "$dir/docker-compose.yml" | head -1)
        [[ -z "$current" ]] && continue
        if [[ "$current" == "$new_tag" ]]; then
            info "[$(basename "$dir")] 已是 $new_tag，跳过"; continue
        fi
        info "[$(basename "$dir")] $current → $new_tag"
        warn "版本跨越升级前请先备份数据"
        read -rp "  确认升级？[y/N]: " confirm
        [[ "${confirm,,}" != "y" ]] && { info "已取消"; continue; }
        _replace_image_and_restart "$dir" "$current" "$new_tag" "nextcloud" "cron"
        log "[$(basename "$dir")] 已更新为 $new_tag"
        ((updated++))
    done < <(list_instances "nextcloud")
    [[ $updated -eq 0 ]] && info "无 Nextcloud 实例需要更新"
}

update_component_mariadb() {
    header "统一 MariaDB → mariadb:11"
    local updated=0
    for app in "${ALL_APPS[@]}"; do
        while IFS= read -r dir; do
            [[ ! -f "$dir/docker-compose.yml" ]] && continue
            grep -q 'mariadb:' "$dir/docker-compose.yml" || continue
            local current
            current=$(grep -oP 'mariadb:[^\s"]+' "$dir/docker-compose.yml" | head -1)
            if [[ "$current" == "mariadb:11" ]]; then
                info "[$(basename "$dir")] MariaDB 已是 11，跳过"; continue
            fi
            info "[$(basename "$dir")] $current → mariadb:11"
            # FIX: 不再硬编码服务名 "db lskypro-db"，改为只拉取 compose 中实际存在的 mariadb 服务
            local db_service
            db_service=$(grep -B2 "image: ${current}" "$dir/docker-compose.yml" \
                | grep -oP '^\s+\K\S+(?=:)' | head -1)
            _replace_image_and_restart "$dir" "$current" "mariadb:11" "${db_service:-db}"
            ((updated++))
        done < <(list_instances "$app")
    done
    [[ $updated -eq 0 ]] && info "无需更新" || log "已更新 $updated 个 MariaDB 实例"
}

update_component_postgres() {
    header "升级 PostgreSQL → postgres:17-alpine"
    local updated=0
    for app in "${ALL_APPS[@]}"; do
        while IFS= read -r dir; do
            [[ ! -f "$dir/docker-compose.yml" ]] && continue
            grep -q 'postgres:' "$dir/docker-compose.yml" || continue
            local current
            current=$(grep -oP 'postgres:[^\s"]+' "$dir/docker-compose.yml" | head -1)
            if [[ "$current" == "postgres:17-alpine" ]]; then
                info "[$(basename "$dir")] PostgreSQL 已是 17-alpine，跳过"; continue
            fi
            warn "[$(basename "$dir")] PostgreSQL 大版本升级（$current → postgres:17-alpine）需手动迁移数据！"
            warn "参考: https://www.postgresql.org/docs/current/upgrading.html"
            read -rp "仍要修改 $(basename "$dir") 的镜像标签？[y/N]: " confirm
            if [[ "${confirm,,}" == "y" ]]; then
                sed -i "s|${current}|postgres:17-alpine|g" "$dir/docker-compose.yml"
                warn "[$(basename "$dir")] 标签已修改，请手动完成数据库迁移后再执行 docker compose up -d"
                ((updated++))
            fi
        done < <(list_instances "$app")
    done
    [[ $updated -eq 0 ]] && info "无需更新" || log "已修改 $updated 个 PostgreSQL 实例标签"
}

update_component_redis() {
    header "统一 Redis → redis:7-alpine"
    local updated=0
    for app in "${ALL_APPS[@]}"; do
        while IFS= read -r dir; do
            [[ ! -f "$dir/docker-compose.yml" ]] && continue
            grep -q 'redis:' "$dir/docker-compose.yml" || continue
            local current
            current=$(grep -oP 'redis:[^\s"]+' "$dir/docker-compose.yml" | head -1)
            if [[ "$current" == "redis:7-alpine" ]]; then
                info "[$(basename "$dir")] Redis 已是 7-alpine，跳过"; continue
            fi
            info "[$(basename "$dir")] $current → redis:7-alpine"
            _replace_image_and_restart "$dir" "$current" "redis:7-alpine" "redis"
            ((updated++))
        done < <(list_instances "$app")
    done
    [[ $updated -eq 0 ]] && info "无需更新" || log "已更新 $updated 个 Redis 实例"
}

update_component_nginx() {
    header "统一 Nginx → nginx:alpine"
    local updated=0
    for app in "${ALL_APPS[@]}"; do
        while IFS= read -r dir; do
            [[ ! -f "$dir/docker-compose.yml" ]] && continue
            grep -q 'nginx:' "$dir/docker-compose.yml" || continue
            local current
            current=$(grep -oP 'nginx:[^\s"]+' "$dir/docker-compose.yml" | head -1)
            if [[ "$current" == "nginx:alpine" ]]; then
                info "[$(basename "$dir")] Nginx 已是 alpine，跳过"; continue
            fi
            info "[$(basename "$dir")] $current → nginx:alpine"
            _replace_image_and_restart "$dir" "$current" "nginx:alpine" "nginx"
            ((updated++))
        done < <(list_instances "$app")
    done
    [[ $updated -eq 0 ]] && info "无需更新" || log "已更新 $updated 个 Nginx 实例"
}

deploy_all_apps() {
    echo ""
    echo -e "${YELLOW}即将部署全部 ${#ALL_APPS[@]} 个应用，这会占用大量磁盘和内存。${NC}"
    read -rp "确认继续？[y/N]: " confirm
    [[ "${confirm,,}" != "y" ]] && { info "已取消"; return; }
    for app in "${ALL_APPS[@]}"; do
        "deploy_${app//-/_}" "$BASE_DIR/$app" \
            || warn "$app 部署失败，继续下一个..."
    done
    print_summary "${ALL_APPS[@]}"
}

usage() {
    cat <<EOF
用法: $0 [选项]
选项:
  无参数                   进入交互式菜单（推荐）
  --install                仅安装 / 更新 Docker
  --deploy APP             仅部署指定应用默认实例（自动安装 Docker）
  --deploy APP --instance NAME [--port PORT]
                           部署指定应用的命名实例（用于多开）
  --uninstall DIR          卸载指定目录的实例并删除数据
  --backup DIR             备份指定目录的实例到 /tmp
  --update DIR             更新指定目录的实例镜像并重启
  --update-all             更新全部已部署实例镜像
  --list                   列出所有可管理的应用及状态
  --all                    部署全部应用（非交互，适合自动化）
  --help                   显示此帮助

可部署的应用:
  wordpress, nextcloud, gitea, uptime-kuma, portainer
  phpmyadmin, redis-commander, minio, lskypro, easyimage, alist

示例:
  sudo bash $0                                    # 进入交互菜单
  sudo bash $0 --deploy alist                     # 部署 AList 默认实例
  sudo bash $0 --deploy wordpress --instance blog2 --port 8090
                                                  # 部署第二个 WordPress
  sudo bash $0 --update /opt/docker-apps/alist    # 更新默认实例
  sudo bash $0 --update-all                       # 更新全部实例
  sudo bash $0 --list                             # 查看应用状态
EOF
    exit 0
}

list_apps() {
    echo ""
    echo -e "${CYAN}${BOLD}── 应用实例状态 ──${NC}"
    echo ""
    local found=0
    for app in "${ALL_APPS[@]}"; do
        while IFS= read -r dir; do
            found=1
            local lbl status total url
            lbl=$(inst_label "$dir" "$app")
            status=$(cd "$dir" && docker compose ps --status running --quiet 2>/dev/null | wc -l || echo "0")
            total=$(cd "$dir" && docker compose ps --quiet 2>/dev/null | wc -l || echo "0")
            url=$(get_instance_url "$dir" "$app")
            if [[ "$status" -gt 0 ]]; then
                echo -e "  ${GREEN}[运行中]${NC} $app [$lbl]  (${status}/${total} 容器)  → $url"
            else
                echo -e "  ${RED}[已停止]${NC} $app [$lbl]  ($dir)"
            fi
        done < <(list_instances "$app")
    done
    [[ $found -eq 0 ]] && warn "尚未部署任何应用"
    echo ""
}

check_system() {
    local mem disk
    mem=$(free -m | awk '/^Mem:/{print $2}')
    disk=$(df -m /opt | awk 'NR==2{print $4}')
    [[ "$mem" -lt 1024 ]] && warn "内存不足 1GB（当前 ${mem}MB），可能影响性能"
    [[ "$disk" -lt 5120 ]] && warn "磁盘空间不足 5GB（剩余 ${disk}MB），建议扩展空间"
    if ! command -v apt-get &>/dev/null; then
        error "仅支持 apt 系发行版（Debian/Ubuntu/Raspbian 等），当前系统不支持"
    fi
}

# ── run_compose: 在指定目录启动 compose 服务 ────────────────
run_compose() {
    local dir="$1" name="$2"
    cd "$dir"
    if docker compose up -d; then
        log "$name 启动成功"
    else
        cd - > /dev/null
        error "无法启动 $name，请检查 $dir 目录"
    fi
    cd - > /dev/null
}

# ============================================================
# 安装 / 更新 Docker
# ============================================================
install_docker() {
    header "安装 / 更新 Docker Engine"
    if command -v docker &>/dev/null; then
        local CURRENT
        CURRENT=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
        warn "检测到已安装 Docker（版本 $CURRENT），执行更新..."
    fi
    . /etc/os-release
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/${ID} $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    local DOCKER_VER COMPOSE_VER
    DOCKER_VER=$(docker version --format '{{.Server.Version}}')
    COMPOSE_VER=$(docker compose version --short)
    log "Docker         $DOCKER_VER"
    log "Docker Compose $COMPOSE_VER"
    if command -v ufw &>/dev/null && ufw status | grep -q inactive; then
        warn "检测到 ufw 未启用，建议执行: ufw enable && ufw allow 22/tcp"
    fi
}

randpw() {
    local len="${1:-24}"
    # 用 dd 精确读取字节数，避免 head -c 关闭管道时 tr 收到 SIGPIPE 触发 pipefail
    tr -dc 'A-Za-z0-9!@#%^&*()_+-=' </dev/urandom 2>/dev/null \
        | dd bs=1 count="$len" 2>/dev/null
    echo
}

backup_app() {
    local dir="$1"
    local app_name
    app_name=$(basename "$dir")
    local backup_file="/tmp/${app_name}_$(date +%Y%m%d_%H%M%S).tar.gz"
    [[ ! -d "$dir" ]] && error "目录 $dir 不存在"
    header "备份 $app_name"
    if ! (cd "$dir" && docker compose stop 2>/dev/null); then
        warn "$app_name 容器停止失败，备份数据可能不一致，继续..."
    fi
    tar -czf "$backup_file" -C "$(dirname "$dir")" "$(basename "$dir")"
    (cd "$dir" && docker compose start 2>/dev/null) || warn "$app_name 备份后重启失败，请手动执行: docker compose start"
    local size
    size=$(du -h "$backup_file" | cut -f1)
    log "已备份 $app_name 到 $backup_file（大小: $size）"
}

uninstall_app() {
    local dir="$1"
    local app_name
    app_name=$(basename "$dir")
    [[ ! -d "$dir" ]] && error "目录 $dir 不存在"
    header "卸载 $app_name"
    if [[ -f "$dir/docker-compose.yml" ]]; then
        (cd "$dir" && docker compose down -v --remove-orphans) || warn "容器停止失败，继续清理..."
    fi
    if [[ -f "$dir/.env" ]]; then
        local bak="/tmp/${app_name}_env_backup_$(date +%Y%m%d_%H%M%S)"
        cp "$dir/.env" "$bak" 2>/dev/null || true
        log "凭据已备份到 $bak"
    fi
    rm -rf "$dir"
    log "已卸载 $app_name 并删除所有数据"
}

# ============================================================
# ── 各应用部署函数 ──────────────────────────────────────────
# 统一签名：deploy_<app> <install_dir> [host_port]
# install_dir 默认 $BASE_DIR/<app>，多实例时传命名目录
# host_port   默认各应用的 APP_DEFAULT_PORT
# ============================================================

# ── 生成网络名（取目录 basename，去除特殊字符，固定后缀 _net）─
net_name() {
    local dir="$1"
    echo "$(basename "$dir" | tr -cd 'a-zA-Z0-9_' | tr '[:upper:]' '[:lower:]')_net"
}

# ============================================================
# WordPress（含 MariaDB + Redis）
# ============================================================
deploy_wordpress() {
    local DIR="${1:-$BASE_DIR/wordpress}"
    local HOST_PORT="${2:-${APP_DEFAULT_PORT[wordpress]}}"
    local NET
    NET=$(net_name "$DIR")

    header "部署 WordPress → $DIR (端口 $HOST_PORT)"
    mkdir -p "$DIR"/{data,db,redis,uploads}

    local DB_ROOT_PW DB_PW
    DB_ROOT_PW=$(randpw); DB_PW=$(randpw)
    cat > "$DIR/.env" <<EOF
WORDPRESS_DB_ROOT_PASSWORD=${DB_ROOT_PW}
WORDPRESS_DB_PASSWORD=${DB_PW}
WORDPRESS_DB_NAME=wordpress
WORDPRESS_DB_USER=wpuser
HOST_PORT=${HOST_PORT}
EOF

    cat > "$DIR/docker-compose.yml" <<YAML
services:
  db:
    image: mariadb:11
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: \${WORDPRESS_DB_ROOT_PASSWORD}
      MARIADB_DATABASE: \${WORDPRESS_DB_NAME}
      MARIADB_USER: \${WORDPRESS_DB_USER}
      MARIADB_PASSWORD: \${WORDPRESS_DB_PASSWORD}
    volumes:
      - ./db:/var/lib/mysql
    networks: [${NET}]
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: redis-server --save 60 1 --loglevel warning
    volumes:
      - ./redis:/data
    networks: [${NET}]

  wordpress:
    image: wordpress:php8.3-fpm-alpine
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      WORDPRESS_DB_HOST: db:3306
      WORDPRESS_DB_NAME: \${WORDPRESS_DB_NAME}
      WORDPRESS_DB_USER: \${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD: \${WORDPRESS_DB_PASSWORD}
      WORDPRESS_CONFIG_EXTRA: |
        define('WP_REDIS_HOST', 'redis');
        define('WP_REDIS_PORT', 6379);
        define('WP_CACHE', true);
        define('WP_MEMORY_LIMIT', '512M');
        define('WP_MAX_MEMORY_LIMIT', '1024M');
    volumes:
      - ./data:/var/www/html
      - ./uploads/php-uploads.ini:/usr/local/etc/php/conf.d/uploads.ini:ro
    networks: [${NET}]

  nginx:
    image: nginx:alpine
    restart: unless-stopped
    depends_on: [wordpress]
    volumes:
      - ./data:/var/www/html:ro
      - ./uploads/nginx-wp.conf:/etc/nginx/conf.d/default.conf:ro
    networks: [${NET}]
    ports:
      - "127.0.0.1:${HOST_PORT}:80"

networks:
  ${NET}:
    driver: bridge
YAML

    cat > "$DIR/uploads/php-uploads.ini" <<'INI'
upload_max_filesize = 2048M
post_max_size       = 2048M
memory_limit        = 1024M
max_execution_time  = 600
max_input_time      = 600
max_input_vars      = 10000
INI

    cat > "$DIR/uploads/nginx-wp.conf" <<'NGINX'
server {
    listen 80;
    root /var/www/html;
    index index.php index.html;
    client_max_body_size 2048M;
    location / { try_files $uri $uri/ /index.php?$args; }
    location ~ \.php$ {
        fastcgi_pass  wordpress:9000;
        fastcgi_index index.php;
        include       fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_read_timeout 600;
    }
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2)$ {
        expires max;
        log_not_found off;
    }
}
NGINX

    run_compose "$DIR" "WordPress"
    log "WordPress 已启动 → http://127.0.0.1:${HOST_PORT}"
    log "凭据已保存至 $DIR/.env"
}

# ============================================================
# Nextcloud（含 MariaDB + Redis）
# ============================================================
deploy_nextcloud() {
    local DIR="${1:-$BASE_DIR/nextcloud}"
    local HOST_PORT="${2:-${APP_DEFAULT_PORT[nextcloud]}}"
    local NET
    NET=$(net_name "$DIR")

    header "部署 Nextcloud → $DIR (端口 $HOST_PORT)"
    mkdir -p "$DIR"/{data,db,redis,config,apps}

    local DB_ROOT_PW DB_PW ADMIN_PW
    DB_ROOT_PW=$(randpw); DB_PW=$(randpw); ADMIN_PW=$(randpw 20)
    cat > "$DIR/.env" <<EOF
MYSQL_ROOT_PASSWORD=${DB_ROOT_PW}
MYSQL_PASSWORD=${DB_PW}
NEXTCLOUD_ADMIN_PASSWORD=${ADMIN_PW}
HOST_PORT=${HOST_PORT}
EOF

    cat > "$DIR/docker-compose.yml" <<YAML
services:
  db:
    image: mariadb:11
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MARIADB_DATABASE: nextcloud
      MARIADB_USER: nextcloud
      MARIADB_PASSWORD: \${MYSQL_PASSWORD}
    volumes:
      - ./db:/var/lib/mysql
    networks: [${NET}]
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    networks: [${NET}]

  nextcloud:
    image: nextcloud:production-fpm-alpine
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      MYSQL_HOST: db
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: \${MYSQL_PASSWORD}
      REDIS_HOST: redis
      NEXTCLOUD_ADMIN_USER: admin
      NEXTCLOUD_ADMIN_PASSWORD: \${NEXTCLOUD_ADMIN_PASSWORD}
      PHP_UPLOAD_LIMIT: 2048M
      PHP_MEMORY_LIMIT: 1024M
    volumes:
      - ./data:/var/www/html/data
      - ./config:/var/www/html/config
      - ./apps:/var/www/html/custom_apps
    networks: [${NET}]

  nginx:
    image: nginx:alpine
    restart: unless-stopped
    depends_on: [nextcloud]
    volumes:
      - ./data:/var/www/html/data:ro
      - ./config:/var/www/html/config:ro
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    networks: [${NET}]
    ports:
      - "127.0.0.1:${HOST_PORT}:80"

  cron:
    image: nextcloud:production-fpm-alpine
    restart: unless-stopped
    depends_on: [nextcloud]
    volumes:
      - ./data:/var/www/html/data
      - ./config:/var/www/html/config
    entrypoint: /cron.sh
    networks: [${NET}]

networks:
  ${NET}:
    driver: bridge
YAML

    cat > "$DIR/nginx.conf" <<'NGINX'
upstream php-handler { server nextcloud:9000; }
server {
    listen 80;
    root /var/www/html;
    client_max_body_size 2048M;
    add_header Strict-Transport-Security "max-age=15768000" always;
    location = /robots.txt { allow all; log_not_found off; access_log off; }
    location ^~ /.well-known { return 301 /index.php$uri; }
    location / { rewrite ^ /index.php; }
    location ~ ^\/(?:build|tests|config|lib|3rdparty|templates|data)\/ { deny all; }
    location ~ ^\/(?:\.|autotest|occ|issue|indie|db_|console) { deny all; }
    location ~ ^\/(?:index|remote|public|cron|core\/ajax\/update|status|ocs\/v[12]|updater\/.+|oc[ms]-provider\/.+)\.php(?:$|\/) {
        fastcgi_split_path_info ^(.+?\.php)(\/.*|)$;
        fastcgi_pass php-handler;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $fastcgi_path_info;
        fastcgi_read_timeout 600;
    }
    location ~ ^\/(?:updater|oc[ms]-provider)(?:$|\/) { try_files $uri/ =404; index index.php; }
    location ~* \.(?:css|js|woff2|svg|gif|map)$ { try_files $uri /index.php$request_uri; expires 6M; }
    location ~* \.(?:png|html|ttf|ico|jpg|jpeg|bcmap|mp4|webm)$ { try_files $uri /index.php$request_uri; }
}
NGINX

    run_compose "$DIR" "Nextcloud"
    log "Nextcloud 已启动 → http://127.0.0.1:${HOST_PORT}"
    log "管理员账号: admin  密码: ${ADMIN_PW}"
}

# ============================================================
# Gitea（含 PostgreSQL）
# ============================================================
deploy_gitea() {
    local DIR="${1:-$BASE_DIR/gitea}"
    local HOST_PORT="${2:-${APP_DEFAULT_PORT[gitea]}}"
    local HOST_SSH_PORT
    HOST_SSH_PORT=$(find_free_port $((HOST_PORT + 10)))   # SSH 端口经 find_free_port 分配，避免冲突
    local NET
    NET=$(net_name "$DIR")

    header "部署 Gitea → $DIR (端口 $HOST_PORT)"
    mkdir -p "$DIR"/{data,db}

    local DB_PW; DB_PW=$(randpw)
    cat > "$DIR/.env" <<EOF
POSTGRES_PASSWORD=${DB_PW}
HOST_PORT=${HOST_PORT}
HOST_SSH_PORT=${HOST_SSH_PORT}
EOF

    cat > "$DIR/docker-compose.yml" <<YAML
services:
  db:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: gitea
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_DB: gitea
    volumes:
      - ./db:/var/lib/postgresql/data
    networks: [${NET}]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U gitea"]
      interval: 10s
      timeout: 5s
      retries: 5

  gitea:
    image: gitea/gitea:latest
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      USER_UID: 1000
      USER_GID: 1000
      GITEA__database__DB_TYPE: postgres
      GITEA__database__HOST: db:5432
      GITEA__database__NAME: gitea
      GITEA__database__USER: gitea
      GITEA__database__PASSWD: \${POSTGRES_PASSWORD}
      GITEA__server__DOMAIN: localhost
      GITEA__server__ROOT_URL: http://localhost/
      GITEA__attachment__MAX_SIZE: 2048
      GITEA__picture__MAX_ORIGINAL_FILE_SIZE: 4096
    volumes:
      - ./data:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    ports:
      - "127.0.0.1:${HOST_PORT}:3000"
      - "127.0.0.1:${HOST_SSH_PORT}:22"
    networks: [${NET}]

networks:
  ${NET}:
    driver: bridge
YAML

    run_compose "$DIR" "Gitea"
    log "Gitea 已启动 → http://127.0.0.1:${HOST_PORT}  SSH: 127.0.0.1:${HOST_SSH_PORT}"
}

# ============================================================
# Uptime Kuma
# ============================================================
deploy_uptime_kuma() {
    local DIR="${1:-$BASE_DIR/uptime-kuma}"
    local HOST_PORT="${2:-${APP_DEFAULT_PORT[uptime-kuma]}}"

    header "部署 Uptime Kuma → $DIR (端口 $HOST_PORT)"
    mkdir -p "$DIR/data"
    echo "HOST_PORT=${HOST_PORT}" > "$DIR/.env"

    cat > "$DIR/docker-compose.yml" <<YAML
services:
  uptime-kuma:
    image: louislam/uptime-kuma:latest
    restart: unless-stopped
    volumes:
      - ./data:/app/data
    ports:
      - "127.0.0.1:${HOST_PORT}:3001"
YAML

    run_compose "$DIR" "Uptime Kuma"
    log "Uptime Kuma 已启动 → http://127.0.0.1:${HOST_PORT}"
}

# ============================================================
# Portainer
# ============================================================
deploy_portainer() {
    local DIR="${1:-$BASE_DIR/portainer}"
    local HOST_PORT="${2:-${APP_DEFAULT_PORT[portainer]}}"
    local HOST_HTTPS_PORT
    HOST_HTTPS_PORT=$(find_free_port $((HOST_PORT + 1)))
    local NET
    NET=$(net_name "$DIR")

    header "部署 Portainer CE → $DIR (端口 $HOST_PORT)"
    mkdir -p "$DIR/data"
    cat > "$DIR/.env" <<EOF
HOST_PORT=${HOST_PORT}
HOST_HTTPS_PORT=${HOST_HTTPS_PORT}
EOF

    cat > "$DIR/docker-compose.yml" <<YAML
services:
  portainer:
    image: portainer/portainer-ce:latest
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/data
    ports:
      - "127.0.0.1:${HOST_HTTPS_PORT}:9443"
      - "127.0.0.1:${HOST_PORT}:9000"
YAML

    run_compose "$DIR" "Portainer"
    log "Portainer 已启动 → http://127.0.0.1:${HOST_PORT}  HTTPS: https://127.0.0.1:${HOST_HTTPS_PORT}"
}

# ============================================================
# phpMyAdmin
# ============================================================
deploy_phpmyadmin() {
    local DIR="${1:-$BASE_DIR/phpmyadmin}"
    local HOST_PORT="${2:-${APP_DEFAULT_PORT[phpmyadmin]}}"

    header "部署 phpMyAdmin → $DIR (端口 $HOST_PORT)"
    mkdir -p "$DIR"
    echo "HOST_PORT=${HOST_PORT}" > "$DIR/.env"

    cat > "$DIR/docker-compose.yml" <<YAML
services:
  phpmyadmin:
    image: phpmyadmin:latest
    restart: unless-stopped
    environment:
      PMA_ARBITRARY: 1
      PMA_ABSOLUTE_URI: "http://localhost/pma/"
      UPLOAD_LIMIT: 2048M
      MEMORY_LIMIT: 1024M
      MAX_EXECUTION_TIME: 600
    ports:
      - "127.0.0.1:${HOST_PORT}:80"
YAML

    run_compose "$DIR" "phpMyAdmin"
    log "phpMyAdmin 已启动 → http://127.0.0.1:${HOST_PORT}"
}

# ============================================================
# Redis Commander
# ============================================================
deploy_redis_commander() {
    local DIR="${1:-$BASE_DIR/redis-commander}"
    local HOST_PORT="${2:-${APP_DEFAULT_PORT[redis-commander]}}"

    header "部署 Redis Commander → $DIR (端口 $HOST_PORT)"
    mkdir -p "$DIR"
    echo "HOST_PORT=${HOST_PORT}" > "$DIR/.env"

    cat > "$DIR/docker-compose.yml" <<YAML
services:
  redis-commander:
    image: rediscommander/redis-commander:latest
    restart: unless-stopped
    environment:
      REDIS_HOSTS: "local:host.docker.internal:6379"
    ports:
      - "127.0.0.1:${HOST_PORT}:8081"
    extra_hosts:
      - "host.docker.internal:host-gateway"
YAML

    run_compose "$DIR" "Redis Commander"
    log "Redis Commander 已启动 → http://127.0.0.1:${HOST_PORT}"
}

# ============================================================
# MinIO
# ============================================================
deploy_minio() {
    local DIR="${1:-$BASE_DIR/minio}"
    local HOST_PORT="${2:-${APP_DEFAULT_PORT[minio]}}"    # 控制台端口
    local API_PORT=$((HOST_PORT + 1))                     # API 端口
    local NET
    NET=$(net_name "$DIR")

    header "部署 MinIO → $DIR (控制台 $HOST_PORT, API $API_PORT)"
    mkdir -p "$DIR/data"

    local SECRET_KEY; SECRET_KEY=$(randpw 32)
    cat > "$DIR/.env" <<EOF
MINIO_ROOT_USER=admin
MINIO_ROOT_PASSWORD=${SECRET_KEY}
HOST_PORT=${HOST_PORT}
API_PORT=${API_PORT}
EOF

    cat > "$DIR/docker-compose.yml" <<YAML
services:
  minio:
    image: minio/minio:latest
    restart: unless-stopped
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: \${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: \${MINIO_ROOT_PASSWORD}
    volumes:
      - ./data:/data
    ports:
      - "127.0.0.1:${API_PORT}:9000"
      - "127.0.0.1:${HOST_PORT}:9001"
    networks: [${NET}]
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 30s
      timeout: 20s
      retries: 3

networks:
  ${NET}:
    driver: bridge
YAML

    run_compose "$DIR" "MinIO"
    log "MinIO 控制台: http://127.0.0.1:${HOST_PORT}  API: http://127.0.0.1:${API_PORT}"
    log "Access Key: admin  Secret Key: ${SECRET_KEY}"
}

# ============================================================
# Lsky Pro（兰空图床）
# ────────────────────────────────────────────────────────────
#  官方镜像 lskypro/lsky-pro 已停止维护（最后推送 2023 年）。
#  改用社区镜像 bestzwei/lskypro，持续跟进官方源码构建。
# ============================================================
deploy_lskypro() {
    local DIR="${1:-$BASE_DIR/lskypro}"
    local HOST_PORT="${2:-${APP_DEFAULT_PORT[lskypro]}}"
    local NET
    NET=$(net_name "$DIR")

    header "部署 Lsky Pro 图床 → $DIR (端口 $HOST_PORT)"
    mkdir -p "$DIR"/{uploads,db}

    local DB_ROOT_PW DB_PW
    DB_ROOT_PW=$(randpw); DB_PW=$(randpw)
    cat > "$DIR/.env" <<EOF
MARIADB_ROOT_PASSWORD=${DB_ROOT_PW}
MARIADB_PASSWORD=${DB_PW}
HOST_PORT=${HOST_PORT}
EOF

    cat > "$DIR/docker-compose.yml" <<YAML
services:
  lskypro-db:
    image: mariadb:11
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: \${MARIADB_ROOT_PASSWORD}
      MARIADB_DATABASE: lskypro
      MARIADB_USER: lskypro
      MARIADB_PASSWORD: \${MARIADB_PASSWORD}
    volumes:
      - ./db:/var/lib/mysql
    networks: [${NET}]
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 5

  lskypro:
    # 官方镜像 lskypro/lsky-pro 已停止维护，使用社区维护镜像
    image: bestzwei/lskypro:latest
    restart: unless-stopped
    environment:
      DB_CONNECTION: mysql
      DB_HOST: lskypro-db
      DB_PORT: 3306
      DB_DATABASE: lskypro
      DB_USERNAME: lskypro
      DB_PASSWORD: \${MARIADB_PASSWORD}
    volumes:
      - ./uploads:/var/www/html/storage/app/uploads
    ports:
      - "127.0.0.1:${HOST_PORT}:80"
    depends_on:
      lskypro-db:
        condition: service_healthy
    networks: [${NET}]

networks:
  ${NET}:
    driver: bridge
YAML

    run_compose "$DIR" "Lsky Pro"
    log "Lsky Pro 已启动 → http://127.0.0.1:${HOST_PORT}"
    warn "首次访问需完成 Web 安装向导（数据库主机填 lskypro-db）"
    log "数据库: lskypro  用户: lskypro  密码见 $DIR/.env"
}

# ============================================================
# EasyImage
# ============================================================
deploy_easyimage() {
    local DIR="${1:-$BASE_DIR/easyimage}"
    local HOST_PORT="${2:-${APP_DEFAULT_PORT[easyimage]}}"
    local NET
    NET=$(net_name "$DIR")

    header "部署 EasyImage 图床 → $DIR (端口 $HOST_PORT)"
    mkdir -p "$DIR"/{data,config}
    echo "HOST_PORT=${HOST_PORT}" > "$DIR/.env"

    cat > "$DIR/docker-compose.yml" <<YAML
services:
  easyimage:
    image: ddsderek/easyimage:latest
    restart: unless-stopped
    environment:
      TZ: Asia/Shanghai
      PUID: 1000
      PGID: 1000
    volumes:
      - ./data:/app/web/i
      - ./config:/app/web/config
    ports:
      - "127.0.0.1:${HOST_PORT}:80"
    networks: [${NET}]

networks:
  ${NET}:
    driver: bridge
YAML

    run_compose "$DIR" "EasyImage"
    log "EasyImage 已启动 → http://127.0.0.1:${HOST_PORT}"
}

# ============================================================
# AList（多存储文件列表 / 网盘挂载）
# ============================================================
deploy_alist() {
    local DIR="${1:-$BASE_DIR/alist}"
    local HOST_PORT="${2:-${APP_DEFAULT_PORT[alist]}}"
    local NET
    NET=$(net_name "$DIR")

    header "部署 AList → $DIR (端口 $HOST_PORT)"
    mkdir -p "$DIR/data"

    # 移除多余的 .env 写入，直接由脚本在下方 Heredoc 中渲染

    cat > "$DIR/docker-compose.yml" <<YAML
services:
  alist:
    image: xhofe/alist:latest
    restart: unless-stopped
    environment:
      - PUID=0
      - PGID=0
      - UMASK=022
    volumes:
      - ./data:/opt/alist/data
      - /root/tgdown/downloads:media  #冒号左边为实际路径 右边为容器映射路径
    ports:
      - "127.0.0.1:${HOST_PORT}:5244"
    networks: [${NET}]
    healthcheck:
      # 替换为 alpine 自带的 wget，并检查主页状态
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:5244/"]
      interval: 30s
      timeout: 10s
      retries: 3

networks:
  ${NET}:
    driver: bridge
YAML

    run_compose "$DIR" "AList"

    # 等待初始化后尝试从日志提取初始密码
    info "等待 AList 初始化（约 5 秒）..."
    sleep 5
    local cid init_pw
    cid=$(cd "$DIR" && docker compose ps -q alist 2>/dev/null | head -1)
    
    # 提示：只有第一次全新部署时日志才会有密码；若容器重启，日志里就不会再出现了
    init_pw=$(docker logs "$cid" 2>&1 | grep -oP '(?<=password: )[^\s]+' | tail -1 || true)

    log "AList 已启动 → http://127.0.0.1:${HOST_PORT}"
    if [[ -n "${init_pw:-}" ]]; then
        log "初始管理员密码: ${init_pw}"
        echo "ALIST_INIT_PASSWORD=${init_pw}" >> "$DIR/.env"
        log "凭据已保存至 $DIR/.env"
    else
        warn "无法自动获取初始密码（可能非首次部署），如需重置请执行："
        warn "  随机新密码: docker exec -it ${cid:-<容器ID>} ./alist admin random"
        warn "  指定新密码: docker exec -it ${cid:-<容器ID>} ./alist admin set <新密码>"
    fi
}

print_summary() {
    local apps=("$@")
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗"
    echo -e "║              🐳  部署完成 — 访问地址汇总                    ║"
    echo -e "╠══════════════════════════════════════════════════════════════╣"
    for app in "${apps[@]}"; do
        local port
        # 优先读取 .env 中的实际端口，回退到默认值
        port=$(grep -oP '(?<=HOST_PORT=)\d+' "$BASE_DIR/$app/.env" 2>/dev/null | head -1) \
            || port="${APP_DEFAULT_PORT[$app]}"
        printf "║  %-16s → %-38s║\n" "$app" "http://127.0.0.1:${port}"
    done
    echo -e "╠══════════════════════════════════════════════════════════════╣"
    echo -e "║  凭据文件位置: /opt/docker-apps/<app>/.env                  ║"
    echo -e "║  在外部 nginx 将以上端口逐一反代即可对外提供服务            ║"
    echo -e "╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ============================================================
# 主流程
# ============================================================
main() {
    if [[ $# -gt 0 ]]; then
        case "$1" in
            --install)    check_system; install_docker; exit 0 ;;
            --deploy)
                [[ -z "${2:-}" ]] && error "请指定应用名称"
                local app="$2"
                local inst_name="" host_port=""
                shift 2
                # 解析可选参数 --instance NAME --port PORT
                while [[ $# -gt 0 ]]; do
                    case "$1" in
                        --instance) inst_name="$2"; shift 2 ;;
                        --port)     host_port="$2"; shift 2 ;;
                        *) error "未知参数: $1" ;;
                    esac
                done
                local inst_dir
                if [[ -n "$inst_name" ]]; then
                    inst_dir="$BASE_DIR/${app}__${inst_name}"
                else
                    inst_dir="$BASE_DIR/$app"
                fi
                [[ -z "$host_port" ]] && host_port=$(find_free_port "${APP_DEFAULT_PORT[$app]:-8080}")
                ensure_docker
                case "$app" in
                    wordpress)       deploy_wordpress       "$inst_dir" "$host_port" ;;
                    nextcloud)       deploy_nextcloud       "$inst_dir" "$host_port" ;;
                    gitea)           deploy_gitea           "$inst_dir" "$host_port" ;;
                    uptime-kuma)     deploy_uptime_kuma     "$inst_dir" "$host_port" ;;
                    portainer)       deploy_portainer       "$inst_dir" "$host_port" ;;
                    phpmyadmin)      deploy_phpmyadmin      "$inst_dir" "$host_port" ;;
                    redis-commander) deploy_redis_commander "$inst_dir" "$host_port" ;;
                    minio)           deploy_minio           "$inst_dir" "$host_port" ;;
                    lskypro)         deploy_lskypro         "$inst_dir" "$host_port" ;;
                    easyimage)       deploy_easyimage       "$inst_dir" "$host_port" ;;
                    alist)           deploy_alist           "$inst_dir" "$host_port" ;;
                    *)               error "未知应用: $app" ;;
                esac
                exit 0
                ;;
            --uninstall)
                [[ -z "${2:-}" ]] && error "请指定实例目录"
                uninstall_app "$2"; exit 0
                ;;
            --backup)
                [[ -z "${2:-}" ]] && error "请指定实例目录"
                backup_app "$2"; exit 0
                ;;
            --update)
                [[ -z "${2:-}" ]] && error "请指定实例目录"
                ensure_docker; update_app_images "$2"; exit 0
                ;;
            --update-all)
                ensure_docker
                local updated=0
                for app in "${ALL_APPS[@]}"; do
                    while IFS= read -r dir; do
                        update_app_images "$dir"; ((updated++))
                    done < <(list_instances "$app")
                done
                [[ $updated -eq 0 ]] && warn "没有已部署的应用"
                exit 0
                ;;
            --list)   list_apps; exit 0 ;;
            --all)    check_system; ensure_docker; deploy_all_apps; exit 0 ;;
            --help|-h) usage ;;
            *)        error "未知选项: $1，使用 --help 查看帮助" ;;
        esac
    fi
    interactive_menu
}

main "$@"
