#!/usr/bin/env bash
# ====================================================
# VPS 文件/目录交互式发送工具 (基于 rsync + sshpass)
# ====================================================

# 定义颜色输出
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}       VPS 跨机文件/目录推送工具 (rsync)${NC}"
echo -e "${CYAN}=============================================${NC}\n"

# 1. 环境准备与依赖检查 (提前，避免用户填完信息才报错)
echo -e "${YELLOW}正在检查运行环境...${NC}"

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

install_pkg() {
    local pkg=$1
    echo -e "${YELLOW}未检测到 ${pkg},正在尝试自动安装...${NC}"
    if command -v apt-get &> /dev/null; then
        $SUDO apt-get update -qq && $SUDO apt-get install -y "$pkg"
    elif command -v yum &> /dev/null; then
        $SUDO yum install -y "$pkg"
    elif command -v apk &> /dev/null; then
        $SUDO apk add "$pkg"
    else
        echo -e "${RED}❌ 无法自动安装 ${pkg},请手动安装后重试。${NC}"
        exit 1
    fi
}

command -v rsync   &> /dev/null || install_pkg rsync
command -v sshpass &> /dev/null || install_pkg sshpass

echo -e "${GREEN}✅ 环境检查通过${NC}\n"
echo -e "${YELLOW}---------------------------------------------${NC}"

# 2. 获取本地路径并校验
read -p "请输入要发送的本地路径 (文件或目录, 必填): " LOCAL_PATH
if [ -z "$LOCAL_PATH" ] || [ ! -e "$LOCAL_PATH" ]; then
    echo -e "${RED}❌ 错误: 本地路径为空或不存在,请检查输入!${NC}"
    exit 1
fi

# 3. 获取远程服务器 IP
read -p "请输入接收端 VPS 的 IP 地址 (必填): " REMOTE_IP
if [ -z "$REMOTE_IP" ]; then
    echo -e "${RED}❌ 错误: IP 地址不能为空!${NC}"
    exit 1
fi

# 4. 获取远程 SSH 端口 (默认 22)
read -p "请输入接收端 SSH 端口 [默认 22]: " REMOTE_PORT
REMOTE_PORT=${REMOTE_PORT:-22}

# 5. 获取远程登录用户名 (默认 root)
read -p "请输入接收端登录用户 [默认 root]: " REMOTE_USER
REMOTE_USER=${REMOTE_USER:-root}

# 6. 获取远程目标路径
read -p "请输入在远程 VPS 上的保存路径 (必填, 如 /root/): " REMOTE_PATH
if [ -z "$REMOTE_PATH" ]; then
    echo -e "${RED}❌ 错误: 远程保存路径不能为空!${NC}"
    exit 1
fi

# 7. 获取密码 (隐藏输入)
read -s -p "请输入接收端用户 ${REMOTE_USER} 的密码 (输入时不可见): " REMOTE_PASS
echo -e "\n"

# 8. 执行传输
echo -e "${GREEN}🚀 开始推送 [ ${LOCAL_PATH} ] -> [ ${REMOTE_IP}:${REMOTE_PATH} ]${NC}"
echo -e "${YELLOW}---------------------------------------------${NC}"

export SSHPASS="${REMOTE_PASS}"
sshpass -e rsync -avzP \
    -e "ssh -p ${REMOTE_PORT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
    "${LOCAL_PATH}" \
    "${REMOTE_USER}@${REMOTE_IP}:${REMOTE_PATH}"

RSYNC_EXIT=$?
unset SSHPASS

# 9. 结果判断
echo -e "${YELLOW}---------------------------------------------${NC}"
if [ "${RSYNC_EXIT}" -eq 0 ]; then
    echo -e "${GREEN}🎉 传输成功完成!${NC}"
else
    echo -e "${RED}❌ 传输失败 (退出码: ${RSYNC_EXIT})!可能原因:网络不通、密码错误或远程路径无权限。${NC}"
fi
echo -e "${CYAN}=============================================${NC}"

exit "${RSYNC_EXIT}"
