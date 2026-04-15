#!/usr/bin/env bash
# =============================================================================
# 通用 x86_64 VPS 优化安装脚本 v3.1 R55
# 硬件: 通用 x86_64 架构
# 特点: 自适应内存配置（内存分级），通用性最强
# =============================================================================
#
# 一键运行: bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/generic-x86.sh)
#
# 模式说明:
#   --optimize-only   纯环境优化（不安装 Docker/Node.js）
#   --uninstall       卸载所有优化配置
#

# ─────────────────────────────────────────────────────────────────────────────
# 平台信息
# ─────────────────────────────────────────────────────────────────────────────
readonly PLATFORM_NAME="通用 x86_64 VPS"
readonly PLATFORM_DESC="x86_64 ($(uname -r | cut -d'.' -f1-3))"

# ─────────────────────────────────────────────────────────────────────────────
# 平台差异变量（generic-x86 自适应）
# ─────────────────────────────────────────────────────────────────────────────
readonly SYSCTL_FILE="/etc/sysctl.d/99-vps-youhua-generic.conf"
# journald persistent for generic VPS
readonly JOURNALD_STORAGE="persistent"
readonly JOURNALD_MAX_USE="100M"
readonly TMPFS_SIZE="512M"

# 内存分级变量（detect_memory_profile() 中设置）
ZRAM_SIZE=0; SWAPPINESS=10; TCP_BUF_MAX=16777216
CT_MAX=65536; MIN_FREE_KB=16384; PROFILE_DESC=""

