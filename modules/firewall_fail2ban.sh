#!/bin/bash
# 防火墙与 Fail2Ban 模块 (修复优化版 v2 - 增强开机自启)

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vn_modules/common.sh 2>/dev/null || {
        echo "无法加载公共函数库"
        exit 1
    }
fi
detect_os
check_dependencies

# -------- 防火墙 --------
detect_firewall() {
    if command -v ufw &>/dev/null; then
        if ufw status | grep -q "Status: active"; then
            printf "${GREEN}UFW 运行中${NC}\n"
        else
            printf "${YELLOW}UFW 已安装（未运行）${NC}\n"
        fi
    elif command -v firewall-cmd &>/dev/null; then
        if firewall-cmd --state 2>/dev/null | grep -q "running"; then
            printf "${GREEN}firewalld 运行中${NC}\n"
        else
            printf "${YELLOW}firewalld 已安装（未运行）${NC}\n"
        fi
    elif command -v iptables &>/dev/null; then
        local policy=$(iptables -L INPUT -n 2>/dev/null | head -1 | awk '{print $4}')
        local rules_count=$(iptables -L INPUT -n 2>/dev/null | grep -c '^[0-9]')
        if [ "$policy" != "ACCEPT" ] || [ "$rules_count" -gt 0 ]; then
            printf "${GREEN}iptables 运行中${NC}\n"
        else
            printf "${YELLOW}iptables 已安装（未运行）${NC}\n"
        fi
    else
        printf "${RED}未安装${NC}\n"
    fi
}

# 优化：统一防火墙类型判断，优先看"正在运行"的是哪个，而不是简单看"装没装"。
# 背景：install_firewall/enable_firewall 只会 stop/disable 另一个，不会卸载，
# 所以 ufw 和 firewalld 的可执行文件可能同时存在。之前 open_ports/close_ports 等函数
# 用 command -v 判断，会永远优先选中先装的那个，跟 detect_firewall 实际报告的运行状态对不上。
# 若两者都未运行（比如刚装完还没启用），按 ufw > firewalld > iptables 的顺序兜底，保持原有默认行为。
get_active_firewall() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo "ufw"
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q "running"; then
        echo "firewalld"
    elif command -v ufw &>/dev/null; then
        echo "ufw"
    elif command -v firewall-cmd &>/dev/null; then
        echo "firewalld"
    elif command -v iptables &>/dev/null; then
        echo "iptables"
    else
        echo "none"
    fi
}

# 优化：纯 iptables 场景（没装 ufw/firewalld）下的规则持久化。
# 原理跟防扫描的持久化一致：写入 iptables-save 快照 + 注册开机恢复的 systemd 服务，
# 不依赖发行版专属的 iptables-persistent/netfilter-persistent 包。
persist_iptables_rules() {
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null
    if command -v ip6tables &>/dev/null; then
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
    fi

    if [ ! -f /etc/systemd/system/iptables-restore-custom.service ]; then
        cat > /etc/systemd/system/iptables-restore-custom.service <<'EOF'
[Unit]
Description=Restore iptables rules saved by firewall_fail2ban.sh
After=network.target
Before=fail2ban.service f2b-portscan-restore.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c '[ -f /etc/iptables/rules.v4 ] && iptables-restore < /etc/iptables/rules.v4; [ -f /etc/iptables/rules.v6 ] && command -v ip6tables-restore >/dev/null 2>&1 && ip6tables-restore < /etc/iptables/rules.v6; exit 0'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload &>/dev/null
        systemctl enable iptables-restore-custom.service &>/dev/null
    fi
    printf "${GREEN}iptables 规则已持久化 (/etc/iptables/rules.v4)，并注册开机恢复服务${NC}\n"
}

install_firewall() {
    local ssh_port=$(get_ssh_port)
    printf "${BLUE}正在安装防火墙...${NC}\n"
    if [ "$OS_FAMILY" = "debian" ]; then
        # 优化：安装前清理可能冲突的 firewalld
        if command -v systemctl &>/dev/null; then
            systemctl stop firewalld &>/dev/null
            systemctl disable firewalld &>/dev/null
        fi
        apt-get update -qq && apt-get install -y ufw || {
            printf "${RED}UFW 安装失败${NC}\n"; return
        }
        ufw allow "$ssh_port"/tcp      
        printf "${GREEN}UFW 安装完成，SSH 端口 $ssh_port 已预放行（防火墙未启用）${NC}\n"
    else
        # 优化：安装前清理可能冲突的 ufw
        if command -v systemctl &>/dev/null; then
            systemctl stop ufw &>/dev/null
            systemctl disable ufw &>/dev/null
        fi
        yum install -y firewalld || {
            printf "${RED}firewalld 安装失败${NC}\n"; return
        }
        systemctl start firewalld && systemctl enable firewalld
        firewall-cmd --zone=public --add-port="${ssh_port}/tcp" --permanent
        firewall-cmd --reload
        printf "${GREEN}firewalld 安装并已启用，SSH 端口 $ssh_port 已放行${NC}\n"
    fi
}

enable_firewall() {
    local ssh_port=$(get_ssh_port)
    case "$(get_active_firewall)" in
        ufw)
            # 优化：规避双防火墙冲突
            if command -v systemctl &>/dev/null; then
                systemctl stop firewalld &>/dev/null
                systemctl disable firewalld &>/dev/null
                systemctl enable ufw &>/dev/null
            fi
            ufw allow "$ssh_port"/tcp
            ufw --force enable
            printf "${GREEN}UFW 已开启，SSH 端口 $ssh_port 已放行，并设为开机自启${NC}\n"
            ;;
        firewalld)
            # 优化：规避双防火墙冲突
            if command -v systemctl &>/dev/null; then
                systemctl stop ufw &>/dev/null
                systemctl disable ufw &>/dev/null
            fi
            firewall-cmd --zone=public --add-port="${ssh_port}/tcp" --permanent 2>/dev/null
            firewall-cmd --reload
            if command -v systemctl &>/dev/null; then
                systemctl start firewalld && systemctl enable firewalld
            fi
            printf "${GREEN}firewalld 已开启，SSH 端口 $ssh_port 已放行，并设为开机自启${NC}\n"
            ;;
        *)
            printf "${RED}未找到防火墙，请先安装${NC}\n"
            ;;
    esac
}

