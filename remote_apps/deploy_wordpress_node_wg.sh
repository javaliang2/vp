#!/usr/bin/env bash
# ============================================================
# WordPress 多节点部署 —— WireGuard 内网 + S3 存储
# 依赖：docker compose v2, wg-quick, randpw(), run_compose(),
#       net_name(), log(), warn(), error(), header()
# ============================================================

# ── 辅助：写 nginx fastcgi 配置 ────────────────────────────
_write_nginx_wp_conf() {
    local DEST="$1"
    cat > "$DEST" <<'NGINX'
# 根据 X-Forwarded-Proto 映射 HTTPS 变量
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

    # 节点 nginx 自己不做 HTTP→HTTPS 跳转
    # 跳转逻辑由 A 机器网关统一处理
    
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
        fastcgi_param             SCRIPT_FILENAME $document_root$fastcgi_script_name;
        # 透传代理信息给 PHP
        fastcgi_param             HTTPS           $fastcgi_https;
        fastcgi_param             HTTP_X_FORWARDED_PROTO $http_x_forwarded_proto;
        fastcgi_param             HTTP_X_FORWARDED_FOR   $http_x_forwarded_for;
        fastcgi_param             HTTP_X_REAL_IP         $http_x_real_ip;
        fastcgi_read_timeout      600;
        fastcgi_keep_conn         on;
    }
}
NGINX
}

# ── 辅助：写 php uploads ini ────────────────────────────────
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

# ── 辅助：写 s3-config.php（wp-config.php 会 require 它）──
# 支持 AWS S3 / Cloudflare R2 / 任意兼容 S3 的对象存储
#
# 参数：
#   $1  目标路径
#   $2  provider: aws | r2 | do | other
#   $3  自定义 endpoint（R2/MinIO 等非 AWS 时填，AWS 留空）
_write_s3_config_php() {
    local DEST="$1"
    local PROVIDER="${2:-aws}"
    local CUSTOM_ENDPOINT="${3:-}"

    local ENDPOINT_LINE=""
    [[ -n "$CUSTOM_ENDPOINT" ]] && \
        ENDPOINT_LINE="'endpoint' => '${CUSTOM_ENDPOINT}',"

    cat > "$DEST" <<PHP
<?php
/**
 * WP Offload Media (AS3CF) 配置
 * 通过环境变量注入，不硬编码凭据
 * 本文件由 deploy_wordpress_node_wg() 自动生成
 */
define('AS3CF_SETTINGS', serialize([
    'provider'                  => '${PROVIDER}',
    'access-key-id'             => getenv('AWS_ACCESS_KEY_ID'),
    'secret-access-key'         => getenv('AWS_SECRET_ACCESS_KEY'),
    'bucket'                    => getenv('S3_BUCKET'),
    'region'                    => getenv('S3_REGION'),
    ${ENDPOINT_LINE}

    // 上传行为
    'copy-to-s3'                => true,
    'serve-from-s3'             => true,
    'remove-local-file'         => true,   // 上传后删本地副本
    'enable-object-prefix'      => true,
    'object-prefix'             => 'uploads/',
    'delivery-provider'         => 'storage', // 有 CDN 改为 'cloudfront' 等
    'delivery-provider-domain'  => getenv('S3_CDN_DOMAIN') ?: '',

    // 安全
    'force-https'               => true,
    'use-presigned-urls'        => false,

    // 性能
    'enable-cron'               => false,  // 由 WP-Cron 接管
]));
PHP
}

# ── 辅助：wp-cli 封装（在 wordpress 容器内执行）─────────────
wp_cli() {
    local DIR="$1"; shift
    docker compose -f "$DIR/docker-compose.yml" \
        exec -T wordpress \
        wp --allow-root "$@"
}

# ── 等待 WordPress 容器就绪（wp-cli 可用）──────────────────
_wait_wp_ready() {
    local DIR="$1"
    local RETRIES="${2:-20}"
    log "等待 WordPress 就绪..."
    while ! wp_cli "$DIR" core is-installed &>/dev/null; do
        sleep 5
        (( RETRIES-- ))
        [[ $RETRIES -eq 0 ]] && {
            warn "WordPress 尚未完成初始化，请稍后手动运行 wp_install_offload_plugin"
            return 1
        }
    done
    return 0
}

