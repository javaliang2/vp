#!/usr/bin/env bash
# ============================================================
# pg-redis-shared.sh — 共享 PostgreSQL 18 + Redis（仅监听 WireGuard 网口）
#
# 用法:
#   ./pg-redis-shared.sh                            # 交互菜单
#   ./pg-redis-shared.sh deploy  [DIR] [WG_IP] [db|redis|all]
#   ./pg-redis-shared.sh update  [DIR] [db|redis|all]
#   ./pg-redis-shared.sh add-db  [DIR] <DB> <USER> [PW]
#   ./pg-redis-shared.sh del-db  [DIR] <DB> <USER>
#   ./pg-redis-shared.sh clear-db [DIR] <DB>
#   ./pg-redis-shared.sh list-db [DIR]
#   ./pg-redis-shared.sh passwd  [DIR] <USER> [NEW_PW]
#   ./pg-redis-shared.sh backup  [DIR] [DEST] [--rsync] [--alist] [--encrypt]  # 全量备份（.env+配置+pg_dumpall+Redis数据 → 单个 tar.gz，--encrypt 额外加密）
#   ./pg-redis-shared.sh restore [DIR] <备份tar.gz[.enc]|rsync://user@host[:port]/path/file|alist:///path/file> [解密密钥]  # 全量恢复
#   ./pg-redis-shared.sh tune-db    [DIR]               # 查看/调整 PostgreSQL 性能参数
#   ./pg-redis-shared.sh tune-redis [DIR]               # 查看/调整 Redis 性能参数
#   ./pg-redis-shared.sh rsync-config [DIR]             # 配置/查看远端 rsync 参数
#   ./pg-redis-shared.sh alist-config [DIR]             # 配置/测试 AList 连接
#   ./pg-redis-shared.sh status  [DIR]
#   ./pg-redis-shared.sh start   [DIR] [db|redis]
#   ./pg-redis-shared.sh stop    [DIR] [db|redis]
#   ./pg-redis-shared.sh logs    [DIR] <db|redis>
#   ./pg-redis-shared.sh help
#
# 与 MariaDB 版本(infra-shared.sh)的关键差异：
#   - PostgreSQL 角色(role)是集群全局的，不像 MariaDB 那样 'user'@'host' 按来源
#     主机分别建号。网络级访问控制改由 pg_hba.conf 按 WireGuard/Docker 网段限制，
#     换机后只需重写 pg_hba.conf + reload，无需逐个账号重新授权。
#   - 全量备份/恢复用 pg_dumpall（含角色+全部库），而非 mysqldump --all-databases。
# ============================================================
set -euo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# ── 默认值 ──────────────────────────────────────────────────
DEFAULT_DIR="${BASE_DIR:-/srv}/pg-infra"
WG_IFACE="${WG_IFACE:-wg0}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
REDIS_PORT="${REDIS_PORT:-6379}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:18-alpine}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"

# ── 输出 ────────────────────────────────────────────────────
_c()     { printf "\033[%sm%s\033[0m\n" "$1" "$2"; }
log()    { _c "32"   "[OK]  $*"; }
info()   { _c "36"   "[..]  $*"; }
warn()   { _c "33"   "[!!]  $*"; }
error()  { _c "31"   "[EE]  $*"; exit 1; }
header() { echo; _c "1;34" "══ $* ══"; }

# ── 临时目录兜底清理 ──────────────────────────────────────────
_TMP_DIRS=()
_register_tmp() { [[ -n "$1" ]] && _TMP_DIRS+=("$1"); }
_cleanup_tmp() {
    local d
    for d in "${_TMP_DIRS[@]:-}"; do
        [[ -n "$d" && ( -d "$d" || -f "$d" ) ]] && rm -rf "$d" 2>/dev/null
    done
}
trap _cleanup_tmp EXIT

# ── 菜单安全调用包装 ─────────────────────────────────────────
_menu_run() {
    local _exit_code=0
    (
        set -euo pipefail
        "$@"
    ) || _exit_code=$?
    return $_exit_code
}

# ── 工具函数 ─────────────────────────────────────────────────
randpw() {
    local p
    p=$(timeout 5 sh -c "LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32" 2>/dev/null) \
    || p=$(openssl rand -base64 48 | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 32)
    printf '%s' "$p"
}

get_wg_ip() {
    local ip
    ip=$(ip addr show "${WG_IFACE}" 2>/dev/null \
        | awk '/inet /{gsub(/\/.*/, "", $2); print $2; exit}')
    [[ -n "$ip" ]] || error "无法获取 ${WG_IFACE} IP，请确认 WireGuard 已启动"
    echo "$ip"
}

_check_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || error "IP 格式无效: '${ip}'"
    local IFS='.'; read -ra o <<< "$ip"
    for s in "${o[@]}"; do (( s <= 255 )) || error "IP 段超范围: '${ip}'"; done
}

_check_id()  {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]{0,63}$ ]] \
        || error "$2 只能以字母/下划线开头，含字母/数字/下划线，长度 1-64，实际: '$1'"
}

