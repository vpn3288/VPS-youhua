#!/usr/bin/env bash
# =============================================================================
# AIagent 环境优化脚本（统一入口） v3.3
# 支持平台: NanoPi R4S, NanoPC T6, Oracle ARM, N5105, 通用 x86 VPS
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

readonly VERSION="3.3"
readonly RAW_BASE="https://raw.githubusercontent.com/vpn3288/VPS-youhua/main"

# ─────────────────────────────────────────────────────────────────────────────
# SHA256 校验和（防止供应链污染）
# ⚠️  脚本更新时必须同步更新对应 SHA256
# R54: 新手友好交互菜单(纯优化/全量安装/自定义), install.sh作为统一入口
# ─────────────────────────────────────────────────────────────────────────────

declare -A EXPECTED_SHA256=(
    ["nanopi-r4s"]="ef271da01e9cb9e82ce44e74ccb327d4e9c6600342b1a2e40cd429b6b1ff1384"
    ["nanopi-t6"]="143d551f92c78ac85eb91eee9e310288ff187b96294250af51789ccfb54a5078"
    ["oracle-arm"]="cc2817bd50bac11b70b469310934e701e54a8605a3c3eed9762f79acfc7d4a26"
    ["oracle-1c4g"]="f6cbf6effbe51e3ce20f8cc056e4c15ec6613cd5d5a1957b46e8f3cfb81b0f6e"
    ["n5105"]="e8dbfee4348d6860fdd000b1b8ad31318021aab6f15736fd6753f4785186278a"
    ["generic-x86"]="4381868c945d48a9b6ac9d43bdb33a9e34e1d65373bfb3c7012351fb23c0a58b"
    ["generic-1c1g"]="688167a0defa2e06923da00648a306721b7f80dfd23b6d4c2cb3558007df3898"
    ["google-cloud-e2"]="81469db7d63732fd753c6ed64efd27c519fedf9b3cc418b8a90a66ec454fa383"
    ["verify-v3.1"]="6fdd998e4ba8d8545e4eff27b7cddc8ce9880095b9d0336feffe3fa54385e4a3"
)

# ─────────────────────────────────────────────────────────────────────────────
# root 检查
# ─────────────────────────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
    echo "[✗] 请使用 root 运行: sudo bash \"$0\" \"$*\"" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 全局状态（菜单选择结果）
# ─────────────────────────────────────────────────────────────────────────────

SELECTED_PLATFORM=""      # nanopi-r4s | nanopi-t6 | oracle-arm | oracle-1c4g | n5105 | generic-x86 | generic-1c1g | google-cloud-e2
SELECTED_MODE=""          # optimize | full | custom
MODE=""                  # uninstall | status（命令行特殊模式）
INSTALL_DOCKER="ask"      # true | false | ask
INSTALL_NODEJS="ask"       # true | false | ask
CONFIGURE_UNATTENDED="true"   # true | false（自动安全更新，默认开）
CONFIGURE_FAIL2BAN="false"    # true | false（SSH防暴破，默认关）
CONFIGURE_MIRROR="auto"       # auto | off（APT镜像，默认自动测速）
INTERACTIVE=true

# ─────────────────────────────────────────────────────────────────────────────
# 参数解析
# ─────────────────────────────────────────────────────────────────────────────

FORCE_MODE=""
FORCE_PLATFORM=""

for arg in "$@"; do
    case "$arg" in
        --optimize|--optimize-only) FORCE_MODE="optimize" ;;
        --full|--install-all)        FORCE_MODE="full" ;;
        --no-software)               FORCE_MODE="optimize" ;;
        --install-deps)              INSTALL_DEPS="true" ;;
        --proxy-mode)                FORCE_MODE="optimize"; SKIP_SOFTWARE_SCRIPT="true"; OPTIMIZE_ONLY="true" ;;
        --non-interactive|-y|--yes)  INTERACTIVE=false; NONINTERACTIVE=1 ;;
        --with-docker)               INSTALL_DOCKER="true" ;;
        --without-docker)            INSTALL_DOCKER="false" ;;
        --with-npm)                  INSTALL_NODEJS="true" ;;
        --without-npm)               INSTALL_NODEJS="false" ;;
        --with-unattended)           CONFIGURE_UNATTENDED="true" ;;
        --without-unattended)        CONFIGURE_UNATTENDED="false" ;;
        --with-fail2ban)             CONFIGURE_FAIL2BAN="true" ;;
        --without-fail2ban)          CONFIGURE_FAIL2BAN="false" ;;
        --mirror-auto)               CONFIGURE_MIRROR="auto" ;;
        --mirror-off)                CONFIGURE_MIRROR="preserve" ;;
        --clean-system)              CLEAN_SYSTEM="true" ;;
        --uninstall)                 MODE="uninstall" ;;
        --status)                    MODE="status" ;;
        --help|-h)                   show_help; exit 0 ;;
        --platform) ;; # skip, handled below
        *)
            if [[ "$arg" == --platform=* ]]; then
                FORCE_PLATFORM="${arg#*=}"
            elif [[ "$arg" == --* ]]; then
                log_warn "未知选项: $arg"
            fi
            ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# 颜色
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

