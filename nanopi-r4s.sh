#!/usr/bin/env bash
# =============================================================================
# NanoPi R4S 专用优化安装脚本 v3.0
# 硬件: RK3399 ARM64, 4GB RAM, 双网口, TF卡
# 特点: TF卡保护为核心，安全/稳定/长期运行
# =============================================================================
#
# 一键运行: bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/nanopi-r4s.sh)
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
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_step()  { echo -e "${CYAN}[➜]${NC} $1"; }

readonly SCRIPT_VERSION="3.1"
readonly APT_LOG="/var/log/openclaw-install.log"
readonly LOCK_FILE="/var/lock/openclaw-install.lock"

SYS_MEM_MB=0; SYS_CPU_CORES=0; SYS_ARCH=""
SYS_KERNEL=""; SYS_OS_ID=""; SYS_OS_VERSION=""
SYS_DISK_TOTAL_GB=0; SYS_DISK_AVAIL_GB=0
SYS_NET_IF=""; SYS_ROOT_DISK=""; SYS_IS_TF_CARD=false

INSTALL_DOCKER="${INSTALL_DOCKER:-true}"
INSTALL_NODEJS="${INSTALL_NODEJS:-true}"
NODEJS_VERSION="${NODEJS_VERSION:-20}"
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
    SYS_OS_ID=$(grep -oP '(?<=^ID=).+' /etc/os-release 2>/dev/null | tr -d '"' || echo "unknown")
    SYS_OS_VERSION=$(grep -oP '(?<=^VERSION_ID=).+' /etc/os-release 2>/dev/null | tr -d '"' || echo "unknown")
    SYS_DISK_TOTAL_GB=$(df -BG / 2>/dev/null | awk 'NR==2 {print $2}' | tr -d 'G' || echo 0)
    SYS_DISK_AVAIL_GB=$(df -BG / 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G' || echo 0)
    SYS_NET_IF=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}' || true)
    [[ -z "$SYS_NET_IF" ]] && SYS_NET_IF=$(ip -6 route show default 2>/dev/null | awk '/default/{print $5; exit}' || true)
    detect_tf_card
    log_info "系统: ${SYS_OS_ID} ${SYS_OS_VERSION}"
    log_info "架构: ${SYS_ARCH} | 内存: ${SYS_MEM_MB}MB | CPU: ${SYS_CPU_CORES}核"
    [[ "$SYS_IS_TF_CARD" == "true" ]] && log_warn "检测到TF卡存储，实施TF卡保护"
}

detect_tf_card() {
    local root_dev
    root_dev=$(df / 2>/dev/null | awk 'NR==2 {print $1}' || true)
    if [[ "$root_dev" =~ mmcblk ]]; then
        SYS_IS_TF_CARD=true
        SYS_ROOT_DISK="$root_dev"
        return 0
    fi
    local dev_name; dev_name=$(basename "$root_dev" 2>/dev/null || true)
    if [[ -n "$dev_name" && -f "/sys/block/$dev_name/queue/rotational" ]]; then
        local rotational; rotational=$(cat "/sys/block/$dev_name/queue/rotational" 2>/dev/null || echo "1")
        if [[ "$rotational" == "0" ]]; then
            if [[ "$dev_name" == mmcblk* ]] || [[ -d "/sys/block/$dev_name" && ! -d "/sys/block/$dev_name/device" ]]; then
                SYS_IS_TF_CARD=true
                SYS_ROOT_DISK="$root_dev"
                return 0
            fi
        fi
    fi
    if [[ -f "/sys/block/$dev_name/device/name" ]]; then
        local model; model=$(cat "/sys/block/$dev_name/device/name" 2>/dev/null || true)
        if echo "$model" | grep -qi "tf\|sd\|emmc"; then
            SYS_IS_TF_CARD=true
            SYS_ROOT_DISK="$root_dev"
            return 0
        fi
    fi
    SYS_IS_TF_CARD=false
    SYS_ROOT_DISK="$root_dev"
    return 0
}

check_network() {
    log_step "检测网络连接..."
    if ! ping -c1 -W3 8.8.8.8 &>/dev/null; then
        log_error "无法连接到 8.8.8.8，请检查网络"
        exit 1
    fi
    log_info "网络连接正常"
}

preflight_check() {
    log_step "执行预检查..."
    [[ $EUID -ne 0 ]] && { log_error "需要 root 权限"; exit 1; }
    [[ $SYS_DISK_AVAIL_GB -lt 3 ]] && log_warn "磁盘可用空间 ${SYS_DISK_AVAIL_GB}GB < 3GB"
    [[ $SYS_MEM_MB -lt 256 ]] && log_warn "内存 ${SYS_MEM_MB}MB < 256MB，可能不稳定"
    if ! ping -c1 -W3 github.com &>/dev/null; then
        log_warn "无法访问 GitHub，部分功能可能受限"
    fi
    log_info "预检查通过"
}

