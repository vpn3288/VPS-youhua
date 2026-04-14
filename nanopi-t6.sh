#!/usr/bin/env bash
# =============================================================================
# NanoPC T6/T6S (FriendlyELEC) 专用优化安装脚本 v3.1
# 硬件: RK3588S ARM64, 8GB RAM (T6) / 4GB RAM (T6S), eMMC, 1×GbE + 2×2.5GbE
# 特点: 性能更强, 8GB大内存, 适合重度使用
# =============================================================================
#
# 一键运行: bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/nanopi-t6.sh)
#

set -euo pipefail
IFS=$'\n\t'


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
readonly SCRIPT_VERSION="3.1"
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
NODEJS_VERSION="${NODEJS_VERSION:-22}"
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
        [[ $SYS_DISK_AVAIL_GB -lt 10 ]] && { log_warn "磁盘可用空间 ${SYS_DISK_AVAIL_GB}GB < 10GB，建议清理"; }
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
DNS=1.1.1.1 8.8.8.8 223.5.5.5
FallbackDNS=1.0.0.1 8.8.4.4
DNSSEC=no
DNSOverTLS=no
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


# =============================================================================
# journald 优化 (eMMC 存储保护)
# =============================================================================
configure_journald() {
    log_step "配置 journald..."

    mkdir -p /etc/systemd
    cat > /etc/systemd/journald.conf <<'EOF'
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
RuntimeMaxUse=100M
MaxRetentionSec=7day
Compress=yes
Storage=persistent
ForwardToSyslog=no
MaxLevelStore=notice
EOF

    systemctl restart systemd-journald 2>/dev/null || true
    log_info "journald 配置完成"
}




# 配置中文 locale
configure_locale() {
    log_step "配置 locale..."

    # 立即导出：解决 bash <(curl) 非login shell 的 locale 丢失问题
    export LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 LANGUAGE=zh_CN.UTF-8

    # 检查是否已有中文 locale
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

    # 同步到 /etc/default/locale（update-locale 的实际写入位置）
    echo "LANG=zh_CN.UTF-8" > /etc/default/locale
    echo "LC_ALL=zh_CN.UTF-8" >> /etc/default/locale

    log_info "中文 locale 配置完成"
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
root soft nofile 1048576
root hard nofile 1048576
EOF

    # inotify
    [[ -f /proc/sys/fs/inotify/max_user_watches ]] && echo 1048576 > /proc/sys/fs/inotify/max_user_watches
    [[ -f /proc/sys/fs/inotify/max_user_instances ]] && echo 8192 > /proc/sys/fs/inotify/max_user_instances

    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-inotify.conf <<'EOF'
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 8192
EOF

    # systemd 系统级限制
    mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
    cat > /etc/systemd/system.conf.d/99-ai-limits.conf <<'EOFSYSD'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=131072
DefaultLimitMEMLOCK=infinity
EOFSYSD
    cat > /etc/systemd/user.conf.d/99-ai-limits.conf <<'EOFUSRD'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=65535
EOFUSRD

    # Docker systemd limit
    mkdir -p /etc/systemd/system/docker.service.d
    cat > /etc/systemd/system/docker.service.d/override.conf <<'EOFDOCKERLIM'
[Service]
LimitNOFILE=1048576
LimitNPROC=65535
LimitMEMLOCK=infinity
EOFDOCKERLIM

    systemctl daemon-reload || log_warn "daemon-reload 失败，服务可能使用旧配置"

    log_info "系统限制配置完成"
}