# ─────────────────────────────────────────────────────────────────────────────
# SSD 检测
# ─────────────────────────────────────────────────────────────────────────────
detect_storage_type() {
    local root_dev
    root_dev=$(df / 2>/dev/null | awk 'NR==2 {print $1}')
    root_dev=$(basename "$root_dev" 2>/dev/null)

    if [[ -f "/sys/block/${root_dev}/queue/rotational" ]]; then
        if [[ "$(cat "/sys/block/${root_dev}/queue/rotational" 2>/dev/null)" == "0" ]]; then
            SYS_IS_SSD=true
            log_info "检测到 SSD: $root_dev"
        else
            SYS_IS_SSD=false
            log_info "检测到 HDD: $root_dev"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 内存分级检测
# ─────────────────────────────────────────────────────────────────────────────
detect_memory_profile() {
    if [[ $SYS_MEM_MB -ge 16384 ]]; then
        ZRAM_SIZE=0; SWAPPINESS=10; TCP_BUF_MAX=67108864; CT_MAX=262144; MIN_FREE_KB=32768
        PROFILE_DESC="高内存 (${SYS_MEM_MB}MB)"
    elif [[ $SYS_MEM_MB -ge 4096 ]]; then
        ZRAM_SIZE=0; SWAPPINESS=15; TCP_BUF_MAX=33554432; CT_MAX=131072; MIN_FREE_KB=32768
        PROFILE_DESC="中等内存 (${SYS_MEM_MB}MB)"
    elif [[ $SYS_MEM_MB -ge 2048 ]]; then
        ZRAM_SIZE=512; SWAPPINESS=20; TCP_BUF_MAX=16777216; CT_MAX=65536; MIN_FREE_KB=16384
        PROFILE_DESC="低内存 (${SYS_MEM_MB}MB)"
    else
        ZRAM_SIZE=1024; SWAPPINESS=30; TCP_BUF_MAX=8388608; CT_MAX=32768; MIN_FREE_KB=8192
        PROFILE_DESC="极低内存 (${SYS_MEM_MB}MB)"
    fi
    readonly ZRAM_SIZE SWAPPINESS TCP_BUF_MAX CT_MAX MIN_FREE_KB PROFILE_DESC
}

# ─────────────────────────────────────────────────────────────────────────────
# 内存优化（generic-x86 自适应）
# ─────────────────────────────────────────────────────────────────────────────
optimize_memory_generic() {
    log_step "配置内存优化 (${PROFILE_DESC})..."

    for sw in /swapfile /swap.img; do
        swapon --show 2>/dev/null | grep -q "$sw" && swapoff "$sw" 2>/dev/null || true
        [[ -f "$sw" ]] && rm -f "$sw"
    done
    sed -i '/swapfile/d; /swap.img/d' /etc/fstab 2>/dev/null || true

    if [[ -f /sys/module/zswap/parameters/enabled ]]; then
        echo N > /sys/module/zswap/parameters/enabled 2>/dev/null || true
    fi

    if [[ $ZRAM_SIZE -gt 0 ]]; then
        if modprobe zram 2>/dev/null || [[ -d /sys/block/zram0 ]]; then
            apt-get remove --purge -y zram-config >> "$APT_LOG" 2>&1 || true
            apt-get install -y --no-install-recommends zram-tools >> "$APT_LOG" 2>&1 || true

            cat > /etc/default/zramswap <<EOF
ALGO=lzo
SIZE=${ZRAM_SIZE}
PRIORITY=100
EOF
            systemctl enable zramswap 2>/dev/null || true
            systemctl restart zramswap 2>/dev/null || true
            sleep 2
            lsblk | grep -q zram && log_info "ZRAM ${ZRAM_SIZE}MB 已启用"
        fi
    else
        log_info "跳过 ZRAM（${PROFILE_DESC}）"
    fi

    sysctl -w vm.swappiness=$SWAPPINESS 2>/dev/null || true
    log_info "内存优化完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# generic-x86 sysctl（自适应参数）
# ─────────────────────────────────────────────────────────────────────────────
configure_sysctl_generic() {
    log_step "配置 sysctl (${PROFILE_DESC})..."

    backup_file "$SYSCTL_FILE"

    write_common_sysctl "$SYSCTL_FILE"

    cat >> "$SYSCTL_FILE" <<EOF

# ── generic-x86 内存 ─────────────────────────────────────────────────────────
vm.swappiness = ${SWAPPINESS}
vm.min_free_kbytes = ${MIN_FREE_KB}
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.dirty_writeback_centisecs = 10000
vm.dirty_expire_centisecs = 60000

# ── generic-x86 网络 ─────────────────────────────────────────────────────────
net.core.netdev_max_backlog = 65535
net.core.somaxconn = 65535
net.core.rmem_max = ${TCP_BUF_MAX}
net.core.wmem_max = ${TCP_BUF_MAX}
net.ipv4.tcp_rmem = 4096 131072 ${TCP_BUF_MAX}
net.ipv4.tcp_wmem = 4096 131072 ${TCP_BUF_MAX}
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3

# ── 连接追踪 ─────────────────────────────────────────────────────────────────
net.netfilter.nf_conntrack_max = ${CT_MAX}
net.netfilter.nf_conntrack_hashsize = ${CT_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 900
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 20
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 10
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 10
EOF

    apply_sysctl
    log_info "generic-x86 sysctl 配置完成"
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
# journald
# ─────────────────────────────────────────────────────────────────────────────
configure_journald() {
    log_step "配置 journald..."
    mkdir -p /etc/systemd/journald.conf.d

    cat > /etc/systemd/journald.conf.d/99-vps-youhua.conf <<EOF
[Journal]
SystemMaxUse=${JOURNALD_MAX_USE}
SystemMaxFileSize=50M
MaxRetentionSec=14day
Compress=yes
Storage=${JOURNALD_STORAGE}
RuntimeMaxUse=100M
Seal=yes
EOF
    systemctl restart systemd-journald 2>/dev/null || true
    log_info "journald 配置完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# I/O Scheduler（SSD → none）
# ─────────────────────────────────────────────────────────────────────────────
optimize_io_scheduler() {
    log_step "配置 I/O Scheduler..."

    local root_dev
    root_dev=$(df / 2>/dev/null | awk 'NR==2 {print $1}')
    root_dev=$(basename "$root_dev" 2>/dev/null)

    if [[ "$SYS_IS_SSD" == "true" ]]; then
        local sched_file="/sys/block/${root_dev}/queue/scheduler"
        if [[ -f "$sched_file" ]]; then
            echo "none" > "$sched_file" 2>/dev/null || true
            log_info "SSD $root_dev I/O Scheduler → none"
        fi
        systemctl enable --now fstrim.timer 2>/dev/null || true
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SSH
# ─────────────────────────────────────────────────────────────────────────────
optimize_ssh() {
    log_step "加固 SSH..."
    mkdir -p /etc/ssh/sshd_config.d

    local dropin_file="/etc/ssh/sshd_config.d/99-vps-youhua.conf"
    cat > "$dropin_file" <<'EOF'
# VPS-youhua SSH 安全配置
PermitEmptyPasswords no
ClientAliveInterval 3600
ClientAliveCountMax 3
X11Forwarding no
EOF
    chmod 644 "$dropin_file"

    if command -v sshd &>/dev/null; then
        if ! sshd -t -f "$dropin_file" 2>&1 | grep -qi "error"; then
            log_info "SSH 加固已应用 + 语法验证通过"
        else
            log_warn "SSH 配置语法异常，移除并跳过"
            rm -f "$dropin_file"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 编译依赖
# ─────────────────────────────────────────────────────────────────────────────
install_build_deps() {
    log_step "安装编译依赖..."
    install_if_missing build-essential cmake pkg-config libssl-dev \
        python3-venv python3-dev python3-pip \
        libffi-dev libxml2-dev libxslt1-dev zlib1g-dev
    log_info "编译依赖安装完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# Docker
# ─────────────────────────────────────────────────────────────────────────────
install_docker() {
    [[ "$INSTALL_DOCKER" != "true" ]] && return 0
    log_step "安装 Docker..."

    if command -v docker &>/dev/null; then
        log_info "Docker 已安装，跳过"
        return 0
    fi

    curl -fsSL https://get.docker.com | sh >> "$APT_LOG" 2>&1 || {
        apt-get install -y docker.io docker-compose >> "$APT_LOG" 2>&1 || true
    }

    systemctl enable docker 2>/dev/null || true
    systemctl start docker 2>/dev/null || true

    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://docker.xuanyuan.me"
  ],
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"}
}
EOF
    systemctl restart docker 2>/dev/null || true
    log_info "Docker 安装完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# Node.js
# ─────────────────────────────────────────────────────────────────────────────
install_nodejs() {
    [[ "$INSTALL_NODEJS" != "true" ]] && return 0
    log_step "安装 Node.js..."

    if command -v node &>/dev/null; then
        log_info "Node.js 已安装: $(node --version)，跳过"
        return 0
    fi

    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >> "$APT_LOG" 2>&1 || true
    apt-get install -y nodejs >> "$APT_LOG" 2>&1 || true

    if command -v node &>/dev/null; then
        log_info "Node.js 安装完成: $(node --version)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 诊断报告
# ─────────────────────────────────────────────────────────────────────────────
run_doctor() {
    log_step "运行诊断..."
    echo ""
    echo "=== VPS-youhua 环境诊断报告 (Generic x86_64) ==="
    echo ""
    echo "1. 系统信息:"
    echo "   平台: $PLATFORM_NAME"
    echo "   系统: $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)"
    echo "   内存: ${SYS_MEM_MB}MB"
    echo "   配置: ${PROFILE_DESC}"
    echo "   SSD: ${SYS_IS_SSD}"
    echo ""
    echo "2. CPU:"
    local gov; gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
    echo "   Governor: $gov"
    echo ""
    echo "3. Docker:"
    if command -v docker &>/dev/null; then
        echo "   版本: $(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')"
        echo "   状态: $(systemctl is-active docker 2>/dev/null || echo 'inactive')"
    else
        echo "   未安装"
    fi
    echo ""
    echo "4. Node.js:"
    command -v node &>/dev/null && echo "   版本: $(node --version)" || echo "   未安装"
    echo ""
    echo "=== 诊断完成 ==="
}

# ─────────────────────────────────────────────────────────────────────────────
# 卸载
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
    echo -n "确认卸载？(输入 'yes' 继续): "
    read -r confirm
    [[ "$confirm" != "yes" ]] && { echo "已取消。"; exit 0; }

    echo ""
    echo -e "${CYAN}[➜] 开始卸载...${NC}"

    systemctl stop vps-youhua-cleanup.timer 2>/dev/null || true

    rm -f /etc/sysctl.d/99-vps-youhua-generic.conf
    rm -f /etc/systemd/journald.conf.d/99-vps-youhua.conf
    rm -f /etc/security/limits.d/99-vps-youhua.conf
    rm -f /etc/systemd/system.conf.d/99-memory-accounting.conf
    rm -f /etc/systemd/system.conf.d/99-resource-limits.conf
    rm -f /etc/systemd/system.conf.d/99-oom-policy.conf
    rm -f /etc/ssh/sshd_config.d/99-vps-youhua.conf
    rm -f /etc/cron.d/vps-youhua-cleanup
    rm -f /etc/logrotate.d/vps-youhua
    rm -f /etc/apt/apt.conf.d/99-noninteractive
    rm -f /etc/apt/apt.conf.d/99-vps-youhua-no-unattended

    systemctl daemon-reload 2>/dev/null || true

    echo ""
    echo "========================================================================"
    echo -e "${GREEN}  ✅ VPS-youhua 卸载完成${NC}"
    echo "========================================================================"
    exit 0
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

    uninstall_all "$@" || exit 1

    clear
    echo "========================================================================"
    echo -e "${GREEN}  通用 x86_64 VPS 优化安装脚本 v${SCRIPT_VERSION} R55${NC}"
    echo "========================================================================"
    echo ""

    init_script
    detect_system
    detect_storage_type
    check_network
    preflight_check
    detect_memory_profile

    show_platform_summary

    if [[ -t 0 ]]; then
        echo -n "继续执行？(y/n，默认 y): "
        read -r confirm
        [[ "$confirm" == "n" || "$confirm" == "N" ]] && exit 0
    fi

    echo ""
    log_step "开始优化..."
    echo ""

    backup_all
    configure_apt_sources
    clean_system
    optimize_memory_generic
    configure_sysctl_generic
    configure_limits
    configure_journald
    configure_dns
    configure_time_sync
    configure_locale
    configure_firewall_lo
    configure_npm_cache_tmpfs
    configure_memory_accounting
    optimize_io_scheduler
    optimize_oom
    disable_auto_updates
    optimize_ssh
    configure_cleanup_cron
    configure_logrotate
    configure_tmp_tmpfs

    if [[ "$SKIP_SOFTWARE_SCRIPT" == "true" ]]; then
        log_info "纯优化模式，跳过软件安装"
        local did_install=false
    else
        install_build_deps
        [[ "$INSTALL_DOCKER" == "true" ]] && install_docker
        [[ "$INSTALL_NODEJS" == "true" ]] && install_nodejs
        local did_install=true
    fi

    run_doctor || { log_warn "诊断报告有异常，但继续完成"; }

    apt-get autoremove -y >> "$APT_LOG" 2>&1 || true
    apt-get autoclean >> "$APT_LOG" 2>&1 || true

    echo ""
    echo "========================================================================"
    echo -e "${GREEN}  ✅ Generic x86_64 v${SCRIPT_VERSION} R55 优化完成！${NC}"
    echo "========================================================================"
    echo ""
    echo -e "${CYAN}系统优化内容:${NC}"
    echo "  - sysctl 自适应参数（${PROFILE_DESC}）"
    echo "  - journald: 100MB 持久化"
    echo "  - /tmp: tmpfs 512MB"
    echo "  - SSD: fstrim.timer"
    echo "  - 编译依赖: build-essential/cmake/pkg-config等"

    if [[ "$did_install" == "true" ]]; then
        echo ""
        echo -e "${CYAN}后续步骤:${NC}"
        echo "  1. reboot  ← 必须重启！"
    else
        echo ""
        echo -e "${CYAN}后续步骤:${NC}"
        echo "  1. reboot  ← 必须重启！"
        echo "  2. 安装你的软件"
    fi

    echo ""
    echo -e "${YELLOW}⚠️  必须重启才能使所有优化生效！${NC}"
    echo ""
    echo -e "${YELLOW}日志: ${APT_LOG}${NC}"
    echo ""

    return 0
}

# 加载通用函数库
if [[ -f "$(dirname "${BASH_SOURCE[0]}")/common-optimize.sh" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/common-optimize.sh"
elif [[ -f /tmp/vps-youhua-tmp/common-optimize.sh ]]; then
    source /tmp/vps-youhua-tmp/common-optimize.sh
elif [[ -f /tmp/vps-youhua/common-optimize.sh ]]; then
    source /tmp/vps-youhua/common-optimize.sh
fi

trap 'log_error "脚本异常退出 (行: ${LINENO})"; exit 1' ERR
trap 'log_warn "被中断"; exit 130' INT TERM

main "$@"
