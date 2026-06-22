#!/usr/bin/env bash
# ============================================================
# wp-deploy.sh — WordPress 多节点全自动部署（内网 WG + S3 + Redis 闭环版）
# v2.3 新增：权限自动修复（entrypoint chown）+ rsync 多节点同步
# ============================================================
set -uo pipefail
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

BASE_DIR="${BASE_DIR:-/srv}"
DEFAULT_DIR="${BASE_DIR}/wordpress"
WG_IFACE="${WG_IFACE:-wg0}"
NODES_FILE="${BASE_DIR}/nodes.conf"

_c()     { printf "\e[%sm%s\e[0m\n" "$1" "$2"; }
log()    { _c "32"   "[成功] $*"; }
info()   { _c "36"   "[提示] $*"; }
warn()   { _c "33"   "[警告] $*"; }
error()  { _c "31"   "[错误] $*"; exit 1; }
header() { echo; _c "1;34" "=== $* ==="; }

# ── 获取 WireGuard 接口 IP ───────────────────────────
get_wg_ip() {
    local IP
    IP=$(ip addr show "${WG_IFACE}" 2>/dev/null \
        | awk '/inet /{gsub(/\/.*/, "", $2); print $2; exit}')
    [[ -n "$IP" ]] || error "无法获取 ${WG_IFACE} IP，请确认 WireGuard 已启动"
    echo "$IP"
}

# ── docker compose 统一入口 ──────────────────────────
dc() {
    local DIR="$1"; shift
    docker compose -f "$DIR/docker-compose.yml" --env-file "$DIR/.env" "$@"
}

# ── 容器内安装 WP-CLI ────────────────────────────────
_install_wpcli() {
    local DIR="$1"
    dc "$DIR" exec -T wordpress sh -c '
        set -e
        DEST="/usr/local/bin/wp"
        URL="https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"
        if command -v curl >/dev/null 2>&1; then
            curl -4 -fsSL "$URL" -o "$DEST"
        elif command -v wget >/dev/null 2>&1; then
            wget -T 15 --no-check-certificate -O "$DEST" "$URL"
        else
            echo "ERROR: 容器内既无 wget 也无 curl" >&2; exit 1
        fi
        chmod +x "$DEST"
    ' 2>&1
}

# ── wp-cli 封装 ──────────────────────────────────────
wp_cli() {
    local DIR="$1"; shift
    if ! dc "$DIR" exec -T wordpress test -f /usr/local/bin/wp 2>/dev/null; then
        _install_wpcli "$DIR" >/dev/null || true
    fi
    dc "$DIR" exec -T wordpress wp --allow-root "$@"
}

# ── 安全读取密码 ─────────────────────────────────────
read_secret() {
    local PROMPT="$1" VAR_NAME="$2" VALUE=""
    IFS= read -rp "$PROMPT" VALUE
    VALUE="${VALUE#"${VALUE%%[![:space:]]*}"}"
    VALUE="${VALUE%"${VALUE##*[![:space:]]}"}"
    printf -v "$VAR_NAME" '%s' "$VALUE"
}

# ════════════════════════════════════════════════════════
# 配置文件生成函数
# ════════════════════════════════════════════════════════

# ── Nginx 配置 ───────────────────────────────────────
_write_nginx_wp_conf() {
    local DEST="$1"
    local WG_IP="$2"
    sed "s/__WG_IP__/${WG_IP}/g" > "$DEST" <<'NGINX'
map $http_x_forwarded_proto $fastcgi_https {
    default "";
    https   "on";
}

upstream wordpress_fpm {
    server 127.0.0.1:9000;
    least_conn;
    keepalive 32;
}

server {
    listen __WG_IP__:80;
    root /var/www/html;
    index index.php index.html;
    client_max_body_size 2048M;

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
        fastcgi_param SCRIPT_FILENAME  $document_root$fastcgi_script_name;
        fastcgi_param HTTPS            $fastcgi_https if_not_empty;
        fastcgi_param HTTP_X_FORWARDED_PROTO $http_x_forwarded_proto;
        fastcgi_param HTTP_X_FORWARDED_FOR   $http_x_forwarded_for;
        fastcgi_param HTTP_X_REAL_IP         $http_x_real_ip;
        fastcgi_read_timeout 600;
        fastcgi_keep_conn on;
    }

    location ~* /(?:wp-config\.php|\.env|\.git) {
        deny all;
    }
}
NGINX
}

