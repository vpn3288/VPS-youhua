#!/usr/bin/env bash
# =============================================================================
# VPS-youhua common ordinary optimization engine v4.3
#
# Design goal:
#   - high compatibility, low conflict, production friendly
#   - no package install, no DNS/SSH/firewall changes, no service stopping
#   - platform scripts only select a conservative profile and call vpsy_main
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[✓]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
log_error() { echo -e "${RED}[✗]${NC} $*" >&2; }
log_step()  { echo -e "${CYAN}[➜]${NC} $*"; }
log_debug() { [[ "${DEBUG:-0}" == "1" ]] && echo -e "${MAGENTA}[DEBUG]${NC} $*" || true; }

SCRIPT_VERSION="4.3.0"
APT_LOG="${APT_LOG:-/var/log/vps-youhua.log}"
LOCK_FILE="${LOCK_FILE:-/var/lock/vps-youhua.lock}"
VPSY_SWAP_FILE="${VPSY_SWAP_FILE:-/swapfile-vps-youhua}"
VPSY_SWAP_MODE="${VPSY_SWAP_MODE:-auto}"
VPSY_SWAP_SIZE_MB="${VPSY_SWAP_SIZE_MB:-0}"

SYS_MEM_MB=0
SYS_CPU_CORES=1
SYS_ARCH=""
SYS_KERNEL=""
SYS_OS_ID="unknown"
SYS_OS_VERSION="unknown"
SYS_OS_PRETTY="unknown"
SYS_ROOT_SOURCE=""
SYS_ROOT_DISK=""
SYS_VIRT="none"
SYS_IS_ARMBIAN=false
SYS_IS_TF_CARD=false
SYS_IS_ORACLE_CLOUD=false
SYS_IS_GOOGLE_CLOUD=false

NOFILE_LIMIT=131072
NPROC_LIMIT=65535
FILE_MAX=524288
INOTIFY_WATCHES=262144
INOTIFY_INSTANCES=1024
INOTIFY_QUEUED_EVENTS=32768
NR_OPEN=1048576
AIO_MAX_NR=1048576
SOMAXCONN=2048
NETDEV_BACKLOG=4096
SYN_BACKLOG=2048
TCP_BUF_MAX=8388608
TCP_MAX_TW_BUCKETS=131072
TCP_MAX_ORPHANS=65536
CONNTRACK_MAX=65536
SWAPPINESS=10
MIN_FREE_KB=32768
DIRTY_BACKGROUND_RATIO=5
DIRTY_RATIO=15
DIRTY_WRITEBACK_CENTISECS=3000
DIRTY_EXPIRE_CENTISECS=6000
VFS_CACHE_PRESSURE=100
MAX_MAP_COUNT=262144
SWAP_CREATED=false
SWAP_STATUS="未处理"

if [[ -z "${PLATFORM_ID:-}" ]]; then PLATFORM_ID="generic"; fi
if [[ -z "${PLATFORM_NAME:-}" ]]; then PLATFORM_NAME="通用 Linux"; fi
if [[ -z "${PLATFORM_DESC:-}" ]]; then PLATFORM_DESC="普通保守优化"; fi
if [[ -z "${VPSY_MEMORY_PROFILE:-}" ]]; then VPSY_MEMORY_PROFILE="auto"; fi
if [[ -z "${VPSY_CPU_PROFILE:-}" ]]; then VPSY_CPU_PROFILE="auto"; fi
if [[ -z "${VPSY_STORAGE_PROFILE:-}" ]]; then VPSY_STORAGE_PROFILE="auto"; fi
if [[ -z "${VPSY_ROLE_PROFILE:-}" ]]; then VPSY_ROLE_PROFILE="production"; fi
if [[ -z "${VPSY_TUNING_PROFILE:-}" ]]; then VPSY_TUNING_PROFILE="balanced"; fi

vpsy_slug() {
    local value="$1"
    value="${value//[^a-zA-Z0-9_-]/-}"
    value="${value,,}"
    echo "${value:-generic}"
}

vpsy_require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        log_error "需要 root 权限运行"
        exit 1
    fi
}

vpsy_acquire_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log_error "另一个 VPS-youhua 实例正在运行"
        exit 1
    fi
}

backup_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    cp -a "$file" "${file}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
}

