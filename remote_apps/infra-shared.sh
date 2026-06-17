#!/usr/bin/env bash
# ============================================================
# infra-shared.sh — 共享 MariaDB + Redis（交互式小白版）
# ============================================================
set -euo pipefail

# ── 默认值 ──────────────────────────────────────────────────
DEFAULT_DIR="${BASE_DIR:-/srv}/infra"
WG_IFACE="${WG_IFACE:-wg0}"
MARIADB_PORT="${MARIADB_PORT:-3306}"
REDIS_PORT="${REDIS_PORT:-6379}"
MARIADB_IMAGE="${MARIADB_IMAGE:-mariadb:11}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"

# ── 颜色与界面输出 ──────────────────────────────────────────
_c() { printf "\e[${1}m${2}\e[0m\n"; }
log()    { _c "32" "[成功] $*"; }
info()   { _c "36" "[提示] $*"; }
warn()   { _c "33" "[警告] $*"; }
error()  { _c "31" "[错误] $*"; exit 1; }
header() { echo; _c "1;34" "=== $* ==="; }

randpw() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32; }

# ── 基础工具函数 ────────────────────────────────────────────
get_wg_ip() {
    local IP
    IP=$(ip addr show "${WG_IFACE}" 2>/dev/null \
        | awk '/inet /{gsub(/\/.*/, "", $2); print $2; exit}')
    [[ -n "$IP" ]] || error "无法获取 ${WG_IFACE} IP，请确认 WireGuard 已启动"
    echo "$IP"
}

load_env() {
    local DIR="$1"
    if [[ ! -f "$DIR/.env" ]]; then
        error "尚未部署或找不到配置文件: $DIR/.env"
    fi
    # shellcheck disable=SC1090
    set -a; source "$DIR/.env"; set +a
}

dc() {
    local DIR="$1"; shift
    docker compose -f "$DIR/docker-compose.yml" --env-file "$DIR/.env" "$@"
}

mariadb_exec() {
    local DIR="$1"; shift
    load_env "$DIR"
    dc "$DIR" exec -T db \
        mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" "$@"
}

wait_db_ready() {
    local DIR="$1"
    local RETRIES="${2:-20}"
    info "正在等待 MariaDB 启动就绪..."
    load_env "$DIR"
    while ! dc "$DIR" exec -T db \
            mariadb-admin -uroot -p"${MARIADB_ROOT_PASSWORD}" \
            ping --silent 2>/dev/null; do
        sleep 3
        (( RETRIES-- ))
        [[ $RETRIES -gt 0 ]] || error "MariaDB 启动超时，请检查日志"
    done
    log "MariaDB 已就绪！"
}

# ════════════════════════════════════════════════════════════
# 核心功能模块
# ════════════════════════════════════════════════════════════

