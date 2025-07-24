#!/bin/bash
# Clash Pro Manager - 增强版
# 支持mihomo配置的专业Clash管理工具，包含内核下载和更新功能
# author: jrebort
# date: 2025-07-23

set -euo pipefail

# ==================== 配置 ====================
readonly SCRIPT_VERSION="4.0"
readonly CONFIG_DIR="$HOME/.config/mihomo"
readonly API_URL="http://localhost:9090"
readonly SERVICE_SESSION="clash-service"
readonly DEBUG_SESSION="clash-debug"
readonly GITHUB_API="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
readonly INSTALL_DIR="/usr/local/bin"
readonly BACKUP_DIR="$CONFIG_DIR/backups"

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

# 检测系统架构
detect_architecture() {
    local arch=$(uname -m)
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    
    case "$arch" in
        x86_64|amd64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        armv7l|armhf)
            ARCH="armv7"
            ;;
        i386|i686)
            ARCH="386"
            ;;
        *)
            print_error "不支持的架构: $arch"
            return 1
            ;;
    esac
    
    case "$os" in
        linux)
            OS="linux"
            ;;
        darwin)
            OS="darwin"
            ;;
        *)
            print_error "不支持的操作系统: $os"
            return 1
            ;;
    esac
    
    PLATFORM="${OS}-${ARCH}"
    return 0
}

