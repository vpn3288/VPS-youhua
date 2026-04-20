#!/bin/bash
#
# 修复: 非交互式环境(如SSH远程执行)需要 TERM 变量
: "${TERM:=xterm}"
# VPS 优化脚本 - Oracle Cloud ARM (1核4G)
#
# 用法:
#   sudo bash oracle-1c4g.sh                    # 完整安装（底层优化 + 软件依赖）
#   sudo bash oracle-1c4g.sh --optimize-only    # 仅底层优化
#   sudo bash oracle-1c4g.sh --uninstall        # 卸载所有优化
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
# Oracle Cloud ARM 1核4G 专用优化安装脚本 v3.4
# 硬件: Ampere Altra, 1核 4GB, Oracle Cloud
# 特点: Oracle Cloud 专属优化（禁用 cloud-agent，元数据检查）
#       针对 1C4G 资源精简优化（比 2C16G 更保守）
# =============================================================================
#
# 一键运行: bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/oracle-1c4g.sh)
#
# 模式说明:
#   --optimize-only   纯环境优化（不安装 Docker/Node.js）
#   --uninstall       卸载所有优化配置
#

# ─────────────────────────────────────────────────────────────────────────────
# 平台信息
# ─────────────────────────────────────────────────────────────────────────────
readonly PLATFORM_NAME="Oracle Cloud ARM (1核4G)"
readonly PLATFORM_DESC="Ampere Altra ($(awk '/MemTotal/{printf "%.0fGB", $2/1024/1024}' /proc/meminfo), Oracle Cloud 1核精选)"

# ─────────────────────────────────────────────────────────────────────────────
# 平台差异变量（Oracle ARM 1C4G 专项，比 2C16G 更保守）
# ─────────────────────────────────────────────────────────────────────────────
readonly SYSCTL_FILE="/etc/sysctl.d/99-vps-youhua-oracle-1c4g.conf"
# journald persistent for cloud server
readonly JOURNALD_STORAGE="persistent"
readonly JOURNALD_MAX_USE="100M"
readonly TMPFS_SIZE="256M"

# Oracle Cloud 1C4G TCP 缓冲（内存 4%，上限 16MB，下限 4MB）
# 内存 4% 自适应（1C4G proxy 专用，省内存+够用）
# BUG FIX: 原公式单位混滑（KB级cap/floor应用于KB结果再*1024），改为字节级正确计算
TCP_BUF_MAX=$(awk '/MemTotal/{m=$2*1024; buf=m*4/100; if(buf>16777216) buf=16777216; if(buf<4194304) buf=4194304; printf "%.0f", buf}' /proc/meminfo)
readonly TCP_BUF_MAX
readonly CT_MAX=8192  # 1C4G 精简资源限制
readonly SOMAXCONN=1024
readonly NETDEV_BACKLOG=4096
readonly SWAPPINESS=10
readonly MIN_FREE_KB=16384

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
    if [[ -f /tmp/vps-youhua-tmp/common-optimize.sh ]]; then
        source /tmp/vps-youhua-tmp/common-optimize.sh
        return 0
    fi
    if [[ -f /tmp/vps-youhua/common-optimize.sh ]]; then
        source /tmp/vps-youhua/common-optimize.sh
        return 0
    fi
    
    # 下载到临时目录（SHA256 完整性验证 + 降级 fallback）
    local tmpdir="/tmp/vps-youhua"
    mkdir -p "$tmpdir"
    echo -e "\033[36m[➜] 下载 common-optimize.sh...\033[0m"

    local dest="${tmpdir}/common-optimize.sh"
    local sha256_expected="26b2fe9227954fae688d60da54046fbaae34c09fddd47084d715e5b72d95f3a8"
    local sha256_actual=""

    # 主站下载（带 SHA256 验证）
    if curl -fsSL "$COMMON_OPTIMIZE_URL" -o "$dest" 2>/dev/null; then
        sha256_actual=$(sha256sum "$dest" 2>/dev/null | awk '{print $1}' || echo "")
        if [[ -n "$sha256_actual" && "$sha256_actual" == "$sha256_expected" ]]; then
            source "$dest"
            return 0
        else
            echo -e "\033[33m[!] SHA256 校验失败（预期: ${sha256_expected:0:16}...，实际: ${sha256_actual:0:16}...），尝试备用源...\033[0m" >&2
            rm -f "$dest"
        fi
    fi

    # Fallback: GitHub raw CDN（带 SHA256 验证）
    local fallback_url="https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/common-optimize.sh"
    if curl -fsSL "$fallback_url" -o "$dest" 2>/dev/null; then
        sha256_actual=$(sha256sum "$dest" 2>/dev/null | awk '{print $1}' || echo "")
        if [[ -n "$sha256_actual" && "$sha256_actual" == "$sha256_expected" ]]; then
            source "$dest"
            return 0
        else
            echo -e "\033[31m[✗] 错误: common-optimize.sh SHA256 校验失败\033[0m" >&2
            rm -f "$dest"
            exit 1
        fi
    fi

    echo -e "\033[31m[✗] 错误: 无法下载 common-optimize.sh（主站和备用源均失败）\033[0m" >&2
    exit 1
}