_check_pw() {
    # db_sql()/cmd_add_db() 等直接把密码拼进 SQL 字符串字面量，
    # 依赖这里禁止单引号和反斜杠来防止 SQL 注入。修改此校验前必须确认
    # 所有拼接点都已改为参数化/转义，否则会重新引入注入风险。
    [[ -n "$1" ]]      || error "$2 不能为空"
    [[ "$1" != *"'"* ]] || error "$2 不能含单引号"
    [[ "$1" != *"\\"* ]] || error "$2 不能含反斜杠"
    [[ ${#1} -ge 8 ]]  || error "$2 至少 8 个字符"
}

load_env() {
    [[ -f "$1/.env" ]] || error ".env 不存在: $1/.env"
    chmod 600 "$1/.env" 2>/dev/null || true
    local _ALLOWED_KEYS='WG_IP|POSTGRES_PASSWORD|POSTGRES_DATABASE|POSTGRES_APP_USER|POSTGRES_APP_PASSWORD|REDIS_PASSWORD|DEPLOY_DB|DEPLOY_REDIS|POSTGRES_IMAGE|REDIS_IMAGE|BACKUP_ENC_KEY|RSYNC_REMOTE|RSYNC_USER|RSYNC_PORT|RSYNC_KEY|RSYNC_REMOTE_DIR|ALIST_MODE|ALIST_MOUNT|ALIST_URL|ALIST_TOKEN|ALIST_REMOTE_DIR|POSTGRES_SHARED_BUFFERS|POSTGRES_EFFECTIVE_CACHE|POSTGRES_MAINTENANCE_WORK_MEM|POSTGRES_WORK_MEM|POSTGRES_MAX_CONNECTIONS|POSTGRES_WAL_BUFFERS|REDIS_MAXMEMORY'
    local key val line
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            if [[ "$key" =~ ^($_ALLOWED_KEYS)$ ]]; then
                printf -v "$key" '%s' "$val"
                export "$key"
            fi
        fi
    done < "$1/.env"
}

_env_set() {   # DIR KEY VAL
    local envfile="$1/.env" key="$2" val="$3" tmp
    tmp="${envfile}.tmp.$$"
    if grep -q "^${key}=" "$envfile" 2>/dev/null; then
        awk -v k="$key" -v v="$val" '
            BEGIN { replaced=0 }
            /^[[:space:]]*#/ { print; next }
            $0 ~ "^" k "=" { print k "=" v; replaced=1; next }
            { print }
            END { if (!replaced) print k "=" v }
        ' "$envfile" > "$tmp" && mv "$tmp" "$envfile"
    else
        printf '%s=%s\n' "$key" "$val" >> "$envfile"
    fi
}

_check_dir_safe() {   # DIR — 防止误传危险路径后被后续 rm -rf "$dir/xxx" 误伤
    local d="$1"
    [[ -n "$d" ]] || error "DIR 不能为空"
    case "$d" in
        /|/root|/root/|/home|/home/|/etc|/etc/|/var|/var/|/usr|/usr/)
            error "DIR 不能是系统关键路径: '${d}'，请指定专用的业务目录" ;;
    esac
}

_svc_exists() {   # DIR SVC
    grep -q "^  $2:" "$1/docker-compose.yml" 2>/dev/null
}

# 实际 Docker 网段 CIDR（用于 pg_hba.conf），优先 compose 项目网络
_docker_subnet_cidr() {
    local s
    s=$(docker network inspect pg-infra_default \
        --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)
    [[ -z "$s" ]] && s=$(docker network inspect infra_default \
        --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)
    if [[ -z "$s" ]]; then
        s=$(docker network inspect bridge \
            --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)
    fi
    echo "${s:-172.17.0.0/16}"
}

# WireGuard 网段 CIDR，假定 /24（与 MariaDB 版本 'IP%' 的假设一致）
_wg_subnet_cidr() {
    local ip="$1"
    echo "${ip%.*}.0/24"
}

# ── 依赖检查 ─────────────────────────────────────────────────
_check_deps() {
    local missing=()
    for cmd in docker ip awk grep tar; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if command -v docker >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
        missing+=("docker compose (插件)")
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "缺少依赖命令: ${missing[*]}\n请安装后再运行本脚本。\nDocker 安装参考: curl -fsSL https://get.docker.com | sudo bash"
    fi
}

compose_run() { local d="$1"; shift
    docker compose --project-directory "$d" -f "$d/docker-compose.yml" --env-file "$d/.env" "$@"
}

db_exec() { local d="$1"; shift
    compose_run "$d" exec -T db psql -U postgres -v ON_ERROR_STOP=1 "$@"
}

db_sql() {   # DIR SQL
    compose_run "$1" exec -T \
        db psql -U postgres -v ON_ERROR_STOP=1 < <(printf '%s\n' "$2")
}

db_sql_on() {   # DIR DB SQL — 直接指定目标库
    compose_run "$1" exec -T \
        db psql -U postgres -v ON_ERROR_STOP=1 -d "$2" < <(printf '%s\n' "$3")
}

# ════════════════════════════════════════════════════════════
# 配置文件生成
# ════════════════════════════════════════════════════════════
# ── 自动计算调优默认值 ───────────────────────────────────────
# 输出变量：_AT_SHARED_BUFFERS _AT_EFFECTIVE_CACHE _AT_MAINTENANCE_WORK_MEM
#          _AT_WORK_MEM _AT_MAX_CONN _AT_WAL_BUFFERS _AT_REDIS_MEM
_auto_tune() {
    local total_kb; total_kb=$(awk '/^MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    local total_mb=$(( total_kb / 1024 ))
    (( total_mb < 512 )) && total_mb=512

    # shared_buffers = 25% 物理内存，最小 128M，最大 8192M
    local sb=$(( total_mb / 4 ))
    (( sb <  128  )) && sb=128
    (( sb > 8192  )) && sb=8192
    _AT_SHARED_BUFFERS="${sb}MB"

    # effective_cache_size = 50% 物理内存，最小 256M
    local ecs=$(( total_mb / 2 ))
    (( ecs < 256 )) && ecs=256
    _AT_EFFECTIVE_CACHE="${ecs}MB"

    # maintenance_work_mem = 6.25% 物理内存，最小 64M，最大 2048M
    local mwm=$(( total_mb * 625 / 10000 ))
    (( mwm <   64 )) && mwm=64
    (( mwm > 2048 )) && mwm=2048
    _AT_MAINTENANCE_WORK_MEM="${mwm}MB"

    # max_connections 按内存档位梯度
    if   (( total_mb >= 16384 )); then _AT_MAX_CONN=400
    elif (( total_mb >=  8192 )); then _AT_MAX_CONN=300
    elif (( total_mb >=  4096 )); then _AT_MAX_CONN=200
    elif (( total_mb >=  2048 )); then _AT_MAX_CONN=100
    else                               _AT_MAX_CONN=50
    fi

    # work_mem ≈ (25% 物理内存) / max_connections，最小 4M，最大 256M
    local wm=$(( total_mb / 4 / _AT_MAX_CONN ))
    (( wm <   4 )) && wm=4
    (( wm > 256 )) && wm=256
    _AT_WORK_MEM="${wm}MB"

    # wal_buffers = shared_buffers / 32，最小 4M，最大 64M
    local wb=$(( sb / 32 ))
    (( wb <  4 )) && wb=4
    (( wb > 64 )) && wb=64
    _AT_WAL_BUFFERS="${wb}MB"

    # redis maxmemory = 15% 物理内存，最小 128M，最大 4096M
    local rm=$(( total_mb * 15 / 100 ))
    (( rm <  128  )) && rm=128
    (( rm > 4096  )) && rm=4096
    _AT_REDIS_MEM="${rm}mb"
}

# 生成 pg_hba.conf（按 WireGuard / Docker 网段限制访问），并在服务已运行时 reload
_write_pg_hba() {
    local dir="$1"
    load_env "$dir"
    mkdir -p "$dir/pg-conf"
    local wg_cidr; wg_cidr=$(_wg_subnet_cidr "${WG_IP}")
    local docker_cidr; docker_cidr=$(_docker_subnet_cidr)
    cat > "$dir/pg-conf/pg_hba.conf" <<HBA
# 自动生成，勿手动编辑；deploy/restore 时会按当前 WG_IP 重写
local   all             all                                     scram-sha-256
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ${wg_cidr}               scram-sha-256
host    all             all             ${docker_cidr}           scram-sha-256
HBA
    log "pg_hba.conf 已生成: WG网段=${wg_cidr}  Docker网段=${docker_cidr}"
    if _svc_exists "$dir" "db" 2>/dev/null; then
        compose_run "$dir" exec -T db \
            psql -U postgres -c "SELECT pg_reload_conf();" >/dev/null 2>&1 \
            && log "已 reload PostgreSQL 配置（pg_hba 生效，无需重启）" \
            || true
    fi
}

_write_redis_conf() {
    local dir="$1"
    mkdir -p "$dir/redis-conf"
    _auto_tune
    load_env "$dir" 2>/dev/null || true
    local maxmem="${REDIS_MAXMEMORY:-${_AT_REDIS_MEM}}"
    cat > "$dir/redis-conf/redis.conf" <<CONF
bind 0.0.0.0
port ${REDIS_PORT}
requirepass ${REDIS_PASSWORD}
save 900 1
save 300 10
save 60 10000
appendonly yes
appendfsync everysec
maxmemory ${maxmem}
maxmemory-policy allkeys-lru
loglevel notice
logfile ""
CONF
    log "Redis 配置: maxmemory=${maxmem}"
}

_write_compose() {
    load_env "$1"
    local has_db="${DEPLOY_DB:-0}" has_redis="${DEPLOY_REDIS:-0}"
    _auto_tune
    local sb="${POSTGRES_SHARED_BUFFERS:-$_AT_SHARED_BUFFERS}"
    local ecs="${POSTGRES_EFFECTIVE_CACHE:-$_AT_EFFECTIVE_CACHE}"
    local mwm="${POSTGRES_MAINTENANCE_WORK_MEM:-$_AT_MAINTENANCE_WORK_MEM}"
    local wm="${POSTGRES_WORK_MEM:-$_AT_WORK_MEM}"
    local conn="${POSTGRES_MAX_CONNECTIONS:-$_AT_MAX_CONN}"
    local wb="${POSTGRES_WAL_BUFFERS:-$_AT_WAL_BUFFERS}"

    : > "$1/docker-compose.yml"
    echo "services:" >> "$1/docker-compose.yml"

    [[ "$has_db" == "1" ]] && cat >> "$1/docker-compose.yml" <<YAML

  db:
    image: ${POSTGRES_IMAGE}
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      PGPASSWORD: \${POSTGRES_PASSWORD}
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - ./db:/var/lib/postgresql/data
      - ./pg-conf/pg_hba.conf:/etc/postgresql-custom/pg_hba.conf:ro
    command:
      - postgres
      - -c
      - hba_file=/etc/postgresql-custom/pg_hba.conf
      - -c
      - listen_addresses=*
      - -c
      - shared_buffers=${sb}
      - -c
      - effective_cache_size=${ecs}
      - -c
      - maintenance_work_mem=${mwm}
      - -c
      - work_mem=${wm}
      - -c
      - max_connections=${conn}
      - -c
      - wal_buffers=${wb}
      - -c
      - checkpoint_completion_target=0.9
      - -c
      - random_page_cost=1.1
      - -c
      - effective_io_concurrency=200
    ports:
      - "\${WG_IP}:${POSTGRES_PORT}:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s
YAML

    [[ "$has_redis" == "1" ]] && cat >> "$1/docker-compose.yml" <<YAML

  redis:
    image: ${REDIS_IMAGE}
    restart: unless-stopped
    environment:
      REDISCLI_AUTH: \${REDIS_PASSWORD}
    volumes:
      - ./redis:/data
      - ./redis-conf/redis.conf:/etc/redis/redis.conf:ro
    command: redis-server /etc/redis/redis.conf
    ports:
      - "\${WG_IP}:${REDIS_PORT}:${REDIS_PORT}"
    healthcheck:
      test: ["CMD", "redis-cli", "-h", "127.0.0.1", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
YAML
}

# ════════════════════════════════════════════════════════════
# deploy [DIR] [WG_IP] [db|redis|all]
# update [DIR] [db|redis|all]
# ════════════════════════════════════════════════════════════
cmd_deploy() {
    [[ $EUID -eq 0 ]] || error "需要 root 权限"
    local dir="${1:-$DEFAULT_DIR}" wg_ip="${2:-$(get_wg_ip)}" target="${3:-all}"
    _check_ipv4 "$wg_ip"
    ip link show "${WG_IFACE}" &>/dev/null || error "${WG_IFACE} 不存在，请先启动 WireGuard"

    local do_db=0 do_redis=0
    case "$target" in
        db)    do_db=1 ;;
        redis) do_redis=1 ;;
        all)   do_db=1; do_redis=1 ;;
        *)     error "target 须为 db / redis / all" ;;
    esac

    mkdir -p "$dir"
    [[ -f "$dir/.env" ]] || { cat > "$dir/.env" <<EOF
# 共享基础设施凭据
WG_IP=${wg_ip}
EOF
        chmod 600 "$dir/.env"; }
    chmod 600 "$dir/.env"
    _env_set "$dir" "WG_IP" "$wg_ip"

    if (( do_db )); then
        mkdir -p "$dir/db" "$dir/backup"
        if ! grep -q "^POSTGRES_PASSWORD=" "$dir/.env" 2>/dev/null; then
            local _root_pw _app_pw
            _root_pw=$(randpw)
            _app_pw=$(randpw)
            [[ -n "$_root_pw" && -n "$_app_pw" ]] || error "随机密码生成失败，请检查 openssl 或 /dev/urandom"
            printf "POSTGRES_PASSWORD=%s\nPOSTGRES_DATABASE=gallery\nPOSTGRES_APP_USER=gallery\nPOSTGRES_APP_PASSWORD=%s\n" \
                "$_root_pw" "$_app_pw" >> "$dir/.env"
            log "PostgreSQL 凭据已生成"
        else
            warn "PostgreSQL 凭据已存在，跳过生成"
        fi
        _env_set "$dir" "DEPLOY_DB" "1"
        grep -q "^POSTGRES_IMAGE=" "$dir/.env" 2>/dev/null || _env_set "$dir" "POSTGRES_IMAGE" "$POSTGRES_IMAGE"
        _write_pg_hba "$dir"
    fi

    if (( do_redis )); then
        mkdir -p "$dir/redis"
        if ! grep -q "^REDIS_PASSWORD=" "$dir/.env" 2>/dev/null; then
            local _redis_pw
            _redis_pw=$(randpw)
            [[ -n "$_redis_pw" ]] || error "随机密码生成失败，请检查 openssl 或 /dev/urandom"
            echo "REDIS_PASSWORD=${_redis_pw}" >> "$dir/.env"
            log "Redis 凭据已生成"
        else
            warn "Redis 凭据已存在，跳过生成"
        fi
        _env_set "$dir" "DEPLOY_REDIS" "1"
        grep -q "^REDIS_IMAGE=" "$dir/.env" 2>/dev/null || _env_set "$dir" "REDIS_IMAGE" "$REDIS_IMAGE"
        load_env "$dir"
        _write_redis_conf "$dir"
    fi

    _write_compose "$dir"

    sysctl -w vm.overcommit_memory=1 >/dev/null 2>&1 || true
    grep -q 'vm.overcommit_memory' /etc/sysctl.conf \
        || echo 'vm.overcommit_memory = 1' >> /etc/sysctl.conf

    local svcs=()
    (( do_db ))    && svcs+=("db")
    (( do_redis )) && svcs+=("redis")

    header "启动: ${svcs[*]}"
    compose_run "$dir" up -d --wait "${svcs[@]}" 2>&1 \
        || error "docker compose up 失败"

    if (( do_db )); then
        load_env "$dir"
        header "初始化应用库/用户: ${POSTGRES_DATABASE} / ${POSTGRES_APP_USER}"
        _ensure_role "$dir" "${POSTGRES_APP_USER}" "${POSTGRES_APP_PASSWORD}"
        _ensure_database "$dir" "${POSTGRES_DATABASE}" "${POSTGRES_APP_USER}"
        # 网络访问由 pg_hba.conf 按 WG/Docker 网段控制，pg_hba 已在上面写好，此处 reload 一次确保生效
        compose_run "$dir" exec -T db \
            psql -U postgres -c "SELECT pg_reload_conf();" >/dev/null 2>&1 || true
    fi

    compose_run "$dir" ps
    log "部署完成"
    _print_creds "$dir"
}

cmd_update() {
    [[ $EUID -eq 0 ]] || error "需要 root 权限"
    local dir="${1:-$DEFAULT_DIR}" target="${2:-all}"
    load_env "$dir"

    local svcs=()
    case "$target" in
        db)    _svc_exists "$dir" "db"    || error "PostgreSQL 未部署"; svcs=("db") ;;
        redis) _svc_exists "$dir" "redis" || error "Redis 未部署";      svcs=("redis") ;;
        all)
            _svc_exists "$dir" "db"    && svcs+=("db")
            _svc_exists "$dir" "redis" && svcs+=("redis")
            [[ ${#svcs[@]} -gt 0 ]] || error "没有已部署的服务"
            ;;
        *) error "target 须为 db / redis / all" ;;
    esac

    header "拉取最新镜像: ${svcs[*]}"
    compose_run "$dir" pull "${svcs[@]}"

    for svc in "${svcs[@]}"; do
        info "重建 ${svc}..."
        compose_run "$dir" up -d --wait --no-deps "$svc" 2>&1 \
            || error "${svc} 重建失败"
        log "${svc} 已更新"
    done

    compose_run "$dir" ps
    log "更新完成"
}

# ── 角色/库创建（幂等） ──────────────────────────────────────
# CREATE DATABASE 不能在事务块内执行，因此不能包进 DO $$ ... $$；
# 角色的存在性判断可以放进 DO 块（用 EXECUTE format(...) 动态执行）。
_ensure_role() {   # DIR USER PW
    local dir="$1" user="$2" pw="$3"
    db_sql "$dir" "
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${user}') THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', '${user}', '${pw}');
  ELSE
    EXECUTE format('ALTER ROLE %I PASSWORD %L', '${user}', '${pw}');
  END IF;
END
\$\$;"
}

