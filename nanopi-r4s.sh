#!/usr/bin/env bash
# =============================================================================
# NanoPi R4S 专用优化安装脚本 v3.1 R58
# 硬件: RK3399 ARM64, 3.8GB RAM, 58GB TF卡
# 特点: 强 TF 卡保护（journald volatile + /tmp tmpfs + 高 dirty_writeback）
#       R4S 只做 Armbian 环境优化，不碰 agent 安装
# =============================================================================
#
# 一键运行: bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/nanopi-r4s.sh)
#
# 模式说明:
#   --optimize-only   纯环境优化（不安装 Docker/Node.js）
#   --uninstall       卸载所有优化配置
#

# ─────────────────────────────────────────────────────────────────────────────
# 平台信息
# ─────────────────────────────────────────────────────────────────────────────
readonly PLATFORM_NAME="NanoPi R4S (Armbian)"
readonly PLATFORM_DESC="RK3399 ARM64 | 3.8GB RAM | TF卡 | Armbian 24.04"

# ─────────────────────────────────────────────────────────────────────────────
# 平台差异变量（R4S 专项）
# ─────────────────────────────────────────────────────────────────────────────
readonly SYSCTL_FILE="/etc/sysctl.d/99-vps-youhua-r4s.conf"

# TF 卡保护变量
# journald volatile for TF card
readonly JOURNALD_STORAGE="volatile"
readonly JOURNALD_MAX_USE="50M"             # 限制 journald 磁盘占用
readonly TMPFS_SIZE="512M"                  # /tmp tmpfs 大小
readonly MIN_FREE_KB=65536                   # 4GB 机器 OOM 防线

# R4S 网络优化（2×GbE）
readonly NETDEV_BACKLOG=65535
readonly SOMAXCONN=1024

