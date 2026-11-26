#!/usr/bin/env bash
# 安装 hvigor 与 OpenHarmony 构建插件（华为 npm 镜像公开可读）。
#
# 安装到仓库外的工具目录（$HVIGOR_TOOLS_DIR），再把 node_modules 软链到仓库根，
# 避免把仓库根 package.json 里的测试依赖（esbuild/jsqr）也一起装到华为镜像上（会 404）。
set -euo pipefail

HVIGOR_VERSION="${HVIGOR_VERSION:-5.7.0}"
REGISTRY="${HVIGOR_REGISTRY:-https://repo.harmonyos.com/npm/}"
TOOLS_DIR="${HVIGOR_TOOLS_DIR:-$HOME/ohos-build-tools}"

if [ -f node_modules/@ohos/hvigor/bin/hvigor.js ] && [ -d node_modules/@ohos/hvigor-ohos-plugin ]; then
  echo "[skip] hvigor 已安装"
  exit 0
fi

mkdir -p "$TOOLS_DIR"
if [ ! -f "$TOOLS_DIR/package.json" ]; then
  echo '{"name":"ohos-build-tools","version":"1.0.0","private":true}' > "$TOOLS_DIR/package.json"
fi

if [ -f "$TOOLS_DIR/node_modules/@ohos/hvigor/bin/hvigor.js" ]; then
  echo "[skip] 工具目录已存在 hvigor: $TOOLS_DIR"
else
  echo "[info] 从 $REGISTRY 安装 hvigor@$HVIGOR_VERSION 到 $TOOLS_DIR"
  (
    cd "$TOOLS_DIR"
    npm install --registry "$REGISTRY" --no-audit --no-fund --no-save --loglevel=error \
      "@ohos/hvigor@${HVIGOR_VERSION}" "@ohos/hvigor-ohos-plugin@${HVIGOR_VERSION}"
  )
fi

# hvigorfile.ts 需要能从仓库根解析到 @ohos/hvigor-ohos-plugin
rm -rf node_modules
if ! ln -s "$TOOLS_DIR/node_modules" node_modules 2>/dev/null; then
  echo "[info] 软链不可用，改为复制 node_modules"
  cp -r "$TOOLS_DIR/node_modules" node_modules
fi

test -f node_modules/@ohos/hvigor/bin/hvigor.js
test -d node_modules/@ohos/hvigor-ohos-plugin
echo "[info] hvigor 安装完成"
