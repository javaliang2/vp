#!/bin/bash

# ============================================
# Sing-box Telegram Bot Pro v2
# ============================================

BOT_DIR="/etc/sing-box"
BOT_SCRIPT="/etc/sing-box/tg_worker.sh"
BOT_CONF="$BOT_DIR/tg_bot.conf"
BOT_SERVICE="/etc/systemd/system/tg-bot.service"
SING_BOX_CONFIG="/etc/sing-box/config.json"
UPDATE_URL="https://raw.githubusercontent.com/lje02/vp/main/modules/tgbot.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# ============================================
# 工具函数
# ============================================

view_logs() {
    echo -e "${YELLOW}正在查看机器人实时日志 (Ctrl+C 退出)...${PLAIN}"
    journalctl -u tg-bot -f -n 50
}

inject_api_config() {
    local port=$1
    if [[ -f "$SING_BOX_CONFIG" ]]; then
        cp "$SING_BOX_CONFIG" "${SING_BOX_CONFIG}.bak"
        jq --arg port "127.0.0.1:$port" \
            '.experimental.clash_api = {"external_controller": $port}' \
            "$SING_BOX_CONFIG" > "${SING_BOX_CONFIG}.tmp"
        if sing-box check -c "${SING_BOX_CONFIG}.tmp" &>/dev/null; then
            mv "${SING_BOX_CONFIG}.tmp" "$SING_BOX_CONFIG"
            systemctl restart sing-box
            echo -e "${GREEN}✔ Sing-box API 已开启 (端口: $port)${PLAIN}"
        else
            echo -e "${RED}✘ JSON 校验失败，已还原${PLAIN}"
            rm -f "${SING_BOX_CONFIG}.tmp"
        fi
    fi
}

# ============================================
# 安装
# ============================================

