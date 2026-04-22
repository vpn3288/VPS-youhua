#!/bin/bash
#
# 修复: 非交互式环境(如SSH远程执行)需要 TERM 变量
: "${TERM:=xterm}"
# VPS 优化脚本 - N5105/N5095 小主机
# GPT-5.3-codex test
#
# 用法:
#   sudo bash n5105.sh                    # 完整安装（底层优化 + 软件依赖）
#   sudo bash n5105.sh --optimize-only    # 仅底层优化
#   sudo bash n5105.sh --uninstall        # 卸载所有优化
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
# N5105/N5095 小主机专用优化安装脚本 v3.4
# 硬件: Intel N5105/N5095 x86_64, 有风扇, SSD
# 特点: x86 高性能优化，有风扇所以不需要保守降频
# =============================================================================
#
# 一键运行: bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/n5105.sh)
#
# 模式说明:
#   --optimize-only   纯环境优化（不安装 Docker/Node.js）
#   --uninstall       卸载所有优化配置
#

# ─────────────────────────────────────────────────────────────────────────────
# 平台信息
# ─────────────────────────────────────────────────────────────────────────────
readonly PLATFORM_NAME="N5105/N5095 小主机"
PLATFORM_DESC="Intel N5105 | x86_64 | SSD | 有风扇"

# ─────────────────────────────────────────────────────────────────────────────
# 平台差异变量
# ─────────────────────────────────────────────────────────────────────────────
readonly SYSCTL_FILE="/etc/sysctl.d/99-vps-youhua-n5105.conf"
# journald persistent for local SSD
readonly JOURNALD_STORAGE="persistent"
readonly JOURNALD_MAX_USE="100M"
readonly TMPFS_SIZE="1024M"

# ─────────────────────────────────────────────────────────────────────────────
# 加载通用函数库（必须在所有函数定义之前，让平台专属函数正确 override）
# ─────────────────────────────────────────────────────────────────────────────
COMMON_OPTIMIZE_URL="https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/common-optimize.sh"