open_all_ports() {
    local ssh_port=$(get_ssh_port)
    printf "${YELLOW}开放全部端口前，已确保 SSH($ssh_port) 不被禁用${NC}\n"
    case "$(get_active_firewall)" in
        ufw)
            # 修复：仅改默认策略（ufw default allow incoming）不会覆盖 close_ports 之前加过的
            # 显式 deny 规则（deny 优先级高于默认策略），必须先 reset 清空历史规则再重新放行
            printf "${YELLOW}正在清理历史显式拒绝规则...${NC}\n"
            ufw --force reset
            ufw default allow incoming
            ufw default allow outgoing
            ufw allow "$ssh_port"/tcp
            ufw --force enable
            printf "${GREEN}UFW 默认策略已设为 ALLOW，历史 deny 规则已一并清空${NC}\n"
            ;;
        firewalld)
            # 修复：--set-default-zone 只影响"未显式绑定 zone 的新接口"，
            # 脚本其它地方全是显式操作 --zone=public，若当前网卡已绑定在 public zone，
            # 改默认 zone 对现网不生效。改为直接把当前实际生效的 zone 的 target 设为 ACCEPT。
            local active_zones=$(firewall-cmd --get-active-zones 2>/dev/null | grep -v "interfaces\|sources" | tr -d ' ')
            [ -z "$active_zones" ] && active_zones="public"
            for zone in $active_zones; do
                firewall-cmd --zone="$zone" --set-target=ACCEPT --permanent 2>/dev/null
            done
            firewall-cmd --set-default-zone=trusted 2>/dev/null
            firewall-cmd --reload
            printf "${GREEN}firewalld 当前生效区域 (%s) 已设为 ACCEPT，默认区域也已设为 trusted${NC}\n" "$active_zones"
            ;;
        iptables)
            iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT; iptables -F
            persist_iptables_rules
            printf "${GREEN}iptables 默认策略已改为 ACCEPT${NC}\n"
            ;;
        *)
            printf "${RED}未检测到可用防火墙${NC}\n"
            ;;
    esac
}

close_all_ports() {
    local ssh_port=$(get_ssh_port)
    printf "${RED}⚠ 关闭全部端口可能导致你失去 SSH 连接！${NC}\n"
    read -p "是否保留 SSH 端口？(推荐保留) [Y/n]: " keep_ssh
    keep_ssh=${keep_ssh:-Y}
    local open_ssh=false
    [[ $keep_ssh =~ ^[Yy]$ ]] && open_ssh=true

    case "$(get_active_firewall)" in
        ufw)
            ufw --force reset
            ufw default deny incoming
            ufw default allow outgoing
            $open_ssh && ufw allow "$ssh_port"/tcp
            ufw --force enable
            printf "${GREEN}UFW 已重置，仅保留必要端口${NC}\n"
            ;;
        firewalld)
            firewall-cmd --set-default-zone=public
            if [ "$open_ssh" = true ]; then
                firewall-cmd --zone=public --add-port="${ssh_port}/tcp" --permanent
            else
                firewall-cmd --zone=public --remove-port="${ssh_port}/tcp" --permanent 2>/dev/null
                firewall-cmd --zone=public --remove-service=ssh --permanent 2>/dev/null
            fi
            firewall-cmd --reload
            printf "${GREEN}firewalld 默认区域已设为 public，仅开放必要端口${NC}\n"
            ;;
        iptables)
            iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT ACCEPT; iptables -F
            $open_ssh && iptables -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT
            iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
            persist_iptables_rules
            printf "${GREEN}iptables 已配置为 DROP 所有入站（SSH: $open_ssh）${NC}\n"
            ;;
        *)
            printf "${RED}未检测到可用防火墙${NC}\n"
            ;;
    esac
}

open_ports() {
    read -p "请输入要开放的端口（多个用空格分隔，支持范围如 1000:2000）：" ports
    [[ -z "$ports" ]] && printf "${RED}未输入任何端口${NC}\n" && return
    case "$(get_active_firewall)" in
        ufw)
            for port in $ports; do
                if [[ $port == *:* ]]; then
                    ufw allow proto tcp to any port "$port"
                else
                    ufw allow "$port"
                fi
            done
            printf "${GREEN}UFW 规则已添加${NC}\n"
            ;;
        firewalld)
            for port in $ports; do
                # 修复：firewalld 端口范围用短横线而非冒号，需转换否则范围端口开放失败
                local fw_port="${port/:/-}"
                firewall-cmd --zone=public --add-port="${fw_port}/tcp" --permanent
            done
            firewall-cmd --reload
            printf "${GREEN}firewalld 端口已开放${NC}\n"
            ;;
        iptables)
            for port in $ports; do
                if [[ $port == *:* ]]; then
                    start=$(echo "$port" | cut -d: -f1); end=$(echo "$port" | cut -d: -f2)
                    iptables -A INPUT -p tcp --dport "${start}:${end}" -j ACCEPT
                else
                    iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
                fi
            done
            persist_iptables_rules
            printf "${GREEN}iptables 规则已添加${NC}\n"
            ;;
        *)
            printf "${RED}未检测到可用防火墙${NC}\n"
            ;;
    esac
}

close_ports() {
    read -p "请输入要关闭的端口（多个用空格分隔）：" ports
    [[ -z "$ports" ]] && printf "${RED}未输入任何端口${NC}\n" && return
    case "$(get_active_firewall)" in
        ufw)
            for port in $ports; do
                # 修复：范围端口需用完整语法+协议，否则 ufw 会报错拒绝执行，导致关不掉
                if [[ $port == *:* ]]; then
                    ufw deny proto tcp to any port "$port"
                else
                    ufw deny "$port"
                fi
            done
            printf "${GREEN}UFW 拒绝规则已添加${NC}\n"
            ;;
        firewalld)
            for port in $ports; do
                # 修复：同步转换端口范围格式（冒号→短横线），与 open_ports 保持一致
                local fw_port="${port/:/-}"
                firewall-cmd --zone=public --remove-port="${fw_port}/tcp" --permanent
            done
            firewall-cmd --reload
            printf "${GREEN}firewalld 端口已关闭${NC}\n"
            ;;
        iptables)
            for port in $ports; do iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true; done
            persist_iptables_rules
            printf "${GREEN}iptables 规则已尝试删除${NC}\n"
            ;;
        *)
            printf "${RED}未检测到可用防火墙${NC}\n"
            ;;
    esac
}

show_firewall_status() {
    clear
    printf "${BLUE}===== 防火墙详细状态 =====${NC}\n"
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        printf "${GREEN}UFW 状态:${NC}\n"
        ufw status verbose
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q "running"; then
        printf "${GREEN}firewalld 状态:${NC}\n"
        firewall-cmd --state
        echo ""
        printf "默认区域: %s\n" "$(firewall-cmd --get-default-zone)"
        for zone in $(firewall-cmd --get-active-zones | grep -v "interfaces\|sources" | tr ' ' '\n' | grep -v '^$'); do
            printf "\n区域: %s\n" "$zone"
            firewall-cmd --zone="$zone" --list-all
        done
    elif command -v iptables &>/dev/null; then
        printf "${YELLOW}iptables 规则 (无 UFW/firewalld 管理):${NC}\n"
        iptables -L INPUT -n -v --line-numbers 2>/dev/null
        iptables -L FORWARD -n -v --line-numbers 2>/dev/null
        iptables -L OUTPUT -n -v --line-numbers 2>/dev/null
    else
        printf "${RED}未检测到活动的防火墙${NC}\n"
    fi
    echo ""
    read -p "按回车键继续..." dummy
}

