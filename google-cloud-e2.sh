#!/usr/bin/env bash
#
# 修复: 非交互式环境(如SSH远程执行)需要 TERM 变量
: "${TERM:=xterm}"
# VPS 优化脚本 - Google Cloud e2-micro（共享 CPU 永久免费）
#
# 用法:
#   sudo bash google-cloud-e2.sh                    # 完整安装（底层优化 + 软件依赖）
#   sudo bash google-cloud-e2.sh --optimize-only    # 仅底层优化
#   sudo bash google-cloud-e2.sh --uninstall        # 卸载所有优化
#
# 功能:
#   - 系统内核参数优化（网络、内存、文件系统）
#   - 安全加固（SSH、防火墙、fail2ban）
#   - 性能调优（swap、tmpfs、I/O调度）
#   - 可选软件安装（Docker、Node.js、开发工具）
#
# 项目: https://github.com/vpn3288/VPS-youhua
#
set -euo pipefail
# =============================================================================
# Google Cloud e2-micro 永久免费 VPS 优化安装脚本 v3.4.4
# 硬件: Google Cloud e2-micro, 1vCPU(共享) 1GB RAM, 30GB SSD
# 特点: GCP 共享 CPU 特化优化（burstable CPU + Intel + VPC 网络）
#       GCP Always Free 机型永久免费（1vCPU 1GB，非 ARM）
# =============================================================================
#
# 一键运行: bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/google-cloud-e2.sh)
#
# 模式说明:
#   --optimize-only   纯环境优化（不安装 Docker/Node.js）
#   --uninstall       卸载所有优化配置
#

# ─────────────────────────────────────────────────────────────────────────────
# 平台信息
# ─────────────────────────────────────────────────────────────────────────────
readonly PLATFORM_NAME="Google Cloud e2-micro（共享 CPU 永久免费）"
readonly PLATFORM_DESC="1vCPU 共享 $(awk '/MemTotal/{printf "%.0fGB", $2/1024/1024}' /proc/meminfo) RAM, Google Cloud Always Free"

# ─────────────────────────────────────────────────────────────────────────────
# 平台差异变量（GCP e2-micro 专项，比 Oracle 1C4G 更保守，共享 CPU）
# ─────────────────────────────────────────────────────────────────────────────
readonly SYSCTL_FILE="/etc/sysctl.d/99-vps-youhua-gcp-e2.conf"
# journald volatile（重启丢失，GCP SSD 不需要 persistent。R4 FIX: volatile 是设计选择，非 bug；GCP SSD 持久性和 IOPS 足够好，不需要 journal 持久化）
readonly JOURNALD_STORAGE="volatile"
readonly JOURNALD_MAX_USE="50M"
readonly TMPFS_SIZE="256M"

# GCP e2-micro TCP 缓冲（内存3%，上限8MB，下限4MB）
# MemTotal($2)为KB，转换为字节后计算3%，单位一致
# MEDIUM FIX: 添加验证，防止 awk 失败导致空值被 readonly 锁定
TCP_BUF_MAX=$(awk '/MemTotal/{m=$2*1024; buf=m*3/100; if(buf>8388608) buf=8388608; if(buf<4194304) buf=4194304; printf "%d", buf}' /proc/meminfo)
[[ -z "$TCP_BUF_MAX" || ! "$TCP_BUF_MAX" =~ ^[0-9]+$ ]] && TCP_BUF_MAX=4194304
readonly TCP_BUF_MAX
readonly CT_MAX=16384
readonly SOMAXCONN=512
readonly NETDEV_BACKLOG=2048
readonly SWAPPINESS=5
readonly MIN_FREE_KB=8192

# ─────────────────────────────────────────────────────────────────────────────
# 加载通用函数库
# ─────────────────────────────────────────────────────────────────────────────
COMMON_OPTIMIZE_URL="https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/common-optimize.sh"

