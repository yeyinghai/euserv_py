#!/bin/bash

# EUserv 自动续期一键部署脚本
# 支持安装、配置、卸载功能

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置文件路径
INSTALL_DIR="/opt/euserv_renew"
CONFIG_FILE="${INSTALL_DIR}/config.env"
SERVICE_NAME="euserv-renew"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
COMMAND_LINK="/usr/local/bin/dj"

# 打印带颜色的信息
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本必须以root权限运行"
        exit 1
    fi
}

# 检查并安装依赖
install_dependencies() {
    print_info "检查并安装必要依赖..."
    
    # 检查Docker是否安装
    if ! command -v docker &> /dev/null; then
        print_info "Docker未安装,正在安装..."
        curl -fsSL https://get.docker.com | bash
        systemctl enable docker
        systemctl start docker
        print_success "Docker安装完成"
    else
        print_success "Docker已安装"
    fi
    
    # 检查docker-compose是否安装
    if ! command -v docker-compose &> /dev/null; then
        print_info "Docker Compose未安装,正在安装..."
        curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        print_success "Docker Compose安装完成"
    else
        print_success "Docker Compose已安装"
    fi
}

# 创建项目目录
create_directories() {
    print_info "创建项目目录..."
    mkdir -p ${INSTALL_DIR}/{logs,config}
    print_success "目录创建完成"
}

# 创建Dockerfile
create_dockerfile() {
    print_info "创建Dockerfile..."
    cat > ${INSTALL_DIR}/Dockerfile <<'EOF'
FROM python:3.9-slim

WORKDIR /app

# 安装依赖
RUN pip install --no-cache-dir requests beautifulsoup4 lxml

# 复制脚本
COPY euser_renew.py /app/
COPY config.env /app/

# 设置时区
ENV TZ=Asia/Shanghai
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

CMD ["python", "/app/euser_renew.py"]
EOF
    print_success "Dockerfile创建完成"
}

# 创建docker-compose.yml
create_docker_compose() {
    local run_hour=$1
    
    print_info "创建docker-compose配置..."
    cat > ${COMPOSE_FILE} <<EOF
version: '3.8'

services:
  euserv-renew:
    build: .
    container_name: euserv-renew
    restart: unless-stopped
    env_file:
      - config.env
    volumes:
      - ./logs:/app/logs
      - ./config.env:/app/config.env:ro
      - ./euser_renew.py:/app/euser_renew.py:ro
    environment:
      - TZ=Asia/Shanghai
      - RUN_HOUR=${run_hour}
    labels:
      - "euserv.schedule=${run_hour}"
EOF
    print_success "docker-compose配置创建完成"
}

# 下载脚本
download_script() {
    print_info "下载EUserv续期脚本..."
    
    # 从GitHub下载脚本
    if curl -fsSL https://raw.githubusercontent.com/dufei511/euserv_py/dev/euser_renew.py -o ${INSTALL_DIR}/euser_renew.py; then
        chmod +x ${INSTALL_DIR}/euser_renew.py
        print_success "脚本下载成功"
    else
        print_error "脚本下载失败,请检查网络连接或GitHub是否可访问"
        exit 1
    fi
}

# 配置环境变量
configure_env() {
    print_info "配置环境变量..."
    echo ""
    
    # 必填项
    print_info "=== 必填项 ==="
    read -p "请输入EUserv账号邮箱: " email
    read -sp "请输入EUserv账号密码: " password
    echo ""
    read -sp "请输入邮箱应用专用密码(EMAIL_PASS): " email_pass
    echo ""
    echo ""
    
    # 可选项
    print_info "=== 可选项(推送通知配置，不需要可直接回车跳过) ==="
    read -p "Telegram Bot Token (可选): " tg_bot_token
    read -p "Telegram Chat ID (可选): " tg_chat_id
    read -p "Bark推送URL (可选): " bark_url
    echo ""
    
    # 生成配置文件
    cat > ${CONFIG_FILE} <<EOF
# EUserv账号配置(必填)
EUSERV_EMAIL=${email}
EUSERV_PASSWORD=${password}
EMAIL_PASS=${email_pass}

# Telegram推送配置(可选)
EOF

    # 只有填写了才添加到配置文件
    if [ -n "$tg_bot_token" ]; then
        echo "TG_BOT_TOKEN=${tg_bot_token}" >> ${CONFIG_FILE}
    fi
    
    if [ -n "$tg_chat_id" ]; then
        echo "TG_CHAT_ID=${tg_chat_id}" >> ${CONFIG_FILE}
    fi
    
    if [ -n "$bark_url" ]; then
        echo "BARK_URL=${bark_url}" >> ${CONFIG_FILE}
    fi
    
    chmod 600 ${CONFIG_FILE}
    print_success "环境变量配置完成"
}

