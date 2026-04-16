#!/usr/bin/env bash
# =============================================================================
# Google Cloud e2-micro 永久免费 VPS 优化安装脚本 v3.1 R61
# 硬件: Google Cloud e2-micro, 1vCPU(共享) 1GB RAM, 30GB SSD
# 特点: GCP 共享 CPU 特化优化（burstable CPU + Intel + VPC 网络）
#       GCP Always Free 机型永久免费（1vCPU 1GB，非 ARM）
# =============================================================================
#
# 一键运行: bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/google-cloud-e2.sh)
#
# 模式说明:
#   --optimize-only   纯环境优化（不安装 Docker/Node.js）
#   --uninstall       卸载所有优化配置
#

# ─────────────────────────────────────────────────────────────────────────────
# 平台信息
# ─────────────────────────────────────────────────────────────────────────────
readonly PLATFORM_NAME="Google Cloud e2-micro（共享 CPU 永久免费）"
readonly PLATFORM_DESC="1vCPU 共享 $(awk '/MemTotal/{printf "%.0fGB", $2/1024/1024}' /proc/meminfo) RAM, Google Cloud Always Free"

# ─────────────────────────────────────────────────────────────────────────────
# 平台差异变量（GCP e2-micro 专项，比 Oracle 1C4G 更保守，共享 CPU）
# ─────────────────────────────────────────────────────────────────────────────
readonly SYSCTL_FILE="/etc/sysctl.d/99-vps-youhua-gcp-e2.conf"
# journald volatile（重启丢失，GCP SSD 不需要 persistent）
readonly JOURNALD_STORAGE="volatile"
readonly JOURNALD_MAX_USE="50M"
readonly TMPFS_SIZE="256M"

# GCP e2-micro TCP 缓冲（1GB 内存 3%，上限 8MB，下限 4MB）
readonly TCP_BUF_MAX
TCP_BUF_MAX=$(awk '/MemTotal/{m=$2/1024; printf "%.0f", (m*0.03*1024*1024>8388608)?8388608:(m*0.03*1024*1024<4194304)?4194304:m*0.03*1024*1024}' /proc/meminfo)
readonly CT_MAX=16384
readonly SOMAXCONN=512
readonly NETDEV_BACKLOG=2048
readonly SWAPPINESS=5
readonly MIN_FREE_KB=8192