_ensure_database() {   # DIR DB OWNER_USER
    local dir="$1" db="$2" owner="$3"
    local exists
    exists=$(db_exec "$dir" -tAc "SELECT 1 FROM pg_database WHERE datname='${db}';" 2>/dev/null | tr -d '[:space:]')
    if [[ "$exists" != "1" ]]; then
        db_exec "$dir" -c "CREATE DATABASE \"${db}\" OWNER \"${owner}\" ENCODING 'UTF8';"
    else
        db_exec "$dir" -c "ALTER DATABASE \"${db}\" OWNER TO \"${owner}\";" 2>/dev/null || true
    fi
    db_exec "$dir" -c "GRANT ALL PRIVILEGES ON DATABASE \"${db}\" TO \"${owner}\";"
    db_sql_on "$dir" "$db" "
GRANT ALL ON SCHEMA public TO \"${owner}\";
ALTER DEFAULT PRIVILEGES FOR ROLE \"${owner}\" IN SCHEMA public GRANT ALL ON TABLES TO \"${owner}\";
ALTER DEFAULT PRIVILEGES FOR ROLE \"${owner}\" IN SCHEMA public GRANT ALL ON SEQUENCES TO \"${owner}\";"
    log "库: ${db}  Owner: ${owner}"
}

# ── 凭据打印 ─────────────────────────────────────────────────
_print_creds() {
    load_env "$1"
    echo ""
    echo "┌─── 连接信息 ───────────────────────────────────────────"
    [[ "${DEPLOY_DB:-0}"    == "1" ]] && printf "│  [PostgreSQL] %s:%s  用户:%s  库:%s\n│  密码: %s\n│  超级用户: postgres  密码: %s\n│\n" \
        "$WG_IP" "$POSTGRES_PORT" "$POSTGRES_APP_USER" "$POSTGRES_DATABASE" "$POSTGRES_APP_PASSWORD" "$POSTGRES_PASSWORD"
    [[ "${DEPLOY_REDIS:-0}" == "1" ]] && printf "│  [Redis]      %s:%s\n│  密码: %s\n│\n" \
        "$WG_IP" "$REDIS_PORT" "$REDIS_PASSWORD"
    echo "│  凭据文件: $1/.env"
    echo "└────────────────────────────────────────────────────────"
    warn "请通过 WireGuard 安全传输 .env 到各节点"
}

# ════════════════════════════════════════════════════════════
# 数据库管理
# ════════════════════════════════════════════════════════════
cmd_add_db() {
    local dir="${1:-$DEFAULT_DIR}" db="${2:?用法: add-db [DIR] <DB> <USER> [PW]}" user="${3:?}" pw="${4:-$(randpw)}"
    _check_id "$db" "数据库名"; _check_id "$user" "用户名"; _check_pw "$pw" "密码"
    _svc_exists "$dir" "db" || error "PostgreSQL 未部署"
    load_env "$dir"
    header "新建数据库: ${db} / 用户: ${user}"
    _ensure_role "$dir" "$user" "$pw"
    _ensure_database "$dir" "$db" "$user"
    log "库: ${db}  用户: ${user}  密码: ${pw}  主机: ${WG_IP}:${POSTGRES_PORT:-5432}"
}

cmd_del_db() {
    local dir="${1:-$DEFAULT_DIR}" db="${2:?用法: del-db [DIR] <DB> <USER>}" user="${3:?}"
    _check_id "$db" "数据库名"; _check_id "$user" "用户名"
    _svc_exists "$dir" "db" || error "PostgreSQL 未部署"
    load_env "$dir"
    warn "即将删除库 ${db} 和用户 ${user}，不可逆！"
    read -rp "输入库名确认: " c; [[ "$c" == "$db" ]] || { info "已取消"; return; }
    db_exec "$dir" -c "DROP DATABASE IF EXISTS \"${db}\" WITH (FORCE);" \
        || warn "DROP DATABASE 失败（当前 PostgreSQL 版本可能不支持 WITH (FORCE)，或仍有连接占用），请手动检查"
    db_exec "$dir" -c "DROP ROLE IF EXISTS \"${user}\";" \
        || warn "DROP ROLE 失败：该角色可能仍拥有其他库/对象的所有权，请手动处理后重试"
    log "已删除库 ${db} 和用户 ${user}"
}

cmd_clear_db() {
    local dir="${1:-$DEFAULT_DIR}" db="${2:?用法: clear-db [DIR] <DB>}"
    _check_id "$db" "数据库名"
    _svc_exists "$dir" "db" || error "PostgreSQL 未部署"
    load_env "$dir"
    warn "即将清空库 ${db} 内所有表（库和权限保留：重建 public schema），不可逆！"
    read -rp "输入库名确认: " c; [[ "$c" == "$db" ]] || { info "已取消"; return; }

    local owner
    owner=$(db_exec "$dir" -tAc "SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname='${db}';" | tr -d '[:space:]')
    [[ -n "$owner" ]] || { warn "找不到库 ${db}"; return 1; }

    db_sql_on "$dir" "$db" "
DROP SCHEMA public CASCADE;
CREATE SCHEMA public;
GRANT ALL ON SCHEMA public TO \"${owner}\";
GRANT ALL ON SCHEMA public TO public;
ALTER DEFAULT PRIVILEGES FOR ROLE \"${owner}\" IN SCHEMA public GRANT ALL ON TABLES TO \"${owner}\";
ALTER DEFAULT PRIVILEGES FOR ROLE \"${owner}\" IN SCHEMA public GRANT ALL ON SEQUENCES TO \"${owner}\";"
    log "已清空库 ${db}（public schema 已重建，owner: ${owner}）"
}

cmd_list_db() {
    local dir="${1:-$DEFAULT_DIR}"
    _svc_exists "$dir" "db" || error "PostgreSQL 未部署"
    load_env "$dir"
    header "数据库列表"
    db_exec "$dir" -c "SELECT datname AS \"数据库\", pg_catalog.pg_get_userbyid(datdba) AS \"Owner\",
        pg_catalog.pg_encoding_to_char(encoding) AS \"编码\"
        FROM pg_database WHERE datname NOT IN ('template0','template1','postgres') ORDER BY datname;"
    header "角色列表"
    db_exec "$dir" -c "SELECT rolname AS \"角色\", rolcanlogin AS \"可登录\", rolsuper AS \"超级用户\"
        FROM pg_roles WHERE rolname NOT LIKE 'pg\_%' ORDER BY rolname;"
}

cmd_passwd() {
    local dir="${1:-$DEFAULT_DIR}" user="${2:?用法: passwd [DIR] <USER> [PW]}" pw="${3:-$(randpw)}"
    _check_id "$user" "用户名"; _check_pw "$pw" "新密码"
    _svc_exists "$dir" "db" || error "PostgreSQL 未部署"
    load_env "$dir"
    local exists
    exists=$(db_exec "$dir" -tAc "SELECT 1 FROM pg_roles WHERE rolname='${user}';" | tr -d '[:space:]')
    [[ "$exists" == "1" ]] || { warn "未找到角色 ${user}"; return 1; }
    db_exec "$dir" -c "ALTER ROLE \"${user}\" PASSWORD '${pw}';"
    log "新密码: ${pw}"
}

# ════════════════════════════════════════════════════════════
# 性能调优子命令
# ════════════════════════════════════════════════════════════
cmd_tune_db() {
    local dir="${1:-$DEFAULT_DIR}"
    [[ -f "$dir/.env" ]] || error ".env 不存在: ${dir}/.env"
    _auto_tune
    load_env "$dir"

    local sb="${POSTGRES_SHARED_BUFFERS:-$_AT_SHARED_BUFFERS}"
    local ecs="${POSTGRES_EFFECTIVE_CACHE:-$_AT_EFFECTIVE_CACHE}"
    local mwm="${POSTGRES_MAINTENANCE_WORK_MEM:-$_AT_MAINTENANCE_WORK_MEM}"
    local wm="${POSTGRES_WORK_MEM:-$_AT_WORK_MEM}"
    local conn="${POSTGRES_MAX_CONNECTIONS:-$_AT_MAX_CONN}"
    local wb="${POSTGRES_WAL_BUFFERS:-$_AT_WAL_BUFFERS}"

    local total_kb; total_kb=$(awk '/^MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    local total_mb=$(( total_kb / 1024 ))

    header "PostgreSQL 性能参数  （系统内存: ${total_mb}MB）"
    printf "  %-30s %s\n" "shared_buffers"          "${sb}   （自动推荐: ${_AT_SHARED_BUFFERS}）"
    printf "  %-30s %s\n" "effective_cache_size"    "${ecs}  （自动推荐: ${_AT_EFFECTIVE_CACHE}）"
    printf "  %-30s %s\n" "maintenance_work_mem"    "${mwm}  （自动推荐: ${_AT_MAINTENANCE_WORK_MEM}）"
    printf "  %-30s %s\n" "work_mem"                "${wm}   （自动推荐: ${_AT_WORK_MEM}）"
    printf "  %-30s %s\n" "max_connections"         "${conn} （自动推荐: ${_AT_MAX_CONN}）"
    printf "  %-30s %s\n" "wal_buffers"              "${wb}   （自动推荐: ${_AT_WAL_BUFFERS}）"
    echo
    warn "shared_buffers / max_connections / wal_buffers 修改后需重启 PostgreSQL 才生效；work_mem / effective_cache_size / maintenance_work_mem 重启后同样按新 compose 生效（本脚本统一走重启方式，不做 reload 差异化）。"

    read -rp "  是否修改参数？[y/N] " yn
    [[ "${yn,,}" == "y" ]] || return 0

    echo; echo "  提示：留空保持当前值；输入 auto 恢复为自动计算值"; echo

    local val
    read -rp "  shared_buffers          [${sb}]: " val
    case "$val" in
        auto|AUTO) _env_set "$dir" "POSTGRES_SHARED_BUFFERS" "" ;;
        "") : ;;
        *[0-9][MmGg][Bb]) _env_set "$dir" "POSTGRES_SHARED_BUFFERS" "${val^^}" ;;
        *) warn "格式无效（示例: 512MB 1GB），跳过" ;;
    esac

    read -rp "  effective_cache_size    [${ecs}]: " val
    case "$val" in
        auto|AUTO) _env_set "$dir" "POSTGRES_EFFECTIVE_CACHE" "" ;;
        "") : ;;
        *[0-9][MmGg][Bb]) _env_set "$dir" "POSTGRES_EFFECTIVE_CACHE" "${val^^}" ;;
        *) warn "格式无效，跳过" ;;
    esac

    read -rp "  maintenance_work_mem    [${mwm}]: " val
    case "$val" in
        auto|AUTO) _env_set "$dir" "POSTGRES_MAINTENANCE_WORK_MEM" "" ;;
        "") : ;;
        *[0-9][MmGg][Bb]) _env_set "$dir" "POSTGRES_MAINTENANCE_WORK_MEM" "${val^^}" ;;
        *) warn "格式无效，跳过" ;;
    esac

    read -rp "  work_mem                [${wm}]: " val
    case "$val" in
        auto|AUTO) _env_set "$dir" "POSTGRES_WORK_MEM" "" ;;
        "") : ;;
        *[0-9][MmGg][Bb]) _env_set "$dir" "POSTGRES_WORK_MEM" "${val^^}" ;;
        *) warn "格式无效，跳过" ;;
    esac

    read -rp "  max_connections         [${conn}]: " val
    if [[ "$val" == "auto" || "$val" == "AUTO" ]]; then
        _env_set "$dir" "POSTGRES_MAX_CONNECTIONS" ""
    elif [[ -z "$val" ]]; then
        :
    elif [[ "$val" =~ ^[0-9]+$ ]]; then
        local val_dec=$((10#$val))
        if (( val_dec >= 10 && val_dec <= 5000 )); then
            _env_set "$dir" "POSTGRES_MAX_CONNECTIONS" "$val_dec"
        else
            warn "范围 10-5000，跳过"
        fi
    else
        warn "需要数字，跳过"
    fi

    read -rp "  wal_buffers             [${wb}]: " val
    case "$val" in
        auto|AUTO) _env_set "$dir" "POSTGRES_WAL_BUFFERS" "" ;;
        "") : ;;
        *[0-9][MmGg][Bb]) _env_set "$dir" "POSTGRES_WAL_BUFFERS" "${val^^}" ;;
        *) warn "格式无效，跳过" ;;
    esac

    _write_compose "$dir"
    log "配置已写入 compose，重启后生效: ${dir}/docker-compose.yml"

    if _svc_exists "$dir" "db" 2>/dev/null; then
        read -rp "  是否立即重启 PostgreSQL 使配置生效？[y/N] " yn
        if [[ "${yn,,}" == "y" ]]; then
            compose_run "$dir" up -d --wait --force-recreate db \
                && log "PostgreSQL 已重启" \
                || warn "重启失败，请手动执行: docker compose -f ${dir}/docker-compose.yml up -d --force-recreate db"
        else
            warn "配置已写入，请手动重启 PostgreSQL 生效"
        fi
    fi
}

