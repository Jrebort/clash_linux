# Clash Pro Manager

增强版 Clash/mihomo 管理工具，支持内核下载、安装和更新。

## 功能特性

### 内核管理
- 自动检测系统架构（amd64, arm64, armv7, 386）
- 从 GitHub 下载最新 mihomo 内核
- 版本检查和更新提醒
- 自动备份旧版本

### 服务管理
- 启动/停止/重启 Clash 服务
- tmux 会话管理
- 服务状态监控

### 调试工具
- 分屏调试环境
- 实时日志查看
- API 交互终端

## 安装依赖

```bash
# Ubuntu/Debian
sudo apt install tmux curl wget jq tar gzip

# macOS
brew install tmux curl wget jq
```

## 快速开始

```bash
# 安装最新内核
./clash_manager.sh install

# 启动服务
./clash_manager.sh start

# 显示交互菜单
./clash_manager.sh
```

## 命令列表

- `install` - 下载并安装最新版本内核
- `update` - 检查内核更新
- `start` - 启动 Clash 服务
- `stop` - 停止 Clash 服务
- `restart` - 重启 Clash 服务
- `debug` - 创建调试环境
- `status` - 显示详细状态
- `logs` - 查看服务日志
- `cleanup` - 清理所有会话
- `menu` - 显示交互菜单（默认）

## 配置要求

- 配置文件：`~/.config/mihomo/config.yaml`
- 内核安装位置：`/usr/local/bin/clash`
- 备份目录：`~/.config/mihomo/backups/`

## 版本历史

- v4.0 - 新增内核下载和安装功能
- v3.1 - 原始版本（仅服务管理）