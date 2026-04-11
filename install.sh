#!/usr/bin/env bash
# =============================================================================
# OpenClaw 智能安装脚本
# 支持平台: NanoPi R4S, NanoPi T6, N5105, Oracle Cloud ARM, 通用 x86 VPS
# 功能: 环境优化 + OpenClaw 安装
# 安装方式: 支持全局安装和容器安装
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

readonly VERSION="3.0"

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
    # 如果已通过环境变量传入，直接使用
    if [[ -n "${INSTALL_METHOD:-}" ]]; then
        log_info "使用预选安装方式: $INSTALL_METHOD"
        return 0
    fi
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                     OpenClaw 安装方式选择                           ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    echo "│                                                                     │"
    echo "│  [1] 全局安装 (npm install -g)                                       │"
    echo "│      优点: 简单直接，占用资源少                                      │"
    echo "│      缺点: 与宿主机共享环境                                          │"
    echo "│                                                                     │"
    echo "│  [2] 容器安装 (Docker)                                              │"
    echo "│      优点: 环境隔离，易于管理                                        │"
    echo "│      缺点: 占用更多资源                                             │"
    echo "│                                                                     │"
    echo "└─────────────────────────────────────────────────────────────────────┘"
    echo ""
    
    local choice=""
    while [[ "$choice" != "1" && "$choice" != "2" ]]; do
        read -p "请选择安装方式 [1/2，默认1]: " choice
        [[ -z "$choice" ]] && choice="1"
        [[ "$choice" != "1" && "$choice" != "2" ]] && echo "请输入 1 或 2"
    done
    
    if [[ "$choice" == "1" ]]; then
        INSTALL_METHOD="npm"
        INSTALL_DOCKER="false"
        INSTALL_NODEJS="true"
        log_info "选择: 全局安装 (npm install -g)"
    else
        INSTALL_METHOD="docker"
        INSTALL_DOCKER="true"
        INSTALL_NODEJS="false"
        log_info "选择: 容器安装 (Docker)"
    fi
    
    export INSTALL_METHOD INSTALL_DOCKER INSTALL_NODEJS
}

# ─────────────────────────────────────────────────────────────────────────────
# 平台检测
# ─────────────────────────────────────────────────────────────────────────────

detect_platform() {
    log_step "检测硬件平台..."
    
    local arch=$(uname -m)
    local mem_mb=$(free -m | awk '/^Mem:/{print $2}')
    local cpu_model=$(cat /proc/cpuinfo | grep "model name" | head -1 | cut -d: -f2 | sed 's/^ //' || echo "")
    local model=$(cat /proc/device-tree/model 2>/dev/null || echo "")
    
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
            elif echo "$cpu_model" | grep -qiE "Intel|AMD"; then
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

# ─────────────────────────────────────────────────────────────────────────────
# 主函数
# ─────────────────────────────────────────────────────────────────────────────

main() {
    clear
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                       ║"
    echo "║            OpenClaw 智能安装脚本 v${VERSION}                           ║"
    echo "║                                                                       ║"
    echo "╚═══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    
    # 选择安装方式
    select_install_method
    echo ""
    
    # 检测平台
    local platform
    platform=$(detect_platform)
    
    log_info "检测到平台: $platform"
    echo ""
    
    # 显示平台信息
    case "$platform" in
        nanopi-r4s)
            echo -e "${BLUE}  平台: NanoPi R4S${NC}"
            echo -e "${BLUE}  CPU:  RK3399 ARM64${NC}"
            echo -e "${BLUE}  特点: 双千兆网口, 低功耗${NC}"
            echo -e "${BLUE}  存储: TF卡 (需要优化)${NC}"
            ;;
        nanopi-t6)
            echo -e "${BLUE}  平台: NanoPi T6${NC}"
            echo -e "${BLUE}  CPU:  RK3588 ARM64${NC}"
            echo -e "${BLUE}  特点: 大内存, 64GB SSD${NC}"
            ;;
        n5105)
            echo -e "${BLUE}  平台: N5105 小主机${NC}"
            echo -e "${BLUE}  CPU:  Intel N5105 x86_64${NC}"
            echo -e "${BLUE}  特点: 低功耗, 稳定性好${NC}"
            ;;
        oracle-arm)
            echo -e "${BLUE}  平台: Oracle Cloud ARM${NC}"
            echo -e "${BLUE}  CPU:  Ampere Altra${NC}"
            echo -e "${BLUE}  特点: 云环境, 100GB存储${NC}"
            ;;
        generic-x86|generic-arm)
            echo -e "${BLUE}  平台: 通用设备${NC}"
            echo -e "${BLUE}  特点: 自动适配${NC}"
            ;;
    esac
    echo ""
    
    # 确认开始安装
    echo -e "${YELLOW}即将开始安装 OpenClaw (安装方式: $INSTALL_METHOD)${NC}"
    read -p "按回车继续，或 Ctrl+C 取消: "
    
    # 下载并执行对应平台脚本
    local script_url="https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/${platform}.sh"
    log_step "下载 ${platform}.sh..."
    
    # 设置环境变量传递给平台脚本
    export INSTALL_METHOD
    export INSTALL_DOCKER
    export INSTALL_NODEJS
    
    # 下载并执行脚本
    bash <(curl -fsSL "$script_url")
    
    echo ""
    log_step "安装完成!"
    echo ""
    echo -e "${GREEN}请访问 OpenClaw 控制台配置您的 AI 网关${NC}"
}

main "$@"
