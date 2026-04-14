#!/usr/bin/env bash
# =============================================================================
# AIagent 环境优化脚本（通用入口）v3.1
# 支持平台: NanoPi R4S, NanoPC T6, Oracle ARM, N5105, 通用 x86 VPS
# 功能: 只优化环境，不安装 AIagent
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

readonly VERSION="3.1"
readonly RAW_BASE="https://raw.githubusercontent.com/vpn3288/VPS-youhua/main"

# ─────────────────────────────────────────────────────────────────────────────
# SHA256 校验和（防止供应链污染）
# ⚠️  脚本更新时必须同步更新对应 SHA256
# ─────────────────────────────────────────────────────────────────────────────

declare -A EXPECTED_SHA256=(
    ["nanopi-r4s"]="104ff6086baba5aa8cbb2b7f5348c84c0de93d5054b79f36b19b1535276f5dad"
    ["nanopi-t6"]="8be8671734ffd235eb9385ce8800e2b8fb1fb571289a2c08c0f657485bd3d539"
    ["oracle-arm"]="f9ff99239a48a7e99e9b419e84addc25152bd6ce4602bdf88b8558ef39be1248"
    ["n5105"]="32954afb8e66a15ca4f0e5643c5e9ae1557f5cb718c79aa9532456d24eb3b44e"
    ["generic-x86"]="deaf8b9e71b3213229f83fc211e334e58a6eb7845bbf62fe7745594bf3c8a750"
    ["verify-v3.1"]="d734d7b4a3cc933ce03021ac87279f8ecd20c4f0033a1c9b21a935f1df0ec5b4"
)

# ─────────────────────────────────────────────────────────────────────────────
# 参数解析（非交互模式）
# ─────────────────────────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
    echo "[✗] 请使用 root 运行: sudo bash \"$0\" \"$*\"" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 参数解析（非交互模式）
# ─────────────────────────────────────────────────────────────────────────────

INTERACTIVE=true
if [[ ! -t 0 ]] || [[ "${1:-}" == "--non-interactive" ]] || [[ "${1:-}" == "-y" ]] || [[ "${1:-}" == "--yes" ]]; then
    INTERACTIVE=false
fi

# ─────────────────────────────────────────────────────────────────────────────
# 颜色
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1" >&2; }
log_step()  { echo -e "${CYAN}[➜]${NC} $1"; }

# ─────────────────────────────────────────────────────────────────────────────
# 平台检测（统一显式分流）
# ─────────────────────────────────────────────────────────────────────────────

detect_platform() {
    local arch=$(uname -m)
    local cpu_model=$(cat /proc/cpuinfo | grep "model name" | head -1 | cut -d: -f2 | sed 's/^ //' || echo "")
    local model
    model=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0' | xargs 2>/dev/null || echo "")

    # 32位 ARM 未支持，直接报错退出
    if [[ "$arch" == "armv7l" ]] || [[ "$arch" == "armv6l" ]]; then
        log_error "不支持 32位 ARM (${arch})，请使用 ARM64 设备"
        exit 1
    fi

    case "$arch" in
        aarch64)
            # 1. 按设备树判断 NanoPi 系列（最精确）
            if echo "$model" | grep -qi "NanoPi R4S"; then
                echo "nanopi-r4s"
            elif echo "$model" | grep -qiE "NanoPC.?T6|T6"; then
                echo "nanopi-t6"
            # 2. 按 DMI/sys_vendor 判断云厂商 ARM
            elif grep -qiE "oracle|oraclecloud" /sys/class/dmi/id/sys_vendor 2>/dev/null || \
                 echo "$cpu_model" | grep -qiE "Ampere|Altra"; then
                echo "oracle-arm"
            # 3. 按 CPU model 判断其他已知 ARM 设备
            elif echo "$cpu_model" | grep -qi "RK3588"; then
                echo "nanopi-t6"
            elif echo "$cpu_model" | grep -qi "RK3399"; then
                echo "nanopi-r4s"
            # 4. 未知 ARM64 → generic-arm（无 NanoPi 专属优化）
            else
                echo "generic-arm"
            fi
            ;;
        x86_64)
            if echo "$cpu_model" | grep -qiE "N5105|N5095|J6412|J6413"; then
                echo "n5105"
            else
                echo "generic-x86"
            fi
            ;;
        *)
            log_error "不支持的架构: $arch"
            exit 1
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# 网络检测
# ─────────────────────────────────────────────────────────────────────────────

