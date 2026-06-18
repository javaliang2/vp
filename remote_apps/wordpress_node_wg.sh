#!/usr/bin/env bash
# ============================================================
# wp-deploy.sh — WordPress 多节点部署（内网 WG + S3 存储交互版）
# ============================================================
set -euo pipefail
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# ── 默认值 ──────────────────────────────────────────────────
BASE_DIR="${BASE_DIR:-/srv}"
DEFAULT_DIR="${BASE_DIR}/wordpress"
DEFAULT_PORT="8080"

# ── 颜色与界面输出 ──────────────────────────────────────────
_c() { printf "\e[${1}m${2}\e[0m\n"; }
log()    { _c "32" "[成功] $*"; }
info()   { _c "36" "[提示] $*"; }
warn()   { _c "33" "[警告] $*"; }
error()  { _c "31" "[错误] $*"; exit 1; }
header() { echo; _c "1;34" "=== $* ==="; }

# 修复：加 true 防止 set -e 误触发
randpw() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32; true; }

# ── 辅助函数 ────────────────────────────────────────────────
net_name() { echo "wp_net_$(basename "$1")"; }

dc() {
    local DIR="$1"; shift
    docker compose -f "$DIR/docker-compose.yml" --env-file "$DIR/.env" "$@"
}

wp_cli() {
    local DIR="$1"; shift
    dc "$DIR" exec -T wordpress wp --allow-root "$@"
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
        fastcgi_param             SCRIPT_FILENAME    $document_root$fastcgi_script_name;
        fastcgi_param             HTTPS              $fastcgi_https;
        fastcgi_param             HTTP_X_FORWARDED_PROTO $http_x_forwarded_proto;
        fastcgi_param             HTTP_X_FORWARDED_FOR   $http_x_forwarded_for;
        fastcgi_param             HTTP_X_REAL_IP         $http_x_real_ip;
        fastcgi_read_timeout      600;
        fastcgi_keep_conn         on;
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
    local PROVIDER="$2"
    local CUSTOM_ENDPOINT="$3"
    local ENDPOINT_LINE=""
    [[ -n "$CUSTOM_ENDPOINT" ]] && ENDPOINT_LINE="    'endpoint' => '${CUSTOM_ENDPOINT}',"

    cat > "$DEST" <<PHP
<?php
define('AS3CF_SETTINGS', serialize([
    'provider'                  => '${PROVIDER}',
    'access-key-id'             => getenv('AWS_ACCESS_KEY_ID'),
    'secret-access-key'         => getenv('AWS_SECRET_ACCESS_KEY'),
    'bucket'                    => getenv('S3_BUCKET'),
    'region'                    => getenv('S3_REGION'),
${ENDPOINT_LINE}
    'copy-to-s3'                => true,
    'serve-from-s3'             => true,
    'remove-local-file'         => true,
    'enable-object-prefix'      => true,
    'object-prefix'             => 'uploads/',
    'delivery-provider'         => 'storage',
    'delivery-provider-domain'  => getenv('S3_CDN_DOMAIN') ?: '',
    'force-https'               => true,
    'use-presigned-urls'        => false,
    'enable-cron'               => false,
]));
PHP
}

