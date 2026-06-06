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

# ============================================================
# SSH 密钥检测与自动推送（供迁移等需要 SSH 的功能复用）
# 用法：ensure_ssh_key <user@host> <port>
# 返回：0 = 密钥已就位可免密登录；非0 = 失败
# ============================================================
ensure_ssh_key() {
    local remote_host="$1"
    local ssh_port="${2:-22}"
    local ssh_opts="-p ${ssh_port} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

    # ── 1. 先测试密钥是否已经可用 ───────────────────────────
    if ssh $ssh_opts -o BatchMode=yes "$remote_host" "echo ok" &>/dev/null; then
        log "密钥登录已可用：$remote_host"
        return 0
    fi

    info "未检测到可用密钥，将用密码完成一次性公钥推送"
    echo ""

    # ── 2. 找或生成本机公钥 ─────────────────────────────────
    local pubkey_file=""
    for f in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
        [[ -f "$f" ]] && pubkey_file="$f" && break
    done

    if [[ -z "$pubkey_file" ]]; then
        info "本机无 SSH 密钥，自动生成 ed25519 密钥对..."
        ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 \
            -C "docker-migrate-$(hostname)-$(date +%Y%m%d)" \
            || { warn "密钥生成失败"; return 1; }
        pubkey_file=~/.ssh/id_ed25519.pub
        log "密钥已生成：$pubkey_file"
    else
        info "使用现有公钥：$pubkey_file"
    fi

    local pubkey_content
    pubkey_content=$(cat "$pubkey_file")

    # ── 3. 需要 sshpass 来做一次性密码推送 ──────────────────
    if ! command -v sshpass &>/dev/null; then
        warn "需要安装 sshpass 来完成一次性密码推送..."
        if command -v apt-get &>/dev/null; then
            apt-get install -y -qq sshpass \
                || { warn "sshpass 安装失败，请手动安装后重试"; return 1; }
        else
            warn "请手动安装 sshpass 后重试"; return 1
        fi
    fi

    read -s -rp "输入 ${remote_host} 的密码（仅此一次）: " remote_pass
    echo ""
    echo ""

    # ── 4. 推送公钥 ─────────────────────────────────────────
    info "推送公钥到目标机..."
    export SSHPASS="${remote_pass}"
    if sshpass -e ssh $ssh_opts "$remote_host" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
         echo '${pubkey_content}' >> ~/.ssh/authorized_keys && \
         sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys && \
         chmod 600 ~/.ssh/authorized_keys"; then
        log "公钥推送成功"
    else
        unset SSHPASS
        warn "公钥推送失败（密码错误或目标机未开放密码登录）"
        return 1
    fi
    unset SSHPASS

    # ── 5. 验证密钥是否生效 ──────────────────────────────────
    info "验证密钥登录..."
    if ssh $ssh_opts -o BatchMode=yes "$remote_host" "echo ok" &>/dev/null; then
        log "密钥登录验证通过 ✓"
        echo ""
        info "下次连接此主机无需再输密码"
        info "如需关闭目标机密码登录（推荐），可执行："
        info "  ssh ${remote_host} \"sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config && systemctl restart sshd\""
        echo ""
        return 0
    else
        warn "密钥验证失败，请在目标机确认："
        warn "  /etc/ssh/sshd_config 中 PubkeyAuthentication yes"
        warn "  AuthorizedKeysFile .ssh/authorized_keys"
        warn "  执行 systemctl restart sshd 后重试"
        return 1
    fi
}

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
        echo -e "╠══════════════════════════════════════════════════════════════╣"
        echo -e "║  10) 容器详情（镜像/IP/卷/端口/健康）                        ║"
        echo -e "║  11) 资源监控（CPU/内存/网络）                                ║"
        echo -e "║  12) 查看应用日志                                             ║"
        echo -e "║  13) 应用迁移（本地路径 / 远程服务器）                       ║"
        echo -e "║  14) 启动 / 停止 / 重启实例                                  ║"
        echo -e "║  15) 清理 Docker 资源                                         ║"
        echo -e "║  0) 退出                                                      ║"
        echo -e "╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        read -rp "请选择操作 [0-15]: " choice

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
            0)  echo "再见！"; exit 0 ;;
            *)  warn "无效选项，请输入 0-15" ;;
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
  --info DIR               查看指定实例的容器详情
  --logs DIR               查看指定实例最近 100 行日志
  --stats                  查看全部容器资源快照（CPU/内存/网络）
  --cleanup                清理悬空镜像 + 已停止容器 + 未使用卷
  --start DIR              启动指定实例
  --stop DIR               停止指定实例
  --restart DIR            重启指定实例
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
  sudo bash $0 --info /opt/docker-apps/gitea      # 查看容器详情
  sudo bash $0 --logs /opt/docker-apps/wordpress  # 查看应用日志
  sudo bash $0 --stats                            # 查看资源占用
  sudo bash $0 --restart /opt/docker-apps/alist   # 重启实例
  sudo bash $0 --cleanup                          # 清理 Docker 资源
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

    # 获取所有容器 ID
    local cids
    mapfile -t cids < <(cd "$dir" && docker compose ps -q 2>/dev/null)
    if [[ ${#cids[@]} -eq 0 ]]; then warn "该实例无运行中的容器"; return; fi

    for cid in "${cids[@]}"; do
        local name image status created
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
    echo ""
    echo -e "${CYAN}${BOLD}── 资源监控 ──${NC}"
    echo ""
    echo -e "  1) 查看全部容器资源快照（一次性）"
    echo -e "  2) 实时监控指定实例（每 3 秒刷新，Ctrl+C 退出）"
    echo -e "  3) 查看 Docker 磁盘使用总览"
    echo -e "  0) 返回"
    echo ""
    read -rp "请选择 [0-3]: " choice

    case "$choice" in
        1)
            header "全部容器资源快照"
            echo ""
            # 表头
            printf "  %-30s %-10s %-18s %-18s %-18s\n" \
                "容器名" "状态" "CPU%" "内存使用" "网络 I/O"
            echo "  $(printf '─%.0s' {1..90})"
            docker stats --no-stream --format \
                '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}' \
                2>/dev/null | sort | while IFS=$'\t' read -r name cpu mem net blk; do
                printf "  %-30s %-10s %-18s %-18s %-18s\n" \
                    "${name:0:29}" "${cpu}" "${mem:0:17}" "${net:0:17}" "${blk:0:17}"
            done
            echo ""
            ;;
        2)
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
            local cids_str
            cids_str=$(cd "$dir" && docker compose ps -q 2>/dev/null | tr '\n' ' ')
            if [[ -z "$cids_str" ]]; then warn "该实例无运行容器"; return; fi
            info "按 Ctrl+C 退出实时监控..."
            # shellcheck disable=SC2086
            docker stats --format \
                'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}' \
                $cids_str
            ;;
        3)
            header "Docker 磁盘使用总览"
            docker system df -v 2>/dev/null || docker system df
            echo ""
            ;;
        0) return ;;
        *) warn "无效输入" ;;
    esac
}