log_info()  { echo -e "${GREEN}[✓]${NC} $1" >&2; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1" >&2; }
log_step()  { echo -e "${CYAN}[➜]${NC} $1"; }

# ─────────────────────────────────────────────────────────────────────────────
# 健康检查（--status）
# ─────────────────────────────────────────────────────────────────────────────

run_verify_status() {
    echo -e "${BOLD}正在下载并运行环境健康检查...${NC}"
    local verify_url="${RAW_BASE}/verify-v3.1.sh"
    local verify_file
    verify_file=$(mktemp /tmp/vps-youhua-verify-XXXXXX.sh)

    if ! curl -fsSL "$verify_url" -o "$verify_file"; then
        log_error "无法下载 verify-v3.1.sh，请检查网络连接"
        rm -f "$verify_file"
        return 1
    fi

    # [C5] SHA256 校验
    local actual_sha256
    actual_sha256=$(sha256sum "$verify_file" | awk '{print $1}')
    if [[ "$actual_sha256" != "${EXPECTED_SHA256[verify-v3.1]}" ]]; then
        log_error "verify-v3.1.sh SHA256 校验失败！疑似供应链污染。"
        log_error "预期: ${EXPECTED_SHA256[verify-v3.1]}"
        log_error "实际: $actual_sha256"
        rm -f "$verify_file"
        return 1
    fi

    bash "$verify_file"
    local rv=$?

    # 清理临时文件
    rm -f "$verify_file"

    if [[ $rv -eq 0 ]]; then
        echo ""
        echo -e "${GREEN}✅ 环境健康检查通过！${NC}"
    else
        echo ""
        echo -e "${YELLOW}⚠️  环境健康检查有异常，请查看上方输出${NC}"
    fi

    return $rv
}

# ─────────────────────────────────────────────────────────────────────────────
# 帮助信息
# ─────────────────────────────────────────────────────────────────────────────

show_help() {
    cat << 'EOF'
用法: bash install.sh [选项]

选项:
  运行模式（二选一，不选则交互询问）:
    --optimize         只做底层系统优化，不安装任何软件
    --full             做系统优化 + 安装全部软件（Docker + Node.js）

  软件选择（仅 --full 时有效）:
    --with-docker      安装 Docker（默认: 询问或安装）
    --without-docker   不安装 Docker
    --with-npm         安装 Node.js（默认: 询问或安装）
    --without-npm      不安装 Node.js
    --no-software      跳过所有软件安装（等价于 --optimize）

  可选功能:
    --with-unattended     开启自动安全更新（默认已开启）
    --without-unattended   关闭自动安全更新
    --with-fail2ban        安装 fail2ban 防 SSH 暴破
    --without-fail2ban     不安装 fail2ban（默认）
    --mirror-auto          自动测速选择最快镜像源（默认）
    --mirror-off           跳过镜像切换，保持系统默认源

  其他:
    --non-interactive   非交互模式，使用默认选项
    --clean-system      优化前清理系统缓存
    --uninstall         卸载所有优化配置
    --status            运行环境健康检查（查看当前优化状态）
    --help, -h          显示本帮助信息

示例:
    bash install.sh                         # 交互式菜单（新手推荐）
    bash install.sh --optimize              # 只做优化，不装软件
    bash install.sh --full                  # 优化 + 全量安装
    bash install.sh --full --without-docker  # 优化 + 安装但跳过 Docker
    bash install.sh --status                 # 查看当前环境健康状态
    bash install.sh --with-fail2ban         # 优化 + 开启 fail2ban
    bash install.sh --without-unattended    # 优化，安全更新保持系统默认
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# APT 锁抢占处理（防止 unattended-upgrades 阻塞脚本）
# ─────────────────────────────────────────────────────────────────────────────

wait_for_apt_lock() {
    local max_wait=60
    local waited=0

    # 优雅停止 apt-daily 服务并屏蔽（防止恢复）
    for svc in apt-daily apt-daily-upgrade unattended-upgrades; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            log_warn "停止后台服务: $svc"
            systemctl stop "$svc" 2>/dev/null || true
        fi
        systemctl mask "$svc" 2>/dev/null || true
    done

    # 等待锁释放（同时检查进程和锁文件）
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
          pgrep -x apt-get >/dev/null 2>&1 || \
          pgrep -x dpkg >/dev/null 2>&1; do
        if [[ $waited -ge $max_wait ]]; then
            log_error "APT 锁等待超时（${max_wait}s），请手动检查："
            log_error "  1. ps aux | grep -E 'apt|dpkg'"
            log_error "  2. sudo kill <PID>"
            log_error "  3. sudo dpkg --configure -a"
            log_error "  4. 重新运行本脚本"
            return 1
        fi
        sleep 2
        waited=$((waited + 2))
    done

    # 确保 dpkg 状态正常
    dpkg --configure -a 2>/dev/null || true
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 取消屏蔽 apt-daily 服务（清理 wait_for_apt_lock 的副作用）
# ─────────────────────────────────────────────────────────────────────────────
cleanup_apt_mask() {
    for svc in apt-daily apt-daily-upgrade unattended-upgrades; do
        systemctl unmask "$svc" 2>/dev/null || true
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# 平台检测
# ─────────────────────────────────────────────────────────────────────────────

detect_platform() {
    # 先获取内存信息（用于内存级别路由）
    local sys_mem_mb=0
    if [[ -f /proc/meminfo ]]; then
        sys_mem_mb=$(awk '/MemTotal/{printf "%.0f", $2/1024}' /proc/meminfo)
    fi

    local arch
    arch="$(uname -m)"
    local cpu_model
    cpu_model="$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | sed 's/^ //' 2>/dev/null || echo "")"
    local model
    model="$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0' | xargs 2>/dev/null || echo "")"

    if [[ "$arch" == "armv7l" ]] || [[ "$arch" == "armv6l" ]]; then
        log_error "不支持 32位 ARM (${arch})，请使用 ARM64 设备"
        exit 1
    fi

    case "$arch" in
        aarch64|aarch64_be)
            if echo "$model" | grep -qi "NanoPi R4S"; then
                echo "nanopi-r4s"
            elif echo "$model" | grep -qiE "NanoPC.?T6|T6"; then
                echo "nanopi-t6"
            elif grep -qiE "oracle|oraclecloud" /sys/class/dmi/id/sys_vendor 2>/dev/null || \
                 echo "$cpu_model" | grep -qiE "Ampere|Altra"; then
                # Oracle Cloud：根据内存自动选择规格
                if [[ $sys_mem_mb -gt 0 ]] && [[ $sys_mem_mb -lt 8192 ]]; then
                    log_info "Oracle Cloud 检测到内存 ${sys_mem_mb}MB，自动选择 1核4G 配置"
                    echo "oracle-1c4g"
                else
                    echo "oracle-arm"
                fi
            elif echo "$cpu_model" | grep -qi "RK3588"; then
                echo "nanopi-t6"
            elif echo "$cpu_model" | grep -qi "RK3399"; then
                echo "nanopi-r4s"
            else
                # 未知 ARM64 设备，必须显式选择
                log_error "未知 ARM64 设备: ${cpu_model:-unknown}，不支持自动配置"
                log_info "请通过 --platform=<name> 指定平台，或运行交互式菜单选择"
                exit 1
            fi
            ;;
        x86_64)
            # ── Google Cloud 检测（优先于内存路由）─────────────────────────────
            local gcp_meta
            gcp_meta="$(curl -s --connect-timeout 3 -H "Metadata-Flavor: Google" \
                "http://metadata.google.internal/computeMetadata/v1/instance/machine-type" 2>/dev/null || echo "")"
            if echo "$gcp_meta" | grep -q "e2-micro\|e2-small\|e2-medium\|f1-micro\|g1-small"; then
                log_info "Google Cloud 检测通过（${gcp_meta}），使用 GCP e2 优化"
                echo "google-cloud-e2"
            elif echo "$cpu_model" | grep -qiE "N5105|N5095|J6412|J6413"; then
                echo "n5105"
            elif [[ $sys_mem_mb -gt 0 ]] && [[ $sys_mem_mb -lt 2048 ]]; then
                # 1GB 及以下内存，自动使用极简版
                log_info "检测到内存 ${sys_mem_mb}MB，自动选择 1核1G 极简版配置"
                echo "generic-1c1g"
            else
                echo "generic-x86"
            fi
            ;;
        *)
            log_error "不支持的架构: $arch"
            exit 1
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# 网络检测
# ─────────────────────────────────────────────────────────────────────────────

check_network() {
    log_step "检测网络连通性..."

    if ! host -W 3 "cloudflare.com" >/dev/null 2>&1 && \
       ! getent hosts "github.com" >/dev/null 2>&1; then
        log_error "DNS 解析失败，请检查 /etc/resolv.conf 和 nameserver 配置"
        exit 1
    fi

    if ! curl --silent --head --fail --connect-timeout 5 \
        -H "Host: www.cloudflare.com" https://104.16.123.96 >/dev/null 2>&1 && \
       ! curl --silent --head --fail --connect-timeout 5 \
        https://github.com >/dev/null 2>&1; then
        log_warn "HTTPS 不可达（可能存在防火墙限制），尝试 ping..."
        if ! ping -c 2 -W 4 1.1.1.1 >/dev/null 2>&1; then
            log_error "网络完全不可达，请检查网络连接"
            exit 1
        fi
        log_warn "网络检测降级为 ping 模式（部分云环境 ICMP 被限速）"
    fi

    log_info "网络检测通过"
}

# ─────────────────────────────────────────────────────────────────────────────
# 交互式主菜单
# ─────────────────────────────────────────────────────────────────────────────

show_banner() {
    clear
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                       ║"
    echo "║              AIagent 环境优化脚本 v${VERSION}                             ║"
    echo "║              新手友好 · 自由选择 · 安全可控                           ║"
    echo "║              支持代理节点纯环境优化模式                               ║"
    echo "║                                                                       ║"
    echo "╚═══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
}

show_platform_info() {
    local platform="$1"
    echo -e "  ${BLUE}检测到平台: ${BOLD}${platform}${NC}"
    case "$platform" in
        nanopi-r4s)
            echo -e "  ${BLUE}设备:     NanoPi R4S (RK3399 ARM64)${NC}"
            echo -e "  ${BLUE}存储:     TF卡（已针对写入保护优化）${NC}"
            echo -e "  ${BLUE}特点:     双千兆网口，低功耗${NC}"
            ;;
        nanopi-t6)
            echo -e "  ${BLUE}设备:     NanoPC T6 (RK3588 ARM64)${NC}"
            echo -e "  ${BLUE}存储:     eMMC（已针对eMMC优化）${NC}"
            echo -e "  ${BLUE}特点:     3网口(1×GbE+2×2.5GbE)，16GB大内存${NC}"
            ;;
        oracle-arm)
            echo -e "  ${BLUE}设备:     Oracle Cloud ARM (Ampere Altra, 2核+)${NC}"
            echo -e "  ${BLUE}存储:     云盘（高IOPS）${NC}"
            echo -e "  ${BLUE}特点:     TCP缓冲自适应优化${NC}"
            ;;
        oracle-1c4g)
            echo -e "  ${BLUE}设备:     Oracle Cloud ARM 精选（1核 4GB）${NC}"
            echo -e "  ${BLUE}存储:     云盘${NC}"
            echo -e "  ${BLUE}特点:     zram内存扩展 + 精简资源限制${NC}"
            ;;
        n5105)
            echo -e "  ${BLUE}设备:     N5105/N5095 小主机 (x86_64)${NC}"
            echo -e "  ${BLUE}存储:     SSD${NC}"
            echo -e "  ${BLUE}特点:     低功耗，有风扇${NC}"
            ;;
        generic-x86)
            echo -e "  ${BLUE}设备:     通用 x86_64 VPS（2GB+ 内存）${NC}"
            echo -e "  ${BLUE}特点:     自动适配${NC}"
            ;;
        generic-1c1g)
            echo -e "  ${BLUE}设备:     通用 1核 1G VPS（极简版）${NC}"
            echo -e "  ${BLUE}特点:     zram扩展 + 极保守资源限制${NC}"
            ;;
        google-cloud-e2)
            echo -e "  ${BLUE}设备:     Google Cloud e2-micro（Always Free）${NC}"
            echo -e "  ${BLUE}存储:     30GB SSD${NC}"
            echo -e "  ${BLUE}特点:     共享 CPU(burstable) + Intel + VPC 网络优化${NC}"
            echo -e "  ${BLUE}说明:     仅环境优化，不安装 Docker / Node.js / Agent${NC}"
            ;;
    esac
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# 菜单步骤
# ─────────────────────────────────────────────────────────────────────────────

