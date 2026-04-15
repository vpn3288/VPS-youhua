#!/usr/bin/env bash
# =============================================================================
# N5105/N5095 小主机专用优化安装脚本 v3.1
# 硬件: Intel N5105/N5095 x86_64, 低功耗小主机
# 特点: SSD优先，性能与静音平衡
# =============================================================================
#
# 一键运行: bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/n5105.sh)
#

set -euo pipefail
IFS=$'\n\t'

# 提高当前shell的文件描述符限制（立即生效）
ulimit -n 1048576
ulimit -u 131072
ulimit -m unlimited
[[ -f /proc/sys/fs/inotify/max_user_watches ]] && echo 524288 > /proc/sys/fs/inotify/max_user_watches 2>/dev/null || true

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_step()  { echo -e "${CYAN}[➜]${NC} $1"; }

# 全局变量
readonly SCRIPT_VERSION="3.1"
readonly APT_LOG="/var/log/openclaw-install.log"
readonly LOCK_FILE="/var/lock/openclaw-install.lock"

# 系统信息
SYS_MEM_MB=0; SYS_CPU_CORES=0; SYS_ARCH=""
SYS_KERNEL=""; SYS_OS_ID=""; SYS_OS_VERSION=""
SYS_DISK_TOTAL_GB=0; SYS_DISK_AVAIL_GB=0
SYS_NET_IF=""; SYS_ROOT_DISK=""
SYS_IS_SSD=false; SYS_CPU_MODEL=""

# 安装选项
INSTALL_DOCKER="${INSTALL_DOCKER:-true}"
INSTALL_NODEJS="${INSTALL_NODEJS:-true}"
OPTIMIZE_ONLY="${OPTIMIZE_ONLY:-false}"
NODEJS_VERSION="${NODEJS_VERSION:-24}"
OPENCLAW_USER="${OPENCLAW_USER:-openclaw}"
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
OPENCLAW_DATA_DIR="${OPENCLAW_DATA_DIR:-/opt/openclaw}"