# ─────────────────────────────────────────────────────────────────────────────
# 加载通用函数库（必须在所有函数定义之前，让平台专属函数正确 override）
# ─────────────────────────────────────────────────────────────────────────────
if [[ -f "$(dirname "${BASH_SOURCE[0]}")/common-optimize.sh" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/common-optimize.sh"
elif [[ -f /tmp/vps-youhua-tmp/common-optimize.sh ]]; then
    source /tmp/vps-youhua-tmp/common-optimize.sh
elif [[ -f /tmp/vps-youhua/common-optimize.sh ]]; then
    source /tmp/vps-youhua/common-optimize.sh
fi

# ─────────────────────────────────────────────────────────────────────────────
# TF 卡检测（R4S 专项）
# ─────────────────────────────────────────────────────────────────────────────
detect_storage_type() {
    local root_dev
    root_dev=$(df / 2>/dev/null | awk 'NR==2 {print $1}')
    root_dev=$(basename "$root_dev" 2>/dev/null)

    if [[ "$root_dev" == mmcblk* ]]; then
        SYS_IS_TF_CARD=true
        log_info "检测到 TF 卡存储（$root_dev）— 启用写入保护"
    else
        SYS_IS_TF_CARD=false
        log_info "非 TF 卡存储（$root_dev）"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# R4S TF 卡保护（ext4 挂载参数 + dirty）
# ─────────────────────────────────────────────────────────────────────────────
configure_tf_card_protection() {
    [[ "$SYS_IS_TF_CARD" != "true" ]] && return 0
    log_step "配置 TF 卡写入保护..."

    # ext4 挂载参数（减少随机写入）
    if grep -q "^UUID=" /etc/fstab 2>/dev/null; then
        # 追加 noatime,nodiratime,commit=600 到 root 条目
        sed -i 's/\(UUID=.*\s\/\s ext4\s*\)/\1noatime,nodiratime,commit=600/' /etc/fstab
    fi

    log_info "TF 卡 ext4 优化完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# R4S 内存优化（禁用物理 swap，保留 Armbian 原生 zram）
# ─────────────────────────────────────────────────────────────────────────────
optimize_memory_r4s() {
    log_step "配置内存 (R4S TF卡保护)..."

    # 禁用物理 swap（TF 卡禁止 swap）
    for sw in /swapfile /swap.img; do
        swapon --show 2>/dev/null | grep -q "$sw" && swapoff "$sw" 2>/dev/null || true
        [[ -f "$sw" ]] && rm -f "$sw"
    done
    sed -i '/swapfile/d; /swap.img/d' /etc/fstab 2>/dev/null || true

    # Armbian 原生 zram-config 保留，不碰
    if systemctl is-active armbian-zram-config &>/dev/null; then
        log_info "Armbian zram-config 保持原状"
    fi

    # swappiness 保守
    sysctl -w vm.swappiness=10 2>/dev/null || true

    log_info "内存优化完成（物理 swap 已禁用，zram 保留）"
}

# ─────────────────────────────────────────────────────────────────────────────
# R4S sysctl（TF 卡保护 + 网络优化）
# ─────────────────────────────────────────────────────────────────────────────
configure_sysctl_r4s() {
    log_step "配置 sysctl (NanoPi R4S)..."

    backup_file "$SYSCTL_FILE"

    # 共享通用加固参数
    write_common_sysctl "$SYSCTL_FILE"

    # R4S 专属（追加）
    cat >> "$SYSCTL_FILE" <<EOF

# ── R4S TF 卡保护 ───────────────────────────────────────────────────────────
vm.dirty_ratio = 8
vm.dirty_background_ratio = 3
vm.dirty_writeback_centisecs = 6000
vm.dirty_expire_centisecs = 30000
vm.swappiness = 10
vm.min_free_kbytes = ${MIN_FREE_KB}
vm.vfs_cache_pressure = 50

# ── R4S 网络 ────────────────────────────────────────────────────────────────
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}
net.core.somaxconn = ${SOMAXCONN}
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 131072 16777216
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
net.netfilter.nf_conntrack_max = 131072
net.netfilter.nf_conntrack_hashsize = 65536
net.netfilter.nf_conntrack_tcp_timeout_established = 900
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 20
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 10
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 5
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 10
EOF

    apply_sysctl
    log_info "R4S sysctl 配置完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# ARM 专项优化（R4S/RK3399）
# ─────────────────────────────────────────────────────────────────────────────
optimize_arm() {
    log_step "ARM 专项优化..."

    # CPU governor（Armbian 默认 schedutil，R4S 4核，设 performance 也可以）
    mkdir -p /etc/default
    cat > /etc/default/cpufrequtils <<'EOF'
GOVERNOR=schedutil
MIN_SPEED=408000
MAX_SPEED=2016000
EOF
    systemctl restart cpufrequtils 2>/dev/null || true

    # irqbalance（多核 ARM 提升中断均衡）
    if ! command -v irqbalance &>/dev/null; then
        apt-get install -y irqbalance >> "$APT_LOG" 2>&1 || true
    fi
    systemctl enable irqbalance 2>/dev/null || true

    log_info "ARM 优化完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# R4S 网络优化
# ─────────────────────────────────────────────────────────────────────────────
optimize_network_r4s() {
    log_step "R4S 网络优化..."

    # 网卡 txqueuelen（全匹配）
    for iface in /sys/class/net/*; do
        [[ -d "$iface" ]] || continue
        local name; name=$(basename "$iface")
        ip link set "$name" txqueuelen 1000 2>/dev/null || true
        # RPS（RK3399 四核，CPU mask = 0xF）
        local r4s_mask="F"
        for rps_file in /sys/class/net/${name}/queues/rx-*/rps_cpus; do
            [[ -f "$rps_file" ]] || continue
            printf "%s" "$r4s_mask" > "$rps_file" 2>/dev/null || true
        done
        log_info "网卡 $name 已优化"
    done

    log_info "R4S 网络优化完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# OOM killer 配置
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
# TF 卡检测后传递给 common 的 journald 配置
# ─────────────────────────────────────────────────────────────────────────────
configure_journald() {
    log_step "配置 journald..."
    mkdir -p /etc/systemd/journald.conf.d

    cat > /etc/systemd/journald.conf.d/99-vps-youhua.conf <<EOF
[Journal]
SystemMaxUse=${JOURNALD_MAX_USE}
SystemMaxFileSize=50M
MaxRetentionSec=7day
Compress=yes
Storage=${JOURNALD_STORAGE}
RuntimeMaxUse=50M
Seal=yes
EOF
    systemctl restart systemd-journald 2>/dev/null || true
    log_info "journald 配置完成（Storage=${JOURNALD_STORAGE}）"
}

# ─────────────────────────────────────────────────────────────────────────────
# I/O Scheduler（TF 卡用 mq-deadline，eMMC/SSD 用 none）
# ─────────────────────────────────────────────────────────────────────────────
optimize_io_scheduler() {
    log_step "配置 I/O Scheduler..."

    local root_dev
    root_dev=$(df / 2>/dev/null | awk 'NR==2 {print $1}')
    root_dev=$(basename "$root_dev" 2>/dev/null)

    if [[ "$root_dev" == mmcblk* ]]; then
        # TF 卡：mq-deadline（减少随机写入）
        local sched_file="/sys/block/${root_dev}/queue/scheduler"
        if [[ -f "$sched_file" ]]; then
            echo "mq-deadline" > "$sched_file" 2>/dev/null || true
            log_info "TF 卡 $root_dev I/O Scheduler → mq-deadline"
        fi
    elif [[ -f "/sys/block/${root_dev}/queue/rotational" ]] && \
         [[ "$(cat /sys/block/${root_dev}/queue/rotational 2>/dev/null)" == "0" ]]; then
        # SSD / eMMC：none
        local sched_file="/sys/block/${root_dev}/queue/scheduler"
        if [[ -f "$sched_file" ]]; then
            echo "none" > "$sched_file" 2>/dev/null || true
            log_info "SSD $root_dev I/O Scheduler → none"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 编译依赖（R4S）
# ─────────────────────────────────────────────────────────────────────────────
install_build_deps() {
    log_step "安装编译依赖..."
    install_if_missing build-essential cmake pkg-config libssl-dev \
        python3-venv python3-dev python3-pip \
        libffi-dev libxml2-dev libxslt1-dev zlib1g-dev
    log_info "编译依赖安装完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# Docker（R4S）
# ─────────────────────────────────────────────────────────────────────────────
install_docker() {
    log_step "安装 Docker..."

    if command -v docker &>/dev/null; then
        log_info "Docker 已安装，跳过"
        return 0
    fi

    # Docker 官方安装脚本
    curl -fsSL https://get.docker.com | sh >> "$APT_LOG" 2>&1 || {
        log_warn "get.docker.com 安装失败，尝试 apt 安装 docker.io..."
        apt-get install -y docker.io docker-compose >> "$APT_LOG" 2>&1 || {
            log_error "Docker 安装失败，请查看 $APT_LOG"
            return 1
        }
    }

    if ! command -v docker &>/dev/null; then
        log_error "Docker 安装后仍未找到 docker 命令"
        return 1
    fi

    systemctl enable docker 2>/dev/null || true
    systemctl start docker 2>/dev/null || true

    # Docker 镜像加速
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
# Node.js（R4S）
# ─────────────────────────────────────────────────────────────────────────────
install_nodejs() {
    log_step "安装 Node.js..."

    if command -v node &>/dev/null; then
        log_info "Node.js 已安装: $(node --version)，跳过"
        return 0
    fi

    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >> "$APT_LOG" 2>&1 || {
        log_warn "NodeSource 安装失败，尝试 apt 安装..."
        apt-get install -y nodejs >> "$APT_LOG" 2>&1 || {
            log_error "Node.js 安装失败，请查看 $APT_LOG"
            return 1
        }
    }

    if command -v node &>/dev/null; then
        log_info "Node.js 安装完成: $(node --version)"
    else
        log_error "Node.js 安装后仍未找到 node 命令"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 诊断报告
# ─────────────────────────────────────────────────────────────────────────────
run_doctor() {
    log_step "运行诊断..."
    echo ""
    echo "=== VPS-youhua 环境诊断报告 (NanoPi R4S) ==="
    echo ""
    echo "1. 系统信息:"
    echo "   平台: $PLATFORM_NAME"
    echo "   系统: $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)"
    echo "   内核: $(uname -r)"
    echo "   架构: $(uname -m)"
    echo "   CPU: $SYS_CPU_CORES 核"
    echo "   内存: ${SYS_MEM_MB}MB"
    echo ""
    echo "2. TF卡保护:"
    echo "   TF卡存储: $([ "$SYS_IS_TF_CARD" == "true" ] && echo 是 || echo 否)"
    echo "   journald: $(grep SystemMaxUse /etc/systemd/journald.conf.d/99-vps-youhua.conf 2>/dev/null | cut -d= -f2)"
    echo "   swap状态: $(swapon --show 2>/dev/null | grep -v Filename | wc -l) 个"
    echo ""
    echo "3. CPU:"
    local gov; gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
    echo "   Governor: $gov"
    echo ""
    echo "4. Docker:"
    if command -v docker &>/dev/null; then
        echo "   版本: $(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')"
        echo "   状态: $(systemctl is-active docker 2>/dev/null || echo 'inactive')"
    else
        echo "   未安装"
    fi
    echo ""
    echo "5. Node.js:"
    command -v node &>/dev/null && echo "   版本: $(node --version)" || echo "   未安装"
    echo ""
    echo "6. 端口监听:"
    ss -tlnp 2>/dev/null | grep -E "18789|18790" || netstat -tlnp 2>/dev/null | grep -E "18789|18790" || echo "   无"
    echo ""
    echo "7. 服务状态:"
    systemctl is-active docker 2>/dev/null && echo "   docker: active" || echo "   docker: inactive"
    systemctl is-active chronyd 2>/dev/null && echo "   chronyd: active" || echo "   chronyd: inactive"
    echo ""
    echo "8. 磁盘:"
    df -h / | tail -1 | awk '{printf "   系统盘: %s 总, %s 已用, %s 可用 (%s)\n", $2, $3, $4, $5}'
    echo ""
    echo "=== 诊断完成 ==="
}

configure_fail2ban() {
    if [[ "${CONFIGURE_FAIL2BAN:-false}" != "true" ]]; then
        return 0
    fi

    log_step "安装 fail2ban 防 SSH 暴力破解..."

    if ! command -v fail2ban-server &>/dev/null; then
        apt-get install -y fail2ban >> "$APT_LOG" 2>&1 || {
            log_warn "fail2ban 安装失败，跳过"
            return 0
        }
    fi

    cat > /etc/fail2ban/jail.local << 'EOF'
[sshd]
enabled   = true
port      = ssh
filter    = sshd
action    = iptables[name=SSH, port=ssh, protocol=tcp]
logpath   = /var/log/auth.log
maxretry  = 3
bantime   = 3600
findtime  = 600
EOF

    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban >/dev/null 2>&1 || true
    log_info "fail2ban 已启用（SSH: 3次失败封IP 1小时）"
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
    if [[ "$confirm" != "yes" ]]; then
        echo "已取消卸载。"
        exit 0
    fi

    echo ""
    echo -e "${CYAN}[➜] 开始卸载...${NC}"

    # 停止服务
    systemctl stop vps-youhua-cleanup.timer 2>/dev/null || true

    # 清理所有配置文件
    rm -f /etc/sysctl.d/99-vps-youhua-r4s.conf
    rm -f /etc/sysctl.d/99-tf-optimize.conf 2>/dev/null || true
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
    rm -f /etc/apt/apt.conf.d/99-vps-youhua-unattended
    rm -f /etc/needrestart/conf.d/99-vps-youhua.conf
    rm -f /etc/default/cpufrequtils 2>/dev/null || true

    # 停止并卸载 unattended-upgrades（如果安装了的话）
    if command -v unattended-upgrades &>/dev/null; then
        systemctl stop unattended-upgrades 2>/dev/null || true
        systemctl disable unattended-upgrades 2>/dev/null || true
        apt-get remove --purge -y unattended-upgrades >> /dev/null 2>&1 || true
    fi

    # 停止并卸载 fail2ban（如果安装了的话）
    if command -v fail2ban-server &>/dev/null; then
        systemctl stop fail2ban 2>/dev/null || true
        systemctl disable fail2ban 2>/dev/null || true
        rm -f /etc/fail2ban/jail.local
        rm -f /etc/fail2ban/jail.d/*.local 2>/dev/null || true
        apt-get remove --purge -y fail2ban >> /dev/null 2>&1 || true
    fi

    # 恢复 sources.list 备份（如果存在）
    local backup
    for backup in /etc/apt/sources.list.bak.*; do
        [[ -f "$backup" ]] && cp "$backup" /etc/apt/sources.list && break
    done

    systemctl daemon-reload
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
    # 参数解析
    for arg in "$@"; do
        case "$arg" in
            --optimize-only) export SKIP_SOFTWARE_SCRIPT="true" ;;
            --uninstall) ;;
        esac
    done

    # 环境变量默认值
    : "${SKIP_SOFTWARE_SCRIPT:=false}"

    uninstall_all "$@" || exit 1

    clear
    echo "========================================================================"
    echo -e "${GREEN}  NanoPi R4S 专用优化安装脚本 v${SCRIPT_VERSION} R58${NC}"
    echo "========================================================================"
    echo ""

    init_script
    detect_system
    detect_storage_type
    check_network
    preflight_check

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
    configure_tf_card_protection
    optimize_memory_r4s
    configure_sysctl_r4s
    configure_limits
    configure_journald
    configure_dns
    configure_time_sync
    configure_locale
    configure_firewall_lo
    configure_npm_cache_tmpfs
    configure_memory_accounting
    optimize_io_scheduler
    optimize_arm
    optimize_network_r4s
    optimize_oom
    configure_unattended_upgrades
    configure_fail2ban
    optimize_ssh
    configure_cleanup_cron
    configure_logrotate
    configure_tmp_tmpfs

    # ── 软件安装 ──────────────────────────────────────────────────────────────
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
    echo -e "${GREEN}  ✅ NanoPi R4S v${SCRIPT_VERSION} R58 优化完成！${NC}"
    echo "========================================================================"
    echo ""
    echo -e "${CYAN}系统优化内容:${NC}"
    echo "  - sysctl 网络/内存/内核参数（TF卡保护）"
    echo "  - journald: volatile + 50MB限制"
    echo "  - /tmp: tmpfs 512MB（减少TF卡写入）"
    echo "  - ext4: noatime,commit=600（减少随机写入）"
    echo "  - swap: 物理swap已禁用, Armbian原生zram保持"
    echo "  - 每日清理: cron + journalctl vacuum"
    echo "  - 编译依赖: build-essential/cmake/pkg-config等"

    if [[ "$did_install" == "true" ]]; then
        echo ""
        echo -e "${CYAN}后续步骤:${NC}"
        echo "  1. reboot  ← 必须重启！sysctl/CPU governor/tmpfs 不重启不生效"
        echo "  2. 手动安装 agent（官方脚本），本脚本不碰 agent 安装"
    else
        echo ""
        echo -e "${CYAN}后续步骤:${NC}"
        echo "  1. reboot  ← 必须重启！"
        echo "  2. 安装你的软件（Docker / Xray / Nginx / agent 等）"
    fi

    echo ""
    echo -e "${YELLOW}⚠️  必须重启才能使所有优化生效！${NC}"
    echo ""
    echo -e "${YELLOW}日志: ${APT_LOG}${NC}"
    echo ""

    return 0
}

trap 'log_error "脚本异常退出 (行: ${LINENO})"; exit 1' ERR
trap 'log_warn "被中断"; exit 130' INT TERM

main "$@"