# ── PHP 上传限制 ini ─────────────────────────────────
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

# ── Media Cloud 配置 PHP ─────────────────────────────
_write_s3_config_php() {
    local DEST="$1"
    cat > "$DEST" <<'PHP'
<?php
// ── Media Cloud / ilab-media-tools 常量配置 ──────────
define('ILAB_MEDIA_S3_ACCESS_KEY',      getenv('AWS_ACCESS_KEY_ID'));
define('ILAB_MEDIA_S3_SECRET',          getenv('AWS_SECRET_ACCESS_KEY'));
define('ILAB_MEDIA_S3_BUCKET',          getenv('S3_BUCKET'));
define('ILAB_MEDIA_S3_REGION',          getenv('S3_REGION') ?: 'auto');
define('ILAB_MEDIA_S3_ENDPOINT',        getenv('S3_ENDPOINT') ?: '');
define('ILAB_MEDIA_S3_USE_PATH_STYLE',  false);
define('ILAB_MEDIA_S3_CDN_BASE',        getenv('S3_CDN_DOMAIN') ?: '');
define('ILAB_MEDIA_S3_DELETE_UPLOADS',  false);
define('ILAB_MEDIA_S3_UPLOAD_IMAGES',   true);
define('ILAB_MEDIA_S3_UPLOAD_VIDEOS',   true);
define('ILAB_MEDIA_S3_UPLOAD_AUDIO',    true);
define('ILAB_MEDIA_S3_UPLOAD_DOCS',     true);
PHP
}

