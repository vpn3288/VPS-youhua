#!/usr/bin/env bash
# =============================================================================
# NanoPi R4S 专用优化安装脚本 v3.1
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
[[ -f /proc/sys/fs/inotify/max_user_watches ]] && echo 1048576 > /proc/sys/fs/inotify/max_user_watches 2>/dev/null || true

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
OPTIMIZE_ONLY="${OPTIMIZE_ONLY:-false}"
NODEJS_VERSION="${NODEJS_VERSION:-22}"
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

    [[ -f /proc/sys/fs/inotify/max_user_watches ]] && echo 1048576 > /proc/sys/fs/inotify/max_user_watches
    [[ -f /proc/sys/fs/inotify/max_user_instances ]] && echo 8192 > /proc/sys/fs/inotify/max_user_instances

    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-inotify.conf <<'EOFINOTIFY'
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 8192
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

    systemctl daemon-reload || log_warn "daemon-reload 失败，服务可能使用旧配置"
    log_info "系统限制配置完成"
}

# =============================================================================
# journald 优化 (TF卡/flash 存储保护)
# =============================================================================
configure_journald() {
    log_step "配置 journald..."
    mkdir -p /etc/systemd
    cat > /etc/systemd/journald.conf <<'EOF'
[Journal]
SystemMaxUse=100M
SystemMaxFileSize=30M
RuntimeMaxUse=80M
MaxRetentionSec=7day  # TF卡保护: 7天足够排查问题，3天太短
Compress=yes
Storage=volatile
ForwardToSyslog=no
MaxLevelStore=notice
EOF
    systemctl restart systemd-journald 2>/dev/null || true
    log_info "journald 配置完成 (TF卡保护: 100M)"
}




configure_tf_card_protection() {
    log_step "TF卡保护核心优化..."
    if [[ "$SYS_IS_TF_CARD" != "true" ]]; then
        log_info "非TF卡，跳过TF卡保护"
        return 0
    fi
    log_info "实施TF卡保护策略..."

    # 1. TF卡保护（仅禁用物理swap，不碰 zram）
    log_step "TF卡保护..."
    for sw in /swapfile /swap.img; do
        if swapon --show 2>/dev/null | grep -q "$sw"; then
            swapoff "$sw" 2>/dev/null || true
            rm -f "$sw"
        fi
    done
    log_info "物理 swap 已禁用（保留 zram）"

    # 2. log2ram
    configure_log2ram_local

    # 3. /tmp tmpfs（动态大小：内存/8，上限2G，下限256M）
    log_step "配置 /tmp tmpfs..."
    local tmpfs_size_mb=$((SYS_MEM_MB / 8))
    [[ $tmpfs_size_mb -lt 256 ]] && tmpfs_size_mb=256
    [[ $tmpfs_size_mb -gt 2048 ]] && tmpfs_size_mb=2048
    if ! grep -q "tmpfs /tmp" /etc/fstab 2>/dev/null; then
        echo "tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,mode=1777,size=${tmpfs_size_mb}M 0 0" >> /etc/fstab
    fi
    log_info "/tmp tmpfs 已配置（${tmpfs_size_mb}MB，按内存比例动态计算）"

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

    # 9. TF卡保护：禁用物理swap但不破坏Armbian原生zram
    log_step "TF卡保护：检查物理swap... "
    # 只禁用物理swap文件（会写TF卡），不碰zram
    for sw in /swapfile /swap.img; do
        if swapon --show 2>/dev/null | grep -q "$sw"; then
            swapoff "$sw" 2>/dev/null || true
            rm -f "$sw"
            log_info "物理swap $sw 已禁用"
        fi
    done
    sed -i '/swapfile/d; /swap.img/d' /etc/fstab 2>/dev/null || true
    # 注意：不禁用zswap — Armbian原生zram-config依赖zswap压缩
    # Armbian的zram swap是压缩内存，零TF卡写入，完全安全
    log_info "Armbian原生zram swap保持启用（压缩内存，不写TF卡）"

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
    log_info "ext4 挂载参数已优化 (noatime,commit=600)"
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

    # 等待 Docker daemon 就绪（ARM 设备启动较慢）
    local docker_ready=false
    for i in {1..30}; do
        if docker info >/dev/null 2>&1; then
            docker_ready=true
            break
        fi
        sleep 1
    done
    [[ "$docker_ready" != "true" ]] && log_warn "Docker daemon 未就绪"
}

