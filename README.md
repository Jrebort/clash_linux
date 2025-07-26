# Clash Manager

[![Version](https://img.shields.io/badge/version-0.1-blue.svg)](https://github.com/yourusername/clash-manager)
[![Shell](https://img.shields.io/badge/shell-bash-green.svg)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/license-MIT-yellow.svg)](LICENSE)

一个功能强大的 Clash/Mihomo 代理管理工具，支持一键安装、订阅管理、节点切换等功能。

## ✨ 特性

- 🚀 **一键安装** - 自动检测系统架构，下载并安装最新版 Mihomo 内核
- 📦 **订阅管理** - 支持订阅链接下载、配置导入、自动备份
- 🔄 **节点切换** - 智能分页显示、批量测速、快速筛选
- 🎯 **模式切换** - Rule/Global/Direct 模式一键切换
- 🛠️ **调试工具** - 集成 tmux 调试环境，实时查看日志
- 📊 **状态监控** - 实时显示服务状态、连接信息
- 🔒 **安全设计** - 配置文件权限保护、自动备份机制

## 📋 系统要求

- Linux 操作系统（支持 Ubuntu、Debian、CentOS 等）
- Bash 4.0 或更高版本
- 基础依赖：`curl`、`jq`、`tmux`

## 🚀 快速开始

### 1. 下载脚本

```bash
git clone https://github.com/yourusername/clash-manager.git
cd clash-manager
chmod +x clash_manager.sh
```

### 2. 首次使用

```bash
# 运行主程序
./clash_manager.sh

# 按以下顺序操作：
# 1. 选择 2 - 下载并安装最新版本
# 2. 选择 12 - 订阅管理（添加你的订阅链接）
# 3. 选择 4 - 启动Clash服务
```

### 3. 命令行模式

```bash
# 直接安装最新版本
./clash_manager.sh install

# 启动服务
./clash_manager.sh start

# 查看状态
./clash_manager.sh status

# 创建调试环境
./clash_manager.sh debug
```

## 📖 使用指南

### 订阅管理

支持多种订阅管理方式：

- **更新订阅**：直接输入订阅链接下载
- **导入配置**：从本地文件导入
- **自动备份**：每次更新自动备份，保留最近 10 个版本

```bash
# 选择 12 进入订阅管理
# 选择 1 输入订阅链接
# 系统会自动下载并验证配置文件
```

### 节点切换

增强的节点切换功能：

- **分页显示**：大量节点时自动分页
- **搜索功能**：按关键词快速查找节点
- **批量测速**：测试所有节点延迟
- **快速筛选**：只显示延迟 <500ms 的节点

```bash
# 选择 13 进入节点切换
# 使用以下快捷键：
# N/P - 翻页
# S - 搜索节点
# T - 测试所有节点
# F - 快速测试（<500ms）
```

### 调试模式

专业的 tmux 调试环境：

```bash
# 选择 7 创建调试环境
# 自动分屏显示：
# - 上方：交互终端
# - 下方：实时日志

# 快捷键：
# Ctrl+B ↑↓ - 切换窗格
# Ctrl+B z - 最大化当前窗格
# Ctrl+B d - 分离会话
```

## ⚙️ 配置文件

### clash_config.conf

可自定义的配置参数：

```bash
# API 配置
API_HOST="localhost"
API_PORT="9090"

# 测试配置
TEST_URL="http://www.gstatic.com/generate_204"
TEST_TIMEOUT="5000"

# 延迟颜色阈值（毫秒）
DELAY_EXCELLENT="100"  # 绿色
DELAY_GOOD="300"      # 黄色

# 分页设置
PAGE_SIZE="15"

# 并发设置
MAX_CONCURRENT="10"
```

## 🔧 高级功能

### 代理模式

- **Rule 模式**：根据规则自动分流（推荐）
- **Global 模式**：所有流量走代理
- **Direct 模式**：所有流量直连

### 自动化功能

- 配置文件自动备份
- 服务异常自动检测
- 镜像站自动切换

## ❓ 常见问题

### 1. 安装失败

检查网络连接，脚本会自动尝试多个镜像站：
- GitHub 官方
- ghproxy.com
- ghfast.top
- 其他备用镜像

### 2. 订阅下载失败

可能原因：
- 订阅链接错误或过期
- 需要代理才能访问（先启动服务）
- 订阅不是 Clash 格式

### 3. 节点切换无效

确保：
- Clash 服务正在运行
- 选择的是 Selector 类型的代理组
- 节点名称没有特殊字符

## 🛡️ 安全说明

- 配置文件权限自动设置为 600
- API 密钥自动从配置文件读取
- 支持安全的自毁功能（需要双重确认）

## 📝 更新日志

### v0.1 (2025-07-26)
- 初始版本发布
- 集成所有功能到单一脚本
- 优化节点测速算法
- 修复进程管理问题

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 许可证

本项目采用 MIT 许可证 - 查看 [LICENSE](LICENSE) 文件了解详情

## 🙏 致谢

- [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo) - 核心代理程序
- [Dreamacro/clash](https://github.com/Dreamacro/clash) - 原始 Clash 项目

---

**注意**：本工具仅供学习交流使用，请遵守当地法律法规。