# -------- Fail2Ban --------
# 优化：状态检测同时显示运行状态与开机自启状态，避免"装完忘启用"
detect_fail2ban() {
    if command -v fail2ban-client &>/dev/null; then
        local run_txt enable_txt
        if pgrep -x fail2ban-server &>/dev/null; then
            run_txt="${GREEN}运行中${NC}"
        else
            run_txt="${YELLOW}未运行${NC}"
        fi
        if command -v systemctl &>/dev/null; then
            if systemctl is-enabled fail2ban &>/dev/null; then
                enable_txt="${GREEN}已开机自启${NC}"
            else
                enable_txt="${RED}未开机自启${NC}"
            fi
        elif command -v chkconfig &>/dev/null; then
            if chkconfig --list fail2ban 2>/dev/null | grep -q "3:on"; then
                enable_txt="${GREEN}已开机自启${NC}"
            else
                enable_txt="${RED}未开机自启${NC}"
            fi
        else
            enable_txt="${YELLOW}未知${NC}"
        fi
        printf "已安装（%b / %b）\n" "$run_txt" "$enable_txt"
    else
        printf "${RED}未安装${NC}\n"
    fi
}

# 优化：独立的开机自启设置函数，install_fail2ban 复用，也可在菜单中单独调用
# 适用场景：已安装但未设置自启、手动装过 fail2ban、systemctl enable 未生效等
enable_fail2ban_autostart() {
    if ! command -v fail2ban-client &>/dev/null; then
        printf "${RED}Fail2Ban 未安装，请先安装${NC}\n"; return
    fi
    printf "${BLUE}正在设置 Fail2Ban 开机自启...${NC}\n"
    if command -v systemctl &>/dev/null; then
        systemctl enable fail2ban &>/dev/null
        if systemctl is-enabled fail2ban &>/dev/null; then
            printf "${GREEN}✔ 已设置开机自启（systemd）${NC}\n"
        else
            printf "${RED}✘ 设置失败，请手动执行: systemctl enable fail2ban${NC}\n"
        fi
        if ! pgrep -x fail2ban-server &>/dev/null; then
            systemctl start fail2ban &>/dev/null && printf "${GREEN}已同步启动 Fail2Ban${NC}\n"
        fi
    else
        chkconfig fail2ban on 2>/dev/null || update-rc.d fail2ban defaults 2>/dev/null
        if command -v chkconfig &>/dev/null && chkconfig --list fail2ban 2>/dev/null | grep -q "3:on"; then
            printf "${GREEN}✔ 已设置开机自启（chkconfig）${NC}\n"
        else
            printf "${YELLOW}已尝试设置，请手动确认: chkconfig fail2ban on 或 update-rc.d fail2ban defaults${NC}\n"
        fi
        if ! pgrep -x fail2ban-server &>/dev/null; then
            service fail2ban start &>/dev/null && printf "${GREEN}已同步启动 Fail2Ban${NC}\n"
        fi
    fi
}

