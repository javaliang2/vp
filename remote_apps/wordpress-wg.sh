#!/usr/bin/env bash
# ============================================================
# wp-deploy.sh — WordPress 多节点全自动部署（内网 WG + S3 + Redis 闭环版）
# 修复：host 网络 + WORDPRESS_CONFIG_EXTRA + get_wg_ip
# ============================================================
set -uo pipefail
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

BASE_DIR="${BASE_DIR:-/srv}"
DEFAULT_DIR="${BASE_DIR}/wordpress"
DEFAULT_PORT="8080"
WG_IFACE="${WG_IFACE:-wg0}"

_c()     { printf "\e[%sm%s\e[0m\n" "$1" "$2"; }
log()    { _c "32"   "[成功] $*"; }
info()   { _c "36"   "[提示] $*"; }
warn()   { _c "33"   "[警告] $*"; }
error()  { _c "31"   "[错误] $*"; exit 1; }
header() { echo; _c "1;34" "=== $* ==="; }

# 获取 WireGuard 接口 IP
get_wg_ip() {
    local IP
    IP=$(ip addr show "${WG_IFACE}" 2>/dev/null \
        | awk '/inet /{gsub(/\/.*/, "", $2); print $2; exit}')
    [[ -n "$IP" ]] || error "无法获取 ${WG_IFACE} IP，请确认 WireGuard 已启动"
    echo "$IP"
}

# dc 统一入口（保留，用于 exec 等操作）
dc() {
    local DIR="$1"; shift
    docker compose -f "$DIR/docker-compose.yml" --env-file "$DIR/.env" "$@"
}

# 在 wordpress 容器内安装 WP-CLI
_install_wpcli() {
    local DIR="$1"
    dc "$DIR" exec -T wordpress sh -c '
        set -e
        WPCLI_URL="https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"
        DEST="/usr/local/bin/wp"
        if command -v wget >/dev/null 2>&1; then
            wget --no-check-certificate -O "$DEST" "$WPCLI_URL"
        elif command -v curl >/dev/null 2>&1; then
            curl -fsSL "$WPCLI_URL" -o "$DEST"
        else
            echo "ERROR: 容器内既无 wget 也无 curl" >&2
            exit 1
        fi
        chmod +x "$DEST"
    ' 2>&1
}

# wp-cli 封装
wp_cli() {
    local DIR="$1"; shift
    if ! dc "$DIR" exec -T wordpress test -f /usr/local/bin/wp 2>/dev/null; then
        _install_wpcli "$DIR" >/dev/null || true
    fi
    dc "$DIR" exec -T wordpress wp --allow-root "$@"
}