# ── WordPress 额外配置 PHP ───────────────────────────
_write_wp_config_extra() {
    local DEST="$1"
    cat > "$DEST" <<'PHP'
<?php
// ── 可信代理判断（仅接受 WireGuard 内网段）────────────
function _wp_is_trusted_proxy(string $ip): bool {
    return (bool) preg_match(
        '/^(10\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.)/',
        $ip
    );
}

// ── 动态设置 WP_HOME / WP_SITEURL ────────────────────
if (php_sapi_name() !== 'cli') {
    $remote = $_SERVER['REMOTE_ADDR'] ?? '';

    if (_wp_is_trusted_proxy($remote)) {
        if (($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https') {
            $_SERVER['HTTPS'] = 'on';
        }

        $fwd_host = trim(explode(',', $_SERVER['HTTP_X_FORWARDED_HOST'] ?? '')[0]);

        if ($fwd_host !== '') {
            $scheme   = ($_SERVER['HTTPS'] ?? '') === 'on' ? 'https' : 'http';
            $site_url = $scheme . '://' . $fwd_host;
            if (!defined('WP_HOME')) {
                define('WP_HOME',    $site_url);
                define('WP_SITEURL', $site_url);
            }
        }
    }

    if (!defined('WP_HOME')) {
        $fallback = getenv('WP_SITEURL_FALLBACK') ?: '';
        if ($fallback !== '') {
            define('WP_HOME',    $fallback);
            define('WP_SITEURL', $fallback);
        }
    }
}

// ── Redis ────────────────────────────────────────────
$_redis_host = getenv('REDIS_HOST') ?: '127.0.0.1';
$_redis_pw   = getenv('REDIS_PW')   ?: '';
if (!defined('WP_REDIS_HOST')) {
    define('WP_REDIS_HOST',     $_redis_host);
    define('WP_REDIS_PORT',     6379);
    define('WP_REDIS_PASSWORD', $_redis_pw);
    define('WP_CACHE',          true);
}
define('WP_MEMORY_LIMIT',     '512M');
define('WP_MAX_MEMORY_LIMIT', '1024M');
if (extension_loaded('redis') && php_sapi_name() !== 'cli') {
    ini_set('session.save_handler', 'redis');
    ini_set('session.save_path',
        'tcp://' . $_redis_host . ':6379?auth=' . urlencode($_redis_pw));
}

// ── S3 ───────────────────────────────────────────────
if (file_exists('/etc/wordpress/s3-config.php')) {
    require_once '/etc/wordpress/s3-config.php';
}
PHP
}

# ── Dockerfile ──────────────────────────────────────
# 基于官方 WordPress 镜像追加 Redis PHP 扩展，
# 使 session.save_handler=redis 生效，同时保留对象缓存插件能力
_write_dockerfile() {
    local DEST="$1"
    cat > "$DEST" <<'DOCKERFILE'
FROM wordpress:php8.3-fpm-alpine

# 安装 curl（BusyBox wget 不支持 -4 强制 IPv4，curl 支持）
# 编译 Redis 扩展需要的构建工具，安装完即删除以控制镜像体积
RUN apk add --no-cache curl \
    && apk add --no-cache --virtual .build-deps $PHPIZE_DEPS \
    && pecl install redis \
    && docker-php-ext-enable redis \
    && apk del .build-deps \
    && rm -rf /tmp/pear
DOCKERFILE
}

# ── docker-compose.yml ───────────────────────────────
# entrypoint 每次容器启动时自动执行 chown，
# 修复宿主机卷挂载后 www-data 无写权限导致主题/插件上传失败的问题
_write_docker_compose() {
    local DIR="$1"
    cat > "$DIR/docker-compose.yml" <<'YAML'
services:
  wordpress:
    build:
      context: .
      dockerfile: Dockerfile
    image: wordpress-redis:php8.3-fpm-alpine
    restart: unless-stopped
    network_mode: host
    entrypoint: ["sh", "-c", "mkdir -p /var/www/html/wp-content && chown -R www-data:www-data /var/www/html/wp-content && exec docker-entrypoint.sh php-fpm"]
    environment:
      WORDPRESS_DB_HOST:      ${DB_HOST}:3306
      WORDPRESS_DB_NAME:      ${WORDPRESS_DB_NAME}
      WORDPRESS_DB_USER:      ${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD:  ${WORDPRESS_DB_PASSWORD}
      AWS_ACCESS_KEY_ID:      ${AWS_ACCESS_KEY_ID}
      AWS_SECRET_ACCESS_KEY:  ${AWS_SECRET_ACCESS_KEY}
      S3_BUCKET:              ${S3_BUCKET}
      S3_REGION:              ${S3_REGION}
      S3_PROVIDER:            ${S3_PROVIDER}
      S3_ENDPOINT:            ${S3_ENDPOINT}
      S3_CDN_DOMAIN:          ${S3_CDN_DOMAIN}
      REDIS_HOST:             ${REDIS_HOST}
      REDIS_PW:               ${REDIS_PW}
      WP_SITEURL_FALLBACK:    ${WP_SITEURL_FALLBACK}
      WORDPRESS_CONFIG_EXTRA: "require_once('/etc/wordpress/wp-config-extra.php');"
    volumes:
      - ./data:/var/www/html
      - ./uploads/php-uploads.ini:/usr/local/etc/php/conf.d/uploads.ini:ro
      - ./uploads/s3-config.php:/etc/wordpress/s3-config.php:ro
      - ./uploads/wp-config-extra.php:/etc/wordpress/wp-config-extra.php:ro

  nginx:
    image: nginx:alpine
    restart: unless-stopped
    network_mode: host
    depends_on:
      - wordpress
    volumes:
      - ./data:/var/www/html:ro
      - ./uploads/nginx-wp.conf:/etc/nginx/conf.d/default.conf:ro
      - ./logs:/var/log/nginx
YAML
}

# ════════════════════════════════════════════════════════
# 插件安装与 Redis 启用
# ════════════════════════════════════════════════════════
_wait_and_setup_plugin() {
    local DIR="$1"
    local IS_AUTO_INSTALL="${2:-false}"
    local URL="${3:-}"
    local TITLE="${4:-}"
    local ADMIN="${5:-}"
    local PASS="${6:-}"
    local EMAIL="${7:-}"
    local LOCALE="${8:-zh_CN}"
    local WP_CONFIG="/var/www/html/wp-config.php"

    # ── 等待 wp-config.php ──
    info "等待 wp-config.php 生成..."
    local RETRIES=45
    while ! dc "$DIR" exec -T wordpress grep -q "ABSPATH" "$WP_CONFIG" 2>/dev/null; do
        sleep 2
        RETRIES=$((RETRIES - 1))
        if [[ $RETRIES -le 0 ]]; then
            warn "wp-config.php 超时，请检查容器日志。"
            return 1
        fi
    done

    # ── 验证 WP-CLI ──
    info "验证 WP-CLI..."
    if ! dc "$DIR" exec -T wordpress test -f /usr/local/bin/wp 2>/dev/null; then
        if ! _install_wpcli "$DIR"; then
            warn "WP-CLI 安装失败。"
            return 1
        fi
    fi

    # ── 核心安装 ──
    if [[ "$IS_AUTO_INSTALL" == "true" ]]; then
        if ! wp_cli "$DIR" core is-installed &>/dev/null; then
            info "空数据库，安装 WordPress 核心..."
            if ! wp_cli "$DIR" core install \
                --url="$URL" --title="$TITLE" \
                --admin_user="$ADMIN" --admin_password="$PASS" \
                --admin_email="$EMAIL" --locale="$LOCALE" --skip-email; then
                warn "安装失败，请查看日志。"
                return 1
            fi
            log "WordPress 安装成功！"
            echo -e "  站点: \e[32m${URL}\e[0m"
            echo -e "  账号: \e[32m${ADMIN}\e[0m / 密码: \e[32m${PASS}\e[0m"

            if [[ "$LOCALE" != "en_US" && -n "$LOCALE" ]]; then
                info "安装并激活语言包: ${LOCALE}..."
                wp_cli "$DIR" language core install "$LOCALE" 2>/dev/null || true

                # 同时更新 WPLANG 和 user_locale（管理员后台语言）
                wp_cli "$DIR" option update WPLANG "$LOCALE" || true

                local ADMIN_ID
                ADMIN_ID=$(wp_cli "$DIR" user get "$ADMIN" --field=ID 2>/dev/null || echo "1")
                wp_cli "$DIR" user meta update "$ADMIN_ID" locale "$LOCALE" 2>/dev/null || true

                # 刷新缓存，否则 Redis 会缓存旧的 en_US
                wp_cli "$DIR" cache flush 2>/dev/null || true
                wp_cli "$DIR" rewrite flush 2>/dev/null || true

                log "界面语言已设为 ${LOCALE}"
            fi

            fi
        else
            log "数据库已有数据，跳过安装。"
        fi
    else
        if ! wp_cli "$DIR" core is-installed &>/dev/null; then
            warn "WordPress 未初始化，请通过菜单 1 重新部署。"
            return 1
        fi
    fi

    # ── 修复文件权限 ──
    info "修复文件权限..."
    dc "$DIR" exec -T wordpress chown -R www-data:www-data /var/www/html/wp-content || true

    # ── Media Cloud 插件 ──
    info "配置 Media Cloud 插件..."
    if wp_cli "$DIR" plugin is-installed amazon-s3-and-cloudfront &>/dev/null; then
        wp_cli "$DIR" plugin deactivate amazon-s3-and-cloudfront 2>/dev/null || true
        wp_cli "$DIR" plugin delete amazon-s3-and-cloudfront 2>/dev/null || true
        info "已移除旧版 AS3CF 插件。"
    fi
    if wp_cli "$DIR" plugin is-installed ilab-media-tools &>/dev/null; then
        if ! wp_cli "$DIR" plugin activate ilab-media-tools; then
            warn "Media Cloud 插件激活失败。"
        fi
    else
        if ! wp_cli "$DIR" plugin install ilab-media-tools --activate; then
            warn "Media Cloud 插件安装失败。"
        fi
    fi

    # ── Redis 插件 ──
    info "配置 Redis 插件..."
    if wp_cli "$DIR" plugin is-installed redis-cache &>/dev/null; then
        if ! wp_cli "$DIR" plugin activate redis-cache; then
            warn "Redis 插件激活失败。"
        fi
    else
        if ! wp_cli "$DIR" plugin install redis-cache --activate; then
            warn "Redis 插件安装失败。"
        fi
    fi

    # ── 探测连通性后启用对象缓存 ──
    info "探测 Redis 连通性..."
    local REDIS_HOST_VAL
    REDIS_HOST_VAL=$(grep '^REDIS_HOST=' "$DIR/.env" | cut -d= -f2-)
    local PROBE_CODE="\$c=@fsockopen('${REDIS_HOST_VAL}',6379,\$e,\$s,5);if(\$c){fclose(\$c);exit(0);}exit(1);"
    if dc "$DIR" exec -T wordpress php -r "$PROBE_CODE" 2>/dev/null; then
        if ! wp_cli "$DIR" redis enable; then
            warn "redis enable 失败，请检查密码或插件状态。"
        else
            log "Redis 对象缓存已启用！"
        fi
    else
        warn "无法连接 Redis (${REDIS_HOST_VAL}:6379)，跳过启用。"
    fi
}

# ════════════════════════════════════════════════════════
# 业务命令
# ════════════════════════════════════════════════════════
cmd_deploy() {
    header "WordPress 分布式节点全自动部署（WG 内网闭环）"

    read -rp "部署目录 [默认: ${DEFAULT_DIR}]: " DIR
    DIR="${DIR:-$DEFAULT_DIR}"

    read -rp "Nginx 监听端口 [默认: 80]: " HOST_PORT
    HOST_PORT="${HOST_PORT:-80}"
    [[ "$HOST_PORT" =~ ^[0-9]+$ ]] && (( HOST_PORT >= 1 && HOST_PORT <= 65535 )) \
        || error "无效端口: $HOST_PORT"

    info "--- 站点配置 ---"
    read -rp "初始安装 URL（如 https://example.com）: " WP_URL
    [[ -z "$WP_URL" ]] && error "URL 不能为空"
    read -rp "站点名称 [默认: Distributed WP]: " WP_TITLE
    WP_TITLE="${WP_TITLE:-Distributed WP}"
    read -rp "安装语言 [默认: zh_CN]: " WP_LOCALE
    WP_LOCALE="${WP_LOCALE:-zh_CN}"
    read -rp "管理员用户名 [默认: wpadmin]: " WP_ADMIN
    WP_ADMIN="${WP_ADMIN:-wpadmin}"

    local WP_PASS=""
    read_secret "管理员密码 [留空随机生成]: " WP_PASS
    if [[ -z "$WP_PASS" ]]; then
        WP_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9!@#%^&*()' < /dev/urandom | head -c 16)
        info "已生成随机密码: ${WP_PASS}"
    fi

    read -rp "管理员邮箱 [默认: admin@example.com]: " WP_EMAIL
    WP_EMAIL="${WP_EMAIL:-admin@example.com}"

    info "--- 数据库 ---"
    read -rp "MariaDB WireGuard IP（不含端口，如 10.10.0.2）: " DB_HOST
    [[ -z "$DB_HOST" ]] && error "数据库 IP 不能为空"
    DB_HOST="${DB_HOST%%:*}"

    read -rp "数据库名 [默认: wordpress]: " DB_NAME
    DB_NAME="${DB_NAME:-wordpress}"
    read -rp "数据库用户名 [默认: wpuser]: " DB_USER
    DB_USER="${DB_USER:-wpuser}"
    local DB_PW=""
    read_secret "数据库密码: " DB_PW
    [[ -z "$DB_PW" ]] && error "数据库密码不能为空"

    info "--- Redis ---"
    read -rp "Redis WireGuard IP [默认同数据库 ${DB_HOST}]: " REDIS_HOST
    REDIS_HOST="${REDIS_HOST:-$DB_HOST}"
    REDIS_HOST="${REDIS_HOST%%:*}"
    local REDIS_PW=""
    read_secret "Redis 密码: " REDIS_PW
    [[ -z "$REDIS_PW" ]] && error "Redis 密码不能为空"

    info "--- 对象存储 ---"
    echo "  1. AWS S3"
    echo "  2. Cloudflare R2"
    echo "  3. 其他 S3 兼容（MinIO 等）"
    read -rp "选择 [默认: 1]: " S3_CHOICE
    local S3_PROVIDER="aws" S3_ENDPOINT="" S3_REGION=""
    case "${S3_CHOICE:-1}" in
        2) S3_PROVIDER="cloudflare"
           read -rp "R2 Endpoint URL (https://xxx.r2.cloudflarestorage.com): " S3_ENDPOINT
           [[ -z "$S3_ENDPOINT" ]] && error "R2 必须填写 Endpoint"
           read -rp "区域 [默认: auto]: " S3_REGION
           S3_REGION="${S3_REGION:-auto}" ;;
        3) S3_PROVIDER="other"
           read -rp "自定义 Endpoint URL: " S3_ENDPOINT
           [[ -z "$S3_ENDPOINT" ]] && error "非 AWS 提供商必须填写 Endpoint"
           read -rp "区域 [默认: us-east-1]: " S3_REGION
           S3_REGION="${S3_REGION:-us-east-1}" ;;
        *) S3_PROVIDER="aws"
           read -rp "区域 [默认: us-east-1]: " S3_REGION
           S3_REGION="${S3_REGION:-us-east-1}" ;;
    esac
    read -rp "存储桶名称: " S3_BUCKET
    [[ -z "$S3_BUCKET" ]] && error "桶名不能为空"
    local S3_KEY="" S3_SECRET=""
    read_secret "S3 Access Key ID: " S3_KEY
    [[ -z "$S3_KEY" ]] && error "S3 Key 不能为空"
    read_secret "S3 Secret Access Key: " S3_SECRET
    [[ -z "$S3_SECRET" ]] && error "S3 Secret 不能为空"
    read -rp "CDN 域名（留空跳过）: " S3_CDN_DOMAIN
    S3_CDN_DOMAIN="${S3_CDN_DOMAIN:-}"

    local WG_IP
    WG_IP=$(get_wg_ip)
    log "WireGuard IP: ${WG_IP}"

    info "生成配置文件..."
    mkdir -p "$DIR"/{data,uploads,logs}

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
WP_SITEURL_FALLBACK=${WP_URL}
EOF
    chmod 600 "$DIR/.env"

    _write_dockerfile      "$DIR/Dockerfile"
    _write_nginx_wp_conf   "$DIR/uploads/nginx-wp.conf" "$WG_IP"
    _write_php_uploads_ini "$DIR/uploads/php-uploads.ini"
    _write_s3_config_php   "$DIR/uploads/s3-config.php"
    _write_wp_config_extra "$DIR/uploads/wp-config-extra.php"
    _write_docker_compose  "$DIR"

    # 部署时自动注册当前节点
    _register_node "$WG_IP"

    info "启动容器..."
    dc "$DIR" up -d || error "容器启动失败，请检查 Docker 环境。"

    _wait_and_setup_plugin "$DIR" "true" \
        "$WP_URL" "$WP_TITLE" "$WP_ADMIN" "$WP_PASS" "$WP_EMAIL" "$WP_LOCALE" \
        || warn "插件配置未完全成功，可通过菜单 6 重试。"

    log "节点部署完成！"
    echo -e "  内网访问: \e[33mhttp://${WG_IP}:${HOST_PORT}\e[0m"
    echo -e "  初始站点: \e[33m${WP_URL}\e[0m"
    echo -e "  \e[36m换域名只需改网关 X-Forwarded-Host，容器无需重启。\e[0m"
    echo -e "  \e[36m上传主题/插件后可通过菜单 10 同步到其他节点。\e[0m"
}