cmd_tune_redis() {
    local dir="${1:-$DEFAULT_DIR}"
    [[ -f "$dir/.env" ]] || error ".env 不存在: ${dir}/.env"
    _auto_tune
    load_env "$dir"

    local maxmem="${REDIS_MAXMEMORY:-${_AT_REDIS_MEM}}"
    local total_kb; total_kb=$(awk '/^MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    local total_mb=$(( total_kb / 1024 ))

    header "Redis 性能参数  （系统内存: ${total_mb}MB）"
    printf "  %-20s %s\n" "maxmemory" "${maxmem}  （自动推荐: ${_AT_REDIS_MEM}）"
    echo
    printf "  当前配置文件: %s/redis-conf/redis.conf\n" "$dir"
    [[ -f "$dir/redis-conf/redis.conf" ]] && {
        echo; echo "  ── 当前文件内容 ──"
        grep -v "requirepass" "$dir/redis-conf/redis.conf" | sed 's/^/  /'
        echo
    }

    read -rp "  是否修改参数？[y/N] " yn
    [[ "${yn,,}" == "y" ]] || return 0

    echo
    local val
    read -rp "  maxmemory  [${maxmem}]（示例: 256mb 512mb 1gb，auto=自动推荐）: " val
    case "$val" in
        auto|AUTO) _env_set "$dir" "REDIS_MAXMEMORY" "" ;;
        "")        : ;;
        *[0-9][mMgGbB]*)
            _env_set "$dir" "REDIS_MAXMEMORY" "${val,,}" ;;
        *) warn "格式无效（示例: 512mb），跳过" ;;
    esac

    load_env "$dir"
    _write_redis_conf "$dir"
    log "配置文件已更新: ${dir}/redis-conf/redis.conf"

    if _svc_exists "$dir" "redis" 2>/dev/null; then
        read -rp "  是否立即重启 Redis 使配置生效？[y/N] " yn
        if [[ "${yn,,}" == "y" ]]; then
            compose_run "$dir" restart redis \
                && log "Redis 已重启" \
                || warn "重启失败，请手动执行: docker compose -f ${dir}/docker-compose.yml restart redis"
        else
            warn "配置已写入，请手动重启 Redis 生效"
        fi
    fi
}

# ════════════════════════════════════════════════════════════
# rsync 远端传输（通用文件传输，与数据库引擎无关）
# ════════════════════════════════════════════════════════════
_check_rsync() {
    command -v rsync >/dev/null 2>&1 || error "未找到 rsync，请先安装: apt-get install -y rsync"
    command -v ssh   >/dev/null 2>&1 || error "未找到 ssh，请先安装 openssh-client"
}

_load_rsync_conf() {
    local dir="$1"
    load_env "$dir"
    [[ -n "${RSYNC_REMOTE:-}"     ]] || error "未配置 RSYNC_REMOTE，请先运行 rsync-config"
    [[ -n "${RSYNC_USER:-}"       ]] || error "未配置 RSYNC_USER，请先运行 rsync-config"
    [[ -n "${RSYNC_REMOTE_DIR:-}" ]] || error "未配置 RSYNC_REMOTE_DIR，请先运行 rsync-config"
    RSYNC_PORT="${RSYNC_PORT:-22}"
    RSYNC_KEY="${RSYNC_KEY:-}"
    RSYNC_KNOWN_HOSTS="${dir}/.rsync_known_hosts"
    touch "$RSYNC_KNOWN_HOSTS" 2>/dev/null
    chmod 600 "$RSYNC_KNOWN_HOSTS" 2>/dev/null || true
}

_rsync_ssh_opts() {
    local key="${RSYNC_KEY:-}" port="${RSYNC_PORT:-22}"
    local khf="${RSYNC_KNOWN_HOSTS:-/dev/null}"
    local ssh_cmd="ssh -p ${port} -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${khf} -o BatchMode=yes"
    [[ -n "$key" ]] && ssh_cmd+=" -i ${key}"
    echo "$ssh_cmd"
}

_rsync_push() {   # DIR SRC_PATH [REMOTE_DEST_DIR]
    local dir="$1" src="$2" remote_dest="${3:-}"
    _check_rsync
    _load_rsync_conf "$dir"
    [[ -n "$remote_dest" ]] || remote_dest="$RSYNC_REMOTE_DIR"
    remote_dest="${remote_dest%/}/"
    local ssh_cmd; ssh_cmd=$(_rsync_ssh_opts)
    info "rsync 推送: ${src} → ${RSYNC_USER}@${RSYNC_REMOTE}:${remote_dest}"
    rsync -avz --progress -e "$ssh_cmd" "$src" "${RSYNC_USER}@${RSYNC_REMOTE}:${remote_dest}" \
        && log "推送完成" || error "rsync 推送失败（退出码 $?）"
}

_rsync_list() {   # DIR [REMOTE_PATH]
    local dir="$1" remote_path="${2:-}"
    _check_rsync
    _load_rsync_conf "$dir"
    [[ -n "$remote_path" ]] || remote_path="$RSYNC_REMOTE_DIR"
    local ssh_cmd; ssh_cmd=$(_rsync_ssh_opts)
    $ssh_cmd "${RSYNC_USER}@${RSYNC_REMOTE}" \
        "ls -lht '${remote_path}' 2>/dev/null || echo '（目录为空或不存在）'"
}

_parse_rsync_uri() {   # URI → RSYNC_URI_{USER,HOST,PORT,PATH}
    local uri="$1"
    if [[ "$uri" =~ ^rsync://([^@]+)@([^:/]+)(:([0-9]+))?(/.*)?$ ]]; then
        RSYNC_URI_USER="${BASH_REMATCH[1]}"
        RSYNC_URI_HOST="${BASH_REMATCH[2]}"
        RSYNC_URI_PORT="${BASH_REMATCH[4]:-22}"
        RSYNC_URI_PATH="${BASH_REMATCH[5]:-/}"
    else
        error "无法解析 rsync URI: '${uri}'  格式: rsync://user@host[:port]/path/file"
    fi
}

cmd_rsync_config() {
    local dir="${1:-$DEFAULT_DIR}"
    [[ -f "$dir/.env" ]] || error ".env 不存在，请先部署: ${dir}/.env"
    load_env "$dir"

    header "当前 rsync 配置"
    printf "  RSYNC_REMOTE     = %s\n" "${RSYNC_REMOTE:-（未设置）}"
    printf "  RSYNC_USER       = %s\n" "${RSYNC_USER:-（未设置）}"
    printf "  RSYNC_PORT       = %s\n" "${RSYNC_PORT:-22}"
    printf "  RSYNC_KEY        = %s\n" "${RSYNC_KEY:-（使用默认密钥）}"
    printf "  RSYNC_REMOTE_DIR = %s\n" "${RSYNC_REMOTE_DIR:-（未设置）}"
    echo

    read -rp "  是否修改配置？[y/N] " yn
    [[ "${yn,,}" == "y" ]] || return 0

    local val
    read -rp "  远端主机 IP/域名 [${RSYNC_REMOTE:-}]: " val
    [[ -n "$val" ]] && _env_set "$dir" "RSYNC_REMOTE" "$val"
    read -rp "  SSH 用户名 [${RSYNC_USER:-root}]: " val
    [[ -n "$val" ]] && _env_set "$dir" "RSYNC_USER" "$val" || \
        { [[ -z "${RSYNC_USER:-}" ]] && _env_set "$dir" "RSYNC_USER" "root"; }
    read -rp "  SSH 端口 [${RSYNC_PORT:-22}]: " val
    [[ -n "$val" ]] && _env_set "$dir" "RSYNC_PORT" "$val" || \
        { [[ -z "${RSYNC_PORT:-}" ]] && _env_set "$dir" "RSYNC_PORT" "22"; }
    read -rp "  SSH 私钥路径（留空使用默认）[${RSYNC_KEY:-}]: " val
    [[ -n "$val" ]] && _env_set "$dir" "RSYNC_KEY" "$val"
    read -rp "  远端备份目录 [${RSYNC_REMOTE_DIR:-/backup/pg-infra}]: " val
    if [[ -n "$val" ]]; then
        _env_set "$dir" "RSYNC_REMOTE_DIR" "$val"
    elif [[ -z "${RSYNC_REMOTE_DIR:-}" ]]; then
        _env_set "$dir" "RSYNC_REMOTE_DIR" "/backup/pg-infra"
    fi
    log "rsync 配置已保存"

    read -rp "  是否立即测试连通性？[y/N] " yn
    if [[ "${yn,,}" == "y" ]]; then
        load_env "$dir"
        _rsync_list "$dir" || warn "连接测试失败，请检查配置"
    fi
}

# ════════════════════════════════════════════════════════════
# AList 网盘（通用文件传输）
# ════════════════════════════════════════════════════════════
_check_alist_deps() { command -v curl >/dev/null 2>&1 || error "未找到 curl，请先安装"; }

_load_alist_conf() {
    local dir="$1"
    load_env "$dir"
    ALIST_MODE="${ALIST_MODE:-mount}"
    ALIST_REMOTE_DIR="${ALIST_REMOTE_DIR:-/backup/pg-infra}"
    case "$ALIST_MODE" in
        mount)
            [[ -n "${ALIST_MOUNT:-}" ]] || error "mount 模式需要配置 ALIST_MOUNT（本地挂载点），请运行 alist-config"
            ;;
        webdav)
            [[ -n "${ALIST_URL:-}"   ]] || error "webdav 模式需要配置 ALIST_URL，请运行 alist-config"
            [[ -n "${ALIST_TOKEN:-}" ]] || error "webdav 模式需要配置 ALIST_TOKEN，请运行 alist-config"
            ALIST_URL="${ALIST_URL%/}"
            ;;
        *) error "ALIST_MODE 只能为 mount 或 webdav，当前: '${ALIST_MODE}'" ;;
    esac
}

