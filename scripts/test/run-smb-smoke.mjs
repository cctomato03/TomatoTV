#!/usr/bin/env node
/**
 * SMB2 冒烟测试执行器（本地专用，不在 CI 运行：需要一台可访问的 SMB 服务端）。
 *
 * 把 ArkTS 的 @kit.NetworkKit / @kit.PerformanceAnalysisKit 映射到 Node 实现，
 * 于是同一份 Smb2Client 代码可以直接连真实 SMB 服务端。
 *
 * 用法：
 *   node scripts/test/run-smb-smoke.mjs
 *   SMB_SMOKE_HOST=192.168.1.9 SMB_SMOKE_SHARE=media node scripts/test/run-smb-smoke.mjs
 */
import { build } from 'esbuild';
import { existsSync, mkdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const outDir = resolve(root, '.tmp-unit');
const entryArg = process.argv[2] || 'test/smoke/smb.smoke.ts';
const outFile = join(outDir, entryArg.replace(/[\\/]/g, '_').replace(/\.ts$/, '.mjs'));

const aliases = {
  '@kit.ArkTS': resolve(root, 'test/unit/shim-arkts.ts'),
  '@kit.NetworkKit': resolve(root, 'test/smoke/shim-network.ts'),
  '@kit.PerformanceAnalysisKit': resolve(root, 'test/smoke/shim-hilog.ts'),
  '@kit.BasicServicesKit': resolve(root, 'test/smoke/shim-hilog.ts')
};

const arktsPlugin = {
  name: 'arkts-resolve',
  setup(context) {
    for (const [name, target] of Object.entries(aliases)) {
      const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      context.onResolve({ filter: new RegExp(`^${escaped}$`) }, () => ({ path: target }));
    }
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
  entryPoints: [resolve(root, entryArg)],
  outfile: outFile,
  bundle: true,
  platform: 'node',
  format: 'esm',
  target: 'node18',
  logLevel: 'warning',
  plugins: [arktsPlugin],
  external: ['node:net', 'node:assert', 'node:assert/strict']
});

await import(pathToFileURL(outFile).href);
