#!/usr/bin/env bash
# =============================================================================
# VPS-youhua 通用函数库 v3.4
# 所有平台共享的函数和变量（各平台脚本 source 此文件）
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# 基础安全设置
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────────────────────
# 颜色
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_step()  { echo -e "${CYAN}[➜]${NC} $1"; }
log_debug() { [[ "${DEBUG:-0}" == "1" ]] && echo -e "${MAGENTA}[DEBUG]${NC} $1" || true; }

# ─────────────────────────────────────────────────────────────────────────────
# 全局常量（可被调用者 override）
# ─────────────────────────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="3.4"
readonly APT_LOG="/var/log/vps-youhua.log"         # 统一日志路径（所有平台共用）
readonly LOCK_FILE="/var/lock/vps-youhua.lock"      # 统一锁文件

# 系统信息（初始化为空）
SYS_MEM_MB=0; SYS_CPU_CORES=0; SYS_ARCH=""
SYS_KERNEL=""; SYS_OS_ID=""; SYS_OS_VERSION=""
SYS_DISK_TOTAL_GB=0; SYS_DISK_AVAIL_GB=0
SYS_NET_IF=""; SYS_ROOT_DISK=""
SYS_IS_SSD=false; SYS_IS_ORACLE_CLOUD=false
SYS_IS_ARMBIAN=false; SYS_IS_TF_CARD=false
PROFILE_DESC=""

# 安装选项（从环境变量读取默认值）
# ── 安装选项（所有平台统一逻辑）──────────────────────────────────────────
# SKIP_SOFTWARE_SCRIPT=true  → 跳过 Docker / Node.js / build deps
# OPTIMIZE_ONLY=true         → 等价于 SKIP_SOFTWARE_SCRIPT=true + INSTALL_DEPS=false
# --proxy-mode               → FORCE_MODE=optimize + SKIP_SOFTWARE_SCRIPT=true + OPTIMIZE_ONLY=true
INSTALL_DEPS="${INSTALL_DEPS:-true}"         # 基础编译依赖（可被 --install-deps 覆盖）
INSTALL_DOCKER="${INSTALL_DOCKER:-false}"    # Docker（需显式开启）
INSTALL_NODEJS="${INSTALL_NODEJS:-false}"   # Node.js（需显式开启）
SKIP_SOFTWARE_SCRIPT="${SKIP_SOFTWARE_SCRIPT:-false}"
OPTIMIZE_ONLY="${OPTIMIZE_ONLY:-false}"

# OPTIMIZE_ONLY=true 时联动跳过所有软件安装
if [[ "${OPTIMIZE_ONLY}" == "true" ]]; then
    SKIP_SOFTWARE_SCRIPT="true"
    INSTALL_DEPS="false"
fi

# ── 代理节点专用模式（低资源平台推荐）──────────────────────────────────
CONFIGURE_PROXY_ONLY="${CONFIGURE_PROXY_ONLY:-false}"   # 代理节点专用（仅环境优化，不装重软件）

# 平台标识（各平台脚本必须定义，source前已设置）
# 只在未定义时才设置（避免与平台脚本的readonly冲突）
if [[ -z "${PLATFORM_NAME:-}" ]]; then
    readonly PLATFORM_NAME="unknown"
fi
if [[ -z "${PLATFORM_DESC:-}" ]]; then
    readonly PLATFORM_DESC="unknown"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 并发锁
# ─────────────────────────────────────────────────────────────────────────────
acquire_lock() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log_error "另一个实例正在运行，退出"
        exit 1
    fi
}

