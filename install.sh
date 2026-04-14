#!/usr/bin/env bash
# =============================================================================
# AIagent 环境优化脚本（通用入口）
# 支持平台: NanoPi R4S, NanoPC T6, Oracle ARM, N5105, 通用 x86 VPS
# 功能: 只优化环境，不安装 AIagent（安装 AIagent 请参考其官方文档）
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

readonly VERSION="3.1"

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
    local cpu_model=$(cat /proc/cpuinfo | grep "model name" | head -1 | cut -d: -f2 | sed 's/^ //' || echo "")
    local model
    model=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0' | xargs 2>/dev/null || echo "")

    case "$arch" in
        aarch64)
            if echo "$model" | grep -qi "NanoPi R4S"; then
                echo "nanopi-r4s"
            elif echo "$model" | grep -qiE "NanoPC.?T6|T6"; then
                echo "nanopi-t6"
            else
                # 未知 ARM64 设备，使用 nanopi-r4s 脚本（内有平台自适应）
                echo "nanopi-r4s"
            fi
            ;;
        armv7l|armv6l)
            echo "nanopi-r4s"
            ;;
        x86_64)
            if echo "$cpu_model" | grep -qiE "N5105|N5095|J6412|J6413"; then
                echo "n5105"
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
    echo "║            AIagent 环境优化脚本 v${VERSION}                             ║"
    echo "║                                                                       ║"
    echo "╚═══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
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
            echo -e "${BLUE}  存储: TF卡 (已针对TF卡写入保护优化)${NC}"
            ;;
        nanopi-t6)
            echo -e "${BLUE}  平台: NanoPC T6${NC}"
            echo -e "${BLUE}  CPU:  RK3588 ARM64${NC}"
            echo -e "${BLUE}  特点: 3网口(1×GbE+2×2.5GbE), 16GB大内存${NC}"
            echo -e "${BLUE}  存储: eMMC (已针对eMMC写入优化)${NC}"
            ;;
        n5105)
            echo -e "${BLUE}  平台: N5105/N5095 小主机${NC}"
            echo -e "${BLUE}  CPU:  Intel N5105 x86_64${NC}"
            echo -e "${BLUE}  特点: 低功耗, 静音 (Turbo Boost 已禁用)${NC}"
            echo -e "${BLUE}  存储: SSD${NC}"
            ;;
        oracle-arm)
            echo -e "${BLUE}  平台: Oracle Cloud ARM${NC}"
            echo -e "${BLUE}  CPU:  Ampere Altra${NC}"
            echo -e "${BLUE}  特点: 云环境, 32MB TCP缓冲优化${NC}"
            ;;
        generic-arm)
            echo -e "${BLUE}  平台: 通用 ARM64 设备${NC}"
            echo -e "${BLUE}  特点: 自动适配${NC}"
            ;;
        generic-x86)
            echo -e "${BLUE}  平台: 通用 x86_64 VPS${NC}"
            echo -e "${BLUE}  特点: 自动适配${NC}"
            ;;
    esac
    echo ""

    echo -e "${YELLOW}即将开始环境优化（不安装 AIagent）${NC}"
    echo ""
    read -p "按回车继续，或 Ctrl+C 取消: "

    # 下载并执行对应平台优化脚本
    local script_url="https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/${platform}.sh"
    log_step "下载 ${platform}.sh..."

    bash <(curl -fsSL "$script_url")

    echo ""
    log_step "环境优化完成!"
    echo ""
    echo -e "${GREEN}✓ 系统已针对 AIagent 运行优化完毕${NC}"
    echo ""
    echo "下一步: 安装你的 AIagent（OpenClaw / Hermes / 其他）"
    echo ""
    echo -e "${CYAN}验证优化效果: bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/verify-v3.1.sh)${NC}"
}

main "$@"
