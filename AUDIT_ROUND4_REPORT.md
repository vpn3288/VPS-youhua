# Round 4 审计报告 - v3.4.2

**审计时间**: 2026-04-23  
**审计版本**: v3.4.2 (commit 0c049b1)  
**审计工程师**: Hermes Agent  
**审计范围**: 验证 Round 3 修复 + 全面代码审计

---

## 执行摘要

### Round 3 修复验证结果

| 修复项 | 状态 | 详情 |
|--------|------|------|
| HIGH-1: conntrack 参数验证 | ✅ 完全通过 | 4个平台全部实施 |
| HIGH-2: 备份函数调用 | ⚠️ 部分通过 | 3个脚本缺少备份 |
| MEDIUM: 变量作用域补全 | ✅ 完全通过 | 3个平台已修复 |

### Clean Round 判定

**❌ 未达到 clean round 标准**

**原因**: 发现 3 个 HIGH 级别问题（备份机制不完整）

---

## Round 3 修复详细验证

### ✅ HIGH-1: conntrack 参数跨文件不一致 - 完全通过

**验证结果**: 所有 4 个平台脚本已正确实施参数验证和最小值保护

#### generic-x86.sh (行 296-330)
```bash
configure_conntrack_hashsize() {
    # Round 3 Fix H1: 参数验证
    local conntrack_max=${CT_MAX:-0}
    
    if [[ -z "$conntrack_max" || "$conntrack_max" -le 0 ]]; then
        log_warn "conntrack_max 无效（${conntrack_max:-未定义}），使用默认值"
        conntrack_max=131072
    fi
    
    local hashsize=$((conntrack_max / 4))
    
    # 最小值保护
    if [[ $hashsize -lt 16384 ]]; then
        log_warn "hashsize 过小（$hashsize），使用最小值 16384"
        hashsize=16384
    fi
    ...
}
```

✅ **验证通过**:
- 空值检查: `[[ -z "$conntrack_max" ]]`
- 负值检查: `"$conntrack_max" -le 0`
- 默认值回退: `conntrack_max=131072`
- 最小值保护: `hashsize=16384`

#### n5105.sh (行 274-308)
✅ **验证通过**: 与 generic-x86.sh 逻辑完全一致

#### nanopc-t6.sh (行 314-363)
✅ **验证通过**: 增强版验证，包含数字格式检查
```bash
# 验证是否为有效数字
if ! [[ "$calc_conntrack_max" =~ ^[0-9]+$ ]]; then
    log_warn "conntrack_max 不是有效数字（${calc_conntrack_max}），使用默认值 262144"
    calc_conntrack_max=262144
fi
```

#### nanopi-r4s.sh (行 524-574)
✅ **验证通过**: 最完整的验证逻辑
- 参数空值检查
- 数字格式验证
- 非零验证
- 最小值保护 (4096 和 16384 双重保护)

**结论**: HIGH-1 修复完全符合要求，所有平台参数验证逻辑一致且健壮。

---

### ⚠️ HIGH-2: 备份函数调用不完整 - 部分通过

**验证结果**: 部分脚本缺少备份调用

#### ✅ 已正确实施备份的文件

1. **limits.conf** (common-optimize.sh:722)
   ```bash
   [[ -f "$limits_conf" ]] && backup_file "$limits_conf"
   ```

2. **SSH 配置** (common-optimize.sh:1334)
   ```bash
   [[ -f "$dropin_file" ]] && backup_file "$dropin_file"
   ```

3. **journald.conf** - 4个平台脚本已实施:
   - generic-x86.sh:356 ✅
   - n5105.sh:334 ✅
   - nanopc-t6.sh:389 ✅
   - nanopi-r4s.sh:601 ✅

#### ❌ 缺少备份的关键文件

**HIGH-3**: 以下 3 个脚本的 `configure_journald()` 缺少备份调用:

1. **oracle-arm.sh** (行 341-357)
   ```bash
   configure_journald() {
       log_step "配置 journald..."
       mkdir -p /etc/systemd/journald.conf.d
       
       # ❌ 缺少备份
       cat > /etc/systemd/journald.conf.d/99-vps-youhua.conf <<EOF
   ```

2. **oracle-1c4g.sh** (行 370-383)
   ```bash
   configure_journald() {
       log_step "配置 journald 日志..."
       mkdir -p /etc/systemd/journald.conf.d
       # ❌ 缺少备份
       cat > /etc/systemd/journald.conf.d/99-vps-youhua.conf <<EOF
   ```

3. **google-cloud-e2.sh** (行 449-465)
   ```bash
   configure_journald() {
       log_step "配置 journald 日志..."
       mkdir -p /etc/systemd/journald.conf.d
       # ❌ 缺少备份
       cat > /etc/systemd/journald.conf.d/99-vps-youhua.conf <<EOF
   ```