# ── 注册节点 IP 到 nodes.conf ────────────────────────
_register_node() {
    local IP="$1"
    touch "$NODES_FILE"
    if ! grep -qxF "$IP" "$NODES_FILE"; then
        echo "$IP" >> "$NODES_FILE"
        log "节点 ${IP} 已注册到 ${NODES_FILE}"
    fi
}

# ── 同步主题和插件到所有节点 ────────────────────────
# 仅同步 themes/ 和 plugins/：
#   - uploads/ 媒体文件走 R2，无需同步
#   - cache/   各节点独立缓存，不应互相覆盖
cmd_sync() {
    header "同步主题 / 插件到所有节点"

    read -rp "源节点目录 [默认: ${DEFAULT_DIR}]: " SRC_DIR
    SRC_DIR="${SRC_DIR:-$DEFAULT_DIR}"
    [[ -f "$SRC_DIR/.env" ]] || error "未找到 .env：${SRC_DIR}"

    [[ -f "$NODES_FILE" ]] || error "未找到节点列表：${NODES_FILE}（每行一个 WireGuard IP）"

    local CURRENT_IP
    CURRENT_IP=$(get_wg_ip)

    read -rp "目标节点部署目录 [默认: ${DEFAULT_DIR}]: " DEST_DIR
    DEST_DIR="${DEST_DIR:-$DEFAULT_DIR}"

    local SYNC_OK=0 SYNC_FAIL=0
    while IFS= read -r NODE_IP; do
        [[ -z "$NODE_IP" || "$NODE_IP" == "#"* ]] && continue
        [[ "$NODE_IP" == "$CURRENT_IP" ]] && continue

        info "→ 同步到 ${NODE_IP}..."

        local FAILED=false

        rsync -az --delete \
            --exclude='cache/' \
            -e "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10" \
            "$SRC_DIR/data/wp-content/themes/" \
            "root@${NODE_IP}:${DEST_DIR}/data/wp-content/themes/" \
        || FAILED=true

        rsync -az --delete \
            --exclude='cache/' \
            -e "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10" \
            "$SRC_DIR/data/wp-content/plugins/" \
            "root@${NODE_IP}:${DEST_DIR}/data/wp-content/plugins/" \
        || FAILED=true

        if [[ "$FAILED" == "true" ]]; then
            warn "→ ${NODE_IP} 同步失败，请检查 SSH 连通性。"
            SYNC_FAIL=$((SYNC_FAIL + 1))
        else
            log "→ ${NODE_IP} 同步完成。"
            SYNC_OK=$((SYNC_OK + 1))
        fi
    done < "$NODES_FILE"

    echo ""
    log "同步结束：成功 ${SYNC_OK} 个节点，失败 ${SYNC_FAIL} 个节点。"
    if (( SYNC_FAIL > 0 )); then
        warn "失败节点请确认：1) SSH 免密登录已配置  2) 目标路径存在  3) WireGuard 已连通"
    fi
}

