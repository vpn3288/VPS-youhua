#!/usr/bin/env bash
# =============================================================================
# VPS-youhua ordinary optimization launcher v4.2
#
# This launcher only selects a platform wrapper and runs the shared conservative
# optimization engine. It does not install software or change DNS/SSH/firewall.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

VERSION="4.2"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/vpn3288/VPS-youhua/main}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[✓]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
log_error() { echo -e "${RED}[✗]${NC} $*" >&2; }
log_step()  { echo -e "${CYAN}[➜]${NC} $*"; }

MODE="optimize"
SELECTED_PLATFORM=""
INTERACTIVE=true
FORCE_REAPPLY="${FORCE_REAPPLY:-false}"

VALID_PLATFORMS=(
    nanopi-r4s
    nanopc-t6
    oracle-arm
    oracle-1c4g
    n5105
    generic-x86
    generic-1c1g
    google-cloud-e2
)

show_help() {
    cat <<EOF
VPS-youhua 普通优化统一入口 v${VERSION}

用法:
  bash install.sh [选项]

常用:
  --optimize, --optimize-only      执行普通优化（默认）
  --platform=<name>                指定平台
  --status                         查看本项目配置状态
  --uninstall                      仅移除本项目写入的配置文件
  --non-interactive, -y, --yes     非交互，自动检测平台
  --force-reapply                  重写本项目配置
  --help, -h                       显示帮助

平台:
  nanopi-r4s, nanopc-t6, oracle-arm, oracle-1c4g,
  n5105, generic-x86, generic-1c1g, google-cloud-e2

说明:
  当前版本只做高兼容普通优化。旧版安装软件、改 DNS/SSH/防火墙、
  服务清理、包卸载等参数会被接受但忽略。
EOF
}

is_valid_platform() {
    local item
    for item in "${VALID_PLATFORMS[@]}"; do
        [[ "$item" == "$1" ]] && return 0
    done
    return 1
}

parse_args() {
    local arg next
    while [[ $# -gt 0 ]]; do
        arg="$1"
        case "$arg" in
            --optimize|--optimize-only|--no-software|--proxy-mode)
                MODE="optimize"
                ;;
            --status)
                MODE="status"
                ;;
            --uninstall)
                MODE="uninstall"
                ;;
            --platform=*)
                SELECTED_PLATFORM="${arg#*=}"
                ;;
            --platform)
                shift
                next="${1:-}"
                if [[ -z "$next" ]]; then
                    log_error "--platform 需要平台名称"
                    exit 1
                fi
                SELECTED_PLATFORM="$next"
                ;;
            --non-interactive|-y|--yes)
                INTERACTIVE=false
                ;;
            --force|--force-reapply)
                FORCE_REAPPLY=true
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            --full|--install-all|--install-deps|--clean-system|--with-*|--without-*|--mirror-*)
                log_warn "忽略旧版参数 ${arg}：当前入口只做普通优化"
                MODE="optimize"
                ;;
            *)
                if [[ "$arg" == --mode=* ]]; then
                    case "${arg#*=}" in
                        optimize) MODE="optimize" ;;
                        status) MODE="status" ;;
                        uninstall) MODE="uninstall" ;;
                        *) log_error "未知 mode: ${arg#*=}"; exit 1 ;;
                    esac
                elif [[ "$arg" == --* ]]; then
                    log_warn "未知参数 ${arg}，已忽略"
                fi
                ;;
        esac
        shift
    done
}

detect_platform() {
    local arch cpu_model model mem_mb gcp_meta
    arch="$(uname -m 2>/dev/null || echo unknown)"
    cpu_model="$(awk -F: '/model name|Hardware|Processor/ {gsub(/^ /,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null || echo "")"
    model="$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0' || echo "")"
    mem_mb="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"

    case "$arch" in
        aarch64|arm64)
            if echo "$model" | grep -qi "NanoPi R4S"; then
                echo "nanopi-r4s"
            elif echo "$model" | grep -qiE "NanoPC.?T6|T6"; then
                echo "nanopc-t6"
            elif echo "$cpu_model" | grep -qi "RK3588"; then
                echo "nanopc-t6"
            elif echo "$cpu_model" | grep -qi "RK3399"; then
                echo "nanopi-r4s"
            elif grep -qiE "oracle|oraclecloud" /sys/class/dmi/id/sys_vendor 2>/dev/null || \
                 echo "$cpu_model" | grep -qiE "Ampere|Altra"; then
                if [[ "$mem_mb" =~ ^[0-9]+$ ]] && (( mem_mb > 0 && mem_mb < 8192 )); then
                    echo "oracle-1c4g"
                else
                    echo "oracle-arm"
                fi
            else
                log_warn "未知 ARM64 设备，按通用 ARM VPS 档位处理"
                echo "oracle-arm"
            fi
            ;;
        x86_64|amd64)
            gcp_meta=""
            if command -v curl >/dev/null 2>&1; then
                gcp_meta="$(curl -s --connect-timeout 1 --max-time 2 -H "Metadata-Flavor: Google" \
                    "http://metadata.google.internal/computeMetadata/v1/instance/machine-type" 2>/dev/null || echo "")"
            fi

            if echo "$gcp_meta" | grep -qE "e2-micro|e2-small|e2-medium|f1-micro|g1-small"; then
                echo "google-cloud-e2"
            elif echo "$cpu_model" | grep -qiE "N5105|N5095|J6412|J6413"; then
                echo "n5105"
            elif [[ "$mem_mb" =~ ^[0-9]+$ ]] && (( mem_mb > 0 && mem_mb < 2048 )); then
                echo "generic-1c1g"
            else
                echo "generic-x86"
            fi
            ;;
        *)
            log_warn "未知架构 ${arch}，按通用 x86 VPS 档位处理"
            echo "generic-x86"
            ;;
    esac
}

