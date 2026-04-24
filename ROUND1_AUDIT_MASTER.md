# Round 1 审计主报告

**审计时间:** 2026-04-24  
**审计范围:** 10 个 Bash 脚本（11,078 行代码）  
**审计模式:** 双代理并行  
- Agent-Alpha (gpt-5.4): Group A (5 文件)
- Agent-Beta (gpt-5.4): Group B (5 文件)

---

## 审计统计

**总发现:** 24 个问题
- CRITICAL: 1
- HIGH: 2
- MEDIUM: 9
- LOW: 12

**按文件分布:**
- common-optimize.sh: 5 问题
- install.sh: 3 问题
- generic-x86.sh: 2 问题
- google-cloud-e2.sh: 2 问题
- generic-1c1g.sh: 1 问题
- nanopi-r4s.sh: 4 问题
- oracle-1c4g.sh: 3 问题
- oracle-arm.sh: 2 问题
- n5105.sh: 1 问题
- nanopc-t6.sh: 1 问题

---

## CRITICAL 优先级 (1 个)

### [FINDING-1] install.sh - case 语句语法错误
**Location:** Lines 1128-1130  
**Severity:** CRITICAL  
**Description:** case 语句中使用反斜杠转义导致语法错误
```bash
case "${1:-}" in
    ''|-y|--yes) _sanitized_arg1="${1:-}" ;;\
    *)  log_error "不支持的参数: $1"; echo "用法: $0 ..."; exit 1 ;;\
esac
```
**Impact:** 脚本执行失败
**Fix:**
```bash
case "${1:-}" in
    ''|-y|--yes) _sanitized_arg1="${1:-}" ;;
    *)  log_error "不支持的参数: ${1:-unknown}"; echo "用法: ${0} [--platform=xxx] [--mode=optimize|status|uninstall] [-y|--yes]"; exit 1 ;;
esac
```

---

## HIGH 优先级 (2 个)

### [FINDING-2] install.sh - curl 超时参数不一致
**Location:** Lines 305-307, 341-345  
**Severity:** HIGH  
**Description:** 部分 curl 调用缺少 `--max-time` 参数，可能导致挂起
**Impact:** 网络不稳定时脚本阻塞
**Fix:** 所有 curl 调用统一添加 `--max-time 10`

### [FINDING-6] generic-x86.sh - Docker 镜像 URL 验证逻辑错误
**Location:** Lines 513-518  
**Severity:** HIGH  
**Description:** `mirror_url` 硬编码为 `download.docker.com`，验证永远不会失败
**Impact:** 无法支持镜像切换，验证无意义
**Fix:**
```bash
local mirror_url="${DOCKER_MIRROR:-download.docker.com}"
if [[ -z "$mirror_url" ]] || [[ ! "$mirror_url" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
    log_error "Docker 镜像 URL 无效: ${mirror_url}"
    return 1
fi
```

---

## MEDIUM 优先级 (9 个)

### [FINDING-3] common-optimize.sh - install_if_missing 逻辑缺陷
**Location:** Lines 513-522  
**Severity:** MEDIUM  
**Description:** 使用 `command -v` 检查包安装不准确（包名≠命令名）
**Fix:** 改用 `dpkg-query -W` 检查

### [FINDING-4] common-optimize.sh - DNS 锁定竞态条件
**Location:** Lines 553-558  
**Severity:** MEDIUM  
**Description:** systemd-resolved 检查和 chattr +i 之间存在竞态
**Fix:** 先检查 systemd-resolved，如果激活则解锁 resolv.conf

### [FINDING-5] common-optimize.sh - ulimit 错误处理缺失
**Location:** Lines 710-712  
**Severity:** MEDIUM  
**Description:** ulimit 命令失败时无错误处理，且 `ulimit -m` 已废弃
**Fix:** 添加错误处理，移除 `ulimit -m`

### [FINDING-7] generic-x86.sh - Node.js SHA256 硬编码
**Location:** Lines 602-610  
**Severity:** MEDIUM  
**Description:** NodeSource setup 脚本 SHA256 硬编码，会过期
**Fix:** 移除 SHA256 校验（HTTPS 已提供传输层保护）或使用 GPG 签名验证

### [FINDING-8] google-cloud-e2.sh - zram 内存验证不完整
**Location:** Lines 215-220  
**Severity:** MEDIUM  
**Description:** 未检查 `mem_kb` 是否为纯数字
**Fix:** 添加正则验证 `[[ ! "$mem_kb" =~ ^[0-9]+$ ]]`

