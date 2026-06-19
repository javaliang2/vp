#!/usr/bin/env bash
# ============================================================
# wp-deploy.sh — WordPress 多节点全自动部署（内网 WG + S3 + Redis）
# 功能：全自动安装核心、状态、日志、启停、重试配置、删除节点、更新镜像
# ============================================================
set -uo pipefail
# 注意：不使用全局 set -e，改为在关键位置显式检查返回值，
# 避免子 shell 或管道误触发意外退出。
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# ── 默认值 ──────────────────────────────────────────────────
BASE_DIR="${BASE_DIR:-/srv}"
DEFAULT_DIR="${BASE_DIR}/wordpress"
DEFAULT_PORT="8080"

# ── 颜色与界面输出 ──────────────────────────────────────────
_c()     { printf "\e[%sm%s\e[0m\n" "$1" "$2"; }
log()    { _c "32"   "[成功] $*"; }
info()   { _c "36"   "[提示] $*"; }
warn()   { _c "33"   "[警告] $*"; }
error()  { _c "31"   "[错误] $*"; exit 1; }
header() { echo; _c "1;34" "=== $* ==="; }

# ── 辅助函数 ────────────────────────────────────────────────
net_name() { echo "wp_net_$(basename "$1")"; }

# 统一入口：所有 docker compose 调用均通过此函数
dc() {
    local DIR="$1"; shift
    docker compose -f "$DIR/docker-compose.yml" --env-file "$DIR/.env" "$@"
}

# 在 wordpress 容器内执行 wp-cli，按需自动安装
# WP-CLI 安装到 /usr/local/bin/wp（不在任何 volume 挂载路径内，重建容器后需重装）
_install_wpcli() {
    local DIR="$1"
    # alpine 镜像内置 busybox wget，不支持 -q，但支持 -O（大写）和 --no-check-certificate
    # 优先尝试 wget，失败则尝试 curl（需容器内有 curl）
    dc "$DIR" exec -T wordpress sh -c '
        set -e
        WPCLI_URL="https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"
        DEST="/usr/local/bin/wp"
        if command -v wget >/dev/null 2>&1; then
            wget --no-check-certificate -O "$DEST" "$WPCLI_URL"
        elif command -v curl >/dev/null 2>&1; then
            curl -fsSL "$WPCLI_URL" -o "$DEST"
        else
            echo "ERROR: 容器内既无 wget 也无 curl，无法下载 WP-CLI" >&2
            exit 1
        fi
        chmod +x "$DEST"
    ' 2>&1
}

wp_cli() {
    local DIR="$1"; shift
    if ! dc "$DIR" exec -T wordpress test -f /usr/local/bin/wp 2>/dev/null; then
        _install_wpcli "$DIR" >/dev/null || true
    fi
    dc "$DIR" exec -T wordpress wp --allow-root "$@"
}

read_secret() {
    local PROMPT="$1"
    local VAR_NAME="$2"
    local VALUE=""

    if [[ -t 0 ]]; then
        # 使用 read -s 隐藏输入，兼容粘贴（带 -r 避免反斜杠转义）
        IFS= read -rsp "$PROMPT" VALUE
        echo    # 补一个换行
    else
        IFS= read -rp "$PROMPT" VALUE
    fi

    # 去除首尾所有空白（空格/Tab/换行等粘贴残留）
    VALUE="${VALUE#"${VALUE%%[![:space:]]*}"}"
    VALUE="${VALUE%"${VALUE##*[![:space:]]}"}"
    printf -v "$VAR_NAME" '%s' "$VALUE"
}

# ── 配置文件生成器 ──────────────────────────────────────────

_write_nginx_wp_conf() {
    local DEST="$1"
    cat > "$DEST" <<'NGINX'
map $http_x_forwarded_proto $fastcgi_https {
    default  "";
    https    "on";
}
upstream wordpress_fpm {
    server wordpress:9000;
    least_conn;
    keepalive 32;
}
server {
    listen 80;
    root   /var/www/html;
    index  index.php index.html;
    client_max_body_size 2048M;

    # 静态资源长期缓存
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2|webp)$ {
        expires max;
        log_not_found off;
        try_files $uri =404;
    }

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        fastcgi_pass              wordpress_fpm;
        fastcgi_index             index.php;
        include                   fastcgi_params;
        fastcgi_param SCRIPT_FILENAME    $document_root$fastcgi_script_name;
        fastcgi_param HTTPS              $fastcgi_https;
        fastcgi_param HTTP_X_FORWARDED_PROTO $http_x_forwarded_proto;
        fastcgi_param HTTP_X_FORWARDED_FOR   $http_x_forwarded_for;
        fastcgi_param HTTP_X_REAL_IP         $http_x_real_ip;
        fastcgi_read_timeout 600;
        fastcgi_keep_conn    on;
    }

    # 禁止直接访问敏感文件
    location ~* /(?:wp-config\.php|\.env|\.git) {
        deny all;
    }
}
NGINX
}

