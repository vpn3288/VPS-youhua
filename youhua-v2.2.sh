#!/bin/bash

#################################################
# 1GB VPS 完美优化脚本 v2.2 - 代理节点专用
# 修复: ZRAM 配置问题
# 目标: 极致速度 + 超低延迟 + 最大稳定性
# 适用: Ubuntu 20.04/22.04/24.04, Debian 11/12
# 特性: 不修改防火墙 | 不配置BBR | 修复DNS冲突
#################################################

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 辅助函数 ---
log_info() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_step() { echo -e "${CYAN}[➜]${NC} $1"; }

# 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
    log_error "必须使用 root 权限运行"
    exit 1
fi

# 备份函数
backup_config() {
    local file=$1
    [[ -f "$file" ]] && cp "$file" "${file}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null
}

# 检测系统信息
detect_system() {
    TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
    TOTAL_MEM_GB=$((TOTAL_MEM_MB / 1024))
    [[ $TOTAL_MEM_GB -eq 0 ]] && TOTAL_MEM_GB=1
    
    CPU_CORES=$(nproc)
    
    DISK_TYPE="未知"
    for disk in /sys/block/sd* /sys/block/vd* /sys/block/nvme*; do
        if [[ -e "$disk/queue/rotational" ]]; then
            [[ $(cat "$disk/queue/rotational") -eq 0 ]] && DISK_TYPE="SSD" || DISK_TYPE="HDD"
            break
        fi
    done
}

# ========================================
# 1. 内存极致优化 (ZRAM + Swap兜底) - 修复版
# ========================================
optimize_memory() {
    log_step "正在优化内存配置 (ZRAM + Swap)..."

    # 1.1 禁用 Zswap（避免冲突）
    if [[ -f /sys/module/zswap/parameters/enabled ]]; then
        echo N > /sys/module/zswap/parameters/enabled 2>/dev/null
    fi
    if [[ -f /etc/default/grub ]]; then
        backup_config "/etc/default/grub"
        sed -i 's/zswap.enabled=1/zswap.enabled=0/g' /etc/default/grub
        if ! grep -q "zswap.enabled=0" /etc/default/grub; then
            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/&zswap.enabled=0 /' /etc/default/grub
        fi
        update-grub >/dev/null 2>&1
    fi

    # 1.2 停止现有 ZRAM
    log_info "清理现有 ZRAM 配置..."
    systemctl stop zramswap 2>/dev/null || true
    systemctl stop zram-config 2>/dev/null || true
    swapoff /dev/zram* 2>/dev/null || true
    modprobe -r zram 2>/dev/null || true

    # 1.3 安装并配置 ZRAM
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq 2>/dev/null
    
    # 卸载旧版本
    apt-get remove --purge -y zram-config 2>/dev/null || true
    
    # 安装 zram-tools
    apt-get install -y zram-tools >/dev/null 2>&1

    # 根据内存大小智能配置 ZRAM
    if [[ $TOTAL_MEM_GB -eq 1 ]]; then
        ZRAM_SIZE=512  # 1GB VPS 用 512MB ZRAM
        ZRAM_PERCENT=50
        SWAP_SIZE="2G"
    elif [[ $TOTAL_MEM_GB -eq 2 ]]; then
        ZRAM_SIZE=1024
        ZRAM_PERCENT=50
        SWAP_SIZE="2G"
    else
        ZRAM_SIZE=2048
        ZRAM_PERCENT=50
        SWAP_SIZE="2G"
    fi

    # 创建 ZRAM 配置
    cat > /etc/default/zramswap <<EOF
# ZRAM 配置 - 使用百分比和大小混合模式
ALGO=zstd
PERCENT=${ZRAM_PERCENT}
SIZE=${ZRAM_SIZE}
PRIORITY=100
EOF
    
    log_info "ZRAM 配置: ${ZRAM_SIZE}MB, zstd 算法, 优先级 100"

    # 启动 ZRAM
    systemctl enable zramswap >/dev/null 2>&1
    systemctl restart zramswap
    
    sleep 2
    
    # 验证 ZRAM
    if lsblk | grep -q zram; then
        log_info "ZRAM 已启用"
    else
        log_warn "ZRAM 启动失败，尝试手动加载..."
        modprobe zram num_devices=1
        ZRAM_SIZE_BYTES=$((ZRAM_SIZE * 1024 * 1024))
        echo zstd > /sys/block/zram0/comp_algorithm 2>/dev/null
        echo $ZRAM_SIZE_BYTES > /sys/block/zram0/disksize 2>/dev/null
        mkswap /dev/zram0 >/dev/null 2>&1
        swapon -p 100 /dev/zram0 2>/dev/null
        
        if lsblk | grep -q zram; then
            log_info "ZRAM 手动加载成功"
        else
            log_error "ZRAM 无法启用，将依赖物理 Swap"
        fi
    fi

    # 1.4 创建物理 Swap 作为兜底
    if swapon --show 2>/dev/null | grep -q "/swapfile"; then
        log_info "检测到现有 Swap，重新配置..."
        swapoff /swapfile 2>/dev/null
        rm -f /swapfile
    fi
    
    log_info "创建 ${SWAP_SIZE} 物理 Swap 文件..."
    if fallocate -l $SWAP_SIZE /swapfile 2>/dev/null; then
        log_info "使用 fallocate 快速创建"
    else
        log_warn "fallocate 不支持，使用 dd（较慢）..."
        dd if=/dev/zero of=/swapfile bs=1M count=$((${SWAP_SIZE%G}*1024)) status=none 2>/dev/null
    fi
    
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
    swapon -p 10 /swapfile
    
    # 更新 fstab
    sed -i '/\/swapfile/d' /etc/fstab
    echo '/swapfile none swap sw,pri=10 0 0' >> /etc/fstab
    
    log_info "物理 Swap ${SWAP_SIZE} 已创建 (优先级 10)"
    
    # 1.5 创建启动自动加载脚本
    cat > /etc/rc.local <<'EOFRC'
#!/bin/bash
# 确保 ZRAM 在启动时正确加载
if ! lsblk | grep -q zram; then
    systemctl start zramswap 2>/dev/null || {
        modprobe zram num_devices=1
        echo zstd > /sys/block/zram0/comp_algorithm 2>/dev/null
        echo $((512 * 1024 * 1024)) > /sys/block/zram0/disksize 2>/dev/null
        mkswap /dev/zram0 >/dev/null 2>&1
        swapon -p 100 /dev/zram0 2>/dev/null
    }
fi
exit 0
EOFRC
    chmod +x /etc/rc.local 2>/dev/null
    
    log_info "内存架构优化完成 (ZRAM ${ZRAM_SIZE}MB + Swap ${SWAP_SIZE})"
}

