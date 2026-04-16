# VPS-youhua 环境优化脚本

<div align="center">

**NanoPi R4S / T6、Oracle Cloud ARM、N5105、通用 x86 VPS 的系统优化**
适用于 OpenClaw、Hermes 等所有需要 Linux 环境的 AIagent

[![Debian 12](https://img.shields.io/badge/Debian-12-AA0000?logo=debian)](https://www.debian.org/)
[![Ubuntu 24.04](https://img.shields.io/badge/Ubuntu-24.04-E95420?logo=ubuntu)](https://ubuntu.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![v3.3](https://img.shields.io/badge/版本-v3.3-green.svg)](https://github.com/vpn3288/VPS-youhua)
[![审查](https://img.shields.io/badge/审查-8轮0bug-blue.svg)](https://github.com/vpn3288/VPS-youhua)
[![5平台](https://img.shields.io/badge/平台-5个-cyan.svg)](https://github.com/vpn3288/VPS-youhua)

</div>

---

## 简介

本项目为 AIagent（OpenClaw、Hermes 等）提供**安装前的环境优化**，让 AIagent 能以安全、稳定、高速、长期运行的状态部署。

**交互模式默认行为：完整优化 + Docker + Node.js（适合新手快速部署）。**

使用 `--optimize-only` 可跳过所有安装步骤，仅做纯环境优化（sysctl、journald、swap、CPU governor、inotify 等），适合"只想优化环境、后面装其他东西"的场景。使用环境变量 `INSTALL_DOCKER=false` 或 `INSTALL_NODEJS=false` 可单独禁用某项安装。

### 核心原则

- **安全优先**：所有优化均经过验证，不引入潜在风险
- **稳定长期**：参数以长期稳定运行为目标，不过度激进
- **硬件适配**：每个平台针对性优化，不搞一刀切
- **TF卡保护**（R4S专用）：dirty_writeback、SWAP、journald 等全部针对TF卡寿命优化

---

## 快速开始

### 第一步：运行优化脚本（选一个）

```bash
# 自动检测平台（推荐新手）
bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/install.sh)

# 手动指定平台
bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/nanopi-r4s.sh)    # NanoPi R4S
bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/nanopi-t6.sh)     # NanoPC T6
bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/oracle-arm.sh)  # Oracle Cloud ARM
bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/n5105.sh)        # N5105/N5095 小主机
bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/generic-x86.sh)   # 其他 x86 VPS

# 可选参数：
#   --optimize-only   仅做环境优化，跳过 Docker / Node.js / OpenClaw 安装
#   --clean-system    清理 apt purge 预装软件（apache2/nginx/postfix 等）
#   --uninstall       卸载已安装的优化配置
#   --non-interactive 自动执行（适合自动化）
```

### 第二步：验证优化效果

```bash
curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/verify-v3.1.sh -o /tmp/verify-v3.1.sh
bash /tmp/verify-v3.1.sh
```

### 第三步：使用 AIagent

Docker / Node.js / OpenClaw 已在第一步中安装完毕。如需重启服务：

```bash
systemctl --user start openclaw-gateway   # 启动
systemctl --user enable openclaw-gateway  # 开机自启
openclaw onboard                          # 首次配置
```

---

## 支持的平台

| 平台 | CPU | 内存 | 存储 | 推荐脚本 |
|------|-----|------|------|----------|
| NanoPi R4S | RK3399 (ARM64) | 4GB | **TF卡** | `nanopi-r4s.sh` |
| NanoPC T6 | RK3588S (ARM64) | 16GB | **eMMC** | `nanopi-t6.sh` |
| Oracle Cloud ARM | Ampere Altra (ARM64) | 16GB | 云盘 | `oracle-arm.sh` |
| N5105/N5095 小主机 | Intel N5105 (x86_64) | 4-16GB | SSD | `n5105.sh` |
| 通用 x86 VPS | 任意 x86_64 | 自动适配 | 自动检测（SSD/HDD） | `generic-x86.sh` |

---

## 各平台优化详情

### NanoPi R4S（TF卡保护重点）

TF卡写入寿命有限，脚本从系统层面最大限度减少随机写入：

| 优化项 | 配置值 | 说明 |
|--------|--------|------|
| journald Storage | volatile | 日志写入内存而非TF卡 |
| vm.dirty_ratio | 8 | 减少刷盘次数 |
| vm.dirty_background_ratio | 3 | 后台合并写入 |
| vm.dirty_writeback_centisecs | 6000（6秒） | 拉长回写间隔 |
| vm.dirty_expire_centisecs | 60000（10分钟） | 数据过期才回写 |
| SWAP | 禁用 | 禁用swap分区 |
| zswap | N | 禁用压缩swap |
| log2ram | 可选安装 | journal写入RAM缓冲 |
| netdev_max_backlog | 16384 | 适度队列，不过度缓冲 |
| conntrack timeout | 1800s | 减少连接表条目 |
| CPU Governor | performance | ARM高频稳定运行 |
| inotify watches | 524288 | 大量文件监控支持 |

### NanoPC T6（eMMC 存储，3网口）

ARMbian 官方配置：**RK3588S, 8GB RAM, eMMC, 1×GbE + 2×2.5GbE**

eMMC 写入寿命比 TF 卡好得多，但仍需优化随机写入：

| 优化项 | 配置值 | 说明 |
|--------|--------|------|
| 物理 swap | 禁用文件，保留 zswap | 16GB RAM + zswap 压缩，eMMC 不怕写 |
| dirty_ratio | 20 | 减少回写频率 |
| dirty_background_ratio | 10 | 后台合并写入 |
| dirty_writeback_centisecs | 6000（6秒） | 减少 eMMC 随机写入 |
| vm.swappiness | 10 | 减少 swap 倾向 |
| netdev_max_backlog | 65535 | 大吞吐量队列 |
| conntrack timeout | 3600s | 长连接优化 |
| CPU Governor | performance | RK3588 高频稳定运行 |
| inotify watches | 1048576 | 大量文件监控支持 |


### Oracle Cloud ARM（云环境）

云上环境侧重吞吐量和连接处理：

| 优化项 | 配置值 | 说明 |
|--------|--------|------|
| TCP缓冲 | 32MB | 云网络带宽优化 |
| netdev_max_backlog | 65535 | 大吞吐量队列 |
| conntrack_max | 262144 | 高并发连接数 |
| conntrack timeout | 3600s | 长连接优化 |
| dirty_ratio | 20 | 云盘写入更激进 |
| TCP early_retrans | 3 | 丢包快速恢复 |
| TCP MTU probing | 开启 | 阿里云/Oracle网络优化 |

### N5105/N5095（静音省电）

静音小主机，禁用 Turbo Boost 减少风扇噪音：

| 优化项 | 配置值 | 说明 |
|--------|--------|------|
| Turbo Boost | 禁用 | 静音降功耗 |
| CPU Governor | performance | 禁用后维持基准频率 |
| SSD调度器 | none | 直通调度无延迟 |
| irqbalance | 自动 | 多核负载均衡 |
| conntrack timeout | 3600s | 长连接优化 |
| dirty_ratio | 15 | SSD不怕写磨损 |
| TCP缓冲 | 16MB | 平衡内存占用 |

### Generic x86 VPS（通用）

通用Debian12环境，自适应内存配置：

| 优化项 | 配置值 | 说明 |
|--------|--------|------|
| 内存分级 | 4GB/8GB/16GB+ | 配置文件数自动适配 |
| dirty_ratio | 15 | 通用推荐值 |
| TCP fastopen | 3 | 快速建立连接 |
| BBR | 强制开启 | 拥塞控制优化 |
| inotify watches | 1048576 | 大型agent支持 |

---

## v3.1 全部优化参数一览

### TCP 网络优化（全平台）

| 参数 | 值 | 说明 |
|------|----|------|
| tcp_congestion_control | bbr | BBR拥塞控制 |
| tcp_fastopen | 3 | TFO客户端+服务端 |
| tcp_timestamps | 1 | RTT精确计算 |
| tcp_sack | 1 | 选择性确认 |
| tcp_slow_start_after_idle | 0 | 空闲保持拥塞窗口 |
| tcp_rfc1337 | 1 | TIME_WAIT套接字保护 |
| tcp_early_retrans | 3 | 丢包早期恢复 |
| tcp_orphan_retries | 1 | 快速清理孤儿socket |
| tcp_mtu_probing | 1 | PMTU黑洞探测 |
| tcp_notsent_lowat | 16384 | 未发送缓冲优化 |
| tcp_tw_reuse | 1 | TIME_WAIT复用 |
| tcp_fin_timeout | 15 | 加快FIN处理 |
| tcp_keepalive_time | 1800 | 保活间隔 |
| tcp_keepalive_intvl | 30 | 保活重试间隔 |
| tcp_keepalive_probes | 3 | 保活探测次数 |

### 网络队列（全平台）

| 参数 | 说明 |
|------|------|
| net.core.default_qdisc = fq | 公平队列算法 |
| net.core.somaxconn = 65535 | 监听队列长度 |
| net.core.rmem_max / wmem_max | 套接字缓冲上限 |

### 安全加固（全平台）

| 参数 | 值 | 说明 |
|------|----|------|
| accept_redirects | 0 | 禁用ICMP重定向 |
| accept_source_route | 0 | 禁用源路由 |
| secure_redirects | 0 | 仅接受网关发来的重定向 |
| log_martians | 0 | 关闭虚假地址日志 |
| rp_filter | 1 | 反向路径过滤 |
| tcp_syncookies | 1 | SYN洪水防护 |
| ipv6.accept_redirects | 0 | IPv6重定向防护 |
| kernel.dmesg_restrict | 1 | 限制dmesg访问 |
| kernel.kptr_restrict | 1 | 隐藏内核指针 |
| kernel.yama.ptrace_scope | 1 | 限制ptrace |

### 连接追踪 conntrack（全平台）

| 参数 | 值 | 说明 |
|------|----|------|
| established | 1800-3600s | 已建立连接超时 |
| time_wait | 10-15s | 快速释放TIME_WAIT |
| close_wait | 5s | 快速关闭CLOSE_WAIT |
| fin_wait | 10s | 快速关闭FIN_WAIT |

### 内存管理（全平台）

| 参数 | 值 | 说明 |
|------|----|------|
| vm.swappiness | 10（R4S）/ 60（云） | 减少swap倾向 |
| vm.overcommit_memory | 1 | 允许内存超量分配 |
| vm.zone_reclaim_mode | 0 | NUMA节点优先本地分配 |
| vm.vfs_cache_pressure | 50 | 优先回收dentry/inode |

### 文件描述符（全平台）

| 参数 | 值 | 说明 |
|------|----|------|
| fs.file-max | 900000 | 全局文件句柄上限 |
| limits nofile | 1048576 | 进程打开文件数 |

---

## 验证脚本（verify-v3.1.sh）

下载并运行验证脚本，检查所有优化参数是否生效：

```bash
curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/verify-v3.1.sh -o /tmp/verify-v3.1.sh
bash /tmp/verify-v3.1.sh                    # 本机验证
sudo bash /tmp/verify-v3.1.sh               # 带root权限验证（完整检查）
bash /tmp/verify-v3.1.sh --remote root@IP  # 远程SSH验证
```

验证范围（14个维度）：
1. 系统基础信息（CPU/内存/磁盘/TF卡）
2. sysctl 网络参数（TCP/队列/BBR/安全）
3. conntrack 连接追踪
4. 内存管理（dirty_writeback/TF卡保护）
5. 文件描述符 & 进程限制
6. SSH 配置
7. journald 日志配置
8. inotify 文件监控
9. SWAP 状态（TF卡保护）
10. CPU Governor
11. systemd 服务状态
12. sysctl 配置文件完整性
13. 网络连接实战状态
14. 与 v3.1 目标值逐项对比（自动pass/fail）

---

## 配置文件位置

| 文件 | 路径 |
|------|------|
| sysctl 主配置 | `/etc/sysctl.d/99-openclaw.conf` |
| sysctl TF卡优化 | `/etc/sysctl.d/99-tf-optimize.conf` (R4S) |
| sysctl inotify | `/etc/sysctl.d/99-inotify.conf` |
| journald 配置 | `/etc/systemd/journald.conf` |
| limits 配置 | `/etc/security/limits.conf` |
| SSH 服务配置 | `/etc/ssh/sshd_config` |
| log2ram 配置 | `/etc/log2ram.conf` (可选) |

---

## 常见问题

### Q: 脚本会修改哪些系统文件？

主要修改以下文件（幂等设计，可重复运行）：
- `/etc/sysctl.d/99-openclaw.conf` — sysctl网络/内存参数
- `/etc/systemd/journald.conf` — 日志配置
- `/etc/security/limits.conf` — 进程限制
- `/etc/ssh/sshd_config` — SSH加固
- SSH 公钥authorized_keys（如果配置了）

**不会修改**：系统核心配置文件、用户数据、已有服务配置。

### Q: 运行后需要重启吗？

大多数参数通过 `sysctl -p` 即时生效，无需重启。少数参数（如 journald Storage）需要重启 journald：

```bash
systemctl restart systemd-journald
```

### Q: NanoPi R4S 为什么禁用 SWAP？

TF卡写入寿命有限。SWAP会产生大量随机小写入，严重影响TF卡寿命。脚本通过：
- 禁用SWAP分区
- 优化 `vm.swappiness=10` 减少内存回收
- 使用 zram 压缩内存（可选）
- 减少 dirty_writeback 频率
等多重手段减少对 TF 卡的写入。

### Q: Oracle Cloud ARM 为什么 TCP缓冲只有 32MB？

Oracle Cloud 的网络带宽是有限制的（最大 50Mbps Small Tenant），不是越高越好。过大的 TCP缓冲会导致内存浪费和更高的延迟。32MB 是 Oracle Cloud ARM 的最优值。

### Q: 如何确认 BBR 已开启？

```bash
sysctl net.ipv4.tcp_congestion_control   # 应显示 bbr
lsmod | grep bbr                         # 应显示 tcp_bbr
```

### Q: 优化后还需要做什么？

运行完本脚本后，再按你的 AIagent 官方文档安装：
- [OpenClaw 安装](https://docs.openclaw.ai/)
- [Hermes Agent 安装](https://github.com/nickaroot/hermes-agent)

---

## 版本历史

### v3.3 R67（最新）
- 审查：8轮严格审查（6轮 Sonnet-4.5 + 5轮 Opus-4.6），连续5轮0 bug确认
- 审查：代码质量达到生产级别（8,731行，11个脚本）
- 修复：APT锁超时处理从强制删锁改为提示用户手动处理
- 修复：fstab sed转义使用完整字符集 `[][.*^$\\]` 避免误匹配
- 修复：nanopi-t6 conntrack_max添加262144上限保护
- 修复：RPS配置添加cores>1和cores>0双重检查
- 修复：所有平台RPS配置统一防御性检查
- 新增：nanopi-r4s fstab使用awk精确匹配root分区避免sed误匹配
- 新增：所有平台函数调用顺序优化（detect_system先于configure_*）

### v3.2 R61
- 新增：`--status` 参数直接调用 verify-v3.1.sh 健康检查（install.sh），并更新帮助文档
- 新增：R4S `install_nodejs()` 编译前临时挂载 1G tmpfs 到 /tmp（TF 卡保护），编译完自动卸载
- 新增：fail2ban 选项 B 增加新手警告"请确保已配置 SSH 密钥登录，否则可能锁死"
- 新增：Oracle Cloud ARM 增加 `check_oracle_metadata()` 元数据健康检查（非 Oracle 环境自动跳过）
- 修复：verify-v3.1.sh 删除残留 `99-openclaw.conf`（替换为 `99-vps-youhua-*.conf`）
- 修复：Oracle ARM TCP 缓冲从固定 32MB 改为动态自适应（内存 5%，上限 64MB，下限 16MB）
- 新增：所有平台添加 `vm.oom_kill_allocating_task=1`（sysctl 配置 + 运行时立即生效）
- 新增：幂等性检测，重复运行时提示"系统已完成过优化"（检测 /etc/vps-youhua-optimized 标记文件，-y 参数跳过确认）
- 新增：所有平台脚本完成时写入 /etc/vps-youhua-optimized 标记（date 时间戳）
- 新增：R4S TF 卡检测升级为多方法交叉验证（df + sys/class/block + eMMC 存在性检测）
- 新增：R4S Armbian zram-config 强化（SIZE=50%，ENABLED=true）
- 新增：R4S Armbian ramlog 强化（SIZE=256M）
- 新增：R4S TF 卡每周 fstrim 定时任务（延长卡寿命）
- 新增：T6 Armbian zram-config 强化（SIZE=30%，ENABLED=true）
- 新增：T6 Armbian ramlog 强化（SIZE=256M）
- 新增：T6 eMMC 每周 fstrim 定时任务（保持长期 IO 性能）
- 安全：APT 官方源 http→https（deb.debian.org 全线加密）
- 安全：install.sh 添加 `wait_for_apt_lock()` 函数（解决 Debian 12 新机 unattended-upgrades 锁阻塞）
- 健壮：未知 ARM64 设备 fallback 增加 log_warn 警告提示

### v3.1
- 移除 OpenClaw 相关代码及文本残留（纯优化定位更清晰）
- R57: 5个平台脚本 uninstall 函数清理 OpenClaw 残留
- 统一全平台 conntrack timeout（close_wait=5, fin_wait=10）
- 补全 tcp_rfc1337、IPv6 forwarding、ip_forward
- nanopi-r4s 补全 IPv6 accept_redirects 安全参数
- 统一 tcp_early_retrans=3、tcp_orphan_retries=1
- n5105 补全 vm.zone_reclaim_mode=0 NUMA优化
- generic-x86 补全 conntrack close_wait/fin_wait
- 新增 verify-v3.1.sh 完整验证脚本
- oracle-arm TCP缓冲从 64MB 调整为 32MB（更合理）
- nanopi-r4s 移除不可靠的外部 log2ram 源，改为 journald volatile 替代

### v3.0
- 完整重构，4平台差异化配置
- BBR + fq 队列全平台统一
- SSH 加固（MaxAuthTries、ClientAliveInterval）
- journald 压缩 + RateLimit
- TF卡保护体系（dirty_writeback、journald volatile）
- N5105 Turbo Boost 静音优化

---

## 获取帮助

- 问题反馈：https://github.com/vpn3288/VPS-youhua/issues
- 提交优化：欢迎提交 Issue 和 PR

---

## License

MIT License
