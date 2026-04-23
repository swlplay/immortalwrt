#!/bin/bash
# 功能：遍历所有子模块，如有本地变更（包括未跟踪文件），则暂存后从 origin 拉取最新代码（rebase），再强制推送
# 注意：不会拉取原始上游（upstream），只处理 origin
# 用法：在主仓库目录（~/immortalwrt）下执行，或任意目录执行（脚本会自动进入主仓库）

set -e

MAIN_REPO="$HOME/immortalwrt"
COMMIT_MSG="swlplay $(date '+%Y-%m-%d %H:%M:%S') Update submodule"
POINTER_COMMIT_MSG="swlplay $(date '+%Y-%m-%d %H:%M:%S') Update submodule pointers [skip ci]"

cd "$MAIN_REPO" || { echo "主仓库不存在: $MAIN_REPO"; exit 1; }

echo "=== 开始处理所有子模块（从 origin 拉取并 rebase，保留本地修改） ==="

submodule_paths=$(git config --file .gitmodules --get-regexp path | awk '{print $2}')

if [ -z "$submodule_paths" ]; then
    echo "没有找到任何子模块配置"
    exit 0
fi

changed_submodules=()

for path in $submodule_paths; do
    echo ""
    echo "--- 处理子模块: $path ---"

    if ! git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
        echo "警告：子模块 $path 未初始化，跳过"
        continue
    fi

    cd "$path" || continue

    # 检查是否有任何变更（包括未跟踪文件）
    if ! git status --porcelain | grep -q .; then
        echo "没有发现任何需要提交的变更（包括未跟踪文件），跳过"
        cd "$MAIN_REPO" > /dev/null
        continue
    fi

    echo "发现本地变更（包括未跟踪文件），准备从 origin 拉取最新代码..."

    current_branch=$(git rev-parse --abbrev-ref HEAD)
    echo "当前分支: $current_branch"

    # 暂存本地未提交的修改（包括未跟踪文件）
    stashed=false
    echo "暂存本地未提交的修改（包括未跟踪文件）..."
    if git stash push --include-untracked -m "自动 stash 于 $(date)"; then
        stashed=true
        echo "已暂存修改（包含未跟踪文件）"
    else
        echo "警告：stash 失败，可能没有可暂存的内容，继续执行"
    fi

    # 从 origin 拉取，使用 rebase 并自动采用本地修改（-X ours）解决冲突
    echo "从 origin 拉取 $current_branch 并 rebase（冲突时保留本地修改）..."
    if git pull --rebase origin "$current_branch" -X ours; then
        echo "拉取并 rebase 成功"
    else
        echo "错误：拉取或 rebase 失败（可能无法自动解决的冲突），放弃本次处理"
        git rebase --abort 2>/dev/null || true
        if [ "$stashed" = true ]; then
            git stash pop || echo "警告：stash pop 失败，请手动恢复"
        fi
        cd "$MAIN_REPO" > /dev/null
        continue
    fi

    # 恢复 stash
    if [ "$stashed" = true ]; then
        echo "恢复之前暂存的修改..."
        if git stash pop; then
            echo "恢复成功"
        else
            echo "警告：stash pop 出现冲突，请手动解决。工作区已包含您的修改和拉取后的代码。"
        fi
    fi

    # 再次检查是否有变更（包括未跟踪文件）
    if ! git status --porcelain | grep -q .; then
        echo "没有新的变更需要提交（包括未跟踪文件），跳过推送"
        cd "$MAIN_REPO" > /dev/null
        continue
    fi

    # 添加所有变更并提交
    echo "添加所有变更并提交..."
    git add -A
    if git commit -m "$COMMIT_MSG"; then
        echo "本地提交成功"
    else
        echo "警告：提交失败（可能没有变更），跳过推送"
        cd "$MAIN_REPO" > /dev/null
        continue
    fi

    # 强制推送到 origin
    echo "强制推送到 origin/$current_branch..."
    if git push origin "$current_branch" --force-with-lease; then
        echo "推送成功"
        changed_submodules+=("$path")
    else
        echo "错误：推送失败，请检查网络或权限"
    fi

    cd "$MAIN_REPO" > /dev/null
done

# 更新主仓库的子模块指针
echo ""
echo "=== 更新主仓库的子模块指针 ==="

if [ ${#changed_submodules[@]} -eq 0 ]; then
    echo "没有子模块的指针发生变化，跳过"
else
    git add "${changed_submodules[@]}"
    if git diff --cached --quiet; then
        echo "子模块指针没有实际变化，跳过提交"
    else
        git commit -m "$POINTER_COMMIT_MSG"
        echo "推送到主仓库 origin/master"
        git push origin master
    fi
fi

echo "=== 所有操作完成 ==="