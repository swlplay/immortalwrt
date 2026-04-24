#!/bin/bash
# 批量同步子模块（rebase 线性历史）并更新主仓库的子模块指针
# 同时同步主仓库自身从原始上游（upstream）拉取最新代码
# 用法：可以在任意目录执行，脚本会自动处理 ~/immortalwrt
# 注意：会重写子模块的本地及远程历史，请确保本地提交已备份

set -Eeuo pipefail

# 获取脚本所在目录的绝对路径（即 ~/）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==================== 配置区域 ====================
MAIN_REPO_DIR="$HOME/immortalwrt"
MAIN_UPSTREAM_URL="https://github.com/immortalwrt/immortalwrt.git"
MY_FORK_URL="git@github.com:swlplay/immortalwrt.git"   # 请修改为你的 fork 地址

# 辅助脚本路径（与主脚本同目录）
INIT_SCRIPT="$SCRIPT_DIR/zckcsh.sh"
SUB_PUSH_SCRIPT="$SCRIPT_DIR/zckpush.sh"   # 子仓库推送脚本与主脚本同目录

# 定义子模块路径和对应的上游 URL
modules=(
  "swlplay/package/pingdongyi:https://github.com/pingdongyi/actionbased-openwrt-packages.git"
  "swlplay/package/xuanranran:https://github.com/xuanranran/openwrt-package.git"
  "swlplay/package/chenmozhijin:https://github.com/chenmozhijin/turboacc.git"
  "swlplay/package/sirpdboy/luci-app-timecontrol:https://github.com/sirpdboy/luci-app-timecontrol.git"
  "swlplay/package/sirpdboy/luci-app-advancedplus:https://github.com/sirpdboy/luci-app-advancedplus.git"
  "swlplay/package/sirpdboy/luci-app-ddns-go:https://github.com/sirpdboy/luci-app-ddns-go.git"
  "swlplay/package/sirpdboy/luci-app-netspeedtest:https://github.com/sirpdboy/netspeedtest.git"
  "swlplay/package/kiddin9:https://github.com/kiddin9/openwrt-thunder.git"
)

# ==================== 0. 确保主仓库目录存在且为 Git 仓库 ====================
if [ ! -d "$MAIN_REPO_DIR" ]; then
    echo "目录 $MAIN_REPO_DIR 不存在，正在从自己的仓库克隆: $MY_FORK_URL"
    if ! git clone "$MY_FORK_URL" "$MAIN_REPO_DIR"; then
        echo "错误：克隆失败，请检查网络、SSH 密钥或仓库地址是否正确"
        exit 1
    fi
    cd "$MAIN_REPO_DIR"
    echo "克隆完成，当前位于 $(pwd)"
    # 添加 upstream 远程（指向原始仓库）
    if ! git remote | grep -q upstream; then
        echo "添加 upstream 远程: $MAIN_UPSTREAM_URL"
        git remote add upstream "$MAIN_UPSTREAM_URL"
    fi
elif [ ! -d "$MAIN_REPO_DIR/.git" ]; then
    echo "错误：$MAIN_REPO_DIR 存在但不是 Git 仓库，请手动处理"
    exit 1
else
    cd "$MAIN_REPO_DIR"
    echo "已进入主仓库目录: $(pwd)"
    # 确保 upstream 远程存在
    if ! git remote | grep -q upstream; then
        echo "添加 upstream 远程: $MAIN_UPSTREAM_URL"
        git remote add upstream "$MAIN_UPSTREAM_URL"
    fi
fi

MAIN_REPO=$(pwd)
# ==================== 1. 同步主仓库自身（从原始上游更新） ====================
echo ""
echo "=== 同步主仓库自身（从上游 $MAIN_UPSTREAM_URL）==="

cd "$MAIN_REPO"

# 预先获取上游默认分支（只做轻量查询，不下载任何对象）
upstream_branch=""
head_ref=$(git ls-remote --symref upstream HEAD | head -1 | awk '{print $2}' | sed 's|refs/heads/||')
if [ -n "$head_ref" ]; then
    upstream_branch="$head_ref"
else
    # 降级检测常见分支名：main -> master -> luci
    if git ls-remote --heads upstream main | grep -q refs/heads/main; then
        upstream_branch="main"
    elif git ls-remote --heads upstream master | grep -q refs/heads/master; then
        upstream_branch="master"
    elif git ls-remote --heads upstream luci | grep -q refs/heads/luci; then
        upstream_branch="luci"
    fi