load_common_optimize

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
    for svc in oracle-cloud-agent oracle-cloud-agent-updater; do
        if systemctl is-active "$svc" &>/dev/null; then
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
            log_info "已停止并禁用 $svc"
        fi
    done

    # 屏蔽服务防止恢复
    for svc in oracle-cloud-agent oracle-cloud-agent-updater; do
        systemctl mask "$svc" 2>/dev/null || true
    done

    log_info "Oracle Cloud 监控组件已清理"
}

# ─────────────────────────────────────────────────────────────────────────────
# 内存优化（1C4G 精简版）
# ─────────────────────────────────────────────────────────────────────────────
optimize_memory_oracle() {
    log_step "配置内存优化..."

    # 透明大页（1C4G 建议开启，对数据库/容器友好）
    echo "always" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    echo "never"  > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

    # zram 保留（1C4G 开启 zram，内存压缩比 2:1，等效扩展内存）
    # AUDIT-5 FIX: 添加 zram 设备存在性和激活状态检查
    if [[ -b /dev/zram0 ]] && [[ -f /sys/block/zram0/comp_algorithm ]]; then
        # 检查 zram0 是否已激活
        if swapon -s | grep -q "/dev/zram0" 2>/dev/null; then
            log_info "zram0 已激活，跳过配置"
        else
            # 检查 disksize 是否已设置
            local current_disksize
            current_disksize=$(cat /sys/block/zram0/disksize 2>/dev/null || echo "0")
            if [[ "$current_disksize" != "0" ]]; then
                log_info "zram0 disksize 已设置，跳过配置"
            else
                echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
                local mem_kb
                mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
                local zram_size=$((mem_kb * 1024))  # zram 1:1 匹配 RAM（字节）
                if [[ -f /sys/block/zram0/disksize ]]; then
                    echo "${zram_size}" > /sys/block/zram0/disksize 2>/dev/null || true
                    mkswap /dev/zram0 >/dev/null 2>&1 || true
                    swapon /dev/zram0 -p 32767 2>/dev/null || true
                    log_info "zram 开启，压缩后约等效 $((mem_kb * 2 / 1024))MB 可用内存"
                fi
            fi
        fi
    else
        log_info "zram0 设备不存在或不支持，跳过 zram 配置"
    fi

    # TCP 缓冲（已在顶部常量定义）
    log_info "TCP 缓冲上限: $(numfmt --to=iec-i --suffix=B $TCP_BUF_MAX 2>/dev/null || echo "${TCP_BUF_MAX} bytes")"

    sysctl -w vm.swappiness=$SWAPPINESS 2>/dev/null || true
    sysctl -w vm.oom_kill_allocating_task=1 2>/dev/null || true
    log_info "内存优化完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# sysctl Oracle Cloud 1C4G 专项配置
# ─────────────────────────────────────────────────────────────────────────────

configure_sysctl_oracle() {
    log_step "配置 sysctl 系统参数..."

    backup_file "$SYSCTL_FILE"
    write_common_sysctl "$SYSCTL_FILE"

    cat >> "$SYSCTL_FILE" <<EOF
# ─────────────────────────────────────────────────────────────────────────────
# VPS-youhua Oracle Cloud ARM 1C4G sysctl 配置
# 平台: Oracle Cloud 1核 4GB AMPERE ALTA
# ─────────────────────────────────────────────────────────────────────────────

# ── 内存 ────────────────────────────────────────────────────────────────────
vm.swappiness = ${SWAPPINESS}
vm.min_free_kbytes = ${MIN_FREE_KB}
vm.vfs_cache_pressure = 50
vm.oom_kill_allocating_task = 1
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
# 1C4G 低核省IO
vm.dirty_writeback_centisecs = 3000
vm.dirty_expire_centisecs = 30000

# ── 网络（Oracle Cloud 1C4G 精简）──────────────────────────────────────────
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}
net.core.somaxconn = ${SOMAXCONN}
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_tw_reuse = 1
# SYN cookies for DDoS protection on proxy servers
net.ipv4.tcp_syncookies = 1

# ── conntrack（1C4G 资源有限，保持较小）─────────────────────────────────────
net.netfilter.nf_conntrack_max = ${CT_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 1800
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30

# ── TCP 缓冲（内存 4%，自适应）───────────────────────────────────────────────
net.core.rmem_max = ${TCP_BUF_MAX}
net.core.wmem_max = ${TCP_BUF_MAX}
net.ipv4.tcp_rmem = 4096 262144 ${TCP_BUF_MAX}
net.ipv4.tcp_wmem = 4096 262144 ${TCP_BUF_MAX}
# tcp_mem auto-tuned by kernel based on total RAM

# ── 本地端口范围 ─────────────────────────────────────────────────────────────
net.ipv4.ip_local_port_range = 10240 65535

# ── ICMP ────────────────────────────────────────────────────────────────────
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# ── ARP ─────────────────────────────────────────────────────────────────────
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
EOF

    # 应用 sysctl 配置
    if sysctl -p "$SYSCTL_FILE" 2>&1 | grep -v "^$" | head -5; then
        log_info "sysctl 参数已应用（$SYSCTL_FILE）"
    else
        log_warn "sysctl 部分参数不支持当前内核（可忽略）"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# CRITICAL FIX: 设置 nf_conntrack_hashsize（只读参数，不能通过 sysctl）
# ─────────────────────────────────────────────────────────────────────────────
configure_conntrack_hashsize() {
    log_step "配置 nf_conntrack_hashsize..."
    
    # 加载 nf_conntrack 模块
    modprobe nf_conntrack 2>/dev/null || true
    
    local hashsize_file="/sys/module/nf_conntrack/parameters/hashsize"
    if [[ -f "$hashsize_file" ]]; then
        local hashsize=$((CT_MAX / 4))
        echo "$hashsize" > "$hashsize_file" 2>/dev/null || {
            log_warn "nf_conntrack_hashsize 设置失败，写入 modprobe 配置（下次启动生效）"
            # 备用方案：通过 modprobe 配置（下次启动或模块重载时生效）
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
# Oracle Cloud 网络优化（RPS 单核简化版）
# ─────────────────────────────────────────────────────────────────────────────
optimize_network_oracle() {
    log_step "优化 Oracle Cloud 网络..."

    # Oracle Cloud MTU 检测（不强制修改）
    local mtu
    mtu=$(ip link show $(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}') 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1); exit}' || echo "1500")
    log_info "当前网卡 MTU: $mtu"

    for iface in /sys/class/net/en* /sys/class/net/eth*; do
        [[ -d "$iface" ]] || continue
        local name; name=$(basename "$iface")

        ethtool -K "$name" tso on 2>/dev/null || true
        ethtool -K "$name" gso on 2>/dev/null || true
        ethtool -K "$name" gro on 2>/dev/null || true
        ip link set "$name" txqueuelen 10000 2>/dev/null || true

        # RPS（多核时启用，单核跳过）
        # M2 FIX: 限制为 63 核防止 bitmask 溢出（bash 算术溢出）
        if [[ $SYS_CPU_CORES -gt 1 ]]; then
            local cores=$SYS_CPU_CORES
            [[ $cores -gt 63 ]] && cores=63
            if [[ $cores -gt 0 ]]; then
                local mask
                if [[ $cores -eq 63 ]]; then
                    # 63 核: 0x7fffffffffffffff（避免 1<<63 溢出）
                    mask="7fffffffffffffff"
                else
                    mask=$(printf '%x' $(( (1 << cores) - 1 )))
                fi
                for rps_file in /sys/class/net/${name}/queues/rx-*/rps_cpus; do
                    [[ -f "$rps_file" ]] || continue
                    printf "%s" "$mask" > "$rps_file" 2>/dev/null || true
                done
            fi
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
    log_step "配置 journald 日志..."
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-vps-youhua.conf <<EOF
[Journal]
Storage=${JOURNALD_STORAGE}
SystemMaxUse=${JOURNALD_MAX_USE}
SystemMaxFileSize=20M
MaxRetentionSec=7day
Compress=yes
EOF
    systemctl restart systemd-journald 2>/dev/null || true
    log_info "journald 已配置（${JOURNALD_STORAGE}，上限 ${JOURNALD_MAX_USE}）"
}

# ─────────────────────────────────────────────────────────────────────────────
# 清理定时任务
# ─────────────────────────────────────────────────────────────────────────────
configure_cleanup_cron() {
    log_step "配置定时清理..."
    mkdir -p /etc/cron.daily
    cat > /etc/cron.daily/vps-youhua-clean <<'EOF'
#!/bin/sh
# 每日清理：日志/缓存/临时文件（1C4G 精简版）
journalctl --vacuum-time=3d 2>/dev/null || true
apt-get clean 2>/dev/null || true
rm -rf /tmp/pear 2>/dev/null || true
rm -rf /var/cache/apt/archives/*.deb 2>/dev/null || true
EOF
    chmod +x /etc/cron.daily/vps-youhua-clean
    log_info "每日清理任务已配置"
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
# /tmp tmpfs
# ─────────────────────────────────────────────────────────────────────────────
configure_tmp_tmpfs() {
    log_step "配置 /tmp tmpfs..."
    if mount | grep -q "tmpfs on /tmp"; then
        log_info "/tmp 已是 tmpfs，跳过"
        return 0
    fi
    mkdir -p /tmp
    # H5 FIX: 仅在 mount 成功时才写入 fstab
    if mount -t tmpfs -o size=${TMPFS_SIZE},mode=1777,nosuid,nodev tmpfs /tmp 2>/dev/null; then
        if ! grep -q "tmpfs /tmp" /etc/fstab 2>/dev/null; then
            echo "tmpfs /tmp tmpfs size=${TMPFS_SIZE},mode=1777,nosuid,nodev 0 0" >> /etc/fstab
        fi
        log_info "/tmp tmpfs 已配置（${TMPFS_SIZE}）"
    else
        log_warn "mount tmpfs 失败，跳过 fstab 写入"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 诊断报告
# ─────────────────────────────────────────────────────────────────────────────
run_doctor() {
    log_step "运行诊断..."
    echo ""
    echo "=== VPS-youhua 环境诊断报告 (Oracle Cloud ARM 1C4G) ==="
    echo ""
    echo "1. 系统信息:"
    echo "   平台: $PLATFORM_NAME"
    echo "   系统: $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)"
    echo "   内核: $(uname -r)"
    echo "   架构: $(uname -m)"
    echo "   CPU: $SYS_CPU_CORES 核"
    echo "   内存: ${SYS_MEM_MB}MB"
    echo ""
    echo "2. Oracle Cloud:"
    echo "   Oracle Cloud: $SYS_IS_ORACLE_CLOUD"
    echo "   Cloud Agent: $(systemctl is-active oracle-cloud-agent 2>/dev/null || echo '已停止')"
    echo ""
    echo "3. 资源限制:"
    echo "   Conntrack: ${CT_MAX}"
    echo "   SOMAXCONN: ${SOMAXCONN}"
    echo "   TCP缓冲: $(numfmt --to=iec-i --suffix=B $TCP_BUF_MAX 2>/dev/null || echo "${TCP_BUF_MAX} bytes")"
    echo "   Swappiness: $SWAPPINESS"
    echo ""
    echo "4. 网络:"
    echo "   BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')"
    echo "   qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo '未知')"
    echo ""
    echo "5. 存储:"
    echo "   /tmp: $(df -h /tmp 2>/dev/null | awk 'NR==2 {print $2}' || echo 'tmpfs')"
    echo "   journald: $(journalctl --disk-usage 2>/dev/null | awk '{print $1,$2}' || echo '正常')"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Oracle Cloud 元数据健康检查（可选，防云端 kill）
# ─────────────────────────────────────────────────────────────────────────────
check_oracle_metadata() {
    log_step "检查 Oracle Cloud 元数据..."

    local meta_status
    meta_status=$(curl -s --connect-timeout 3 -o /dev/null -w "%{http_code}" \
        http://169.254.169.254/latest/meta-data/ 2>/dev/null || echo "000")

    if [[ "$meta_status" == "200" ]]; then
        local instance_id
        instance_id=$(curl -s --connect-timeout 3 http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "unknown")
        log_info "Oracle Cloud 元数据正常（实例: $instance_id）"

        local agent_status
        agent_status=$(systemctl is-active oracle-cloud-agent 2>/dev/null || echo "inactive")
        if [[ "$agent_status" == "active" ]]; then
            log_warn "检测到 Oracle Cloud Agent 运行中，已安排卸载"
        else
            log_info "Oracle Cloud Agent 未运行（已卸载或不存在）"
        fi
    else
        log_info "非 Oracle Cloud 环境或元数据端点不可访问（元数据检查跳过）"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 卸载函数（BUG#FIX: oracle-1c4g.sh 原缺少卸载函数）
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
    if [[ -t 0 ]]; then
        echo -n "确认卸载？(输入 'yes' 继续): "
        read -r -t 30 confirm || confirm=""
        confirm="${confirm,,}"
        if [[ -z "$confirm" ]]; then
            if [[ "${FORCE_UNINSTALL:-false}" == "true" ]]; then
                confirm="yes"
            else
                echo "已取消卸载（未检测到 TTY，请设置 FORCE_UNINSTALL=true 强制卸载）。"
                exit 0
            fi
        fi
        [[ "$confirm" != "yes" ]] && { echo "已取消。"; exit 0; }
    else
        # 非交互环境（SSH远程执行/cron）：检查 FORCE_UNINSTALL 变量
        if [[ "${FORCE_UNINSTALL:-false}" != "true" ]]; then
            echo "已取消卸载（未检测到 TTY，请设置 FORCE_UNINSTALL=true 强制卸载）。"
            exit 0
        fi
        log_info "非交互模式 + FORCE_UNINSTALL=true，自动确认卸载"
    fi

    echo ""
    echo -e "${CYAN}[➜] 开始卸载...${NC}"

    rm -f /etc/ssh/sshd_config.d/99-vps-youhua.conf
    rm -f /etc/sysctl.d/99-vps-youhua-oracle-1c4g.conf
    rm -f /etc/systemd/journald.conf.d/99-vps-youhua.conf
    rm -f /etc/security/limits.d/99-vps-youhua.conf
    rm -f /etc/systemd/system.conf.d/99-memory-accounting.conf
    rm -f /etc/systemd/system.conf.d/99-resource-limits.conf
    rm -f /etc/systemd/system.conf.d/99-oom-policy.conf
    rm -f /etc/cron.daily/vps-youhua-clean
    rm -f /etc/logrotate.d/vps-youhua
    rm -f /etc/apt/apt.conf.d/99-noninteractive
    rm -f /etc/apt/apt.conf.d/99-vps-youhua-no-unattended
    rm -f /etc/apt/apt.conf.d/99-vps-youhua-unattended
    rm -f /etc/needrestart/conf.d/99-vps-youhua.conf
    rm -f /etc/profile.d/99-agent-cache.sh
    rm -f /etc/default/cpufrequtils 2>/dev/null || true
    rm -f /etc/default/zramswap 2>/dev/null || true
    rm -f /etc/modprobe.d/nf_conntrack.conf

    # 停止并卸载 Docker（如果安装了的话）
    if command -v docker &>/dev/null; then
        systemctl stop docker 2>/dev/null || true
        systemctl disable docker 2>/dev/null || true
        log_info "Docker 服务已停止并禁用"
    fi

    # 停止并卸载 unattended-upgrades
    if command -v unattended-upgrades &>/dev/null; then
        systemctl stop unattended-upgrades 2>/dev/null || true
        systemctl disable unattended-upgrades 2>/dev/null || true
        apt-get remove --purge -y unattended-upgrades >> /dev/null 2>&1 || true
    fi

    # 停止并卸载 fail2ban
    if command -v fail2ban-server &>/dev/null; then
        systemctl stop fail2ban 2>/dev/null || true
        systemctl disable fail2ban 2>/dev/null || true
        rm -f /etc/fail2ban/jail.local
        rm -f /etc/fail2ban/jail.d/*.local 2>/dev/null || true
        apt-get remove --purge -y fail2ban >> /dev/null 2>&1 || true
    fi

    # 恢复 sources.list 备份
    local backup
    for backup in /etc/apt/sources.list.bak.*; do
        [[ -f "$backup" ]] && cp "$backup" /etc/apt/sources.list && break
    done

    systemctl daemon-reload 2>/dev/null || true

    # 卸载 /tmp tmpfs
    if mount | grep -q "tmpfs on /tmp"; then
        umount /tmp 2>/dev/null || true
        log_info "/tmp tmpfs 已卸载"
    fi

    # 清理 fstab tmpfs 条目
    sed -i '/tmpfs.*\/tmp/d' /etc/fstab 2>/dev/null || true
    log_info "fstab tmpfs 条目已清理"

    # 清理 iptables 规则（L5 FIX: 精准删除而非盲目 flush）
    # 只删除本脚本添加的规则，避免影响其他防火墙配置
    iptables -D INPUT -i lo -j ACCEPT 2>/dev/null || true
    iptables -D OUTPUT -o lo -j ACCEPT 2>/dev/null || true
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
# 软件安装桩函数（oracle-1c4g 调用 install_docker / install_nodejs）
# 这些函数在 source common-optimize.sh 时若未定义，则在此提供空实现
# ─────────────────────────────────────────────────────────────────────────────
install_docker() {
    log_warn "Docker 安装未对此平台实现，跳过"
    return 0
}
install_nodejs() {
    log_warn "Node.js 安装未对此平台实现，跳过"
    return 0
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
    echo -e "${GREEN}  Oracle Cloud ARM 1核4G 专用优化安装脚本 v${SCRIPT_VERSION}${NC}"
    echo "========================================================================"
    echo ""

    init_script
    check_idempotent
    detect_system
    # M1 FIX: detect_oracle_cloud 必须在 configure_ipv6_health 和 configure_dns_lock 之前
    # 因为 SYS_IS_ORACLE_CLOUD 变量被这些函数使用来决定行为
    detect_oracle_cloud
    # BUG#5: IPv6 黑洞检测
    configure_ipv6_health
    # BUG#7: DNS 锁定防篡改
    configure_dns_lock
    check_oracle_metadata
    check_network
    preflight_check

    show_platform_summary

    # M16 FIX: 远程执行时 stdin 可能非 TTY（ssh host 'sudo bash script'）
    # 只有在真正可交互时才显示确认提示
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
    oracle_cloud_cleanup
    optimize_memory_oracle
    # BUG#1+22 FIX: Oracle 1C4G 在 zram 就位后才判断 swap（避免浪费磁盘 swap）
    configure_swap
    configure_sysctl_oracle
    configure_conntrack_hashsize
    configure_limits

    configure_sysctl_oracle
    configure_conntrack_hashsize
    configure_limits
    configure_fstab
    configure_journald
    configure_dns
    configure_time_sync
    configure_locale
    configure_firewall_lo
    configure_tmp_tmpfs
    # BUG#FIX: 补充通用函数调用（npm缓存/tmpfs + 内存统计）
    configure_npm_cache_tmpfs
    configure_memory_accounting

    # ── CPU governor powersave（Oracle 1C4G 代理节点省电）────────────
    if [[ -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
        for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            [ -f "$cpu" ] && echo "powersave" > "$cpu" 2>/dev/null || true
        done
        log_info "CPU governor 已设为 powersave（省电）"
    fi

    optimize_oom
    configure_unattended_upgrades
    configure_fail2ban
    optimize_ssh
    configure_cleanup_cron
    configure_logrotate

    # BUG#3: 安装熵服务（Oracle 1C4G ARM TLS 加解密瓶颈优化）
    if command -v haveged >/dev/null 2>&1; then
        systemctl enable haveged 2>/dev/null || true
        systemctl restart haveged 2>/dev/null || true
        log_info "haveged 熵服务运行中"
    elif command -v rng-tools >/dev/null 2>&1; then
        systemctl enable rng-tools 2>/dev/null || true
        systemctl restart rng-tools 2>/dev/null || true
        log_info "rng-tools 熵服务运行中"
    else
        # M5 FIX: 使用 install_if_missing + 统一日志路径
        DEBIAN_FRONTEND=noninteractive install_if_missing rng-tools
        if command -v rng-tools >/dev/null 2>&1; then
            systemctl enable rng-tools 2>/dev/null || true
            systemctl restart rng-tools 2>/dev/null || true
            log_info "rng-tools 已安装并运行（TLS 熵池充足）"
        else
            log_warn "熵服务安装失败（TLS 加解密可能受影响）"
        fi
    fi

    # BUG#46 Fix: install_build_deps 独立于 SKIP_SOFTWARE_SCRIPT
    # INSTALL_DEPS 由用户选择决定（Option 2 = true），与 Docker/NodeJS 分开
    # SKIP_SOFTWARE_SCRIPT 只阻止 Docker/NodeJS，不阻止编译依赖
    : "${INSTALL_DEPS:=false}"
    if [[ "${INSTALL_DEPS}" == "true" ]]; then
        install_build_deps
    fi
    # Proxy-only 平台不安装 Docker / Node.js
    log_info "代理节点专用模式，跳过 Docker / Node.js 安装"

    run_doctor || { log_warn "诊断报告有异常，但继续完成"; }

    apt-get autoremove -y >> "$APT_LOG" 2>&1 || true
    apt-get autoclean >> "$APT_LOG" 2>&1 || true

    echo ""
    echo "========================================================================"
    echo -e "${GREEN}  ✅ Oracle Cloud ARM 1核4G v${SCRIPT_VERSION} 优化完成！${NC}"
    echo "========================================================================"
    echo ""
    echo -e "${CYAN}系统优化内容:${NC}"
    echo "  - Oracle Cloud Agent 已清理（释放 CPU/内存）"
    echo "  - TCP 缓冲自适应: $(numfmt --to=iec-i --suffix=B $TCP_BUF_MAX 2>/dev/null || echo "${TCP_BUF_MAX} bytes")"
    echo "  - zram 内存压缩（约等效扩展 2 倍内存）"
    echo "  - conntrack: ${CT_MAX}（1C4G 保守值）"
    echo "  - BBR + fq qdisc"
    echo "  - journald: ${JOURNALD_STORAGE} + ${JOURNALD_MAX_USE} 限制"
    echo "  - /tmp: tmpfs ${TMPFS_SIZE}"
    echo "  - 每日自动清理"
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
