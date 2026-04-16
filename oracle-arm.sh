#!/usr/bin/env bash
# =============================================================================
# Oracle Cloud ARM 专用优化安装脚本 v3.2 R64
# 硬件: Ampere Altra, 2核16GB, 100GB 云盘
# 特点: Oracle Cloud 专属优化（禁用 cloud-agent，MTU 感知，高 TCP 缓冲）
# =============================================================================
#
# 一键运行: bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/oracle-arm.sh)
#
# 模式说明:
#   --optimize-only   纯环境优化（不安装 Docker/Node.js）
#   --uninstall       卸载所有优化配置
#

# ─────────────────────────────────────────────────────────────────────────────
# 平台信息
# ─────────────────────────────────────────────────────────────────────────────
readonly PLATFORM_NAME="Oracle Cloud ARM"
readonly PLATFORM_DESC="Ampere Altra ($(awk '/MemTotal/{printf "%.0fGB", $2/1024/1024}' /proc/meminfo), Oracle Cloud)"

# ─────────────────────────────────────────────────────────────────────────────
# 平台差异变量（Oracle ARM 专项）
# ─────────────────────────────────────────────────────────────────────────────
readonly SYSCTL_FILE="/etc/sysctl.d/99-vps-youhua-oracle-arm.conf"
# journald persistent for cloud server
readonly JOURNALD_STORAGE="persistent"
readonly JOURNALD_MAX_USE="100M"
readonly TMPFS_SIZE="512M"

