#!/usr/bin/env bash

###############################################################################
# 多架构开源二进制自动化下载与版本管控工具
# 版本: 1.0.0
# 描述: 自动从指定GitHub仓库下载并管理Linux amd64/arm64二进制文件，具备版本管控能力
# 注意: 故意不使用 set -e，确保单个失败不会中断整体执行流程
###############################################################################

# ============================================================================
# 配置区域 - 易于扩展新项目
# ============================================================================

# 目标项目配置
# 格式: 项目名|仓库所有者|仓库名|AMD64资产匹配模式|ARM64资产匹配模式|二进制文件名
# 注意: 资产匹配模式使用兼容grep的正则表达式来匹配Release资产名称
# 已验证实际Release资产格式（2026-04-19）
declare -a PROJECTS=(
    "transmission|qq859952722|transmission-builder|transmission-daemon.*amd64|transmission-daemon.*arm64|transmission-daemon"
    "qbittorrent|userdocs|qbittorrent-nox-static|x86_64-qbittorrent-nox|aarch64-qbittorrent-nox|qbittorrent-nox"
    "smartdns|pymumu|smartdns|smartdns-x86_64|smartdns-aarch64|smartdns"
    "adguardhome|AdguardTeam|AdGuardHome|AdGuardHome_linux_amd64|AdGuardHome_linux_arm64|AdGuardHome"
    "dnscrypt-proxy|DNSCrypt|dnscrypt-proxy|dnscrypt-proxy-linux_x86_64|dnscrypt-proxy-linux_arm64|dnscrypt-proxy"
    "aria2|SuperNG6|Aria2-Pro-Core|aria2-static-linux-x86_64|aria2-static-linux-arm64|aria2c"
)

# 支持的CPU架构
declare -a ARCHITECTURES=("amd64" "arm64")

# GitHub API 配置
GITHUB_API_BASE="https://api.github.com"
DOWNLOAD_TIMEOUT=30
MAX_RETRIES=2

# ============================================================================
# 日志函数
# ============================================================================

# 日志颜色代码（CI环境下禁用颜色以保持日志整洁）
if [ -n "${GITHUB_WORKSPACE:-}" ]; then
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
    
    log_info() {
        echo "[INFO] $1"
    }
    
    log_success() {
        echo "[SUCCESS] $1"
    }
    
    log_warn() {
        echo "[WARN] $1"
    }
    
    log_error() {
        echo "[ERROR] $1"
    }
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
    
    log_info() {
        echo -e "${BLUE}[INFO]${NC} $1"
    }
    
    log_success() {
        echo -e "${GREEN}[SUCCESS]${NC} $1"
    }
    
    log_warn() {
        echo -e "${YELLOW}[WARN]${NC} $1"
    }
    
    log_error() {
        echo -e "${RED}[ERROR]${NC} $1"
    }
fi

# ============================================================================
# 环境设置函数
# ============================================================================

# 确定工作目录
setup_workspace() {
    if [ -n "${GITHUB_WORKSPACE:-}" ]; then
        WORKSPACE="${GITHUB_WORKSPACE}"
        log_info "运行在CI环境，工作目录: ${WORKSPACE}"
    else
        WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        log_info "运行在本地环境，工作目录: ${WORKSPACE}"
    fi
    
    DOWNLOAD_DIR="${WORKSPACE}/downloads"
    AMD64_DIR="${DOWNLOAD_DIR}/amd64"
    ARM64_DIR="${DOWNLOAD_DIR}/arm64"
    VERSION_RECORD="${DOWNLOAD_DIR}/version_record.txt"
    
    # 创建目标目录
    mkdir -p "${AMD64_DIR}" "${ARM64_DIR}"
    
    log_info "下载目录: ${DOWNLOAD_DIR}"
}

