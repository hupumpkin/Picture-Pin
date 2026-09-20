#!/bin/bash
# 生成交付快照清单：完整文件列表 + SHA-256。
#
# 用法: scripts/manifest.sh          # 写入 BASELINE-A.sha256
#       scripts/manifest.sh --check  # 只校验，不写文件
#
# ## 为什么不用 git 提交号当标识
#
# 路线图 §6 明确要求日常迭代**不提交**，所以本批次没有提交号可用。审核要求
# "停止并发编辑并提供一个不可变标识"，二者只能取后者：把每个文件的哈希写下来，
# 审核方据此确认他读的和我说的确实是同一份东西。
#
# 这个文件是**证据**，不是版本号——它不代表发布，也不进任何版本序列。
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
manifest="$project_dir/BASELINE-A.sha256"
mode="${1:-write}"

cd "$project_dir"

# 排除构建产物（.build/ 是 SPM 的，build/ 是打包输出与截图）。
# **也要排除清单自己**：列出自己的哈希是不可能的任务，而重新生成时它已经存在，
# 不排除就会混进去一条永远对不上的记录。
# 排序保证两次运行的输出逐字节一致——清单本身不可复现的话就没有意义。
files=$(find . \
    -type d \( -name '.build' -o -name 'build' \) -prune -o \
    -name '.DS_Store' -prune -o \
    -name 'BASELINE-A.sha256' -prune -o \
    -type f -print \
    | sed 's|^\./||' | LC_ALL=C sort)

count=$(printf '%s\n' "$files" | wc -l | tr -d ' ')

if [ "$mode" = "--check" ]; then
    if [ ! -f "$manifest" ]; then
        echo "清单不存在：$manifest" >&2
        exit 1
    fi

    # ## 先比对文件集合，再比对哈希
    #
    # `shasum -c` 只会检查**清单里列到的**文件，磁盘上多出来的文件它一无所知。
    # 所以"哈希全部匹配"根本不等于"交付物没变"——审核期间新加一个源文件，
    # 校验照样全绿。这个清单的用途是不可变交付边界，那就必须两边都比。
    #
    # 第一版只有下面那一步，被独立审核指出（2026-09-17），这是修复。
    listed=$(grep -v '^#' "$manifest" | sed 's/^[0-9a-f]\{64\}  //' | LC_ALL=C sort)
    if [ "$listed" != "$files" ]; then
        echo "❌ 清单与磁盘上的文件不一致：" >&2
        comm -13 <(printf '%s\n' "$listed") <(printf '%s\n' "$files") \
            | sed 's/^/   未登记（磁盘上有，清单里没有）：/' >&2
        comm -23 <(printf '%s\n' "$listed") <(printf '%s\n' "$files") \
            | sed 's/^/   已消失（清单里有，磁盘上没有）：/' >&2
        echo "   重新生成：scripts/manifest.sh" >&2
        exit 1
    fi

    if shasum -a 256 -c "$manifest" --status 2>/dev/null; then
        echo "✅ 清单校验通过（$count 个文件，文件集合与哈希均一致）"
    else
        echo "❌ 清单校验失败：" >&2
        shasum -a 256 -c "$manifest" 2>&1 | grep -v ': OK$' >&2
        exit 1
    fi
    exit 0
fi

{
    echo "# Pin 原生 · 批次 A 交付快照"
    echo "# 生成时间：$(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "# 文件数：$count"
    echo "# 分支：$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '（非 git 工作区）')"
    echo "# 基线提交：$(git rev-parse --short HEAD 2>/dev/null || echo '（无）')"
    echo "# 校验：scripts/manifest.sh --check"
    echo "#"
    # shasum 的 -c 要求 "哈希  文件名" 两空格分隔，恰好也是 sha256sum 的格式。
    printf '%s\n' "$files" | xargs shasum -a 256
} > "$manifest"

echo "$manifest"
echo "  文件数: $count"
