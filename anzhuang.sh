#!/bin/bash

#######################################
# VPS 完美优化 - 一键安装脚本
# GitHub: vpn3288/vps-optimizer
#######################################

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

REPO_USER="vpn3288"
REPO_NAME="vps-optimizer"
SCRIPT_NAME="install.sh"  # 你的主脚本名称
SCRIPT_URL="https://raw.githubusercontent.com/${REPO_USER}/${REPO_NAME}/main/${SCRIPT_NAME}"

clear
echo -e "${CYAN}"
cat << "EOF"
╔═══════════════════════════════════════════════╗
║                                               ║
║     VPS 完美优化脚本 v2.1 - 安装程序          ║
║     代理节点专用 | 不修改防火墙和BBR          ║
║                                               ║
╚═══════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# 检查 root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[✗] 需要 root 权限${NC}"
    echo "使用: sudo bash $0"
    exit 1
fi

# 检测系统
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    echo -e "${GREEN}[✓] 系统: $ID $VERSION_ID${NC}"
else
    echo -e "${RED}[✗] 无法检测系统${NC}"
    exit 1
fi

# 检测内存
TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
TOTAL_MEM_GB=$((TOTAL_MEM_MB / 1024))
[[ $TOTAL_MEM_GB -eq 0 ]] && TOTAL_MEM_GB=1
echo -e "${GREEN}[✓] 内存: ${TOTAL_MEM_GB}GB (${TOTAL_MEM_MB}MB)${NC}"

# 检查网络
echo -e "${CYAN}[→] 检查网络连接...${NC}"
if ! ping -c 1 -W 3 raw.githubusercontent.com >/dev/null 2>&1; then
    echo -e "${YELLOW}[!] 无法连接 GitHub${NC}"
    echo "请检查网络或使用代理"
    exit 1
fi
echo -e "${GREEN}[✓] 网络正常${NC}"

# 下载脚本
echo -e "${CYAN}[→] 下载优化脚本...${NC}"

TEMP_SCRIPT="/tmp/vps-optimizer-$(date +%s).sh"

if command -v wget &>/dev/null; then
    wget -q -T 30 --tries=3 -O "$TEMP_SCRIPT" "$SCRIPT_URL" || {
        echo -e "${RED}[✗] 下载失败${NC}"
        exit 1
    }
elif command -v curl &>/dev/null; then
    curl -sSL --max-time 30 --retry 3 -o "$TEMP_SCRIPT" "$SCRIPT_URL" || {
        echo -e "${RED}[✗] 下载失败${NC}"
        exit 1
    }
else
    echo -e "${RED}[✗] 未找到 wget 或 curl${NC}"
    exit 1
fi

echo -e "${GREEN}[✓] 下载完成${NC}"
echo ""

# 显示优化内容
echo -e "${YELLOW}════════════════════════════════════════${NC}"
echo -e "${YELLOW}  将执行以下优化:${NC}"
echo -e "${YELLOW}════════════════════════════════════════${NC}"
echo ""
echo "  ✓ ZRAM + Swap 内存优化"
echo "  ✓ 网络性能优化 (TCP 缓冲区 + 连接队列)"
echo "  ✓ 系统资源限制提升"
echo "  ✓ DNS 优化 (dnsmasq 本地缓存)"
echo "  ✓ 磁盘 I/O 优化"
echo "  ✓ 时间同步优化"
echo "  ✓ 系统瘦身 (移除不必要服务)"
echo ""
echo -e "${CYAN}特点:${NC}"
echo "  • 不修改防火墙"
echo "  • 不配置 BBR"
echo "  • 智能适配内存大小"
echo "  • 自动备份配置文件"
echo ""
echo -e "${YELLOW}3 秒后自动开始...${NC}"
sleep 3

chmod +x "$TEMP_SCRIPT"

# 执行脚本
echo ""
bash "$TEMP_SCRIPT"

# 清理
rm -f "$TEMP_SCRIPT"

echo ""
echo -e "${GREEN}[✓] 安装完成！${NC}"
echo ""
