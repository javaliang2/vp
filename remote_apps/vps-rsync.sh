#!/usr/bin/env bash
# ====================================================
#  VPS 文件/目录交互式发送工具 (rsync + 自动密钥管理)
#  流程：检测密钥 → 没有则用密码推公钥 → rsync 走密钥
# ====================================================

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}✔ ${NC}$*"; }
warn() { echo -e "${YELLOW}! ${NC}$*"; }
err()  { echo -e "${RED}✘ ${NC}$*"; exit 1; }
info() { echo -e "${CYAN}i ${NC}$*"; }

echo -e "${CYAN}${BOLD}=============================================${NC}"
echo -e "${CYAN}${BOLD}       VPS 跨机文件/目录推送工具 (rsync)${NC}"
echo -e "${CYAN}${BOLD}=============================================${NC}"
echo ""

# ── 环境检查 ────────────────────────────────────────────────
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

install_pkg() {
    local pkg=$1
    warn "未检测到 ${pkg}，正在自动安装..."
    if command -v apt-get &>/dev/null; then
        $SUDO apt-get update -qq && $SUDO apt-get install -y -qq "$pkg"
    elif command -v yum &>/dev/null; then
        $SUDO yum install -y "$pkg"
    elif command -v apk &>/dev/null; then
        $SUDO apk add -q "$pkg"
    else
        err "无法自动安装 ${pkg}，请手动安装后重试"
    fi
}

command -v rsync   &>/dev/null || install_pkg rsync
command -v ssh     &>/dev/null || install_pkg openssh-client
log "环境检查通过"
echo ""

# ── 收集参数 ────────────────────────────────────────────────
read -rp "本地路径（文件或目录，必填）: " LOCAL_PATH
[ -z "$LOCAL_PATH" ] || [ ! -e "$LOCAL_PATH" ] && err "路径为空或不存在"

read -rp "目标 VPS IP（必填）: " REMOTE_IP
[ -z "$REMOTE_IP" ] && err "IP 不能为空"

read -rp "SSH 端口 [默认 22]: " REMOTE_PORT
REMOTE_PORT=${REMOTE_PORT:-22}

read -rp "登录用户 [默认 root]: " REMOTE_USER
REMOTE_USER=${REMOTE_USER:-root}

read -rp "远程保存路径（必填，如 /root/）: " REMOTE_PATH
[ -z "$REMOTE_PATH" ] && err "远程路径不能为空"

echo ""

# ── 密钥检测与自动推送 ──────────────────────────────────────
SSH_OPTS="-p ${REMOTE_PORT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
KEY_OK=0

# 找本机已有的公钥（优先 ed25519，其次 rsa）
PUBKEY_FILE=""
for f in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
    [ -f "$f" ] && PUBKEY_FILE="$f" && break
done

# 测试是否已经可以密钥登录
if ssh -p "$REMOTE_PORT" \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       -o BatchMode=yes \
       -o ConnectTimeout=8 \
       "${REMOTE_USER}@${REMOTE_IP}" "echo ok" &>/dev/null; then
    KEY_OK=1
    log "已检测到可用密钥，直接走密钥登录"
fi

if [ "$KEY_OK" -eq 0 ]; then
    info "未找到可用密钥，将用密码把公钥推到目标机（仅需一次）"
    echo ""

    # 没有公钥就生成一对
    if [ -z "$PUBKEY_FILE" ]; then
        info "本机无 SSH 密钥，自动生成 ed25519 密钥对..."
        ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -C "vps-send-$(hostname)" \
            || err "密钥生成失败"
        PUBKEY_FILE=~/.ssh/id_ed25519.pub
        log "密钥已生成：$PUBKEY_FILE"
    else
        info "使用现有公钥：$PUBKEY_FILE"
    fi

    PUBKEY_CONTENT=$(cat "$PUBKEY_FILE")
    echo ""

    # 检查 sshpass 是否可用（推公钥需要密码）
    if ! command -v sshpass &>/dev/null; then
        warn "需要 sshpass 来完成一次性密码推送..."
        install_pkg sshpass
    fi

    read -s -rp "输入 ${REMOTE_USER}@${REMOTE_IP} 的密码（仅此一次）: " REMOTE_PASS
    echo ""
    echo ""

    # 推公钥到目标机
    info "推送公钥到目标机..."
    export SSHPASS="${REMOTE_PASS}"

    if sshpass -e ssh $SSH_OPTS "${REMOTE_USER}@${REMOTE_IP}" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
         echo '${PUBKEY_CONTENT}' >> ~/.ssh/authorized_keys && \
         sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys && \
         chmod 600 ~/.ssh/authorized_keys"; then
        log "公钥推送成功"
        KEY_OK=1
    else
        unset SSHPASS
        err "公钥推送失败（密码错误或 SSH 未开放密码登录），请检查后重试"
    fi
    unset SSHPASS

    # 验证密钥是否生效
    info "验证密钥登录..."
    if ssh -p "$REMOTE_PORT" \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -o BatchMode=yes \
           -o ConnectTimeout=8 \
           "${REMOTE_USER}@${REMOTE_IP}" "echo ok" &>/dev/null; then
        log "密钥登录验证通过 ✓"
    else
        warn "密钥验证失败，可能目标机未开启 PubkeyAuthentication"
        warn "请在目标机 /etc/ssh/sshd_config 确认："
        warn "  PubkeyAuthentication yes"
        warn "  AuthorizedKeysFile .ssh/authorized_keys"
        warn "然后执行：systemctl restart sshd"
        err "迁移中止"
    fi
fi

# ── 执行 rsync 传输（全程走密钥，不再需要密码）──────────────
echo ""
echo -e "${GREEN}${BOLD}🚀 开始推送${NC}"
info "  本地：$LOCAL_PATH"
info "  目标：${REMOTE_USER}@${REMOTE_IP}:${REMOTE_PATH}  (端口 ${REMOTE_PORT})"
echo ""

rsync -avzP \
    -e "ssh ${SSH_OPTS}" \
    "${LOCAL_PATH}" \
    "${REMOTE_USER}@${REMOTE_IP}:${REMOTE_PATH}"
RSYNC_EXIT=$?

echo ""
echo -e "${CYAN}${BOLD}=============================================${NC}"
if [ "${RSYNC_EXIT}" -eq 0 ]; then
    log "传输成功完成！"
    echo ""
    info "下次推送到同一台机器直接运行脚本即可，无需再输密码"
    info "如需关闭目标机的密码登录（推荐）："
    echo ""
    echo "    ssh -p ${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_IP} \\"
    echo "      \"sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' \\"
    echo "      /etc/ssh/sshd_config && systemctl restart sshd\""
    echo ""
else
    err "传输失败（退出码：${RSYNC_EXIT}），可能原因：网络不通、远程路径无权限"
fi
echo -e "${CYAN}${BOLD}=============================================${NC}"
exit "${RSYNC_EXIT}"
