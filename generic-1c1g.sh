#!/bin/bash
#
# VPS 优化脚本 - 通用 1核 1G VPS
#
# 用法:
#   sudo bash generic-1c1g.sh                    # 完整安装（底层优化 + 软件依赖）
#   sudo bash generic-1c1g.sh --optimize-only    # 仅底层优化
#   sudo bash generic-1c1g.sh --uninstall        # 卸载所有优化
#
# 功能:
#   - 系统内核参数优化（网络、内存、文件系统）
#   - 安全加固（SSH、防火墙）
#   - 性能调优（swap、tmpfs、I/O调度）
#   - 可选软件安装（Docker、Node.js、开发工具）
#
# 项目: https://github.com/vpn3288/VPS-youhua
#
# 修复: 非交互式环境（如SSH远程执行）需要 TERM 变量
: "${TERM:=xterm}"
set -euo pipefail
# =============================================================================
# 通用 1核 1G VPS 极简优化安装脚本 v3.4
# 硬件: 任意 1核 1GB x86_64 VPS（最低配套餐）
# 特点: 极简资源占用优化（适用于 1GB 及以下超小内存 VPS）
#       去除所有重资源功能（fail2ban / unattended-upgrades / zram 替代 swap）
# =============================================================================
#
# 一键运行: bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/generic-1c1g.sh)
#
# 模式说明:
#   --optimize-only   纯环境优化（不安装任何额外软件）
#   --uninstall       卸载所有优化配置
#

# ─────────────────────────────────────────────────────────────────────────────
# 平台信息
# ─────────────────────────────────────────────────────────────────────────────
readonly PLATFORM_NAME="通用 1核 1G VPS"
readonly PLATFORM_DESC="1核 1GB x86_64 $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo 'Debian')"

# ─────────────────────────────────────────────────────────────────────────────
# 平台差异变量（1核1G 极简版）
# ─────────────────────────────────────────────────────────────────────────────
readonly SYSCTL_FILE="/etc/sysctl.d/99-vps-youhua-generic-1c1g.conf"
# journald volatile（重启丢失，节省磁盘 I/O）
readonly JOURNALD_STORAGE="volatile"
readonly JOURNALD_MAX_USE="30M"
readonly TMPFS_SIZE="256M"

# 1C1G TCP 缓冲（极保守：内存 3%，上限 8MB，下限 4MB）
TCP_BUF_MAX=$(awk '/MemTotal/{m=$2/1024/1024;t=m*31457280;if(t>8388608)t=8388608;else if(t<4194304)t=4194304;printf "%.0f",t}' /proc/meminfo)
readonly TCP_BUF_MAX
readonly CT_MAX=16384
readonly SOMAXCONN=512       # 1C1G 低资源限制
readonly NETDEV_BACKLOG=2048  # 1C1G
readonly SWAPPINESS=1
readonly MIN_FREE_KB=16384  # 1C1G 防止OOM

# ─────────────────────────────────────────────────────────────────────────────
# 加载通用函数库
# ─────────────────────────────────────────────────────────────────────────────
COMMON_OPTIMIZE_URL="https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/common-optimize.sh"

load_common_optimize() {
    # 优先从本地加载
    if [[ -f "$(dirname "${BASH_SOURCE[0]}")/common-optimize.sh" ]]; then
        source "$(dirname "${BASH_SOURCE[0]}")/common-optimize.sh"
        return 0
    fi
    if [[ -f /tmp/vps-youhua-tmp/common-optimize.sh ]]; then
        source /tmp/vps-youhua-tmp/common-optimize.sh
        return 0
    fi
    if [[ -f /tmp/vps-youhua/common-optimize.sh ]]; then
        source /tmp/vps-youhua/common-optimize.sh
        return 0
    fi
    
    # 下载到临时目录（SHA256 完整性验证）
    local tmpdir="/tmp/vps-youhua"
    local sha256_expected="26b2fe9227954fae688d60da54046fbaae34c09fddd47084d715e5b72d95f3a8"
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
            exit 1
        fi
        source "${tmpdir}/common-optimize.sh"
        return 0
    fi
    echo -e "\033[31m[✗] 错误: 无法下载 common-optimize.sh\033[0m" >&2
    exit 1
}

load_common_optimize

# ─────────────────────────────────────────────────────────────────────────────
# sysctl 1核1G 极简配置
# ─────────────────────────────────────────────────────────────────────────────

