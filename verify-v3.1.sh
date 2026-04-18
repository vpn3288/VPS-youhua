#!/usr/bin/env bash
#===============================================================================
# VPS-youhua v3.1 优化验证脚本
# 用途：验证 AIagent 安装前环境优化是否正确生效
# 支持：nanopi-r4s / nanopi-t6 / oracle-arm / n5105 / generic-x86
# 输出：所有优化参数的当前值 + 与目标值对比
#===============================================================================
set -euo pipefail

 readonly VERSION="3.2"
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly RESET='\033[0m'
readonly SEP="════════════════════════════════════════════════════════════"

#------------------------------------------------# -------------------------------
# 检测平台
#------------------------------------------------# -------------------------------
detect_platform() {
    local cpu_info
    cpu_info=$(cat /proc/cpuinfo 2>/dev/null | grep -m1 "model name" | cut -d: -f2 | tr -d '\0' | xargs)

    # Use tr -d '\0' to strip NUL chars (ARM device-tree model has embedded NUL)
    local board_info
    board_info=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0' | xargs 2>/dev/null || echo "")

    # GCP 检测（优先级高：通过元数据端点）
    if curl -s --connect-timeout 3 -o /dev/null -w "%{http_code}" \
       http://169.254.169.254/latest/meta-data/ 2>/dev/null | grep -q "200"; then
        echo "google-cloud-e2"
    elif [[ "$board_info" == *"NanoPi R4S"* ]] || [[ "$board_info" == *"R4S"* ]]; then
        echo "nanopi-r4s"
    elif [[ "$board_info" == *"NanoPC T6"* ]] || [[ "$board_info" == *"T6"* ]] && [[ "$board_info" == *"3588"* ]]; then
        echo "nanopi-t6"
    elif [[ "$cpu_info" == *"Ampere"* ]]; then
        # Oracle Cloud 检测（通过元数据端点）
        if curl -s --connect-timeout 3 -o /dev/null http://169.254.0.23/latest/meta-data/ 2>/dev/null | grep -q "200"; then
            # Oracle 1C4G vs 2C16G：通过内存判断
            local mem_kb
            mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo "0")
            local mem_mb=$((mem_kb / 1024))
            if [[ "$mem_mb" -lt 8192 ]]; then
                echo "oracle-1c4g"
            else
                echo "oracle-arm"
            fi
        else
            echo "generic-arm"
        fi
    elif grep -qi "n5105\|n5095\|jasper lake" /proc/cpuinfo 2>/dev/null; then
        echo "n5105"
    elif [[ -f /etc/oracle-auto-detect ]] || hostnamectl 2>/dev/null | grep -qi "oracle"; then
        local mem_kb
        mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo "0")
        local mem_mb=$((mem_kb / 1024))
        if [[ "$mem_mb" -lt 8192 ]]; then
            echo "oracle-1c4g"
        else
            echo "oracle-arm"
        fi
    elif grep -qi "rockchip\|rk3399" /proc/cpuinfo 2>/dev/null && [[ -d /sys/class/net/eth0 ]]; then
        echo "nanopi-r4s"
    else
        echo "generic-x86"
    fi
}

detect_cloud() {
    if curl -s --connect-timeout 2 -o /dev/null -w "%{http_code}" http://169.254.169.254/latest/meta-data/ 2>/dev/null | grep -q "200"; then
        echo "oracle-cloud"
    elif [[ -d /sys/block/vda/device ]] || lsblk -d -n -o NAME 2>/dev/null | grep -q "^vda"; then
        echo "cloud-virtio"
    else
        echo "physical"
    fi
}

#-----------------# -------------------------------
#────────────────────────────────────────────────────────────────
# zram 状态检查（Armbian/低内存系统）
#────────────────────────────────────────────────────────────────
check_zram_status() {
    log_section "zram 内存扩展状态"
    if lsmod 2>/dev/null | grep -q zram; then
        local zram_devs
        zram_devs=$(ls -la /sys/block/zram* 2>/dev/null | wc -l)
        echo -e "  ${GREEN}✓ zram 模块已加载${RESET}（$(($zram_devs - 1)) 个设备）"
        # 显示各 zram 设备大小
        for dev in /sys/block/zram*; do
            [[ -d "$dev" ]] || continue
            local name
            name=$(basename "$dev")
            local disksize
            disksize=$(cat "$dev/disksize" 2>/dev/null || echo "0")
            local size_mb=$((disksize / 1024 / 1024))
            if [[ $size_mb -gt 0 ]]; then
                log_pair "zram/${name}" "${size_mb}MB"
            fi
        done
    else
        echo -e "  ${YELLOW}⚠ zram 未加载（低内存系统推荐启用）${RESET}"
    fi
    echo ""
}

#────────────────────────────────────────────────────────────────
# fstrim cron 检查
#────────────────────────────────────────────────────────────────
check_fstrim_cron() {
    log_section "fstrim 定时任务状态"
    if [[ -f /etc/cron.daily/vps-youhua-clean ]]; then
        if grep -q fstrim /etc/cron.daily/vps-youhua-clean 2>/dev/null; then
            echo -e "  ${GREEN}✓ fstrim cron 已配置${RESET}"
        else
            echo -e "  ${YELLOW}⚠ vps-youhua-clean cron 存在但无 fstrim${RESET}"
        fi
    else
        echo -e "  ${YELLOW}⚠ 无 vps-youhua-clean cron 任务${RESET}"
    fi
    echo ""
}

#────────────────────────────────────────────────────────────────
# unattended-upgrades 检查
#────────────────────────────────────────────────────────────────
check_unattended_upgrades() {
    log_section "unattended-upgrades 自动更新状态"
    if dpkg -l unattended-upgrades 2>/dev/null | grep -q "^ii"; then
        echo -e "  ${GREEN}✓ unattended-upgrades 已安装${RESET}"
        if systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
            echo -e "  ${GREEN}✓ unattended-upgrades 服务运行中${RESET}"
        else
            echo -e "  ${YELLOW}⚠ unattended-upgrades 服务未运行${RESET}"
        fi
    else
        echo -e "  ${YELLOW}⚠ unattended-upgrades 未安装${RESET}"
    fi
    echo ""
}
# -------------------------------
# 输出格式
#------------------------------------------------# -------------------------------
log_header() {
    echo ""
    echo -e "${SEP}"
    echo -e "${BOLD}${CYAN}  VPS-youhua v${VERSION} 优化验证报告${RESET}"
    echo -e "${DIM}  平台: $(detect_platform) | 云环境: $(detect_cloud) | 时间: $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
    echo -e "${SEP}"
}

