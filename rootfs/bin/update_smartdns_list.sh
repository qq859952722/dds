#!/bin/sh

. /bin/log_functions.sh

MODULE="dcron-smartdns"

RULE_DIR="/config/smartdns/list"
DNS_STATUS_FILE="/config/smartdns/list/last_update_status"
WORK_DIR=$(mktemp -d)

DIRECT_LIST_PRIMARY="https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/direct-list.txt"
DIRECT_LIST_BACKUP="https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/direct-list.txt"

PROXY_LIST_PRIMARY="https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/proxy-list.txt"
PROXY_LIST_BACKUP="https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/proxy-list.txt"

CHINA46_PRIMARY="https://china-operator-ip.yfgao.com/china46.txt"
CHINA46_BACKUP=""

CONNECT_TIMEOUT=15
MAX_TIME=120

log_info "${MODULE}" "========== 开始更新 SmartDNS 规则列表 =========="

# ============================================================
# 创建规则存储目录与临时下载目录
# ============================================================
mkdir -p "${RULE_DIR}"
chown ddsuser:ddsuser "${RULE_DIR}" 2>/dev/null || true

# ============================================================
# 定义下载函数（主备降级策略）
# ============================================================
download_with_fallback() {
    _dest="$1"
    _primary="$2"
    _backup="$3"
    _desc="$4"

    log_info "${MODULE}" "下载 ${_desc} (主地址): ${_primary}"
    HTTP_CODE=$(curl -fsSL \
        --connect-timeout "${CONNECT_TIMEOUT}" \
        --max-time "${MAX_TIME}" \
        -o "${_dest}" \
        -w "%{http_code}" \
        "${_primary}" 2>/dev/null) || HTTP_CODE="000"

    if [ "${HTTP_CODE}" = "200" ] && [ -s "${_dest}" ]; then
        log_info "${MODULE}" "${_desc} 下载成功 (主地址)"
        return 0
    fi

    log_warn "${MODULE}" "${_desc} 主地址下载失败 (HTTP ${HTTP_CODE})，尝试备用地址..."

    if [ -n "${_backup}" ]; then
        log_info "${MODULE}" "下载 ${_desc} (备用地址): ${_backup}"
        HTTP_CODE=$(curl -fsSL \
            --connect-timeout "${CONNECT_TIMEOUT}" \
            --max-time "${MAX_TIME}" \
            -o "${_dest}" \
            -w "%{http_code}" \
            "${_backup}" 2>/dev/null) || HTTP_CODE="000"

        if [ "${HTTP_CODE}" = "200" ] && [ -s "${_dest}" ]; then
            log_info "${MODULE}" "${_desc} 下载成功 (备用地址)"
            return 0
        fi

        log_warn "${MODULE}" "${_desc} 备用地址下载失败 (HTTP ${HTTP_CODE})"
    fi

    log_error "${MODULE}" "${_desc} 所有下载地址均失败"
    return 1
}

# ============================================================
# 下载所有规则文件
# ============================================================
ALL_SUCCESS=true

DIRECT_DEST="${WORK_DIR}/direct-list.txt"
if ! download_with_fallback "${DIRECT_DEST}" "${DIRECT_LIST_PRIMARY}" "${DIRECT_LIST_BACKUP}" "国内直连域名列表"; then
    ALL_SUCCESS=false
fi

PROXY_DEST="${WORK_DIR}/proxy-list.txt"
if ! download_with_fallback "${PROXY_DEST}" "${PROXY_LIST_PRIMARY}" "${PROXY_LIST_BACKUP}" "代理域名列表"; then
    ALL_SUCCESS=false
fi

CHINA46_DEST="${WORK_DIR}/china46.txt"
if ! download_with_fallback "${CHINA46_DEST}" "${CHINA46_PRIMARY}" "${CHINA46_BACKUP}" "中国大陆IP段列表"; then
    ALL_SUCCESS=false
fi

# ============================================================
# 校验下载文件完整性
# ============================================================
if [ "${ALL_SUCCESS}" = "true" ]; then
    for f in "${DIRECT_DEST}" "${PROXY_DEST}" "${CHINA46_DEST}"; do
        fname=$(basename "${f}")
        if [ ! -s "${f}" ]; then
            log_error "${MODULE}" "文件 ${fname} 为空，校验失败"
            ALL_SUCCESS=false
            break
        fi
        log_info "${MODULE}" "文件 ${fname} 校验通过 ($(wc -l < "${f}") 行)"
    done
fi

# ============================================================
# 原子替换策略：仅当所有文件全部成功时才替换
# ============================================================
if [ "${ALL_SUCCESS}" = "true" ]; then
    log_info "${MODULE}" "所有规则文件下载成功，执行原子替换..."

    cp "${DIRECT_DEST}" "${RULE_DIR}/direct-list.txt"
    cp "${PROXY_DEST}" "${RULE_DIR}/proxy-list.txt"
    cp "${CHINA46_DEST}" "${RULE_DIR}/china46.txt"

    chown ddsuser:ddsuser "${RULE_DIR}/direct-list.txt" "${RULE_DIR}/proxy-list.txt" "${RULE_DIR}/china46.txt"

    log_info "${MODULE}" "规则文件替换完成"

    # 重启SmartDNS服务使新规则生效
    log_info "${MODULE}" "重启 SmartDNS 服务使新规则生效..."
    if s6-svc -r /run/service/smartdns; then
        log_info "${MODULE}" "SmartDNS 服务重启成功"
    else
        log_warn "${MODULE}" "SmartDNS 服务重启失败，请手动重启"
    fi
else
    log_error "${MODULE}" "部分规则文件下载失败，终止替换流程，保留原有规则文件"
    echo "FAILED|$(date '+%Y-%m-%d %H:%M:%S')|部分规则文件下载失败" > "${DNS_STATUS_FILE}"
    rm -rf "${WORK_DIR}"
    exit 1
fi

# ============================================================
# 清理临时文件
# ============================================================
rm -rf "${WORK_DIR}"

log_info "${MODULE}" "========== SmartDNS 规则列表更新完成 =========="
echo "SUCCESS|$(date '+%Y-%m-%d %H:%M:%S')|规则文件更新成功" > "${DNS_STATUS_FILE}"