# ─────────────────────────────────────────────────────────────────────────────
# 加载通用函数库
# ─────────────────────────────────────────────────────────────────────────────
if [[ -f "$(dirname "${BASH_SOURCE[0]}")/common-optimize.sh" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/common-optimize.sh"
elif [[ -f /tmp/vps-youhua-tmp/common-optimize.sh ]]; then
    source /tmp/vps-youhua-tmp/common-optimize.sh
elif [[ -f /tmp/vps-youhua/common-optimize.sh ]]; then
    source /tmp/vps-youhua/common-optimize.sh
fi

# ─────────────────────────────────────────────────────────────────────────────
# GCP Cloud 检测（通过官方元数据服务器）
# ─────────────────────────────────────────────────────────────────────────────
detect_gcp_cloud() {
    local gcp_meta
    gcp_meta=$(curl -s --connect-timeout 3 -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/compute/v1/instance/machine-type" 2>/dev/null || echo "")

    if echo "$gcp_meta" | grep -q "e2-micro\|e2-small\|e2-medium\|f1-micro\|g1-small"; then
        SYS_IS_GCP_CLOUD=true
        SYS_GCP_MACHINE_TYPE=$(echo "$gcp_meta" | grep -o 'e2-micro\|e2-small\|e2-medium\|f1-micro\|g1-small' | head -1)
        log_info "GCP Cloud 检测通过（机型: ${SYS_GCP_MACHINE_TYPE}）"
    else
        SYS_IS_GCP_CLOUD=false
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# GCP Cloud 专属检测信息
# ─────────────────────────────────────────────────────────────────────────────
check_gcp_metadata() {
    log_step "检查 GCP Cloud 元数据..."

    local meta_status
    meta_status=$(curl -s --connect-timeout 3 -o /dev/null -w "%{http_code}" \
        -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/compute/v1/instance/" 2>/dev/null || echo "000")

    if [[ "$meta_status" == "200" ]]; then
        local instance_name instance_zone
        instance_name=$(curl -s --connect-timeout 3 -H "Metadata-Flavor: Google" \
            "http://metadata.google.internal/compute/v1/instance/name" 2>/dev/null || echo "unknown")
        instance_zone=$(curl -s --connect-timeout 3 -H "Metadata-Flavor: Google" \
            "http://metadata.google.internal/compute/v1/instance/zone" 2>/dev/null | grep -o '[^/]*$' || echo "unknown")

        log_info "GCP 实例: ${instance_name}（${instance_zone}）"
        log_info "GCP 机型: ${SYS_GCP_MACHINE_TYPE:-未知}"

        # GCP google-guest-agent 状态（建议保留，用于 IP 配置和启动脚本）
        local guest_status
        guest_status=$(systemctl is-active google-guest-agent 2>/dev/null || echo "inactive")
        if [[ "$guest_status" == "active" ]]; then
            log_info "google-guest-agent 运行中（建议保留：处理 IP/路由/启动脚本）"
        else
            log_warn "google-guest-agent 未运行，可能影响 GCP 元数据访问"
        fi

        # GCP 外部 IP 信息
        local external_ip
        external_ip=$(curl -s --connect-timeout 3 -H "Metadata-Flavor: Google" \
            "http://metadata.google.internal/compute/v1/instance/network-interfaces/0/access-configs/0/externalIp" 2>/dev/null || echo "未分配")
        log_info "GCP 外部 IP: ${external_ip}"
    else
        log_info "非 GCP Cloud 环境或元数据端点不可访问"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# GCP Cloud 清理（可选，google-guest-agent 建议保留，其他可清理）
# ─────────────────────────────────────────────────────────────────────────────
gcp_cloud_cleanup() {
    [[ "$SYS_IS_GCP_CLOUD" != "true" ]] && return 0
    log_step "GCP Cloud 专属清理..."

    # 关闭 GCP 的 ce-susAttd（Google 的安全守护，消耗资源）
    for svc in ce-susAttd; do
        if systemctl is-active "$svc" &>/dev/null; then
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
            log_info "已停止并禁用 $svc"
        fi
    done

    log_info "GCP Cloud 清理完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# 内存优化（GCP e2-micro 精简版）
# ─────────────────────────────────────────────────────────────────────────────
optimize_memory_gcp() {
    log_step "配置内存优化..."

    # 透明大页（Intel CPU，关闭 defrag 减少抖动）
    echo "always" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    echo "madvise" > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

    # zram 内存扩展（e2-micro 1GB，开启压缩约等效 +512MB）
    if ! modprobe zram 2>/dev/null; then
        log_warn "zram 模块不可用，跳过"
    else
        local mem_kb
        mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
        local zram_size=$((mem_kb / 2))
        if [[ -f /sys/block/zram0/disksize ]]; then
            echo "${zram_size}K" > /sys/block/zram0/disksize 2>/dev/null || true
            mkswap /dev/zram0 >/dev/null 2>&1 || true
            swapon /dev/zram0 -p 32767 2>/dev/null || true
            log_info "zram 开启，压缩后约等效 +$((zram_size / 1024))MB 可用内存"
        fi
    fi

    log_info "内存优化完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# sysctl GCP e2-micro 专项配置
# ─────────────────────────────────────────────────────────────────────────────
configure_sysctl_gcp() {
    log_step "配置 sysctl 系统参数..."

    cat > "$SYSCTL_FILE" <<EOF
# ─────────────────────────────────────────────────────────────────────────────
# VPS-youhua Google Cloud e2-micro sysctl 配置
# 平台: GCP e2-micro 1vCPU 共享 1GB RAM
# 特点: 共享 CPU(burstable) + Intel + VPC 网络优化
# ─────────────────────────────────────────────────────────────────────────────

# ── 内存（1GB 精简）────────────────────────────────────────────────────────────
vm.swappiness = ${SWAPPINESS}
vm.min_free_kbytes = ${MIN_FREE_KB}
vm.vfs_cache_pressure = 50
vm.oom_kill_allocating_task = 1
vm.dirty_ratio = 10
vm.dirty_background_ratio = 3
vm.dirty_writeback_centisecs = 15000
vm.dirty_expire_centisecs = 30000

# ── 网络（GCP VPC 优化，比普通 VPS 更高吞吐）─────────────────────────────────
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}
net.core.somaxconn = ${SOMAXCONN}
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_tw_reuse = 1

# ── conntrack（1GB 保守，仅基础 NAT）────────────────────────────────────────
net.netfilter.nf_conntrack_max = ${CT_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 1200

# ── TCP 缓冲（内存 3%，上限 8MB）──────────────────────────────────────────────
net.core.rmem_max = ${TCP_BUF_MAX}
net.core.wmem_max = ${TCP_BUF_MAX}
net.ipv4.tcp_rmem = 4096 131072 ${TCP_BUF_MAX}
net.ipv4.tcp_wmem = 4096 131072 ${TCP_BUF_MAX}

# ── 本地端口范围 ─────────────────────────────────────────────────────────────
net.ipv4.ip_local_port_range = 10240 65535

# ── ICMP ────────────────────────────────────────────────────────────────────
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# ── ARP ─────────────────────────────────────────────────────────────────────
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2

# ── GCP 共享 CPU 特化（burstable 0.2vCPU 基线）───────────────────────────────
# GCP e2-micro 实际可 burst 到 2vCPU，但基线仅 0.2vCPU
# 以下参数减少单进程 CPU 占用，让 burst 更平滑
kernel.sched_child_runs_first = 0
kernel.sched_latency_ns = 10000000
kernel.sched_min_granularity_ns = 1000000
kernel.sched_wakeup_granularity_ns = 2000000
EOF

    if sysctl -p "$SYSCTL_FILE" 2>&1 | grep -v "^$" | head -5; then
        log_info "sysctl 参数已应用（$SYSCTL_FILE）"
    else
        log_warn "sysctl 部分参数不支持当前内核（可忽略）"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# GCP Cloud 网络优化（VPC + 共享 CPU）
# ─────────────────────────────────────────────────────────────────────────────
optimize_network_gcp() {
    log_step "优化 GCP Cloud 网络..."

    # GCP VPC 网卡优化
    for iface in /sys/class/net/en* /sys/class/net/eth* /sys/class/net/gcp*; do
        [[ -d "$iface" ]] || continue
        local name; name=$(basename "$iface")

        # GCP Virtio 网卡优化
        ethtool -K "$name" tso on 2>/dev/null || true
        ethtool -K "$name" gso on 2>/dev/null || true
        ethtool -K "$name" gro on 2>/dev/null || true
        ethtool -K "$name" tx-gso-robust on 2>/dev/null || true
        ip link set "$name" txqueuelen 1000 2>/dev/null || true

        # RPS（共享 CPU 单核，CPU 掩码 = 1）
        if [[ $SYS_CPU_CORES -ge 1 ]]; then
            local cores=$((SYS_CPU_CORES > 63 ? 63 : SYS_CPU_CORES))
            local mask; mask=$(printf '%x' $(( (1 << cores) - 1 )))
            for rps_file in /sys/class/net/${name}/queues/rx-*/rps_cpus; do
                [[ -f "$rps_file" ]] || continue
                printf "%s" "$mask" > "$rps_file" 2>/dev/null || true
            done
        fi

        log_info "网卡 $name 已优化"
    done

    # GCP 元数据 IP 路由确认
    if ip route get 8.8.8.8 2>/dev/null | grep -q "via"; then
        log_info "默认路由正常（via $(ip route get 8.8.8.8 2>/dev/null | awk '{print $3; exit}'))"
    fi

    log_info "GCP Cloud 网络优化完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# OOM Killer
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
SystemMaxFileSize=10M
MaxRetentionSec=7day
Compress=yes
EOF
    systemctl restart systemd-journald 2>/dev/null || true
    log_info "journald 已配置（${JOURNALD_STORAGE}，上限 ${JOURNALD_MAX_USE}）"
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
    mount -t tmpfs -o size=${TMPFS_SIZE},mode=1777,nosuid,nodev tmpfs /tmp 2>/dev/null || true
    if ! grep -q "tmpfs /tmp" /etc/fstab 2>/dev/null; then
        echo "tmpfs /tmp tmpfs size=${TMPFS_SIZE},mode=1777,nosuid,nodev 0 0" >> /etc/fstab
    fi
    log_info "/tmp tmpfs 已配置（${TMPFS_SIZE}）"
}

# ─────────────────────────────────────────────────────────────────────────────
# 清理定时任务
# ─────────────────────────────────────────────────────────────────────────────
configure_cleanup_cron() {
    log_step "配置定时清理..."
    mkdir -p /etc/cron.daily
    cat > /etc/cron.daily/vps-youhua-clean <<'EOF'
#!/bin/sh
# 每日清理（GCP e2-micro 精简版）
journalctl --vacuum-time=3d 2>/dev/null || true
apt-get clean 2>/dev/null || true
rm -rf /tmp/pear 2>/dev/null || true
rm -rf /var/cache/apt/archives/*.deb 2>/dev/null || true
EOF
    chmod +x /etc/cron.daily/vps-youhua-clean
    log_info "每日清理任务已配置"
}

# ─────────────────────────────────────────────────────────────────────────────
# 诊断报告
# ─────────────────────────────────────────────────────────────────────────────
run_doctor() {
    log_step "运行诊断..."
    echo ""
    echo "=== VPS-youhua 环境诊断报告 (Google Cloud e2-micro) ==="
    echo ""
    echo "1. 系统信息:"
    echo "   平台: $PLATFORM_NAME"
    echo "   系统: $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)"
    echo "   内核: $(uname -r)"
    echo "   架构: $(uname -m)"
    echo "   CPU: $SYS_CPU_CORES 核（共享 CPU，burst 到 2vCPU）"
    echo "   内存: ${SYS_MEM_MB}MB"
    echo ""
    echo "2. GCP Cloud:"
    echo "   GCP Cloud: $SYS_IS_GCP_CLOUD"
    echo "   机型: ${SYS_GCP_MACHINE_TYPE:-未知}"
    echo "   google-guest-agent: $(systemctl is-active google-guest-agent 2>/dev/null || echo '未运行')"
    echo ""
    echo "3. 资源限制:"
    echo "   Conntrack: ${CT_MAX}（精简，仅基础 NAT）"
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
# 主函数
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# OpenClaw-Proxy 落地机安装（全自动非交互）
# ─────────────────────────────────────────────────────────────────────────────
# 环境变量：
#   LANDING_AUTO_DOMAIN   落地机域名（必需）
#   LANDING_AUTO_PASS     Trojan 密码（可选，空则自动生成）
#   LANDING_AUTO_TRANSIT  中转机公网 IP（可选）
#   LANDING_AUTO_CFTOKEN  Cloudflare API Token（必需）
#   LANDING_AUTO_STAGING  使用 Let's Encrypt staging（0/1，默认 0）
# ─────────────────────────────────────────────────────────────────────────────

OPENCLAW_LANDING_URL="https://raw.githubusercontent.com/vpn3288/OpenClaw-Proxy/main/install_landing_v1.00-2.sh"
OPENCLAW_LANDING_SCRIPT="/tmp/openclaw-landing-install.sh"

download_openclaw_landing() {
    log_step "下载 OpenClaw-Proxy 落地机安装脚本..."
    if [[ -f "$OPENCLAW_LANDING_SCRIPT" ]]; then
        log_info "OpenClaw-Proxy 落地机脚本已存在，跳过下载"
        return 0
    fi
    if ! curl -fsSL "$OPENCLAW_LANDING_URL" -o "$OPENCLAW_LANDING_SCRIPT" 2>&1; then
        log_error "下载 OpenClaw-Proxy 落地机脚本失败"
        return 1
    fi
    chmod +x "$OPENCLAW_LANDING_SCRIPT"
    log_info "OpenClaw-Proxy 落地机脚本已下载"
}

validate_cf_token() {
    log_step "验证 Cloudflare API Token..."
    local cf_verify
    cf_verify=$(curl -s --connect-timeout 10 -H "Authorization: Bearer ${LANDING_AUTO_CFTOKEN}" \
        -H "Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/user/tokens/verify" 2>/dev/null)
    if echo "$cf_verify" | grep -q '"success":true'; then
        log_info "Cloudflare API Token 验证成功"
    else
        log_warn "Cloudflare API Token 验证失败，继续安装"
    fi
}

install_openclaw_landing() {
    log_step "安装 OpenClaw-Proxy 落地机..."

    if [[ -z "${LANDING_AUTO_DOMAIN:-}" ]]; then
        log_error "未设置 LANDING_AUTO_DOMAIN，跳过代理安装"
        return 1
    fi
    if [[ -z "${LANDING_AUTO_CFTOKEN:-}" ]]; then
        log_error "未设置 LANDING_AUTO_CFTOKEN，跳过代理安装"
        return 1
    fi

    download_openclaw_landing || return 1
    validate_cf_token

    export LANDING_AUTO_DOMAIN
    export LANDING_AUTO_PASS="${LANDING_AUTO_PASS:-}"
    export LANDING_AUTO_TRANSIT="${LANDING_AUTO_TRANSIT:-}"
    export LANDING_AUTO_CFTOKEN
    export LANDING_AUTO_CFTOKEN_MODE="${LANDING_AUTO_CFTOKEN_MODE:-auto}"
    export LANDING_AUTO_CFTOKEN2="${LANDING_AUTO_CFTOKEN2:-}"
    export LANDING_AUTO_STAGING="${LANDING_AUTO_STAGING:-0}"

    log_info "开始安装 OpenClaw-Proxy 落地机..."
    log_info "  域名: ${LANDING_AUTO_DOMAIN}"
    log_info "  密码: ${LANDING_AUTO_PASS:-（自动生成）}"
    log_info "  中转: ${LANDING_AUTO_TRANSIT:-（无）}"

    bash "$OPENCLAW_LANDING_SCRIPT" 2>&1 | tee -a "$APT_LOG"
    local rv=$?
    [[ $rv -eq 0 ]] && log_info "OpenClaw-Proxy 落地机安装完成"         || log_error "OpenClaw-Proxy 落地机安装失败（退出码: $rv）"
    return $rv
}

show_agent_help() {
    cat << 'AGENTEOF'

代理节点安装参数（通过环境变量传入）：
  LANDING_AUTO_DOMAIN   落地机域名（必需）       例：node.example.com
  LANDING_AUTO_PASS     Trojan密码（可选）        例：mypassword123
  LANDING_AUTO_TRANSIT  中转机IP（可选）          例：1.2.3.4
  LANDING_AUTO_CFTOKEN  Cloudflare Token（必需）  例：cf_xxxxxxxxxxxxx
  LANDING_AUTO_STAGING  使用测试证书（可选）     1=使用，0=正式（默认）

  示例（单行）：
  LANDING_AUTO_DOMAIN=node.example.com \
  LANDING_AUTO_CFTOKEN=cf_xxxxx \
  LANDING_AUTO_PASS=mypass123 \
  LANDING_AUTO_TRANSIT=1.2.3.4 \
  bash oracle-1c4g-agent.sh

AGENTEOF
}

# ─────────────────────────────────────────────────────────────────────────────
# 主函数（环境优化 + OpenClaw-Proxy 落地机）
# ─────────────────────────────────────────────────────────────────────────────
main() {
    for arg in "$@"; do
        case "$arg" in
            --optimize-only) export SKIP_SOFTWARE_SCRIPT="true"; export SKIP_AGENT="true" ;;
            --uninstall) ;;
            --help|-h) show_agent_help; exit 0 ;;
        esac
    done

    : "${SKIP_SOFTWARE_SCRIPT:=false}"
    : "${SKIP_AGENT:=false}"

    uninstall_all "$@" || exit 1

    clear
    echo "========================================================================"
    echo -e "${GREEN}  Google Cloud e2-micro + OpenClaw-Proxy 落地机 v${SCRIPT_VERSION} R61${NC}"
    echo "========================================================================"
    echo ""
    echo -e "${YELLOW}  一键安装：GCP 共享 CPU 优化 + OpenClaw-Proxy 落地机${NC}"

    init_script
    detect_system
    detect_gcp_cloud
    check_gcp_metadata
    check_network
    preflight_check
    show_platform_summary

    # ── 代理节点配置 ──────────────────────────────────────────────────
    local domain="" cf_token="" password="" transit_ip=""

    if [[ "$SKIP_AGENT" != "true" ]]; then
        echo ""
        echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BOLD}  代理节点配置（直接回车使用环境变量值）${NC}"
        echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

        if [[ -t 0 ]]; then
            echo -e "${CYAN}  落地机域名（必需，例：node.example.com）${NC}"
            echo -n "  > "; read -r d; domain="${d:-${LANDING_AUTO_DOMAIN:-}}"
            echo -e "${CYAN}  Cloudflare API Token（必需，cf_xxxxxxxx）${NC}"
            echo -n "  > "; read -r c; cf_token="${c:-${LANDING_AUTO_CFTOKEN:-}}"
            echo -e "${CYAN}  Trojan 密码（可选，直接回车自动生成）${NC}"
            echo -n "  > "; read -r p; password="${p:-${LANDING_AUTO_PASS:-}}"
            echo -e "${CYAN}  中转机公网 IP（可选，直接回车跳过）${NC}"
            echo -n "  > "; read -r t; transit_ip="${t:-${LANDING_AUTO_TRANSIT:-}}"
        else
            domain="${LANDING_AUTO_DOMAIN:-}"; cf_token="${LANDING_AUTO_CFTOKEN:-}"
            password="${LANDING_AUTO_PASS:-}"; transit_ip="${LANDING_AUTO_TRANSIT:-}"
        fi

        if [[ -z "$domain" ]] || [[ -z "$cf_token" ]]; then
            echo -e "${YELLOW}  警告：域名或 CF Token 为空，跳过代理安装${NC}"
            export SKIP_AGENT="true"
        else
            export LANDING_AUTO_DOMAIN="$domain" LANDING_AUTO_CFTOKEN="$cf_token"
            export LANDING_AUTO_PASS="$password" LANDING_AUTO_TRANSIT="$transit_ip"
            echo -e "${GREEN}  代理节点：$domain${NC}"
        fi
    fi

    if [[ -t 0 ]]; then
        echo ""; echo -n "继续执行？(y/n，默认 y): "; read -r confirm
        [[ "$confirm" == "n" || "$confirm" == "N" ]] && exit 0
    fi

    echo ""; log_step "开始环境优化..."

    backup_all
    configure_apt_sources
    clean_system
    gcp_cloud_cleanup
    optimize_memory_gcp
    configure_sysctl_gcp
    optimize_network_gcp
    configure_limits
    configure_journald
    configure_dns
    configure_time_sync
    configure_locale
    configure_firewall_lo
    configure_tmp_tmpfs
    optimize_oom
    configure_cleanup_cron
    configure_logrotate

    if [[ "$SKIP_SOFTWARE_SCRIPT" != "true" ]]; then
        install_build_deps
        [[ "$INSTALL_DOCKER" == "true" ]] && install_docker
        [[ "$INSTALL_NODEJS" == "true" ]] && install_nodejs
    fi

    if [[ "$SKIP_AGENT" != "true" ]]; then
        echo ""; log_step "安装 OpenClaw-Proxy 落地机..."
        install_openclaw_landing || log_warn "代理节点安装未成功"
    fi

    echo ""
    echo "========================================================================"
    echo -e "${GREEN}  ✅ Google Cloud e2-micro 优化完成！${NC}"
    echo "========================================================================"
    date > /etc/vps-youhua-optimized 2>/dev/null || true
    chmod 444 /etc/vps-youhua-optimized 2>/dev/null || true
    return 0
}


trap 'log_error "脚本异常退出 (行: ${LINENO})"; exit 1' ERR

main "$@"