# ========================================
# 2. 网络内核参数优化
# ========================================
optimize_network() {
    log_step "正在应用网络极限优化参数..."
    
    cat > /etc/sysctl.d/99-proxy-optimized.conf <<'EOF'
# ========================================
# 网络优化 - 1GB VPS 代理节点专用
# ========================================

# === 内存管理 ===
vm.swappiness=60
vm.vfs_cache_pressure=100
vm.dirty_ratio=15
vm.dirty_background_ratio=5
vm.overcommit_memory=1
vm.panic_on_oom=0
vm.min_free_kbytes=65536

# === TCP 缓冲区 (平衡值) ===
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.core.rmem_default=1048576
net.core.wmem_default=1048576
net.ipv4.tcp_rmem=4096 131072 134217728
net.ipv4.tcp_wmem=4096 131072 134217728

# UDP 优化 (SS/V2Ray)
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384

# === 连接队列 ===
net.core.netdev_max_backlog=32768
net.core.somaxconn=32768
net.ipv4.tcp_max_syn_backlog=16384

# === TCP 性能优化 ===
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_fin_timeout=10
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_max_tw_buckets=500000

# Keepalive 优化
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_keepalive_intvl=10

# === 协议优化 ===
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_moderate_rcvbuf=1

# === 低延迟优化 ===
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_autocorking=0

# === 端口范围 ===
net.ipv4.ip_local_port_range=10000 65535

# === 连接跟踪 ===
net.netfilter.nf_conntrack_max=1048576
net.netfilter.nf_conntrack_tcp_timeout_established=3600

# === IPv6 支持 ===
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0

# === 安全优化 ===
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
EOF

    sysctl -p /etc/sysctl.d/99-proxy-optimized.conf >/dev/null 2>&1
    log_info "网络参数已调优 (TCP 缓冲区: 128MB)"
}

