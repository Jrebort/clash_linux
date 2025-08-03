#!/bin/bash
# Clash Pro Manager - 增强版
# 支持mihomo配置的专业Clash管理工具，包含内核下载和更新功能
# author: jrebort
# date: 2025-07-23

set -euo pipefail

# ==================== 配置 ====================
readonly SCRIPT_VERSION="0.1"
readonly CONFIG_DIR="$HOME/.config/mihomo"
readonly SERVICE_SESSION="clash-service"
readonly DEBUG_SESSION="clash-debug"

# 加载配置文件（如果存在）
CONFIG_FILE="$(dirname "$0")/clash_config.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# 默认配置（可被配置文件覆盖）
readonly API_URL="${API_URL:-http://${API_HOST:-localhost}:${API_PORT:-9090}}"
readonly TEST_URL="${TEST_URL:-http://www.gstatic.com/generate_204}"
readonly TEST_TIMEOUT="${TEST_TIMEOUT:-5000}"
readonly MAX_CONCURRENT="${MAX_CONCURRENT:-10}"
readonly PAGE_SIZE="${PAGE_SIZE:-15}"
readonly GITHUB_API="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
readonly INSTALL_DIR="/usr/local/bin"
readonly BACKUP_DIR="$CONFIG_DIR/backups"

# 颜色定义
readonly RED=$'\033[0;31m'
readonly GREEN=$'\033[0;32m'
readonly YELLOW=$'\033[1;33m'
readonly BLUE=$'\033[0;34m'
readonly PURPLE=$'\033[0;35m'
readonly CYAN=$'\033[0;36m'
readonly NC=$'\033[0m'

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

# 获取当前代理模式
get_proxy_mode() {
    local mode="Unknown"
    
    # 确保有API认证
    if [ -z "$CURL_AUTH" ]; then
        get_api_secret
    fi
    
    # 获取当前模式
    local config=$(curl -s -H "$CURL_AUTH" "$API_URL/configs" 2>/dev/null)
    if [ -n "$config" ] && command -v jq >/dev/null 2>&1; then
        mode=$(echo "$config" | jq -r '.mode // "Unknown"' 2>/dev/null)
    fi
    
    # 转换为友好显示
    case "$mode" in
        "rule")
            echo "Rule"
            ;;
        "global")
            echo "Global"
            ;;
        "direct")
            echo "Direct"
            ;;
        "script")
            echo "Script"
            ;;
        *)
            echo "$mode"
            ;;
    esac
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

# 下载 MMDB 文件
download_mmdb() {
    local mmdb_file="$CONFIG_DIR/geoip.metadb"
    local country_mmdb="$CONFIG_DIR/Country.mmdb"
    
    # 如果文件已存在且大小合理，跳过下载
    if [ -f "$mmdb_file" ] && [ $(stat -c%s "$mmdb_file" 2>/dev/null || echo 0) -gt 1000 ]; then
        return 0
    fi
    
    if [ -f "$country_mmdb" ] && [ $(stat -c%s "$country_mmdb" 2>/dev/null || echo 0) -gt 1000 ]; then
        return 0
    fi
    
    print_step "检测到缺少 MMDB 文件，正在下载..."
    
    # 定义下载 URL
    local mmdb_urls=(
        "https://mirror.ghproxy.com/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb"
        "https://ghfast.top/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb"
        "https://gh.con.sh/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb"
        "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb"
    )
    
    local country_urls=(
        "https://cdn.jsdelivr.net/gh/Dreamacro/maxmind-geoip@release/Country.mmdb"
        "https://fastly.jsdelivr.net/gh/Dreamacro/maxmind-geoip@release/Country.mmdb"
    )
    
    # 先尝试下载 geoip.metadb
    for url in "${mmdb_urls[@]}"; do
        print_info "尝试: $url"
        if curl -L -o "$mmdb_file.tmp" "$url" --connect-timeout 10 --max-time 60 -# 2>/dev/null; then
            if [ -f "$mmdb_file.tmp" ] && [ $(stat -c%s "$mmdb_file.tmp" 2>/dev/null || echo 0) -gt 1000 ]; then
                mv "$mmdb_file.tmp" "$mmdb_file"
                print_success "MMDB 文件下载成功"
                return 0
            fi
        fi
        rm -f "$mmdb_file.tmp"
    done
    
    # 如果失败，尝试下载 Country.mmdb
    print_warning "geoip.metadb 下载失败，尝试下载 Country.mmdb..."
    for url in "${country_urls[@]}"; do
        print_info "尝试: $url"
        if curl -L -o "$country_mmdb.tmp" "$url" --connect-timeout 10 --max-time 60 -# 2>/dev/null; then
            if [ -f "$country_mmdb.tmp" ] && [ $(stat -c%s "$country_mmdb.tmp" 2>/dev/null || echo 0) -gt 1000 ]; then
                mv "$country_mmdb.tmp" "$country_mmdb"
                print_success "Country.mmdb 下载成功"
                return 0
            fi
        fi
        rm -f "$country_mmdb.tmp"
    done
    
    print_error "MMDB 文件下载失败"
    print_info "你可以手动下载后放到: $CONFIG_DIR/"
    print_info "或者先禁用配置文件中的 GEOIP 规则"
    return 1
}

