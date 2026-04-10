# OpenClaw 一键优化安装脚本

<div align="center">

**为 OpenClaw AI 网关设计的专属平台优化脚本**

</div>

---

## 简介

本项目提供针对 **OpenClaw AI 网关**的一键优化安装脚本，支持多种硬件平台。

### 主要功能

- 系统优化 - 网络、内存、I/O、CPU 全方位优化
- 自动检测 - 智能识别硬件平台
- 一键安装 - 下载即用，无需配置
- 新手友好 - 中文界面，简单易用
- 安全可靠 - 多重错误处理，幂等设计

### 支持的系统

| 系统 | 版本 |
|------|------|
| Debian | 12 (Bookworm) |
| Ubuntu | 24.04 LTS (Noble) |

---

## 快速开始

### 方式一：自动检测（推荐新手）

自动检测你的硬件平台并选择最优脚本：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/install.sh)
```

### 方式二：手动选择

根据你的硬件平台选择对应的脚本：

| 硬件 | 一键命令 |
|------|----------|
| NanoPi R4S | `bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/nanopi-r4s.sh)` |
| NanoPi T6/T6S | `bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/nanopi-t6.sh)` |
| N5105/N5095 小主机 | `bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/n5105.sh)` |
| Oracle Cloud ARM | `bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/oracle-arm.sh)` |
| 其他 x86 VPS | `bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/generic-x86.sh)` |

---

## 支持的平台

### 硬件平台对比

| 平台 | CPU | 内存 | 特点 | 推荐脚本 |
|------|-----|------|------|----------|
| NanoPi R4S | RK3399 (ARM64) | 4GB | 双千兆网口，低功耗 | nanopi-r4s.sh |
| NanoPi T6/T6S | RK3588 (ARM64) | 16GB | 性能强，适合重度使用(16GB大内存) | nanopi-t6.sh |
| N5105 小主机 | Intel N5105 (x86_64) | 4-16GB | 低功耗x86，稳定可靠 | n5105.sh |
| Oracle Cloud ARM | Ampere Altra (ARM64) | 2核16GB | 云环境，网络优化 | oracle-arm.sh |
| 通用 x86 VPS | 任意 x86_64 | 自动适配 | 通用兼容 | generic-x86.sh |

### 各平台优化详情

#### NanoPi R4S
- CPU: RK3399 (双核 Cortex-A72 + 四核 Cortex-A53)
- 内存: 4GB LPDDR4
- 网络: 双千兆网口 (RTL8211E)
- 优化: ZRAM 1GB、TCP缓冲16MB、ARM特定调优

#### NanoPi T6/T6S
- CPU: RK3588 (四核 Cortex-A76 + 四核 Cortex-A55)
- 内存: 16GB LPDDR4X
- 网络: 2.5Gbps (RTL8125)
- 优化: 跳过ZRAM(16GB充足)、大内存优化

#### N5105/N5095 小主机
- CPU: Intel N5105/N5095 (四核, 2.0-2.9GHz)
- 内存: 4-16GB DDR4
- 网络: 2.5Gbps (RTL8125)
- 优化: Intel P-State、irqbalance、按内存自动配置

#### Oracle Cloud ARM
- CPU: Ampere Altra (2核)
- 内存: 16GB
- 存储: 100GB
- 优化: TCP缓冲64MB、连接追踪262K、保留oci-agent

---

## 使用指南

### 安装前准备

1. 准备一台干净的 Debian 12 或 Ubuntu 24.04 系统
2. 确保有 root 权限或 sudo 权限
3. 确保网络连接正常
4. 建议磁盘可用空间 > 5GB

### 安装步骤

#### 第一步：连接服务器

```bash
ssh root@your-server-ip
```

#### 第二步：运行安装脚本

```bash
# 自动检测（推荐）
bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/install.sh)
```

#### 第三步：等待安装完成

脚本会自动完成以下操作：
1. 检测硬件平台
2. 优化系统参数
3. 安装 Node.js
4. 安装 Docker（可选）
5. 安装 OpenClaw
6. 创建 systemd 服务

#### 第四步：配置 OpenClaw

安装完成后，运行以下命令完成 OpenClaw 配置：

```bash
# 切换到 openclaw 用户
sudo -u openclaw -i openclaw onboard --install-daemon
```

按照提示完成：
- 选择模型提供商
- 输入 API Key
- 配置 Telegram（可选）

#### 第五步：启动服务

```bash
# 启动 OpenClaw Gateway
systemctl start openclaw-gateway