_write_php_uploads_ini() {
    local DEST="$1"
    cat > "$DEST" <<'INI'
upload_max_filesize = 2048M
post_max_size       = 2048M
memory_limit        = 1024M
max_execution_time  = 600
max_input_time      = 600
max_input_vars      = 10000
INI
}

_write_s3_config_php() {
    local DEST="$1"
    cat > "$DEST" <<'PHP'
<?php
// WP Offload Media 常量配置（通过环境变量注入，避免硬编码凭证）
define('AS3CF_SETTINGS', serialize([
    'provider'                 => getenv('S3_PROVIDER') ?: 'aws',
    'access-key-id'            => getenv('AWS_ACCESS_KEY_ID'),
    'secret-access-key'        => getenv('AWS_SECRET_ACCESS_KEY'),
    'bucket'                   => getenv('S3_BUCKET'),
    'region'                   => getenv('S3_REGION'),
    'endpoint'                 => getenv('S3_ENDPOINT') ?: '',
    'copy-to-s3'               => true,
    'serve-from-s3'            => true,
    'remove-local-file'        => true,
    'enable-object-prefix'     => true,
    'object-prefix'            => 'uploads/',
    'delivery-provider'        => 'storage',
    'delivery-provider-domain' => getenv('S3_CDN_DOMAIN') ?: '',
    'force-https'              => true,
    'use-presigned-urls'       => false,
    'enable-cron'              => false,
]));
PHP
}

# FIX: 原脚本混用了引号与非引号 heredoc，导致 REDIS_HOST/REDIS_PW
#      在第一段（单引号 heredoc）中不被展开，但在第二段中又被展开，
#      生成的 PHP 文件包含 bash 变量字面量而非实际值。
#      修复：两段均使用非引号 heredoc，统一展开。
_write_wp_config_extra() {
    local REDIS_HOST="$1"
    local REDIS_PW="$2"
    local DEST="$3"
    # 对 PHP heredoc 内的 $ 进行转义，防止 bash 误展开 PHP 变量
    cat > "$DEST" <<PHPEOF
<?php
// 反向代理 HTTPS 修复
if ( isset( \$_SERVER['HTTP_X_FORWARDED_PROTO'] )
     && \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https' ) {
    \$_SERVER['HTTPS'] = 'on';
}
if ( isset( \$_SERVER['HTTP_X_FORWARDED_HOST'] ) ) {
    \$_SERVER['HTTP_HOST'] = \$_SERVER['HTTP_X_FORWARDED_HOST'];
}
define( 'WP_HOME',    'https://' . \$_SERVER['HTTP_HOST'] );
define( 'WP_SITEURL', 'https://' . \$_SERVER['HTTP_HOST'] );

// Redis 对象缓存
define( 'WP_REDIS_HOST', '${REDIS_HOST}' );
define( 'WP_REDIS_PORT', 6379 );
define( 'WP_REDIS_AUTH', '${REDIS_PW}' );
define( 'WP_CACHE',      true );

// 内存限制
define( 'WP_MEMORY_LIMIT',     '512M' );
define( 'WP_MAX_MEMORY_LIMIT', '1024M' );

// 将 PHP Session 存入 Redis（多节点共享会话）
ini_set( 'session.save_handler', 'redis' );
ini_set( 'session.save_path',
    'tcp://' . WP_REDIS_HOST . ':' . WP_REDIS_PORT
    . '?auth=' . urlencode( WP_REDIS_AUTH ) );

// S3 配置（挂载至 /etc/wordpress/ 独立路径，避免与 wp-content volume 冲突）
if ( file_exists( '/etc/wordpress/s3-config.php' ) ) {
    require_once '/etc/wordpress/s3-config.php';
}
PHPEOF
}

