#!/usr/bin/env node
/**
 * 纯逻辑单元测试执行器。
 *
 * 为什么需要一层打包：被测模块是 .ets（ArkTS），Node 不能直接加载。
 * 这里用 esbuild 把测试用例与 .ets 模块一起打包成 ESM：
 *  - 相对导入缺少扩展名时自动补 .ets；
 *  - `.ets` 以 ts loader 处理（被测的纯逻辑模块本身是 TypeScript 语法子集）；
 *  - `@kit.ArkTS` 映射到 test/unit/shim-arkts.ts（Node 自带的 TextEncoder/TextDecoder）。
 *
 * 用法：node scripts/test/run-unit.mjs
 */
import { build } from 'esbuild';
import { existsSync, mkdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const outDir = resolve(root, '.tmp-unit');
const outFile = join(outDir, 'logic.test.mjs');
const shimPath = resolve(root, 'test/unit/shim-arkts.ts');

const etsPlugin = {
  name: 'arkts-resolve',
  setup(context) {
    context.onResolve({ filter: /^@kit\.ArkTS$/ }, () => ({ path: shimPath }));
    context.onResolve({ filter: /^\.{1,2}\// }, (args) => {
      const base = resolve(args.resolveDir, args.path);
      const candidates = [base, `${base}.ets`, `${base}.ts`, join(base, 'index.ets'), join(base, 'index.ts')];
      for (const candidate of candidates) {
        if (existsSync(candidate) && statSync(candidate).isFile()) {
          return { path: candidate };
        }
      }
      return null;
    });
    context.onLoad({ filter: /\.ets$/ }, (args) => ({
      contents: readFileSync(args.path, 'utf8'),
      loader: 'ts'
    }));
  }
};

if (!existsSync(outDir)) {
  mkdirSync(outDir, { recursive: true });
}

await build({
  entryPoints: [resolve(root, 'test/unit/logic.test.ts')],
  outfile: outFile,
  bundle: true,
  platform: 'node',
  format: 'esm',
  target: 'node18',
  logLevel: 'warning',
  plugins: [etsPlugin],
  external: ['node:assert', 'node:assert/strict']
});

await import(pathToFileURL(outFile).href);