# 查看状态
systemctl status openclaw-gateway

# 查看 OpenClaw 状态
openclaw status
```

### 安装后验证

```bash
# 运行诊断
openclaw doctor

# 查看 Gateway 日志
journalctl -u openclaw-gateway -f

# 测试端口
ss -tlnp | grep 18789
```

---

## 脚本选项

所有脚本支持以下选项：

| 选项 | 说明 | 默认值 |
|------|------|--------|
| --no-docker | 跳过 Docker 安装 | 安装 |
| --no-nodejs | 跳过 Node.js 安装 | 安装 |
| --nodejs-version N | 指定 Node.js 版本 | 24 |

### 示例

```bash
# 跳过 Docker 安装
bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/nanopi-r4s.sh) --no-docker

# 指定 Node.js 22
bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/nanopi-r4s.sh) --nodejs-version 22
```

---

## 脚本功能说明

| 功能 | 说明 |
|------|------|
| 系统检测 | 自动检测硬件平台、内存、CPU、磁盘 |
| APT 源配置 | 腾讯云镜像 + 官方源备选 |
| 系统清理 | 移除 snapd、apache、nginx 等 |
| DNS 配置 | 1.1.1.1 + 8.8.8.8 |
| 时区配置 | Asia/Shanghai |
| 时间同步 | chrony + NTP 服务器 |
| 网络优化 | BBR + TCP 缓冲 + 连接追踪 |
| 内存优化 | ZRAM（低内存设备）+ swappiness |
| I/O 优化 | SSD/HDD 自动检测调度器 |
| 安全优化 | 文件描述符、内核参数 |
| Node.js | Node 24 LTS |
| Docker | Docker CE + 阿里云镜像 |
| OpenClaw | 最新版 + systemd 服务 |

### 配置文件位置

| 文件 | 路径 |
|------|------|
| OpenClaw 配置 | ~/.openclaw/openclaw.json |
| Gateway 服务 | /etc/systemd/system/openclaw-gateway.service |
| 系统限制 | /etc/security/limits.conf |
| sysctl 配置 | /etc/sysctl.d/99-openclaw.conf |
| Docker 配置 | /etc/docker/daemon.json |
| 安装日志 | /var/log/openclaw-install.log |

---

## 常见问题

### Q: 安装失败怎么办？

首先查看日志：
```bash
cat /var/log/openclaw-install.log
```

常见问题：
- 网络问题：检查能否访问 GitHub
- 权限问题：确保用 root 运行
- 磁盘空间：确保 > 3GB 可用空间

### Q: 如何重新配置 OpenClaw？

删除配置后重新运行 onboard：
```bash
rm -rf ~/.openclaw
sudo -u openclaw -i openclaw onboard --install-daemon
```

### Q: 如何更新 OpenClaw？

```bash
npm update -g openclaw
systemctl restart openclaw-gateway
```

### Q: 如何卸载？

```bash
# 停止服务
systemctl stop openclaw-gateway
systemctl disable openclaw-gateway

# 删除服务
rm /etc/systemd/system/openclaw-gateway.service
systemctl daemon-reload

# 删除用户
userdel openclaw

# 删除目录
rm -rf /opt/openclaw ~/.openclaw
```

### Q: NanoPi R4S 发热严重怎么办？

脚本已优化，可以添加散热片或风扇

### Q: Oracle Cloud ARM 无法连接？

检查防火墙设置：
```bash
# 开放端口 18789
ufw allow 18789
# 或在 Oracle 控制台安全组开放
```

### Q: 如何查看 Gateway 状态？

```bash
# 查看服务状态
systemctl status openclaw-gateway

# 查看实时日志
journalctl -u openclaw-gateway -f

# 运行诊断
openclaw doctor
```

---

## 获取帮助

- OpenClaw 官方文档: https://docs.openclaw.ai/
- 问题反馈: https://github.com/vpn3288/VPS-youhua/issues

---

## License

MIT License - 欢迎使用和改进！
