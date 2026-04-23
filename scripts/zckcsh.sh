#!/bin/bash
set -e

cd ~/immortalwr

echo "== 初始化所有子模块 =="
git submodule update --init --recursive

declare -A SUBMODULES=(
    ["swlplay/package/xuanranran"]="https://github.com/xuanranran/openwrt-package.git"
    ["swlplay/package/sirpdboy/luci-app-timecontrol"]="https://github.com/sirpdboy/luci-app-timecontrol.git"
    ["swlplay/package/sirpdboy/luci-app-netspeedtest"]="https://github.com/sirpdboy/netspeedtest.git"
    ["swlplay/package/sirpdboy/luci-app-ddns-go"]="https://github.com/sirpdboy/luci-app-ddns-go.git"
    ["swlplay/package/sirpdboy/luci-app-advancedplus"]="https://github.com/sirpdboy/luci-app-advancedplus.git"
    ["swlplay/package/pingdongyi"]="https://github.com/pingdongyi/actionbased-openwrt-packages.git"
    ["swlplay/package/kiddin9"]="https://github.com/kiddin9/openwrt-thunder.git"
    ["swlplay/package/chenmozhijin"]="https://github.com/chenmozhijin/turboacc.git"
)

declare -A SPARSE_PATTERNS=(
    ["swlplay/package/xuanranran"]='
/*
!/*/
/clouddrive2/
/luci-app-clouddrive2/
/luci-app-openclash/
/luci-app-openlist2/
/luci-app-qbittorrent/
/luci-app-smartdns/
/luci-app-unblockneteasemusic/
/luci-app-unishare/
/luci-app-wolplus/
/openlist2/
/qbittorrent/
/rblibtorrent/
/smartdns/
/unishare/
/webdav2/
'
    ["swlplay/package/pingdongyi"]='
/*
!/*/
/luci-app-nginx/
/luci-app-systools/
/luci-app-tailscale/
/luci-app-tcpdump/
/luci-app-verysync/
/luci-lib-iform/
/luci-lib-taskd/
/luci-lib-xterm/
/speedtestcli/
/taskd/
/verysync/
'
)

echo "== 为子模块添加 upstream remote =="
for path in "${!SUBMODULES[@]}"; do
    upstream_url="${SUBMODULES[$path]}"
    if [ -d "$path" ]; then
        echo "处理子模块: $path"
        if ! git -C "$path" remote | grep -q "^upstream$"; then
            git -C "$path" remote add upstream "$upstream_url"
            echo "  已添加 upstream -> $upstream_url"
        else
            echo "  upstream 已存在，跳过添加"
        fi
        git -C "$path" config remote.upstream.fetch "+refs/heads/*:refs/remotes/upstream/*"
    else
        echo "警告: 子模块路径不存在: $path"
    fi
done

echo "== 启用稀疏检出 =="
for path in "${!SPARSE_PATTERNS[@]}"; do
    if [ -d "$path" ]; then
        echo "为 $path 配置稀疏检出"
        git -C "$path" config core.sparseCheckout true
        
        # 获取子模块的实际 Git 目录
        actual_git_dir=$(git -C "$path" rev-parse --git-dir)
        mkdir -p "$actual_git_dir/info"
        
        patterns="${SPARSE_PATTERNS[$path]}"
        echo "$patterns" | sed '/^$/d' > "$actual_git_dir/info/sparse-checkout"
        
        git -C "$path" read-tree -mu HEAD
        echo "  已应用稀疏检出模式"
    else
        echo "警告: 稀疏检出子模块路径不存在: $path"
    fi
done

echo "== 将所有子模块的 origin 转换为 SSH 格式（仅当需要时） =="
git submodule foreach --recursive '
    current_url=$(git remote get-url origin)
    new_url=$(echo "$current_url" | sed "s|https://github.com/|git@github.com:|")
    if [ "$current_url" != "$new_url" ]; then
        echo "转换子模块 $name: $current_url -> $new_url"
        git remote set-url origin "$new_url"
    else
        echo "子模块 $name 的 origin 已是 SSH 格式，无需转换"
    fi
'

echo "== 子模块初始化完成 =="
