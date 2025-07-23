#!/bin/bash
# Clash Pro Manager - 简洁版本
# 支持mihomo配置的专业Clash管理工具
# author: jrebort
# date: 2025-07-23

set -euo pipefail

# ==================== 配置 ====================
readonly SCRIPT_VERSION="3.1"
readonly CONFIG_DIR="$HOME/.config/mihomo"
readonly API_URL="http://localhost:9090"
readonly SERVICE_SESSION="clash-service"
readonly DEBUG_SESSION="clash-debug"

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# ==================== 工具函数 ====================

print_header() { 
    echo -e "${PURPLE}🚀 $1${NC}" 
}

print_success() { 
    echo -e "${GREEN}✅ $1${NC}" 
}

print_warning() { 
    echo -e "${YELLOW}⚠️  $1${NC}" 
}

print_error() { 
    echo -e "${RED}❌ $1${NC}" 
}

print_info() { 
    echo -e "${BLUE}💡 $1${NC}" 
}

print_step() { 
    echo -e "${CYAN}▶️  $1${NC}" 
}

# 检查依赖
check_dependencies() {
    local missing=()
    
    command -v tmux >/dev/null 2>&1 || missing+=("tmux")
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    
    if [ ${#missing[@]} -ne 0 ]; then
        print_error "缺少依赖: ${missing[*]}"
        print_info "安装: sudo apt install ${missing[*]} 或 brew install ${missing[*]}"
        return 1
    fi
    return 0
}

# 检查Clash环境
check_clash_setup() {
    if [ ! -d "$CONFIG_DIR" ]; then
        print_error "配置目录不存在: $CONFIG_DIR"
        return 1
    fi
    
    if [ ! -f "$CONFIG_DIR/config.yaml" ]; then
        print_error "配置文件不存在: $CONFIG_DIR/config.yaml"
        return 1
    fi
    
    # 查找clash二进制
    local clash_bin=""
    for path in "$CONFIG_DIR/clash" "/usr/local/bin/clash" "/usr/bin/clash" "$(command -v clash 2>/dev/null || echo '')"; do
        if [ -x "$path" ]; then
            clash_bin="$path"
            break
        fi
    done
    
    if [ -z "$clash_bin" ]; then
        print_error "找不到clash二进制文件"
        return 1
    fi
    
    export CLASH_BINARY="$clash_bin"
    return 0
}

# 获取API认证
get_api_secret() {
    local secret=""
    if command -v grep >/dev/null 2>&1; then
        secret=$(grep -E '^secret:' "$CONFIG_DIR/config.yaml" 2>/dev/null | sed 's/secret: *//' | tr -d '"'"'" || echo "")
    fi
    
    if [ -n "$secret" ]; then
        export CURL_AUTH="Authorization: Bearer $secret"
    else
        export CURL_AUTH=""
    fi
}

# 检查服务状态
check_clash_status() {
    local running=false
    local api_ok=false
    
    if pgrep -f clash >/dev/null 2>&1; then
        running=true
    fi
    
    if [ "$running" = "true" ]; then
        if curl -s -H "$CURL_AUTH" "$API_URL/version" >/dev/null 2>&1; then
            api_ok=true
        fi
    fi
    
    export CLASH_RUNNING="$running"
    export CLASH_API_OK="$api_ok"
}

# ==================== 主要功能 ====================

# 启动Clash服务
start_clash_service() {
    print_header "启动Clash服务"
    
    check_clash_status
    
    if [ "$CLASH_RUNNING" = "true" ] && [ "$CLASH_API_OK" = "true" ]; then
        print_warning "Clash服务已在运行"
        return 0
    fi
    
    # 停止异常进程
    if [ "$CLASH_RUNNING" = "true" ]; then
        print_step "停止异常进程..."
        pkill -x clash 2>/dev/null || true
        sleep 2
    fi
    
    # 清理旧会话
    if tmux has-session -t "$SERVICE_SESSION" 2>/dev/null; then
        tmux kill-session -t "$SERVICE_SESSION"
    fi
    
    # 启动服务
    print_step "启动Clash服务..."
    tmux new-session -d -s "$SERVICE_SESSION"
    tmux send-keys -t "$SERVICE_SESSION" "cd '$CONFIG_DIR'" Enter
    tmux send-keys -t "$SERVICE_SESSION" "echo '🚀 启动Clash服务...'" Enter
    tmux send-keys -t "$SERVICE_SESSION" "'$CLASH_BINARY' -d '$CONFIG_DIR' -f config.yaml" Enter
    
    # 等待启动
    sleep 3
    check_clash_status
    
    if [ "$CLASH_RUNNING" = "true" ] && [ "$CLASH_API_OK" = "true" ]; then
        print_success "Clash服务启动成功！"
        print_info "查看日志: tmux attach -t $SERVICE_SESSION"
    else
        print_error "Clash服务启动失败"
        print_info "查看详情: tmux attach -t $SERVICE_SESSION"
        return 1
    fi
}

# 停止Clash服务
stop_clash_service() {
    print_header "停止Clash服务"
    
    check_clash_status
    
    if [ "$CLASH_RUNNING" = "false" ]; then
        print_info "Clash服务未运行"
    else
        print_step "停止Clash进程..."
        pkill -x clash 2>/dev/null || true
        sleep 2
        
        if pgrep -f clash >/dev/null 2>&1; then
            print_warning "强制终止..."
            pkill -9 -x clash 2>/dev/null || true
        fi
        
        print_success "Clash进程已停止"
    fi
    
    # 清理服务会话
    if tmux has-session -t "$SERVICE_SESSION" 2>/dev/null; then
        tmux kill-session -t "$SERVICE_SESSION"
        print_success "服务会话已清理"
    fi
}

# 创建调试环境
create_debug_environment() {
    print_header "创建调试环境"
    
    check_clash_status
    if [ "$CLASH_RUNNING" = "false" ] || [ "$CLASH_API_OK" = "false" ]; then
        print_error "Clash服务未运行，请先启动服务"
        return 1
    fi
    
    # 清理已存在的调试会话
    if tmux has-session -t "$DEBUG_SESSION" 2>/dev/null; then
        tmux kill-session -t "$DEBUG_SESSION"
    fi
    
    print_step "创建调试会话..."
    tmux new-session -d -s "$DEBUG_SESSION"
    
    # 强制刷新窗口大小
    tmux refresh-client -t "$DEBUG_SESSION"
    
    # === 重命名窗口 ===
    tmux rename-window -t "$DEBUG_SESSION:0" "Debug"
    
    # === 上半部分: 交互终端 ===
    tmux send-keys -t "$DEBUG_SESSION:0" "clear" Enter
    
    # === 创建下半部分: 上下分屏，50%-50% ===
    tmux split-window -v -t "$DEBUG_SESSION:0"
    
    # === 配置下半部分: Clash日志 ===
    # 优先连接到服务会话查看实时日志
    if tmux has-session -t "$SERVICE_SESSION" 2>/dev/null; then
        tmux send-keys -t "$DEBUG_SESSION:0.1" "echo '📄 Clash实时日志 | 会话: $SERVICE_SESSION'" Enter
        tmux send-keys -t "$DEBUG_SESSION:0.1" "watch -n 2 -t 'tmux capture-pane -t $SERVICE_SESSION -p | tail -25'" Enter
    else
        # 查找日志文件
        local log_paths=(
            "$CONFIG_DIR/logs/clash.log"
            "$CONFIG_DIR/clash.log"
            "/var/log/clash.log"
        )
        
        local log_found=false
        for log_path in "${log_paths[@]}"; do
            if [ -f "$log_path" ]; then
                tmux send-keys -t "$DEBUG_SESSION:0.1" "echo '📄 Clash日志文件: $log_path'" Enter
                tmux send-keys -t "$DEBUG_SESSION:0.1" "echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'" Enter
                tmux send-keys -t "$DEBUG_SESSION:0.1" "tail -f '$log_path'" Enter
                log_found=true
                break
            fi
        done
        
        if [ "$log_found" = "false" ]; then
            tmux send-keys -t "$DEBUG_SESSION:0.1" "echo '📄 Clash日志监控'" Enter
            tmux send-keys -t "$DEBUG_SESSION:0.1" "echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'" Enter
            tmux send-keys -t "$DEBUG_SESSION:0.1" "echo '⚠️  未找到日志文件，监控服务会话输出...'" Enter
            tmux send-keys -t "$DEBUG_SESSION:0.1" "echo ''" Enter
            tmux send-keys -t "$DEBUG_SESSION:0.1" "watch -n 2 -t 'tmux has-session -t $SERVICE_SESSION 2>/dev/null && tmux capture-pane -t $SERVICE_SESSION -p | tail -20 || echo \"💡 启动服务: bash clash-manager.sh start\"'" Enter
        fi
    fi
    
    # 选择上半部分终端作为活跃窗格
    tmux select-pane -t "$DEBUG_SESSION:0.0"
    
    print_success "调试环境已优化！"
    echo ""
    print_info "📊 布局说明:"
    echo "  上: 交互终端 (50%) - 执行API命令"  
    echo "  下: 实时日志 (50%) - 查看Clash输出，长行自动截断"
    echo ""
    print_info "🎮 快捷操作:"
    echo "  Ctrl+B ↑↓     切换窗格"
    echo "  Ctrl+B z      最大化当前窗格"
    echo "  Ctrl+B d      分离会话"
    
    return 0
}

# 显示状态
show_status() {
    print_header "Clash服务状态"
    
    check_clash_status
    get_api_secret
    
    echo "🔧 基本信息:"
    echo "  配置目录: $CONFIG_DIR"
    echo "  API地址: $API_URL"
    echo "  API密钥: $([ -n "$CURL_AUTH" ] && echo '已配置' || echo '未配置')"
    echo ""
    
    echo "⚙️  服务状态:"
    if [ "$CLASH_RUNNING" = "true" ]; then
        local pid=$(pgrep -f clash | head -1)
        echo "  进程状态: ✅ 运行中 (PID: $pid)"
    else
        echo "  进程状态: ❌ 未运行"
    fi
    
    if [ "$CLASH_API_OK" = "true" ]; then
        echo "  API状态: ✅ 响应正常"
        
        # 获取连接数
        local conn_count=0
        if command -v jq >/dev/null 2>&1; then
            conn_count=$(curl -s -H "$CURL_AUTH" "$API_URL/connections" 2>/dev/null | jq '.connections | length' 2>/dev/null || echo "0")
        fi
        echo "  活跃连接: $conn_count"
    else
        echo "  API状态: ❌ 无响应"
    fi
    
    echo ""
    echo "📋 会话状态:"
    if tmux has-session -t "$SERVICE_SESSION" 2>/dev/null; then
        echo "  服务会话: ✅ $SERVICE_SESSION"
    else
        echo "  服务会话: ❌ 不存在"
    fi
    
    if tmux has-session -t "$DEBUG_SESSION" 2>/dev/null; then
        echo "  调试会话: ✅ $DEBUG_SESSION"
    else
        echo "  调试会话: ❌ 不存在"
    fi
}

# 显示菜单
show_menu() {
    clear
    echo -e "${PURPLE}===========================================${NC}"
    echo -e "${PURPLE}        🚀 Clash Pro Manager v$SCRIPT_VERSION${NC}"
    echo -e "${PURPLE}===========================================${NC}"
    echo ""
    
    check_clash_status >/dev/null 2>&1
    local status_icon="🔴"
    local status_text="未运行"
    
    if [ "$CLASH_RUNNING" = "true" ] && [ "$CLASH_API_OK" = "true" ]; then
        status_icon="🟢"
        status_text="运行正常"
    elif [ "$CLASH_RUNNING" = "true" ]; then
        status_icon="🟡"
        status_text="API异常"
    fi
    
    echo -e "当前状态: $status_icon $status_text"
    echo ""
    echo "选择操作:"
    echo "  1) 启动Clash服务"
    echo "  2) 停止Clash服务"
    echo "  3) 重启Clash服务"
    echo "  4) 创建调试环境"
    echo "  5) 连接调试环境"
    echo "  6) 查看服务日志"
    echo "  7) 显示详细状态"
    echo "  8) 清理所有会话"
    echo ""
    echo "  0) 退出"
    echo ""
}

# 清理所有
cleanup_all() {
    print_header "清理所有会话和服务"
    
    # 停止服务
    pkill -x clash 2>/dev/null || true
    
    # 清理所有相关会话
    local sessions=($(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E "(clash|debug)" || true))
    for session in "${sessions[@]}"; do
        print_info "删除会话: $session"
        tmux kill-session -t "$session" 2>/dev/null || true
    done
    
    print_success "清理完成"
}

# ==================== 主函数 ====================

main() {
    case "${1:-menu}" in
        "start")
            check_dependencies || exit 1
            check_clash_setup || exit 1
            get_api_secret
            start_clash_service
            ;;
        "stop")
            stop_clash_service
            ;;
        "restart")
            check_dependencies || exit 1
            check_clash_setup || exit 1
            get_api_secret
            stop_clash_service
            sleep 2
            start_clash_service
            ;;
        "debug")
            check_dependencies || exit 1
            check_clash_setup || exit 1
            get_api_secret
            if create_debug_environment; then
                echo ""
                print_info "连接到调试环境..."
                sleep 1
                tmux attach -t "$DEBUG_SESSION"
            fi
            ;;
        "status")
            check_clash_setup >/dev/null 2>&1 || true
            get_api_secret >/dev/null 2>&1 || true
            show_status
            ;;
        "logs")
            if tmux has-session -t "$SERVICE_SESSION" 2>/dev/null; then
                tmux attach -t "$SERVICE_SESSION"
            else
                print_error "服务会话不存在，请先启动服务"
            fi
            ;;
        "cleanup")
            cleanup_all
            ;;
        "menu"|"")
            if ! check_dependencies; then
                exit 1
            fi
            
            if ! check_clash_setup; then
                print_error "环境检查失败"
                exit 1
            fi
            
            get_api_secret >/dev/null 2>&1
            
            while true; do
                show_menu
                read -p "请选择 [0-8]: " choice
                echo ""
                
                case $choice in
                    1)
                        start_clash_service
                        read -p "按回车继续..."
                        ;;
                    2)
                        stop_clash_service
                        read -p "按回车继续..."
                        ;;
                    3)
                        stop_clash_service
                        sleep 2
                        start_clash_service
                        read -p "按回车继续..."
                        ;;
                    4)
                        if create_debug_environment; then
                            print_info "连接到调试环境..."
                            sleep 1
                            tmux attach -t "$DEBUG_SESSION"
                        fi
                        ;;
                    5)
                        if tmux has-session -t "$DEBUG_SESSION" 2>/dev/null; then
                            tmux attach -t "$DEBUG_SESSION"
                        else
                            print_warning "调试环境不存在，请先创建"
                            read -p "按回车继续..."
                        fi
                        ;;
                    6)
                        if tmux has-session -t "$SERVICE_SESSION" 2>/dev/null; then
                            tmux attach -t "$SERVICE_SESSION"
                        else
                            print_warning "服务会话不存在，请先启动服务"
                            read -p "按回车继续..."
                        fi
                        ;;
                    7)
                        show_status
                        read -p "按回车继续..."
                        ;;
                    8)
                        read -p "确认清理所有会话和服务? [y/N]: " confirm
                        if [[ $confirm =~ ^[Yy]$ ]]; then
                            cleanup_all
                        fi
                        read -p "按回车继续..."
                        ;;
                    0)
                        print_success "再见！"
                        exit 0
                        ;;
                    *)
                        print_warning "无效选择"
                        sleep 1
                        ;;
                esac
            done
            ;;
        "help"|"-h"|"--help")
            echo "Clash Pro Manager v$SCRIPT_VERSION"
            echo ""
            echo "用法: $0 [命令]"
            echo ""
            echo "可用命令:"
            echo "  start     启动Clash服务"
            echo "  stop      停止Clash服务"
            echo "  restart   重启Clash服务"
            echo "  debug     创建调试环境"
            echo "  status    显示详细状态"
            echo "  logs      查看服务日志"
            echo "  cleanup   清理所有会话"
            echo "  menu      显示交互菜单(默认)"
            echo "  help      显示此帮助"
            echo ""
            echo "示例:"
            echo "  $0           # 显示交互菜单"
            echo "  $0 start     # 启动服务"
            echo "  $0 debug     # 创建调试环境"
            ;;
        *)
            print_error "未知命令: $1"
            echo "使用 '$0 help' 查看可用命令"
            exit 1
            ;;
    esac
}

# 脚本入口
main "$@"