fi

if [ -z "$upstream_branch" ]; then
    echo "错误：无法确定上游默认分支，跳过主仓库同步"
else
    echo "上游默认分支: $upstream_branch"

    # 仅拉取上游默认分支（完整历史，不使用浅克隆）
    echo "只拉取上游分支: $upstream_branch"
    git fetch upstream "$upstream_branch"

    current_branch=$(git rev-parse --abbrev-ref HEAD)
    if [ "$current_branch" != "master" ]; then
        if git show-ref --verify --quiet refs/heads/master; then
            git checkout master
        else
            git checkout -b master
        fi
    fi

    # === 绝对可靠的 stash 检测：比较 stash 数量 ===
    old_stash_count=$(git stash list | wc -l)
    if [ -n "$(git status --porcelain)" ]; then
        echo "发现本地修改（包括未跟踪文件），正在 stash 保存..."
        # 尝试 stash，无论成功与否都继续（但通过数量判断）
        git stash push --include-untracked -m "自动 stash 于 $(date)" > /dev/null 2>&1 || true
        new_stash_count=$(git stash list | wc -l)
        if [ $new_stash_count -gt $old_stash_count ]; then
            stashed_main=true
            echo "已暂存本地修改（包含未跟踪文件）"
        else
            stashed_main=false
            echo -e "\033[0;31m警告：没有实际可 stash 的修改（可能是子模块修改或未跟踪文件问题），跳过\033[0m"
        fi
    else
        stashed_main=false
        echo "没有发现本地修改"
    fi

    # 执行 rebase
    echo "正在 rebase 到 upstream/$upstream_branch (冲突时自动采用上游版本)..."
    if git rebase "upstream/$upstream_branch" -X theirs; then
        echo "主仓库 rebase 成功"
    else
        echo "错误：rebase 冲突无法自动解决，请手动处理"
        git rebase --abort
        if [ "$stashed_main" = true ]; then
            git stash pop
        fi
        exit 1
    fi

    # 修复：先 fetch origin/master 以更新本地跟踪，再使用 --force-with-lease
    echo "强制推送到 origin/master..."
    git fetch origin master
    git push origin master --force-with-lease

    # 恢复 stash（仅当真正 stash 了内容）
    if [ "$stashed_main" = true ]; then
        if git stash pop; then
            echo "已恢复主仓库之前的本地修改"
        else
            echo "警告：stash pop 出现冲突，请手动处理"
        fi
    else
        echo "主仓库没有本地修改需要恢复"
    fi
fi