cmd_deploy() {
    local DIR="$1"
    header "部署共享基础设施"
    [[ $EUID -eq 0 ]] || error "请使用 root 权限执行"

    ip link show "${WG_IFACE}" &>/dev/null || \
        error "${WG_IFACE} 接口不存在，请先启动 WireGuard"
    
    local WG_IP
    WG_IP=$(get_wg_ip)
    
    info "目标目录: ${DIR}"
    info "监听 IP: ${WG_IP}"

    mkdir -p "${DIR}"/{db,redis,backup}

    if [[ ! -f "${DIR}/.env" ]]; then
        local ROOT_PW DB_PW REDIS_PW
        ROOT_PW=$(randpw)
        DB_PW=$(randpw)
        REDIS_PW=$(randpw)

        cat > "${DIR}/.env" <<EOF
# 共享基础设施凭据
MARIADB_ROOT_PASSWORD=${ROOT_PW}
MARIADB_DATABASE=wordpress
MARIADB_USER=wpuser
MARIADB_PASSWORD=${DB_PW}
REDIS_PASSWORD=${REDIS_PW}
WG_IP=${WG_IP}
EOF
        chmod 600 "${DIR}/.env"
        log "已自动生成高强度随机密码"
    else
        warn ".env 已存在，将使用已有凭据（自动更新 IP）"
        sed -i "s|^WG_IP=.*|WG_IP=${WG_IP}|" "${DIR}/.env"
    fi

    load_env "${DIR}"

    # 写入配置文件
    mkdir -p "${DIR}/mariadb-conf" "${DIR}/redis-conf"
    
    cat > "${DIR}/mariadb-conf/custom.cnf" <<INI
[mysqld]
innodb_buffer_pool_size  = 512M
innodb_log_file_size     = 128M
innodb_flush_log_at_trx_commit = 2
max_connections          = 200
query_cache_type         = 0
character-set-server     = utf8mb4
collation-server         = utf8mb4_unicode_ci
bind-address             = ${WG_IP}
slow_query_log           = 1
slow_query_log_file      = /var/lib/mysql/slow.log
long_query_time          = 2
INI

    cat > "${DIR}/redis-conf/redis.conf" <<CONF
bind ${WG_IP} 127.0.0.1
port ${REDIS_PORT}
requirepass ${REDIS_PASSWORD}
save 900 1
save 300 10
save 60  10000
appendonly yes
appendfsync everysec
maxmemory 512mb
maxmemory-policy allkeys-lru
loglevel notice
logfile ""
CONF

    cat > "${DIR}/docker-compose.yml" <<YAML
services:
  db:
    image: ${MARIADB_IMAGE}
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: \${MARIADB_ROOT_PASSWORD}
      MARIADB_DATABASE:      \${MARIADB_DATABASE}
      MARIADB_USER:          \${MARIADB_USER}
      MARIADB_PASSWORD:      \${MARIADB_PASSWORD}
    volumes:
      - ./db:/var/lib/mysql
      - ./mariadb-conf/custom.cnf:/etc/mysql/conf.d/custom.cnf:ro
    ports:
      - "${WG_IP}:${MARIADB_PORT}:3306"
    network_mode: host
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s

  redis:
    image: ${REDIS_IMAGE}
    restart: unless-stopped
    volumes:
      - ./redis:/data
      - ./redis-conf/redis.conf:/etc/redis/redis.conf:ro
    command: redis-server /etc/redis/redis.conf
    ports:
      - "${WG_IP}:${REDIS_PORT}:6379"
    network_mode: host
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "\${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
YAML

    info "正在拉取镜像并启动服务..."
    dc "${DIR}" up -d
    wait_db_ready "${DIR}"

    # 授权 WG 网段
    local WG_SUBNET="${WG_IP%.*}.%"
    mariadb_exec "$DIR" <<SQL
GRANT ALL PRIVILEGES ON \`${MARIADB_DATABASE}\`.* TO '${MARIADB_USER}'@'${WG_SUBNET}' IDENTIFIED BY '${MARIADB_PASSWORD}';
FLUSH PRIVILEGES;
SQL
    
    log "部署成功！"
    _print_credentials "$DIR"
}

_print_credentials() {
    local DIR="$1"
    load_env "$DIR"
    echo ""
    _c "1;32" "┌─────────────────────────────────────────────┐"
    _c "1;32" "│           共享基础设施连接信息              │"
    _c "1;32" "├─────────────────────────────────────────────┤"
    printf "│  MariaDB 地址: %-29s│\n" "${WG_IP}:${MARIADB_PORT}"
    printf "│  默认库名: %-33s│\n" "${MARIADB_DATABASE}"
    printf "│  默认用户: %-33s│\n" "${MARIADB_USER}"
    printf "│  默认密码: %-33s│\n" "${MARIADB_PASSWORD}"
    _c "1;32" "├─────────────────────────────────────────────┤"
    printf "│  Redis 地址: %-31s│\n" "${WG_IP}:${REDIS_PORT}"
    printf "│  Redis 密码: %-31s│\n" "${REDIS_PASSWORD}"
    _c "1;32" "└─────────────────────────────────────────────┘"
    echo ""
}

cmd_add_db() {
    local DIR="$1"
    header "新建数据库与用户"
    
    read -rp "请输入数据库名: " DB_NAME
    [[ -z "$DB_NAME" ]] && { error "操作取消：数据库名不能为空"; }
    
    read -rp "请输入分配的用户名 [默认同数据库名]: " USER
    USER=${USER:-$DB_NAME}
    
    read -rp "请输入密码 [直接回车将自动生成强密码]: " PW
    PW=${PW:-$(randpw)}

    load_env "$DIR"
    mariadb_exec "$DIR" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${USER}'@'${WG_IP%.*}.%' IDENTIFIED BY '${PW}';
FLUSH PRIVILEGES;
SQL

    log "创建成功！"
    echo -e "数据库: \e[33m${DB_NAME}\e[0m"
    echo -e "用户名: \e[33m${USER}\e[0m"
    echo -e "密  码: \e[33m${PW}\e[0m"
}

cmd_list_db() {
    local DIR="$1"
    load_env "$DIR"
    header "当前数据库列表"
    mariadb_exec "$DIR" -e \
        "SELECT schema_name AS '业务库名' FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys');"
    
    header "当前用户列表"
    mariadb_exec "$DIR" -e \
        "SELECT user AS '用户名', host AS '允许来源' FROM mysql.db GROUP BY user, host;"
}

cmd_passwd() {
    local DIR="$1"
    header "修改用户密码"
    read -rp "请输入要修改密码的用户名: " USER
    [[ -z "$USER" ]] && return
    read -rp "请输入新密码: " NEW_PW
    [[ -z "$NEW_PW" ]] && return

    load_env "$DIR"
    mariadb_exec "$DIR" -e \
        "ALTER USER '${USER}'@'${WG_IP%.*}.%' IDENTIFIED BY '${NEW_PW}'; FLUSH PRIVILEGES;"
    log "用户 ${USER} 的密码已更新！"
}

cmd_del_db() {
    local DIR="$1"
    header "删除数据库与用户 (危险操作!)"
    read -rp "请输入要删除的【数据库名】: " DB_NAME
    [[ -z "$DB_NAME" ]] && return
    read -rp "请输入关联的【用户名】: " USER
    [[ -z "$USER" ]] && return

    warn "即将永久删除数据库 ${DB_NAME} 及其数据！此操作不可逆转！"
    read -rp "请再次输入数据库名 [${DB_NAME}] 以确认删除: " CONFIRM
    [[ "$CONFIRM" != "$DB_NAME" ]] && { info "确认失败，操作已取消"; return; }

    load_env "$DIR"
    mariadb_exec "$DIR" <<SQL
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
DROP USER IF EXISTS '${USER}'@'${WG_IP%.*}.%';
FLUSH PRIVILEGES;
SQL
    log "数据库 ${DB_NAME} 和用户 ${USER} 已彻底删除。"
}

cmd_status() {
    local DIR="$1"
    load_env "$DIR"
    header "服务运行状态"
    dc "$DIR" ps

    echo ""
    if dc "$DIR" exec -T db mariadb-admin -uroot -p"${MARIADB_ROOT_PASSWORD}" ping --silent 2>/dev/null; then
        log "MariaDB 状态正常"
    else
        warn "MariaDB 无响应"
    fi

    if dc "$DIR" exec -T redis redis-cli -a "${REDIS_PASSWORD}" ping 2>/dev/null | grep -q PONG; then
        log "Redis 状态正常"
    else
        warn "Redis 无响应"
    fi
}

cmd_backup() {
    local DIR="$1"
    local DEST="${DIR}/backup"
    local TS
    TS=$(date +%Y%m%d_%H%M%S)

    load_env "$DIR"
    mkdir -p "$DEST"
    header "正在备份数据库到 ${DEST}"

    local DBS
    DBS=$(mariadb_exec "$DIR" -sN -e \
        "SELECT schema_name FROM information_schema.schemata \
         WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys');")

    for DB in $DBS; do
        local OUT="${DEST}/${DB}_${TS}.sql.gz"
        info "正在备份: ${DB} ..."
        dc "$DIR" exec -T db \
            mariadb-dump -uroot -p"${MARIADB_ROOT_PASSWORD}" --single-transaction --routines --triggers "${DB}" \
            | gzip > "$OUT"
        log "完成: ${DB} (文件大小: $(du -sh "$OUT" | cut -f1))"
    done
    log "全部备份完毕！"
}

cmd_restore() {
    local DIR="$1"
    header "恢复数据库"
    local DEST="${DIR}/backup"
    info "备份目录 (${DEST}) 下的可用备份文件："
    ls -lh "${DEST}"/*.sql.gz 2>/dev/null | awk '{print $9}' || { warn "没有找到备份文件"; return; }
    
    echo ""
    read -rp "请输入要恢复的完整文件路径: " SQL_FILE
    [[ ! -f "$SQL_FILE" ]] && { error "找不到文件: ${SQL_FILE}"; }

    local DB_NAME
    DB_NAME=$(basename "$SQL_FILE" | sed 's/_[0-9]\{8\}_[0-9]\{6\}\.sql\.gz$//')
    
    warn "即将把数据覆盖到数据库: ${DB_NAME}"
    read -rp "确认执行恢复吗? (y/n) " CONFIRM
    [[ "${CONFIRM,,}" != "y" ]] && { info "操作已取消"; return; }

    load_env "$DIR"
    mariadb_exec "$DIR" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

    info "正在导入数据，请耐心等待..."
    zcat "$SQL_FILE" | dc "$DIR" exec -T db mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" "${DB_NAME}"
    log "数据库 ${DB_NAME} 恢复成功！"
}

# ════════════════════════════════════════════════════════════
# 交互式主菜单
# ════════════════════════════════════════════════════════════

interactive_menu() {
    local DIR="${DEFAULT_DIR}"
    
    while true; do
        echo ""
        _c "1;36" "========================================"
        _c "1;36" "   共享数据库与缓存管理 (小白向导版)"
        _c "1;36" "   当前工作目录: ${DIR}"
        _c "1;36" "========================================"
        echo -e "  \e[32m1.\e[0m 🚀 一键部署 MariaDB + Redis"
        echo -e "  \e[32m2.\e[0m 📊 查看服务运行状态"
        echo -e "  \e[32m3.\e[0m ➕ 新建数据库和用户"
        echo -e "  \e[32m4.\e[0m 📋 列出所有数据库和用户"
        echo -e "  \e[32m5.\e[0m 🔑 修改数据库用户密码"
        echo -e "  \e[32m6.\e[0m 💾 备份所有数据库"
        echo -e "  \e[32m7.\e[0m ⏳ 恢复单个数据库"
        echo -e "  \e[31m8.\e[0m 🗑️  删除数据库和用户 (危险)"
        echo -e "  \e[33m9.\e[0m 📜 查看实时服务日志"
        echo -e "  \e[33m10.\e[0m⚙️  启动 / 停止 服务"
        echo -e "  \e[35m0.\e[0m 🚪 退出脚本"
        echo "----------------------------------------"
        read -rp "请输入序号并回车: " CHOICE

        case "$CHOICE" in
            1)  cmd_deploy "$DIR" ;;
            2)  cmd_status "$DIR" ;;
            3)  cmd_add_db "$DIR" ;;
            4)  cmd_list_db "$DIR" ;;
            5)  cmd_passwd "$DIR" ;;
            6)  cmd_backup "$DIR" ;;
            7)  cmd_restore "$DIR" ;;
            8)  cmd_del_db "$DIR" ;;
            9)  
                read -rp "要查看哪个日志？(db/redis): " SVC
                [[ "$SVC" == "db" || "$SVC" == "redis" ]] && dc "$DIR" logs -f --tail=100 "$SVC"
                ;;
            10) 
                read -rp "1)启动服务  2)停止服务 : " ACT
                [[ "$ACT" == "1" ]] && { dc "$DIR" up -d; log "服务已启动"; }
                [[ "$ACT" == "2" ]] && { dc "$DIR" stop; log "服务已停止"; }
                ;;
            0)  info "退出管理工具，再见！"; exit 0 ;;
            *)  warn "无效输入，请重新选择" ;;
        esac
        
        echo ""
        read -rp "按回车键返回主菜单..."
        clear
    done
}

# ── 入口处理 ────────────────────────────────────────────────
# 支持通过参数直接调用（兼顾老模式），无参数则进入小白模式
if [[ $# -gt 0 ]]; then
    CMD="$1"; shift
    case "$CMD" in
        deploy)   cmd_deploy  "${1:-$DEFAULT_DIR}" ;;
        add-db)   cmd_add_db  "${1:-$DEFAULT_DIR}" ;; # 兼容老命令可能无法全静默，这里做了混编
        list-db)  cmd_list_db "${1:-$DEFAULT_DIR}" ;;
        status)   cmd_status  "${1:-$DEFAULT_DIR}" ;;
        *) error "交互式版本请直接运行脚本: bash $0" ;;
    esac
else
    clear
    interactive_menu
fi
