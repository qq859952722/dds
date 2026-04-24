#!/bin/sh
set -e

. /bin/log_functions.sh

log_info "init" "========== 开始构建镜像 =========="

# ============================================================
# 第1步：配置Alpine源并安装核心依赖
# ============================================================
log_info "init" "配置Alpine源并安装核心依赖..."

cat > /etc/apk/repositories << 'EOF'
https://dl-cdn.alpinelinux.org/alpine/latest-stable/main
https://dl-cdn.alpinelinux.org/alpine/latest-stable/community
EOF

apk add --no-cache \
    s6-overlay \
    dcron \
    curl \
    jq \
    ca-certificates \
    tzdata \
    tar \
    unzip \
    gzip \
    busybox-extras

log_info "init" "核心依赖安装完成"

# ============================================================
# 第2步：配置默认时区
# ============================================================
log_info "init" "配置默认时区为 Asia/Shanghai..."
cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "Asia/Shanghai" > /etc/timezone

log_info "init" "时区配置完成"

# ============================================================
# 第3步：创建默认非root 用户
# ============================================================
log_info "init" "创建默认用户 ddsuser..."
if ! getent group ddsuser > /dev/null 2>&1; then
    addgroup -g 1000 ddsuser
    log_info "init" "已创建用户组 ddsuser (GID=1000)"
fi
if ! id -u ddsuser > /dev/null 2>&1; then
    adduser -D -u 1000 -G ddsuser -s /bin/sh ddsuser
    log_info "init" "已创建用户 ddsuser (UID=1000)"
fi

# ============================================================
# 第4步：获取并部署核心二进制文件
# ============================================================
log_info "init" "从 qq859952722/dds 获取核心二进制文件..."

DDS_REPO="qq859952722/dds"
ARCH=$(uname -m)

case "${ARCH}" in
    x86_64)  ASSET_ARCH="amd64" ;;
    aarch64) ASSET_ARCH="arm64" ;;
    *)       log_error "init" "不支持的架构: ${ARCH}"; exit 1 ;;
esac

log_info "init" "当前构建架构: ${ARCH} (${ASSET_ARCH})"