# 启动Clash服务
start_clash_service() {
    print_header "启动Clash服务"
    
    if [ -z "${CLASH_BINARY:-}" ] || [ ! -x "$CLASH_BINARY" ]; then
        print_error "Clash二进制文件不存在或不可执行"
        print_info "请先安装内核: $0 install"
        return 1
    fi
    
    # 下载 MMDB 文件（如果需要）
    download_mmdb
    
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
    
    # 分别检查不同的错误情况，给出更准确的提示
    if [ "$CLASH_RUNNING" = "false" ]; then
        print_error "Clash 进程未运行，请先启动服务"
        return 1
    fi
    
    if [ "$CLASH_API_OK" = "false" ]; then
        print_error "Clash API 无法访问"
        echo "可能的原因："
        echo "  • API 端口配置错误（当前：$CLASH_API_URL）"
        echo "  • 防火墙阻止了 API 端口"
        echo "  • Clash 正在启动中，请稍后再试"
        echo "  • 配置文件中未启用 external-controller"
        echo ""
        echo "建议："
        echo "  1. 检查配置文件中的 external-controller 设置"
        echo "  2. 确认 API 端口未被占用"
        echo "  3. 查看 Clash 日志了解详细信息"
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
        
        # 获取代理模式
        local proxy_mode=$(get_proxy_mode)
        echo "  代理模式: $proxy_mode"
        
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
    
    # 获取代理模式
    local proxy_mode=""
    if [ "$CLASH_API_OK" = "true" ]; then
        proxy_mode=$(get_proxy_mode)
        if [ -n "$proxy_mode" ] && [ "$proxy_mode" != "Unknown" ]; then
            proxy_mode=" | 模式: $proxy_mode"
        else
            proxy_mode=""
        fi
    fi
    
    echo -e "当前状态: $status_icon $status_text | 版本: $(get_current_version)$proxy_mode"
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
    echo "  12) 订阅管理"
    echo "  13) 节点切换"
    echo "  14) 模式切换"
    echo "  15) 立即自毁"
    echo "  16) 卸载 Clash"
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

# 订阅下载功能（内置）
download_subscription() {
    local url="$1"
    local output="${2:-$CONFIG_DIR/config.yaml}"
    local temp_file="${output}.tmp"
    
    print_info "下载订阅配置..."
    print_info "URL: $url"
    
    # 创建必要的目录
    mkdir -p "$(dirname "$output")"
    mkdir -p "$BACKUP_DIR"
    
    # 备份当前配置
    if [ -f "$output" ]; then
        local backup_name="config_$(date +%Y%m%d_%H%M%S).yaml"
        cp "$output" "$BACKUP_DIR/$backup_name"
        print_info "已备份当前配置到: $backup_name"
    fi
    
    # 下载配置
    local http_code=$(curl -w "%{http_code}" -sL \
        -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
        -H "Accept: text/plain, application/yaml, application/x-yaml, text/yaml, */*" \
        -o "$temp_file" \
        "$url" 2>/dev/null)
    
    # 检查 HTTP 状态码
    if [[ "$http_code" -ne 200 ]]; then
        print_error "下载失败，HTTP 状态码: $http_code"
        rm -f "$temp_file"
        return 1
    fi
    
    # 检查文件是否存在且不为空
    if [[ ! -s "$temp_file" ]]; then
        print_error "下载的文件为空"
        rm -f "$temp_file"
        return 1
    fi
    
    # 获取文件大小
    local file_size=$(stat -c%s "$temp_file" 2>/dev/null || stat -f%z "$temp_file" 2>/dev/null || echo 0)
    print_info "文件大小: $((file_size / 1024)) KB"
    
    # 检查是否为错误页面
    local first_line=$(head -1 "$temp_file" | tr -d '\r\n' | tr -d ' ')
    if [[ "$first_line" =~ ^\<\!DOCTYPE ]] || [[ "$first_line" =~ ^\<html ]]; then
        print_error "获取到的是 HTML 页面而不是配置文件"
        print_info "可能原因："
        print_info "1. 订阅链接错误"
        print_info "2. 需要认证或被防火墙阻止"
        print_info "3. 订阅已过期"
        rm -f "$temp_file"
        return 1
    fi
    
    # 检查是否为有效的 YAML 格式（简单检查）
    if ! grep -q "^\(proxies\|rules\|proxy-groups\|port\|socks-port\|mixed-port\):" "$temp_file"; then
        print_warning "文件可能不是有效的 Clash 配置格式"
        print_info "将继续保存，但可能需要手动检查"
    fi
    
    # 移动到目标位置
    mv "$temp_file" "$output"
    
    # 设置文件权限
    chmod 600 "$output"
    
    print_success "订阅下载成功！"
    
    # 显示配置摘要
    echo ""
    print_info "配置摘要："
    
    # 统计节点数量
    local proxy_count=$(grep -c "^[[:space:]]*- name:" "$output" 2>/dev/null || echo 0)
    print_info "代理节点数: $proxy_count"
    
    # 显示端口配置
    local mixed_port=$(grep "^mixed-port:" "$output" 2>/dev/null | awk '{print $2}' || echo "")
    local http_port=$(grep "^port:" "$output" 2>/dev/null | awk '{print $2}' || echo "")
    local socks_port=$(grep "^socks-port:" "$output" 2>/dev/null | awk '{print $2}' || echo "")
    
    [[ -n "$mixed_port" ]] && print_info "混合端口: $mixed_port"
    [[ -n "$http_port" ]] && print_info "HTTP 端口: $http_port"
    [[ -n "$socks_port" ]] && print_info "SOCKS 端口: $socks_port"
    
    # 保留最近10个备份
    local backup_count=$(ls -1 "$BACKUP_DIR"/config_*.yaml 2>/dev/null | wc -l)
    if [ $backup_count -gt 10 ]; then
        ls -1t "$BACKUP_DIR"/config_*.yaml | tail -n +11 | xargs rm -f
        print_info "清理旧备份，保留最近10个"
    fi
    
    return 0
}

# 订阅管理
manage_subscription() {
    print_header "订阅管理"
    
    echo "1) 更新订阅（从链接）"
    echo "2) 导入订阅（从文件）"
    echo "3) 使用示例配置"
    echo "4) 备份当前配置"
    echo "5) 恢复备份配置"
    echo "0) 返回"
    echo ""
    
    read -p "请选择 [0-5]: " sub_choice
    
    case $sub_choice in
        1)
            echo ""
            print_info "请输入订阅链接"
            print_info "示例: https://example.com/clash?token=xxx&flag=true"
            echo ""
            read -p "订阅链接: " sub_url
            if [ -z "$sub_url" ]; then
                print_error "订阅链接不能为空"
                return 1
            fi
            
            # 使用内置下载功能
            print_step "下载订阅配置..."
            if download_subscription "$sub_url"; then
                print_success "订阅更新成功！"
                
                # 询问是否重启服务
                check_clash_status
                if [ "$CLASH_RUNNING" = "true" ]; then
                    read -p "是否重启服务以应用新配置？[Y/n]: " restart_confirm
                    if [[ ! $restart_confirm =~ ^[Nn]$ ]]; then
                        stop_clash_service
                        sleep 2
                        start_clash_service
                    fi
                fi
            else
                print_error "订阅下载失败"
                print_info "请检查："
                print_info "1. 订阅链接是否正确"
                print_info "2. 网络连接是否正常"
                print_info "3. 订阅是否需要代理访问"
            fi
            ;;
            
        2)
            read -p "请输入配置文件路径: " config_file
            if [ ! -f "$config_file" ]; then
                print_error "文件不存在: $config_file"
                return 1
            fi
            
            print_step "导入配置文件..."
            
            # 备份当前配置
            if [ -f "$CONFIG_DIR/config.yaml" ]; then
                local backup_name="config_$(date +%Y%m%d_%H%M%S).yaml"
                cp "$CONFIG_DIR/config.yaml" "$BACKUP_DIR/$backup_name"
                print_info "已备份当前配置"
            fi
            
            # 复制新配置
            cp "$config_file" "$CONFIG_DIR/config.yaml"
            
            # 验证配置
            if command -v clash &> /dev/null; then
                if clash -t -f "$CONFIG_DIR/config.yaml" &>/dev/null; then
                    print_success "配置导入成功并验证通过！"
                else
                    print_warning "配置已导入但验证失败，请检查配置格式"
                fi
            else
                print_success "配置导入成功！"
            fi
            
            # 询问是否重启服务
            check_clash_status
            if [ "$CLASH_RUNNING" = "true" ]; then
                read -p "是否重启服务以应用新配置？[Y/n]: " restart_confirm
                if [[ ! $restart_confirm =~ ^[Nn]$ ]]; then
                    stop_clash_service
                    sleep 2
                    start_clash_service
                fi
            fi
            ;;
            
        3)
            print_step "生成示例配置..."
            cat > "$CONFIG_DIR/config.yaml" << 'EOF'