# ── 生成 WORDPRESS_CONFIG_EXTRA（单独函数避免 bash 展开 $_ 变量）──
_write_wp_config_extra() {
    local REDIS_HOST="$1"
    local REDIS_PW="$2"
    # 注意：此处故意用单引号heredoc，PHP的$变量不被bash展开
    cat <<'PHPEOF'
if ( isset( $_SERVER['HTTP_X_FORWARDED_PROTO'] ) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https' ) {
    $_SERVER['HTTPS'] = 'on';
}
if ( isset( $_SERVER['HTTP_X_FORWARDED_HOST'] ) ) {
    $_SERVER['HTTP_HOST'] = $_SERVER['HTTP_X_FORWARDED_HOST'];
}
define( 'WP_HOME',    'https://' . $_SERVER['HTTP_HOST'] );
define( 'WP_SITEURL', 'https://' . $_SERVER['HTTP_HOST'] );
PHPEOF
    # 需要 bash 变量展开的部分单独输出
    cat <<PHPEOF
define('WP_REDIS_HOST',   '${REDIS_HOST}');
define('WP_REDIS_PORT',   6379);
define('WP_REDIS_AUTH',   '${REDIS_PW}');
define('WP_CACHE',        true);
define('WP_MEMORY_LIMIT', '512M');
define('WP_MAX_MEMORY_LIMIT', '1024M');
ini_set('session.save_handler', 'redis');
ini_set('session.save_path', 'tcp://${REDIS_HOST}:6379?auth=${REDIS_PW}');
if (file_exists(ABSPATH . 'wp-content/s3-config.php')) {
    require_once(ABSPATH . 'wp-content/s3-config.php');
}
PHPEOF
}

# ── 核心异步任务：激活并配置 S3 插件 ─────────────────────────
_wait_and_setup_plugin() {
    local DIR="$1"
    info "后台任务：等待 WordPress 容器初始化（约需 30 秒）..."
    sleep 30

    local RETRIES=10
    while ! wp_cli "$DIR" core is-installed &>/dev/null; do
        sleep 5
        (( RETRIES-- ))
        if [[ $RETRIES -eq 0 ]]; then
            warn "WordPress 初始化未完成，请稍后在菜单手动安装 Offload Media 插件。"
            return 1
        fi
    done

    if wp_cli "$DIR" plugin is-installed amazon-s3-and-cloudfront &>/dev/null; then
        wp_cli "$DIR" plugin activate amazon-s3-and-cloudfront
    else
        wp_cli "$DIR" plugin install amazon-s3-and-cloudfront --activate
    fi
    log "WP Offload Media 插件已在后台成功安装并激活！"

    local WP_CONFIG_FILE
    WP_CONFIG_FILE=$(dc "$DIR" exec -T wordpress find /var/www/html -maxdepth 1 -name wp-config.php 2>/dev/null | head -1 | tr -d '\r')
    if [[ -n "$WP_CONFIG_FILE" ]]; then
        dc "$DIR" exec -T wordpress grep -q "s3-config.php" "$WP_CONFIG_FILE" || \
        dc "$DIR" exec -T wordpress sed -i "s|<?php|<?php\nrequire_once(ABSPATH . 'wp-content/s3-config.php');|" "$WP_CONFIG_FILE"
        log "s3-config.php 已成功挂载到 WordPress 核心配置中！"
    fi
}

# ════════════════════════════════════════════════════════════
# 业务功能模块
# ════════════════════════════════════════════════════════════