# Oracle Cloud TCP 缓冲（动态自适应：内存的 5%，上限 64MB，下限 16MB）
readonly TCP_BUF_MAX
TCP_BUF_MAX=$(awk '/MemTotal/{m=$2/1024; printf "%.0f", (m*0.05*1024*1024>67108864)?67108864:(m*0.05*1024*1024<16777216)?16777216:m*0.05*1024*1024}' /proc/meminfo)
readonly CT_MAX=131072
readonly SOMAXCONN=65535
readonly NETDEV_BACKLOG=65535
readonly SWAPPINESS=10
readonly MIN_FREE_KB=32768

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
# Oracle Cloud 检测
# ─────────────────────────────────────────────────────────────────────────────
detect_oracle_cloud() {
    if grep -qi "oracle" /sys/class/dmi/id/sys_vendor 2>/dev/null || \
       grep -qi "oracle" /sys/class/dmi/id/product_name 2>/dev/null; then
        SYS_IS_ORACLE_CLOUD=true
        log_info "Oracle Cloud 环境检测通过"
    else
        SYS_IS_ORACLE_CLOUD=false
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Oracle Cloud 专属清理（云监控组件）
# ─────────────────────────────────────────────────────────────────────────────
oracle_cloud_cleanup() {
    [[ "$SYS_IS_ORACLE_CLOUD" != "true" ]] && return 0
    log_step "Oracle Cloud 专属清理..."

    # 禁用 Oracle 云监控 agent（节省资源 + 减少磁盘写入）
    if systemctl is-active oracle-cloud-agent &>/dev/null; then
        systemctl disable --now oracle-cloud-agent oracle-cloud-agent-updater 2>/dev/null || true
        systemctl mask oracle-cloud-agent oracle-cloud-agent-updater 2>/dev/null || true
        log_info "oracle-cloud-agent 已禁用"
    fi

    # cloud-init 保留配置但禁用网络探测（避免每次启动执行脚本）
    mkdir -p /etc/cloud/cloud.cfg.d
    cat > /etc/cloud/cloud.cfg.d/99-disable-net.cfg <<'EOF'
network:
  config: disabled
EOF

    log_info "Oracle Cloud 专属清理完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# 内存优化（Oracle 16GB：保留 zram 泄洪）
# ─────────────────────────────────────────────────────────────────────────────
optimize_memory_oracle() {
    log_step "配置内存 (Oracle Cloud ARM)..."

    # 保留 zram 泄洪区（不在此禁用 swap，由 configure_swap 统一决策）
    # 如果 Armbian zram 已配置，configure_swap 会检测到并跳过 swap 创建
    if [[ -d /sys/block/zram0 ]]; then
        log_info "zram 保持原状（configure_swap 将根据 zram 状态决定是否创建 swap）"
    fi

    sysctl -w vm.swappiness=$SWAPPINESS 2>/dev/null || true
    sysctl -w vm.oom_kill_allocating_task=1 2>/dev/null || true
    log_info "内存优化完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# Oracle Cloud sysctl（高缓冲 + 连接追踪）
# ─────────────────────────────────────────────────────────────────────────────
    install_base_tools

configure_sysctl_oracle() {
    log_step "配置 sysctl (Oracle Cloud ARM)..."

    backup_file "$SYSCTL_FILE"

    write_common_sysctl "$SYSCTL_FILE"

    cat >> "$SYSCTL_FILE" <<EOF

# ── Oracle Cloud 内存 ───────────────────────────────────────────────────────
vm.swappiness = ${SWAPPINESS}
vm.min_free_kbytes = ${MIN_FREE_KB}
vm.vfs_cache_pressure = 50
vm.oom_kill_allocating_task = 1
vm.dirty_ratio = 20
vm.dirty_background_ratio = 10
vm.dirty_writeback_centisecs = 15000
vm.dirty_expire_centisecs = 60000

# ── Oracle Cloud 网络（高缓冲）───────────────────────────────────────────────
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}
net.core.somaxconn = ${SOMAXCONN}
net.core.rmem_max = ${TCP_BUF_MAX}
net.core.wmem_max = ${TCP_BUF_MAX}
net.ipv4.tcp_rmem = 4096 262144 ${TCP_BUF_MAX}
net.ipv4.tcp_wmem = 4096 262144 ${TCP_BUF_MAX}
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3

# ── Oracle Cloud 连接追踪 ────────────────────────────────────────────────────
net.netfilter.nf_conntrack_max = ${CT_MAX}
net.netfilter.nf_conntrack_hashsize = ${CT_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 900
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 20
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 10
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 5
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 10
EOF

    apply_sysctl
    log_info "Oracle sysctl 配置完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# Oracle Cloud 网卡优化（MTU 感知 / TSO-GRO / RPS）
# ─────────────────────────────────────────────────────────────────────────────
optimize_network_oracle() {
    log_step "Oracle Cloud 网络优化..."

    local primary_iface
    primary_iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')

    if [[ -n "$primary_iface" ]] && [[ -d "/sys/class/net/$primary_iface" ]]; then
        local mtu; mtu=$(cat "/sys/class/net/$primary_iface/mtu" 2>/dev/null || echo "unknown")
        if [[ "$mtu" == "1500" ]]; then
            log_warn "主网卡 $primary_iface MTU=1500（公网）；Oracle 内部网络 MTU=9001"
        elif [[ "$mtu" =~ ^[0-9]+$ ]] && [[ $mtu -gt 1500 ]]; then
            log_info "主网卡 $primary_iface MTU=$mtu（内部网络）"
        fi
    fi

    for iface in /sys/class/net/en* /sys/class/net/eth*; do
        [[ -d "$iface" ]] || continue
        local name; name=$(basename "$iface")

        ethtool -K "$name" tso on 2>/dev/null || true
        ethtool -K "$name" gso on 2>/dev/null || true
        ethtool -K "$name" gro on 2>/dev/null || true
        ip link set "$name" txqueuelen 10000 2>/dev/null || true

        # RPS
        if [[ $SYS_CPU_CORES -gt 1 ]]; then
            local cores=$((SYS_CPU_CORES > 63 ? 63 : SYS_CPU_CORES))
            local mask; mask=$(printf '%x' $(( (1 << cores) - 1 )))
            for rps_file in /sys/class/net/${name}/queues/rx-*/rps_cpus; do
                [[ -f "$rps_file" ]] || continue
                printf "%s" "$mask" > "$rps_file" 2>/dev/null || true
            done
        fi
        log_info "网卡 $name 已优化"
    done

    log_info "Oracle Cloud 网络优化完成"
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
# I/O Scheduler（云盘用 none）
# ─────────────────────────────────────────────────────────────────────────────
optimize_io_scheduler() {
    log_step "配置 I/O Scheduler..."

    local root_dev
    root_dev=$(df / 2>/dev/null | awk 'NR==2 {print $1}')
    root_dev=$(basename "$root_dev" 2>/dev/null)

    local sched_file="/sys/block/${root_dev}/queue/scheduler"
    if [[ -f "$sched_file" ]]; then
        echo "none" > "$sched_file" 2>/dev/null || true
        log_info "云盘 $root_dev I/O Scheduler → none"
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
    # Docker 健康检查
    if docker ps >/dev/null 2>&1; then
        log_info "Docker 运行正常: $(docker ps -q | wc -l) 个容器在运行"
    else
        log_warn "Docker 守护进程可能未正常启动"
    fi
    log_info "Docker 安装完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# Node.js
# ─────────────────────────────────────────────────────────────────────────────
install_nodejs() {
    [[ "${INSTALL_NODEJS:-false}" != "true" ]] && return 0
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
    echo "=== VPS-youhua 环境诊断报告 (Oracle Cloud ARM) ==="
    echo ""
    echo "1. 系统信息:"
    echo "   平台: $PLATFORM_NAME"
    echo "   系统: $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)"
    echo "   内核: $(uname -r)"
    echo "   内存: ${SYS_MEM_MB}MB"
    echo "   Oracle: ${SYS_IS_ORACLE_CLOUD}"
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
    echo "5. 端口监听:"
    ss -tlnp 2>/dev/null | grep -E "18789|18790" || echo "   无"
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
    [[ "$confirm" != "yes" ]] && { echo "已取消。"; exit 0; }

    echo ""
    echo -e "${CYAN}[➜] 开始卸载...${NC}"

    systemctl stop vps-youhua-cleanup.timer 2>/dev/null || true
    # 清理所有配置文件
    rm -f /etc/sysctl.d/99-vps-youhua-oracle-arm.conf
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

    systemctl daemon-reload 2>/dev/null || true

    # 清理 iptables 规则
    iptables -D INPUT -i lo -j ACCEPT 2>/dev/null || true
    log_info "iptables 规则已清理"

    echo ""
    echo "========================================================================"
    echo -e "${GREEN}  ✅ VPS-youhua 卸载完成${NC}"
    echo "========================================================================"
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Oracle Cloud 元数据健康检查（可选，防云端 kill）
# ─────────────────────────────────────────────────────────────────────────────
check_oracle_metadata() {
    log_step "检查 Oracle Cloud 元数据..."

    # 检测是否在 Oracle Cloud 环境中
    local meta_status
    meta_status=$(curl -s --connect-timeout 3 -o /dev/null -w "%{http_code}" \
        http://169.254.169.254/latest/meta-data/ 2>/dev/null || echo "000")

    if [[ "$meta_status" == "200" ]]; then
        local instance_id
        instance_id=$(curl -s --connect-timeout 3 http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "unknown")
        log_info "Oracle Cloud 元数据正常（实例: $instance_id）"

        # 检测是否启用了 Oracle Cloud Agent（消耗资源）
        local agent_status
        agent_status=$(systemctl is-active oracle-cloud-agent 2>/dev/null || echo "inactive")
        if [[ "$agent_status" == "active" ]]; then
            log_warn "检测到 Oracle Cloud Agent 运行中（消耗内存/CPU），已安排卸载"
        else
            log_info "Oracle Cloud Agent 未运行（已卸载或不存在）"
        fi
    else
        log_info "非 Oracle Cloud 环境或元数据端点不可访问（元数据检查跳过）"
    fi
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
    echo -e "${GREEN}  Oracle Cloud ARM 专用优化安装脚本 v${SCRIPT_VERSION} R61${NC}"
    echo "========================================================================"
    echo ""

    init_script
    check_idempotent
    # BUG#5: IPv6 黑洞检测
    configure_ipv6_health
    # BUG#7: DNS 锁定防篡改
    configure_dns_lock
    detect_system
    detect_oracle_cloud
    check_oracle_metadata
    check_network
    preflight_check

    show_platform_summary

    if [[ -t 0 ]]; then
        echo -n "继续执行？(y/n，默认 y): "
        read -r confirm
        [[ "$confirm" == "n" || "$confirm" == "N" ]] && exit 0
    fi

    echo ""
    log_step "[1/12] 开始优化..."
    echo ""

    backup_all
    configure_apt_sources
    clean_system
    oracle_cloud_cleanup
    optimize_memory_oracle
    # BUG#1 FIX: Oracle ARM 在 zram 之后才检查 swap（避免冲突）
    configure_swap
    configure_sysctl_oracle
    configure_limits
    configure_fstab
    configure_journald
    configure_dns
    configure_time_sync
    configure_locale
    configure_firewall_lo
    configure_npm_cache_tmpfs
    configure_memory_accounting
    optimize_io_scheduler
    optimize_network_oracle
    optimize_oom
    configure_unattended_upgrades
    configure_fail2ban
    optimize_ssh
    configure_cleanup_cron
    configure_logrotate
    configure_tmp_tmpfs

    # BUG#46 Fix: install_build_deps 独立于 SKIP_SOFTWARE_SCRIPT
    # INSTALL_DEPS 由用户选择决定（Option 2 = true），与 Docker/NodeJS 分开
    # SKIP_SOFTWARE_SCRIPT 只阻止 Docker/NodeJS，不阻止编译依赖
    if [[ "${INSTALL_DEPS}" == "true" ]]; then
        install_build_deps
    fi
    if [[ "$SKIP_SOFTWARE_SCRIPT" == "true" ]]; then
        log_info "纯优化模式，跳过 Docker / Node.js 安装"
        local did_install=false
    else
        [[ "$INSTALL_DOCKER" == "true" ]] && install_docker
        [[ "$INSTALL_NODEJS" == "true" ]] && install_nodejs
        [[ "$INSTALL_DOCKER" == "true" || "$INSTALL_NODEJS" == "true" ]] && local did_install=true
    fi

    run_doctor || { log_warn "诊断报告有异常，但继续完成"; }

    apt-get autoremove -y >> "$APT_LOG" 2>&1 || true
    apt-get autoclean >> "$APT_LOG" 2>&1 || true

    echo ""
    echo "========================================================================"
    echo -e "${GREEN}  ✅ Oracle Cloud ARM v${SCRIPT_VERSION} R61 优化完成！${NC}"
    echo "========================================================================"
    echo ""
    echo -e "${CYAN}系统优化内容:${NC}"
    echo "  - sysctl 高缓冲网络参数"
    echo "  - journald: 100MB 持久化"
    echo "  - Oracle cloud-agent 已禁用（节省资源）"
    echo "  - cloud-init 网络探测已禁用"
    echo "  - 编译依赖: build-essential/cmake/pkg-config等"

    if [[ "$did_install" == "true" ]]; then
        echo ""
        echo -e "${CYAN}后续步骤:${NC}"
        echo "  1. reboot  ← 必须重启！"
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

    # ── 写入优化完成标记（供幂等性检测使用）────────────────────────────────
    date > /etc/vps-youhua-optimized 2>/dev/null || true
    chmod 444 /etc/vps-youhua-optimized 2>/dev/null || true

    return 0
}

trap 'log_error "脚本异常退出 (行: ${LINENO})"; exit 1' ERR
trap 'log_warn "被中断"; exit 130' INT TERM

main "$@"