log_section() {
    echo ""
    echo -e "${BOLD}${BLUE}▶ $1${RESET}"
    echo -e "${DIM}$(printf '─%.0s' {1..60})${RESET}"
}

log_ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
log_fail() { echo -e "  ${RED}✗${RESET} $1"; }
log_warn() { echo -e "  ${YELLOW}⚠${RESET} $1"; }
log_info() { echo -e "  ${DIM}•${RESET} $1"; }

log_pair() {
    local param="$1"; shift
    local val="$1"; shift
    local note="${1:-}"
    if [[ -n "$note" ]]; then
        echo -e "    ${CYAN}${param}${RESET} = ${YELLOW}${val}${RESET}  ${DIM}(${note})${RESET}"
    else
        echo -e "    ${CYAN}${param}${RESET} = ${YELLOW}${val}${RESET}"
    fi
}

log_pass() {
    local param="$1"; shift
    local val="$1"; shift
    echo -e "    ${GREEN}✓${RESET} ${CYAN}${param}${RESET} = ${GREEN}${val}${RESET}"
}

log_fail_param() {
    local param="$1"; shift
    local val="$1"; shift
    local expected="$1"; shift
    local desc="${1:-}"
    echo -e "    ${RED}✗${RESET} ${CYAN}${param}${RESET} = ${RED}${val}${RESET}"
    echo -e "         目标值: ${GREEN}${expected}${RESET}  ${DIM}${desc}${RESET}"
}

#------------------------------------------------# -------------------------------
# 1. 系统基础信息
#------------------------------------------------# -------------------------------
check_system_info() {
    log_section "1. 系统基础信息"

    echo -e "  ${BOLD}主机名${RESET}  = $(hostname)"
    echo -e "  ${BOLD}平台${RESET}    = $(detect_platform)"
    echo -e "  ${BOLD}内核${RESET}    = $(uname -r)"
    echo -e "  ${BOLD}OS${RESET}      = $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | xargs || echo 'unknown')"
    echo -e "  ${BOLD}CPU 核数${RESET} = $(nproc 2>/dev/null || echo '?')"
    echo -e "  ${BOLD}内存${RESET}    = $(free -h 2>/dev/null | grep Mem | awk '{print $2}' || echo '?')"
    echo ""
}

#-----------------------------------------------# -------------------------------
# 1b. locale 全链路 UTF-8 验证
#-----------------------------------------------# -------------------------------
check_locale_chain() {
    log_section "1b. locale 全链路 UTF-8"

    local issues=0

    # Layer 1: 当前 shell 环境变量
    local current_lang="${LANG:-<未设置>}"
    local current_lc="${LC_ALL:-<未设置>}"
    echo -e "  ${DIM}Layer 1 - 当前shell环境:${RESET}"
    echo -e "    LANG=${current_lang}"
    echo -e "    LC_ALL=${current_lc}"
    if [[ "$current_lang" == *"UTF-8"* || "$current_lang" == *"utf-8"* ]]; then
        echo -e "    ${GREEN}✓${RESET} 当前shell UTF-8"
    else
        echo -e "    ${RED}✗${RESET} 当前shell 非UTF-8"
        ((issues++))
    fi

    # Layer 2: /etc/default/locale
    echo -e "  ${DIM}Layer 2 - /etc/default/locale:${RESET}"
    if [[ -f /etc/default/locale ]]; then
        grep -v "^#" /etc/default/locale 2>/dev/null | grep -v "^$" | while read -r line; do
            echo -e "    ${line}"
        done
        if grep -qi "UTF-8\|utf-8" /etc/default/locale 2>/dev/null; then
            echo -e "    ${GREEN}✓${RESET} /etc/default/locale UTF-8"
        else
            echo -e "    ${RED}✗${RESET} /etc/default/locale 非UTF-8"
            ((issues++))
        fi
    else
        echo -e "    ${RED}✗${RESET} 文件不存在"
        ((issues++))
    fi

    # Layer 3: /etc/environment.d/90-chinese.conf (systemd/PAM)
    echo -e "  ${DIM}Layer 3 - /etc/environment.d/90-chinese.conf:${RESET}"
    if [[ -f /etc/environment.d/90-chinese.conf ]]; then
        grep -v "^#" /etc/environment.d/90-chinese.conf 2>/dev/null | grep -v "^$" | while read -r line; do
            echo -e "    ${line}"
        done
        echo -e "    ${GREEN}✓${RESET} systemd环境配置存在"
    else
        echo -e "    ${DIM}  文件不存在（可选，非必须）${RESET}"
    fi

    # Layer 4: zh_CN.UTF-8 locale 已生成
    echo -e "  ${DIM}Layer 4 - 可用的中文locale:${RESET}"
    if locale -a 2>/dev/null | grep -qi "zh_CN"; then
        echo -e "    $(locale -a 2>/dev/null | grep -i zh_CN | tr '\n' ' ')"
        echo -e "    ${GREEN}✓${RESET} 中文locale已生成"
    else
        echo -e "    ${RED}✗${RESET} 系统中未生成zh_CN.UTF-8"
        ((issues++))
    fi

    # Layer 5: Docker daemon locale（检查daemon.json）
    echo -e "  ${DIM}Layer 5 - Docker daemon:${RESET}"
    if command -v docker &>/dev/null; then
        echo -e "    Docker: ${GREEN}已安装${RESET}"
        if systemctl is-active docker &>/dev/null; then
            echo -e "    Docker daemon: ${GREEN}运行中${RESET}"
        else
            echo -e "    Docker daemon: ${DIM}未运行${RESET}"
        fi
    else
        echo -e "    Docker: ${DIM}未安装${RESET}"
    fi

    # Layer 6: systemd service 中的 LANG
    echo -e "  ${DIM}Layer 6 - systemd service Environment:${RESET}"
    # 注意: systemd user/global service LANG 检查已移除（通用脚本不再绑定特定agent）

    echo ""
    if [[ $issues -eq 0 ]]; then
        echo -e "  ${GREEN}✓ locale全链路完整${RESET}"
    else
        echo -e "  ${RED}✗ locale全链路有${issues}处问题${RESET}"
    fi
    echo ""
}

