#!/bin/sh

. /bin/log_functions.sh

MODULE="dcron-tracker"

TARGET_SOFTWARE="$1"
if [ -z "${TARGET_SOFTWARE}" ]; then
    log_info "${MODULE}" "未指定目标软件，将同时更新 Aria2 和 Transmission"
fi

TRACKER_PRIMARY_URL="https://down.adysec.com/trackers_best.txt"
TRACKER_BACKUP_URL="https://raw.githubusercontent.com/adysec/tracker/main/trackers_best.txt"

TRACKER_FILE="/config/trackerlist/trackers_best.txt"
TRACKER_STATUS_FILE="/config/trackerlist/last_update_status"
ARIA2_CONF="/config/aria2/aria2.conf"
TRANSMISSION_CONF="/config/transmission/settings.json"
ARIA2_RPC_SECRET="${ARIA2_RPC_SECRET:-dds}"
ARIA2_RPC_PORT="${ARIA2_RPC_PORT:-6800}"
TRANSMISSION_RPC_PORT="${TRANSMISSION_RPC_PORT:-9091}"

MAX_RETRIES=3
RETRY_DELAY=5
CONNECT_TIMEOUT=15
MAX_TIME=60

log_info "${MODULE}" "========== 开始更新 Tracker 列表 =========="

# ============================================================
# 下载Tracker列表（主备降级策略）
# ============================================================
WORK_DIR=$(mktemp -d)
DOWNLOADED_FILE="${WORK_DIR}/trackers_best.txt"
DOWNLOAD_SUCCESS=false

for url in "${TRACKER_PRIMARY_URL}" "${TRACKER_BACKUP_URL}"; do
    log_info "${MODULE}" "尝试下载: ${url}"
    HTTP_CODE=$(curl -fsSL \
        --connect-timeout "${CONNECT_TIMEOUT}" \
        --max-time "${MAX_TIME}" \
        -o "${DOWNLOADED_FILE}" \
        -w "%{http_code}" \
        "${url}" 2>/dev/null) || HTTP_CODE="000"

    if [ "${HTTP_CODE}" = "200" ] && [ -s "${DOWNLOADED_FILE}" ]; then
        log_info "${MODULE}" "下载成功 (HTTP ${HTTP_CODE}): ${url}"
        DOWNLOAD_SUCCESS=true
        break
    else
        log_warn "${MODULE}" "下载失败 (HTTP ${HTTP_CODE}): ${url}，尝试备用地址..."
    fi
done

if [ "${DOWNLOAD_SUCCESS}" = "false" ]; then
    log_error "${MODULE}" "所有下载地址均失败，终止更新任务"
    echo "FAILED|$(date '+%Y-%m-%d %H:%M:%S')|所有下载地址均失败" > "${TRACKER_STATUS_FILE}"
    rm -rf "${WORK_DIR}"
    exit 1
fi

# ============================================================
# 校验下载文件完整性
# ============================================================
if [ ! -s "${DOWNLOADED_FILE}" ]; then
    log_error "${MODULE}" "下载的文件为空，终止更新任务"
    rm -rf "${WORK_DIR}"
    exit 1
fi

VALID_LINES=$(grep -cE '^(https?|udp|wss?)://.+' "${DOWNLOADED_FILE}" 2>/dev/null || echo "0")
if [ "${VALID_LINES}" -eq 0 ]; then
    log_error "${MODULE}" "下载的文件无有效tracker链接，终止更新任务"
    rm -rf "${WORK_DIR}"
    exit 1
fi

log_info "${MODULE}" "文件校验通过，有效tracker链接: ${VALID_LINES} 条"

# ============================================================
# 保存Tracker列表到正式目录
# ============================================================
mkdir -p /config/trackerlist

if [ -f "${TRACKER_FILE}" ]; then
    cp "${TRACKER_FILE}" "${TRACKER_FILE}.bak"
    log_info "${MODULE}" "已备份原有Tracker列表"
fi

