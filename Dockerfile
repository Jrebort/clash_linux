# 使用 Ubuntu 22.04 作为基础镜像
# 如果下载失败，可以尝试使用国内镜像源
# FROM ccr.ccs.tencentyun.com/library/ubuntu:22.04
FROM ubuntu:22.04

# 设置环境变量，避免交互式提示
ENV DEBIAN_FRONTEND=noninteractive

# 更新包列表并安装依赖
RUN apt-get update && apt-get install -y \
    tmux \
    curl \
    wget \
    jq \
    tar \
    gzip \
    net-tools \
    iputils-ping \
    vim \
    sudo \
    proxychains \
    && rm -rf /var/lib/apt/lists/*

# 创建测试用户（避免直接使用 root）
RUN useradd -m -s /bin/bash testuser && \
    echo 'testuser:testpass' | chpasswd && \
    usermod -aG sudo testuser && \
    echo 'testuser ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

# 切换到测试用户
USER testuser
WORKDIR /home/testuser

# 创建必要的目录
RUN mkdir -p ~/.config/mihomo

# 复制脚本到容器（保留以防没有挂载时使用）
COPY --chown=testuser:testuser clash_manager.sh /home/testuser/
RUN chmod +x /home/testuser/clash_manager.sh

# 创建基础配置文件
RUN echo '# 基础测试配置\n\
port: 7890\n\
socks-port: 7891\n\
allow-lan: false\n\
mode: rule\n\
log-level: info\n\
external-controller: 127.0.0.1:9090\n\
secret: ""\n\
\n\
# DNS 配置\n\
dns:\n\
  enable: true\n\
  nameserver:\n\
    - 114.114.114.114\n\
    - 8.8.8.8\n\
\n\
# 最简单的规则\n\
rules:\n\
  - DOMAIN-SUFFIX,google.com,DIRECT\n\
  - DOMAIN-SUFFIX,github.com,DIRECT\n\
  - MATCH,DIRECT' > ~/.config/mihomo/config.yaml

# 暴露端口
EXPOSE 7890 7891 9090

# 设置启动命令
CMD ["/bin/bash"]