import { readdirSync, existsSync, mkdirSync, readFileSync, statSync } from 'node:fs';
/**
 * 纯逻辑单元测试执行器。
 *
 * 为什么需要一层打包：被测模块是 .ets（ArkTS），Node 不能直接加载。
 * 这里用 esbuild 把测试用例与 .ets 模块一起打包成 ESM：
 *  - 相对导入缺少扩展名时自动补 .ets；
 *  - `.ets` 以 ts loader 处理（被测的纯逻辑模块本身是 TypeScript 语法子集）；
 *  - `@kit.ArkTS` 映射到 test/unit/shim-arkts.ts（Node 自带的 TextEncoder/TextDecoder）。
 *
 * 自动发现 test/unit/*.test.ts，逐个打包并执行。
 *
 * 用法：node scripts/test/run-unit.mjs
 */
import { build } from 'esbuild';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const unitDir = resolve(root, 'test/unit');
const outDir = resolve(root, '.tmp-unit');
const shimPath = resolve(unitDir, 'shim-arkts.ts');

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

const entries = readdirSync(unitDir)
  .filter((name) => name.endsWith('.test.ts'))
  .sort();

if (entries.length === 0) {
  console.error('❌ test/unit 下没有找到 *.test.ts');
  process.exitCode = 1;
} else {
  let failed = 0;
  for (const entry of entries) {
    const outFile = join(outDir, entry.replace(/\.ts$/, '.mjs'));
    await build({
      entryPoints: [join(unitDir, entry)],
      outfile: outFile,
      bundle: true,
      platform: 'node',
      format: 'esm',
      target: 'node18',
      logLevel: 'warning',
      plugins: [etsPlugin],
      external: ['node:assert', 'node:assert/strict']
    });
    try {
      await import(pathToFileURL(outFile).href);
    } catch (error) {
      failed++;
      console.error(`❌ ${entry} 失败: ${error && error.message ? error.message : error}`);
    }
  }
  if (failed > 0) {
    process.exitCode = 1;
  } else {
    console.log(`\n✅ ${entries.length} 个测试文件全部通过`);
  }
}
