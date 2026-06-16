#!/bin/bash
# ============================================================
#  Docker + Docker Compose 安装 & 热门应用一键部署脚本
#  支持：WordPress / Nextcloud / Gitea / Uptime Kuma /
#        Portainer / phpMyAdmin / Redis Commander / MinIO /
#        Lsky Pro / EasyImage / AList
#  支持多实例：通过 --deploy APP --instance NAME 或交互菜单指定
#  用法：sudo bash setup-docker-apps.sh [选项]
# ----------------------------------------------------------

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()    { echo -e "${GREEN}[✔]${NC} $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }
error()  { echo -e "${RED}[✘]${NC} $*"; exit 1; }
info()   { echo -e "${BLUE}[i]${NC} $*"; }
header() { echo -e "\n${CYAN}${BOLD}━━━ $* ━━━${NC}\n"; }

BASE_DIR="/opt/docker-apps"
BACKUP_LOCAL_DIR="/var/backups/docker-apps"
mkdir -p "$BASE_DIR" "$BACKUP_LOCAL_DIR"
TARGET_WORDPRESS_PHP="wordpress:php8.3-fpm-alpine"
TARGET_NEXTCLOUD="nextcloud:production-fpm-alpine"
TARGET_MARIADB="mariadb:11"
TARGET_POSTGRES="postgres:16-alpine"
TARGET_REDIS="redis:7-alpine"
TARGET_NGINX="nginx:alpine"

# ============================================================
# SSH 密钥检测与自动推送
# 用法：ensure_ssh_key <user@host> <port>
# ============================================================
ensure_ssh_key() {
    local remote_host="$1"
    local ssh_port="${2:-22}"
    local ssh_opts="-p ${ssh_port} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

    if ssh $ssh_opts -o BatchMode=yes "$remote_host" "echo ok" &>/dev/null; then
        log "密钥登录已可用：$remote_host"
        return 0
    fi

    info "未检测到可用密钥，将用密码完成一次性公钥推送"
    echo ""

    local pubkey_file=""
    for f in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
        [[ -f "$f" ]] && pubkey_file="$f" && break
    done

    if [[ -z "$pubkey_file" ]]; then
        info "本机无 SSH 密钥，自动生成 ed25519 密钥对..."
        ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 \
            -C "docker-script-$(hostname)-$(date +%Y%m%d)" \
            || { warn "密钥生成失败"; return 1; }
        pubkey_file=~/.ssh/id_ed25519.pub
        log "密钥已生成：$pubkey_file"
    else
        info "使用现有公钥：$pubkey_file"
    fi

    local pubkey_content
    pubkey_content=$(cat "$pubkey_file")

    if ! command -v sshpass &>/dev/null; then
        warn "需要安装 sshpass..."
        if command -v apt-get &>/dev/null; then
            apt-get install -y -qq sshpass || { warn "sshpass 安装失败"; return 1; }
        else
            warn "请手动安装 sshpass 后重试"; return 1
        fi
    fi

    read -s -rp "输入 ${remote_host} 的密码（仅此一次）: " remote_pass
    echo ""; echo ""

    export SSHPASS="${remote_pass}"
    if sshpass -e ssh $ssh_opts "$remote_host" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
         echo '${pubkey_content}' >> ~/.ssh/authorized_keys && \
         sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys && \
         chmod 600 ~/.ssh/authorized_keys"; then
        log "公钥推送成功"
    else
        unset SSHPASS
        warn "公钥推送失败"; return 1
    fi
    unset SSHPASS

    if ssh $ssh_opts -o BatchMode=yes "$remote_host" "echo ok" &>/dev/null; then
        log "密钥登录验证通过 ✓"
        return 0
    else
        warn "密钥验证失败，请确认目标机 sshd_config 中 PubkeyAuthentication yes"
        return 1
    fi
}

[[ $EUID -ne 0 ]] && error "请使用 root 或 sudo 运行此脚本"

ALL_APPS=(
    wordpress nextcloud gitea uptime-kuma portainer
    phpmyadmin redis-commander minio lskypro easyimage alist
    sunpanel vaultwarden emby
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
    [sunpanel]="Sun-Panel          个人豪华版导航页"
    [vaultwarden]="Vaultwarden        轻量级密码管理器"
    [emby]="Emby Server       多媒体服务器（视频海报墙）"
)

declare -A APP_DEFAULT_PORT=(
    [wordpress]=8080 [nextcloud]=8081 [gitea]=3000 [uptime-kuma]=3001
    [portainer]=9000 [phpmyadmin]=8082 [redis-commander]=8083
    [minio]=9001 [lskypro]=8085 [easyimage]=8086 [alist]=5244
    [sunpanel]=3002 [vaultwarden]=8099 [emby]=8096
)

get_instance_url() {
    local inst_dir="$1" app="$2"
    local port=""
    [[ -f "$inst_dir/.env" ]] && port=$(grep -oP '(?<=HOST_PORT=)\d+' "$inst_dir/.env" | head -1)
    [[ -z "$port" ]] && port="${APP_DEFAULT_PORT[$app]:-0}"
    echo "http://127.0.0.1:${port}"
}

list_instances() {
    local app="$1"
    [[ -f "$BASE_DIR/$app/docker-compose.yml" ]] && echo "$BASE_DIR/$app"
    for d in "$BASE_DIR/${app}__"*/; do
        [[ -f "${d}docker-compose.yml" ]] && echo "${d%/}"
    done
}

inst_label() {
    local dir="$1" app="$2"
    local name; name=$(basename "$dir")
    [[ "$name" == "$app" ]] && echo "默认实例" || echo "${name#${app}__}"
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
        echo -e "║  5) 备份应用（本地 / 推送到远程）                            ║"
        echo -e "║  6) 查看已部署应用状态                                        ║"
        echo -e "║  7) 更新应用镜像                                              ║"
        echo -e "║  8) 更新应用组件（PHP/DB/Redis 等）                          ║"
        echo -e "║  9) 部署额外实例（同一应用多开）                             ║"
        echo -e "╠══════════════════════════════════════════════════════════════╣"
        echo -e "║  10) 容器详情（镜像/IP/卷/端口/健康）                        ║"
        echo -e "║  11) 资源监控（CPU/内存/网络）                                ║"
        echo -e "║  12) 查看应用日志                                             ║"
        echo -e "║  13) 应用迁移（本地路径 / 远程服务器）                       ║"
        echo -e "║  14) 启动 / 停止 / 重启实例                                  ║"
        echo -e "║  15) 清理 Docker 资源                                         ║"
        echo -e "║  16) 还原应用（从本地或远程备份）                            ║"
        echo -e "║  0) 退出                                                      ║"
        echo -e "╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        read -rp "请选择操作 [0-16]: " choice

        case "$choice" in
            1)  check_system; install_docker ;;
            2)  ensure_docker; menu_select_apps ;;
            3)  check_system; ensure_docker; deploy_all_apps ;;
            4)  menu_uninstall_app ;;
            5)  menu_backup_app ;;
            6)  list_apps ;;
            7)  menu_update_images ;;
            8)  menu_update_components ;;
            9)  ensure_docker; menu_deploy_extra_instance ;;
            10) menu_container_info ;;
            11) menu_resource_monitor ;;
            12) menu_view_logs ;;
            13) menu_migrate_app ;;
            14) menu_start_stop_restart ;;
            15) menu_cleanup_docker ;;
            16) menu_restore_app ;;
            0)  echo "再见！"; exit 0 ;;
            *)  warn "无效选项，请输入 0-16" ;;
        esac
    done
}

ensure_docker() {
    if ! command -v docker &>/dev/null; then
        warn "未检测到 Docker，自动执行安装..."
        check_system; install_docker
    fi
}