cp "${DOWNLOADED_FILE}" "${TRACKER_FILE}"
chown ddsuser:ddsuser "${TRACKER_FILE}"
log_info "${MODULE}" "Tracker列表已保存到 ${TRACKER_FILE}"

# ============================================================
# 列表分类过滤
# ============================================================

# Aria2：保留全类型tracker链接（http/https/udp/wss等），过滤不完整URL
ARIA2_TRACKERS=$(grep -v '^$' "${DOWNLOADED_FILE}" | grep -v '^#' | grep -E '^(https?|udp|wss?)://.+' | sort -u | head -100 | tr '\n' ',' | sed 's/,$//')
ARIA2_COUNT=$(echo "${ARIA2_TRACKERS}" | tr ',' '\n' | grep -cE '^(https?|udp|wss?)://.+' 2>/dev/null || echo "0")

# Transmission：仅保留http/https类型链接
TRANSMISSION_TRACKERS=$(grep -E '^https?://' "${DOWNLOADED_FILE}" | sort -u)
TRANSMISSION_COUNT=$(echo "${TRANSMISSION_TRACKERS}" | wc -l)

log_info "${MODULE}" "Tracker分类完成 - Aria2: ${ARIA2_COUNT}条(全类型), Transmission: ${TRANSMISSION_COUNT}条(仅http/https)"

# ============================================================
# 更新指定软件
# ============================================================

if [ -z "${TARGET_SOFTWARE}" ] || [ "${TARGET_SOFTWARE}" = "aria2" ]; then
    # 更新Aria2（RPC热更新 + 配置持久化）
    log_info "${MODULE}" "更新 Aria2 tracker列表..."

    ARIA2_RPC_URL="http://localhost:${ARIA2_RPC_PORT}/jsonrpc"

    ARIA2_PAYLOAD=$(cat <<EOF
{
    "jsonrpc": "2.0",
    "method": "aria2.changeGlobalOption",
    "id": "tracker_update",
    "params": [
        "token:${ARIA2_RPC_SECRET}",
        {
            "bt-tracker": "${ARIA2_TRACKERS}"
        }
    ]
}
EOF
    )

    ARIA2_RPC_RESULT=$(curl -fsSL \
        --connect-timeout 5 \
        --max-time 10 \
        -X POST \
        -H "Content-Type: application/json" \
        -d "${ARIA2_PAYLOAD}" \
        "${ARIA2_RPC_URL}" 2>/dev/null) || ARIA2_RPC_RESULT=""

    if [ -n "${ARIA2_RPC_RESULT}" ] && echo "${ARIA2_RPC_RESULT}" | jq -e '.result' >/dev/null 2>&1; then
        log_info "${MODULE}" "Aria2 RPC热更新成功"
    else
        if [ -n "${ARIA2_RPC_RESULT}" ] && echo "${ARIA2_RPC_RESULT}" | jq -e '.error' >/dev/null 2>&1; then
            _rpc_err=$(echo "${ARIA2_RPC_RESULT}" | jq -r '.error.message // empty' 2>/dev/null)
            log_warn "${MODULE}" "Aria2 RPC热更新失败: ${_rpc_err:-未知错误}，请检查ARIA2_RPC_SECRET是否与aria2.conf中rpc-secret一致"
        else
            log_warn "${MODULE}" "Aria2 RPC热更新失败，Aria2可能未启动或网络不可达"
        fi
    fi

    # 持久化到aria2.conf（原子替换策略）
    if [ -f "${ARIA2_CONF}" ]; then
        TMP_CONF="${ARIA2_CONF}.tmp"
        grep -v '^bt-tracker=' "${ARIA2_CONF}" > "${TMP_CONF}"
        echo "bt-tracker=${ARIA2_TRACKERS}" >> "${TMP_CONF}"
        if mv "${TMP_CONF}" "${ARIA2_CONF}" 2>/dev/null; then
            chown ddsuser:ddsuser "${ARIA2_CONF}"
            log_info "${MODULE}" "Aria2配置文件持久化完成"
        else
            rm -f "${TMP_CONF}" 2>/dev/null
            log_error "${MODULE}" "Aria2配置文件持久化失败"
        fi
    else
        log_warn "${MODULE}" "Aria2配置文件不存在: ${ARIA2_CONF}"
    fi