# 优化：多重兜底检测当前登录 IP
# 背景：SSH_CLIENT/SSH_CONNECTION 只在原始 SSH 登录 shell 里存在，
# 若脚本是在 tmux/screen 断开重连后的会话里运行，这两个变量会是空的，
# 导致白名单写入失败而不自知，存在把自己封锁在外的风险。
get_current_client_ip() {
    local ip=""
    ip=$(echo "$SSH_CLIENT" | awk '{print $1}')
    if [ -z "$ip" ]; then
        ip=$(echo "$SSH_CONNECTION" | awk '{print $1}')
    fi
    if [ -z "$ip" ]; then
        # who am i 兜底：适配 tmux/screen 场景，读取终端登录记录里的来源 IP
        ip=$(who am i 2>/dev/null | grep -oE '\([0-9]{1,3}(\.[0-9]{1,3}){3}\)' | tr -d '()' | head -1)
    fi
    if [ -z "$ip" ]; then
        # w 命令兜底：取当前终端对应的登录来源
        ip=$(w -h 2>/dev/null | awk -v tty="$(tty 2>/dev/null | sed 's|/dev/||')" '$2==tty{print $3}' | grep -oE '^[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -1)
    fi
    echo "$ip"
}

install_fail2ban() {
    printf "${BLUE}正在安装 Fail2Ban...${NC}\n"
    if [ "$OS_FAMILY" = "debian" ]; then
        apt-get update -qq && apt-get install -y fail2ban iptables || {
            printf "${RED}Fail2Ban 安装失败${NC}\n"; return
        }
    else
        yum install -y epel-release && yum install -y fail2ban iptables || {
            printf "${RED}Fail2Ban 安装失败${NC}\n"; return
        }
    fi

    local jail_local="/etc/fail2ban/jail.local"
    [ ! -f "$jail_local" ] && cp /etc/fail2ban/jail.conf "$jail_local"

    # 优化：自动将当前 SSH 连接 IP 写入白名单，防止误封自己
    # 修复：SSH_CLIENT 在 tmux/screen 断线重连后会丢失，改用多重兜底检测
    local current_ip=$(get_current_client_ip)
    if [ -n "$current_ip" ]; then
        if grep -q "^ignoreip" "$jail_local"; then
            sed -i "s|^ignoreip.*|& $current_ip|" "$jail_local"
        else
            sed -i "/^\[DEFAULT\]/a ignoreip = 127.0.0.1/8 ::1 $current_ip" "$jail_local"
        fi
        printf "${GREEN}已自动将您当前的远程 IP ($current_ip) 加为不限制白名单。${NC}\n"
    else
        printf "${RED}⚠ 未能自动检测到您当前的连接 IP（可能处于 tmux/screen 会话中）！${NC}\n"
        read -p "为避免把自己封锁在外，请手动输入您的公网 IP 加入白名单（留空跳过，风险自担）: " manual_ip
        if [ -n "$manual_ip" ]; then
            if grep -q "^ignoreip" "$jail_local"; then
                sed -i "s|^ignoreip.*|& $manual_ip|" "$jail_local"
            else
                sed -i "/^\[DEFAULT\]/a ignoreip = 127.0.0.1/8 ::1 $manual_ip" "$jail_local"
            fi
            printf "${GREEN}已将 %s 加入白名单${NC}\n" "$manual_ip"
        fi
    fi

    if ! [ -f /var/log/auth.log ] && command -v journalctl &>/dev/null; then
        if grep -q '^\[sshd\]' "$jail_local"; then
            sed -i '/^\[sshd\]/,/^\[/ s/^backend.*/backend = systemd/' "$jail_local"
        else
            echo -e "[sshd]\nbackend = systemd" >> "$jail_local"
        fi
    fi

    # 优化：统一调用自启设置函数，安装即保证开机自启，逻辑不再重复
    enable_fail2ban_autostart

    sleep 2
    if pgrep -x fail2ban-server &>/dev/null; then
        printf "${GREEN}Fail2Ban 安装完成并已启动${NC}\n"
    else
        printf "${RED}Fail2Ban 安装后未能启动，请检查: journalctl -u fail2ban${NC}\n"
    fi
}

show_ban_records() {
    if ! command -v fail2ban-client &>/dev/null; then
        printf "${RED}Fail2Ban 未安装${NC}\n"; return
    fi
    printf "${BLUE}==== 拦截记录 ====${NC}\n"
    fail2ban-client status
    for jail in $(fail2ban-client status | grep "Jail list" | cut -d: -f2 | tr -d ','); do
        printf "${GREEN}-- $jail --${NC}\n"
        fail2ban-client status "$jail"
        echo ""
    done
}

# 优化：新增一键手动解封 IP 功能
unban_ip_fail2ban() {
    if ! command -v fail2ban-client &>/dev/null; then
        printf "${RED}Fail2Ban 未安装${NC}\n"; return
    fi
    read -p "请输入需要紧急解封的 IP: " target_ip
    [ -z "$target_ip" ] && printf "${RED}输入不能为空${NC}\n" && return
    
    printf "${YELLOW}正在尝试从所有 Jail 规则中释放 ${target_ip}...${NC}\n"
    local has_unbanned=false
    for jail in $(fail2ban-client status | grep "Jail list" | cut -d: -f2 | tr -d ','); do
        if fail2ban-client set "$jail" unbanip "$target_ip" &>/dev/null; then
            printf "${GREEN}已成功从 [$jail] 移出该 IP${NC}\n"
            has_unbanned=true
        fi
    done
    if [ "$has_unbanned" = false ]; then
        printf "${YELLOW}未在任何活动监控链中发现该 IP 封禁记录。${NC}\n"
    fi
}

config_fail2ban() {
    if ! command -v fail2ban-client &>/dev/null; then
        printf "${RED}Fail2Ban 未安装${NC}\n"; return
    fi
    local conf_file="/etc/fail2ban/jail.local"
    [ ! -f "$conf_file" ] && cp /etc/fail2ban/jail.conf "$conf_file"

    read -p "封禁时长(秒, 默认600): " bantime; bantime=${bantime:-600}
    read -p "时间窗口(秒, 默认600): " findtime; findtime=${findtime:-600}
    read -p "最大尝试次数(默认5): " maxretry; maxretry=${maxretry:-5}

    # 修复：限定只替换 [DEFAULT] 段落内的参数，避免覆盖 portscan 等 jail 单独设置的 bantime
    sed -i "/^\[DEFAULT\]/,/^\[/ s/^bantime.*=.*/bantime = $bantime/" "$conf_file"
    sed -i "/^\[DEFAULT\]/,/^\[/ s/^findtime.*=.*/findtime = $findtime/" "$conf_file"
    sed -i "/^\[DEFAULT\]/,/^\[/ s/^maxretry.*=.*/maxretry = $maxretry/" "$conf_file"

    if fail2ban-server -t &>/dev/null; then
        systemctl restart fail2ban 2>/dev/null || service fail2ban restart
        printf "${GREEN}参数已更新，Fail2Ban 已重启${NC}\n"
    else
        printf "${RED}配置语法错误，请检查 $conf_file${NC}\n"
    fi
}

uninstall_fail2ban() {
    read -p "确定要卸载 Fail2Ban 吗？[y/N] " confirm
    [[ ! $confirm =~ ^[Yy]$ ]] && return
    systemctl stop fail2ban 2>/dev/null; systemctl disable fail2ban 2>/dev/null
    if [ "$OS_FAMILY" = "debian" ]; then apt-get purge -y fail2ban; else yum remove -y fail2ban; fi
    printf "${GREEN}Fail2Ban 已卸载${NC}\n"
}

# 优化：新增独立的白名单管理菜单
# 场景：换了办公地点/新 IP、需要给同事临时加白名单、或安装时自动检测失败需要事后补充
manage_fail2ban_whitelist() {
    local jail_local="/etc/fail2ban/jail.local"
    if [ ! -f "$jail_local" ]; then
        printf "${RED}配置文件不存在，请先安装 Fail2Ban${NC}\n"; return
    fi
    while true; do
        clear
        printf "${BLUE}===== Fail2Ban 白名单管理 =====${NC}\n"
        local current_list=$(grep "^ignoreip" "$jail_local" | head -1 | sed 's/^ignoreip[[:space:]]*=[[:space:]]*//')
        printf "当前白名单: %s\n" "${current_list:-无}"
        echo "--------------------------------------"
        echo "1. 添加 IP/网段到白名单"
        echo "2. 从白名单移除 IP"
        echo "3. 重新检测并添加当前连接 IP"
        echo "0. 返回"
        read -p "选择: " wl_choice
        case $wl_choice in
            1)
                read -p "输入要加入白名单的 IP/网段 (如 1.2.3.4 或 1.2.3.0/24): " new_ip
                [ -z "$new_ip" ] && continue
                if grep -q "^ignoreip" "$jail_local"; then
                    sed -i "s|^ignoreip.*|& $new_ip|" "$jail_local"
                else
                    sed -i "/^\[DEFAULT\]/a ignoreip = 127.0.0.1/8 ::1 $new_ip" "$jail_local"
                fi
                if fail2ban-server -t &>/dev/null; then
                    fail2ban-client reload &>/dev/null
                    printf "${GREEN}已添加 %s 到白名单${NC}\n" "$new_ip"
                else
                    printf "${RED}配置语法错误，请检查${NC}\n"
                fi
                read -p "按回车键继续..." dummy
                ;;
            2)
                read -p "输入要移除的 IP: " rm_ip
                [ -z "$rm_ip" ] && continue
                sed -i "/^ignoreip/ s/[[:space:]]$rm_ip\b//" "$jail_local"
                if fail2ban-server -t &>/dev/null; then
                    fail2ban-client reload &>/dev/null
                    printf "${GREEN}已从白名单移除 %s${NC}\n" "$rm_ip"
                else
                    printf "${RED}配置语法错误，已导致校验失败，请手动检查 %s${NC}\n" "$jail_local"
                fi
                read -p "按回车键继续..." dummy
                ;;
            3)
                local ip=$(get_current_client_ip)
                if [ -z "$ip" ]; then
                    printf "${RED}未能自动检测到当前连接 IP，请使用选项 1 手动添加${NC}\n"
                else
                    if grep -q "^ignoreip" "$jail_local"; then
                        sed -i "s|^ignoreip.*|& $ip|" "$jail_local"
                    else
                        sed -i "/^\[DEFAULT\]/a ignoreip = 127.0.0.1/8 ::1 $ip" "$jail_local"
                    fi
                    fail2ban-client reload &>/dev/null
                    printf "${GREEN}已添加当前连接 IP %s 到白名单${NC}\n" "$ip"
                fi
                read -p "按回车键继续..." dummy
                ;;
            0) break ;;
            *) printf "${RED}无效选项${NC}\n"; sleep 1 ;;
        esac
    done
}