# 安全读取密码（明文模式，可粘贴）
read_secret() {
    local PROMPT="$1"
    local VAR_NAME="$2"
    local VALUE=""
    IFS= read -rp "$PROMPT" VALUE
    VALUE="${VALUE#"${VALUE%%[![:space:]]*}"}"
    VALUE="${VALUE%"${VALUE##*[![:space:]]}"}"
    printf -v "$VAR_NAME" '%s' "$VALUE"
}

# ── 生成 Nginx 配置（仅监听 WG IP:80）──────────────
_write_nginx_wp_conf() {
    local DEST="$1"
    local WG_IP="$2"
    cat > "$DEST" <<NGINX
upstream wordpress_fpm {
    server 127.0.0.1:9000;
    least_conn;
    keepalive 32;
}

map $http_x_forwarded_proto $fastcgi_https {
    default  "";
    https    "on";
}

upstream wordpress_fpm {
    server 127.0.0.1:9000;
    least_conn;
    keepalive 32;
}

server {
    listen ${WG_IP}:80;
    root /var/www/html;
    index index.php index.html;
    client_max_body_size 2048M;

    # 将网关传来的真实协议头传给 PHP
    # 已通过 map 定义为 $fastcgi_https

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
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param HTTPS $fastcgi_https if_not_empty;
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

# ── 生成 PHP 上传限制 ini ────────────────────────────
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

# ── 生成 S3 配置 PHP（挂载到 /etc/wordpress）────────
_write_s3_config_php() {
    local DEST="$1"
    cat > "$DEST" <<'PHP'
<?php
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

# ── 生成 docker-compose.yml（host 网络）─────────────
_write_docker_compose() {
    local DIR="$1"
    cat > "$DIR/docker-compose.yml" <<YAML
services:
  wordpress:
    image: wordpress:php8.3-fpm-alpine
    restart: unless-stopped
    network_mode: host
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
      REDIS_HOST:            \${REDIS_HOST}
      REDIS_PW:              \${REDIS_PW}
      WORDPRESS_CONFIG_EXTRA: |
        <?php
        \$redis_host = getenv('REDIS_HOST');
        \$redis_pw   = getenv('REDIS_PW');
        define('WP_REDIS_HOST', \$redis_host);
        define('WP_REDIS_PORT', 6379);
        define('WP_REDIS_AUTH', \$redis_pw ?: '');
        define('WP_CACHE', true);
        define('WP_MEMORY_LIMIT', '512M');
        define('WP_MAX_MEMORY_LIMIT', '1024M');
        if (extension_loaded('redis')) {
            ini_set('session.save_handler', 'redis');
            ini_set('session.save_path',
                'tcp://'.\$redis_host.':6379?auth='.urlencode(\$redis_pw));
        }
        if (file_exists('/etc/wordpress/s3-config.php')) {
            require_once '/etc/wordpress/s3-config.php';
        }
    volumes:
      - ./data:/var/www/html
      - ./uploads/php-uploads.ini:/usr/local/etc/php/conf.d/uploads.ini:ro
      - ./uploads/s3-config.php:/etc/wordpress/s3-config.php:ro

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

# ── 等待 & 配置插件（核心安装）─────────────────────
_wait_and_setup_plugin() {
    local DIR="$1"
    local IS_AUTO_INSTALL="${2:-false}"
    local URL="${3:-}"
    local TITLE="${4:-}"
    local ADMIN="${5:-}"
    local PASS="${6:-}"
    local EMAIL="${7:-}"
    local WP_CONFIG="/var/www/html/wp-config.php"

    info "检测 WordPress 初始化状态..."
    local CFG_RETRIES=45
    while ! dc "$DIR" exec -T wordpress grep -q "ABSPATH" "$WP_CONFIG" 2>/dev/null; do
        sleep 2
        CFG_RETRIES=$((CFG_RETRIES - 1))
        if [[ $CFG_RETRIES -le 0 ]]; then
            warn "wp-config.php 生成超时，请检查日志。"
            return 1
        fi
    done

    info "验证 WP-CLI 状态..."
    if ! dc "$DIR" exec -T wordpress test -f /usr/local/bin/wp 2>/dev/null; then
        if ! _install_wpcli "$DIR"; then
            warn "WP-CLI 安装失败，请检查外网连通性。"
            return 1
        fi
    fi

    # 全自动核心安装
    if [[ "$IS_AUTO_INSTALL" == "true" ]]; then
        if ! wp_cli "$DIR" core is-installed &>/dev/null; then
            info "空数据库，正在安装 WordPress 核心..."
            if wp_cli "$DIR" core install \
                    --url="$URL" \
                    --title="$TITLE" \
                    --admin_user="$ADMIN" \
                    --admin_password="$PASS" \
                    --admin_email="$EMAIL" \
                    --skip-email; then
                log "WordPress 安装成功！"
                echo -e "  站点: \e[32m${URL}\e[0m"
                echo -e "  账号: \e[32m${ADMIN}\e[0m"
                echo -e "  密码: \e[32m${PASS}\e[0m"
            else
                warn "安装失败，请查看日志。"
                return 1
            fi
        else
            log "数据库已有数据，跳过安装。"
        fi
    else
        if ! wp_cli "$DIR" core is-installed &>/dev/null; then
            warn "WordPress 尚未初始化，请通过菜单 1 重新部署。"
            return 1
        fi
    fi

    info "修复文件权限..."
    dc "$DIR" exec -T wordpress chown -R www-data:www-data /var/www/html/wp-content || true

    # S3 插件
    info "配置 S3 插件..."
    if wp_cli "$DIR" plugin is-installed amazon-s3-and-cloudfront &>/dev/null; then
        wp_cli "$DIR" plugin activate amazon-s3-and-cloudfront || warn "S3 插件激活失败。"
    else
        wp_cli "$DIR" plugin install amazon-s3-and-cloudfront --activate || warn "S3 插件安装失败。"
    fi

    # Redis 插件
    info "配置 Redis 插件..."
    if wp_cli "$DIR" plugin is-installed redis-cache &>/dev/null; then
        wp_cli "$DIR" plugin activate redis-cache || warn "Redis 插件激活失败。"
    else
        wp_cli "$DIR" plugin install redis-cache --activate || warn "Redis 插件安装失败。"
    fi

    # 启用 Redis 对象缓存
    info "探测 Redis 连通性..."
    local REDIS_HOST_VAL
    REDIS_HOST_VAL=$(grep '^REDIS_HOST=' "$DIR/.env" | cut -d= -f2)
    if dc "$DIR" exec -T wordpress sh -c \
        "nc -zw5 '${REDIS_HOST_VAL}' 6379" 2>/dev/null; then
        info "激活 Redis Object Cache..."
        if wp_cli "$DIR" redis enable; then
            log "Redis 对象缓存已启用！"
        else
            warn "Redis enable 失败，请检查密码或插件状态。"
        fi
    else
        warn "无法连接 Redis (${REDIS_HOST_VAL}:6379)，跳过启用。"
    fi
}

# ══════════════════════════════════════════════════════
# 业务菜单函数
# ══════════════════════════════════════════════════════

cmd_deploy() {
    header "WordPress 分布式节点全自动部署（WG 内网闭环）"

    read -rp "部署目录 [默认: ${DEFAULT_DIR}]: " DIR
    DIR="${DIR:-$DEFAULT_DIR}"
    read -rp "Nginx 监听端口（WG IP 上） [默认: 80]: " HOST_PORT
    HOST_PORT="${HOST_PORT:-80}"
    if ! [[ "$HOST_PORT" =~ ^[0-9]+$ ]] || (( HOST_PORT < 1 || HOST_PORT > 65535 )); then
        error "无效端口: $HOST_PORT"
    fi

    info "--- 站点配置 ---"
    read -rp "站点访问 URL（如 http://你的域名 或 http://WG_IP）: " WP_URL
    [[ -z "$WP_URL" ]] && error "URL 不能为空"
    read -rp "站点名称 [默认: Distributed WP]: " WP_TITLE
    WP_TITLE="${WP_TITLE:-Distributed WP}"
    read -rp "管理员用户名 [默认: wpadmin]: " WP_ADMIN
    WP_ADMIN="${WP_ADMIN:-wpadmin}"

    local WP_PASS=""
    read_secret "管理员密码 [留空随机生成]: " WP_PASS
    if [[ -z "$WP_PASS" ]]; then
        WP_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9!@#%^&*()' < /dev/urandom | head -c 16)
        info "已生成随机密码。"
    fi

    read -rp "管理员邮箱 [默认: admin@example.com]: " WP_EMAIL
    WP_EMAIL="${WP_EMAIL:-admin@example.com}"

    info "--- 数据库与缓存 ---"
    read -rp "MariaDB WireGuard IP: " DB_HOST
    [[ -z "$DB_HOST" ]] && error "数据库 IP 不能为空"
    read -rp "数据库名 [默认: wordpress]: " DB_NAME
    DB_NAME="${DB_NAME:-wordpress}"
    read -rp "数据库用户名 [默认: wpuser]: " DB_USER
    DB_USER="${DB_USER:-wpuser}"

    local DB_PW=""
    read_secret "数据库密码: " DB_PW
    [[ -z "$DB_PW" ]] && error "数据库密码不能为空"

    read -rp "Redis WireGuard IP [默认同数据库 ${DB_HOST}]: " REDIS_HOST
    REDIS_HOST="${REDIS_HOST:-$DB_HOST}"

    local REDIS_PW=""
    read_secret "Redis 密码: " REDIS_PW
    [[ -z "$REDIS_PW" ]] && error "Redis 密码不能为空"

    info "--- 对象存储 ---"
    echo "  1. AWS S3"
    echo "  2. Cloudflare R2"
    echo "  3. 其他/MinIO"
    read -rp "选择 [默认: 1]: " S3_CHOICE
    local S3_PROVIDER="aws"
    local S3_ENDPOINT=""
    case "${S3_CHOICE:-1}" in
        2) S3_PROVIDER="r2" ;;
        3) S3_PROVIDER="other" ;;
    esac

    read -rp "存储桶名称: " S3_BUCKET
    [[ -z "$S3_BUCKET" ]] && error "桶名不能为空"
    read -rp "区域 [默认: us-east-1]: " S3_REGION
    S3_REGION="${S3_REGION:-us-east-1}"
    if [[ "$S3_PROVIDER" != "aws" ]]; then
        read -rp "自定义 Endpoint URL: " S3_ENDPOINT
        [[ -z "$S3_ENDPOINT" ]] && error "非 AWS 提供商必须填写 Endpoint"
    fi

    local S3_KEY=""
    local S3_SECRET=""
    read_secret "S3 Access Key ID: " S3_KEY
    [[ -z "$S3_KEY" ]] && error "S3 Key 不能为空"
    read_secret "S3 Secret Access Key: " S3_SECRET
    [[ -z "$S3_SECRET" ]] && error "S3 Secret 不能为空"
    read -rp "CDN 域名（留空跳过）: " S3_CDN_DOMAIN
    S3_CDN_DOMAIN="${S3_CDN_DOMAIN:-}"

    # 获取 WG IP
    local WG_IP
    WG_IP=$(get_wg_ip)
    log "WireGuard IP: ${WG_IP}"

    # 创建目录与文件
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
EOF
    chmod 600 "$DIR/.env"

    _write_nginx_wp_conf    "$DIR/uploads/nginx-wp.conf" "$WG_IP"
    _write_php_uploads_ini  "$DIR/uploads/php-uploads.ini"
    _write_s3_config_php    "$DIR/uploads/s3-config.php"
    _write_docker_compose   "$DIR"

    info "启动容器..."
    if ! dc "$DIR" up -d 2>&1; then
        error "容器启动失败，请检查 Docker 环境。"
    fi

    if ! _wait_and_setup_plugin "$DIR" "true" \
            "$WP_URL" "$WP_TITLE" "$WP_ADMIN" "$WP_PASS" "$WP_EMAIL"; then
        warn "插件配置未完全成功，可通过菜单 6 重试。"
    fi

    log "节点部署完成！"
    echo -e "  访问地址: \e[33mhttp://${WG_IP}:${HOST_PORT}\e[0m"
    echo -e "  (请通过 WG 网关反代或直接从内网访问)"
}

cmd_status() {
    read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR
    DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"
    dc "$DIR" ps
}

cmd_logs() {
    read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR
    DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"
    read -rp "容器 (wordpress/nginx) [默认: wordpress]: " SVC
    SVC="${SVC:-wordpress}"
    dc "$DIR" logs -f --tail=100 "$SVC"
}

cmd_destroy() {
    read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR
    DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"
    warn "将停止容器并清理网络，数据目录保留。"
    read -rp "输入 'yes' 确认: " CONFIRM
    [[ "$CONFIRM" != "yes" ]] && { info "已取消"; return; }
    dc "$DIR" down --volumes --remove-orphans 2>/dev/null || true
    log "节点已释放，数据保留在 ${DIR}"
}

cmd_stop() {
    read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR
    DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"
    dc "$DIR" stop && log "已停止。"
}

cmd_start() {
    read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR
    DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"
    dc "$DIR" up -d && log "已启动。"
}

cmd_retry_plugins() {
    read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR
    DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"
    if ! dc "$DIR" ps --services --filter status=running | grep -q "wordpress"; then
        warn "wordpress 容器未运行，请先启动。"
        return
    fi
    _wait_and_setup_plugin "$DIR" "false" || warn "插件配置未完全成功。"
}

cmd_update() {
    read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR
    DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"
    header "滚动更新"
    echo "  1. WordPress"
    echo "  2. Nginx"
    echo "  3. 全部"
    read -rp "选择: " UP_CHOICE
    local SVC=""
    case "$UP_CHOICE" in
        1) SVC="wordpress" ;;
        2) SVC="nginx" ;;
        3) SVC="" ;;
        *) error "无效选择" ;;
    esac
    if [[ -n "$SVC" ]]; then
        dc "$DIR" pull "$SVC"
        dc "$DIR" up -d --force-recreate "$SVC"
    else
        dc "$DIR" pull
        dc "$DIR" up -d --force-recreate
    fi
    log "更新完成。"
    dc "$DIR" ps
}

