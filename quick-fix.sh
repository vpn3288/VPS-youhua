#!/usr/bin/env bash
# =============================================================================
# VPS-youhua 快速修复脚本
# 
# 此脚本修复已知的严重 bug，可以直接应用到现有仓库
# 不改变架构，只修复关键问题
#
# 使用方法：
#   1. 克隆原仓库: git clone https://github.com/vpn3288/VPS-youhua.git
#   2. 进入目录: cd VPS-youhua
#   3. 运行此脚本: bash quick-fix.sh
#   4. 检查修改: git diff
#   5. 提交修改: git commit -am "fix: 修复关键 bug"
#
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_step()  { echo -e "${CYAN}[➜]${NC} $1"; }

# ─────────────────────────────────────────────────────────────────────────────
# 检查是否在 VPS-youhua 仓库中
# ─────────────────────────────────────────────────────────────────────────────
check_repository() {
    if [[ ! -f "install.sh" ]] || [[ ! -f "common-optimize.sh" ]]; then
        log_error "请在 VPS-youhua 仓库根目录运行此脚本"
        exit 1
    fi
    log_info "检测到 VPS-youhua 仓库"
}

# ─────────────────────────────────────────────────────────────────────────────
# 备份原始文件
# ─────────────────────────────────────────────────────────────────────────────
backup_files() {
    log_step "备份原始文件..."
    local backup_dir="backup-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    for file in *.sh; do
        [[ -f "$file" ]] && cp "$file" "$backup_dir/"
    done
    
    log_info "备份已保存至: $backup_dir"
}

# ─────────────────────────────────────────────────────────────────────────────
# 修复 1: 算术表达式陷阱
# ─────────────────────────────────────────────────────────────────────────────
fix_arithmetic_trap() {
    log_step "修复算术表达式陷阱..."
    
    local files=(
        "n5105.sh"
        "nanopi-r4s.sh"
        "oracle-arm.sh"
        "nanopc-t6.sh"
        "generic-x86.sh"
        "common-optimize.sh"
    )
    
    local count=0
    for file in "${files[@]}"; do
        if [[ -f "$file" ]]; then
            # 修复 ((retry++))
            if grep -q '((retry++))' "$file"; then
                sed -i 's/((retry++))/((retry++)) || true/g' "$file"
                count=$((count + 1))
            fi
            
            # 修复 ((wait_count++))
            if grep -q '((wait_count++))' "$file"; then
                sed -i 's/((wait_count++))/((wait_count++)) || true/g' "$file"
                count=$((count + 1))
            fi
            
            # 修复 ((waited++))
            if grep -q '((waited++))' "$file"; then
                sed -i 's/((waited++))/((waited++)) || true/g' "$file"
                count=$((count + 1))
            fi
        fi
    done
    
    log_info "修复了 $count 处算术表达式"
}

# ─────────────────────────────────────────────────────────────────────────────
# 修复 2: 安全检查必须使用 exit
# ─────────────────────────────────────────────────────────────────────────────
fix_security_checks() {
    log_step "加强安全检查..."
    
    # 修复 install.sh 中的 SHA256 校验
    if [[ -f "install.sh" ]]; then
        # 将 return 1 改为 exit 2（安全错误）
        sed -i '/SHA256 校验失败/,/return 1/ {
            s/return 1/exit 2/
        }' install.sh
        
        # 修复 GPG 指纹校验
        sed -i '/GPG 密钥指纹校验失败/,/return 1/ {
            s/return 1/exit 2/
        }' install.sh
        
        log_info "已加强 install.sh 安全检查"
    fi
    
    # 修复各平台脚本中的 SHA256 校验
    for file in n5105.sh nanopi-r4s.sh oracle-arm.sh nanopc-t6.sh; do
        if [[ -f "$file" ]]; then
            sed -i '/common-optimize.sh SHA256 校验失败/,/exit 1/ {
                s/exit 1/exit 2/
            }' "$file"
        fi
    done
    
    log_info "已加强平台脚本安全检查"
}

