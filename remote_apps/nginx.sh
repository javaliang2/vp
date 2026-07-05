#!/bin/bash
# 切换到 nginx.org 官方 stable 仓库并升级
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "请用 root 运行 (sudo $0)"; exit 1; }

. /etc/os-release
DISTRO_ID="$ID"          # debian / ubuntu
CODENAME="$(lsb_release -cs)"

if [[ "$DISTRO_ID" != "debian" && "$DISTRO_ID" != "ubuntu" ]]; then
    echo "未识别的发行版: $DISTRO_ID，请手动参考 https://nginx.org/en/linux_packages.html"
    exit 1
fi

apt update
apt install -y curl gnupg2 ca-certificates lsb-release debian-archive-keyring

# 官方签名 key
curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor \
    | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null

# 校验指纹（应为 573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62）
FPR=$(gpg --dry-run --quiet --no-keyring --import --import-options import-show \
    /usr/share/keyrings/nginx-archive-keyring.gpg | grep -o '[0-9A-F]\{40\}' | head -1)
echo "密钥指纹: $FPR"
if [[ "$FPR" != "573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62" ]]; then
    echo "警告：指纹不匹配，请勿继续，手动核实！"
    exit 1
fi

# 官方 stable 仓库
echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/${DISTRO_ID} ${CODENAME} nginx" \
    | tee /etc/apt/sources.list.d/nginx.list

# 仓库优先级：确保 apt 用官方包而不是系统自带的旧包
printf 'Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n' \
    | tee /etc/apt/preferences.d/99nginx

apt update
apt install -y nginx

echo ""
nginx -v

# ── 关键：官方 nginx.org 包不带 sites-available/sites-enabled 这套约定，
# 只有 conf.d/。而 nginx-gateway.sh / nginx-web-security.sh 都硬编码依赖
# sites-available/sites-enabled，如果是首次安装（这两个目录不存在），
# 需要手动补上，否则你现有脚本会直接找不到任何站点配置。
if [[ ! -d /etc/nginx/sites-available ]]; then
    echo ""
    echo "检测到首次安装（官方包默认没有 sites-available/sites-enabled），正在补齐..."
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

    if ! grep -q 'sites-enabled' /etc/nginx/nginx.conf; then
        # 在 http {} 块内、conf.d include 之后追加 sites-enabled include
        sed -i '/include\s*\/etc\/nginx\/conf\.d\/\*\.conf;/a\    include /etc/nginx/sites-enabled/*.conf;' /etc/nginx/nginx.conf
    fi

    nginx -t && echo "已补齐 sites-available/sites-enabled 结构，nginx -t 通过" \
        || echo "补齐后 nginx -t 失败，请检查 /etc/nginx/nginx.conf 的 include 是否重复或位置不对"
fi

echo "升级完成。建议：nginx -t 检查现有配置无误后，再 systemctl restart nginx"