# ── 节点列表管理 ─────────────────────────────────────
cmd_nodes() {
    header "节点列表管理"
    echo "  1. 列出所有节点"
    echo "  2. 添加节点"
    echo "  3. 删除节点"
    read -rp "选择: " NODE_CHOICE
    case "$NODE_CHOICE" in
        1)
            if [[ ! -f "$NODES_FILE" ]] || [[ ! -s "$NODES_FILE" ]]; then
                warn "节点列表为空：${NODES_FILE}"
            else
                echo ""
                nl -ba "$NODES_FILE"
            fi
            ;;
        2)
            read -rp "节点 WireGuard IP: " NEW_IP
            [[ -z "$NEW_IP" ]] && error "IP 不能为空"
            _register_node "$NEW_IP"
            ;;
        3)
            if [[ ! -f "$NODES_FILE" ]]; then
                warn "节点列表不存在。"
                return
            fi
            nl -ba "$NODES_FILE"
            read -rp "输入要删除的行号: " LINE_NUM
            [[ "$LINE_NUM" =~ ^[0-9]+$ ]] || error "无效行号"
            sed -i "${LINE_NUM}d" "$NODES_FILE"
            log "已删除第 ${LINE_NUM} 行。"
            ;;
        *) warn "无效输入" ;;
    esac
}

