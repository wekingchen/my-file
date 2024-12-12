#!/bin/bash

# 检查是否以 root 身份运行
if [ "$EUID" -ne 0 ]; then
    echo "请以 root 用户运行脚本。"
    exit 1
fi

# 动态判断平台架构并获取对应的包名
get_platform_package() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            echo "realm-x86_64-unknown-linux-gnu.tar.gz"
            ;;
        aarch64|armv8)
            echo "realm-aarch64-unknown-linux-gnu.tar.gz"
            ;;
        armv7l|armhf)
            echo "realm-armv7-unknown-linux-gnueabihf.tar.gz"
            ;;
        armv6l)
            echo "realm-arm-unknown-linux-gnueabi.tar.gz"
            ;;
        *)
            echo "不支持的架构：$ARCH"
            return 1
            ;;
    esac
    return 0
}

# 判断服务器IP是否在中国
check_server_location() {
    local ip_info=$(curl -s https://ipinfo.io)
    local country=$(echo "$ip_info" | grep -oP '"country":\s*"\K[^"]+')

    if [ "$country" == "CN" ]; then
        echo "CN"
    else
        echo "OTHER"
    fi
}

# 获取最新版本
get_latest_version() {
    location=$(check_server_location)
    if [ "$location" == "CN" ]; then
        base_url="https://ghp.ci/https://github.com"
    else
        base_url="https://github.com"
    fi

    curl -sL "$base_url/zhboner/realm/releases/latest" | \
    grep -oP 'tag/v\K[0-9.]+' | head -1
}

# 获取已安装版本（仅提取版本号）
get_installed_version() {
    if [ -f "/root/realm/realm" ]; then
        /root/realm/realm --version 2>/dev/null | awk '{print $2}' || echo "未知版本"
    else
        echo "未安装"
    fi
}

# 部署环境的函数
deploy_realm() {
    current_version=$(get_installed_version)
    latest_version=$(get_latest_version)

    if [ "$current_version" != "未安装" ] && [ -n "$latest_version" ] && [ "$current_version" == "$latest_version" ]; then
        echo "当前已是最新版本 $current_version，无需更新。"
        return 0
    fi

    # 确认提示
    if [ "$current_version" == "未安装" ]; then
        echo "即将首次安装 realm"
    else
        echo "即将从 $current_version 更新到 $latest_version"
    fi

    read -p "是否继续？(Y/N): " confirm
    if [[ "$confirm" != "Y" && "$confirm" != "y" ]]; then
        echo "取消安装/更新。"
        return 0
    fi

    echo "开始部署/更新realm..."
    mkdir -p /root/realm
    cd /root/realm || exit

    package_name=$(get_platform_package)
    if [ $? -ne 0 ] || [ -z "$package_name" ]; then
        echo "无法确定下载包，请检查架构支持。"
        return 1
    fi

    location=$(check_server_location)
    if [ "$location" == "CN" ]; then
        base_url="https://ghp.ci/https://github.com"
    else
        base_url="https://github.com"
    fi

    download_url="$base_url/zhboner/realm/releases/latest/download/$package_name"
    echo "下载地址: $download_url"
    wget -O realm.tar.gz "$download_url"
    if [ $? -ne 0 ]; then
        echo "下载realm失败，请检查网络或镜像地址。"
        return 1
    fi

    tar -xvf realm.tar.gz || { echo "解压失败，请检查下载的文件。"; return 1; }
    chmod +x realm

    # 创建服务文件
    echo "[Unit]
Description=realm
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
DynamicUser=true
WorkingDirectory=/root/realm
ExecStart=/root/realm/realm -c /root/realm/config.toml

[Install]
WantedBy=multi-user.target" > /etc/systemd/system/realm.service

    systemctl daemon-reload
    rm -f realm.tar.gz

    if [ "$current_version" == "未安装" ]; then
        echo "首次部署完成。"
    else
        echo "更新完成。旧版本：$current_version，新版本：$latest_version"
    fi
}

# 检查realm服务状态
check_realm_service_status() {
    if systemctl is-active --quiet realm; then
        echo -e "\033[0;32m已启用\033[0m" # 绿色
    else
        echo -e "\033[0;31m未启用\033[0m" # 红色
    fi
}

# 修改转发规则的函数
modify_forward() {
    local config_file="/root/realm/config.toml"
    if [ ! -f "$config_file" ]; then
        echo "配置文件不存在，无法修改。"
        return
    fi

    echo "当前转发规则："
    local rules=($(grep -n '^\[\[endpoints\]\]' "$config_file"))
    if [ ${#rules[@]} -eq 0 ]; then
        echo "没有发现任何转发规则。"
        return
    fi

    for i in "${!rules[@]}"; do
        local start_line=$(echo "${rules[$i]}" | cut -d ':' -f 1)
        local end_line
        if [ $i -lt $((${#rules[@]} - 1)) ]; then
            end_line=$(echo "${rules[$((i + 1))]}" | cut -d ':' -f 1)
            end_line=$((end_line - 1))
        else
            end_line=$(wc -l < "$config_file")
        fi
        local rule=$(sed -n "${start_line},${end_line}p" "$config_file")
        echo "$((i + 1)). $rule"
    done

    echo "请输入要修改的转发规则序号，直接按回车返回主菜单。"
    read -p "选择: " choice
    [[ -z "$choice" ]] && return  # 直接返回主菜单

    if ! [[ $choice =~ ^[0-9]+$ ]] || [ $choice -lt 1 ] || [ $choice -gt ${#rules[@]} ]; then
        echo "无效输入，请输入有效序号。"
        return
    fi

    local selected_rule_start=$(echo "${rules[$((choice - 1))]}" | cut -d ':' -f 1)
    local selected_rule_end
    if [ $choice -lt ${#rules[@]} ]; then
        selected_rule_end=$(echo "${rules[$choice]}" | cut -d ':' -f 1)
        selected_rule_end=$((selected_rule_end - 1))
    else
        selected_rule_end=$(wc -l < "$config_file")
    fi

    echo "请输入新的域名/IP:"
    read -p "新域名/IP: " new_ip
    echo "请输入新的端口:"
    read -p "新端口: " new_port

    sed -i "${selected_rule_start},${selected_rule_end}c [[endpoints]]\nlisten = \"0.0.0.0:$new_port\"\nremote = \"$new_ip:$new_port\"" "$config_file"
    echo "转发规则已修改。"
}

# 删除转发规则的函数
delete_forward() {
    local config_file="/root/realm/config.toml"
    if [ ! -f "$config_file" ]; then
        echo "配置文件不存在，无法删除。"
        return
    fi

    echo "当前转发规则："
    local rules=($(grep -n '^\[\[endpoints\]\]' "$config_file"))
    if [ ${#rules[@]} -eq 0 ]; then
        echo "没有发现任何转发规则。"
        return
    fi

    for i in "${!rules[@]}"; do
        local start_line=$(echo "${rules[$i]}" | cut -d ':' -f 1)
        local end_line
        if [ $i -lt $((${#rules[@]} - 1)) ]; then
            end_line=$(echo "${rules[$((i + 1))]}" | cut -d ':' -f 1)
            end_line=$((end_line - 1))
        else
            end_line=$(wc -l < "$config_file")
        fi
        local rule=$(sed -n "${start_line},${end_line}p" "$config_file")
        echo "$((i + 1)). $rule"
    done

    echo "请输入要删除的转发规则序号，直接按回车返回主菜单。"
    read -p "选择: " choice
    [[ -z "$choice" ]] && return  # 直接返回主菜单

    if ! [[ $choice =~ ^[0-9]+$ ]] || [ $choice -lt 1 ] || [ $choice -gt ${#rules[@]} ]; then
        echo "无效输入，请输入有效序号。"
        return
    fi

    local selected_rule_start=$(echo "${rules[$((choice - 1))]}" | cut -d ':' -f 1)
    local selected_rule_end
    if [ $choice -lt ${#rules[@]} ]; then
        selected_rule_end=$(echo "${rules[$choice]}" | cut -d ':' -f 1)
        selected_rule_end=$((selected_rule_end - 1))
    else
        selected_rule_end=$(wc -l < "$config_file")
    fi

    sed -i "${selected_rule_start},${selected_rule_end}d" "$config_file"
    echo "转发规则已删除。"
}

# 添加转发规则
add_forward() {
    local config_file="/root/realm/config.toml"
    if [ ! -f "$config_file" ]; then
        echo "配置文件不存在，无法添加转发规则。"
        return
    fi

    echo "当前转发规则："
    local rules=($(grep -n '^\[\[endpoints\]\]' "$config_file"))
    local rule_count=${#rules[@]}

    if [ $rule_count -eq 0 ]; then
        echo "当前没有任何转发规则。"
    else
        local i=0
        while [ $i -lt $rule_count ]; do
            local start_line=$(echo "${rules[$i]}" | cut -d ':' -f 1)
            local end_line
            if [ $i -lt $((rule_count - 1)) ]; then
                end_line=$(echo "${rules[$((i + 1))]}" | cut -d ':' -f 1)
                end_line=$((end_line - 1))
            else
                end_line=$(wc -l < "$config_file")
            fi
            local rule=$(sed -n "${start_line},${end_line}p" "$config_file")
            echo "$((i + 1)). $rule"
            ((i++))
        done
    fi

    while true; do
        echo -e "\n即将添加第 $((rule_count + 1)) 条转发规则"
        echo "提示：直接按回车可返回主菜单"
        read -p "请输入域名/IP: " ip
        
        # 如果直接回车，返回主菜单
        [[ -z "$ip" ]] && return

        read -p "请输入端口: " port
        
        # 如果端口为空，重新开始输入
        [[ -z "$port" ]] && continue

        echo "[[endpoints]]
listen = \"0.0.0.0:$port\"
remote = \"$ip:$port\"" >> "$config_file"

        echo -e "\n已添加转发规则："
        echo "监听地址：0.0.0.0:$port"
        echo "目标地址：$ip:$port"

        read -p "是否继续添加(Y/N)? " answer
        if [[ $answer != "Y" && $answer != "y" ]]; then
            break
        fi

        # 重新计算规则数量
        rules=($(grep -n '^\[\[endpoints\]\]' "$config_file"))
        rule_count=${#rules[@]}
    done
}

# 检查最新版的功能
check_latest_version() {
    echo "正在检查最新版本..."
    latest_version=$(get_latest_version)
    if [ -z "$latest_version" ]; then
        echo "无法获取最新版本，请检查网络连接或GitHub状态。"
    else
        echo "当前最新版本为：$latest_version"
    fi
}

# 启动服务
start_service() {
    systemctl unmask realm.service
    systemctl daemon-reload
    systemctl restart realm.service
    systemctl enable realm.service
    echo "realm服务已启动并设置为开机自启。"
}

# 停止服务
stop_service() {
    systemctl stop realm
    echo "realm服务已停止。"
}

# 卸载realm
uninstall_realm() {
    systemctl stop realm
    systemctl disable realm
    rm -f /etc/systemd/system/realm.service
    systemctl daemon-reload
    rm -rf /root/realm
    echo "realm已被卸载。"
}

# 主菜单
show_menu() {
    clear
    echo "欢迎使用realm一键转发脚本"
    echo "================="
    echo "1. 部署/更新"
    echo "2. 添加转发"
    echo "3. 修改转发"
    echo "4. 删除转发"
    echo "5. 启动服务"
    echo "6. 停止服务"
    echo "7. 一键卸载"
    echo "0. 退出脚本"
    echo "================="

    current_version=$(get_installed_version)
    latest_version=$(get_latest_version)

    echo "realm 当前版本：$current_version"
    
    if [ "$current_version" != "未安装" ] && [ -n "$latest_version" ] && [ "$current_version" != "$latest_version" ]; then
        echo -e "\033[0;33m最新版本：$latest_version (可更新)\033[0m"
    fi

    echo -n "realm 服务状态："
    check_realm_service_status
}

# 主循环
while true; do
    show_menu
    read -p "请选择一个选项: " choice
    case $choice in
        0)
            echo "退出脚本，再见！"
            break
            ;;
        1)
            deploy_realm
            ;;
        2)
            add_forward
            ;;
        3)
            modify_forward
            ;;
        4)
            delete_forward
            ;;
        5)
            start_service
            ;;
        6)
            stop_service
            ;;
        7)
            uninstall_realm
            ;;
        *)
            echo "无效选项: $choice，请重新选择。"
            ;;
    esac
done