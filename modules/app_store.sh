#!/bin/bash
# 应用商店 - 远程加载

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vn_modules/common.sh 2>/dev/null || {
        echo "无法加载公共函数库"
        exit 1
    }
fi

detect_os
check_dependencies

# 应用注册表 (全局)
declare -A APPS=(
    ["docker应用"]="https://raw.githubusercontent.com/lje02/vp/main/remote_apps/docker.sh"
    ["tg-sb管理"]="https://raw.githubusercontent.com/lje02/vp/main/remote_apps/singbox-bot.sh"
    ["tg 私聊"]="https://raw.githubusercontent.com/lje02/vp/main/remote_apps/tg-call.sh"
    ["工具环境"]="https://raw.githubusercontent.com/lje02/vp/main/remote_apps/huanjing.sh"
    ["远程文件传输"]="https://raw.githubusercontent.com/lje02/vp/main/remote_apps/vps-rsync.sh"
    ["证书/代理/网站"]="https://raw.githubusercontent.com/lje02/vp/main/remote_apps/nginx-manager.sh"
)

run_remote_app() {
    local name="$1" url="$2" tmp="/tmp/vn_app_$$.sh"
    printf "${BLUE}▶ 正在加载: %s ...${NC}\n" "$name"
    if curl -fsSL "$url" -o "$tmp" 2>/dev/null; then
        if [ -s "$tmp" ]; then
            chmod +x "$tmp"
            bash "$tmp"
            rm -f "$tmp"
            printf "${GREEN}✔ %s 执行完毕。${NC}\n" "$name"
        else
            printf "${RED}✘ 下载的脚本为空。${NC}\n"
            rm -f "$tmp"
        fi
    else
        printf "${RED}✘ 无法连接到远程仓库，请检查网络。${NC}\n"
    fi
    read -p "按回车键继续..." dummy
}

# 将所有菜单逻辑移入函数，即可使用 local 变量
app_store_menu() {
    while true; do
        clear
        printf "${BLUE}===== 应用商店 (远程加载) =====${NC}\n"
        printf "共 %d 个可用应用\n" "${#APPS[@]}"
        echo "--------------------------------------"
        local i=1
        for app_name in "${!APPS[@]}"; do
            printf "%d. %s\n" "$i" "$app_name"
            ((i++))
        done
        echo "0. 返回主菜单"
        read -p "选择: " choice

        if [[ "$choice" == "0" ]]; then
            break
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#APPS[@]}" ]; then
            local selected_name="" selected_url=""
            local j=1
            for n in "${!APPS[@]}"; do
                if [ "$j" -eq "$choice" ]; then
                    selected_name="$n"
                    selected_url="${APPS[$n]}"
                    break
                fi
                ((j++))
            done
            run_remote_app "$selected_name" "$selected_url"
        else
            printf "${RED}无效选项${NC}\n"
            sleep 1
        fi
    done
}

app_store_menu