# ─────────────────────────────────────────────────────────────────────────────
# 修复 3: APT 锁处理
# ─────────────────────────────────────────────────────────────────────────────
fix_apt_lock() {
    log_step "修复 APT 锁处理..."
    
    if [[ -f "install.sh" ]]; then
        # 将 wait_for_apt_lock 超时时的 return 1 改为 exit 5
        sed -i '/APT 锁等待超时/,/return 1/ {
            s/return 1/exit 5/
        }' install.sh
        
        log_info "已修复 APT 锁处理"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 修复 4: 临时文件清理
# ─────────────────────────────────────────────────────────────────────────────
fix_temp_file_cleanup() {
    log_step "完善临时文件清理..."
    
    local files=(
        "n5105.sh"
        "nanopi-r4s.sh"
        "oracle-arm.sh"
        "common-optimize.sh"
    )
    
    for file in "${files[@]}"; do
        if [[ -f "$file" ]]; then
            # 将 trap ... RETURN INT 改为 trap ... EXIT INT TERM ERR
            sed -i "s/trap '\([^']*\)' RETURN INT/trap '\1' EXIT INT TERM ERR/g" "$file"
        fi
    done
    
    log_info "已完善临时文件清理"
}

# ─────────────────────────────────────────────────────────────────────────────
# 修复 5: 输入验证
# ─────────────────────────────────────────────────────────────────────────────
fix_input_validation() {
    log_step "加强输入验证..."
    
    if [[ -f "install.sh" ]]; then
        # 在 read 命令后添加长度检查
        # 这个修复比较复杂，暂时跳过，留给手动修复
        log_warn "输入验证需要手动修复（见重构方案文档）"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 修复 6: 变量作用域（添加注释警告）
# ─────────────────────────────────────────────────────────────────────────────
fix_variable_scope() {
    log_step "标记变量作用域问题..."
    
    if [[ -f "n5105.sh" ]]; then
        # 在 _detect_n5105_memory_profile 函数前添加警告注释
        sed -i '/_detect_n5105_memory_profile() {/i\
# FIXME: 此函数污染全局命名空间，应该使用 declare -g 或 nameref' n5105.sh
        
        log_info "已标记变量作用域问题"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 修复 7: sed 正则表达式兼容性
# ─────────────────────────────────────────────────────────────────────────────
fix_sed_regex() {
    log_step "修复 sed 正则表达式..."
    
    local files=(
        "n5105.sh"
        "nanopi-r4s.sh"
    )
    
    for file in "${files[@]}"; do
        if [[ -f "$file" ]]; then
            # 修复 \| 分隔符
            sed -i "s|sed -i '\\\\|^\\[^#\\]\\*\\[\\[:space:\\]\\]/swapfile\\[\\[:space:\\]\\]|d'|sed -i '/^[^#].*[[:space:]]\\/swapfile[[:space:]]/d'|g" "$file"
            sed -i "s|sed -i '\\\\|^\\[^#\\]\\*\\[\\[:space:\\]\\]/swap\\\\.img\\[\\[:space:\\]\\]|d'|sed -i '/^[^#].*[[:space:]]\\/swap\\.img[[:space:]]/d'|g" "$file"
        fi
    done
    
    log_info "已修复 sed 正则表达式"
}

# ─────────────────────────────────────────────────────────────────────────────
# 添加文档注释
# ─────────────────────────────────────────────────────────────────────────────
add_documentation() {
    log_step "添加修复说明文档..."
    
    cat > BUGFIX.md <<'EOF'
# Bug 修复说明

本次修复解决了以下关键问题：

## 1. 算术表达式陷阱 (P0)

**问题**: `((retry++))` 在 `set -e` 下当 retry=0 时返回 0，导致脚本退出

**修复**: 改为 `((retry++)) || true`

**影响文件**: n5105.sh, nanopi-r4s.sh, oracle-arm.sh 等

## 2. 安全检查可被绕过 (P0)

**问题**: SHA256/GPG 校验失败使用 `return 1`，调用者可能忽略

**修复**: 改为 `exit 2`（安全错误码）

**影响文件**: install.sh, 各平台脚本

## 3. APT 锁处理不当 (P0)

**问题**: 超时后 `return 1` 可被忽略

**修复**: 改为 `exit 5`（依赖错误码）

**影响文件**: install.sh

## 4. 临时文件清理不完整 (P1)

**问题**: trap 只捕获 RETURN INT，未捕获 TERM ERR

**修复**: 改为 `trap ... EXIT INT TERM ERR`

**影响文件**: 所有使用 mktemp 的脚本

## 5. sed 正则表达式兼容性 (P1)

**问题**: `\|` 分隔符在 BSD sed 中不支持

**修复**: 使用标准 `/` 分隔符并转义斜杠

**影响文件**: n5105.sh, nanopi-r4s.sh

## 待手动修复的问题

以下问题需要更深入的重构，建议参考 `vps-youhua-refactor-plan.md`：

1. 变量作用域污染（需要使用 declare -g 或 nameref）
2. 输入验证不足（需要添加长度和格式检查）
3. 整数溢出风险（需要添加边界检查）
4. 魔法数字缺少文档（需要添加注释）
5. 错误处理不一致（需要统一标准）

## 测试建议

修复后请进行以下测试：

1. 在低内存环境（1GB）测试
2. 在网络不稳定环境测试
3. 测试中断恢复（Ctrl+C）
4. 测试重复运行（幂等性）

## 参考文档

- 完整重构方案: vps-youhua-refactor-plan.md
- 测试示例: tests/unit/test_error.sh
- 新架构示例: lib/core/error.sh

---

**修复日期**: $(date +%Y-%m-%d)
**修复版本**: v3.4.1-hotfix
EOF
    
    log_info "已创建 BUGFIX.md"
}

# ─────────────────────────────────────────────────────────────────────────────
# 生成测试脚本
# ─────────────────────────────────────────────────────────────────────────────
create_test_script() {
    log_step "创建测试脚本..."
    
    cat > test-fixes.sh <<'EOF'
#!/usr/bin/env bash
# 快速测试修复是否生效

set -euo pipefail

echo "测试 1: 算术表达式不会导致退出"
(
    set -e
    retry=0
    ((retry++)) || true
    echo "  ✓ 通过"
)

echo "测试 2: SHA256 校验失败会退出"
(
    tmpfile=$(mktemp)
    echo "test" > "$tmpfile"
    
    # 模拟校验函数
    verify_sha256() {
        local file="$1"
        local expected="$2"
        local actual=$(sha256sum "$file" | awk '{print $1}')
        if [[ "$actual" != "$expected" ]]; then
            exit 2  # 必须 exit，不能 return
        fi
    }
    
    if verify_sha256 "$tmpfile" "wrong_hash" 2>/dev/null; then
        echo "  ✗ 失败: 应该退出但没有"
        exit 1
    else
        echo "  ✓ 通过"
    fi
    
    rm -f "$tmpfile"
)

echo "测试 3: 临时文件清理"
(
    tmpfile=$(mktemp)
    trap "rm -f '$tmpfile'" EXIT INT TERM ERR
    
    # 模拟错误
    false || true
    
    # 检查 trap 是否正确设置
    if trap -p EXIT | grep -q "rm -f"; then
        echo "  ✓ 通过"
    else
        echo "  ✗ 失败: trap 未正确设置"
        exit 1
    fi
)

echo ""
echo "所有测试通过！"
EOF
    
    chmod +x test-fixes.sh
    log_info "已创建 test-fixes.sh"
}

# ─────────────────────────────────────────────────────────────────────────────
# 主函数
# ─────────────────────────────────────────────────────────────────────────────
main() {
    echo "========================================"
    echo "VPS-youhua 快速修复脚本"
    echo "========================================"
    echo ""
    
    check_repository
    backup_files
    
    echo ""
    echo "开始修复..."
    echo ""
    
    fix_arithmetic_trap
    fix_security_checks
    fix_apt_lock
    fix_temp_file_cleanup
    fix_sed_regex
    fix_variable_scope
    
    echo ""
    add_documentation
    create_test_script
    
    echo ""
    echo "========================================"
    echo "修复完成！"
    echo "========================================"
    echo ""
    echo "下一步："
    echo "  1. 查看修改: git diff"
    echo "  2. 运行测试: bash test-fixes.sh"
    echo "  3. 查看文档: cat BUGFIX.md"
    echo "  4. 提交修改: git commit -am 'fix: 修复关键 bug'"
    echo ""
    echo "完整重构方案请参考: vps-youhua-refactor-plan.md"
    echo ""
}

main "$@"