load_common_optimize() {
    # 优先从本地加载
    if [[ -f "$(dirname "${BASH_SOURCE[0]}")/common-optimize.sh" ]]; then
        source "$(dirname "${BASH_SOURCE[0]}")/common-optimize.sh"
        if declare -f log_step >/dev/null 2>&1; then
            return 0
        fi
        echo -e "\033[33m[!] 警告: 本地 common-optimize.sh 加载失败，尝试下载...\033[0m" >&2
    fi
    if [[ -f /tmp/vps-youhua-tmp/common-optimize.sh ]]; then
        source /tmp/vps-youhua-tmp/common-optimize.sh
        if declare -f log_step >/dev/null 2>&1; then
            return 0
        fi
        echo -e "\033[33m[!] 警告: /tmp/vps-youhua-tmp/common-optimize.sh 加载失败，尝试下载...\033[0m" >&2
    fi
    if [[ -f /tmp/vps-youhua/common-optimize.sh ]]; then
        source /tmp/vps-youhua/common-optimize.sh
        if declare -f log_step >/dev/null 2>&1; then
            return 0
        fi
        echo -e "\033[33m[!] 警告: /tmp/vps-youhua/common-optimize.sh 加载失败，尝试下载...\033[0m" >&2
    fi
    
    # 下载到临时目录（SHA256 完整性验证）
    local tmpdir="/tmp/vps-youhua"
    local sha256_expected="d5b94b48770d43216f2751bbd881aa2ff8ba9d856c4c9e56e3d91d07b9731e67"
    mkdir -p "$tmpdir"
    echo -e "\033[36m[➜] 下载 common-optimize.sh...\033[0m"
    if curl -fsSL "$COMMON_OPTIMIZE_URL" -o "${tmpdir}/common-optimize.sh"; then
        # SHA256 校验供应链安全
        local sha256_actual
        sha256_actual=$(sha256sum "${tmpdir}/common-optimize.sh" | awk '{print $1}')
        if [[ "$sha256_actual" != "$sha256_expected" ]]; then
            echo -e "\033[31m[✗] 错误: common-optimize.sh SHA256 校验失败\033[0m" >&2
            echo -e "\033[31m  期望: $sha256_expected\033[0m" >&2
            echo -e "\033[31m  实际: $sha256_actual\033[0m" >&2
            rm -f "${tmpdir}/common-optimize.sh"
            rmdir "$tmpdir" 2>/dev/null || true  # 清理空目录
            exit 1
        fi
        source "${tmpdir}/common-optimize.sh"
        if declare -f log_step >/dev/null 2>&1; then
            return 0
        fi
        echo -e "\033[31m[✗] 错误: common-optimize.sh 下载成功但加载失败\033[0m" >&2
        exit 1
    fi
    echo -e "\033[31m[✗] 错误: 无法下载 common-optimize.sh\033[0m" >&2
    exit 1
}

load_common_optimize

