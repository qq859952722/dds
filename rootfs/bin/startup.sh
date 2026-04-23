#!/bin/sh
set -e

. /bin/log_functions.sh

log_info "startup" "========== 容器启动初始化 =========="

# ============================================================
# 第1步：校验环境变量
# ============================================================
log_info "startup" "校验环境变量..."

# 校验PUID
PUID="${PUID:-1000}"
case "${PUID}" in
    ''|*[!0-9]*) log_warn "startup" "PUID值非法(${PUID})，使用默认值1000"; PUID=1000 ;;
    *) ;;
esac

# 校验PGID
PGID="${PGID:-1000}"
case "${PGID}" in
    ''|*[!0-9]*) log_warn "startup" "PGID值非法(${PGID})，使用默认值1000"; PGID=1000 ;;
    *) ;;
esac

# 校验UMASK
UMASK="${UMASK:-022}"
case "${UMASK}" in
    [0-7][0-7][0-7]) ;;
    *) log_warn "startup" "UMASK值非法(${UMASK})，使用默认值022"; UMASK="022" ;;
esac

# 校验LOG_LEVEL
LOG_LEVEL="${LOG_LEVEL:-INFO}"
case "${LOG_LEVEL}" in
    DEBUG|INFO|WARN|ERROR) ;;
    *) log_warn "startup" "LOG_LEVEL值非法(${LOG_LEVEL})，使用默认值INFO"; LOG_LEVEL="INFO" ;;
esac
export LOG_LEVEL

# 校验ENABLE_TRACKER_UPDATE
ENABLE_TRACKER_UPDATE="${ENABLE_TRACKER_UPDATE:-true}"
case "${ENABLE_TRACKER_UPDATE}" in
    true|false) ;;
    *) log_warn "startup" "ENABLE_TRACKER_UPDATE值非法(${ENABLE_TRACKER_UPDATE})，使用默认值true"; ENABLE_TRACKER_UPDATE="true" ;;
esac

# 校验ENABLE_DNS_LIST_UPDATE
ENABLE_DNS_LIST_UPDATE="${ENABLE_DNS_LIST_UPDATE:-false}"
case "${ENABLE_DNS_LIST_UPDATE}" in
    true|false) ;;
    *) log_warn "startup" "ENABLE_DNS_LIST_UPDATE值非法(${ENABLE_DNS_LIST_UPDATE})，使用默认值false"; ENABLE_DNS_LIST_UPDATE="false" ;;
esac

# 校验时区
TZ="${TZ:-Asia/Shanghai}"
case "${TZ}" in
    *[!A-Za-z0-9_/-]*)
        log_warn "startup" "时区${TZ}包含非法字符，使用默认值Asia/Shanghai"
        TZ="Asia/Shanghai"
        ;;
esac
if [ ! -f "/usr/share/zoneinfo/${TZ}" ] 2>/dev/null; then
    if [ -f "/etc/localtime" ]; then
        log_warn "startup" "时区${TZ}不可用，保持当前系统时区"
    else
        log_warn "startup" "时区${TZ}不可用，使用UTC"
        TZ="UTC"
    fi
fi

log_info "startup" "环境变量校验完成: PUID=${PUID}, PGID=${PGID}, UMASK=${UMASK}, TZ=${TZ}, LOG_LEVEL=${LOG_LEVEL}"

# ============================================================
# 第2步：配置用户权限
# ============================================================
log_info "startup" "配置用户权限..."

# 设置系统UMASK
umask "${UMASK}"

# 创建非root用户组
if ! getent group ddsuser > /dev/null 2>&1; then
    addgroup -g "${PGID}" ddsuser
    log_info "startup" "创建用户组 ddsuser (GID=${PGID})"
else
    # 更新已有用户组的GID
    CURRENT_GID=$(getent group ddsuser | cut -d: -f3)
    if [ "${CURRENT_GID}" != "${PGID}" ]; then
        groupmod -g "${PGID}" ddsuser
        log_info "startup" "更新用户组 ddsuser GID: ${CURRENT_GID} -> ${PGID}"
    fi
fi

# 创建非root用户
if ! id -u ddsuser > /dev/null 2>&1; then
    adduser -D -u "${PUID}" -G ddsuser -s /bin/sh ddsuser
    log_info "startup" "创建用户 ddsuser (UID=${PUID})"
else
    # 更新已有用户的UID
    CURRENT_UID=$(id -u ddsuser)
    if [ "${CURRENT_UID}" != "${PUID}" ]; then
        usermod -u "${PUID}" ddsuser
        log_info "startup" "更新用户 ddsuser UID: ${CURRENT_UID} -> ${PUID}"
    fi
    
    # 确保用户在ddsuser组中
    if ! id -nG ddsuser 2>/dev/null | grep -qw ddsuser; then
        usermod -G ddsuser ddsuser
        log_info "startup" "将用户 ddsuser 加入 ddsuser 组"
    fi
fi

# 将用户加入必要的组
addgroup ddsuser cron 2>/dev/null || true
addgroup ddsuser tty 2>/dev/null || true

# 配置时区
if [ -f "/usr/share/zoneinfo/${TZ}" ]; then
    cp "/usr/share/zoneinfo/${TZ}" /etc/localtime
    echo "${TZ}" > /etc/timezone
    log_info "startup" "时区已配置为 ${TZ}"
fi

