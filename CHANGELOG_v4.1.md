# VPS-youhua v4.1.0 更新日志

**发布日期**: 2026-06-08

---

## 🎯 核心改进

### 1. **智能保留用户网络配置**（关键特性）

#### 问题
v3.4.3 及更早版本会自动尝试启用 BBR/BBRv2，会覆盖用户手动配置的高级网络优化：
- BBR3（最新版）
- bbrplus（优化版）
- CAKE 队列调度器

#### 解决方案
`common-optimize.sh` 新增智能检测逻辑：
```bash
# 检测当前拥塞控制算法
current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)

# 如果用户已配置（不是 cubic/reno），完整保留
if [[ -n "$current_cc" ]] && [[ "$current_cc" != "cubic" ]] && [[ "$current_cc" != "reno" ]]; then
    BBR_CC="$current_cc"
    log_info "TCP 拥塞控制: $current_cc（检测到用户配置，已保留）"
else
    # 只有默认配置才尝试启用 BBR
    ...
fi
```

**受益场景**：
- 用户手动安装 BBR3 后运行优化脚本，BBR3 配置不会被降级到 BBR1/BBR2
- 用户配置 bbrplus + cake 后，不会被改回 bbr + fq
- 适合网络优化爱好者和高级用户

---

### 2. **网络下载重试机制**

#### 问题
所有 `curl -fsSL` 下载操作没有重试，网络不稳定时容易失败。

#### 解决方案
新增 `download_with_retry()` 函数：
- **3 次重试**
- **指数退避**（2秒 → 4秒 → 8秒）
- **详细日志**记录每次尝试

```bash
download_with_retry() {
    local url="$1"
    local output="$2"
    local max_attempts=3
    local attempt=1
    local wait_time=2

    while [[ $attempt -le $max_attempts ]]; do
        if curl --connect-timeout 10 --max-time 60 -fsSL "$url" -o "$output" 2>/dev/null; then
            return 0
        fi
        if [[ $attempt -lt $max_attempts ]]; then
            log_warn "下载失败，${wait_time}秒后重试... ($attempt/$max_attempts)"
            sleep $wait_time
            wait_time=$((wait_time * 2))
        fi
        attempt=$((attempt + 1))
    done
    return 1
}
```

**受益场景**：
- 国内 VPS 访问 GitHub Raw 不稳定
- 网络波动导致脚本中断
- 自动化部署环境

---

### 3. **严格系统版本检测**

#### 变更
`detect_system()` 函数新增版本检查：

**仅支持**：
- Debian 12
- Debian 13
- Ubuntu 22.04
- Ubuntu 24.04

**不支持的系统将拒绝运行**：
```bash
if [[ "$supported" == "false" ]]; then
    log_error "不支持的系统: ${SYS_OS_ID} ${SYS_OS_VERSION}"
    log_error "仅支持: Debian 12/13, Ubuntu 22.04/24.04"
    return 1
fi
```

**原因**：
- 用户明确表示只使用这些系统
- 减少未经测试的兼容性问题
- 集中精力优化主流版本

---

## 📝 文档改进

### README.md 重大更新

1. **移除应用特定引用**
   - 删除：AIagent、OpenClaw、Hermes 等应用名称
   - 改为：通用系统优化定位

2. **适用场景扩展**
   ```markdown
   - Web 服务器：Nginx、Apache、Caddy
   - 容器平台：Docker、Kubernetes
   - 数据库：MySQL、PostgreSQL、Redis
   - 网络服务：VPN、代理、CDN
   - AI 应用：各类 Agent、模型推理
   - 开发环境：Node.js、Python、Go
   ```

3. **新增核心原则**
   - 用户配置保护：智能检测并保留 BBR3、bbrplus、cake 等

---

## 🔧 技术细节

### 版本号统一

所有文件版本号升级到 v4.1.0：
- `common-optimize.sh`: `SCRIPT_VERSION="4.1.0"`
- `install.sh`: `VERSION="4.1"`
- 8 个平台脚本：v3.4.3 → v4.1.0

### 配置文件版本

sysctl 配置文件头部版本：
```bash
# VPS-youhua 通用内核加固参数 v4.1
```

---

## 🚀 升级指南

### 从 v3.4.3 升级到 v4.1.0

**方式 1：直接运行新版本**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/VPS-youhua/main/install.sh)
```

**方式 2：手动更新**
```bash
cd VPS-youhua
git pull origin main
bash install.sh
```

### 兼容性说明

- ✅ **完全向后兼容** v3.4.3 的配置文件
- ✅ **幂等性保证** 可以在已优化的系统上重新运行
- ✅ **用户配置保护** 不会覆盖手动配置的网络优化

---

## 📊 测试覆盖

### 测试环境
- Debian 12 (x86_64)
- Ubuntu 22.04 (x86_64)
- NanoPi R4S (ARM64, Armbian)
- Oracle Cloud ARM (Ampere Altra)

### 测试场景
- ✅ 全新安装（未优化系统）
- ✅ 重复运行（已优化系统）
- ✅ BBR3 保留测试
- ✅ bbrplus + cake 保留测试
- ✅ 网络下载重试测试
- ✅ 不支持系统拒绝测试

---

## 🐛 Bug 修复

无新增 Bug 修复（v3.4.3 已非常稳定）。

---

## 📦 交付文件

1. **Shell 脚本**（11 个）
   - `common-optimize.sh` - 通用函数库
   - `install.sh` - 统一入口
   - 8 个平台脚本
   - `verify-v3.4.sh` - 验证脚本

2. **文档**（3 个）
   - `README.md` - 项目说明
   - `CHANGELOG_v4.1.md` - 本更新日志
   - `SHA256SUMS` - 校验和

---

## 🙏 致谢

感谢用户反馈的关键需求：
- 保留 BBR3/bbrplus 配置不被覆盖
- 网络下载稳定性提升
- 仅支持常用 Debian/Ubuntu 版本

---

## 📞 反馈与支持

- 问题反馈：https://github.com/vpn3288/VPS-youhua/issues
- 功能建议：欢迎提交 Issue 和 PR

---

**v4.1.0 - 更智能，更稳定，更专注** 🚀
