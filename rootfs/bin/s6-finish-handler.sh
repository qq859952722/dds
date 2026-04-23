#!/bin/sh

# s6-overlay 服务通用退出处理脚本
# 用法: /bin/s6-finish-handler.sh <SERVICE_NAME> [EXIT_CODE]
# 所有服务的 finish 脚本统一调用此脚本，避免重复代码
# 设计说明：
#   finish脚本仅记录退出日志，不干预s6-supervise的自动重启行为
#   s6-supervise会自动重启异常退出的服务，无需手动干预
#   若需在关键服务失败时停止整个容器，应使用 /run/s6/basedir/bin/halt

. /bin/log_functions.sh

SERVICE_NAME="${1:-unknown}"
EXIT_CODE="${2:-0}"

if [ ${EXIT_CODE} -eq 0 ]; then
    log_info "${SERVICE_NAME}" "服务正常退出"
else
    log_error "${SERVICE_NAME}" "服务异常退出，退出码: ${EXIT_CODE}，s6-supervise将自动重启"
fi
