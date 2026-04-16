#!/usr/bin/env bash
# =============================================================================
# AIagent 环境优化脚本（统一入口） v3.1
# 支持平台: NanoPi R4S, NanoPC T6, Oracle ARM, N5105, 通用 x86 VPS
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

readonly VERSION="3.1"
readonly RAW_BASE="https://raw.githubusercontent.com/vpn3288/VPS-youhua/main"

# ─────────────────────────────────────────────────────────────────────────────
# SHA256 校验和（防止供应链污染）
# ⚠️  脚本更新时必须同步更新对应 SHA256
# R54: 新手友好交互菜单(纯优化/全量安装/自定义), install.sh作为统一入口
# ─────────────────────────────────────────────────────────────────────────────

declare -A EXPECTED_SHA256=(
    ["nanopi-r4s"]="a8a085c3c2dbee14efa66662c9967b55eb89c46b0fc4e655a614346d1f202409"
    ["nanopi-t6"]="ab54fdd96f41bdeaa37acaa9b6c1c0ae2f27a1c0efac150c342d82669f8a303b"
    ["oracle-arm"]="2595d1d5953d8b986bbaa7aa71a8814581d38b4d52371a759f8d8ecab48936a7"
    ["n5105"]="50c57730a047c057ec7216375b3e8f65f87a219a946d66449d48d49bd4cc24ca"
    ["generic-x86"]="b68935265101416d813b30761c762ee4263bda352578bbb25453247818e5e88f"
    ["verify-v3.1"]="95760662417b601103a63512b6bb204bc8b56136e2337ea206b322f8d509ebc4"
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

SELECTED_PLATFORM=""      # nanpi-r4s | nanpi-t6 | oracle-arm | n5105 | generic-x86
SELECTED_MODE=""          # optimize | full | custom
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
        --non-interactive|-y|--yes)  INTERACTIVE=false ;;
        --with-docker)               INSTALL_DOCKER="true" ;;
        --without-docker)             INSTALL_DOCKER="false" ;;
        --with-npm)                  INSTALL_NODEJS="true" ;;
        --without-npm)               INSTALL_NODEJS="false" ;;
        --with-unattended)           CONFIGURE_UNATTENDED="true" ;;
        --without-unattended)        CONFIGURE_UNATTENDED="false" ;;
        --with-fail2ban)             CONFIGURE_FAIL2BAN="true" ;;
        --without-fail2ban)          CONFIGURE_FAIL2BAN="false" ;;
        --mirror-auto)               CONFIGURE_MIRROR="auto" ;;
        --mirror-off)                CONFIGURE_MIRROR="off" ;;
        --clean-system)              CLEAN_SYSTEM="true" ;;
        --uninstall)                 MODE="uninstall" ;;
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

log_info()  { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1" >&2; }
log_step()  { echo -e "${CYAN}[➜]${NC} $1"; }

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
    --help, -h          显示本帮助信息

示例:
    bash install.sh                         # 交互式菜单（新手推荐）
    bash install.sh --optimize              # 只做优化，不装软件
    bash install.sh --full                  # 优化 + 全量安装
    bash install.sh --full --without-docker  # 优化 + 安装但跳过 Docker
    bash install.sh --with-fail2ban         # 优化 + 开启 fail2ban
    bash install.sh --without-unattended    # 优化，安全更新保持系统默认
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# 平台检测
# ─────────────────────────────────────────────────────────────────────────────

detect_platform() {
    local arch=$(uname -m)
    local cpu_model
    cpu_model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | sed 's/^ //' 2>/dev/null || echo "")
    local model
    model=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0' | xargs 2>/dev/null || echo "")

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
                echo "oracle-arm"
            elif echo "$cpu_model" | grep -qi "RK3588"; then
                echo "nanopi-t6"
            elif echo "$cpu_model" | grep -qi "RK3399"; then
                echo "nanopi-r4s"
            else
                echo "nanopi-r4s"
            fi
            ;;
        x86_64)
            if echo "$cpu_model" | grep -qiE "N5105|N5095|J6412|J6413"; then
                echo "n5105"
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

    if ! host -W 3 cloudflare.com >/dev/null 2>&1 && \
       ! getent hosts github.com >/dev/null 2>&1; then
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
            echo -e "  ${BLUE}设备:     Oracle Cloud ARM (Ampere Altra)${NC}"
            echo -e "  ${BLUE}存储:     云盘（高IOPS）${NC}"
            echo -e "  ${BLUE}特点:     32MB TCP缓冲优化${NC}"
            ;;
        n5105)
            echo -e "  ${BLUE}设备:     N5105/N5095 小主机 (x86_64)${NC}"
            echo -e "  ${BLUE}存储:     SSD${NC}"
            echo -e "  ${BLUE}特点:     低功耗，有风扇${NC}"
            ;;
        generic-x86)
            echo -e "  ${BLUE}设备:     通用 x86_64 VPS${NC}"
            echo -e "  ${BLUE}特点:     自动适配${NC}"
            ;;
    esac
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# 菜单步骤
# ─────────────────────────────────────────────────────────────────────────────

