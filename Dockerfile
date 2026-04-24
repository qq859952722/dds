# 基于 Alpine Linux 的多进程集成 Docker 镜像
# 包含 AdGuard Home, SmartDNS, DNSCrypt-Proxy, Transmission, Aria2, qBittorrent
FROM alpine:3.22

# 复制 rootfs 目录下所有内容到镜像根目录
COPY rootfs/ /

# 允许来自构建参数的 DDS 版本传递
ARG DDS_VERSION

# 执行构建初始化脚本（只在镜像构建阶段运行一次）
# 负责：安装依赖、获取二进制文件、初始化配置目录等
RUN chmod +x /bin/init.sh && DDS_VERSION=${DDS_VERSION} /bin/init.sh

# 核心环境变量配置（可在启动时覆盖）
ENV PUID=1000 \
    PGID=1000 \
    UMASK=022 \
    TZ=Asia/Shanghai \
    LOG_LEVEL=INFO \
    ENABLE_TRACKER_UPDATE=true \
    ENABLE_DNS_LIST_UPDATE=false \
    # Aria2 配置
    ARIA2_RPC_SECRET=dds \
    ARIA2_RPC_PORT=6800 \
    # Transmission 配置
    TRANSMISSION_RPC_PORT=9091 \
    TRANSMISSION_RPC_USER=admin \
    TRANSMISSION_RPC_PASSWORD=admin \
    TRANSMISSION_WEB_HOME=/config/transmission/web \
    # qBittorrent 配置
    QBITTORRENT_WEBUI_PORT=8080 \
    # AdGuard Home 配置
    ADGUARDHOME_WEBUI_PORT=3000 \
    # SmartDNS 配置
    SMARTDNS_PORT=5353 \
    # s6-overlay 配置
    S6_LOGGING=0 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=30000 \
    S6_LOGGING_SCRIPT="n20 s1000000 T"

# 暴露的端口
# 53: AdGuard Home DNS
# 3000: AdGuard Home WebUI
# 5353: SmartDNS DNS
# 51413: Transmission
# 6800: Aria2 RPC
# 6881-6999: Aria2 BT/DHT
# 8080: qBittorrent WebUI
# 8999: qBittorrent
# 9091: Transmission RPC
EXPOSE 53/udp 53/tcp 3000 5353/udp 5353/tcp 51413/tcp 51413/udp 6800 8080 8999 9091

# 持久化数据卷
VOLUME ["/config", "/download"]

# 容器启动入口
ENTRYPOINT ["/bin/startup.sh"]
