#!/usr/bin/env bash
# ============================================================
# infra-shared.sh — 共享 MariaDB + Redis（仅监听 WireGuard 网口）
#
# 用法：
#   bash infra-shared.sh <子命令> [参数...]
#
# 子命令：
#   deploy  [DIR] [WG_IP]   部署 MariaDB + Redis
#   add-db  [DIR] <DB> <USER> <PW>
#                           在运行中的 MariaDB 新建库和用户
#   del-db  [DIR] <DB> <USER>
#                           删除库和用户
#   list-db [DIR]           列出所有业务库和用户
#   passwd  [DIR] <USER> <NEW_PW>
#                           修改用户密码
#   status  [DIR]           显示运行状态
#   backup  [DIR] [DEST]    备份所有库到本地目录
#   restore [DIR] <SQL文件>  恢复单个库
#   stop    [DIR]           停止服务
#   start   [DIR]           启动服务
#   logs    [DIR] <db|redis> 查看日志
#
# 前置条件：
#   - WireGuard 已启动（wg0 接口存在）
#   - docker compose v2 已安装
#
# WG_IP 默认读取 wg0 接口当前地址，也可显式传入
# ============================================================
set -euo pipefail

# ── 默认值 ──────────────────────────────────────────────────
DEFAULT_DIR="${BASE_DIR:-/srv}/infra"
WG_IFACE="${WG_IFACE:-wg0}"
MARIADB_PORT="${MARIADB_PORT:-3306}"
REDIS_PORT="${REDIS_PORT:-6379}"
MARIADB_IMAGE="${MARIADB_IMAGE:-mariadb:11}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"

# ── 颜色输出 ────────────────────────────────────────────────
_c() { printf "\e[${1}m${2}\e[0m\n"; }
log()    { _c "32" "[OK]  $*"; }
info()   { _c "36" "[..] $*"; }
warn()   { _c "33" "[!!] $*"; }
error()  { _c "31" "[EE] $*"; exit 1; }
header() { echo; _c "1;34" "══ $* ══"; }

randpw() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32; }

# ── 获取 WireGuard 接口 IP ──────────────────────────────────
get_wg_ip() {
    local IP
    IP=$(ip addr show "${WG_IFACE}" 2>/dev/null \
        | awk '/inet /{gsub(/\/.*/, "", $2); print $2; exit}')
    [[ -n "$IP" ]] || error "无法获取 ${WG_IFACE} IP，请确认 WireGuard 已启动"
    echo "$IP"
}

# ── 读取 .env 中的变量 ──────────────────────────────────────
load_env() {
    local DIR="$1"
    [[ -f "$DIR/.env" ]] || error ".env 不存在: $DIR/.env"
    # shellcheck disable=SC1090
    set -a; source "$DIR/.env"; set +a
}

# ── compose 快捷执行 ────────────────────────────────────────
dc() {
    local DIR="$1"; shift
    docker compose -f "$DIR/docker-compose.yml" --env-file "$DIR/.env" "$@"
}

# ── MariaDB 执行 SQL ────────────────────────────────────────
mariadb_exec() {
    local DIR="$1"; shift
    load_env "$DIR"
    dc "$DIR" exec -T db \
        mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" "$@"
}

# ── 等待 MariaDB 就绪 ───────────────────────────────────────
wait_db_ready() {
    local DIR="$1"
    local RETRIES="${2:-20}"
    info "等待 MariaDB 就绪..."
    load_env "$DIR"
    while ! dc "$DIR" exec -T db \
            mariadb-admin -uroot -p"${MARIADB_ROOT_PASSWORD}" \
            ping --silent 2>/dev/null; do
        sleep 3
        (( RETRIES-- ))
        [[ $RETRIES -gt 0 ]] || error "MariaDB 启动超时"
    done
    log "MariaDB 就绪"
}