backup_file() {
    local file="$1"
    [[ -f "$file" ]] && cp -a "$file" "${file}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
}

# =============================================================================
# APT 配置
# =============================================================================
configure_apt_sources() {
    log_step "配置 APT 源..."
    local sources_list="/etc/apt/sources.list"
    local codename; codename=$(grep -oP '(?<=^VERSION_CODENAME=).+' /etc/os-release 2>/dev/null | tr -d '"' || echo "bookworm")
    backup_file "$sources_list"

    mkdir -p /etc/apt/apt.conf.d /etc/needrestart/conf.d
    printf 'DPkg::Options {"--force-confdef"; "--force-confold";};\nAPT::Get::Assume-Yes "true";\nAPT::Get::Fix-Missing "true";\n' > /etc/apt/apt.conf.d/99-noninteractive
    printf '$nrconf{restart} = '"'"'a'"'"';\n$nrconf{kernelhints} = 0;\n$nrconf{unneeded} = '"'"'a'"'"';\n' > /etc/needrestart/conf.d/99-openclaw.conf

    cat > "$sources_list" <<EOF
deb http://mirrors.tencent.com/debian/ ${codename} main contrib non-free non-free-firmware
deb http://mirrors.tencent.com/debian/ ${codename}-updates main contrib non-free non-free-firmware
deb http://mirrors.tencent.com/debian-security/ ${codename}-security main contrib non-free non-free-firmware
deb http://mirrors.tencent.com/debian/ ${codename}-backports main contrib non-free non-free-firmware
EOF

    if ! apt-get update -qq >> "$APT_LOG" 2>&1; then
        log_warn "腾讯云镜像不可用，尝试官方源..."
        cat > "$sources_list" <<'EOFALL'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-backports main contrib non-free non-free-firmware
EOFALL
        apt-get update -qq >> "$APT_LOG" 2>&1 || true
    fi
    log_info "APT 源配置完成"
}