# ========================================
# 3. 系统资源限制
# ========================================
optimize_limits() {
    log_step "提升系统资源限制..."
    
    backup_config "/etc/security/limits.conf"
    
    cat >> /etc/security/limits.conf <<EOF

# VPS 优化 - 资源限制
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 655350
* hard nproc 655350
root soft nofile 1048576
root hard nofile 1048576
EOF

    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/limits.conf <<EOF
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=655350
EOF
    
    cat > /etc/sysctl.d/50-limits.conf <<EOF
fs.file-max=2097152
fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=524288
EOF
    
    sysctl -p /etc/sysctl.d/50-limits.conf >/dev/null 2>&1
    systemctl daemon-reexec 2>/dev/null
    log_info "资源限制已提升 (文件描述符: 1,048,576)"
}

# ========================================
# 4. 垃圾清理与服务精简
# ========================================
clean_bloatware() {
    log_step "执行系统瘦身..."

    # 移除 Snapd
    if command -v snap >/dev/null 2>&1; then
        log_info "移除 Snapd..."
        systemctl stop snapd.socket snapd >/dev/null 2>&1
        apt-get purge -y snapd >/dev/null 2>&1
        rm -rf /var/cache/snapd/ ~/snap /snap 2>/dev/null
    fi

    # 禁用不必要的服务
    local services="oracle-cloud-agent exim4 postfix ModemManager bluetooth cups apport"
    for svc in $services; do
        if systemctl is-active --quiet $svc 2>/dev/null || systemctl is-enabled --quiet $svc 2>/dev/null; then
            systemctl stop $svc >/dev/null 2>&1
            systemctl disable $svc >/dev/null 2>&1
            systemctl mask $svc >/dev/null 2>&1
        fi
    done
    
    # 清理包和缓存
    apt-get autoremove --purge -y >/dev/null 2>&1
    apt-get clean >/dev/null 2>&1
    journalctl --vacuum-time=3d >/dev/null 2>&1
    
    # 限制日志大小
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/size.conf <<EOF
[Journal]
SystemMaxUse=100M
SystemMaxFileSize=10M
RuntimeMaxUse=50M
EOF
    systemctl restart systemd-journald 2>/dev/null

    log_info "系统瘦身完成"
}

# ========================================
# 5. DNS 优化 (修复端口冲突)
# ========================================
optimize_dns() {
    log_step "配置 DNS (替换 systemd-resolved)..."

    # 5.1 停用 systemd-resolved（释放 53 端口）
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        log_info "停用 systemd-resolved 以释放 53 端口..."
        systemctl stop systemd-resolved
        systemctl disable systemd-resolved >/dev/null 2>&1
        systemctl mask systemd-resolved >/dev/null 2>&1
    fi

    # 5.2 删除旧的 resolv.conf
    chattr -i /etc/resolv.conf 2>/dev/null
    [[ -L /etc/resolv.conf ]] || [[ -f /etc/resolv.conf ]] && \
        cp /etc/resolv.conf /etc/resolv.conf.bak.sys 2>/dev/null
    rm -f /etc/resolv.conf

    # 5.3 创建临时 DNS
    cat > /etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
options timeout:2 attempts:2 rotate edns0
EOF

    # 5.4 安装 dnsmasq
    if ! command -v dnsmasq &>/dev/null; then
        apt-get update -qq 2>/dev/null
        apt-get install -y dnsmasq >/dev/null 2>&1
    fi

    # 5.5 配置 dnsmasq
    backup_config "/etc/dnsmasq.conf"
    
    cat > /etc/dnsmasq.d/proxy-opt.conf <<EOF
# 监听配置
listen-address=127.0.0.1
bind-interfaces
no-dhcp-interface=

# 缓存配置
cache-size=10000
min-cache-ttl=3600
max-cache-ttl=86400
neg-ttl=60

# 上游 DNS
no-resolv
server=1.1.1.1
server=1.0.0.1
server=8.8.8.8
server=8.8.4.4
server=2606:4700:4700::1111
server=2606:4700:4700::1001
EOF

    # 5.6 确保 53 端口空闲
    fuser -k 53/tcp 53/udp >/dev/null 2>&1

    # 5.7 重启 dnsmasq
    if systemctl restart dnsmasq 2>/dev/null; then
        systemctl enable dnsmasq >/dev/null 2>&1
        
        # 5.8 指向本地 dnsmasq
        echo "nameserver 127.0.0.1" > /etc/resolv.conf
        chattr +i /etc/resolv.conf 2>/dev/null
        
        log_info "DNS 优化成功 (本地缓存 10000 条)"
    else
        log_warn "dnsmasq 启动失败，回滚 DNS 配置..."
        chattr -i /etc/resolv.conf 2>/dev/null
        cat > /etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
    fi
}

