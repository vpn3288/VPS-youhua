#!/usr/bin/env bash
# =============================================================================
# OpenClaw 智能安装脚本 - 自动检测平台
# 支持: NanoPi R4S/T6, N5105, Oracle Cloud ARM, 通用 x86 VPS
# =============================================================================
#
# 一键运行: bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/install.sh)
#

set -euo pipefail
IFS=$'\n\t'

readonly VERSION="2.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_step()  { echo -e "${CYAN}[➜]${NC} $1"; }


# ─────────────────────────────────────────────────────────────────────────────
# 安装方式选择
# ─────────────────────────────────────────────────────────────────────────────

select_install_method() {
    log_step "选择 OpenClaw 安装方式..."
    echo ""
    echo "┌──────────────────────────────────────────────────────────────┐"
    echo "│                    OpenClaw 安装方式                        │"
    echo "├──────────────────────────────────────────────────────────────┤"
    echo "│                                                              │"
    echo "│  [1] 全局安装 (npm install -g)                              │"
    echo "│      - 优点: 简单直接，占用资源少                            │"
    echo "│      - 缺点: 与宿主机共享环境                                │"
    echo "│                                                              │"
    echo "│  [2] 容器安装 (Docker)                                       │"
    echo "│      - 优点: 环境隔离，易于管理                              │"
    echo "│      - 缺点: 占用更多资源                                    │"
    echo "│                                                              │"
    echo "└──────────────────────────────────────────────────────────────┘"
    echo ""
    
    local choice=""
    while [[ "$choice" != "1" && "$choice" != "2" ]]; do
        read -p "请选择安装方式 [1/2，默认1]: " choice
        [[ -z "$choice" ]] && choice="1"
        [[ "$choice" != "1" && "$choice" != "2" ]] && echo "请输入 1 或 2"
    done
    
    if [[ "$choice" == "1" ]]; then
        INSTALL_METHOD="global"
        log_info "选择: 全局安装 (npm install -g)"
    else
        INSTALL_METHOD="docker"
        log_info "选择: 容器安装 (Docker)"
    fi
    
    export INSTALL_METHOD
}

# ─────────────────────────────────────────────────────────────────────────────
# 平台检测
# ─────────────────────────────────────────────────────────────────────────────
detect_platform() {
    log_step "检测硬件平台..."
    
    local arch=$(uname -m)
    local mem_mb=$(free -m | awk '/^Mem:/{print $2}')
    local cpu_model=$(cat /proc/cpuinfo | grep "model name" | head -1 | cut -d: -f2 | sed 's/^ //' || echo "")
    
    # Oracle Cloud 检测
    if grep -qi "oracle" /etc/hostname 2>/dev/null || \
       dmidecode -s system-manufacturer 2>/dev/null | grep -qi "oracle" || \
       [[ -d /etc/oci ]]; then
        echo "oracle-arm"
        return
    fi
    
    # NanoPi R4S 检测
    if [[ -f /proc/device-tree/model ]] && grep -qi "R4S" /proc/device-tree/model 2>/dev/null; then
        echo "nanopi-r4s"
        return
    fi
    
    # NanoPi T6 检测
    if [[ -f /proc/device-tree/model ]] && grep -qi "T6" /proc/device-tree/model 2>/dev/null; then
        echo "nanopi-t6"
        return
    fi
    
    # RK3399/RK3588 检测
    if grep -qi "rk3399" /proc/cpuinfo 2>/dev/null; then
        echo "nanopi-r4s"
        return
    fi
    if grep -qi "rk3588" /proc/cpuinfo 2>/dev/null; then
        echo "nanopi-t6"
        return
    fi
    
    # N5105/N5095 检测
    if echo "$cpu_model" | grep -qiE "N5105|N5095|N5095|J6412|J6413"; then
        echo "n5105"
        return
    fi
    
    # x86_64 通用
    if [[ "$arch" == "x86_64" ]]; then
        echo "generic-x86"
        return
    fi
    
    # ARM64 通用
    if [[ "$arch" == "aarch64" ]]; then
        echo "generic-arm"
        return
    fi
    
    echo "unknown"
}

# ─────────────────────────────────────────────────────────────────────────────
# 主函数
# ─────────────────────────────────────────────────────────────────────────────
main() {
    clear
    echo "═══════════════════════════════════════════════════════════════════════"
    echo -e "${GREEN}  OpenClaw 智能安装脚本 v${VERSION}${NC}"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo ""
    
    # 选择安装方式
    select_install_method
    echo ""
    
    # 检测平台
    local platform
    platform=$(detect_platform)
    
    log_info "检测到平台: $platform"
    echo ""
    
    # 确认开始安装
    echo -e "${YELLOW}即将开始安装 OpenClaw (安装方式: $INSTALL_METHOD)${NC}"
    read -p "按回车继续，或 Ctrl+C 取消: "
    
    # 下载并执行对应平台脚本
    local script_url="https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/${platform}.sh"
    log_info "下载 ${platform}.sh..."
    
    # 设置环境变量传递给平台脚本
    export INSTALL_METHOD
    
    # 下载并执行脚本
    bash <(curl -fsSL "$script_url")
    
    log_step "安装完成!"
}

trap 'log_error "脚本异常退出"; exit 1' ERR

main "$@"
