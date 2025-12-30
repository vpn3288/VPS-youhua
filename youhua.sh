#!/bin/bash

#################################################
# 1GB VPS 极致优化脚本 - 代理节点专用 (DNS修复版)
# 目标: 极致速度 + 超低延迟 + 最大稳定性
# 适用: Ubuntu 20.04/22.04/24.04, Debian 11/12
# 修复: 解决 Ubuntu 24.04 systemd-resolved 端口冲突
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
    if [[ -f "$file" ]]; then
        cp "$file" "${file}.bak.$(date +%Y%m%d_%H%M%S)"
    fi
}

# ========================================
# 1. 内存极致优化 (ZRAM + Swap兜底)
# ========================================
optimize_memory() {
    log_step "正在优化内存配置 (ZRAM + Swap)..."

    # 1.1 禁用 Zswap
    if [[ -f /sys/module/zswap/parameters/enabled ]]; then
        echo N > /sys/module/zswap/parameters/enabled
    fi
    if [[ -f /etc/default/grub ]]; then
        backup_config "/etc/default/grub"
        sed -i 's/zswap.enabled=1/zswap.enabled=0/g' /etc/default/grub
        if ! grep -q "zswap.enabled=0" /etc/default/grub; then
            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/&zswap.enabled=0 /' /etc/default/grub
        fi
        update-grub >/dev/null 2>&1
    fi

    # 1.2 配置 ZRAM
    apt-get update -qq
    apt-get install -y zram-tools >/dev/null 2>&1

    cat > /etc/default/zramswap <<EOF
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
    systemctl restart zramswap >/dev/null 2>&1
    log_info "ZRAM 已启用 (zstd 算法)"

    # 1.3 创建物理 Swap 作为兜底 (1.5GB)
    if ! swapon --show | grep -q "/swapfile"; then
        log_info "创建 1.5GB 物理 Swap 文件..."
        fallocate -l 1.5G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1536 status=none
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    log_info "内存架构优化完成"
}

# ========================================
# 2. 网络内核参数优化
# ========================================
optimize_network() {
    log_step "正在应用网络极限优化参数..."
    
    cat > /etc/sysctl.d/99-proxy-optimized.conf <<'EOF'
# === 内存管理 ===
vm.swappiness=60
vm.vfs_cache_pressure=100
vm.overcommit_memory=1
vm.panic_on_oom=0

# === TCP 连接与缓冲区 (1GB内存安全值) ===
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=262144
net.core.wmem_default=262144
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192

# === 连接队列 ===
net.core.netdev_max_backlog=10000
net.core.somaxconn=8192
net.ipv4.tcp_max_syn_backlog=4096
net.ipv4.tcp_max_tw_buckets=50000

# === TCP 握手与超时 ===
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_keepalive_intvl=15

# === 协议优化 ===
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_no_metrics_save=1
net.ipv4.ip_local_port_range=10000 65535
EOF

    sysctl -p /etc/sysctl.d/99-proxy-optimized.conf >/dev/null 2>&1
    log_info "网络参数已调优"
}

# ========================================
# 3. 系统资源限制
# ========================================
optimize_limits() {
    log_step "提升系统资源限制..."
    
    cat > /etc/security/limits.conf <<EOF
* soft nofile 1000000
* hard nofile 1000000
* soft nproc 50000
* hard nproc 50000
root soft nofile 1000000
root hard nofile 1000000
EOF

    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/limits.conf <<EOF
[Manager]
DefaultLimitNOFILE=1000000
DefaultLimitNPROC=50000
EOF
    
    systemctl daemon-reexec
    log_info "资源限制已提升"
}

# ========================================
# 4. 垃圾清理与服务精简
# ========================================
clean_bloatware() {
    log_step "执行系统瘦身..."

    # 针对 Ubuntu 24.04 的 Snapd 移除
    if command -v snap >/dev/null; then
        log_info "移除 Snapd..."
        systemctl stop snapd.socket >/dev/null 2>&1
        systemctl stop snapd >/dev/null 2>&1
        apt-get purge -y snapd >/dev/null 2>&1
        rm -rf /var/cache/snapd/ ~/snap
    fi

    if systemctl is-active --quiet oracle-cloud-agent; then
        systemctl stop oracle-cloud-agent
        systemctl disable oracle-cloud-agent
        apt-get purge -y oracle-cloud-agent >/dev/null 2>&1
    fi

    systemctl stop exim4 >/dev/null 2>&1 && systemctl disable exim4 >/dev/null 2>&1
    systemctl stop postfix >/dev/null 2>&1 && systemctl disable postfix >/dev/null 2>&1
    
    apt-get autoremove --purge -y >/dev/null 2>&1
    apt-get clean >/dev/null 2>&1
    
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/size.conf <<EOF
[Journal]
SystemMaxUse=100M
RuntimeMaxUse=50M
EOF
    systemctl restart systemd-journald

    log_info "系统瘦身完成"
}