4. **generic-1c1g.sh** (行 258-271)
   ```bash
   configure_journald() {
       log_step "配置 journald 日志（极简模式）..."
       mkdir -p /etc/systemd/journald.conf.d
       # ❌ 缺少备份
       cat > /etc/systemd/journald.conf.d/99-vps-youhua.conf <<EOF
   ```

**影响**: 这些脚本在覆盖 journald 配置前没有备份，违反了 Round 3 的修复标准。

---

### ✅ MEDIUM: 变量作用域补全 - 完全通过

**验证结果**: 所有 3 个平台的 `sw` 变量已正确声明为 local

#### generic-x86.sh (行 150)
```bash
# Round 3 Fix M2: 添加循环变量 local 声明
local sw
for sw in /swapfile /swap.img; do
```

#### n5105.sh (行 154)
```bash
# Round 3 Fix M2: 添加循环变量 local 声明
local sw
for sw in /swapfile /swap.img; do
```

#### nanopc-t6.sh (行 133)
```bash
# Round 3 Fix M2: 添加循环变量 local 声明
local sw
for sw in /swapfile /swap.img; do
```

✅ **验证通过**: 所有循环变量已正确限制作用域

---

## 新发现的问题

### HIGH 级别

**HIGH-3: journald 配置缺少备份（4个脚本）**

**严重性**: HIGH  
**影响范围**: oracle-arm.sh, oracle-1c4g.sh, google-cloud-e2.sh, generic-1c1g.sh

**问题描述**:
这 4 个脚本的 `configure_journald()` 函数在覆盖 `/etc/systemd/journald.conf.d/99-vps-youhua.conf` 前没有调用 `backup_file()`，与其他 4 个平台脚本不一致。

**修复方案**:
在每个脚本的 `configure_journald()` 函数中，在 `cat >` 之前添加:
```bash
# Round 4 Fix H3: 添加备份
local journald_conf="/etc/systemd/journald.conf.d/99-vps-youhua.conf"
[[ -f "$journald_conf" ]] && backup_file "$journald_conf"
```

**受影响文件**:
1. oracle-arm.sh:345 (在 cat > 之前)
2. oracle-1c4g.sh:373 (在 cat > 之前)
3. google-cloud-e2.sh:452 (在 cat > 之前)
4. generic-1c1g.sh:261 (在 cat > 之前)

---

### MEDIUM 级别

**无新发现的 MEDIUM 问题**

---

### LOW 级别

**LOW-1: fstab 备份使用自定义后缀而非 backup_file()**

**严重性**: LOW  
**影响范围**: common-optimize.sh:772

**问题描述**:
`configure_fstab()` 使用自定义备份命令而非标准的 `backup_file()` 函数:
```bash
cp -a /etc/fstab /etc/fstab.vps-youhua-bak 2>/dev/null || true
```

**建议修复**:
```bash
backup_file "/etc/fstab"
```

**理由**: 统一备份机制，使用时间戳后缀便于追溯多次修改历史。

---

**LOW-2: apt sources.list 备份已使用 backup_file()**

**严重性**: LOW (已修复，仅记录)  
**影响范围**: common-optimize.sh:281

✅ **已正确实施**:
```bash
backup_file "$sources_list"
```

---

## 代码质量评分

### 当前评分: 8.5/10

**评分依据**:

| 维度 | 评分 | 说明 |
|------|------|------|
| 参数验证 | 10/10 | Round 3 修复后，conntrack 参数验证完美 |
| 备份机制 | 7/10 | 4个脚本缺少 journald 备份 |
| 变量作用域 | 10/10 | 循环变量已正确声明 local |
| 错误处理 | 9/10 | 大部分函数有错误处理，少数可改进 |
| 幂等性 | 9/10 | 大部分函数支持重复执行 |
| 代码一致性 | 8/10 | 4个脚本的 journald 配置不一致 |

### 改进点

1. **备份机制统一性** (HIGH)
   - 4个脚本需要补充 journald 备份
   - 建议统一使用 `backup_file()` 函数

2. **代码一致性** (MEDIUM)
   - 所有平台脚本的相同功能函数应保持一致的实现模式
   - 特别是备份调用的位置和方式

3. **文档完整性** (LOW)
   - 建议在每个修复点添加 Round 标记（如 `# Round 4 Fix H3`）
   - 便于追溯修复历史

### 剩余风险

1. **数据丢失风险** (HIGH)
   - 4个脚本在覆盖 journald 配置前无备份
   - 用户无法回滚到原始配置

2. **不一致性风险** (MEDIUM)
   - 不同平台脚本的实现差异可能导致维护困难
   - 未来修复可能遗漏部分脚本

---

## 审计标准符合性检查

