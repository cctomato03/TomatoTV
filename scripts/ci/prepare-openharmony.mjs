#!/usr/bin/env node
/**
 * 将仓库中面向 HarmonyOS NEXT 的工程配置，临时转换为可被「OpenHarmony 公共 SDK」构建的配置。
 *
 * 背景：
 *  - 本工程的产品目标平台是 HarmonyOS NEXT（runtimeOS = HarmonyOS，deviceTypes 含 phone/tablet/2in1/tv）。
 *  - HarmonyOS SDK 需登录 DevEco Studio 下载，无法在公开 CI Runner 上获取；
 *  - 公开的 OpenHarmony SDK（repo.huaweicloud.com）可以匿名下载，可用于「编译校验 + 产出未签名 HAP」。
 *
 * 用法：
 *   node scripts/ci/prepare-openharmony.mjs            应用转换（CI 用）
 *   node scripts/ci/prepare-openharmony.mjs --restore  还原为 HarmonyOS 配置（本地用）
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const buildProfilePath = resolve(root, 'build-profile.json5');
const modulePath = resolve(root, 'entry/src/main/module.json5');

const HARMONY_PRODUCT = `"compatibleSdkVersion": "5.0.0(12)",
        "runtimeOS": "HarmonyOS",`;
const OPENHARMONY_PRODUCT = `"compileSdkVersion": 12,
        "compatibleSdkVersion": 12,
        "runtimeOS": "OpenHarmony",`;

const HARMONY_DEVICES = `"deviceTypes": [
      "phone",
      "tablet",
      "2in1",
      "tv"
    ],`;
const OPENHARMONY_DEVICES = `"deviceTypes": [
      "default",
      "tablet"
    ],`;

function patch(file, from, to, label) {
  const text = readFileSync(file, 'utf8');
  if (!text.includes(from)) {
    if (text.includes(to)) {
      console.log(`[skip] ${label} 已是目标状态`);
      return;
    }
    throw new Error(`${label}: 找不到待替换片段，请检查 ${file}`);
  }
  writeFileSync(file, text.replace(from, to), 'utf8');
  console.log(`[ok] ${label}`);
}

const restore = process.argv.includes('--restore');

if (restore) {
  patch(buildProfilePath, OPENHARMONY_PRODUCT, HARMONY_PRODUCT, 'build-profile.json5 -> HarmonyOS');
  patch(modulePath, OPENHARMONY_DEVICES, HARMONY_DEVICES, 'module.json5 -> phone/tablet/2in1/tv');
} else {
  patch(buildProfilePath, HARMONY_PRODUCT, OPENHARMONY_PRODUCT, 'build-profile.json5 -> OpenHarmony');
  patch(modulePath, HARMONY_DEVICES, OPENHARMONY_DEVICES, 'module.json5 -> default/tablet');
}