#------------------------------------------------# -------------------------------
# 2. sysctl 网络参数
#------------------------------------------------# -------------------------------
check_sysctl_network() {
    log_section "2. sysctl 网络参数"

    # 自动检测实际存在的 sysctl 配置文件
    local sysctl_file=""
    for f in /etc/sysctl.d/99-vps-youhua-*.conf \
             /etc/sysctl.d/99-tf-optimize.conf; do
        [[ -f "$f" ]] && { sysctl_file="$f"; break; }
    done
    sysctl_file="${sysctl_file:-/etc/sysctl.d/99-vps-youhua-*.conf}"

    if [[ -n "$sysctl_file" && "$sysctl_file" != *'*'* ]]; then
        echo -e "  ${GREEN}✓${RESET} 配置文件 ${DIM}${sysctl_file}${RESET} 存在 ($(wc -l < "$sysctl_file" 2>/dev/null || echo 0) 行)"
    else
        echo -e "  ${YELLOW}⚠${RESET} 未检测到 99-vps-youhua-*.conf 配置文件"
    fi

    echo ""
    echo -e "  ${BOLD}[TCP 核心参数]${RESET}"
    log_pair "net.ipv4.tcp_rmem"                          "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null || echo N/A)"
    log_pair "net.ipv4.tcp_wmem"                          "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null || echo N/A)"
    log_pair "net.ipv4.tcp_tw_reuse"                      "$(sysctl -n net.ipv4.tcp_tw_reuse 2>/dev/null || echo N/A)"
    log_pair "net.ipv4.tcp_fin_timeout"                   "$(sysctl -n net.ipv4.tcp_fin_timeout 2>/dev/null || echo N/A)"
    log_pair "net.ipv4.tcp_rfc1337"                       "$(sysctl -n net.ipv4.tcp_rfc1337 2>/dev/null || echo N/A)"
    log_pair "net.ipv4.tcp_early_retrans"                  "$(sysctl -n net.ipv4.tcp_early_retrans 2>/dev/null || echo N/A)"
    log_pair "net.ipv4.tcp_orphan_retries"                "$(sysctl -n net.ipv4.tcp_orphan_retries 2>/dev/null || echo N/A)"
    log_pair "net.ipv4.tcp_keepalive_time"                 "$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null || echo N/A)"
    log_pair "net.ipv4.tcp_keepalive_intvl"                "$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null || echo N/A)"
    log_pair "net.ipv4.tcp_keepalive_probes"               "$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null || echo N/A)"
    log_pair "net.ipv4.tcp_slow_start_after_idle"         "$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null || echo N/A)"
    log_pair "net.ipv4.tcp_fastopen"                       "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo N/A)"
    log_pair "net.ipv4.tcp_timestamps"                     "$(sysctl -n net.ipv4.tcp_timestamps 2>/dev/null || echo N/A)"
    log_pair "net.ipv4.tcp_sack"                           "$(sysctl -n net.ipv4.tcp_sack 2>/dev/null || echo N/A)"
    log_pair "net.ipv4.tcp_max_syn_backlog"                "$(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null || echo N/A)"
    log_pair "net.ipv4.tcp_notsent_lowat"                  "$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null || echo N/A)"
    log_pair "net.ipv4.tcp_mtu_probing"                    "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo N/A)"

    echo ""
    echo -e "  ${BOLD}[网络队列与缓冲区]${RESET}"
    log_pair "net.core.default_qdisc"      "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo N/A)"
    log_pair "net.core.rmem_max"           "$(sysctl -n net.core.rmem_max 2>/dev/null || echo N/A)"
    log_pair "net.core.wmem_max"           "$(sysctl -n net.core.wmem_max 2>/dev/null || echo N/A)"
    log_pair "net.core.netdev_max_backlog" "$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo N/A)"
    log_pair "net.core.somaxconn"          "$(sysctl -n net.core.somaxconn 2>/dev/null || echo N/A)"
    log_pair "net.ipv4.ip_local_port_range" "$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null || echo N/A)"

    echo ""
    echo -e "  ${BOLD}[BBR 拥塞控制]${RESET}"
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "N/A")
    if [[ "$cc" == "bbr" ]]; then
        log_pass "net.ipv4.tcp_congestion_control" "$cc"
    else
        log_fail_param "net.ipv4.tcp_congestion_control" "$cc" "bbr"
    fi
    if lsmod | grep -q bbr; then
        echo -e "    ${GREEN}✓${RESET} BBR 模块已加载"
    else
        echo -e "    ${RED}✗${RESET} BBR 模块未加载 (modprobe tcp_bbr)"
    fi

    echo ""
    echo -e "  ${BOLD}[网关转发]${RESET}"
    log_pair "net.ipv4.ip_forward"             "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo N/A)"
    log_pair "net.ipv6.conf.all.forwarding"     "$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo N/A)"
    log_pair "net.ipv6.conf.default.forwarding" "$(sysctl -n net.ipv6.conf.default.forwarding 2>/dev/null || echo N/A)"

    echo ""
    echo -e "  ${BOLD}[安全参数 - IPv4]${RESET}"
    for param in         "net.ipv4.conf.all.rp_filter"         "net.ipv4.conf.default.rp_filter"         "net.ipv4.conf.all.accept_redirects"         "net.ipv4.conf.default.accept_redirects"         "net.ipv4.conf.all.secure_redirects"         "net.ipv4.conf.default.secure_redirects"         "net.ipv4.conf.all.send_redirects"         "net.ipv4.conf.default.send_redirects"         "net.ipv4.tcp_syncookies"; do
        log_pair "$param" "$(sysctl -n $param 2>/dev/null || echo N/A)"
    done

    echo ""
    echo -e "  ${BOLD}[安全参数 - IPv6]${RESET}"
    for param in         "net.ipv6.conf.all.accept_redirects"         "net.ipv6.conf.default.accept_redirects"         "net.ipv6.conf.all.disable_ipv6"         "net.ipv6.conf.default.disable_ipv6"; do
        log_pair "$param" "$(sysctl -n $param 2>/dev/null || echo N/A)"
    done
}