# 安装所需依赖
install_dependencies() {
    local deps=("curl" "jq" "tar" "sed" "unzip")
    local missing_deps=()
    
    # 检查缺失的依赖
    for dep in "${deps[@]}"; do
        if ! command -v "${dep}" &>/dev/null; then
            missing_deps+=("${dep}")
        fi
    done
    
    if [ ${#missing_deps[@]} -eq 0 ]; then
        log_info "所有依赖已安装"
        return 0
    fi
    
    log_info "正在安装缺失的依赖: ${missing_deps[*]}"
    
    # 使用apt安装依赖
    if command -v apt-get &>/dev/null; then
        apt-get update -qq &>/dev/null
        for dep in "${missing_deps[@]}"; do
            if ! apt-get install -y -qq "${dep}" &>/dev/null; then
                log_error "依赖安装失败: ${dep}"
                exit 1
            fi
        done
        log_success "依赖安装成功"
    else
        log_error "不支持的包管理器，请手动安装: ${missing_deps[*]}"
        exit 1
    fi
}

# ============================================================================
# 版本管控函数
# ============================================================================

# 从GitHub API获取最新Release版本号
get_latest_version() {
    local owner="$1"
    local repo="$2"
    local token="${GITHUB_TOKEN:-}"
    
    local api_url="${GITHUB_API_BASE}/repos/${owner}/${repo}/releases/latest"
    local curl_cmd=("curl" "-s" "-L" "--connect-timeout" "10" "--max-time" "30")
    
    if [ -n "${token}" ]; then
        curl_cmd+=("-H" "Authorization: token ${token}")
    fi
    
    local response
    response=$("${curl_cmd[@]}" "${api_url}" 2>/dev/null) || {
        log_warn "获取 ${owner}/${repo} Release信息失败"
        echo ""
        return 1
    }
    
    local version
    version=$(echo "${response}" | jq -r '.tag_name // empty' 2>/dev/null) || {
        log_warn "解析 ${owner}/${repo} Release信息失败"
        echo ""
        return 1
    }
    
    echo "${version}"
}

# 从版本记录文件获取已记录的版本
get_recorded_version() {
    local project_name="$1"
    
    if [ ! -f "${VERSION_RECORD}" ]; then
        echo ""
        return 0
    fi
    
    local version
    version=$(grep "^${project_name}:" "${VERSION_RECORD}" 2>/dev/null | tail -1 | cut -d':' -f2-) || {
        echo ""
        return 0
    }
    
    echo "${version}"
}

# 更新版本记录文件
update_version_record() {
    local project_name="$1"
    local version="$2"
    
    local temp_file="${VERSION_RECORD}.tmp"
    
    if [ -f "${VERSION_RECORD}" ]; then
        # 删除旧版本记录并写入新版本
        grep -v "^${project_name}:" "${VERSION_RECORD}" > "${temp_file}" 2>/dev/null || true
        echo "${project_name}:${version}" >> "${temp_file}"
        mv "${temp_file}" "${VERSION_RECORD}"
    else
        # 创建新的版本记录文件
        echo "${project_name}:${version}" > "${VERSION_RECORD}"
    fi
    
    log_info "更新版本记录: ${project_name}:${version}"
}

# 检查是否需要更新版本
needs_update() {
    local project_name="$1"
    local latest_version="$2"
    
    local recorded_version
    recorded_version=$(get_recorded_version "${project_name}")
    
    if [ -z "${recorded_version}" ]; then
        log_info "项目 ${project_name} 无历史记录，将执行首次下载"
        return 0
    fi
    
    if [ "${recorded_version}" = "${latest_version}" ]; then
        log_info "项目 ${project_name} 已是最新版本 (${latest_version}) - 无需升级"
        return 1
    else
        log_info "项目 ${project_name} 有版本更新: ${recorded_version} -> ${latest_version}"
        return 0
    fi
}

# ============================================================================
# 下载与处理函数
# ============================================================================

# 带重试机制的文件下载
download_with_retry() {
    local url="$1"
    local output_file="$2"
    local attempt=1
    
    while [ ${attempt} -le $((MAX_RETRIES + 1)) ]; do
        log_info "下载中 (第 ${attempt}/$((MAX_RETRIES + 1)) 次尝试): ${url}"
        
        if curl -s -L \
            --connect-timeout "${DOWNLOAD_TIMEOUT}" \
            --max-time 300 \
            --retry 0 \
            -o "${output_file}" \
            "${url}" 2>/dev/null; then
            
            if [ -f "${output_file}" ] && [ -s "${output_file}" ]; then
                return 0
            fi
        fi
        
        log_warn "第 ${attempt} 次下载尝试失败"
        attempt=$((attempt + 1))
        sleep 2
    done
    
    return 1
}

# 从压缩包中提取二进制文件
extract_binary() {
    local archive_file="$1"
    local binary_name="$2"
    local output_dir="$3"
    local temp_dir
    
    temp_dir=$(mktemp -d /tmp/binary_extract.XXXXXX)
    
    # 根据压缩包类型选择解压方式
    case "${archive_file}" in
        *.tar.xz)
            if ! tar -xJf "${archive_file}" -C "${temp_dir}" 2>/dev/null; then
                log_error "解压tar.xz失败: ${archive_file}"
                rm -rf "${temp_dir}"
                return 1
            fi
            ;;
        *.tar.gz|*.tgz)
            if ! tar -xzf "${archive_file}" -C "${temp_dir}" 2>/dev/null; then
                log_error "解压tar.gz失败: ${archive_file}"
                rm -rf "${temp_dir}"
                return 1
            fi
            ;;
        *.zip)
            if ! unzip -q "${archive_file}" -d "${temp_dir}" 2>/dev/null; then
                log_error "解压zip失败: ${archive_file}"
                rm -rf "${temp_dir}"
                return 1
            fi
            ;;
        *)
            # 假设为直接二进制文件
            cp "${archive_file}" "${output_dir}/${binary_name}"
            chmod +x "${output_dir}/${binary_name}" 2>/dev/null || log_warn "设置可执行权限失败"
            rm -rf "${temp_dir}"
            return 0
            ;;
    esac
    
    # 在解压内容中查找目标二进制文件
    local found_binary
    found_binary=$(find "${temp_dir}" -type f -name "${binary_name}" 2>/dev/null | head -1)
    
    if [ -z "${found_binary}" ]; then
        # 尝试查找任意可执行文件
        found_binary=$(find "${temp_dir}" -type f -executable 2>/dev/null | head -1)
    fi
    
    if [ -n "${found_binary}" ]; then
        cp "${found_binary}" "${output_dir}/${binary_name}"
        chmod +x "${output_dir}/${binary_name}" 2>/dev/null || log_warn "设置可执行权限失败"
        log_success "提取二进制文件: ${binary_name}"
    else
        log_error "在压缩包中未找到二进制文件: ${archive_file}"
        rm -rf "${temp_dir}"
        return 1
    fi
    
    rm -rf "${temp_dir}"
    return 0
}