# ─────────────────────────────────────────────────────────────────────────────
# GCP Cloud 检测（通过官方元数据服务器）
# ─────────────────────────────────────────────────────────────────────────────
detect_gcp_cloud() {
    local gcp_meta
    gcp_meta=$(curl -s --connect-timeout 3 -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/machine-type" 2>/dev/null || echo "")

    if echo "$gcp_meta" | grep -qE "e2-micro|e2-small|e2-medium|f1-micro|g1-small"; then
        SYS_IS_GCP_CLOUD=true
        SYS_GCP_MACHINE_TYPE=$(echo "$gcp_meta" | grep -oE 'e2-micro|e2-small|e2-medium|f1-micro|g1-small' | head -1)
        log_info "GCP Cloud 检测通过（机型: ${SYS_GCP_MACHINE_TYPE}）"
    else
        SYS_IS_GCP_CLOUD=false
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# GCP Cloud 专属检测信息
# ─────────────────────────────────────────────────────────────────────────────
check_gcp_metadata() {
    log_step "检查 GCP Cloud 元数据..."

    local meta_status
    meta_status=$(curl -s --connect-timeout 3 -o /dev/null -w "%{http_code}" \
        -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/" 2>/dev/null || echo "000")

    if [[ "$meta_status" == "200" ]]; then
        local instance_name instance_zone
        instance_name=$(curl -s --connect-timeout 3 -H "Metadata-Flavor: Google" \
            "http://metadata.google.internal/computeMetadata/v1/instance/name" 2>/dev/null || echo "unknown")
        instance_zone=$(curl -s --connect-timeout 3 -H "Metadata-Flavor: Google" \
            "http://metadata.google.internal/computeMetadata/v1/instance/zone" 2>/dev/null | grep -o '[^/]*$' || echo "unknown")

        log_info "GCP 实例: ${instance_name}（${instance_zone}）"
        log_info "GCP 机型: ${SYS_GCP_MACHINE_TYPE:-未知}"

        # GCP google-guest-agent 状态（建议保留，用于 IP 配置和启动脚本）
        local guest_status
        guest_status=$(systemctl is-active google-guest-agent 2>/dev/null || echo "inactive")
        if [[ "$guest_status" == "active" ]]; then
            log_info "google-guest-agent 运行中（建议保留：处理 IP/路由/启动脚本）"
        else
            log_warn "google-guest-agent 未运行，可能影响 GCP 元数据访问"
        fi

        # GCP 外部 IP 信息
        local external_ip
        external_ip=$(curl -s --connect-timeout 3 -H "Metadata-Flavor: Google" \
            "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/externalIp" 2>/dev/null || echo "未分配")
        log_info "GCP 外部 IP: ${external_ip}"
    else
        log_info "非 GCP Cloud 环境或元数据端点不可访问"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# GCP Cloud 清理（可选，google-guest-agent 建议保留，其他可清理）
# ─────────────────────────────────────────────────────────────────────────────
gcp_cloud_cleanup() {
    [[ "$SYS_IS_GCP_CLOUD" != "true" ]] && return 0
    log_step "GCP Cloud 专属清理..."

    # 关闭 GCP 的 ce-susAttd（Google 的安全守护，消耗资源）
    # 只清理 ce-susAttd，保留 google-guest-agent（处理 IP/路由/启动脚本必需）
    # 其他 GCP 服务如 accounts-daemon/metadata-server 无需干预
    for svc in ce-susAttd; do
        if systemctl is-active "$svc" &>/dev/null; then
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
            log_info "已停止并禁用 $svc"
        fi
    done

    log_info "GCP Cloud 清理完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# 内存优化（GCP e2-micro 精简版）
# ─────────────────────────────────────────────────────────────────────────────
optimize_memory_gcp() {
    log_step "配置内存优化..."

    # 透明大页（Intel CPU，关闭 defrag 减少抖动）
    echo "never" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    echo "never" > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

    # zram 内存扩展（e2-micro 1GB，开启压缩约等效 +512MB）
    if ! modprobe zram 2>/dev/null; then
        log_warn "zram 模块不可用，跳过内存扩展"
        return 0
    fi

    local mem_kb
    mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo "0")
    if [[ ! "$mem_kb" =~ ^[0-9]+$ ]] || [[ "$mem_kb" -le 0 ]]; then
        log_warn "无法读取有效内存信息（mem_kb=${mem_kb}），跳过 zram"
        return 0
    fi
    local zram_size_bytes=$((mem_kb * 1024 / 2))

    # Round 10 Fix: 等待 zram 设备就绪（竞态条件修复）
    local retry=0
    while [[ $retry -lt 20 ]] && [[ ! -b /dev/zram0 ]]; do
        sleep 0.1
        retry=$((retry + 1))
    done

    local zram_dev="/dev/zram0"
    if [[ -f /sys/block/zram0/disksize ]]; then
        # 幂等性检查：如果 zram0 已激活且 disksize 匹配则跳过
        local current_disksize
        current_disksize=$(cat /sys/block/zram0/disksize 2>/dev/null || echo "0")
        if [[ "$current_disksize" == "$zram_size_bytes" ]] && swapon --show 2>/dev/null | grep -q "^/dev/zram0"; then
            log_info "zram0 已配置且 disksize 匹配，跳过（幂等性）"
            return 0
        fi
        # 重置 zram（如果已配置则先清理）
        if swapon --show 2>/dev/null | grep -q "^/dev/zram0"; then
            swapoff "${zram_dev}" 2>/dev/null || true
        fi
        # 重置 zram 设备（使用 reset 文件，比 disksize=0 更可靠）
        if [[ -f /sys/block/zram0/reset ]]; then
            sync
            echo 1 > /sys/block/zram0/reset 2>/dev/null || true
        fi
        # 设置压缩算法
        if [[ -f /sys/block/zram0/comp_algorithm ]]; then
            echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
        fi
        # 重新配置
        echo "${zram_size_bytes}" > /sys/block/zram0/disksize 2>/dev/null || true
        mkswap "${zram_dev}" >/dev/null 2>&1 || true
        swapon "${zram_dev}" -p 32767 2>/dev/null || true
        log_info "zram 开启，约 +$((zram_size_bytes / 1024 / 1024))MB 等效内存（lz4 压缩）"
    else
        log_warn "zram0 设备未就绪，跳过内存扩展"
    fi

    log_info "内存优化完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# sysctl GCP e2-micro 专项配置
# ─────────────────────────────────────────────────────────────────────────────

configure_sysctl_gcp() {
    log_step "配置 sysctl 系统参数..."

    backup_file "$SYSCTL_FILE"
    write_common_sysctl "$SYSCTL_FILE"

    cat >> "$SYSCTL_FILE" <<EOF
# ─────────────────────────────────────────────────────────────────────────────
# VPS-youhua Google Cloud e2-micro sysctl 配置
# 平台: GCP e2-micro 1vCPU 共享 1GB RAM
# 特点: 共享 CPU(burstable) + Intel + VPC 网络优化
# ─────────────────────────────────────────────────────────────────────────────

# ── 内存（1GB 精简）────────────────────────────────────────────────────────────
vm.swappiness = ${SWAPPINESS}  # 优先使用Swap保护内存（与configure_swap一致）
vm.min_free_kbytes = ${MIN_FREE_KB}
vm.vfs_cache_pressure = 50
vm.oom_kill_allocating_task = 1
vm.overcommit_memory = 1  # GCP 共享 CPU 允许内存超用
vm.dirty_ratio = 10
vm.dirty_background_ratio = 3
vm.dirty_writeback_centisecs = 15000
vm.dirty_expire_centisecs = 30000

# ── 网络（GCP VPC 优化，比普通 VPS 更高吞吐）─────────────────────────────────
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}
net.core.somaxconn = ${SOMAXCONN}
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15  # GCP 共享 CPU 快速回收
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
# SYN cookies for DDoS protection on proxy servers
net.ipv4.tcp_syncookies = 1

# ── TCP 缓冲（内存 3%，上限 8MB）──────────────────────────────────────────────
net.core.rmem_max = ${TCP_BUF_MAX}
net.core.wmem_max = ${TCP_BUF_MAX}
net.ipv4.tcp_rmem = 4096 131072 ${TCP_BUF_MAX}
net.ipv4.tcp_wmem = 4096 131072 ${TCP_BUF_MAX}

# ── 本地端口范围 ─────────────────────────────────────────────────────────────
net.ipv4.ip_local_port_range = 10240 65535

# ── ICMP ────────────────────────────────────────────────────────────────────
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# ── ARP ─────────────────────────────────────────────────────────────────────
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2

# ── GCP 共享 CPU 特化（burstable 0.2vCPU 基线）───────────────────────────────
# GCP e2-micro 实际可 burst 到 2vCPU，但基线仅 0.2vCPU
# 以下参数减少单进程 CPU 占用，让 burst 更平滑
kernel.sched_child_runs_first = 0
EOF

    # ── 可选参数：conntrack（需要 nf_conntrack 模块）────────────────────────────
    # GCP 内核可能未加载 nf_conntrack，尝试配置但不强制要求
    if [[ -f /proc/sys/net/netfilter/nf_conntrack_max ]]; then
        log_info "检测到 nf_conntrack 支持，配置连接跟踪参数..."
        cat >> "$SYSCTL_FILE" <<EOF

# ── conntrack（1GB 保守，仅基础 NAT）────────────────────────────────────────
net.netfilter.nf_conntrack_max = ${CT_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 1200
EOF
    else
        log_warn "nf_conntrack 模块未加载，跳过连接跟踪配置（不影响基础功能）"
    fi
    
    # ── 可选参数：调度器参数（GCP 内核可能不支持）──────────────────────────────
    # 尝试配置但不强制要求
    if [[ -f /proc/sys/kernel/sched_latency_ns ]]; then
        log_info "配置 CPU 调度器参数..."
        cat >> "$SYSCTL_FILE" <<EOF

# ── 调度器优化（共享 CPU 环境）────────────────────────────────────────────
kernel.sched_latency_ns = 10000000
kernel.sched_min_granularity_ns = 1000000
kernel.sched_wakeup_granularity_ns = 2000000
EOF
    else
        log_warn "内核不支持调度器参数配置（GCP 限制，不影响基础功能）"
    fi
    
    # 应用所有 sysctl 参数（忽略不支持的参数）
    sysctl -p "$SYSCTL_FILE" 2>&1 | grep -v "cannot stat" || true
    
    log_info "sysctl 参数配置完成（已跳过不支持的参数）"
}

# ─────────────────────────────────────────────────────────────────────────────
# GCP Cloud CPU 调度器（共享 CPU 防护：ondemand 省电防降频）
# ─────────────────────────────────────────────────────────────────────────────
optimize_cpu_gcp() {
    [[ "$SYS_IS_GCP_CLOUD" != "true" ]] && return 0
    log_step "配置 GCP Cloud CPU 调度器..."

    local avail_governors
    avail_governors=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || echo "")

    local chosen="ondemand"
    if echo "$avail_governors" | grep -qw "conservative"; then
        chosen="conservative"
        log_info "CPU 调度器: conservative"
    elif echo "$avail_governors" | grep -qw "ondemand"; then
        log_info "CPU 调度器: ondemand"
    else
        log_warn "CPU 调度器不可调: $avail_governors"
        return 0
    fi

    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
        local gf="$cpu/cpufreq/scaling_governor"
        [[ -f "$gf" ]] && echo "$chosen" > "$gf" 2>/dev/null || true
    done

    local cur; cur=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
    log_info "CPU 调度器: $cur"
}

# ─────────────────────────────────────────────────────────────────────────────
# GCP Cloud 网络优化（VPC + 共享 CPU）
# ─────────────────────────────────────────────────────────────────────────────
optimize_network_gcp() {
    SYS_CPU_CORES=${SYS_CPU_CORES:-$(nproc 2>/dev/null || echo 1)}
    log_step "优化 GCP Cloud 网络..."

    # GCP VPC 网卡优化
    for iface in /sys/class/net/en* /sys/class/net/eth* /sys/class/net/gcp*; do
        [[ -d "$iface" ]] || continue
        local name; name=$(basename "$iface")

        # GCP Virtio 网卡优化
        ethtool -K "$name" tso on 2>/dev/null || true
        ethtool -K "$name" gso on 2>/dev/null || true
        ethtool -K "$name" gro on 2>/dev/null || true
        ethtool -K "$name" tx-gso-robust on 2>/dev/null || true
        ethtool -s "$name" tx-queue-len 1000 2>/dev/null || true

        # RPS（多核时启用，单核跳过）
        if [[ $SYS_CPU_CORES -gt 1 ]]; then
            local cores=$((SYS_CPU_CORES > 63 ? 63 : SYS_CPU_CORES))
            if [[ $cores -gt 0 ]]; then
                local mask; mask=$(printf '%x' $(( (1 << cores) - 1 )))
                for rps_file in /sys/class/net/${name}/queues/rx-*/rps_cpus; do
                    [[ -f "$rps_file" ]] || continue
                    printf "%s" "$mask" > "$rps_file" 2>/dev/null || true
                done
            fi
        fi

        log_info "网卡 $name 已优化"
    done

    # GCP 元数据 IP 路由确认
    if ip route get 8.8.8.8 2>/dev/null | grep -q "via"; then
        log_info "默认路由正常（via $(ip route get 8.8.8.8 2>/dev/null | awk '{print $3; exit}'))"
    fi

    log_info "GCP Cloud 网络优化完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# conntrack hashsize 配置（GCP e2-micro 专用）
# BUG#6e FIX: nf_conntrack_hashsize 是只读参数，不能通过 sysctl 设置
# ─────────────────────────────────────────────────────────────────────────────
configure_conntrack_hashsize() {
    log_step "配置 nf_conntrack_hashsize（GCP）..."

    modprobe nf_conntrack 2>/dev/null || true

    local hashsize_file="/sys/module/nf_conntrack/parameters/hashsize"
    local hashsize=$((CT_MAX / 4))
    if [[ -f "$hashsize_file" ]]; then
        echo "$hashsize" > "$hashsize_file" 2>/dev/null || {
            log_warn "nf_conntrack_hashsize 设置失败，写入 modprobe 配置（下次启动生效）"
            mkdir -p /etc/modprobe.d
            echo "options nf_conntrack hashsize=$hashsize" > /etc/modprobe.d/nf_conntrack.conf
        }
        local current_hashsize
        current_hashsize=$(cat "$hashsize_file" 2>/dev/null || echo "unknown")
        log_info "nf_conntrack_hashsize 已设置: ${current_hashsize}"
    else
        log_warn "nf_conntrack 模块未加载或不支持，跳过 hashsize 配置"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# OOM Killer
# ─────────────────────────────────────────────────────────────────────────────
optimize_oom() {
    log_step "配置 OOM Killer..."
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/99-oom-policy.conf <<'EOF'
[Manager]
OOMPolicy=continue
OOMScoreAdjust=-500
EOF
    systemctl daemon-reload 2>/dev/null || true
    log_info "OOM Killer 配置完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# journald
# ─────────────────────────────────────────────────────────────────────────────
configure_journald() {
    log_step "配置 journald 日志..."
    local journald_conf="/etc/systemd/journald.conf.d/99-vps-youhua.conf"
    
    # 备份现有配置
    [[ -f "$journald_conf" ]] && backup_file "$journald_conf"
    
    mkdir -p /etc/systemd/journald.conf.d
    cat > "$journald_conf" <<EOF
[Journal]
Storage=${JOURNALD_STORAGE}
SystemMaxUse=${JOURNALD_MAX_USE}
# 同时设置 SystemMaxUse 和 MaxRetentionSec=7day：
# SystemMaxUse=50M 限制磁盘占用，MaxRetentionSec=7day 限制日志保留时间
# 双重保险确保 e2-micro 30GB SSD 不会被日志撑满
SystemMaxFileSize=10M
MaxRetentionSec=7day
Compress=yes
EOF
    systemctl restart systemd-journald 2>/dev/null || true
    log_info "journald 已配置（${JOURNALD_STORAGE}，上限 ${JOURNALD_MAX_USE}）"
}

# ─────────────────────────────────────────────────────────────────────────────
# /tmp tmpfs
# ─────────────────────────────────────────────────────────────────────────────
configure_tmp_tmpfs() {
    log_step "配置 /tmp tmpfs..."
    if mount | grep -q "tmpfs on /tmp"; then
        log_info "/tmp 已是 tmpfs，跳过"
        return 0
    fi
    mkdir -p /tmp
    if mount -t tmpfs -o size=${TMPFS_SIZE},mode=1777,nosuid,nodev tmpfs /tmp 2>/dev/null; then
        # MEDIUM FIX: 改进 grep 模式，避免匹配注释行
        if ! grep -q "^[^#]*tmpfs[[:space:]]/tmp[[:space:]]tmpfs" /etc/fstab 2>/dev/null; then
            echo "tmpfs /tmp tmpfs size=${TMPFS_SIZE},mode=1777,nosuid,nodev 0 0" >> /etc/fstab
        fi
        log_info "/tmp tmpfs 已配置（${TMPFS_SIZE}）"
    else
        log_warn "/tmp tmpfs 挂载失败，跳过 fstab 写入"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 清理定时任务
# ─────────────────────────────────────────────────────────────────────────────
configure_cleanup_cron() {
    log_step "配置定时清理..."
    mkdir -p /etc/cron.daily
    cat > /etc/cron.daily/vps-youhua-clean <<'EOF'
#!/bin/sh
# 每日清理（GCP e2-micro 精简版）
journalctl --vacuum-time=3d 2>/dev/null || true
apt-get clean 2>/dev/null || true
rm -rf /tmp/pear 2>/dev/null || true
rm -rf /var/cache/apt/archives/*.deb 2>/dev/null || true
EOF
    chmod +x /etc/cron.daily/vps-youhua-clean
    log_info "每日清理任务已配置"
}

# ─────────────────────────────────────────────────────────────────────────────
# 诊断报告
# ─────────────────────────────────────────────────────────────────────────────
run_doctor() {
    log_step "运行诊断..."
    echo ""
    echo "=== VPS-youhua 环境诊断报告 (Google Cloud e2-micro) ==="
    echo ""
    echo "1. 系统信息:"
    echo "   平台: $PLATFORM_NAME"
    echo "   系统: $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)"
    echo "   内核: $(uname -r)"
    echo "   架构: $(uname -m)"
    echo "   CPU: $SYS_CPU_CORES 核（共享 CPU，burst 到 2vCPU）"
    echo "   内存: ${SYS_MEM_MB}MB"
    echo ""
    echo "2. GCP Cloud:"
    echo "   GCP Cloud: $SYS_IS_GCP_CLOUD"
    echo "   机型: ${SYS_GCP_MACHINE_TYPE:-未知}"
    echo "   google-guest-agent: $(systemctl is-active google-guest-agent 2>/dev/null || echo '未运行')"
    echo ""
    echo "3. 资源限制:"
    echo "   Conntrack: ${CT_MAX}（精简，仅基础 NAT）"
    echo "   SOMAXCONN: ${SOMAXCONN}"
    echo "   TCP缓冲: $(numfmt --to=iec-i --suffix=B $TCP_BUF_MAX 2>/dev/null || echo "${TCP_BUF_MAX} bytes")"
    echo "   Swappiness: $SWAPPINESS"
    echo ""
    echo "4. 网络:"
    echo "   BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')"
    echo "   qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo '未知')"
    echo ""
    echo "5. 存储:"
    # Round 10 Fix: 使用 tail -1 而不是 NR==2，避免文件系统名称过长导致换行时解析失败
    echo "   /tmp: $(df -h /tmp 2>/dev/null | tail -1 | awk '{print $2}' || echo 'tmpfs')"
    echo "   journald: $(journalctl --disk-usage 2>/dev/null | awk '{print $1,$2}' || echo '正常')"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# 卸载函数（BUG#FIX: google-cloud-e2.sh 原缺少卸载函数）
# ─────────────────────────────────────────────────────────────────────────────
uninstall_all() {
    echo ""
    echo "========================================================================"
    echo -e "${RED}  VPS-youhua 卸载 / 回滚${NC}"
    echo "========================================================================"
    echo ""

    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[✗] 需要 root 权限${NC}"
        exit 1
    fi

    if [[ "${1:-}" != "--uninstall" ]]; then
        return 0
    fi

    echo -e "${YELLOW}警告：此操作将删除所有 VPS-youhua 优化配置！${NC}"
    echo ""
    # 非交互卸载时跳过确认提示
    if [[ "${FORCE_UNINSTALL:-false}" != "true" ]]; then
        echo -n "确认卸载？(输入 'yes' 继续): "
        read -r -t 30 confirm || confirm=""
        confirm="${confirm,,}"
        if [[ -z "$confirm" ]]; then
            echo "已取消卸载（未检测到 TTY，请设置 FORCE_UNINSTALL=true 强制卸载）。"
            exit 0
        fi
        if [[ "$confirm" != "yes" ]]; then
            echo "已取消卸载。"
            exit 0
        fi
    fi

    echo ""
    echo -e "${CYAN}[➜] 开始卸载...${NC}"

    # 清理所有配置文件
    rm -f "$SYSCTL_FILE"
    rm -f /etc/systemd/journald.conf.d/99-vps-youhua.conf
    rm -f /etc/security/limits.d/99-vps-youhua.conf
    rm -f /etc/systemd/system.conf.d/99-memory-accounting.conf
    rm -f /etc/systemd/system.conf.d/99-resource-limits.conf
    rm -f /etc/systemd/system.conf.d/99-oom-policy.conf
    rm -f /etc/ssh/sshd_config.d/99-vps-youhua.conf
    rm -f /etc/cron.daily/vps-youhua-clean
    # BUG#6e FIX: 清理 conntrack hashsize 配置
    rm -f /etc/modprobe.d/nf_conntrack.conf
    rm -f /etc/logrotate.d/vps-youhua
    rm -f /etc/apt/apt.conf.d/99-noninteractive
    rm -f /etc/apt/apt.conf.d/99-vps-youhua-no-unattended
    rm -f /etc/apt/apt.conf.d/99-vps-youhua-unattended
    rm -f /etc/needrestart/conf.d/99-vps-youhua.conf
    rm -f /etc/profile.d/99-agent-cache.sh

    systemctl daemon-reload 2>/dev/null || true

    # 卸载 /tmp tmpfs
    if mount | grep -q "tmpfs on /tmp"; then
        umount /tmp 2>/dev/null || log_warn "umount /tmp 失败（可能被进程占用），建议重启系统"
        log_info "/tmp tmpfs 已卸载"
    fi

    # 清理 fstab tmpfs 条目
    sed -i '/tmpfs.*\/tmp.*tmpfs/d' /etc/fstab 2>/dev/null || true
    log_info "fstab tmpfs 条目已清理"

    # BUG#FIX: 清理 zram swap（google-cloud-e2 和 generic-1c1g 都开启了 zram）
    if swapon --show 2>/dev/null | grep -q "/dev/zram0"; then
        swapoff /dev/zram0 2>/dev/null || true
        log_info "zram0 swapoff 完成"
    fi
    # 清理 zram 模块配置（下次启动不自动加载）
    rm -f /etc/modprobe.d/zram 2>/dev/null || true

    # 清理 iptables 规则
    iptables -D INPUT -i lo -j ACCEPT 2>/dev/null || true
    log_info "iptables 规则已清理"

    # 清理优化标记文件
    rm -f /etc/vps-youhua-optimized
    log_info "优化标记文件已清理"

    echo ""
    echo "========================================================================"
    echo -e "${GREEN}  ✅ VPS-youhua 卸载完成${NC}"
    echo -e "${YELLOW}  ⚠️  建议重启系统以确保所有更改生效: sudo reboot${NC}"
    echo "========================================================================"
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 软件安装桩函数（低配平台不支持 Docker/Node.js）
# 由于内存限制（e2-micro 0.5C1G），这些平台不安装 Docker 和 Node.js 以避免资源耗尽
# ─────────────────────────────────────────────────────────────────────────────
install_build_deps() {
    log_step "安装编译依赖..."
    log_info "正在安装编译依赖..."
    install_if_missing build-essential cmake pkg-config libssl-dev \
        python3-venv python3-dev python3-pip \
        libffi-dev libxml2-dev libxslt1-dev zlib1g-dev
    log_info "编译依赖安装完成"
}

install_docker() {
    # TODO: 提取到 common-optimize.sh（低配平台统一跳过逻辑）
    log_warn "Docker 安装在此低配平台跳过（内存限制）"
    return 0
}
install_nodejs() {
    log_warn "Node.js 安装在此低配平台跳过（内存限制）"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 主函数
# ─────────────────────────────────────────────────────────────────────────────
main() {
    for arg in "$@"; do
        case "$arg" in
            --optimize-only) export SKIP_SOFTWARE_SCRIPT="true" ;;
            --uninstall) ;;
        esac
    done

    : "${SKIP_SOFTWARE_SCRIPT:=false}"
    FORCE_REAPPLY="${FORCE_REAPPLY:-false}"

    if [[ "${1:-}" == "--uninstall" ]]; then
        uninstall_all "$@"
        exit $?
    fi

    clear
    echo "========================================================================"
    echo -e "${GREEN}  Google Cloud e2-micro 共享 CPU 优化脚本 v${SCRIPT_VERSION}${NC}"
    echo "========================================================================"
    echo ""
    echo -e "${YELLOW}  ⚠️  GCP Always Free 永久免费机型${NC}"
    echo -e "${YELLOW}  CPU: 共享 1vCPU（burst 到 2vCPU，基线 0.2vCPU）${NC}"
    echo -e "${YELLOW}  内存: 1GB | 存储: 30GB SSD${NC}"
    echo ""

    init_script
    check_idempotent
    # BUG#6 FIX: optimize_memory_gcp 先运行（决定是否需要 swap），configure_swap 后判断
    optimize_memory_gcp
    configure_swap
    # BUG#5: IPv6 黑洞检测
    configure_ipv6_health
    # BUG#7: DNS 锁定防篡改
    configure_dns_lock
    detect_system
    detect_gcp_cloud
    check_gcp_metadata
    check_network
    preflight_check

    show_platform_summary

    if [[ -t 0 ]]; then
        echo -n "继续执行？(y/n，默认 y): "
        read -r -t 30 confirm || confirm="y"
        [[ "$confirm" == "n" || "$confirm" == "N" ]] && exit 0
    fi

    echo ""
    log_step "[1/12] 开始优化..."
    echo ""

    backup_all
    configure_apt_sources
    clean_system
    gcp_cloud_cleanup
    configure_sysctl_gcp
    configure_conntrack_hashsize
    configure_limits

    # BUG#8: 低内存极限清理
    [[ "${IS_LOW_MEMORY}" == "true" ]] && configure_lowmem_purge
    configure_fstab
    configure_journald
    configure_dns
    configure_time_sync
    configure_locale
    configure_firewall_lo
    configure_tmp_tmpfs
    # BUG#FIX: 补充通用函数调用
    configure_npm_cache_tmpfs
    configure_memory_accounting
    optimize_oom
    optimize_cpu_gcp
    optimize_network_gcp
    configure_cleanup_cron
    configure_entropy
    configure_logrotate
    local did_install=false
    # e2-micro 1GB 内存：跳过 unattended-upgrades（后台进程太重）
    # e2-micro 1GB 内存：跳过 fail2ban（Python 占用内存太多）
    optimize_ssh  # SSH 硬化（来自 common-optimize.sh），不装 fail2ban
    # Proxy-only 平台：Docker/Node.js 由上级平台管理，本脚本只做网络优化

    # BUG#46 Fix: install_build_deps 独立于 SKIP_SOFTWARE_SCRIPT
    # INSTALL_DEPS 由用户选择决定（Option 2 = true），与 Docker/NodeJS 分开
    # SKIP_SOFTWARE_SCRIPT 只阻止 Docker/NodeJS，不阻止编译依赖
    if [[ "${INSTALL_DEPS}" == "true" ]]; then
        install_build_deps
    fi
    # Proxy-only 平台不安装 Docker / Node.js
    if [[ "${SKIP_SOFTWARE_SCRIPT}" == "true" ]]; then
        log_info "纯优化模式，跳过 Docker / Node.js 安装"
    fi

    run_doctor || { log_warn "诊断报告有异常，但继续完成"; }

    apt-get autoremove -y >> "$APT_LOG" 2>&1 || true
    apt-get autoclean >> "$APT_LOG" 2>&1 || true

    echo ""
    echo "========================================================================"
    echo -e "${GREEN}  ✅ GCP e2-micro v${SCRIPT_VERSION} 优化完成！${NC}"
    echo "========================================================================"
    echo ""
    echo -e "${CYAN}系统优化内容:${NC}"
    echo "  - TCP 缓冲: $(numfmt --to=iec-i --suffix=B $TCP_BUF_MAX 2>/dev/null || echo "${TCP_BUF_MAX} bytes")"
    echo "  - conntrack: ${CT_MAX}（精简，仅够基础 NAT）"
    echo "  - zram 内存扩展（约 +512MB 等效内存）"
    echo "  - BBR + fq qdisc"
    echo "  - journald: volatile + ${JOURNALD_MAX_USE} 限制"
    echo "  - /tmp: tmpfs ${TMPFS_SIZE}"
    echo "  - GCP Virtio 网卡优化"
    echo "  - CPU burst 调度优化（madvise THP + sched 参数）"
    echo -e "${YELLOW}  ⚠  未安装 fail2ban / unattended-upgrades（1GB 内存保留）${NC}"
    echo ""
    echo -e "${YELLOW}日志: ${APT_LOG}${NC}"
    echo ""

    # ── 写入优化完成标记（供幂等性检测使用）────────────────────────────────
    date > /etc/vps-youhua-optimized 2>/dev/null || true
    chmod 444 /etc/vps-youhua-optimized 2>/dev/null || true

    return 0
}

trap 'log_error "脚本异常退出 (行: ${LINENO})"; exit 1' ERR
trap 'log_warn "被中断"; exit 130' INT TERM

main "$@"