# ── 安装并激活 WP Offload Media 插件 ────────────────────────
wp_install_offload_plugin() {
    local DIR="${1:-$BASE_DIR/wordpress}"

    _wait_wp_ready "$DIR" || return 0

    if wp_cli "$DIR" plugin is-installed amazon-s3-and-cloudfront &>/dev/null; then
        log "WP Offload Media 已安装，跳过"
        wp_cli "$DIR" plugin activate amazon-s3-and-cloudfront
    else
        wp_cli "$DIR" plugin install amazon-s3-and-cloudfront --activate
        log "WP Offload Media 安装激活完成"
    fi

    # 确认插件已加载 s3-config.php
    # wp-config.php 里需有: require_once(ABSPATH . 'wp-content/s3-config.php');
    # 首次部署时 WP 会自动写 wp-config.php，我们追加进去
    local WP_CONFIG_FILE
    WP_CONFIG_FILE=$(docker compose -f "$DIR/docker-compose.yml" \
        exec -T wordpress find /var/www/html -maxdepth 1 -name wp-config.php 2>/dev/null | head -1)

    if [[ -n "$WP_CONFIG_FILE" ]]; then
        docker compose -f "$DIR/docker-compose.yml" exec -T wordpress \
            grep -q "s3-config.php" "$WP_CONFIG_FILE" || \
            docker compose -f "$DIR/docker-compose.yml" exec -T wordpress \
            sed -i "s|<?php|<?php\nrequire_once(ABSPATH . 'wp-content/s3-config.php');|" \
            "$WP_CONFIG_FILE"
        log "s3-config.php 已注入 wp-config.php"
    fi
}