#────────────────────────────────────────────────────────────────
# OPTIMIZE #3: 新手友好快速选择菜单（5选项）
# 位置: 交互式入口，在 step1 之前调用
#────────────────────────────────────────────────────────────────
show_quick_start_menu() {
    # NONINTERACTIVE 模式跳过交互菜单
    if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
        quick_choice="${QUICK_CHOICE:-1}"
        log_info "非交互模式: quick_choice=${quick_choice}"
        return 0
    fi

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  ⚡ 快速选择（新手友好）${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}[1]${NC} ${BOLD}仅底层优化${NC} ← ${CYAN}新手推荐${NC}"
    echo -e "       sysctl参数 / DNS / CPU调频 / journald / 防火墙"
    echo -e "       ${YELLOW}不安装 Docker / Node.js / Agent${NC}"
    echo -e "       ${GREEN}适合: 代理节点 / 后续自装软件 / 低配置小鸡${NC}"
    echo ""
    echo -e "  ${GREEN}[2]${NC} ${BOLD}底层优化 + 基础编译依赖${NC}"
    echo -e "       纯优化 + build-essential / cmake / python3"
    echo -e "       ${GREEN}适合: 后续编译安装软件（v2ray-core / xray 等）${NC}"
    echo ""
    echo -e "  ${GREEN}[3]${NC} ${BOLD}底层优化 + Docker${NC}"
    echo -e "       纯优化 + Docker 最新版"
    echo -e "       ${GREEN}适合: Docker Compose / 容器化部署${NC}"
    echo ""
    echo -e "  ${GREEN}[4]${NC} ${BOLD}底层优化 + Node.js${NC}"
    echo -e "       纯优化 + Node.js LTS"
    echo -e "       ${GREEN}适合: JavaScript 运行时 / npm 工具链${NC}"
    echo ""
    echo -e "  ${GREEN}[5]${NC} ${BOLD}全量安装（一步到位）${NC}"
    echo -e "       底层优化 + Docker + Node.js"
    echo -e "       ${GREEN}适合: 直接跑 AIagent / 完整开发环境${NC}"
    echo ""
    echo -e "  ${GREEN}[6]${NC} ${BOLD}专家模式（完全自定义）${NC}"
    echo -e "       4步引导: 选平台 → 选套餐 → 选功能 → 确认"
    echo ""
    echo -n "请输入选项 [1/2/3/4/5/6，默认 1]: "
    read -r quick_choice
    quick_choice="${quick_choice:-1}"

    case "$quick_choice" in
        1)
            SELECTED_MODE="optimize"
            INSTALL_DOCKER="false"
            INSTALL_NODEJS="false"
            INSTALL_DEPS="false"
            CONFIGURE_UNATTENDED="true"
            CONFIGURE_FAIL2BAN="false"
            CONFIGURE_MIRROR="auto"
            log_info "快速模式: 仅底层优化"
            ;;
        2)
            SELECTED_MODE="optimize"
            INSTALL_DEPS="true"
            INSTALL_DOCKER="false"
            INSTALL_NODEJS="false"
            CONFIGURE_UNATTENDED="true"
            CONFIGURE_FAIL2BAN="false"
            CONFIGURE_MIRROR="auto"
            log_info "快速模式: 底层优化 + 基础依赖"
            ;;
        3)
            SELECTED_MODE="full"
            INSTALL_DOCKER="true"
            INSTALL_NODEJS="false"
            INSTALL_DEPS="true"
            CONFIGURE_UNATTENDED="true"
            CONFIGURE_FAIL2BAN="false"
            CONFIGURE_MIRROR="auto"
            log_info "快速模式: 底层优化 + Docker"
            ;;
        4)
            SELECTED_MODE="full"
            INSTALL_DOCKER="false"
            INSTALL_NODEJS="true"
            INSTALL_DEPS="true"
            CONFIGURE_UNATTENDED="true"
            CONFIGURE_FAIL2BAN="false"
            CONFIGURE_MIRROR="auto"
            log_info "快速模式: 底层优化 + Node.js"
            ;;
        5)
            SELECTED_MODE="full"
            INSTALL_DOCKER="true"
            INSTALL_NODEJS="true"
            INSTALL_DEPS="true"
            CONFIGURE_UNATTENDED="true"
            CONFIGURE_FAIL2BAN="false"
            CONFIGURE_MIRROR="auto"
            log_info "快速模式: 全量安装"
            ;;
        6)
            # 专家模式: 使用原有 4 步流程
            return 1  # 通知调用方继续 4-step 流程
            ;;
        *)
            echo -e "${YELLOW}无效选项，默认仅底层优化${NC}"
            SELECTED_MODE="optimize"
            ;;
    esac
}


