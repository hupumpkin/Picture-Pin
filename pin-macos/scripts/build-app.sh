#!/bin/bash
# 组装可双击运行的 Pin.app。
#
# 用法: scripts/build-app.sh [debug|release] [production|cc|codex|cc-debug]
#       默认：release production
#
# 为什么要按 profile 打不同的包：双击启动的 .app 拿不到环境变量，
# 所以"哪个包进哪个数据目录"只能写进 bundle identifier。
# `AppEnvironment.resolve` 认最后一段：com.pin.native.dev-cc / .dev-codex，
# 其余的（含 com.pin.native）一律当正式版。
#
# 不这样做的话，Codex 双击一个普通 Pin.app 就会落进 Claude 的 dev-cc 目录。
#
# ## cc-debug 为什么单独一个 profile
#
# 演示素材（`DevelopmentCommands`）整个包在 `#if DEBUG` 里，正式包里没有。
# 于是"让人亲眼看一下带素材的画布"这件事**只能**用 debug 包做——而它和
# `cc` 用同一个 `app_dir`，实测一次就把正式包覆盖掉了（已经发生过两次）。
# 给它单开一个输出路径，两个包就能同时存在。
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
config="${1:-release}"
profile="${2:-production}"

case "$profile" in
    production)
        bundle_id="com.pin.native"
        display_name="Pin"
        app_dir="$project_dir/build/Pin.app"
        data_hint="~/Library/Application Support/Pin/"
        ;;
    cc)
        bundle_id="com.pin.native.dev-cc"
        display_name="Pin (Claude)"
        app_dir="$project_dir/build/Pin-cc.app"
        data_hint="~/Library/Application Support/Pin/dev-cc/"
        ;;
    codex)
        bundle_id="com.pin.native.dev-codex"
        display_name="Pin (Codex)"
        app_dir="$project_dir/build/Pin-codex.app"
        data_hint="~/Library/Application Support/Pin/dev-codex/"
        ;;
    cc-debug)
        # 与 cc 同一个数据目录（bundle id 完全相同）：它就是"同一个 Claude 工作区
        # 的实测包"，不该多出一个 dev-cc-debug 目录来分叉运行数据。
        bundle_id="com.pin.native.dev-cc"
        display_name="Pin (Claude 实测)"
        app_dir="$project_dir/build/Pin-cc-debug.app"
        data_hint="~/Library/Application Support/Pin/dev-cc/"
        ;;
    *)
        echo "未知 profile: $profile（可用：production / cc / codex / cc-debug）" >&2
        exit 2
        ;;
esac

# cc-debug 存在的唯一理由是演示素材，而那只在 debug 构建里。
# 允许 `release cc-debug` 会产出一个名字叫"实测"却不含素材的包——那种包
# 以后一定会有人拿去"实测"，然后奇怪为什么画布是空的。直接拦掉。
if [ "$profile" = "cc-debug" ] && [ "$config" != "debug" ]; then
    echo "cc-debug 只用于 debug 构建（演示素材不在正式包里）" >&2
    exit 2
fi

cd "$project_dir"
swift build -c "$config"

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS"
cp "$project_dir/.build/$config/PinNative" "$app_dir/Contents/MacOS/PinNative"
cp "$project_dir/AppBundle/Info.plist" "$app_dir/Contents/Info.plist"

# 直接改 plist，不再维护三份内容几乎相同的文件——那样迟早会改漏一份。
plutil -replace CFBundleIdentifier -string "$bundle_id" "$app_dir/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "$display_name" "$app_dir/Contents/Info.plist"
plutil -replace CFBundleName -string "$display_name" "$app_dir/Contents/Info.plist"

echo "$app_dir"
echo "  bundle id: $bundle_id"
echo "  数据目录: $data_hint"