_alist_check_mount() {
    local mnt="$1"
    [[ -d "$mnt" ]] || error "AList 挂载目录不存在: ${mnt}"
    timeout 5 ls "$mnt" >/dev/null 2>&1 || error "AList 挂载点无响应: ${mnt}"
}

_alist_authfile() {
    # 把 Authorization header 写进临时文件（0600，随进程退出自动清理），
    # 交给 curl -K 读取，避免 token 以 -H 参数形式出现在 `ps` 里。
    local f; f=$(mktemp); _register_tmp "$f"
    chmod 600 "$f"
    printf 'header = "Authorization: Basic %s"\n' "$(printf '%s' ":${ALIST_TOKEN}" | base64 -w0)" > "$f"
    echo "$f"
}

_alist_mkdir_webdav() {
    local path="$1"
    local authfile; authfile=$(_alist_authfile)
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X MKCOL \
        -K "$authfile" \
        "${ALIST_URL}/dav${path}")
    rm -f "$authfile"
    [[ "$code" == "201" || "$code" == "405" || "$code" == "301" ]] \
        || warn "创建目录 ${path} 返回 HTTP ${code}（可能已存在，继续）"
}

_alist_upload_webdav() {   # LOCAL_FILE REMOTE_PATH
    local local_file="$1" remote_path="$2"
    local fname; fname=$(basename "$local_file")
    local url="${ALIST_URL}/dav${remote_path%/}/${fname}"
    local authfile; authfile=$(_alist_authfile)
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
        -K "$authfile" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@${local_file}" "$url")
    rm -f "$authfile"
    [[ "$code" == "200" || "$code" == "201" || "$code" == "204" ]] \
        || error "上传 ${fname} 失败，HTTP ${code}（URL: ${url}）"
    log "✓ 上传: ${fname}  HTTP ${code}"
}

_alist_download_webdav() {   # REMOTE_FILE_PATH LOCAL_DIR
    local remote_path="$1" local_dir="$2"
    local fname; fname=$(basename "$remote_path")
    local url="${ALIST_URL}/dav${remote_path}"
    local out="${local_dir}/${fname}"
    local authfile; authfile=$(_alist_authfile)
    local code
    code=$(curl -s -w "%{http_code}" -X GET \
        -K "$authfile" \
        -o "$out" "$url")
    rm -f "$authfile"
    [[ "$code" == "200" || "$code" == "206" ]] \
        || { rm -f "$out"; error "下载 ${fname} 失败，HTTP ${code}"; }
    log "✓ 下载: ${fname}  ($(du -sh "$out" | cut -f1))" >&2
}

_alist_list_webdav() {
    local remote_path="${1:-$ALIST_REMOTE_DIR}"
    local url="${ALIST_URL}/dav${remote_path}"
    local authfile; authfile=$(_alist_authfile)
    local body
    body=$(curl -s -X PROPFIND \
        -K "$authfile" \
        -H "Depth: 1" -H "Content-Type: application/xml" \
        --data '<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:displayname/><D:getcontentlength/><D:getlastmodified/></D:prop></D:propfind>' \
        "$url" 2>/dev/null) || { rm -f "$authfile"; warn "无法连接 AList WebDAV: ${url}" >&2; return 1; }
    rm -f "$authfile"
    echo "$body" | grep -oP '(?<=<D:href>)[^<]+' | grep -E '\.(sql|sql\.gz|tar\.gz)$' \
        | sed 's|.*/dav||' | while read -r p; do printf "  %s\n" "$p"; done
}

_alist_push_file() {   # DIR LOCAL_FILE [REMOTE_SUBDIR]
    local dir="$1" local_file="$2" remote_sub="${3:-}"
    _load_alist_conf "$dir"; _check_alist_deps
    [[ -f "$local_file" ]] || error "文件不存在: ${local_file}"
    local remote_dir="${ALIST_REMOTE_DIR%/}${remote_sub:+/${remote_sub}}"
    case "$ALIST_MODE" in
    mount)
        _alist_check_mount "$ALIST_MOUNT"
        local dest_dir="${ALIST_MOUNT%/}/${remote_dir#/}"
        mkdir -p "$dest_dir" 2>/dev/null || warn "无法在挂载点创建目录（某些只读网盘正常），继续尝试..."
        header "AList 挂载上传: ${local_file} → ${dest_dir}"
        cp "$local_file" "${dest_dir%/}/" \
            && log "上传完成 → ${dest_dir%/}/$(basename "$local_file")" \
            || error "复制到 AList 挂载目录失败"
        ;;
    webdav)
        header "AList WebDAV 上传: ${local_file} → ${ALIST_URL}/dav${remote_dir}"
        _alist_mkdir_webdav "$remote_dir"
        _alist_upload_webdav "$local_file" "$remote_dir"
        ;;
    esac
}

_alist_fetch_file() {   # DIR REMOTE_FILE → 返回本地临时路径
    local dir="$1" remote_file="$2"
    _load_alist_conf "$dir"; _check_alist_deps
    local tmp_dir; tmp_dir=$(mktemp -d); _register_tmp "$tmp_dir"
    local fname; fname=$(basename "$remote_file")
    case "$ALIST_MODE" in
    mount)
        _alist_check_mount "$ALIST_MOUNT"
        local src="${ALIST_MOUNT%/}/${remote_file#/}"
        [[ -f "$src" ]] || { rm -rf "$tmp_dir"; error "AList 挂载中找不到文件: ${src}"; }
        cp "$src" "${tmp_dir}/${fname}" || { rm -rf "$tmp_dir"; error "从 AList 挂载复制文件失败"; }
        ;;
    webdav)
        _alist_download_webdav "$remote_file" "$tmp_dir" \
            || { rm -rf "$tmp_dir"; error "从 AList WebDAV 下载文件失败"; }
        ;;
    esac
    echo "${tmp_dir}/${fname}"
}

_alist_list() {   # DIR [REMOTE_PATH]
    local dir="$1" remote_path="${2:-}"
    _load_alist_conf "$dir"
    [[ -n "$remote_path" ]] || remote_path="$ALIST_REMOTE_DIR"
    case "$ALIST_MODE" in
    mount)
        _alist_check_mount "$ALIST_MOUNT"
        local src="${ALIST_MOUNT%/}/${remote_path#/}"
        [[ -d "$src" ]] || { warn "目录不存在: ${src}"; return 0; }
        ls -lht "$src" 2>/dev/null | grep -E '\.(sql|sql\.gz|tar\.gz)$' || warn "（目录为空或无备份文件）"
        ;;
    webdav)
        _check_alist_deps
        local files; files=$(_alist_list_webdav "$remote_path")
        [[ -n "$files" ]] && echo "$files" || warn "（目录为空或无备份文件）"
        ;;
    esac
}

cmd_alist_config() {
    local dir="${1:-$DEFAULT_DIR}"
    [[ -f "$dir/.env" ]] || error ".env 不存在，请先部署: ${dir}/.env"
    load_env "$dir"

    header "当前 AList 配置"
    printf "  ALIST_MODE       = %s\n" "${ALIST_MODE:-mount}"
    printf "  ALIST_MOUNT      = %s\n" "${ALIST_MOUNT:-（未设置，mount 模式需要）}"
    printf "  ALIST_URL        = %s\n" "${ALIST_URL:-（未设置，webdav 模式需要）}"
    printf "  ALIST_TOKEN      = %s\n" "${ALIST_TOKEN:+***已设置***}${ALIST_TOKEN:-（未设置，webdav 模式需要）}"
    printf "  ALIST_REMOTE_DIR = %s\n" "${ALIST_REMOTE_DIR:-/backup/pg-infra}"
    echo

    read -rp "  是否修改配置？[y/N] " yn
    [[ "${yn,,}" == "y" ]] || return 0

    echo "  AList 支持两种接入模式："
    echo "  [1] mount  — AList 已挂载为本地 FUSE 目录（推荐，速度快）"
    echo "  [2] webdav — 通过 AList WebDAV HTTP 接口传输（无需挂载）"
    read -rp "  选择模式 [1=mount/2=webdav，当前: ${ALIST_MODE:-mount}]: " sel
    case "$sel" in
        1) _env_set "$dir" "ALIST_MODE" "mount"  ;;
        2) _env_set "$dir" "ALIST_MODE" "webdav" ;;
        "") : ;;
        *) warn "无效选择，保持原值" ;;
    esac
    load_env "$dir"

    local val
    if [[ "${ALIST_MODE:-mount}" == "mount" ]]; then
        read -rp "  本地挂载点路径 [${ALIST_MOUNT:-/mnt/alist}]: " val
        if [[ -n "$val" ]]; then _env_set "$dir" "ALIST_MOUNT" "$val"
        elif [[ -z "${ALIST_MOUNT:-}" ]]; then _env_set "$dir" "ALIST_MOUNT" "/mnt/alist"; fi
    else
        read -rp "  AList 服务地址（含端口，如 http://127.0.0.1:5244）[${ALIST_URL:-}]: " val
        [[ -n "$val" ]] && _env_set "$dir" "ALIST_URL" "${val%/}"
        read -rsp "  AList Token / 密码（输入不回显）: " val; echo
        [[ -n "$val" ]] && _env_set "$dir" "ALIST_TOKEN" "$val"
    fi

    read -rp "  AList 内备份目录 [${ALIST_REMOTE_DIR:-/backup/pg-infra}]: " val
    if [[ -n "$val" ]]; then _env_set "$dir" "ALIST_REMOTE_DIR" "$val"
    elif [[ -z "${ALIST_REMOTE_DIR:-}" ]]; then _env_set "$dir" "ALIST_REMOTE_DIR" "/backup/pg-infra"; fi

    log "AList 配置已保存"
    load_env "$dir"

    read -rp "  是否立即测试连通性？[y/N] " yn
    if [[ "${yn,,}" == "y" ]]; then
        _load_alist_conf "$dir"
        case "$ALIST_MODE" in
        mount)
            if timeout 5 ls "$ALIST_MOUNT" >/dev/null 2>&1; then
                log "✓ 挂载点响应正常: ${ALIST_MOUNT}"; ls -lh "$ALIST_MOUNT" 2>/dev/null | head -5 || true
            else warn "✗ 挂载点无响应: ${ALIST_MOUNT}"; fi
            ;;
        webdav)
            _check_alist_deps
            local code authfile; authfile=$(_alist_authfile)
            code=$(curl -s -o /dev/null -w "%{http_code}" -X PROPFIND \
                -K "$authfile" \
                -H "Depth: 0" --connect-timeout 8 "${ALIST_URL}/dav/")
            rm -f "$authfile"
            if [[ "$code" == "207" || "$code" == "200" ]]; then
                log "✓ AList WebDAV 连接正常（HTTP ${code}）"
            else
                warn "✗ AList WebDAV 连接失败（HTTP ${code}）  URL: ${ALIST_URL}/dav/"
            fi
            ;;
        esac
    fi
}