# 创建cron任务
setup_cron() {
    local run_hour=$1
    
    print_info "设置定时任务(每天${run_hour}点执行)..."
    
    # 创建systemd timer
    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=EUserv Auto Renew Service
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/local/bin/docker-compose -f ${COMPOSE_FILE} up --build
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/${SERVICE_NAME}.timer <<EOF
[Unit]
Description=EUserv Auto Renew Timer
Requires=${SERVICE_NAME}.service

[Timer]
OnCalendar=*-*-* ${run_hour}:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME}.timer
    systemctl start ${SERVICE_NAME}.timer
    
    print_success "定时任务设置完成"
}

# 创建快捷命令
create_command() {
    print_info "创建快捷命令..."
    
    cat > ${COMMAND_LINK} <<'EOF'
#!/bin/bash

INSTALL_DIR="/opt/euserv_renew"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"

show_menu() {
    clear
    echo "======================================"
    echo "    EUserv 自动续期管理面板"
    echo "======================================"
    echo "1. 查看服务状态"
    echo "2. 查看日志"
    echo "3. 立即执行续期"
    echo "4. 重启服务"
    echo "5. 修改执行时间"
    echo "6. 修改账号配置"
    echo "7. 更新续期脚本"
    echo "8. 卸载服务"
    echo "0. 退出"
    echo "======================================"
    read -p "请选择操作 [0-8]: " choice
    
    case $choice in
        1) show_status ;;
        2) show_logs ;;
        3) run_now ;;
        4) restart_service ;;
        5) change_schedule ;;
        6) change_config ;;
        7) update_script ;;
        8) uninstall ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 2; show_menu ;;
    esac
}

show_status() {
    echo ""
    echo "===== 服务状态 ====="
    systemctl status euserv-renew.timer --no-pager
    echo ""
    echo "===== 下次执行时间 ====="
    systemctl list-timers euserv-renew.timer --no-pager
    echo ""
    read -p "按回车键返回菜单..." 
    show_menu
}

show_logs() {
    echo ""
    echo "===== 最近的日志 (按Ctrl+C退出) ====="
    journalctl -u euserv-renew.service -f --no-pager
    show_menu
}

run_now() {
    echo ""
    echo "===== 立即执行续期任务 ====="
    cd ${INSTALL_DIR}
    docker-compose up --build
    read -p "按回车键返回菜单..." 
    show_menu
}

restart_service() {
    echo ""
    echo "===== 重启服务 ====="
    systemctl restart euserv-renew.timer
    echo "服务已重启"
    sleep 2
    show_menu
}

change_schedule() {
    echo ""
    read -p "请输入新的执行时间(0-23): " new_hour
    
    if [[ $new_hour =~ ^[0-9]+$ ]] && [ $new_hour -ge 0 ] && [ $new_hour -le 23 ]; then
        sed -i "s/OnCalendar=\*-\*-\* [0-9]\{1,2\}:00:00/OnCalendar=*-*-* ${new_hour}:00:00/" /etc/systemd/system/euserv-renew.timer
        systemctl daemon-reload
        systemctl restart euserv-renew.timer
        echo "执行时间已修改为每天 ${new_hour}:00"
    else
        echo "无效的时间,请输入0-23之间的数字"
    fi
    
    sleep 2
    show_menu
}

