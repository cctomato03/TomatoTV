#!/usr/bin/env bash
# 安装 hvigor 与 OpenHarmony 构建插件（华为 npm 镜像公开可读）。
# 安装到仓库根的 node_modules，hvigorfile.ts 才能解析到 @ohos/hvigor-ohos-plugin。
set -euo pipefail

HVIGOR_VERSION="${HVIGOR_VERSION:-5.7.0}"
REGISTRY="${HVIGOR_REGISTRY:-https://repo.harmonyos.com/npm/}"

if [ -f node_modules/@ohos/hvigor/bin/hvigor.js ] && [ -d node_modules/@ohos/hvigor-ohos-plugin ]; then
  echo "[skip] hvigor 已安装"
  exit 0
fi

if [ ! -f package.json ]; then
  echo '{"name":"tomato-tv-ci","version":"1.0.0","private":true}' > package.json
fi

echo "[info] 从 $REGISTRY 安装 hvigor@$HVIGOR_VERSION"
npm install --registry "$REGISTRY" --no-audit --no-fund --no-save --loglevel=error \
  "@ohos/hvigor@${HVIGOR_VERSION}" "@ohos/hvigor-ohos-plugin@${HVIGOR_VERSION}"

test -f node_modules/@ohos/hvigor/bin/hvigor.js
echo "[info] hvigor 安装完成"