# =============================================================================
# 系统清理
# =============================================================================
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
    [[ ${#to_remove[@]} -gt 0 ]] && apt-get remove --purge -y "${to_remove[@]}" >> "$APT_LOG" 2>&1 || true
    apt-get autoremove -y >> "$APT_LOG" 2>&1 || true
    apt-get autoclean >> "$APT_LOG" 2>&1 || true
    log_info "系统清理完成"
}

install_base_tools() {
    log_step "安装基础工具..."
    local tools=(curl wget git jq vim htop net-tools dnsutils traceroute mtr iptraf-ng iftop iperf3 sysstat ncdu tree rsync tmux unzip zip ca-certificates gnupg lsb-release apt-transport-https dirmngr ethtool pciutils bc dc cron)
    local to_install=()
    for tool in "${tools[@]}"; do command -v "$tool" &>/dev/null || to_install+=("$tool"); done
    [[ ${#to_install[@]} -gt 0 ]] && { apt-get install -y --no-install-recommends "${to_install[@]}" >> "$APT_LOG" 2>&1; log_info "已安装 ${#to_install[@]} 个工具"; }
}

configure_dns() {
    log_step "配置 DNS..."
    mkdir -p /etc/systemd
    cat > /etc/systemd/resolved.conf <<'EOFDNS'
[Resolve]
DNS=1.1.1.1 8.8.8.8 223.5.5.5
FallbackDNS=1.0.0.1 8.8.4.4 119.29.29.29
DNSSEC=no
DNSOverTLS=no
DNSStubListener=no
ReadEtcHosts=yes
EOFDNS
    systemctl restart systemd-resolved 2>/dev/null || true
    systemctl enable systemd-resolved 2>/dev/null || true
    log_info "DNS 配置完成"
}

configure_time_sync() {
    log_step "配置时间同步..."
    if ! command -v chronyd &>/dev/null; then apt-get install -y chrony >> "$APT_LOG" 2>&1 || true; fi
    cat > /etc/chrony/chrony.conf <<'EOFCHRONY'
server 0.pool.ntp.org iburst
server 1.pool.ntp.org iburst
server 2.pool.ntp.org iburst
server 3.pool.ntp.org iburst
server ntp.cloud.tencent.com iburst
server time.google.com iburst
makestep 1.0 -1
rtcsync
logdir /var/log/chrony
EOFCHRONY
    systemctl restart chronyd 2>/dev/null || true
    systemctl enable chronyd 2>/dev/null || true
    systemctl enable cron 2>/dev/null || true
    systemctl restart cron 2>/dev/null || true
    chronyc makestep 2>/dev/null || true
    log_info "时间同步配置完成"
}

detect_timezone() {
    if command -v timedatectl &>/dev/null; then
        local tz; tz=$(timedatectl show --property=Timezone --value 2>/dev/null || true)
        [[ -n "$tz" && -f "/usr/share/zoneinfo/$tz" ]] && { echo "$tz"; return 0; }
    fi
    if [[ -f /etc/timezone ]] && [[ -n "$(cat /etc/timezone 2>/dev/null)" ]]; then
        local tz; tz=$(cat /etc/timezone 2>/dev/null)
        [[ -f "/usr/share/zoneinfo/$tz" ]] && { echo "$tz"; return 0; }
    fi
    for tz in "Asia/Shanghai" "America/New_York" "America/Los_Angeles" "UTC"; do
        [[ -f "/usr/share/zoneinfo/$tz" ]] && { echo "$tz"; return 0; }
    done
    echo "UTC"
}

configure_timezone() {
    log_step "配置时区..."
    local server_tz; server_tz=$(detect_timezone)
    local current_tz=""; [[ -f /etc/timezone ]] && current_tz=$(cat /etc/timezone 2>/dev/null || echo "")
    if [[ "$current_tz" == "$server_tz" ]]; then log_info "时区已是 $server_tz"; return 0; fi
    if command -v timedatectl &>/dev/null && timedatectl set-timezone "$server_tz" 2>/dev/null; then
        log_info "时区已设置为 $server_tz"
    elif [[ -f "/usr/share/zoneinfo/$server_tz" ]]; then
        ln -sf "/usr/share/zoneinfo/$server_tz" /etc/localtime 2>/dev/null
        echo "$server_tz" > /etc/timezone 2>/dev/null || true
        log_info "时区已设置为 $server_tz"
    else
        log_warn "无法设置时区 $server_tz"
    fi
}

configure_locale() {
    log_step "配置 locale..."
    if locale -a 2>/dev/null | grep -qi "zh_CN"; then log_info "中文 locale 已存在"; return 0; fi
    apt-get install -y locales >> "$APT_LOG" 2>&1 || true
    sed -i '/zh_CN.UTF-8/s/^# //' /etc/locale.gen 2>/dev/null || true
    locale-gen >> "$APT_LOG" 2>&1 || true
    update-locale LANG=zh_CN.UTF-8 2>/dev/null || true
    log_info "中文 locale 配置完成"
}

configure_limits() {
    log_step "配置系统限制..."
    local limits_file="/etc/security/limits.conf"
    backup_file "$limits_file"

    cat >> "$limits_file" <<'EOFLIMITS'

* soft nofile 524288
* hard nofile 524288
* soft nproc 65535
* hard nproc 65535
* soft memlock unlimited
* hard memlock unlimited
root soft nofile 1048576
root hard nofile 1048576
root soft nproc 131072
root hard nproc 131072
root soft memlock unlimited
root hard memlock unlimited
EOFLIMITS

    [[ -f /proc/sys/fs/inotify/max_user_watches ]] && echo 524288 > /proc/sys/fs/inotify/max_user_watches
    [[ -f /proc/sys/fs/inotify/max_user_instances ]] && echo 4096 > /proc/sys/fs/inotify/max_user_instances

    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-inotify.conf <<'EOFINOTIFY'
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 4096
EOFINOTIFY

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
    mkdir -p /etc/systemd/system/docker.service.d
    cat > /etc/systemd/system/docker.service.d/override.conf <<'EOFDOCKERLIM'
[Service]
LimitNOFILE=1048576
LimitNPROC=65535
LimitMEMLOCK=infinity
EOFDOCKERLIM

    systemctl daemon-reload >/dev/null 2>&1 || true
    log_info "系统限制配置完成"
}

# =============================================================================
# TF卡保护核心优化 v3.0
# =============================================================================
configure_tf_card_protection() {
    log_step "TF卡保护核心优化..."
    if [[ "$SYS_IS_TF_CARD" != "true" ]]; then
        log_info "非TF卡，跳过TF卡保护"
        return 0
    fi
    log_info "实施TF卡保护策略..."

    # 1. journald压缩+大小限制
    log_step "配置 journald..."
    mkdir -p /etc/systemd
    cat > /etc/systemd/journald.conf <<'EOFJOURNAL'
[Journal]
SystemMaxUse=50M
SystemMaxFileSize=20M
RuntimeMaxUse=50M
MaxRetentionSec=1day
Compress=yes
Storage=volatile
ForwardToSyslog=no
MaxLevelStore=warning
EOFJOURNAL
    systemctl restart systemd-journald 2>/dev/null || true
    log_info "journald 已优化 (压缩+50MB限制)"

    # 2. log2ram
    configure_log2ram_local

    # 3. /tmp tmpfs
    log_step "配置 /tmp tmpfs..."
    if ! grep -q "tmpfs /tmp" /etc/fstab 2>/dev/null; then
        echo "tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,mode=1777,size=512M 0 0" >> /etc/fstab
    fi
    log_info "/tmp tmpfs 已配置"

    # 4. ext4挂载参数
    log_step "优化 ext4 挂载参数..."
    configure_ext4_commit

    # 5. 禁用iostats
    log_step "禁用 TF卡 iostats..."
    local dev_name; dev_name=$(basename "$SYS_ROOT_DISK" 2>/dev/null || echo "")
    if [[ -n "$dev_name" && -f "/sys/block/$dev_name/queue/iostats" ]]; then
        echo 0 > "/sys/block/$dev_name/queue/iostats" 2>/dev/null || true
        log_info "iostats 已禁用"
    fi

    # 6. read_ahead
    log_step "优化 read_ahead..."
    for dev in /sys/block/*/queue/read_ahead_kb; do
        [[ -f "$dev" ]] && echo 128 > "$dev" 2>/dev/null || true
    done
    log_info "read_ahead 已优化为 128KB"

    # 7. sysctl TF卡优化
    log_step "配置 sysctl TF卡优化..."
    cat > /etc/sysctl.d/99-tf-optimize.conf <<'EOFSYSCTL'
vm.dirty_writeback_centisecs = 15000
vm.dirty_expire_centisecs = 15000
vm.dirty_ratio = 8
vm.dirty_background_ratio = 3
EOFSYSCTL
    sysctl -p /etc/sysctl.d/99-tf-optimize.conf 2>/dev/null || true
    log_info "sysctl TF卡优化完成"

    # 8. logrotate
    log_step "配置 logrotate..."
    mkdir -p /etc/logrotate.d
    cat > /etc/logrotate.d/openclaw <<'EOFLOGROTATE'
/var/log/openclaw/*.log {
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

    # 9. 禁用swap
    log_step "禁用 swap（保护TF卡）..."
    for sw in /swapfile /swap.img; do
        swapon --show 2>/dev/null | grep -q "$sw" && swapoff "$sw" 2>/dev/null || true
        [[ -f "$sw" ]] && rm -f "$sw"
    done
    sed -i '/swapfile/d; /swap.img/d' /etc/fstab 2>/dev/null || true
    [[ -f /sys/module/zswap/parameters/enabled ]] && echo N > /sys/module/zswap/parameters/enabled 2>/dev/null || true
    log_info "swap 已禁用"

    # 10. 清理定时任务
    configure_cleanup_cron

    log_info "TF卡保护完成"
}

configure_log2ram_local() {
    log_step "配置 log2ram..."
    if command -v log2ram &>/dev/null; then
        log_info "log2ram 已安装"
    else
        log_info "安装 log2ram..."
        local log2ram_ver="1.4.1"
        local tmpdir="/tmp/log2ram_install"
        mkdir -p "$tmpdir"
        rm -rf "$tmpdir"/*
        if curl -fsSL "https://github.com/azlux/log2ram/archive/refs/tags/${log2ram_ver}.tar.gz" -o "$tmpdir/log2ram.tar.gz" 2>/dev/null; then
            tar -xzf "$tmpdir/log2ram.tar.gz" -C "$tmpdir" 2>/dev/null
            cd "$tmpdir/log2ram-${log2ram_ver}" 2>/dev/null || cd "$tmpdir" && ls
            if [[ -f install.sh ]]; then
                chmod +x install.sh
                SKIP_SYSD=1 bash install.sh >> "$APT_LOG" 2>&1 || true
            fi
        else
            log_warn "log2ram 下载失败，跳过"
        fi
        cd / 2>/dev/null
        rm -rf "$tmpdir"
    fi
    if [[ -f /etc/log2ram.conf ]]; then
        log_info "配置 log2ram 参数..."
        sed -i 's/^SIZE=.*/SIZE=64M/' /etc/log2ram.conf
        sed -i 's/^USE_RSYNC=.*/USE_RSYNC=true/' /etc/log2ram.conf
        sed -i 's/^COMPRESSION=.*/COMPRESSION=true/' /etc/log2ram.conf
        systemctl enable log2ram 2>/dev/null || true
        systemctl restart log2ram 2>/dev/null || true
        log_info "log2ram 已配置 (64MB)"
    fi
}

configure_ext4_commit() {
    local fstab_file="/etc/fstab"
    [[ ! -f "$fstab_file" ]] && { log_warn "/etc/fstab 不存在"; return 1; }
    backup_file "$fstab_file"

    local line has_ext4=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^[^#].*\ ext4 ]]; then
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

configure_cleanup_cron() {
    log_step "配置自动清理..."
    mkdir -p /usr/local/bin
    cat > /usr/local/bin/aiagent-cleanup.sh <<'EOTCLEANUP'
#!/bin/bash
# AIagent 清理脚本 - TF卡保护版
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

# =============================================================================
# 安装 Node.js
# =============================================================================
install_nodejs() {
    if [[ "$INSTALL_NODEJS" != "true" ]]; then log_info "跳过 Node.js 安装"; return 0; fi
    log_step "安装 Node.js ${NODEJS_VERSION}..."
    if command -v node &>/dev/null; then log_info "Node.js 已安装: $(node --version)"; return 0; fi
    curl --max-time 90 -fsSL "https://deb.nodesource.com/setup_${NODEJS_VERSION}.x" | bash - >> "$APT_LOG" 2>&1 || {
        log_warn "NodeSource 安装失败，尝试系统包..."
        apt-get install -y nodejs npm >> "$APT_LOG" 2>&1 || true
        return 0
    }
    apt-get install -y nodejs >> "$APT_LOG" 2>&1
    if command -v node &>/dev/null; then log_info "Node.js $(node --version) 安装成功"; fi
}

# =============================================================================
# 安装 Docker
# =============================================================================
install_docker() {
    if [[ "$INSTALL_DOCKER" != "true" ]]; then log_info "跳过 Docker 安装"; return 0; fi
    log_step "安装 Docker..."
    if command -v docker &>/dev/null; then log_info "Docker 已安装: $(docker --version)"; return 0; fi
    curl --max-time 120 -fsSL https://get.docker.com | sh -s -- --mirror Aliyun >> "$APT_LOG" 2>&1 || {
        log_warn "Docker 安装失败，使用系统包..."
        apt-get install -y docker.io docker-compose >> "$APT_LOG" 2>&1 || true
    }
    systemctl enable docker 2>/dev/null || true
    systemctl start docker 2>/dev/null || true

    mkdir -p /etc/docker
    local docker_log_size="50m"
    [[ $SYS_DISK_AVAIL_GB -lt 10 ]] && docker_log_size="20m" && log_warn "磁盘空间有限，Docker日志限制为20MB"
    cat > /etc/docker/daemon.json <<EOFDOCKER
{
    "storage-driver": "overlay2",
    "log-driver": "json-file",
    "log-opts": {"max-size": "${docker_log_size}", "max-file": "2"},
    "live-restore": true,
    "userland-proxy": false,
    "registry-mirrors": ["https://mirror.ccs.tencentyi.com"]
}
EOFDOCKER

    systemctl restart docker 2>/dev/null || true
    if command -v docker &>/dev/null; then log_info "Docker $(docker --version) 安装成功"; fi
}

# =============================================================================
# 安装 OpenClaw
# =============================================================================
install_openclaw() {
    log_step "安装 OpenClaw..."
    if ! id -u "$OPENCLAW_USER" &>/dev/null; then useradd -r -m -s /bin/bash -c "OpenClaw Service Account" "$OPENCLAW_USER" 2>/dev/null || true; fi
    if [[ "${INSTALL_METHOD:-}" == "docker" ]]; then
        log_info "使用 Docker 容器安装 OpenClaw..."
        if ! command -v docker &>/dev/null; then install_docker; fi
        mkdir -p "$OPENCLAW_DATA_DIR"
        chown -R "$OPENCLAW_USER:$OPENCLAW_USER" "$OPENCLAW_DATA_DIR" 2>/dev/null || true
        log_info "拉取 OpenClaw 镜像..."
        docker pull openclaw/openclaw:latest >> "$APT_LOG" 2>&1 || {
            docker pull ghcr.io/openclaw/openclaw:latest >> "$APT_LOG" 2>&1 || { log_error "Docker 镜像拉取失败"; return 1; }
        }
        log_info "OpenClaw 容器安装完成"
    else
        log_info "使用全局安装 OpenClaw..."
        if ! command -v openclaw &>/dev/null; then
            npm install -g openclaw --registry https://registry.npmmirror.com >> "$APT_LOG" 2>&1 || {
                npm install -g openclaw >> "$APT_LOG" 2>&1 || { log_error "OpenClaw 安装失败"; return 1; }
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
        cat > ~/.config/systemd/user/openclaw-gateway.service <<EOFSYSDOCKER
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
    openclaw/openclaw:latest gateway --port ${OPENCLAW_PORT}
ExecStop=/usr/bin/docker stop openclaw-gateway 2>/dev/null || true

${memory_max}
OOMScoreAdjust=-200

[Install]
WantedBy=default.target
EOFSYSDOCKER
    else
        mkdir -p ~/.config/systemd/user
        cat > ~/.config/systemd/user/openclaw-gateway.service <<EOFSYSSERVICE
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
OOMScoreAdjust=-200

[Install]
WantedBy=default.target
EOFSYSSERVICE
    fi

    systemctl --user daemon-reload
    systemctl --user enable openclaw-gateway 2>/dev/null || true
    log_info "systemd 服务创建完成"
    log_step "提示: 运行以下命令启动服务:"
    echo "  systemctl --user start openclaw-gateway"
    echo "  systemctl --user enable openclaw-gateway  # 开机自启"
}

# =============================================================================
# I/O 调度
# =============================================================================
optimize_io_scheduler() {
    log_step "优化 I/O 调度..."
    if [[ "$SYS_IS_TF_CARD" == "true" ]]; then
        for dev in /sys/block/*/queue/scheduler; do [[ -f "$dev" ]] && echo "none" > "$dev" 2>/dev/null || true; done
        log_info "TF卡: none 调度器"
    elif [[ -b "$SYS_ROOT_DISK" ]]; then
        if cat /sys/block/*/queue/rotational 2>/dev/null | grep -q "0"; then
            for dev in /sys/block/*/queue/scheduler; do [[ -f "$dev" ]] && echo "none" > "$dev" 2>/dev/null || true; done
            log_info "SSD: none 调度器"
        else
            for dev in /sys/block/*/queue/scheduler; do [[ -f "$dev" ]] && echo "mq-deadline" > "$dev" 2>/dev/null || true; done
            log_info "HDD: mq-deadline 调度器"
        fi
    fi
}

# =============================================================================
# 平台信息
# =============================================================================
readonly PLATFORM_NAME="NanoPi R4S"
readonly PLATFORM_DESC="RK3399 ARM64, 4GB RAM, TF卡, 双千兆网口"

ZRAM_SIZE=1024
ZRAM_ALGO="lz4"
SWAPPINESS=10
TCP_BUF_MAX=8388608
TCP_TW_BUCKETS=32768
CT_MAX=524288
MIN_FREE_KB=8192

# =============================================================================
# 平台检测
# =============================================================================
detect_nanopi_r4s() {
    log_step "检测 NanoPi R4S..."
    if [[ -f /proc/device-tree/model ]]; then
        local model; model=$(cat /proc/device-tree/model 2>/dev/null || echo "")
        if echo "$model" | grep -qi "R4S"; then log_info "检测到: $model"; return 0; fi
    fi
    if grep -qi "rk3399" /proc/cpuinfo 2>/dev/null; then log_info "检测到 RK3399 平台"; return 0; fi
    if [[ "$(uname -m)" != "aarch64" ]]; then log_error "NanoPi R4S 需要 ARM64 架构"; return 1; fi
    log_warn "未明确检测到 NanoPi R4S，但架构匹配"
    return 0
}

# =============================================================================
# 内存优化
# =============================================================================
optimize_memory_r4s() {
    log_step "配置内存优化 (R4S 4GB)..."
    for sw in /swapfile /swap.img; do
        swapon --show 2>/dev/null | grep -q "$sw" && swapoff "$sw" 2>/dev/null || true
        [[ -f "$sw" ]] && rm -f "$sw"
    done
    sed -i '/swapfile/d; /swap.img/d' /etc/fstab 2>/dev/null || true
    [[ -f /sys/module/zswap/parameters/enabled ]] && echo N > /sys/module/zswap/parameters/enabled 2>/dev/null || true

    if [[ $SYS_MEM_MB -ge 4096 ]]; then
        log_info "内存 >= 4GB，ZRAM ${ZRAM_SIZE}MB (紧急备用)"
    else
        ZRAM_SIZE=512
        log_info "内存 < 4GB，ZRAM 调整为 ${ZRAM_SIZE}MB"
    fi

    if modinfo zram >/dev/null 2>&1 || [[ -d /sys/block/zram0 ]]; then
        apt-get remove --purge -y zram-config >> "$APT_LOG" 2>&1 || true
        apt-get install -y --no-install-recommends zram-tools >> "$APT_LOG" 2>&1 || true
        cat > /etc/default/zramswap <<EOFZRAM
ALGO=${ZRAM_ALGO}
SIZE=${ZRAM_SIZE}
PRIORITY=100
EOFZRAM
        systemctl enable zramswap 2>/dev/null || true
        systemctl restart zramswap 2>/dev/null || true
        sleep 2
        lsblk | grep -q zram && log_info "ZRAM ${ZRAM_SIZE}MB (${ZRAM_ALGO}) 已启用"
    else
        log_warn "ZRAM 不可用"
    fi
    sysctl -w vm.swappiness=$SWAPPINESS 2>/dev/null || true
    log_info "内存优化完成"
}

# =============================================================================
# sysctl
# =============================================================================
configure_sysctl_r4s() {
    log_step "配置 sysctl (R4S v3.0)..."
    local sysctl_file="/etc/sysctl.d/99-openclaw.conf"
    backup_file "$sysctl_file"

    cat > "$sysctl_file" <<EOFSYSCTL
# NanoPi R4S OpenClaw 优化配置 v3.0
# RK3399 ARM64, 4GB RAM, TF卡存储

# 网络缓冲区 (R4S - 8MB)
net.core.rmem_max = ${TCP_BUF_MAX}
net.core.wmem_max = ${TCP_BUF_MAX}
net.ipv4.ip_local_port_range = 10240 65535
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 16384

# TCP
net.ipv4.tcp_rmem = 4096 131072 ${TCP_BUF_MAX}
net.ipv4.tcp_wmem = 4096 65536 ${TCP_BUF_MAX}
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = ${TCP_TW_BUCKETS}
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_mtu_probing = 1

# BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 文件描述符
fs.file-max = 524288
fs.nr_open = 524288

# 内存
vm.swappiness = ${SWAPPINESS}
vm.dirty_ratio = 8
vm.dirty_background_ratio = 3
vm.min_free_kbytes = ${MIN_FREE_KB}
vm.overcommit_memory = 1
vm.zone_reclaim_mode = 0

# 连接追踪
net.netfilter.nf_conntrack_max = ${CT_MAX}
net.netfilter.nf_conntrack_hashsize = ${CT_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 1800
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 10

# IPv6
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0

# 安全
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.log_martians = 0
net.ipv4.conf.default.log_martians = 0
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 1
kernel.yama.ptrace_scope = 1

# ARM64 特定
vm.vfs_cache_pressure = 50
EOFSYSCTL

    # 加载 BBR 模块
    modprobe tcp_bbr 2>/dev/null || true
    modprobe tcp_dctcp 2>/dev/null || true
    sysctl -p "$sysctl_file" 2>/dev/null || true
    log_info "sysctl R4S v3.0 优化完成"
}

# =============================================================================
# 网卡优化
# =============================================================================
optimize_network_r4s() {
    log_step "优化网卡 (R4S 双网口)..."
    for iface in /sys/class/net/eth*; do
        [[ -d "$iface" ]] || continue
        local name; name=$(basename "$iface")
        ethtool -K "$name" tso on 2>/dev/null || true
        ethtool -K "$name" gso on 2>/dev/null || true
        ethtool -K "$name" gro on 2>/dev/null || true
        ethtool -A "$name" rx on 2>/dev/null || true
        ethtool -A "$name" tx on 2>/dev/null || true
        # 增加网卡队列长度（网关大流量优化）
        ip link set "$name" txqueuelen 10000 2>/dev/null || true
        local speed; speed=$(ethtool "$name" 2>/dev/null | grep "Speed:" | awk '{print $2}' || echo "unknown")
        log_info "网卡 $name 优化完成 (Speed: $speed, TX: 10000)"
    done
    if [[ $SYS_CPU_CORES -gt 1 ]]; then
        local mask; mask=$(printf '%x' $(( (1 << SYS_CPU_CORES) - 1 )) | tr 'a-z' 'A-Z')
        for rps in /sys/class/net/eth*/queues/rx-*/rps_cpus; do [[ -f "$rps" ]] || continue; printf "%s" "$mask" > "$rps" 2>/dev/null || true; done
        log_info "RPS 启用 (CPU mask: 0x$mask)"
    fi
}

# =============================================================================
# ARM 特定优化
# =============================================================================
optimize_arm() {
    log_step "ARM 特定优化..."
    local gov_changed=false
    # CPU governor（强制performance，AIagent需要稳定响应速度）
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [[ -f "$cpu" && -w "$cpu" ]] || continue
        echo "performance" > "$cpu" 2>/dev/null || true
        gov_changed=true
    done
    if [[ "$gov_changed" == "true" ]]; then
        local gov; gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
        log_info "CPU governor: ${gov}"
    else
        log_info "CPU governor 无法修改（容器限制）"
    fi

    # irqbalance (ARM多核需要)
    if ! command -v irqbalance &>/dev/null; then
        apt-get install -y --no-install-recommends irqbalance >> "$APT_LOG" 2>&1 || true
    fi
    systemctl enable irqbalance 2>/dev/null || true
    systemctl start irqbalance 2>/dev/null || true
    log_info "irqbalance 已启用"

    log_info "ARM 特定优化完成"
}

# =============================================================================
# OOM Killer
# =============================================================================
optimize_oom() {
    log_step "配置 OOM Killer..."
    mkdir -p /etc/systemd/system/openclaw-gateway.service.d
    cat > /etc/systemd/system/openclaw-gateway.service.d/oom.conf <<'EOFOOM'
[Service]
OOMScoreAdjust=-200
EOFOOM
    log_info "OOM Killer 优化完成"
}

# =============================================================================
# SSH
# =============================================================================
optimize_ssh() {
    log_step "SSH 安全加固..."
    local sshd_config="/etc/ssh/sshd_config"
    [[ ! -f "$sshd_config" ]] && return 0
    backup_file "$sshd_config"
    sed -i 's/^PermitEmptyPasswords.*/PermitEmptyPasswords no/' "$sshd_config" 2>/dev/null || true
    sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' "$sshd_config" 2>/dev/null || true
    sed -i 's/^PubkeyAuthentication.*/PubkeyAuthentication no/' "$sshd_config" 2>/dev/null || true
    grep -q "^ClientAliveInterval" "$sshd_config" 2>/dev/null || echo "ClientAliveInterval 3600" >> "$sshd_config"
    sed -i 's/^ClientAliveInterval.*/ClientAliveInterval 3600/' "$sshd_config" 2>/dev/null || true
    sed -i 's/^ClientAliveCountMax.*/ClientAliveCountMax 3/' "$sshd_config" 2>/dev/null || true
    sed -i 's/^X11Forwarding.*/X11Forwarding no/' "$sshd_config" 2>/dev/null || true
    log_info "SSH 加固完成"
}

# =============================================================================
# 诊断
# =============================================================================
run_doctor() {
    log_step "运行诊断..."
    echo ""
    echo "=== AIagent 环境诊断报告 (NanoPi R4S) ==="
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
    [[ "$SYS_IS_TF_CARD" == "true" ]] && echo "   TF卡存储: 是" || echo "   TF卡存储: 否"
    echo "   swap状态: $(swapon --show 2>/dev/null | grep -v Filename | wc -l) 个"
    echo "   journald: $(grep SystemMaxUse /etc/systemd/journald.conf 2>/dev/null | cut -d= -f2)"
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
    systemctl --user is-active openclaw-gateway 2>/dev/null && echo "   openclaw-gateway: active" || echo "   openclaw-gateway: inactive"
    systemctl is-active docker 2>/dev/null && echo "   docker: active" || echo "   docker: inactive"
    systemctl is-active chronyd 2>/dev/null && echo "   chronyd: active" || echo "   chronyd: inactive"
    echo ""
    echo "8. 磁盘:"
    df -h / | tail -1 | awk '{printf "   系统盘: %s 总, %s 已用, %s 可用 (%s)\n", $2, $3, $4, $5}'
    echo ""
    echo "=== 诊断完成 ==="
}

# =============================================================================
# 主函数
# =============================================================================
main() {
    clear
    echo "========================================================================"
    echo -e "${GREEN}  NanoPi R4S 专用优化安装脚本 v${SCRIPT_VERSION}${NC}"
    echo "========================================================================"
    echo -e "${BLUE}平台: ${PLATFORM_DESC}${NC}"
    echo ""

    init_script
    detect_system
    check_network
    detect_nanopi_r4s || exit 1

    echo ""
    echo -e "${BLUE}优化计划:${NC}"
    echo "  平台:      ${PLATFORM_DESC}"
    echo "  系统:      ${SYS_OS_ID} ${SYS_OS_VERSION}"
    echo "  架构:      ${SYS_ARCH} | 内存: ${SYS_MEM_MB}MB | CPU: ${SYS_CPU_CORES}核"
    echo "  TF卡:      ${SYS_IS_TF_CARD}"
    echo "  ZRAM:      ${ZRAM_SIZE}MB (紧急备用)"
    echo ""

    if [[ -t 0 ]]; then
        echo -e "${YELLOW}请选择 OpenClaw 安装方式:${NC}"
        echo "  1) Docker 容器安装 (推荐)"
        echo "  2) 全局安装 (npm install -g)"
        echo -n "选择 (1/2，默认 1): "
        read -r install_choice
        case "$install_choice" in
            2) export INSTALL_METHOD="npm"; INSTALL_DOCKER="false"; INSTALL_NODEJS="true"; install_method_display="全局安装 (npm)"; ;;
            *) export INSTALL_METHOD="docker"; INSTALL_DOCKER="true"; INSTALL_NODEJS="false"; install_method_display="Docker 容器"; ;;
        esac
    else
        export INSTALL_METHOD="${INSTALL_METHOD:-docker}"
        INSTALL_DOCKER="${INSTALL_DOCKER:-true}"
        INSTALL_NODEJS="${INSTALL_NODEJS:-false}"
        install_method_display="Docker 容器 (默认)"
    fi
    local docker_display="${INSTALL_DOCKER}"; [[ "$docker_display" == "true" ]] && docker_display="是" || docker_display="跳过"
    echo "  安装方式:  ${install_method_display}"
    echo "  Docker:    ${docker_display}"
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
    configure_tf_card_protection
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
    optimize_oom
    optimize_ssh

    install_base_tools
    install_nodejs
    install_docker
    install_openclaw
    create_systemd_service
    run_doctor

    apt-get autoremove -y >> "$APT_LOG" 2>&1 || true
    apt-get autoclean >> "$APT_LOG" 2>&1 || true

    echo ""
    echo "========================================================================"
    echo -e "${GREEN}  ✅ NanoPi R4S v${SCRIPT_VERSION} 优化完成！${NC}"
    echo "========================================================================"
    echo ""
    echo -e "${CYAN}TF卡保护已启用:${NC}"
    echo "  - journald: 压缩 + 50MB限制"
    echo "  - log2ram: 64MB RAM日志缓冲"
    echo "  - /tmp: tmpfs (减少TF卡写入)"
    echo "  - ext4: commit=600 (5分钟批量写)"
    echo "  - swap: 已禁用 (保护TF卡)"
    echo "  - 每日清理: 自动执行"
    echo ""
    echo -e "${CYAN}后续步骤:${NC}"
    echo "  1. reboot"
    echo "  2. sudo -u ${OPENCLAW_USER} -i openclaw onboard"
    echo "  3. systemctl --user start openclaw-gateway"
    echo "  4. systemctl --user enable openclaw-gateway  # 开机自启"
    echo ""
    echo -e "${YELLOW}日志: ${APT_LOG}${NC}"
    echo ""
}

trap 'log_error "脚本异常退出 (行: ${LINENO})"; exit 1' ERR
trap 'log_warn "被中断"; exit 130' INT TERM

main "$@"