configure_sysctl_generic_1c1g() {
    log_step "配置 sysctl 系统参数..."

    write_common_sysctl "$SYSCTL_FILE"

    cat >> "$SYSCTL_FILE" <<EOF
# ─────────────────────────────────────────────────────────────────────────────
# VPS-youhua 通用 1核 1G VPS sysctl 极简配置
# 平台: 任意 1核 1GB x86_64 VPS
# ─────────────────────────────────────────────────────────────────────────────

# ── 内存（极保守）─────────────────────────────────────────────────────────────
vm.swappiness = ${SWAPPINESS}
vm.min_free_kbytes = ${MIN_FREE_KB}
vm.vfs_cache_pressure = 50
vm.oom_kill_allocating_task = 1
vm.dirty_ratio = 10
vm.dirty_background_ratio = 3
vm.dirty_writeback_centisecs = 15000
vm.dirty_expire_centisecs = 30000

# ── 网络（极保守）─────────────────────────────────────────────────────────────
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}
net.core.somaxconn = ${SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = 1024  # 1C1G 低资源
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fastopen = 3  # TFO降低延迟
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
# SYN cookies for DDoS protection on proxy servers
net.ipv4.tcp_syncookies = 1

# ── conntrack（1C1G 极小）─────────────────────────────────────────────────────
net.netfilter.nf_conntrack_max = 32768
# AUDIT-FIX: nf_conntrack_buckets 是只读参数，不能通过 sysctl 设置
# hashsize 将由 configure_conntrack_hashsize_1c1g() 通过 /sys/module 设置
net.netfilter.nf_conntrack_tcp_timeout_established = 1200

# ── TCP 缓冲（内存 3%，极小）──────────────────────────────────────────────────
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
EOF

    if sysctl -p "$SYSCTL_FILE" 2>&1 | grep -v "^$" | head -5; then
        log_info "sysctl 参数已应用（$SYSCTL_FILE）"
    else
        log_warn "sysctl 部分参数不支持当前内核（可忽略）"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# zram 内存扩展（1GB 物理内存的 50%，等效 +512MB）
# ─────────────────────────────────────────────────────────────────────────────
configure_zram_1c1g() {
    log_step "配置 zram 内存扩展..."

    if ! modprobe zram 2>/dev/null; then
        log_warn "zram 模块不可用，跳过内存扩展"
        return 0
    fi

    local mem_kb
    mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    local zram_size_bytes=$((mem_kb * 1024 / 2))

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
            echo 1 > /sys/block/zram0/reset 2>/dev/null || true
        fi
        # 重新配置
        echo "${zram_size_bytes}" > /sys/block/zram0/disksize 2>/dev/null || true
        mkswap "${zram_dev}" >/dev/null 2>&1 || true
        swapon "${zram_dev}" -p 32767 2>/dev/null || true
        log_info "zram 开启，约 +$((zram_size_bytes / 1024 / 1024))MB 等效内存（lz4 压缩）"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# conntrack hashsize 配置（generic-1c1g 专用）
# AUDIT-FIX: nf_conntrack_buckets 是只读参数，不能通过 sysctl 设置
# ─────────────────────────────────────────────────────────────────────────────
configure_conntrack_hashsize() {
    log_step "配置 nf_conntrack_hashsize（1C1G）..."

    modprobe nf_conntrack 2>/dev/null || true

    local hashsize_file="/sys/module/nf_conntrack/parameters/hashsize"
    local ct_max="${CT_MAX:-16384}"
    if [[ -f "$hashsize_file" ]]; then
        echo "${ct_max}" > "$hashsize_file" 2>/dev/null || {
            log_warn "nf_conntrack_hashsize 设置失败，尝试 modprobe 配置"
            mkdir -p /etc/modprobe.d
            echo "options nf_conntrack hashsize=${ct_max}" > /etc/modprobe.d/nf_conntrack.conf
        }
        local current_hashsize
        current_hashsize=$(cat "$hashsize_file" 2>/dev/null || echo "unknown")
        log_info "nf_conntrack_hashsize 已设置: ${current_hashsize}"
    else
        log_warn "nf_conntrack 模块未加载或不支持，跳过 hashsize 配置"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# journald 极简配置
# ─────────────────────────────────────────────────────────────────────────────
configure_journald() {
    log_step "配置 journald 日志（极简模式）..."
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-vps-youhua.conf <<EOF
[Journal]
Storage=${JOURNALD_STORAGE}
SystemMaxUse=${JOURNALD_MAX_USE}
SystemMaxFileSize=10M
MaxRetentionSec=3day
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
    mount -t tmpfs -o size=${TMPFS_SIZE},mode=1777,nosuid,nodev tmpfs /tmp 2>/dev/null || true
    if ! awk '$2=="/tmp" && $3=="tmpfs"' /etc/fstab > /dev/null 2>&1; then
        echo "tmpfs /tmp tmpfs size=${TMPFS_SIZE},mode=1777,nosuid,nodev 0 0" >> /etc/fstab
    fi
    log_info "/tmp tmpfs 已配置（${TMPFS_SIZE}）"
}

# ─────────────────────────────────────────────────────────────────────────────
# 清理定时任务
# ─────────────────────────────────────────────────────────────────────────────
configure_cleanup_cron() {
    log_step "配置定时清理..."
    mkdir -p /etc/cron.daily
    cat > /etc/cron.daily/vps-youhua-clean <<'EOF'
#!/bin/sh
# 每日清理（1核1G 极简版）
journalctl --vacuum-time=2d 2>/dev/null || true
apt-get clean 2>/dev/null || true
rm -rf /tmp/pear 2>/dev/null || true
rm -rf /var/cache/apt/archives/*.deb 2>/dev/null || true
rm -rf /var/tmp/* 2>/dev/null || true
EOF
    chmod +x /etc/cron.daily/vps-youhua-clean
    log_info "每日清理任务已配置"
}

# ─────────────────────────────────────────────────────────────────────────────
# OOM
# ─────────────────────────────────────────────────────────────────────────────
optimize_oom() {
    log_step "配置 OOM Killer..."
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/99-oom-policy.conf <<'EOF'
[Manager]
OOMPolicy=continue
OOMScoreAdjust=-900
EOF
    systemctl daemon-reload 2>/dev/null || true
    log_info "OOM Killer 配置完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# 诊断报告
# ─────────────────────────────────────────────────────────────────────────────
run_doctor() {
    log_step "运行诊断..."
    echo ""
    echo "=== VPS-youhua 环境诊断报告 (通用 1核 1G VPS) ==="
    echo ""
    echo "1. 系统信息:"
    echo "   平台: $PLATFORM_NAME"
    echo "   系统: $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)"
    echo "   内核: $(uname -r)"
    echo "   架构: $(uname -m)"
    echo "   CPU: $SYS_CPU_CORES 核"
    echo "   内存: ${SYS_MEM_MB}MB"
    echo ""
    echo "2. 资源限制:"
    echo "   Conntrack: ${CT_MAX}（极小，仅够 NAT 转发）"
    echo "   SOMAXCONN: ${SOMAXCONN}"
    echo "   TCP缓冲: $(numfmt --to=iec-i --suffix=B $TCP_BUF_MAX 2>/dev/null || echo "${TCP_BUF_MAX} bytes")"
    echo "   Swappiness: $SWAPPINESS（极保守，优先用内存）"
    echo "   zram: $(swapon --show 2>/dev/null | grep zram0 | awk '{print $3}' || echo '未启用')"
    echo ""
    echo "3. 网络:"
    echo "   BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')"
    echo "   qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo '未知')"
    echo ""
    echo "4. 存储:"
    echo "   /tmp: $(df -h /tmp 2>/dev/null | awk 'NR==2 {print $2}' || echo 'tmpfs')"
    echo "   journald: $(journalctl --disk-usage 2>/dev/null | awk '{print $1,$2}' || echo '正常')"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# 卸载函数（BUG#FIX: generic-1c1g.sh 原缺少卸载函数）
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

    # 非交互式环境（如SSH远程执行/cron）检查 FORCE_UNINSTALL
    if [[ -t 0 ]]; then
        echo -e "${YELLOW}警告：此操作将删除所有 VPS-youhua 优化配置！${NC}"
        echo ""
        echo -n "确认卸载？(输入 'yes' 继续): "
        read -r -t 30 confirm || confirm=""
        confirm="${confirm,,}"
        if [[ -z "$confirm" ]]; then
            if [[ "${FORCE_UNINSTALL:-false}" == "true" ]]; then
                confirm="yes"
            else
                echo "已取消卸载（未检测到 TTY，请设置 FORCE_UNINSTALL=true 强制卸载）。"
                exit 0
            fi
        fi
        [[ "$confirm" != "yes" ]] && { echo "已取消。"; exit 0; }
    else
        # 非交互环境（SSH远程执行/cron）：检查 FORCE_UNINSTALL 变量
        if [[ "${FORCE_UNINSTALL:-false}" != "true" ]]; then
            echo "已取消卸载（未检测到 TTY，请设置 FORCE_UNINSTALL=true 强制卸载）。"
            exit 0
        fi
        log_info "非交互模式 + FORCE_UNINSTALL=true，自动确认卸载"
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

    # BUG#6d FIX: 清理 conntrack hashsize 配置
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
        umount /tmp 2>/dev/null || true
        log_info "/tmp tmpfs 已卸载"
    fi

    # 清理 fstab tmpfs 条目
    sed -i '/tmpfs.*\/tmp.*tmpfs/d' /etc/fstab 2>/dev/null || true
    log_info "fstab tmpfs 条目已清理"

    # BUG#FIX: 清理 zram swap（generic-1c1g 开启了 zram）
    if [[ -b /dev/zram0 ]] && swapon --show 2>/dev/null | grep -q "/dev/zram0"; then
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
# 软件安装桩函数（generic-1c1g 调用 install_docker / install_nodejs）
# BUG#15+17: 编译依赖（python3-venv/cmake/pkg-config/libssl-dev）
install_build_deps() {
    log_step "安装编译依赖..."
    install_if_missing build-essential cmake pkg-config libssl-dev \
        python3-venv python3-dev python3-pip \
        libffi-dev libxml2-dev libxslt1-dev zlib1g-dev
    log_info "编译依赖安装完成"
}

install_docker() {
    log_warn "Docker 安装未对此平台实现，跳过"
    return 0
}
install_nodejs() {
    log_warn "Node.js 安装未对此平台实现，跳过"
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

    uninstall_all "$@" || exit 1

    clear
    echo "========================================================================"
    echo -e "${GREEN}  通用 1核 1G VPS 极简优化脚本 v${SCRIPT_VERSION}${NC}"
    echo "========================================================================"
    echo ""

    init_script
    check_idempotent
    # BUG#5: IPv6 黑洞检测
    configure_ipv6_health
    # BUG#7: DNS 锁定防篡改
    configure_dns_lock
    detect_system
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
    configure_sysctl_generic_1c1g
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
    configure_zram_1c1g
    # BUG#FIX: 补充通用函数调用
    configure_npm_cache_tmpfs
    configure_memory_accounting
    optimize_oom
    # 1核1G 不安装 unattended-upgrades（太重后台进程）
    configure_cleanup_cron
    configure_logrotate
    # 1核1G 不安装 fail2ban（太重，1GB 内存撑不住）

    # BUG#46 Fix: install_build_deps 独立于 SKIP_SOFTWARE_SCRIPT
    # INSTALL_DEPS 由用户选择决定（Option 2 = true），与 Docker/NodeJS 分开
    # SKIP_SOFTWARE_SCRIPT 只阻止 Docker/NodeJS，不阻止编译依赖
    if [[ "${INSTALL_DEPS}" == "true" ]]; then
        install_build_deps
    fi
    if [[ "${SKIP_SOFTWARE_SCRIPT}" == "true" ]]; then
        log_info "代理节点专用模式，跳过 Docker / Node.js 安装"
    fi

    run_doctor || { log_warn "诊断报告有异常，但继续完成"; }

    apt-get autoremove -y >> "$APT_LOG" 2>&1 || true
    apt-get autoclean >> "$APT_LOG" 2>&1 || true

    echo ""
    echo "========================================================================"
    echo -e "${GREEN}  ✅ 通用 1核 1G VPS v${SCRIPT_VERSION} 优化完成！${NC}"
    echo "========================================================================"
    echo ""
    echo -e "${CYAN}系统优化内容:${NC}"
    echo "  - TCP 缓冲: $(numfmt --to=iec-i --suffix=B $TCP_BUF_MAX 2>/dev/null || echo "${TCP_BUF_MAX} bytes")（极保守）"
    echo "  - conntrack: ${CT_MAX}（仅够 NAT 基础转发）"
    echo "  - zram 内存扩展（已启用，详见 swapon --show）"
    echo "  - BBR + fq qdisc"
    echo "  - journald: volatile + ${JOURNALD_MAX_USE} 限制"
    echo "  - /tmp: tmpfs ${TMPFS_SIZE}"
    echo "  - 每日自动清理"
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
