#!/usr/bin/env node
/**
 * CI 专用：跳过 hvigor 的 "SDK 许可未接受" 校验。
 *
 * 背景：
 *  hvigor 在构建前会调用华为许可服务查询 OpenHarmony SDK 许可，并在
 *  $SDK_ROOT/licenses/<licenseId>.sha256 中比对本地"已接受"记录。
 *  在 DevEco Studio 中这一步等价于用户勾选同意；CI 无交互界面，因此这里做一个
 *  幂等补丁：让 findUnacceptedLicenses() 直接返回空数组（= 全部已接受）。
 *
 *  该脚本只修改本地 node_modules 中的依赖实现，不涉及业务代码；
 *  重复执行不会叠加修改（检测到标记即跳过）。
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const MARKER = 'AUTO_ACCEPT_PATCH';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');

const candidates = [
  'node_modules/@ohos/hvigor-ohos-plugin/node_modules/@ohos/sdkmanager-common/build/src/core/license/license-manager.js',
  'node_modules/@ohos/sdkmanager-common/build/src/core/license/license-manager.js'
];

let patched = 0;
for (const rel of candidates) {
  const file = resolve(root, rel);
  if (!existsSync(file)) {
    continue;
  }
  const source = readFileSync(file, 'utf8');
  if (source.includes(MARKER)) {
    console.log(`[skip] 已打过补丁: ${rel}`);
    patched++;
    continue;
  }
  const target = 'findUnacceptedLicenses(licenseIds, progress) {';
  if (!source.includes(target)) {
    console.warn(`[warn] 未找到目标函数，跳过: ${rel}`);
    continue;
  }
  const replaced = source.replace(
    target,
    `${target} /* ${MARKER} */ return Promise.resolve([]);`
  );
  writeFileSync(file, replaced, 'utf8');
  console.log(`[ok] 已跳过 SDK 许可校验: ${rel}`);
  patched++;
}

if (patched === 0) {
  console.error('[error] 未找到 sdkmanager-common 的 license-manager.js，请先安装 hvigor 依赖');
  process.exitCode = 1;
}