if [ -z "${DDS_VERSION}" ]; then
    RELEASE_JSON=$(curl -fsSL --retry 3 --retry-delay 5 -A "dds-init-script" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${DDS_REPO}/releases/latest")
    if [ -z "${RELEASE_JSON}" ]; then
        log_error "init" "无法获取 ${DDS_REPO} 的Release信息"
        exit 1
    fi
    DDS_VERSION=$(echo "${RELEASE_JSON}" | jq -r '.tag_name')
    log_info "init" "最新Release版本: ${DDS_VERSION}"
else
    log_info "init" "使用外部传入的 DDS_VERSION: ${DDS_VERSION}"
fi

echo "${DDS_VERSION}" > /dds-version

DOWNLOAD_URL="https://github.com/${DDS_REPO}/releases/download/${DDS_VERSION}/dds-${DDS_VERSION}.zip"
log_info "init" "下载地址: ${DOWNLOAD_URL}"
mkdir -p /tmp/dds_binaries
if curl -fsSL --retry 3 --retry-delay 5 -I "${DOWNLOAD_URL}" >/dev/null 2>&1; then
    ASSET_TYPE=zip
else
    DOWNLOAD_URL=$(echo "${RELEASE_JSON}" | jq -r '.assets[] | select(.name | test("\\.zip$|\\.tar\\.gz$")) | .browser_download_url' | head -1)
    if [ -z "${DOWNLOAD_URL}" ]; then
        log_error "init" "未找到备用 Release 资产"
        exit 1
    fi
    log_info "init" "备用下载地址: ${DOWNLOAD_URL}"
    if echo "${DOWNLOAD_URL}" | grep -qE '\.zip$'; then
        ASSET_TYPE=zip
    else
        ASSET_TYPE=tgz
    fi
fi

if [ "${ASSET_TYPE}" = "zip" ]; then
    curl -fsSL --retry 3 --retry-delay 5 -A "dds-init-script" -H "Accept: application/octet-stream" "${DOWNLOAD_URL}" -o /tmp/dds_binaries.zip
    unzip -q /tmp/dds_binaries.zip -d /tmp/dds_binaries
    if [ -d "/tmp/dds_binaries/${ASSET_ARCH}" ]; then
        cp /tmp/dds_binaries/${ASSET_ARCH}/* /bin/ 2>/dev/null || true
    else
        cp /tmp/dds_binaries/* /bin/ 2>/dev/null || true
    fi
else
    curl -fsSL --retry 3 --retry-delay 5 -A "dds-init-script" "${DOWNLOAD_URL}" -o /tmp/dds_binaries.tar.gz
    tar -xzf /tmp/dds_binaries.tar.gz -C /tmp/dds_binaries/
    if [ -d /tmp/dds_binaries/bin ]; then
        cp /tmp/dds_binaries/bin/* /bin/ 2>/dev/null || true
    else
        cp /tmp/dds_binaries/* /bin/ 2>/dev/null || true
    fi
fi

find /bin -maxdepth 1 -type f -executable -exec chmod 755 {} \;

log_info "init" "校验二进制文件可执行性..."
for bin in smartdns AdGuardHome dnscrypt-proxy transmission-daemon aria2c qbittorrent-nox; do
    if [ -x "/bin/${bin}" ]; then
        log_info "init" "二进制文件校验通过: ${bin}"
    else
        log_error "init" "二进制文件校验失败: ${bin}"
        exit 1
    fi
done

rm -rf /tmp/dds_binaries /tmp/dds_binaries.tar.gz
log_info "init" "核心二进制文件部署完成，临时文件已清理"

# ============================================================
# 第4步：获取Transmission Web前端
# ============================================================
log_info "init" "获取 Transmission Web 前端..."

TWM_REPO="qq859952722/transmission_web_manager"
mkdir -p /tmp/twm

TWM_URL="https://github.com/${TWM_REPO}/archive/refs/heads/main.tar.gz"
HTTP_CODE=$(curl -fsSL -o /dev/null -w "%{http_code}" "${TWM_URL}" 2>/dev/null || true)
if [ "${HTTP_CODE}" != "200" ]; then
    TWM_URL="https://github.com/${TWM_REPO}/archive/refs/heads/master.tar.gz"
fi

curl -fsSL "${TWM_URL}" -o /tmp/twm.tar.gz
tar -xzf /tmp/twm.tar.gz -C /tmp/twm --strip-components=1

mkdir -p /config_back/transmission/web

if [ -d /tmp/twm/dist ]; then
    cp -r /tmp/twm/dist/* /config_back/transmission/web/
elif [ -d /tmp/twm/src ]; then
    cp -r /tmp/twm/src/* /config_back/transmission/web/
else
    cp -r /tmp/twm/* /config_back/transmission/web/ 2>/dev/null || true
fi

rm -rf /tmp/twm /tmp/twm.tar.gz
log_info "init" "Transmission Web前端部署完成，临时文件已清理"

# ============================================================
# 第5步：创建固定目录结构
# ============================================================
log_info "init" "创建固定目录结构..."

mkdir -p /config
mkdir -p /config/trackerlist
mkdir -p /config_back/smartdns/list
mkdir -p /config_back/adguardhome
mkdir -p /config_back/dnscrypt-proxy
mkdir -p /config_back/transmission/web
mkdir -p /config_back/aria2
mkdir -p /config_back/qbittorrent/qBittorrent
mkdir -p /var/spool/cron/crontabs

log_info "init" "目录结构创建完成"

# 设置配置目录权限
find /config_back -type d -exec chmod 755 {} \;
find /config_back -type f -exec chmod 644 {} \;

# ============================================================
# 第6步：部署辅助脚本与权限配置
# ============================================================
log_info "init" "部署辅助脚本与配置权限..."

# 设置辅助脚本执行权限
chmod 755 /bin/log_functions.sh
chmod 755 /bin/update_tracker.sh
chmod 755 /bin/update_smartdns_list.sh
chmod 755 /bin/move_complete.sh
chmod 755 /bin/startup.sh
chmod 755 /bin/s6-finish-handler.sh

# 设置s6-overlay服务脚本执行权限（包括日志服务）
find /etc/s6-overlay/s6-rc.d -name run -o -name finish | while read f; do
    chmod 755 "${f}"
done

# 创建必要的日志目录
mkdir -p /var/log/aria2 /var/log/transmission /var/log/smartdns
mkdir -p /var/log/adguardhome /var/log/qbittorrent /var/log/dnscrypt-proxy /var/log/dcron
chown nobody:nogroup /var/log/aria2 /var/log/transmission /var/log/smartdns
chown nobody:nogroup /var/log/adguardhome /var/log/qbittorrent /var/log/dnscrypt-proxy /var/log/dcron

# 配置dcron定时任务（默认全部注释，由startup.sh根据环境变量启用）
# 注意：dcron不支持@reboot特殊字符串，首次启动更新任务通过s6-rc oneshot服务实现
cat > /var/spool/cron/crontabs/root << 'CRON_EOF'
# Tracker列表每日更新（凌晨2:00）
#0 2 * * * /bin/update_tracker.sh
# SmartDNS规则列表每日更新（凌晨3:00）
#0 3 * * * /bin/update_smartdns_list.sh
CRON_EOF

chmod 600 /var/spool/cron/crontabs/root

log_info "init" "辅助脚本与权限配置完成"

# ============================================================
# 第7步：编译s6-rc服务数据库
# ============================================================
log_info "init" "编译s6-rc服务数据库..."

# s6-overlay v3会自动编译/etc/s6-overlay/s6-rc.d下的服务定义，无需手动编译
log_info "init" "s6-overlay v3 服务定义已就绪，将由s6-overlay自动编译服务数据库"

# ============================================================
# 第8步：构建收尾
# ============================================================
log_info "init" "清理临时文件与缓存..."
rm -rf /tmp/* /var/cache/apk/* 2>/dev/null || true

log_info "init" "========== 镜像构建完成 =========="