fi

if [ -z "${TARGET_SOFTWARE}" ] || [ "${TARGET_SOFTWARE}" = "transmission" ]; then
    # 更新Transmission（RPC热更新 + 配置持久化）
    log_info "${MODULE}" "更新 Transmission tracker列表..."

    TRANSMISSION_RPC_URL="http://localhost:${TRANSMISSION_RPC_PORT}/transmission/rpc"

    # 通过 localhost 白名单直接访问（无需认证）
    # 获取 CSRF Token：Transmission 在收到无有效 Session-Id 的请求时会返回 409 并在响应头中提供
    SESSION_ID=""
    CSRF_HEADERS=$(curl -sSL \
        --connect-timeout 5 \
        --max-time 10 \
        -D - \
        -o /dev/null \
        -X POST \
        -H "Content-Type: application/json" \
        -d '{"method":"session-get"}' \
        "${TRANSMISSION_RPC_URL}" 2>&1) || true

    SESSION_ID=$(echo "${CSRF_HEADERS}" | grep -i 'X-Transmission-Session-Id' | awk '{print $2}' | tr -d '\r' 2>/dev/null) || true

    if [ -z "${SESSION_ID}" ]; then
        log_warn "${MODULE}" "无法获取Transmission CSRF Token，Transmission可能未启动"
    else
        # 格式化tracker列表为Transmission格式（每行一个tracker，用换行分隔）
        TRANSMISSION_TRACKERS_JSON=$(echo "${TRANSMISSION_TRACKERS}" | jq -R -s 'rtrimstr("\n")')

        TRANS_PAYLOAD=$(cat <<EOF
{
    "method": "session-set",
    "arguments": {
        "default-trackers": ${TRANSMISSION_TRACKERS_JSON}
    }
}
EOF
        )

        TRANS_RPC_RESULT=$(curl -fsSL \
            --connect-timeout 5 \
            --max-time 10 \
            -X POST \
            -H "X-Transmission-Session-Id: ${SESSION_ID}" \
            -H "Content-Type: application/json" \
            -d "${TRANS_PAYLOAD}" \
            "${TRANSMISSION_RPC_URL}" 2>/dev/null) || TRANS_RPC_RESULT=""

        if [ -n "${TRANS_RPC_RESULT}" ]; then
            log_info "${MODULE}" "Transmission RPC热更新成功"
        else
            log_warn "${MODULE}" "Transmission RPC热更新失败"
        fi
    fi

    # 持久化到settings.json
    if [ -f "${TRANSMISSION_CONF}" ] && command -v jq > /dev/null 2>&1; then
        TRANSMISSION_TRACKERS_STR=$(echo "${TRANSMISSION_TRACKERS}" | jq -Rs 'rtrimstr("\n")')
        TMP_CONF="${TRANSMISSION_CONF}.tmp"
        jq --argjson trackers "${TRANSMISSION_TRACKERS_STR}" '.["default-trackers"] = $trackers' \
            "${TRANSMISSION_CONF}" > "${TMP_CONF}" && \
            mv "${TMP_CONF}" "${TRANSMISSION_CONF}"
        chown ddsuser:ddsuser "${TRANSMISSION_CONF}"
        log_info "${MODULE}" "Transmission配置文件持久化完成"
    else
        log_warn "${MODULE}" "Transmission配置文件不存在或jq不可用，跳过持久化"
    fi
fi

# ============================================================
# 清理临时文件
# ============================================================
rm -rf "${WORK_DIR}"

log_info "${MODULE}" "========== Tracker 列表更新完成 (Aria2: ${ARIA2_COUNT}条, Transmission: ${TRANSMISSION_COUNT}条) =========="
echo "SUCCESS|$(date '+%Y-%m-%d %H:%M:%S')|Aria2:${ARIA2_COUNT}条,Transmission:${TRANSMISSION_COUNT}条" > "${TRACKER_STATUS_FILE}"