# ========================================
# 6. 磁盘 I/O 优化
# ========================================
optimize_io() {
    log_step "优化磁盘 I/O 调度器..."
    
    local optimized=0
    for disk in /sys/block/sd* /sys/block/vd* /sys/block/nvme*n*; do
        [[ ! -e "$disk" ]] && continue
        [[ $(basename "$disk") =~ nvme.*p ]] && continue
        
        local disk_name=$(basename "$disk")
        
        if [[ -f "$disk/queue/rotational" ]] && [[ $(cat "$disk/queue/rotational") -eq 0 ]]; then
            echo "none" > "$disk/queue/scheduler" 2>/dev/null || \
                echo "mq-deadline" > "$disk/queue/scheduler" 2>/dev/null
            echo 0 > "$disk/queue/read_ahead_kb" 2>/dev/null
            log_info "SSD $disk_name: none 调度器"
        else
            echo "mq-deadline" > "$disk/queue/scheduler" 2>/dev/null
            echo 512 > "$disk/queue/read_ahead_kb" 2>/dev/null
            log_info "HDD $disk_name: mq-deadline 调度器"
        fi
        
        echo 256 > "$disk/queue/nr_requests" 2>/dev/null
        echo 2 > "$disk/queue/rq_affinity" 2>/dev/null
        optimized=1
    done
    
    [[ $optimized -eq 0 ]] && log_warn "未找到可优化的磁盘"
}

# ========================================
# 7. 时间同步优化
# ========================================
optimize_time() {
    log_step "配置高精度时间同步..."
    
    if ! command -v chrony &>/dev/null; then
        apt-get install -y chrony >/dev/null 2>&1
    fi
    
    backup_config "/etc/chrony/chrony.conf"
    
    cat > /etc/chrony/chrony.conf <<EOF
server time.cloudflare.com iburst
server time.google.com iburst
server ntp.ubuntu.com iburst

makestep 1 3
rtcsync

driftfile /var/lib/chrony/drift
logdir /var/log/chrony
maxupdateskew 100.0
EOF
    
    systemctl restart chrony 2>/dev/null
    systemctl enable chrony >/dev/null 2>&1
    log_info "时间同步已启用"
}

# ========================================
# 8. 网络接口优化
# ========================================
optimize_network_interface() {
    log_step "优化网络接口..."
    
    NET_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    
    if [[ -n "$NET_INTERFACE" ]]; then
        ethtool -G "$NET_INTERFACE" rx 4096 tx 4096 2>/dev/null && \
            log_info "网卡队列已优化" || true
        
        ethtool -K "$NET_INTERFACE" tso off gso off 2>/dev/null && \
            log_info "TSO/GSO 已禁用" || true
        
        ethtool -K "$NET_INTERFACE" gro on 2>/dev/null || true
        ethtool -C "$NET_INTERFACE" rx-usecs 0 tx-usecs 0 2>/dev/null || true
    else
        log_warn "未检测到网络接口"
    fi
}

# ========================================
# 9. 安装监控工具
# ========================================
install_tools() {
    log_step "安装监控工具..."
    
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq 2>/dev/null
    apt-get install -y htop iftop vnstat nethogs curl wget >/dev/null 2>&1
    
    systemctl enable vnstat >/dev/null 2>&1
    systemctl start vnstat 2>/dev/null
    
    log_info "监控工具已安装 (htop, iftop, vnstat, nethogs)"
}

