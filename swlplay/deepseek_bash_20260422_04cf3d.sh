#!/bin/bash
# 批量同步子模块（rebase 线性历史）并更新主仓库的子模块指针
# 同时同步主仓库自身从原始上游（upstream）拉取最新代码
# 用法：可以在任意目录执行，脚本会自动进入 ~/immortalwrt
# 注意：会重写子模块的本地及远程历史，请确保本地提交已备份

set -e  # 遇到错误退出

# ==================== 配置区域 ====================
MAIN_REPO_DIR=~/immortalwrt
MAIN_UPSTREAM_URL="https://github.com/immortalwrt/immortalwrt.git"
MY_FORK_URL="git@github.com:你的用户名/immortalwrt.git"   # 请修改为你的 fork 地址

# 子模块初始化脚本（请根据实际路径修改）
INIT_SCRIPT_PATH="~/init-submodules.sh"   # 例如：~/scripts/init-submodules.sh

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

# ==================== 函数：检查子模块是否已初始化 ====================
# 检查第一个子模块的路径是否存在且包含 .git 目录（或 .git 文件）
is_submodules_initialized() {
    if [ ${#modules[@]} -eq 0 ]; then
        return 0  # 没有子模块定义，视为已初始化
    fi
    local first_path="${modules[0]%%:*}"
    if [ -d "$first_path/.git" ] || [ -f "$first_path/.git" ]; then
        return 0  # 已初始化
    else
        return 1  # 未初始化
    fi
}

# ==================== 0. 确保主仓库目录存在且为 Git 仓库 ====================
if [ ! -d "$MAIN_REPO_DIR" ]; then
    echo "目录 $MAIN_REPO_DIR 不存在，正在从自己的仓库克隆: $MY_FORK_URL"
    git clone "$MY_FORK_URL" "$MAIN_REPO_DIR"
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

# ==================== 检查并初始化子模块 ====================
echo ""
echo "=== 检查子模块初始化状态 ==="
if is_submodules_initialized; then
    echo "子模块已初始化，跳过初始化步骤"
else
    echo "子模块尚未初始化，开始执行初始化脚本: $INIT_SCRIPT_PATH"
    if [ -f "$INIT_SCRIPT_PATH" ]; then
        bash "$INIT_SCRIPT_PATH"
    else
        echo "警告：初始化脚本 $INIT_SCRIPT_PATH 不存在，将执行默认的 git submodule update --init --recursive"
        git submodule update --init --recursive
    fi
    echo "子模块初始化完成"
fi

# ==================== 1. 同步主仓库自身（从原始上游更新） ====================
echo ""
echo "=== 同步主仓库自身（从上游 $MAIN_UPSTREAM_URL）==="

# 拉取上游更新
git fetch upstream

# 确保当前在 master 分支（可根据需要修改为 main）
current_branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$current_branch" != "master" ]; then
    if git show-ref --verify --quiet refs/heads/master; then
        git checkout master
    else
        git checkout -b master
    fi
fi

# 检测上游默认分支
upstream_branch=""
head_ref=$(git ls-remote --symref upstream HEAD | head -1 | awk '{print $2}' | sed 's|refs/heads/||')
if [ -n "$head_ref" ]; then
    upstream_branch="$head_ref"
else
    if git ls-remote --heads upstream main | grep -q refs/heads/main; then
        upstream_branch="main"
    elif git ls-remote --heads upstream master | grep -q refs/heads/master; then
        upstream_branch="master"
    fi
fi

if [ -z "$upstream_branch" ]; then
    echo "错误：无法确定上游默认分支，跳过主仓库同步"
else
    echo "上游默认分支: $upstream_branch"
    # 暂存本地未提交的修改
    stashed_main=false
    if ! git diff --quiet || ! git diff --cached --quiet; then
        echo "发现未提交的修改，正在 stash 保存..."
        git stash push -m "自动 stash 于 $(date)" && stashed_main=true
    fi

    # 执行 rebase
    echo "正在 rebase 到 upstream/$upstream_branch (冲突时自动采用上游版本)..."
    if git rebase "upstream/$upstream_branch" -X theirs; then
        echo "主仓库 rebase 成功"
    else
        echo "错误：rebase 冲突无法自动解决，请手动处理"
        git rebase --abort
        [ "$stashed_main" = true ] && git stash pop
        exit 1
    fi

    # 强制推送到 origin（你的 fork）
    echo "强制推送到 origin/master..."
    git push origin master --force-with-lease

    # 恢复 stash
    [ "$stashed_main" = true ] && git stash pop
fi

# ==================== 2. 同步每个子模块 ====================
echo ""
for entry in "${modules[@]}"; do
  path="${entry%%:*}"
  upstream_url="${entry#*:}"
  echo "=== 线性同步 $path 从 $upstream_url ==="

  cd "$path" || { echo "错误：无法进入 $path，跳过"; continue; }

  # 确保工作区干净（暂存未提交的修改）
  stashed=false
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "发现未提交的修改，正在 stash 保存..."
    git stash push -m "自动 stash 于 $(date)" || { echo "stash 失败，跳过 $path"; cd - > /dev/null; continue; }
    stashed=true
  fi

  # 确保 upstream 远程存在
  if ! git remote | grep -q upstream; then
    echo "添加 upstream 远程..."
    git remote add upstream "$upstream_url"
  fi

  # 拉取上游
  echo "拉取上游更新..."
  git fetch upstream

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

  # 检测上游默认分支
  upstream_branch=""
  head_ref=$(git ls-remote --symref upstream HEAD | head -1 | awk '{print $2}' | sed 's|refs/heads/||')
  if [ -n "$head_ref" ]; then
    upstream_branch="$head_ref"
    echo "检测到上游默认分支: $upstream_branch"
  else
    if git ls-remote --heads upstream main | grep -q refs/heads/main; then
      upstream_branch="main"
    elif git ls-remote --heads upstream master | grep -q refs/heads/master; then
      upstream_branch="master"
    fi
  fi

  if [ -z "$upstream_branch" ]; then
    echo "错误：无法确定上游的默认分支（尝试过 main/master），跳过 $path"
    cd - > /dev/null
    continue
  fi

  echo "当前分支: master，上游分支: $upstream_branch"

  # 执行 rebase，冲突时自动采用上游版本
  echo "正在 rebase 到 upstream/$upstream_branch (冲突时自动采用上游版本)..."
  if git rebase "upstream/$upstream_branch" -X ours; then
    echo "rebase 成功"
  else
    echo "错误：rebase 冲突无法自动解决，跳过 $path"
    git rebase --abort
    cd - > /dev/null
    continue
  fi

  # 强制推送到你的 fork（origin）
  echo "强制推送到 origin/master..."
  git push origin master --force-with-lease

  # 恢复 stash
  if [ "$stashed" = true ]; then
    echo "恢复之前 stash 的修改..."
    git stash pop || echo "警告：stash pop 出现冲突，请手动处理"
  fi

  cd "$MAIN_REPO" > /dev/null
  echo "✅ $path 同步完成"
done

# ==================== 3. 更新主仓库的子模块指针 ====================
echo ""
echo "=== 更新主仓库的子模块指针 ==="

# 获取所有子模块的路径
submodule_paths=$(git config --file .gitmodules --get-regexp path | awk '{print $2}')
if [ -n "$submodule_paths" ]; then
    echo "暂存子模块指针变更:"
    echo "$submodule_paths"
    git add $submodule_paths
else
    echo "没有找到子模块配置，跳过 add"
fi

# 查看变更
echo "=== 主仓库状态 ==="
git status

# 提交变更（如果有）
if git diff --cached --quiet; then
    echo "没有子模块指针变更需要提交"
else
    git commit -m "Update submodule pointers after batch sync [skip ci]"
    echo "=== 推送到主仓库远程 ==="
    git push origin master
fi