install_bot() {
    echo -e "${YELLOW}--- Telegram 机器人安装 v2 ---${PLAIN}"

    apt update && apt install -y jq curl bc procps iproute2 net-tools 2>/dev/null
    mkdir -p "$BOT_DIR"

    read -p "请输入 Sing-box API 端口 (默认 9090): " API_PORT
    API_PORT=${API_PORT:-9090}
    inject_api_config "$API_PORT"

    read -p "请输入 Bot Token: " TG_TOKEN
    read -p "请输入管理员 Chat ID (多个用逗号分隔): " TG_CHATID

    if [[ -z "$TG_TOKEN" || -z "$TG_CHATID" ]]; then
        echo -e "${RED}✘ Token 或 Chat ID 不能为空${PLAIN}"
        return
    fi

    read -p "定时状态推送间隔(分钟，0=关闭，默认60): " PUSH_INTERVAL
    PUSH_INTERVAL=${PUSH_INTERVAL:-60}

    cat > "$BOT_CONF" <<EOF
TOKEN="$TG_TOKEN"
ADMIN_IDS="$TG_CHATID"
API_PORT="$API_PORT"
PUSH_INTERVAL="$PUSH_INTERVAL"
EOF
    chmod 600 "$BOT_CONF"

    # ============================================================
    # 生成后台工作脚本
    # ============================================================
    cat > "$BOT_SCRIPT" <<'WORKER_EOF'
#!/bin/bash

source /etc/sing-box/tg_bot.conf

LINK_DIR="/etc/sing-box/links"
SB_CONFIG="/etc/sing-box/config.json"
OFFSET_FILE="/etc/sing-box/tg_bot_offset"
LAST_ALERT_TIME=0
LAST_PUSH_TIME=0

SERVER_IP=$(curl -s --max-time 5 http://ip-api.com/line?fields=query 2>/dev/null || echo "未知")
CPU_CORES=$(nproc)

# ──────────────────────────────────────────
# 权限校验：支持多管理员（逗号分隔）
# ──────────────────────────────────────────
is_admin() {
    local uid=$1
    echo "$ADMIN_IDS" | tr ',' '\n' | grep -qx "$uid"
}

# 取第一个管理员 ID（用于主动推送）
first_admin() {
    echo "$ADMIN_IDS" | cut -d',' -f1
}

# ──────────────────────────────────────────
# Telegram API 封装
# ──────────────────────────────────────────

# 发送普通消息（支持 Markdown）
send_msg() {
    local chat_id=$1
    local text=$2
    local extra=${3:-""}
    curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{
            \"chat_id\": \"$chat_id\",
            \"text\": $(echo "$text" | jq -Rs .),
            \"parse_mode\": \"Markdown\",
            \"disable_web_page_preview\": true
            $( [[ -n "$extra" ]] && echo ", $extra" )
        }" > /dev/null 2>&1
}

# 发送带 inline keyboard 的消息
send_keyboard() {
    local chat_id=$1
    local text=$2
    local keyboard=$3
    curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{
            \"chat_id\": \"$chat_id\",
            \"text\": $(echo "$text" | jq -Rs .),
            \"parse_mode\": \"Markdown\",
            \"disable_web_page_preview\": true,
            \"reply_markup\": $keyboard
        }" > /dev/null 2>&1
}

# 编辑已有消息（刷新用）
edit_msg() {
    local chat_id=$1
    local msg_id=$2
    local text=$3
    local keyboard=${4:-""}
    local body="{
        \"chat_id\": \"$chat_id\",
        \"message_id\": $msg_id,
        \"text\": $(echo "$text" | jq -Rs .),
        \"parse_mode\": \"Markdown\",
        \"disable_web_page_preview\": true
        $( [[ -n "$keyboard" ]] && echo ", \"reply_markup\": $keyboard" )
    }"
    curl -s -X POST "https://api.telegram.org/bot${TOKEN}/editMessageText" \
        -H "Content-Type: application/json" \
        -d "$body" > /dev/null 2>&1
}

# 回复 callback query（消除按钮 loading 状态）
answer_cb() {
    local cb_id=$1
    local text=${2:-""}
    curl -s -X POST "https://api.telegram.org/bot${TOKEN}/answerCallbackQuery" \
        -H "Content-Type: application/json" \
        -d "{\"callback_query_id\":\"$cb_id\",\"text\":$(echo "$text" | jq -Rs .)}" \
        > /dev/null 2>&1
}

# 注册底部菜单命令（Bot Menu Button）
register_commands() {
    curl -s -X POST "https://api.telegram.org/bot${TOKEN}/setMyCommands" \
        -H "Content-Type: application/json" \
        -d '{
            "commands": [
                {"command":"start",   "description":"🏠 主菜单"},
                {"command":"status",  "description":"📊 完整状态报告"},
                {"command":"singbox", "description":"⚙️ 服务管理"},
                {"command":"nodes",   "description":"🔗 节点列表"},
                {"command":"links",   "description":"📂 分享链接"},
                {"command":"system",  "description":"🖥 系统监控"},
                {"command":"myid",    "description":"👤 我的信息"}
            ]
        }' > /dev/null 2>&1
}

# ──────────────────────────────────────────
# CPU 使用率获取（修复版）
# ──────────────────────────────────────────
get_cpu_usage() {
    local cpu1 cpu2 idle1 idle2 total1 total2 diff_total diff_idle
    
    # 从 /proc/stat 获取第一次采样
    read cpu1 user1 nice1 sys1 idle1 iowait1 rest1 < <(awk '/^cpu[^0-9]/ {print $1,$2,$3,$4,$5,$6,$7}' /proc/stat)
    
    sleep 0.1
    
    # 获取第二次采样
    read cpu2 user2 nice2 sys2 idle2 iowait2 rest2 < <(awk '/^cpu[^0-9]/ {print $1,$2,$3,$4,$5,$6,$7}' /proc/stat)
    
    # 计算总的 tick 变化（user + nice + sys + idle + iowait + irq + softirq）
    total1=$(( user1 + nice1 + sys1 + idle1 + iowait1 + rest1 ))
    total2=$(( user2 + nice2 + sys2 + idle2 + iowait2 + rest2 ))
    diff_total=$(( total2 - total1 ))
    
    # 计算空闲时间的变化
    diff_idle=$(( idle2 - idle1 ))
    
    if [[ $diff_total -gt 0 ]]; then
        # CPU使用率 = (1 - idle_change / total_change) * 100
        awk "BEGIN{printf \"%.1f\", (1 - $diff_idle/$diff_total) * 100}"
    else
        echo "N/A"
    fi
}