# 检查依赖
check_dependencies() {
    local missing=()
    
    command -v tmux >/dev/null 2>&1 || missing+=("tmux")
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v wget >/dev/null 2>&1 || missing+=("wget")
    command -v jq >/dev/null 2>&1 || missing+=("jq")
    command -v tar >/dev/null 2>&1 || missing+=("tar")
    command -v gzip >/dev/null 2>&1 || missing+=("gzip")
    
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
        print_warning "配置目录不存在，创建中..."
        mkdir -p "$CONFIG_DIR"
    fi
    
    if [ ! -f "$CONFIG_DIR/config.yaml" ]; then
        print_error "配置文件不存在: $CONFIG_DIR/config.yaml"
        return 1
    fi
    
    # 查找clash二进制 - 只在系统路径查找
    local clash_bin=""
    for path in "$INSTALL_DIR/clash" "/usr/local/bin/clash" "/usr/bin/clash" "$(command -v clash 2>/dev/null || echo '')"; do
        if [ -x "$path" ]; then
            clash_bin="$path"
            break
        fi
    done
    
    if [ -z "$clash_bin" ]; then
        print_warning "找不到clash二进制文件"
        export CLASH_BINARY=""
    else
        export CLASH_BINARY="$clash_bin"
    fi
    
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

# ==================== 内核管理功能 ====================

# 获取当前版本
get_current_version() {
    if [ -n "${CLASH_BINARY:-}" ] && [ -x "$CLASH_BINARY" ]; then
        local version=$("$CLASH_BINARY" -v 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
        echo "${version:-unknown}"
    else
        echo "not installed"
    fi
}

# 获取最新版本信息
get_latest_version_info() {
    print_step "获取最新版本信息..."
    
    # 添加 User-Agent 以避免被拒绝
    local release_info=$(curl -s -m 10 -H "User-Agent: Mozilla/5.0" "$GITHUB_API" 2>/dev/null)
    
    # 调试：显示响应的前100个字符
    if [ -n "${DEBUG:-}" ]; then
        echo "API响应: ${release_info:0:100}..."
    fi
    
    # 检查是否是有效的 JSON 响应（应该包含 tag_name）
    if [ -z "$release_info" ] || [ "$release_info" = "null" ] || ! echo "$release_info" | grep -q '"tag_name"'; then
        print_warning "GitHub API 访问失败，尝试镜像 API..."
        
        # 尝试使用镜像 API
        release_info=$(curl -s -m 10 -H "User-Agent: Mozilla/5.0" "https://mirror.ghproxy.com/$GITHUB_API" 2>/dev/null)
        
        if [ -z "$release_info" ] || [ "$release_info" = "null" ]; then
            # 备用方案：从 releases 页面提取
            print_warning "镜像 API 也失败，尝试从页面提取..."
            local latest_url=$(curl -sL -m 10 "https://github.com/MetaCubeX/mihomo/releases/latest" 2>/dev/null | grep -o '/MetaCubeX/mihomo/releases/tag/[^"]*' | head -1)
            if [ -n "$latest_url" ]; then
                LATEST_VERSION=$(echo "$latest_url" | sed 's|.*/tag/||')
                if [ -n "$LATEST_VERSION" ]; then
                    print_success "最新版本: $LATEST_VERSION (从页面获取)"
                    return 0
                fi
            fi
            
            # 最后的备用方案：使用已知的最新版本
            print_warning "无法自动获取版本，使用默认版本 v1.19.11"
            LATEST_VERSION="v1.19.11"
            print_success "使用版本: $LATEST_VERSION (默认)"
            return 0
        fi
    fi
    
    # 尝试用 jq 解析，如果没有 jq 就用 grep
    if command -v jq >/dev/null 2>&1; then
        LATEST_VERSION=$(echo "$release_info" | jq -r '.tag_name' 2>/dev/null || echo "")
    else
        LATEST_VERSION=$(echo "$release_info" | grep '"tag_name"' | cut -d'"' -f4)
    fi
    
    if [ -z "$LATEST_VERSION" ] || [ "$LATEST_VERSION" = "null" ]; then
        print_error "无法解析版本信息"
        return 1
    fi
    
    print_success "最新版本: $LATEST_VERSION"
    return 0
}

# 下载内核
download_clash_core() {
    local version="$1"
    local platform="$2"
    
    # 构建下载URL - 注意文件名格式包含版本号
    local filename="mihomo-${platform}-${version}.gz"
    local original_url="https://github.com/MetaCubeX/mihomo/releases/download/${version}/${filename}"
    
    print_step "下载 mihomo ${version} (${platform})..."
    
    # 创建临时目录
    local temp_dir=$(mktemp -d)
    trap "rm -rf $temp_dir" EXIT
    
    # 尝试使用镜像下载
    local mirrors=(
        "https://ghfast.top/"
        "https://mirror.ghproxy.com/"  # 新的推荐镜像
        "https://ghproxy.com/"
        "https://github.moeyy.xyz/"
        "https://gh.ddlc.top/"
        ""  # 原始地址作为最后尝试
    )
    
    local downloaded=false
    for mirror in "${mirrors[@]}"; do
        local download_url="${mirror}${original_url}"
        if [ -z "$mirror" ]; then
            print_info "尝试原始地址..."
        else
            print_info "尝试镜像: $mirror"
        fi
        
        if wget --timeout=30 --tries=2 -O "$temp_dir/$filename" "$download_url" 2>/dev/null; then
            # 验证文件是否为有效的 tar.gz 文件
            # 检查文件大小（至少要有 1MB）
            local file_size=$(stat -c%s "$temp_dir/$filename" 2>/dev/null || echo 0)
            if [ "$file_size" -gt 1048576 ]; then
                # 尝试用 gzip -t 测试文件完整性
                if gzip -t "$temp_dir/$filename" 2>/dev/null; then
                    downloaded=true
                    print_success "下载成功！(大小: $(( file_size / 1024 / 1024 ))MB)"
                    break
                else
                    # 可能是 HTML 错误页面
                    print_warning "下载的文件无效"
                    if [ -n "${DEBUG:-}" ]; then
                        echo "文件大小: $file_size 字节"
                        echo "文件内容预览: $(head -c 200 "$temp_dir/$filename" 2>/dev/null | grep -o '[[:print:]]*')"
                    fi
                fi
            else
                print_warning "文件太小 (${file_size} 字节)，可能是错误页面"
            fi
        else
            if [ -n "$mirror" ]; then
                print_warning "下载失败，尝试下一个镜像..."
            fi
        fi
    done
    
    if [ "$downloaded" = "false" ]; then
        print_error "所有下载方式都失败了"
        return 1
    fi
    
    # 解压文件 - 现在是 .gz 格式，不是 tar.gz
    print_step "解压文件..."
    local binary_file="$temp_dir/mihomo"
    if ! gzip -dc "$temp_dir/$filename" > "$binary_file"; then
        print_error "解压失败"
        return 1
    fi
    
    # 验证解压后的文件
    if [ ! -f "$binary_file" ] || [ ! -s "$binary_file" ]; then
        print_error "解压后的文件无效"
        return 1
    fi
    
    # 设置执行权限
    chmod +x "$binary_file"
    
    # 导出路径供安装使用
    export DOWNLOADED_BINARY="$binary_file"
    
    print_success "下载完成"
    return 0
}

# 安装内核
install_clash_core() {
    if [ -z "${DOWNLOADED_BINARY:-}" ] || [ ! -f "$DOWNLOADED_BINARY" ]; then
        print_error "没有可安装的二进制文件"
        return 1
    fi
    
    print_header "安装 Clash/mihomo 内核"
    
    # 创建备份目录
    mkdir -p "$BACKUP_DIR"
    
    # 备份当前版本
    if [ -n "${CLASH_BINARY:-}" ] && [ -f "$CLASH_BINARY" ]; then
        local current_version=$(get_current_version)
        if [ "$current_version" != "not installed" ] && [ "$current_version" != "unknown" ]; then
            local backup_name="clash-${current_version}-$(date +%Y%m%d%H%M%S)"
            print_step "备份当前版本到: $BACKUP_DIR/$backup_name"
            cp "$CLASH_BINARY" "$BACKUP_DIR/$backup_name"
        fi
    fi
    
    # 检查是否需要sudo
    local need_sudo=false
    local install_path="$INSTALL_DIR/clash"
    
    if [ -w "$INSTALL_DIR" ]; then
        need_sudo=false
    else
        need_sudo=true
    fi
    
    # 安装新版本
    if [ "$need_sudo" = "true" ]; then
        print_step "安装到系统目录需要管理员权限"
        print_info "执行: sudo cp $DOWNLOADED_BINARY $install_path"
        if ! sudo cp "$DOWNLOADED_BINARY" "$install_path"; then
            print_error "安装失败"
            return 1
        fi
        print_step "设置执行权限..."
        sudo chmod +x "$install_path"
    else
        print_step "安装到: $install_path"
        if ! cp "$DOWNLOADED_BINARY" "$install_path"; then
            print_error "安装失败"
            return 1
        fi
        chmod +x "$install_path"
    fi
    
    # 不再创建符号链接，直接使用系统级安装
    
    # 更新环境变量
    export CLASH_BINARY="$install_path"
    
    # 验证安装
    local new_version=$("$install_path" -v 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
    if [ -n "$new_version" ]; then
        print_success "安装成功！版本: $new_version"
    else
        print_warning "安装完成，但无法验证版本"
    fi
    
    return 0
}

# 检查更新
check_for_updates() {
    print_header "检查内核更新"
    
    local current_version=$(get_current_version)
    print_info "当前版本: $current_version"
    
    if ! get_latest_version_info; then
        return 1
    fi
    
    if [ "$current_version" = "not installed" ]; then
        print_warning "未安装内核"
        return 0
    fi
    
    if [ "$current_version" = "$LATEST_VERSION" ]; then
        print_success "已是最新版本"
        return 0
    fi
    
    print_warning "有新版本可用: $LATEST_VERSION"
    return 0
}

# 列出备份版本
list_backups() {
    print_header "备份版本列表"
    
    if [ ! -d "$BACKUP_DIR" ]; then
        print_info "没有备份"
        return 0
    fi
    
    local backups=($(ls -1 "$BACKUP_DIR"/clash-* 2>/dev/null | sort -r))
    
    if [ ${#backups[@]} -eq 0 ]; then
        print_info "没有备份"
        return 0
    fi
    
    echo "找到 ${#backups[@]} 个备份:"
    for backup in "${backups[@]}"; do
        local name=$(basename "$backup")
        local size=$(du -h "$backup" | awk '{print $1}')
        echo "  - $name ($size)"
    done
}

# ==================== 主要功能 ====================

# 启动Clash服务
start_clash_service() {
    print_header "启动Clash服务"
    
    if [ -z "${CLASH_BINARY:-}" ] || [ ! -x "$CLASH_BINARY" ]; then
        print_error "Clash二进制文件不存在或不可执行"
        print_info "请先安装内核: $0 install"
        return 1
    fi
    
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
    # 创建会话时指定较大的默认窗口大小
    tmux new-session -d -s "$DEBUG_SESSION" -x 120 -y 30
    
    # 设置默认窗口大小
    tmux set-option -t "$DEBUG_SESSION" default-terminal "screen-256color"
    tmux set-window-option -t "$DEBUG_SESSION" aggressive-resize on
    
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
        # 使用 COLUMNS 环境变量让 watch 使用全宽度
        tmux send-keys -t "$DEBUG_SESSION:0.1" "COLUMNS=\$(tput cols) watch -n 2 -t 'tmux capture-pane -t $SERVICE_SESSION -p | tail -25 | cut -c1-\$(tput cols)'" Enter
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
            tmux send-keys -t "$DEBUG_SESSION:0.1" "COLUMNS=\$(tput cols) watch -n 2 -t 'tmux has-session -t $SERVICE_SESSION 2>/dev/null && tmux capture-pane -t $SERVICE_SESSION -p | tail -20 | cut -c1-\$(tput cols) || echo \"💡 启动服务: bash clash-manager.sh start\"'" Enter
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
    echo "  内核版本: $(get_current_version)"
    echo "  系统架构: ${PLATFORM:-未检测}"
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
    
    echo -e "当前状态: $status_icon $status_text | 版本: $(get_current_version)"
    echo ""
    echo "📦 内核管理:"
    echo "  1) 检查更新"
    echo "  2) 下载并安装最新版本"
    echo "  3) 查看备份版本"
    echo ""
    echo "🎯 服务管理:"
    echo "  4) 启动Clash服务"
    echo "  5) 停止Clash服务"
    echo "  6) 重启Clash服务"
    echo ""
    echo "🔧 调试工具:"
    echo "  7) 创建调试环境"
    echo "  8) 连接/删除调试环境"
    echo "  9) 查看服务日志"
    echo ""
    echo "📊 其他:"
    echo "  10) 显示详细状态"
    echo "  11) 清理所有会话"
    echo ""
    echo "  0) 退出"
    echo ""
}

# 删除调试会话
cleanup_debug_session() {
    print_header "删除调试会话"
    
    if tmux has-session -t "$DEBUG_SESSION" 2>/dev/null; then
        print_step "删除调试会话: $DEBUG_SESSION"
        tmux kill-session -t "$DEBUG_SESSION"
        print_success "调试会话已删除"
    else
        print_info "调试会话不存在"
    fi
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
        "install")
            check_dependencies || exit 1
            detect_architecture || exit 1
            
            if ! get_latest_version_info; then
                exit 1
            fi
            
            if download_clash_core "$LATEST_VERSION" "$PLATFORM"; then
                install_clash_core
            fi
            ;;
        "update")
            check_dependencies || exit 1
            detect_architecture || exit 1
            check_for_updates
            ;;
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
            detect_architecture >/dev/null 2>&1 || true
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
            
            detect_architecture >/dev/null 2>&1 || true
            check_clash_setup >/dev/null 2>&1 || true
            get_api_secret >/dev/null 2>&1
            
            while true; do
                show_menu
                read -p "请选择 [0-11]: " choice
                echo ""
                
                case $choice in
                    1)
                        check_for_updates
                        read -p "按回车继续..."
                        ;;
                    2)
                        if ! get_latest_version_info; then
                            read -p "按回车继续..."
                            continue
                        fi
                        
                        read -p "确认下载并安装 $LATEST_VERSION? [y/N]: " confirm
                        if [[ $confirm =~ ^[Yy]$ ]]; then
                            if download_clash_core "$LATEST_VERSION" "$PLATFORM"; then
                                install_clash_core
                            fi
                        fi
                        read -p "按回车继续..."
                        ;;
                    3)
                        list_backups
                        read -p "按回车继续..."
                        ;;
                    4)
                        start_clash_service
                        read -p "按回车继续..."
                        ;;
                    5)
                        stop_clash_service
                        read -p "按回车继续..."
                        ;;
                    6)
                        stop_clash_service
                        sleep 2
                        start_clash_service
                        read -p "按回车继续..."
                        ;;
                    7)
                        if create_debug_environment; then
                            print_info "连接到调试环境..."
                            sleep 1
                            tmux attach -t "$DEBUG_SESSION"
                        fi
                        ;;
                    8)
                        if tmux has-session -t "$DEBUG_SESSION" 2>/dev/null; then
                            echo "调试会话存在"
                            echo "1) 连接到调试会话"
                            echo "2) 删除调试会话"
                            echo "0) 返回上一层"
                            read -p "请选择 [0-2]: " debug_choice
                            
                            case $debug_choice in
                                1)
                                    tmux attach -t "$DEBUG_SESSION"
                                    ;;
                                2)
                                    cleanup_debug_session
                                    read -p "按回车继续..."
                                    ;;
                                0)
                                    # 返回上一层，不做任何操作
                                    ;;
                                *)
                                    print_warning "无效选择"
                                    read -p "按回车继续..."
                                    ;;
                            esac
                        else
                            print_warning "调试环境不存在，请先创建"
                            read -p "按回车继续..."
                        fi
                        ;;
                    9)
                        if tmux has-session -t "$SERVICE_SESSION" 2>/dev/null; then
                            tmux attach -t "$SERVICE_SESSION"
                        else
                            print_warning "服务会话不存在，请先启动服务"
                            read -p "按回车继续..."
                        fi
                        ;;
                    10)
                        show_status
                        read -p "按回车继续..."
                        ;;
                    11)
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
            echo "  install   下载并安装最新版本内核"
            echo "  update    检查内核更新"
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
            echo "  $0 install   # 安装最新内核"
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