configure_docker_daemon() {
    log_step "配置 Docker daemon..."

    mkdir -p /etc/docker
    local docker_log_size="50m"
    [[ $SYS_DISK_AVAIL_GB -lt 10 ]] && docker_log_size="20m" && log_warn "磁盘空间有限，Docker日志限制为20M"

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
    \"log-opts\": {\"max-size\": \"${docker_log_size}\", \"max-file\": \"2\"},
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
        timeout 300 docker pull openclaw/openclaw:latest >> "$APT_LOG" 2>&1 || {
            timeout 300 docker pull ghcr.io/openclaw/openclaw:latest >> "$APT_LOG" 2>&1 || { log_error "Docker 镜像拉取失败"; return 1; }
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
    -e LANG=zh_CN.UTF-8 \
    -e LC_ALL=zh_CN.UTF-8 \
    openclaw/openclaw:latest gateway --port ${OPENCLAW_PORT}
ExecStop=/usr/bin/docker stop -t 10 openclaw-gateway
ExecStopPost=/usr/bin/docker rm -f openclaw-gateway

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
EOFSYSSERVICE
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
# I/O 调度
# =============================================================================
optimize_io_scheduler() {
    log_step "优化 I/O 调度..."
    if [[ "$SYS_IS_TF_CARD" == "true" ]]; then
        for dev in /sys/block/*/queue/scheduler; do [[ -f "$dev" ]] && echo "none" > "$dev" 2>/dev/null || true; done
        log_info "TF卡: none 调度器"
    elif [[ -b "$SYS_ROOT_DISK" ]]; then
        local root_name; root_name=$(basename "$SYS_ROOT_DISK" 2>/dev/null)
        if [[ -n "$root_name" && -f "/sys/block/$root_name/queue/rotational" ]] && \
           [[ "$(cat "/sys/block/$root_name/queue/rotational" 2>/dev/null)" == "0" ]]; then
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
TCP_BUF_MAX=16777216  # 16MB TCP缓冲（R4S 作为网关需要足够的窗口）
TCP_TW_BUCKETS=32768
CT_MAX=524288
MIN_FREE_KB=65536  # 4GB 机器预留 64MB，防止 OOM；8KB 太小，模型加载时 direct reclaim 会触发 OOM

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
        if swapon --show 2>/dev/null | grep -q "$sw"; then
            swapoff "$sw" 2>/dev/null || true
            rm -f "$sw"
            log_info "物理swap $sw 已禁用"
        fi
    done
    sed -i '/swapfile/d; /swap.img/d' /etc/fstab 2>/dev/null || true
    # 注意：不禁用zswap — Armbian原生zram-config依赖zswap压缩，零TF卡写入
    log_info "Armbian原生zram swap保持启用（压缩内存，不写TF卡）"

    if [[ $SYS_MEM_MB -ge 4096 ]]; then
        log_info "内存 >= 4GB，ZRAM ${ZRAM_SIZE}MB (紧急备用)"
    else
        ZRAM_SIZE=512
        log_info "内存 < 4GB，ZRAM 调整为 ${ZRAM_SIZE}MB"
    fi

    if [[ -d /sys/block/zram0 ]]; then
        # Armbian 原生自带 armbian-zram-config + armbian-ramlog
        # 不要卸载！armbian-ramlog 负责 /var/log ramlog（写内存不写TF卡）
        # 只需调整 vm.swappiness 让系统优先回收page cache而非用swap
        log_info "Armbian zram-config 已存在，保持原状（armbian-ramlog 管/var/log）"
        log_info "armbian-ramlog 将/var/log写入zram，零TF卡写入"
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
# NanoPi R4S OpenClaw 优化配置 v3.1
# RK3399 ARM64, 4GB RAM, TF卡存储

# 网络缓冲区
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
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_early_retrans = 3
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_keepalive_time = 300
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

# 内存
vm.swappiness = ${SWAPPINESS}
vm.dirty_ratio = 8
vm.dirty_background_ratio = 3
vm.min_free_kbytes = ${MIN_FREE_KB}
vm.overcommit_memory = 1

# 连接追踪
net.netfilter.nf_conntrack_max = ${CT_MAX}
net.netfilter.nf_conntrack_hashsize = ${CT_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 900
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 20
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 20
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 10
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 10
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 10

# IPv6
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.default.forwarding = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# IP 转发（Docker 容器网络必需；无容器时可不开启，但开启无害）
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# 连接安全
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# 内核安全强化（防止内核指针泄露和信息泄露攻击）
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
kernel.yama.ptrace_scope = 1

# ARM64 内存
vm.vfs_cache_pressure = 50
EOFSYSCTL

    if modprobe tcp_bbr 2>/dev/null; then
        log_info "BBR 已加载"
    else
        log_warn "BBR 加载失败（内核可能不支持）"
    fi
    sysctl -p "$sysctl_file" 2>/dev/null || true
    log_info "sysctl R4S v3.1 优化完成"
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
        local cores=$((SYS_CPU_CORES > 63 ? 63 : SYS_CPU_CORES))
        local mask; mask=$(printf '%x' $(( (1 << cores) - 1 )) | tr 'a-z' 'A-Z')
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
    echo -e "  ${CYAN}上次登录记录:${RESET}"
    last -n 3 2>/dev/null | grep -v "^$" | head -3 | sed "s/^/    /" || true
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
            # 清理后只剩 {} 或空文件，直接删除让 Docker 恢复默认配置
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
    echo "========================================================================"
    echo -e "${GREEN}  NanoPi R4S 专用优化安装脚本 v${SCRIPT_VERSION}${NC}"
    echo "========================================================================"
    echo -e "${BLUE}平台: ${PLATFORM_DESC}${NC}"
    echo ""

    # 解析参数
    for arg in "$@"; do
        case "$arg" in
            --optimize-only) OPTIMIZE_ONLY=true ;;
            --uninstall) ;;
        esac
    done

    uninstall_openclaw "$@" || exit 1
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
    [[ "$OPTIMIZE_ONLY" == "true" ]] && echo "  模式:      ${YELLOW}纯优化（跳过安装）${NC}" || echo "  模式:      全量安装"
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
    configure_journald
    configure_dns
    configure_time_sync
    configure_locale
    optimize_io_scheduler
    optimize_arm
    optimize_network_r4s
    optimize_oom
    disable_auto_updates
    optimize_ssh

    if [[ "$OPTIMIZE_ONLY" != "true" ]]; then
        install_base_tools || exit 1
        install_nodejs || exit 1
        install_docker || exit 1
        install_openclaw || exit 1
        create_systemd_service || exit 1
    else
        log_info "纯优化模式，跳过 Docker / Node.js / OpenClaw 安装"
    fi
    run_doctor || { log_warn "诊断报告有异常，但继续完成"; }

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
    echo "  - ext4: noatime,commit=600 (减少随机写入，延长TF寿命)"
    echo "  - swap: 物理swap已禁用, Armbian原生zram保持启用(压缩内存)"
    echo "  - 每日清理: 自动执行"
    echo ""
    echo -e "${CYAN}后续步骤:${NC}"
    echo "  1. reboot  ← 必须重启！sysctl/CPU governor/tmpfsmount/内核参数不重启不生效"
    echo "  2. sudo -u ${OPENCLAW_USER} -i openclaw onboard"
    echo "  3. systemctl --user start openclaw-gateway"
    echo "  4. systemctl --user enable openclaw-gateway  # 开机自启"
    echo ""
    echo -e "${YELLOW}⚠️  必须重启才能使所有优化生效！未重启时 sysctl/内存/tmpfs governor 均未就位${NC}"
    echo ""
    echo -e "${YELLOW}日志: ${APT_LOG}${NC}"
    echo ""
}

trap 'log_error "脚本异常退出 (行: ${LINENO})"; exit 1' ERR
trap 'log_warn "被中断"; exit 130' INT TERM

main "$@"