# ── 主菜单 ──────────────────────────────────────────
interactive_menu() {
    while true; do
        echo ""
        _c "1;35" "========================================"
        _c "1;35" "    WordPress 多节点分发管理 (host 网络)"
        _c "1;35" "========================================"
        echo -e "  \e[32m1.\e[0m 部署新节点 (全自动建站)"
        echo -e "  \e[32m2.\e[0m 查看状态"
        echo -e "  \e[32m3.\e[0m 查看日志"
        echo -e "  \e[31m4.\e[0m 停止节点"
        echo -e "  \e[32m5.\e[0m 启动节点"
        echo -e "  \e[33m6.\e[0m 重试插件配置"
        echo -e "  \e[31m7.\e[0m 删除节点"
        echo -e "  \e[36m8.\e[0m 更新镜像"
        echo -e "  \e[36m0.\e[0m 退出"
        echo "----------------------------------------"
        read -rp "选择: " CHOICE
        case "$CHOICE" in
            1) cmd_deploy ;;
            2) cmd_status ;;
            3) cmd_logs ;;
            4) cmd_stop ;;
            5) cmd_start ;;
            6) cmd_retry_plugins ;;
            7) cmd_destroy ;;
            8) cmd_update ;;
            0) info "再见！"; exit 0 ;;
            *) warn "无效输入" ;;
        esac
        read -rp "按回车继续..."
        clear
    done
}

# 入口
clear
interactive_menu
