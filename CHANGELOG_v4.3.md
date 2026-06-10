# VPS-youhua v4.3.0 更新日志

**发布日期**: 2026-06-10

## 核心目标

v4.3.0 继续保持高兼容、低冲突、不安装软件、不接管业务环境的定位，同时补上低内存机器更需要的保守虚拟内存和通用稳定性参数。

## 新增功能

### 1. 项目自有 swapfile

- 默认仅在低内存、无现有 swap/zram/fstab swap 配置、非 TF 卡场景创建 `/swapfile-vps-youhua`。
- 已有 swap、zram 或 fstab swap 配置时保持现状，不重复创建。
- TF 卡设备默认跳过，避免额外写入压力；需要时可用 `--force-swap`。
- 根分区空间不足时自动跳过。
- `--uninstall` 会关闭并删除本项目 swapfile，只移除带 `VPS-youhua managed swapfile` 标记的 fstab 行。

默认大小：

| 内存档 | 默认 swapfile |
|--------|---------------|
| tiny | 1024MB |
| small | 2048MB |
| medium + cloud/ssd | 1024MB |
| large | 不创建 |

可选参数：

```bash
--no-swap
--force-swap
--swap-size=<MB>
```

### 2. 稳定性和容量类 sysctl 增强

新增或细化以下保守参数：

- `fs.nr_open`
- `fs.aio-max-nr`
- `fs.inotify.max_user_instances`
- `fs.inotify.max_queued_events`
- `net.ipv4.tcp_max_tw_buckets`
- `net.ipv4.tcp_max_orphans`
- `net.ipv4.tcp_no_metrics_save`
- `vm.page-cluster`
- `vm.max_map_count`
- `vm.zone_reclaim_mode`

这些参数按 tiny/small/medium/large 档位计算，低配共享 CPU 会自动压低上限。

### 3. 新增 v4.3 验证脚本

- 新增 `verify-v4.3.sh`，只验证当前保守优化项。
- 旧版 `verify-v3.4.sh` 保留为历史脚本，但它会检查 BBR/qdisc 等 v4.3 不再强制修改的项目，不适合作为 v4.3 成功标准。

## 保持不变

- 不安装 Docker、Node.js、构建依赖或任何软件包。
- 不修改 DNS、SSH、防火墙、iptables/nftables、APT 源、CPU governor。
- 不停止、禁用、mask 或卸载服务。
- 不重置已有 swap/zram，不改 Armbian 原生组件。
- 不覆盖用户已有 swap/fstab 配置。

## 验证

```bash
for f in *.sh; do bash -n "$f" || exit 1; done
bash install.sh --help
bash common-optimize.sh --help
bash verify-v4.3.sh
```