# ============================================================
# 12) 查看应用日志
# ============================================================
menu_view_logs() {
    echo ""
    echo -e "${CYAN}${BOLD}── 查看应用日志 ──${NC}"
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
    echo ""
    echo -e "  1) 查看最近 100 行日志"
    echo -e "  2) 实时跟踪日志（Ctrl+C 退出）"
    echo -e "  3) 查看最近 500 行并导出到 /tmp"
    echo ""
    read -rp "请选择 [1-3]: " log_choice

    case "$log_choice" in
        1)
            cd "$dir" && docker compose logs --tail=100 --timestamps 2>/dev/null
            cd - > /dev/null
            ;;
        2)
            info "按 Ctrl+C 退出日志跟踪..."
            cd "$dir" && docker compose logs -f --timestamps 2>/dev/null
            cd - > /dev/null
            ;;
        3)
            local out_file="/tmp/$(basename "$dir")_logs_$(date +%Y%m%d_%H%M%S).log"
            cd "$dir" && docker compose logs --tail=500 --timestamps > "$out_file" 2>&1
            cd - > /dev/null
            log "日志已导出到 $out_file（$(wc -l < "$out_file") 行）"
            ;;
        *) warn "无效输入" ;;
    esac
}

# ============================================================
# 13) 应用迁移
# ============================================================
menu_migrate_app() {
    echo ""
    echo -e "${CYAN}${BOLD}── 应用迁移 ──${NC}"
    echo ""
    echo -e "  1) 迁移到本地新路径"
    echo -e "  2) 迁移到远程服务器（rsync + SSH）"
    echo -e "  0) 返回"
    echo ""
    read -rp "请选择 [0-2]: " choice

    case "$choice" in
        1) _migrate_local ;;
        2) _migrate_remote ;;
        0) return ;;
        *) warn "无效输入" ;;
    esac
}

