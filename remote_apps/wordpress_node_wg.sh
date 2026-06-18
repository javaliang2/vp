#!/usr/bin/env bash
# ============================================================
# wp-deploy.sh — WordPress 多节点部署（内网 WG + S3 存储交互版）
# 功能：部署、状态、日志、启停、重试配置、删除节点、更新镜像
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

_write_wp_config_extra() {
    local REDIS_HOST="$1"
    local REDIS_PW="$2"
    cat <<'PHPEOF'
<?php
if ( isset( $_SERVER['HTTP_X_FORWARDED_PROTO'] ) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https' ) {
    $_SERVER['HTTPS'] = 'on';
}
if ( isset( $_SERVER['HTTP_X_FORWARDED_HOST'] ) ) {
    $_SERVER['HTTP_HOST'] = $_SERVER['HTTP_X_FORWARDED_HOST'];
}
define( 'WP_HOME',    'https://' . $_SERVER['HTTP_HOST'] );
define( 'WP_SITEURL', 'https://' . $_SERVER['HTTP_HOST'] );
PHPEOF
    cat <<PHPEOF
define('WP_REDIS_HOST',   '${REDIS_HOST}');
define('WP_REDIS_PORT',   6379);
define('WP_REDIS_AUTH',   '${REDIS_PW}');
define('WP_CACHE',        true);
define('WP_MEMORY_LIMIT', '512M');
define('WP_MAX_MEMORY_LIMIT', '1024M');

ini_set('session.save_handler', 'redis');
ini_set('session.save_path', 'tcp://' . WP_REDIS_HOST . ':' . WP_REDIS_PORT . '?auth=' . urlencode(WP_REDIS_AUTH));

if (file_exists(ABSPATH . 'wp-content/s3-config.php')) {
    require_once(ABSPATH . 'wp-content/s3-config.php');
}
PHPEOF
}

# ── 核心异步任务 ────────────────────────────────────────────
_wait_and_setup_plugin() {
    local DIR="$1"
    info "后台任务：等待 WordPress 容器就绪..."
    local RETRIES=60
    while ! wp_cli "$DIR" core is-installed &>/dev/null; do
        sleep 5
        (( RETRIES-- ))
        if [[ $RETRIES -eq 0 ]]; then
            warn "WordPress 初始化超时，请稍后通过菜单 6 手动完成配置。"
            return 1
        fi
    done

    local WP_CONFIG="/var/www/html/wp-config.php"
    if ! dc "$DIR" exec -T wordpress grep -q "wp-config-extra.php" "$WP_CONFIG"; then
        dc "$DIR" exec -T wordpress sed -i "1s|<?php|<?php\nrequire_once(ABSPATH . 'wp-config-extra.php');|" "$WP_CONFIG"
        log "wp-config-extra.php 注入成功"
    else
        log "wp-config-extra.php 已存在，跳过注入"
    fi

    if wp_cli "$DIR" plugin is-installed amazon-s3-and-cloudfront &>/dev/null; then
        wp_cli "$DIR" plugin activate amazon-s3-and-cloudfront
    else
        wp_cli "$DIR" plugin install amazon-s3-and-cloudfront --activate
    fi
    log "WP Offload Media 插件已就绪。"
}

# ════════════════════════════════════════════════════════════
# 业务功能模块
# ════════════════════════════════════════════════════════════