cmd_status() {
    read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR; DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"
    dc "$DIR" ps
}

cmd_logs() {
    read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR; DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"
    read -rp "容器 (wordpress/nginx) [默认: wordpress]: " SVC; SVC="${SVC:-wordpress}"
    dc "$DIR" logs -f --tail=100 "$SVC"
}

cmd_destroy() {
    read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR; DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"
    warn "将停止容器并删除全部数据（不可恢复）。"
    read -rp "输入 'yes' 确认: " CONFIRM
    [[ "$CONFIRM" != "yes" ]] && { info "已取消"; return; }
    dc "$DIR" down --volumes --remove-orphans 2>/dev/null || true
    rm -rf "$DIR"
    log "节点及数据已完全删除：${DIR}"
}

cmd_stop() {
    read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR; DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"
    dc "$DIR" stop && log "已停止。"
}

cmd_start() {
    read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR; DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"
    dc "$DIR" up -d && log "已启动。"
}

cmd_retry_plugins() {
    read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR; DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"
    dc "$DIR" ps --services --filter status=running | grep -q "wordpress" \
        || { warn "wordpress 容器未运行，请先启动。"; return; }
    _wait_and_setup_plugin "$DIR" "false" || warn "插件配置未完全成功。"
}

cmd_update() {
    read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR; DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"
    header "滚动更新"
    echo "  1. WordPress（拉取基础镜像并重建）"
    echo "  2. Nginx"
    echo "  3. 全部"
    read -rp "选择: " UP_CHOICE
    local SVC=""
    case "$UP_CHOICE" in
        1) SVC="wordpress" ;; 2) SVC="nginx" ;; 3) SVC="" ;; *) error "无效选择" ;;
    esac
    if [[ "$SVC" == "wordpress" || -z "$SVC" ]]; then
        info "重建 WordPress 镜像（含 Redis 扩展）..."
        dc "$DIR" build --pull --no-cache wordpress
    fi
    if [[ -n "$SVC" && "$SVC" != "wordpress" ]]; then
        dc "$DIR" pull "$SVC" && dc "$DIR" up -d --force-recreate "$SVC"
    else
        dc "$DIR" up -d --force-recreate
    fi
    log "更新完成。"; dc "$DIR" ps
}

