# Clash Linux Manager

一个功能强大的 Clash/Mihomo 代理管理工具集，提供多种实现方案。

## 🎯 项目特点

- 🚀 **多版本实现**：提供三个不同版本，满足不同需求
- 📦 **自动化管理**：内核下载、更新、服务管理一键完成
- 🔄 **订阅转换**：内置订阅转换功能，支持 SS/VMess/Trojan
- 🛠️ **零依赖版本**：纯 Shell 实现，无需 Python
- 🐳 **容器支持**：提供 Docker 测试环境

## 📁 文件说明

### 核心脚本

1. **clash_manager.sh** (v4.0)
   - 原始增强版管理工具
   - 强大的 tmux 调试环境
   - 适合开发和调试使用

2. **clash_pure_shell.sh** (v6.0-PURE) ⭐ 推荐
   - 纯 Shell 实现，无需 Python
   - 内置订阅转换功能
   - 适合生产环境部署

3. **clash_all_in_one.sh** (v5.0-AIO)
   - 集成版本，功能最全
   - 需要 Python3 支持
   - 适合功能要求全面的场景

### 文档

- **README.md** - 项目说明（本文件）
- **QUICK_START.md** - 快速开始指南
- **USER_GUIDE.md** - 详细使用指南
- **TEST_GUIDE.md** - 测试指南
- **security_analysis.md** - 安全分析报告

### 测试环境

- **Dockerfile** - Docker 测试环境
- **docker-compose.yml** - Docker Compose 配置

## 🚀 快速开始

### 推荐使用纯 Shell 版本

```bash
# 添加执行权限
chmod +x clash_pure_shell.sh

# 运行脚本
./clash_pure_shell.sh
```

首次运行会自动进入向导模式，引导你完成：
1. 安装 Clash 内核
2. 配置订阅
3. 启动服务

### 设置代理

```bash
# 临时设置（当前终端）
export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890

# 永久设置（添加到 ~/.bashrc）
echo 'export http_proxy=http://127.0.0.1:7890' >> ~/.bashrc
echo 'export https_proxy=http://127.0.0.1:7890' >> ~/.bashrc
```

## 📊 版本对比

| 特性 | clash_manager.sh | clash_pure_shell.sh | clash_all_in_one.sh |
|-----|-----------------|-------------------|-------------------|
| 内核管理 | ✅ | ✅ | ✅ |
| 服务管理 | ✅ | ✅ | ✅ |
| 调试环境 | ✅ 增强 | ❌ | ❌ |
| 订阅转换 | ❌ | ✅ 内置 | ✅ 内置 |
| Python依赖 | ❌ | ❌ | ✅ |
| tmux依赖 | ✅ | ❌ | ❌ |
| 推荐场景 | 开发调试 | 生产部署 | 功能全面 |

## 🔧 功能特性

### 内核管理
- 自动检测系统架构
- 多镜像站下载支持
- 版本更新和回滚
- 本地文件安装支持

### 订阅管理
- 支持 SS/SSR/VMess/Trojan 协议
- Base64 订阅解码
- 自动生成 Clash 配置
- 配置文件备份

### 服务管理
- 一键启动/停止
- 状态监控
- 日志查看
- 代理测试

## 🐳 Docker 测试

```bash
# 构建并运行
docker-compose up -d

# 进入容器
docker exec -it clash-test bash

# 运行脚本
./clash_pure_shell.sh
```

## 📝 配置说明

配置文件位置：`~/.config/mihomo/`

```
~/.config/mihomo/
├── config.yaml        # 主配置文件
├── cache/            # 缓存目录
├── logs/             # 日志目录
└── backups/          # 备份目录
```

## ❓ 常见问题

### 1. 无法下载内核？
- 脚本内置多个镜像站
- 支持手动下载后本地安装

### 2. 订阅转换失败？
- 检查订阅链接是否有效
- 使用示例配置测试

### 3. 代理不工作？
- 检查服务状态：选项 3
- 测试代理连接：选项 5
- 查看日志：选项 4

## 🔒 安全说明

- 所有操作都在本地完成
- 不会上传任何数据
- 订阅转换完全离线
- 详见 `security_analysis.md`

## 📄 许可证

MIT License

## 👥 贡献

欢迎提交 Issue 和 Pull Request！

---

更多详细信息请查看：
- [快速开始](QUICK_START.md)
- [使用指南](USER_GUIDE.md)
- [测试指南](TEST_GUIDE.md)