# 处理单个项目的指定架构
process_project_arch() {
    local project_name="$1"
    local owner="$2"
    local repo="$3"
    local asset_pattern="$4"
    local arch="$5"
    local binary_name="$6"
    
    log_info "处理项目 ${project_name} (${arch}架构)..."
    
    local token="${GITHUB_TOKEN:-}"
    local api_url="${GITHUB_API_BASE}/repos/${owner}/${repo}/releases/latest"
    local curl_cmd=("curl" "-s" "-L" "--connect-timeout" "10" "--max-time" "30")
    
    if [ -n "${token}" ]; then
        curl_cmd+=("-H" "Authorization: token ${token}")
    fi
    
    local release_info
    release_info=$("${curl_cmd[@]}" "${api_url}" 2>/dev/null) || {
        log_warn "获取 ${project_name} (${arch}) Release信息失败"
        return 1
    }
    
    # 查找匹配的资产
    local asset_url
    asset_url=$(echo "${release_info}" | jq -r --arg pattern "${asset_pattern}" \
        '.assets[] | select(.name | test($pattern)) | .browser_download_url' 2>/dev/null | head -1)
    
    if [ -z "${asset_url}" ]; then
        log_warn "项目 ${project_name} (${arch}) 未找到匹配的资产，匹配模式: ${asset_pattern}"
        # 列出所有可用资产以便调试
        local all_assets
        all_assets=$(echo "${release_info}" | jq -r '.assets[].name' 2>/dev/null | grep -i "linux" || true)
        if [ -n "${all_assets}" ]; then
            log_warn "可用的Linux资产: $(echo ${all_assets} | tr '\n' ', ')"
        fi
        return 1
    fi
    
    local asset_name
    asset_name=$(echo "${release_info}" | jq -r --arg pattern "${asset_pattern}" \
        '.assets[] | select(.name | test($pattern)) | .name' 2>/dev/null | head -1)
    
    log_info "找到资产: ${asset_name}"
    
    # 下载到/tmp目录
    local temp_file="/tmp/${asset_name}"
    if ! download_with_retry "${asset_url}" "${temp_file}"; then
        log_error "下载 ${asset_name} 失败 (项目: ${project_name}, 架构: ${arch})"
        rm -f "${temp_file}"
        return 1
    fi
    
    # 确定输出目录
    local output_dir
    if [ "${arch}" = "amd64" ]; then
        output_dir="${AMD64_DIR}"
    else
        output_dir="${ARM64_DIR}"
    fi
    
    # 提取二进制文件
    if ! extract_binary "${temp_file}" "${binary_name}" "${output_dir}"; then
        log_error "提取二进制文件失败 (项目: ${project_name}, 架构: ${arch})"
        rm -f "${temp_file}"
        return 1
    fi
    
    # 清理临时文件
    rm -f "${temp_file}"
    
    log_success "项目 ${project_name} (${arch}) 处理成功"
    return 0
}