# ── 核心自动化安装与配置模块 ─────────────────────────────────
_wait_and_setup_plugin() {
    local DIR="$1"
    local IS_AUTO_INSTALL="${2:-false}"
    local URL="${3:-}"
    local TITLE="${4:-}"
    local ADMIN="${5:-}"
    local PASS="${6:-}"
    local EMAIL="${7:-}"
    local WP_CONFIG="/var/www/html/wp-config.php"

    info "正在检测 wordpress 容器初始化状态..."
    local CFG_RETRIES=45
    # FIX: 原脚本 `(( CFG_RETRIES-- ))` 在计数器归零时，bash 算术求值返回 1，
    #      触发 set -e 导致整个脚本意外退出。改为 CFG_RETRIES=$((CFG_RETRIES-1))。
    while ! dc "$DIR" exec -T wordpress grep -q "ABSPATH" "$WP_CONFIG" 2>/dev/null; do
        sleep 2
        CFG_RETRIES=$((CFG_RETRIES - 1))
        if [[ $CFG_RETRIES -le 0 ]]; then
            warn "wp-config.php 生成超时。数据库连接可能有误，请通过菜单 3 查看容器日志。"
            return 1
        fi
    done

    # 注入高级配置引用（幂等：重复执行不重复注入）
    if ! dc "$DIR" exec -T wordpress grep -q "wp-config-extra.php" "$WP_CONFIG" 2>/dev/null; then
        dc "$DIR" exec -T wordpress \
            sed -i "1s|<?php|<?php\nrequire_once(ABSPATH . 'wp-config-extra.php');|" \
            "$WP_CONFIG"
        log "高级核心配置注入成功 (wp-config-extra.php 已生效)"
    else
        log "高级核心配置已存在，跳过注入"
    fi

    info "正在验证 WP-CLI 状态..."
    if ! dc "$DIR" exec -T wordpress test -f /usr/local/bin/wp 2>/dev/null; then
        info "WP-CLI 未找到，正在容器内安装..."
        if ! _install_wpcli "$DIR"; then
            warn "WP-CLI 安装失败，请检查容器外网连通性。"
            return 1
        fi
    fi

    if ! dc "$DIR" exec -T wordpress test -f /usr/local/bin/wp 2>/dev/null; then
        warn "WP-CLI 安装后仍无法验证，请检查容器状态。"
        return 1
    fi

    # 全自动核心静默安装
    if [[ "$IS_AUTO_INSTALL" == "true" ]]; then
        if ! wp_cli "$DIR" core is-installed &>/dev/null; then
            info "检测到空数据库，正在执行 WordPress 核心静默安装..."
            if wp_cli "$DIR" core install \
                    --url="$URL" \
                    --title="$TITLE" \
                    --admin_user="$ADMIN" \
                    --admin_password="$PASS" \
                    --admin_email="$EMAIL" \
                    --skip-email; then
                log "WordPress 核心安装成功！"
                echo -e "  站点主页: \e[32m${URL}\e[0m"
                echo -e "  管理账号: \e[32m${ADMIN}\e[0m"
                echo -e "  管理密码: \e[32m${PASS}\e[0m"
            else
                warn "WordPress 核心安装失败，请通过菜单 3 查看日志。"
                return 1
            fi
        else
            log "数据库已有数据，跳过核心初始化。"
        fi
    else
        if ! wp_cli "$DIR" core is-installed &>/dev/null; then
            warn "WordPress 尚未完成初始化。若需全自动安装，请通过菜单 1 重新部署。"
            return 1
        fi
    fi

    info "正在修复容器内文件权限..."
    dc "$DIR" exec -T wordpress chown -R www-data:www-data /var/www/html/wp-content || true

    # WP Offload Media (S3 插件)
    info "配置 S3 对象存储插件 (amazon-s3-and-cloudfront)..."
    if wp_cli "$DIR" plugin is-installed amazon-s3-and-cloudfront &>/dev/null; then
        wp_cli "$DIR" plugin activate amazon-s3-and-cloudfront \
            || warn "S3 插件激活失败。"
    else
        wp_cli "$DIR" plugin install amazon-s3-and-cloudfront --activate \
            || warn "S3 插件安装失败，请检查网络连通性。"
    fi

    # Redis Object Cache (Redis 插件)
    info "配置分布式缓存插件 (redis-cache)..."
    if wp_cli "$DIR" plugin is-installed redis-cache &>/dev/null; then
        wp_cli "$DIR" plugin activate redis-cache \
            || warn "Redis 插件激活失败。"
    else
        wp_cli "$DIR" plugin install redis-cache --activate \
            || warn "Redis 插件安装失败，请检查网络连通性。"
    fi

    # 在执行 wp redis enable 前先探测 Redis 连通性
    # wp redis enable 会写入 object-cache.php；若 Redis 不可达但 WP_CACHE=true，
    # WordPress 会因找不到可用缓存驱动产生致命错误。
    info "探测 Redis 连通性 (${REDIS_HOST:-}:6379)..."
    local REDIS_HOST_VAL
    REDIS_HOST_VAL=$(dc "$DIR" exec -T wordpress sh -c \
        'php -r "echo getenv(\"REDIS_HOST\") ?: (defined(\"WP_REDIS_HOST\") ? WP_REDIS_HOST : \"\");"' \
        2>/dev/null || true)
    # 从 .env 直接读取更可靠
    REDIS_HOST_VAL=$(grep '^REDIS_HOST=' "$DIR/.env" | cut -d= -f2)

    local REDIS_REACHABLE=false
    if dc "$DIR" exec -T wordpress sh -c \
        "nc -zw5 '${REDIS_HOST_VAL}' 6379" 2>/dev/null; then
        REDIS_REACHABLE=true
    elif dc "$DIR" exec -T wordpress sh -c \
        "timeout 5 bash -c \"echo >/dev/tcp/'${REDIS_HOST_VAL}'/6379\"" 2>/dev/null; then
        REDIS_REACHABLE=true
    fi

    if [[ "$REDIS_REACHABLE" == "true" ]]; then
        info "激活 Redis Object Cache..."
        if wp_cli "$DIR" redis enable; then
            log "Redis Object Cache 已启用！"
        else
            warn "Redis enable 命令失败（可能是密码错误或插件问题）。"
            warn "WP_CACHE 已设为 true，建议手动在后台检查 Redis 插件状态。"
        fi
    else
        warn "无法连接到 Redis (${REDIS_HOST_VAL}:6379)，跳过 redis enable。"
        warn "请检查 WireGuard 路由和 Redis 服务状态后，通过菜单 6 重试。"
        warn "注意：wp-config-extra.php 中 WP_CACHE=true 已写入，"
        warn "      若 object-cache.php 缺失，WordPress 将回退到无缓存模式（不会白屏）。"
    fi
}

