#!/bin/bash
# shellcheck disable=SC2148
# shellcheck disable=SC2155

# 内核更新脚本

# 加载通用函数
source "$(dirname "$0")/common.sh"

# 下载 mihomo 内核
_download_mihomo() {
    local version=$1
    local arch=$2
    local kernel_name="mihomo"
    
    # 架构映射
    case "$arch" in
        x86_64)
            arch_name="amd64-v3"
            ;;
        aarch64)
            arch_name="arm64"
            ;;
        armv7*)
            arch_name="armv7"
            ;;
        *)
            _error_quit "不支持的架构：$arch"
            ;;
    esac
    
    local download_url="https://github.com/MetaCubeX/mihomo/releases/download/${version}/mihomo-linux-${arch_name}-${version}.gz"
    local output_file="${ZIP_BASE_DIR}/mihomo-linux-${arch_name}-${version}.gz"
    
    _okcat '⏳' "正在下载 ${kernel_name} ${version} (${arch_name})..."
    
    # 使用代理下载（如果可用）
    local proxy_opts=""
    [ -n "$http_proxy" ] && proxy_opts="--proxy $http_proxy"
    
    curl \
        --location \
        --progress-bar \
        --show-error \
        --fail \
        --insecure \
        --connect-timeout 30 \
        --retry 3 \
        --output "$output_file" \
        $proxy_opts \
        "$download_url" || {
        _failcat "下载失败，尝试使用 gh-proxy..."
        curl \
            --location \
            --progress-bar \
            --show-error \
            --fail \
            --insecure \
            --connect-timeout 30 \
            --retry 3 \
            --output "$output_file" \
            "${URL_GH_PROXY}${download_url}"
    } || {
        _failcat "gh-proxy 下载失败，尝试使用 jsdelivr CDN..."
        local jsdelivr_url="https://cdn.jsdelivr.net/gh/MetaCubeX/mihomo@releases/download/${version}/mihomo-linux-${arch_name}-${version}.gz"
        curl \
            --location \
            --progress-bar \
            --show-error \
            --fail \
            --insecure \
            --connect-timeout 30 \
            --retry 3 \
            --output "$output_file" \
            $proxy_opts \
            "$jsdelivr_url"
    } || _error_quit "所有下载源均失败：请检查网络连接或手动下载"
    
    _okcat '✅' "下载完成：$output_file"
}