#------------------------------------------------# -------------------------------
# 3. conntrack 连接追踪
#------------------------------------------------# -------------------------------
check_sysctl_conntrack() {
    log_section "3. conntrack 连接追踪"

    local ct_max ct_count
    ct_max=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo "N/A")
    ct_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "N/A")
    log_pair "net.netfilter.nf_conntrack_max"      "$ct_max"
    log_pair "当前连接数"                            "$ct_count"
    if [[ "$ct_count" != "N/A" ]] && [[ "$ct_max" != "N/A" ]]; then
        local pct
        pct=$(awk -v c="$ct_count" -v m="$ct_max" 'BEGIN {printf "%.1f", c/m*100}')
        echo -e "    ${CYAN}使用率${RESET} = ${YELLOW}${pct}%${RESET}"
    fi
    log_pair "net.netfilter.nf_conntrack_hashsize"  "$(sysctl -n net.netfilter.nf_conntrack_hashsize 2>/dev/null || echo N/A)"

    echo ""
    echo -e "  ${BOLD}[TCP 超时设置]${RESET}"
    for param in         "net.netfilter.nf_conntrack_tcp_timeout_established"         "net.netfilter.nf_conntrack_tcp_timeout_time_wait"         "net.netfilter.nf_conntrack_tcp_timeout_close_wait"         "net.netfilter.nf_conntrack_tcp_timeout_fin_wait"; do
        log_pair "$param" "$(sysctl -n $param 2>/dev/null || echo N/A)"
    done
}

#------------------------------------------------# -------------------------------
# 4. 内存管理
#------------------------------------------------# -------------------------------
check_sysctl_memory() {
    log_section "4. 内存管理"

    echo -e "  ${BOLD}[内存参数]${RESET}"
    for param in         "vm.swappiness"         "vm.overcommit_memory"         "vm.vfs_cache_pressure"         "vm.min_free_kbytes"; do
        log_pair "$param" "$(sysctl -n $param 2>/dev/null || echo N/A)"
    done

    echo ""
    echo -e "  ${BOLD}[Dirty Writeback - TF卡保护关键]${RESET}"
    for param in         "vm.dirty_ratio"         "vm.dirty_background_ratio"         "vm.dirty_writeback_centisecs"         "vm.dirty_expire_centisecs"; do
        log_pair "$param" "$(sysctl -n $param 2>/dev/null || echo N/A)"
    done

    echo ""
    echo -e "  ${BOLD}[Armbian zram swap 状态]${RESET}"
    local zram_swap_count
    zram_swap_count=$(swapon --show 2>/dev/null | grep -c "^/dev/zram" || echo 0)
    local zram_log_dev
    zram_log_dev=$(df /var/log 2>/dev/null | tail -1 | awk '{print $1}' || echo "")
    if [[ "$zram_swap_count" -gt 0 ]]; then
        echo -e "    ${GREEN}✓${RESET} Armbian原生zram swap已启用 (压缩内存, 不写TF卡)"
    fi
    if [[ "$zram_log_dev" == *zram* ]]; then
        echo -e "    ${GREEN}✓${RESET} armbian-ramlog /var/log在zram中 (零TF卡写入)"
        # BUG#42 Fix: 检查 armbian-ramlog SIZE 是否合理（应为 128M 或以上）
        local ramlog_size
        ramlog_size=$(grep -oP '(?<=^SIZE=).+' /etc/default/armbian-ramlog 2>/dev/null | tr -d '"' || echo "")
        if [[ -n "$ramlog_size" ]]; then
            log_pair "armbian-ramlog SIZE" "$ramlog_size"
        else
            echo -e "    ${YELLOW}⚠ armbian-ramlog SIZE 未配置（建议 ≥128M）${RESET}"
        fi
    fi
    if swapon --show 2>/dev/null | grep -qE "^/swapfile|^/swap\.img"; then
        echo -e "    ${RED}⚠ 物理swap文件已启用 (会写TF卡, 必须禁用!)${RESET}"
    fi

    echo ""
    echo -e "  ${BOLD}[OOM 保护]${RESET}"
    # 注意: openclaw OOM 配置检查已移除（通用脚本不再绑定特定agent）
}

#------------------------------------------------# -------------------------------
# 5. 文件描述符 & 进程限制
#------------------------------------------------# -------------------------------
check_limits() {
    log_section "5. 文件描述符 & 进程限制"

    log_pair "ulimit -n (软限制)"  "$(ulimit -Sn 2>/dev/null || echo N/A)"
    log_pair "ulimit -n (硬限制)"  "$(ulimit -Hn 2>/dev/null || echo N/A)"
    log_pair "ulimit -u (nproc)"   "$(ulimit -Su 2>/dev/null || echo N/A)"

    echo ""
    if grep -qE "nofile\|nproc" /etc/security/limits.conf 2>/dev/null; then
        echo -e "  ${GREEN}✓${RESET} /etc/security/limits.conf 有 nofile/nproc 配置"
        grep -v "^#" /etc/security/limits.conf 2>/dev/null | grep -v "^$" | grep -E "nofile|nproc" | while read -r line; do
            echo -e "    $line"
        done
    else
        echo -e "  ${DIM}• /etc/security/limits.conf 无 nofile/nproc 配置${RESET}"
    fi
}