# ── Docker Compose 文件生成 ──────────────────────────────────
_write_docker_compose() {
    local DIR="$1"
    local NET="$2"
    # FIX: s3-config.php 原先挂载到 /var/www/html/wp-content/s3-config.php，
    #      与 ./data:/var/www/html 的大 volume 存在子路径冲突，Docker 挂载顺序
    #      不确定时文件可能不可见。改挂到 /etc/wordpress/（容器内空目录，无冲突）。
    cat > "$DIR/docker-compose.yml" <<YAML
services:
  wordpress:
    image: wordpress:php8.3-fpm-alpine
    restart: unless-stopped
    environment:
      WORDPRESS_DB_HOST:     \${DB_HOST}:3306
      WORDPRESS_DB_NAME:     \${WORDPRESS_DB_NAME}
      WORDPRESS_DB_USER:     \${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD: \${WORDPRESS_DB_PASSWORD}
      AWS_ACCESS_KEY_ID:     \${AWS_ACCESS_KEY_ID}
      AWS_SECRET_ACCESS_KEY: \${AWS_SECRET_ACCESS_KEY}
      S3_BUCKET:             \${S3_BUCKET}
      S3_REGION:             \${S3_REGION}
      S3_PROVIDER:           \${S3_PROVIDER}
      S3_ENDPOINT:           \${S3_ENDPOINT}
      S3_CDN_DOMAIN:         \${S3_CDN_DOMAIN}
    volumes:
      - ./data:/var/www/html
      - ./uploads/php-uploads.ini:/usr/local/etc/php/conf.d/uploads.ini:ro
      - ./uploads/s3-config.php:/etc/wordpress/s3-config.php:ro
      - ./uploads/wp-config-extra.php:/var/www/html/wp-config-extra.php:ro
    networks: [${NET}]

  nginx:
    image: nginx:alpine
    restart: unless-stopped
    depends_on: [wordpress]
    volumes:
      - ./data:/var/www/html:ro
      - ./uploads/nginx-wp.conf:/etc/nginx/conf.d/default.conf:ro
      - ./logs:/var/log/nginx
    networks: [${NET}]
    ports:
      - "\${WG_IP}:\${HOST_PORT}:80"

networks:
  ${NET}:
    driver: bridge
    driver_opts:
      com.docker.network.bridge.enable_icc: "false"
YAML
}

# ════════════════════════════════════════════════════════════
# 业务功能模块
# ════════════════════════════════════════════════════════════

cmd_deploy() {
    header "启动 WordPress 分布式节点全自动部署向导"

    read -rp "请输入部署目录 [默认: ${DEFAULT_DIR}]: " DIR
    DIR="${DIR:-$DEFAULT_DIR}"
    read -rp "请输入本机对外监听端口 [默认: ${DEFAULT_PORT}]: " HOST_PORT
    HOST_PORT="${HOST_PORT:-$DEFAULT_PORT}"

    # 端口范围校验
    if ! [[ "$HOST_PORT" =~ ^[0-9]+$ ]] || (( HOST_PORT < 1 || HOST_PORT > 65535 )); then
        error "无效端口号: $HOST_PORT"
    fi

    info "--- 站点基础配置 ---"
    read -rp "请输入站点访问域名或公网IP (例如: https://wp.example.com): " WP_URL
    [[ -z "$WP_URL" ]] && error "站点 URL 不能为空"
    read -rp "请输入站点名称 [默认: Distributed WP]: " WP_TITLE
    WP_TITLE="${WP_TITLE:-Distributed WP}"
    read -rp "请输入管理员用户名 [默认: wpadmin]: " WP_ADMIN
    WP_ADMIN="${WP_ADMIN:-wpadmin}"

    local WP_PASS=""
    read_secret "请输入管理员密码 [留空则随机生成]: " WP_PASS
    if [[ -z "$WP_PASS" ]]; then
        WP_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9!@#%^&*()' < /dev/urandom | head -c 16)
        info "已随机生成管理员密码，请在部署完成后妥善保存。"
    fi

    read -rp "请输入管理员邮箱 [默认: admin@example.com]: " WP_EMAIL
    WP_EMAIL="${WP_EMAIL:-admin@example.com}"

    info "--- 数据库与缓存配置 (WireGuard 内网) ---"
    read -rp "请输入 MariaDB 的 WireGuard IP: " DB_HOST
    [[ -z "$DB_HOST" ]] && error "数据库 IP 不能为空"
    read -rp "请输入数据库库名 [默认: wordpress]: " DB_NAME
    DB_NAME="${DB_NAME:-wordpress}"
    read -rp "请输入数据库用户名 [默认: wpuser]: " DB_USER
    DB_USER="${DB_USER:-wpuser}"

    local DB_PW=""
    read_secret "请输入数据库密码: " DB_PW
    [[ -z "$DB_PW" ]] && error "数据库密码不能为空"

    read -rp "请输入 Redis 的 WireGuard IP [默认同数据库 ${DB_HOST}]: " REDIS_HOST
    REDIS_HOST="${REDIS_HOST:-$DB_HOST}"

    local REDIS_PW=""
    read_secret "请输入 Redis 连接密码: " REDIS_PW
    [[ -z "$REDIS_PW" ]] && error "Redis 密码不能为空"

    info "--- 对象存储配置 (AWS / Cloudflare R2 / MinIO) ---"
    echo "  1. AWS S3"
    echo "  2. Cloudflare R2"
    echo "  3. 其他/MinIO"
    read -rp "请选择存储提供商 [默认: 1]: " S3_CHOICE
    local S3_PROVIDER="aws"
    local S3_ENDPOINT=""
    case "${S3_CHOICE:-1}" in
        2) S3_PROVIDER="r2" ;;
        3) S3_PROVIDER="other" ;;
    esac

    read -rp "请输入 S3 存储桶名称: " S3_BUCKET
    [[ -z "$S3_BUCKET" ]] && error "存储桶名称不能为空"
    read -rp "请输入 S3 区域 [默认: us-east-1 / R2 填 auto]: " S3_REGION
    S3_REGION="${S3_REGION:-us-east-1}"

    if [[ "$S3_PROVIDER" != "aws" ]]; then
        read -rp "请输入自定义 Endpoint URL: " S3_ENDPOINT
        [[ -z "$S3_ENDPOINT" ]] && error "非 AWS 提供商必须填写 Endpoint"
    fi

    local S3_KEY=""
    local S3_SECRET=""
    read_secret "请输入 S3 Access Key ID: " S3_KEY
    [[ -z "$S3_KEY" ]] && error "S3 Key 不能为空"
    read_secret "请输入 S3 Secret Access Key: " S3_SECRET
    [[ -z "$S3_SECRET" ]] && error "S3 Secret 不能为空"
    read -rp "请输入绑定的 CDN 域名 [没有请留空]: " S3_CDN_DOMAIN
    S3_CDN_DOMAIN="${S3_CDN_DOMAIN:-}"

    # read_secret 内已统一去除首尾空白，此处无需重复处理

    # 获取 WireGuard IP，wg0 不存在则拒绝部署
    info "检测本机 WireGuard 接口地址..."
    local WG_IP=""
    if ip -4 addr show wg0 &>/dev/null; then
        WG_IP=$(ip -4 addr show wg0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
        log "检测到 wg0 IP: ${WG_IP}"
    else
        error "未找到 wg0 接口，拒绝部署。请先配置 WireGuard 后重试。"
    fi

    info "正在创建目录结构..."
    mkdir -p "$DIR"/{data,uploads,logs}
    local NET
    NET=$(net_name "$DIR")

    # .env 文件：仅 owner 可读，防止凭证泄露
    cat > "$DIR/.env" <<EOF
WORDPRESS_DB_PASSWORD=${DB_PW}
WORDPRESS_DB_NAME=${DB_NAME}
WORDPRESS_DB_USER=${DB_USER}
HOST_PORT=${HOST_PORT}
DB_HOST=${DB_HOST}
REDIS_HOST=${REDIS_HOST}
REDIS_PW=${REDIS_PW}
AWS_ACCESS_KEY_ID=${S3_KEY}
AWS_SECRET_ACCESS_KEY=${S3_SECRET}
S3_BUCKET=${S3_BUCKET}
S3_REGION=${S3_REGION}
S3_PROVIDER=${S3_PROVIDER}
S3_ENDPOINT=${S3_ENDPOINT}
S3_CDN_DOMAIN=${S3_CDN_DOMAIN}
WG_IP=${WG_IP}
EOF
    chmod 600 "$DIR/.env"

    _write_nginx_wp_conf    "$DIR/uploads/nginx-wp.conf"
    _write_php_uploads_ini  "$DIR/uploads/php-uploads.ini"
    _write_s3_config_php    "$DIR/uploads/s3-config.php"
    # FIX: 原脚本通过 `> "$DIR/..."` 重定向函数输出，但函数内同时向 stdout
    #      输出多段 heredoc 时行为不稳定（尤其在混用引号/非引号 heredoc 时）。
    #      修复：将目标路径作为参数传入，函数内直接写文件。
    _write_wp_config_extra  "$REDIS_HOST" "$REDIS_PW" "$DIR/uploads/wp-config-extra.php"

    _write_docker_compose "$DIR" "$NET"

    info "正在拉取镜像并启动容器..."
    if ! dc "$DIR" up -d 2>&1; then
        error "docker compose 启动失败，请检查 Docker 环境。"
    fi

    # 前台执行插件安装与配置，确保流程完整闭环
    if ! _wait_and_setup_plugin "$DIR" "true" \
            "$WP_URL" "$WP_TITLE" "$WP_ADMIN" "$WP_PASS" "$WP_EMAIL"; then
        warn "插件配置未完全成功，可通过菜单 6 重试。"
    fi

    log "WordPress 节点部署完成！"
    echo -e "  监听地址:   \e[33m${WG_IP}:${HOST_PORT}\e[0m"
    echo -e "  共享数据库: \e[33m${DB_HOST}\e[0m"
    echo -e "  共享缓存:   \e[33m${REDIS_HOST}\e[0m"
    echo -e "  对象存储桶: \e[33ms3://${S3_BUCKET}\e[0m"
}