# ========================================
# 10. 创建状态检查脚本
# ========================================
create_status_script() {
    cat > /usr/local/bin/vps-status <<'EOF'
#!/bin/bash
G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; NC='\033[0m'

clear
echo -e "${B}════════════════════════════════════════════════════${NC}"
echo -e "${B}           VPS 性能状态监控 v2.2${NC}"
echo -e "${B}════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${G}=== 系统信息 ===${NC}"
echo "系统: $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)"
echo "运行: $(uptime -p)"
echo ""

echo -e "${G}=== 内存状态 (ZRAM + Swap) ===${NC}"
free -h
echo ""

echo -e "${G}=== Swap 设备详情 ===${NC}"
swapon --show 2>/dev/null || echo "无 swap"
echo ""

echo -e "${G}=== ZRAM 设备 ===${NC}"
lsblk | grep -E "NAME|zram" || echo "ZRAM 未启用"
echo ""

echo -e "${G}=== DNS 监听状态 ===${NC}"
if systemctl is-active --quiet dnsmasq; then
    echo "✓ dnsmasq 运行中"
    ss -ulpn 2>/dev/null | grep :53 || echo "端口 53 未监听"
else
    echo "✗ dnsmasq 未运行"
fi
echo ""

echo -e "${G}=== 网络参数 ===${NC}"
echo "TCP 缓冲区: $(sysctl -n net.ipv4.tcp_rmem | awk '{printf "%.0fMB", $3/1024/1024}')"
echo "连接队列: $(sysctl -n net.core.somaxconn)"
echo "Swappiness: $(sysctl -n vm.swappiness)"
echo ""

echo -e "${G}=== TCP 连接数 ===${NC}"
ss -s 2>/dev/null | head -5
echo ""

echo -e "${G}=== 资源限制 ===${NC}"
echo "文件描述符: $(ulimit -n)"
echo "进程数: $(ulimit -u)"
echo ""

echo -e "${G}=== 负载情况 ===${NC}"
uptime
echo ""

echo -e "${G}=== 磁盘使用 ===${NC}"
df -h / | tail -1
echo ""

# 计算总可用内存
PHYSICAL_MEM=$(free -h | awk '/^Mem:/{print $2}')
TOTAL_SWAP=$(free -h | awk '/^Swap:/{print $2}')
echo -e "${G}=== 总可用内存 ===${NC}"
echo "物理内存: $PHYSICAL_MEM"
echo "虚拟内存: $TOTAL_SWAP"
echo ""

echo -e "${B}════════════════════════════════════════════════════${NC}"
echo -e "${Y}监控命令: htop | iftop | vnstat | nethogs${NC}"
echo -e "${B}════════════════════════════════════════════════════${NC}"
EOF
    
    chmod +x /usr/local/bin/vps-status
    log_info "状态脚本已创建: vps-status"
}

# ========================================
# 主逻辑
# ========================================
main() {
    clear
    detect_system
    
    echo "==========================================================="
    echo -e "${GREEN} VPS 完美优化脚本 v2.2 (ZRAM 修复版) ${NC}"
    echo "==========================================================="
    echo ""
    echo -e "${BLUE}检测信息:${NC}"
    echo "  • 系统: $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)"
    echo "  • 内存: ${TOTAL_MEM_GB}GB (${TOTAL_MEM_MB}MB)"
    echo "  • CPU: ${CPU_CORES} 核心"
    echo "  • 磁盘: ${DISK_TYPE}"
    echo ""
    echo -e "${YELLOW}[!] 警告: 本脚本将进行激进的内存和网络优化${NC}"
    echo -e "${YELLOW}[!] 不会修改防火墙，不会修改 BBR${NC}"
    echo ""

    if [[ -t 0 ]]; then
        read -p "是否继续? (y/n): " confirm
    else
        confirm="y"
    fi

    if [[ "$confirm" != "y" ]]; then
        echo "已取消"
        exit 0
    fi

    echo ""
    log_step "开始优化..."
    echo ""

    clean_bloatware
    optimize_memory
    optimize_network
    optimize_limits
    optimize_dns
    optimize_io
    optimize_time
    optimize_network_interface
    install_tools
    create_status_script
    
    echo ""
    echo "==========================================================="
    echo -e "${GREEN} 🚀 优化完成！${NC}"
    echo "==========================================================="
    echo ""
    echo -e "${GREEN}优化内容:${NC}"
    echo "  ✓ ZRAM (${ZRAM_SIZE}MB) + Swap (${SWAP_SIZE})"
    echo "  ✓ 网络参数 (TCP 缓冲区: 128MB, 队列: 32768)"
    echo "  ✓ 资源限制 (文件描述符: 1,048,576)"
    echo "  ✓ DNS 缓存 (dnsmasq, 10000 条)"
    echo "  ✓ 磁盘 I/O ($DISK_TYPE 优化)"
    echo "  ✓ 时间同步 (chrony)"
    echo ""
    echo -e "${BLUE}当前 Swap 状态:${NC}"
    swapon --show
    echo ""
    echo -e "${BLUE}当前内存状态:${NC}"
    free -h
    echo ""
    echo -e "${YELLOW}重要提示:${NC}"
    echo "  1. ${RED}建议立即重启${NC} VPS 使所有配置生效"
    echo "  2. 重启后运行 ${CYAN}vps-status${NC} 查看完整状态"
    echo "  3. BBR 需手动配置 (未包含在此脚本中)"
    echo ""
    echo -e "${CYAN}输入 reboot 重启系统${NC}"
    echo ""
}

main "$@"