# ──────────────────────────────────────────
# 数据采集函数
# ──────────────────────────────────────────

get_sb_status() {
    local pid
    pid=$(pgrep -f "sing-box run" | head -n1)
    local active
    active=$(systemctl is-active sing-box 2>/dev/null)

    local status_icon runtime cpu mem conns ports

    if [[ "$active" == "active" && -n "$pid" ]]; then
        status_icon="✅ 运行中"
        local secs
        secs=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
        runtime=$(printf "%02d:%02d:%02d" \
            $((secs/3600)) $(((secs%3600)/60)) $((secs%60)) 2>/dev/null || echo "N/A")
        cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0")
        mem=$(ps -p "$pid" -o rss= 2>/dev/null | \
            awk '{printf "%.1f MB", $1/1024}' || echo "0 MB")
    else
        status_icon="❌ 已停止"
        runtime="N/A"; cpu="0"; mem="0 MB"
    fi

    # 活跃连接：优先 Clash API，降级到 ss
    conns=$(curl -s --max-time 2 "http://127.0.0.1:${API_PORT}/connections" 2>/dev/null | \
        jq '.connections | length' 2>/dev/null)
    [[ -z "$conns" || "$conns" == "null" ]] && \
        conns=$(ss -tnp 2>/dev/null | grep -c sing-box || echo "0")

    ports=$(ss -tlnp 2>/dev/null | grep sing-box | \
        awk '{print $4}' | awk -F: '{print $NF}' | sort -un | tr '\n' ' ')
    [[ -z "$ports" ]] && ports="无"

    cat <<EOF
⚙️ *Sing-box 服务状态*
━━━━━━━━━━━━━━━━━━━━━━
🟢 状态: $status_icon
🔹 PID: ${pid:-N/A}
🔹 运行: $runtime
🔹 CPU: ${cpu}%
🔹 内存: $mem
🔹 连接: $conns 条
🔹 端口: $ports
━━━━━━━━━━━━━━━━━━━━━━
🕒 $(date '+%Y-%m-%d %H:%M:%S')
EOF
}

get_system_stats() {
    local uptime_str
    uptime_str=$(uptime -p 2>/dev/null | sed 's/up //' || echo "N/A")

    local mem_used mem_total mem_pct
    read mem_used mem_total < <(free -m | awk '/^Mem:/{print $3, $2}')
    mem_pct=$(awk "BEGIN{printf \"%.1f\", $mem_used/$mem_total*100}" 2>/dev/null || echo "0")

    local disk_used disk_total disk_pct
    read disk_used disk_total disk_pct < <(df -h / | awk 'NR==2{print $3,$2,$5}')

    local load
    load=$(uptime | awk -F'load average:' '{print $2}' | xargs 2>/dev/null || echo "N/A")

    # 修复：使用新的 get_cpu_usage 函数
    local cpu_pct
    cpu_pct=$(get_cpu_usage)

    local dev rx tx
    dev=$(ip route 2>/dev/null | awk '/default/{print $5; exit}')
    if [[ -n "$dev" ]]; then
        rx=$(awk -v d="$dev" '$1==d":" {printf "%.2f GB", $2/1073741824}' \
            /proc/net/dev 2>/dev/null || echo "N/A")
        tx=$(awk -v d="$dev" '$1==d":" {printf "%.2f GB", $10/1073741824}' \
            /proc/net/dev 2>/dev/null || echo "N/A")
    else
        rx="N/A"; tx="N/A"
    fi

    cat <<EOF
🖥 *系统监控*
━━━━━━━━━━━━━━━━━━━━━━
🔹 CPU: ${cpu_pct}%
🔹 内存: ${mem_used}/${mem_total} MB (${mem_pct}%)
🔹 磁盘: ${disk_used}/${disk_total} (${disk_pct})
🔹 负载: $load
🔹 流量: ⬇️ $rx | ⬆️ $tx
🔹 运行: $uptime_str
━━━━━━━━━━━━━━━━━━━━━━
🕒 $(date '+%Y-%m-%d %H:%M:%S')
EOF
}

