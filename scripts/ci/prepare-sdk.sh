#!/usr/bin/env bash
# 下载并整理公开的 OpenHarmony SDK，供 hvigor 使用。
# 目录布局：$SDK_ROOT/12/{ets,js,native,toolchains}
set -euo pipefail

SDK_VERSION="${SDK_VERSION:-5.0.0-Release}"
SDK_ROOT="${SDK_ROOT:-$HOME/ohos-sdk}"
API_DIR="$SDK_ROOT/12"
ARCHIVE="$SDK_ROOT/ohos-sdk-public.tar.gz"
URL="https://repo.huaweicloud.com/openharmony/os/${SDK_VERSION}/ohos-sdk-windows_linux-public.tar.gz"

if [ -f "$API_DIR/ets/oh-uni-package.json" ] && [ -f "$API_DIR/toolchains/oh-uni-package.json" ]; then
  echo "[skip] SDK 已就绪: $API_DIR"
else
  mkdir -p "$SDK_ROOT"
  if [ ! -f "$ARCHIVE" ]; then
    echo "[info] 下载 $URL"
    curl -L --retry 3 --retry-delay 5 -o "$ARCHIVE" "$URL"
  fi
  echo "[info] 解压 linux 组件"
  rm -rf "$SDK_ROOT/linux"
  tar -xzf "$ARCHIVE" -C "$SDK_ROOT" linux
  mkdir -p "$API_DIR"
  for zip_file in "$SDK_ROOT"/linux/*.zip; do
    echo "[info] unzip $(basename "$zip_file")"
    unzip -q -o "$zip_file" -d "$API_DIR"
  done
fi

# hvigor 通过 local.properties 的 sdk.dir 或 OHOS_BASE_SDK_HOME 定位 SDK
cat > local.properties <<EOF
sdk.dir=$SDK_ROOT
EOF

echo "[info] SDK 布局:"
ls "$API_DIR"

{
  echo "DEVECO_SDK_HOME=$SDK_ROOT"
  echo "OHOS_BASE_SDK_HOME=$SDK_ROOT"
} >> "${GITHUB_ENV:-/dev/null}"