# ─────────────────────────────────────────────────────────────────────────────
# SSH 安全加固
# ─────────────────────────────────────────────────────────────────────────────
optimize_ssh_t6() {
    log_step "SSH 安全加固 (T6)..."

    local sshd_config="/etc/ssh/sshd_config"
    [[ ! -f "$sshd_config" ]] && { log_warn "sshd_config 不存在，跳过"; return 0; }

    backup_file "$sshd_config"

    # 只做必要的安全配置，不强制关闭密码登录
    sed -i 's/^PermitEmptyPasswords.*/PermitEmptyPasswords no/' "$sshd_config" 2>/dev/null || true
    grep -q "^ClientAliveInterval" "$sshd_config" 2>/dev/null || echo "ClientAliveInterval 3600" >> "$sshd_config"
    sed -i 's/^ClientAliveInterval.*/ClientAliveInterval 3600/' "$sshd_config" 2>/dev/null || true
    sed -i 's/^ClientAliveCountMax.*/ClientAliveCountMax 3/' "$sshd_config" 2>/dev/null || true
    sed -i 's/^X11Forwarding.*/X11Forwarding no/' "$sshd_config" 2>/dev/null || true
    # 保留系统原有 PermitRootLogin 和 PubkeyAuthentication 设置
    systemctl reload sshd 2>/dev/null || true
    log_info "SSH 已配置 (ClientAliveInterval=3600, 空密码已禁止)"

    # 显示上次登录信息（发现异常登录时能立刻看到）
    echo -e "  \${CYAN}上次登录记录:\${RESET}"
    last -n 3 2>/dev/null | grep -v "^$" | head -3 | sed "s/^/    /" || true
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
    
    local docker_install_script=$(mktemp)
    curl --max-time 120 -fsSL https://get.docker.com -o "$docker_install_script" || {
        log_warn "Docker 安装脚本下载失败，使用系统包"
        rm -f "$docker_install_script"
        apt-get install -y docker.io docker-compose >> "$APT_LOG" 2>&1 || true
        systemctl enable docker 2>/dev/null || true
        systemctl start docker 2>/dev/null || true
        local docker_ready=false
        for i in {1..30}; do
            if docker info >/dev/null 2>&1; then docker_ready=true; break; fi
            sleep 1
        done
        [[ "$docker_ready" != "true" ]] && log_warn "Docker daemon 未就绪"
        return 0
    }
    bash "$docker_install_script" --mirror Aliyun >> "$APT_LOG" 2>&1 || {
        log_warn "Docker 安装脚本执行失败，使用系统包"
        rm -f "$docker_install_script"
        apt-get install -y docker.io docker-compose >> "$APT_LOG" 2>&1 || true
    }
    rm -f "$docker_install_script"
    systemctl enable docker 2>/dev/null || true
    systemctl start docker 2>/dev/null || true
    local docker_ready=false
    for i in {1..30}; do
        if docker info >/dev/null 2>&1; then docker_ready=true; break; fi
        sleep 1
    done
    [[ "$docker_ready" != "true" ]] && log_warn "Docker daemon 未就绪"

    # Docker 配置
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'EOF'
{
    "storage-driver": "overlay2",
    "log-driver": "json-file",
    "log-opts": {"max-size": "50m", "max-file": "3"},
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
    
    if ! id -u "$OPENCLAW_USER" &>/dev/null; then
        useradd -r -m -s /bin/bash -c "OpenClaw Service Account" "$OPENCLAW_USER" 2>/dev/null || true
    fi
    
    if [[ "${INSTALL_METHOD:-}" == "docker" ]]; then
        log_info "使用 Docker 容器安装 OpenClaw..."
        if ! command -v docker &>/dev/null; then
            log_info "安装 Docker..."
            install_docker
        fi
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


# ─────────────────────────────────────────────────────────────────────────────
# 创建 systemd 服务
# ─────────────────────────────────────────────────────────────────────────────

create_systemd_service() {
    log_step "创建 systemd 服务..."
    local memory_max="MemoryMax=8G"
    
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

    # eMMC 批量写优化：减少 ext4 元数据同步次数
    configure_ext4_commit
}


# ─────────────────────────────────────────────────────────────────────────────
# ARM 特定优化
# ─────────────────────────────────────────────────────────────────────────────
optimize_arm() {
    log_step "ARM 特定优化..."
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [[ -f "$cpu" ]] && echo "performance" > "$cpu" 2>/dev/null || true
    done
    log_info "ARM 特定优化完成"
}

configure_ext4_commit() {
    local fstab_file="/etc/fstab"
    [[ ! -f "$fstab_file" ]] && { log_warn "/etc/fstab 不存在"; return 1; }
    backup_file "$fstab_file"

    local line has_ext4=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^[^#].*[[:space:]]ext4[[:space:]] ]]; then
            has_ext4=true
            if [[ "$line" =~ noatime ]]; then
                if [[ ! "$line" =~ commit= ]]; then
                    line=$(echo "$line" | sed 's/\(ext4[^,]*\)/\1,commit=600/')
                fi
            else
                line=$(echo "$line" | sed 's/\(ext4[^,]*\)/\1,noatime,commit=600/')
            fi
        fi
        echo "$line"
    done < "$fstab_file" > "${fstab_file}.new"
    mv "${fstab_file}.new" "$fstab_file"
    log_info "ext4 挂载参数已优化 (commit=600)"
}

readonly PLATFORM_NAME="NanoPi T6/T6S"
readonly PLATFORM_DESC="RK3588 ARM64, 8GB RAM"

# T6 优化参数 - 8GB 内存更宽裕
ZRAM_SIZE=0        # 8GB 足够，不需要 ZRAM
SWAPPINESS=10       # 低 swappiness，内存充足
TCP_BUF_MAX=33554432  # 32MB TCP 缓冲
TCP_TW_BUCKETS=65536
CT_MAX=131072
CT_HASH_SIZE=65536  # conntrack hash size (与 CT_MAX 成比例)
INOTIFY_WATCHES=1048576  # 完整 inotify

detect_nanopi_t6() {
    log_step "检测 NanoPi T6/T6S..."
    
    if [[ -f /proc/device-tree/model ]]; then
        local model
        model=$(cat /proc/device-tree/model 2>/dev/null || echo "")
        if echo "$model" | grep -qi "T6"; then
            log_info "检测到: $model"
            # 自动检测真实内存（不要硬编码，让 line 81 的检测结果生效）
            # T6/T6S 统一走系统自动检测（detect_system 已正确获取）
            PLATFORM_DESC="RK3588S ARM64, 自动检测"
            log_info "检测到 RK3588 平台"
            return 0
        fi
    fi
    
    return 0
}

optimize_memory_t6() {
    log_step "配置内存优化 (T6 ${SYS_MEM_MB}MB)..."

    # 清理物理swap文件（eMMC 不怕，但物理 swap 文件会占用 eMMC 空间）
    for sw in /swapfile /swap.img; do
        swapon --show 2>/dev/null | grep -q "$sw" && swapoff "$sw" 2>/dev/null || true
        [[ -f "$sw" ]] && rm -f "$sw"
    done
    sed -i '/swapfile/d; /swap.img/d' /etc/fstab 2>/dev/null || true

    # 保留 zswap：16GB RAM 充足，zswap 压缩 swap 很有用；eMMC 不怕写，无需禁用
    log_info "zswap 保持原状（16GB RAM 充足，eMMC 不怕写）"

    sysctl -w vm.swappiness=$SWAPPINESS 2>/dev/null || true
    log_info "内存优化完成 (eMMC存储, 保留zswap)"
}

configure_sysctl_t6() {
    log_step "配置 sysctl (T6 优化)..."
    
    local sysctl_file="/etc/sysctl.d/99-openclaw.conf"
    backup_file "$sysctl_file"
    
    cat > "$sysctl_file" <<EOF
# NanoPC T6/T6S 环境优化配置
# RK3588S ARM64, ${SYS_MEM_MB}MB RAM, 64GB eMMC

# ===== TCP 核心优化 =====
net.ipv4.tcp_rmem = 4096 131072 ${TCP_BUF_MAX}
net.ipv4.tcp_wmem = 4096 131072 ${TCP_BUF_MAX}
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = ${TCP_TW_BUCKETS}
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_early_retrans = 3
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1

# ===== 网络队列与缓冲 =====
net.core.rmem_max = ${TCP_BUF_MAX}
net.core.wmem_max = ${TCP_BUF_MAX}
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.netdev_max_backlog = 65535
net.core.somaxconn = 65535
net.ipv4.ip_local_port_range = 10240 65535

# ===== BBR 拥塞控制 =====
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ===== 安全加固 =====
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1

# ===== IPv6 =====
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.ip_forward = 1

# ===== 连接追踪 conntrack =====
net.netfilter.nf_conntrack_max = ${CT_MAX}
net.netfilter.nf_conntrack_hashsize = ${CT_HASH_SIZE}
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 10
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 5
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 10

# ===== 内存管理 =====
vm.swappiness = ${SWAPPINESS}
vm.overcommit_memory = 1
vm.vfs_cache_pressure = 50

# eMMC 保护：dirty_writeback 调优（减少随机写入，延长 eMMC 寿命）
vm.dirty_ratio = 20
vm.dirty_background_ratio = 10
vm.dirty_writeback_centisecs = 6000
vm.dirty_expire_centisecs = 60000

# 内存充足，min_free_kbytes 适当调高
vm.min_free_kbytes = 32768

# ===== inotify =====
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 8192
EOF
    
    sysctl -p "$sysctl_file" 2>/dev/null || true
    log_info "sysctl T6 优化完成"
}

optimize_network_t6() {
    log_step "优化网卡 (T6)..."
    
    for iface in /sys/class/net/eth*; do
        [[ -d "$iface" ]] || continue
        local name
        name=$(basename "$iface")
        
        ethtool -K "$name" tso on 2>/dev/null || true
        ethtool -K "$name" gso on 2>/dev/null || true
        ethtool -K "$name" gro on 2>/dev/null || true
        ethtool -A "$name" rx on 2>/dev/null || true
        ethtool -A "$name" tx on 2>/dev/null || true
        
        local speed
        speed=$(ethtool "$name" 2>/dev/null | grep "Speed:" | awk '{print $2}' || echo "unknown")
        log_info "网卡 $name 优化完成 (Speed: $speed)"
    done
    
    # RPS
    if [[ $SYS_CPU_CORES -gt 1 ]]; then
        for rps in /sys/class/net/eth*/queues/rx-*/rps_cpus; do
            [[ -f "$rps" ]] || continue
            local cores=$((SYS_CPU_CORES > 63 ? 63 : SYS_CPU_CORES))
            local mask; mask=$(printf '%x' $(( (1 << cores) - 1 )))
            printf "%s" "$mask" > "$rps" 2>/dev/null || true
        done
        log_info "RPS 启用 (CPU mask: 0x$mask)"
    fi
}

# OOM Killer 保护 - 防止 AIagent 进程被 oomkill
optimize_oom() {
    log_step "配置 OOM Killer 保护..."
    mkdir -p /etc/systemd/system/openclaw-gateway.service.d
    cat > /etc/systemd/system/openclaw-gateway.service.d/oom.conf <<'EOFOOM'
[Service]
OOMScoreAdjust=-200
EOFOOM
    log_info "OOM Killer 保护已配置"
}

# 日志轮转配置 - 自动切割 openclaw 日志，防止 eMMC 存储被日志撑满
configure_logrotate() {
    log_step "配置 logrotate..."
    mkdir -p /etc/logrotate.d
    cat > /etc/logrotate.d/openclaw <<'EOFLOGROTATE'
/var/log/openclaw/*.log /var/log/aiagent-cleanup.log {
    daily
    rotate 2
    size 2M
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

# 自动清理 - 定时清理日志/临时文件/旧镜像，减少 eMMC 写入
configure_cleanup_cron() {
    log_step "配置自动清理..."
    mkdir -p /usr/local/bin
    cat > /usr/local/bin/aiagent-cleanup.sh <<'EOTCLEANUP'
#!/bin/bash
# AIagent 清理脚本 - eMMC 保护版
docker image prune -af --filter "until=168h" 2>/dev/null || true
journalctl --vacuum-size=30M 2>/dev/null || true
journalctl --vacuum-time=3d 2>/dev/null || true
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

main() {
    clear
    echo "═══════════════════════════════════════════════════════════════════════"
    echo -e "${GREEN}  NanoPi T6/T6S 专用优化安装脚本 v${SCRIPT_VERSION}${NC}"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo -e "${BLUE}平台: ${PLATFORM_DESC}${NC}"
    echo ""
    
    init_script
    detect_system
    check_network
    detect_nanopi_t6 || exit 1
    
    echo ""
    echo -e "${BLUE}优化计划:${NC}"
    echo "  平台:      ${PLATFORM_DESC}"
    echo "  系统:      ${SYS_OS_ID} ${SYS_OS_VERSION}"
    echo "  架构:      ${SYS_ARCH} | 内存: ${SYS_MEM_MB}MB | CPU: ${SYS_CPU_CORES}核"
    echo "  ZRAM:      跳过 (内存充足)"
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
    echo ""
    
    if [[ -t 0 ]]; then
        echo -n "继续执行？(y/n，默认 y): "
        read -r confirm
        [[ "$confirm" == "n" || "$confirm" == "N" ]] && exit 0
    fi
    
    echo ""
    log_step "开始优化..."
    echo ""
    
    preflight_check
    configure_apt_sources
    clean_system
    configure_logrotate
    optimize_memory_t6
    configure_sysctl_t6
    configure_limits
    optimize_ssh_t6
    configure_dns
    configure_time_sync
    configure_journald
    configure_locale
    optimize_io_scheduler
    optimize_arm
    optimize_network_t6
    
    # OOM Killer 保护（重要：AIagent 进程被oomkill会导致会话中断）
    optimize_oom
    configure_cleanup_cron
    
    install_base_tools
    install_docker
    install_nodejs
    install_openclaw
    create_systemd_service
    run_doctor
    
    apt-get autoremove -y >> "$APT_LOG" 2>&1 || true
    apt-get autoclean >> "$APT_LOG" 2>&1 || true
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════"
    echo -e "${GREEN}  ✅ NanoPi T6/T6S v${SCRIPT_VERSION} 优化完成！${NC}"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo ""
    echo -e "${CYAN}后续步骤:${NC}"
    echo "  1. sudo -u ${OPENCLAW_USER} -i openclaw onboard"
    echo "  2. systemctl start openclaw-gateway"
    echo "  3. openclaw status"
    echo ""
}

trap 'log_error "脚本异常退出 (行: ${LINENO})"; exit 1' ERR
trap 'log_warn "被中断"; exit 130' INT TERM


# OpenClaw 诊断
run_doctor() {
    log_step "运行诊断..."
    echo ""
    echo "=== AIagent 环境诊断报告 (NanoPC T6) ==="
    echo ""
    echo "1. 系统信息:"
    echo "   平台: $PLATFORM_NAME"
    echo "   系统: $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)"
    echo "   内核: $(uname -r)"
    echo "   架构: $(uname -m)"
    echo "   CPU: $SYS_CPU_CORES 核"
    echo "   内存: ${SYS_MEM_MB}MB"
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
    ss -tlnp 2>/dev/null | grep -E "18789|18790" || netstat -tlnp 2>/dev/null | grep -E "18789|18790" || echo "   无"
    echo ""
    echo "6. 服务状态:"
    systemctl --user is-active openclaw-gateway 2>/dev/null && echo "   openclaw-gateway: active" || echo "   openclaw-gateway: inactive"
    systemctl is-active docker 2>/dev/null && echo "   docker: active" || echo "   docker: inactive"
    systemctl is-active chronyd 2>/dev/null && echo "   chronyd: active" || echo "   chronyd: inactive"
    echo ""
    echo "7. 磁盘:"
    df -h / | tail -1 | awk '{printf "   系统盘: %s 总, %s 已用, %s 可用 (%s)\n", $2, $3, $4, $5}'
    echo ""
    echo "=== 诊断完成 ==="
}
main "$@"