# ==================== 函数：检查子模块是否已初始化 ====================
is_submodules_initialized() {
    if [ ${#modules[@]} -eq 0 ]; then
        return 0
    fi
    local first_path="${modules[0]%%:*}"
    if [ -d "$first_path/.git" ] || [ -f "$first_path/.git" ]; then
        return 0
    else
        return 1
    fi
}


# ==================== 检查并初始化子模块 ====================
echo ""
echo "=== 检查子模块初始化状态 ==="
if is_submodules_initialized; then
    echo "子模块已初始化，跳过初始化步骤"
else
    echo "子模块尚未初始化，开始执行初始化脚本: $INIT_SCRIPT"
    if [ -f "$INIT_SCRIPT" ]; then
        cd "$MAIN_REPO"
        bash "$INIT_SCRIPT"
        cd - > /dev/null
    else
        echo "警告：初始化脚本 $INIT_SCRIPT 不存在，将执行默认的 git submodule update --init --recursive"
        cd "$MAIN_REPO"
        git submodule update --init --recursive
        cd - > /dev/null
    fi
    echo "子模块初始化完成"
fi


# ==================== 2. 同步每个子模块 ====================
echo ""
for entry in "${modules[@]}"; do
  path="${entry%%:*}"
  upstream_url="${entry#*:}"
  echo "=== 线性同步 $path 从 $upstream_url ==="

  cd "$MAIN_REPO/$path" || { echo "错误：无法进入 $path，跳过"; continue; }

  # === 绝对可靠的 stash 检测：比较 stash 数量 ===
  old_stash_count=$(git stash list | wc -l)
  if [ -n "$(git status --porcelain)" ]; then
      echo "发现本地修改（包括未跟踪文件），正在 stash 保存..."
      git stash push --include-untracked -m "自动 stash 于 $(date)" > /dev/null 2>&1 || true
      new_stash_count=$(git stash list | wc -l)
      if [ $new_stash_count -gt $old_stash_count ]; then
          stashed=true
          echo "已暂存本地修改（包含未跟踪文件）"
      else
          stashed=false
          echo -e "\033[0;31m警告：没有实际可 stash 的修改（可能是子模块修改或未跟踪文件问题），跳过\033[0m"
      fi
  else
      stashed=false
      echo "没有发现本地修改"
  fi

  # 确保 upstream 远程存在
  if ! git remote | grep -q upstream; then
    echo "添加 upstream 远程..."
    git remote add upstream "$upstream_url"
  fi

  # 预先获取子模块上游的默认分支（只做轻量查询）
  upstream_branch=""
  head_ref=$(git ls-remote --symref upstream HEAD | head -1 | awk '{print $2}' | sed 's|refs/heads/||')
  if [ -n "$head_ref" ]; then
    upstream_branch="$head_ref"
    echo "检测到上游默认分支: $upstream_branch"
  else
    # 降级检测常见分支名：main -> master -> luci
    if git ls-remote --heads upstream main | grep -q refs/heads/main; then
      upstream_branch="main"
    elif git ls-remote --heads upstream master | grep -q refs/heads/master; then
      upstream_branch="master"
    elif git ls-remote --heads upstream luci | grep -q refs/heads/luci; then
      upstream_branch="luci"
    fi
  fi

  if [ -z "$upstream_branch" ]; then
    echo "错误：无法确定上游的默认分支（尝试过 main/master/luci），跳过 $path"
    cd "$MAIN_REPO" > /dev/null
    continue
  fi

  # 仅拉取上游默认分支（完整历史，不使用浅克隆）
  echo "只拉取子模块 $path 的上游分支: $upstream_branch"
  git fetch upstream "$upstream_branch"

  # 确保本地分支为 master（若不存在则创建）
  if git rev-parse --abbrev-ref HEAD | grep -q 'HEAD'; then
    if git show-ref --verify --quiet refs/heads/master; then
      git checkout master
    else
      git checkout -b master
    fi
  fi
  current_branch=$(git rev-parse --abbrev-ref HEAD)
  if [ "$current_branch" != "master" ]; then
    echo "当前分支不是 master，尝试切换到 master..."
    if git show-ref --verify --quiet refs/heads/master; then
      git checkout master
    else
      git checkout -b master
    fi
  fi

  echo "当前分支: master，上游分支: $upstream_branch"

  # 执行 rebase，冲突时自动采用上游版本（ours 表示保留本地修改）
  echo "正在 rebase 到 upstream/$upstream_branch (冲突时自动采用上游版本)..."
  if git rebase "upstream/$upstream_branch" -X ours; then
    echo "rebase 成功"
  else
    echo "错误：rebase 冲突无法自动解决，跳过 $path"
    git rebase --abort
    cd "$MAIN_REPO" > /dev/null
    continue
  fi

  # 强制推送到你的 fork（origin）
  echo "强制推送到 origin/master..."
  git push origin master --force-with-lease

  # 恢复 stash（仅当真正 stash 了内容）
  if [ "$stashed" = true ]; then
    echo "恢复之前 stash 的修改..."
    if git stash pop; then
        echo "已成功恢复 $path 中的本地修改"
    else
        echo "警告：$path 中的 stash pop 出现冲突，请手动处理"
    fi
  else
    echo "$path 没有本地修改需要恢复"
  fi

  cd "$MAIN_REPO" > /dev/null
  echo "✅ $path 同步完成"
done

# ==================== 可选：执行子仓库推送脚本 ====================
echo ""
echo "=== 是否执行子仓库推送脚本（用于推送本地未提交的修改）？==="
read -p "输入 y 执行 $SUB_PUSH_SCRIPT，输入 n 跳过: " -r run_sub_push
if [[ "$run_sub_push" =~ ^[Yy]$ ]]; then
    if [ -f "$SUB_PUSH_SCRIPT" ]; then
        echo "正在执行子仓库推送脚本: $SUB_PUSH_SCRIPT"
        bash "$SUB_PUSH_SCRIPT" || echo "警告：子仓库推送脚本执行失败，继续执行后续步骤"
    else
        echo "错误：子仓库推送脚本 $SUB_PUSH_SCRIPT 不存在，跳过"
    fi
else
    echo "跳过子仓库推送脚本"
fi

# ==================== 3. 更新主仓库的变更（合并子模块指针与主仓库文件） ====================
echo ""
echo "=== 更新主仓库的变更 ==="

cd "$MAIN_REPO"

# 获取子模块路径
submodule_paths=$(git config --file .gitmodules --get-regexp path | awk '{print $2}' || true)

# 询问是否提交主仓库自身的未跟踪/修改文件
echo ""
echo "=== 处理主仓库自身的未跟踪/修改文件 ==="
commit_main=false
read -p "是否提交主仓库的未跟踪/修改文件？(y/n): " -r main_choice
if [[ "$main_choice" =~ ^[Yy]$ ]]; then
    commit_main=true
    echo "将添加主仓库所有变更（git add -A）。"
else
    echo "跳过主仓库文件提交。"
fi

# 判断是否有任何变更（子模块指针或主仓库文件）
has_changes=false
if [ -n "$submodule_paths" ]; then
    # 检查子模块指针是否有变化（索引区）
    if ! git diff --cached --quiet; then
        has_changes=true
    fi
fi
if [ "$commit_main" = true ]; then
    # 检查主仓库是否有未跟踪/修改的文件（工作区）
    if [ -n "$(git status --porcelain)" ]; then
        has_changes=true
    fi
fi

if [ "$has_changes" = false ]; then
    echo "没有子模块指针变更，也未选择提交主仓库文件，无需提交。"
else
    # 添加子模块指针
    if [ -n "$submodule_paths" ]; then
        echo "暂存子模块指针变更:"
        echo "$submodule_paths"
        git add $submodule_paths
    fi

    # 如果用户选择提交主仓库文件，则添加所有变更（包括未跟踪、修改、删除）
    if [ "$commit_main" = true ]; then
        git add -A
        echo "已添加主仓库所有变更。"
    fi

    # 再次检查暂存区是否有实际内容
    if git diff --cached --quiet; then
        echo "暂存区没有实际变更，跳过提交。"
    else
        # 询问是否启动 CI 编译（决定 commit message 是否带 [skip ci]）
        echo ""
        echo "是否启动 CI 编译？"
        read -p "输入 y 以启动编译（不添加 [skip ci]），输入 n 以跳过编译（添加 [skip ci]）: " -r ci_choice
        if [[ "$ci_choice" =~ ^[Yy]$ ]]; then
            COMMIT_MSG="swlplay $(date '+%Y-%m-%d %H:%M:%S') Update submodule pointers and main repo"
            echo "将启动编译（未添加 [skip ci]）。"
        else
            COMMIT_MSG="swlplay $(date '+%Y-%m-%d %H:%M:%S') Update submodule pointers and main repo [skip ci]"
            echo "将跳过编译（已添加 [skip ci]）。"
        fi

        git commit -m "$COMMIT_MSG"

        # 最终确认推送
        echo ""
        read -p "是否确定推送到 origin/master？(y/n): " -r push_confirm
        if [[ "$push_confirm" =~ ^[Yy]$ ]]; then
            echo "=== 推送到主仓库远程 ==="
            git push origin master
            echo "推送完成。"
        else
            echo "已取消推送，本地 commit 仍保留。"
        fi
    fi
fi

echo ""
echo "=== 本地修改状态提醒 ==="
echo "脚本已尽力保留你在子模块中的本地修改（通过 stash/pop，包含未跟踪文件）。"
echo "如果 git status 显示某个子模块有 '修改的内容'，说明该子模块内仍有未提交的变更。"
echo "你可以选择："
echo "  1) 进入子模块目录，执行 'git add' 和 'git commit' 提交这些修改"
echo "  2) 进入子模块目录，执行 'git restore <文件>' 丢弃它们"
echo "  3) 如果这些修改是临时的，也可以直接忽略，不影响后续编译"
echo ""
echo "要查看具体是哪些子模块有未提交修改，请运行："
echo "  cd $MAIN_REPO && git status --ignore-submodules=all"
echo "  （然后对每个子模块进入查看 git status）"
echo ""

echo "=== 脚本执行完成 ==="