# ---------- 防扫描 / 黑名单/地域限制----------
advanced_defense_menu() {
    while true; do
        clear
        printf "${BLUE}===== 高级入侵防御 =====${NC}\n"
        printf "Fail2Ban: "; detect_fail2ban
        echo "1. 启用防端口扫描 (recidive+portscan)"
        echo "2. IP 黑名单管理 (ipset)"
        echo "3. GeoIP 国家/地域封锁 (自动载入)"
        echo "4. WordPress 防护 (wp-login/xmlrpc 爆破)"
        echo "0. 返回 Fail2Ban 菜单"
        read -p "选择: " ad_choice
        case $ad_choice in
            1) enable_portscan_protection ;;
            2) manage_ip_blacklist ;;
            3) manage_geoip ;;
            4) enable_wp_login_protection ;;
            0) break ;;
            *) printf "${RED}无效选项${NC}\n"; sleep 1 ;;
        esac
    done
}

# ---------- 防端口扫描 ----------
# 优化：检测 firewalld 是否在跑，以及当前 iptables 走的是 legacy 还是 nf_tables 后端。
# 二者一般不会互相清除规则（各自独立生效于同一 netfilter hook），
# 但用 firewall-cmd 审计时看不到这里加的规则，容易误判为没生效，所以在此提前告知。
check_firewall_backend_conflict() {
    if command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q running; then
        local ipt_backend
        ipt_backend=$(iptables --version 2>&1 | grep -oE '\(legacy\)|\(nf_tables\)' | tr -d '()')
        printf "${YELLOW}⚠ 检测到 firewalld 正在运行（iptables 后端: %s）。${NC}\n" "${ipt_backend:-未知}"
        printf "${YELLOW}  本功能直接操作 iptables，独立于 firewalld 管理，两者通常不会互相冲突或清除规则，${NC}\n"
        printf "${YELLOW}  但 firewall-cmd 审计时看不到这里加的规则，需用 iptables -L F2B_PORTSCAN -n 单独确认。${NC}\n"
        read -p "是否继续? [Y/n]: " confirm_continue
        confirm_continue=${confirm_continue:-Y}
        [[ ! $confirm_continue =~ ^[Yy]$ ]] && return 1
    fi
    return 0
}

# 优化：从当前已启用的防火墙里读出已放行端口，作为白名单默认值，
# 避免用户在 open_ports() 里新开了业务端口，却忘了同步到这里而被误封
get_active_open_ports() {
    local ports=""
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ports=$(ufw status 2>/dev/null | grep -i "ALLOW" | awk '{print $1}' | grep -oE '^[0-9]+' | sort -un | paste -sd, -)
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q running; then
        ports=$(firewall-cmd --zone=public --list-ports 2>/dev/null | tr ' ' '\n' | grep -oE '^[0-9]+' | sort -un | paste -sd, -)
    elif command -v iptables &>/dev/null; then
        ports=$(iptables -L INPUT -n 2>/dev/null | grep ACCEPT | grep -oE 'dpt:[0-9]+' | cut -d: -f2 | sort -un | paste -sd, -)
    fi
    echo "$ports"
}

# 优化：持久化探测链，防止重启后静默失效
# 原理：把白名单端口写入配置文件，注册一个在 fail2ban 启动前执行的 systemd 服务，
# 开机自动重建 F2B_PORTSCAN(6) 检测链，不依赖具体发行版的 iptables-persistent 包
persist_portscan_rules() {
    local white_ports="$1"
    mkdir -p /etc/fail2ban/scripts
    echo "$white_ports" > /etc/fail2ban/scripts/portscan-whiteports.conf

    cat > /usr/local/sbin/f2b-portscan-restore.sh <<'RESTORE_EOF'
#!/bin/bash
# 由 firewall_fail2ban.sh 自动生成，开机重建端口扫描探测链，勿手动编辑
WHITE_PORTS=$(cat /etc/fail2ban/scripts/portscan-whiteports.conf 2>/dev/null)
[ -z "$WHITE_PORTS" ] && exit 0

while iptables -D INPUT -p tcp -m state --state NEW -j F2B_PORTSCAN 2>/dev/null; do :; done
iptables -F F2B_PORTSCAN 2>/dev/null; iptables -X F2B_PORTSCAN 2>/dev/null
iptables -N F2B_PORTSCAN
iptables -A F2B_PORTSCAN -p tcp -m multiport --dports "$WHITE_PORTS" -j RETURN
iptables -A F2B_PORTSCAN -p tcp -m state --state NEW -j LOG --log-prefix "Portscan4: "
iptables -I INPUT 1 -p tcp -m state --state NEW -j F2B_PORTSCAN

if command -v ip6tables &>/dev/null && [ -f /proc/net/if_inet6 ]; then
    while ip6tables -D INPUT -p tcp -m state --state NEW -j F2B_PORTSCAN6 2>/dev/null; do :; done
    ip6tables -F F2B_PORTSCAN6 2>/dev/null; ip6tables -X F2B_PORTSCAN6 2>/dev/null
    ip6tables -N F2B_PORTSCAN6
    ip6tables -A F2B_PORTSCAN6 -p tcp -m multiport --dports "$WHITE_PORTS" -j RETURN
    ip6tables -A F2B_PORTSCAN6 -p tcp -m state --state NEW -j LOG --log-prefix "Portscan6: "
    ip6tables -I INPUT 1 -p tcp -m state --state NEW -j F2B_PORTSCAN6
fi
RESTORE_EOF
    chmod +x /usr/local/sbin/f2b-portscan-restore.sh

    cat > /etc/systemd/system/f2b-portscan-restore.service <<'EOF'
[Unit]
Description=Restore Fail2Ban portscan detection chains (by firewall_fail2ban.sh)
After=network.target iptables-restore-custom.service
Before=fail2ban.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/f2b-portscan-restore.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload &>/dev/null
    systemctl enable f2b-portscan-restore.service &>/dev/null
    printf "${GREEN}已注册开机自启恢复服务 (f2b-portscan-restore.service)，重启后探测链会自动重建。${NC}\n"
}

