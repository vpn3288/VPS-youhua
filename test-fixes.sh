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