# ── 幂等检查：重复运行提示 ───────────────────────────────────────────────
check_idempotent() {
    if [[ -f /etc/vps-youhua-optimized ]] && [[ "${FORCE_REAPPLY:-false}" != "true" ]]; then
        log_warn "检测到系统已优化（/etc/vps-youhua-optimized 存在）"
        if [[ -t 0 ]]; then
            echo -n "  是否重新应用优化？(y/N，默认 N): "
            read -r -t 30 confirm || confirm="N"
            confirm="${confirm,,}"
            if [[ "$confirm" != "y" ]]; then
                log_info "跳过，已运行过优化"
                exit 0
            fi
            log_info "重新应用中..."
        else
            log_warn "非交互模式，跳过幂等检查（使用 FORCE_REAPPLY=true 强制重试）"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 初始化（各平台 main() 开头调用）
# ─────────────────────────────────────────────────────────────────────────────
init_script() {
    acquire_lock
    export DEBIAN_FRONTEND=noninteractive
    mkdir -p "$(dirname "$APT_LOG")"
    mkdir -p /var/lock /var/log
    truncate -s 0 "$APT_LOG" 2>/dev/null || : > "$APT_LOG"
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

    SYS_OS_ID=$(awk -F'["= ]' '/^ID=/ {print $2; exit}' /etc/os-release 2>/dev/null || echo "unknown")
    SYS_OS_VERSION=$(awk -F'["= ]' '/^VERSION_ID=/ {print $2; exit}' /etc/os-release 2>/dev/null || echo "unknown")

    SYS_DISK_TOTAL_GB=$(df -BG / 2>/dev/null | awk 'NR==2 {print $2}' | tr -d 'G' || echo 0)
    SYS_DISK_AVAIL_GB=$(df -BG / 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G' || echo 0)

    SYS_NET_IF=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}' || true)
    [[ -z "$SYS_NET_IF" ]] && SYS_NET_IF=$(ip -6 route show default 2>/dev/null | awk '/default/{print $5; exit}' || true)

    # 检测 Armbian
    [[ -f /etc/armbian-release ]] && SYS_IS_ARMBIAN=true

    log_info "系统: ${SYS_OS_ID} ${SYS_OS_VERSION}"
    log_info "架构: ${SYS_ARCH} | 内存: ${SYS_MEM_MB}MB | CPU: ${SYS_CPU_CORES}核"

    # ── 低内存自动检测（2GB 以下）───────────────────────────────────
    IS_LOW_MEMORY=false
    if [[ ${SYS_MEM_MB:-0} -gt 0 ]] && [[ ${SYS_MEM_MB} -lt 2048 ]]; then
        IS_LOW_MEMORY=true
        export IS_LOW_MEMORY
        log_info "检测到低内存（${SYS_MEM_MB}MB），已启用低资源优化模式"
    fi
    [[ "$SYS_IS_ARMBIAN" == "true" ]] && log_info "Armbian 检测通过" || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Oracle Cloud 检测
# ─────────────────────────────────────────────────────────────────────────────
detect_oracle_cloud() {
    if grep -qi "oracle" /sys/class/dmi/id/sys_vendor 2>/dev/null || \
       grep -qi "oracle" /sys/class/dmi/id/product_name 2>/dev/null; then
        SYS_IS_ORACLE_CLOUD=true
        log_info "Oracle Cloud 环境检测通过"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 网络检测
# ─────────────────────────────────────────────────────────────────────────────
check_network() {
    log_step "检测网络连接..."

    # 国内可达目标优先（避免 8.8.8.8 在大陆受干扰导致误判）
    if ping -c1 -W3 1.1.1.1 &>/dev/null || \
       ping -c1 -W3 223.5.5.5 &>/dev/null; then
        log_info "网络连接正常"
        return 0
    fi

    # 二级降级：DNS 解析测试
    if ! host -W3 debian.org &>/dev/null; then
        # 三级降级：HTTPS HEAD 检查
        if ! curl --connect-timeout 5 -s -o /dev/null -w "%{http_code}" \
            https://deb.debian.org/ 2>/dev/null | grep -qE "200|301|302"; then
            log_error "无法连接到网络，请检查网络配置"
            exit 1
        fi
    fi
    log_info "网络连接正常"
}

# ─────────────────────────────────────────────────────────────────────────────
# 预检查
# ─────────────────────────────────────────────────────────────────────────────
preflight_check() {
    log_step "执行预检查..."

    local errors=0

    if [[ $EUID -ne 0 ]]; then
        log_error "需要 root 权限"
        errors=$((errors + 1))
    fi

    if [[ $SYS_DISK_AVAIL_GB -lt 3 ]]; then
        log_warn "磁盘可用空间 ${SYS_DISK_AVAIL_GB}GB < 3GB"
        [[ $SYS_DISK_AVAIL_GB -lt 1 ]] && errors=$((errors + 1))
    fi

    if [[ $SYS_MEM_MB -lt 256 ]]; then
        log_warn "内存 ${SYS_MEM_MB}MB < 256MB，可能不稳定"
    fi

    if ! ping -c1 -W3 1.1.1.1 &>/dev/null && \
       ! ping -c1 -W3 223.5.5.5 &>/dev/null; then
        log_warn "无法访问互联网，部分功能可能受限"
    fi

    [[ $errors -gt 0 ]] && exit 1
    log_info "预检查通过"
}

# ─────────────────────────────────────────────────────────────────────────────
# 文件备份
# ─────────────────────────────────────────────────────────────────────────────
backup_file() {
    local file="$1"
    [[ -f "$file" ]] && cp -a "$file" "${file}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# 全量备份（回滚机制，保留最近5份）
# ─────────────────────────────────────────────────────────────────────────────
backup_all() {
    log_step "备份当前配置（回滚用）..."
    local backup_dir="/var/backups/vps-youhua"
    mkdir -p "$backup_dir"
    local ts; ts=$(date +%Y%m%d_%H%M%S)

    [[ -d /etc/sysctl.d ]] && cp -a /etc/sysctl.d "$backup_dir/sysctl.d_${ts}" 2>/dev/null || true
    [[ -d /etc/systemd/system.conf.d ]] && cp -a /etc/systemd/system.conf.d "$backup_dir/system.conf.d_${ts}" 2>/dev/null || true
    [[ -d /etc/systemd/journald.conf.d ]] && cp -a /etc/systemd/journald.conf.d "$backup_dir/journald.conf.d_${ts}" 2>/dev/null || true
    [[ -f /etc/fstab ]] && cp -a /etc/fstab "$backup_dir/fstab_${ts}" 2>/dev/null || true
    [[ -f /etc/security/limits.conf ]] && cp -a /etc/security/limits.conf "$backup_dir/limits.conf_${ts}" 2>/dev/null || true
    [[ -f /etc/default/cpufrequtils ]] && cp -a /etc/default/cpufrequtils "$backup_dir/cpufrequtils_${ts}" 2>/dev/null || true
    [[ -f /etc/docker/daemon.json ]] && cp -a /etc/docker/daemon.json "$backup_dir/daemon.json_${ts}" 2>/dev/null || true

    # 清理超过5份的旧备份
    find "$backup_dir" -maxdepth 1 -type d -name "*_[0-9]*" | sort -r | tail -n +6 | xargs -r rm -rf 2>/dev/null || true
    log_info "备份已保存至 $backup_dir（最近5份）"
}

# ─────────────────────────────────────────────────────────────────────────────
# 重启提示
# ─────────────────────────────────────────────────────────────────────────────
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
    if [[ -t 0 ]]; then
        echo "立即重启？[y/N]"
        echo -n "→ "
        read -r yn
        [[ "$yn" =~ ^[Yy]$ ]] && reboot || true
    fi
}
# ─────────────────────────────────────────────────────────────────────────────
# APT 配置（自动地区检测选择最快源）
# CONFIGURE_MIRROR: "auto"(自动) | "official"(官方) | "tencent"(腾讯) | "ali"(阿里) | "tsinghua"(清华)
# ─────────────────────────────────────────────────────────────────────────────
configure_apt_sources() {
    log_step "配置 APT 源..."

    local sources_list="/etc/apt/sources.list"
    local codename
    codename=$(awk -F'["=]' '/^VERSION_CODENAME=/ {print $2; exit}' /etc/os-release 2>/dev/null || echo "bookworm")

    backup_file "$sources_list"

    mkdir -p /etc/apt/apt.conf.d /etc/needrestart/conf.d
    cat > /etc/apt/apt.conf.d/99-noninteractive <<'EOF'
DPkg::Options {
"--force-confdef"; "--force-confold";};
APT::Get::Assume-Yes "true";
APT::Get::Fix-Missing "true";
EOF
    cat > /etc/needrestart/conf.d/99-vps-youhua.conf <<'EOF'
$nrconf{restart} = 'a';
$nrconf{kernelhints} = 0;
$nrconf{unneeded} = 'a';
EOF

    # CONFIGURE_MIRROR: auto=测速选源, off=仅配APT参数, preserve=保留原源
    local mirror_mode="${CONFIGURE_MIRROR:-auto}"
    local selected_mirror=""

    if [[ "$mirror_mode" == "off" ]]; then
        log_info "跳过 APT 镜像切换（保持系统默认源）"
        if ! apt-get update -qq >> "$APT_LOG" 2>&1; then
            log_warn "APT 更新失败"
        fi
        log_info "APT 源配置完成（仅配置参数）"
        return 0
    fi

    if [[ "$mirror_mode" == "preserve" ]]; then
        log_info "保留原始 sources.list，不做任何更改"
        if ! apt-get update -qq >> "$APT_LOG" 2>&1; then
            log_warn "APT 更新失败"
        fi
        return 0
    fi

    # 幂等性检查：若已标记为已配置，跳过镜像切换（仅保留 apt-get update）
    local apt_marker="/etc/vps-youhua-apt-sources-configured"
    if [[ -f "$apt_marker" ]]; then
        log_info "APT 源已配置，跳过镜像切换"
        if ! apt-get update -qq >> "$APT_LOG" 2>&1; then
            log_warn "APT 更新失败"
        fi
        return 0
    fi

    # 地区检测函数
    auto_select_mirror() {
        local latencies=""
        local mirrors="tencent:mirrors.tencent.com,ali:mirrors.aliyun.com,tsinghua:mirrors.tuna.tsinghua.edu.cn,official:deb.debian.org"
        local fastest=""
        local fastest_ms=9999

        for m in ${mirrors//,/ }; do
            local name="${m%%:*}"
            local host="${m#*:}"
            local ms; ms=$(curl --connect-timeout 3 -s -o /dev/null -w "%{time_total}" "http://${host}/debian/" 2>/dev/null | awk '{printf "%.0f", $1*1000}')
            # 防御：确保 ms 是有效数字（curl 失败或 awk 无输出时跳过）
            [[ -n "$ms" && "$ms" =~ ^[0-9]+$ && "$ms" -gt 0 ]] || continue
            [[ $ms -lt $fastest_ms ]] && fastest_ms=$ms && fastest=$name
        done

        if [[ -n "$fastest" ]]; then
            echo "$fastest"
        else
            echo "official"
        fi
    }

    if [[ "$mirror_mode" == "auto" ]]; then
        log_info "正在测速选择最快镜像..."
        mirror_mode=$(auto_select_mirror)
        log_info "最快镜像: $mirror_mode"
    fi

    write_mirror() {
        local m="$1"
        case "$m" in
            tencent)
                cat > "$sources_list" <<EOF
deb https://mirrors.tencent.com/debian/ ${codename} main contrib non-free-firmware
deb https://mirrors.tencent.com/debian/ ${codename}-updates main contrib non-free-firmware
deb https://mirrors.tencent.com/debian-security/ ${codename}-security main contrib non-free-firmware
deb https://mirrors.tencent.com/debian/ ${codename}-backports main contrib non-free-firmware
EOF
                ;;
            ali)
                cat > "$sources_list" <<EOF
deb https://mirrors.aliyun.com/debian/ ${codename} main contrib non-free-firmware
deb https://mirrors.aliyun.com/debian/ ${codename}-updates main contrib non-free-firmware
deb https://mirrors.aliyun.com/debian-security/ ${codename}-security main contrib non-free-firmware
deb https://mirrors.aliyun.com/debian/ ${codename}-backports main contrib non-free-firmware
EOF
                ;;
            tsinghua)
                cat > "$sources_list" <<EOF
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ ${codename} main contrib non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ ${codename}-updates main contrib non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian-security/ ${codename}-security main contrib non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ ${codename}-backports main contrib non-free-firmware
EOF
                ;;
            official|*)
                cat > "$sources_list" <<EOF
deb https://deb.debian.org/debian ${codename} main contrib non-free-firmware
deb https://deb.debian.org/debian ${codename}-updates main contrib non-free-firmware
deb https://security.debian.org/debian-security ${codename}-security main contrib non-free-firmware
deb https://deb.debian.org/debian ${codename}-backports main contrib non-free-firmware
EOF
                ;;
        esac
    }

    write_mirror "$mirror_mode"

    # 如果选定源不可用，自动 fallback 到官方
    # 从 sources.list 提取 URL 时去掉协议前缀和路径（只保留域名）
    local mirror_url
    mirror_url=$(grep -m1 "^deb " "$sources_list" | awk '{print $2}')
    mirror_url="${mirror_url#http://}"
    mirror_url="${mirror_url#https://}"
    mirror_url="${mirror_url%%/*}"  # 去掉路径部分，只保留域名
    if ! curl --connect-timeout 5 -sf "https://${mirror_url}/" > /dev/null 2>&1; then
        log_warn "镜像 ${mirror_mode} 不可用，fallback 到官方源..."
        write_mirror official
    fi

    # Armbian 源保护：如果检测到 Armbian，保留 armbian.list 不动
    if [[ -f /etc/apt/sources.list.d/armbian.list ]]; then
        log_info "检测到 Armbian 专用源，跳过 sources.list 替换"
    fi

    if ! apt-get update -qq >> "$APT_LOG" 2>&1; then
        log_warn "APT 源更新失败，保留原有配置"
    fi

    log_info "APT 源配置完成"
    touch "$apt_marker"
}

