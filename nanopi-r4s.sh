#!/usr/bin/env bash
# VPS-youhua platform wrapper: NanoPi R4S

set -euo pipefail
: "${TERM:=xterm}"

PLATFORM_ID="nanopi-r4s"
PLATFORM_NAME="NanoPi R4S"
PLATFORM_DESC="RK3399 ARM64 开发板，TF 卡场景优先保护写入寿命，普通保守优化"
VPSY_MEMORY_PROFILE="${VPSY_MEMORY_PROFILE:-medium}"
VPSY_CPU_PROFILE="${VPSY_CPU_PROFILE:-arm}"
VPSY_STORAGE_PROFILE="${VPSY_STORAGE_PROFILE:-tf-card}"
VPSY_ROLE_PROFILE="${VPSY_ROLE_PROFILE:-armbian}"
VPSY_TUNING_PROFILE="${VPSY_TUNING_PROFILE:-tf-card}"
VPSY_SYSCTL_FILE="${VPSY_SYSCTL_FILE:-/etc/sysctl.d/99-vps-youhua-nanopi-r4s.conf}"

COMMON_OPTIMIZE_URL="${COMMON_OPTIMIZE_URL:-https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/common-optimize.sh}"

load_common_optimize() {
    local script_dir tmp_file
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [[ -f "${script_dir}/common-optimize.sh" ]]; then
        # shellcheck source=/dev/null
        source "${script_dir}/common-optimize.sh"
        return 0
    fi

    tmp_file="${TMPDIR:-/tmp}/vps-youhua-common-$$.sh"
    if command -v curl >/dev/null 2>&1 && curl --connect-timeout 10 --max-time 60 -fsSL "$COMMON_OPTIMIZE_URL" -o "$tmp_file"; then
        # shellcheck source=/dev/null
        source "$tmp_file"
        rm -f -- "$tmp_file"
        return 0
    fi

    echo "[✗] 无法加载 common-optimize.sh" >&2
    exit 1
}

load_common_optimize
vpsy_main "$@"