# ════════════════════════════════════════════════════════════
# 备份 / 恢复
# ════════════════════════════════════════════════════════════
# cmd_backup [DIR] [DEST] [--rsync] [--alist] [--encrypt]
cmd_backup() {
    local do_rsync=0 do_alist=0 do_encrypt=0
    local _pos=()
    for _a in "$@"; do
        case "$_a" in
            --rsync)   do_rsync=1 ;;
            --alist)   do_alist=1 ;;
            --encrypt) do_encrypt=1 ;;
            *) _pos+=("$_a") ;;
        esac
    done
    local dir="${_pos[0]:-$DEFAULT_DIR}" dest="${_pos[1]:-${_pos[0]:-$DEFAULT_DIR}/backup}"
    _check_dir_safe "$dir"

    [[ -f "$dir/.env" ]] || error ".env 不存在，请先部署: ${dir}/.env"
    load_env "$dir"
    mkdir -p "$dest"; chmod 700 "$dest" 2>/dev/null || true

    local ts; ts=$(date +%Y%m%d_%H%M%S)
    local work; work=$(mktemp -d); _register_tmp "$work"
    local pack="${work}/pack"; mkdir -p "$pack"

    header "全量备份 → ${dest}"

    cp "$dir/.env" "$pack/.env"
    [[ -f "$dir/docker-compose.yml" ]] && cp "$dir/docker-compose.yml" "$pack/docker-compose.yml"
    [[ -d "$dir/pg-conf"    ]] && cp -a "$dir/pg-conf"    "$pack/pg-conf"
    [[ -d "$dir/redis-conf" ]] && cp -a "$dir/redis-conf" "$pack/redis-conf"

    cat > "$pack/manifest.txt" <<EOF
backup_time=$(date -Iseconds)
hostname=$(hostname)
DEPLOY_DB=${DEPLOY_DB:-0}
DEPLOY_REDIS=${DEPLOY_REDIS:-0}
WG_IP=${WG_IP:-}
POSTGRES_IMAGE=${POSTGRES_IMAGE}
REDIS_IMAGE=${REDIS_IMAGE}
EOF

    # ── PostgreSQL 全量导出（pg_dumpall：含所有角色 + 所有库） ──
    if [[ "${DEPLOY_DB:-0}" == "1" ]]; then
        _svc_exists "$dir" "db" || { rm -rf "$work"; error "manifest 标记部署了 PostgreSQL，但 compose 中无 db 服务"; }
        info "导出 PostgreSQL 全量数据（pg_dumpall，含角色/库/权限），可能需要几分钟..."
        if compose_run "$dir" exec -T db \
                pg_dumpall -U postgres | gzip > "${pack}/postgres-all.sql.gz"; then
            log "✓ PostgreSQL 全量导出完成 ($(du -sh "${pack}/postgres-all.sql.gz" | cut -f1))"
        else
            rm -rf "$work"; error "pg_dumpall 导出失败"
        fi
    fi

    # ── Redis 数据打包 ──────────────────────────────────────
    if [[ "${DEPLOY_REDIS:-0}" == "1" ]]; then
        if _svc_exists "$dir" "redis"; then
            local _redis_cli=(compose_run "$dir" exec -T redis redis-cli -h 127.0.0.1)
            local _orig_aofpct
            _orig_aofpct=$("${_redis_cli[@]}" CONFIG GET auto-aof-rewrite-percentage 2>/dev/null | tail -1 || true)
            "${_redis_cli[@]}" CONFIG SET auto-aof-rewrite-percentage 0 >/dev/null 2>&1 || true
            "${_redis_cli[@]}" BGSAVE >/dev/null 2>&1 || true

            info "等待 Redis BGSAVE 完成..."
            local _bg_wait=0 _bg_done=0
            while (( _bg_wait < 60 )); do
                if [[ "$("${_redis_cli[@]}" INFO persistence 2>/dev/null \
                        | tr -d '\r' | awk -F: '/^rdb_bgsave_in_progress:/{print $2}')" == "0" ]]; then
                    _bg_done=1; break
                fi
                sleep 1; _bg_wait=$((_bg_wait + 1))
            done
            (( _bg_done )) || warn "等待 BGSAVE 完成超时（60s），备份的 RDB 可能不是最新一致状态"

            if [[ -d "$dir/redis" ]]; then
                tar -C "$dir" -czf "${pack}/redis-data.tar.gz" redis \
                    && log "✓ Redis 数据目录打包完成 ($(du -sh "${pack}/redis-data.tar.gz" | cut -f1))" \
                    || warn "Redis 数据打包失败，恢复时该库将为空"
            else
                warn "Redis 数据目录不存在，跳过"
            fi

            if [[ -n "${_orig_aofpct:-}" ]]; then
                "${_redis_cli[@]}" CONFIG SET auto-aof-rewrite-percentage "${_orig_aofpct}" >/dev/null 2>&1 || true
            fi
        else
            warn "manifest 标记部署了 Redis，但 compose 中无 redis 服务，跳过 Redis 备份"
        fi
    fi

    if [[ "${DEPLOY_DB:-0}" != "1" && "${DEPLOY_REDIS:-0}" != "1" ]]; then
        rm -rf "$work"; error "未检测到已部署的 PostgreSQL/Redis，无内容可备份"
    fi

    local out="${dest}/pg-infra-full-backup_${ts}.tar.gz"
    ( umask 077; tar -C "$pack" -czf "$out" . ) || { rm -rf "$work"; error "打包失败"; }
    chmod 600 "$out" 2>/dev/null || warn "无法收紧备份文件权限，该文件含明文密码，请手动 chmod 600"
    rm -rf "$work"
    log "全量备份完成: ${out}  ($(du -sh "$out" | cut -f1))"

    if (( do_encrypt )); then
        command -v openssl >/dev/null 2>&1 || error "加密需要 openssl，请先安装"
        load_env "$dir"
        local enc_key="${BACKUP_ENC_KEY:-}" _generated=0
        if [[ -z "$enc_key" ]]; then
            enc_key=$(randpw); _generated=1
            _env_set "$dir" "BACKUP_ENC_KEY" "$enc_key"
        fi
        local enc_out="${out}.enc"
        if openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
                -pass "pass:${enc_key}" -in "$out" -out "$enc_out"; then
            command -v shred >/dev/null 2>&1 && shred -u "$out" 2>/dev/null || rm -f "$out"
            chmod 600 "$enc_out" 2>/dev/null || true
            out="$enc_out"
            log "✓ 已加密: ${out}"
        else
            error "备份加密失败"
        fi
        echo
        _c "1;31" "════════════════════════════════════════════════════════"
        _c "1;31" "  重要：备份解密密钥（务必单独抄录保存，不要只依赖本机 .env）"
        _c "1;31" "  ${enc_key}"
        (( _generated )) && _c "1;31" "  已顺手写入 ${dir}/.env 的 BACKUP_ENC_KEY，方便本机后续备份复用；"
        _c "1;31" "  但机器重装后 .env 会随之丢失，到时候 restore 这份备份必须"
        _c "1;31" "  手动提供上面这个密钥，请现在就把它记录到密码管理器/纸面等独立位置。"
        _c "1;31" "════════════════════════════════════════════════════════"
        echo
    fi

    info "该文件可直接拷走保存；机器重装后执行 restore 即可整体恢复。"

    (( do_rsync )) && { header "推送备份到 rsync 远端"; _rsync_push "$dir" "$out" ""; }
    (( do_alist )) && { header "上传备份到 AList 网盘"; _alist_push_file "$dir" "$out"; }
}

