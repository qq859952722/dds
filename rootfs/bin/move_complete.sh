#!/bin/sh

. /bin/log_functions.sh

MODULE="aria2-complete"

# aria2下载完成后自动从inAdown移动到Adown
# 参数说明：
#   $1 - GID (下载GID)
#   $2 - 文件数量
#   $3 - 文件路径

GID="$1"
FILE_COUNT="$2"
FILE_PATH="$3"

log_info "${MODULE}" "下载完成触发: GID=${GID}, 文件数=${FILE_COUNT}, 路径=${FILE_PATH}"

# 等待磁盘写入完成（重试机制：检测文件是否仍被占用或正在写入）
wait_for_file_stable() {
    _path="$1"
    _max_retries=10
    _retry=0
    while [ ${_retry} -lt ${_max_retries} ]; do
        if [ ! -e "${_path}" ]; then
            return 1
        fi
        _size1=$(wc -c < "${_path}" 2>/dev/null || echo "0")
        sleep 1
        _size2=$(wc -c < "${_path}" 2>/dev/null || echo "0")
        if [ "${_size1}" = "${_size2}" ] && [ "${_size1}" != "0" ]; then
            return 0
        fi
        _retry=$((_retry + 1))
    done
    log_warn "${MODULE}" "文件稳定检测超时: ${_path}"
    return 0
}

# 检查路径是否在inAdown目录下
case "${FILE_PATH}" in
    /download/inAdown/*)
        # 等待文件/目录稳定
        wait_for_file_stable "${FILE_PATH}"

        # 计算任务根目录（将inAdown替换为Adown）
        # 单文件任务: FILE_PATH 即为文件完整路径，需取其父目录
        # 多文件任务: FILE_PATH 即为目录路径
        if [ -f "${FILE_PATH}" ]; then
            # 单文件任务：移动到 Adown 的对应子目录
            SOURCE_DIR=$(dirname "${FILE_PATH}")
            FILE_NAME=$(basename "${FILE_PATH}")
            RELATIVE_DIR="${SOURCE_DIR#/download/inAdown}"
            DEST_DIR="/download/Adown${RELATIVE_DIR}"
            DEST_FILE="${DEST_DIR}/${FILE_NAME}"
        else
            # 多文件任务：移动整个目录
            RELATIVE_DIR="${FILE_PATH#/download/inAdown}"
            DEST_DIR="/download/Adown${RELATIVE_DIR}"
            SOURCE_DIR="${FILE_PATH}"
        fi

        # 创建目标目录
        mkdir -p "${DEST_DIR}"

        # 检查目标是否已存在（防止覆盖）
        if [ -f "${FILE_PATH}" ] && [ -e "${DEST_FILE}" ]; then
            log_warn "${MODULE}" "目标文件已存在，跳过移动: ${DEST_FILE}"
        elif [ -d "${FILE_PATH}" ] && [ -e "${DEST_DIR}" ] && [ "$(ls -A "${SOURCE_DIR}" 2>/dev/null)" ]; then
            # 目录已存在且非空，检查是否有冲突文件
            CONFLICT=false
            CONFLICT_COUNT=$(find "${SOURCE_DIR}" -maxdepth 1 -mindepth 1 -exec sh -c '[ -e "$1/$(basename "$2")" ]' _ "${DEST_DIR}" {} \; -print | wc -l)
            if [ "${CONFLICT_COUNT}" -gt 0 ]; then
                CONFLICT=true
            fi
            if [ "${CONFLICT}" = "true" ]; then
                log_warn "${MODULE}" "存在文件冲突，跳过移动: ${SOURCE_DIR}"
            else
                # 无冲突，移动目录
                if mv "${SOURCE_DIR}"/* "${DEST_DIR}/" 2>/dev/null; then
                    log_info "${MODULE}" "目录内容已移动: ${SOURCE_DIR}/ -> ${DEST_DIR}/"
                else
                    log_error "${MODULE}" "目录内容移动失败: ${SOURCE_DIR}"
                fi
            fi
        elif [ -f "${FILE_PATH}" ]; then
            # 单文件移动
            if mv "${FILE_PATH}" "${DEST_DIR}/" 2>/dev/null; then
                log_info "${MODULE}" "文件已移动: ${FILE_PATH} -> ${DEST_DIR}/"
            else
                log_error "${MODULE}" "文件移动失败: ${FILE_PATH}"
            fi
        fi
        ;;
    *)
        log_debug "${MODULE}" "文件不在inAdown目录下，跳过移动: ${FILE_PATH}"
        ;;
esac