cmd_status() {
    read -rp "请输入 WordPress 部署目录 [默认: ${DEFAULT_DIR}]: " DIR
    DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "目录 $DIR 中未找到 docker-compose.yml"
    header "节点运行状态"
    dc "$DIR" ps
}

cmd_logs() {
    read -rp "请输入 WordPress 部署目录 [默认: ${DEFAULT_DIR}]: " DIR
    DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "目录 $DIR 中未找到 docker-compose.yml"
    read -rp "查看哪个容器日志？(wordpress/nginx) [默认: wordpress]: " SVC
    SVC="${SVC:-wordpress}"
    dc "$DIR" logs -f --tail=100 "$SVC"
}

cmd_destroy() {
    read -rp "请输入要删除的节点目录 [默认: ${DEFAULT_DIR}]: " DIR
    DIR="${DIR:-$DEFAULT_DIR}"
    if [[ ! -f "$DIR/docker-compose.yml" ]]; then
        error "目录 $DIR 中未找到有效编排文件，请检查路径。"
    fi
    warn "此操作将停止并销毁容器与网桥，挂载的数据目录将完好保留。"
    read -rp "确认摧毁当前节点？请输入 'yes' 继续: " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        info "操作已取消。"
        return
    fi
    dc "$DIR" down --volumes --remove-orphans 2>/dev/null || true
    log "节点容器及网络已释放。本地目录 ${DIR} 已安全保留。"
}