get_full_report() {
    printf "🌐 *服务器*: \`%s\`\n\n%s\n\n%s" \
        "$SERVER_IP" "$(get_sb_status)" "$(get_system_stats)"
}

# 从 config.json 读取入站节点列表
get_nodes_text() {
    if [[ ! -f "$SB_CONFIG" ]]; then
        echo "❌ 配置文件不存在"
        return
    fi
    local count
    count=$(jq '.inbounds | length' "$SB_CONFIG" 2>/dev/null || echo 0)
    if [[ "$count" -eq 0 ]]; then
        echo "暂无入站节点"
        return
    fi

    local text="🔗 *当前入站节点 ($count 个)*\n━━━━━━━━━━━━━━━━━━━━━━\n"
    local i=0
    while [[ $i -lt $count ]]; do
        local tag type port
        tag=$(jq -r ".inbounds[$i].tag"          "$SB_CONFIG" 2>/dev/null)
        type=$(jq -r ".inbounds[$i].type"         "$SB_CONFIG" 2>/dev/null)
        port=$(jq -r ".inbounds[$i].listen_port"  "$SB_CONFIG" 2>/dev/null)
        text+="$(( i+1 )). \`$tag\`  [$type : $port]\n"
        (( i++ ))
    done
    text+="━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "$text"
}