#------------------------------------------------# -------------------------------
# 6. SSH 配置
#------------------------------------------------# -------------------------------
check_ssh() {
    log_section "6. SSH 配置"

    local sshd_config="/etc/ssh/sshd_config"
    if [[ ! -f "$sshd_config" ]]; then
        echo -e "  ${DIM}• sshd_config 不存在${RESET}"
        return
    fi

    for param in         "PermitRootLogin"         "PubkeyAuthentication"         "PasswordAuthentication"         "X11Forwarding"         "ClientAliveInterval"         "ClientAliveCountMax"         "MaxAuthTries"         "Protocol"         "PermitEmptyPasswords"; do
        local val
        val=$(grep -E "^${param}[[:space:]]" "$sshd_config" 2>/dev/null | tail -1 | awk '{print $2}' || echo "N/A")
        log_pair "$param" "$val"
    done

    echo ""
    echo -e "  ${BOLD}当前 SSH 连接${RESET}"
    who 2>/dev/null | while read -r line; do
        echo -e "    $line"
    done
}

#------------------------------------------------# -------------------------------
# 7. journald 日志配置
#------------------------------------------------# -------------------------------
check_journald() {
    log_section "7. journald 日志配置"

    local jc="/etc/systemd/journald.conf"
    if [[ -f "$jc" ]]; then
        echo -e "  ${GREEN}✓${RESET} journald.conf 存在"
        grep -v "^#" "$jc" 2>/dev/null | grep -v "^$" | while read -r line; do
            echo -e "    ${CYAN}${line}${RESET}"
        done
    else
        echo -e "  ${RED}✗ journald.conf 不存在${RESET}"
    fi

    echo ""
    log_pair "/var/log/journal 大小" "$(du -sh /var/log/journal 2>/dev/null | awk '{print $1}' || echo N/A)"
    log_pair "systemd-journald Storage" "$(systemctl show systemd-journald -p Storage --value 2>/dev/null || echo N/A)"
}

#------------------------------------------------# -------------------------------
# 8. inotify 文件监控
#------------------------------------------------# -------------------------------
check_inotify() {
    log_section "8. inotify 文件监控"

    log_pair "fs.inotify.max_user_watches"    "$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo N/A)" "目标: 1048576 (所有平台)"
    log_pair "fs.inotify.max_user_instances"   "$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo N/A)" "目标: 8192 (所有平台)"

    echo ""
    if [[ -f /etc/sysctl.d/99-inotify.conf ]]; then
        echo -e "  ${GREEN}✓${RESET} /etc/sysctl.d/99-inotify.conf 存在"
        grep -v "^#" /etc/sysctl.d/99-inotify.conf 2>/dev/null | grep -v "^$" | while read -r line; do
            echo -e "    $line"
        done
    else
        echo -e "  ${DIM}• /etc/sysctl.d/99-inotify.conf 不存在${RESET}"
    fi
}

#------------------------------------------------# -------------------------------
# 9. SWAP 状态 (TF卡保护)
#------------------------------------------------# -------------------------------
check_swap() {
    log_section "9. SWAP 状态 (TF卡保护)"

    log_pair "SWAP 总计" "$(free -h 2>/dev/null | grep Swap | awk '{print $2}' || echo N/A)"

    if swapon --show 2>/dev/null | grep -q "/"; then
        echo -e "  ${RED}⚠ SWAP 已启用 (R4S TF卡模式应禁用!)${RESET}"
        swapon --show 2>/dev/null | tail -n +2 | while read -r line; do
            echo -e "    $line"
        done
    else
        echo -e "  ${GREEN}✓ SWAP 已禁用${RESET}"
    fi

    if [[ -f /sys/module/zswap/parameters/enabled ]]; then
        log_pair "zswap" "$(cat /sys/module/zswap/parameters/enabled 2>/dev/null || echo N/A)" "TF卡模式应=N"
    fi

    if grep -qE "swap|swapfile|swap.img" /etc/fstab 2>/dev/null; then
        echo -e "  ${RED}⚠ fstab 中有 swap 配置${RESET}"
    else
        echo -e "  ${GREEN}✓ fstab 无 swap 配置${RESET}"
    fi
}

#------------------------------------------------# -------------------------------
# 10. CPU 调频 & Governor
#------------------------------------------------# -------------------------------
check_cpu() {
    log_section "10. CPU 调频 & Governor"

    log_pair "CPU Governor"      "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo N/A)" "目标:performance"
    log_pair "CPU 最小频率"       "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 2>/dev/null || echo N/A)"
    log_pair "CPU 最大频率"       "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || echo N/A)"

    if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
        local tv
        tv=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo N/A)
        if [[ "$tv" == "1" ]]; then
            echo -e "    ${GREEN}✓${RESET} ${CYAN}Turbo Boost${RESET} = ${GREEN}已禁用${RESET} (静音模式)"
        else
            echo -e "    ${DIM}•${RESET} ${CYAN}Turbo Boost${RESET} = ${YELLOW}未禁用${RESET}"
        fi
    fi

    if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
        local temp
        temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo N/A)
        if [[ "$temp" != "N/A" ]] && [[ "$temp" -gt 0 ]]; then
            log_pair "CPU 温度" "$((temp/1000))°C"
        fi
    fi
}

#------------------------------------------------# -------------------------------
# 11. systemd 服务状态
#------------------------------------------------# -------------------------------
check_services() {
    log_section "11. systemd 服务状态"

    for svc in systemd-journald sshd irqbalance chronyd systemd-resolved; do
        local active enabled
        active=$(systemctl is-active "$svc" 2>/dev/null || echo "N/A")
        enabled=$(systemctl is-enabled "$svc" 2>/dev/null || echo "N/A")
        if [[ "$active" == "active" ]]; then
            echo -e "    ${GREEN}●${RESET} ${CYAN}${svc}${RESET} active=${GREEN}${active}${RESET} enabled=${YELLOW}${enabled}${RESET}"
        else
            echo -e "    ${RED}○${RESET} ${CYAN}${svc}${RESET} active=${RED}${active}${RESET} enabled=${YELLOW}${enabled}${RESET}"
        fi
    done
}