cmd_deploy() {
    header "启动 WordPress 节点部署向导"

    # 1. 基础路径和端口
    read -rp "请输入部署目录 [默认: ${DEFAULT_DIR}]: " DIR
    DIR="${DIR:-$DEFAULT_DIR}"
    read -rp "请输入本机对外监听端口 [默认: ${DEFAULT_PORT}]: " HOST_PORT
    HOST_PORT="${HOST_PORT:-$DEFAULT_PORT}"

    # 2. 数据库与缓存配置
    info "--- 远端共享数据库与缓存配置 (WireGuard 内网) ---"
    read -rp "请输入 MariaDB 的 WireGuard IP: " DB_HOST
    [[ -z "$DB_HOST" ]] && error "数据库 IP 不能为空"
    read -rp "请输入数据库库名 [默认: wordpress]: " DB_NAME
    DB_NAME="${DB_NAME:-wordpress}"
    read -rp "请输入数据库用户名 [默认: wpuser]: " DB_USER
    DB_USER="${DB_USER:-wpuser}"
    read -rp "请输入数据库密码: " DB_PW
    [[ -z "$DB_PW" ]] && error "数据库密码不能为空"

    read -rp "请输入 Redis 的 WireGuard IP [默认同数据库]: " REDIS_HOST
    REDIS_HOST="${REDIS_HOST:-$DB_HOST}"
    read -rp "请输入 Redis 连接密码: " REDIS_PW
    [[ -z "$REDIS_PW" ]] && error "Redis 密码不能为空"

    # 3. 对象存储 S3 配置
    info "--- 共享对象存储配置 (支持 AWS / Cloudflare R2 / MinIO) ---"
    read -rp "请选择存储提供商 (1: AWS S3, 2: Cloudflare R2, 3: 其他/MinIO) [默认: 1]: " S3_CHOICE
    local S3_PROVIDER="aws"
    local S3_ENDPOINT=""
    case "$S3_CHOICE" in
        2) S3_PROVIDER="r2" ;;
        3) S3_PROVIDER="other" ;;
    esac

    read -rp "请输入 S3 存储桶(Bucket)名称: " S3_BUCKET
    [[ -z "$S3_BUCKET" ]] && error "存储桶名称不能为空"
    read -rp "请输入 S3 区域(Region) [默认: us-east-1 / R2填 auto]: " S3_REGION
    S3_REGION="${S3_REGION:-us-east-1}"

    if [[ "$S3_PROVIDER" != "aws" ]]; then
        read -rp "请输入自定义 Endpoint URL (例如 https://<id>.r2.cloudflarestorage.com): " S3_ENDPOINT
        [[ -z "$S3_ENDPOINT" ]] && error "非 AWS 提供商必须填写 Endpoint"
    fi

    read -rp "请输入 S3 Access Key ID: " S3_KEY
    [[ -z "$S3_KEY" ]] && error "S3 Key 不能为空"
    read -rp "请输入 S3 Secret Access Key: " S3_SECRET
    [[ -z "$S3_SECRET" ]] && error "S3 Secret 不能为空"
    read -rp "请输入绑定的 CDN 域名 [没有请留空直接回车]: " S3_CDN_DOMAIN

    # ── 开始执行部署 ──────────────────────────────────────────
    info "正在创建目录结构..."
    mkdir -p "$DIR"/{data,uploads,logs}
    local NET
    NET=$(net_name "$DIR")

    # 写入 .env
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
S3_CDN_DOMAIN=${S3_CDN_DOMAIN}
EOF
    chmod 600 "$DIR/.env"

    # 生成辅助配置文件
    _write_nginx_wp_conf   "$DIR/uploads/nginx-wp.conf"
    _write_php_uploads_ini "$DIR/uploads/php-uploads.ini"
    _write_s3_config_php   "$DIR/uploads/s3-config.php" "$S3_PROVIDER" "$S3_ENDPOINT"

    # 预生成 config extra 到文件，避免 compose yaml 里的 bash 变量展开问题
    local CONFIG_EXTRA_FILE="$DIR/uploads/wp-config-extra.php"
    _write_wp_config_extra "$REDIS_HOST" "$REDIS_PW" > "$CONFIG_EXTRA_FILE"

    # 生成 docker-compose.yml
    # 修复：WORDPRESS_CONFIG_EXTRA 改为挂载文件方式，彻底避免 $_SERVER 被 bash 展开
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
      S3_CDN_DOMAIN:         \${S3_CDN_DOMAIN}
    volumes:
      - ./data:/var/www/html
      - ./uploads/php-uploads.ini:/usr/local/etc/php/conf.d/uploads.ini:ro
      - ./uploads/s3-config.php:/var/www/html/wp-content/s3-config.php:ro
      - ./uploads/wp-config-extra.php:/var/www/html/wp-config-extra.php:ro
    networks: [${NET}]
    extra_hosts:
      - "host-wg:host-gateway"

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
      - "127.0.0.1:${HOST_PORT}:80"

networks:
  ${NET}:
    driver: bridge
YAML

    # 生成 wp-config.php 注入脚本（在容器启动后执行）
    cat > "$DIR/uploads/inject-config.sh" <<'SH'