# ════════════════════════════════════════════════════════════
# deploy [DIR] [WG_IP]
# ════════════════════════════════════════════════════════════
cmd_deploy() {
    local DIR="${1:-$DEFAULT_DIR}"
    local WG_IP="${2:-$(get_wg_ip)}"

    header "部署共享基础设施 → ${DIR}  (监听 ${WG_IP})"
    [[ $EUID -eq 0 ]] || error "需要 root 权限"

    # WireGuard 接口必须存在
    ip link show "${WG_IFACE}" &>/dev/null || \
        error "${WG_IFACE} 接口不存在，请先启动 WireGuard"

    mkdir -p "${DIR}"/{db,redis,backup}

    # 生成随机密码（已有 .env 则跳过，避免覆盖）
    if [[ ! -f "${DIR}/.env" ]]; then
        local ROOT_PW DB_PW REDIS_PW
        ROOT_PW=$(randpw)
        DB_PW=$(randpw)
        REDIS_PW=$(randpw)

        cat > "${DIR}/.env" <<EOF
# 共享基础设施凭据 — 保密，分发给各 WordPress 节点
MARIADB_ROOT_PASSWORD=${ROOT_PW}
MARIADB_DATABASE=wordpress
MARIADB_USER=wpuser
MARIADB_PASSWORD=${DB_PW}
REDIS_PASSWORD=${REDIS_PW}
WG_IP=${WG_IP}
EOF
        chmod 600 "${DIR}/.env"
        log ".env 已生成: ${DIR}/.env"
    else
        warn ".env 已存在，跳过生成密码（使用已有凭据）"
        # 更新 WG_IP（接口 IP 可能变化）
        sed -i "s|^WG_IP=.*|WG_IP=${WG_IP}|" "${DIR}/.env"
    fi

    load_env "${DIR}"

    # ── MariaDB 配置 ──────────────────────────────────────
    mkdir -p "${DIR}/mariadb-conf"
    cat > "${DIR}/mariadb-conf/custom.cnf" <<INI
[mysqld]
# 性能
innodb_buffer_pool_size  = 512M
innodb_log_file_size     = 128M
innodb_flush_log_at_trx_commit = 2
max_connections          = 200
query_cache_type         = 0

# 字符集
character-set-server     = utf8mb4
collation-server         = utf8mb4_unicode_ci

# 只监听 WireGuard 接口
bind-address             = ${WG_IP}

# 慢查询日志
slow_query_log           = 1
slow_query_log_file      = /var/lib/mysql/slow.log
long_query_time          = 2
INI

    # ── Redis 配置 ────────────────────────────────────────
    mkdir -p "${DIR}/redis-conf"
    cat > "${DIR}/redis-conf/redis.conf" <<CONF
# 只监听 WireGuard 接口 + 本地回环
bind ${WG_IP} 127.0.0.1
port ${REDIS_PORT}

# 认证
requirepass ${REDIS_PASSWORD}

# 持久化
save 900 1
save 300 10
save 60  10000
appendonly yes
appendfsync everysec

# 内存
maxmemory 512mb
maxmemory-policy allkeys-lru

# 日志
loglevel notice
logfile ""
CONF

    # ── docker-compose.yml ────────────────────────────────
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
    # 只绑定 WireGuard 接口，公网不可见
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
    # 只绑定 WireGuard 接口
    ports:
      - "${WG_IP}:${REDIS_PORT}:6379"
    network_mode: host
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "\${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
YAML
    # 注：network_mode: host 让容器直接用宿主机网络栈，
    # bind-address 在配置文件里控制，不走 Docker NAT

    dc "${DIR}" up -d
    wait_db_ready "${DIR}"

    # 授权 WireGuard 网段远程访问
    _grant_wg_access "${DIR}" "${MARIADB_DATABASE}" "${MARIADB_USER}" "${MARIADB_PASSWORD}"

    log "共享基础设施部署完成"
    _print_credentials "${DIR}"
}

