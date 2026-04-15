#!/usr/bin/env bash
# =============================================================================
# AIagent 环境优化脚本（通用入口）v3.1
# 支持平台: NanoPi R4S, NanoPC T6, Oracle ARM, N5105, 通用 x86 VPS
# 功能: 环境优化 + 可选 Docker / Node.js / OpenClaw 安装（默认全量）
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

readonly VERSION="3.1"
readonly RAW_BASE="https://raw.githubusercontent.com/vpn3288/VPS-youhua/main"

# ─────────────────────────────────────────────────────────────────────────────
# SHA256 校验和（防止供应链污染）
# ⚠️  脚本更新时必须同步更新对应 SHA256
# R49: --optimize-only, --clean-system, ip_forward注释, apt purge可选, /tmp动态, aarch64_be, Oracle MTU
# ─────────────────────────────────────────────────────────────────────────────

declare -A EXPECTED_SHA256=(
    ["nanopi-r4s"]="4bb47b90216ddb2f476c8bafa4915a8b12027e0536c8743a195e889c8af1ef28"
    ["nanopi-t6"]="e91597f08b384fa604ebf4c3f9023d2e8e5833e4268c10dc998fd12076c09011"
    ["oracle-arm"]="da5fc3f8074cce99965d9570cc7a321e836c9b1aa58d490b29d8113e27d2fdf5"
    ["n5105"]="465a7f5a395fd6f3a61598aa09c89f1d5ea5ba0fcf3f290e4b4057669837fd7f"
    ["generic-x86"]="89115a438457a820de708879c8e34e968ade7690b6b5148fee6aa5bb3cf240e5"
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
# 参数解析（操作模式 + 非交互模式）
# ─────────────────────────────────────────────────────────────────────────────

MODE="install"
INTERACTIVE=true
OPTIMIZE_ONLY=false
CLEAN_SYSTEM=false

for arg in "$@"; do
    case "$arg" in
        --uninstall)
            MODE="uninstall"
            ;;
        --non-interactive|-y|--yes)
            INTERACTIVE=false
            ;;
        --optimize-only)
            OPTIMIZE_ONLY=true
            ;;
        --clean-system)
            CLEAN_SYSTEM=true
            ;;
    esac
done

# 透传参数给平台脚本（子脚本通过 curl | bash 启动，无法继承父 shell 变量）
[[ "$OPTIMIZE_ONLY" == "true" ]] && export OPTIMIZE_ONLY="true"
[[ "$CLEAN_SYSTEM" == "true" ]] && export CLEAN_SYSTEM="true"

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

    # aarch64_be（部分 big-endian ARM64 变体）按 aarch64 处理
    # 注意：部分国产 ARM 服务器使用 aarch64_be，内核仍兼容普通 aarch64 二进制

    case "$arch" in
        aarch64|aarch64_be)
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
            # 4. 未知 ARM64 → fallback 到 nanopi-r4s（脚本内有平台自检）
            else
                echo "nanopi-r4s"
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
# 统一卸载（检测平台后调用对应平台脚本的 uninstall）
# ─────────────────────────────────────────────────────────────────────────────

uninstall_all() {
    clear
    echo -e "${RED}"
    echo "╔═══════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                       ║"
    echo "║              AIagent 环境优化脚本 v${VERSION} — 卸载模式               ║"
    echo "║                                                                       ║"
    echo "╚═══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""

    # root 检查已在上方完成
    # 并发锁
    local lock_file="/var/lock/vps-youhua-uninstall.lock"
    exec 9>"$lock_file"
    if ! flock -n 9; then
        log_error "另一个实例正在运行，退出"
        exit 1
    fi

    check_network

    local platform
    platform=$(detect_platform)

    log_info "检测到平台: $platform"
    echo ""

    # 确认
    if [[ "$INTERACTIVE" == "true" ]]; then
        echo -e "${YELLOW}警告：此操作将清理本脚本安装的所有环境优化配置！${NC}"
        echo ""
        echo -n "确认卸载？(输入 'yes' 继续): "
        read -r confirm
        [[ "$confirm" != "yes" ]] && { echo "已取消。"; exit 0; }
    else
        log_info "非交互模式，自动确认"
    fi

    echo ""
    log_step "调用 ${platform}.sh --uninstall..."
    echo ""

    # 下载平台脚本并执行 uninstall
    local tmpfile
    tmpfile=$(mktemp)
    trap 'rm -f "$tmpfile"' EXIT

    local script_url="${RAW_BASE}/${platform}.sh"
    if ! curl -fsSL "$script_url" -o "$tmpfile"; then
        log_error "下载失败: $script_url"
        exit 1
    fi

    # SHA256 校验（防止供应链污染，即使是卸载也要验证）
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

    bash "$tmpfile" --uninstall
    local ret=$?

    rm -f "$tmpfile"
    trap - EXIT

    if [[ $ret -eq 0 ]]; then
        echo ""
        echo "========================================================================"
        echo -e "${GREEN}  ✅ 卸载完成${NC}"
        echo "========================================================================"
    else
        echo ""
        log_error "平台脚本卸载失败 (exit $ret)"
    fi
    exit $ret
}

# ─────────────────────────────────────────────────────────────────────────────
# 主函数
# ─────────────────────────────────────────────────────────────────────────────

main() {
    if [[ "$MODE" == "uninstall" ]]; then
        uninstall_all
        return
    fi

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
