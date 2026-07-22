#!/bin/bash
# 一键部署 VPS 管理面板 (vp)

REPO_URL="https://raw.githubusercontent.com/lje02/vp/main"
INSTALL_DIR="/usr/local/bin"
MODULES_DIR="/usr/local/share/vn_modules"
set -e

mkdir -p "$MODULES_DIR"

# 下载公共库和主控
echo "下载公共库和主控..."
curl -fsSL "$REPO_URL/common.sh" -o "$MODULES_DIR/common.sh" || { echo "公共库下载失败"; exit 1; }
curl -fsSL "$REPO_URL/vn" -o "$INSTALL_DIR/vn" || { echo "主控下载失败"; exit 1; }
chmod +x "$INSTALL_DIR/vn"

# 静态后备模块列表
BASE_MODULES=(
    "firewall_fail2ban.sh"
    "system_optimize.sh"
    "remote_jump.sh"
    "singbox.sh"
    "monitor.sh"
    "ssh_harden.sh"
    "traffic_monitor.sh"
    "logs.sh"
    "wireguard-mesh.sh"
    "nginx-gateway.sh"
)

# 动态提取主控中的 MODULES_LIST
modules=()
if [ -f "$INSTALL_DIR/vn" ]; then
    modules=($(awk '/^MODULES_LIST=\(/ {flag=1; next} /^\)/ {flag=0} flag {gsub(/"/, ""); if ($1 ~ /\.sh$/) print $1}' "$INSTALL_DIR/vn"))
fi

# 提取为空时使用静态列表
if [ ${#modules[@]} -eq 0 ]; then
    modules=("${BASE_MODULES[@]}")
    echo "使用静态模块列表"
fi

echo -n "下载模块中"
for mod in "${modules[@]}"; do
    # 增加 -f 参数并在下载后校验文件是否为空
    if curl -fsSL "$REPO_URL/modules/$mod" -o "$MODULES_DIR/$mod" 2>/dev/null && [ -s "$MODULES_DIR/$mod" ]; then
        chmod +x "$MODULES_DIR/$mod" 2>/dev/null
        echo -n "."
    else
        echo -n "!"
        rm -f "$MODULES_DIR/$mod" # 清理下载失败或为空的文件
    fi
done
echo " 完成"

echo ""
echo "安装完成！输入 'vn' 即可启动管理面板。"