### [FINDING-11] common-optimize.sh - 镜像测速验证缺陷
**Location:** Lines 337-340  
**Severity:** MEDIUM  
**Description:** curl 失败时 awk 输出 0，被误判为最快镜像
**Fix:** awk 中添加条件 `if($1>0) printf "%.0f", $1*1000; else print ""`

### [FINDING-12] install.sh - 临时目录清理缺失
**Location:** Lines 876-884  
**Severity:** MEDIUM  
**Description:** 未设置 trap 清理临时目录
**Fix:** 添加 `trap "rm -rf '$tmpdir'" RETURN EXIT`

### [FINDING-3B] nanopi-r4s.sh - 函数参数传递错误
**Location:** Line 555-606, ~1200  
**Severity:** MEDIUM  
**Description:** `configure_conntrack_hashsize_r4s` 需要参数但调用时未传递
**Impact:** 连接追踪优化失效
**Fix:**
```bash
local calc_conntrack_max=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo "131072")
configure_conntrack_hashsize_r4s "$calc_conntrack_max"
```

### [FINDING-6B] oracle-1c4g.sh - TCP_BUF_MAX 格式化问题
**Location:** Line 54-57  
**Severity:** MEDIUM  
**Description:** 使用 `printf "%.0f"` 可能产生浮点格式，验证失败
**Fix:** 改用 `printf "%d"`

### [FINDING-12B] nanopi-r4s.sh - zram 模块检查不足
**Location:** Line 340-358  
**Severity:** MEDIUM  
**Description:** 未检查 zram 模块是否真正加载成功
**Fix:** 添加 `lsmod | grep -q "^zram "` 检查

---

## LOW 优先级 (12 个)

### [FINDING-9] google-cloud-e2.sh - GCP 机型检测正则错误
**Location:** Line 307  
**Severity:** LOW  
**Description:** `\\|` 在双引号内被解释为字面字符串
**Fix:** 使用 `grep -E` 或单引号

### [FINDING-10] generic-1c1g.sh - 注释不一致
**Location:** Lines 52-53  
**Severity:** LOW  
**Description:** 注释说"内存3%"，代码是 `m*3/100`
**Fix:** 改为 `m*0.03` 或明确说明百分比计算

### [FINDING-1B~5B, 8B, 10B] 缺少显式 main 函数调用
**Files:** n5105.sh, nanopc-t6.sh, nanopi-r4s.sh, oracle-1c4g.sh, oracle-arm.sh  
**Severity:** LOW  
**Description:** 所有平台脚本末尾缺少 `main "$@"`
**Fix:** 在文件末尾添加 `main "$@"`

### [FINDING-4B] nanopi-r4s.sh - trap 清理不完整
**Location:** Line 740  
**Severity:** LOW  
**Description:** Docker 安装 trap 缺少 `gpg_dearmored` 清理
**Fix:** 添加到 trap 语句

### [FINDING-7B] oracle-1c4g.sh - 桩函数无提示
**Location:** Line 653-661  
**Severity:** LOW  
**Description:** install_docker/nodejs 桩函数无警告信息
**Fix:** 添加 `log_warn` 提示用户

### [FINDING-9B] oracle-arm.sh - trap 变量顺序错误
**Location:** Line 436  
**Severity:** LOW  
**Description:** trap 在 `gpg_dearmored` 声明前设置
**Fix:** 调整变量声明顺序

### [FINDING-11B] 所有文件 - 错误抑制过度
**Location:** 全局  
**Severity:** LOW  
**Description:** 大量使用 `|| true` 可能掩盖真实问题
**Fix:** 关键配置后添加验证和警告

---

## 修复优先级建议

**立即修复（CRITICAL/HIGH）:** 3 个
1. FINDING-1: install.sh case 语句语法错误
2. FINDING-2: install.sh curl 超时不一致
3. FINDING-6: generic-x86.sh Docker URL 验证

**高优先级（MEDIUM）:** 9 个
4-12. 所有 MEDIUM 问题

**低优先级（LOW）:** 12 个
13-24. 所有 LOW 问题

---

## 下一步

按优先级分配修复任务给双代理：
- **Batch 1 (Agent-Alpha):** CRITICAL + HIGH + 部分 MEDIUM (12 个问题)
- **Batch 2 (Agent-Beta):** 剩余 MEDIUM + 部分 LOW (12 个问题)
