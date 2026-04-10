#!/usr/bin/env bash
# =============================================================================
# OpenClaw 全局安装脚本 - 自动检测平台
# 支持: NanoPi R4S/T6, N5105, Oracle Cloud ARM, 通用 x86 VPS
# 安装方式: npm 全局安装 (不用容器)
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

readonly VERSION="2.1"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_step()  { echo -e "${CYAN}[➜]${NC} $1"; }

# ─────────────────────────────────────────────────────────────────────────────
# 平台检测
# ─────────────────────────────────────────────────────────────────────────────

detect_platform() {
    log_step "检测硬件平台..."
    
    local arch=$(uname -m)
    local mem_mb=$(free -m | awk '/^Mem:/{print $2}')
    local cpu_model=$(cat /proc/cpuinfo | grep "model name" | head -1 | cut -d: -f2 | sed 's/^ //' || echo "")
    local model=$(cat /proc/device-tree/model 2>/dev/null || echo "")
    
    echo "$model" | grep -qi "Raspberry Pi" && arch="rpi"
    
    case "$arch" in
        aarch64)
            if echo "$model" | grep -qi "NanoPi T6"; then
                echo "nanopi-t6"
            elif echo "$model" | grep -qi "NanoPi R4S"; then
                echo "nanopi-r4s"
            elif echo "$model" | grep -qi "Rockchip"; then
                echo "nanopi-t6"
            else
                echo "generic-arm"
            fi
            ;;
        armv7l|armv6l)
            echo "nanopi-r4s"
            ;;
        x86_64)
            if echo "$cpu_model" | grep -qiE "N5105|N5095|J6412|J6413"; then
                echo "n5105"
            elif echo "$cpu_model" | grep -qi "Intel\|AMD"; then
                echo "generic-x86"
            else
                echo "generic-x86"
            fi
            ;;
        *)
            echo "generic-x86"
            ;;
    esac
}

main() {
    clear
    echo "═══════════════════════════════════════════════════════════════════════"
    echo -e "${GREEN}  OpenClaw 全局安装脚本 v${VERSION}${NC}"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo ""
    
    log_info "安装方式: npm 全局安装"
    echo ""
    
    # 检测平台
    local platform
    platform=$(detect_platform)
    
    log_info "检测到平台: $platform"
    echo ""
    
    # 确认开始安装
    echo -e "${YELLOW}即将开始安装 OpenClaw${NC}"
    read -p "按回车继续，或 Ctrl+C 取消: "
    
    # 下载并执行对应平台脚本
    local script_url="https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/${platform}.sh"
    log_info "下载 ${platform}.sh..."
    
    # 下载并执行脚本
    bash <(curl -fsSL "$script_url")
    
    log_step "安装完成!"
}

main "$@"