change_config() {
    echo ""
    echo "===== 修改账号配置 ====="
    echo ""
    
    # 必填项
    print_info "=== 必填项 ==="
    read -p "请输入EUserv账号邮箱: " email
    read -sp "请输入EUserv账号密码: " password
    echo ""
    read -sp "请输入邮箱应用专用密码(EMAIL_PASS): " email_pass
    echo ""
    echo ""
    
    # 可选项
    print_info "=== 可选项(推送通知配置，不需要可直接回车跳过) ==="
    read -p "Telegram Bot Token (可选): " tg_bot_token
    read -p "Telegram Chat ID (可选): " tg_chat_id
    read -p "Bark推送URL (可选): " bark_url
    echo ""
    
    # 生成配置文件
    cat > ${INSTALL_DIR}/config.env <<EOL
# EUserv账号配置(必填)
EUSERV_EMAIL=${email}
EUSERV_PASSWORD=${password}
EMAIL_PASS=${email_pass}

# Telegram推送配置(可选)
EOL

    # 只有填写了才添加到配置文件
    if [ -n "$tg_bot_token" ]; then
        echo "TG_BOT_TOKEN=${tg_bot_token}" >> ${INSTALL_DIR}/config.env
    fi
    
    if [ -n "$tg_chat_id" ]; then
        echo "TG_CHAT_ID=${tg_chat_id}" >> ${INSTALL_DIR}/config.env
    fi
    
    if [ -n "$bark_url" ]; then
        echo "BARK_URL=${bark_url}" >> ${INSTALL_DIR}/config.env
    fi
    
    chmod 600 ${INSTALL_DIR}/config.env
    echo "配置已更新"
    sleep 2
    show_menu
}

update_script() {
    echo ""
    echo "===== 更新续期脚本 ====="
    echo ""
    
    # 显示当前脚本信息
    if [ -f "${INSTALL_DIR}/euser_renew.py" ]; then
        echo "当前脚本修改时间: $(stat -c %y ${INSTALL_DIR}/euser_renew.py 2>/dev/null || stat -f %Sm ${INSTALL_DIR}/euser_renew.py 2>/dev/null)"
    fi
    echo ""
    
    read -p "确定要从GitHub更新脚本吗? (y/N): " confirm
    
    if [[ $confirm == "y" || $confirm == "Y" ]]; then
        echo "正在备份当前脚本..."
        if [ -f "${INSTALL_DIR}/euser_renew.py" ]; then
            cp ${INSTALL_DIR}/euser_renew.py ${INSTALL_DIR}/euser_renew.py.bak.$(date +%Y%m%d_%H%M%S)
            echo "备份完成: ${INSTALL_DIR}/euser_renew.py.bak.$(date +%Y%m%d_%H%M%S)"
        fi
        
        echo "正在下载最新脚本..."
        if curl -fsSL https://raw.githubusercontent.com/dufei511/euserv_py/dev/euser_renew.py -o ${INSTALL_DIR}/euser_renew.py.new; then
            mv ${INSTALL_DIR}/euser_renew.py.new ${INSTALL_DIR}/euser_renew.py
            chmod +x ${INSTALL_DIR}/euser_renew.py
            echo ""
            echo "✓ 脚本更新成功!"
            echo "新脚本修改时间: $(stat -c %y ${INSTALL_DIR}/euser_renew.py 2>/dev/null || stat -f %Sm ${INSTALL_DIR}/euser_renew.py 2>/dev/null)"
            echo ""
            
            read -p "是否立即重启服务以应用更新? (Y/n): " restart_confirm
            if [[ $restart_confirm != "n" && $restart_confirm != "N" ]]; then
                echo "正在重启服务..."
                cd ${INSTALL_DIR}
                docker-compose down
                docker-compose up --build -d
                echo "✓ 服务已重启，更新已生效"
            else
                echo "提示: 记得稍后手动重启服务以应用更新"
            fi
        else
            echo ""
            echo "✗ 脚本下载失败，可能原因:"
            echo "  1. 网络连接问题"
            echo "  2. GitHub无法访问"
            echo "  3. 脚本路径已变更"
            echo ""
            if [ -f "${INSTALL_DIR}/euser_renew.py.bak.$(date +%Y%m%d_%H%M%S)" ]; then
                echo "备份文件已保留，原脚本未受影响"
            fi
        fi
    else
        echo "取消更新"
    fi
    
    echo ""
    read -p "按回车键返回菜单..." 
    show_menu
}