cmd_stop() {
    read -rp "请输入要停止的节点目录 [默认: ${DEFAULT_DIR}]: " DIR
    DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "目录 $DIR 中未找到 docker-compose.yml"
    dc "$DIR" stop && log "节点服务已停止。"
}

cmd_start() {
    read -rp "请输入要启动的节点目录 [默认: ${DEFAULT_DIR}]: " DIR
    DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "目录 $DIR 中未找到 docker-compose.yml"
    dc "$DIR" up -d && log "节点已恢复运行。"
}

cmd_retry_plugins() {
    read -rp "请输入要维护的节点目录 [默认: ${DEFAULT_DIR}]: " DIR
    DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "目录 $DIR 中未找到 docker-compose.yml"
    # FIX: 原脚本菜单 6 直接传 "false"，若 WP 未安装则 _wait_and_setup_plugin
    #      立即 return 1 而无任何有效提示。现在在调用前检查容器状态。
    if ! dc "$DIR" ps --services --filter status=running | grep -q "wordpress"; then
        warn "wordpress 容器当前未运行，请先通过菜单 5 启动节点。"
        return
    fi
    _wait_and_setup_plugin "$DIR" "false" || warn "插件重试配置未完全成功，请查看上方日志。"
}

cmd_update() {
    read -rp "请输入要更新的节点目录 [默认: ${DEFAULT_DIR}]: " DIR
    DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "目录 $DIR 中未找到 docker-compose.yml"
    header "热更新计算节点组件"
    echo "  1. 仅升级 WordPress 镜像"
    echo "  2. 仅升级 Nginx 镜像"
    echo "  3. 全量升级整体集群"
    read -rp "请选择升级策略 [1-3]: " UP_CHOICE
    local SERVICES=""
    case "$UP_CHOICE" in
        1) SERVICES="wordpress" ;;
        2) SERVICES="nginx" ;;
        3) SERVICES="" ;;
        *) error "无效选择" ;;
    esac

    info "正在拉取最新镜像..."
    # FIX: 原脚本 `dc "$DIR" pull $SERVICES` 在 SERVICES 为空时，
    #      bash 的 set -u 会报 unbound variable（如果 SERVICES 未声明）。
    #      此处已通过 local SERVICES="" 避免，但仍统一使用数组安全传参。
    if [[ -n "$SERVICES" ]]; then
        dc "$DIR" pull "$SERVICES"
        dc "$DIR" up -d --force-recreate "$SERVICES"
    else
        dc "$DIR" pull
        dc "$DIR" up -d --force-recreate
    fi

    log "节点镜像升级完成。"
    dc "$DIR" ps
}