# ─────────────────────────────────────────────────────────────────────────────
# 系统清理
# ─────────────────────────────────────────────────────────────────────────────
clean_system() {
    log_step "清理系统..."

    # BUG 修复: 防止 APT 锁死冲突（DD 镜像 / 刚开机的 Debian 12）
    # apt-daily / apt-daily-upgrade 在后台运行会持有 dpkg 锁导致 apt-get 失败
    local apt_svcs=(apt-daily apt-daily-upgrade unattended-upgrades)
    for svc in "${apt_svcs[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            log_info "停止后台 APT 服务: $svc"
            systemctl stop "$svc" 2>/dev/null || true
        fi
        systemctl mask "$svc" 2>/dev/null || true
    done

    # 关闭常见干扰服务（仅当服务存在且处于激活状态时才停止）
    local stop_svcs=(snapd apache2 nginx postfix exim4 ufw)
    for svc in "${stop_svcs[@]}"; do
        if systemctl list-unit-files "$svc.service" 2>/dev/null | grep -q "$svc.service"; then
            systemctl is-active --quiet "$svc" 2>/dev/null && {
                log_info "停止干扰服务: $svc"
                systemctl stop "$svc" 2>/dev/null || true
            }
            systemctl disable "$svc" 2>/dev/null || true
        fi
    done

    # Oracle Cloud 专属清理（节省资源 + 减少磁盘写入）
    if [[ "$SYS_IS_ORACLE_CLOUD" == "true" ]]; then
        log_info "Oracle Cloud 环境：清理云监控组件..."
        systemctl disable --now oracle-cloud-agent oracle-cloud-agent-updater 2>/dev/null || true
        systemctl mask oracle-cloud-agent oracle-cloud-agent-updater 2>/dev/null || true
        # cloud-init 保留（用户可能需要），但禁用其网络探测
        mkdir -p /etc/cloud/cloud.cfg.d
        cat > /etc/cloud/cloud.cfg.d/99-disable-net.cfg <<'EOF'
network:
  config: disabled
EOF
        log_info "Oracle 云监控已禁用（节省资源）"
    fi

    # 可选 purge（仅当明确指定时）
    if [[ "${CLEAN_SYSTEM:-false}" == "true" ]]; then
        local remove_pkgs=(snapd apache2-bin apache2-utils nginx nginx-light nginx-full postfix exim4-base exim4-config)
        local to_remove
        to_remove=$(dpkg -l "${remove_pkgs[@]}" 2>/dev/null | awk '/^ii/{print $2}')
        [[ -n "$to_remove" ]] && apt-get remove --purge -y $to_remove >> "$APT_LOG" 2>&1 || true
    fi

    apt-get autoremove -y >> "$APT_LOG" 2>&1 || true
    apt-get autoclean >> "$APT_LOG" 2>&1 || true
    log_info "系统清理完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# 基础工具（通用）
# ─────────────────────────────────────────────────────────────────────────────
install_base_tools() {
    log_step "安装基础工具..."

    # 通用工具（任何环境都需要）
    local basic_tools=(
        curl wget git jq vim htop net-tools dnsutils
        traceroute mtr iptraf-ng iftop iperf3 sysstat
        ncdu tree rsync tmux unzip zip
        ca-certificates gnupg lsb-release apt-transport-https
        dirmngr ethtool pciutils bc dc cron
    )
    install_if_missing "${basic_tools[@]}"

    # BUG 修复: DD 镜像根证书断层
    # DD 出来的 Debian 可能证书链不完整，强制刷新
    if command -v update-ca-certificates &>/dev/null; then
        update-ca-certificates 2>/dev/null || true
    fi

    # 编译依赖（任何 agent 安装脚本都需要）
    local compile_tools=(
        build-essential cmake pkg-config libssl-dev
        python3-venv python3-dev python3-pip
        libffi-dev libxml2-dev libxslt1-dev zlib1g-dev
    )
    install_if_missing "${compile_tools[@]}"

    log_info "基础工具安装完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# 安装缺失的包（内部函数）
# ─────────────────────────────────────────────────────────────────────────────
install_if_missing() {
    local to_install=()
    for tool in "$@"; do
        command -v "$tool" &>/dev/null || to_install+=("$tool")
    done
    [[ ${#to_install[@]} -gt 0 ]] && {
        apt-get install -y --no-install-recommends "${to_install[@]}" >> "$APT_LOG" 2>&1
        log_info "已安装 ${#to_install[@]} 个缺失工具"
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
FallbackDNS=1.0.0.1 8.8.4.4 119.29.29.29
DNSSEC=no
DNSOverTLS=no
DNSStubListener=no
ReadEtcHosts=yes
EOF
    systemctl restart systemd-resolved 2>/dev/null || true
    systemctl enable systemd-resolved 2>/dev/null || true

    # DNS 防篡改：锁定 resolv.conf（百毒不侵核心）
    # 注意：systemd-resolved 激活时不能 chattr +i（由systemd管理）
    if [[ -f /etc/resolv.conf ]]; then
        local resolved_active=false
        if systemctl is-active systemd-resolved > /dev/null 2>&1; then
            resolved_active=true
        fi
        if [[ "$resolved_active" == "true" ]]; then
            log_info "DNS 由 systemd-resolved 管理，跳过 chattr +i"
        else
            if ! lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i'; then
                chattr -i /etc/resolv.conf 2>/dev/null || true
                chattr +i /etc/resolv.conf 2>/dev/null || log_warn "chattr +i 失败（权限不足）"
                log_info "DNS 配置已锁定（chattr +i）"
            fi
        fi
    fi

    log_info "DNS 配置完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# 防火墙：lo 网卡无脑放行
# ─────────────────────────────────────────────────────────────────────────────
configure_firewall_lo() {
    log_step "配置防火墙 lo 网卡放行..."
    if ! command -v iptables &>/dev/null; then
        log_info "iptables 未安装，跳过"
        return 0
    fi

    iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || iptables -A INPUT -i lo -j ACCEPT
    iptables -C OUTPUT -o lo -j ACCEPT 2>/dev/null || iptables -A OUTPUT -o lo -j ACCEPT
    log_info "lo 网卡已无脑放行"

    # BUG#FIX: iptables 规则持久化（重启后保留）
    # M4 FIX: 不再自动安装 iptables-persistent（会触发交互提示）
    # 用户如有需要可手动安装，或确保 iptables-save 能在启动时自动加载
    mkdir -p /etc/iptables
    if command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        log_info "iptables 规则已保存（/etc/iptables/rules.v4）"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# npm/pip 缓存指向 tmpfs（减少磁盘写入）
# ─────────────────────────────────────────────────────────────────────────────
configure_npm_cache_tmpfs() {
    log_step "配置 npm/pip 缓存到 tmpfs..."
    local cache_dir="/tmp/agent_cache"
    mkdir -p "$cache_dir"
    chmod 1777 "$cache_dir"

    local profile_file="/etc/profile.d/99-agent-cache.sh"
    local marker="# VPS-youhua agent cache config"
    mkdir -p /etc/profile.d

    # 防重复：检查是否已配置
    if [[ -f "$profile_file" ]] && grep -q "$marker" "$profile_file" 2>/dev/null; then
        log_info "npm/pip 缓存配置已存在（跳过）"
    else
        cat > "$profile_file" <<'EOFCACHE'
# VPS-youhua agent cache config
export npm_config_cache="/tmp/agent_cache"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/agent_cache}"
export PIP_CACHE_DIR="/tmp/agent_cache/pip"
EOFCACHE
        chmod +x "$profile_file"
        log_info "npm/pip 缓存已指向 $cache_dir"
    fi

    export npm_config_cache="/tmp/agent_cache"
    export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/agent_cache}"
}

# ─────────────────────────────────────────────────────────────────────────────
# systemd 内存统计（防止内存泄漏拖死系统）
# ─────────────────────────────────────────────────────────────────────────────
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

# ─────────────────────────────────────────────────────────────────────────────
# 时间同步（Chrony）
# ─────────────────────────────────────────────────────────────────────────────
configure_time_sync() {
    log_step "配置时间同步..."

    if ! command -v chronyd &>/dev/null; then
        apt-get install -y chrony >> "$APT_LOG" 2>&1 || true
    fi

    # NTP 服务器池（智能选择）
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

# ─────────────────────────────────────────────────────────────────────────────
# Locale 配置
# ─────────────────────────────────────────────────────────────────────────────
configure_locale() {
    log_step "配置 Locale..."
    if [[ -f /etc/locale.gen ]] && ! grep -q "^en_US.UTF-8 UTF-8" /etc/locale.gen 2>/dev/null; then
        sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen 2>/dev/null || true
        locale-gen >> "$APT_LOG" 2>&1 || true
    fi
    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 2>/dev/null || true
    export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
    log_info "Locale 配置完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG#1 FIX: 低内存机器自动创建 1GB Swap（GCP/1C1G 代理节点必选）
# 适用: RAM < 1024MB 且无 Swap 的机器
# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
# 文件句柄 / 资源限制
# ─────────────────────────────────────────────────────────────────────────────
configure_limits() {
    log_step "配置资源限制..."

    # ── 内存检测 ─────────────────────────────────────────────────────────────
    local sys_mem_kb sys_mem_mb
    sys_mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    sys_mem_mb=$((sys_mem_kb / 1024))
    IS_LOW_MEMORY=false
    [[ "${SYS_MEM_MB:-0}" -gt 0 ]] && [[ "${SYS_MEM_MB}" -lt 2048 ]] && IS_LOW_MEMORY=true

    # ── 句柄数动态配置（BUG#2: RAM<2048MB → 限制在 65535 防止内核崩溃）────────
    local NOFILE_VAL NPROC_VAL
    if [[ "${IS_LOW_MEMORY}" == "true" ]]; then
        NOFILE_VAL=65535
        NPROC_VAL=65535
        log_info "低内存机器，句柄数限制为 ${NOFILE_VAL}"
    else
        NOFILE_VAL=1048576
        NPROC_VAL=131072
    fi

    # 立即生效
    ulimit -n ${NOFILE_VAL}
    ulimit -u ${NPROC_VAL}
    ulimit -m unlimited
    [[ -f /proc/sys/fs/inotify/max_user_watches ]] && echo 524288 > /proc/sys/fs/inotify/max_user_watches 2>/dev/null || true

    # 持久化（幂等性检查）
    local limits_conf="/etc/security/limits.d/99-vps-youhua.conf"
    mkdir -p /etc/security/limits.d
    if [[ -f "$limits_conf" ]] && grep -q "vps-youhua" "$limits_conf" 2>/dev/null; then
        log_info "资源限制已配置，跳过"
    else
        cat > "$limits_conf" <<EOF
root soft nofile ${NOFILE_VAL}
root hard nofile ${NOFILE_VAL}
root soft nproc ${NPROC_VAL}
root hard nproc ${NPROC_VAL}
* soft nofile ${NOFILE_VAL}
* hard nofile ${NOFILE_VAL}
* soft nproc ${NPROC_VAL}
* hard nproc ${NPROC_VAL}
# vps-youhua
EOF
    fi

    # systemd 级别（幂等性检查）
    local systemd_conf="/etc/systemd/system.conf.d/99-resource-limits.conf"
    mkdir -p /etc/systemd/system.conf.d
    if [[ -f "$systemd_conf" ]] && grep -q "vps-youhua" "$systemd_conf" 2>/dev/null; then
        log_info "systemd 资源限制已配置，跳过"
    else
        cat > "$systemd_conf" <<EOF
[Manager]
DefaultLimitNOFILE=infinity
DefaultLimitNPROC=${NPROC_VAL}:${NPROC_VAL}
DefaultLimitMEMLOCK=infinity
# vps-youhua
EOF
    fi
    systemctl daemon-reload 2>/dev/null || true

    # ── BUG#1: RAM<=1024MB 自动创建 1GB Swap（防止 GCP/1C1G OOM）──────────────
    if [[ "${IS_LOW_MEMORY}" == "true" ]]; then
        if declare -f configure_swap > /dev/null 2>&1; then
            configure_swap
        fi
    fi

    log_info "资源限制配置完成（nofile=${NOFILE_VAL}, nproc=${NPROC_VAL}）"
}

# ─────────────────────────────────────────────────────────────────────────────
# OPTIMIZE #13: fstab 统一加 noatime,nodiratime + fsck 自动修复
# 适用: 所有平台（TF卡/SSD/eMMC/云盘统一）
# ─────────────────────────────────────────────────────────────────────────────
configure_fstab() {
    log_step "配置 fstab（noatime + fsck）..."

    [[ ! -f /etc/fstab ]] && log_warn "/etc/fstab 不存在，跳过" && return 0

    local fstab_changed=false

    # 备份
    cp -a /etc/fstab /etc/fstab.vps-youhua-bak 2>/dev/null || true

    # 遍历所有 ext4/xfs 分区，添加 noatime,nodiratime
    # fstab格式: <device> <mount> <type> <options> <dump> <pass>
    # 规则: 第5列(dump)保持不变，第6列(pass)改为 1(root) 或 2(其他)
    while IFS= read -r line; do
        # 跳过注释和空行
        [[ "$line" =~ ^#.*$ ]] && continue
        [[ -z "$line" ]] && continue

        # 解析: LABEL=/ /dev/sda1 UUID=xxx 等
        local dev mnt fs_type opts dump pass
        dev=$(echo "$line" | awk '{print $1}')
        mnt=$(echo "$line" | awk '{print $2}')
        fs_type=$(echo "$line" | awk '{print $3}')
        opts=$(echo "$line" | awk '{print $4}')
        dump=$(echo "$line" | awk '{print $5}')
        pass=$(echo "$line" | awk '{print $6}')

        # 仅处理 ext4/xfs/btrfs
        [[ "$fs_type" != "ext4" && "$fs_type" != "xfs" && "$fs_type" != "btrfs" ]] && continue

        # 如果是 / (root)，pass 改为 1（开机 fsck）
        # 其他分区 pass 改为 2
        [[ "$mnt" == "/" ]] && pass="1" || pass="2"

        # 添加 noatime,nodiratime（如果尚未存在）
        if [[ "$opts" != *"noatime"* ]]; then
            opts="${opts},noatime"
        fi
        if [[ "$opts" != *"nodiratime"* ]]; then
            opts="${opts},nodiratime"
        fi
        # 去重逗号
        opts=$(echo "$opts" | sed 's/,,/,/g; s/^,//; s/,$//')

        # 重建行
        local new_line="${dev} ${mnt} ${fs_type} ${opts} ${dump} ${pass}"
        # 替换原行（转义设备路径中的正则元字符，避免误匹配）
        local escaped_dev
        # 修复: 使用 awk 代替有问题的 sed 避免字符类解析问题
        if grep -qF "$dev " /etc/fstab 2>/dev/null; then
            awk -v dev="$dev" -v newline="$new_line" '
                BEGIN { found=0 }
                $1 == dev { print newline; found=1; next }
                { print }
            ' /etc/fstab > /etc/fstab.tmp && mv /etc/fstab.tmp /etc/fstab && test -f /etc/fstab && chmod 644 /etc/fstab
            fstab_changed=true
        fi
    done < /etc/fstab

    if [[ "$fstab_changed" == "true" ]]; then
        log_info "fstab 已更新: noatime,nodiratime 已添加，fsck pass 已配置"
    else
        log_info "fstab 无需更改（已是最优配置）"
    fi
}


# ─────────────────────────────────────────────────────────────────────────────
# BUG#5: IPv6 黑洞检测 — 若 ping6 失败则强制禁用 IPv6
# 美国低端/免费 VPS 的 IPv6 路由常损坏，会导致代理请求超时
# ─────────────────────────────────────────────────────────────────────────────
configure_ipv6_health() {
    log_step "IPv6 连通性检测..."

    # 先检查 IPv6 是否已禁用
    if grep -q "net.ipv6.conf.all.disable_ipv6 = 1" /etc/sysctl.d/99-vps-youhua*.conf 2>/dev/null; then
        log_info "IPv6 已禁用，跳过"
        return 0
    fi

    # 检测 IPv6 是否通（允许超时）
    # 优先使用 ping6，fallback 到 ping -6
    local ping_cmd="ping6"
    if ! command -v ping6 &>/dev/null; then
        ping_cmd="ping -6"
    fi
    
    if $ping_cmd -c 1 -W 2 ipv6.google.com >/dev/null 2>&1; then
        log_info "IPv6 连通正常，保持开启"
    else
        log_warn "IPv6 黑洞检测失败（ping6 超时），强制禁用 IPv6"

        # 写入 sysctl
        mkdir -p /etc/sysctl.d
        cat >> /etc/sysctl.d/99-vps-youhua-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
        sysctl -w net.ipv6.conf.all.disable_ipv6=1 2>/dev/null || true
        sysctl -w net.ipv6.conf.default.disable_ipv6=1 2>/dev/null || true
        sysctl -w net.ipv6.conf.lo.disable_ipv6=1 2>/dev/null || true
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG#7: DNS 锁定防篡改
# ─────────────────────────────────────────────────────────────────────────────
configure_dns_lock() {
    log_step "加固 DNS 配置（防篡改）..."

    # 检查是否已被锁定（幂等性）
    if lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i'; then
        log_info "DNS 已锁定（chattr +i），跳过"
        return 0
    fi

    # 检查 systemd-resolved（不能对由systemd管理的文件加immutable，也不能覆盖其管理的resolv.conf）
    local resolved_active=false
    if systemctl is-active systemd-resolved > /dev/null 2>&1; then
        resolved_active=true
    fi
    if [[ "$resolved_active" == "true" ]]; then
        log_info "DNS 由 systemd-resolved 管理，跳过 chattr +i 和 resolv.conf 覆盖"
        return 0
    fi

    # 备份
    cp -a /etc/resolv.conf /etc/resolv.conf.vps-youhua-bak 2>/dev/null || true

    # 写入可信 DNS
    cat > /etc/resolv.conf <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 2001:4860:4860::8888
EOF

    # 防止 DHCP/云厂商自动覆盖（BUG#7 核心修复）
    chattr +i /etc/resolv.conf 2>/dev/null || true
    log_info "DNS 已锁定（1.1.1.1 + 8.8.8.8），chattr +i 保护"
    log_info "提示：卸载时需要 chattr -i /etc/resolv.conf 解锁"
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG#10: 低内存极限清理
# ─────────────────────────────────────────────────────────────────────────────
configure_lowmem_purge() {
    log_step "低内存极限清理（释放 ~100MB）..."

    local PKGS_TO_REMOVE="rpcbind apache2 snapd ufw"
    local removed=false

    for pkg in ${PKGS_TO_REMOVE}; do
        if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            log_info "  移除 $pkg（释放内存）"
            apt-get purge -y "$pkg" >/dev/null 2>&1 && removed=true || true
        fi
    done

    [[ "$removed" == "true" ]] && log_info "低内存清理完成（释放约 100MB）" || log_info "无需清理（这些包未安装）"
}

# ─────────────────────────────────────────────────────────────────────────────
# conntrack hashsize 配置（所有平台通用部分）
# AUDIT-2 FIX: nf_conntrack_hashsize 是只读参数，不能通过 sysctl 设置
# 通过 /sys/module/nf_conntrack/parameters/hashsize 设置（需先加载模块）
# modprobe 失败时回退到 /etc/modprobe.d/ 配置（下次启动生效）
# ─────────────────────────────────────────────────────────────────────────────
configure_conntrack_hashsize() {
    # CT_MAX 由调用者定义（各平台不同）
    local CT_MAX="${CT_MAX:-65536}"
    local hashsize=$((CT_MAX / 4))
    local hashsize_file="/sys/module/nf_conntrack/parameters/hashsize"

    log_step "配置 nf_conntrack_hashsize..."

    # 确保模块已加载（modprobe 失败不算致命错误，继续尝试直接写入）
    if ! modprobe nf_conntrack 2>/dev/null; then
        log_warn "nf_conntrack 模块加载失败（可能已内置或内核不支持）"
    fi

    if [[ -f "$hashsize_file" ]]; then
        if ! echo "$hashsize" > "$hashsize_file" 2>/dev/null; then
            log_warn "nf_conntrack_hashsize 运行时设置失败，写入 modprobe 配置（下次启动生效）"
            mkdir -p /etc/modprobe.d
            echo "options nf_conntrack hashsize=$hashsize" > /etc/modprobe.d/nf_conntrack.conf
        fi
        local current_hashsize
        current_hashsize=$(cat "$hashsize_file" 2>/dev/null || echo "unknown")
        log_info "nf_conntrack_hashsize 已设置: ${current_hashsize}"
    else
        log_warn "nf_conntrack 模块未加载或不支持，跳过 hashsize 配置"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG#5: configure_swap 实现（低内存机器自动创建 1GB Swap）
# ─────────────────────────────────────────────────────────────────────────────
configure_swap() {
    log_step "配置 Swap（低内存防护）..."

    # 幂等性检查：如果已有活跃 swap，跳过（不论来源）
    local swap_active
    swap_active=$(swapon --show 2>/dev/null | tail -n +2 | wc -l)
    if [[ "${swap_active}" -gt 0 ]]; then
        log_info "Swap 已活跃（${swap_active} device），跳过"
        return 0
    fi

    # 检查是否已有物理 swap 或 zram
    local swap_total zram_total=0
    swap_total=$(awk '/SwapTotal/{print $2}' /proc/meminfo 2>/dev/null || echo "0")
    # zram 也算 Swap（/proc/meminfo 的 Swap 统计不包含 zram，需手动计算）
    # disksize 单位是字节，除以 1024 得到 KB
    if [[ -d /sys/block/zram0 ]] && [[ -f /sys/block/zram0/disksize ]]; then
        local zram_size
        zram_size=$(cat /sys/block/zram0/disksize 2>/dev/null || echo "0")
        zram_total=$((zram_size / 1024))  # KB
    fi
    local total_swap=$((swap_total + zram_total))
    if [[ "${total_swap}" -gt 0 ]]; then
        log_info "Swap 已存在（物理: ${swap_total}KB + zram: ${zram_total}KB），跳过"
        return 0
    fi

    # Round 10 Fix: Add disk space threshold check (1500MB minimum for swapfile)
    # 检查磁盘空间（至少需要 1.5GB 可用空间，为 1GB swapfile 留出安全余量）
    local available_mb
    available_mb=$(df -BM / 2>/dev/null | awk 'NR==2 {gsub(/M/,"",$4); print $4}')
    if [[ "${available_mb}" -lt 1500 ]]; then
        log_warn "磁盘空间不足（可用: ${available_mb}MB < 1500MB），跳过 Swap 创建"
        return 0
    fi

    log_info "检测到无 Swap，创建 1GB swapfile..."

    # 创建 1GB swapfile
    if fallocate -l 1G /swapfile 2>/dev/null; then
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1 || { log_warn "mkswap 失败"; rm -f /swapfile; return 1; }
        swapon /swapfile || { log_warn "swapon 失败"; rm -f /swapfile; return 1; }
    elif dd if=/dev/zero of=/swapfile bs=1M count=1024 2>/dev/null; then
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1 || { log_warn "mkswap 失败"; rm -f /swapfile; return 1; }
        swapon /swapfile || { log_warn "swapon 失败"; rm -f /swapfile; return 1; }
    else
        log_warn "Swap 创建失败，跳过"
        return 1
    fi

    # 持久化 fstab
    if ! grep -q "/swapfile" /etc/fstab 2>/dev/null; then
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi

    # 创建标记文件，记录本脚本已创建 swap
    local swap_marker="/etc/vps-youhua-swap-created"
    touch "$swap_marker"

    # swappiness 由各平台 sysctl 持久化配置控制（vm.swappiness 在 /etc/sysctl.d/ 里统一设置）
    log_info "Swap 1GB 创建完成"
}

# ─────────────────────────────────────────────────────────────────────────────
# 内核参数（通用部分，所有平台共享）
# 所有平台共享的内核加固参数
# ─────────────────────────────────────────────────────────────────────────────
write_common_sysctl() {
    local file="$1"
    # 输入验证：确保 file 参数不为空
    if [[ -z "$file" ]]; then
        log_error "write_common_sysctl: file 参数不能为空"
        return 1
    fi
    # 幂等性检查：如果文件已存在且包含 vps-youhua 标记，跳过
    if [[ -f "$file" ]] && grep -q "vps-youhua" "$file" 2>/dev/null; then
        log_info "sysctl 配置已存在 ($file)，跳过"
        return 0
    fi
    backup_file "$file"

    # BUG#4: BBR 自适应检测（先运行，再写文件）
    BBR_CC="cubic"
    
    # 智能选择 qdisc：优先 CAKE（为 BBR 优化），回退到 fq
    BBR_QDISC="fq"
    modprobe -q sch_cake 2>/dev/null || true
    if lsmod | grep -qw sch_cake 2>/dev/null; then
        BBR_QDISC="cake"
        # 持久化 CAKE 模块加载
        mkdir -p /etc/modules-load.d
        if ! grep -q "^sch_cake$" /etc/modules-load.d/qdisc.conf 2>/dev/null; then
            echo "sch_cake" > /etc/modules-load.d/qdisc.conf
            log_info "队列调度: cake（已加载并持久化，为 BBR 优化）"
        else
            log_info "队列调度: cake（已加载，为 BBR 优化）"
        fi
    else
        log_info "队列调度: fq（CAKE 不可用，使用默认）"
    fi
    
    if [[ -f /proc/sys/net/ipv4/tcp_available_congestion_control ]]; then
        modprobe -q tcp_bbr2 2>/dev/null || true
        if grep -qw "bbr2" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
            BBR_CC="bbr"
            # 持久化 BBR 模块加载
            mkdir -p /etc/modules-load.d
            if ! grep -q "^tcp_bbr$" /etc/modules-load.d/bbr.conf 2>/dev/null; then
                echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
                log_info "TCP 拥塞控制: bbr（BBRv3 已激活并持久化）"
            else
                log_info "TCP 拥塞控制: bbr（BBRv3 已激活）"
            fi
        else
            modprobe -q tcp_bbr 2>/dev/null || true
            if grep -qw "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
                BBR_CC="bbr"
                # 持久化 BBR 模块加载
                mkdir -p /etc/modules-load.d
                if ! grep -q "^tcp_bbr$" /etc/modules-load.d/bbr.conf 2>/dev/null; then
                    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
                    log_info "TCP 拥塞控制: bbr（BBRv1 已激活并持久化）"
                else
                    log_info "TCP 拥塞控制: bbr（BBRv1 已激活）"
                fi
            else
                BBR_CC="cubic"
                log_info "TCP 拥塞控制: cubic（BBR 不可用，降级）"
            fi
        fi
    else
        BBR_CC="cubic"
    fi

    # 写入通用 sysctl 配置（使用已确定的 BBR_CC 值）
    cat > "$file" <<EOF
# =============================================================================
# VPS-youhua 通用内核加固参数 v3.4
# 所有平台共享
# =============================================================================

# ── 内核安全加固 ──────────────────────────────────────────────────────────
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
kernel.yama.ptrace_scope = 1
kernel.panic = 10
kernel.panic_on_io_nmi = 1
kernel.panic_on_oops = 1

# ── IPv4 安全（所有平台） ─────────────────────────────────────────────────
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384

# ── IPv6 安全（所有平台） ─────────────────────────────────────────────────
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
# 禁用 IPv6 RA（路由公告），防止被恶意路由劫持；本地网络无 IPv6 路由时不影响
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0

# ── 内存管理 ──────────────────────────────────────────────────────────────
vm.overcommit_memory = 1

# ── 网络基础 ──────────────────────────────────────────────────────────────
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.ip_local_port_range = 10240 65535

# ── BBR/BBRv3/cubic（BUG#4: 动态选择） ─────────────────────────────────
net.core.default_qdisc = ${BBR_QDISC}
net.ipv4.tcp_congestion_control = ${BBR_CC}
EOF

    # BUG#10: 检查平台默认 sysctl 冲突，避免重复覆盖
    if [[ -d /etc/sysctl.d ]] && grep -r "net.core" /etc/sysctl.d/ 2>/dev/null | grep -qv "vps-youhua"; then
        log_warn "检测到平台默认 sysctl 参数，保留原配置，仅追加本项目参数"
    fi
}


apply_sysctl() {
    log_step "应用 sysctl 参数..."
    sysctl --system >> "$APT_LOG" 2>&1 || sysctl -e -f /etc/sysctl.d/*.conf 2>/dev/null || true
    log_info "sysctl 已应用"
}

# ─────────────────────────────────────────────────────────────────────────────
# /tmp tmpfs
# ─────────────────────────────────────────────────────────────────────────────
configure_tmp_tmpfs() {
    log_step "配置 /tmp 为 tmpfs..."
    local tmpfs_size="${TMPFS_SIZE:-512M}"

    # P1-1 FIX: Validate existing tmpfs size before skipping
    if grep -qE "^tmpfs\s+/tmp\s+" /etc/fstab 2>/dev/null; then
        local existing_size
        existing_size=$(grep -E "^tmpfs\s+/tmp\s+" /etc/fstab | grep -oP 'size=\K[^,\s]+' || echo "")
        if [[ -n "$existing_size" && "$existing_size" != "$tmpfs_size" ]]; then
            log_warn "/tmp tmpfs 已存在但大小不匹配（当前: ${existing_size}, 期望: ${tmpfs_size}），更新配置"
            sed -i "s|^tmpfs\s\+/tmp\s\+tmpfs.*|tmpfs /tmp tmpfs defaults,noatime,mode=1777,size=${tmpfs_size} 0 0|" /etc/fstab
            mount -o remount /tmp 2>/dev/null || log_warn "/tmp tmpfs 重新挂载失败"
        else
            log_info "/tmp 已配置 tmpfs（跳过）"
            return 0
        fi
    else
        echo "tmpfs /tmp tmpfs defaults,noatime,mode=1777,size=${tmpfs_size} 0 0" >> /etc/fstab
        mkdir -p /tmp
        mount -o remount /tmp 2>/dev/null || mount /tmp 2>/dev/null || log_warn "/tmp tmpfs 挂载失败"
    fi

    # P1-1 FIX: tmpfs mount without verification - add mount check
    if ! mount | grep -q "tmpfs on /tmp type tmpfs"; then
        log_warn "/tmp tmpfs 挂载验证失败"
        return 1
    fi

    log_info "/tmp tmpfs 已配置（${tmpfs_size}）"
}

# ─────────────────────────────────────────────────────────────────────────────
# daily cleanup cron
# ─────────────────────────────────────────────────────────────────────────────
configure_cleanup_cron() {
    log_step "配置每日清理 cron..."
    mkdir -p /etc/cron.d
    cat > /etc/cron.d/vps-youhua-cleanup <<'EOF'
# VPS-youhua 每日清理（减少磁盘占用）
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
1 4 * * * root find /tmp -type f -atime +7 -delete 2>/dev/null; find /var/log -name "*.gz" -mtime +7 -delete 2>/dev/null; journalctl --vacuum-time=7d 2>/dev/null; true
EOF
    chmod 644 /etc/cron.d/vps-youhua-cleanup
    log_info "每日清理 cron 已配置"
}

# ─────────────────────────────────────────────────────────────────────────────
# logrotate
# ─────────────────────────────────────────────────────────────────────────────
configure_logrotate() {
    log_step "配置 logrotate..."
    cat > /etc/logrotate.d/vps-youhua <<'EOF'
/var/log/vps-youhua.log {
    daily
    rotate 7
    compress
    delaycompress
    notifempty
    create 0644 root root
}
EOF
    log_info "logrotate 已配置"
}

# ─────────────────────────────────────────────────────────────────────────────
# 自动安全更新（CONFIGURE_UNATTENDED 控制开关）
# ─────────────────────────────────────────────────────────────────────────────
configure_unattended_upgrades() {
    log_step "配置自动更新..."

    if [[ "${CONFIGURE_UNATTENDED:-true}" == "true" ]]; then
        # 启用自动安全更新
        if ! command -v unattended-upgrades &>/dev/null; then
            apt-get install -y unattended-upgrades >> "$APT_LOG" 2>&1 || {
                log_warn "unattended-upgrades 安装失败"
                return 0
            }
        fi
        mkdir -p /etc/apt/apt.conf.d
        cat > /etc/apt/apt.conf.d/99-vps-youhua-unattended <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
        systemctl enable --now unattended-upgrades 2>/dev/null || true
        log_info "自动安全更新已启用（每日检查，不自动重启）"
    else
        # 禁用自动更新（生产环境优先稳定）
        if command -v unattended-upgrades &>/dev/null; then
            mkdir -p /etc/apt/apt.conf.d
            cat > /etc/apt/apt.conf.d/99-vps-youhua-no-unattended <<'EOF'
APT::Periodic::Enable "0";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
        fi
        log_info "自动更新已禁用（防止生产环境被升级打断）"
    fi
}
# ─────────────────────────────────────────────────────────────────────────────
optimize_ssh() {
    log_step "加固 SSH..."
    mkdir -p /etc/ssh/sshd_config.d

    local dropin_file="/etc/ssh/sshd_config.d/99-vps-youhua.conf"
    cat > "$dropin_file" <<'EOF'
# VPS-youhua SSH 安全配置 — 由脚本维护，请勿手动修改
PermitEmptyPasswords no
ClientAliveInterval 3600
ClientAliveCountMax 3
X11Forwarding no
PrintLastLog yes
MaxAuthTries 3
EOF
    chmod 644 "$dropin_file"

    # 语法验证（防止把自己锁外面）
    if command -v sshd &>/dev/null; then
        if sshd -t -f "$dropin_file" 2>&1; then
            log_info "SSH 加固已应用 + 语法验证通过"
        else
            log_warn "SSH 配置语法异常，移除并跳过"
            rm -f "$dropin_file"
        fi
    fi

    echo -e "  ${CYAN}上次登录记录:${NC}"
    last -n 3 2>/dev/null | grep -v "^$" | head -3 | sed "s/^/    /" || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Oracle Cloud 专属优化已移除（这些是平台专属函数，应在 oracle-arm.sh 中实现）
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# fail2ban（可选，SSH 暴力破解防护）
# ─────────────────────────────────────────────────────────────────────────────
configure_fail2ban() {
    [[ "${CONFIGURE_FAIL2BAN:-false}" != "true" ]] && return 0
    log_step "安装并配置 fail2ban..."

    if ! command -v fail2ban-server &>/dev/null; then
        apt-get install -y fail2ban >> "$APT_LOG" 2>&1 || {
            log_warn "fail2ban 安装失败"
            return 0
        }
    fi

    # 动态检测 SSH 端口
    local ssh_port="22"
    if command -v sshd &>/dev/null; then
        local detected_port
        detected_port=$(sshd -T 2>/dev/null | awk '/^port /{print $2}' | head -1)
        [[ -n "$detected_port" ]] && ssh_port="$detected_port"
    fi

    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
destemail = root@localhost
sender = root@localhost
action = %(action_mwl)s

[sshd]
enabled = true
port = ${ssh_port}
maxretry = 3
bantime = 3600
findtime = 600
logpath = /var/log/auth.log
EOF

    systemctl enable --now fail2ban 2>/dev/null || true
    log_info "fail2ban 已启用（SSH 暴力破解防护，端口: ${ssh_port}）"
}

# ─────────────────────────────────────────────────────────────────────────────
# 平台信息输出（供 main() 调用）
# ─────────────────────────────────────────────────────────────────────────────
show_platform_summary() {
    echo ""
    echo "========================================================================"
    echo -e "${GREEN}  ${PLATFORM_NAME} 优化安装脚本 v${SCRIPT_VERSION}${NC}"
    echo -e "${BLUE}平台: ${PLATFORM_DESC}${NC}"
    echo ""
    echo "------------------------------------------------------------------------"
    echo -e "  ${BLUE}系统:${NC}      ${SYS_OS_ID} ${SYS_OS_VERSION}"
    echo -e "  ${BLUE}架构:${NC}      ${SYS_ARCH} | 内存: ${SYS_MEM_MB}MB | CPU: ${SYS_CPU_CORES}核"
    echo -e "  ${BLUE}Armbian:${NC}   ${SYS_IS_ARMBIAN}"
    echo -e "  ${BLUE}Oracle:${NC}   ${SYS_IS_ORACLE_CLOUD}"
    echo -e "  ${BLUE}TF卡:${NC}      ${SYS_IS_TF_CARD}"
    echo ""
    echo "------------------------------------------------------------------------"
    echo -e "  ${BLUE}模式:${NC}      ${SKIP_SOFTWARE_SCRIPT:+纯优化（不安装软件）}${SKIP_SOFTWARE_SCRIPT:-安装 Docker/Node.js}"

    if [[ "$SKIP_SOFTWARE_SCRIPT" != "true" ]]; then
        echo -e "  ${BLUE}Docker:${NC}    ${INSTALL_DOCKER}"
        echo -e "  ${BLUE}Node.js:${NC}   ${INSTALL_NODEJS}"
    fi
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# 熵服务配置（TLS 加解密加速）
# ─────────────────────────────────────────────────────────────────────────────
configure_entropy() {
    log_step "配置熵服务（TLS 加速）..."
    
    # 检查是否已有熵服务运行
    if systemctl is-active --quiet haveged 2>/dev/null; then
        log_info "haveged 熵服务运行中"
        return 0
    fi
    
    if systemctl is-active --quiet rng-tools 2>/dev/null; then
        log_info "rng-tools 熵服务运行中"
        return 0
    fi
    
    # 尝试安装并启动熵服务
    if command -v haveged >/dev/null 2>&1; then
        systemctl enable haveged 2>/dev/null || true
        systemctl restart haveged 2>/dev/null || true
        log_info "haveged 熵服务已启动"
    elif command -v rngd >/dev/null 2>&1; then
        systemctl enable rng-tools 2>/dev/null || true
        systemctl restart rng-tools 2>/dev/null || true
        log_info "rng-tools 熵服务已启动"
    else
        DEBIAN_FRONTEND=noninteractive apt-get install -y rng-tools 2>/dev/null || true
        if command -v rngd >/dev/null 2>&1; then
            systemctl enable rng-tools 2>/dev/null || true
            systemctl restart rng-tools 2>/dev/null || true
            log_info "rng-tools 已安装并运行（TLS 熵池充足）"
        else
            log_warn "熵服务安装失败（TLS 加解密可能受影响）"
        fi
    fi
    
    log_info "熵服务配置完成"
}