# ── 主函数：部署 WordPress 节点 ─────────────────────────────
#
# 参数：
#   $1  DIR           部署目录，默认 $BASE_DIR/wordpress
#   $2  HOST_PORT     本机监听端口（127.0.0.1:PORT，给 A 网关反代）
#   $3  DB_HOST       MariaDB WireGuard IP（如 10.10.0.5）
#   $4  REDIS_HOST    Redis    WireGuard IP（如 10.10.0.5）
#   $5  REDIS_PW      Redis 密码
#   $6  S3_BUCKET     存储桶名称
#   $7  S3_REGION     区域，如 us-east-1 / auto（R2）
#   $8  S3_KEY        Access Key ID
#   $9  S3_SECRET     Secret Access Key
#   $10 S3_PROVIDER   aws | r2 | do，默认 aws
#   $11 S3_ENDPOINT   自定义 endpoint，AWS 留空
#                     R2 示例: https://<accountid>.r2.cloudflarestorage.com
#   $12 S3_CDN_DOMAIN CDN 域名，留空则直接用 S3 URL
#
deploy_wordpress_node_wg() {
    local DIR="${1:-$BASE_DIR/wordpress}"
    local HOST_PORT="${2:-${APP_DEFAULT_PORT[wordpress]}}"
    local DB_HOST="${3:?需要 DB 的 WireGuard IP，如 10.10.0.5}"
    local REDIS_HOST="${4:?需要 Redis 的 WireGuard IP，如 10.10.0.5}"
    local REDIS_PW="${5:?需要 Redis 密码}"
    local S3_BUCKET="${6:?需要 S3 Bucket 名称}"
    local S3_REGION="${7:-us-east-1}"
    local S3_KEY="${8:?需要 S3 Access Key ID}"
    local S3_SECRET="${9:?需要 S3 Secret Access Key}"
    local S3_PROVIDER="${10:-aws}"
    local S3_ENDPOINT="${11:-}"
    local S3_CDN_DOMAIN="${12:-}"

    local DB_PW="${WORDPRESS_DB_PASSWORD:?需要设置 WORDPRESS_DB_PASSWORD}"
    local DB_NAME="${WORDPRESS_DB_NAME:-wordpress}"
    local DB_USER="${WORDPRESS_DB_USER:-wpuser}"
    local NET
    NET=$(net_name "$DIR")

    header "部署 WordPress 节点(WG+S3) → $DIR (端口 $HOST_PORT)"
    mkdir -p "$DIR"/{data,uploads,logs}

    # ── .env ──────────────────────────────────────────────────
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

    # ── 辅助配置文件 ─────────────────────────────────────────
    _write_nginx_wp_conf    "$DIR/uploads/nginx-wp.conf"
    _write_php_uploads_ini  "$DIR/uploads/php-uploads.ini"
    _write_s3_config_php    "$DIR/uploads/s3-config.php" \
                            "$S3_PROVIDER" "$S3_ENDPOINT"

    # ── docker-compose.yml ───────────────────────────────────
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
      # S3 凭据透传给 s3-config.php 的 getenv()
      AWS_ACCESS_KEY_ID:     \${AWS_ACCESS_KEY_ID}
      AWS_SECRET_ACCESS_KEY: \${AWS_SECRET_ACCESS_KEY}
      S3_BUCKET:             \${S3_BUCKET}
      S3_REGION:             \${S3_REGION}
      S3_CDN_DOMAIN:         \${S3_CDN_DOMAIN}
      WORDPRESS_CONFIG_EXTRA: |
        if ( isset( $_SERVER['HTTP_X_FORWARDED_PROTO'] )
             && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https' ) {
            $_SERVER['HTTPS'] = 'on';
        }
        if ( isset( $_SERVER['HTTP_X_FORWARDED_HOST'] ) ) {
            $_SERVER['HTTP_HOST'] = $_SERVER['HTTP_X_FORWARDED_HOST'];
        }
        define( 'WP_HOME',    'https://' . $_SERVER['HTTP_HOST'] );
        define( 'WP_SITEURL', 'https://' . $_SERVER['HTTP_HOST'] );
        define('WP_REDIS_HOST',   '\${REDIS_HOST}');
        define('WP_REDIS_PORT',   6379);
        define('WP_REDIS_AUTH',   '\${REDIS_PW}');
        define('WP_CACHE',        true);
        define('WP_MEMORY_LIMIT', '512M');
        define('WP_MAX_MEMORY_LIMIT', '1024M');
        // Session 存 Redis，多节点登录态共享
        ini_set('session.save_handler', 'redis');
        ini_set('session.save_path',
            'tcp://\${REDIS_HOST}:6379?auth=\${REDIS_PW}');
        // S3 配置（require 路径，插件安装后生效）
        if (file_exists(ABSPATH . 'wp-content/s3-config.php')) {
            require_once(ABSPATH . 'wp-content/s3-config.php');
        }
    volumes:
      - ./data:/var/www/html
      - ./uploads/php-uploads.ini:/usr/local/etc/php/conf.d/uploads.ini:ro
      # s3-config.php 挂载到 wp-content 下，插件直接读取
      - ./uploads/s3-config.php:/var/www/html/wp-content/s3-config.php:ro
    networks: [${NET}]
    # 容器能访问宿主机 wg0 地址（DB/Redis 通过 WG 内网可达）
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

    # ── 启动 ─────────────────────────────────────────────────
    run_compose "$DIR" "WordPress节点(WG+S3)"

    # ── 自动安装 Offload Media 插件 ──────────────────────────
    # 放后台，不阻塞部署流程（WP 首次启动需要时间初始化 DB）
    (
        sleep 30
        wp_install_offload_plugin "$DIR"
    ) &

    log "节点已启动 → 127.0.0.1:${HOST_PORT}"
    log "DB:    ${DB_HOST}:3306    (via WireGuard)"
    log "Redis: ${REDIS_HOST}:6379 (via WireGuard)"
    log "S3:    s3://${S3_BUCKET} (${S3_PROVIDER} ${S3_REGION})"
    log "凭据:  $DIR/.env"
    log "插件安装中（后台），约 30s 后完成..."
}

# ── 验证 S3 连通性（部署前可先检查）────────────────────────
check_s3_access() {
    local BUCKET="$1"
    local REGION="${2:-us-east-1}"
    local KEY="$3"
    local SECRET="$4"
    local ENDPOINT="${5:-}"

    if ! command -v aws &>/dev/null; then
        warn "未安装 awscli，跳过 S3 连通性检查"
        return 0
    fi

    local ARGS=(s3 ls "s3://${BUCKET}" --region "$REGION")
    [[ -n "$ENDPOINT" ]] && ARGS+=(--endpoint-url "$ENDPOINT")

    AWS_ACCESS_KEY_ID="$KEY" \
    AWS_SECRET_ACCESS_KEY="$SECRET" \
    aws "${ARGS[@]}" &>/dev/null && \
        log "✓ S3 桶 ${BUCKET} 可访问" || \
        warn "✗ S3 桶 ${BUCKET} 无法访问，请检查凭据和权限"
}
