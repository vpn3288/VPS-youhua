#!/usr/bin/env bash
# =============================================================================
# NanoPi R4S 专用优化安装脚本
# 硬件: RK3399 ARM64, 4GB RAM, 双网口
# 特点: 适合家庭网关用途, 低功耗, 双网口
# =============================================================================
#
# 一键运行: bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/nanopi-r4s.sh)
#

set -euo pipefail
IFS=$'\n\t'

# 加载通用函数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# =============================================================================
# OpenClaw 安装脚本 - 通用函数库
# 所有平台共享的函数和变量
# =============================================================================

set -euo pipefail
IFS=$'\n\t'


# 颜色
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_step()  { echo -e "${CYAN}[➜]${NC} $1"; }
log_debug() { [[ "${DEBUG:-0}" == "1" ]] && echo -e "${MAGENTA}[DEBUG]${NC} $1" || true; }

# ─────────────────────────────────────────────────────────────────────────────
# 全局变量
# ─────────────────────────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="2.0"
readonly APT_LOG="/var/log/openclaw-install.log"
readonly LOCK_FILE="/var/lock/openclaw-install.lock"

# 系统信息
SYS_MEM_MB=0; SYS_CPU_CORES=0; SYS_ARCH=""
SYS_KERNEL=""; SYS_OS_ID=""; SYS_OS_VERSION=""
SYS_DISK_TOTAL_GB=0; SYS_DISK_AVAIL_GB=0
SYS_NET_IF=""

# 安装选项
INSTALL_DOCKER="${INSTALL_DOCKER:-true}"
INSTALL_NODEJS="${INSTALL_NODEJS:-true}"
NODEJS_VERSION="${NODEJS_VERSION:-24}"
OPENCLAW_USER="${OPENCLAW_USER:-openclaw}"
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
OPENCLAW_DATA_DIR="${OPENCLAW_DATA_DIR:-/opt/openclaw}"

# ─────────────────────────────────────────────────────────────────────────────
# 初始化
# ─────────────────────────────────────────────────────────────────────────────
init_script() {
    # 并发锁
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log_error "另一个实例正在运行，退出"
        exit 1
    fi
    
    export DEBIAN_FRONTEND=noninteractive
    
    # 创建日志目录
    mkdir -p "$(dirname "$APT_LOG")"
    : > "$APT_LOG"
}

# ─────────────────────────────────────────────────────────────────────────────
# 系统检测
# ─────────────────────────────────────────────────────────────────────────────
detect_system() {
    log_step "检测系统信息..."
    
    SYS_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
    [[ -z "$SYS_MEM_MB" || "$SYS_MEM_MB" -eq 0 ]] && SYS_MEM_MB=1024
    
    SYS_CPU_CORES=$(nproc 2>/dev/null || echo 1)
    SYS_KERNEL=$(uname -r)
    SYS_ARCH=$(uname -m)
    
    SYS_OS_ID=$(grep -oP '(?<=^ID=).+' /etc/os-release 2>/dev/null | tr -d '"' || echo "unknown")
    SYS_OS_VERSION=$(grep -oP '(?<=^VERSION_ID=).+' /etc/os-release 2>/dev/null | tr -d '"' || echo "unknown")
    
    SYS_DISK_TOTAL_GB=$(df -BG / 2>/dev/null | awk 'NR==2 {print $2}' | tr -d 'G' || echo 0)
    SYS_DISK_AVAIL_GB=$(df -BG / 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G' || echo 0)
    
    SYS_NET_IF=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}' || true)
    [[ -z "$SYS_NET_IF" ]] && SYS_NET_IF=$(ip -6 route show default 2>/dev/null | awk '/default/{print $5; exit}' || true)
    
    log_info "系统: ${SYS_OS_ID} ${SYS_OS_VERSION}"
    log_info "架构: ${SYS_ARCH} | 内存: ${SYS_MEM_MB}MB | CPU: ${SYS_CPU_CORES}核"
}

# ─────────────────────────────────────────────────────────────────────────────
# 网络检测
# ─────────────────────────────────────────────────────────────────────────────
check_network() {
    log_step "检测网络连接..."
    
    if ! ping -c1 -W3 8.8.8.8 &>/dev/null; then
        log_error "无法连接到 8.8.8.8，请检查网络"
        exit 1
    fi
    
    log_info "网络连接正常"
}

# ─────────────────────────────────────────────────────────────────────────────
# 预检查
# ─────────────────────────────────────────────────────────────────────────────
preflight_check() {
    log_step "执行预检查..."
    
    local errors=0
    
    [[ $EUID -ne 0 ]] && {
        log_error "需要 root 权限"
        ((errors++))
    }
    
    [[ $SYS_DISK_AVAIL_GB -lt 3 ]] && {
        log_warn "磁盘可用空间 ${SYS_DISK_AVAIL_GB}GB < 3GB"
    }
    
    [[ $SYS_MEM_MB -lt 256 ]] && {
        log_warn "内存 ${SYS_MEM_MB}MB < 256MB，可能不稳定"
    }
    
    if ! ping -c1 -W3 github.com &>/dev/null; then
        log_warn "无法访问 GitHub，部分功能可能受限"
    fi
    
    [[ $errors -gt 0 ]] && exit 1
    
    log_info "预检查通过"
}