#------------------------------------------------# -------------------------------
# 12. sysctl 配置文件完整性
#------------------------------------------------# -------------------------------
check_sysctl_files() {
    log_section "12. sysctl 配置文件完整性"

    echo -e "  ${BOLD}所有 99-*.conf:${RESET}"
    ls -la /etc/sysctl.d/99-*.conf 2>/dev/null | while read -r line; do
        echo -e "    $line"
    done

    echo ""
    log_pair "已应用 sysctl 参数总数" "$(sysctl -a 2>/dev/null | wc -l)"

    echo ""
    echo -e "  ${BOLD}[TF卡优化 - nanopi-r4s 专用]${RESET}"
    if [[ -f /etc/sysctl.d/99-tf-optimize.conf ]]; then
        echo -e "    ${GREEN}✓${RESET} /etc/sysctl.d/99-tf-optimize.conf"
        grep -v "^#" /etc/sysctl.d/99-tf-optimize.conf 2>/dev/null | grep -v "^$" | while read -r line; do
            echo -e "      $line"
        done
    else
        echo -e "    ${DIM}• /etc/sysctl.d/99-tf-optimize.conf 不存在 (非 R4S 平台正常)${RESET}"
    fi
}

#------------------------------------------------# -------------------------------
# 13. 网络连接实战状态
#------------------------------------------------# -------------------------------
check_network_stats() {
    log_section "13. 网络连接实战状态"

    if command -v ss &>/dev/null; then
        echo -e "  ${BOLD}[连接数统计]${RESET}"
        ss -s 2>/dev/null | head -10 | while read -r line; do
            echo -e "    $line"
        done
    fi

    echo ""
    echo -e "  ${BOLD}[各状态连接数]${RESET}"
    ss -tan 2>/dev/null | awk 'NR>1 {print $1}' | sort | uniq -c | sort -rn | head -10 | while read -r cnt state; do
        echo -e "    ${YELLOW}${cnt}${RESET} x ${state}"
    done

    echo ""
    echo -e "  ${BOLD}[端口监听 (LISTEN)]${RESET}"
    ss -tlnp 2>/dev/null | awk 'NR>1 {print $4}' | sort -u | while read -r addr; do
        echo -e "    $addr"
    done

    echo ""
    echo -e "  ${BOLD}[网卡流量 (RX=接收 TX=发送)]${RESET}"
    cat /proc/net/dev 2>/dev/null | grep -v "Inter\|face" | awk '{print $1, "RX:"$3, "TX:"$11}' | while read -r iface rx tx; do
        echo -e "    ${CYAN}${iface}${RESET} RX=$rx  TX=$tx"
    done
}

