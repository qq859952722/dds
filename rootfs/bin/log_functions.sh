#!/bin/sh

# 公共日志函数库
# 所有脚本必须source此脚本复用日志能力，禁止重复定义日志函数
# 日志格式：[模块名] [级别] 日志内容
# 级别过滤：仅输出级别大于等于当前配置级别的日志
# 颜色区分：DEBUG蓝色、INFO绿色、WARN黄色、ERROR红色

# 日志级别数值定义（数值越大级别越高）
_LOG_LEVEL_DEBUG=0
_LOG_LEVEL_INFO=1
_LOG_LEVEL_WARN=2
_LOG_LEVEL_ERROR=3

# ANSI颜色定义
_COLOR_BLUE='\033[0;34m'
_COLOR_GREEN='\033[0;32m'
_COLOR_YELLOW='\033[1;33m'
_COLOR_RED='\033[0;31m'
_COLOR_RESET='\033[0m'

# 当前日志级别，通过环境变量LOG_LEVEL控制，默认INFO
_CURRENT_LOG_LEVEL="${LOG_LEVEL:-INFO}"

# 获取当前配置日志级别的数值
_case_log_level() {
    case "${_CURRENT_LOG_LEVEL}" in
        DEBUG) echo ${_LOG_LEVEL_DEBUG} ;;
        INFO)  echo ${_LOG_LEVEL_INFO} ;;
        WARN)  echo ${_LOG_LEVEL_WARN} ;;
        ERROR) echo ${_LOG_LEVEL_ERROR} ;;
        *)     echo ${_LOG_LEVEL_INFO} ;;
    esac
}

# 将日志级别名称转换为数值
_numeric_level() {
    case "$1" in
        DEBUG) echo ${_LOG_LEVEL_DEBUG} ;;
        INFO)  echo ${_LOG_LEVEL_INFO} ;;
        WARN)  echo ${_LOG_LEVEL_WARN} ;;
        ERROR) echo ${_LOG_LEVEL_ERROR} ;;
        *)     echo ${_LOG_LEVEL_INFO} ;;
    esac
}

# DEBUG级别日志函数（蓝色）
# 参数：$1=模块名，$2...=日志内容
log_debug() {
    _module="${1:-UNKNOWN}"
    shift
    _msg="$*"
    _configured_level=$(_case_log_level)
    _message_level=$(_numeric_level "DEBUG")
    if [ "${_configured_level}" -le "${_message_level}" ]; then
        printf '%s[%s] [DEBUG] %s%s\n' "${_COLOR_BLUE}" "${_module}" "${_msg}" "${_COLOR_RESET}" >&2
    fi
}

# INFO级别日志函数（绿色）
# 参数：$1=模块名，$2...=日志内容
log_info() {
    _module="${1:-UNKNOWN}"
    shift
    _msg="$*"
    _configured_level=$(_case_log_level)
    _message_level=$(_numeric_level "INFO")
    if [ "${_configured_level}" -le "${_message_level}" ]; then
        printf '%s[%s] [INFO] %s%s\n' "${_COLOR_GREEN}" "${_module}" "${_msg}" "${_COLOR_RESET}" >&2
    fi
}

# WARN级别日志函数（黄色）
# 参数：$1=模块名，$2...=日志内容
log_warn() {
    _module="${1:-UNKNOWN}"
    shift
    _msg="$*"
    _configured_level=$(_case_log_level)
    _message_level=$(_numeric_level "WARN")
    if [ "${_configured_level}" -le "${_message_level}" ]; then
        printf '%s[%s] [WARN] %s%s\n' "${_COLOR_YELLOW}" "${_module}" "${_msg}" "${_COLOR_RESET}" >&2
    fi
}

# ERROR级别日志函数（红色）
# 参数：$1=模块名，$2...=日志内容
log_error() {
    _module="${1:-UNKNOWN}"
    shift
    _msg="$*"
    _configured_level=$(_case_log_level)
    _message_level=$(_numeric_level "ERROR")
    if [ "${_configured_level}" -le "${_message_level}" ]; then
        printf '%s[%s] [ERROR] %s%s\n' "${_COLOR_RED}" "${_module}" "${_msg}" "${_COLOR_RESET}" >&2
    fi
}