# ========================================
# 5. DNS 优化 (已修复端口冲突)
# ========================================
optimize_dns() {
    log_step "配置 DNS (替换 systemd-resolved)..."

    # 5.1 停用 systemd-resolved (它占用了 53 端口)
    if systemctl is-active --quiet systemd-resolved; then
        log_info "检测到 systemd-resolved，正在停用以释放 53 端口..."
        systemctl stop systemd-resolved
        systemctl disable systemd-resolved >/dev/null 2>&1
    fi

    # 5.2 备份并删除原 resolv.conf (通常是软链接)
    if [[ -L /etc/resolv.conf ]] || [[ -f /etc/resolv.conf ]]; then
        cp /etc/resolv.conf /etc/resolv.conf.bak.sys
        rm -f /etc/resolv.conf
    fi

    # 5.3 创建临时的 resolv.conf 以便能够下载包
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf

    # 5.4 安装 dnsmasq
    if ! command -v dnsmasq &>/dev/null; then
        apt-get update -qq
        apt-get install -y dnsmasq >/dev/null 2>&1
    fi

    # 5.5 配置 dnsmasq
    cat > /etc/dnsmasq.d/proxy-opt.conf <<EOF
# 监听地址
listen-address=127.0.0.1
bind-interfaces
# 缓存配置
cache-size=10000
min-cache-ttl=3600
# 上游 DNS
server=1.1.1.1
server=8.8.8.8
server=2606:4700:4700::1111
EOF

    # 5.6 确保没有其他进程占用 53 端口
    fuser -k 53/tcp >/dev/null 2>&1
    fuser -k 53/udp >/dev/null 2>&1

    # 5.7 重启 dnsmasq
    systemctl restart dnsmasq
    systemctl enable dnsmasq >/dev/null 2>&1

    # 5.8 将系统 DNS 指向本地 dnsmasq
    # 锁定文件防止被其他程序覆盖
    chattr -i /etc/resolv.conf 2>/dev/null
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null

    # 5.9 验证是否启动成功
    if systemctl is-active --quiet dnsmasq; then
        log_info "DNS 优化成功 (已接管 53 端口)"
    else
        log_warn "DNSmasq 启动失败，正在回滚 DNS 设置..."
        chattr -i /etc/resolv.conf 2>/dev/null
        echo "nameserver 1.1.1.1" > /etc/resolv.conf
        echo "nameserver 8.8.8.8" >> /etc/resolv.conf
    fi
}

# ========================================
# 6. 时间同步
# ========================================
optimize_time() {
    log_step "配置时间同步..."
    apt-get install -y chrony >/dev/null 2>&1
    systemctl enable chrony >/dev/null 2>&1
    systemctl restart chrony
    log_info "时间同步已启用"
}

# ========================================
# 7. 磁盘 I/O 优化
# ========================================
optimize_io() {
    log_step "优化 I/O 调度器..."
    for disk in /sys/block/sd* /sys/block/vd* /sys/block/nvme*; do
        if [[ -w "$disk/queue/scheduler" ]]; then
            echo "none" > "$disk/queue/scheduler" 2>/dev/null || echo "mq-deadline" > "$disk/queue/scheduler" 2>/dev/null
        fi
        if [[ -w "$disk/queue/nr_requests" ]]; then
             echo 256 > "$disk/queue/nr_requests" 2>/dev/null
        fi
    done
    log_info "I/O 调度器已优化"
}

# ========================================
# 主逻辑
# ========================================
main() {
    clear
    echo -e "==========================================================="
    echo -e "${GREEN} 1GB VPS 极限优化脚本 (代理专用 | 无BBR版) ${NC}"
    echo -e "${YELLOW} 系统: $(grep -oP 'PRETTY_NAME="\K[^"]+' /etc/os-release) ${NC}"
    echo -e "==========================================================="
    echo ""
    echo -e "${YELLOW}[!] 警告: 本脚本将进行激进的内存和网络修改。${NC}"
    echo -e "${YELLOW}[!] 不会修改防火墙，不会修改 BBR。${NC}"
    echo ""

    if [[ -c /dev/tty ]]; then
        read -p "是否继续? (y/n): " confirm < /dev/tty
    else
        read -p "是否继续? (y/n): " confirm
    fi

    if [[ "$confirm" != "y" ]]; then
        echo "已取消。"
        exit 0
    fi

    # 执行优化
    clean_bloatware
    optimize_memory
    optimize_network
    optimize_limits
    optimize_dns
    optimize_time
    optimize_io
    
    # 状态检查脚本
    cat > /usr/local/bin/vps-status <<'EOF'
#!/bin/bash
clear
echo "=== 内存状态 (ZRAM + Swap) ==="
free -h
echo ""
echo "=== DNS 监听状态 ==="
ss -ulpn | grep :53
echo ""
echo "=== TCP 连接数 ==="
ss -s
echo ""
echo "=== 负载情况 ==="
uptime
EOF
    chmod +x /usr/local/bin/vps-status

    echo ""
    echo -e "==========================================================="
    echo -e "${GREEN} 🚀 优化完成! ${NC}"
    echo -e "==========================================================="
    echo -e "建议立即重启 VPS 以使所有配置生效。"
    echo -e "输入 ${CYAN}reboot${NC} 重启。"
    echo -e "重启后输入 ${CYAN}vps-status${NC} 查看状态。"
    echo ""
}

main "$@"