#------------------------------------------------# -------------------------------
# 14. 与 v3.1 目标值逐项对比
#------------------------------------------------# -------------------------------
check_vs_targets() {
    log_section "14. 与 v3.1 目标值逐项对比"

    local platform
    platform=$(detect_platform)
    echo -e "  ${DIM}检测平台: ${platform}${RESET}"
    echo ""

    local passed=0
    local failed=0

    check_ok() {
        local p="$1"; local v="$2"; local d="$3"
        echo -e "    ${GREEN}✓${RESET} ${CYAN}${p}${RESET} = ${GREEN}${v}${RESET}  ${DIM}${d}${RESET}"
        ((passed++))
    }

    check_bad() {
        local p="$1"; local v="$2"; local e="$3"; local d="$4"
        echo -e "    ${RED}✗${RESET} ${CYAN}${p}${RESET} = ${RED}${v}${RESET}"
        echo -e "         目标: ${GREEN}${e}${RESET}  ${DIM}${d}${RESET}"
        ((failed++))
    }

    check_eq() {
        local actual expected
        actual=$(sysctl -n "$1" 2>/dev/null || echo "N/A")
        expected="$2"
        local desc="$3"
        if [[ "$actual" == "$expected" ]]; then
            check_ok "$1" "$actual" "$desc"
        else
            check_bad "$1" "$actual" "$expected" "$desc"
        fi
    }

    echo -e "  ${BOLD}[全平台通用]${RESET}"
    check_eq "net.ipv4.tcp_syncookies"              "1"   "SYN cookie防洪水"
    check_eq "net.ipv4.conf.all.accept_redirects"   "0"   "IPv4接受重定向"
    check_eq "net.ipv4.conf.default.accept_redirects" "0" "IPv4接受重定向默认"
    check_eq "net.ipv4.conf.all.rp_filter"             "1"  "反向路径过滤"
    check_eq "net.ipv4.conf.default.rp_filter"         "1" "反向路径过滤默认"
    check_eq "net.core.default_qdisc"                 "fq" "默认队列算法"
    check_eq "net.ipv4.tcp_congestion_control"        "bbr" "BBR拥塞控制"
    check_eq "net.ipv4.tcp_timestamps"                "1"  "TCP时间戳"
    check_eq "net.ipv4.tcp_sack"                      "1"  "SACK选择确认"
    check_eq "net.ipv4.tcp_fastopen"                  "3"  "TCP快速打开"
    check_eq "net.ipv4.tcp_slow_start_after_idle"    "0"  "空闲后慢启动"
    check_eq "net.ipv4.tcp_rfc1337"                   "1"  "TIME_WAIT保护"
    check_eq "net.ipv4.tcp_early_retrans"             "3"  "早期重传"
    check_eq "net.ipv4.tcp_orphan_retries"           "1"  "孤儿socket清理"
    check_eq "net.ipv4.tcp_mtu_probing"              "1"  "MTU探测"
    check_eq "net.ipv4.tcp_notsent_lowat"        "16384"  "未发送低水位"
    check_eq "vm.overcommit_memory"                  "1"  "内存超量分配"

    echo ""
    echo -e "  ${BOLD}[全平台 IPv6 安全]${RESET}"
    check_eq "net.ipv6.conf.all.accept_redirects"       "0"  "IPv6接受重定向"
    check_eq "net.ipv6.conf.default.accept_redirects" "0"  "IPv6接受重定向默认"
    check_eq "net.ipv6.conf.all.accept_source_route"    "0"  "IPv6源路由"
    check_eq "net.ipv6.conf.default.accept_source_route" "0" "IPv6源路由默认"
    check_eq "net.ipv6.conf.all.accept_ra"            "0"  "IPv6 RA通告"
    check_eq "net.ipv6.conf.default.accept_ra"        "0"  "IPv6 RA通告默认"

    echo ""
    echo -e "  ${BOLD}[全平台 网络基础]${RESET}"
    check_eq "net.core.somaxconn"                      "65535" "监听队列上限"
    check_eq "net.core.netdev_max_backlog"             "65535" "网卡最大积压"

    echo ""
    echo -e "  ${BOLD}[全平台 kernel hardening]${RESET}"
    check_eq "kernel.kptr_restrict"                 "2"   "内核指针泄露防护"
    check_eq "kernel.dmesg_restrict"                "1"   "dmesg 访问限制"
    check_eq "fs.protected_hardlinks"                "1"   "硬链接保护"
    check_eq "fs.protected_symlinks"                 "1"   "符号链接保护"
    check_eq "kernel.yama.ptrace_scope"              "1"   "ptrace 权限限制"

    echo ""
    echo -e "  ${BOLD}[全平台 conntrack 超时]${RESET}"
    check_eq "net.netfilter.nf_conntrack_tcp_timeout_time_wait"  "10" "TW超时(通用)"
    check_eq "net.netfilter.nf_conntrack_tcp_timeout_close_wait" "5" "CLOSE_WAIT超时"
    check_eq "net.netfilter.nf_conntrack_tcp_timeout_fin_wait"  "10" "FIN_WAIT超时"
    check_eq "net.netfilter.nf_conntrack_tcp_timeout_syn_sent"  "20" "SYN_SENT超时"
    check_eq "net.netfilter.nf_conntrack_tcp_timeout_syn_recv"  "20" "SYN_RECV超时"

    echo ""
    if [[ "$platform" == "nanopi-r4s" ]]; then
        echo -e "  ${BOLD}[nanopi-r4s 专用]${RESET}"
        check_eq "net.core.netdev_max_backlog"                                 "65535" "网卡队列"
        check_eq "vm.dirty_ratio"                                               "8"     "dirty比例(TF卡)"
        check_eq "vm.dirty_background_ratio"                                    "3"     "dirty后台比例"
        check_eq "vm.dirty_expire_centisecs"                                   "30000" "dirty过期时间(TF卡)"
        check_eq "vm.min_free_kbytes"                                          "65536" "min_free_kbytes(防OOM)"
        check_eq "net.netfilter.nf_conntrack_tcp_timeout_established"         "900"   "ESTABLISHED超时(收紧)"
    elif [[ "$platform" == "oracle-arm" ]]; then
        echo -e "  ${BOLD}[oracle-arm 专用]${RESET}"
        check_eq "net.core.netdev_max_backlog"                                 "65535" "网卡队列"
        check_eq "vm.dirty_ratio"                                               "20"    "dirty比例(云)"
        check_eq "vm.dirty_background_ratio"                                    "10"    "dirty后台比例"
        check_eq "net.netfilter.nf_conntrack_tcp_timeout_established"         "900"   "ESTABLISHED超时(收紧)"
        check_eq "net.netfilter.nf_conntrack_tcp_timeout_time_wait"           "10"    "TW超时(云)"
    elif [[ "$platform" == "nanopi-t6" ]]; then
        echo -e "  ${BOLD}[nanopi-t6 专用]${RESET}"
        check_eq "net.core.netdev_max_backlog"                                 "131072" "网卡队列(2.5GbE)"
        check_eq "vm.dirty_ratio"                                               "20"    "dirty比例(eMMC)"
        check_eq "vm.dirty_background_ratio"                                    "10"    "dirty后台比例"
        check_eq "net.netfilter.nf_conntrack_tcp_timeout_established"         "900"   "ESTABLISHED超时(收紧)"
        check_eq "net.netfilter.nf_conntrack_tcp_timeout_time_wait"            "10"    "TW超时"
    elif [[ "$platform" == "n5105" ]]; then
        echo -e "  ${BOLD}[n5105 专用]${RESET}"
        check_eq "net.core.netdev_max_backlog"                                 "65535" "网卡队列"
        check_eq "vm.dirty_ratio"                                               "15"    "dirty比例(SSD)"
        check_eq "vm.dirty_background_ratio"                                    "5"     "dirty后台比例"
        check_eq "net.netfilter.nf_conntrack_tcp_timeout_established"         "900"   "ESTABLISHED超时(收紧)"
        check_eq "net.netfilter.nf_conntrack_tcp_timeout_time_wait"           "15"    "TW超时"
    else
        echo -e "  ${BOLD}[generic-x86 / 通用平台]${RESET}"
        check_eq "vm.dirty_ratio"                                               "15"    "dirty比例"
        check_eq "vm.dirty_background_ratio"                                    "5"     "dirty后台比例"
        check_eq "net.netfilter.nf_conntrack_tcp_timeout_established"         "900"   "ESTABLISHED超时(收紧)"
        check_eq "net.netfilter.nf_conntrack_tcp_timeout_time_wait"           "15"    "TW超时"
    fi

    echo ""
    echo -e "${SEP}"
    echo -e "${BOLD}  验证结果汇总${RESET}"
    echo -e "${SEP}"
    echo -e "  ${GREEN}✓ 通过: ${passed} 项${RESET}"
    if [[ $failed -gt 0 ]]; then
        echo -e "  ${RED}✗ 有 ${failed} 项未通过 ← 需要修复${RESET}"
    else
        echo -e "  ${GREEN}✓ 全部通过!${RESET} (失败: 0 项)"
    fi
    echo -e "${SEP}"
}