step1_choose_platform() {
    # NONINTERACTIVE 模式：跳过菜单，使用默认值
    if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
        if [[ -z "$SELECTED_PLATFORM" ]]; then
            SELECTED_PLATFORM=$(detect_platform)
            log_info "非交互模式: 自动检测平台 = $SELECTED_PLATFORM"
        else
            log_info "非交互模式: 使用预设平台 = $SELECTED_PLATFORM"
        fi
        return 0
    fi

    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  Step 1/4：选择你的设备类型${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}[1]${NC} ARM 开发板（NanoPi R4S / NanoPC T6）"
    echo -e "  ${GREEN}[2]${NC} 云服务器（Oracle Cloud ARM）"
    echo -e "  ${GREEN}[3]${NC} 小主机（N5105 / N5095）"
    echo -e "  ${GREEN}[4]${NC} Google Cloud（e2-micro 永久免费）"
    echo -e "  ${GREEN}[5]${NC} 通用 x86_64 VPS"
    echo ""
    echo -n "请输入选项 [1/2/3/4/5]: "
    read -r -t 15 choice || choice=""
    case "$choice" in
        1) PLATFORM_CATEGORY="arm" ;;
        2) PLATFORM_CATEGORY="oracle" ;;
        3) PLATFORM_CATEGORY="n5105" ;;
        4) PLATFORM_CATEGORY="google" ;;
        5) PLATFORM_CATEGORY="generic" ;;
        *) echo -e "${YELLOW}无效选项${NC}"; step1_choose_platform; return ;;
    esac
}

