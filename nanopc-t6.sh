#!/bin/bash
#
# 修复: 非交互式环境(如SSH远程执行)需要 TERM 变量
: "${TERM:=xterm}"
# VPS 优化脚本 - NanoPC T6 (Armbian)
#
# 用法:
#   sudo bash nanopc-t6.sh                    # 完整安装（底层优化 + 软件依赖）
#   sudo bash nanopc-t6.sh --optimize-only    # 仅底层优化
#   sudo bash nanopc-t6.sh --uninstall        # 卸载所有优化
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
# NanoPC T6/T6S (FriendlyELEC) 专用优化安装脚本 v3.4.1
# 硬件: RK3588S ARM64, 16GB RAM, eMMC, 1×GbE + 2×2.5GbE
# 特点: 平衡稳定模式（保留轻量 ZRAM，不过度禁用缓冲）
# =============================================================================
#
# 一键运行: bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/nanopc-t6.sh)
#
# 模式说明:
#   --optimize-only   纯环境优化（不安装 Docker/Node.js）
#   --uninstall       卸载所有优化配置
#

# ─────────────────────────────────────────────────────────────────────────────
# 平台信息
# ─────────────────────────────────────────────────────────────────────────────
readonly PLATFORM_NAME="NanoPC T6 (Armbian)"
readonly PLATFORM_DESC="RK3588S ARM64 | 16GB RAM | eMMC | Armbian 24.04"

# ─────────────────────────────────────────────────────────────────────────────
# 平台差异变量（T6 专项）
# ─────────────────────────────────────────────────────────────────────────────
readonly SYSCTL_FILE="/etc/sysctl.d/99-vps-youhua-t6.conf"
# journald persistent for eMMC
readonly JOURNALD_STORAGE="persistent"
readonly JOURNALD_MAX_USE="100M"             # eMMC 可以用更多日志
readonly TMPFS_SIZE="1024M"                  # 16GB 机器 /tmp 可以更大

# T6 使用 Armbian 原生 zram-config（SIZE=30%），不使用 ZRAM_SIZE 变量
readonly ZRAM_ALGO="lz4"
readonly SWAPPINESS=20                        # 16GB 积极回收 page cache
readonly MIN_FREE_KB=65536                     # 16GB OOM 防线

# T6 网络（2.5GbE × 2）
readonly NETDEV_BACKLOG=131072
readonly SOMAXCONN=65535
# BUG 修复: T6 16GB 机器使用动态 conntrack 公式
# 动态: RAM_MB * 32，范围 [16384, 1048576]
# 公式: RAM_MB * 32 提供足够连接数同时不耗尽内存
readonly CT_HASH_SIZE=131072

# ─────────────────────────────────────────────────────────────────────────────
# 加载通用函数库（必须在所有函数定义之前，让平台专属函数正确 override）
# ─────────────────────────────────────────────────────────────────────────────
COMMON_OPTIMIZE_URL="https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/common-optimize.sh"

load_common_optimize() {
    # 优先从本地加载
    if [[ -f "$(dirname "${BASH_SOURCE[0]}")/common-optimize.sh" ]]; then
        source "$(dirname "${BASH_SOURCE[0]}")/common-optimize.sh"
        if declare -f log_step >/dev/null 2>&1; then
            return 0
        fi
        echo -e "\033[33m[!] 警告: 本地 common-optimize.sh 加载失败，尝试下载...\033[0m" >&2
    fi
    if [[ -f /tmp/vps-youhua-tmp/common-optimize.sh ]]; then
        source /tmp/vps-youhua-tmp/common-optimize.sh
        if declare -f log_step >/dev/null 2>&1; then
            return 0
        fi
        echo -e "\033[33m[!] 警告: /tmp/vps-youhua-tmp/common-optimize.sh 加载失败，尝试下载...\033[0m" >&2
    fi
    if [[ -f /tmp/vps-youhua/common-optimize.sh ]]; then
        source /tmp/vps-youhua/common-optimize.sh
        if declare -f log_step >/dev/null 2>&1; then
            return 0
        fi
        echo -e "\033[33m[!] 警告: /tmp/vps-youhua/common-optimize.sh 加载失败，尝试下载...\033[0m" >&2
    fi
    
    # 下载到临时目录
    local tmpdir="/tmp/vps-youhua"
    mkdir -p "$tmpdir"
    echo -e "\033[36m[➜] 下载 common-optimize.sh...\033[0m"
    if curl -fsSL "$COMMON_OPTIMIZE_URL" -o "${tmpdir}/common-optimize.sh"; then
        # SHA256 校验供应链安全
        local sha256_expected="d5b94b48770d43216f2751bbd881aa2ff8ba9d856c4c9e56e3d91d07b9731e67"
        local sha256_actual
        sha256_actual=$(sha256sum "${tmpdir}/common-optimize.sh" | awk '{print $1}')
        if [[ "$sha256_actual" != "$sha256_expected" ]]; then
            echo -e "\033[31m[✗] 错误: common-optimize.sh SHA256 校验失败\033[0m" >&2
            echo -e "\033[31m  期望: $sha256_expected\033[0m" >&2
            echo -e "\033[31m  实际: $sha256_actual\033[0m" >&2
            rm -f "${tmpdir}/common-optimize.sh"
            rmdir "$tmpdir" 2>/dev/null || true  # 清理空目录
            exit 1
        fi
        source "${tmpdir}/common-optimize.sh"
        if declare -f log_step >/dev/null 2>&1; then
            return 0
        fi
        echo -e "\033[31m[✗] 错误: common-optimize.sh 下载成功但加载失败\033[0m" >&2
        exit 1
    fi
    echo -e "\033[31m[✗] 错误: 无法下载 common-optimize.sh\033[0m" >&2
    exit 1
}