# ---------- 防端口扫描 (修复优化版 v2 - 持久化/IPv6/防火墙冲突检测) ----------
enable_portscan_protection() {
    if ! pgrep -x fail2ban-server &>/dev/null; then
        printf "${RED}Fail2Ban 未运行，请先启动。${NC}\n"
        read -p "按回车键继续..." dummy
        return
    fi

    check_firewall_backend_conflict || { read -p "按回车键继续..." dummy; return; }

    # 修复：改为复用 get_ssh_port，避免和脚本其他地方各自解析 sshd_config 得出不一致的端口
    local ssh_port=$(get_ssh_port)
    ssh_port=${ssh_port:-22}

    # 优化：自动读取当前防火墙已放行端口作为默认白名单，减少"新开端口忘了同步"的误封风险
    local detected_ports=$(get_active_open_ports)
    local default_ports="${ssh_port},80,443"
    if [ -n "$detected_ports" ]; then
        default_ports=$(echo "${default_ports},${detected_ports}" | tr ',' '\n' | grep -v '^$' | sort -un | paste -sd, -)
    fi

    printf "${YELLOW}⚠ 警告：必须豁免正常业务端口，否则正常访客将被当成扫描者封禁！${NC}\n"
    printf "${BLUE}（已自动探测当前防火墙放行的端口并合并进默认值）${NC}\n"
    read -p "请输入要放行的业务端口 (逗号分隔，默认 $default_ports): " white_ports
    white_ports=${white_ports:-"$default_ports"}

    # 优化：IPv6 支持探测
    local has_ipv6=false
    if command -v ip6tables &>/dev/null && [ -f /proc/net/if_inet6 ]; then
        has_ipv6=true
    fi

    local jail_local="/etc/fail2ban/jail.local"
    local action_dir="/etc/fail2ban/action.d"
    cp "$jail_local" "${jail_local}.bak"

    # ---------- 1. 确保 iptables-allports action 存在 (IPv4) ----------
    if [ ! -f "$action_dir/iptables-allports.conf" ]; then
        mkdir -p "$action_dir"
        cat > "$action_dir/iptables-allports.conf" <<'EOF'
[Definition]
actionstart = <iptables> -N f2b-<n>
              <iptables> -A f2b-<n> -j <returntype>
              <iptables> -I <chain> -p <protocol> -j f2b-<n>
actionstop = <iptables> -D <chain> -p <protocol> -j f2b-<n>
             <iptables> -F f2b-<n>
             <iptables> -X f2b-<n>
actioncheck = <iptables> -n -L <chain> | grep -q 'f2b-<n>[ \t]'
actionban = <iptables> -I f2b-<n> 1 -s <ip> -j <blocktype>
actionunban = <iptables> -D f2b-<n> -s <ip> -j <blocktype>
[Init]
name = default
protocol = all
chain = INPUT
EOF
    fi

    # ---------- 1b. 确保 ip6tables-allports action 存在 (IPv6, 用显式二进制名，不依赖标签自动解析) ----------
    if [ "$has_ipv6" = true ] && [ ! -f "$action_dir/ip6tables-allports.conf" ]; then
        mkdir -p "$action_dir"
        cat > "$action_dir/ip6tables-allports.conf" <<'EOF'
[Definition]
actionstart = ip6tables -N f2b-<n>
              ip6tables -A f2b-<n> -j RETURN
              ip6tables -I <chain> -p <protocol> -j f2b-<n>
actionstop = ip6tables -D <chain> -p <protocol> -j f2b-<n>
             ip6tables -F f2b-<n>
             ip6tables -X f2b-<n>
actioncheck = ip6tables -n -L <chain> | grep -q 'f2b-<n>[ \t]'
actionban = ip6tables -I f2b-<n> 1 -s <ip> -j DROP
actionunban = ip6tables -D f2b-<n> -s <ip> -j DROP
[Init]
name = default
protocol = all
chain = INPUT
EOF
    fi

    # ---------- 2. 创建精准的 portscan 过滤器（v4/v6 分开，避免依赖 fail2ban 自动地址族识别）----------
    cat > /etc/fail2ban/filter.d/portscan.conf <<'EOF'
[Definition]
failregex = .*Portscan4: .* SRC=<HOST>
ignoreregex =
EOF
    if [ "$has_ipv6" = true ]; then
        cat > /etc/fail2ban/filter.d/portscan6.conf <<'EOF'
[Definition]
failregex = .*Portscan6: .* SRC=<HOST>
ignoreregex =
EOF
    fi

    # ---------- 3. 处理日志源 ----------
    local portscan_backend=""
    local logpath_entry=""

    if command -v journalctl &>/dev/null && fail2ban-server -t --dp 2>&1 | grep -q 'systemd'; then
        portscan_backend="backend = systemd"
    elif [ -f /var/log/kern.log ]; then
        logpath_entry="logpath = /var/log/kern.log"
    elif [ -f /var/log/messages ]; then
        logpath_entry="logpath = /var/log/messages"
    else
        printf "${RED}✘ 未找到内核日志路径，功能启用取消。${NC}\n"
        sleep 2; return
    fi

    # ---------- 4. 写入 jail (调整判定阈值) ----------
    if grep -q '^\[recidive\]' "$jail_local"; then
        sed -i '/^\[recidive\]/,/^\[/ s/^enabled.*/enabled = true/' "$jail_local"
    fi

    # 修复：用 awk 按段落边界删除旧的 [portscan]/[portscan6]，避免文件末尾段落删不干净导致重复
    for section in portscan portscan6; do
        if grep -q "^\[${section}\]" "$jail_local"; then
            awk -v sec="[$section]" '
                $0 == sec { skip=1; next }
                /^\[/ && skip { skip=0 }
                !skip { print }
            ' "$jail_local" > "${jail_local}.tmp" && mv "${jail_local}.tmp" "$jail_local"
        fi
    done

    # 优化点：阈值收紧到 4 次，因为业务端口已被排除，碰触其他端口 4 次必是扫描
    cat >> "$jail_local" <<EOF

[portscan]
enabled  = true
filter   = portscan
${logpath_entry}
${portscan_backend}
maxretry = 4
findtime = 60
bantime  = 86400
banaction = iptables-allports[name=portscan]
EOF

    if [ "$has_ipv6" = true ]; then
        cat >> "$jail_local" <<EOF

[portscan6]
enabled  = true
filter   = portscan6
${logpath_entry}
${portscan_backend}
maxretry = 4
findtime = 60
bantime  = 86400
banaction = ip6tables-allports[name=portscan6]
EOF
    fi

    # ---------- 5. 构建安全无误伤的 iptables/ip6tables 探测链 ----------
    # 修复：原来只 -D 一次，若之前重复执行残留了多条跳转规则会删不干净，改为循环删到删不动为止
    while iptables -D INPUT -p tcp -m state --state NEW -j F2B_PORTSCAN 2>/dev/null; do :; done
    iptables -F F2B_PORTSCAN 2>/dev/null
    iptables -X F2B_PORTSCAN 2>/dev/null

    iptables -N F2B_PORTSCAN
    # 1. 业务端口直接 RETURN 放行，绝对不记录日志（防止误封真实用户）
    iptables -A F2B_PORTSCAN -p tcp -m multiport --dports "$white_ports" -j RETURN
    # 2. 对其它非业务端口的探测，记录到内核日志
    iptables -A F2B_PORTSCAN -p tcp -m state --state NEW -j LOG --log-prefix "Portscan4: "
    iptables -I INPUT 1 -p tcp -m state --state NEW -j F2B_PORTSCAN

    if [ "$has_ipv6" = true ]; then
        while ip6tables -D INPUT -p tcp -m state --state NEW -j F2B_PORTSCAN6 2>/dev/null; do :; done
        ip6tables -F F2B_PORTSCAN6 2>/dev/null
        ip6tables -X F2B_PORTSCAN6 2>/dev/null

        ip6tables -N F2B_PORTSCAN6
        ip6tables -A F2B_PORTSCAN6 -p tcp -m multiport --dports "$white_ports" -j RETURN
        ip6tables -A F2B_PORTSCAN6 -p tcp -m state --state NEW -j LOG --log-prefix "Portscan6: "
        ip6tables -I INPUT 1 -p tcp -m state --state NEW -j F2B_PORTSCAN6
    fi

    # ---------- 6. 重载生效 + 持久化 ----------
    printf "${YELLOW}正在使规则生效...${NC}\n"
    if fail2ban-server -t 2>/dev/null; then
        fail2ban-client reload &>/dev/null || systemctl restart fail2ban 2>/dev/null
        persist_portscan_rules "$white_ports"
        printf "${GREEN}✔ 防端口扫描已激活！业务端口 ($white_ports) 已被保护，IPv6: %s${NC}\n" "$([ "$has_ipv6" = true ] && echo 已启用 || echo 未启用/系统无IPv6)"
    else
        printf "${RED}✘ 配置文件语法错误，已自动回滚。${NC}\n"
        cp "${jail_local}.bak" "$jail_local"
    fi

    read -p "按回车键继续..." dummy
}

# ---------- WordPress / nginx wp-login 爆破防护 ----------
# 场景：nginx 反代 WordPress 多节点部署下，wp-login.php / xmlrpc.php 是最常见的暴力破解入口。
# 通过 nginx 访问日志识别对这两个端点的 POST 请求次数，超阈值直接封 IP。
# 依赖 nginx-gateway.sh 已启用的 Cloudflare Real IP 还原，确保日志里记录的是真实客户端 IP。
enable_wp_login_protection() {
    if ! pgrep -x fail2ban-server &>/dev/null; then
        printf "${RED}Fail2Ban 未运行，请先启动。${NC}\n"
        read -p "按回车键继续..." dummy
        return
    fi

    printf "${BLUE}===== WordPress wp-login/xmlrpc 爆破防护 =====${NC}\n"
    read -p "nginx 访问日志路径 (支持通配符，多节点可用 *，默认 /var/log/nginx/*access*.log): " log_pattern
    log_pattern=${log_pattern:-"/var/log/nginx/*access*.log"}

    if ! compgen -G "$log_pattern" > /dev/null 2>&1; then
        printf "${YELLOW}⚠ 未在该路径下找到匹配的日志文件，请确认路径正确（仍会继续写入配置）。${NC}\n"
    fi

    read -p "最大尝试次数(默认5): " maxretry; maxretry=${maxretry:-5}
    read -p "时间窗口(秒, 默认300): " findtime; findtime=${findtime:-300}
    read -p "封禁时长(秒, 默认3600): " bantime; bantime=${bantime:-3600}

    # 过滤器：只匹配 POST 请求（GET 是正常打开登录页，不应计入失败次数）
    cat > /etc/fail2ban/filter.d/nginx-wplogin.conf <<'EOF'
[Definition]
failregex = ^<HOST> -.*"POST /(wp-login\.php|xmlrpc\.php)[^"]*" (200|401|403)
ignoreregex =
EOF

    local jail_local="/etc/fail2ban/jail.local"
    [ ! -f "$jail_local" ] && cp /etc/fail2ban/jail.conf "$jail_local"
    cp "$jail_local" "${jail_local}.bak"

    # 移除旧的同名 jail 段落，避免重复写入（沿用 portscan 的 awk 按段落边界删除写法）
    if grep -q '^\[nginx-wplogin\]' "$jail_local"; then
        awk '
            /^\[nginx-wplogin\]/ { skip=1; next }
            /^\[/ && skip { skip=0 }
            !skip { print }
        ' "$jail_local" > "${jail_local}.tmp" && mv "${jail_local}.tmp" "$jail_local"
    fi

    cat >> "$jail_local" <<EOF

[nginx-wplogin]
enabled  = true
port     = http,https
filter   = nginx-wplogin
logpath  = ${log_pattern}
maxretry = ${maxretry}
findtime = ${findtime}
bantime  = ${bantime}
EOF

    if fail2ban-server -t 2>/dev/null; then
        fail2ban-client reload &>/dev/null || systemctl restart fail2ban 2>/dev/null
        printf "${GREEN}✔ WordPress 爆破防护已启用（wp-login.php / xmlrpc.php，%s 次/%s 秒 → 封 %s 秒）${NC}\n" "$maxretry" "$findtime" "$bantime"
    else
        printf "${RED}✘ 配置文件语法错误，已自动回滚。${NC}\n"
        cp "${jail_local}.bak" "$jail_local"
    fi

    read -p "按回车键继续..." dummy
}

# ---------- IP 黑名单管理 ----------
manage_ip_blacklist() {
    # 优化：进入模块自动检测安装 ipset 核心依赖
    if ! command -v ipset &>/dev/null; then
        printf "${YELLOW}未检测到 ipset 环境，正在尝试自动配置...${NC}\n"
        if [ "$OS_FAMILY" = "debian" ]; then
            apt-get update -qq && apt-get install -y ipset
        else
            yum install -y ipset
        fi
    fi

    while true; do
        clear
        printf "${BLUE}===== IP 黑名单 (ipset) =====${NC}\n"
        echo "1. 查看黑名单列表"
        echo "2. 手动添加 IP 到黑名单"
        echo "3. 从黑名单移除 IP"
        echo "4. 彻底清空黑名单"
        echo "5. 持久化保存黑名单 (防止重启丢失)"
        echo "0. 返回"
        read -p "选择: " ip_choice
        case $ip_choice in
            1) 
                ipset list blacklist 2>/dev/null || echo "黑名单集合当前未创建或为空"
                read -p "按回车键继续..." dummy 
                ;;
            2)
                read -p "输入要封禁的 IP: " ban_ip
                [ -z "$ban_ip" ] && continue
                ipset create blacklist hash:ip timeout 0 -exist
                ipset add blacklist "$ban_ip" -exist
                iptables -C INPUT -m set --match-set blacklist src -j DROP 2>/dev/null || \
                iptables -I INPUT -m set --match-set blacklist src -j DROP
                printf "${GREEN}已成功将 %s 拉入黑名单并彻底丢弃其报文。${NC}\n" "$ban_ip"
                read -p "按回车键继续..." dummy 
                ;;
            3)
                read -p "输入要解除的 IP: " unban_ip
                [ -z "$unban_ip" ] && continue
                ipset del blacklist "$unban_ip" 2>/dev/null
                printf "${GREEN}IP %s 已从黑名单中移除${NC}\n" "$unban_ip"
                read -p "按回车键继续..." dummy 
                ;;
            4)
                ipset flush blacklist 2>/dev/null
                printf "${GREEN}黑名单池已全部清空${NC}\n"
                read -p "按回车键继续..." dummy 
                ;;
            5)
                # 优化：新增黑名单规则落盘固化
                if [ "$OS_FAMILY" = "debian" ]; then
                    mkdir -p /etc/iptables
                    ipset save > /etc/iptables/ipset.rules
                    printf "${GREEN}规则已导出至 /etc/iptables/ipset.rules${NC}\n"
                else
                    ipset save > /etc/sysconfig/ipset
                    printf "${GREEN}规则已导出至 /etc/sysconfig/ipset${NC}\n"
                fi
                printf "${YELLOW}提示：确保您的开机脚本中包含 [ipset restore] 即可实现永久加载。${NC}\n"
                read -p "按回车键继续..." dummy 
                ;;
            0) break ;;
            *) printf "${RED}无效选项${NC}\n"; sleep 1 ;;
        esac
    done
}

