# VPS-youhua 环境优化脚本

<div align="center">

**NanoPi R4S / T6、Oracle Cloud ARM、N5105、通用 x86 VPS 的系统优化**
适用于 OpenClaw、Hermes 等所有需要 Linux 环境的 AIagent

[![Debian 12](https://img.shields.io/badge/Debian-12-AA0000?logo=debian)](https://www.debian.org/)
[![Ubuntu 24.04](https://img.shields.io/badge/Ubuntu-24.04-E95420?logo=ubuntu)](https://ubuntu.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![v3.4](https://img.shields.io/badge/版本-v3.4-green.svg)](https://github.com/vpn3288/VPS-youhua)
[![8平台](https://img.shields.io/badge/平台-8个-cyan.svg)](https://github.com/vpn3288/VPS-youhua)

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


### 自动检测平台（推荐新手）
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/install.sh)
```
### 手动指定平台
### NanoPi R4S (4GB ARM, TF卡)
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/nanopi-r4s.sh)
```
### NanoPC T6 (16GB ARM, eMMC)
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/nanopc-t6.sh)
```
### Oracle Cloud ARM 2C16G
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/oracle-arm.sh)
```
### Oracle Cloud ARM 1C4G
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/oracle-1c4g.sh)
```
### N5105/N5095 小主机
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/n5105.sh)
```
### 通用 x86 VPS
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/generic-x86.sh)
```
### 通用 1C1G 低配 VPS
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/generic-1c1g.sh)
```
 ### Google Cloud e2-micro
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/google-cloud-e2.sh)
```

可选参数：
--optimize-only   仅做环境优化，跳过 Docker / Node.js / OpenClaw 安装
--clean-system    清理 apt purge 预装软件（apache2/nginx/postfix 等）
--uninstall       卸载已安装的优化配置
--non-interactive 自动执行（适合自动化）


### 第二步：验证优化效果

```bash
curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/verify-v3.4.sh -o /tmp/verify-v3.4.sh
bash /tmp/verify-v3.4.sh
```

### 第三步：安装 AIagent

如果你在第一步选择了安装 Docker / Node.js，现在可以安装你的 AIagent：

**OpenClaw（推荐）：**
```bash
openclaw install      # 安装
openclaw onboard      # 首次配置
systemctl --user start openclaw-gateway   # 启动
systemctl --user enable openclaw-gateway  # 开机自启
```

**或者纯优化用户：** 环境已优化完毕，直接安装你需要的软件即可。

---

## 支持的平台

| 平台 | CPU | 内存 | 存储 | 推荐脚本 |
|------|-----|------|------|----------|
| NanoPi R4S | RK3399 (ARM64) | 4GB | **TF卡** | `nanopi-r4s.sh` |
| NanoPC T6 | RK3588S (ARM64) | 16GB | **eMMC** | `nanopc-t6.sh` |
| Oracle Cloud ARM | Ampere Altra (ARM64) | 2核16GB | 云盘 | `oracle-arm.sh` |
| Oracle Cloud ARM | Ampere Altra (ARM64) | 1核4GB | 云盘 | `oracle-1c4g.sh` |
| N5105/N5095 小主机 | Intel N5105 (x86_64) | 4-16GB | SSD | `n5105.sh` |
| 通用 x86 VPS | 任意 x86_64 | 1C1G | 自动检测（SSD/HDD） | `generic-1c1g.sh` |
| Google Cloud e2-micro | 共享 vCPU | 1GB | **免费套餐** | `google-cloud-e2.sh` |
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


### Oracle Cloud ARM 2C16G（云环境）

云上环境侧重吞吐量和连接处理：

| 优化项 | 配置值 | 说明 |
|--------|--------|------|
| TCP缓冲 | 动态（内存5%） | 云网络带宽优化，上限64MB |
| netdev_max_backlog | 65535 | 大吞吐量队列 |
| conntrack_max | 262144 | 高并发连接数 |
| conntrack timeout | 3600s | 长连接优化 |
| dirty_ratio | 20 | 云盘写入更激进 |
| TCP early_retrans | 3 | 丢包快速恢复 |
| TCP MTU probing | 开启 | Oracle网络优化 |

### Oracle Cloud ARM 1C4G（低配云环境）

低配版针对1核4GB内存优化，侧重内存压缩和资源控制：

| 优化项 | 配置值 | 说明 |
|--------|--------|------|
| TCP缓冲 | 动态（内存5%） | 云网络优化，上限32MB |
| netdev_max_backlog | 32768 | 适度队列 |
| conntrack_max | 131072 | 中等并发连接数 |
| vm.swappiness | 60 | 较高swap倾向（内存有限） |
| zram | 启用（内存50%） | 内存压缩替代物理swap |
| dirty_ratio | 15 | 保守回写 |
| transparent_hugepage | 开启 | 对容器/数据库友好 |

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

### Generic x86 VPS（通用中配）

通用Debian12环境，2核2GB以上，自适应内存配置：

| 优化项 | 配置值 | 说明 |
|--------|--------|------|
| 内存分级 | 4GB/8GB/16GB+ | 配置文件数自动适配 |
| dirty_ratio | 15 | 通用推荐值 |
| TCP fastopen | 3 | 快速建立连接 |
| BBR | 强制开启 | 拥塞控制优化 |
| inotify watches | 1048576 | 大型agent支持 |

### Generic 1C1G VPS（低配通用）

极低配VPS，1核1GB，专为资源受限环境设计：

| 优化项 | 配置值 | 说明 |
|--------|--------|------|
| TCP缓冲 | 动态（内存3%） | 最低4MB，最高8MB |
| netdev_max_backlog | 16384 | 适度队列 |
| conntrack_max | 65536 | 有限并发 |
| vm.swappiness | 60 | 较高swap倾向 |
| swap | 1GB文件swap | 低内存防护 |
| dirty_ratio | 10 | 保守回写 |
| inotify watches | 262144 | 有限但够用 |

### Google Cloud e2-micro（免费套餐）

GCP免费套餐，共享vCPU 1核1GB，针对资源共享优化：

| 优化项 | 配置值 | 说明 |
|--------|--------|------|
| TCP缓冲 | 动态（内存3%） | 最低4MB，最高8MB |
| netdev_max_backlog | 16384 | 适度队列 |
| conntrack_max | 65536 | 有限并发 |
| vm.swappiness | 60 | 较高swap倾向 |
| swap | 1GB文件swap | 低内存防护 |
| dirty_ratio | 10 | 保守回写 |
| CPU限制 | GCP元数据 | 识别共享CPU |

---

## v3.3 全部优化参数一览

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

## 验证脚本（verify-v3.4.sh）

下载并运行验证脚本，检查所有优化参数是否生效：

```bash
curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/verify-v3.4.sh -o /tmp/verify-v3.4.sh
bash /tmp/verify-v3.4.sh                    # 本机验证
sudo bash /tmp/verify-v3.4.sh               # 带root权限验证（完整检查）
bash /tmp/verify-v3.4.sh --remote root@IP  # 远程SSH验证
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
| sysctl 主配置 | `/etc/sysctl.d/99-vps-youhua-sysctl.conf` |
| sysctl inotify | `/etc/sysctl.d/99-vps-youhua-inotify.conf` |
| sysctl TF卡优化 | `/etc/sysctl.d/99-vps-youhua-tf-optimize.conf` (R4S) |
| journald 配置 | `/etc/systemd/journald.conf` |
| limits 配置 | `/etc/security/limits.conf` |
| SSH 服务配置 | `/etc/ssh/sshd_config` |
| log2ram 配置 | `/etc/log2ram.conf` (可选) |
| 优化标记 | `/etc/vps-youhua-optimized` |

### 卸载后配置文件自动清理

使用 `--uninstall` 会自动删除上述所有配置文件。

---

## 常见问题

### Q: 脚本会修改哪些系统文件？

主要修改以下文件（幂等设计，可重复运行）：
- `/etc/sysctl.d/99-vps-youhua-*.conf` — sysctl网络/内存参数
- `/etc/systemd/journald.conf` — 日志配置
- `/etc/security/limits.conf` — 进程限制
- `/etc/ssh/sshd_config` — SSH加固
- SSH 公钥authorized_keys（如果配置了）
- `/etc/vps-youhua-optimized` — 优化完成标记

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

### Q: Oracle Cloud ARM 为什么 TCP缓冲不是固定值？

Oracle Cloud 的网络带宽与实例规格相关：
- **X86 免费小户型 (AMD/E4)**：最大 50Mbps（Small Tenant），确实不是越高越好。
- **ARM Ampere (1C/2C/4C)**：每核 1Gbps，最大 4Gbps（4核），带宽远大于 X86 免费版。脚本使用动态计算：内存的5%，上限64MB（2C16G）或32MB（1C4G），在不同内存规格下都能获得最优值。

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
- 新增：11个平台脚本完整支持（新增 oracle-1c4g、generic-1c1g、google-cloud-e2）
- 新增：`--status` 参数直接调用 verify-v3.4.sh 健康检查（install.sh），并更新帮助文档
- 新增：R4S `install_nodejs()` 编译前临时挂载 1G tmpfs 到 /tmp（TF 卡保护），编译完自动卸载
- 新增：fail2ban 选项 B 增加新手警告"请确保已配置 SSH 密钥登录，否则可能锁死"
- 新增：Oracle Cloud ARM 增加 `check_oracle_metadata()` 元数据健康检查（非 Oracle 环境自动跳过）
- 修复：verify-v3.4.sh 删除残留 `99-openclaw.conf`（替换为 `99-vps-youhua-*.conf`）
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
- 新增 verify-v3.4.sh 完整验证脚本
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

## 代码质量保证

本项目采用严格的多轮审计流程确保代码质量：

- **审计标准**：遵循 `AUDIT_STANDARD.md` 定义的安全、语法、硬件适配和最佳实践标准
- **多轮审计**：每个版本经过多轮 AI 辅助审计，覆盖安全漏洞、逻辑错误、硬件兼容性等方面
- **分组审计**：将脚本分组进行针对性审计，确保每个平台的特定优化得到验证
- **修复验证**：所有发现的问题都经过修复并验证，确保不引入新问题

审计重点包括：
- 命令注入和路径遍历等安全风险
- 变量作用域和引用正确性
- 硬件特定优化（SD卡保护、内存限制等）
- 幂等性和错误处理
- GPG 密钥指纹完整性验证

---

## 获取帮助

- 问题反馈：https://github.com/vpn3288/VPS-youhua/issues
- 提交优化：欢迎提交 Issue 和 PR

---

## License

MIT License