step1_choose_platform() {
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  Step 1/3：选择你的设备类型${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}[1]${NC} ARM 开发板（NanoPi R4S / NanoPC T6）"
    echo -e "  ${GREEN}[2]${NC} 云服务器（Oracle Cloud ARM）"
    echo -e "  ${GREEN}[3]${NC} 小主机（N5105 / N5095）"
    echo -e "  ${GREEN}[4]${NC} 通用 x86_64 VPS"
    echo ""
    echo -n "请输入选项 [1/2/3/4]: "
    read -r choice
    case "$choice" in
        1) PLATFORM_CATEGORY="arm" ;;
        2) PLATFORM_CATEGORY="oracle" ;;
        3) PLATFORM_CATEGORY="n5105" ;;
        4) PLATFORM_CATEGORY="generic" ;;
        *) echo -e "${YELLOW}无效选项${NC}"; step1_choose_platform; return ;;
    esac
}

step2_choose_subplatform() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  Step 2/3：选择具体设备${NC}"
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
            echo -e "  ${GREEN}[1]${NC} Oracle Cloud ARM"
            echo -e "       Ampere Altra | 1-4核 | 最高64GB RAM | 云盘存储"
            echo ""
            echo -n "请输入选项 [1]: "
            read -r choice
            SELECTED_PLATFORM="oracle-arm"
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
            echo -e "  ${GREEN}[1]${NC} 通用 x86_64 VPS"
            echo -e "       任何 x86_64 云服务器均可"
            echo ""
            echo -n "请输入选项 [1]: "
            read -r choice
            SELECTED_PLATFORM="generic-x86"
            ;;
    esac

    show_platform_info "$SELECTED_PLATFORM"
}