vpsy_clamp() {
    local value="$1" min="$2" max="$3"
    if (( value < min )); then
        echo "$min"
    elif (( value > max )); then
        echo "$max"
    else
        echo "$value"
    fi
}

vpsy_detect_system() {
    log_step "检测系统信息..."

    SYS_MEM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    [[ -z "$SYS_MEM_MB" || "$SYS_MEM_MB" -le 0 ]] && SYS_MEM_MB=0

    SYS_CPU_CORES=$(nproc 2>/dev/null || echo 1)
    [[ -z "$SYS_CPU_CORES" || "$SYS_CPU_CORES" -le 0 ]] && SYS_CPU_CORES=1

    SYS_ARCH=$(uname -m 2>/dev/null || echo unknown)
    SYS_KERNEL=$(uname -r 2>/dev/null || echo unknown)

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        SYS_OS_ID="${ID:-unknown}"
        SYS_OS_VERSION="${VERSION_ID:-unknown}"
        SYS_OS_PRETTY="${PRETTY_NAME:-${SYS_OS_ID} ${SYS_OS_VERSION}}"
    fi

    [[ -f /etc/armbian-release ]] && SYS_IS_ARMBIAN=true

    if grep -qi "oracle" /sys/class/dmi/id/sys_vendor 2>/dev/null || \
       grep -qi "oracle" /sys/class/dmi/id/product_name 2>/dev/null; then
        SYS_IS_ORACLE_CLOUD=true
    fi

    if command -v curl >/dev/null 2>&1; then
        if curl -s --connect-timeout 1 --max-time 2 -H "Metadata-Flavor: Google" \
            "http://metadata.google.internal/computeMetadata/v1/instance/id" >/dev/null 2>&1; then
            SYS_IS_GOOGLE_CLOUD=true
        fi
    fi

    if command -v systemd-detect-virt >/dev/null 2>&1; then
        SYS_VIRT=$(systemd-detect-virt 2>/dev/null || echo none)
        [[ -z "$SYS_VIRT" ]] && SYS_VIRT="none"
    fi

    SYS_ROOT_SOURCE=$(findmnt -no SOURCE / 2>/dev/null || echo "")
    if [[ "$SYS_ROOT_SOURCE" == /dev/* ]]; then
        SYS_ROOT_DISK=$(lsblk -no PKNAME "$SYS_ROOT_SOURCE" 2>/dev/null | head -1 || echo "")
        [[ -z "$SYS_ROOT_DISK" ]] && SYS_ROOT_DISK=$(basename "$SYS_ROOT_SOURCE")
    fi

    if [[ "$SYS_ROOT_DISK" == mmcblk* ]] || [[ "$SYS_ROOT_SOURCE" == /dev/mmcblk* ]]; then
        SYS_IS_TF_CARD=true
    fi

    log_info "系统: ${SYS_OS_PRETTY} | 内核: ${SYS_KERNEL}"
    log_info "硬件: ${SYS_ARCH}, ${SYS_CPU_CORES} CPU, ${SYS_MEM_MB}MB RAM, virt=${SYS_VIRT}"
}

vpsy_resolve_profiles() {
    [[ "${SYS_IS_ARMBIAN}" == "true" ]] && [[ "${VPSY_ROLE_PROFILE}" == "production" ]] && VPSY_ROLE_PROFILE="armbian"
    [[ "${SYS_IS_TF_CARD}" == "true" ]] && [[ "${VPSY_STORAGE_PROFILE}" == "auto" ]] && VPSY_STORAGE_PROFILE="tf-card"
    [[ "${SYS_IS_GOOGLE_CLOUD}" == "true" ]] && [[ "${VPSY_CPU_PROFILE}" == "auto" ]] && VPSY_CPU_PROFILE="shared"
    [[ "${SYS_IS_ORACLE_CLOUD}" == "true" ]] && [[ "${VPSY_STORAGE_PROFILE}" == "auto" ]] && VPSY_STORAGE_PROFILE="cloud"

    if [[ "$VPSY_MEMORY_PROFILE" == "auto" ]]; then
        if (( SYS_MEM_MB > 0 && SYS_MEM_MB < 1536 )); then
            VPSY_MEMORY_PROFILE="tiny"
        elif (( SYS_MEM_MB > 0 && SYS_MEM_MB < 4096 )); then
            VPSY_MEMORY_PROFILE="small"
        elif (( SYS_MEM_MB > 0 && SYS_MEM_MB < 8192 )); then
            VPSY_MEMORY_PROFILE="medium"
        else
            VPSY_MEMORY_PROFILE="large"
        fi
    fi

    if [[ "$VPSY_CPU_PROFILE" == "auto" ]]; then
        if (( SYS_CPU_CORES <= 1 )); then
            VPSY_CPU_PROFILE="shared"
        elif [[ "$SYS_ARCH" == "aarch64" || "$SYS_ARCH" == "arm64" ]]; then
            VPSY_CPU_PROFILE="arm"
        elif [[ "$SYS_VIRT" == "oracle" || "$SYS_VIRT" == "google" || "$SYS_IS_ORACLE_CLOUD" == "true" || "$SYS_IS_GOOGLE_CLOUD" == "true" ]]; then
            VPSY_CPU_PROFILE="cloud"
        else
            VPSY_CPU_PROFILE="standard"
        fi
    fi

    if [[ "$VPSY_STORAGE_PROFILE" == "auto" ]]; then
        if [[ "$SYS_IS_TF_CARD" == "true" ]]; then
            VPSY_STORAGE_PROFILE="tf-card"
        elif [[ "$SYS_ARCH" == "aarch64" || "$SYS_ARCH" == "arm64" ]]; then
            VPSY_STORAGE_PROFILE="emmc"
        elif [[ "$SYS_VIRT" == "none" ]]; then
            VPSY_STORAGE_PROFILE="ssd"
        else
            VPSY_STORAGE_PROFILE="cloud"
        fi
    fi

    local slug
    slug=$(vpsy_slug "$PLATFORM_ID")
    VPSY_SYSCTL_FILE="${VPSY_SYSCTL_FILE:-/etc/sysctl.d/99-vps-youhua-${slug}.conf}"
}

vpsy_calculate_values() {
    case "$VPSY_MEMORY_PROFILE" in
        tiny)
            NOFILE_LIMIT=65535
            NPROC_LIMIT=32768
            SOMAXCONN=1024
            NETDEV_BACKLOG=2048
            SYN_BACKLOG=1024
            TCP_BUF_MAX=4194304
            TCP_MAX_TW_BUCKETS=65536
            TCP_MAX_ORPHANS=32768
            CONNTRACK_MAX=32768
            INOTIFY_WATCHES=131072
            INOTIFY_INSTANCES=512
            INOTIFY_QUEUED_EVENTS=16384
            ;;
        small)
            NOFILE_LIMIT=131072
            NPROC_LIMIT=65535
            SOMAXCONN=2048
            NETDEV_BACKLOG=4096
            SYN_BACKLOG=2048
            TCP_BUF_MAX=8388608
            TCP_MAX_TW_BUCKETS=131072
            TCP_MAX_ORPHANS=65536
            CONNTRACK_MAX=65536
            INOTIFY_WATCHES=262144
            INOTIFY_INSTANCES=1024
            INOTIFY_QUEUED_EVENTS=32768
            ;;
        medium)
            NOFILE_LIMIT=196608
            NPROC_LIMIT=98304
            SOMAXCONN=4096
            NETDEV_BACKLOG=8192
            SYN_BACKLOG=4096
            TCP_BUF_MAX=12582912
            TCP_MAX_TW_BUCKETS=262144
            TCP_MAX_ORPHANS=131072
            CONNTRACK_MAX=131072
            INOTIFY_WATCHES=524288
            INOTIFY_INSTANCES=2048
            INOTIFY_QUEUED_EVENTS=65536
            ;;
        large|*)
            NOFILE_LIMIT=262144
            NPROC_LIMIT=131072
            SOMAXCONN=8192
            NETDEV_BACKLOG=16384
            SYN_BACKLOG=8192
            TCP_BUF_MAX=16777216
            TCP_MAX_TW_BUCKETS=524288
            TCP_MAX_ORPHANS=262144
            CONNTRACK_MAX=262144
            INOTIFY_WATCHES=524288
            INOTIFY_INSTANCES=4096
            INOTIFY_QUEUED_EVENTS=131072
            ;;
    esac

    if [[ "$VPSY_CPU_PROFILE" == "shared" ]]; then
        SOMAXCONN=$(vpsy_clamp "$SOMAXCONN" 512 2048)
        NETDEV_BACKLOG=$(vpsy_clamp "$NETDEV_BACKLOG" 1024 4096)
        SYN_BACKLOG=$(vpsy_clamp "$SYN_BACKLOG" 1024 2048)
        TCP_MAX_TW_BUCKETS=$(vpsy_clamp "$TCP_MAX_TW_BUCKETS" 32768 131072)
        TCP_MAX_ORPHANS=$(vpsy_clamp "$TCP_MAX_ORPHANS" 16384 65536)
        CONNTRACK_MAX=$(vpsy_clamp "$CONNTRACK_MAX" 16384 65536)
    fi

    if [[ "$VPSY_STORAGE_PROFILE" == "tf-card" ]]; then
        DIRTY_BACKGROUND_RATIO=2
        DIRTY_RATIO=8
        DIRTY_WRITEBACK_CENTISECS=1500
        DIRTY_EXPIRE_CENTISECS=3000
        SWAPPINESS=10
    elif [[ "$VPSY_STORAGE_PROFILE" == "emmc" ]]; then
        DIRTY_BACKGROUND_RATIO=3
        DIRTY_RATIO=10
        DIRTY_WRITEBACK_CENTISECS=2000
        DIRTY_EXPIRE_CENTISECS=5000
        SWAPPINESS=10
    else
        DIRTY_BACKGROUND_RATIO=5
        DIRTY_RATIO=15
        DIRTY_WRITEBACK_CENTISECS=3000
        DIRTY_EXPIRE_CENTISECS=6000
        SWAPPINESS=10
    fi

    if [[ "$VPSY_MEMORY_PROFILE" == "tiny" ]]; then
        VFS_CACHE_PRESSURE=120
    else
        VFS_CACHE_PRESSURE=100
    fi

    local mem_based_minfree
    mem_based_minfree=$(( SYS_MEM_MB * 1024 / 100 ))
    MIN_FREE_KB=$(vpsy_clamp "$mem_based_minfree" 16384 262144)
    [[ "$VPSY_MEMORY_PROFILE" == "tiny" ]] && MIN_FREE_KB=$(vpsy_clamp "$MIN_FREE_KB" 16384 65536)

    FILE_MAX=$(( NOFILE_LIMIT * 4 ))
    FILE_MAX=$(vpsy_clamp "$FILE_MAX" 262144 1048576)
}

vpsy_write_sysctl() {
    local file="$VPSY_SYSCTL_FILE"
    log_step "写入低冲突 sysctl: ${file}"

    mkdir -p /etc/sysctl.d
    backup_file "$file"

    cat > "$file" <<EOF
# =============================================================================
# VPS-youhua ordinary conservative sysctl v${SCRIPT_VERSION}
# Platform: ${PLATFORM_ID}
# Profiles: memory=${VPSY_MEMORY_PROFILE}, cpu=${VPSY_CPU_PROFILE}, storage=${VPSY_STORAGE_PROFILE}, role=${VPSY_ROLE_PROFILE}
# This file intentionally does not change DNS, SSH, firewall, routes, IPv6 state,
# CPU governor, zram, swap, fstab, cloud agents, or package sources.
# =============================================================================

# Kernel and filesystem safety
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.file-max = ${FILE_MAX}
fs.nr_open = ${NR_OPEN}
fs.aio-max-nr = ${AIO_MAX_NR}
fs.inotify.max_user_watches = ${INOTIFY_WATCHES}
fs.inotify.max_user_instances = ${INOTIFY_INSTANCES}
fs.inotify.max_queued_events = ${INOTIFY_QUEUED_EVENTS}

# Conservative network hardening
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# TCP defaults suited for generic VPS and production services
net.core.somaxconn = ${SOMAXCONN}
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = ${TCP_BUF_MAX}
net.core.wmem_max = ${TCP_BUF_MAX}
net.ipv4.tcp_max_syn_backlog = ${SYN_BACKLOG}
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = ${TCP_MAX_TW_BUCKETS}
net.ipv4.tcp_max_orphans = ${TCP_MAX_ORPHANS}
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_rmem = 4096 131072 ${TCP_BUF_MAX}
net.ipv4.tcp_wmem = 4096 131072 ${TCP_BUF_MAX}

# Conntrack is capped conservatively; unsupported kernels ignore it with sysctl -e.
net.netfilter.nf_conntrack_max = ${CONNTRACK_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 3600

# VM writeback and memory behavior
vm.swappiness = ${SWAPPINESS}
vm.min_free_kbytes = ${MIN_FREE_KB}
vm.vfs_cache_pressure = ${VFS_CACHE_PRESSURE}
vm.overcommit_memory = 0
vm.page-cluster = 0
vm.max_map_count = ${MAX_MAP_COUNT}
vm.zone_reclaim_mode = 0
vm.dirty_background_ratio = ${DIRTY_BACKGROUND_RATIO}
vm.dirty_ratio = ${DIRTY_RATIO}
vm.dirty_writeback_centisecs = ${DIRTY_WRITEBACK_CENTISECS}
vm.dirty_expire_centisecs = ${DIRTY_EXPIRE_CENTISECS}
EOF

    chmod 644 "$file"
}

vpsy_apply_sysctl() {
    log_step "应用本项目 sysctl 参数..."
    sysctl -e -p "$VPSY_SYSCTL_FILE" >> "$APT_LOG" 2>&1 || true
    log_info "sysctl 应用完成（不强制修改不支持的内核参数）"
}

vpsy_write_limits() {
    local file="/etc/security/limits.d/99-vps-youhua.conf"
    log_step "写入保守资源限制: ${file}"
    mkdir -p /etc/security/limits.d
    backup_file "$file"
    cat > "$file" <<EOF
# VPS-youhua ordinary conservative limits v${SCRIPT_VERSION}
root soft nofile ${NOFILE_LIMIT}
root hard nofile ${NOFILE_LIMIT}
root soft nproc ${NPROC_LIMIT}
root hard nproc ${NPROC_LIMIT}
* soft nofile ${NOFILE_LIMIT}
* hard nofile ${NOFILE_LIMIT}
* soft nproc ${NPROC_LIMIT}
* hard nproc ${NPROC_LIMIT}
EOF
    chmod 644 "$file"
}

vpsy_active_swap_count() {
    swapon --noheadings --show=NAME 2>/dev/null | awk 'NF {count++} END {print count + 0}'
}

vpsy_project_swap_active() {
    swapon --noheadings --show=NAME 2>/dev/null | grep -Fxq "$VPSY_SWAP_FILE"
}

vpsy_configured_swap_count() {
    [[ -f /etc/fstab ]] || { echo 0; return; }
    awk '$1 !~ /^#/ && $3 == "swap" {count++} END {print count + 0}' /etc/fstab
}

vpsy_project_swap_configured() {
    [[ -f /etc/fstab ]] || return 1
    awk -v f="$VPSY_SWAP_FILE" '$1 == f && $3 == "swap" {found=1} END {exit found ? 0 : 1}' /etc/fstab
}

vpsy_swap_size_mb() {
    if [[ "${VPSY_SWAP_SIZE_MB}" =~ ^[0-9]+$ ]] && (( VPSY_SWAP_SIZE_MB > 0 )); then
        vpsy_clamp "$VPSY_SWAP_SIZE_MB" 256 8192
        return
    fi

    case "$VPSY_MEMORY_PROFILE" in
        tiny) echo 1024 ;;
        small) echo 2048 ;;
        medium)
            if [[ "$VPSY_STORAGE_PROFILE" == "cloud" || "$VPSY_STORAGE_PROFILE" == "ssd" ]]; then
                echo 1024
            else
                echo 0
            fi
            ;;
        *) echo 0 ;;
    esac
}

vpsy_root_free_mb() {
    df -Pm / 2>/dev/null | awk 'NR==2 {print $4 + 0}'
}

vpsy_ensure_swap_fstab() {
    local tmp
    [[ -f /etc/fstab ]] || touch /etc/fstab

    if awk -v f="$VPSY_SWAP_FILE" '$1 == f && $3 == "swap" {found=1} END {exit found ? 0 : 1}' /etc/fstab; then
        return 0
    fi

    backup_file /etc/fstab
    printf '%s none swap sw,nofail 0 0 # VPS-youhua managed swapfile\n' "$VPSY_SWAP_FILE" >> /etc/fstab
}

vpsy_remove_swap_fstab() {
    local tmp
    [[ -f /etc/fstab ]] || return 0
    grep -Fq "VPS-youhua managed swapfile" /etc/fstab || return 0

    backup_file /etc/fstab
    tmp="$(mktemp)"
    awk -v f="$VPSY_SWAP_FILE" '!(($1 == f) && ($3 == "swap") && ($0 ~ /VPS-youhua managed swapfile/))' /etc/fstab > "$tmp"
    cat "$tmp" > /etc/fstab
    rm -f -- "$tmp"
}

vpsy_ensure_swapfile() {
    local size_mb free_mb min_free_after_mb

    SWAP_STATUS="跳过"

    if [[ "$VPSY_SWAP_MODE" == "off" || "$VPSY_SWAP_MODE" == "disabled" ]]; then
        SWAP_STATUS="已关闭"
        log_info "虚拟内存: 已按配置跳过"
        return 0
    fi

    if ! command -v swapon >/dev/null 2>&1 || ! command -v mkswap >/dev/null 2>&1; then
        SWAP_STATUS="缺少 swapon/mkswap，跳过"
        log_warn "虚拟内存: 系统缺少 swapon/mkswap，跳过"
        return 0
    fi

    if (( $(vpsy_active_swap_count) > 0 )); then
        SWAP_STATUS="检测到已有 swap/zram，未改动"
        log_info "虚拟内存: 检测到已有 swap/zram，保持现状"
        return 0
    fi

    if (( $(vpsy_configured_swap_count) > 0 )) && ! vpsy_project_swap_configured; then
        SWAP_STATUS="检测到 fstab 已有 swap 配置，未改动"
        log_info "虚拟内存: 检测到 fstab 已有 swap 配置，保持现状"
        return 0
    fi

    if [[ "$VPSY_SWAP_FILE" != /* || "$VPSY_SWAP_FILE" =~ [[:space:]] ]]; then
        SWAP_STATUS="swapfile 路径不安全，跳过"
        log_warn "虚拟内存: swapfile 路径需要是无空格的绝对路径，跳过"
        return 0
    fi

    if [[ "$VPSY_STORAGE_PROFILE" == "tf-card" || "$SYS_IS_TF_CARD" == "true" ]] && [[ "$VPSY_SWAP_MODE" != "force" ]]; then
        SWAP_STATUS="TF 卡场景默认跳过"
        log_info "虚拟内存: TF 卡场景默认不创建 swapfile"
        return 0
    fi

    size_mb="$(vpsy_swap_size_mb)"
    if (( size_mb <= 0 )); then
        SWAP_STATUS="当前档位无需创建"
        log_info "虚拟内存: 当前档位无需创建 swapfile"
        return 0
    fi

    free_mb="$(vpsy_root_free_mb)"
    min_free_after_mb=1024
    if (( free_mb > 0 && free_mb < size_mb + min_free_after_mb )); then
        SWAP_STATUS="磁盘空间不足，跳过"
        log_warn "虚拟内存: 根分区剩余 ${free_mb}MB，不足以创建 ${size_mb}MB swapfile"
        return 0
    fi

    if [[ -e "$VPSY_SWAP_FILE" && ! -f "$VPSY_SWAP_FILE" ]]; then
        SWAP_STATUS="目标路径不是普通文件，跳过"
        log_warn "虚拟内存: ${VPSY_SWAP_FILE} 不是普通文件，跳过"
        return 0
    fi

    if [[ ! -f "$VPSY_SWAP_FILE" ]]; then
        log_step "创建项目自有 swapfile: ${VPSY_SWAP_FILE} (${size_mb}MB)"
        if ! {
            if command -v fallocate >/dev/null 2>&1; then
                fallocate -l "${size_mb}M" "$VPSY_SWAP_FILE" >> "$APT_LOG" 2>&1 || \
                    dd if=/dev/zero of="$VPSY_SWAP_FILE" bs=1M count="$size_mb" status=none >> "$APT_LOG" 2>&1
            else
                dd if=/dev/zero of="$VPSY_SWAP_FILE" bs=1M count="$size_mb" status=none >> "$APT_LOG" 2>&1
            fi
        }; then
            rm -f -- "$VPSY_SWAP_FILE"
            SWAP_STATUS="创建失败，跳过"
            log_warn "虚拟内存: swapfile 创建失败，已跳过"
            return 0
        fi
        SWAP_CREATED=true
    else
        log_info "虚拟内存: 发现项目 swapfile，尝试启用"
    fi

    chmod 600 "$VPSY_SWAP_FILE"
    if ! mkswap -f "$VPSY_SWAP_FILE" >> "$APT_LOG" 2>&1; then
        [[ "$SWAP_CREATED" == "true" ]] && rm -f -- "$VPSY_SWAP_FILE"
        SWAP_STATUS="mkswap 失败，跳过"
        log_warn "虚拟内存: mkswap 失败，已跳过"
        return 0
    fi

    if ! swapon "$VPSY_SWAP_FILE" >> "$APT_LOG" 2>&1; then
        [[ "$SWAP_CREATED" == "true" ]] && rm -f -- "$VPSY_SWAP_FILE"
        SWAP_STATUS="swapon 失败，跳过"
        log_warn "虚拟内存: swapon 失败，已跳过（可能是文件系统不支持 swapfile）"
        return 0
    fi

    vpsy_ensure_swap_fstab

    SWAP_STATUS="已启用 ${size_mb}MB (${VPSY_SWAP_FILE})"
    log_info "虚拟内存: ${SWAP_STATUS}"
}

vpsy_write_logrotate() {
    local file="/etc/logrotate.d/vps-youhua"
    log_step "写入脚本日志轮转规则"
    cat > "$file" <<'EOF'
/var/log/vps-youhua.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
}
EOF
    chmod 644 "$file"
}

vpsy_write_marker() {
    local file="/etc/vps-youhua-optimized"
    cat > "$file" <<EOF
version=${SCRIPT_VERSION}
platform_id=${PLATFORM_ID}
platform_name=${PLATFORM_NAME}
memory_profile=${VPSY_MEMORY_PROFILE}
cpu_profile=${VPSY_CPU_PROFILE}
storage_profile=${VPSY_STORAGE_PROFILE}
role_profile=${VPSY_ROLE_PROFILE}
sysctl_file=${VPSY_SYSCTL_FILE}
swap_mode=${VPSY_SWAP_MODE}
swap_file=${VPSY_SWAP_FILE}
swap_status=${SWAP_STATUS}
updated_at=$(date -Is)
EOF
    chmod 644 "$file"
}

vpsy_show_summary() {
    echo ""
    echo "========================================================================"
    echo -e "${GREEN}  VPS-youhua 普通优化完成 v${SCRIPT_VERSION}${NC}"
    echo "========================================================================"
    echo -e "${BLUE}平台:${NC} ${PLATFORM_NAME} (${PLATFORM_ID})"
    echo -e "${BLUE}描述:${NC} ${PLATFORM_DESC}"
    echo -e "${BLUE}档位:${NC} memory=${VPSY_MEMORY_PROFILE}, cpu=${VPSY_CPU_PROFILE}, storage=${VPSY_STORAGE_PROFILE}"
    echo -e "${BLUE}资源:${NC} nofile=${NOFILE_LIMIT}, somaxconn=${SOMAXCONN}, conntrack=${CONNTRACK_MAX}"
    echo -e "${BLUE}虚拟内存:${NC} ${SWAP_STATUS}"
    echo -e "${BLUE}写入:${NC} ${VPSY_SYSCTL_FILE}, /etc/security/limits.d/99-vps-youhua.conf"
    echo ""
    echo -e "${YELLOW}未执行:${NC} 软件安装、DNS、SSH、防火墙、服务启停、包卸载、zram、云厂商组件处理"
    echo -e "${YELLOW}说明:${NC} sysctl 已立即应用；limits 对新登录会话生效。"
    echo ""
}

vpsy_optimize() {
    vpsy_require_root
    vpsy_acquire_lock
    mkdir -p "$(dirname "$APT_LOG")" /var/log
    touch "$APT_LOG"

    vpsy_detect_system
    vpsy_resolve_profiles
    vpsy_calculate_values

    if [[ -f /etc/vps-youhua-optimized && "${FORCE_REAPPLY:-false}" != "true" ]]; then
        log_info "检测到已优化标记，将幂等重写本项目配置"
    fi

    log_info "执行普通优化，不安装软件、不改变业务服务"
    vpsy_write_sysctl
    vpsy_apply_sysctl
    vpsy_write_limits
    vpsy_ensure_swapfile
    vpsy_write_logrotate
    vpsy_write_marker
    vpsy_show_summary
}

vpsy_status() {
    vpsy_detect_system
    vpsy_resolve_profiles
    echo ""
    echo "VPS-youhua 状态"
    echo "  platform: ${PLATFORM_ID} (${PLATFORM_NAME})"
    echo "  system: ${SYS_OS_PRETTY}"
    echo "  profile: memory=${VPSY_MEMORY_PROFILE}, cpu=${VPSY_CPU_PROFILE}, storage=${VPSY_STORAGE_PROFILE}"
    echo "  marker: $([[ -f /etc/vps-youhua-optimized ]] && echo present || echo absent)"
    echo "  sysctl: $([[ -f "$VPSY_SYSCTL_FILE" ]] && echo "$VPSY_SYSCTL_FILE" || echo absent)"
    echo "  limits: $([[ -f /etc/security/limits.d/99-vps-youhua.conf ]] && echo present || echo absent)"
    echo "  swap: $(swapon --noheadings --show=NAME,SIZE,TYPE 2>/dev/null | tr '\n' ';' | sed 's/;$//' || true)"
    echo "  project_swap: $([[ -f "$VPSY_SWAP_FILE" ]] && echo "$VPSY_SWAP_FILE" || echo absent)"
}

vpsy_uninstall() {
    vpsy_require_root
    vpsy_acquire_lock
    log_step "移除 VPS-youhua 自有配置文件..."

    local f
    for f in /etc/sysctl.d/99-vps-youhua*.conf; do
        [[ -e "$f" ]] && rm -f -- "$f"
    done
    if vpsy_project_swap_active; then
        swapoff "$VPSY_SWAP_FILE" 2>/dev/null || true
    fi
    vpsy_remove_swap_fstab
    rm -f -- "$VPSY_SWAP_FILE"
    rm -f -- /etc/security/limits.d/99-vps-youhua.conf
    rm -f -- /etc/logrotate.d/vps-youhua
    rm -f -- /etc/vps-youhua-optimized

    log_info "已移除持久化配置。当前运行时 sysctl 不强制回滚，重启后按系统默认/其他配置生效。"
}

vpsy_help() {
    cat <<EOF
VPS-youhua 普通优化入口 v${SCRIPT_VERSION}

用法:
  bash <platform>.sh [选项]

选项:
  --optimize, --optimize-only   执行普通优化（默认）
  --proxy-mode                  普通优化别名，保持业务环境不变
  --status                      查看本项目配置状态
  --uninstall                   仅移除本项目写入的配置文件
  --force-reapply               重写本项目配置
  --no-swap                     不创建项目 swapfile
  --force-swap                  允许在 TF 卡场景创建 swapfile
  --swap-size=<MB>              指定项目 swapfile 大小
  --help, -h                    显示帮助

兼容说明:
  旧版软件安装、DNS、SSH、防火墙、服务清理相关参数会被忽略。
EOF
}

vpsy_main() {
    local mode="optimize"
    local arg

    for arg in "$@"; do
        case "$arg" in
            --status) mode="status" ;;
            --uninstall) mode="uninstall" ;;
            --optimize|--optimize-only|--proxy-mode|--no-software) mode="optimize" ;;
            --force|--force-reapply) FORCE_REAPPLY=true ;;
            --no-swap|--without-swap) VPSY_SWAP_MODE="off" ;;
            --force-swap) VPSY_SWAP_MODE="force" ;;
            --swap-size=*) VPSY_SWAP_SIZE_MB="${arg#*=}" ;;
            --help|-h) vpsy_help; return 0 ;;
            --full|--install-all|--install-deps|--clean-system|--with-*|--without-*|--mirror-*)
                log_warn "忽略旧版参数 ${arg}：当前版本只做普通优化"
                ;;
            --platform|--platform=*)
                ;;
            *)
                if [[ "$arg" == --* ]]; then
                    log_warn "未知参数 ${arg}，已忽略"
                fi
                ;;
        esac
    done

    case "$mode" in
        status) vpsy_status ;;
        uninstall) vpsy_uninstall ;;
        optimize) vpsy_optimize ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    vpsy_main "$@"
fi