step2_choose_subplatform() {
    # NONINTERACTIVE 模式：跳过菜单，使用 SELECTED_PLATFORM
    if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
        log_info "非交互模式: subplatform 使用 SELECTED_PLATFORM=${SELECTED_PLATFORM:-auto}"
        return 0
    fi

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  Step 2/4：选择具体设备${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    case "$PLATFORM_CATEGORY" in
        arm)
            echo -e "  ${GREEN}[1]${NC} NanoPi R4S"
            echo -e "       RK3399 ARM64 | 双千兆网口 | TF卡存储 | 3.8GB RAM"
            echo ""
            echo -e "  ${GREEN}[2]${NC} NanoPC T6 / T6S"
            echo -e "       RK3588 ARM64 | 3网口 | eMMC存储 | 16GB RAM"
            echo ""
            echo -n "请输入选项 [1/2]: "
            read -r choice
            case "$choice" in
                1) SELECTED_PLATFORM="nanopi-r4s" ;;
                2) SELECTED_PLATFORM="nanopi-t6" ;;
                *) echo -e "${YELLOW}无效选项${NC}"; step2_choose_subplatform; return ;;
            esac
            ;;
        oracle)
            echo -e "  ${GREEN}[1]${NC} Oracle Cloud ARM（2核 8GB+）"
            echo -e "       Ampere Altra | 2核起 | Oracle Cloud 标准配置"
            echo ""
            echo -e "  ${GREEN}[2]${NC} Oracle Cloud ARM 精选（1核 4GB）"
            echo -e "       Ampere Altra | 1核 4GB | Oracle 促销机型（仅环境优化）"
            echo ""
            echo -n "请输入选项 [1/2]: "
            read -r choice
            case "$choice" in
                1) SELECTED_PLATFORM="oracle-arm" ;;
                2) SELECTED_PLATFORM="oracle-1c4g" ;;
                *) echo -e "${YELLOW}无效选项${NC}"; step2_choose_subplatform; return ;;
            esac
            ;;
        google)
            echo -e "  ${GREEN}[1]${NC} Google Cloud e2-micro（永久免费）"
            echo -e "       1vCPU 共享 | 1GB RAM | 30GB SSD | Always Free（仅环境优化）"
            echo ""
            echo -n "请输入选项 [1]: "
            read -r choice
            case "$choice" in
                1) SELECTED_PLATFORM="google-cloud-e2" ;;
                *) echo -e "${YELLOW}无效选项${NC}"; step2_choose_subplatform; return ;;
            esac
            ;;
        n5105)
            echo -e "  ${GREEN}[1]${NC} N5105 / N5095 小主机"
            echo -e "       x86_64 | 低功耗 | 有风扇 | SSD存储"
            echo ""
            echo -n "请输入选项 [1]: "
            read -r choice
            SELECTED_PLATFORM="n5105"
            ;;
        generic)
            echo -e "  ${GREEN}[1]${NC} 通用 x86_64 VPS（2GB+ 内存）"
            echo -e "       任何 x86_64 云服务器均可（2GB 及以上内存）"
            echo ""
            echo -e "  ${GREEN}[2]${NC} 通用 1核 1G VPS（极简版）"
            echo -e "       最低配套餐 | 1GB 内存 | 仅环境优化，不安装重软件"
            echo ""
            echo -n "请输入选项 [1/2]: "
            read -r choice
            case "$choice" in
                1) SELECTED_PLATFORM="generic-x86" ;;
                2) SELECTED_PLATFORM="generic-1c1g" ;;
                *) echo -e "${YELLOW}无效选项${NC}"; step2_choose_subplatform; return ;;
            esac
            ;;
    esac

    show_platform_info "$SELECTED_PLATFORM"
}

step3_choose_mode() {
    # NONINTERACTIVE 模式：跳过菜单，使用 SELECTED_MODE
    if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
        log_info "非交互模式: mode 使用 SELECTED_MODE=${SELECTED_MODE:-optimize}"
        return 0
    fi

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  Step 3/4：选择运行模式${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}[1]${NC} ${BOLD}纯系统优化（新手推荐）${NC}"
    echo -e "       只做底层优化: sysctl参数 / journald / DNS / CPU调频 / 防火墙"
    echo -e "       ${YELLOW}不安装 Docker / Node.js${NC}"
    echo -e "       适合: 只想优化环境，后续自己装其他软件（Xray / Nginx / Docker Compose 等）"
    echo ""
    echo -e "  ${GREEN}[2]${NC} ${BOLD}全量安装（一步到位）${NC}"
    echo -e "       系统优化 + 自动安装: Docker + Node.js"
    echo -e "       ${YELLOW}适合: 想一条命令搞定所有，直接跑 AIagent${NC}"
    echo ""
    echo -e "  ${GREEN}[0]${NC}  退出"
    echo ""
    echo -n "请输入选项 [1/2/0，默认 1]: "
    read -r choice
    choice="${choice:-1}"
    case "$choice" in
        1) SELECTED_MODE="optimize" ;;
        2) SELECTED_MODE="full" ;;
        0) echo "已退出。"; exit 0 ;;
        *) echo -e "${YELLOW}无效选项${NC}"; step3_choose_mode; return ;;
    esac
}

step4_choose_features() {
    # NONINTERACTIVE 模式：跳过菜单，使用默认值
    if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
        CONFIGURE_UNATTENDED="${CONFIGURE_UNATTENDED:-true}"
        CONFIGURE_FAIL2BAN="${CONFIGURE_FAIL2BAN:-false}"
        CONFIGURE_MIRROR="${CONFIGURE_MIRROR:-auto}"
        log_info "非交互模式: features 使用默认值（安全更新开，fail2ban关，镜像测速）"
        return 0
    fi

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  Step 4/4：可选功能（安全加固）${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}[A]${NC} ${BOLD}自动安全更新（unattended-upgrades）${NC}"
    echo -e "       每日自动检查并安装安全更新，不自动重启"
    echo -e "       ${CYAN}适合: 生产服务器、长期运行的设备${NC}  ${YELLOW}[默认: 开启]${NC}"
    echo ""
    echo -e "  ${GREEN}[B]${NC} ${BOLD}SSH 防暴力破解（fail2ban）${NC}"
    echo -e "       失败3次封IP 1小时，检测 SSH 暴力破解"
    echo -e "       ${CYAN}适合: 有公网 IP 的 VPS（Oracle/通用 x86）${NC}  ${YELLOW}[默认: 关闭]${NC}"
    echo ""
    echo -e "  ${GREEN}[C]${NC} ${BOLD}APT 镜像源切换${NC}"
    echo -e "       自动测速选择最快镜像（腾讯/阿里/清华）"
    echo -e "       ${CYAN}选 OFF 保持系统默认源${NC}  ${YELLOW}[默认: 自动测速]${NC}"
    echo ""
    echo -e "  ${GREEN}[D]${NC}  使用全部默认值（安全更新开，其余关）"
    echo ""
    echo -n "请输入选项 [A/B/C/D，默认 D]: "
    read -r -t 30 choice || choice="D"
    choice="${choice:-D}"
    # Sanitize: only accept valid choices
    if [[ ! "$choice" =~ ^[aAbBcCdD]$ ]]; then
        log_warn "无效选项 '$choice'，使用默认值 D"
        choice="D"
    fi
    case "$choice" in
        a|A)
            CONFIGURE_UNATTENDED="true"
            CONFIGURE_FAIL2BAN="false"
            CONFIGURE_MIRROR="off"
            ;;
        b|B)
            CONFIGURE_UNATTENDED="false"
            CONFIGURE_FAIL2BAN="true"
            CONFIGURE_MIRROR="off"
            echo ""
            echo -e "${YELLOW}⚠️  重要提示：fail2ban 开启后，请确保已配置 SSH 密钥登录！${NC}"
            echo -e "${YELLOW}   否则如果密码登录失败3次，当前 IP 会被封禁1小时。${NC}"
            echo -e "${YELLOW}   如需保留密码登录作为备份，请先编辑 /etc/ssh/sshd_config 添加密钥后再继续。${NC}"
            echo ""
            # ── SSH 密钥登录新手提示 ───────────────────────────────────────
            if [[ -t 0 ]]; then
                echo -e "  ${BOLD}是否配置 SSH 密钥登录？${NC}（推荐生产环境开启）"
                echo -e "  ${GREEN}[1]${NC} 跳过（保持当前 SSH 配置不变）"
                echo -e "  ${GREEN}[2]${NC} 引导配置（生成密钥对，显示公钥，提示添加到 ~/.ssh/authorized_keys）"
                echo ""
                echo -n "请输入选项 [1/2，默认 1]: "
                read -r ssh_key_choice
                ssh_key_choice="${ssh_key_choice:-1}"
                case "$ssh_key_choice" in
                    2)
                        CONFIGURE_SSH_KEY="true"
                        log_info "SSH 密钥登录引导已开启（请在下一步确认）"
                        ;;
                    *)
                        CONFIGURE_SSH_KEY="false"
                        ;;
                esac
            fi
            ;;
        c|C)
            CONFIGURE_UNATTENDED="false"
            CONFIGURE_FAIL2BAN="false"
            CONFIGURE_MIRROR="auto"
            ;;
        d|D)
            # 全部使用默认值（已在变量声明中设置）
            CONFIGURE_UNATTENDED="true"
            CONFIGURE_FAIL2BAN="false"
            CONFIGURE_MIRROR="auto"
            ;;
        *)
            echo -e "${YELLOW}无效选项${NC}"; step4_choose_features; return ;;
    esac
}