# ════════════════════════════════════════════════════════════
# 交互式主菜单
# ════════════════════════════════════════════════════════════
interactive_menu() {
    while true; do
        echo ""
        _c "1;35" "========================================"
        _c "1;35" "    WordPress 多节点分发管理 (自动化版)"
        _c "1;35" "========================================"
        echo -e "  \e[32m1.\e[0m 部署全新 WordPress 业务节点 (全自动建站)"
        echo -e "  \e[32m2.\e[0m 查看当前节点容器运行状态"
        echo -e "  \e[32m3.\e[0m 查看业务节点实时运行日志"
        echo -e "  \e[31m4.\e[0m 停止该节点服务"
        echo -e "  \e[32m5.\e[0m 启动该节点服务"
        echo -e "  \e[33m6.\e[0m 强制触发重试配置 / 手动安装并启用 S3 与 Redis 插件"
        echo -e "  \e[31m7.\e[0m 删除节点 (移除容器/网桥)"
        echo -e "  \e[36m8.\e[0m 滚动更新计算组件 (拉取最新镜像)"
        echo -e "  \e[36m0.\e[0m 退出管理向导"
        echo "----------------------------------------"
        read -rp "请输入功能序号并回车: " CHOICE

        case "$CHOICE" in
            1) cmd_deploy ;;
            2) cmd_status ;;
            3) cmd_logs ;;
            4) cmd_stop ;;
            5) cmd_start ;;
            6) cmd_retry_plugins ;;
            7) cmd_destroy ;;
            8) cmd_update ;;
            0) info "管理向导已退出。"; exit 0 ;;
            *) warn "无效输入，请重新输入可用序号" ;;
        esac

        echo ""
        read -rp "按回车键返回主管理菜单..."
        clear
    done
}

# 入口
clear
interactive_menu