log_info "startup" "用户权限配置完成"

# ============================================================
# 第3步：下载目录校验与创建
# ============================================================
log_info "startup" "校验与创建下载目录..."

for dir in Adown inAdown Qdown inQdown Tdown inTdown; do
    mkdir -p "/download/${dir}"
    chown ddsuser:ddsuser "/download/${dir}"
    chmod 775 "/download/${dir}"
done

chown ddsuser:ddsuser /download
chmod 775 /download

log_info "startup" "下载目录校验完成"

# ============================================================
# 第4步：配置文件夹与文件同步校验
# ============================================================
log_info "startup" "同步配置文件..."

# 可自动生成配置的软件列表
AUTO_GEN_CONFIGS="qbittorrent transmission adguardhome"
# 不可自动生成配置的软件及其核心配置文件
# aria2核心配置文件
ARIA2_CORE_FILES="aria2.conf aria2.session"
# smartdns核心配置文件
SMARTDNS_CORE_FILES="smartdns.conf"
# dnscrypt-proxy核心配置文件
DNSCRYPT_CORE_FILES="dnscrypt-proxy.toml"

for tool_dir in /config_back/*/; do
    tool_name=$(basename "${tool_dir}")

    if [ ! -d "/config/${tool_name}" ]; then
        # 配置文件夹不存在，完整复制
        log_info "startup" "配置目录 /config/${tool_name} 不存在，从 /config_back 复制"
        cp -r "/config_back/${tool_name}" "/config/${tool_name}"
        chown -R ddsuser:ddsuser "/config/${tool_name}"
    else
        # 配置文件夹已存在
        case "${AUTO_GEN_CONFIGS}" in
            *"${tool_name}"*)
                # 可自动生成配置的软件：仅修改所有者
                log_info "startup" "配置目录 /config/${tool_name} 已存在(${tool_name}可自动生成配置)，仅修改所有者"
                chown -R ddsuser:ddsuser "/config/${tool_name}"
                ;;
            *)
                # 不可自动生成配置的软件：检查核心配置文件
                log_info "startup" "配置目录 /config/${tool_name} 已存在，检查核心配置文件..."

                # 确定核心配置文件列表
                case "${tool_name}" in
                    aria2) CORE_FILES="${ARIA2_CORE_FILES}" ;;
                    smartdns) CORE_FILES="${SMARTDNS_CORE_FILES}" ;;
                    dnscrypt-proxy) CORE_FILES="${DNSCRYPT_CORE_FILES}" ;;
                    *) CORE_FILES="" ;;
                esac

                for core_file in ${CORE_FILES}; do
                    if [ ! -f "/config/${tool_name}/${core_file}" ]; then
                        log_info "startup" "核心配置文件缺失: /config/${tool_name}/${core_file}，从备份复制"
                        cp "/config_back/${tool_name}/${core_file}" "/config/${tool_name}/${core_file}"
                    else
                        log_debug "startup" "核心配置文件已存在: /config/${tool_name}/${core_file}"
                    fi
                done

                chown -R ddsuser:ddsuser "/config/${tool_name}"
                ;;
        esac
    fi
done

# 确保 trackerlist 目录存在
mkdir -p /config/trackerlist
chown ddsuser:ddsuser /config/trackerlist

# 确保 smartdns/list 目录存在
mkdir -p /config/smartdns/list
chown ddsuser:ddsuser /config/smartdns/list

log_info "startup" "配置文件同步完成"

# ============================================================
# 第5步：定时任务开关配置
# ============================================================
log_info "startup" "配置定时任务..."

CRON_FILE="/var/spool/cron/crontabs/root"

if [ "${ENABLE_TRACKER_UPDATE}" = "true" ]; then
    log_info "startup" "启用 Tracker 列表每日更新定时任务"
    sed -i 's|^#\(0 2 \* \* \* /bin/update_tracker.sh\)|\1|' "${CRON_FILE}"
else
    log_info "startup" "禁用 Tracker 列表每日更新定时任务"
    sed -i 's|^\(0 2 \* \* \* /bin/update_tracker.sh\)|#\1|' "${CRON_FILE}"
fi

if [ "${ENABLE_DNS_LIST_UPDATE}" = "true" ]; then
    log_info "startup" "启用 SmartDNS 规则列表每日更新定时任务"
    sed -i 's|^#\(0 3 \* \* \* /bin/update_smartdns_list.sh\)|\1|' "${CRON_FILE}"
else
    log_info "startup" "禁用 SmartDNS 规则列表每日更新定时任务"
    sed -i 's|^\(0 3 \* \* \* /bin/update_smartdns_list.sh\)|#\1|' "${CRON_FILE}"
fi

log_info "startup" "定时任务配置完成"

# ============================================================
# 第6步：移交进程管理权给s6-overlay
# ============================================================
log_info "startup" "移交进程管理权给 s6-overlay..."
export PUID PGID UMASK TZ LOG_LEVEL ENABLE_TRACKER_UPDATE ENABLE_DNS_LIST_UPDATE
export ARIA2_RPC_SECRET ARIA2_RPC_PORT TRANSMISSION_RPC_PORT TRANSMISSION_RPC_USER TRANSMISSION_RPC_PASSWORD
export TRANSMISSION_WEB_HOME QBITTORRENT_WEBUI_PORT ADGUARDHOME_WEBUI_PORT SMARTDNS_PORT

exec /init