cmd_fix_env() {
    read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR; DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/.env" ]] || error "未找到 .env 文件"

    local CURRENT_DB_HOST
    CURRENT_DB_HOST=$(grep '^DB_HOST=' "$DIR/.env" | cut -d= -f2-)
    local CLEAN_DB_HOST="${CURRENT_DB_HOST%%:*}"
    if [[ "$CURRENT_DB_HOST" != "$CLEAN_DB_HOST" ]]; then
        sed -i "s|^DB_HOST=.*|DB_HOST=${CLEAN_DB_HOST}|" "$DIR/.env"
        log "DB_HOST 已修正: ${CURRENT_DB_HOST} → ${CLEAN_DB_HOST}"
    else
        log "DB_HOST 无需修正: ${CURRENT_DB_HOST}"
    fi

    if ! grep -q '^WP_SITEURL_FALLBACK=' "$DIR/.env"; then
        read -rp "请输入站点 URL（用于 Gutenberg 兜底，如 https://example.com）: " FALLBACK_URL
        [[ -z "$FALLBACK_URL" ]] && error "URL 不能为空"
        echo "WP_SITEURL_FALLBACK=${FALLBACK_URL}" >> "$DIR/.env"
        log "已写入 WP_SITEURL_FALLBACK=${FALLBACK_URL}"
    else
        log "WP_SITEURL_FALLBACK 已存在，跳过。"
    fi

    info "同步 wp-config-extra.php..."
    _write_wp_config_extra "$DIR/uploads/wp-config-extra.php"
    log "wp-config-extra.php 已更新。"

    info "同步 s3-config.php..."
    _write_s3_config_php "$DIR/uploads/s3-config.php"
    log "s3-config.php 已更新。"

    # 同步 Dockerfile（如旧部署缺失）
    if [[ ! -f "$DIR/Dockerfile" ]]; then
        info "生成 Dockerfile（含 Redis 扩展）..."
        _write_dockerfile "$DIR/Dockerfile"
        log "Dockerfile 已生成。"
    fi

    echo ""
    echo "  1. 仅重启容器（不重建镜像）"
    echo "  2. 重建镜像后重启（首次加 Redis 扩展时选此项）"
    echo "  0. 暂不操作"
    read -rp "选择 [默认: 0]: " RESTART_CHOICE
    case "${RESTART_CHOICE:-0}" in
        1)
            dc "$DIR" up -d --force-recreate && log "容器已重启。"
            ;;
        2)
            info "重建镜像中（首次需编译 Redis 扩展，约 1-2 分钟）..."
            dc "$DIR" build --no-cache wordpress \
                && dc "$DIR" up -d --force-recreate \
                && log "镜像重建完成，容器已重启。"
            ;;
        *)
            warn "请手动执行: docker compose -f $DIR/docker-compose.yml --env-file $DIR/.env up -d --force-recreate"
            ;;
    esac
}

