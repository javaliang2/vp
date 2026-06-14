#!/bin/bash

# 获取当前时间
CURRENT_TIME=$(date "+%Y-%m-%d %H:%M:%S")

echo "=================================================="
echo "执行时间: $CURRENT_TIME"
echo "=================================================="

# 1. 记录清理前的“空间大户”
echo "-> 清理前，占用空间最大的 5 个日志文件："
du -sh /var/log/* /var/lib/docker/containers/*/*-json.log 2>/dev/null | sort -rh | head -n 5
echo "--------------------------------------------------"

# 2. 清理 Systemd Journal 日志
echo "-> 正在清理 journal 日志 (保留 100MB)..."
journalctl --vacuum-size=100M >/dev/null 2>&1

# 3. 删除旧的系统日志
echo "-> 正在删除旧的轮转日志 (*.gz, *.1)..."
rm -f /var/log/*.gz
rm -f /var/log/*.1

# 4. 抽干活动系统日志
echo "-> 正在抽干活动系统日志..."
truncate -s 0 /var/log/syslog
truncate -s 0 /var/log/kern.log 2>/dev/null
truncate -s 0 /var/log/ufw.log 2>/dev/null
truncate -s 0 /var/log/auth.log 2>/dev/null

# 5. 抽干 Docker 容器日志
echo "-> 正在抽干 Docker 容器日志..."
truncate -s 0 /var/lib/docker/containers/*/*-json.log 2>/dev/null

# 6. 清除系统包缓存
echo "-> 正在清理 APT 缓存..."
apt-get clean

# 7. 清理旧的临时文件
echo "-> 正在清理 /tmp 目录下的旧临时文件..."
find /tmp -type f -mtime +3 -delete

# 8. 记录清理后的磁盘情况
echo "--------------------------------------------------"
echo "-> 清理完成！当前的系统根目录磁盘占用："
df -h / | awk 'NR==2 {print "总大小: "$2" | 已用: "$3" | 可用: "$4" | 使用率: "$5}'
echo -e "==================================================\n"