# cmd_restore [DIR] <备份tar.gz[.enc]|rsync://...|alist:///...> [解密密钥]
cmd_restore() {
    local dir="${1:-$DEFAULT_DIR}" f="${2:?用法: restore [DIR] <pg-infra-full-backup_*.tar.gz[.enc]|rsync://...|alist:///...> [解密密钥]}"
    local enc_key="${3:-}"
    _check_dir_safe "$dir"

    local _tmp_dir="" _cleanup=0
    if [[ "$f" == rsync://* ]]; then
        _check_rsync
        _parse_rsync_uri "$f"
        _tmp_dir=$(mktemp -d); _register_tmp "$_tmp_dir"; _cleanup=1
        local _fname; _fname=$(basename "$RSYNC_URI_PATH")
        mkdir -p "$dir"
        local _khf="${dir}/.rsync_known_hosts"; touch "$_khf" 2>/dev/null; chmod 600 "$_khf" 2>/dev/null || true
        local _ssh_cmd="ssh -p ${RSYNC_URI_PORT} -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${_khf} -o BatchMode=yes"
        [[ -n "${RSYNC_KEY:-}" ]] && _ssh_cmd+=" -i ${RSYNC_KEY}"
        info "从远端拉取: ${RSYNC_URI_USER}@${RSYNC_URI_HOST}:${RSYNC_URI_PATH}"
        rsync -avz --progress -e "$_ssh_cmd" \
            "${RSYNC_URI_USER}@${RSYNC_URI_HOST}:${RSYNC_URI_PATH}" "${_tmp_dir}/" \
            || { rm -rf "$_tmp_dir"; error "rsync 拉取失败，请检查远端路径和 SSH 配置"; }
        f="${_tmp_dir}/${_fname}"
        log "已拉取到临时目录: ${f}"
    elif [[ "$f" == alist://* ]]; then
        local _alist_path="${f#alist://}"
        [[ "$_alist_path" == /* ]] || _alist_path="/${_alist_path}"
        info "从 AList 网盘获取文件: ${_alist_path}"
        local _fetched; _fetched=$(_alist_fetch_file "$dir" "$_alist_path")
        _tmp_dir=$(dirname "$_fetched"); _register_tmp "$_tmp_dir"; _cleanup=1
        f="$_fetched"
        log "已从 AList 下载到临时目录: ${f}"
    fi

    [[ -f "$f" ]] || { [[ $_cleanup -eq 1 ]] && rm -rf "$_tmp_dir"; error "文件不存在: ${f}"; }

    if [[ "$f" == *.enc ]]; then
        command -v openssl >/dev/null 2>&1 \
            || { [[ $_cleanup -eq 1 ]] && rm -rf "$_tmp_dir"; error "解密需要 openssl，请先安装"; }
        if [[ -z "$enc_key" ]]; then
            read -rsp "该备份已加密，请输入解密密钥: " enc_key; echo
        fi
        [[ -n "$enc_key" ]] \
            || { [[ $_cleanup -eq 1 ]] && rm -rf "$_tmp_dir"; error "未提供解密密钥，无法继续"; }
        local _dec_dir; _dec_dir=$(mktemp -d); _register_tmp "$_dec_dir"
        local _dec_file="${_dec_dir}/$(basename "${f%.enc}")"
        if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
                -pass "pass:${enc_key}" -in "$f" -out "$_dec_file" 2>/dev/null; then
            rm -rf "$_dec_dir"; [[ $_cleanup -eq 1 ]] && rm -rf "$_tmp_dir"
            error "解密失败，密钥可能不正确"
        fi
        [[ $_cleanup -eq 1 ]] && rm -rf "$_tmp_dir"
        _tmp_dir="$_dec_dir"; _cleanup=1
        f="$_dec_file"
        log "解密成功"
    fi

    tar -tzf "$f" >/dev/null 2>&1 \
        || { [[ $_cleanup -eq 1 ]] && rm -rf "$_tmp_dir"; error "不是有效的 tar.gz 备份归档: ${f}"; }

    local extract; extract=$(mktemp -d); _register_tmp "$extract"
    tar -C "$extract" -xzf "$f" \
        || { rm -rf "$extract"; [[ $_cleanup -eq 1 ]] && rm -rf "$_tmp_dir"; error "解压失败: ${f}"; }
    [[ $_cleanup -eq 1 ]] && rm -rf "$_tmp_dir"
    [[ -f "$extract/.env" ]] || { rm -rf "$extract"; error "备份归档中缺少 .env，不是有效的全量备份文件"; }

    header "全量恢复 → ${dir}"
    [[ -f "$extract/manifest.txt" ]] && { echo; cat "$extract/manifest.txt" | sed 's/^/  /'; echo; }

    [[ -f "$dir/.env" ]] && warn "目标目录已存在 .env，恢复将覆盖现有配置，PostgreSQL/Redis 数据将被备份内容整体替换！"
    read -rp "确认恢复到 ${dir}？[y/N] " c
    [[ "${c,,}" == "y" ]] || { info "已取消"; rm -rf "$extract"; return; }
    [[ $EUID -eq 0 ]] || { rm -rf "$extract"; error "需要 root 权限"; }

    if [[ -f "$dir/docker-compose.yml" ]]; then
        info "停止现有服务..."
        compose_run "$dir" down 2>/dev/null || true
    fi

    mkdir -p "$dir"
    cp "$extract/.env" "$dir/.env"; chmod 600 "$dir/.env"
    [[ -f "$extract/docker-compose.yml" ]] && cp "$extract/docker-compose.yml" "$dir/docker-compose.yml"
    [[ -d "$extract/redis-conf" ]] && { rm -rf "$dir/redis-conf"; cp -a "$extract/redis-conf" "$dir/redis-conf"; }

    load_env "$dir"

    local new_wg_ip
    if new_wg_ip=$(get_wg_ip 2>/dev/null) && [[ -n "$new_wg_ip" ]]; then
        if [[ "$new_wg_ip" != "${WG_IP:-}" ]]; then
            warn "当前 WG IP (${new_wg_ip}) 与备份记录 (${WG_IP:-无}) 不同，已更新 .env"
            _env_set "$dir" "WG_IP" "$new_wg_ip"
        fi
    else
        warn "无法获取当前 WireGuard IP，沿用备份中的 WG_IP=${WG_IP:-无}（请确认 WireGuard 已启动）"
    fi
    load_env "$dir"
    _write_compose "$dir"
    _write_pg_hba "$dir"   # 按当前（可能已变化的）WG/Docker 网段重写 pg_hba，PostgreSQL 角色本身不受 IP 变化影响

    if [[ "${DEPLOY_DB:-0}" == "1" ]]; then
        [[ -f "$extract/postgres-all.sql.gz" ]] \
            || warn "备份标记 DEPLOY_DB=1，但归档中缺少 postgres-all.sql.gz！PostgreSQL 将以全新空库启动，请确认这是你想要的行为。"
        rm -rf "$dir/db"; mkdir -p "$dir/db"
    fi

    if [[ "${DEPLOY_REDIS:-0}" == "1" ]]; then
        rm -rf "$dir/redis"; mkdir -p "$dir/redis"
        if [[ -f "$extract/redis-data.tar.gz" ]]; then
            info "恢复 Redis 数据目录（dump.rdb + appendonlydir）..."
            tar -C "$dir" -xzf "$extract/redis-data.tar.gz" \
                || warn "Redis 数据解压失败，Redis 将以空数据启动"
        else
            warn "备份中无 Redis 数据文件，Redis 将以空数据启动"
        fi
    fi

    local svcs=()
    [[ "${DEPLOY_DB:-0}"    == "1" ]] && svcs+=("db")
    [[ "${DEPLOY_REDIS:-0}" == "1" ]] && svcs+=("redis")
    [[ ${#svcs[@]} -gt 0 ]] || { rm -rf "$extract"; error "备份未标记任何已部署服务（DEPLOY_DB/DEPLOY_REDIS）"; }

    header "启动服务: ${svcs[*]}"
    compose_run "$dir" up -d --wait "${svcs[@]}" 2>&1 \
        || { rm -rf "$extract"; error "docker compose up 失败"; }

    # ── 导入 PostgreSQL 全量数据 ──────────────────────────────
    # 说明：pg_dumpall 的输出对 postgres 超级用户和 template0/1 也会有 CREATE 语句，
    # 而全新集群里这些对象已存在，导入时会出现少量“already exists”提示，属预期现象，
    # 不使用 ON_ERROR_STOP，遇到这类无害错误会跳过继续，直到全部语句执行完。
    if [[ "${DEPLOY_DB:-0}" == "1" && -f "$extract/postgres-all.sql.gz" ]]; then
        info "导入全量 SQL，可能需要几分钟..."
        if gzip -dc "$extract/postgres-all.sql.gz" \
                | compose_run "$dir" exec -T db psql -U postgres; then
            log "✓ PostgreSQL 数据导入完成"
        else
            warn "导入过程中出现部分错误（常见于 postgres/template0/template1 的 already-exists 提示），请核对 list-db 结果确认数据完整"
        fi
    elif [[ "${DEPLOY_DB:-0}" == "1" ]]; then
        warn "未导入任何 PostgreSQL 数据（归档缺少 postgres-all.sql.gz），当前为全新空库！"
    fi

    rm -rf "$extract"
    compose_run "$dir" ps
    log "全量恢复完成"
    _print_creds "$dir"
}

# ════════════════════════════════════════════════════════════
# 运维命令
# ════════════════════════════════════════════════════════════
cmd_status() {
    local dir="${1:-$DEFAULT_DIR}"; load_env "$dir"
    header "服务状态"; compose_run "$dir" ps
    if _svc_exists "$dir" "db"; then
        header "PostgreSQL"
        if compose_run "$dir" exec -T db pg_isready -U postgres 2>/dev/null | grep -q "accepting connections"; then
            log "✓ 响应正常"
            db_exec "$dir" -c "SELECT count(*) AS 当前连接数 FROM pg_stat_activity;" 2>/dev/null || true
        else warn "✗ 无响应"; fi
    fi
    if _svc_exists "$dir" "redis"; then
        header "Redis"
        if compose_run "$dir" exec -T redis redis-cli -h 127.0.0.1 ping 2>/dev/null | grep -q PONG; then
            log "✓ 响应正常"
            compose_run "$dir" exec -T redis redis-cli -h 127.0.0.1 \
                info server 2>/dev/null | grep -E "redis_version|used_memory_human|connected_clients"
        else warn "✗ 无响应"; fi
    fi
}

_svc_op() {   # op=start|stop DIR [SVC]
    local op="$1" dir="${2:-$DEFAULT_DIR}" svc="${3:-}"
    if [[ -n "$svc" ]]; then
        _svc_exists "$dir" "$svc" || error "服务 ${svc} 未部署"
        compose_run "$dir" "$op" "$svc"
    else
        compose_run "$dir" "$op"
    fi
}
cmd_start() { _svc_op start "$@"; }
cmd_stop()  { _svc_op stop  "$@"; }

cmd_logs() {
    local dir="${1:-$DEFAULT_DIR}" svc="${2:?用法: logs [DIR] <db|redis>}"
    _svc_exists "$dir" "$svc" || error "服务 ${svc} 未部署"
    compose_run "$dir" logs -f --tail=100 "$svc"
}

# ════════════════════════════════════════════════════════════
# 交互菜单
# ════════════════════════════════════════════════════════════
_pause() { echo; read -rp "  按 Enter 返回..." _ || true; }
_ask()   {   # PROMPT VAR [DEFAULT]
    local hint=""; [[ -n "${3:-}" ]] && hint=" [${3}]"
    read -rp "  ${1}${hint}: " "$2"
    if [[ -z "${!2}" && -n "${3:-}" ]]; then
        printf -v "$2" '%s' "$3"
    fi
    return 0
}

_mhdr() {
    clear; echo
    _c "1;34" "╔══════════════════════════════════════════════╗"
    _c "1;34" "║   pg-redis-shared.sh  PostgreSQL 18 + Redis  ║"
    _c "1;34" "╚══════════════════════════════════════════════╝"
    echo
}

_deployed_svcs() {   # DIR → 打印已部署服务
    local out=""
    _svc_exists "$1" "db"    && out+=" PostgreSQL"
    _svc_exists "$1" "redis" && out+=" Redis"
    [[ -n "$out" ]] && info "已部署:${out}" || warn "尚未部署任何服务"
    echo
}

_ask_deploy_params() {
    local auto_ip=""
    ip link show "${WG_IFACE}" &>/dev/null \
        && auto_ip=$(ip addr show "${WG_IFACE}" | awk '/inet /{gsub(/\/.*/, "", $2); print $2; exit}') \
        || warn "${WG_IFACE} 未检测到"
    _ask "部署目录" DIR "$DEFAULT_DIR"
    _ask "WireGuard IP" WG_IP "$auto_ip"
    [[ -n "$WG_IP" ]] || { warn "WireGuard IP 不能为空"; return 1; }
    [[ "$WG_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { warn "IP 格式无效"; return 1; }
}

menu_main() {
    while true; do
        _mhdr
        echo "  ─── 部署 ────────────────────────────────────"
        echo "  1) 部署服务（PostgreSQL / Redis / 全部）"
        echo "  2) 更新服务镜像"
        echo "  ─── 运维 ────────────────────────────────────"
        echo "  3) 查看状态    4) 启动    5) 停止    6) 日志"
        echo "  ─── 数据 ────────────────────────────────────"
        echo "  7) 数据库管理 ▶        8) 备份 / 恢复 ▶"
        echo "  ─── 调优 ────────────────────────────────────"
        echo "  9) 性能调优 ▶（shared_buffers / maxmemory 等）"
        echo "  ─────────────────────────────────────────────"
        echo "  0) 退出"
        echo
        read -rp "  请选择 [0-9]: " CH
        case "$CH" in
            1) menu_deploy  ;; 2) menu_update ;;
            3) menu_status  ;; 4) menu_svc start ;;
            5) menu_svc stop ;; 6) menu_logs ;;
            7) menu_db      ;; 8) menu_bk ;;
            9) menu_tune    ;;
            0) info "再见！"; exit 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

menu_deploy() {
    _mhdr; _c "1;33" "  ▶ 部署服务"; echo
    _ask_deploy_params || { _pause; return; }
    echo "  a) PostgreSQL + Redis（全部）"
    echo "  b) 仅 PostgreSQL"
    echo "  c) 仅 Redis"
    echo
    read -rp "  请选择 [a/b/c]: " CH
    local target
    case "$CH" in
        a) target=all   ;; b) target=db ;; c) target=redis ;;
        *) warn "无效选项"; _pause; return ;;
    esac
    warn "将部署 ${target} 到 ${DIR}（WG: ${WG_IP}）"
    read -rp "  确认? [y/N] " C; [[ "${C,,}" == "y" ]] || { info "已取消"; _pause; return; }
    echo; _menu_run cmd_deploy "$DIR" "$WG_IP" "$target" || true; _pause
}

menu_update() {
    _mhdr; _c "1;33" "  ▶ 更新服务镜像"; echo
    _ask "部署目录" DIR "$DEFAULT_DIR"; _deployed_svcs "$DIR"
    echo "  a) 全部更新  b) 仅 PostgreSQL  c) 仅 Redis"
    read -rp "  请选择 [a/b/c]: " CH
    local target
    case "$CH" in
        a) target=all   ;; b) target=db ;; c) target=redis ;;
        *) warn "无效选项"; _pause; return ;;
    esac
    warn "将拉取最新镜像并重建 ${target}"
    read -rp "  确认? [y/N] " C; [[ "${C,,}" == "y" ]] || { info "已取消"; _pause; return; }
    echo; _menu_run cmd_update "$DIR" "$target" || true; _pause
}

menu_status() {
    _mhdr; _ask "部署目录" DIR "$DEFAULT_DIR"; echo
    _menu_run cmd_status "$DIR" || true; _pause
}