cmd_deploy() {
    header "启动 WordPress 节点部署向导"

    read -rp "请输入部署目录 [默认: ${DEFAULT_DIR}]: " DIR
    DIR="${DIR:-$DEFAULT_DIR}"
    read -rp "请输入本机对外监听端口 [默认: ${DEFAULT_PORT}]: " HOST_PORT
    HOST_PORT="${HOST_PORT:-$DEFAULT_PORT}"

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

    info "--- 共享对象存储配置 (支持 AWS / Cloudflare R2 / MinIO) ---"
    read -rp "请选择存储提供商 (1: AWS S3, 2: Cloudflare R2, 3: 其他/MinIO) [默认: 1]: " S3_CHOICE
    local S3_PROVIDER="aws"
    local S3_ENDPOINT=""
    case "$S3_CHOICE" in
        2) S3_PROVIDER="r2" ;;
        3) S3_PROVIDER="other" ;;
    esac

    read -rp "请输入 S3 存储桶名称: " S3_BUCKET
    [[ -z "$S3_BUCKET" ]] && error "存储桶名称不能为空"
    read -rp "请输入 S3 区域 [默认: us-east-1 / R2填 auto]: " S3_REGION
    S3_REGION="${S3_REGION:-us-east-1}"

    if [[ "$S3_PROVIDER" != "aws" ]]; then
        read -rp "请输入自定义 Endpoint URL: " S3_ENDPOINT
        [[ -z "$S3_ENDPOINT" ]] && error "非 AWS 提供商必须填写 Endpoint"
    fi

    read -rp "请输入 S3 Access Key ID: " S3_KEY
    [[ -z "$S3_KEY" ]] && error "S3 Key 不能为空"
    read -rp "请输入 S3 Secret Access Key: " S3_SECRET
    [[ -z "$S3_SECRET" ]] && error "S3 Secret 不能为空"
    read -rp "请输入绑定的 CDN 域名 [没有请留空]: " S3_CDN_DOMAIN

    # 输入清理
    DB_PW="${DB_PW//[[:space:]]/}"
    REDIS_PW="${REDIS_PW//[[:space:]]/}"
    S3_KEY="${S3_KEY//[[:space:]]/}"
    S3_SECRET="${S3_SECRET//[[:space:]]/}"

    # 获取 WireGuard IP
    info "检测本机 WireGuard 接口地址..."
    WG_IP=""
    if ip -4 addr show wg0 &>/dev/null; then
        WG_IP=$(ip -4 addr show wg0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
        log "检测到 wg0 IP: ${WG_IP}，Nginx 将仅监听此地址。"
    else
        warn "未找到 wg0 接口，回退为监听 0.0.0.0（所有接口）。"
        warn "请务必通过防火墙限制访问。"
        WG_IP="0.0.0.0"
    fi

    info "正在创建目录结构..."
    mkdir -p "$DIR"/{data,uploads,logs}
    local NET
    NET=$(net_name "$DIR")

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

    _write_nginx_wp_conf   "$DIR/uploads/nginx-wp.conf"
    _write_php_uploads_ini "$DIR/uploads/php-uploads.ini"
    _write_s3_config_php   "$DIR/uploads/s3-config.php"
    _write_wp_config_extra "$REDIS_HOST" "$REDIS_PW" > "$DIR/uploads/wp-config-extra.php"

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
      - ./uploads/s3-config.php:/var/www/html/wp-content/s3-config.php:ro
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
YAML

    info "正在拉取镜像并构建本地节点环境..."
    dc "$DIR" up -d 2>&1 || error "docker compose up 失败"

    _wait_and_setup_plugin "$DIR" &

    log "WordPress 节点容器群启动成功！"
    echo -e "绑定地址: \e[33m${WG_IP}:${HOST_PORT}\e[0m"
    echo -e "内网数据库: \e[33m${DB_HOST}\e[0m"
    echo -e "内网缓存: \e[33m${REDIS_HOST}\e[0m"
    echo -e "对象存储桶: \e[33ms3://${S3_BUCKET}\e[0m"
    if [[ "$WG_IP" == "0.0.0.0" ]]; then
        warn "当前监听所有接口，请立即配置防火墙！"
    fi
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

# ── 新增：删除节点 ──────────────────────────────────────────
cmd_destroy() {
    read -rp "请输入要删除的节点目录 [默认: ${DEFAULT_DIR}]: " DIR
    DIR="${DIR:-$DEFAULT_DIR}"
    if [[ ! -f "$DIR/docker-compose.yml" ]]; then
        error "目录 $DIR 中未找到 docker-compose.yml，请检查路径。"
    fi
    warn "此操作将停止并删除容器和网络，但保留所有数据（包括数据库、Redis 不受影响）。"
    read -rp "确认删除节点吗？请输入 'yes' 继续: " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        info "已取消删除。"
        return
    fi
    dc "$DIR" down --volumes --remove-orphans 2>/dev/null || true
    log "节点容器与网络已删除，数据目录 ${DIR} 保留。"
}

# ── 新增：更新组件 ──────────────────────────────────────────
cmd_update() {
    read -rp "请输入要更新的节点目录 [默认: ${DEFAULT_DIR}]: " DIR
    DIR="${DIR:-$DEFAULT_DIR}"
    header "更新节点组件"
    echo "  1. 仅更新 WordPress 镜像"
    echo "  2. 仅更新 Nginx 镜像"
    echo "  3. 更新全部组件"
    read -rp "请选择 [1-3]: " UP_CHOICE
    case "$UP_CHOICE" in
        1) SERVICES="wordpress" ;;
        2) SERVICES="nginx" ;;
        3) SERVICES="" ;;  # pull all and recreate
        *) error "无效选择" ;;
    esac

    info "正在拉取最新镜像..."
    if [[ -z "$SERVICES" ]]; then
        dc "$DIR" pull
    else
        dc "$DIR" pull $SERVICES
    fi

    info "正在重新创建容器..."
    if [[ -z "$SERVICES" ]]; then
        dc "$DIR" up -d --force-recreate
    else
        dc "$DIR" up -d --force-recreate $SERVICES
    fi

    log "节点组件更新完成。"
    cmd_status
}

# ════════════════════════════════════════════════════════════
# 交互式主菜单
# ════════════════════════════════════════════════════════════
interactive_menu() {
    while true; do
        echo ""
        _c "1;35" "========================================"
        _c "1;35" "    WordPress 多节点分发管理 (完整版)"
        _c "1;35" "========================================"
        echo -e "  \e[32m1.\e[0m 部署全新 WordPress 业务节点"
        echo -e "  \e[32m2.\e[0m 查看当前节点容器运行状态"
        echo -e "  \e[32m3.\e[0m 查看业务节点实时运行日志"
        echo -e "  \e[31m4.\e[0m 停止该节点服务"
        echo -e "  \e[32m5.\e[0m 启动该节点服务"
        echo -e "  \e[33m6.\e[0m 手动重试注入配置 / 安装 S3 插件"
        echo -e "  \e[31m7.\e[0m 删除节点 (移除容器/网络)"
        echo -e "  \e[36m8.\e[0m 更新节点组件 (拉取新镜像)"
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
            7) cmd_destroy ;;
            8) cmd_update ;;
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