#!/bin/bash

# ==========================================
# rsync 自动化安装与更新脚本
# ==========================================

# 1. 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "❌ 错误: 请使用 root 权限运行此脚本 (例如: sudo bash $0)"
  exit 1
fi

echo "=== 开始检测并安装/更新 rsync ==="

# 2. 根据系统包管理器执行安装/更新
if command -v apt-get >/dev/null 2>&1; then
    echo "📦 检测到 Debian/Ubuntu 系统 (apt)..."
    apt-get update -y
    apt-get install -y rsync

elif command -v dnf >/dev/null 2>&1; then
    echo "📦 检测到 Fedora/RHEL/CentOS 8+ 系统 (dnf)..."
    dnf check-update rsync
    dnf install -y rsync

elif command -v yum >/dev/null 2>&1; then
    echo "📦 检测到 CentOS/RHEL 7 或更早版本 (yum)..."
    yum install -y rsync

elif command -v pacman >/dev/null 2>&1; then
    echo "📦 检测到 Arch Linux 系统 (pacman)..."
    pacman -Sy --noconfirm rsync

elif command -v zypper >/dev/null 2>&1; then
    echo "📦 检测到 openSUSE 系统 (zypper)..."
    zypper refresh
    zypper install -y rsync

elif command -v apk >/dev/null 2>&1; then
    echo "📦 检测到 Alpine Linux 系统 (apk)..."
    apk update
    apk add rsync

else
    echo "❌ 错误: 未检测到受支持的包管理器 (apt, dnf, yum, pacman, zypper, apk)。"
    echo "请手动下载源码编译安装。"
    exit 1
fi

# 3. 验证安装结果
echo "=== 流程结束 ==="

if command -v rsync >/dev/null 2>&1; then
    echo "✅ rsync 已成功安装/更新！当前版本信息如下："
    echo "------------------------------------------------"
    rsync --version | head -n 1
    echo "------------------------------------------------"
else
    echo "❌ 安装似乎失败，请检查上方的错误日志。"
    exit 1
fi