# 读取分享链接文件列表
get_links_menu_kb() {
    [[ ! -d "$LINK_DIR" ]] && mkdir -p "$LINK_DIR"
    local files
    mapfile -t files < <(ls "$LINK_DIR" 2>/dev/null)
    if [[ ${#files[@]} -eq 0 ]]; then
        echo '{"inline_keyboard":[[{"text":"📂 暂无链接文件","callback_data":"noop"}]]}'
        return
    fi
    local rows="["
    for f in "${files[@]}"; do
        rows+="[{\"text\":\"🔗 $f\",\"callback_data\":\"getlink_$f\"}],"
    done
    rows="${rows%,}]"
    echo "{\"inline_keyboard\":$rows}"
}

# ──────────────────────────────────────────
# Inline Keyboard 定义
# ──────────────────────────────────────────

KB_MAIN='{
    "inline_keyboard":[
        [{"text":"📊 完整报告","callback_data":"full_report"},
         {"text":"⚙️ 服务管理","callback_data":"menu_singbox"}],
        [{"text":"🔗 节点列表","callback_data":"menu_nodes"},
         {"text":"�� 分享链接","callback_data":"menu_links"}],
        [{"text":"🖥 系统监控","callback_data":"menu_system"},
         {"text":"🔄 刷新","callback_data":"full_report"}]
    ]
}'

KB_SINGBOX='{
    "inline_keyboard":[
        [{"text":"▶️ 启动","callback_data":"sb_start"},
         {"text":"🛑 停止","callback_data":"sb_stop"},
         {"text":"🔄 重启","callback_data":"sb_restart"}],
        [{"text":"📋 查看日志(50行)","callback_data":"sb_logs"}],
        [{"text":"⬅️ 返回主菜单","callback_data":"menu_main"}]
    ]
}'

KB_BACK_MAIN='{"inline_keyboard":[[{"text":"⬅️ 返回主菜单","callback_data":"menu_main"}]]}'
KB_REFRESH_MAIN='{"inline_keyboard":[[{"text":"🔄 刷新","callback_data":"full_report"},{"text":"🏠 主菜单","callback_data":"menu_main"}]]}'

# ──────────────────────────────────────────
# 告警检测
# ───────────────────────────���──────────────

check_alerts() {
    local now
    now=$(date +%s)
    [[ $(( now - LAST_ALERT_TIME )) -lt 120 ]] && return

    # 服务宕机
    if ! systemctl is-active --quiet sing-box; then
        send_msg "$(first_admin)" "🚨 *服务宕机告警*
━━━━━━━━━━━━━━━━━━━━━━
📍 服务器: \`$SERVER_IP\`
❌ sing-box 已停止！
🕒 $(date '+%H:%M:%S')"
        LAST_ALERT_TIME=$now
        return
    fi

    # 高负载 / 内存告警
    local load1
    load1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)
    local load_int
    load_int=$(awk "BEGIN{printf \"%d\", $load1 * 100}")
    local limit_int=$(( CPU_CORES * 100 ))

    local mem_avail mem_total mem_pct
    read mem_avail mem_total < <(free | awk '/^Mem:/{print $7, $2}')
    mem_pct=$(( (mem_total - mem_avail) * 100 / mem_total ))

    if (( load_int > limit_int )) || (( mem_pct > 90 )); then
        send_msg "$(first_admin)" "⚠️ *资源告警*
━━━━━━━━━━━━━━━━━━━━━━
📍 服务器: \`$SERVER_IP\`
🔹 负载: $load1 (核心: $CPU_CORES)
🔹 内存: ${mem_pct}%
🕒 $(date '+%H:%M:%S')"
        LAST_ALERT_TIME=$now
    fi
}

# 定时推送
check_scheduled_push() {
    [[ "${PUSH_INTERVAL:-0}" -eq 0 ]] && return
    local now
    now=$(date +%s)
    local interval=$(( PUSH_INTERVAL * 60 ))
    if (( now - LAST_PUSH_TIME >= interval )); then
        send_keyboard "$(first_admin)" "$(get_full_report)" "$KB_REFRESH_MAIN"
        LAST_PUSH_TIME=$now
    fi
}

# ──────────────────────────────────────────
# 指令 & 回调处理
# ──────────────────────────────────────────

handle_command() {
    local chat_id=$1 cmd=$2

    case "$cmd" in
        /start|/help)
            local welcome="🤖 *Sing-box 管理机器人*
━━━━━━━━━━━━━━━━━━━━━━
📍 服务器: \`$SERVER_IP\`
请使用下方按钮或底部菜单操作
━━━━━━━━━━━━━━━━━━━━━━"
            send_keyboard "$chat_id" "$welcome" "$KB_MAIN"
            ;;
        /status)
            send_keyboard "$chat_id" "$(get_full_report)" "$KB_REFRESH_MAIN"
            ;;
        /singbox)
            send_keyboard "$chat_id" "$(get_sb_status)" "$KB_SINGBOX"
            ;;
        /nodes)
            send_keyboard "$chat_id" "$(get_nodes_text)" "$KB_BACK_MAIN"
            ;;
        /links)
            local kb
            kb=$(get_links_menu_kb)
            send_keyboard "$chat_id" "📂 *节点分享链接库*
━━━━━━━━━━━━━━━━━━━━━━
路径: \`$LINK_DIR\`
请选择文件查看链接：" "$kb"
            ;;
        /system)
            send_keyboard "$chat_id" "$(get_system_stats)" "$KB_BACK_MAIN"
            ;;
        /myid)
            send_msg "$chat_id" "👤 *你的信息*
━━━━━━━━━━━━━━━━━━━━━━
🔹 Chat ID: \`$chat_id\`
🔹 服务器: \`$SERVER_IP\`
🔹 权限: 管理员"
            ;;
    esac
}

handle_callback() {
    local chat_id=$1 msg_id=$2 cb_id=$3 data=$4
    local toast="" new_text="" new_kb=""

    case "$data" in
        # ── 菜单导航 ──
        menu_main)
            new_text="🤖 *Sing-box 管理机器人*
━━━━━━━━━━━━━━━━━━━━━━
📍 服务器: \`$SERVER_IP\`
请选择操作："
            new_kb="$KB_MAIN"
            toast="主菜单"
            ;;
        menu_singbox)
            new_text="$(get_sb_status)"
            new_kb="$KB_SINGBOX"
            toast="服务管理"
            ;;
        menu_nodes)
            new_text="$(get_nodes_text)"
            new_kb="$KB_BACK_MAIN"
            toast="节点列表"
            ;;
        menu_system)
            new_text="$(get_system_stats)"
            new_kb="$KB_BACK_MAIN"
            toast="系统监控"
            ;;
        menu_links)
            local kb
            kb=$(get_links_menu_kb)
            new_text="📂 *节点分享链接库*
━━━━━━━━━━━━━━━━━━━━━━
路径: \`$LINK_DIR\`
请选择文件："
            new_kb="$kb"
            toast="链接库"
            ;;
        full_report)
            new_text="$(get_full_report)"
            new_kb="$KB_REFRESH_MAIN"
            toast="已刷新"
            ;;

        # ── 服务操作 ──
        sb_start)
            systemctl start sing-box
            sleep 1
            new_text="$(get_sb_status)"
            new_kb="$KB_SINGBOX"
            toast="▶️ 已启动"
            ;;
        sb_stop)
            systemctl stop sing-box
            sleep 1
            new_text="$(get_sb_status)"
            new_kb="$KB_SINGBOX"
            toast="🛑 已停止"
            ;;
        sb_restart)
            systemctl restart sing-box
            sleep 2
            new_text="$(get_sb_status)"
            new_kb="$KB_SINGBOX"
            toast="🔄 已重启"
            ;;
        sb_logs)
            # 日志不走 editMessage（太长），单独发一条
            answer_cb "$cb_id" "📋 获取日志中..."
            local log_text
            log_text=$(journalctl -u sing-box -n 50 --no-pager \
                --output=short-monotonic 2>/dev/null | tail -50)
            send_keyboard "$chat_id" "\`\`\`
${log_text:0:3500}
\`\`\`" "$KB_SINGBOX"
            return
            ;;

        # ── 分享链接 ──
        getlink_*)
            local fname="${data#getlink_}"
            local fpath="$LINK_DIR/$fname"
            answer_cb "$cb_id" "读取中..."
            if [[ -f "$fpath" ]]; then
                local link_content
                link_content=$(cat "$fpath" | tr -d '\r')
                local back_kb='{"inline_keyboard":[[{"text":"⬅️ 返回链接库","callback_data":"menu_links"},{"text":"🏠 主菜单","callback_data":"menu_main"}]]}'
                send_keyboard "$chat_id" "📋 *$fname*
━━━━━━━━━━━━━━━━━━━━━━
\`$link_content\`" "$back_kb"
            else
                send_msg "$chat_id" "❌ 文件不存在: \`$fname\`"
            fi
            return
            ;;

        noop)
            answer_cb "$cb_id" ""
            return
            ;;
    esac

    answer_cb "$cb_id" "$toast"
    [[ -n "$new_text" ]] && edit_msg "$chat_id" "$msg_id" "$new_text" "$new_kb"
}

# ──────────────────────────────────────────
# 主循环
# ──────────────────────────────────────────

# 启动时注册底部菜单命令
register_commands

# 启动通知
send_keyboard "$(first_admin)" "✅ *机器人已启动*
━━━━━━━━━━━━━━━━━━━━━━
📍 服务器: \`$SERVER_IP\`
🕒 $(date '+%Y-%m-%d %H:%M:%S')" "$KB_MAIN"

OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)

while true; do
    check_alerts
    check_scheduled_push

    # 长轮询拉取更新（超时 20s）
    RESPONSE=$(curl -s --max-time 25 \
        "https://api.telegram.org/bot${TOKEN}/getUpdates?offset=${OFFSET}&timeout=20" \
        2>/dev/null)

    # jq 解析失败时跳过（网络抖动等）
    echo "$RESPONSE" | jq -e '.ok == true' > /dev/null 2>&1 || { sleep 2; continue; }

    while IFS= read -r update; do
        [[ -z "$update" ]] && continue

        UPDATE_ID=$(echo "$update" | jq -r '.update_id')
        OFFSET=$(( UPDATE_ID + 1 ))
        echo "$OFFSET" > "$OFFSET_FILE"

        local_chat=$(echo "$update" | jq -r \
            '.message.chat.id // .callback_query.message.chat.id // empty')
        local_user=$(echo "$update" | jq -r \
            '.message.from.id // .callback_query.from.id // empty')

        # 权限校验
        if ! is_admin "$local_user"; then
            send_msg "$local_chat" "⛔ 未授权访问"
            continue
        fi

        MSG_TEXT=$(echo "$update" | jq -r '.message.text // empty')
        CB_DATA=$(echo "$update"  | jq -r '.callback_query.data // empty')
        CB_ID=$(echo "$update"    | jq -r '.callback_query.id // empty')
        MSG_ID=$(echo "$update"   | jq -r '.callback_query.message.message_id // empty')

        if [[ -n "$MSG_TEXT" ]]; then
            # 只取第一个词作为命令（忽略 /cmd@botname 格式后缀）
            local cmd
            cmd=$(echo "$MSG_TEXT" | awk '{print $1}' | cut -d'@' -f1)
            handle_command "$local_chat" "$cmd"
        fi

        if [[ -n "$CB_DATA" ]]; then
            handle_callback "$local_chat" "$MSG_ID" "$CB_ID" "$CB_DATA"
        fi

    done < <(echo "$RESPONSE" | jq -c '.result[]' 2>/dev/null)

done
WORKER_EOF

    chmod +x "$BOT_SCRIPT"

    cat > "$BOT_SERVICE" <<EOF
[Unit]
Description=Sing-box Telegram Bot v2
After=network.target sing-box.service

[Service]
ExecStart=/bin/bash $BOT_SCRIPT
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now tg-bot
    echo -e "${GREEN}✔ 机器人 v2 已启动！发送 /start 开始使用。${PLAIN}"
}

# ============================================
# 其他管理函数
# ============================================

uninstall_bot() {
    echo -e "${YELLOW}正在卸载机器人...${PLAIN}"
    systemctl stop tg-bot 2>/dev/null
    systemctl disable tg-bot 2>/dev/null
    rm -f /etc/systemd/system/tg-bot.service
    systemctl daemon-reload
    systemctl reset-failed
    rm -f "$BOT_SCRIPT" "$BOT_CONF" "$OFFSET_FILE"
    echo -e "${GREEN}✔ 卸载完成（links/ 和 config.json 已保留）${PLAIN}"
}

update_bot() {
    echo -e "${YELLOW}正在更新脚本...${PLAIN}"
    curl -sL "$UPDATE_URL" -o "$0" && chmod +x "$0"
    echo -e "${GREEN}✔ 已更新，请重新运行并选择安装以更新后台服务${PLAIN}"
    exit 0
}

show_menu() {
    clear
    echo -e "${CYAN}================================${PLAIN}"
    echo -e "${GREEN}   Sing-box Bot 管理面板 v2    ${PLAIN}"
    echo -e "${CYAN}================================${PLAIN}"
    echo -e "1. 安装/重装 机器人"
    echo -e "2. ${YELLOW}更新脚本${PLAIN}"
    echo -e "3. ${RED}查看运行日志${PLAIN}"
    echo -e "4. 修改 API 监听端口"
    echo -e "5. 卸载机器人"
    echo -e "0. 退出"
    echo -e "${CYAN}--------------------------------${PLAIN}"
    read -p "请输入选项 [0-5]: " choice
    case $choice in
        1) install_bot ;;
        2) update_bot ;;
        3) view_logs ;;
        4) read -p "新端口: " p; inject_api_config "$p" ;;
        5) uninstall_bot ;;
        *) exit 0 ;;
    esac
}

show_menu