menu_select_apps() {
    local -a selected=()
    while true; do
        echo ""
        echo -e "${CYAN}${BOLD}── 选择要部署的应用（输入编号切换选中，支持多选）──${NC}"
        echo ""
        local i=1
        for app in "${ALL_APPS[@]}"; do
            local mark=" "
            if [[ ${#selected[@]} -gt 0 ]]; then
                for s in "${selected[@]}"; do [[ "$s" == "$app" ]] && mark="${GREEN}✔${NC}" && break; done
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
                    local app="${ALL_APPS[$idx]}" found=0
                    local -a new_selected=()
                    if [[ ${#selected[@]} -gt 0 ]]; then
                        for s in "${selected[@]}"; do
                            [[ "$s" == "$app" ]] && found=1 || new_selected+=("$s")
                        done
                    fi
                    if [[ $found -eq 0 ]]; then selected+=("$app"); info "已选中: $app"
                    else
                        [[ ${#new_selected[@]} -gt 0 ]] && selected=("${new_selected[@]}") || selected=()
                        info "已取消: $app"
                    fi
                else warn "编号超出范围"; fi
                ;;
            a) selected=("${ALL_APPS[@]}"); info "已全选 ${#ALL_APPS[@]} 个应用" ;;
            c) selected=(); info "已清空选择" ;;
            d)
                if [[ ${#selected[@]} -eq 0 ]]; then warn "请至少选择一个应用"
                else
                    echo ""; echo -e "${CYAN}即将部署:${NC}"
                    for app in "${selected[@]}"; do echo "  - ${APP_DESC[$app]}"; done
                    echo ""
                    read -rp "确认部署？[y/N]: " confirm
                    if [[ "${confirm,,}" == "y" ]]; then
                        for app in "${selected[@]}"; do
                            "deploy_${app//-/_}" "$BASE_DIR/$app" || warn "$app 部署失败，继续..."
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

menu_deploy_extra_instance() {
    echo ""; echo -e "${CYAN}${BOLD}── 部署额外实例 ──${NC}"; echo ""
    local i=1
    for app in "${ALL_APPS[@]}"; do printf "  %2d) %s\n" "$i" "${APP_DESC[$app]}"; ((i++)); done
    echo ""
    read -rp "请输入应用编号（0 返回）: " idx_input
    [[ "$idx_input" == "0" ]] && return
    local idx=$((idx_input - 1))
    [[ $idx -lt 0 || $idx -ge ${#ALL_APPS[@]} ]] && warn "编号无效" && return
    local app="${ALL_APPS[$idx]}"

    echo ""
    read -rp "  输入新实例名称（字母数字和-）: " inst_name
    inst_name="${inst_name// /_}"
    [[ -z "$inst_name" || ! "$inst_name" =~ ^[a-zA-Z0-9_-]+$ ]] && warn "名称无效" && return

    local inst_dir="$BASE_DIR/${app}__${inst_name}"
    [[ -d "$inst_dir" ]] && warn "实例已存在" && return

    local host_port; host_port=$(find_free_port "${APP_DEFAULT_PORT[$app]}")
    echo -e "  建议端口: ${CYAN}${host_port}${NC}"
    read -rp "  确认端口（回车接受）: " custom_port
    [[ -n "$custom_port" ]] && host_port="$custom_port"

    read -rp "确认创建 ${app}__${inst_name}（端口 ${host_port}）？[y/N]: " confirm
    [[ "${confirm,,}" != "y" ]] && { info "已取消"; return; }

    "deploy_${app//-/_}" "$inst_dir" "$host_port" \
        && log "实例已部署 → http://127.0.0.1:${host_port}" || warn "部署失败"
}

find_free_port() {
    local base="$1" port=$base
    while true; do
        local in_use=0
        while IFS= read -r env_file; do
            grep -qP "HOST_PORT=${port}$" "$env_file" && in_use=1 && break
        done < <(find "$BASE_DIR" -name ".env" -maxdepth 3 2>/dev/null)
        if [[ $in_use -eq 0 ]] && ! ss -tlnH "sport = :${port}" 2>/dev/null | grep -q .; then
            echo "$port"; return
        fi
        ((port++))
    done
}

menu_uninstall_app() {
    echo ""; echo -e "${CYAN}${BOLD}── 选择要卸载的实例 ──${NC}"
    local -a deployed_dirs=() deployed_labels=()
    for app in "${ALL_APPS[@]}"; do
        while IFS= read -r dir; do
            deployed_dirs+=("$dir"); deployed_labels+=("$app  [$(inst_label "$dir" "$app")]")
        done < <(list_instances "$app")
    done
    [[ ${#deployed_dirs[@]} -eq 0 ]] && warn "没有已部署的应用" && return
    local i=1
    for lbl in "${deployed_labels[@]}"; do printf "  %2d) %s\n" "$i" "$lbl"; ((i++)); done
    echo ""; read -rp "请输入要卸载的编号（0 返回）: " input
    [[ "$input" == "0" ]] && return
    local idx=$((input - 1))
    if [[ $idx -ge 0 && $idx -lt ${#deployed_dirs[@]} ]]; then
        read -rp "确认卸载并删除所有数据？[y/N]: " confirm
        [[ "${confirm,,}" == "y" ]] && uninstall_app "${deployed_dirs[$idx]}" || info "已取消"
    else warn "编号无效"; fi
}

# ============================================================
# 5) 备份菜单（支持本地 + 远程推送）
# ============================================================
menu_backup_app() {
    echo ""; echo -e "${CYAN}${BOLD}── 选择要备份的实例 ──${NC}"
    local -a deployed_dirs=() deployed_labels=()
    for app in "${ALL_APPS[@]}"; do
        while IFS= read -r dir; do
            deployed_dirs+=("$dir"); deployed_labels+=("$app  [$(inst_label "$dir" "$app")]")
        done < <(list_instances "$app")
    done
    [[ ${#deployed_dirs[@]} -eq 0 ]] && warn "没有已部署的应用" && return
    local i=1
    for lbl in "${deployed_labels[@]}"; do printf "  %2d) %s\n" "$i" "$lbl"; ((i++)); done
    echo ""; read -rp "请输入要备份的编号（0 返回）: " input
    [[ "$input" == "0" ]] && return
    local idx=$((input - 1))
    [[ $idx -lt 0 || $idx -ge ${#deployed_dirs[@]} ]] && warn "编号无效" && return

    local dir="${deployed_dirs[$idx]}"
    echo ""
    echo -e "  备份保存位置："
    echo -e "  1) 仅本地（${BACKUP_LOCAL_DIR}）"
    echo -e "  2) 本地 + 推送到远程服务器"
    echo -e "  3) 仅远程（推送后删除本地临时文件）"
    echo ""
    read -rp "请选择 [1-3，默认 1]: " backup_mode
    backup_mode="${backup_mode:-1}"

    local remote_host="" remote_path="/var/backups/docker-apps" remote_port="22"
    if [[ "$backup_mode" == "2" || "$backup_mode" == "3" ]]; then
        echo ""; read -rp "  目标服务器（user@host）: " remote_host
        if [[ -z "$remote_host" ]]; then
            warn "地址不能为空，退回仅本地备份"; backup_mode=1
        else
            read -rp "  远程保存路径 [默认 /var/backups/docker-apps]: " remote_path
            remote_path="${remote_path:-/var/backups/docker-apps}"
            read -rp "  SSH 端口 [默认 22]: " remote_port
            remote_port="${remote_port:-22}"
        fi
    fi

    backup_app "$dir" "$remote_host" "$remote_path" "$remote_port" "$backup_mode"
}

# ============================================================
# 16) 还原菜单
# ============================================================
menu_restore_app() {
    echo ""; echo -e "${CYAN}${BOLD}── 还原应用（从备份文件）──${NC}"; echo ""
    echo -e "  1) 从本地备份文件还原"
    echo -e "  2) 从远程服务器拉取备份并还原"
    echo -e "  0) 返回"
    echo ""; read -rp "请选择 [0-2]: " choice
    case "$choice" in
        1) _restore_from_local ;;
        2) _restore_from_remote ;;
        0) return ;;
        *) warn "无效输入" ;;
    esac
}

_restore_from_local() {
    echo ""; echo -e "${CYAN}── 本地备份还原 ──${NC}"; echo ""
    local -a backup_files=()
    while IFS= read -r f; do backup_files+=("$f"); done \
        < <(find "$BACKUP_LOCAL_DIR" /tmp -maxdepth 1 -name "*.tar.gz" 2>/dev/null | sort -r)

    if [[ ${#backup_files[@]} -eq 0 ]]; then
        warn "在 ${BACKUP_LOCAL_DIR} 和 /tmp 中未找到备份文件"
        echo ""; read -rp "  手动输入备份文件完整路径: " manual_path
        [[ -z "$manual_path" || ! -f "$manual_path" ]] && { warn "文件不存在，已取消"; return; }
        backup_files=("$manual_path")
    fi

    echo -e "  找到以下备份文件："
    local i=1
    for f in "${backup_files[@]}"; do
        local sz; sz=$(du -h "$f" | cut -f1)
        printf "  %2d) %-55s %s\n" "$i" "$(basename "$f")" "$sz"
        ((i++))
    done
    echo ""; echo -e "   m) 手动输入文件路径"; echo ""
    read -rp "请选择备份编号（0 返回）: " sel
    [[ "$sel" == "0" ]] && return

    local backup_file=""
    if [[ "$sel" == "m" ]]; then
        read -rp "输入备份文件完整路径: " backup_file
        [[ ! -f "$backup_file" ]] && { warn "文件不存在"; return; }
    else
        local sidx=$((sel - 1))
        [[ $sidx -lt 0 || $sidx -ge ${#backup_files[@]} ]] && { warn "编号无效"; return; }
        backup_file="${backup_files[$sidx]}"
    fi

    restore_app "$backup_file"
}

_restore_from_remote() {
    echo ""; echo -e "${CYAN}── 远程备份还原 ──${NC}"; echo ""
    read -rp "  远程服务器（user@host）: " remote_host
    [[ -z "$remote_host" ]] && { warn "地址不能为空"; return; }
    read -rp "  SSH 端口 [默认 22]: " remote_port; remote_port="${remote_port:-22}"
    read -rp "  远程备份目录 [默认 /var/backups/docker-apps]: " remote_path
    remote_path="${remote_path:-/var/backups/docker-apps}"

    local SSH_OPTS="-p ${remote_port} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

    info "检查 SSH 连通性..."
    ensure_ssh_key "$remote_host" "$remote_port" || { warn "SSH 连接失败"; return; }

    info "获取远程备份文件列表..."
    local remote_files_raw
    remote_files_raw=$(ssh $SSH_OPTS "$remote_host" \
        "find '$remote_path' -maxdepth 1 -name '*.tar.gz' 2>/dev/null | sort -r" 2>/dev/null) || true

    if [[ -z "$remote_files_raw" ]]; then
        warn "远程目录中未找到 .tar.gz 备份文件"
        read -rp "  手动输入远程文件完整路径: " manual_remote
        [[ -z "$manual_remote" ]] && return
        remote_files_raw="$manual_remote"
    fi

    local -a remote_files=()
    while IFS= read -r line; do [[ -n "$line" ]] && remote_files+=("$line"); done <<< "$remote_files_raw"

    echo ""; echo -e "  远程备份文件："
    local i=1
    for f in "${remote_files[@]}"; do
        local sz; sz=$(ssh $SSH_OPTS "$remote_host" "du -h '$f' 2>/dev/null | cut -f1" 2>/dev/null || echo "?")
        printf "  %2d) %-55s %s\n" "$i" "$(basename "$f")" "$sz"
        ((i++))
    done
    echo ""; read -rp "请选择备份编号（0 返回）: " sel
    [[ "$sel" == "0" ]] && return
    local sidx=$((sel - 1))
    [[ $sidx -lt 0 || $sidx -ge ${#remote_files[@]} ]] && { warn "编号无效"; return; }

    local remote_file="${remote_files[$sidx]}"
    local local_tmp="${BACKUP_LOCAL_DIR}/_restore_tmp_$(date +%Y%m%d_%H%M%S).tar.gz"

    info "从远程拉取备份文件..."
    if rsync -az --info=progress2 -e "ssh ${SSH_OPTS}" "${remote_host}:${remote_file}" "$local_tmp"; then
        log "拉取完成：$(du -h "$local_tmp" | cut -f1)"
        restore_app "$local_tmp"
        echo ""; read -rp "删除本地临时备份文件？[y/N]: " del_tmp
        [[ "${del_tmp,,}" == "y" ]] && rm -f "$local_tmp" && log "临时文件已删除"
    else
        warn "备份文件拉取失败"
        rm -f "$local_tmp" 2>/dev/null || true
    fi
}

menu_update_images() {
    echo ""; echo -e "${CYAN}${BOLD}── 更新应用镜像 ──${NC}"; echo ""
    echo -e "  1) 更新指定实例镜像"
    echo -e "  2) 更新全部已部署实例镜像"
    echo -e "  0) 返回"
    echo ""; read -rp "请选择 [0-2]: " choice

    case "$choice" in
        1)
            local -a deployed_dirs=() deployed_labels=()
            for app in "${ALL_APPS[@]}"; do
                while IFS= read -r dir; do
                    deployed_dirs+=("$dir"); deployed_labels+=("$app  [$(inst_label "$dir" "$app")]")
                done < <(list_instances "$app")
            done
            [[ ${#deployed_dirs[@]} -eq 0 ]] && warn "没有已部署的应用" && return
            local i=1
            for lbl in "${deployed_labels[@]}"; do printf "  %2d) %s\n" "$i" "$lbl"; ((i++)); done
            echo ""; read -rp "请输入要更新的编号（0 返回）: " input
            [[ "$input" == "0" ]] && return
            local idx=$((input - 1))
            [[ $idx -ge 0 && $idx -lt ${#deployed_dirs[@]} ]] && update_app_images "${deployed_dirs[$idx]}" || warn "编号无效"
            ;;
        2)
            local updated=0
            for app in "${ALL_APPS[@]}"; do
                while IFS= read -r dir; do update_app_images "$dir"; ((updated++)); done < <(list_instances "$app")
            done
            [[ $updated -eq 0 ]] && warn "没有已部署的应用"
            ;;
        0) return ;;
        *) warn "无效输入" ;;
    esac
}

update_app_images() {
    local dir="$1"
    [[ ! -f "$dir/docker-compose.yml" ]] && warn "$dir 未部署，跳过" && return
    header "更新 $(basename "$dir") 镜像"
    cd "$dir"
    if docker compose pull; then
        docker compose up -d --remove-orphans && log "已使用最新镜像重启" || warn "重启失败"
    else warn "镜像拉取失败，保持当前版本"; fi
    cd - > /dev/null
    local dangling; dangling=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l)
    [[ "$dangling" -gt 0 ]] && docker image prune -f > /dev/null && info "已清理 $dangling 个悬空镜像"
}

menu_update_components() {
    echo ""; echo -e "${CYAN}${BOLD}── 更新应用组件 ──${NC}"; echo ""
    echo -e "  1) 升级 WordPress PHP → ${TARGET_WORDPRESS_PHP}"
    echo -e "  2) 升级 Nextcloud → ${TARGET_NEXTCLOUD}"
    echo -e "  3) 统一所有 MariaDB → ${TARGET_MARIADB}"
    echo -e "  4) 升级所有 PostgreSQL → ${TARGET_POSTGRES}"
    echo -e "  5) 统一所有 Redis → ${TARGET_REDIS}"
    echo -e "  6) 统一所有 Nginx → ${TARGET_NGINX}"
    echo -e "  7) 批量执行以上全部"
    echo -e "  0) 返回"
    echo ""; read -rp "请选择 [0-7]: " choice
    case "$choice" in
        1) update_component_php_wordpress ;;
        2) update_component_nextcloud ;;
        3) update_component_mariadb ;;
        4) update_component_postgres ;;
        5) update_component_redis ;;
        6) update_component_nginx ;;
        7) update_component_all ;;
        0) return ;;
        *) warn "无效输入" ;;
    esac
}

_major_ver() {
    echo "$1" | grep -oP '\d+' | head -1
}
 
# ============================================================
# 内部工具：大版本升级提示
# 用法：_major_upgrade_warn "mariadb:10" "mariadb:11" → 返回 0=继续 1=跳过
# ============================================================
_major_upgrade_warn() {
    local current="$1" target="$2"
    local cur_major tgt_major
    cur_major=$(_major_ver "$current")
    tgt_major=$(_major_ver "$target")
 
    if [[ -n "$cur_major" && -n "$tgt_major" && "$tgt_major" -gt "$cur_major" ]]; then
        echo ""
        warn "检测到大版本升级：${current} → ${target}（${cur_major} → ${tgt_major}）"
        warn "大版本升级可能导致数据格式不兼容，建议先执行备份（菜单 5）"
        read -rp "  仍要继续升级？[y/N]: " confirm
        [[ "${confirm,,}" == "y" ]] && return 0 || return 1
    fi
    return 0
}

_replace_image_and_restart() {
    local dir="$1" old_tag="$2" new_tag="$3"; local services=("${@:4}")
    sed -i "s|${old_tag}|${new_tag}|g" "$dir/docker-compose.yml"
    cd "$dir"
    if [[ ${#services[@]} -gt 0 ]]; then
        docker compose pull "${services[@]}" || warn "$(basename "$dir") 镜像拉取失败"
        docker compose up -d "${services[@]}" || warn "$(basename "$dir") 服务重启失败"
    else
        docker compose pull || warn "$(basename "$dir") 镜像拉取失败"
        docker compose up -d --remove-orphans || warn "$(basename "$dir") 重启失败"
    fi
    cd - > /dev/null
}
 
# ============================================================
# 内部工具：从 compose 文件中找某个镜像所属的服务名
# 用法：_find_service_by_image "$dir/docker-compose.yml" "mariadb:10"
# 输出：服务名（如 db / lskypro-db / redis 等）
# ============================================================
_find_service_by_image() {
    local compose_file="$1" image="$2"
    # 过滤注释行后，用 awk 扫描：遇到顶层服务行记录服务名，遇到匹配 image 行输出
    grep -v '^\s*#' "$compose_file" \
        | awk -v img="$image" '
            /^  [a-zA-Z]/ { svc=$1; gsub(/:$/, "", svc) }
            $0 ~ ("image:.*" img) { print svc; exit }
        '
}
 
# ============================================================
# 8-1) 升级 WordPress PHP 版本
# ============================================================
update_component_php_wordpress() {
    local new_tag="$TARGET_WORDPRESS_PHP"
    header "升级 WordPress PHP → ${new_tag}"
    local updated=0
    while IFS= read -r dir; do
        [[ ! -f "$dir/docker-compose.yml" ]] && continue
 
        # 排除注释行后提取当前标签
        local current
        current=$(grep -v '^\s*#' "$dir/docker-compose.yml" \
            | grep -oP 'wordpress:php[\d.]+-fpm-alpine' | head -1)
        [[ -z "$current" || "$current" == "$new_tag" ]] && continue
 
        info "[$(basename "$dir")] $current → $new_tag"
 
        # 大版本检测
        _major_upgrade_warn "$current" "$new_tag" || { info "已跳过 $(basename "$dir")"; continue; }
 
        _replace_image_and_restart "$dir" "$current" "$new_tag" "wordpress"
        log "已升级 $(basename "$dir")"; ((updated++))
    done < <(list_instances "wordpress")
    [[ $updated -eq 0 ]] && info "所有 WordPress 实例均已是最新版本"
}
 
# ============================================================
# 8-2) 升级 Nextcloud 版本
# ============================================================
update_component_nextcloud() {
    local new_tag="$TARGET_NEXTCLOUD"
    header "升级 Nextcloud → ${new_tag}"
    local updated=0
    while IFS= read -r dir; do
        [[ ! -f "$dir/docker-compose.yml" ]] && continue
 
        local current
        current=$(grep -v '^\s*#' "$dir/docker-compose.yml" \
            | grep -oP 'nextcloud:[a-z0-9][a-z0-9.\-]*-fpm-alpine' | head -1)
        [[ -z "$current" || "$current" == "$new_tag" ]] && continue
 
        info "[$(basename "$dir")] $current → $new_tag"
        warn "Nextcloud 版本跨越升级前请先备份数据（菜单 5）"
 
        read -rp "  确认升级？[y/N]: " confirm
        [[ "${confirm,,}" != "y" ]] && { info "已跳过 $(basename "$dir")"; continue; }
 
        _replace_image_and_restart "$dir" "$current" "$new_tag" "nextcloud" "cron"
        log "已升级 $(basename "$dir")"; ((updated++))
    done < <(list_instances "nextcloud")
    [[ $updated -eq 0 ]] && info "所有 Nextcloud 实例均已是最新版本"
}
 
# ============================================================
# 8-3) 统一 MariaDB 版本
# ============================================================
update_component_mariadb() {
    local new_tag="$TARGET_MARIADB"
    header "统一 MariaDB → ${new_tag}"
    local updated=0
    for app in "${ALL_APPS[@]}"; do
        while IFS= read -r dir; do
            [[ ! -f "$dir/docker-compose.yml" ]] && continue
            grep -v '^\s*#' "$dir/docker-compose.yml" | grep -q 'image:.*mariadb:' || continue
 
            local current
            current=$(grep -v '^\s*#' "$dir/docker-compose.yml" \
                | grep -oP 'mariadb:[^\s"]+' | head -1)
            [[ -z "$current" || "$current" == "$new_tag" ]] && continue
 
            info "[$(basename "$dir")] $current → $new_tag"
 
            # 大版本检测（mariadb:10 → 11 也要提示）
            _major_upgrade_warn "$current" "$new_tag" || { info "已跳过 $(basename "$dir")"; continue; }
 
            # 动态提取服务名（awk 解析，不依赖 grep -B2）
            local db_service
            db_service=$(_find_service_by_image "$dir/docker-compose.yml" "mariadb:" )
            db_service="${db_service:-db}"
            info "  目标服务名：$db_service"
 
            _replace_image_and_restart "$dir" "$current" "$new_tag" "$db_service"
            log "已升级 $(basename "$dir")"; ((updated++))
        done < <(list_instances "$app")
    done
    [[ $updated -eq 0 ]] && info "所有实例 MariaDB 均已是最新版本" || log "已更新 $updated 个实例"
}
 
# ============================================================
# 8-4) 升级 PostgreSQL 版本
# ============================================================
update_component_postgres() {
    local new_tag="$TARGET_POSTGRES"
    header "升级 PostgreSQL → ${new_tag}"
    local updated=0
    for app in "${ALL_APPS[@]}"; do
        while IFS= read -r dir; do
            [[ ! -f "$dir/docker-compose.yml" ]] && continue
            grep -v '^\s*#' "$dir/docker-compose.yml" | grep -q 'image:.*postgres:' || continue
 
            local current
            current=$(grep -v '^\s*#' "$dir/docker-compose.yml" \
                | grep -oP 'postgres:[^\s"]+' | head -1)
            [[ -z "$current" || "$current" == "$new_tag" ]] && continue
 
            info "[$(basename "$dir")] $current → $new_tag"
 
            # PostgreSQL 大版本升级必须手动迁移数据，强制提示
            warn "PostgreSQL 大版本升级（如 15→17）需手动迁移数据！"
            warn "升级流程：pg_dumpall 导出 → 换标签 → up -d → psql 导入"
            warn "直接挂载旧数据目录启动新版本容器会损坏数据"
 
            _major_upgrade_warn "$current" "$new_tag" || { info "已跳过 $(basename "$dir")"; continue; }
 
            # 只改标签，不自动重启（数据迁移需手动完成）
            sed -i "s|${current}|${new_tag}|g" "$dir/docker-compose.yml"
            warn "$(basename "$dir") 标签已修改为 ${new_tag}"
            warn "请手动完成数据迁移后再执行：cd $dir && docker compose up -d"
            ((updated++))
        done < <(list_instances "$app")
    done
    [[ $updated -eq 0 ]] && info "所有实例 PostgreSQL 均已是最新版本" \
        || log "已修改 $updated 个实例标签（需手动迁移数据后启动）"
}
 
# ============================================================
# 8-5) 统一 Redis 版本
# ============================================================
update_component_redis() {
    local new_tag="$TARGET_REDIS"
    header "统一 Redis → ${new_tag}"
    local updated=0
    for app in "${ALL_APPS[@]}"; do
        while IFS= read -r dir; do
            [[ ! -f "$dir/docker-compose.yml" ]] && continue
            grep -v '^\s*#' "$dir/docker-compose.yml" | grep -q 'image:.*redis:' || continue
 
            local current
            current=$(grep -v '^\s*#' "$dir/docker-compose.yml" \
                | grep -oP 'redis:[^\s"]+' | head -1)
            [[ -z "$current" || "$current" == "$new_tag" ]] && continue
 
            info "[$(basename "$dir")] $current → $new_tag"
 
            # 大版本检测
            _major_upgrade_warn "$current" "$new_tag" || { info "已跳过 $(basename "$dir")"; continue; }
 
            # 动态提取服务名
            local redis_service
            redis_service=$(_find_service_by_image "$dir/docker-compose.yml" "redis:")
            redis_service="${redis_service:-redis}"
            info "  目标服务名：$redis_service"
 
            _replace_image_and_restart "$dir" "$current" "$new_tag" "$redis_service"
            log "已升级 $(basename "$dir")"; ((updated++))
        done < <(list_instances "$app")
    done
    [[ $updated -eq 0 ]] && info "所有实例 Redis 均已是最新版本" || log "已更新 $updated 个实例"
}
 
# ============================================================
# 8-6) 统一 Nginx 版本
# ============================================================
update_component_nginx() {
    local new_tag="$TARGET_NGINX"
    header "统一 Nginx → ${new_tag}"
    local updated=0
    for app in "${ALL_APPS[@]}"; do
        while IFS= read -r dir; do
            [[ ! -f "$dir/docker-compose.yml" ]] && continue
            grep -v '^\s*#' "$dir/docker-compose.yml" | grep -q 'image:.*nginx:' || continue
 
            local current
            current=$(grep -v '^\s*#' "$dir/docker-compose.yml" \
                | grep -oP 'nginx:[^\s"]+' | head -1)
            [[ -z "$current" || "$current" == "$new_tag" ]] && continue
 
            info "[$(basename "$dir")] $current → $new_tag"
 
            # nginx 通常只追 alpine tag，大版本变动较少，仍走通用检测
            _major_upgrade_warn "$current" "$new_tag" || { info "已跳过 $(basename "$dir")"; continue; }
 
            # 动态提取服务名
            local nginx_service
            nginx_service=$(_find_service_by_image "$dir/docker-compose.yml" "nginx:")
            nginx_service="${nginx_service:-nginx}"
            info "  目标服务名：$nginx_service"
 
            _replace_image_and_restart "$dir" "$current" "$new_tag" "$nginx_service"
            log "已升级 $(basename "$dir")"; ((updated++))
        done < <(list_instances "$app")
    done
    [[ $updated -eq 0 ]] && info "所有实例 Nginx 均已是最新版本" || log "已更新 $updated 个实例"
}

deploy_all_apps() {
    echo ""
    echo -e "${YELLOW}即将部署全部 ${#ALL_APPS[@]} 个应用。${NC}"
    read -rp "确认继续？[y/N]: " confirm
    [[ "${confirm,,}" != "y" ]] && { info "已取消"; return; }
    for app in "${ALL_APPS[@]}"; do
        "deploy_${app//-/_}" "$BASE_DIR/$app" || warn "$app 部署失败，继续..."
    done
    print_summary "${ALL_APPS[@]}"
}

usage() {
    cat <<EOF
用法: $0 [选项]

选项:
  （无参数）               进入交互式菜单（推荐）
  --install                仅安装 / 更新 Docker
  --deploy APP             部署指定应用默认实例
  --deploy APP --instance NAME [--port PORT]
                           部署命名实例（多开）
  --uninstall DIR          卸载实例并删除数据
  --backup DIR             备份实例到 ${BACKUP_LOCAL_DIR}
  --backup DIR --remote user@host [--remote-path PATH] [--remote-port PORT]
                           备份并推送到远程（本地+远程）
  --restore BACKUP_FILE    从本地 tar.gz 备份还原
  --restore --remote user@host REMOTE_FILE [--remote-port PORT]
                           从远程拉取备份文件并还原
  --update DIR             更新实例镜像并重启
  --update-all             更新全部已部署实例镜像
  --list                   列出应用状态
  --all                    部署全部应用（非交互）
  --info DIR               查看容器详情
  --logs DIR               查看最近 100 行日志
  --stats                  查看资源快照
  --cleanup                清理 Docker 资源
  --start / --stop / --restart DIR
                           启动 / 停止 / 重启实例
  --help                   显示此帮助

备份文件保存于: ${BACKUP_LOCAL_DIR}
每个应用本地/远程各保留最近 10 份，自动轮转清理。

示例:
  sudo bash $0
  sudo bash $0 --backup /opt/docker-apps/alist
  sudo bash $0 --backup /opt/docker-apps/wordpress \\
       --remote root@10.0.0.2 --remote-path /data/backups
  sudo bash $0 --restore /var/backups/docker-apps/alist_20250606_120000.tar.gz
  sudo bash $0 --restore --remote root@10.0.0.2 \\
       /var/backups/docker-apps/wordpress_20250606.tar.gz
EOF
    exit 0
}

list_apps() {
    echo ""; echo -e "${CYAN}${BOLD}── 应用实例状态 ──${NC}"; echo ""
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
    [[ "$mem" -lt 1024 ]] && warn "内存不足 1GB（当前 ${mem}MB）"
    [[ "$disk" -lt 5120 ]] && warn "磁盘空间不足 5GB（剩余 ${disk}MB）"
    command -v apt-get &>/dev/null || error "仅支持 apt 系发行版"
}

run_compose() {
    local dir="$1" name="$2"
    cd "$dir"
    docker compose up -d && log "$name 启动成功" || { cd - > /dev/null; error "无法启动 $name，请检查 $dir"; }
    cd - > /dev/null
}

install_docker() {
    header "安装 / 更新 Docker Engine"
    command -v docker &>/dev/null && warn "已安装 Docker，执行更新..."
    . /etc/os-release
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/${ID} $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    log "Docker         $(docker version --format '{{.Server.Version}}')"
    log "Docker Compose $(docker compose version --short)"
}

randpw() {
    local len="${1:-24}"
    tr -dc 'A-Za-z0-9!@#%^&*()_+-=' </dev/urandom 2>/dev/null | dd bs=1 count="$len" 2>/dev/null
    echo
}

# ============================================================
# backup_app — 本地备份 + 可选推送到远程
#
# 参数:
#   $1  dir          实例目录
#   $2  remote_host  远程服务器 user@host（可为空）
#   $3  remote_path  远程保存路径（默认 /var/backups/docker-apps）
#   $4  remote_port  SSH 端口（默认 22）
#   $5  mode         1=仅本地  2=本地+远程  3=仅远程
#
# 特性:
#   · 停止容器 → 打包 → 重启，保证数据一致性
#   · 本地/远程各自保留最近 10 份，自动轮转清理旧备份
#   · SSH 密钥自动推送（首次需要密码）
# ============================================================
backup_app() {
    local dir="$1"
    local remote_host="${2:-}"
    local remote_path="${3:-/var/backups/docker-apps}"
    local remote_port="${4:-22}"
    local mode="${5:-1}"

    local app_name; app_name=$(basename "$dir")
    local timestamp; timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_LOCAL_DIR}/${app_name}_${timestamp}.tar.gz"

    [[ ! -d "$dir" ]] && error "目录 $dir 不存在"
    header "备份 $app_name"
    mkdir -p "$BACKUP_LOCAL_DIR"

    # ── 1. 停止容器确保数据一致性 ────────────────────────────
    info "[1/4] 停止容器（确保备份数据一致性）..."
    if ! (cd "$dir" && docker compose stop 2>/dev/null); then
        warn "容器停止失败，备份数据可能不一致，继续..."
    else
        log "容器已停止"
    fi

    # ── 2. 打包 ───────────────────────────────────────────────
    info "[2/4] 打包数据 → ${backup_file} ..."
    if tar -czf "$backup_file" -C "$(dirname "$dir")" "$(basename "$dir")"; then
        log "打包完成：$(du -h "$backup_file" | cut -f1)"
    else
        warn "打包失败！"
        (cd "$dir" && docker compose start 2>/dev/null) || true
        return 1
    fi

    # ── 3. 重启容器 ───────────────────────────────────────────
    info "[3/4] 重启容器..."
    if ! (cd "$dir" && docker compose start 2>/dev/null); then
        warn "$app_name 备份后重启失败，请手动执行: cd $dir && docker compose up -d"
    else
        log "容器已重启"
    fi

    # ── 4. 远程推送 ───────────────────────────────────────────
    if [[ -n "$remote_host" && ( "$mode" == "2" || "$mode" == "3" ) ]]; then
        info "[4/4] 推送备份到 ${remote_host}:${remote_path} ..."
        local SSH_OPTS="-p ${remote_port} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"

        # 自动推送公钥（如未就位）
        if ! ensure_ssh_key "$remote_host" "$remote_port"; then
            warn "SSH 连接失败，备份文件仅保存在本地：$backup_file"
            return 1
        fi

        # 在远程创建目录
        ssh $SSH_OPTS "$remote_host" "mkdir -p '${remote_path}'" \
            || { warn "远程目录创建失败，备份保存在本地：$backup_file"; return 1; }

        # rsync 推送
        if rsync -az --info=progress2 -e "ssh ${SSH_OPTS}" \
            "$backup_file" "${remote_host}:${remote_path}/"; then
            log "已推送到 ${remote_host}:${remote_path}/$(basename "$backup_file")"

            # mode=3：仅远程，删除本地文件
            if [[ "$mode" == "3" ]]; then
                rm -f "$backup_file"
                log "已删除本地临时文件（仅远程模式）"
            fi

            # 远程轮转：保留最近 10 份
            _remote_rotate_backups "$remote_host" "$remote_path" "$app_name" "$SSH_OPTS"
        else
            warn "远程推送失败！备份文件保留在本地：$backup_file"
            return 1
        fi
    else
        info "[4/4] 跳过远程推送"
    fi

    # 本地轮转（mode=3 时本地文件已删除，跳过）
    [[ "$mode" != "3" ]] && _local_rotate_backups "$app_name"

    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗"
    echo -e "║                       备份完成                              ║"
    echo -e "╠══════════════════════════════════════════════════════════════╣"
    [[ "$mode" != "3" ]] && printf "║  本地: %-54s║\n" "$backup_file"
    [[ -n "$remote_host" && ( "$mode" == "2" || "$mode" == "3" ) ]] && \
        printf "║  远程: %-54s║\n" "${remote_host}:${remote_path}/$(basename "$backup_file")"
    echo -e "╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ── 本地轮转：每个应用最多保留 10 份 ───────────────────────
_local_rotate_backups() {
    local app_name="$1" keep=10
    local count; count=$(find "$BACKUP_LOCAL_DIR" -maxdepth 1 -name "${app_name}_*.tar.gz" 2>/dev/null | wc -l)
    if [[ "$count" -gt "$keep" ]]; then
        local to_delete=$(( count - keep ))
        info "本地备份超过 ${keep} 份，清理最旧的 ${to_delete} 份..."
        find "$BACKUP_LOCAL_DIR" -maxdepth 1 -name "${app_name}_*.tar.gz" \
            | sort | head -n "$to_delete" | xargs rm -f
        log "已清理 ${to_delete} 份旧备份"
    fi
}

# ── 远程轮转：每个应用最多保留 10 份 ───────────────────────
_remote_rotate_backups() {
    local remote_host="$1" remote_path="$2" app_name="$3" ssh_opts="$4" keep=10
    local remote_count
    remote_count=$(ssh $ssh_opts "$remote_host" \
        "find '$remote_path' -maxdepth 1 -name '${app_name}_*.tar.gz' 2>/dev/null | wc -l" 2>/dev/null || echo "0")
    if [[ "$remote_count" -gt "$keep" ]]; then
        local to_delete=$(( remote_count - keep ))
        info "远程备份超过 ${keep} 份，清理最旧的 ${to_delete} 份..."
        ssh $ssh_opts "$remote_host" \
            "find '$remote_path' -maxdepth 1 -name '${app_name}_*.tar.gz' \
             | sort | head -n ${to_delete} | xargs rm -f" 2>/dev/null || true
        log "远程旧备份已清理"
    fi
}

# ============================================================
# restore_app — 从 tar.gz 备份还原实例
#
# 参数:
#   $1  backup_file  本地备份文件路径（必须）
#
# 流程:
#   1. 解析备份中的顶层目录名（= 应用目录名）
#   2. 询问还原目标路径（默认 BASE_DIR/<原目录名>）
#   3. 若目标已存在 → 提供"先备份再覆盖/直接覆盖/取消"三选
#   4. 解压备份文件
#   5. 校验 docker-compose.yml 是否存在
#   6. docker compose pull && up -d 自动拉取镜像并启动
#   7. 打印汇总：路径、访问地址、注意事项
# ============================================================
restore_app() {
    local backup_file="$1"
    [[ ! -f "$backup_file" ]] && error "备份文件不存在：$backup_file"

    header "还原应用 ← $(basename "$backup_file")"

    # ── 1. 解析备份顶层目录名 ────────────────────────────────
    info "[1/6] 分析备份文件内容..."
    local top_dir
    top_dir=$(tar -tzf "$backup_file" 2>/dev/null | head -1 | cut -d'/' -f1)
    [[ -z "$top_dir" ]] && error "无法读取备份内容，文件可能损坏"
    log "备份中的应用目录：$top_dir"

    # ── 2. 确认还原路径 ───────────────────────────────────────
    local default_restore_dir="$BASE_DIR/$top_dir"
    echo ""
    echo -e "  默认还原路径：${CYAN}${default_restore_dir}${NC}"
    read -rp "  确认路径（回车接受，或输入自定义路径）: " custom_dir
    local restore_dir="${custom_dir:-$default_restore_dir}"

    # ── 3. 处理已存在的目录 ───────────────────────────────────
    if [[ -d "$restore_dir" ]]; then
        echo ""; warn "目标路径已存在：$restore_dir"
        echo -e "  a) 先备份现有实例，再覆盖还原"
        echo -e "  b) 直接覆盖（现有数据将被删除）"
        echo -e "  c) 取消"
        echo ""; read -rp "  请选择 [a/b/c]: " overwrite_choice

        case "${overwrite_choice,,}" in
            a)
                info "备份现有实例..."
                local existing_bak="${BACKUP_LOCAL_DIR}/${top_dir}_pre_restore_${timestamp:-$(date +%Y%m%d_%H%M%S)}.tar.gz"
                tar -czf "$existing_bak" -C "$(dirname "$restore_dir")" "$(basename "$restore_dir")" \
                    && log "现有实例已备份到：$existing_bak" \
                    || { warn "备份失败，还原中止"; return 1; }
                [[ -f "$restore_dir/docker-compose.yml" ]] && \
                    (cd "$restore_dir" && docker compose down 2>/dev/null) || true
                rm -rf "$restore_dir"
                ;;
            b)
                read -rp "  确认删除 ${restore_dir} 的全部数据？[y/N]: " del_confirm
                [[ "${del_confirm,,}" != "y" ]] && { info "已取消"; return; }
                [[ -f "$restore_dir/docker-compose.yml" ]] && \
                    (cd "$restore_dir" && docker compose down 2>/dev/null) || true
                rm -rf "$restore_dir"
                ;;
            *)
                info "已取消还原"; return ;;
        esac
    fi

    # ── 4. 解压 ───────────────────────────────────────────────
    info "[4/6] 解压备份文件..."
    local extract_dir; extract_dir=$(dirname "$restore_dir")
    mkdir -p "$extract_dir"
    tar -xzf "$backup_file" -C "$extract_dir" || error "解压失败，备份文件可能损坏"
    # 若备份目录名与还原目标不同则重命名
    local extracted_path="$extract_dir/$top_dir"
    if [[ "$extracted_path" != "$restore_dir" && -d "$extracted_path" ]]; then
        mv "$extracted_path" "$restore_dir"
        log "目录已重命名为：$restore_dir"
    fi
    log "解压完成：$restore_dir"

    # ── 5. 校验 compose 文件 ──────────────────────────────────
    info "[5/6] 校验配置文件..."
    if [[ ! -f "$restore_dir/docker-compose.yml" ]]; then
        warn "未找到 docker-compose.yml，备份可能不完整"
        ls -la "$restore_dir" 2>/dev/null || true
        read -rp "  仍要尝试启动？[y/N]: " force_start
        [[ "${force_start,,}" != "y" ]] && return
    else
        log "docker-compose.yml 存在"
    fi

    # ── 6. 拉取镜像并启动 ─────────────────────────────────────
    info "[6/6] 拉取镜像并启动服务..."
    if (cd "$restore_dir" && docker compose pull 2>/dev/null && docker compose up -d); then
        log "服务已启动"
    else
        warn "自动启动失败，请手动检查：cd $restore_dir && docker compose logs"
    fi

    # ── 汇总 ──────────────────────────────────────────────────
    local access_url="见 .env 中 HOST_PORT"
    if [[ -f "$restore_dir/.env" ]]; then
        local port; port=$(grep -oP '(?<=HOST_PORT=)\d+' "$restore_dir/.env" 2>/dev/null | head -1 || true)
        [[ -n "$port" ]] && access_url="http://127.0.0.1:${port}"
    fi

    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗"
    echo -e "║                       还原完成                              ║"
    echo -e "╠══════════════════════════════════════════════════════════════╣"
    printf  "║  备份文件: %-50s║\n" "$(basename "$backup_file")"
    printf  "║  还原路径: %-50s║\n" "$restore_dir"
    printf  "║  访问地址: %-50s║\n" "$access_url"
    echo -e "╠══════════════════════════════════════════════════════════════╣"
    echo -e "║  注意事项：                                                  ║"
    echo -e "║  · 核查 .env 中的密码与数据库配置是否正确                   ║"
    echo -e "║  · 若端口冲突，修改 .env 中 HOST_PORT 后重启                ║"
    echo -e "║  · Nextcloud/Gitea 首次访问可能需要重新完成配置向导         ║"
    echo -e "╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

uninstall_app() {
    local dir="$1"; local app_name; app_name=$(basename "$dir")
    [[ ! -d "$dir" ]] && error "目录 $dir 不存在"
    header "卸载 $app_name"
    [[ -f "$dir/docker-compose.yml" ]] && \
        (cd "$dir" && docker compose down -v --remove-orphans) || warn "容器停止失败，继续..."
    if [[ -f "$dir/.env" ]]; then
        local bak="/tmp/${app_name}_env_backup_$(date +%Y%m%d_%H%M%S)"
        cp "$dir/.env" "$bak" 2>/dev/null || true; log "凭据已备份到 $bak"
    fi
    rm -rf "$dir"; log "已卸载 $app_name 并删除所有数据"
}

# ============================================================
# 各应用部署函数
# ============================================================
net_name() { echo "$(basename "$1" | tr -cd 'a-zA-Z0-9_' | tr '[:upper:]' '[:lower:]')_net"; }

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

deploy_gitea() {
    local DIR="${1:-$BASE_DIR/gitea}"
    local HOST_PORT="${2:-${APP_DEFAULT_PORT[gitea]}}"
    local HOST_SSH_PORT
    HOST_SSH_PORT=$(find_free_port $((HOST_PORT + 10)))
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

deploy_portainer() {
    local DIR="${1:-$BASE_DIR/portainer}"
    local HOST_PORT="${2:-${APP_DEFAULT_PORT[portainer]}}"
    local HOST_HTTPS_PORT
    HOST_HTTPS_PORT=$(find_free_port $((HOST_PORT + 1)))

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

deploy_minio() {
    local DIR="${1:-$BASE_DIR/minio}"
    local HOST_PORT="${2:-${APP_DEFAULT_PORT[minio]}}"
    local API_PORT=$((HOST_PORT + 1))
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

deploy_alist() {
    local DIR="${1:-$BASE_DIR/alist}"
    local HOST_PORT="${2:-${APP_DEFAULT_PORT[alist]}}"
    local MEDIA_DIR="${3:-/root/tg_download/downloads}"
    local NET
    NET=$(net_name "$DIR")

    header "部署 AList → $DIR (端口 $HOST_PORT)"

    # ── 前置检查 ─────────────────────────────────────────────
    if [[ ! -d "$MEDIA_DIR" ]]; then
        warn "媒体目录不存在: $MEDIA_DIR"
        warn "将跳过 /media 挂载，部署后可手动添加"
        local MEDIA_MOUNT=""
    else
        local MEDIA_MOUNT="      - ${MEDIA_DIR}:/media"
    fi

    # 获取宿主机实际 uid/gid，避免以 root 运行容器进程
    local PUID PGID
    PUID=$(id -u)
    PGID=$(id -g)

    mkdir -p "$DIR/data"
    echo "HOST_PORT=${HOST_PORT}" > "$DIR/.env"

    # heredoc 用 <<'YAML' 防止意外展开，变量通过 sed 注入
    sed \
        -e "s|__HOST_PORT__|${HOST_PORT}|g" \
        -e "s|__NET__|${NET}|g" \
        -e "s|__PUID__|${PUID}|g" \
        -e "s|__PGID__|${PGID}|g" \
        -e "s|__MEDIA_MOUNT__|${MEDIA_MOUNT}|g" \
        > "$DIR/docker-compose.yml" <<'YAML'
services:
  alist:
    image: xhofe/alist:latest
    restart: unless-stopped
    environment:
      - PUID=__PUID__
      - PGID=__PGID__
      - UMASK=022
    volumes:
      - ./data:/opt/alist/data
__MEDIA_MOUNT__
    ports:
      - "127.0.0.1:__HOST_PORT__:5244"
    networks: [__NET__]
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:5244/"]
      interval: 30s
      timeout: 10s
      retries: 3
networks:
  __NET__:
    driver: bridge
YAML

    # MEDIA_MOUNT 为空时 compose 里会多一个空行，清理掉
    if [[ -z "$MEDIA_MOUNT" ]]; then
        sed -i '/^$/d' "$DIR/docker-compose.yml"
    fi

    run_compose "$DIR" "AList"

    # ── 等待容器就绪，最多 60 秒 ──────────────────────────────
    info "等待 AList 容器启动..."
    local cid elapsed=0
    while [[ $elapsed -lt 60 ]]; do
        cid=$(cd "$DIR" && docker compose ps -q alist 2>/dev/null | head -1)
        [[ -n "$cid" ]] && break
        sleep 5
        (( elapsed += 5 ))
    done

    if [[ -z "${cid:-}" ]]; then
        warn "容器未能在 60 秒内启动，请手动检查: docker compose -f $DIR/docker-compose.yml ps"
        return 1
    fi

    # ── 提取初始密码（仅首次部署日志中存在）────────────────────
    # 再等几秒让 AList 完成初始化写入日志
    sleep 3
    local init_pw
    init_pw=$(docker logs "$cid" 2>&1 \
        | grep -o 'password: [^ ]*' \
        | awk '{print $2}' \
        | tail -1 || true)

    log "AList 已启动 → http://127.0.0.1:${HOST_PORT}"

    if [[ -n "${init_pw:-}" ]]; then
        log "初始管理员密码: ${init_pw}"
        echo "ALIST_INIT_PASSWORD=${init_pw}" >> "$DIR/.env"
        log "凭据已保存至 $DIR/.env"
    else
        warn "无法自动获取初始密码（可能非首次部署），如需重置请执行："
        warn "  随机新密码: docker exec -it ${cid} ./alist admin random"
        warn "  指定新密码: docker exec -it ${cid} ./alist admin set <新密码>"
    fi
}

# ==========================================
# 个人导航页 (Sun-Panel)
# ==========================================
deploy_sunpanel() {
    local instance_name="${1:-}"
    [[ -z "$instance_name" ]] && read -r -p "请输入导航页实例名称 (默认: sunpanel): " instance_name
    instance_name="${instance_name:-sunpanel}"
    
    local port
    get_free_port 3002; port=$?  # 自动获取可用端口，如果脚本有此函数请保留，没有则直接 local port=3002
    
    local app_dir="$BASE_DIR/$instance_name"
    header "正在初始化个人导航页 (Sun-Panel) 实例: $instance_name"
    
    mkdir -p "$app_dir/conf" "$app_dir/uploads" "$app_dir/database"

    cat <<EOF > "$app_dir/docker-compose.yml"
services:
  sunpanel:
    image: hslr/sun-panel:latest
    container_name: ${instance_name}
    volumes:
      - ./conf:/app/conf
      - ./uploads:/app/uploads
      - ./database:/app/database
    ports:
      - "${port}:3002"
    environment:
      - TZ=Asia/Shanghai
    restart: unless-stopped
    networks:
      - app_net

networks:
  app_net:
    name: ${instance_name}_net
EOF

    log "生成配置文件成功。"
    ensure_docker
    cd "$app_dir" && docker compose up -d
    log "Sun-Panel 部署成功！"
    info "内部访问地址: http://localhost:${port}"
}

# ==========================================
# 密码管理器 (Vaultwarden)
# ==========================================
deploy_vaultwarden() {
    local instance_name="${1:-}"
    [[ -z "$instance_name" ]] && read -r -p "请输入密码管理器实例名称 (默认: vaultwarden): " instance_name
    instance_name="${instance_name:-vaultwarden}"
    
    local port
    get_free_port 8099; port=$?
    
    local app_dir="$BASE_DIR/$instance_name"
    header "正在初始化密码管理器 (Vaultwarden) 实例: $instance_name"
    
    # 使用脚本原有的随机密码生成函数 randpw
    local admin_token
    admin_token=$(randpw 32 2>/dev/null || date +%s | sha256sum | base64 | head -c 32)
    
    mkdir -p "$app_dir/data"

    cat <<EOF > "$app_dir/docker-compose.yml"
services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: ${instance_name}
    environment:
      - TZ=Asia/Shanghai
      - WEBSOCKET_ENABLED=true
      - ADMIN_TOKEN=${admin_token}
    volumes:
      - ./data:/data
    ports:
      - "${port}:80"
    restart: unless-stopped
    networks:
      - app_net

networks:
  app_net:
    name: ${instance_name}_net
EOF

    log "生成配置文件成功。"
    ensure_docker
    cd "$app_dir" && docker compose up -d
    log "Vaultwarden 部署成功！"
    info "内部访问地址: http://localhost:${port}"
    warn "管理面板管理员 Token (建议保存以备后用): ${admin_token}"
}

# ==========================================
#  媒体服务器 (Emby Server)
# ==========================================
deploy_emby() {
    local instance_name="${1:-}"
    [[ -z "$instance_name" ]] && read -r -p "请输入 Emby 实例名称 (默认: emby): " instance_name
    instance_name="${instance_name:-emby}"
    
    local port
    get_free_port 8096; port=$?
    
    local app_dir="$BASE_DIR/$instance_name"
    header "正在初始化 Emby 媒体服务器 实例: $instance_name"
    
    mkdir -p "$app_dir/config" "$app_dir/media"

    cat <<EOF > "$app_dir/docker-compose.yml"
services:
  emby:
    image: amnetworks/embyserver:latest
    container_name: ${instance_name}
    environment:
      - PUID=$(id -u)
      - PGID=$(id -g)
      - TZ=Asia/Shanghai
    volumes:
      - ./config:/config
      - ./media:/data/movies
    ports:
      - "${port}:8096"
    restart: unless-stopped
    networks:
      - app_net

networks:
  app_net:
    name: ${instance_name}_net
EOF

    log "生成配置文件成功。"
    ensure_docker
    cd "$app_dir" && docker compose up -d
    log "Emby 部署成功！"
    info "内部访问地址: http://localhost:${port}"
    info "请将你的媒体文件放至该目录: ${app_dir}/media"
}

# ============================================================
# 10) 容器详情
# ============================================================
menu_container_info() {
    echo ""
    echo -e "${CYAN}${BOLD}── 容器详情 ──${NC}"
    local -a deployed_dirs=() deployed_labels=()
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
    read -rp "请输入编号（0 返回）: " input
    [[ "$input" == "0" ]] && return
    local idx=$((input - 1))
    [[ $idx -lt 0 || $idx -ge ${#deployed_dirs[@]} ]] && warn "编号无效" && return

    local dir="${deployed_dirs[$idx]}"
    header "容器详情：$(basename "$dir")"

    local cids
    mapfile -t cids < <(cd "$dir" && docker compose ps -q 2>/dev/null)
    if [[ ${#cids[@]} -eq 0 ]]; then warn "该实例无运行中的容器"; return; fi

    for cid in "${cids[@]}"; do
        local name image status health created started ip restart_policy pid
        name=$(docker inspect --format '{{.Name}}' "$cid" | sed 's|^/||')
        image=$(docker inspect --format '{{.Config.Image}}' "$cid")
        status=$(docker inspect --format '{{.State.Status}}' "$cid")
        health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}无健康检查{{end}}' "$cid")
        created=$(docker inspect --format '{{.Created}}' "$cid" | cut -c1-19 | tr 'T' ' ')
        started=$(docker inspect --format '{{.State.StartedAt}}' "$cid" | cut -c1-19 | tr 'T' ' ')
        ip=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$cid")
        restart_policy=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$cid")
        pid=$(docker inspect --format '{{.State.Pid}}' "$cid")

        echo ""
        echo -e "  ${BOLD}▸ 容器:${NC} $name"
        printf "    %-14s %s\n" "镜像:"        "$image"
        printf "    %-14s %s\n" "状态:"        "$status"
        printf "    %-14s %s\n" "健康检查:"    "$health"
        printf "    %-14s %s\n" "创建时间:"    "$created"
        printf "    %-14s %s\n" "启动时间:"    "$started"
        printf "    %-14s %s\n" "容器 IP:"     "${ip:-无}"
        printf "    %-14s %s\n" "重启策略:"    "$restart_policy"
        printf "    %-14s %s\n" "主进程 PID:"  "$pid"

        # 端口映射
        local ports
        ports=$(docker inspect --format '{{range $p,$b := .NetworkSettings.Ports}}{{if $b}}{{(index $b 0).HostIp}}:{{(index $b 0).HostPort}}->{{$p}} {{end}}{{end}}' "$cid")
        printf "    %-14s %s\n" "端口映射:" "${ports:-无}"

        # 挂载卷
        local mounts
        mounts=$(docker inspect --format '{{range .Mounts}}{{.Source}}→{{.Destination}} {{end}}' "$cid")
        if [[ -n "$mounts" ]]; then
            echo "    卷挂载:"
            for m in $mounts; do
                echo "      $m"
            done
        fi

        # 镜像构建信息
        local img_id img_size img_created
        img_id=$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null | cut -c8-19 || echo "未知")
        img_size=$(docker image inspect "$image" --format '{{.Size}}' 2>/dev/null | \
            awk '{if($1>=1073741824) printf "%.1f GB",($1/1073741824); else if($1>=1048576) printf "%.1f MB",($1/1048576); else printf "%d KB",($1/1024)}' || echo "未知")
        img_created=$(docker image inspect "$image" --format '{{.Created}}' 2>/dev/null | cut -c1-10 || echo "未知")
        printf "    %-14s %s  (%s, %s)\n" "镜像信息:" "$img_id" "$img_size" "$img_created"
    done
    echo ""
}

# ============================================================
# 11) 资源监控
# ============================================================
menu_resource_monitor() {
    echo ""; echo -e "${CYAN}${BOLD}── 资源监控 ──${NC}"; echo ""
    echo -e "  1) 全部容器资源快照  2) 实时监控指定实例  3) Docker 磁盘总览  0) 返回"
    echo ""; read -rp "请选择 [0-3]: " choice
    case "$choice" in
        1)
            header "全部容器资源快照"
            docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}'
            ;;
        2)
            local -a deployed_dirs=() deployed_labels=()
            for app in "${ALL_APPS[@]}"; do
                while IFS= read -r dir; do
                    deployed_dirs+=("$dir"); deployed_labels+=("$app  [$(inst_label "$dir" "$app")]")
                done < <(list_instances "$app")
            done
            [[ ${#deployed_dirs[@]} -eq 0 ]] && warn "没有已部署的应用" && return
            local i=1
            for lbl in "${deployed_labels[@]}"; do printf "  %2d) %s\n" "$i" "$lbl"; ((i++)); done
            echo ""; read -rp "请输入编号（0 返回）: " input
            [[ "$input" == "0" ]] && return
            local idx=$((input - 1))
            [[ $idx -lt 0 || $idx -ge ${#deployed_dirs[@]} ]] && warn "编号无效" && return
            local cids_str; cids_str=$(cd "${deployed_dirs[$idx]}" && docker compose ps -q 2>/dev/null | tr '\n' ' ')
            [[ -z "$cids_str" ]] && warn "该实例无运行容器" && return
            info "按 Ctrl+C 退出..."
            # shellcheck disable=SC2086
            docker stats --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}' $cids_str
            ;;
        3) docker system df -v 2>/dev/null || docker system df ;;
        0) return ;;
        *) warn "无效输入" ;;
    esac
}

# ============================================================
# 12) 查看应用日志
# ============================================================
menu_view_logs() {
    echo ""; echo -e "${CYAN}${BOLD}── 查看应用日志 ──${NC}"
    local -a deployed_dirs=() deployed_labels=()
    for app in "${ALL_APPS[@]}"; do
        while IFS= read -r dir; do
            deployed_dirs+=("$dir"); deployed_labels+=("$app  [$(inst_label "$dir" "$app")]")
        done < <(list_instances "$app")
    done
    [[ ${#deployed_dirs[@]} -eq 0 ]] && warn "没有已部署的应用" && return
    local i=1
    for lbl in "${deployed_labels[@]}"; do printf "  %2d) %s\n" "$i" "$lbl"; ((i++)); done
    echo ""; read -rp "请输入编号（0 返回）: " input
    [[ "$input" == "0" ]] && return
    local idx=$((input - 1))
    [[ $idx -lt 0 || $idx -ge ${#deployed_dirs[@]} ]] && warn "编号无效" && return
    local dir="${deployed_dirs[$idx]}"
    echo ""; echo -e "  1) 最近 100 行  2) 实时跟踪  3) 500 行导出到 /tmp"
    echo ""; read -rp "请选择 [1-3]: " log_choice
    case "$log_choice" in
        1) cd "$dir" && docker compose logs --tail=100 --timestamps 2>/dev/null; cd - > /dev/null ;;
        2) info "Ctrl+C 退出..."; cd "$dir" && docker compose logs -f --timestamps 2>/dev/null; cd - > /dev/null ;;
        3)
            local out="/tmp/$(basename "$dir")_logs_$(date +%Y%m%d_%H%M%S).log"
            cd "$dir" && docker compose logs --tail=500 --timestamps > "$out" 2>&1; cd - > /dev/null
            log "已导出到 $out（$(wc -l < "$out") 行）"
            ;;
        *) warn "无效输入" ;;
    esac
}

# ============================================================
# 13) 应用迁移
# ============================================================
menu_migrate_app() {
    echo ""; echo -e "${CYAN}${BOLD}── 应用迁移 ──${NC}"; echo ""
    echo -e "  1) 迁移到本地新路径  2) 迁移到远程服务器  0) 返回"
    echo ""; read -rp "请选择 [0-2]: " choice
    case "$choice" in 1) _migrate_local ;; 2) _migrate_remote ;; 0) return ;; *) warn "无效输入" ;; esac
}

_migrate_local() {
    local -a deployed_dirs=() deployed_labels=()
    for app in "${ALL_APPS[@]}"; do
        while IFS= read -r dir; do
            deployed_dirs+=("$dir"); deployed_labels+=("$app  [$(inst_label "$dir" "$app")]")
        done < <(list_instances "$app")
    done
    [[ ${#deployed_dirs[@]} -eq 0 ]] && warn "没有已部署的应用" && return
    local i=1
    for lbl in "${deployed_labels[@]}"; do printf "  %2d) %s\n" "$i" "$lbl"; ((i++)); done
    echo ""; read -rp "请输入要迁移的实例编号（0 返回）: " input
    [[ "$input" == "0" ]] && return
    local idx=$((input - 1))
    [[ $idx -lt 0 || $idx -ge ${#deployed_dirs[@]} ]] && warn "编号无效" && return
    local src_dir="${deployed_dirs[$idx]}"
    read -rp "目标路径: " dst_dir
    [[ -z "$dst_dir" || -d "$dst_dir" ]] && warn "路径无效或已存在" && return
    read -rp "确认迁移？[y/N]: " confirm
    [[ "${confirm,,}" != "y" ]] && return
    (cd "$src_dir" && docker compose stop 2>/dev/null) || warn "停止失败，继续..."
    mkdir -p "$(dirname "$dst_dir")"
    rsync -a --info=progress2 "$src_dir/" "$dst_dir/" || { cp -a "$src_dir" "$dst_dir" || error "复制失败"; }
    if (cd "$dst_dir" && docker compose up -d); then
        log "已在 $dst_dir 启动"
        read -rp "删除旧目录？[y/N]: " del
        if [[ "${del,,}" == "y" ]]; then
            (cd "$src_dir" && docker compose down 2>/dev/null) || true; rm -rf "$src_dir"; log "旧目录已删除"
        fi
    else
        warn "新路径启动失败，恢复旧实例..."
        (cd "$src_dir" && docker compose start 2>/dev/null) || warn "恢复失败"
    fi
}

_migrate_remote() {
    local -a deployed_dirs=() deployed_labels=() deployed_apps=()
    for app in "${ALL_APPS[@]}"; do
        while IFS= read -r dir; do
            deployed_dirs+=("$dir")
            deployed_labels+=("$app  [$(inst_label "$dir" "$app")]")
            deployed_apps+=("$app")
        done < <(list_instances "$app")
    done
    if [[ ${#deployed_dirs[@]} -eq 0 ]]; then warn "没有已部署的应用"; return; fi

    local i=1
    for lbl in "${deployed_labels[@]}"; do printf "  %2d) %s\n" "$i" "$lbl"; ((i++)); done
    echo ""
    read -rp "请输入要迁移的实例编号（0 返回）: " input
    [[ "$input" == "0" ]] && return
    local idx=$((input - 1))
    [[ $idx -lt 0 || $idx -ge ${#deployed_dirs[@]} ]] && warn "编号无效" && return
    local src_dir="${deployed_dirs[$idx]}"
    local app_type="${deployed_apps[$idx]}"

    echo ""
    read -rp "目标服务器（user@host，如 root@192.168.1.100）: " remote_host
    [[ -z "$remote_host" ]] && warn "不能为空" && return
    read -rp "目标路径 [默认 /opt/docker-apps/$(basename "$src_dir")]: " remote_path
    [[ -z "$remote_path" ]] && remote_path="/opt/docker-apps/$(basename "$src_dir")"
    read -rp "SSH 端口 [默认 22]: " ssh_port
    ssh_port="${ssh_port:-22}"

    # ── 检测该应用含有哪些数据库 ────────────────────────────────
    local has_mariadb=0 has_postgres=0 has_redis=0
    grep -q 'image: mariadb'    "$src_dir/docker-compose.yml" 2>/dev/null && has_mariadb=1
    grep -q 'image: mysql'      "$src_dir/docker-compose.yml" 2>/dev/null && has_mariadb=1
    grep -q 'image: postgres'   "$src_dir/docker-compose.yml" 2>/dev/null && has_postgres=1
    grep -q 'image: redis'      "$src_dir/docker-compose.yml" 2>/dev/null && has_redis=1

    echo ""
    echo -e "${CYAN}${BOLD}── 迁移内容预览：$(basename "$src_dir") ──${NC}"
    echo ""
    echo -e "  应用类型  : $app_type"
    echo -e "  源目录    : $src_dir"
    echo -e "  目标       : ${remote_host}:${remote_path}"
    echo ""
    echo -e "  将执行以下步骤："
    echo -e "    [1] SSH 连通性检查"
    echo -e "    [2] 确认目标机已安装 Docker"
    echo -e "    [3] 停止本地服务（保证数据一致性）"
    [[ $has_mariadb -eq 1 ]] && \
        echo -e "    [4] ${YELLOW}mysqldump 导出数据库${NC}（逻辑备份，跨机安全）"
    [[ $has_postgres -eq 1 ]] && \
        echo -e "    [4] ${YELLOW}pg_dumpall 导出数据库${NC}（逻辑备份，跨机安全）"
    echo -e "    [5] rsync 同步文件（配置 / 上传文件 / 静态资源）"
    [[ $has_mariadb -eq 1 || $has_postgres -eq 1 ]] && \
        echo -e "        ${YELLOW}跳过原始数据库文件目录（db/）—— 使用 SQL 导入替代${NC}"
    echo -e "    [6] 目标机拉取镜像并启动服务"
    [[ $has_mariadb -eq 1 || $has_postgres -eq 1 ]] && \
        echo -e "    [7] 等待数据库就绪后导入 SQL"
    echo ""
    read -rp "确认执行？[y/N]: " confirm
    [[ "${confirm,,}" != "y" ]] && { info "已取消"; return; }

    header "远程迁移：$(basename "$src_dir") → ${remote_host}:${remote_path}"

    # ── 步骤 1：确保密钥已就位 ──────────────────────────────────
    info "[1/7] 检查并配置 SSH 密钥登录..."
    ensure_ssh_key "$remote_host" "$ssh_port" \
        || error "SSH 密钥配置失败，迁移中止"

    local SSH_OPTS="-p ${ssh_port} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

    # ── 步骤 2：检查目标机 Docker ────────────────────────────────
    info "[2/7] 检查目标机 Docker..."
    if ! ssh $SSH_OPTS "$remote_host" "command -v docker &>/dev/null"; then
        warn "目标机未安装 Docker"
        read -rp "  是否尝试自动在目标机安装 Docker？[y/N]: " inst_docker
        if [[ "${inst_docker,,}" == "y" ]]; then
            ssh $SSH_OPTS "$remote_host" \
                "curl -fsSL https://get.docker.com | sh && systemctl enable --now docker" \
                || error "目标机 Docker 安装失败，请手动安装后重试"
            log "目标机 Docker 安装完成"
        else
            error "目标机无 Docker，迁移中止"
        fi
    else
        local remote_docker_ver
        remote_docker_ver=$(ssh $SSH_OPTS "$remote_host" \
            "docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown")
        log "目标机 Docker 版本：$remote_docker_ver"
    fi

    # ── 步骤 3：停止本地服务 ─────────────────────────────────────
    info "[3/7] 停止本地服务（确保数据一致性）..."
    if ! (cd "$src_dir" && docker compose stop 2>/dev/null); then
        warn "停止失败，数据可能不一致，继续..."
    else
        log "本地服务已停止"
    fi

    # ── 步骤 4：数据库逻辑导出 ──────────────────────────────────
    local sql_dump_file="" pg_dump_file=""

    if [[ $has_mariadb -eq 1 ]]; then
        info "[4/7] mysqldump 导出数据库..."
        local db_root_pw db_name
        db_root_pw=$(grep -oP '(?<=ROOT_PASSWORD=).+' "$src_dir/.env" 2>/dev/null | head -1 || true)
        local db_cid
        db_cid=$(cd "$src_dir" && docker compose ps -q db lskypro-db nextcloud-db wordpress-db 2>/dev/null \
            | head -1 || docker compose ps -q 2>/dev/null \
            | xargs -I{} docker inspect --format '{{.Name}} {{.Config.Image}}' {} \
            | grep mariadb | awk '{print $1}' | sed 's|^/||' | head -1)

        if [[ -z "$db_cid" ]]; then
            db_cid=$(docker ps --format '{{.Names}} {{.Image}}' \
                | grep mariadb | grep "$(basename "$src_dir")" | awk '{print $1}' | head -1)
        fi

        if [[ -n "$db_cid" ]]; then
            sql_dump_file="/tmp/$(basename "$src_dir")_db_$(date +%Y%m%d_%H%M%S).sql.gz"
            if [[ -n "$db_root_pw" ]]; then
                docker exec "$db_cid" \
                    mysqldump -uroot -p"${db_root_pw}" --all-databases \
                    --single-transaction --quick --triggers --routines --events \
                    2>/dev/null | gzip > "$sql_dump_file"
            else
                docker exec "$db_cid" \
                    mysqldump -uroot --all-databases \
                    --single-transaction --quick --triggers --routines --events \
                    2>/dev/null | gzip > "$sql_dump_file"
            fi
            local dump_size
            dump_size=$(du -h "$sql_dump_file" | cut -f1)
            log "数据库导出完成：$sql_dump_file（$dump_size）"
        else
            warn "未找到 MariaDB 容器，跳过数据库逻辑导出（将由 rsync 直接同步数据文件）"
            warn "注意：直接同步 MariaDB 数据文件到跨版本主机可能导致数据损坏"
        fi

    elif [[ $has_postgres -eq 1 ]]; then
        info "[4/7] pg_dumpall 导出 PostgreSQL..."
        local pg_cid
        pg_cid=$(cd "$src_dir" && docker compose ps -q db postgres gitea-db 2>/dev/null | head -1 || true)
        if [[ -n "$pg_cid" ]]; then
            pg_dump_file="/tmp/$(basename "$src_dir")_pgdb_$(date +%Y%m%d_%H%M%S).sql.gz"
            docker exec "$pg_cid" pg_dumpall -U postgres 2>/dev/null \
                | gzip > "$pg_dump_file"
            local dump_size
            dump_size=$(du -h "$pg_dump_file" | cut -f1)
            log "PostgreSQL 导出完成：$pg_dump_file（$dump_size）"
        else
            warn "未找到 PostgreSQL 容器，跳过逻辑导出"
        fi
    else
        info "[4/7] 无数据库服务，跳过"
    fi

    # ── 步骤 5：rsync 文件同步 ───────────────────────────────────
    info "[5/7] rsync 同步文件..."
    ssh $SSH_OPTS "$remote_host" "mkdir -p '$remote_path'" \
        || error "远程目录创建失败"

    local rsync_excludes=()
    if [[ -n "$sql_dump_file" || -n "$pg_dump_file" ]]; then
        rsync_excludes+=(
            "--exclude=db/"
            "--exclude=postgres/"
            "--exclude=pgdata/"
            "--exclude=database/"
        )
        info "  已排除数据库原始数据目录（将用 SQL 导入）"
    fi

    if rsync -az --info=progress2 -e "ssh ${SSH_OPTS}" \
        "${rsync_excludes[@]}" \
        "$src_dir/" "${remote_host}:${remote_path}/"; then
        log "文件同步完成"
    else
        warn "rsync 失败，正在恢复本地服务..."
        (cd "$src_dir" && docker compose start 2>/dev/null) || true
        return
    fi

    if [[ -n "$sql_dump_file" ]]; then
        info "  传输 SQL dump 到远程..."
        rsync -az -e "ssh ${SSH_OPTS}" \
            "$sql_dump_file" "${remote_host}:${remote_path}/_db_import.sql.gz" \
            && log "  SQL dump 已传输"
    fi
    if [[ -n "$pg_dump_file" ]]; then
        info "  传输 PostgreSQL dump 到远程..."
        rsync -az -e "ssh ${SSH_OPTS}" \
            "$pg_dump_file" "${remote_host}:${remote_path}/_pgdb_import.sql.gz" \
            && log "  PostgreSQL dump 已传输"
    fi

    # ── 步骤 6：目标机拉取镜像并启动 ────────────────────────────
    info "[6/7] 目标机启动服务..."
    if ! ssh $SSH_OPTS "$remote_host" \
        "cd '$remote_path' && docker compose pull && docker compose up -d 2>&1"; then
        warn "目标机启动失败，请登录排查："
        warn "  ssh ${SSH_OPTS} $remote_host 'cd $remote_path && docker compose logs'"
        return
    fi
    log "目标机服务已启动"

    # ── 步骤 7：数据库导入 ───────────────────────────────────────
    if [[ -n "$sql_dump_file" ]]; then
        info "[7/7] 等待目标机 MariaDB 就绪后导入..."
        local retry=0
        while [[ $retry -lt 20 ]]; do
            if ssh $SSH_OPTS "$remote_host" \
                "cd '$remote_path' && docker compose exec -T db \
                 mysqladmin ping -uroot --silent 2>/dev/null"; then
                break
            fi
            ((retry++)); sleep 3
            info "  等待数据库（${retry}/20）..."
        done

        local db_root_pw
        db_root_pw=$(grep -oP '(?<=ROOT_PASSWORD=).+' "$src_dir/.env" 2>/dev/null | head -1 || true)

        if ssh $SSH_OPTS "$remote_host" \
            "cd '$remote_path' && zcat _db_import.sql.gz \
             | docker compose exec -T db \
               mysql -uroot ${db_root_pw:+-p\"${db_root_pw}\"} 2>&1"; then
            log "数据库导入成功"
            ssh $SSH_OPTS "$remote_host" "rm -f '${remote_path}/_db_import.sql.gz'" || true
        else
            warn "数据库自动导入失败，SQL 文件保留在：${remote_host}:${remote_path}/_db_import.sql.gz"
            warn "请手动执行导入："
            warn "  ssh ${SSH_OPTS} $remote_host"
            warn "  cd $remote_path"
            warn "  zcat _db_import.sql.gz | docker compose exec -T db mysql -uroot -p'<密码>'"
        fi

    elif [[ -n "$pg_dump_file" ]]; then
        info "[7/7] 等待目标机 PostgreSQL 就绪后导入..."
        local retry=0
        while [[ $retry -lt 20 ]]; do
            if ssh $SSH_OPTS "$remote_host" \
                "cd '$remote_path' && docker compose exec -T db pg_isready -U postgres &>/dev/null"; then
                break
            fi
            ((retry++)); sleep 3
            info "  等待数据库（${retry}/20）..."
        done

        if ssh $SSH_OPTS "$remote_host" \
            "cd '$remote_path' && zcat _pgdb_import.sql.gz \
             | docker compose exec -T db psql -U postgres 2>&1"; then
            log "PostgreSQL 导入成功"
            ssh $SSH_OPTS "$remote_host" "rm -f '${remote_path}/_pgdb_import.sql.gz'" || true
        else
            warn "PostgreSQL 自动导入失败，dump 文件保留在：${remote_host}:${remote_path}/_pgdb_import.sql.gz"
        fi
    else
        info "[7/7] 无数据库导入步骤，跳过"
    fi

    # ── 完成汇总 ─────────────────────────────────────────────────
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗"
    echo -e "║                    迁移完成 — 操作汇总                      ║"
    echo -e "╠══════════════════════════════════════════════════════════════╣"
    printf  "║  %-60s║\n" "应用: $(basename "$src_dir") ($app_type)"
    printf  "║  %-60s║\n" "目标: ${remote_host}:${remote_path}"
    [[ -n "$sql_dump_file"  ]] && printf "║  %-60s║\n" "DB:   mysqldump 逻辑导出 + 远程导入"
    [[ -n "$pg_dump_file"   ]] && printf "║  %-60s║\n" "DB:   pg_dumpall 逻辑导出 + 远程导入"
    echo -e "╠══════════════════════════════════════════════════════════════╣"
    echo -e "║  验证步骤：                                                  ║"
    echo -e "║  1. 登录目标机，访问应用确认功能正常                        ║"
    echo -e "║  2. 检查用户数据、上传文件、数据库内容                      ║"
    echo -e "║  3. 确认无误后删除本地旧实例：                              ║"
    printf  "║     cd %-54s║\n" "$src_dir"
    echo -e "║     docker compose down -v && cd .. && rm -rf $(basename "$src_dir")   ║"
    echo -e "╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    read -rp "是否恢复本地实例继续运行？[y/N]: " resume_local
    if [[ "${resume_local,,}" == "y" ]]; then
        (cd "$src_dir" && docker compose start 2>/dev/null) \
            && log "本地实例已恢复运行" \
            || warn "本地实例恢复失败，请手动：cd $src_dir && docker compose up -d"
    else
        info "本地实例保持停止状态"
    fi
}

# ============================================================
# 14) 启动 / 停止 / 重启
# ============================================================
menu_start_stop_restart() {
    echo ""; echo -e "${CYAN}${BOLD}── 启动 / 停止 / 重启实例 ──${NC}"
    local -a deployed_dirs=() deployed_labels=()
    for app in "${ALL_APPS[@]}"; do
        while IFS= read -r dir; do
            deployed_dirs+=("$dir"); deployed_labels+=("$app  [$(inst_label "$dir" "$app")]")
        done < <(list_instances "$app")
    done
    [[ ${#deployed_dirs[@]} -eq 0 ]] && warn "没有已部署的应用" && return
    local i=1
    for lbl in "${deployed_labels[@]}"; do printf "  %2d) %s\n" "$i" "$lbl"; ((i++)); done
    echo ""; read -rp "请输入实例编号（0 返回）: " input
    [[ "$input" == "0" ]] && return
    local idx=$((input - 1))
    [[ $idx -lt 0 || $idx -ge ${#deployed_dirs[@]} ]] && warn "编号无效" && return
    local dir="${deployed_dirs[$idx]}"
    echo ""; echo -e "  1) 启动  2) 停止  3) 重启  4) 强制重建并启动"
    echo ""; read -rp "请选择 [1-4]: " op
    case "$op" in
        1) (cd "$dir" && docker compose start 2>/dev/null || docker compose up -d) && log "已启动" || warn "失败" ;;
        2) (cd "$dir" && docker compose stop) && log "已停止" || warn "失败" ;;
        3) (cd "$dir" && docker compose restart) && log "已重启" || warn "失败" ;;
        4) (cd "$dir" && docker compose up -d --force-recreate --remove-orphans) && log "已重建" || warn "失败" ;;
        *) warn "无效输入" ;;
    esac
}

# ============================================================
# 15) 清理 Docker 资源
# ============================================================
menu_cleanup_docker() {
    echo ""; echo -e "${CYAN}${BOLD}── 清理 Docker 资源 ──${NC}"; echo ""
    local dangling=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l)
    local stopped=$(docker ps -a -f "status=exited" -q 2>/dev/null | wc -l)
    local vols=$(docker volume ls -f "dangling=true" -q 2>/dev/null | wc -l)
    printf "    悬空镜像: %s 个  已停止容器: %s 个  未使用卷: %s 个\n" "$dangling" "$stopped" "$vols"
    echo ""
    echo -e "  1) 仅清理悬空镜像  2) 镜像+容器  3) 镜像+容器+卷  4) 全量清理（⚠️）  0) 返回"
    echo ""; read -rp "请选择 [0-4]: " choice
    case "$choice" in
        1) docker image prune -f; log "完成" ;;
        2) docker image prune -f; docker container prune -f; log "完成" ;;
        3) docker image prune -f; docker container prune -f; docker volume prune -f; log "完成" ;;
        4)
            warn "此操作删除所有未使用镜像和卷！"
            read -rp "确认？[y/N]: " c
            [[ "${c,,}" == "y" ]] && docker system prune -a --volumes -f && log "完成" || info "已取消"
            ;;
        0) return ;;
        *) warn "无效输入" ;;
    esac
    echo ""; docker system df
}

print_summary() {
    local apps=("$@")
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗"
    echo -e "║              🐳  部署完成 — 访问地址汇总                    ║"
    echo -e "╠══════════════════════════════════════════════════════════════╣"
    for app in "${apps[@]}"; do
        local port
        port=$(grep -oP '(?<=HOST_PORT=)\d+' "$BASE_DIR/$app/.env" 2>/dev/null | head -1) \
            || port="${APP_DEFAULT_PORT[$app]}"
        printf "║  %-16s → %-38s║\n" "$app" "http://127.0.0.1:${port}"
    done
    echo -e "╠══════════════════════════════════════════════════════════════╣"
    echo -e "║  凭据位置: /opt/docker-apps/<app>/.env                      ║"
    echo -e "║  备份位置: ${BACKUP_LOCAL_DIR}                  ║"
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
                local app="$2" inst_name="" host_port=""; shift 2
                while [[ $# -gt 0 ]]; do
                    case "$1" in --instance) inst_name="$2"; shift 2 ;; --port) host_port="$2"; shift 2 ;;
                    *) error "未知参数: $1" ;; esac
                done
                local inst_dir
                [[ -n "$inst_name" ]] && inst_dir="$BASE_DIR/${app}__${inst_name}" || inst_dir="$BASE_DIR/$app"
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
                    sunpanel)        deploy_sunpanel        "$inst_dir" "$host_port" ;;
                    vaultwarden)     deploy_vaultwarden     "$inst_dir" "$host_port" ;;
                    emby)            deploy_emby            "$inst_dir" "$host_port" ;;
                    *)               error "未知应用: $app" ;;
                esac; exit 0 ;;
            --uninstall) [[ -z "${2:-}" ]] && error "请指定目录"; uninstall_app "$2"; exit 0 ;;
            --backup)
                [[ -z "${2:-}" ]] && error "请指定目录"
                local bdir="$2" bremote="" bpath="/var/backups/docker-apps" bport="22" bmode="1"; shift 2
                while [[ $# -gt 0 ]]; do
                    case "$1" in --remote) bremote="$2"; shift 2; bmode="2" ;;
                    --remote-path) bpath="$2"; shift 2 ;; --remote-port) bport="$2"; shift 2 ;;
                    *) error "未知参数: $1" ;; esac
                done
                ensure_docker; backup_app "$bdir" "$bremote" "$bpath" "$bport" "$bmode"; exit 0 ;;
            --restore)
                if [[ "${2:-}" == "--remote" ]]; then
                    local rhost="${3:-}" rfile="${4:-}" rport="22"
                    [[ -z "$rhost" || -z "$rfile" ]] && error "用法: --restore --remote user@host /remote/file.tar.gz"
                    shift 4
                    while [[ $# -gt 0 ]]; do
                        case "$1" in --remote-port) rport="$2"; shift 2 ;; *) error "未知参数: $1" ;; esac
                    done
                    local SSH_OPTS="-p ${rport} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
                    ensure_docker; ensure_ssh_key "$rhost" "$rport" || error "SSH 失败"
                    local local_tmp="${BACKUP_LOCAL_DIR}/_restore_tmp_$(date +%Y%m%d_%H%M%S).tar.gz"
                    rsync -az -e "ssh ${SSH_OPTS}" "${rhost}:${rfile}" "$local_tmp" || error "拉取失败"
                    log "备份文件已拉取：$(du -h "$local_tmp" | cut -f1)"
                    restore_app "$local_tmp"
                    read -rp "删除本地临时文件？[y/N]: " dt
                    [[ "${dt,,}" == "y" ]] && rm -f "$local_tmp"
                else
                    [[ -z "${2:-}" ]] && error "请指定备份文件路径"
                    ensure_docker; restore_app "$2"
                fi; exit 0 ;;
            --update)     [[ -z "${2:-}" ]] && error "请指定目录"; ensure_docker; update_app_images "$2"; exit 0 ;;
            --update-all)
                ensure_docker; local updated=0
                for app in "${ALL_APPS[@]}"; do
                    while IFS= read -r dir; do update_app_images "$dir"; ((updated++)); done < <(list_instances "$app")
                done
                [[ $updated -eq 0 ]] && warn "没有已部署的应用"; exit 0 ;;
            --list)   list_apps; exit 0 ;;
            --all)    check_system; ensure_docker; deploy_all_apps; exit 0 ;;
            --info)
                [[ -z "${2:-}" ]] && error "请指定目录"; ensure_docker
                local dir="$2"; [[ ! -d "$dir" ]] && error "目录不存在"
                mapfile -t cids < <(cd "$dir" && docker compose ps -q 2>/dev/null)
                [[ ${#cids[@]} -eq 0 ]] && warn "无运行容器" && exit 0
                header "容器详情：$(basename "$dir")"
                for cid in "${cids[@]}"; do
                    docker inspect --format '容器: {{.Name}}{{"\n"}}镜像: {{.Config.Image}}{{"\n"}}状态: {{.State.Status}}' "$cid" | sed 's|^/||'
                done; exit 0 ;;
            --logs)   [[ -z "${2:-}" ]] && error "请指定目录"; ensure_docker; cd "$2" && docker compose logs --tail=100 --timestamps; exit 0 ;;
            --stats)  ensure_docker; docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}'; exit 0 ;;
            --cleanup)
                ensure_docker; docker image prune -f; docker container prune -f; docker volume prune -f
                log "清理完成"; docker system df; exit 0 ;;
            --stop)    [[ -z "${2:-}" ]] && error "请指定目录"; ensure_docker; cd "$2" && docker compose stop; exit 0 ;;
            --start)   [[ -z "${2:-}" ]] && error "请指定目录"; ensure_docker; cd "$2" && docker compose up -d; exit 0 ;;
            --restart) [[ -z "${2:-}" ]] && error "请指定目录"; ensure_docker; cd "$2" && docker compose restart; exit 0 ;;
            --help|-h) usage ;;
            *) error "未知选项: $1，使用 --help 查看帮助" ;;
        esac
    fi
    interactive_menu
}

main "$@"