# Clash 示例配置
mixed-port: 7890
socks-port: 7891
allow-lan: false
mode: rule
log-level: info
external-controller: 127.0.0.1:9090

dns:
  enable: true
  nameserver:
    - 223.5.5.5
    - 114.114.114.114

proxies:
  - name: "示例节点-香港"
    type: ss
    server: hk.example.com
    port: 8388
    cipher: aes-256-gcm
    password: "password123"
    
  - name: "示例节点-日本"
    type: vmess
    server: jp.example.com
    port: 443
    uuid: a3482e88-686a-4a58-8126-99c9df64b7bf
    alterId: 0
    cipher: auto
    tls: true

proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - "示例节点-香港"
      - "示例节点-日本"
      - DIRECT

rules:
  - DOMAIN-SUFFIX,google.com,Proxy
  - DOMAIN-SUFFIX,github.com,Proxy
  - GEOIP,CN,DIRECT
  - MATCH,Proxy
EOF
            print_success "示例配置已生成！"
            print_warning "请编辑配置文件，替换为真实的节点信息"
            ;;
            
        4)
            if [ -f "$CONFIG_DIR/config.yaml" ]; then
                local backup_name="config_$(date +%Y%m%d_%H%M%S).yaml"
                cp "$CONFIG_DIR/config.yaml" "$BACKUP_DIR/$backup_name"
                print_success "配置已备份到: $BACKUP_DIR/$backup_name"
            else
                print_warning "当前没有配置文件"
            fi
            ;;
            
        5)
            if [ -d "$BACKUP_DIR" ] && [ "$(ls -A "$BACKUP_DIR"/*.yaml 2>/dev/null | wc -l)" -gt 0 ]; then
                echo "可用的备份配置："
                ls -1t "$BACKUP_DIR"/*.yaml 2>/dev/null | head -10 | nl
                echo ""
                read -p "请选择要恢复的备份编号: " backup_num
                
                if [[ "$backup_num" =~ ^[0-9]+$ ]]; then
                    local backup_file=$(ls -1t "$BACKUP_DIR"/*.yaml 2>/dev/null | sed -n "${backup_num}p")
                    if [ -f "$backup_file" ]; then
                        cp "$backup_file" "$CONFIG_DIR/config.yaml"
                        print_success "配置已恢复！"
                        
                        # 询问是否重启服务
                        check_clash_status
                        if [ "$CLASH_RUNNING" = "true" ]; then
                            read -p "是否重启服务以应用新配置？[Y/n]: " restart_confirm
                            if [[ ! $restart_confirm =~ ^[Nn]$ ]]; then
                                stop_clash_service
                                sleep 2
                                start_clash_service
                            fi
                        fi
                    else
                        print_error "无效的备份文件"
                    fi
                else
                    print_error "无效的选择"
                fi
            else
                print_warning "没有可用的备份配置"
            fi
            ;;
            
        0)
            return 0
            ;;
            
        *)
            print_warning "无效选择"
            ;;
    esac
}

# 节点切换功能（优化版）
switch_proxy() {
    print_header "节点切换"
    
    # 检查服务状态
    check_clash_status
    if [ "$CLASH_API_OK" != "true" ]; then
        print_error "Clash API 未响应，请先启动服务"
        return 1
    fi
    
    # 检查是否有增强版脚本
    local enhanced_script="$(dirname "$0")/switch_proxy_enhanced.sh"
    if [ -f "$enhanced_script" ] && [ -x "$enhanced_script" ]; then
        # 使用增强版
        "$enhanced_script"
        return
    fi
    
    # 获取所有代理组
    print_step "获取代理组列表..."
    local proxy_groups=$(curl -s -H "$CURL_AUTH" "$API_URL/proxies" 2>/dev/null)

    if [ -z "$proxy_groups" ]; then
        print_error "无法获取代理组信息"
        return 1
    fi
    
    # 检查是否安装了 jq
    if ! command -v jq >/dev/null 2>&1; then
        print_warning "未安装 jq，使用简化显示模式"
        echo ""
        echo "代理组列表："
        echo "$proxy_groups" | grep -o '"name":"[^"]*"' | sed 's/"name":"//g' | sed 's/"//g' | grep -E "(Proxy|Select|Auto|Fallback|LoadBalance|URLTest)" | nl
        echo ""
        print_info "建议安装 jq 以获得更好的体验："
        print_info "  Ubuntu/Debian: sudo apt-get install jq"
        print_info "  CentOS/RHEL: sudo yum install jq"
        return 1
    fi
    
    # 获取所有选择器类型的代理组
    local selectors=$(echo "$proxy_groups" | jq -r '.proxies | to_entries[] | select(.value.type == "Selector") | .key')
    
    if [ -z "$selectors" ]; then
        print_warning "没有找到可选择的代理组"
        return 1
    fi
    
    # 显示代理组列表
    echo ""
    echo "可切换的代理组："
    echo "===================="
    
    # 正确处理代理组列表
    local IFS=$'\n'
    local groups=($(echo "$selectors"))
    unset IFS
    
    local i=1
    for group in "${groups[@]}"; do
        # 获取当前选中的节点
        local current=$(echo "$proxy_groups" | jq -r ".proxies[\"$group\"].now // \"N/A\"")
        echo "$i) $group"
        echo "   当前节点: $current"
        echo ""
        i=$((i + 1))
    done
    
    echo "0) 返回"
    echo ""
    
    # 选择代理组
    read -p "请选择代理组 [0-$((i-1))]: " group_choice
    
    if [ "$group_choice" = "0" ]; then
        return 0
    fi
    
    if [ "$group_choice" -lt 1 ] || [ "$group_choice" -gt "${#groups[@]}" ]; then
        print_error "无效的选择"
        return 1
    fi
    
    local selected_group="${groups[$((group_choice-1))]}"
    
    # 获取该代理组的所有节点
    print_step "获取节点列表..."
    local nodes=$(echo "$proxy_groups" | jq -r ".proxies[\"$selected_group\"].all[]?" 2>/dev/null)
    
    # 如果 all 字段不存在，尝试其他方式
    if [ -z "$nodes" ]; then
        # 尝试从 proxies 字段获取
        nodes=$(echo "$proxy_groups" | jq -r ".proxies[\"$selected_group\"].proxies[]?" 2>/dev/null)
    fi
    
    if [ -z "$nodes" ]; then
        print_error "无法获取节点列表"
        print_info "提示：请检查代理组类型是否为 select"
        return 1
    fi
    
    # 显示节点列表（分页显示）
    echo ""
    echo "代理组: ${CYAN}$selected_group${NC}"
    
    # 正确处理节点列表，保留完整的节点名称
    local IFS=$'\n'
    local node_array=($(echo "$nodes"))
    unset IFS
    
    local total_nodes=${#node_array[@]}
    local current_node=$(echo "$proxy_groups" | jq -r ".proxies[\"$selected_group\"].now // \"\"")
    
    echo "节点总数: ${GREEN}$total_nodes${NC}"
    echo ""
    
    # 如果节点太多，使用分页
    local page_size="$PAGE_SIZE"
    local current_page=0
    local total_pages=$(( (total_nodes + page_size - 1) / page_size ))
    
    while true; do
        echo ""
        if [ $total_nodes -gt $page_size ]; then
            echo "节点列表 (第 ${CYAN}$((current_page + 1))${NC} 页，共 ${CYAN}$total_pages${NC} 页)："
        else
            echo "可用节点："
        fi
        echo "=========================================="
        
        local start=$((current_page * page_size))
        local end=$((start + page_size))
        if [ $end -gt $total_nodes ]; then
            end=$total_nodes
        fi
        
        # 显示当前页的节点
        for ((i=start; i<end; i++)); do
            local node="${node_array[$i]}"
            local display_num=$((i + 1))
            local mark=""
            
            if [ "$node" = "$current_node" ]; then
                mark="${GREEN} ← 当前${NC}"
            fi
            
            # 获取节点延迟信息
            local delay=$(echo "$proxy_groups" | jq -r ".proxies[\"$node\"].history[-1].delay // \"N/A\"" 2>/dev/null)
            local delay_display=""
            local delay_color=""
            
            if [ "$delay" != "N/A" ] && [ "$delay" != "null" ] && [ "$delay" != "" ]; then
                # 分离颜色和显示文本
                if [ "$delay" -lt "${DELAY_EXCELLENT:-100}" ]; then
                    delay_color="$GREEN"
                elif [ "$delay" -lt "${DELAY_GOOD:-300}" ]; then
                    delay_color="$RED"
                else
                    delay_color="$YELLOW"
                fi
                delay_display="${delay}ms"
            else
                delay_color="$CYAN"
                delay_display="未测试"
            fi
            
            # 获取节点类型
            local node_type=$(echo "$proxy_groups" | jq -r ".proxies[\"$node\"].type // \"Unknown\"" 2>/dev/null)
            if [ "$node_type" = "null" ] || [ -z "$node_type" ]; then
                node_type="Unknown"
            fi
            
            # 缩短过长的节点名
            local short_name="$node"
            if [ ${#node} -gt 35 ]; then
                short_name="${node:0:32}..."
            fi
            
            # 使用 echo -e 来正确解释颜色代码
            printf "%3d) %-35s [%-8s] " "$display_num" "$short_name" "$node_type"
            echo -e "${delay_color}${delay_display}${NC}${mark}"
        done
        
        echo "=========================================="
        echo ""
        
        # 分页控制选项
        if [ $total_nodes -gt $page_size ]; then
            echo "N) 下一页  P) 上一页  S) 搜索节点"
        fi
        echo "T) 测试所有  F) 快速测试(<500ms)  1-$total_nodes) 选择节点  0) 返回"
        echo ""
        
        read -p "请输入选择: " choice
        
        case "${choice,,}" in
            n)  # 下一页
                if [ $((current_page + 1)) -lt $total_pages ]; then
                    current_page=$((current_page + 1))
                else
                    print_warning "已经是最后一页"
                fi
                continue
                ;;
            p)  # 上一页
                if [ $current_page -gt 0 ]; then
                    ((current_page--))
                else
                    print_warning "已经是第一页"
                fi
                continue
                ;;
            s)  # 搜索节点
                echo ""
                read -p "输入搜索关键词: " keyword
                if [ -n "$keyword" ]; then
                    local found=false
                    echo ""
                    echo "搜索结果："
                    for i in "${!node_array[@]}"; do
                        if [[ "${node_array[$i],,}" == *"${keyword,,}"* ]]; then
                            echo "$((i+1))) ${node_array[$i]}"
                            found=true
                        fi
                    done
                    if [ "$found" = "false" ]; then
                        print_warning "没有找到匹配的节点"
                    fi
                    echo ""
                    read -p "按回车继续..."
                fi
                continue
                ;;
            t)  # 跳转到测试
                node_choice="T"
                break
                ;;
            f)  # 快速测试
                node_choice="F"
                break
                ;;
            0)  # 返回
                return 0
                ;;
            *)  # 数字选择
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$total_nodes" ]; then
                    node_choice="$choice"
                    break
                else
                    print_error "无效的选择"
                    sleep 1
                fi
                ;;
        esac
    done
    
    # 快速测试（只测试 <500ms 的节点）
    if [ "$node_choice" = "F" ] || [ "$node_choice" = "f" ]; then
        print_step "快速测试模式（只显示延迟 <500ms 的节点）"
        echo ""
        
        # 检查是否有快速测试脚本
        local fast_test_script="$(dirname "$0")/fast_test.sh"
        if [ -f "$fast_test_script" ] && [ -x "$fast_test_script" ]; then
            "$fast_test_script"
        else
            # 内置快速测试
            local max_delay=500
            local quick_timeout=2000
            local test_results=()
            
            print_info "筛选延迟 <${max_delay}ms 的节点..."
            echo ""
            
            # 创建临时目录
            local temp_dir=$(mktemp -d)
            
            # 并发快速测试
            local count=0
            for i in "${!node_array[@]}"; do
                local node="${node_array[$i]}"
                
                # 控制并发
                while [ $(jobs -r 2>/dev/null | wc -l) -ge 20 ]; do
                    sleep 0.02
                done
                
                # 后台测试
                (
                    # 在子shell中禁用错误退出
                    set +e
                    local encoded_name=$(printf '%s' "$node" | jq -sRr @uri)
                    local result=$(timeout 3 curl -s -H "$CURL_AUTH" \
                        "$API_URL/proxies/$encoded_name/delay" \
                        -X GET \
                        -G --data-urlencode "timeout=$quick_timeout" \
                        --data-urlencode "url=$TEST_URL" \
                        2>/dev/null)
                    
                    if [ -n "$result" ]; then
                        local delay=$(echo "$result" | jq -r '.delay // ""' 2>/dev/null)
                        if [ -n "$delay" ] && [ "$delay" != "null" ] && [ "$delay" -lt "$max_delay" ]; then
                            echo "$i|$node|$delay" > "$temp_dir/fast_$i"
                        fi
                    fi
                ) &
                
                count=$((count + 1))
                printf "\r测试进度: %d/%d" "$count" "${#node_array[@]}"
            done
            
            # 等待完成
            wait
            echo -e "\n"
            
            # 收集并排序结果
            local fast_results=()
            for ((i=0; i<${#node_array[@]}; i++)); do
                if [ -f "$temp_dir/fast_$i" ]; then
                    fast_results+=("$(cat "$temp_dir/fast_$i")")
                fi
            done
            
            if [ ${#fast_results[@]} -gt 0 ]; then
                echo "快速节点（延迟 <${max_delay}ms）："
                echo "----------------------------------------"
                
                # 排序并显示
                IFS=$'\n' sorted=($(printf '%s\n' "${fast_results[@]}" | sort -t'|' -k3 -n))
                for result in "${sorted[@]}"; do
                    IFS='|' read -r idx node delay <<< "$result"
                    
                    # 格式化显示
                    local short_name="$node"
                    if [ ${#node} -gt 40 ]; then
                        short_name="${node:0:37}..."
                    fi
                    
                    local color=""
                    if [ "$delay" -lt 100 ]; then
                        color=$GREEN
                    elif [ "$delay" -lt 300 ]; then
                        color=$YELLOW
                    else
                        color=$NC
                    fi
                    
                    printf "%-40s " "${short_name}:"
                    echo -e "${color}${delay}ms ✓${NC}"
                done
                echo "----------------------------------------"
                echo ""
                print_success "找到 ${#fast_results[@]} 个快速节点"
            else
                print_warning "没有找到延迟低于 ${max_delay}ms 的节点"
            fi
        fi
        
        # 清理临时目录
        rm -rf "$temp_dir"
        
        echo ""
        read -p "按回车继续..."
        switch_proxy
        return
    fi
    
    # 测试延迟（全部节点）
    if [ "$node_choice" = "T" ] || [ "$node_choice" = "t" ]; then
        print_step "批量测试节点延迟（方式同 Clash Verge Rev）"
        echo ""
        
        # 并发测试优化（使用配置文件设置）
        local test_url="$TEST_URL"
        local timeout="$TEST_TIMEOUT"
        local max_concurrent="$MAX_CONCURRENT"
        local test_count=0
        # 防止算术运算导致脚本退出
        set +e
        local total_nodes=${#node_array[@]}
        
        print_info "测试 URL: $test_url"
        print_info "超时时间: ${timeout}ms"
        print_info "开始测试 $total_nodes 个节点..."
        echo ""
        
        # 创建临时文件存储结果
        local temp_dir=$(mktemp -d)
        
        # 确保临时目录创建成功
        if [ ! -d "$temp_dir" ]; then
            print_error "无法创建临时目录"
            return 1
        fi
        
        # 批量发起测试
        for i in "${!node_array[@]}"; do
            local node="${node_array[$i]}"
            
            # 控制并发数
            while [ $(jobs -r 2>/dev/null | wc -l) -ge $max_concurrent ]; do
                sleep 0.05
            done
            
            # 后台执行测试
            (
                # 在子shell中禁用错误退出
                set +e
                local start_time=$(date +%s%3N)
                local test_result=$(curl -s -H "$CURL_AUTH" \
                    "$API_URL/proxies/$(printf '%s' "$node" | jq -sRr @uri)/delay" \
                    -X GET \
                    -G --data-urlencode "timeout=$timeout" \
                    --data-urlencode "url=$test_url" \
                    2>/dev/null)
                
                local end_time=$(date +%s%3N)
                
                if [ -n "$test_result" ]; then
                    local delay=$(echo "$test_result" | jq -r '.delay // ""' 2>/dev/null)
                    if [ -n "$delay" ] && [ "$delay" != "null" ]; then
                        echo "$i|$node|$delay|success" > "$temp_dir/result_$i"
                    else
                        echo "$i|$node|timeout|fail" > "$temp_dir/result_$i"
                    fi
                else
                    echo "$i|$node|error|fail" > "$temp_dir/result_$i"
                fi
            ) &
            
            test_count=$((test_count + 1))
            
            # 显示进度
            printf "\r测试进度: %d/%d" "$test_count" "$total_nodes"
        done
        
        # 等待所有测试完成
        wait
        echo -e "\n"
        
        # 收集并显示结果
        echo "测试结果："
        echo "----------------------------------------"
        
        # 排序并显示结果
        for ((i=0; i<total_nodes; i++)); do
            if [ -f "$temp_dir/result_$i" ]; then
                IFS='|' read -r idx node delay status < "$temp_dir/result_$i"
                
                local display_num=$((idx + 1))
                local delay_display=""
                
                # 处理节点名称（避免过长）
                local short_name="$node"
                if [ ${#node} -gt 40 ]; then
                    short_name="${node:0:37}..."
                fi
                
                if [ "$status" = "success" ]; then
                    if [ "$delay" -lt "${DELAY_EXCELLENT:-100}" ]; then
                        delay_display="${GREEN}${delay}ms ✓${NC}"
                    elif [ "$delay" -lt "${DELAY_GOOD:-300}" ]; then
                        delay_display="${YELLOW}${delay}ms ✓${NC}"
                    else
                        delay_display="${RED}${delay}ms ✓${NC}"
                    fi
                elif [ "$delay" = "timeout" ]; then
                    delay_display="${RED}超时 ✗${NC}"
                else
                    delay_display="${RED}错误 ✗${NC}"
                fi
                
                # 标记当前节点
                local mark=""
                if [ "$node" = "$current_node" ]; then
                    mark="${GREEN} ← 当前${NC}"
                fi
                
                # 格式化输出（与 Clash Verge Rev 一致）
                printf "%-40s %s%s\n" "$short_name:" "$delay_display" "$mark"
            fi
        done
        
        echo "----------------------------------------"
        
        # 统计信息
        local success_count=$(find "$temp_dir" -name "result_*" -exec grep -l "success" {} \; | wc -l)
        local fail_count=$((total_nodes - success_count))
        
        echo ""
        print_info "测试完成："
        echo "  成功: $success_count 个节点"
        echo "  失败: $fail_count 个节点"
        
        # 清理临时文件
        rm -rf "$temp_dir"
        
        # 恢复错误退出设置
        set -e
        
        echo ""
        read -p "按回车继续选择节点..."
        switch_proxy
        return
    fi
    
    if [ "$node_choice" -lt 1 ] || [ "$node_choice" -gt "${#node_array[@]}" ]; then
        print_error "无效的选择"
        return 1
    fi
    
    local selected_node="${node_array[$((node_choice-1))]}"
    
    # 切换节点
    print_step "切换到节点: $selected_node"
    
    local switch_result=$(curl -s -H "$CURL_AUTH" \
        -X PUT \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"$selected_node\"}" \
        "$API_URL/proxies/$selected_group" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        print_success "节点切换成功！"
        
        # 显示新的状态
        echo ""
        echo "当前配置："
        echo "  代理组: $selected_group"
        echo "  节点: $selected_node"
        
        # 测试新节点
        echo ""
        read -p "是否测试新节点连接？[Y/n]: " test_confirm
        if [[ ! $test_confirm =~ ^[Nn]$ ]]; then
            print_step "测试代理连接..."
            
            # 使用代理测试连接
            local test_url="https://www.google.com"
            local proxy_port=$(grep -E "^(mixed-port|port):" "$CONFIG_DIR/config.yaml" 2>/dev/null | head -1 | awk '{print $2}' || echo "7890")
            
            if curl -s -x "http://127.0.0.1:$proxy_port" --connect-timeout 10 "$test_url" >/dev/null 2>&1; then
                print_success "代理连接正常！"
            else
                print_warning "代理连接测试失败，请检查节点状态"
            fi
        fi
    else
        print_error "节点切换失败"
        return 1
    fi
}

# 代理模式切换
switch_proxy_mode() {
    print_header "代理模式切换"
    
    # 检查API状态
    check_clash_status
    if [ "$CLASH_API_OK" != "true" ]; then
        print_error "Clash 未运行或 API 不可用"
        return 1
    fi
    
    # 获取API密钥
    get_api_secret
    
    # 获取当前模式
    local current_mode=$(get_proxy_mode)
    echo -e "当前模式: ${GREEN}$current_mode${NC}"
    echo ""
    
    echo "选择代理模式:"
    echo "  1) Rule (规则模式) - 根据规则判断走代理或直连"
    echo "  2) Global (全局模式) - 所有流量走代理"
    echo "  3) Direct (直连模式) - 所有流量直连"
    echo "  0) 返回"
    echo ""
    
    read -p "请选择 [0-3]: " mode_choice
    
    local new_mode=""
    case $mode_choice in
        1)
            new_mode="rule"
            ;;
        2)
            new_mode="global"
            ;;
        3)
            new_mode="direct"
            ;;
        0)
            return
            ;;
        *)
            print_error "无效选择"
            return 1
            ;;
    esac
    
    # 切换模式
    print_step "切换到 $new_mode 模式..."
    
    local result=$(curl -s -H "$CURL_AUTH" \
        -X PATCH \
        -H "Content-Type: application/json" \
        -d "{\"mode\":\"$new_mode\"}" \
        "$API_URL/configs" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        print_success "模式切换成功！"
        
        # 验证切换结果
        sleep 1
        local verify_mode=$(get_proxy_mode)
        echo ""
        echo "当前模式: ${GREEN}$verify_mode${NC}"
        
        # 显示模式说明
        echo ""
        case "$new_mode" in
            "rule")
                echo "规则模式: 根据配置文件中的规则判断走代理或直连"
                ;;
            "global")
                echo "全局模式: 所有流量都通过代理服务器"
                ;;
            "direct")
                echo "直连模式: 所有流量都直接连接，不使用代理"
                ;;
        esac
    else
        print_error "模式切换失败"
        return 1
    fi
}

# 立即执行自毁
execute_immediate_destruct() {
    print_warning "开始执行自毁程序..."
    sleep 2
    
    print_step "停止 Clash 进程..."
    # 只停止 clash 和 mihomo 二进制程序（精确匹配）
    pkill -x clash 2>/dev/null || true
    pkill -x mihomo 2>/dev/null || true
    
    print_step "清理 tmux 会话..."
    tmux kill-session -t "$SERVICE_SESSION" 2>/dev/null || true
    tmux kill-session -t "$DEBUG_SESSION" 2>/dev/null || true
    
    print_step "删除二进制文件..."
    sudo rm -f /usr/local/bin/clash /usr/local/bin/mihomo 2>/dev/null || true
    rm -f "$HOME/.local/bin/clash" "$HOME/.local/bin/mihomo" 2>/dev/null || true
    
    print_step "删除配置和数据..."
    rm -rf "$CONFIG_DIR" "$HOME/.config/clash" 2>/dev/null || true
    sudo rm -rf /etc/clash /etc/mihomo 2>/dev/null || true
    
    print_step "清理系统服务..."
    sudo systemctl stop clash mihomo 2>/dev/null || true
    sudo systemctl disable clash mihomo 2>/dev/null || true
    sudo rm -f /etc/systemd/system/clash.service /etc/systemd/system/mihomo.service 2>/dev/null || true
    sudo systemctl daemon-reload 2>/dev/null || true
    
    print_step "清理日志和缓存..."
    rm -rf /var/log/clash* /var/log/mihomo* 2>/dev/null || true
    rm -rf "$HOME/.cache/clash" "$HOME/.cache/mihomo" 2>/dev/null || true
    
    print_step "清理备份文件..."
    rm -rf "$BACKUP_DIR" 2>/dev/null || true
    
    print_step "清理 crontab..."
    # 只删除包含 clash_self_destruct 的条目（这个脚本创建的）
    crontab -l 2>/dev/null | grep -v "clash_self_destruct" | crontab - 2>/dev/null || true
    
    # 获取脚本所在目录（解析符号链接）
    local script_path="$(readlink -f "$0")"
    local script_dir="$(dirname "$script_path")"
    local script_name="$(basename "$script_path")"
    
    print_step "即将删除脚本目录: $script_dir"
    
    # 创建临时脚本来删除整个目录
    local temp_script="/tmp/clash_final_destruct_$$.sh"
    cat > "$temp_script" << EOF
#!/bin/bash
# 等待主脚本进程结束
sleep 3

# 确保主脚本已经退出
while pgrep -f "$script_name" > /dev/null 2>&1; do
    sleep 1
done

# 再等待一下确保文件句柄释放
sleep 2

# 强制删除整个脚本目录
if [ -d "$script_dir" ]; then
    rm -rf "$script_dir" 2>/dev/null || {
        # 如果失败，尝试先切换到其他目录
        cd /tmp
        rm -rf "$script_dir" 2>/dev/null || {
            # 最后尝试使用 find 删除
            find "$script_dir" -type f -exec rm -f {} \; 2>/dev/null
            find "$script_dir" -type d -empty -delete 2>/dev/null
            rmdir "$script_dir" 2>/dev/null || true
        }
    }
fi

# 记录结果
if [ ! -d "$script_dir" ]; then
    echo "[$(date)] 成功删除脚本目录: $script_dir" >> /tmp/clash_destruct.log
else
    echo "[$(date)] 警告：无法完全删除脚本目录: $script_dir" >> /tmp/clash_destruct.log
    echo "[$(date)] 剩余内容：" >> /tmp/clash_destruct.log
    ls -la "$script_dir" >> /tmp/clash_destruct.log 2>&1
fi

# 删除临时脚本自己
rm -f "$temp_script"
EOF
    
    chmod +x "$temp_script"
    
    print_success "自毁程序已启动！"
    echo "[$(date)] 自毁程序已启动，目标目录: $script_dir" >> /tmp/clash_destruct.log
    
    # 使用 setsid 在新会话中执行，确保与当前进程分离
    setsid bash "$temp_script" </dev/null >/dev/null 2>&1 &
    
    # 给用户一些反馈
    echo ""
    print_info "脚本目录将在程序退出后被删除"
    print_info "查看日志: cat /tmp/clash_destruct.log"
    
    # 退出主脚本
    exit 0
}

# 立即自毁功能
self_destruct() {
    print_header "立即自毁"
    
    echo -e "${RED}⚠️  警告：此功能将立即删除 Clash 及所有相关文件！${NC}"
    echo ""
    echo "自毁内容包括："
    echo "  • 停止所有 Clash 进程"
    echo "  • 删除所有配置文件"
    echo "  • 删除所有二进制文件"
    echo "  • 删除整个脚本目录"
    echo "  • 清理所有日志和缓存"
    echo ""
    echo -e "${RED}此操作不可逆！整个脚本目录将被完全删除！${NC}"
    echo ""
    
    read -p "确认要立即执行自毁？[y/N]: " confirm1
    if [[ ! $confirm1 =~ ^[Yy]$ ]]; then
        print_info "已取消自毁"
        return
    fi
    
    echo ""
    echo -e "${RED}最后警告：这将删除所有 Clash 相关文件！${NC}"
    read -p "请输入 'DESTROY' 确认执行自毁: " confirm2
    if [[ "$confirm2" != "DESTROY" ]]; then
        print_info "已取消自毁"
        return
    fi
    
    echo ""
    execute_immediate_destruct
}

# 卸载 Clash
uninstall_clash() {
    print_header "卸载 Clash"
    
    echo -e "${YELLOW}此操作将：${NC}"
    echo "  • 停止 Clash 服务"
    echo "  • 删除 Clash 二进制文件"
    echo "  • 删除配置文件和数据"
    echo "  • 清理所有相关会话"
    echo ""
    echo -e "${RED}警告：此操作不可逆！${NC}"
    echo ""
    
    read -p "确认要完全卸载 Clash？[y/N]: " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        print_info "已取消卸载"
        return 0
    fi
    
    # 二次确认
    read -p "请再次确认，输入 'UNINSTALL' 继续: " second_confirm
    if [[ "$second_confirm" != "UNINSTALL" ]]; then
        print_info "已取消卸载"
        return 0
    fi
    
    print_step "开始卸载..."
    
    # 1. 停止服务
    print_step "停止 Clash 服务..."
    stop_clash_service
    
    # 2. 清理所有会话
    print_step "清理所有会话..."
    cleanup_all
    
    # 3. 删除二进制文件
    print_step "删除 Clash 二进制文件..."
    local binary_locations=(
        "/usr/local/bin/clash"
        "/usr/bin/clash"
        "$HOME/.local/bin/clash"
    )
    
    for binary in "${binary_locations[@]}"; do
        if [ -f "$binary" ]; then
            if [ -w "$(dirname "$binary")" ]; then
                rm -f "$binary"
                print_info "已删除: $binary"
            else
                sudo rm -f "$binary"
                print_info "已删除: $binary (使用 sudo)"
            fi
        fi
    done
    
    # 4. 询问是否删除配置文件
    echo ""
    read -p "是否删除配置文件和数据？[y/N]: " delete_config
    if [[ $delete_config =~ ^[Yy]$ ]]; then
        print_step "删除配置文件..."
        
        # 备份重要配置
        if [ -f "$CONFIG_DIR/config.yaml" ]; then
            local backup_file="$HOME/clash_config_backup_$(date +%Y%m%d_%H%M%S).yaml"
            cp "$CONFIG_DIR/config.yaml" "$backup_file"
            print_info "配置文件已备份到: $backup_file"
        fi
        
        # 删除配置目录
        if [ -d "$CONFIG_DIR" ]; then
            rm -rf "$CONFIG_DIR"
            print_info "已删除配置目录: $CONFIG_DIR"
        fi
        
        # 删除旧配置目录（如果存在）
        if [ -d "$HOME/.config/clash" ]; then
            rm -rf "$HOME/.config/clash"
            print_info "已删除旧配置目录: $HOME/.config/clash"
        fi
    else
        print_info "保留配置文件"
    fi
    
    # 5. 清理系统服务（如果存在）
    if systemctl is-enabled clash &>/dev/null 2>&1; then
        print_step "删除系统服务..."
        sudo systemctl stop clash
        sudo systemctl disable clash
        sudo rm -f /etc/systemd/system/clash.service
        sudo systemctl daemon-reload
        print_info "已删除系统服务"
    fi
    
    # 6. 清理环境变量提示
    echo ""
    print_warning "如果您在 .bashrc 或 .zshrc 中设置了代理环境变量，请手动删除："
    echo "  export http_proxy=http://127.0.0.1:7890"
    echo "  export https_proxy=http://127.0.0.1:7890"
    echo "  export all_proxy=socks5://127.0.0.1:7891"
    
    echo ""
    print_success "Clash 已成功卸载！"
    
    # 询问是否删除管理脚本
    echo ""
    read -p "是否删除管理脚本？[y/N]: " delete_scripts
    if [[ $delete_scripts =~ ^[Yy]$ ]]; then
        print_info "管理脚本将在退出后自动删除"
        # 创建临时脚本来删除当前目录
        cat > /tmp/remove_clash_scripts.sh << EOF
#!/bin/bash
sleep 2
rm -rf "$(pwd)"
echo "管理脚本已删除"
rm -f /tmp/remove_clash_scripts.sh
EOF
        chmod +x /tmp/remove_clash_scripts.sh
        nohup /tmp/remove_clash_scripts.sh &>/dev/null &
        exit 0
    fi
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
                read -p "请选择 [0-16]: " choice
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
                    12)
                        manage_subscription
                        read -p "按回车继续..."
                        ;;
                    13)
                        switch_proxy
                        read -p "按回车继续..."
                        ;;
                    14)
                        switch_proxy_mode
                        read -p "按回车继续..."
                        ;;
                    15)
                        self_destruct
                        read -p "按回车继续..."
                        ;;
                    16)
                        uninstall_clash
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