# ─────────────────────────────────────────────────────────────────────────────
# 备份配置
# ─────────────────────────────────────────────────────────────────────────────
backup_file() {
    local file="$1"
    [[ -f "$file" ]] && cp -a "$file" "${file}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# APT 配置
# ─────────────────────────────────────────────────────────────────────────────
configure_apt_sources() {
    log_step "配置 APT 源..."
    
    local sources_list="/etc/apt/sources.list"
    local codename
    codename=$(grep -oP '(?<=^VERSION_CODENAME=).+' /etc/os-release 2>/dev/null | tr -d '"' || echo "bookworm")
    
    backup_file "$sources_list"
    
    # 非交互式配置
    mkdir -p /etc/apt/apt.conf.d /etc/needrestart/conf.d
    cat > /etc/apt/apt.conf.d/99-noninteractive <<'EOF'
DPkg::Options {"--force-confdef"; "--force-confold";};
APT::Get::Assume-Yes "true";
APT::Get::Fix-Missing "true";
EOF
    cat > /etc/needrestart/conf.d/99-openclaw.conf <<'EOF'
$nrconf{restart} = 'a';
$nrconf{kernelhints} = 0;
$nrconf{unneeded} = 'a';
EOF
    
    # 写入源
    cat > "$sources_list" <<EOF
# Debian ${codename} - OpenClaw Install
deb http://mirrors.tencent.com/debian/ ${codename} main contrib non-free non-free-firmware
deb http://mirrors.tencent.com/debian/ ${codename}-updates main contrib non-free non-free-firmware
deb http://mirrors.tencent.com/debian-security/ ${codename}-security main contrib non-free non-free-firmware
deb http://mirrors.tencent.com/debian/ ${codename}-backports main contrib non-free non-free-firmware
EOF
    
    # 验证
    if ! apt-get update -qq >> "$APT_LOG" 2>&1; then
        log_warn "腾讯云镜像不可用，尝试官方源..."
        cat > "$sources_list" <<'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-backports main contrib non-free non-free-firmware
EOF
        apt-get update -qq >> "$APT_LOG" 2>&1 || true
    fi
    
    log_info "APT 源配置完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# 系统清理
# ─────────────────────────────────────────────────────────────────────────────
clean_system() {
    log_step "清理系统..."
    
    local stop_svcs=(snapd apache2 nginx postfix exim4 ufw)
    for svc in "${stop_svcs[@]}"; do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    done
    
    local remove_pkgs=(snapd apache2-bin apache2-utils nginx nginx-light nginx-full postfix exim4-base exim4-config)
    local to_remove=()
    for pkg in "${remove_pkgs[@]}"; do
        dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" && to_remove+=("$pkg")
    done
    
    [[ ${#to_remove[@]} -gt 0 ]] && {
        apt-get remove --purge -y "${to_remove[@]}" >> "$APT_LOG" 2>&1 || true
    }
    
    apt-get autoremove -y >> "$APT_LOG" 2>&1 || true
    apt-get autoclean >> "$APT_LOG" 2>&1 || true
    
    log_info "系统清理完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# 安装基础工具
# ─────────────────────────────────────────────────────────────────────────────
install_base_tools() {
    log_step "安装基础工具..."
    
    local tools=(
        curl wget git jq vim htop net-tools dnsutils
        traceroute mtr iptraf-ng iftop iperf3 sysstat
        ncdu tree rsync tmux unzip zip
        ca-certificates gnupg lsb-release apt-transport-https
        dirmngr ethtool pciutils
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

# ─────────────────────────────────────────────────────────────────────────────
# DNS 配置
# ─────────────────────────────────────────────────────────────────────────────
configure_dns() {
    log_step "配置 DNS..."
    
    mkdir -p /etc/systemd
    cat > /etc/systemd/resolved.conf <<'EOF'
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=1.0.0.1 8.8.4.4
DNSStubListener=no
ReadEtcHosts=yes
EOF
    
    systemctl restart systemd-resolved 2>/dev/null || true
    systemctl enable systemd-resolved 2>/dev/null || true
    
    log_info "DNS 配置完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# 时间同步
# ─────────────────────────────────────────────────────────────────────────────
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
makestep 1.0 -1
logdir /var/log/chrony
EOF
    
    systemctl restart chronyd 2>/dev/null || true
    systemctl enable chronyd 2>/dev/null || true
    chronyc makestep 2>/dev/null || true
    
    log_info "时间同步配置完成"
}



# 配置中文 locale
configure_locale() {
    log_step "配置 locale..."
    
    # 检查是否已有中文 locale
    if locale -a 2>/dev/null | grep -qi "zh_CN"; then
        log_info "中文 locale 已存在"
        return 0
    fi
    
    # 安装中文 locale
    apt-get install -y locales >> "$APT_LOG" 2>&1 || true
    
    # 生置中文 locale
    sed -i '/zh_CN.UTF-8/s/^# //' /etc/locale.gen 2>/dev/null || true
    locale-gen >> "$APT_LOG" 2>&1 || true
    
    # 设置默认 locale
    update-locale LANG=zh_CN.UTF-8 2>/dev/null || true
    
    log_info "中文 locale 配置完成"
}




# ─────────────────────────────────────────────────────────────────────────────
# 自动检测服务器时区
# ─────────────────────────────────────────────────────────────────────────────
detect_timezone() {
    log_step "检测服务器时区..."
    
    local detected_tz=""
    
    # 方法1: timedatectl
    if command -v timedatectl &>/dev/null; then
        detected_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || true)
        if [[ -n "$detected_tz" && -f "/usr/share/zoneinfo/$detected_tz" ]]; then
            echo "$detected_tz"
            return 0
        fi
    fi
    
    # 方法2: /etc/timezone
    if [[ -f /etc/timezone ]] && [[ -n "$(cat /etc/timezone 2>/dev/null)" ]]; then
        detected_tz=$(cat /etc/timezone 2>/dev/null)
        if [[ -f "/usr/share/zoneinfo/$detected_tz" ]]; then
            echo "$detected_tz"
            return 0
        fi
    fi
    
    # 方法3: /etc/localtime 符号链接
    if [[ -L /etc/localtime ]]; then
        detected_tz=$(readlink -f /etc/localtime 2>/dev/null | sed 's|/usr/share/zoneinfo/||')
        if [[ -n "$detected_tz" && -f "/usr/share/zoneinfo/$detected_tz" ]]; then
            echo "$detected_tz"
            return 0
        fi
    fi
    
    # 方法4: IP 地理位置 API
    if ping -c1 -W3 ip-api.com &>/dev/null; then
        detected_tz=$(curl -s --max-time 5 http://ip-api.com/json/ 2>/dev/null | \
            python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('timezone',''))" 2>/dev/null || true)
        if [[ -n "$detected_tz" && -f "/usr/share/zoneinfo/$detected_tz" ]]; then
            echo "$detected_tz"
            return 0
        fi
    fi
    
    # 方法5: 美国时区 fallback
    for tz in "America/New_York" "America/Los_Angeles" "America/Chicago" "America/Denver"; do
        if [[ -f "/usr/share/zoneinfo/$tz" ]]; then
            echo "$tz"
            return 0
        fi
    done
    
    echo "UTC"
}

# ─────────────────────────────────────────────────────────────────────────────
# 配置时区
# ─────────────────────────────────────────────────────────────────────────────
configure_timezone() {
    log_step "配置时区..."
    
    local server_tz
    server_tz=$(detect_timezone)
    
    local current_tz=""
    if [[ -f /etc/timezone ]]; then
        current_tz=$(cat /etc/timezone 2>/dev/null || echo "")
    fi
    
    if [[ "$current_tz" == "$server_tz" ]]; then
        log_info "时区已是 $server_tz"
        return 0
    fi
    
    if command -v timedatectl &>/dev/null; then
        timedatectl set-timezone "$server_tz" 2>/dev/null && {
            log_info "时区已设置为 $server_tz"
            return 0
        }
    fi
    
    if [[ -f "/usr/share/zoneinfo/$server_tz" ]]; then
        ln -sf "/usr/share/zoneinfo/$server_tz" /etc/localtime 2>/dev/null
        echo "$server_tz" > /etc/timezone 2>/dev/null || true
        log_info "时区已设置为 $server_tz"
    else
        log_warn "无法设置时区 $server_tz"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 配置 locale
# ─────────────────────────────────────────────────────────────────────────────
configure_locale() {
    log_step "配置 locale..."
    
    if locale -a 2>/dev/null | grep -qi "zh_CN"; then
        log_info "中文 locale 已存在"
        return 0
    fi
    
    apt-get install -y locales >> "$APT_LOG" 2>&1 || true
    sed -i '/zh_CN.UTF-8/s/^# //' /etc/locale.gen 2>/dev/null || true
    locale-gen >> "$APT_LOG" 2>&1 || true
    update-locale LANG=zh_CN.UTF-8 2>/dev/null || true
    
    log_info "中文 locale 配置完成"
}




# ─────────────────────────────────────────────────────────────────────────────
# sysctl 基础配置 (通用)
# ─────────────────────────────────────────────────────────────────────────────
configure_sysctl_base() {
    local sysctl_file="/etc/sysctl.d/99-openclaw.conf"
    backup_file "$sysctl_file"
    
    cat > "$sysctl_file" <<'EOF'
# OpenClaw sysctl 配置

# 网络缓冲区
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.netdev_max_backlog = 65535
net.core.somaxconn = 65535

# TCP
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 131072 16777216
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_max_syn_backlog = 65535

# BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 文件描述符
fs.file-max = 1048576
fs.nr_open = 1048576

# 内存
vm.swappiness = 20
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.min_free_kbytes = 32768
vm.overcommit_memory = 1

# 连接追踪
net.netfilter.nf_conntrack_max = 131072
net.netfilter.nf_conntrack_tcp_timeout_established = 3600

# 安全
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 1
EOF
    
    sysctl -p "$sysctl_file" 2>/dev/null || true
    log_info "sysctl 基础配置完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# 系统限制
# ─────────────────────────────────────────────────────────────────────────────
configure_limits() {
    log_step "配置系统限制..."
    
    local limits_file="/etc/security/limits.conf"
    backup_file "$limits_file"
    
    cat >> "$limits_file" <<'EOF'

# OpenClaw 限制
* soft nofile 524288
* hard nofile 524288
* soft nproc 65535
* hard nproc 65535
root soft nofile 524288
root hard nofile 524288
EOF
    
    # inotify
    [[ -f /proc/sys/fs/inotify/max_user_watches ]] && echo 1048576 > /proc/sys/fs/inotify/max_user_watches
    [[ -f /proc/sys/fs/inotify/max_user_instances ]] && echo 8192 > /proc/sys/fs/inotify/max_user_instances
    
    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-inotify.conf <<'EOF'
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 8192
EOF
    
    log_info "系统限制配置完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# 安装 Node.js
# ─────────────────────────────────────────────────────────────────────────────
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
    
    curl --max-time 60 -fsSL "https://deb.nodesource.com/setup_${NODEJS_VERSION}.x" | bash - >> "$APT_LOG" 2>&1 || {
        log_warn "NodeSource 安装失败，使用系统包"
        apt-get install -y nodejs npm >> "$APT_LOG" 2>&1 || true
        return 0
    }
    
    apt-get install -y nodejs >> "$APT_LOG" 2>&1
    
    if command -v node &>/dev/null; then
        log_info "Node.js $(node --version) 安装成功"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 安装 Docker
# ─────────────────────────────────────────────────────────────────────────────
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
        log_warn "Docker 安装失败，使用系统包"
        apt-get install -y docker.io docker-compose >> "$APT_LOG" 2>&1 || true
    }
    
    systemctl enable docker 2>/dev/null || true
    systemctl start docker 2>/dev/null || true
    
    # Docker 配置
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'EOF'
{
    "storage-driver": "overlay2",
    "log-driver": "json-file",
    "log-opts": {"max-size": "100m", "max-file": "5"},
    "live-restore": true
}
EOF
    
    systemctl restart docker 2>/dev/null || true
    
    if command -v docker &>/dev/null; then
        log_info "Docker $(docker --version) 安装成功"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 安装 OpenClaw
# ─────────────────────────────────────────────────────────────────────────────
install_openclaw() {
    log_step "安装 OpenClaw..."
    
    # 创建用户
    if ! id -u "$OPENCLAW_USER" &>/dev/null; then
        useradd -r -m -s /bin/bash -c "OpenClaw Service Account" "$OPENCLAW_USER" 2>/dev/null || true
    fi
    
    # 根据安装方式安装
    if [[ "${INSTALL_METHOD:-}" == "docker" ]]; then
        # 容器安装 (Docker)
        log_info "使用 Docker 容器安装 OpenClaw..."
        
        # 确保 Docker 已安装
        if ! command -v docker &>/dev/null; then
            log_info "安装 Docker..."
            install_docker
        fi
        
        # 创建 OpenClaw 数据目录
        mkdir -p "$OPENCLAW_DATA_DIR"
        chown -R "$OPENCLAW_USER:$OPENCLAW_USER" "$OPENCLAW_DATA_DIR" 2>/dev/null || true
        
        # 拉取镜像
        log_info "拉取 OpenClaw 镜像..."
        docker pull openclaw/openclaw:latest >> "$APT_LOG" 2>&1 || {
            log_warn "镜像拉取失败，尝试备用方案..."
            docker pull ghcr.io/openclaw/openclaw:latest >> "$APT_LOG" 2>&1 || {
                log_error "Docker 镜像拉取失败"
                return 1
            }
        }
        
        log_info "OpenClaw 容器安装完成"
    else
        # 全局安装 (npm)
        log_info "使用全局安装 OpenClaw (npm install -g)..."
        
        if ! command -v openclaw &>/dev/null; then
            npm install -g openclaw --registry https://registry.npmmirror.com >> "$APT_LOG" 2>&1 || {
                npm install -g openclaw >> "$APT_LOG" 2>&1 || {
                    log_error "OpenClaw 安装失败"
                    return 1
                }
            }
        fi
        
        # 创建目录
        mkdir -p "$OPENCLAW_DATA_DIR"
        chown -R "$OPENCLAW_USER:$OPENCLAW_USER" "$OPENCLAW_DATA_DIR" 2>/dev/null || true
        
        log_info "OpenClaw 全局安装完成"
    fi
}



# ─────────────────────────────────────────────────────────────────────────────
# 创建 systemd 服务
# ─────────────────────────────────────────────────────────────────────────────
create_systemd_service() {
    log_step "创建 systemd 服务..."
    
    # 根据平台设置 MemoryMax
    local memory_max=""
    case "$PLATFORM_NAME" in
        *"R4S"*)
            memory_max="MemoryMax=2G"
            ;;
        *"T6"*|"NanoPi T6"*)
            memory_max="MemoryMax=4G"
            ;;
        *"N5105"*|"N5095"*|"N5105"*)
            memory_max="MemoryMax=2G"
            ;;
        *"Oracle"*|"ARM"*)
            memory_max="MemoryMax=8G"
            ;;
        *)
            memory_max="# MemoryMax=2G  # 自动检测内存"
            ;;
    esac
    
    if [[ "${INSTALL_METHOD:-}" == "docker" ]]; then
        # Docker 容器模式
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

# Docker 容器运行 OpenClaw
ExecStart=/usr/bin/docker run --rm \
    --name openclaw-gateway \
    --network host \
    -v ${OPENCLAW_DATA_DIR}:/root/.openclaw \
    -e OPENCLAW_DATA_DIR=/root/.openclaw \
    -e NODE_ENV=production \
    openclaw/openclaw:latest gateway --port ${OPENCLAW_PORT}
ExecStop=/usr/bin/docker stop openclaw-gateway 2>/dev/null || true

${memory_max}

[Install]
WantedBy=default.target
EOF
    else
        # 全局安装模式
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
ExecStart=/usr/local/bin/openclaw gateway --port ${OPENCLAW_PORT}
ExecStop=/bin/kill -SIGTERM \$MAINPID
Restart=on-failure
RestartSec=10
TimeoutStopSec=30
LimitNOFILE=524288
${memory_max}

[Install]
WantedBy=default.target
EOF
    fi
    
    systemctl --user daemon-reload
    systemctl --user enable openclaw-gateway 2>/dev/null || true
    log_info "systemd 服务创建完成"
    
    # 提示用户启动服务
    log_step "提示: 运行以下命令启动服务:"
    echo "  systemctl --user start openclaw-gateway"
    echo "  systemctl --user enable openclaw-gateway  # 开机自启"
}



# ─────────────────────────────────────────────────────────────────────────────
# I/O 调度优化
# ─────────────────────────────────────────────────────────────────────────────
optimize_io_scheduler() {
    log_step "优化 I/O 调度..."
    
    local root_disk
    root_disk=$(df / 2>/dev/null | awk 'NR==2 {print $1}')
    
    local is_ssd=false
    if [[ -b "$root_disk" ]]; then
        if cat /sys/block/*/queue/rotational 2>/dev/null | grep -q "0"; then
            is_ssd=true
        fi
    fi
    
    if [[ "$is_ssd" == "true" ]]; then
        for dev in /sys/block/*/queue/scheduler; do
            [[ -f "$dev" ]] && echo "none" > "$dev" 2>/dev/null || true
        done
        log_info "SSD 检测到，使用 none 调度器"
    else
        for dev in /sys/block/*/queue/scheduler; do
            [[ -f "$dev" ]] && echo "mq-deadline" > "$dev" 2>/dev/null || true
        done
        log_info "HDD 检测到，使用 mq-deadline 调度器"
    fi
    
    for dev in /sys/block/*/queue/read_ahead_kb; do
        [[ -f "$dev" ]] && echo 4096 > "$dev" 2>/dev/null || true
    done
}


# ─────────────────────────────────────────────────────────────────────────────
# 平台信息
# ─────────────────────────────────────────────────────────────────────────────
readonly PLATFORM_NAME="NanoPi R4S"
readonly PLATFORM_DESC="RK3399 ARM64, 4GB RAM, 双千兆网口"

# ─────────────────────────────────────────────────────────────────────────────
# 平台特定变量
# ─────────────────────────────────────────────────────────────────────────────
ZRAM_SIZE=1024      # R4S 只有 4GB，启用 1GB ZRAM
ZRAM_ALGO="lz4"    # RK3399 lz4 性能最佳
SWAPPINESS=20
TCP_BUF_MAX=16777216  # 16MB TCP 缓冲
TCP_TW_BUCKETS=65536
CT_MAX=1048576
INOTIFY_WATCHES=524288  # R4S 内存有限，减少 inotify

# ─────────────────────────────────────────────────────────────────────────────
# 平台检测
# ─────────────────────────────────────────────────────────────────────────────
detect_nanopi_r4s() {
    log_step "检测 NanoPi R4S..."
    
    # 检测方法1: /proc/device-tree/model
    if [[ -f /proc/device-tree/model ]]; then
        local model
        model=$(cat /proc/device-tree/model 2>/dev/null || echo "")
        if echo "$model" | grep -qi "R4S"; then
            log_info "检测到: $model"
            return 0
        fi
    fi
    
    # 检测方法2: CPU 信息
    if grep -qi "rk3399" /proc/cpuinfo 2>/dev/null; then
        log_info "检测到 RK3399 平台 (可能是 R4S)"
        return 0
    fi
    
    # 检测方法3: 架构
    if [[ "$(uname -m)" != "aarch64" ]]; then
        log_error "NanoPi R4S 需要 ARM64 架构，当前: $(uname -m)"
        return 1
    fi
    
    log_warn "未明确检测到 NanoPi R4S，但架构匹配"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 内存优化 (R4S 专用)
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# TF 卡优化 (NanoPi R4S 专用)
# 目的: 减少 TF 卡写入，延长寿命
# 安全优化: 不破坏数据完整性
# ─────────────────────────────────────────────────────────────────────────────

configure_tf_card_optimize() {
    log_step "配置 TF 卡优化 (减少写入)..."
    
    # 1. 配置 journald 限制 (安全)
    log_info "配置 journald 日志限制..."
    mkdir -p /etc/systemd
    cat > /etc/systemd/journald.conf <<'EOFJ'
[Journal]
SystemMaxUse=50M
SystemMaxFileSize=20M
MaxRetentionSec=1day
ForwardToSyslog=no
EOFJ
    systemctl restart systemd-journald 2>/dev/null || true
    
    # 2. 安装 log2ram (日志写入 RAM)
    log_info "安装 log2ram..."
    if ! command -v log2ram &>/dev/null; then
        curl -fsSL https://azlux.fr/repo.gpg | gpg --dearmor -o /usr/share/keyrings/azlux-archive-keyring.gpg 2>/dev/null || true
        
        local codename
        codename=$(grep -oP '(?<=^VERSION_CODENAME=).+' /etc/os-release 2>/dev/null | tr -d '"' || echo "bookworm")
        
        echo "deb [signed-by=/usr/share/keyrings/azlux-archive-keyring.gpg] http://packages.azlux.fr/debian/ ${codename} main" > /etc/apt/sources.list.d/azlux.list
        
        apt-get update -qq >> "$APT_LOG" 2>&1 || true
        apt-get install -y log2ram >> "$APT_LOG" 2>&1 || {
            log_warn "log2ram 安装失败，跳过"
        }
    fi
    
    # 3. 配置 log2ram (R4S 4GB RAM, 分配 40MB)
    if [[ -f /etc/log2ram.conf ]]; then
        log_info "配置 log2ram..."
        sed -i 's/^SIZE=.*/SIZE=40M/' /etc/log2ram.conf
        sed -i 's/^USE_RSYNC=.*/USE_RSYNC=true/' /etc/log2ram.conf
    fi
    
    # 4. 使用 tmpfs 挂载 /tmp (安全)
    log_info "配置 /tmp 到 tmpfs..."
    if ! grep -q "tmpfs /tmp" /etc/fstab 2>/dev/null; then
        echo "tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,mode=1777 0 0" >> /etc/fstab
    fi
    
    # 5. 禁用 swap (TF 卡不适合 swap)
    log_info "禁用 swap..."
    for sw in /swapfile /swap.img; do
        swapon --show 2>/dev/null | grep -q "$sw" && swapoff "$sw" 2>/dev/null || true
        [[ -f "$sw" ]] && rm -f "$sw"
    done
    sed -i '/swapfile/d; /swap.img/d' /etc/fstab 2>/dev/null || true
    [[ -f /sys/module/zswap/parameters/enabled ]] && echo N > /sys/module/zswap/parameters/enabled 2>/dev/null || true
    
    # 6. 配置 logrotate (安全轮换)
    log_info "配置 logrotate..."
    mkdir -p /etc/logrotate.d
    cat > /etc/logrotate.d/openclaw <<'EOFLOG'
/var/log/openclaw/*.log {
    daily
    rotate 2
    size 2M
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
}
EOFLOG
    
    # 7. 安全 sysctl 优化
    log_info "配置 sysctl 减少写入..."
    cat >> /etc/sysctl.d/99-tf-optimize.conf <<'EOFSYS'
# TF 卡安全优化
vm.dirty_writeback_centisecs = 60000
vm.dirty_expire_centisecs = 60000
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
EOFSYS
    sysctl -p /etc/sysctl.d/99-tf-optimize.conf 2>/dev/null || true
    
    log_info "TF 卡优化完成"
}

optimize_memory_r4s() {
    log_step "配置内存优化 (R4S 4GB)..."
    
    # 清理旧 swap
    for sw in /swapfile /swap.img; do
        swapon --show 2>/dev/null | grep -q "$sw" && swapoff "$sw" 2>/dev/null || true
        [[ -f "$sw" ]] && rm -f "$sw"
    done
    sed -i '/swapfile/d; /swap.img/d' /etc/fstab 2>/dev/null || true
    
    # 4GB 内存: 启用 ZRAM
    if [[ $SYS_MEM_MB -ge 4096 ]]; then
        log_info "内存 >= 4GB，启用 ZRAM ${ZRAM_SIZE}MB"
    else
        ZRAM_SIZE=512
        log_info "内存 < 4GB，ZRAM 调整为 ${ZRAM_SIZE}MB"
    fi
    
    # 禁用 zswap
    [[ -f /sys/module/zswap/parameters/enabled ]] && echo N > /sys/module/zswap/parameters/enabled 2>/dev/null || true
    
    # 检查 ZRAM 可用性
    if modinfo zram >/dev/null 2>&1 || [[ -d /sys/block/zram0 ]]; then
        apt-get remove --purge -y zram-config >> "$APT_LOG" 2>&1 || true
        apt-get install -y --no-install-recommends zram-tools >> "$APT_LOG" 2>&1 || true
        
        cat > /etc/default/zramswap <<EOF
ALGO=${ZRAM_ALGO}
SIZE=${ZRAM_SIZE}
PRIORITY=100
EOF
        
        systemctl enable zramswap 2>/dev/null || true
        systemctl restart zramswap 2>/dev/null || true
        
        sleep 2
        if lsblk | grep -q zram; then
            log_info "ZRAM ${ZRAM_SIZE}MB (${ZRAM_ALGO}) 已启用"
        fi
    else
        log_warn "ZRAM 不可用"
    fi
    
    # 小内存物理 Swap (如果 < 2GB)
    if [[ $SYS_MEM_MB -lt 2048 && $SYS_DISK_AVAIL_GB -gt 2 ]]; then
        local swap_mb=512
        [[ $SYS_MEM_MB -le 512 ]] && swap_mb=512 || swap_mb=1024
        
        fallocate -l "${swap_mb}M" /swapfile 2>/dev/null || \
            dd if=/dev/zero of=/swapfile bs=1M count="$swap_mb" status=none 2>/dev/null || true
        
        chmod 600 /swapfile
        if mkswap /swapfile >/dev/null 2>&1 && swapon -p 10 /swapfile 2>/dev/null; then
            echo '/swapfile none swap sw,pri=10 0 0' >> /etc/fstab
            log_info "物理 Swap ${swap_mb}MB 已启用"
        fi
    fi
    
    sysctl -w vm.swappiness=$SWAPPINESS 2>/dev/null || true
    log_info "内存优化完成 (ZRAM: ${ZRAM_SIZE}MB, swappiness: $SWAPPINESS)"
}

# ─────────────────────────────────────────────────────────────────────────────
# sysctl 优化 (R4S 专用)
# ─────────────────────────────────────────────────────────────────────────────
configure_sysctl_r4s() {
    log_step "配置 sysctl (R4S 优化)..."
    
    local sysctl_file="/etc/sysctl.d/99-openclaw.conf"
    backup_file "$sysctl_file"
    
    cat > "$sysctl_file" <<EOF
# NanoPi R4S OpenClaw 优化配置
# RK3399 ARM64, 4GB RAM, 双网口

# 网络缓冲区 (R4S 优化 - 16MB)
net.core.rmem_max = ${TCP_BUF_MAX}
net.core.wmem_max = ${TCP_BUF_MAX}
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.netdev_max_backlog = 32768
net.core.somaxconn = 32768

# TCP (R4S 优化)
net.ipv4.tcp_rmem = 4096 131072 ${TCP_BUF_MAX}
net.ipv4.tcp_wmem = 4096 131072 ${TCP_BUF_MAX}
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_max_syn_backlog = 32768
net.ipv4.tcp_max_tw_buckets = ${TCP_TW_BUCKETS}

# BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 文件描述符
fs.file-max = 524288
fs.nr_open = 524288

# 内存 (R4S 内存有限，优化)
vm.swappiness = ${SWAPPINESS}
vm.dirty_ratio = 10
vm.dirty_background_ratio = 3
vm.min_free_kbytes = 16384
vm.overcommit_memory = 1
vm.zone_reclaim_mode = 0

# 连接追踪
net.netfilter.nf_conntrack_max = ${CT_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 1800
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 10

# IPv6
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0

# 安全
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 1
EOF
    
    sysctl -p "$sysctl_file" 2>/dev/null || true
    log_info "sysctl R4S 优化完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# 网卡优化 (R4S 双网口)
# ─────────────────────────────────────────────────────────────────────────────
optimize_network_r4s() {
    log_step "优化网卡 (R4S 双网口)..."
    
    # R4S 通常有 eth0 和 eth1
    for iface in /sys/class/net/eth*; do
        [[ -d "$iface" ]] || continue
        local name
        name=$(basename "$iface")
        
        # 启用 TSO/GSO/GRO
        ethtool -K "$name" tso on 2>/dev/null || true
        ethtool -K "$name" gso on 2>/dev/null || true
        ethtool -K "$name" gro on 2>/dev/null || true
        
        # 启用自适应 Rx/Tx
        ethtool -A "$name" rx on 2>/dev/null || true
        ethtool -A "$name" tx on 2>/dev/null || true
        
        local speed
        speed=$(ethtool "$name" 2>/dev/null | grep "Speed:" | awk '{print $2}' || echo "unknown")
        log_info "网卡 $name 优化完成 (Speed: $speed)"
    done
    
    # RPS (多核优化)
    if [[ $SYS_CPU_CORES -gt 1 ]]; then
        for rps in /sys/class/net/eth*/queues/rx-*/rps_cpus; do
            [[ -f "$rps" ]] || continue
            local mask
            mask=$(printf '%x' $(( (1 << SYS_CPU_CORES) - 1 )))
            printf "%s" "$mask" > "$rps" 2>/dev/null || true
        done
        log_info "RPS 启用 (CPU mask: 0x$mask)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# ARM 特定优化
# ─────────────────────────────────────────────────────────────────────────────
optimize_arm() {
    log_step "ARM 特定优化..."
    
    # 启用 armhf 32位支持 (某些场景需要)
    dpkg --add-architecture armhf 2>/dev/null || true
    
    # ARM 特定的性能调整
    # CPU 频率调节
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [[ -f "$cpu" ]] && echo "performance" > "$cpu" 2>/dev/null || true
    done
    
    log_info "ARM 特定优化完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# 主函数
# ─────────────────────────────────────────────────────────────────────────────
main() {
    clear
    echo "═══════════════════════════════════════════════════════════════════════"
    echo -e "${GREEN}  NanoPi R4S 专用优化安装脚本 v${SCRIPT_VERSION}${NC}"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo -e "${BLUE}平台: ${PLATFORM_DESC}${NC}"
    echo ""
    
    init_script
    detect_system
    check_network
    
    # 平台检测
    detect_nanopi_r4s || exit 1
    
    echo ""
    echo -e "${BLUE}优化计划:${NC}"
    echo "  平台:      ${PLATFORM_DESC}"
    echo "  系统:      ${SYS_OS_ID} ${SYS_OS_VERSION}"
    echo "  架构:      ${SYS_ARCH} | 内存: ${SYS_MEM_MB}MB | CPU: ${SYS_CPU_CORES}核"
    echo "  ZRAM:      ${ZRAM_SIZE}MB (${ZRAM_ALGO})"
    # 安装方式选择 (交互式)
    if [[ -t 0 ]]; then
        echo ""
        echo -e "${YELLOW}请选择 OpenClaw 安装方式:${NC}"
        echo "  1) Docker 容器安装 (推荐，默认)"
        echo "  2) 全局安装 (npm install -g)"
        echo -n "选择 (1/2，默认 1): "
        read -r install_choice
        case "$install_choice" in
            2)
                export INSTALL_METHOD="npm"
                INSTALL_DOCKER="false"
                INSTALL_NODEJS="true"
                install_method_display="全局安装 (npm)"
                ;;
            *)
                export INSTALL_METHOD="docker"
                INSTALL_DOCKER="true"
                INSTALL_NODEJS="false"
                install_method_display="Docker 容器 (推荐)"
                ;;
        esac
    else
        export INSTALL_METHOD="${INSTALL_METHOD:-docker}"
        INSTALL_DOCKER="${INSTALL_DOCKER:-true}"
        INSTALL_NODEJS="${INSTALL_NODEJS:-false}"
        install_method_display="Docker 容器 (默认)"
    fi
    
    local docker_display="${INSTALL_DOCKER}"
    local nodejs_display="${INSTALL_NODEJS}"
    [[ "$docker_display" == "true" ]] && docker_display="是" || docker_display="跳过"
    [[ "$nodejs_display" == "true" ]] && nodejs_display="是" || nodejs_display="跳过"
    
    echo "  安装方式:  ${install_method_display}"
    echo "  Docker:    ${docker_display}"
    echo "  Node.js:  ${nodejs_display}"
    echo "  Docker:    ${INSTALL_DOCKER}"
    echo "  Node.js:  ${NODEJS_VERSION}"
    echo ""
    
    if [[ -t 0 ]]; then
        echo -n "继续执行？(y/n，默认 y): "
        read -r confirm
        [[ "$confirm" == "n" || "$confirm" == "N" ]] && exit 0
    fi
    
    echo ""
    log_step "开始优化..."
    echo ""
    
    # 执行顺序
    preflight_check
    configure_apt_sources
    clean_system
    configure_tf_card_optimize
    optimize_memory_r4s
    configure_sysctl_r4s
    configure_limits
    configure_dns
    configure_time_sync
    configure_timezone
    configure_locale
    optimize_io_scheduler
    optimize_arm
    optimize_network_r4s
    
    install_base_tools
    install_nodejs
    install_openclaw
    create_systemd_service
    run_doctor
    
    # 清理
    apt-get autoremove -y >> "$APT_LOG" 2>&1 || true
    apt-get autoclean >> "$APT_LOG" 2>&1 || true
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════"
    echo -e "${GREEN}  ✅ NanoPi R4S 优化完成！${NC}"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo ""
    echo -e "${CYAN}后续步骤:${NC}"
    echo "  1. sudo -u ${OPENCLAW_USER} -i openclaw onboard"
    echo "  2. systemctl start openclaw-gateway"
    echo "  3. openclaw status"
    echo ""
    echo -e "${YELLOW}日志: ${APT_LOG}${NC}"
    echo ""
}

trap 'log_error "脚本异常退出 (行: ${LINENO})"; exit 1' ERR
trap 'log_warn "被中断"; exit 130' INT TERM


# OpenClaw 诊断
run_doctor() {
    log_step "运行 OpenClaw 诊断..."
    echo ""
    echo "=== OpenClaw 诊断报告 ==="
    echo ""
    echo "1. Node.js 版本:"
    node --version
    echo ""
    echo "2. OpenClaw 版本:"
    openclaw --version || echo "  未安装"
    echo ""
    echo "3. Gateway 状态:"
    systemctl is-active openclaw-gateway || echo "  未运行"
    echo ""
    echo "4. Gateway 日志 (最后10行):"
    journalctl -u openclaw-gateway -n 10 --no-pager 2>/dev/null || echo "  无日志"
    echo ""
    echo "5. 监听端口:"
    ss -tlnp | grep 18789 || netstat -tlnp | grep 18789 || echo "  端口 18789 未监听"
    echo ""
    echo "6. 配置检查:"
    openclaw doctor 2>/dev/null || echo "  doctor 命令不可用"
    echo ""
    echo "=== 诊断完成 ==="
}
main "$@"

