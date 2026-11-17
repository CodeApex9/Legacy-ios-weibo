#!/bin/bash
# 可选：拉取完整的 iOS 9.3 SDK（含全部头文件与 armv7 tbd），用于 make SDK=full
# 网络不稳时会重试；拉不下来也不影响默认 mini 模式构建。
#
set -u
cd "$(dirname "$0")/../.."
DEST="toolchain/sdks-repo"

echo "==> 目标：$DEST/iPhoneOS9.3.sdk"
mkdir -p toolchain

for i in 1 2 3; do
    echo "==> 第 $i 次尝试（全量浅克隆）"
    rm -rf "$DEST"
    if git -c http.version=HTTP/1.1 clone --depth 1 https://github.com/theos/sdks.git "$DEST" >/dev/null 2>&1; then
        if [ -d "$DEST/iPhoneOS9.3.sdk" ]; then
            echo "完成，可用 make SDK=full"
            exit 0
        fi
    fi
    sleep 2
done

echo "==> 改用稀疏克隆"
rm -rf "$DEST"
if git -c http.version=HTTP/1.1 clone --depth 1 --filter=blob:none --sparse \
        https://github.com/theos/sdks.git "$DEST" >/dev/null 2>&1; then
    (cd "$DEST" && git sparse-checkout set iPhoneOS9.3.sdk) && \
        [ -d "$DEST/iPhoneOS9.3.sdk" ] && echo "完成，可用 make SDK=full" && exit 0
fi

echo "下载失败。默认 mini 模式不依赖它，可直接 make ipa。" >&2
exit 1
