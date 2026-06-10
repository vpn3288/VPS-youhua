# VPS-youhua 普通优化脚本

VPS-youhua v4.2 提供一套高兼容、低冲突、适合生产环境的 Linux 普通优化脚本。所有平台脚本现在都是薄包装器：只设置平台档位，然后调用同一个 `common-optimize.sh` 引擎。

适用场景：代理节点、普通 VPS、ARM VPS、N5105 小主机、R4S/T6 开发板、本地虚拟机、低配共享 CPU 实例。

## 核心原则

- 默认只做低冲突优化：sysctl、文件句柄限制、脚本日志轮转、优化标记。
- 不安装任何软件，不安装运行时，不接管用户业务栈。
- 不修改 DNS、SSH、防火墙、iptables/nftables、APT 源、fstab、swap/zram、CPU governor。
- 不停止、禁用、卸载任何已有服务或云厂商组件。
- 各平台仍保留轻微档位差异：内存档、CPU 档、存储档、TF 卡/eMMC/云盘差异。

## 快速开始

自动检测平台：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/install.sh)
```

非交互自动检测：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/install.sh) --non-interactive
```

手动指定平台：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/install.sh) --platform=generic-x86
```

查看状态：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/install.sh) --status
```

仅移除本项目写入的持久化配置：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/install.sh) --uninstall
```

## 平台脚本

也可以直接运行平台脚本：

| 平台 | 脚本 | 档位 |
|------|------|------|
| NanoPi R4S | `nanopi-r4s.sh` | ARM + TF 卡保护 |
| NanoPC T6/T6S | `nanopc-t6.sh` | ARM + eMMC |
| Oracle Cloud ARM | `oracle-arm.sh` | ARM VPS + 云盘 |
| Oracle Cloud ARM 1C4G | `oracle-1c4g.sh` | 小规格 ARM VPS |
| N5105/N5095 | `n5105.sh` | 本地 x86 小主机 + SSD |
| 通用 x86 VPS | `generic-x86.sh` | 自动内存档 + 云盘 |
| 通用 1C1G VPS | `generic-1c1g.sh` | 低内存 + 共享 CPU |
| Google Cloud e2/f1/g1 | `google-cloud-e2.sh` | 共享 CPU + 低资源 |

示例：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/nanopi-r4s.sh)
```

## 选项

```text
--optimize, --optimize-only   执行普通优化（默认）
--proxy-mode                  普通优化别名，保持业务环境不变
--status                      查看本项目配置状态
--uninstall                   移除本项目写入的配置文件
--force-reapply               重写本项目配置
--platform=<name>             install.sh 指定平台
--non-interactive, -y, --yes  install.sh 非交互模式
```

旧版安装、清理、镜像、服务相关参数会被接受但忽略或提示忽略。

## 实际写入内容

普通优化只写这些本项目自有文件：

| 文件 | 说明 |
|------|------|
| `/etc/sysctl.d/99-vps-youhua-<platform>.conf` | 保守 sysctl 参数 |
| `/etc/security/limits.d/99-vps-youhua.conf` | 保守 nofile/nproc 限制 |
| `/etc/logrotate.d/vps-youhua` | `/var/log/vps-youhua.log` 轮转 |
| `/etc/vps-youhua-optimized` | 优化标记和档位信息 |

`--uninstall` 只删除这些本项目自有文件。运行时 sysctl 不强制回滚，重启后按系统默认或其他配置生效。

## 档位差异

差异只体现在保守参数强度上：

| 场景 | 主要差异 |
|------|----------|
| 1C1G / 共享 CPU | 更小的队列、连接追踪和文件句柄上限 |
| 2GB+ VPS | 中等队列和 TCP 缓冲 |
| 大内存 ARM/VPS | 更高但仍保守的 backlog、conntrack、nofile |
| R4S / TF 卡 | 更低 dirty ratio，减少大批量回写 |
| T6 / eMMC | 比 TF 卡略宽松，但不改 Armbian zram/ramlog |
| 本地小主机 / SSD | 标准存储回写策略，不改 I/O scheduler |

## 明确不会执行

- 不安装 Docker、Node.js、构建依赖或其他软件包。
- 不改 `/etc/resolv.conf`，不锁 DNS。
- 不写 SSH drop-in，不重启 SSH。
- 不添加 iptables/nftables/ufw 规则。
- 不停止、禁用、mask、卸载任何服务。
- 不创建 swapfile，不重置 zram，不改 Armbian 原生组件。
- 不改 APT 源，不执行包清理，不移除云厂商 agent。

## 本地开发检查

```bash
for f in *.sh; do bash -n "$f" || exit 1; done
bash install.sh --status --non-interactive
grep -nE '\b(apt-get|systemctl|iptables|nft|ufw|chattr|sshd|docker|node|npm|swapoff|swapon|mkswap|modprobe|dpkg|autoremove|purge)\b' \
  common-optimize.sh install.sh generic-1c1g.sh generic-x86.sh google-cloud-e2.sh n5105.sh nanopc-t6.sh nanopi-r4s.sh oracle-1c4g.sh oracle-arm.sh
```

最后一条命令在当前设计下应无输出。