#------------------------------------------------# -------------------------------
# 主函数
#------------------------------------------------# -------------------------------
main() {
    log_header
    check_system_info
    check_locale_chain

    echo ""
    echo -e "${YELLOW}提示: 部分检查需要 root 权限，建议: sudo $0${RESET}"

    check_sysctl_network
    check_sysctl_conntrack
    check_sysctl_memory
    check_limits
    check_ssh
    check_journald
    check_inotify
    check_swap
    check_zram_status
    check_fstrim_cron
    check_unattended_upgrades
    check_cpu
    check_services
    check_sysctl_files
    check_network_stats
    check_vs_targets

    echo ""
    echo -e "${SEP}"
    echo -e "${BOLD}  🎯 环境就绪状态${RESET}"
    echo -e "${SEP}"
    failed=0
    if [[ $failed -eq 0 ]]; then
        echo -e "  ${GREEN}✓ 底层环境优化完成，系统处于最佳状态${RESET}"
        echo -e "  ${GREEN}✓ 可以安全安装任意官方 agent 脚本（参考对应项目文档）${RESET}"
        echo ""
        echo -e "  ${CYAN}推荐下一步:${RESET}"
        echo -e "    1. ${YELLOW}reboot${RESET}  ← 使所有 sysctl 持久化生效"
        echo -e "    2. 安装你的 agent（Docker / Node.js 环境已就绪）"
    else
        echo -e "  ${RED}✗ 有 ${failed} 项未通过，请修复后再安装 agent${RESET}"
        echo -e "  ${DIM}提示: 核心安全项（syncookies/rp_filter/dns）通常不受影响${DIM}"
    fi

    echo ""
    echo -e "${SEP}"
    echo -e "  验证报告生成完毕 | v${VERSION} | $(date)"
    echo -e "${SEP}"
}

#------------------------------------------------# -------------------------------
# SSH 远程执行模式
#------------------------------------------------# -------------------------------
remote_check() {
    local host="$1"
    local user="${2:-root}"
    echo -e "${BOLD}${CYAN}▶ 远程验证: ${user}@${host}${RESET}"

    ssh -o StrictHostKeyChecking=no        -o ConnectTimeout=5        -o BatchMode=yes        "${user}@${host}"         "export VERSION=\$(cat /proc/cpuinfo 2>/dev/null | grep -m1 'model name' | cut -d: -f2 | xargs)
        echo '=== 基础信息 ==='
        echo CPU: \$VERSION
        echo 内核: \$(uname -r)
        echo 主机名: \$(hostname)

        echo ''
        echo '=== TCP 参数 ==='
        sysctl net.ipv4.tcp_tw_reuse net.ipv4.tcp_fin_timeout net.ipv4.tcp_rfc1337               net.ipv4.tcp_early_retrans net.ipv4.tcp_orphan_retries               net.ipv4.tcp_syncookies net.ipv4.tcp_congestion_control               net.ipv4.tcp_fastopen net.ipv4.tcp_mtu_probing               net.ipv4.tcp_notsent_lowat 2>/dev/null

        echo ''
        echo '=== 网络队列 ==='
        sysctl net.core.default_qdisc net.core.netdev_max_backlog               net.core.somaxconn net.core.rmem_max net.core.wmem_max 2>/dev/null

        echo ''
        echo '=== 安全参数 ==='
        sysctl net.ipv4.conf.all.accept_redirects net.ipv4.conf.all.secure_redirects net.ipv4.conf.all.rp_filter net.ipv4.tcp_syncookies 2>/dev/null

        echo ''
        echo '=== IPv6 ==='
        sysctl net.ipv6.conf.all.accept_redirects net.ipv6.conf.default.accept_redirects net.ipv6.conf.all.accept_source_route net.ipv6.conf.default.accept_source_route net.ipv6.conf.all.accept_ra net.ipv6.conf.default.accept_ra 2>/dev/null

        echo ''
        echo '=== 内存/TF卡保护 ==='
        sysctl vm.dirty_ratio vm.dirty_background_ratio vm.dirty_writeback_centisecs vm.dirty_expire_centisecs vm.swappiness vm.overcommit_memory 2>/dev/null

        echo ''
        echo '=== conntrack ==='
        sysctl net.netfilter.nf_conntrack_max               net.netfilter.nf_conntrack_tcp_timeout_established               net.netfilter.nf_conntrack_tcp_timeout_time_wait               net.netfilter.nf_conntrack_tcp_timeout_close_wait               net.netfilter.nf_conntrack_tcp_timeout_fin_wait 2>/dev/null

        echo ''
        echo '=== ulimit ==='
        ulimit -n

        echo ''
        echo '=== journald ==='
        grep -v '^#' /etc/systemd/journald.conf 2>/dev/null | grep -v '^$' | grep -v '^\['

        echo ''
        echo '=== SSH ==='
        grep -E '^(PermitRootLogin|PubkeyAuthentication|PasswordAuthentication|X11Forwarding|ClientAliveInterval|ClientAliveCountMax)' /etc/ssh/sshd_config 2>/dev/null

        echo ''
        echo '=== SWAP ==='
        swapon --show 2>/dev/null || echo '无活动swap'

        echo ''
        echo '=== CPU Governor ==='
        cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo N/A
        " 2>&1

    echo -e "${GREEN}远程验证完成: ${host}${RESET}"
}

#------------------------------------------------# -------------------------------
# 使用说明
#------------------------------------------------# -------------------------------
usage() {
    echo "VPS-youhua v${VERSION} 优化验证脚本"
    echo ""
    echo "用法:"
    echo "  $0                       # 本机完整验证"
    echo "  $0 --remote HOST         # 远程验证 (root@HOST)"
    echo "  $0 --remote USER@HOST    # 远程验证 (指定用户)"
    echo ""
    echo "示例:"
    echo "  sudo $0"
    echo "  sudo $0 --remote 129.213.34.131"
    echo "  sudo $0 --remote root@192.168.1.100"
}

#------------------------------------------------# -------------------------------
# 入口
#------------------------------------------------# -------------------------------
if [[ "${1:-}" == "--remote" ]]; then
    remote_check "${2:-}" "${3:-}"
elif [[ "${1:-}" =~ ^(-h|--help)$ ]]; then
    usage
else
    main
fi