### 安全性 ✅
- [x] 无 eval 使用
- [x] 无命令注入向量
- [x] 变量正确引用
- [x] 无路径遍历漏洞
- [x] 无符号链接攻击风险
- [x] curl/wget 使用安全（带 SHA256 校验）

### 语法与逻辑 ✅
- [x] 所有 heredoc 正确闭合
- [x] 所有 if/for/while 正确闭合
- [x] 引号匹配正确
- [x] 变量作用域正确（Round 3 已修复）
- [x] 函数调用顺序正确
- [x] 算术表达式正确引用

### 硬件特定优化 ✅
- [x] SD 卡 I/O 优化 (NanoPi R4S)
- [x] 内存分级策略 (所有平台)
- [x] TCP 调优 (代理工作负载)
- [x] 计算调度 (AI agent)
- [x] 存储特定优化

### 最佳实践 ⚠️
- [x] 幂等性执行
- [x] 错误处理 (set -euo pipefail)
- [x] 正确的退出码
- [x] 用户输入验证
- [x] Ctrl+C 处理
- [x] 清晰的错误消息
- [⚠️] 备份机制 (4个脚本不完整)

---

## 修复优先级

### 立即修复 (HIGH)

1. **oracle-arm.sh**: 添加 journald 备份 (行 345 之前)
2. **oracle-1c4g.sh**: 添加 journald 备份 (行 373 之前)
3. **google-cloud-e2.sh**: 添加 journald 备份 (行 452 之前)
4. **generic-1c1g.sh**: 添加 journald 备份 (行 261 之前)

### 建议修复 (LOW)

1. **common-optimize.sh**: 统一 fstab 备份使用 backup_file() (行 772)

---

## 结论

### Round 3 修复质量: 优秀

- HIGH-1 (conntrack 参数验证): **完美实施** ✅
- MEDIUM (变量作用域): **完美实施** ✅
- HIGH-2 (备份机制): **部分实施** ⚠️ (7/11 个文件已修复)

### Round 4 发现

- **新 HIGH 问题**: 1 个 (4个脚本的 journald 备份缺失)
- **新 MEDIUM 问题**: 0 个
- **新 LOW 问题**: 1 个 (fstab 备份不统一)

### Clean Round 判定

**❌ 未达到 clean round 标准**

**原因**: 
1. Round 3 的 HIGH-2 修复不完整（4个脚本遗漏）
2. 发现新的 HIGH-3 问题（与 HIGH-2 相同根因）

### 下一步行动

**Round 5 修复计划**:
1. 补全 4 个脚本的 journald 备份调用
2. 统一 fstab 备份机制（可选）
3. 验证所有平台脚本的一致性

**预期结果**: 修复后应达到 clean round 标准

---

## 附录: 修复代码片段

### oracle-arm.sh (行 345 之前插入)

```bash
configure_journald() {
    log_step "配置 journald..."
    mkdir -p /etc/systemd/journald.conf.d

    # Round 4 Fix H3: 添加备份
    local journald_conf="/etc/systemd/journald.conf.d/99-vps-youhua.conf"
    [[ -f "$journald_conf" ]] && backup_file "$journald_conf"

    cat > /etc/systemd/journald.conf.d/99-vps-youhua.conf <<EOF
```

### oracle-1c4g.sh (行 373 之前插入)

```bash
configure_journald() {
    log_step "配置 journald 日志..."
    mkdir -p /etc/systemd/journald.conf.d
    
    # Round 4 Fix H3: 添加备份
    local journald_conf="/etc/systemd/journald.conf.d/99-vps-youhua.conf"
    [[ -f "$journald_conf" ]] && backup_file "$journald_conf"
    
    cat > /etc/systemd/journald.conf.d/99-vps-youhua.conf <<EOF
```

### google-cloud-e2.sh (行 452 之前插入)

```bash
configure_journald() {
    log_step "配置 journald 日志..."
    mkdir -p /etc/systemd/journald.conf.d
    
    # Round 4 Fix H3: 添加备份
    local journald_conf="/etc/systemd/journald.conf.d/99-vps-youhua.conf"
    [[ -f "$journald_conf" ]] && backup_file "$journald_conf"
    
    cat > /etc/systemd/journald.conf.d/99-vps-youhua.conf <<EOF
```

### generic-1c1g.sh (行 261 之前插入)

```bash
configure_journald() {
    log_step "配置 journald 日志（极简模式）..."
    mkdir -p /etc/systemd/journald.conf.d
    
    # Round 4 Fix H3: 添加备份
    local journald_conf="/etc/systemd/journald.conf.d/99-vps-youhua.conf"
    [[ -f "$journald_conf" ]] && backup_file "$journald_conf"
    
    cat > /etc/systemd/journald.conf.d/99-vps-youhua.conf <<EOF
```

---

**审计完成时间**: 2026-04-23  
**下次审计**: Round 5 (修复 HIGH-3 后)