# ════════════════════════════════════════════════════════
# 主菜单
# ════════════════════════════════════════════════════════
interactive_menu() {
    while true; do
        echo ""
        _c "1;35" "========================================"
        _c "1;35" "    WordPress 多节点分发管理 (host 网络)"
        _c "1;35" "========================================"
        echo -e "  \e[32m 1.\e[0m 部署新节点 (全自动建站)"
        echo -e "  \e[32m 2.\e[0m 查看状态"
        echo -e "  \e[32m 3.\e[0m 查看日志"
        echo -e "  \e[31m 4.\e[0m 停止节点"
        echo -e "  \e[32m 5.\e[0m 启动节点"
        echo -e "  \e[33m 6.\e[0m 重试插件配置"
        echo -e "  \e[31m 7.\e[0m 删除节点"
        echo -e "  \e[36m 8.\e[0m 更新镜像"
        echo -e "  \e[33m 9.\e[0m 修复现有部署 .env"
        echo -e "  \e[36m10.\e[0m 同步主题 / 插件到所有节点"
        echo -e "  \e[36m11.\e[0m 节点列表管理"
        echo -e "  \e[36m 0.\e[0m 退出"
        echo "----------------------------------------"
        read -rp "选择: " CHOICE
        case "$CHOICE" in
            1)  cmd_deploy ;;
            2)  cmd_status ;;
            3)  cmd_logs ;;
            4)  cmd_stop ;;
            5)  cmd_start ;;
            6)  cmd_retry_plugins ;;
            7)  cmd_destroy ;;
            8)  cmd_update ;;
            9)  cmd_fix_env ;;
            10) cmd_sync ;;
            11) cmd_nodes ;;
            0)  info "再见！"; exit 0 ;;
            *)  warn "无效输入" ;;
        esac
        read -rp "按回车继续..."
        clear
    done
}

clear
interactive_menu