_migrate_local() {
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
    read -rp "请输入要迁移的实例编号（0 返回）: " input
    [[ "$input" == "0" ]] && return
    local idx=$((input - 1))
    [[ $idx -lt 0 || $idx -ge ${#deployed_dirs[@]} ]] && warn "编号无效" && return
    local src_dir="${deployed_dirs[$idx]}"

    echo ""
    read -rp "请输入目标路径（如 /data/docker-apps/$(basename "$src_dir")）: " dst_dir
    [[ -z "$dst_dir" ]] && warn "目标路径不能为空" && return
    [[ -d "$dst_dir" ]] && warn "目标路径已存在，请选择新路径" && return

    echo ""
    warn "迁移步骤：停止容器 → 复制数据 → 在新目录启动 → 提示删除旧目录"
    read -rp "确认迁移 $(basename "$src_dir") → $dst_dir ？[y/N]: " confirm
    [[ "${confirm,,}" != "y" ]] && { info "已取消"; return; }

    header "迁移：$(basename "$src_dir") → $dst_dir"

    # 1. 停止
    info "停止服务..."
    (cd "$src_dir" && docker compose stop 2>/dev/null) || warn "停止失败，继续复制..."

    # 2. 复制
    info "复制数据（rsync）..."
    mkdir -p "$(dirname "$dst_dir")"
    if rsync -a --info=progress2 "$src_dir/" "$dst_dir/"; then
        log "数据复制完成"
    else
        warn "rsync 失败，尝试 cp..."
        cp -a "$src_dir" "$dst_dir" || { error "复制失败，迁移中止"; }
    fi

    # 3. 启动新路径
    info "在新路径启动服务..."
    if (cd "$dst_dir" && docker compose up -d); then
        log "服务已在 $dst_dir 启动成功"
        echo ""
        warn "旧目录 $src_dir 仍保留，确认新实例运行正常后可手动删除："
        warn "  rm -rf $src_dir"
        echo ""
        read -rp "现在自动删除旧目录？[y/N]: " del_confirm
        if [[ "${del_confirm,,}" == "y" ]]; then
            (cd "$src_dir" && docker compose down 2>/dev/null) || true
            rm -rf "$src_dir"
            log "旧目录已删除"
        fi
    else
        warn "新路径启动失败，正在恢复旧实例..."
        (cd "$src_dir" && docker compose start 2>/dev/null) || warn "旧实例恢复失败，请手动检查"
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

    # ── 步骤 1：确保密钥已就位（没有则自动用密码推送公钥）──
    info "[1/7] 检查并配置 SSH 密钥登录..."
    ensure_ssh_key "$remote_host" "$ssh_port" \
        || error "SSH 密钥配置失败，迁移中止"

    # 后续所有 ssh/rsync 统一使用此选项（密钥已就位，不再需要密码）
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
        # 从 .env 读取凭据
        local db_root_pw db_name
        db_root_pw=$(grep -oP '(?<=ROOT_PASSWORD=).+' "$src_dir/.env" 2>/dev/null | head -1 || true)
        # 找容器名（mariadb 服务）
        local db_cid
        db_cid=$(cd "$src_dir" && docker compose ps -q db lskypro-db nextcloud-db wordpress-db 2>/dev/null \
            | head -1 || docker compose ps -q 2>/dev/null \
            | xargs -I{} docker inspect --format '{{.Name}} {{.Config.Image}}' {} \
            | grep mariadb | awk '{print $1}' | sed 's|^/||' | head -1)

        if [[ -z "$db_cid" ]]; then
            # 最后尝试：找任意带 mariadb 镜像的运行容器
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
                # 无密码时尝试无 -p
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

    # ── 步骤 5：rsync 文件同步（排除数据库原始数据目录）────────
    info "[5/7] rsync 同步文件..."
    ssh $SSH_OPTS "$remote_host" "mkdir -p '$remote_path'" \
        || error "远程目录创建失败"

    # 构建排除规则：若已做逻辑导出，则排除原始 DB 数据目录
    local rsync_excludes=()
    if [[ -n "$sql_dump_file" || -n "$pg_dump_file" ]]; then
        # 常见数据库数据目录名
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

    # 如有 SQL dump，也传到远程
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

    # ── 步骤 6：目标机拉取镜像并启动 ───────────────────────────
    info "[6/7] 目标机启动服务（让 Docker 自行拉取镜像）..."
    if ! ssh $SSH_OPTS "$remote_host" \
        "cd '$remote_path' && docker compose pull && docker compose up -d 2>&1"; then
        warn "目标机启动失败，请登录排查："
        warn "  ssh ${SSH_OPTS} $remote_host 'cd $remote_path && docker compose logs'"
        return
    fi
    log "目标机服务已启动"

    # ── 步骤 7：数据库导入 ──────────────────────────────────────
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

    # ── 完成汇总 ────────────────────────────────────────────────
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

    # 恢复本地服务（迁移期间一直保持停止状态，现在视需要决定）
    echo ""
    read -rp "是否恢复本地实例继续运行（迁移期间已停止）？[y/N]: " resume_local
    if [[ "${resume_local,,}" == "y" ]]; then
        (cd "$src_dir" && docker compose start 2>/dev/null) \
            && log "本地实例已恢复运行" \
            || warn "本地实例恢复失败，请手动：cd $src_dir && docker compose up -d"
    else
        info "本地实例保持停止状态"
    fi
}

# ============================================================
# 14) 启动 / 停止 / 重启实例
# ============================================================
menu_start_stop_restart() {
    echo ""
    echo -e "${CYAN}${BOLD}── 启动 / 停止 / 重启实例 ──${NC}"
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
    read -rp "请输入实例编号（0 返回）: " input
    [[ "$input" == "0" ]] && return
    local idx=$((input - 1))
    [[ $idx -lt 0 || $idx -ge ${#deployed_dirs[@]} ]] && warn "编号无效" && return
    local dir="${deployed_dirs[$idx]}"

    echo ""
    echo -e "  1) 启动"
    echo -e "  2) 停止"
    echo -e "  3) 重启"
    echo -e "  4) 强制重建并启动（docker compose up -d --force-recreate）"
    echo ""
    read -rp "请选择 [1-4]: " op

    case "$op" in
        1)
            if (cd "$dir" && docker compose start 2>/dev/null || docker compose up -d); then
                log "$(basename "$dir") 已启动"
            else warn "启动失败"; fi
            ;;
        2)
            if (cd "$dir" && docker compose stop); then
                log "$(basename "$dir") 已停止"
            else warn "停止失败"; fi
            ;;
        3)
            if (cd "$dir" && docker compose restart); then
                log "$(basename "$dir") 已重启"
            else warn "重启失败"; fi
            ;;
        4)
            if (cd "$dir" && docker compose up -d --force-recreate --remove-orphans); then
                log "$(basename "$dir") 已强制重建并启动"
            else warn "重建失败"; fi
            ;;
        *) warn "无效输入" ;;
    esac
}

# ============================================================
# 15) 清理 Docker 资源
# ============================================================
menu_cleanup_docker() {
    echo ""
    echo -e "${CYAN}${BOLD}── 清理 Docker 资源 ──${NC}"
    echo ""

    # 先统计可清理量
    local dangling_imgs stopped_conts unused_vols unused_nets buildcache_size
    dangling_imgs=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l)
    stopped_conts=$(docker ps -a -f "status=exited" -q 2>/dev/null | wc -l)
    unused_vols=$(docker volume ls -f "dangling=true" -q 2>/dev/null | wc -l)
    unused_nets=$(docker network ls -q --filter "type=custom" 2>/dev/null | wc -l)
    buildcache_size=$(docker buildx du --verbose 2>/dev/null | tail -1 | grep -oP '[\d.]+\s*[KMGT]B' || echo "未知")

    echo -e "  当前可清理资源："
    printf "    悬空镜像 (dangling): %s 个\n" "$dangling_imgs"
    printf "    已停止容器:          %s 个\n" "$stopped_conts"
    printf "    未使用卷:            %s 个\n" "$unused_vols"
    printf "    Build 缓存:          %s\n"   "$buildcache_size"
    echo ""
    echo -e "  1) 仅清理悬空镜像"
    echo -e "  2) 清理悬空镜像 + 已停止容器"
    echo -e "  3) 清理悬空镜像 + 已停止容器 + 未使用卷"
    echo -e "  4) 全量清理（docker system prune -a --volumes，⚠️ 会删除所有未使用镜像）"
    echo -e "  0) 返回"
    echo ""
    read -rp "请选择 [0-4]: " choice

    case "$choice" in
        1)
            docker image prune -f
            log "悬空镜像清理完成"
            ;;
        2)
            docker image prune -f
            docker container prune -f
            log "悬空镜像 + 已停止容器清理完成"
            ;;
        3)
            docker image prune -f
            docker container prune -f
            docker volume prune -f
            log "悬空镜像 + 已停止容器 + 未使用卷清理完成"
            ;;
        4)
            echo ""
            warn "⚠️  此操作将删除所有未被容器引用的镜像、网络、卷，已停止容器也将被删除！"
            warn "    正在运行的应用容器不受影响，但其镜像也会被删除（下次启动将重新拉取）"
            read -rp "确认执行全量清理？[y/N]: " confirm
            if [[ "${confirm,,}" == "y" ]]; then
                docker system prune -a --volumes -f
                log "全量清理完成"
            else
                info "已取消"
            fi
            ;;
        0) return ;;
        *) warn "无效输入" ;;
    esac

    echo ""
    info "清理后磁盘使用："
    docker system df
    echo ""
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
            --info)
                [[ -z "${2:-}" ]] && error "请指定实例目录"
                # 直接调用详情逻辑（非交互，传入目录）
                ensure_docker
                dir="$2"
                [[ ! -d "$dir" ]] && error "目录 $dir 不存在"
                mapfile -t cids < <(cd "$dir" && docker compose ps -q 2>/dev/null)
                [[ ${#cids[@]} -eq 0 ]] && warn "该实例无运行容器" && exit 0
                header "容器详情：$(basename "$dir")"
                for cid in "${cids[@]}"; do
                    docker inspect --format '
容器: {{.Name}}
镜像: {{.Config.Image}}
状态: {{.State.Status}}
启动: {{.State.StartedAt}}
IP:   {{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}
' "$cid" | sed 's|^/||'
                done
                exit 0
                ;;
            --logs)
                [[ -z "${2:-}" ]] && error "请指定实例目录"
                ensure_docker
                cd "$2" && docker compose logs --tail=100 --timestamps
                exit 0
                ;;
            --stats)
                ensure_docker
                docker stats --no-stream --format \
                    'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}'
                exit 0
                ;;
            --cleanup)
                ensure_docker
                docker image prune -f
                docker container prune -f
                docker volume prune -f
                log "清理完成"
                docker system df
                exit 0
                ;;
            --stop)
                [[ -z "${2:-}" ]] && error "请指定实例目录"
                ensure_docker; cd "$2" && docker compose stop; exit 0
                ;;
            --start)
                [[ -z "${2:-}" ]] && error "请指定实例目录"
                ensure_docker; cd "$2" && docker compose up -d; exit 0
                ;;
            --restart)
                [[ -z "${2:-}" ]] && error "请指定实例目录"
                ensure_docker; cd "$2" && docker compose restart; exit 0
                ;;
            --help|-h) usage ;;
            *)        error "未知选项: $1，使用 --help 查看帮助" ;;
        esac
    fi
    interactive_menu
}

main "$@"