# ---------- GeoIP 自动化地域封锁 (基于 ipset) ----------
manage_geoip() {
    # 自动安装必要依赖
    if ! command -v ipset &>/dev/null || ! command -v wget &>/dev/null; then
        printf "${YELLOW}正在安装地域封锁所需依赖 (ipset, wget)...${NC}\n"
        if [ "$OS_FAMILY" = "debian" ]; then
            apt-get update -qq && apt-get install -y ipset wget
        else
            yum install -y ipset wget
        fi
    fi

    while true; do
        clear
        printf "${BLUE}===== GeoIP 地域封锁 (一键版) =====${NC}\n"
        echo "提示：基于 ipdeny.com 的 IP 库和系统 ipset 实现，无需编译内核"
        echo "--------------------------------------------------------"
        echo "1. 封锁指定国家/地区"
        echo "2. 解封指定国家/地区"
        echo "3. 查看当前已封锁的地区"
        echo "4. 清空所有地域封锁"
        echo "0. 返回上级菜单"
        read -p "选择: " geo_choice
        case $geo_choice in
            1)
                read -p "请输入要封锁的国家代码 (2位字母，如 cn=中国, ru=俄罗斯, us=美国): " cc
                cc=$(echo "$cc" | tr '[:upper:]' '[:lower:]') # 转小写
                if [[ ! "$cc" =~ ^[a-z]{2}$ ]]; then
                    printf "${RED}格式错误，请输入正确的2位字母代码！${NC}\n"
                    sleep 2; continue
                fi
                
                printf "${YELLOW}正在下载 [%s] 的 IP 数据库...${NC}\n" "$cc"
                local tmp_file="/tmp/geoip_${cc}.zone"
                wget -qO "$tmp_file" "http://www.ipdeny.com/ipblocks/data/countries/${cc}.zone"
                
                if [ ! -s "$tmp_file" ]; then
                    printf "${RED}下载失败，可能是网络问题或不支持的代码: %s${NC}\n" "$cc"
                    sleep 2; continue
                fi
                
                printf "${YELLOW}正在载入防火墙 (批量导入优化中，约需数秒)...${NC}\n"
                ipset create geoip_$cc hash:net -exist
                ipset flush geoip_$cc
                
                # 使用 ipset restore 批量导入（极速模式，避免循环卡死）
                local tmp_restore="/tmp/ipset_${cc}_restore.txt"
                > "$tmp_restore"
                while read -r net; do
                    echo "add geoip_$cc $net -exist" >> "$tmp_restore"
                done < "$tmp_file"
                ipset restore < "$tmp_restore"
                
                # 下发丢弃规则到 iptables
                iptables -C INPUT -m set --match-set geoip_$cc src -j DROP 2>/dev/null || \
                iptables -I INPUT -m set --match-set geoip_$cc src -j DROP
                
                # 清理临时文件
                rm -f "$tmp_file" "$tmp_restore"
                printf "${GREEN}✔ 成功！来自 [%s] 的所有访问已被防火墙拦截。${NC}\n" "$cc"
                read -p "按回车键继续..." dummy
                ;;
            2)
                read -p "请输入要解封的国家代码 (如 cn): " cc
                cc=$(echo "$cc" | tr '[:upper:]' '[:lower:]')
                # 先删 iptables 规则，再销毁 ipset 集合
                iptables -D INPUT -m set --match-set geoip_$cc src -j DROP 2>/dev/null
                ipset destroy geoip_$cc 2>/dev/null
                printf "${GREEN}已解除对 [%s] 地区的封锁${NC}\n" "$cc"
                read -p "按回车键继续..." dummy
                ;;
            3)
                printf "${GREEN}当前已被封锁的地区代码：${NC}\n"
                local blocked=$(ipset list -n 2>/dev/null | grep '^geoip_' | sed 's/geoip_//')
                if [ -z "$blocked" ]; then
                    echo "当前未配置任何地域封锁。"
                else
                    echo "$blocked"
                fi
                read -p "按回车键继续..." dummy
                ;;
            4)
                printf "${YELLOW}正在清空所有 GeoIP 封锁规则...${NC}\n"
                for setname in $(ipset list -n 2>/dev/null | grep '^geoip_'); do
                    iptables -D INPUT -m set --match-set "$setname" src -j DROP 2>/dev/null
                    ipset destroy "$setname" 2>/dev/null
                done
                printf "${GREEN}所有地域封锁已全部清空${NC}\n"
                read -p "按回车键继续..." dummy
                ;;
            0) break ;;
            *) printf "${RED}无效选项${NC}\n"; sleep 1 ;;
        esac
    done
}