step3_choose_mode() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  Step 3/3：选择运行模式${NC}"
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
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  Step 4/4：可选功能（安全加固）${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}[1]${NC} ${BOLD}自动安全更新（unattended-upgrades）${NC} ${YELLOW}默认: 开启${NC}"
    echo -e "       每日自动检查并安装安全更新，不自动重启"
    echo -e "       ${CYAN}适合: 生产服务器、长期运行的设备${NC}"
    echo ""
    echo -e "  ${GREEN}[2]${NC} ${BOLD}SSH 防暴力破解（fail2ban）${NC} ${YELLOW}默认: 关闭${NC}"
    echo -e "       失败3次封IP 1小时，检测 SSH 暴力破解"
    echo -e "       ${CYAN}适合: 有公网 IP 的 VPS（Oracle/通用 x86）${NC}"
    echo ""
    echo -e "  ${GREEN}[3]${NC} ${BOLD}APT 镜像源切换${NC}"
    echo -e "       自动测速选择最快镜像（腾讯/阿里/清华）"
    echo -e "       ${YELLOW}默认: 自动测速${NC}  |  ${CYAN}选 0 则跳过，保持系统默认源${NC}"
    echo ""
    echo -e "  ${GREEN}[0]${NC}  使用全部默认值（安全更新开，其余关）"
    echo ""
    echo -n "请输入选项 [1/2/3/0，默认 0]: "
    read -r choice
    choice="${choice:-0}"
    case "$choice" in
        1)
            CONFIGURE_FAIL2BAN="true"
            CONFIGURE_MIRROR="auto"
            ;;
        2)
            CONFIGURE_UNATTENDED="false"
            CONFIGURE_MIRROR="auto"
            ;;
        3)
            CONFIGURE_UNATTENDED="true"
            CONFIGURE_FAIL2BAN="true"
            ;;
        0)
            # 全部使用默认值（已在变量声明中设置）
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
    local tmpfile; tmpfile=$(mktemp)

    local script_url="${RAW_BASE}/${platform}.sh"
    log_step "检查 ${platform}.sh..."
    if ! curl --head --silent --fail "$script_url" >/dev/null 2>&1; then
        log_error "平台脚本不存在: $script_url"
        rm -f "$tmpfile"
        exit 1
    fi

    log_step "下载 ${platform}.sh..."
    if ! curl -fsSL "$script_url" -o "$tmpfile"; then
        log_error "下载失败: $script_url"
        rm -f "$tmpfile"
        exit 1
    fi

    local expected="${EXPECTED_SHA256[$platform]:-}"
    if [[ -n "$expected" ]]; then
        local actual; actual=$(sha256sum "$tmpfile" | awk '{print $1}')
        if [[ "$actual" != "$expected" ]]; then
            log_error "SHA256 校验失败！文件可能被篡改。"
            log_error "期望: $expected"
            log_error "实际: $actual"
            rm -f "$tmpfile"
            exit 1
        fi
        log_info "SHA256 校验通过"
    else
        log_warn "SHA256 占位符，跳过校验"
    fi

    log_step "执行 ${platform}.sh..."

    # Armbian 检测：如果是 Armbian 设备，强制跳过 APT 镜像切换
    # （Armbian 有自己的 apt 源，不应被 Debian 源替换）
    if [[ -f /etc/armbian-release ]]; then
        CONFIGURE_MIRROR="off"
        log_info "检测到 Armbian，跳过 APT 镜像切换"
    fi

    # 透传环境变量给平台脚本
    export SKIP_SOFTWARE_SCRIPT="false"
    export INSTALL_DOCKER="$INSTALL_DOCKER"
    export INSTALL_NODEJS="$INSTALL_NODEJS"
    export INSTALL_DOCKER_SCRIPT="$INSTALL_DOCKER"
    export INSTALL_NODEJS_SCRIPT="$INSTALL_NODEJS"
    export INSTALL_METHOD="docker"
    export CONFIGURE_UNATTENDED="$CONFIGURE_UNATTENDED"
    export CONFIGURE_FAIL2BAN="$CONFIGURE_FAIL2BAN"
    export CONFIGURE_MIRROR="$CONFIGURE_MIRROR"

    if [[ "$mode" == "optimize" ]]; then
        export SKIP_SOFTWARE_SCRIPT="true"
        bash "$tmpfile" --optimize-only
    else
        bash "$tmpfile"
    fi

    local ret=$?
    rm -f "$tmpfile"
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

    local tmpfile; tmpfile=$(mktemp)
    trap 'rm -f "$tmpfile"' EXIT

    local script_url="${RAW_BASE}/${platform}.sh"
    if ! curl -fsSL "$script_url" -o "$tmpfile"; then
        log_error "下载失败: $script_url"
        exit 1
    fi

    local expected="${EXPECTED_SHA256[$platform]:-}"
    if [[ -n "$expected" ]]; then
        local actual; actual=$(sha256sum "$tmpfile" | awk '{print $1}')
        if [[ "$actual" != "$expected" ]]; then
            log_error "SHA256 校验失败！文件可能被篡改。"
            rm -f "$tmpfile"
            exit 1
        fi
        log_info "SHA256 校验通过"
    fi

    bash "$tmpfile" --uninstall
    local ret=$?
    rm -f "$tmpfile"
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
    if [[ "${MODE:-}" == "uninstall" ]]; then
        uninstall_all
        return
    fi

    trap 'rm -f /tmp/vps-youhua-*.sh' EXIT

    show_banner
    check_network

    # 自动检测平台（允许用户修改）
    local auto_platform; auto_platform=$(detect_platform)
    show_platform_info "$auto_platform"

    # ── 如果有 --platform= 强制标志，直接用 ─────────────────────────────
    if [[ -n "$FORCE_PLATFORM" ]]; then
        SELECTED_PLATFORM="$FORCE_PLATFORM"
        SELECTED_MODE="${FORCE_MODE:-optimize}"
        echo -e "${GREEN}使用指定平台: ${SELECTED_PLATFORM}${NC}"
        echo -e "${GREEN}使用指定模式: ${SELECTED_MODE}${NC}"
    else
        # ── 交互式菜单 ─────────────────────────────────────────────────────
        PLATFORM_CATEGORY=""
        step1_choose_platform
        step2_choose_subplatform
        step3_choose_mode
        step4_choose_features

        # full 模式：询问 Docker / Node.js
        if [[ "$SELECTED_MODE" == "full" ]]; then
            resolve_full_extras
        fi
    fi

    # 纯优化时强制跳过软件
    if [[ "$SELECTED_MODE" == "optimize" ]]; then
        INSTALL_DOCKER="false"
        INSTALL_NODEJS="false"
        SKIP_SOFTWARE_SCRIPT="true"
    fi

    download_and_run "$SELECTED_PLATFORM" "$SELECTED_MODE"
    local ret=$?

    if [[ $ret -eq 0 ]]; then
        echo ""
        log_step "环境优化完成!"
        echo ""
        if [[ "$SELECTED_MODE" == "optimize" ]]; then
            echo -e "${GREEN}✓ 系统已针对 ${SELECTED_PLATFORM} 优化完毕${NC}"
            echo ""
            echo "下一步: 安装你的软件（Docker / Xray / Nginx 等）"
        else
            echo -e "${GREEN}✓ 全量安装完成！${NC}"
            echo ""
            echo "下一步: 重启后安装并运行你需要的 agent"
        fi
        echo ""
        echo -e "${CYAN}验证优化效果: bash <(curl -fsSL ${RAW_BASE}/verify-v3.1.sh)${NC}"
    else
        log_error "平台脚本执行失败 (exit $ret)"
    fi

    exit $ret
}

main "$@"