resolve_full_extras() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  全量安装 — 确认安装内容${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Docker
    if [[ "$INSTALL_DOCKER" == "ask" ]]; then
        echo -e "  ${GREEN}[✓]${NC} ${BOLD}Docker${NC}（容器引擎，用于运行容器化应用等）"
        echo -e "      ${CYAN}建议安装，输入 y 或直接回车${NC}"
        echo -n "  是否安装 Docker？[y/n，默认 y]: "
        read -r yn

        yn="${yn:-y}"
        case "$yn" in
            n|N) INSTALL_DOCKER="false" ;;
            *)   INSTALL_DOCKER="true" ;;
        esac
    fi

    # Node.js
    if [[ "$INSTALL_NODEJS" == "ask" ]]; then
        echo ""
        echo -e "  ${GREEN}[✓]${NC} ${BOLD}Node.js${NC}（运行环境，用于全局安装 npm 包）"
        echo -n "  是否安装 Node.js？[y/n，默认 y]: "
        read -r yn

        yn="${yn:-y}"
        case "$yn" in
            n|N) INSTALL_NODEJS="false" ;;
            *)   INSTALL_NODEJS="true" ;;
        esac
    fi

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  最终确认${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  平台:     ${BOLD}${SELECTED_PLATFORM}${NC}"

    if [[ "$SELECTED_MODE" == "optimize" ]]; then
        echo -e "  模式:     ${BOLD}纯系统优化${NC}"
        echo -e "  软件:     ${YELLOW}不安装${NC}"
    else
        echo -e "  模式:     ${BOLD}全量安装${NC}"
        local docker_yn="是"; [[ "$INSTALL_DOCKER" == "false" ]] && docker_yn="否"
        local nodejs_yn="是"; [[ "$INSTALL_NODEJS" == "false" ]] && nodejs_yn="否"
        echo -e "  Docker:   ${docker_yn}"
        echo -e "  Node.js:  ${nodejs_yn}"
    fi
    echo ""
    echo -e "  ${CYAN}可选功能:${NC}"
    local ua_yn="开启"; [[ "$CONFIGURE_UNATTENDED" == "false" ]] && ua_yn="关闭"
    local f2b_yn="关闭"; [[ "$CONFIGURE_FAIL2BAN" == "true" ]] && f2b_yn="开启"
    local mirror_desc="$CONFIGURE_MIRROR"; [[ "$mirror_desc" == "auto" ]] && mirror_desc="自动测速"; [[ "$mirror_desc" == "off" ]] && mirror_desc="保持默认"
    echo -e "    自动安全更新: ${ua_yn}  |  fail2ban: ${f2b_yn}  |  镜像: ${mirror_desc}"

    echo ""
    echo -e "${YELLOW}即将开始执行，是否继续？${NC}"
    echo -n "按回车继续，或 Ctrl+C 取消: "
    [[ "$INTERACTIVE" == "true" ]] && read -r dummy || true
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# 下载 → SHA256 校验 → 执行平台脚本
# ─────────────────────────────────────────────────────────────────────────────

download_and_run() {
    local platform="$1"
    local mode="$2"   # optimize | full

    # 在临时目录下载平台脚本 + common-optimize.sh（确保 source 路径有效）
    local tmpdir
    if ! tmpdir=$(mktemp -d 2>/dev/null); then
        log_error "无法创建临时目录，请检查磁盘空间和权限"
        return 1
    fi
    
    if [[ ! -d "$tmpdir" ]]; then
        log_error "临时目录创建失败: $tmpdir"
        return 1
    fi
    
    chmod 755 "$tmpdir"

    local platform_url="${RAW_BASE}/${platform}.sh"
    local common_url="${RAW_BASE}/common-optimize.sh"
    local platform_file="${tmpdir}/${platform}.sh"
    local common_file="${tmpdir}/common-optimize.sh"

    log_step "检查 ${platform}.sh..."
    if ! curl --head --silent --fail "$platform_url" >/dev/null 2>&1; then
        log_error "平台脚本不存在: $platform_url"
        rm -rf "$tmpdir"
        exit 1
    fi

    log_step "下载 ${platform}.sh + common-optimize.sh..."
    if ! curl -fsSL "$platform_url" -o "$platform_file"; then
        log_error "下载失败: $platform_url"
        rm -rf "$tmpdir"
        exit 1
    fi
    if ! curl -fsSL "$common_url" -o "$common_file"; then
        log_error "下载失败: $common_url"
        rm -rf "$tmpdir"
        exit 1
    fi

    # SHA256 校验（仅平台脚本）
    local expected="${EXPECTED_SHA256[$platform]:-}"
    if [[ -n "$expected" ]]; then
        local actual; actual=$(sha256sum "$platform_file" | awk '{print $1}')
        if [[ "$actual" != "$expected" ]]; then
            log_error "SHA256 校验失败！文件可能被篡改。"
            log_error "期望: $expected"
            log_error "实际: $actual"
            rm -rf "$tmpdir"
            exit 1
        fi
        log_info "SHA256 校验通过"
    else
        log_error "平台 ${platform} 缺少 SHA256 校验值，请检查配置"
        rm -rf "$tmpdir"
        exit 1
    fi

    log_step "执行 ${platform}.sh..."

    # Armbian 检测：仅在用户未明确选择时才跳过镜像切换
    if [[ -f /etc/armbian-release ]] && [[ "$CONFIGURE_MIRROR" == "auto" ]]; then
        CONFIGURE_MIRROR="off"
        log_info "检测到 Armbian，自动跳过 APT 镜像切换"
    fi

    # 透传环境变量给平台脚本
    export SKIP_SOFTWARE_SCRIPT="false"
    export INSTALL_DOCKER="$INSTALL_DOCKER"
    export INSTALL_NODEJS="$INSTALL_NODEJS"
    export INSTALL_DOCKER_SCRIPT="$INSTALL_DOCKER"
    export INSTALL_NODEJS_SCRIPT="$INSTALL_NODEJS"
    export INSTALL_DEPS="${INSTALL_DEPS:-false}"
    export INSTALL_METHOD="docker"
    export CONFIGURE_UNATTENDED="$CONFIGURE_UNATTENDED"
    export CONFIGURE_FAIL2BAN="$CONFIGURE_FAIL2BAN"
    export CONFIGURE_MIRROR="$CONFIGURE_MIRROR"

    # 清理函数：执行完毕后删除临时目录
    trap 'rm -rf "$tmpdir"' EXIT

    if [[ "$mode" == "optimize" ]]; then
        export SKIP_SOFTWARE_SCRIPT="true"
        bash "$platform_file" --optimize-only
    else
        bash "$platform_file"
    fi

    local ret=$?
    return $ret
}

# ─────────────────────────────────────────────────────────────────────────────
# 卸载
# ─────────────────────────────────────────────────────────────────────────────

uninstall_all() {
    clear
    echo -e "${RED}"
    echo "╔═══════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                       ║"
    echo "║              AIagent 环境优化脚本 v${VERSION} — 卸载模式               ║"
    echo "║                                                                       ║"
    echo "╚═══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""

    check_network

    cleanup_apt_mask

    local platform; platform=$(detect_platform)
    log_info "检测到平台: $platform"
    echo ""

    if [[ "$INTERACTIVE" == "true" ]]; then
        echo -e "${RED}警告：此操作将清理本脚本安装的所有环境优化配置！${NC}"
        echo ""
        echo -n "确认卸载？(输入 'yes' 继续): "
        read -r confirm
        [[ "$confirm" != "yes" ]] && { echo "已取消。"; exit 0; }
    fi

    echo ""
    log_step "调用 ${platform}.sh --uninstall..."
    echo ""

    # 在临时目录下载平台脚本 + common-optimize.sh
    local tmpdir; tmpdir=$(mktemp -d)
    chmod 755 "$tmpdir"
    trap 'rm -rf "$tmpdir"' EXIT

    local platform_file="${tmpdir}/${platform}.sh"
    local common_file="${tmpdir}/common-optimize.sh"

    if ! curl -fsSL "${RAW_BASE}/${platform}.sh" -o "$platform_file"; then
        log_error "下载失败: ${RAW_BASE}/${platform}.sh"
        rm -rf "$tmpdir"
        exit 1
    fi
    if ! curl -fsSL "${RAW_BASE}/common-optimize.sh" -o "$common_file"; then
        log_error "下载失败: ${RAW_BASE}/common-optimize.sh"
        rm -rf "$tmpdir"
        exit 1
    fi

    bash "$platform_file" --uninstall
    local ret=$?
    rm -rf "$tmpdir"
    trap - EXIT

    if [[ $ret -eq 0 ]]; then
        echo ""
        echo "========================================================================"
        echo -e "${GREEN}  ✅ 卸载完成${NC}"
        echo "========================================================================"
    else
        echo ""
        log_error "平台脚本卸载失败 (exit $ret)"
    fi
    exit $ret
}

# ─────────────────────────────────────────────────────────────────────────────
# 主函数
# ─────────────────────────────────────────────────────────────────────────────

main() {
    local APT_LOG
    APT_LOG=$(mktemp /tmp/vps-youhua-apt-XXXXXX.log)
    
    if [[ "${MODE:-}" == "uninstall" ]]; then
        uninstall_all
        return
    fi

    trap 'rm -f /tmp/vps-youhua-*.sh' EXIT

    # ── 抢占 APT 锁（防止 unattended-upgrades 阻塞脚本）────────────────────────
    if ! wait_for_apt_lock; then
        log_error "APT 锁处理失败，请稍后重试或手动运行: systemctl status apt-daily"
        exit 1
    fi

    # BUG#6 FIX: DD 镜像 SSL 证书（第一步必须执行，防止 GitHub 拉取失败）
    if ! command -v update-ca-certificates &>/dev/null; then
        log_info "安装 CA 证书（DD 镜像必需）..."
        apt-get install -y ca-certificates >> "$APT_LOG" 2>&1 && update-ca-certificates >> "$APT_LOG" 2>&1 || true
    fi

    # ── 幂等性检测（是否重复运行）─────────────────────────────────────────────
    if [[ -f /etc/vps-youhua-optimized ]]; then
        local opt_time
        opt_time=$(stat -c '%y' /etc/vps-youhua-optimized 2>/dev/null | cut -d' ' -f1,2 | cut -d'.' -f1)
        echo ""
        echo -e "${YELLOW}[!] 检测到系统已完成过优化（${opt_time}）${NC}"
        echo -e "${YELLOW}   重复运行将重新应用所有优化项，请确认是否继续？${NC}"
        if [[ "$*" != *"-y"* && "$*" != *"--yes"* ]]; then
            echo -e "   按 ${BOLD}Enter${NC} 继续，或 ${BOLD}Ctrl+C${NC} 退出..."
            read -r </dev/tty || true
        fi
    fi

    show_banner

    # ── MODE=status 直接运行验证 ─────────────────────────────────────────
# BUG#12 FIX: 非交互模式跳过所有 read
# 用法: NONINTERACTIVE=1 ./install.sh --platform=xxx --mode=optimize
# 或: ./install.sh --platform=xxx --mode=optimize -y
# 自动设置默认选项，防止 read 永久挂起
if [[ "${NONINTERACTIVE:-0}" == "1" ]] || [[ "${1:-}" == "-y" ]]; then
    export INTERACTIVE=false
    log_info "非交互模式（NONINTERACTIVE=1 / -y）: 使用默认选项"
fi

    if [[ "${MODE}" == "status" ]]; then
        log_info "运行状态验证..."
        local verify_script
        verify_script="$(cd "$(dirname "$0")" && pwd)/verify-v3.1.sh"
        if [[ -f "$verify_script" ]]; then
            bash "$verify_script"; local ret=$?; exit $ret
        else
            log_error "验证脚本不存在: $verify_script"; exit 1
        fi
    fi

    check_network

    # 自动检测平台（允许用户修改）
    # ── BUG#14: 低内存自动锁（<1024MB 强制纯代理底层优化）──────────────
    local low_mem_kb low_mem_mb
    low_mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo "0")
    low_mem_mb=$((low_mem_kb / 1024))
    if [[ "${low_mem_mb:-0}" -gt 0 ]] && [[ "${low_mem_mb}" -lt 1024 ]]; then
        echo ""
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}  🔒 检测到极低内存机器: ${low_mem_mb}MB < 1024MB${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  ${YELLOW}自动锁定为${NC} ${GREEN}纯代理底层优化模式${NC}（不装 Docker/Node.js）"
        echo -e "  ${YELLOW}防止内存不足导致机器死机！${NC}"
        SELECTED_MODE="optimize"
        INSTALL_DOCKER="false"
        INSTALL_NODEJS="false"
        INSTALL_DEPS="false"
        CONFIGURE_UNATTENDED="true"
        CONFIGURE_FAIL2BAN="false"
        CONFIGURE_MIRROR="auto"
        log_info "极低内存机器，已强制锁定为纯代理模式"
    fi

    # ── 低内存警告 (<2G) ───────────────────────────────────────────────
    if [[ -t 0 ]]; then
        local check_mem
        check_mem=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "0")
        if [[ "${check_mem:-0}" -gt 0 ]] && [[ "${check_mem}" -lt 2048 ]]; then
            echo ""
            echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${YELLOW}  ⚠️  低内存警告: ${check_mem}MB < 2048MB${NC}"
            echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "  ${YELLOW}检测到可用内存 < 2GB，建议使用${NC} ${GREEN}选项 [1] 仅底层优化${NC}"
            echo -e "  ${YELLOW}代理节点/极小鸡推荐纯优化模式，不装 Docker/Node.js${NC}"
            echo ""
        fi
    fi

    local auto_platform; auto_platform=$(detect_platform)
    show_platform_info "$auto_platform"

    # ── 如果有 --platform= 强制标志，直接用 ─────────────────────────────
    if [[ -n "$FORCE_PLATFORM" ]]; then
        SELECTED_PLATFORM="$FORCE_PLATFORM"
        SELECTED_MODE="${FORCE_MODE:-optimize}"
        echo -e "${GREEN}使用指定平台: ${SELECTED_PLATFORM}${NC}"
        echo -e "${GREEN}使用指定模式: ${SELECTED_MODE}${NC}"
    elif [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
        # BUG#45 Fix: NONINTERACTIVE 模式使用自动检测的平台
        SELECTED_PLATFORM="$auto_platform"
        echo -e "${GREEN}非交互模式: 使用自动检测平台 ${SELECTED_PLATFORM}${NC}"
    else
        # ── 交互式菜单 ─────────────────────────────────────────────────────
        PLATFORM_CATEGORY=""
        # ── 新手友好：先问快速选择 ─────────────────────────────────────────
        show_quick_start_menu
        local quick_ret=$?

        if [[ $quick_ret -eq 1 ]]; then
            # 专家模式：走 4-step 流程
            step1_choose_platform
            step2_choose_subplatform
            step3_choose_mode
            step4_choose_features
        else
            # 快速模式：直接选平台
            step1_choose_platform
            step2_choose_subplatform
            # 显示当前配置
            echo ""
            echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${BOLD}  确认你的选择${NC}"
            echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            show_platform_info "$SELECTED_PLATFORM"
            echo ""
            echo -e "  模式: ${GREEN}${SELECTED_MODE}${NC}"
            echo -e "  Docker: ${GREEN}${INSTALL_DOCKER}${NC} | Node.js: ${GREEN}${INSTALL_NODEJS}${NC}"
            echo -e "  编译依赖: ${GREEN}${INSTALL_DEPS}${NC}"
            echo -e "  自动更新: ${GREEN}${CONFIGURE_UNATTENDED}${NC} | 暴力破解防护: ${YELLOW}${CONFIGURE_FAIL2BAN}${NC}"
            echo ""
        fi

        # full 模式：询问 Docker / Node.js
        if [[ "$SELECTED_MODE" == "full" ]]; then
            resolve_full_extras
        fi
    fi

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  执行优化${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    download_and_run "$SELECTED_PLATFORM" "$SELECTED_MODE"
    local ret=$?

    if [[ $ret -eq 0 ]]; then
        echo ""
        echo "========================================================================"
        echo -e "${GREEN}  ✅ 优化完成！建议重启系统使全部配置生效${NC}"
        echo "========================================================================"
        echo ""
        echo -e "  ${CYAN}重启前可运行验证脚本检查优化效果:${NC}"
        echo -e "  ${GREEN}curl -fsSL ${RAW_BASE}/verify-v3.1.sh -o /tmp/verify-v3.1.sh && bash /tmp/verify-v3.1.sh${NC}"
        echo ""
        
        # 非交互模式跳过重启询问
        if [[ "$INTERACTIVE" == "true" ]]; then
            echo -n "  是否立即重启？[y/N]: "
            read -r yn
            if [[ "$yn" =~ ^[yY]$ ]]; then
                echo "正在重启..."
                reboot
            fi
        else
            log_info "非交互模式: 跳过重启询问"
        fi
    else
        echo ""
        log_error "优化失败 (exit $ret)，请检查日志"
    fi
    exit $ret
}

main "$@"