# ── 授权 WG 网段访问（内部使用）──────────────────────────────
_grant_wg_access() {
    local DIR="$1" DB="$2" USER="$3" PW="$4"
    load_env "$DIR"
    local WG_SUBNET="${WG_IP%.*}.%"
    mariadb_exec "$DIR" <<SQL
GRANT ALL PRIVILEGES ON \`${DB}\`.* TO '${USER}'@'${WG_SUBNET}' IDENTIFIED BY '${PW}';
FLUSH PRIVILEGES;
SQL
    log "已授权 ${USER}@${WG_SUBNET} 访问 ${DB}"
}

# ── 打印凭据摘要 ─────────────────────────────────────────────
_print_credentials() {
    local DIR="$1"
    load_env "$DIR"
    echo ""
    echo "┌─────────────────────────────────────────────┐"
    echo "│           共享基础设施连接信息                │"
    echo "├─────────────────────────────────────────────┤"
    printf "│  MariaDB  %-34s│\n" "${WG_IP}:${MARIADB_PORT}"
    printf "│    用户   %-34s│\n" "${MARIADB_USER} / ${MARIADB_PASSWORD}"
    printf "│    库名   %-34s│\n" "${MARIADB_DATABASE}"
    echo "├─────────────────────────────────────────────┤"
    printf "│  Redis    %-34s│\n" "${WG_IP}:${REDIS_PORT}"
    printf "│    密码   %-34s│\n" "${REDIS_PASSWORD}"
    echo "├─────────────────────────────────────────────┤"
    printf "│  凭据文件 %-34s│\n" "${DIR}/.env"
    echo "└─────────────────────────────────────────────┘"
    echo ""
    warn "请将 .env 安全传输到各 WordPress 节点（scp over WireGuard）"
    echo "  scp -i /etc/wireguard/keys/id_ed25519 ${DIR}/.env root@<节点WG_IP>:/srv/wordpress/.env-infra"
}

# ════════════════════════════════════════════════════════════
# add-db [DIR] <DB_NAME> <USER> [PASSWORD]
# ════════════════════════════════════════════════════════════
cmd_add_db() {
    local DIR="${1:-$DEFAULT_DIR}"
    local DB_NAME="${2:?用法: add-db [DIR] <DB名> <用户名> [密码]}"
    local USER="${3:?}"
    local PW="${4:-$(randpw)}"

    load_env "$DIR"
    header "新建数据库: ${DB_NAME} / 用户: ${USER}"

    mariadb_exec "$DIR" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${USER}'@'${WG_IP%.*}.%' IDENTIFIED BY '${PW}';
FLUSH PRIVILEGES;
SQL

    log "数据库 ${DB_NAME} 已创建"
    log "用户: ${USER}  密码: ${PW}"
    log "主机: ${WG_IP}:${MARIADB_PORT}"
}

# ════════════════════════════════════════════════════════════
# del-db [DIR] <DB_NAME> <USER>
# ════════════════════════════════════════════════════════════
cmd_del_db() {
    local DIR="${1:-$DEFAULT_DIR}"
    local DB_NAME="${2:?用法: del-db [DIR] <DB名> <用户名>}"
    local USER="${3:?}"

    load_env "$DIR"
    warn "即将删除数据库 ${DB_NAME} 和用户 ${USER}，此操作不可逆！"
    read -rp "确认删除? 输入库名确认: " CONFIRM
    [[ "$CONFIRM" == "$DB_NAME" ]] || { info "已取消"; return; }

    mariadb_exec "$DIR" <<SQL
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
DROP USER IF EXISTS '${USER}'@'${WG_IP%.*}.%';
FLUSH PRIVILEGES;
SQL
    log "数据库 ${DB_NAME} 和用户 ${USER} 已删除"
}

# ════════════════════════════════════════════════════════════
# list-db [DIR]
# ════════════════════════════════════════════════════════════
cmd_list_db() {
    local DIR="${1:-$DEFAULT_DIR}"
    load_env "$DIR"
    header "数据库列表"
    mariadb_exec "$DIR" -e \
        "SELECT schema_name AS '数据库', \
                default_character_set_name AS '字符集' \
         FROM information_schema.schemata \
         WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys');"
    echo ""
    header "用户列表"
    mariadb_exec "$DIR" -e \
        "SELECT user AS '用户', host AS '来源', \
                GROUP_CONCAT(DISTINCT db) AS '可访问库' \
         FROM mysql.db GROUP BY user, host;"
}

# ════════════════════════════════════════════════════════════
# passwd [DIR] <USER> <NEW_PW>
# ════════════════════════════════════════════════════════════
cmd_passwd() {
    local DIR="${1:-$DEFAULT_DIR}"
    local USER="${2:?用法: passwd [DIR] <用户名> <新密码>}"
    local NEW_PW="${3:?}"

    load_env "$DIR"
    mariadb_exec "$DIR" -e \
        "ALTER USER '${USER}'@'${WG_IP%.*}.%' IDENTIFIED BY '${NEW_PW}'; FLUSH PRIVILEGES;"
    log "用户 ${USER} 密码已更新"
}

# ════════════════════════════════════════════════════════════
# backup [DIR] [DEST]
# ════════════════════════════════════════════════════════════
cmd_backup() {
    local DIR="${1:-$DEFAULT_DIR}"
    local DEST="${2:-${DIR}/backup}"
    local TS
    TS=$(date +%Y%m%d_%H%M%S)

    load_env "$DIR"
    mkdir -p "$DEST"
    header "备份所有数据库 → ${DEST}"

    # 获取所有业务库列表
    local DBS
    DBS=$(mariadb_exec "$DIR" -sN -e \
        "SELECT schema_name FROM information_schema.schemata \
         WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys');")

    for DB in $DBS; do
        local OUT="${DEST}/${DB}_${TS}.sql.gz"
        info "备份 ${DB} → ${OUT}"
        dc "$DIR" exec -T db \
            mariadb-dump \
                -uroot -p"${MARIADB_ROOT_PASSWORD}" \
                --single-transaction \
                --routines \
                --triggers \
                "${DB}" \
            | gzip > "$OUT"
        log "✓ ${DB} ($(du -sh "$OUT" | cut -f1))"
    done

    log "备份完成: ${DEST}"
}

# ════════════════════════════════════════════════════════════
# restore [DIR] <SQL文件>
# ════════════════════════════════════════════════════════════
cmd_restore() {
    local DIR="${1:-$DEFAULT_DIR}"
    local SQL_FILE="${2:?用法: restore [DIR] <SQL文件(.sql 或 .sql.gz)>}"

    load_env "$DIR"
    [[ -f "$SQL_FILE" ]] || error "文件不存在: ${SQL_FILE}"

    # 从文件名推断库名（去掉 _时间戳.sql.gz 后缀）
    local DB_NAME
    DB_NAME=$(basename "$SQL_FILE" | sed 's/_[0-9]\{8\}_[0-9]\{6\}\.sql\.gz$//' | sed 's/\.sql\.gz$//' | sed 's/\.sql$//')
    warn "将恢复到库: ${DB_NAME}"
    read -rp "确认? [y/N] " CONFIRM
    [[ "${CONFIRM,,}" == "y" ]] || { info "已取消"; return; }

    mariadb_exec "$DIR" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

    if [[ "$SQL_FILE" == *.gz ]]; then
        zcat "$SQL_FILE" | dc "$DIR" exec -T db \
            mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" "${DB_NAME}"
    else
        dc "$DIR" exec -T db \
            mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" "${DB_NAME}" < "$SQL_FILE"
    fi

    log "恢复完成: ${DB_NAME}"
}

# ════════════════════════════════════════════════════════════
# status [DIR]
# ════════════════════════════════════════════════════════════
cmd_status() {
    local DIR="${1:-$DEFAULT_DIR}"
    load_env "$DIR"
    header "服务状态"

    dc "$DIR" ps

    echo ""
    header "MariaDB 连通性"
    if dc "$DIR" exec -T db \
            mariadb-admin -uroot -p"${MARIADB_ROOT_PASSWORD}" ping --silent 2>/dev/null; then
        log "✓ MariaDB 响应正常"
        mariadb_exec "$DIR" -e "SHOW STATUS LIKE 'Threads_connected';"
    else
        warn "✗ MariaDB 无响应"
    fi

    echo ""
    header "Redis 连通性"
    if dc "$DIR" exec -T redis \
            redis-cli -a "${REDIS_PASSWORD}" ping 2>/dev/null | grep -q PONG; then
        log "✓ Redis 响应正常"
        dc "$DIR" exec -T redis \
            redis-cli -a "${REDIS_PASSWORD}" info server 2>/dev/null \
            | grep -E "redis_version|used_memory_human|connected_clients"
    else
        warn "✗ Redis 无响应"
    fi
}

# ════════════════════════════════════════════════════════════
# stop / start / logs
# ════════════════════════════════════════════════════════════
cmd_stop()  { dc "${1:-$DEFAULT_DIR}" stop; }
cmd_start() { dc "${1:-$DEFAULT_DIR}" up -d; }
cmd_logs()  {
    local DIR="${1:-$DEFAULT_DIR}"
    local SVC="${2:?用法: logs [DIR] <db|redis>}"
    dc "$DIR" logs -f --tail=100 "$SVC"
}

# ════════════════════════════════════════════════════════════
# 交互菜单
# ════════════════════════════════════════════════════════════

# ── 按回车继续 ───────────────────────────────────────────────
_pause() { echo; read -rp "  按 Enter 返回菜单..." _; }

# ── 提示输入，支持默认值 ─────────────────────────────────────
_ask() {
    local PROMPT="$1" VAR="$2" DEFAULT="${3:-}"
    local HINT=""
    [[ -n "$DEFAULT" ]] && HINT=" [默认: ${DEFAULT}]"
    read -rp "  ${PROMPT}${HINT}: " "$VAR"
    # 若用户直接回车则使用默认值
    if [[ -z "${!VAR}" && -n "$DEFAULT" ]]; then
        printf -v "$VAR" '%s' "$DEFAULT"
    fi
}

# ── 菜单标题 ─────────────────────────────────────────────────
_menu_header() {
    clear
    echo
    _c "1;34" "╔══════════════════════════════════════════════════╗"
    _c "1;34" "║      infra-shared  —  共享 MariaDB + Redis       ║"
    _c "1;34" "╚══════════════════════════════════════════════════╝"
    echo
}

# ── 主菜单 ───────────────────────────────────────────────────
menu_main() {
    while true; do
        _menu_header
        echo "  1)  部署共享基础设施（MariaDB + Redis）"
        echo "  2)  查看服务状态"
        echo "  3)  启动服务"
        echo "  4)  停止服务"
        echo "  ─────────────────────────────────────────"
        echo "  5)  数据库管理 ▶"
        echo "  6)  备份 / 恢复 ▶"
        echo "  7)  查看日志"
        echo "  ─────────────────────────────────────────"
        echo "  0)  退出"
        echo
        read -rp "  请选择 [0-7]: " CHOICE
        case "$CHOICE" in
            1) menu_deploy   ;;
            2) menu_status   ;;
            3) menu_start    ;;
            4) menu_stop     ;;
            5) menu_db       ;;
            6) menu_backup   ;;
            7) menu_logs     ;;
            0) echo; info "再见！"; exit 0 ;;
            *) warn "无效选项，请重新输入" ; sleep 1 ;;
        esac
    done
}

# ── 部署 ─────────────────────────────────────────────────────
menu_deploy() {
    _menu_header
    _c "1;33" "  ▶ 部署共享基础设施"
    echo
    _ask "部署目录" DIR "$DEFAULT_DIR"
    local AUTO_IP; AUTO_IP=$(get_wg_ip 2>/dev/null || echo "")
    _ask "WireGuard IP（留空自动检测）" WG_IP "${AUTO_IP}"
    echo
    warn "即将部署到 ${DIR}，WireGuard IP: ${WG_IP}"
    read -rp "  确认继续? [y/N] " C
    [[ "${C,,}" == "y" ]] || { info "已取消"; _pause; return; }
    echo
    cmd_deploy "$DIR" "$WG_IP"
    _pause
}

# ── 状态 ─────────────────────────────────────────────────────
menu_status() {
    _menu_header
    _ask "部署目录" DIR "$DEFAULT_DIR"
    echo
    cmd_status "$DIR"
    _pause
}

# ── 启动 ─────────────────────────────────────────────────────
menu_start() {
    _menu_header
    _ask "部署目录" DIR "$DEFAULT_DIR"
    echo
    cmd_start "$DIR"
    _pause
}

# ── 停止 ─────────────────────────────────────────────────────
menu_stop() {
    _menu_header
    _ask "部署目录" DIR "$DEFAULT_DIR"
    echo
    warn "即将停止 ${DIR} 下的所有服务"
    read -rp "  确认? [y/N] " C
    [[ "${C,,}" == "y" ]] || { info "已取消"; _pause; return; }
    cmd_stop "$DIR"
    _pause
}

# ── 日志 ─────────────────────────────────────────────────────
menu_logs() {
    _menu_header
    _c "1;33" "  ▶ 查看日志"
    echo
    _ask "部署目录" DIR "$DEFAULT_DIR"
    echo "  1) MariaDB 日志"
    echo "  2) Redis 日志"
    echo
    read -rp "  请选择 [1-2]: " C
    local SVC
    case "$C" in
        1) SVC="db"    ;;
        2) SVC="redis" ;;
        *) warn "无效选项"; _pause; return ;;
    esac
    info "Ctrl+C 退出日志查看"
    echo
    cmd_logs "$DIR" "$SVC" || true
    _pause
}

# ── 数据库子菜单 ─────────────────────────────────────────────
menu_db() {
    while true; do
        _menu_header
        _c "1;33" "  ▶ 数据库管理"
        echo
        echo "  1)  新建数据库和用户"
        echo "  2)  删除数据库和用户"
        echo "  3)  列出所有数据库 / 用户"
        echo "  4)  修改用户密码"
        echo "  0)  ← 返回上级"
        echo
        read -rp "  请选择 [0-4]: " C
        case "$C" in
            1) menu_db_add    ;;
            2) menu_db_del    ;;
            3) menu_db_list   ;;
            4) menu_db_passwd ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

menu_db_add() {
    _menu_header
    _c "1;33" "  ▶ 新建数据库和用户"
    echo
    _ask "部署目录" DIR "$DEFAULT_DIR"
    _ask "数据库名称" DB_NAME ""
    [[ -n "$DB_NAME" ]] || { warn "数据库名不能为空"; _pause; return; }
    _ask "用户名" DB_USER ""
    [[ -n "$DB_USER" ]] || { warn "用户名不能为空"; _pause; return; }
    local AUTO_PW; AUTO_PW=$(randpw)
    _ask "密码" DB_PW "$AUTO_PW"
    echo
    cmd_add_db "$DIR" "$DB_NAME" "$DB_USER" "$DB_PW"
    _pause
}

menu_db_del() {
    _menu_header
    _c "1;33" "  ▶ 删除数据库和用户"
    echo
    _ask "部署目录" DIR "$DEFAULT_DIR"
    # 先列出现有库方便参考
    info "当前数据库列表："
    cmd_list_db "$DIR" 2>/dev/null || true
    echo
    _ask "要删除的数据库名" DB_NAME ""
    _ask "要删除的用户名"   DB_USER ""
    [[ -n "$DB_NAME" && -n "$DB_USER" ]] || { warn "名称不能为空"; _pause; return; }
    echo
    cmd_del_db "$DIR" "$DB_NAME" "$DB_USER"
    _pause
}

menu_db_list() {
    _menu_header
    _ask "部署目录" DIR "$DEFAULT_DIR"
    echo
    cmd_list_db "$DIR"
    _pause
}

menu_db_passwd() {
    _menu_header
    _c "1;33" "  ▶ 修改用户密码"
    echo
    _ask "部署目录" DIR "$DEFAULT_DIR"
    _ask "用户名"   DB_USER ""
    _ask "新密码（留空自动生成）" NEW_PW "$(randpw)"
    [[ -n "$DB_USER" ]] || { warn "用户名不能为空"; _pause; return; }
    echo
    cmd_passwd "$DIR" "$DB_USER" "$NEW_PW"
    _pause
}

# ── 备份 / 恢复子菜单 ────────────────────────────────────────
menu_backup() {
    while true; do
        _menu_header
        _c "1;33" "  ▶ 备份 / 恢复"
        echo
        echo "  1)  备份所有数据库"
        echo "  2)  恢复单个库（从 .sql/.sql.gz 文件）"
        echo "  0)  ← 返回上级"
        echo
        read -rp "  请选择 [0-2]: " C
        case "$C" in
            1) menu_backup_run    ;;
            2) menu_restore_run   ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

menu_backup_run() {
    _menu_header
    _c "1;33" "  ▶ 备份所有数据库"
    echo
    _ask "部署目录" DIR "$DEFAULT_DIR"
    _ask "备份输出目录" DEST "${DIR}/backup"
    echo
    cmd_backup "$DIR" "$DEST"
    _pause
}

menu_restore_run() {
    _menu_header
    _c "1;33" "  ▶ 恢复数据库"
    echo
    _ask "部署目录" DIR "$DEFAULT_DIR"
    _ask "SQL 文件路径（.sql 或 .sql.gz）" SQL_FILE ""
    [[ -n "$SQL_FILE" ]] || { warn "路径不能为空"; _pause; return; }
    echo
    cmd_restore "$DIR" "$SQL_FILE"
    _pause
}

# ── 入口 ────────────────────────────────────────────────────
main() {
    # 无参数 → 交互菜单
    if [[ $# -eq 0 ]]; then
        menu_main
        return
    fi

    local CMD="$1"
    shift

    case "$CMD" in
        deploy)   cmd_deploy  "$@" ;;
        add-db)   cmd_add_db  "$@" ;;
        del-db)   cmd_del_db  "$@" ;;
        list-db)  cmd_list_db "$@" ;;
        passwd)   cmd_passwd  "$@" ;;
        backup)   cmd_backup  "$@" ;;
        restore)  cmd_restore "$@" ;;
        status)   cmd_status  "$@" ;;
        stop)     cmd_stop    "$@" ;;
        start)    cmd_start   "$@" ;;
        logs)     cmd_logs    "$@" ;;
        help|--help|-h)
            grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,2\}//'
            ;;
        *) error "未知子命令: ${CMD}，执行 help 查看用法" ;;
    esac
}

main "$@"