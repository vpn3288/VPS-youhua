#!/usr/bin/env bash
# VPS-youhua v4.3 conservative optimization verifier.

set -euo pipefail
IFS=$'\n\t'

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo -e "${GREEN}[OK]${NC} $*"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo -e "${RED}[FAIL]${NC} $*"; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }

sysctl_get() {
    sysctl -n "$1" 2>/dev/null || true
}

config_get() {
    local file="$1" key="$2"
    awk -F= -v key="$key" '
        $1 ~ "^[[:space:]]*#" {next}
        {
            left=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", left)
            if (left == key) {
                value=$2
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                print value
                exit
            }
        }
    ' "$file" 2>/dev/null || true
}

check_configured_sysctl() {
    local file="$1" key="$2" expected actual
    expected="$(config_get "$file" "$key")"
    if [[ -z "$expected" ]]; then
        warn "$key not found in $(basename "$file")"
        return
    fi

    actual="$(sysctl_get "$key")"
    if [[ -z "$actual" ]]; then
        warn "$key unsupported by this kernel"
    elif [[ "$actual" == "$expected" ]]; then
        pass "$key = $actual"
    else
        fail "$key actual=$actual expected=$expected"
    fi
}

find_sysctl_file() {
    local marker_file="/etc/vps-youhua-optimized" file
    if [[ -f "$marker_file" ]]; then
        file="$(awk -F= '$1 == "sysctl_file" {print $2; exit}' "$marker_file")"
        [[ -n "$file" && -f "$file" ]] && { echo "$file"; return; }
    fi

    for file in /etc/sysctl.d/99-vps-youhua-*.conf; do
        [[ -f "$file" ]] && { echo "$file"; return; }
    done
}

check_marker() {
    local marker="/etc/vps-youhua-optimized"
    echo -e "\n${BOLD}Marker${NC}"
    if [[ -f "$marker" ]]; then
        pass "$marker present"
        grep -E '^(version|platform_id|memory_profile|cpu_profile|storage_profile|swap_status)=' "$marker" || true
    else
        warn "$marker absent"
    fi
}

check_sysctl_file() {
    local file="$1"
    echo -e "\n${BOLD}Sysctl${NC}"
    if [[ -z "$file" ]]; then
        warn "no /etc/sysctl.d/99-vps-youhua-*.conf found"
        return
    fi

    pass "$file present"
    for key in \
        kernel.kptr_restrict \
        fs.file-max \
        fs.nr_open \
        fs.inotify.max_user_watches \
        fs.inotify.max_user_instances \
        net.ipv4.tcp_syncookies \
        net.core.somaxconn \
        net.core.netdev_max_backlog \
        net.ipv4.tcp_max_syn_backlog \
        net.ipv4.tcp_tw_reuse \
        net.ipv4.tcp_max_tw_buckets \
        net.ipv4.tcp_no_metrics_save \
        net.netfilter.nf_conntrack_max \
        vm.swappiness \
        vm.min_free_kbytes \
        vm.vfs_cache_pressure \
        vm.page-cluster \
        vm.max_map_count \
        vm.dirty_ratio; do
        check_configured_sysctl "$file" "$key"
    done
}

check_limits() {
    local file="/etc/security/limits.d/99-vps-youhua.conf"
    echo -e "\n${BOLD}Limits${NC}"
    if [[ -f "$file" ]]; then
        pass "$file present"
        grep -E '^[*]|^root' "$file" || true
    else
        warn "$file absent"
    fi
}

check_swap() {
    local project_swap="/swapfile-vps-youhua"
    echo -e "\n${BOLD}Swap${NC}"
    if swapon --noheadings --show=NAME,SIZE,TYPE 2>/dev/null | grep -q .; then
        pass "active swap detected"
        swapon --show=NAME,SIZE,TYPE,PRIO 2>/dev/null || true
    else
        warn "no active swap/zram"
    fi

    if [[ -f "$project_swap" ]]; then
        pass "$project_swap present"
        if swapon --noheadings --show=NAME 2>/dev/null | grep -Fxq "$project_swap"; then
            pass "$project_swap active"
        else
            warn "$project_swap present but not active"
        fi
        if awk -v f="$project_swap" '$1 == f && $3 == "swap" {found=1} END {exit found ? 0 : 1}' /etc/fstab 2>/dev/null; then
            pass "$project_swap persisted in fstab"
        else
            warn "$project_swap not found in fstab"
        fi
    else
        info "project swapfile absent; this is normal when existing swap/zram, TF card, large memory, or low disk space was detected"
    fi
}

check_non_goals() {
    echo -e "\n${BOLD}Non-goals${NC}"
    info "tcp_congestion_control=$(sysctl_get net.ipv4.tcp_congestion_control)"
    info "default_qdisc=$(sysctl_get net.core.default_qdisc)"
    info "These are reported only. v4.3 intentionally does not force BBR or qdisc."
}

main() {
    local sysctl_file
    sysctl_file="$(find_sysctl_file || true)"

    echo "VPS-youhua v4.3 verifier"
    check_marker
    check_sysctl_file "$sysctl_file"
    check_limits
    check_swap
    check_non_goals

    echo -e "\n${BOLD}Summary${NC}"
    echo "OK=${PASS_COUNT} WARN=${WARN_COUNT} FAIL=${FAIL_COUNT}"
    [[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"