# =============================================================================
# 初始化
# =============================================================================
init_script() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log_error "另一个实例正在运行，退出"
        exit 1
    fi
    export DEBIAN_FRONTEND=noninteractive
    mkdir -p "$(dirname "$APT_LOG")"
    : > "$APT_LOG"

    # OPENCLAW_USER 输入安全校验（防止注入和路径遍历）
    if [[ -n "${OPENCLAW_USER:-}" ]]; then
        if [[ ! "$OPENCLAW_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || \
           [[ "${#OPENCLAW_USER}" -gt 32 ]]; then
            log_error "OPENCLAW_USER 非法: '$OPENCLAW_USER' (只允许 a-z/0-9/_/-，最多32字符)"
            exit 1
        fi
    fi
}

# =============================================================================
# 系统检测
# =============================================================================
detect_system() {
    log_step "检测系统信息..."

    SYS_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
    [[ -z "$SYS_MEM_MB" || "$SYS_MEM_MB" -eq 0 ]] && SYS_MEM_MB=1024

    SYS_CPU_CORES=$(nproc 2>/dev/null || echo 1)
    SYS_KERNEL=$(uname -r)
    SYS_ARCH=$(uname -m)

    SYS_CPU_MODEL=$(cat /proc/cpuinfo | grep "model name" | head -1 | cut -d: -f2 | sed 's/^ //' || echo "unknown")

    SYS_OS_ID=$(grep -oP '(?<=^ID=).+' /etc/os-release 2>/dev/null | tr -d '"' || echo "unknown")
    SYS_OS_VERSION=$(grep -oP '(?<=^VERSION_ID=).+' /etc/os-release 2>/dev/null | tr -d '"' || echo "unknown")

    SYS_DISK_TOTAL_GB=$(df -BG / 2>/dev/null | awk 'NR==2 {print $2}' | tr -d 'G' || echo 0)
    SYS_DISK_AVAIL_GB=$(df -BG / 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G' || echo 0)

    SYS_NET_IF=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}' || true)
    [[ -z "$SYS_NET_IF" ]] && SYS_NET_IF=$(ip -6 route show default 2>/dev/null | awk '/default/{print $5; exit}' || true)

    SYS_ROOT_DISK=$(df / 2>/dev/null | awk 'NR==2 {print $1}' || echo "")

    detect_ssd

    log_info "系统: ${SYS_OS_ID} ${SYS_OS_VERSION}"
    log_info "架构: ${SYS_ARCH} | 内存: ${SYS_MEM_MB}MB | CPU: ${SYS_CPU_CORES}核"
    log_info "CPU: ${SYS_CPU_MODEL}"
    [[ "$SYS_IS_SSD" == "true" ]] && log_info "SSD 检测: 是" || log_info "SSD 检测: 否"
}

# =============================================================================
# SSD检测
# =============================================================================
detect_ssd() {
    # 只检查根磁盘，避免多盘环境下误判
    local root_dev
    root_dev=$(df / 2>/dev/null | awk 'NR==2 {print $1}')
    root_dev=$(basename "$root_dev" 2>/dev/null)
    if [[ -n "$root_dev" ]] && [[ -f "/sys/block/${root_dev}/queue/rotational" ]]; then
        [[ "$(cat /sys/block/${root_dev}/queue/rotational 2>/dev/null)" == "0" ]] && SYS_IS_SSD=true
    fi
}

# =============================================================================
# 网络检测
# =============================================================================
check_network() {
    log_step "检测网络连接..."
    if ! ping -c1 -W3 8.8.8.8 &>/dev/null; then
        log_error "无法连接到 8.8.8.8，请检查网络"
        exit 1
    fi
    log_info "网络连接正常"
}

# =============================================================================
# 预检查
# =============================================================================
preflight_check() {
    log_step "执行预检查..."
    [[ $EUID -ne 0 ]] && { log_error "需要 root 权限"; exit 1; }
    [[ $SYS_DISK_AVAIL_GB -lt 5 ]] && { log_warn "磁盘可用空间 ${SYS_DISK_AVAIL_GB}GB < 5GB"; }
    if ! ping -c1 -W3 github.com &>/dev/null; then
        log_warn "无法访问 GitHub，部分功能可能受限"
    fi
    log_info "预检查通过"
}

# =============================================================================
# 备份配置
# =============================================================================
backup_file() {
    local file="$1"
    [[ -f "$file" ]] && cp -a "$file" "${file}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
}

# =============================================================================
# 全量备份（回滚机制）
# =============================================================================
backup_all() {
    log_step "备份当前配置（回滚用）..."
    local backup_dir="/var/backups/vps-youhua"
    mkdir -p "$backup_dir"
    local ts; ts=$(date +%Y%m%d_%H%M%S)

    [[ -d /etc/sysctl.d ]] && cp -a /etc/sysctl.d "$backup_dir/sysctl.d_${ts}" 2>/dev/null || true
    [[ -d /etc/systemd/system.conf.d ]] && cp -a /etc/systemd/system.conf.d "$backup_dir/system.conf.d_${ts}" 2>/dev/null || true
    [[ -f /etc/fstab ]] && cp -a /etc/fstab "$backup_dir/fstab_${ts}" 2>/dev/null || true
    [[ -f /etc/security/limits.conf ]] && cp -a /etc/security/limits.conf "$backup_dir/limits.conf_${ts}" 2>/dev/null || true
    [[ -f /etc/default/cpufrequtils ]] && cp -a /etc/default/cpufrequtils "$backup_dir/cpufrequtils_${ts}" 2>/dev/null || true

    find "$backup_dir" -maxdepth 1 -type d -name "*_[0-9]*" | sort -r | tail -n +6 | xargs rm -rf 2>/dev/null || true
    log_info "备份已保存至 $backup_dir（最近5份）"
}

# =============================================================================
# 重启提示
# =============================================================================
show_reboot_notice() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════"
    echo -e "${YELLOW}  ⚠️  必须重启才能完全生效${NC}"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo ""
    echo "以下配置必须重启后才能 100% 生效："
    echo "  - sysctl 参数（/etc/sysctl.d/）"
    echo "  - fstab 挂载参数（/tmp tmpfs, ext4 commit）"
    echo "  - journald 配置（volatile 模式）"
    echo "  - systemd 资源限制"
    echo "  - CPU governor 持久化"
    echo ""
    echo "立即重启？[y/N]"
    echo -n "→ "
}

# =============================================================================
# APT 配置
# =============================================================================
configure_apt_sources() {
    log_step "配置 APT 源..."
    local sources_list="/etc/apt/sources.list"
    local codename
    codename=$(grep -oP '(?<=^VERSION_CODENAME=).+' /etc/os-release 2>/dev/null | tr -d '"' || echo "bookworm")

    backup_file "$sources_list"

    mkdir -p /etc/apt/apt.conf.d /etc/needrestart/conf.d
    cat > /etc/apt/apt.conf.d/99-noninteractive <<'EOF'
DPkg::Options {"--force-confdef"; "--force-confold";};
APT::Get::Assume-Yes "true";
APT::Get::Fix-Missing "true";
EOF
    cat > /etc/needrestart/conf.d/99-openclaw.conf <<'EOF'
$nrconf{restart} = 'a'; $nrconf{kernelhints} = 0; $nrconf{unneeded} = 'a';
EOF

    cat > "$sources_list" <<EOF
deb http://mirrors.tencent.com/debian/ ${codename} main contrib non-free non-free-firmware
deb http://mirrors.tencent.com/debian/ ${codename}-updates main contrib non-free non-free-firmware
deb http://mirrors.tencent.com/debian-security/ ${codename}-security main contrib non-free non-free-firmware
deb http://mirrors.tencent.com/debian/ ${codename}-backports main contrib non-free non-free-firmware
EOF

    if ! apt-get update -qq >> "$APT_LOG" 2>&1; then
        log_warn "腾讯云镜像不可用，尝试官方源..."
        cat > "$sources_list" <<'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-backports main contrib non-free non-free-firmware
EOF
        apt-get update -qq >> "$APT_LOG" 2>&1 || true
    fi
    log_info "APT 源配置完成"
}

# =============================================================================
# 系统清理
# =============================================================================
clean_system() {
    log_step "清理系统..."

    # 关闭常见有冲突的服务（始终执行，因为这些服务本身就可能干扰网络栈）
    local stop_svcs=(snapd apache2 nginx postfix exim4 ufw)
    for svc in "${stop_svcs[@]}"; do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    done

    # 卸载预装软件包（默认跳过；只有明确指定 --clean-system 才真正 purge）
    if [[ "${CLEAN_SYSTEM:-false}" != "true" ]]; then
        log_info "clean_system 跳过 apt purge（使用 --clean-system 可开启）"
    else
        local remove_pkgs=(snapd apache2-bin apache2-utils nginx nginx-light nginx-full postfix exim4-base exim4-config)
        local to_remove=()
        for pkg in "${remove_pkgs[@]}"; do
            dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" && to_remove+=("$pkg")
        done
        [[ ${#to_remove[@]} -gt 0 ]] && apt-get remove --purge -y "${to_remove[@]}" >> "$APT_LOG" 2>&1 || true
    fi

    apt-get autoremove -y >> "$APT_LOG" 2>&1 || true
    apt-get autoclean >> "$APT_LOG" 2>&1 || true
    log_info "系统清理完成"
}

# =============================================================================
# 安装基础工具
# =============================================================================
install_base_tools() {
    log_step "安装基础工具..."
    local tools=(
        curl wget git jq vim htop net-tools dnsutils
        traceroute mtr iptraf-ng iftop iperf3 sysstat
        ncdu tree rsync tmux unzip zip
        ca-certificates gnupg lsb-release apt-transport-https
        dirmngr ethtool pciutils bc dc cron
    )
    local to_install=()
    for tool in "${tools[@]}"; do
        command -v "$tool" &>/dev/null || to_install+=("$tool")
    done
    [[ ${#to_install[@]} -gt 0 ]] && {
        apt-get install -y --no-install-recommends "${to_install[@]}" >> "$APT_LOG" 2>&1
        log_info "已安装 ${#to_install[@]} 个工具"
    }
}

# =============================================================================
# DNS 配置
# =============================================================================
configure_dns() {
    log_step "配置 DNS..."
    mkdir -p /etc/systemd
    cat > /etc/systemd/resolved.conf <<'EOF'
[Resolve]
DNS=1.1.1.1 8.8.8.8 223.5.5.5
FallbackDNS=1.0.0.1 8.8.4.4 119.29.29.29
DNSSEC=no
DNSOverTLS=no
DNSStubListener=no
ReadEtcHosts=yes
EOF
    systemctl restart systemd-resolved 2>/dev/null || true
    systemctl enable systemd-resolved 2>/dev/null || true

    # DNS 防篡改：锁定 resolv.conf（百毒不侵核心）
    if [[ -f /etc/resolv.conf ]] && ! lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i'; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
        chattr +i /etc/resolv.conf 2>/dev/null || log_warn "chattr +i 失败（文件可能已上锁或权限不足）"
        log_info "DNS 配置已锁定（chattr +i）"
    fi

    log_info "DNS 配置完成"
}

# =============================================================================
# 防火墙：lo 网卡无脑放行（本地 Agent 通信豁免）
# =============================================================================
configure_firewall_lo() {
    log_step "配置防火墙 lo 网卡放行..."
    if command -v iptables &>/dev/null; then
        iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || iptables -A INPUT -i lo -j ACCEPT
        iptables -C OUTPUT -o lo -j ACCEPT 2>/dev/null || iptables -A OUTPUT -o lo -j ACCEPT
        log_info "lo 网卡已无脑放行"
    else
        log_info "iptables 未安装，跳过"
    fi
}

# =============================================================================
# npm 缓存指向 tmpfs（R4S TF卡保护专项；其他平台通用减少磁盘写入）
# =============================================================================
configure_npm_cache_tmpfs() {
    log_step "配置 npm/pip 缓存到 tmpfs..."
    local cache_dir="/tmp/agent_cache"
    mkdir -p "$cache_dir"
    chmod 1777 "$cache_dir"

    # npm 缓存
    if command -v npm &>/dev/null; then
        mkdir -p /etc/profile.d
        cat > /etc/profile.d/99-agent-cache.sh <<'EOFCACHE'
export npm_config_cache="/tmp/agent_cache"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/agent_cache}"
EOFCACHE
        chmod +x /etc/profile.d/99-agent-cache.sh
        log_info "npm 缓存已指向 $cache_dir"
    fi

    # pip 缓存
    if command -v pip3 &>/dev/null || command -v pip &>/dev/null; then
        mkdir -p /etc/profile.d
        cat >> /etc/profile.d/99-agent-cache.sh <<'EOFPIP'
export PIP_CACHE_DIR="/tmp/agent_cache/pip"
EOFPIP
        log_info "pip 缓存已指向 $cache_dir/pip"
    fi

    # 写入当前 shell 环境（覆盖本次执行）
    export npm_config_cache="/tmp/agent_cache"
    export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/agent_cache}"
}

# =============================================================================
# Systemd 内存统计（防止内存泄漏拖死系统）
# =============================================================================
configure_memory_accounting() {
    log_step "配置 systemd 内存统计..."
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/99-memory-accounting.conf <<'EOF'
[Manager]
DefaultMemoryAccounting=yes
EOF
    systemctl daemon-reload 2>/dev/null || true
    log_info "systemd 内存统计已启用"
}

# =============================================================================
# 时间同步
# =============================================================================
configure_time_sync() {
    log_step "配置时间同步..."
    if ! command -v chronyd &>/dev/null; then
        apt-get install -y chrony >> "$APT_LOG" 2>&1 || true
    fi
    cat > /etc/chrony/chrony.conf <<'EOF'
server 0.pool.ntp.org iburst
server 1.pool.ntp.org iburst
server 2.pool.ntp.org iburst
server 3.pool.ntp.org iburst
server ntp.cloud.tencent.com iburst
server time.google.com iburst
makestep 1.0 -1
rtcsync
logdir /var/log/chrony
EOF
    systemctl restart chronyd 2>/dev/null || true
    systemctl enable chronyd 2>/dev/null || true
    systemctl enable cron 2>/dev/null || true
    systemctl restart cron 2>/dev/null || true
    chronyc makestep 2>/dev/null || true
    log_info "时间同步配置完成"
}

# =============================================================================
# locale
# =============================================================================
configure_locale() {
    log_step "配置 locale..."

    # 立即导出：解决 bash <(curl) 非login shell 的 locale 丢失问题
    export LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 LANGUAGE=zh_CN.UTF-8

    if locale -a 2>/dev/null | grep -qi "zh_CN"; then
        log_info "中文 locale 已存在"
    else
        apt-get install -y locales >> "$APT_LOG" 2>&1 || true
        sed -i '/zh_CN.UTF-8/s/^# //' /etc/locale.gen 2>/dev/null || true
        locale-gen >> "$APT_LOG" 2>&1 || true
    fi

    # 多层持久化：覆盖 login/non-login/login shell / systemd / PAM
    update-locale LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 2>/dev/null || true
    echo "LANG=zh_CN.UTF-8" > /etc/locale.alias 2>/dev/null || true
    cat > /etc/environment.d/90-chinese.conf <<'EOF'
LANG=zh_CN.UTF-8
LC_ALL=zh_CN.UTF-8
LANGUAGE=zh_CN.UTF-8
EOF

    echo "LANG=zh_CN.UTF-8" > /etc/default/locale
    echo "LC_ALL=zh_CN.UTF-8" >> /etc/default/locale

    log_info "中文 locale 配置完成"
}

# =============================================================================
# 系统限制
# =============================================================================
configure_limits() {
    log_step "配置系统限制..."
    local limits_file="/etc/security/limits.conf"
    backup_file "$limits_file"

    cat >> "$limits_file" <<'EOF'

* soft nofile 524288
* hard nofile 524288
* soft nproc 65535
* hard nproc 65535
root soft nofile 1048576
root hard nofile 1048576
root soft nproc 131072
root hard nproc 131072
EOF

    [[ -f /proc/sys/fs/inotify/max_user_watches ]] && echo 1048576 > /proc/sys/fs/inotify/max_user_watches
    [[ -f /proc/sys/fs/inotify/max_user_instances ]] && echo 8192 > /proc/sys/fs/inotify/max_user_instances

    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-inotify.conf <<'EOF'
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 8192
EOF

    # Systemd limits
    mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
    cat > /etc/systemd/system.conf.d/99-ai-limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=131072
EOF
    cat > /etc/systemd/user.conf.d/99-ai-limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=65535
EOF
    mkdir -p /etc/systemd/system/docker.service.d
    cat > /etc/systemd/system/docker.service.d/override.conf <<'EOF'
[Service]
LimitNOFILE=1048576
LimitNPROC=65535
EOF
    systemctl daemon-reload || log_warn "daemon-reload 失败，服务可能使用旧配置"
    log_info "系统限制配置完成"
}

# =============================================================================
# journald
# =============================================================================
configure_journald() {
    log_step "配置 journald..."
    mkdir -p /etc/systemd
    cat > /etc/systemd/journald.conf <<'EOF'
[Journal]
SystemMaxUse=300M
SystemMaxFileSize=50M
RuntimeMaxUse=150M
MaxRetentionSec=7day
Compress=yes
Storage=persistent
ForwardToSyslog=no
MaxLevelStore=notice
EOF
    systemctl restart systemd-journald 2>/dev/null || true
    log_info "journald 配置完成"
}

# =============================================================================
# I/O 调度
# =============================================================================
optimize_io_scheduler() {
    log_step "优化 I/O 调度..."
    if [[ "$SYS_IS_SSD" == "true" ]]; then
        for dev in /sys/block/*/queue/scheduler; do
            [[ -f "$dev" ]] && echo "none" > "$dev" 2>/dev/null || true
        done
        log_info "SSD: none 调度器"
    else
        for dev in /sys/block/*/queue/scheduler; do
            [[ -f "$dev" ]] && echo "mq-deadline" > "$dev" 2>/dev/null || true
        done
        log_info "HDD: mq-deadline 调度器"
    fi
    for dev in /sys/block/*/queue/read_ahead_kb; do
        [[ -f "$dev" ]] && echo 4096 > "$dev" 2>/dev/null || true
    done
}

# =============================================================================
# 平台信息
# =============================================================================
readonly PLATFORM_NAME="N5105/N5095 小主机"
readonly PLATFORM_DESC="Intel N5105/N5095 x86_64, 低功耗小主机, SSD"

# =============================================================================
# 平台变量
# =============================================================================
ZRAM_SIZE=0
[[ $SYS_MEM_MB -lt 4096 ]] && ZRAM_SIZE=512
SWAPPINESS=20
TCP_BUF_MAX=25165824  # 24MB
TCP_TW_BUCKETS=65536
CT_MAX=1048576
MIN_FREE_KB=32768

# =============================================================================
# 检测 N5105
# =============================================================================
detect_n5105() {
    log_step "检测 N5105/N5095 平台..."
    if echo "$SYS_CPU_MODEL" | grep -qiE "N5105|N5095|J6412|J6413|Alder Lake|N100|N200|Celeron|Pentium"; then
        log_info "检测到 Intel 小主机: $SYS_CPU_MODEL"
        return 0
    fi
    if [[ "$(uname -m)" == "x86_64" ]]; then
        log_info "检测到 x86_64 平台: $SYS_CPU_MODEL"
        return 0
    fi
    log_error "N5105 脚本需要在 x86_64 架构运行"
    return 1
}

# =============================================================================
# 内存优化
# =============================================================================
optimize_memory_n5105() {
    log_step "配置内存优化 (N5105 ${SYS_MEM_MB}MB)..."

    for sw in /swapfile /swap.img; do
        swapon --show 2>/dev/null | grep -q "$sw" && swapoff "$sw" 2>/dev/null || true
        [[ -f "$sw" ]] && rm -f "$sw"
    done
    sed -i '/swapfile/d; /swap.img/d' /etc/fstab 2>/dev/null || true

    if [[ $SYS_MEM_MB -ge 4096 ]]; then
        ZRAM_SIZE=0
        log_info "内存 >= 4GB，跳过 ZRAM"
    else
        ZRAM_SIZE=512
        log_info "内存 < 4GB，启用 ZRAM ${ZRAM_SIZE}MB"
    fi

    [[ -f /sys/module/zswap/parameters/enabled ]] && echo N > /sys/module/zswap/parameters/enabled 2>/dev/null || true

    if [[ $ZRAM_SIZE -gt 0 ]]; then
        if modinfo zram >/dev/null 2>&1 || [[ -d /sys/block/zram0 ]]; then
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
            lsblk | grep -q zram && log_info "ZRAM ${ZRAM_SIZE}MB (lzo) 已启用"
        fi
    fi

    sysctl -w vm.swappiness=$SWAPPINESS 2>/dev/null || true
    log_info "内存优化完成"
}

# =============================================================================
# sysctl 优化 (v3.1)
# =============================================================================
configure_sysctl_n5105() {
    log_step "配置 sysctl (N5105 v3.1)..."

    local sysctl_file="/etc/sysctl.d/99-openclaw.conf"
    backup_file "$sysctl_file"

    cat > "$sysctl_file" <<EOF
# N5105/N5095 小主机 OpenClaw 优化配置 v3.1
# Intel x86_64 低功耗平台

# === 网络缓冲区 (N5105 - 24MB) ===
net.core.rmem_max = ${TCP_BUF_MAX}
net.core.wmem_max = ${TCP_BUF_MAX}
net.ipv4.ip_local_port_range = 10240 65535
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.netdev_max_backlog = 65535
net.core.somaxconn = 65535

# === TCP (N5105 优化) ===
net.ipv4.tcp_rmem = 4096 131072 ${TCP_BUF_MAX}
net.ipv4.tcp_wmem = 4096 131072 ${TCP_BUF_MAX}
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_early_retrans = 3
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = ${TCP_TW_BUCKETS}
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_rfc1337 = 1

# === BBR ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# === 内存 ===
vm.swappiness = ${SWAPPINESS}
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.dirty_writeback_centisecs = 1500
vm.dirty_expire_centisecs = 15000
vm.min_free_kbytes = ${MIN_FREE_KB}
vm.overcommit_memory = 1
vm.vfs_cache_pressure = 50


# === 连接追踪 ===
net.netfilter.nf_conntrack_max = ${CT_MAX}
net.netfilter.nf_conntrack_hashsize = ${CT_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 900
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 20
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 20
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 10
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 10

# === 安全 ===
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0

net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.tcp_syncookies = 1

# === IPv6 ===
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.default.forwarding = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# === 网关转发（Docker 容器网络必需；无容器时开启无害） ===
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# 内核安全强化
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
kernel.yama.ptrace_scope = 1
EOF

    # 加载 BBR 模块
    if modprobe tcp_bbr 2>/dev/null; then
        log_info "BBR 已加载"
    else
        log_warn "BBR 加载失败（内核可能不支持）"
    fi
    modprobe tcp_dctcp 2>/dev/null || true
    sysctl -p "$sysctl_file" 2>/dev/null || true
    log_info "sysctl N5105 v3.1 优化完成"
}

# =============================================================================
# 网卡优化
# =============================================================================
optimize_network_n5105() {
    log_step "优化网卡 (N5105)..."

    [[ -z "$SYS_NET_IF" ]] && SYS_NET_IF=$(ip route show default | awk '/default/{print $5; exit}')

    if [[ -n "$SYS_NET_IF" && -d "/sys/class/net/$SYS_NET_IF" ]]; then
        ethtool -K "$SYS_NET_IF" tso on 2>/dev/null || true
        ethtool -K "$SYS_NET_IF" gso on 2>/dev/null || true
        ethtool -K "$SYS_NET_IF" gro on 2>/dev/null || true
        ethtool -A "$SYS_NET_IF" rx on 2>/dev/null || true
        ethtool -A "$SYS_NET_IF" tx on 2>/dev/null || true

        # 增加网卡队列长度（小主机大流量优化）
        ip link set "$SYS_NET_IF" txqueuelen 10000 2>/dev/null || true

        local speed
        speed=$(ethtool "$SYS_NET_IF" 2>/dev/null | grep "Speed:" | awk '{print $2}' || echo "unknown")
        log_info "网卡 $SYS_NET_IF 优化完成 (Speed: $speed, TX: 10000)"

        # RPS (所有RX队列)
        if [[ $SYS_CPU_CORES -gt 1 ]]; then
            local cores=$((SYS_CPU_CORES > 63 ? 63 : SYS_CPU_CORES))
            local mask; mask=$(printf '%x' $(( (1 << cores) - 1 )))
            for rps_file in /sys/class/net/${SYS_NET_IF}/queues/rx-*/rps_cpus; do
                [[ -f "$rps_file" ]] || continue
                printf "%s" "$mask" > "$rps_file" 2>/dev/null || true
            done
            log_info "RPS 启用 (CPU mask: 0x$mask)"
        fi
    fi

    if command -v irqbalance &>/dev/null; then
        systemctl enable irqbalance 2>/dev/null || true
        log_info "irqbalance 已启用"
    fi
}

# =============================================================================
# x86 特定优化 (v3.1 - 性能模式)
# =============================================================================
optimize_x86() {
    log_step "x86 特定优化 (v3.1 性能模式)..."

    # Intel P-State
    if [[ -d /sys/devices/system/cpu/intel_pstate ]]; then
        echo "performance" > /sys/devices/system/cpu/intel_pstate/status 2>/dev/null || true
        log_info "Intel P-State: performance"
    fi

    # CPU 频率（强制performance，避免降频影响AIagent响应速度）
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [[ -f "$cpu" && -w "$cpu" ]] || continue
        echo "performance" > "$cpu" 2>/dev/null || true
    done

    # Turbo Boost 监控（默认保持启用，有风扇可全力跑）
    local turbo_boost="/sys/devices/system/cpu/intel_pstate/no_turbo"
    if [[ -f "$turbo_boost" ]]; then
        local turbo_state
        turbo_state=$(cat "$turbo_boost" 2>/dev/null || echo "unknown")
        if [[ "$turbo_state" == "1" ]]; then
            log_info "Turbo Boost: 已禁用"
        else
            log_info "Turbo Boost: 启用 (性能模式)"
        fi
    fi

    # C-states 控制（省电但可能增加延迟）
    local cpuidle_dir="/sys/devices/system/cpu/cpu0/cpuidle"
    if [[ -d "$cpuidle_dir" ]]; then
        # 启用 deep C-state
        for state in "$cpuidle_dir"/state*/disable; do
            [[ -f "$state" && -w "$state" ]] || continue
            if [[ "$state" == *"state0"* ]]; then
                echo 0 > "$state" 2>/dev/null || true
            fi
        done
        log_info "CPU C-states 已配置"
    fi

    log_info "x86 特定优化完成"
}

# =============================================================================
# OOM
# =============================================================================
optimize_oom() {
    log_step "配置 OOM Killer..."
    mkdir -p /etc/systemd/system/openclaw-gateway.service.d
    cat > /etc/systemd/system/openclaw-gateway.service.d/oom.conf <<'EOF'
[Service]
OOMScoreAdjust=-200
EOF
    log_info "OOM Killer 优化完成"
}

# =============================================================================
# 自动清理 cron（AIagent 长期运行保护）
# =============================================================================
configure_cleanup_cron() {
    log_step "配置自动清理..."
    mkdir -p /usr/local/bin
    cat > /usr/local/bin/aiagent-cleanup.sh <<'EOTCLEANUP'
#!/bin/bash
# AIagent 清理脚本 - 通用版
docker image prune -af --filter "until=168h" 2>/dev/null || true
journalctl --vacuum-size=50M 2>/dev/null || true
journalctl --vacuum-time=7d 2>/dev/null || true
find /tmp -type f -mtime +1 -delete 2>/dev/null || true
find /var/tmp -type f -mtime +1 -delete 2>/dev/null || true
find /root/.openclaw/sessions -name "*.json" -mmin +10080 -delete 2>/dev/null || true
find /root/.hermes/sessions -name "*.json" -mmin +10080 -delete 2>/dev/null || true
npm cache clean --force 2>/dev/null || true
exit 0
EOTCLEANUP
    chmod +x /usr/local/bin/aiagent-cleanup.sh

    local cron_file="/var/spool/cron/crontabs/root"
    mkdir -p "$(dirname "$cron_file")"
    touch "$cron_file"
    chmod 600 "$cron_file"
    if ! grep -q "aiagent-cleanup" "$cron_file" 2>/dev/null; then
        echo "0 3 * * * /usr/local/bin/aiagent-cleanup.sh >> /var/log/aiagent-cleanup.log 2>&1" >> "$cron_file"
    fi
    log_info "自动清理已配置"
}

# =============================================================================
# 禁用自动更新，追求极致控制力
# =============================================================================
disable_auto_updates() {
    log_step "禁用自动更新 (追求极致控制)..."
    systemctl mask apt-daily.service apt-daily.timer \
        apt-daily-upgrade.service apt-daily-upgrade.timer 2>/dev/null || true
    if dpkg -l unattended-upgrades 2>/dev/null | grep -q "^ii"; then
        apt-get remove --purge -y unattended-upgrades >> "$APT_LOG" 2>&1 || true
        log_info "unattended-upgrades 已移除"
    fi
    log_info "自动更新已禁用"
}

# =============================================================================
# logrotate 配置
# =============================================================================
configure_logrotate() {
    log_step "配置 logrotate..."
    mkdir -p /etc/logrotate.d
    cat > /etc/logrotate.d/openclaw <<'EOFLOGROTATE'
/var/log/openclaw/*.log /var/log/aiagent-cleanup.log {
    daily
    rotate 2
    size 5M
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
    postrotate
        systemctl reload systemd-journald 2>/dev/null || true
    endscript
}
/var/log/openclaw-install.log {
    daily
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
}
EOFLOGROTATE
    log_info "logrotate 已配置"
}

# =============================================================================
# SSH
# =============================================================================
optimize_ssh() {
    log_step "SSH 安全加固..."

    # 优先使用 sshd_config.d drop-in（不影响主配置文件）
    local dropin_dir="/etc/ssh/sshd_config.d"
    local dropin_file="${dropin_dir}/99-vps-optimize.conf"
    mkdir -p "$dropin_dir" 2>/dev/null || true

    # 生成 drop-in 配置（保留原有 PermitRootLogin/PubkeyAuthentication 行为）
    cat > "$dropin_file" <<'EOFS'
# VPS-youhua SSH 安全配置 — 由脚本维护，请勿手动修改
PermitEmptyPasswords no
ClientAliveInterval 3600
ClientAliveCountMax 3
X11Forwarding no
EOFS
    chmod 644 "$dropin_file"

    # 语法验证（防止把自己锁外面）
    if command -v sshd &>/dev/null; then
        if ! sshd -t -f "$dropin_file" 2>&1 | grep -qi "error"; then
            log_info "SSH drop-in 已应用 + 语法验证通过"
        else
            log_warn "SSH drop-in 语法异常，移除并跳过"
            rm -f "$dropin_file"
        fi
    fi

    # 记录上次登录
    echo -e "  \${CYAN}上次登录记录:\${RESET}"
    last -n 3 2>/dev/null | grep -v "^$" | head -3 | sed "s/^/    /" || true
}

# =============================================================================
# Node.js
# =============================================================================
install_nodejs() {
    if [[ "$INSTALL_NODEJS" != "true" ]]; then
        log_info "跳过 Node.js 安装"
        return 0
    fi
    log_step "安装 Node.js ${NODEJS_VERSION}..."
    if command -v node &>/dev/null; then
        log_info "Node.js 已安装: $(node --version)"
        return 0
    fi
    curl --max-time 90 -fsSL "https://deb.nodesource.com/setup_${NODEJS_VERSION}.x" | bash - >> "$APT_LOG" 2>&1 || {
        log_warn "NodeSource 安装失败，使用系统包..."
        apt-get install -y nodejs npm >> "$APT_LOG" 2>&1 || true
        return 0
    }
    apt-get install -y nodejs >> "$APT_LOG" 2>&1
    if command -v node &>/dev/null; then
        log_info "Node.js $(node --version) 安装成功"
    fi
}

# =============================================================================
# Docker
# =============================================================================
install_docker() {
    if [[ "$INSTALL_DOCKER" != "true" ]]; then
        log_info "跳过 Docker 安装"
        return 0
    fi
    log_step "安装 Docker..."
    if command -v docker &>/dev/null; then
        log_info "Docker 已安装: $(docker --version)"
        return 0
    fi
    curl --max-time 120 -fsSL https://get.docker.com | sh -s -- --mirror Aliyun >> "$APT_LOG" 2>&1 || {
        log_warn "Docker 安装失败，使用系统包..."
        apt-get install -y docker.io docker-compose >> "$APT_LOG" 2>&1 || true
    }
    systemctl enable docker 2>/dev/null || true
    systemctl start docker 2>/dev/null || true

    # 等待 Docker daemon 就绪
    local docker_ready=false
    for i in {1..30}; do
        if docker info >/dev/null 2>&1; then
            docker_ready=true
            break
        fi
        sleep 1
    done
    [[ "$docker_ready" != "true" ]] && log_warn "Docker daemon 未就绪"

    # Docker registry mirror 连通性检测（失败则降级到官方源）
    local registry_mirror=""
    if curl --max-time 5 -fsSL "https://mirror.ccs.tencentyi.com" >/dev/null 2>&1; then
        registry_mirror="\"registry-mirrors\": [\"https://mirror.ccs.tencentyi.com\"]"
        log_info "Docker registry mirror (腾讯云) 可达"
    else
        log_warn "Docker registry mirror 不可达，降级到官方源"
    fi

    mkdir -p /etc/docker
    local daemon_json="{
    \"storage-driver\": \"overlay2\",
    \"log-driver\": \"json-file\",
    \"log-opts\": {\"max-size\": \"100m\", \"max-file\": \"3\"},
    \"live-restore\": true,
    \"userland-proxy\": false"
    if [[ -n "$registry_mirror" ]]; then
        daemon_json+=",
    $registry_mirror"
    fi
    daemon_json+="
}"
    printf '%s\n' "$daemon_json" > /etc/docker/daemon.json
    systemctl restart docker 2>/dev/null || true
    if command -v docker &>/dev/null; then
        log_info "Docker $(docker --version) 安装成功"
    fi
}

# =============================================================================
# OpenClaw
# =============================================================================
install_openclaw() {
    log_step "安装 OpenClaw..."
    if ! id -u "$OPENCLAW_USER" &>/dev/null; then
        useradd -r -m -s /bin/bash -c "OpenClaw Service Account" "$OPENCLAW_USER" 2>/dev/null || true
    fi

    if [[ "${INSTALL_METHOD:-}" == "docker" ]]; then
        log_info "使用 Docker 容器安装 OpenClaw..."
        if ! command -v docker &>/dev/null; then install_docker; fi
        mkdir -p "$OPENCLAW_DATA_DIR"
        chown -R "$OPENCLAW_USER:$OPENCLAW_USER" "$OPENCLAW_DATA_DIR" 2>/dev/null || true
        log_info "拉取 OpenClaw 镜像..."
        timeout 300 docker pull openclaw/openclaw:latest >> "$APT_LOG" 2>&1 || {
            timeout 300 docker pull ghcr.io/openclaw/openclaw:latest >> "$APT_LOG" 2>&1 || {
                log_error "Docker 镜像拉取失败"
                return 1
            }
        }
        log_info "OpenClaw 容器安装完成"
    else
        log_info "使用全局安装 OpenClaw (npm install -g)..."
        if ! command -v openclaw &>/dev/null; then
            npm install -g openclaw --registry https://registry.npmmirror.com >> "$APT_LOG" 2>&1 || {
                npm install -g openclaw >> "$APT_LOG" 2>&1 || {
                    log_error "OpenClaw 安装失败"
                    return 1
                }
            }
        fi
        mkdir -p "$OPENCLAW_DATA_DIR"
        chown -R "$OPENCLAW_USER:$OPENCLAW_USER" "$OPENCLAW_DATA_DIR" 2>/dev/null || true
        log_info "OpenClaw 全局安装完成"
    fi
}

# =============================================================================
# systemd 服务
# =============================================================================
create_systemd_service() {
    log_step "创建 systemd 服务..."
    local memory_max="MemoryMax=2G"

    if [[ "${INSTALL_METHOD:-}" == "docker" ]]; then
        mkdir -p ~/.config/systemd/user
        cat > ~/.config/systemd/user/openclaw-gateway.service <<EOF
[Unit]
Description=OpenClaw AI Gateway (Docker)
Documentation=https://docs.openclaw.ai
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
Restart=on-failure
RestartSec=10
TimeoutStopSec=30

ExecStart=/usr/bin/docker run --rm \
    --name openclaw-gateway \
    --network host \
    -v ${OPENCLAW_DATA_DIR}:/root/.openclaw \
    -e OPENCLAW_DATA_DIR=/root/.openclaw \
    -e NODE_ENV=production \
    -e LANG=zh_CN.UTF-8 \
    -e LC_ALL=zh_CN.UTF-8 \
    openclaw/openclaw:latest gateway --port ${OPENCLAW_PORT}
ExecStop=/usr/bin/docker stop -t 10 openclaw-gateway
ExecStopPost=/usr/bin/docker rm -f openclaw-gateway

${memory_max}
OOMScoreAdjust=-200

[Install]
WantedBy=default.target
EOF
    else
        mkdir -p ~/.config/systemd/user
        cat > ~/.config/systemd/user/openclaw-gateway.service <<EOF
[Unit]
Description=OpenClaw AI Gateway
Documentation=https://docs.openclaw.ai
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${OPENCLAW_USER}
Group=${OPENCLAW_USER}
WorkingDirectory=${OPENCLAW_DATA_DIR}
Environment="NODE_ENV=production"
Environment="PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"
Environment="OPENCLAW_DATA_DIR=${OPENCLAW_DATA_DIR}"
Environment="LANG=zh_CN.UTF-8"
ExecStart=/usr/local/bin/openclaw gateway --port ${OPENCLAW_PORT}
ExecStop=/bin/kill -SIGTERM \$MAINPID
Restart=on-failure
RestartSec=10
TimeoutStopSec=30
LimitNOFILE=1048576
${memory_max}
OOMScoreAdjust=-200

[Install]
WantedBy=default.target
EOF
    fi

    systemctl --user daemon-reload || log_warn "daemon-reload 失败"
    loginctl enable-linger "$OPENCLAW_USER" 2>/dev/null || log_warn "loginctl enable-linger 失败，开机自启可能不生效"
    systemctl --user enable openclaw-gateway 2>/dev/null || true
    log_info "systemd 服务创建完成"

    log_step "提示: 运行以下命令启动服务:"
    echo "  systemctl --user start openclaw-gateway"
    echo "  systemctl --user enable openclaw-gateway  # 开机自启"
}

# =============================================================================
# 诊断
# =============================================================================
run_doctor() {
    log_step "运行诊断..."
    echo ""
    echo "=== AIagent 环境诊断报告 (N5105) ==="
    echo ""
    echo "1. 系统信息:"
    echo "   平台: $PLATFORM_NAME"
    echo "   CPU: $SYS_CPU_MODEL"
    echo "   核心: $SYS_CPU_CORES | 内存: ${SYS_MEM_MB}MB"
    echo "   SSD: ${SYS_IS_SSD}"
    echo ""

    echo "2. Turbo Boost:"
    local turbo_file="/sys/devices/system/cpu/intel_pstate/no_turbo"
    if [[ -f "$turbo_file" ]]; then
        local ts; ts=$(cat "$turbo_file" 2>/dev/null || echo "unknown")
        [[ "$ts" == "1" ]] && echo "   Turbo Boost: 禁用 (静音)" || echo "   Turbo Boost: 启用"
    fi

    echo "3. Docker:"
    if command -v docker &>/dev/null; then
        echo "   版本: $(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')"
        echo "   状态: $(systemctl is-active docker 2>/dev/null || echo 'inactive')"
    else
        echo "   未安装"
    fi
    echo ""

    echo "4. Node.js: $(node --version 2>/dev/null || echo '未安装')"
    echo ""

    echo "5. 端口监听:"
    ss -tlnp 2>/dev/null | grep -E "18789|18790" || netstat -tlnp 2>/dev/null | grep -E "18789|18790" || echo "   无"
    echo ""

    echo "6. 服务状态:"
    systemctl --user is-active openclaw-gateway 2>/dev/null && echo "   openclaw-gateway: active" || echo "   openclaw-gateway: inactive"
    systemctl is-active docker 2>/dev/null && echo "   docker: active" || echo "   docker: inactive"
    systemctl is-active chronyd 2>/dev/null && echo "   chronyd: active" || echo "   chronyd: inactive"
    echo ""

    echo "=== 诊断完成 ==="
}

# =============================================================================
# 主函数
# =============================================================================

# =============================================================================
# 卸载 / 回滚
# =============================================================================
uninstall_openclaw() {
    echo ""
    echo "========================================================================"
    echo -e "${RED}  OpenClaw 环境卸载 / 回滚${NC}"
    echo "========================================================================"
    echo ""

    # 参数解析：支持 --uninstall 或 OPENCLAW_UNINSTALL=1
    local do_uninstall=false
    if [[ "${1:-}" == "--uninstall" ]] || [[ "${OPENCLAW_UNINSTALL:-}" == "1" ]]; then
        do_uninstall=true
    fi

    if [[ "$do_uninstall" != "true" ]]; then
        return 0
    fi

    # root 权限检查
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[✗] 卸载需要 root 权限${NC}"
        exit 1
    fi

    # 并发锁（防止卸载时脚本正在安装）
    local lock_file="/var/lock/openclaw-uninstall.lock"
    exec 9>"$lock_file"
    if ! flock -n 9; then
        echo -e "${RED}[✗] 另一个实例正在运行，退出${NC}"
        exit 1
    fi

    echo -e "${YELLOW}警告：此操作将删除 OpenClaw 相关配置和服务！${NC}"
    echo ""
    echo "将执行以下清理："
    echo "  - 停止并禁用 openclaw-gateway 服务"
    echo "  - 删除 systemd service 文件"
    echo "  - 删除 /usr/local/bin/aiagent-cleanup.sh"
    echo "  - 清理 cron 中的 aiagent-cleanup 条目"
    echo "  - 删除 /etc/sysctl.d/99-openclaw.conf"
    echo "  - 删除 /etc/logrotate.d/openclaw"
    echo "  - 清理 Docker daemon.json（保留其他 Docker 配置）"
    echo "  - 删除 openclaw 用户（保留 home 目录）"
    echo "  - 删除 /etc/apt/sources.list.d/openclaw.list"
    echo "  - 删除 /etc/apt/preferences.d/openclaw*"
    echo ""
    echo -n "确认卸载？(输入 'yes' 继续): "
    read -r confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "已取消卸载。"
        exit 0
    fi

    echo ""
    echo -e "${CYAN}[➜] 开始卸载...${NC}"

    echo -e "${GREEN}[✓]${NC} 停止 openclaw-gateway 服务..."
    systemctl --user stop openclaw-gateway 2>/dev/null || true
    systemctl stop openclaw-gateway 2>/dev/null || true
    echo -e "${GREEN}[✓]${NC} 停止 docker 容器..."
    docker stop openclaw-gateway 2>/dev/null || true
    docker rm -f openclaw-gateway 2>/dev/null || true

    echo -e "${GREEN}[✓]${NC} 禁用开机自启..."
    systemctl --user disable openclaw-gateway 2>/dev/null || true
    systemctl disable openclaw-gateway 2>/dev/null || true

    echo -e "${GREEN}[✓]${NC} 删除 systemd service 文件..."
    rm -f /etc/systemd/system/openclaw-gateway.service
    rm -rf /etc/systemd/system/openclaw-gateway.service.d
    systemctl daemon-reload 2>/dev/null || true

    echo -e "${GREEN}[✓]${NC} 删除 aiagent-cleanup.sh..."
    rm -f /usr/local/bin/aiagent-cleanup.sh

    echo -e "${GREEN}[✓]${NC} 清理 cron 条目..."
    local cron_file="/var/spool/cron/crontabs/root"
    if [[ -f "$cron_file" ]]; then
        sed -i '/aiagent-cleanup/d' "$cron_file" 2>/dev/null || true
        if [[ ! -s "$cron_file" ]]; then
            rm -f "$cron_file"
        fi
    fi

    echo -e "${GREEN}[✓]${NC} 删除 sysctl 配置..."
    rm -f /etc/sysctl.d/99-openclaw.conf

    echo -e "${GREEN}[✓]${NC} 删除 logrotate 配置..."
    rm -f /etc/logrotate.d/openclaw

    echo -e "${GREEN}[✓]${NC} 清理 Docker daemon.json..."
    if [[ -f /etc/docker/daemon.json ]]; then
        local tmp_daemon="/tmp/daemon.json.$$"
        grep -v 'registry-mirrors' /etc/docker/daemon.json > "$tmp_daemon" 2>/dev/null || true
        if [[ -s "$tmp_daemon" ]] && [[ "$(tr -d '[:space:]' < "$tmp_daemon")" != "{}" ]]; then
            if command -v python3 &>/dev/null; then
                if python3 -c "import json; json.load(open('$tmp_daemon'))" 2>/dev/null; then
                    mv "$tmp_daemon" /etc/docker/daemon.json
                    systemctl restart docker 2>/dev/null || true
                else
                    echo -e "${YELLOW}[!]${NC} Docker daemon.json JSON 无效，保留原文件"
                    rm -f "$tmp_daemon"
                fi
            else
                mv "$tmp_daemon" /etc/docker/daemon.json
            fi
        else
            rm -f "$tmp_daemon" /etc/docker/daemon.json
        fi
    fi

    echo -e "${GREEN}[✓]${NC} 删除 apt sources..."
    rm -f /etc/apt/sources.list.d/openclaw.list
    rm -f /etc/apt/preferences.d/openclaw

    echo -e "${GREEN}[✓]${NC} 删除 openclaw 用户（保留 home 目录）..."
    id openclaw &>/dev/null && userdel openclaw 2>/dev/null || true

    echo ""
    echo "========================================================================"
    echo -e "${GREEN}  ✅ OpenClaw 卸载完成${NC}"
    echo "========================================================================"
    echo ""
    echo "提示："
    echo "  - Docker 保留在系统中"
    echo "  - Node.js 保留在系统中"
    echo "  - /home/openclaw 数据目录已保留（如需删除，请手动 rm -rf /home/openclaw）"
    echo ""
    exit 0
}

main() {
    clear
    echo "═══════════════════════════════════════════════════════════════════════"
    echo -e "${GREEN}  N5105/N5095 小主机专用优化安装脚本 v${SCRIPT_VERSION}${NC}"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo -e "${BLUE}平台: ${PLATFORM_DESC}${NC}"
    echo ""

    # 解析参数
    for arg in "$@"; do
        case "$arg" in
            --optimize-only) export SKIP_SOFTWARE_SCRIPT="true" ;;
            --uninstall) ;;
        esac
    done

    # install.sh 透传的环境变量优先
    : "${SKIP_SOFTWARE_SCRIPT:=false}"
    : "${INSTALL_DOCKER:=true}"
    : "${INSTALL_NODEJS:=false}"

    uninstall_openclaw "$@" || exit 1
    init_script
    detect_system
    check_network
    detect_n5105 || exit 1

    echo ""
    echo -e "${BLUE}优化计划:${NC}"
    echo "  平台:      ${PLATFORM_DESC}"
    echo "  CPU:       ${SYS_CPU_MODEL}"
    echo "  系统:      ${SYS_OS_ID} ${SYS_OS_VERSION}"
    echo "  架构:      ${SYS_ARCH} | 内存: ${SYS_MEM_MB}MB | CPU: ${SYS_CPU_CORES}核"
    echo "  ZRAM:      ${ZRAM_SIZE:-0}MB"

    if [[ "${SKIP_SOFTWARE_SCRIPT}" == "true" ]]; then
        echo "  模式:      ${YELLOW}纯优化（不安装任何软件）${NC}"
    else
        echo "  Docker:    ${INSTALL_DOCKER}"
        echo "  Node.js:   ${INSTALL_NODEJS}"
        echo "  模式:      全量安装"
    fi
    echo ""

    if [[ -t 0 ]]; then
        echo -n "继续执行？(y/n，默认 y): "
        read -r confirm
        [[ "$confirm" == "n" || "$confirm" == "N" ]] && exit 0
    fi

    echo ""
    log_step "开始优化..."
    echo ""

    backup_all
    preflight_check
    configure_apt_sources
    clean_system
    optimize_memory_n5105
    configure_sysctl_n5105
    configure_limits
    configure_journald
    configure_dns
    configure_time_sync
    configure_locale
    configure_firewall_lo
    configure_npm_cache_tmpfs
    configure_memory_accounting
    optimize_io_scheduler
    optimize_x86
    optimize_network_n5105
    optimize_oom
    disable_auto_updates
    configure_cleanup_cron
    configure_logrotate
    optimize_ssh

    # ── 软件安装（受 install.sh 环境变量控制）─────────────────────────────
    if [[ "${SKIP_SOFTWARE_SCRIPT}" != "true" ]]; then
        install_base_tools || exit 1
        install_nodejs || exit 1
        install_docker || exit 1
        install_openclaw || exit 1
        create_systemd_service || exit 1
        local did_install=true
    else
        log_info "纯优化模式，跳过 Docker / Node.js / OpenClaw 安装"
        local did_install=false
    fi

    run_doctor || { log_warn "诊断报告有异常，但继续完成"; }

    apt-get autoremove -y >> "$APT_LOG" 2>&1 || true
    apt-get autoclean >> "$APT_LOG" 2>&1 || true

    echo ""
    echo "═══════════════════════════════════════════════════════════════════════"
    echo -e "${GREEN}  ✅ N5105/N5095 v${SCRIPT_VERSION} 优化完成！${NC}"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo ""
    echo -e "${CYAN}系统优化内容:${NC}"
    echo "  - sysctl 网络/内存/内核参数"
    echo "  - journald 日志压缩 + 100MB 限制"
    echo "  - DNS 锁定（chattr +i）"
    echo "  - CPU governor 持久化"
    echo "  - 防火墙（仅 lo 接口放行）"
    echo "  - /tmp tmpfs（减少磁盘写入）"

    if [[ "$did_install" == "true" ]]; then
        echo ""
        echo -e "${CYAN}后续步骤:${NC}"
        echo "  1. reboot  ← 必须重启！sysctl/CPU governor/journald 不重启不生效"
        echo "  2. sudo -u ${OPENCLAW_USER} -i openclaw onboard"
        echo "  3. systemctl --user start openclaw-gateway"
        echo "  4. systemctl --user enable openclaw-gateway  # 开机自启"
    else
        echo ""
        echo -e "${CYAN}后续步骤:${NC}"
        echo "  1. reboot  ← 必须重启！sysctl/CPU governor/journald 不重启不生效"
        echo "  2. 接下来安装你的软件（Docker / Xray / Nginx / OpenClaw 等）"
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