check_network() {
    if ! ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then
        log_error "网络不可达，请检查网络连接"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 下载 → SHA256 校验 → 执行
# ─────────────────────────────────────────────────────────────────────────────

download_and_run() {
    local platform="$1"
    local script_url="${RAW_BASE}/${platform}.sh"
    local tmpfile
    tmpfile=$(mktemp)

    # 下载前先检查 URL 是否存在
    log_step "检查 ${platform}.sh..."
    if ! curl --head --silent --fail "$script_url" >/dev/null 2>&1; then
        log_error "平台脚本不存在: $script_url"
        rm -f "$tmpfile"
        exit 1
    fi

    log_step "下载 ${platform}.sh..."
    if ! curl -fsSL "$script_url" -o "$tmpfile"; then
        log_error "下载失败: $script_url"
        rm -f "$tmpfile"
        exit 1
    fi

    # SHA256 校验（防止供应链污染）
    local expected="${EXPECTED_SHA256[$platform]:-}"
    if [[ -n "$expected" ]]; then
        local actual
        actual=$(sha256sum "$tmpfile" | awk '{print $1}')
        if [[ "$actual" != "$expected" ]]; then
            log_error "SHA256 校验失败！文件可能被篡改。"
            log_error "期望: $expected"
            log_error "实际: $actual"
            rm -f "$tmpfile"
            exit 1
        fi
        log_info "SHA256 校验通过"
    fi

    log_step "执行 ${platform}.sh..."
    # 执行临时文件后自动清理（trap 在 main 里设置）
    bash "$tmpfile"
    rm -f "$tmpfile"
}

# ─────────────────────────────────────────────────────────────────────────────
# 主函数
# ─────────────────────────────────────────────────────────────────────────────

main() {
    # 清理临时文件
    trap 'rm -f /tmp/vps-youhua-*.sh' EXIT

    clear
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                       ║"
    echo "║            AIagent 环境优化脚本 v${VERSION}                             ║"
    echo "║                                                                       ║"
    echo "╚═══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""

    check_network

    local platform
    platform=$(detect_platform)

    log_info "检测到平台: $platform"
    echo ""

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
            echo -e "${BLUE}  特点: 低功耗, 有风扇${NC}"
            echo -e "${BLUE}  存储: SSD${NC}"
            ;;
        oracle-arm)
            echo -e "${BLUE}  平台: Oracle Cloud ARM${NC}"
            echo -e "${BLUE}  CPU:  Ampere Altra${NC}"
            echo -e "${BLUE}  特点: 云环境, 32MB TCP缓冲优化${NC}"
            ;;
        generic-arm)
            echo -e "${BLUE}  平台: 通用 ARM64 设备${NC}"
            echo -e "${BLUE}  特点: 自动适配（无硬件专属优化）${NC}"
            ;;
        generic-x86)
            echo -e "${BLUE}  平台: 通用 x86_64 VPS${NC}"
            echo -e "${BLUE}  特点: 自动适配${NC}"
            ;;
    esac
    echo ""

    if [[ "$INTERACTIVE" == "true" ]]; then
        echo -e "${YELLOW}即将开始环境优化（不安装 AIagent）${NC}"
        echo ""
        read -p "按回车继续，或 Ctrl+C 取消: "
    else
        log_info "非交互模式，自动继续"
    fi

    download_and_run "$platform"

    echo ""
    log_step "环境优化完成!"
    echo ""
    echo -e "${GREEN}✓ 系统已针对 AIagent 运行优化完毕${NC}"
    echo ""
    echo "下一步: 安装你的 AIagent（OpenClaw / Hermes / 其他）"
    echo ""
    echo -e "${CYAN}验证优化效果: bash <(curl -fsSL ${RAW_BASE}/verify-v3.1.sh)${NC}"
}

main "$@"