load_common_optimize

# ─────────────────────────────────────────────────────────────────────────────
# T6 eMMC 存储检测
# ─────────────────────────────────────────────────────────────────────────────
detect_storage_type() {
    # T6 专用 eMMC，始终返回 emmc
    STORAGE_TYPE="emmc"
    local root_dev
    root_dev=$(df / 2>/dev/null | awk 'NR==2 {print $1}')
    root_dev=$(basename "$root_dev" 2>/dev/null)

    if [[ "$root_dev" == mmcblk* ]]; then
        log_info "检测到 eMMC 存储（$root_dev）"
    else
        log_info "系统盘: $root_dev"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 内存优化（T6 16GB 平衡模式：保留 ZRAM）
# ─────────────────────────────────────────────────────────────────────────────
optimize_memory_t6() {
    log_step "配置内存 (T6 16GB 平衡模式)..."

    # 禁用物理 swap（eMMC 也尽量不用）
    # Round 3 Fix M2: 添加循环变量 local 声明
    local sw
    for sw in /swapfile /swap.img; do
        swapon --show 2>/dev/null | grep -qF "$sw" && swapoff "$sw" 2>/dev/null || true
        [[ -f "$sw" ]] && rm -f "$sw"
    done
    # HIGH FIX: 使用精确锚点匹配 fstab swap 条目
    sed -i '\|^[^#]*[[:space:]]/swapfile[[:space:]]|d' /etc/fstab 2>/dev/null || true
    sed -i '\|^[^#]*[[:space:]]/swap.img[[:space:]]|d' /etc/fstab 2>/dev/null || true

    # Armbian zram-config 保留（zram 是压缩内存，零磁盘写入）
    if systemctl is-active armbian-zram-config &>/dev/null; then
        log_info "Armbian zram-config 保持原状"
    fi

    # ── Armbian 原生 zram-config 强化（T6 16GB）────────────────────────────────
    if [[ -f /etc/default/armbian-zram-config ]]; then
        # LOW FIX: sed 幂等性检查改进，处理末尾空格
        if grep -q "^ENABLED=" /etc/default/armbian-zram-config 2>/dev/null; then
            # 只在值不是 true 时才修改（忽略末尾空格）
            if ! grep -qE "^ENABLED=true[[:space:]]*$" /etc/default/armbian-zram-config 2>/dev/null; then
                sed -i 's/^ENABLED=.*$/ENABLED=true/' /etc/default/armbian-zram-config
            fi
        else
            echo "ENABLED=true" >> /etc/default/armbian-zram-config
        fi
        # 16GB 内存下 zram SIZE=30%（T6 eMMC 耐久好，不强制压缩内存）
        if grep -q "^SIZE=" /etc/default/armbian-zram-config 2>/dev/null; then
            # 只在值不是 30% 时才修改（忽略末尾空格）
            if ! grep -qE "^SIZE=30%[[:space:]]*$" /etc/default/armbian-zram-config 2>/dev/null; then
                sed -i 's/^SIZE=.*$/SIZE=30%/' /etc/default/armbian-zram-config
            fi
        else
            echo "SIZE=30%" >> /etc/default/armbian-zram-config
        fi
        log_info "Armbian zram-config 已强化（SIZE=30%）"
    fi

    # ── Armbian 原生 ramlog 强化（T6）──────────────────────────────────────────
    if [[ -f /etc/default/armbian-ramlog ]]; then
        if grep -q "^ENABLED=" /etc/default/armbian-ramlog 2>/dev/null; then
            sed -i 's/^ENABLED=.*$/ENABLED=true/' /etc/default/armbian-ramlog
        else
            echo "ENABLED=true" >> /etc/default/armbian-ramlog
        fi
        if grep -q "^SIZE=" /etc/default/armbian-ramlog 2>/dev/null; then
            sed -i 's/^SIZE=.*$/SIZE=256M/' /etc/default/armbian-ramlog
        else
            echo "SIZE=256M" >> /etc/default/armbian-ramlog
        fi
        log_info "Armbian ramlog 已强化（SIZE=256M）"
    fi

    # ── eMMC 每周 fstrim 定时任务（保持长期性能）────────────────────────────
    mkdir -p /etc/cron.weekly
    cat > /etc/cron.weekly/fstrim-emmc <<'EOF'
#!/bin/sh
# NanoPC T6 eMMC 每周 fstrim（保持长期 IO 性能）
for d in / /var; do
    fstrim -v "$d" 2>/dev/null || true
done
EOF
    chmod +x /etc/cron.weekly/fstrim-emmc
    log_info "已创建 eMMC 每周 fstrim 定时任务"

    sysctl -w vm.oom_kill_allocating_task=1 2>/dev/null || true
    log_info "内存优化完成（zram 保留，swappiness=$SWAPPINESS）"
}

# ─────────────────────────────────────────────────────────────────────────────
# T6 sysctl（高性能网络 + 平衡内存）
# ─────────────────────────────────────────────────────────────────────────────
configure_sysctl_t6() {
    log_step "配置 sysctl (NanoPC T6)..."

    # HIGH FIX: 验证 SYS_MEM_MB 是否已初始化
    if [[ -z "${SYS_MEM_MB}" || ! "${SYS_MEM_MB}" =~ ^[0-9]+$ || "${SYS_MEM_MB}" -le 0 ]]; then
        log_error "SYS_MEM_MB 未初始化或无效（${SYS_MEM_MB:-未定义}），请先调用 detect_system()"
        return 1
    fi

    # 计算 conntrack_max（使用 RAM_MB * 32 公式，范围 [16384, 1048576]）
    local calc_conntrack_max=$(( SYS_MEM_MB * 32 ))
    [[ $calc_conntrack_max -lt 16384 ]] && calc_conntrack_max=16384
    [[ $calc_conntrack_max -gt 1048576 ]] && calc_conntrack_max=1048576

    backup_file "$SYSCTL_FILE"

    write_common_sysctl "$SYSCTL_FILE"

    cat >> "$SYSCTL_FILE" <<EOF

# ── T6 内存（16GB 平衡）──────────────────────────────────────────────────────
vm.swappiness = ${SWAPPINESS}
vm.dirty_ratio = 20
vm.dirty_background_ratio = 5
vm.dirty_writeback_centisecs = 10000
vm.dirty_expire_centisecs = 60000

# ── T6 网络（2.5GbE × 2，高并发）────────────────────────────────────────────
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}
net.core.somaxconn = ${SOMAXCONN}
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 262144 33554432
net.ipv4.tcp_wmem = 4096 262144 33554432
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
# SYN cookies for DDoS protection on proxy servers
net.ipv4.tcp_syncookies = 1

# ── 连接追踪 ─────────────────────────────────────────────────────────────────
net.netfilter.nf_conntrack_max = ${calc_conntrack_max}
# AUDIT-13 FIX: nf_conntrack_hashsize 是只读参数，不能通过 sysctl 设置
# 将在 configure_conntrack_hashsize_t6() 函数中通过 /sys/module 设置
net.netfilter.nf_conntrack_tcp_timeout_established = 900
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 20
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 10
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 5
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 10
EOF

    apply_sysctl
    log_info "T6 sysctl 配置完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# ARM 专项优化（T6 RK3588S）
# ─────────────────────────────────────────────────────────────────────────────
optimize_arm() {
    log_step "ARM 专项优化..."

    mkdir -p /etc/default
    cat > /etc/default/cpufrequtils <<'EOF'
GOVERNOR=schedutil
MIN_SPEED=408000
MAX_SPEED=2400000
EOF
    systemctl restart cpufrequtils 2>/dev/null || true

    if ! command -v irqbalance &>/dev/null; then
        apt-get install -y irqbalance >> "$APT_LOG" 2>&1 || true
    fi
    systemctl enable irqbalance 2>/dev/null || true

    log_info "ARM 优化完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# T6 网络优化（2.5GbE 高吞吐）
# ─────────────────────────────────────────────────────────────────────────────
optimize_network_t6() {
    log_step "T6 网络优化..."

    for iface in /sys/class/net/en* /sys/class/net/eth*; do
        [[ -d "$iface" ]] || continue
        local name; name=$(basename "$iface")

        # 启用 TSO/GSO/GRO
        ethtool -K "$name" tso on 2>/dev/null || true
        ethtool -K "$name" gso on 2>/dev/null || true
        ethtool -K "$name" gro on 2>/dev/null || true
        ip link set "$name" txqueuelen 10000 2>/dev/null || true

    # 多核 CPU 优化 RPS/RFS
    # LOW FIX: 使用防御性语法避免未初始化变量
    if [[ ${SYS_CPU_CORES:-0} -gt 1 ]]; then
            local cores=$((SYS_CPU_CORES > 63 ? 63 : SYS_CPU_CORES))
            if [[ $cores -gt 0 ]]; then
                local mask; mask=$(printf '%x' $(( (1 << cores) - 1 )))
                for rps_file in /sys/class/net/${name}/queues/rx-*/rps_cpus; do
                    [[ -f "$rps_file" ]] || continue
                    printf "%s" "$mask" > "$rps_file" 2>/dev/null || true
                done
            fi
        fi
        log_info "网卡 $name 已优化"
    done

    log_info "T6 网络优化完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# HIGH FIX: 标准化 nf_conntrack_hashsize 配置（只读参数，不能通过 sysctl）
# ─────────────────────────────────────────────────────────────────────────────
configure_conntrack_hashsize_t6() {
    log_step "配置 nf_conntrack_hashsize..."
    
    # 加载 nf_conntrack 模块
    modprobe nf_conntrack 2>/dev/null || true
    
    local hashsize_file="/sys/module/nf_conntrack/parameters/hashsize"
    if [[ -f "$hashsize_file" ]]; then
        # 计算 hashsize（conntrack_max / 4，上限为 CT_HASH_SIZE）
        local calc_conntrack_max
        calc_conntrack_max=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo "262144")
        
        # Round 3 Fix H1: 增强参数验证
        if [[ -z "$calc_conntrack_max" || "$calc_conntrack_max" -le 0 ]]; then
            log_warn "conntrack_max 无效（${calc_conntrack_max:-未定义}），使用默认值"
            calc_conntrack_max=262144
        fi
        
        # 验证是否为有效数字
        if ! [[ "$calc_conntrack_max" =~ ^[0-9]+$ ]]; then
            log_warn "conntrack_max 不是有效数字（${calc_conntrack_max}），使用默认值 262144"
            calc_conntrack_max=262144
        fi
        
        local hashsize=$(( calc_conntrack_max / 4 ))
        
        # 最小值保护
        if [[ $hashsize -lt 16384 ]]; then
            log_warn "hashsize 过小（$hashsize），使用最小值 16384"
            hashsize=16384
        fi
        
        # CT_HASH_SIZE 作为上限保护
        if [[ $hashsize -gt $CT_HASH_SIZE ]]; then
            hashsize=$CT_HASH_SIZE
        fi
        
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
# OOM 配置
# ─────────────────────────────────────────────────────────────────────────────
optimize_oom() {
    log_step "配置 OOM Killer..."
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/99-oom-policy.conf <<'EOF'
[Manager]
OOMPolicy=continue
OOMScoreAdjust=-300
EOF
    systemctl daemon-reload 2>/dev/null || true
    log_info "OOM Killer 配置完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# journald（T6 eMMC 模式）
# ─────────────────────────────────────────────────────────────────────────────
configure_journald() {
    log_step "配置 journald..."
    mkdir -p /etc/systemd/journald.conf.d

    # Round 3 Fix H2: 添加备份
    local journald_conf="/etc/systemd/journald.conf.d/99-vps-youhua.conf"
    [[ -f "$journald_conf" ]] && backup_file "$journald_conf"

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
    log_info "journald 配置完成（Storage=${JOURNALD_STORAGE}）"
}

# ─────────────────────────────────────────────────────────────────────────────
# I/O Scheduler（eMMC/SSD → none）
# ─────────────────────────────────────────────────────────────────────────────
optimize_io_scheduler() {
    log_step "配置 I/O Scheduler..."

    local root_dev
    root_dev=$(df / 2>/dev/null | awk 'NR==2 {print $1}')
    root_dev=$(basename "$root_dev" 2>/dev/null)

    if [[ "$root_dev" == mmcblk* ]]; then
        # eMMC 或 TF 卡：none
        local sched_file="/sys/block/${root_dev}/queue/scheduler"
        if [[ -f "$sched_file" ]]; then
            echo "none" > "$sched_file" 2>/dev/null || true
            log_info "eMMC/TF $root_dev I/O Scheduler → none"
        fi
    elif [[ -f "/sys/block/${root_dev}/queue/rotational" ]] && \
         [[ "$(cat /sys/block/${root_dev}/queue/rotational 2>/dev/null)" == "0" ]]; then
        # SSD：none
        local sched_file="/sys/block/${root_dev}/queue/scheduler"
        if [[ -f "$sched_file" ]]; then
            echo "none" > "$sched_file" 2>/dev/null || true
            log_info "SSD $root_dev I/O Scheduler → none"
        fi
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
    # TODO: 提取到 common-optimize.sh（完整 Docker 安装逻辑，避免跨文件重复）
    [[ "$INSTALL_DOCKER" != "true" ]] && return 0
    log_step "安装 Docker..."

    if command -v docker &>/dev/null; then
        log_info "Docker 已安装，跳过"
        return 0
    fi

    # 使用官方 APT 仓库安装 Docker，避免 curl|bash 安全风险
    log_info "安装 Docker 依赖..."
    apt-get install -y ca-certificates curl gnupg lsb-release >> "$APT_LOG" 2>&1 || {
        log_error "Docker 依赖安装失败"
        return 1
    }

    log_info "添加 Docker GPG 密钥..."
    mkdir -p /etc/apt/keyrings
    local gpg_tmp; gpg_tmp=$(mktemp)
    local gpg_stderr; gpg_stderr=$(mktemp)
    trap 'rm -f "$gpg_tmp" "$gpg_stderr"' RETURN INT

    # 先下载到临时文件，避免 TOCTOU 漏洞
    if ! curl -fsSL https://download.docker.com/linux/debian/gpg -o "$gpg_tmp" 2>"$gpg_stderr"; then
        log_error "Docker GPG 密钥下载失败"
        cat "$gpg_stderr" >> "$APT_LOG" 2>/dev/null
        return 1
    fi

    # 转换为 gpg 格式（dearmor）到另一个临时文件
    local gpg_dearmored; gpg_dearmored=$(mktemp)
    if ! gpg --dearmor -o "$gpg_dearmored" "$gpg_tmp" 2>"$gpg_stderr"; then
        log_error "Docker GPG 密钥格式转换失败"
        cat "$gpg_stderr" >> "$APT_LOG" 2>/dev/null
        return 1
    fi

    # 在写入目标位置之前验证指纹，防止 TOCTOU 攻击
    local key_fingerprint; key_fingerprint=$(gpg --show-keys --with-colons "$gpg_dearmored" 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}')
    local expected_fingerprint="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
    if [[ -z "$key_fingerprint" ]]; then
        log_error "无法读取 GPG 密钥指纹"
        return 1
    fi
    if [[ "$key_fingerprint" != "$expected_fingerprint" ]]; then
        log_error "GPG 密钥指纹校验失败！疑似供应链污染。"
        log_error "预期: $expected_fingerprint"
        log_error "实际: $key_fingerprint"
        return 1
    fi
    log_info "Docker GPG 密钥指纹校验通过"

    # 验证通过后，原子性移动到目标位置
    chmod 644 "$gpg_dearmored"
    mv -f "$gpg_dearmored" /etc/apt/keyrings/docker.gpg

    log_info "添加 Docker APT 仓库..."
    local codename; codename=$(lsb_release -cs 2>/dev/null || echo "bookworm")
    local mirror_url="download.docker.com"

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://${mirror_url}/linux/debian ${codename} stable" > /etc/apt/sources.list.d/docker.list 2>/dev/null || \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://${mirror_url}/linux/ubuntu ${codename} stable" > /etc/apt/sources.list.d/docker.list 2>/dev/null || true

    log_info "安装 Docker..."
    apt-get update -qq >> "$APT_LOG" 2>&1
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >> "$APT_LOG" 2>&1 || {
        log_error "Docker 安装失败，请查看 $APT_LOG"
        return 1
    }

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
  "log-opts": {"max-size": "10m", "max-file": "3"}
}
EOF
    systemctl restart docker 2>/dev/null || true
    # Docker 健康检查
    if docker ps >/dev/null 2>&1; then
        log_info "Docker 运行正常: $(docker ps -q | wc -l) 个容器在运行"
    else
        log_warn "Docker 守护进程可能未正常启动"
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

    # [H10] FIX: 使用临时文件替代 curl|bash 管道安装 Node.js
    local nodesource_script="/tmp/setup_nodesource.sh"
    local nodesource_download_ok=false
    if curl -fsSL https://deb.nodesource.com/setup_22.x -o "$nodesource_script" 2>/dev/null; then
        nodesource_download_ok=true
    fi

    if [[ "$nodesource_download_ok" == "true" ]]; then
        # SHA256 完整性校验（防止供应链污染）
        # ⚠️  警告：NodeSource 脚本会定期更新，SHA256 会变化
        # 生产环境建议：
        #   1. 定期更新此校验和（每月检查 https://deb.nodesource.com/setup_lts.x）
        #   2. 或使用动态校验（curl + 官方签名验证）
        #   3. 或固定 Node.js 版本号避免自动更新
        local expected_sha256="575583bbac2fccc0b5edd0dbc03e222d9f9dc8d724da996d22754d6411104fd1"
        local actual_sha256
        actual_sha256=$(sha256sum "$nodesource_script" 2>/dev/null | awk '{print $1}')
        if [[ "$actual_sha256" == "$expected_sha256" ]]; then
            chmod +x "$nodesource_script" && "$nodesource_script" >> "$APT_LOG" 2>&1 && log_info "Node.js 安装完成" || nodesource_download_ok="failed"
        else
            log_warn "NodeSource SHA256 校验异常（预期: $expected_sha256, 实际: $actual_sha256），跳过执行"
            nodesource_download_ok="failed"
        fi
        rm -f "$nodesource_script"
    fi

    if [[ "$nodesource_download_ok" != "true" ]]; then
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
    echo "=== VPS-youhua 环境诊断报告 (NanoPC T6) ==="
    echo ""
    echo "1. 系统信息:"
    echo "   平台: $PLATFORM_NAME"
    echo "   系统: $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)"
    echo "   内核: $(uname -r)"
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
    ss -tlnp 2>/dev/null | grep -E "18789|18790" || echo "   无"
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
    # 非交互卸载时跳过确认提示
    if [[ "${FORCE_UNINSTALL:-false}" != "true" ]]; then
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
    rm -f /etc/sysctl.d/99-vps-youhua-t6.conf
    rm -f /etc/systemd/journald.conf.d/99-vps-youhua.conf
    rm -f /etc/security/limits.d/99-vps-youhua.conf
    rm -f /etc/systemd/system.conf.d/99-memory-accounting.conf
    rm -f /etc/systemd/system.conf.d/99-resource-limits.conf
    rm -f /etc/systemd/system.conf.d/99-oom-policy.conf
    rm -f /etc/ssh/sshd_config.d/99-vps-youhua.conf
    rm -f /etc/cron.d/vps-youhua-cleanup
    rm -f /etc/logrotate.d/vps-youhua
    rm -f /etc/apt/apt.conf.d/99-noninteractive
    rm -f /etc/apt/apt.conf.d/99-vps-youhua-no-unattended
    rm -f /etc/apt/apt.conf.d/99-vps-youhua-unattended
    rm -f /etc/needrestart/conf.d/99-vps-youhua.conf
    rm -f /etc/default/cpufrequtils 2>/dev/null || true
    rm -f /etc/cron.weekly/fstrim-emmc
    rm -f /etc/profile.d/nodejs-memory.sh
    rm -f /etc/docker/daemon.json
    rm -f /etc/modprobe.d/nf_conntrack.conf
    # 恢复 Armbian zram-config 默认值
    if [[ -f /etc/default/armbian-zram-config ]]; then
        sed -i 's/^ENABLED=.*/ENABLED=false/' /etc/default/armbian-zram-config 2>/dev/null || true
        sed -i 's/^SIZE=.*/SIZE=50%/' /etc/default/armbian-zram-config 2>/dev/null || true
    fi
    # 恢复 Armbian ramlog 默认值
    if [[ -f /etc/default/armbian-ramlog ]]; then
        sed -i 's/^ENABLED=.*/ENABLED=true/' /etc/default/armbian-ramlog 2>/dev/null || true
        sed -i 's/^SIZE=.*/SIZE=100M/' /etc/default/armbian-ramlog 2>/dev/null || true
    fi
    # 恢复 fstab tmpfs 条目（/tmp 和 /var/log）
    sed -i '/tmpfs.*\/tmp/d' /etc/fstab 2>/dev/null || true
    sed -i '/tmpfs.*\/var\/log/d' /etc/fstab 2>/dev/null || true

    # 停止并卸载 unattended-upgrades（如果安装了的话）
    if command -v unattended-upgrades &>/dev/null; then
        systemctl stop unattended-upgrades 2>/dev/null || true
        systemctl disable unattended-upgrades 2>/dev/null || true
        apt-get remove --purge -y unattended-upgrades >> /dev/null 2>&1 || true
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
    echo -e "${GREEN}  NanoPC T6 专用优化安装脚本 v${SCRIPT_VERSION}${NC}"
    echo "========================================================================"
    echo ""

    init_script
    check_idempotent
    # BUG#5: IPv6 黑洞检测
    configure_ipv6_health
    # BUG#7: DNS 锁定防篡改
    configure_dns_lock
    detect_system
    detect_storage_type
    check_network
    preflight_check

    show_platform_summary

    if [[ -t 0 ]]; then
        echo -n "继续执行？(y/n，默认 y): "
        read -r -t 30 confirm || confirm="y"
        [[ "$confirm" == "n" || "$confirm" == "N" ]] && exit 0
    fi

    echo ""
    log_step "开始优化..."
    echo ""

    backup_all
    configure_apt_sources
    install_base_tools
    clean_system
    optimize_memory_t6
    # BUG#1 FIX: T6 在 zram 之后才检查 swap（避免与 zram 冲突）
    configure_swap
    configure_sysctl_t6
    configure_conntrack_hashsize_t6
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
    optimize_arm
    optimize_network_t6
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
    if [[ "$SKIP_SOFTWARE_SCRIPT" != "true" ]]; then
        [[ "$INSTALL_DOCKER" == "true" ]] && install_docker
        [[ "$INSTALL_NODEJS" == "true" ]] && install_nodejs
        [[ "$INSTALL_DOCKER" == "true" || "$INSTALL_NODEJS" == "true" ]] && did_install=true
    else
        log_info "纯优化模式，跳过 Docker / Node.js 安装"
    fi

    run_doctor || { log_warn "诊断报告有异常，但继续完成"; }

    apt-get autoremove -y >> "$APT_LOG" 2>&1 || true
    apt-get autoclean >> "$APT_LOG" 2>&1 || true

    echo ""
    echo "========================================================================"
    echo -e "${GREEN}  ✅ NanoPC T6 v${SCRIPT_VERSION} 优化完成！${NC}"
    echo "========================================================================"
    echo ""
    echo -e "${CYAN}系统优化内容:${NC}"
    echo "  - sysctl 网络/内存参数（16GB 平衡模式）"
    echo "  - journald: 100MB 持久化"
    echo "  - /tmp: tmpfs 1GB"
    echo "  - swap: 物理swap禁用，zram保留"
    echo "  - 编译依赖: build-essential/cmake/pkg-config等"

    if [[ "$did_install" == "true" ]]; then
        echo ""
        echo -e "${CYAN}后续步骤:${NC}"
        echo "  1. reboot  ← 必须重启！"
    else
        echo ""
        echo -e "${CYAN}后续步骤:${NC}"
        echo "  1. reboot  ← 必须重启！"
        echo "  2. 安装你的软件（Docker / Xray / Nginx / agent 等）"
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

trap 'log_error "脚本异常退出 (行: ${LINENO})"; exit 1' ERR
trap 'log_warn "被中断"; exit 130' INT TERM

main "$@"