# 获取当前内核版本
_get_current_version() {
    if [ -f "$BIN_KERNEL" ] && [ -x "$BIN_KERNEL" ]; then
        local current_version=$("$BIN_KERNEL" -v 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        echo "$current_version"
    else
        echo ""
    fi
}

# 备份当前内核
_backup_kernel() {
    local backup_dir="${CLASH_BASE_DIR}/backup"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    sudo mkdir -p "$backup_dir"
    
    if [ -f "$BIN_KERNEL" ]; then
        local backup_file="${backup_dir}/${BIN_KERNEL_NAME}_${timestamp}"
        sudo cp "$BIN_KERNEL" "$backup_file"
        _okcat '💾' "已备份当前内核：$backup_file"
    fi
}

# 安装新内核
_install_kernel() {
    local kernel_gz=$1
    local temp_kernel="/tmp/$(basename "$kernel_gz" .gz)"
    
    # 解压内核
    _okcat '📦' "正在解压内核..."
    gzip -dc "$kernel_gz" > "$temp_kernel" || _error_quit "解压失败"
    
    # 设置执行权限
    chmod +x "$temp_kernel"
    
    # 验证内核
    _okcat '🔍' "验证内核版本..."
    "$temp_kernel" -v || _error_quit "内核验证失败"
    
    # 停止服务
    systemctl is-active "$BIN_KERNEL_NAME" >&/dev/null && {
        _okcat '🛑' "停止 ${BIN_KERNEL_NAME} 服务..."
        sudo systemctl stop "$BIN_KERNEL_NAME"
    }
    
    # 安装内核
    sudo mv "$temp_kernel" "$BIN_MIHOMO"
    _okcat '🚀' "内核安装完成：$BIN_MIHOMO"
    
    # 更新内核变量
    _set_bin
}

# 主函数
function update_kernel() {
    local kernel_url=$1
    local version
    local arch=$(uname -m)
    
    # 验证权限
    _is_root || _error_quit "需要 root 或 sudo 权限执行"
    
    # 从 URL 提取版本号
    if [ -n "$kernel_url" ]; then
        # 从示例 URL 提取版本号
        version=$(echo "$kernel_url" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    fi
    
    # 如果没有提供版本号，获取最新版本
    if [ -z "$version" ]; then
        _okcat '🔍' "获取最新版本信息..."
        
        # 尝试 GitHub API
        local github_api="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
        version=$(curl -s "$github_api" | grep -oE '"tag_name":\s*"[^"]+' | cut -d'"' -f4 2>/dev/null)
        
        # 如果 GitHub API 失败，尝试 jsdelivr API
        if [ -z "$version" ]; then
            _failcat "GitHub API 获取失败，尝试 jsdelivr API..."
            local jsdelivr_api="https://data.jsdelivr.com/v1/packages/gh/MetaCubeX/mihomo"
            version=$(curl -s "$jsdelivr_api" | grep -oE '"version":\s*"[^"]+' | head -1 | cut -d'"' -f4 2>/dev/null)
            # 如果版本号不以 v 开头，添加 v 前缀
            [ -n "$version" ] && [[ ! "$version" =~ ^v ]] && version="v$version"
        fi
        
        [ -z "$version" ] && _error_quit "无法从所有 API 获取版本信息"
    fi
    
    _okcat '📌' "目标版本：$version"
    
    # 检查当前版本
    local current_version=$(_get_current_version)
    if [ -n "$current_version" ]; then
        _okcat '📋' "当前版本：$current_version"
        
        # 比较版本是否相同
        if [ "$current_version" = "$version" ]; then
            _okcat '✅' "当前版本已是最新版本，无需更新"
            return 0
        fi
    else
        _okcat '⚠️' "未检测到当前内核或内核不可执行"
    fi
    
    _okcat '🔄' "开始更新到版本：$version"
    
    # 备份当前内核
    _backup_kernel
    
    # 下载新内核
    _download_mihomo "$version" "$arch"
    
    # 查找下载的文件
    local kernel_gz=$(find "$ZIP_BASE_DIR" -name "mihomo-linux-*-${version}.gz" -type f | head -1)
    [ -z "$kernel_gz" ] && _error_quit "未找到下载的内核文件"
    
    # 安装新内核
    _install_kernel "$kernel_gz"
    
    # 重启服务
    _okcat '🔄' "重启 ${BIN_KERNEL_NAME} 服务..."
    sudo systemctl start "$BIN_KERNEL_NAME" || {
        _failcat "启动失败，尝试恢复备份..."
        local latest_backup=$(ls -t "${CLASH_BASE_DIR}/backup/${BIN_KERNEL_NAME}_"* 2>/dev/null | head -1)
        [ -n "$latest_backup" ] && sudo cp "$latest_backup" "$BIN_KERNEL"
        _error_quit "内核更新失败，已恢复备份"
    }
    
    # 验证服务状态
    sleep 2
    systemctl is-active "$BIN_KERNEL_NAME" >&/dev/null && {
        _okcat '✅' "内核更新成功！"
        "$BIN_KERNEL" -v
    } || _error_quit "服务启动失败，请检查日志"
}

# 显示帮助信息
function show_help() {
    cat <<EOF
内核更新脚本

用法:
    $(basename "$0") [URL|VERSION]

参数:
    URL      完整的内核下载地址
    VERSION  版本号（如 v1.19.12）
    
示例:
    $(basename "$0")                    # 更新到最新版本
    $(basename "$0") v1.19.12           # 更新到指定版本
    $(basename "$0") https://github.com/MetaCubeX/mihomo/releases/download/v1.19.12/mihomo-linux-amd64-v3-v1.19.12.gz

EOF
}

# 主程序入口
case "$1" in
    -h|--help|help)
        show_help
        ;;
    *)
        update_kernel "$1"
        ;;
esac