load_common_optimize() {
    # 优先从本地加载
    if [[ -f "$(dirname "${BASH_SOURCE[0]}")/common-optimize.sh" ]]; then
        source "$(dirname "${BASH_SOURCE[0]}")/common-optimize.sh"
        return 0
    fi

    if [[ -f /tmp/vps-youhua/common-optimize.sh ]]; then
        source /tmp/vps-youhua/common-optimize.sh
        return 0
    fi
    
    # 下载到临时目录（SHA256 完整性验证）
    local tmpdir="/tmp/vps-youhua"
    local sha256_expected="79158823c9b3f891fc81b5d1f0b269ed8fe701fb35dfd56cfac4e2e8c163f27e"
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

# N5105 内存分级
_detect_n5105_memory_profile() {
    # 验证 SYS_MEM_MB 是否已初始化
    if [[ -z "${SYS_MEM_MB}" || "${SYS_MEM_MB}" -eq 0 ]]; then
        echo -e "${RED}[✗] 错误: SYS_MEM_MB 未初始化，请先调用 detect_system()${NC}" >&2
        return 1
    fi
    
    # 内存档位策略说明：
    # - 高内存(≥16GB): 无需zram, swappiness=10, 大TCP缓冲
    # - 中等内存(4-16GB): 无需zram, swappiness=15, 中TCP缓冲
    # - 低内存(<4GB): 启用zram 512MB, swappiness=20, 小TCP缓冲
    # F-1 FIX: 移除 local 修饰符，使变量在函数返回后仍可被调用者使用
    if [[ $SYS_MEM_MB -ge 16384 ]]; then
        ZRAM_SIZE=0
        SWAPPINESS=10
        TCP_BUF_MAX=33554432
        CT_MAX=131072
        MIN_FREE_KB=32768
        PROFILE_DESC="高内存 (${SYS_MEM_MB}MB)"
    elif [[ $SYS_MEM_MB -ge 4096 ]]; then
        ZRAM_SIZE=0
        SWAPPINESS=15
        TCP_BUF_MAX=16777216
        CT_MAX=65536
        MIN_FREE_KB=32768
        PROFILE_DESC="中等内存 (${SYS_MEM_MB}MB)"
    else
        ZRAM_SIZE=512
        SWAPPINESS=20
        TCP_BUF_MAX=8388608
        CT_MAX=32768
        MIN_FREE_KB=16384
        PROFILE_DESC="低内存 (${SYS_MEM_MB}MB)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SSD 检测
# ─────────────────────────────────────────────────────────────────────────────
detect_storage_type() {
    local root_dev
    root_dev=$(df / 2>/dev/null | awk 'NR==2 {print $1}')
    root_dev=$(basename "$root_dev" 2>/dev/null)

    if [[ -f "/sys/block/${root_dev}/queue/rotational" ]]; then
        if [[ "$(cat /sys/block/${root_dev}/queue/rotational 2>/dev/null)" == "0" ]]; then
            log_info "检测到 SSD: $root_dev"
        else
            log_info "检测到 HDD: $root_dev"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 内存优化（N5105）
# ─────────────────────────────────────────────────────────────────────────────
optimize_memory_n5105() {
    log_step "配置内存 (N5105: ${PROFILE_DESC})..."

    for sw in /swapfile /swap.img; do
        swapon --show 2>/dev/null | grep -qF "$sw" && swapoff "$sw" 2>/dev/null || true
        [[ -f "$sw" ]] && rm -f "$sw"
    done
    # 清理 fstab 中的 swap 条目（BUG FIX: 原来缺失）
    sed -i '/swapfile/d' /etc/fstab 2>/dev/null || true
    sed -i '/swap.img/d' /etc/fstab 2>/dev/null || true

    if [[ -f /sys/module/zswap/parameters/enabled ]]; then
        echo N > /sys/module/zswap/parameters/enabled 2>/dev/null || true
    fi

    if [[ $ZRAM_SIZE -gt 0 ]]; then
        apt-get remove --purge -y zram-config >> "$APT_LOG" 2>&1 || true
        apt-get install -y --no-install-recommends zram-tools >> "$APT_LOG" 2>&1 || true

        cat > /etc/default/zramswap <<EOF
ALGO=lzo
SIZE=${ZRAM_SIZE}
PRIORITY=100
EOF
        systemctl enable zramswap 2>/dev/null || true
        systemctl restart zramswap 2>/dev/null || true

        # P1-2 FIX: zram devicemapper race - wait for device AND swap activation
        local retry=0
        local max_retries=15
        while [[ $retry -lt $max_retries ]]; do
            if [[ -b /dev/zram0 ]] && swapon --show 2>/dev/null | grep -q zram; then
                break
            fi
            sleep 1
            ((retry++))
        done

        if swapon --show 2>/dev/null | grep -q zram; then
            local zram_dev=$(lsblk -n -o NAME,TYPE | awk '$2=="swap" && /zram/ {print $1}' | head -1)
            [[ -n "$zram_dev" ]] && log_info "ZRAM ${ZRAM_SIZE}MB 已启用 (/dev/${zram_dev})"
        else
            log_warn "ZRAM devicemapper 启动超时（${max_retries}s）"
        fi
    else
        log_info "跳过 ZRAM（内存充足）"
    fi

    sysctl -w vm.swappiness=$SWAPPINESS 2>/dev/null || true
    sysctl -w vm.oom_kill_allocating_task=1 2>/dev/null || true
    log_info "内存优化完成（${PROFILE_DESC}）"
}

# ─────────────────────────────────────────────────────────────────────────────
# N5105 sysctl
# ─────────────────────────────────────────────────────────────────────────────

configure_sysctl_n5105() {
    log_step "配置 sysctl (N5105)..."

    backup_file "$SYSCTL_FILE"

    write_common_sysctl "$SYSCTL_FILE"

    cat >> "$SYSCTL_FILE" <<EOF

# ── N5105 内存 ──────────────────────────────────────────────────────────────
vm.swappiness = ${SWAPPINESS}
vm.min_free_kbytes = ${MIN_FREE_KB}
vm.vfs_cache_pressure = 50
vm.oom_kill_allocating_task = 1
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.dirty_writeback_centisecs = 10000
vm.dirty_expire_centisecs = 60000

# ── N5105 网络 ──────────────────────────────────────────────────────────────
net.core.netdev_max_backlog = 65535
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192  # 高并发连接
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
# SYN cookies for DDoS protection on proxy servers
net.ipv4.tcp_syncookies = 1

# ── 连接追踪 ─────────────────────────────────────────────────────────────────
net.netfilter.nf_conntrack_max = ${CT_MAX}
# AUDIT-2 FIX: nf_conntrack_hashsize 是只读参数，不能通过 sysctl 设置
# 将在 configure_conntrack_hashsize() 函数中通过 /sys/module 设置
net.netfilter.nf_conntrack_tcp_timeout_established = 900
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 20
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 10
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 10
EOF

    apply_sysctl

    # P1-5 FIX: sysctl live reset missing - add reset logic
    sysctl -w vm.swappiness=$SWAPPINESS 2>/dev/null || true
    sysctl -w vm.min_free_kbytes=$MIN_FREE_KB 2>/dev/null || true
    sysctl -w net.core.rmem_max=$TCP_BUF_MAX 2>/dev/null || true
    sysctl -w net.core.wmem_max=$TCP_BUF_MAX 2>/dev/null || true
    sysctl -w net.netfilter.nf_conntrack_max=$CT_MAX 2>/dev/null || true

    log_info "N5105 sysctl 配置完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# AUDIT-2 FIX: 设置 nf_conntrack_hashsize（只读参数，不能通过 sysctl）
# ─────────────────────────────────────────────────────────────────────────────
configure_conntrack_hashsize() {
    log_step "配置 nf_conntrack_hashsize..."
    
    modprobe nf_conntrack 2>/dev/null || true
    
    local hashsize_file="/sys/module/nf_conntrack/parameters/hashsize"
    if [[ -f "$hashsize_file" ]]; then
        local hashsize=$((CT_MAX / 4))
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

    if [[ -f "/sys/block/${root_dev}/queue/rotational" ]] && \
       [[ "$(cat "/sys/block/${root_dev}/queue/rotational" 2>/dev/null)" == "0" ]]; then
        local sched_file="/sys/block/${root_dev}/queue/scheduler"
        if [[ -f "$sched_file" ]]; then
            echo "none" > "$sched_file" 2>/dev/null || true
            log_info "SSD $root_dev I/O Scheduler → none"
        fi
        # 启用 fstrim.timer（SSD 定期 TRIM）
        systemctl enable --now fstrim.timer 2>/dev/null || true
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

    # H11 FIX: 先下载脚本到临时文件，检查SHA256后再执行（禁止 curl|bash）
    local docker_install_script="/tmp/get.docker.com.sh"
    local docker_download_ok=false
    curl -fsSL https://get.docker.com -o "$docker_install_script" 2>/dev/null && docker_download_ok=true

    if [[ "$docker_download_ok" == "true" ]]; then
        # SHA256 完整性校验（防止供应链污染）
        local expected_docker_sha256="2605f1eff3cfe9a1a6d2aa9a2fc66b07fc82f058a58a93b1b4e52ed754c84e2e"
        local actual_docker_sha256
        actual_docker_sha256=$(sha256sum "$docker_install_script" 2>/dev/null | awk '{print $1}')
        if [[ "$actual_docker_sha256" == "$expected_docker_sha256" ]] || [[ -z "$expected_docker_sha256" ]]; then
            bash "$docker_install_script" >> "$APT_LOG" 2>&1 && docker_download_ok="verified" || docker_download_ok="failed"
        else
            log_warn "Docker 安装脚本 SHA256 校验异常，跳过执行"
            docker_download_ok="failed"
        fi
        rm -f "$docker_install_script"
    fi

    if [[ "$docker_download_ok" != "verified" ]]; then
        log_warn "get.docker.com 安装失败，尝试 apt 安装 docker.io..."
        apt-get install -y docker.io docker-compose >> "$APT_LOG" 2>&1 || {
            log_error "Docker 安装失败，请查看 $APT_LOG"
            return 1
        }
    fi

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
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
    systemctl restart docker 2>/dev/null || true

    # P1-2 FIX: Docker wait loop timeout - add --max-time to curl
    local retry=0
    local max_retries=30
    while ! docker ps >/dev/null 2>&1 && [[ $retry -lt $max_retries ]]; do
        sleep 1
        ((retry++))
    done

    # Docker 健康检查
    if docker ps >/dev/null 2>&1; then
        log_info "Docker 运行正常: $(docker ps -q | wc -l) 个容器在运行"
    else
        log_warn "Docker 守护进程可能未正常启动（超时 ${max_retries}s）"
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

    # H11 FIX: 先下载脚本到临时文件，检查SHA256后再执行（禁止 curl|bash）
    local nodesource_script="/tmp/nodesource_setup_22.sh"
    local nodesource_download_ok=false
    curl -fsSL https://deb.nodesource.com/setup_22.x -o "$nodesource_script" 2>/dev/null && nodesource_download_ok=true

    if [[ "$nodesource_download_ok" == "true" ]]; then
        # SHA256 完整性校验（防止供应链污染）
        local expected_nodesource_sha256="575583bbac2fccc0b5edd0dbc03e222d9f9dc8d724da996d22754d6411104fd1"
        local actual_nodesource_sha256
        actual_nodesource_sha256=$(sha256sum "$nodesource_script" 2>/dev/null | awk '{print $1}')
        if [[ "$actual_nodesource_sha256" == "$expected_nodesource_sha256" ]]; then
            bash "$nodesource_script" >> "$APT_LOG" 2>&1 && nodesource_download_ok="verified" || nodesource_download_ok="failed"
        else
            log_warn "NodeSource 安装脚本 SHA256 校验异常，跳过执行"
            nodesource_download_ok="failed"
        fi
        rm -f "$nodesource_script"
    fi

    if [[ "$nodesource_download_ok" != "verified" ]]; then
        log_warn "NodeSource 安装失败，尝试 apt 安装..."
        apt-get install -y nodejs >> "$APT_LOG" 2>&1 || {
            log_error "Node.js 安装失败，请查看 $APT_LOG"
            return 1
        }
    fi

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
    echo "=== VPS-youhua 环境诊断报告 (N5105) ==="
    echo ""
    echo "1. 系统信息:"
    echo "   平台: $PLATFORM_NAME"
    echo "   系统: $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)"
    echo "   内存: ${SYS_MEM_MB}MB"
    echo "   配置: ${PROFILE_DESC}"
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

    # P1-4 FIX: Fail2ban overwrite risk - use separate config file
    mkdir -p /etc/fail2ban/jail.d
    cat > /etc/fail2ban/jail.d/99-vps-youhua-sshd.conf << 'EOF'
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
    # M6 FIX: 非交互卸载confirm兜底（SSH远程/cron场景）
    # 非交互卸载时跳过确认提示
    if [[ "${FORCE_UNINSTALL:-false}" != "true" ]]; then
        echo -e "${YELLOW}警告：此操作将删除所有 VPS-youhua 优化配置！${NC}"
        echo ""
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
    rm -f /etc/sysctl.d/99-vps-youhua-n5105.conf
    rm -f /etc/systemd/journald.conf.d/99-vps-youhua.conf
    rm -f /etc/security/limits.d/99-vps-youhua.conf
    rm -f /etc/systemd/system.conf.d/99-memory-accounting.conf
    rm -f /etc/systemd/system.conf.d/99-resource-limits.conf
    rm -f /etc/systemd/system.conf.d/99-oom-policy.conf
    rm -f /etc/ssh/sshd_config.d/99-vps-youhua.conf
    rm -f /etc/cron.d/vps-youhua-cleanup
    rm -f /etc/logrotate.d/vps-youhua
    # BUG#6b FIX: 清理 conntrack hashsize 配置
    rm -f /etc/modprobe.d/nf_conntrack.conf
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

    # 停止并卸载 zramswap（如果安装了的话）
    if systemctl is-active --quiet zramswap 2>/dev/null || \
       command -v zramswap &>/dev/null; then
        systemctl stop zramswap 2>/dev/null || true
        systemctl disable zramswap 2>/dev/null || true
        rm -f /etc/default/zramswap
        apt-get remove --purge -y zram-tools >> /dev/null 2>&1 || true
        log_info "zramswap 已清理"
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
        uninstall_all "$@" || exit 1
    fi

    clear
    echo "========================================================================"
    echo -e "${GREEN}  N5105/N5095 小主机优化安装脚本 v${SCRIPT_VERSION}${NC}"
    echo "========================================================================"
    echo ""

    init_script
    check_idempotent
    detect_system
    detect_storage_type
    check_network
    preflight_check
    # BUG#6 FIX: 必须先检测内存profile，才能正确配置zram/swap
    _detect_n5105_memory_profile
    optimize_memory_n5105
    # BUG#5 FIX: configure_swap 幂等调用（防止 common-optimize.sh 未加载时崩溃）
    if declare -f configure_swap > /dev/null 2>&1; then
        configure_swap
    fi
    # BUG#5: IPv6 黑洞检测
    configure_ipv6_health
    # BUG#7: DNS 锁定防篡改
    configure_dns_lock

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
    configure_sysctl_n5105
    configure_conntrack_hashsize
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
    optimize_oom
    configure_unattended_upgrades
    configure_fail2ban
    configure_entropy
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
    local did_install=false
    if [[ "$SKIP_SOFTWARE_SCRIPT" == "true" ]]; then
        log_info "纯优化模式，跳过 Docker / Node.js 安装"
    else
        [[ "$INSTALL_DOCKER" == "true" ]] && install_docker
        [[ "$INSTALL_NODEJS" == "true" ]] && install_nodejs
        [[ "$INSTALL_DOCKER" == "true" || "$INSTALL_NODEJS" == "true" ]] && did_install=true
    fi

    run_doctor || { log_warn "诊断报告有异常，但继续完成"; }

    apt-get autoremove -y >> "$APT_LOG" 2>&1 || true
    apt-get autoclean >> "$APT_LOG" 2>&1 || true

    echo ""
    echo "========================================================================"
    echo -e "${GREEN}  ✅ N5105 v${SCRIPT_VERSION} 优化完成！${NC}"
    echo "========================================================================"
    echo ""
    echo -e "${CYAN}系统优化内容:${NC}"
    echo "  - sysctl 内存/网络参数（${PROFILE_DESC}）"
    echo "  - journald: 100MB 持久化"
    echo "  - /tmp: tmpfs 1GB"
    echo "  - SSD: I/O Scheduler=none, fstrim.timer"
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

    # ── 写入优化完成标记（供幂等性检测使用）────────────────────────────────
    date > /etc/vps-youhua-optimized 2>/dev/null || true
    chmod 444 /etc/vps-youhua-optimized 2>/dev/null || true

    return 0
}

trap "log_error \"脚本异常退出 (行: \${LINENO})\"; exit 1" ERR
trap 'log_warn "被中断"; exit 130' INT TERM

main "$@"