# ============================================================================
# 主执行函数
# ============================================================================

# 处理单个项目
process_project() {
    local project_config="$1"
    
    # 解析项目配置
    IFS='|' read -r project_name owner repo asset_pattern_amd64 asset_pattern_arm64 binary_name <<< "${project_config}"
    
    log_info "========================================="
    log_info "处理项目: ${project_name}"
    log_info "========================================="
    
    # 获取最新版本
    local latest_version
    latest_version=$(get_latest_version "${owner}" "${repo}") || {
        log_warn "因API调用失败跳过项目 ${project_name}"
        return 0
    }
    
    if [ -z "${latest_version}" ]; then
        log_warn "项目 ${project_name} 未找到Release，跳过"
        return 0
    fi
    
    log_info "最新版本: ${latest_version}"
    
    # 检查是否需要更新
    if ! needs_update "${project_name}" "${latest_version}"; then
        return 0
    fi
    
    # 跟踪是否至少有一个架构下载成功
    local update_success=false
    
    # 处理每个架构
    for arch in "${ARCHITECTURES[@]}"; do
        local asset_pattern
        if [ "${arch}" = "amd64" ]; then
            asset_pattern="${asset_pattern_amd64}"
        else
            asset_pattern="${asset_pattern_arm64}"
        fi
        
        if process_project_arch "${project_name}" "${owner}" "${repo}" "${asset_pattern}" "${arch}" "${binary_name}"; then
            update_success=true
        else
            log_warn "项目 ${project_name} (${arch}) 处理失败"
        fi
    done
    
    # 至少有一个架构成功则更新版本记录
    if [ "${update_success}" = true ]; then
        update_version_record "${project_name}" "${latest_version}"
        log_success "项目 ${project_name} 处理完成"
    else
        log_error "项目 ${project_name} 所有架构处理均失败"
    fi
}

# 主函数
main() {
    log_info "启动多架构二进制文件下载工具"
    log_info "========================================="
    
    # 设置工作目录
    setup_workspace
    
    # 安装依赖
    install_dependencies
    
    # 处理每个项目
    for project_config in "${PROJECTS[@]}"; do
        process_project "${project_config}" || {
            log_warn "处理项目出错，继续处理下一个..."
        }
    done
    
    log_info "========================================="
    log_success "二进制文件下载与管理完成"
    log_info "二进制文件位置: ${DOWNLOAD_DIR}"
    log_info "版本记录文件: ${VERSION_RECORD}"
}

# 执行主函数
main "$@"