menu_svc() {
    local op="$1" label; [[ "$op" == "start" ]] && label="启动" || label="停止"
    _mhdr; _c "1;33" "  ▶ ${label}服务"; echo
    _ask "部署目录" DIR "$DEFAULT_DIR"; _deployed_svcs "$DIR"
    echo "  1) 全部  2) PostgreSQL  3) Redis"
    read -rp "  请选择 [1-3]: " CH
    local svc=""
    case "$CH" in 1) ;; 2) svc="db" ;; 3) svc="redis" ;;
        *) warn "无效选项"; _pause; return ;;
    esac
    read -rp "  确认${label}? [y/N] " C; [[ "${C,,}" == "y" ]] || { info "已取消"; _pause; return; }
    if [[ "$op" == "start" ]]; then
        _menu_run cmd_start "$DIR" ${svc:+"$svc"} || true
    else
        _menu_run cmd_stop  "$DIR" ${svc:+"$svc"} || true
    fi
    _pause
}

menu_logs() {
    _mhdr; _c "1;33" "  ▶ 查看日志"; echo
    _ask "部署目录" DIR "$DEFAULT_DIR"; _deployed_svcs "$DIR"
    echo "  1) PostgreSQL  2) Redis"
    read -rp "  请选择 [1-2]: " CH
    local svc; case "$CH" in 1) svc=db ;; 2) svc=redis ;; *) warn "无效"; _pause; return ;; esac
    info "Ctrl+C 退出"
    local _ot; _ot=$(trap -p INT); trap 'true' INT
    cmd_logs "$DIR" "$svc" || true
    [[ -n "$_ot" ]] && eval "$_ot" || trap - INT
    _pause
}

menu_db() {
    while true; do
        _mhdr; _c "1;33" "  ▶ 数据库管理"; echo
        echo "  1) 新建库和用户  2) 删除库和用户  3) 清空库内容"
        echo "  4) 列出库/用户   5) 修改用户密码  0) 返回"
        echo
        read -rp "  请选择 [0-5]: " CH
        case "$CH" in
            1) menu_db_add    ;; 2) menu_db_del   ;; 3) menu_db_clear ;;
            4) menu_db_list   ;; 5) menu_db_passwd ;; 0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

_db_menu_head() {   # TITLE
    _mhdr; _c "1;33" "  ▶ $1"; echo
    _ask "部署目录" DIR "$DEFAULT_DIR"
}

menu_db_add() {
    _db_menu_head "新建数据库和用户"
    _ask "数据库名" DB_NAME ""; [[ -n "$DB_NAME" ]] || { warn "不能为空"; _pause; return; }
    _ask "用户名"   DB_USER ""; [[ -n "$DB_USER" ]] || { warn "不能为空"; _pause; return; }
    _ask "密码（留空自动生成）" DB_PW "$(randpw)"; echo
    _menu_run cmd_add_db "$DIR" "$DB_NAME" "$DB_USER" "$DB_PW" || true; _pause
}

menu_db_del() {
    _db_menu_head "删除数据库和用户"
    _menu_run cmd_list_db "$DIR" 2>/dev/null || true; echo
    _ask "数据库名" DB_NAME ""; _ask "用户名" DB_USER ""
    [[ -n "$DB_NAME" && -n "$DB_USER" ]] || { warn "不能为空"; _pause; return; }
    echo; _menu_run cmd_del_db "$DIR" "$DB_NAME" "$DB_USER" || true; _pause
}

menu_db_clear() {
    _db_menu_head "清空数据库内容（保留库和权限）"
    _menu_run cmd_list_db "$DIR" 2>/dev/null || true; echo
    _ask "数据库名" DB_NAME ""; [[ -n "$DB_NAME" ]] || { warn "不能为空"; _pause; return; }
    echo; _menu_run cmd_clear_db "$DIR" "$DB_NAME" || true; _pause
}

menu_db_list() {
    _db_menu_head "数据库 / 用户列表"; echo
    _menu_run cmd_list_db "$DIR" || true; _pause
}

menu_db_passwd() {
    _db_menu_head "修改用户密码"
    _ask "用户名" DB_USER ""; [[ -n "$DB_USER" ]] || { warn "不能为空"; _pause; return; }
    _ask "新密码（留空自动生成）" NEW_PW "$(randpw)"; echo
    _menu_run cmd_passwd "$DIR" "$DB_USER" "$NEW_PW" || true; _pause
}

menu_bk() {
    while true; do
        _mhdr; _c "1;33" "  ▶ 备份 / 恢复"; echo
        echo "  说明：全量备份 = .env+配置+pg_dumpall全库(含角色权限)+Redis数据，打包为单个 tar.gz"
        echo "        备份时可选加密（生成 .tar.gz.enc），远端/网盘被攻破也只是密文，密钥务必额外保存"
        echo "        文件可直接拷走；机器重装后用「全量恢复」一步整体拉起。"
        echo "  ─────────────────────────────────────────────"
        echo "  1) 全量备份"
        echo "  2) 全量恢复"
        echo "  3) 远端配置（rsync / AList，仅推送/拉取备份时需要）"
        echo "  ─────────────────────────────────────────────"
        echo "  0) 返回"
        echo
        read -rp "  请选择 [0-3]: " CH
        case "$CH" in
            1) menu_bk_backup        ;;
            2) menu_bk_restore       ;;
            3) menu_bk_remote_config ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

menu_bk_backup() {
    _db_menu_head "全量备份"
    echo "  保存位置？"
    echo "  1) 仅本地"
    echo "  2) 本地 + 推送到 rsync 远端"
    echo "  3) 本地 + 上传到 AList 网盘"
    read -rp "  请选择 [1-3，默认 1]: " LOC_CH
    local _flags=()
    case "$LOC_CH" in
        2) load_env "$DIR"
           if [[ -z "${RSYNC_REMOTE:-}" ]]; then
               warn "尚未配置 rsync 远端，先去配置一下"; menu_bk_remote_config_rsync
               load_env "$DIR"; [[ -z "${RSYNC_REMOTE:-}" ]] && warn "未完成配置，本次改为仅本地备份"
           fi
           [[ -n "${RSYNC_REMOTE:-}" ]] && _flags+=("--rsync") ;;
        3) load_env "$DIR"
           if [[ -z "${ALIST_URL:-}" && -z "${ALIST_MOUNT:-}" ]]; then
               warn "尚未配置 AList 网盘，先去配置一下"; menu_bk_remote_config_alist
               load_env "$DIR"
               [[ -z "${ALIST_URL:-}" && -z "${ALIST_MOUNT:-}" ]] && warn "未完成配置，本次改为仅本地备份"
           fi
           [[ -n "${ALIST_URL:-}" || -n "${ALIST_MOUNT:-}" ]] && _flags+=("--alist") ;;
        *) : ;;
    esac
    _ask "本地输出目录" DEST "${DIR}/backup"
    read -rp "  是否加密备份归档？[y/N]（推荐；密钥请务必额外保存） " ENC_YN; echo
    [[ "${ENC_YN,,}" == "y" ]] && _flags+=("--encrypt")
    _menu_run cmd_backup "$DIR" "$DEST" "${_flags[@]}" || true; _pause
}

menu_bk_restore() {
    _db_menu_head "全量恢复"
    info "支持机器重装后的场景：DIR 可以是全新目录，将从备份归档重建全部配置和数据"
    echo "  备份来源？"
    echo "  1) 本地文件"
    echo "  2) rsync 远端"
    echo "  3) AList 网盘"
    read -rp "  请选择 [1-3，默认 1]: " SRC_CH
    local BK_FILE=""
    case "$SRC_CH" in
        2)
            load_env "$DIR" 2>/dev/null || true
            info "正在列出 rsync 远端目录..."
            ( _load_rsync_conf "$DIR" 2>/dev/null && _rsync_list "$DIR" 2>/dev/null ) \
                || warn "无法列出远端文件（请确认已在「远端配置」里配置过 rsync）"
            echo
            _ask "远端文件路径（rsync://user@host[:port]/path/pg-infra-full-backup_*.tar.gz[.enc]）" BK_FILE ""
            ;;
        3)
            load_env "$DIR" 2>/dev/null || true
            info "正在列出 AList 网盘目录..."
            ( _alist_list "$DIR" 2>/dev/null ) \
                || warn "无法列出网盘文件（请确认已在「远端配置」里配置过 AList）"
            echo
            echo "  输入格式: alist:///AList内部路径/文件名.tar.gz"
            _ask "AList 文件路径（alist:///...）" BK_FILE ""
            ;;
        *)
            _ask "全量备份文件（pg-infra-full-backup_*.tar.gz 或 .tar.gz.enc）" BK_FILE ""
            ;;
    esac
    [[ -n "$BK_FILE" ]] || { warn "不能为空"; _pause; return; }
    echo; _menu_run cmd_restore "$DIR" "$BK_FILE" || true; _pause
}

menu_bk_remote_config() {
    _mhdr; _c "1;33" "  ▶ 远端配置"; echo
    echo "  1) 配置 / 测试 rsync 远端"
    echo "  2) 配置 / 测试 AList 网盘"
    echo "  0) 返回"
    echo
    read -rp "  请选择 [0-2]: " CH
    case "$CH" in
        1) menu_bk_remote_config_rsync ;;
        2) menu_bk_remote_config_alist ;;
        0) return ;;
        *) warn "无效选项"; sleep 1 ;;
    esac
}

menu_bk_remote_config_rsync() {
    _db_menu_head "配置 rsync 远端"
    _menu_run cmd_rsync_config "$DIR" || true; _pause
}

menu_bk_remote_config_alist() {
    _db_menu_head "配置 AList 连接"
    _menu_run cmd_alist_config "$DIR" || true; _pause
}

menu_tune() {
    while true; do
        _mhdr; _c "1;33" "  ▶ 性能调优"; echo
        echo "  1) PostgreSQL 参数（shared_buffers / work_mem / connections）"
        echo "  2) Redis 参数（maxmemory）"
        echo "  0) 返回"
        echo
        read -rp "  请选择 [0-2]: " CH
        case "$CH" in
            1) menu_tune_db    ;;
            2) menu_tune_redis ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

menu_tune_db() {
    _db_menu_head "PostgreSQL 性能调优"
    _menu_run cmd_tune_db "$DIR" || true; _pause
}

menu_tune_redis() {
    _db_menu_head "Redis 性能调优"
    _menu_run cmd_tune_redis "$DIR" || true; _pause
}

# ════════════════════════════════════════════════════════════
# 入口
# ════════════════════════════════════════════════════════════
main() {
    _check_deps
    [[ $# -eq 0 ]] && { menu_main; return; }
    local cmd="$1"; shift
    case "$cmd" in
        deploy)    cmd_deploy   "$@" ;;
        update)    cmd_update   "$@" ;;
        add-db)    cmd_add_db   "$@" ;;
        del-db)    cmd_del_db   "$@" ;;
        clear-db)  cmd_clear_db "$@" ;;
        list-db)   cmd_list_db  "$@" ;;
        passwd)    cmd_passwd   "$@" ;;
        backup)       cmd_backup       "$@" ;;
        restore)      cmd_restore      "$@" ;;
        tune-db)      cmd_tune_db      "$@" ;;
        tune-redis)   cmd_tune_redis   "$@" ;;
        rsync-config) cmd_rsync_config "$@" ;;
        alist-config) cmd_alist_config "$@" ;;
        status)    cmd_status   "$@" ;;
        start)     cmd_start    "$@" ;;
        stop)      cmd_stop     "$@" ;;
        logs)      cmd_logs     "$@" ;;
        help|--help|-h)
            sed -n '/^# 用法/,/^# ══/p' "$0" | sed 's/^# \{0,2\}//' | head -n -1 ;;
        *) error "未知子命令: ${cmd}，执行 help 查看用法" ;;
    esac
}

main "$@"