#!/bin/sh
WP_CONFIG=/var/www/html/wp-config.php
EXTRA=/var/www/html/wp-config-extra.php
if [ -f "$WP_CONFIG" ] && [ -f "$EXTRA" ]; then
    grep -q "wp-config-extra.php" "$WP_CONFIG" || \
        sed -i "s|<?php|<?php\nrequire_once(ABSPATH . 'wp-config-extra.php');|" "$WP_CONFIG"
fi
SH
    chmod +x "$DIR/uploads/inject-config.sh"

    info "正在拉取镜像并构建本地节点环境..."
    dc "$DIR" up -d 2>&1 || error "docker compose up 失败"

    # 异步触发后台插件安装
    _wait_and_setup_plugin "$DIR" &

    log "WordPress 节点容器群启动成功！"
    echo -e "访问地址 (本地反代目标): \e[33m127.0.0.1:${HOST_PORT}\e[0m"
    echo -e "内网数据库目标: \e[33m${DB_HOST}\e[0m"
    echo -e "内网缓存共享: \e[33m${REDIS_HOST}\e[0m"
    echo -e "静态资源上云桶: \e[33ms3://${S3_BUCKET}\e[0m"
    warn "媒体分离插件正在后台静默安装，配置好站点后自动生效。"
}

cmd_status() {
    read -rp "请输入 WordPress 部署目录 [默认: ${DEFAULT_DIR}]: " DIR
    DIR="${DIR:-$DEFAULT_DIR}"
    header "节点运行状态"
    dc "$DIR" ps
}

cmd_logs() {
    read -rp "请输入 WordPress 部署目录 [默认: ${DEFAULT_DIR}]: " DIR
    DIR="${DIR:-$DEFAULT_DIR}"
    read -rp "查看哪个容器日志？(wordpress/nginx) [默认: wordpress]: " SVC
    SVC="${SVC:-wordpress}"
    dc "$DIR" logs -f --tail=100 "$SVC"
}

# ════════════════════════════════════════════════════════════
# 交互式主菜单
# ════════════════════════════════════════════════════════════
interactive_menu() {
    while true; do
        echo ""
        _c "1;35" "========================================"
        _c "1;35" "    WordPress 多节点分发管理 (向导版)"
        _c "1;35" "========================================"
        echo -e "  \e[32m1.\e[0m 部署全新 WordPress 业务节点"
        echo -e "  \e[32m2.\e[0m 查看当前节点容器运行状态"
        echo -e "  \e[32m3.\e[0m 查看业务节点实时运行日志"
        echo -e "  \e[31m4.\e[0m 停止该节点服务"
        echo -e "  \e[32m5.\e[0m 启动该节点服务"
        echo -e "  \e[33m6.\e[0m 手动触发重试安装 S3 媒体分离插件"
        echo -e "  \e[36m0.\e[0m 退出管理向导"
        echo "----------------------------------------"
        read -rp "请输入功能序号并回车: " CHOICE

        case "$CHOICE" in
            1) cmd_deploy ;;
            2) cmd_status ;;
            3) cmd_logs ;;
            4)
                read -rp "请输入要停止的节点目录 [默认: ${DEFAULT_DIR}]: " DIR
                DIR="${DIR:-$DEFAULT_DIR}"
                dc "$DIR" stop && log "节点服务已停止！"
                ;;
            5)
                read -rp "请输入要启动的节点目录 [默认: ${DEFAULT_DIR}]: " DIR
                DIR="${DIR:-$DEFAULT_DIR}"
                dc "$DIR" up -d && log "节点服务已恢复运行！"
                ;;
            6)
                read -rp "请输入节点目录 [默认: ${DEFAULT_DIR}]: " DIR
                DIR="${DIR:-$DEFAULT_DIR}"
                _wait_and_setup_plugin "$DIR"
                ;;
            0) info "退出向导，祝你建站愉快！"; exit 0 ;;
            *) warn "无效输入，请重新输入序号" ;;
        esac

        echo ""
        read -rp "按回车键返回主菜单..."
        clear
    done
}

# 入口
clear
interactive_menu