fail2ban_menu() {
    while true; do
        clear
        printf "${BLUE}===== Fail2Ban 管理 =====${NC}\n"
        printf "当前状态："; detect_fail2ban
        echo "1. 安装 Fail2Ban"
        echo "2. 查看当前拦截记录"
        echo "3. 手动一键解封指定 IP"
        echo "4. 基础参数配置"
        echo "5. 卸载 Fail2Ban"
        echo "6. 防扫/黑名单/地域限制"
        echo "7. 设置/确认开机自启"
        echo "8. 白名单管理"
        echo "0. 返回上级菜单"
        read -p "请选择操作: " fb_choice
        case $fb_choice in
            1) install_fail2ban ;;
            2) show_ban_records ;;
            3) unban_ip_fail2ban ;;
            4) config_fail2ban ;;
            5) uninstall_fail2ban ;;
            6) advanced_defense_menu ;;
            7) enable_fail2ban_autostart ;;
            8) manage_fail2ban_whitelist ;;
            0) break ;;
            *) printf "${RED}无效选项${NC}\n" ;;
        esac
        echo ""; read -p "按回车键继续..." dummy
    done
}

# 组合菜单
firewall_menu() {
    while true; do
        clear
        printf "${BLUE}===== 防火墙 / Fail2Ban 管理 =====${NC}\n"
        printf "当前防火墙状态："; detect_firewall
        printf "当前 Fail2Ban 状态："; detect_fail2ban
        echo "--------------------------------------"
        echo "1. 安装防火墙"
        echo "2. 开启防火墙"
        echo "3. 开放全部端口"
        echo "4. 关闭全部端口"
        echo "5. 开放指定端口"
        echo "6. 关闭指定端口"
        echo "7. 查看防火墙详细状态"
        echo "--------------------------------------"
        echo "8. Fail2Ban 管理"
        echo "0. 返回主菜单"
        read -p "请选择操作: " fw_choice
        case $fw_choice in
            1) install_firewall ;;
            2) enable_firewall ;;
            3) open_all_ports ;;
            4) close_all_ports ;;
            5) open_ports ;;
            6) close_ports ;;
            7) show_firewall_status ;;
            8) fail2ban_menu ;;
            0) break ;;
            *) printf "${RED}无效选项${NC}\n" ;;
        esac
    done
}

firewall_menu