uninstall() {
    echo ""
    read -p "确定要卸载EUserv自动续期服务吗? (y/N): " confirm
    
    if [[ $confirm == "y" || $confirm == "Y" ]]; then
        echo "正在卸载..."
        systemctl stop euserv-renew.timer
        systemctl disable euserv-renew.timer
        rm -f /etc/systemd/system/euserv-renew.service
        rm -f /etc/systemd/system/euserv-renew.timer
        systemctl daemon-reload
        
        cd ${INSTALL_DIR}
        docker-compose down -v 2>/dev/null
        
        rm -rf ${INSTALL_DIR}
        rm -f /usr/local/bin/euserv
        
        echo "卸载完成!"
        exit 0
    else
        show_menu
    fi
}

show_menu
EOF
    
    chmod +x ${COMMAND_LINK}
    print_success "快捷命令创建完成 (使用 'dj' 命令打开管理面板)"
}

# 安装主函数
install() {
    print_info "开始安装EUserv自动续期服务..."
    
    # 检查是否已安装
    if [ -d "${INSTALL_DIR}" ]; then
        print_warning "检测到已安装,是否重新安装? (y/N)"
        read -r reinstall
        if [[ ! $reinstall =~ ^[Yy]$ ]]; then
            print_info "取消安装"
            exit 0
        fi
        uninstall_service
    fi
    
    # 执行安装步骤
    check_root
    install_dependencies
    create_directories
    download_script
    configure_env
    create_dockerfile
    
    # 设置执行时间
    read -p "请输入每天执行的小时数(0-23,默认3点): " run_hour
    run_hour=${run_hour:-3}
    
    if ! [[ $run_hour =~ ^[0-9]+$ ]] || [ $run_hour -lt 0 ] || [ $run_hour -gt 23 ]; then
        print_warning "无效的小时数,使用默认值3"
        run_hour=3
    fi
    
    create_docker_compose $run_hour
    setup_cron $run_hour
    create_command
    
    print_success "========================================="
    print_success "EUserv自动续期服务安装完成!"
    print_success "========================================="
    print_info "服务将在每天 ${run_hour}:00 自动执行"
    print_info "使用以下命令管理服务:"
    print_info "  dj                - 打开管理面板"
    print_info "  systemctl status euserv-renew.timer - 查看定时器状态"
    print_success "========================================="
}

# 卸载函数
uninstall_service() {
    print_info "开始卸载EUserv自动续期服务..."
    
    # 停止并禁用服务
    systemctl stop ${SERVICE_NAME}.timer 2>/dev/null
    systemctl disable ${SERVICE_NAME}.timer 2>/dev/null
    
    # 删除服务文件
    rm -f /etc/systemd/system/${SERVICE_NAME}.service
    rm -f /etc/systemd/system/${SERVICE_NAME}.timer
    systemctl daemon-reload
    
    # 停止并删除Docker容器
    if [ -f "${COMPOSE_FILE}" ]; then
        cd ${INSTALL_DIR}
        docker-compose down -v 2>/dev/null
    fi
    
    # 删除安装目录
    rm -rf ${INSTALL_DIR}
    
    # 删除快捷命令
    rm -f ${COMMAND_LINK}
    
    print_success "卸载完成!"
}

# 显示帮助信息
show_help() {
    echo "EUserv 自动续期一键部署脚本"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  install     安装服务"
    echo "  uninstall   卸载服务"
    echo "  help        显示此帮助信息"
    echo ""
}

# 主函数
main() {
    case "${1:-install}" in
        install)
            install
            ;;
        uninstall)
            check_root
            uninstall_service
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "未知选项: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"