show_banner() {
    echo ""
    echo "========================================================================"
    echo -e "${GREEN}  VPS-youhua 普通优化入口 v${VERSION}${NC}"
    echo "========================================================================"
    echo "默认只做低冲突系统参数优化，不接管业务环境。"
    echo ""
}

choose_platform() {
    local detected choice idx

    if [[ -n "$SELECTED_PLATFORM" ]]; then
        if ! is_valid_platform "$SELECTED_PLATFORM"; then
            log_error "未知平台: ${SELECTED_PLATFORM}"
            show_help
            exit 1
        fi
        return 0
    fi

    detected="$(detect_platform)"
    SELECTED_PLATFORM="$detected"

    if [[ "$INTERACTIVE" != "true" ]]; then
        log_info "非交互模式，自动选择平台: ${SELECTED_PLATFORM}"
        return 0
    fi

    echo -e "${BLUE}检测到平台:${NC} ${BOLD}${detected}${NC}"
    echo ""
    echo "直接回车使用检测结果，或输入编号手动选择："
    idx=1
    local platform
    for platform in "${VALID_PLATFORMS[@]}"; do
        printf "  [%d] %s\n" "$idx" "$platform"
        idx=$((idx + 1))
    done
    echo ""
    echo -n "平台 [默认 ${detected}]: "
    read -r -t 30 choice || choice=""
    choice="${choice:-}"

    if [[ -z "$choice" ]]; then
        SELECTED_PLATFORM="$detected"
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#VALID_PLATFORMS[@]} )); then
        SELECTED_PLATFORM="${VALID_PLATFORMS[$((choice - 1))]}"
    elif is_valid_platform "$choice"; then
        SELECTED_PLATFORM="$choice"
    else
        log_error "无效平台选择: ${choice}"
        exit 1
    fi
}

run_platform() {
    local platform="$1" mode="$2"
    local script_dir platform_file common_file tmpdir

    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    platform_file="${script_dir}/${platform}.sh"
    common_file="${script_dir}/common-optimize.sh"

    export FORCE_REAPPLY

    if [[ -f "$platform_file" && -f "$common_file" ]]; then
        log_step "执行本地平台脚本: ${platform}.sh"
        case "$mode" in
            optimize) bash "$platform_file" --optimize-only ;;
            status) bash "$platform_file" --status ;;
            uninstall) bash "$platform_file" --uninstall ;;
        esac
        return $?
    fi

    if ! command -v curl >/dev/null 2>&1; then
        log_error "无法下载远程脚本：系统缺少 curl"
        return 1
    fi

    tmpdir="$(mktemp -d 2>/dev/null)"
    if [[ -z "${tmpdir:-}" || ! -d "$tmpdir" ]]; then
        log_error "无法创建临时目录"
        return 1
    fi
    trap 'rm -r -- "$tmpdir" 2>/dev/null || true' EXIT

    platform_file="${tmpdir}/${platform}.sh"
    common_file="${tmpdir}/common-optimize.sh"

    log_step "下载平台脚本: ${platform}.sh"
    curl --connect-timeout 10 --max-time 60 -fsSL "${RAW_BASE}/${platform}.sh" -o "$platform_file"
    curl --connect-timeout 10 --max-time 60 -fsSL "${RAW_BASE}/common-optimize.sh" -o "$common_file"

    chmod 755 "$platform_file" "$common_file"

    case "$mode" in
        optimize) bash "$platform_file" --optimize-only ;;
        status) bash "$platform_file" --status ;;
        uninstall) bash "$platform_file" --uninstall ;;
    esac
}

main() {
    parse_args "$@"
    show_banner
    choose_platform

    if [[ "$MODE" != "status" && ${EUID} -ne 0 ]]; then
        log_error "执行 ${MODE} 需要 root 权限"
        exit 1
    fi

    log_info "平台: ${SELECTED_PLATFORM}"
    log_info "模式: ${MODE}"
    run_platform "$SELECTED_PLATFORM" "$MODE"
}

main "$@"
