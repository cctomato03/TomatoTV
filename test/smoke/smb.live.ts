/**
 * SMB 真实服务端冒烟测试（本地 Samba 容器 / 你的 NAS 都可以）。
 *
 * 用法：
 *   SMB_SMOKE_HOST=192.168.1.9 SMB_SMOKE_SHARE=media SMB_SMOKE_USER=u SMB_SMOKE_PASSWORD=p \
 *     node scripts/test/run-smb-smoke.mjs test/smoke/smb.live.ts
 *
 * 覆盖：connect(NEGOTIATE+SESSION_SETUP+TREE_CONNECT) → list → stat → readRange。
 * 每一步失败都会打印服务端返回的状态码与出错命令，便于定位。
 */
import { FileEntry } from '../../entry/src/main/ets/model/FileEntry';
import { FsError } from '../../entry/src/main/ets/data/fs/FileSystemClient';
import { Smb2Client } from '../../entry/src/main/ets/data/smb/Smb2Client';

const host: string = process.env.SMB_SMOKE_HOST || '127.0.0.1';
const port: number = Number(process.env.SMB_SMOKE_PORT || '1445');
const user: string = process.env.SMB_SMOKE_USER || 'alice';
const password: string = process.env.SMB_SMOKE_PASSWORD || 'secreT!23';
const domain: string = process.env.SMB_SMOKE_DOMAIN || '';
const share: string = process.env.SMB_SMOKE_SHARE || 'media';
const rootPath: string = process.env.SMB_SMOKE_ROOT || '';

console.log(`SMB 冒烟目标: ${host}:${port} share=${share} user=${user} root=${rootPath || '(空)'}`);

let failed: number = 0;
function step(name: string, ok: boolean, detail?: string): void {
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${detail === undefined ? '' : ' — ' + detail}`);
  if (!ok) {
    failed++;
  }
}

function describe(error: unknown): string {
  if (error instanceof FsError) {
    return `${(error as FsError).kind} / ${error.message}`;
  }
  return error instanceof Error ? error.message : String(error);
}

const client: Smb2Client = new Smb2Client({
  host: host,
  port: port,
  user: user,
  password: password,
  domain: domain,
  share: share,
  rootPath: rootPath
});

try {
  await client.connect();
  step('connect（NEGOTIATE + NTLMv2 + TREE_CONNECT）', true);

  let entries: FileEntry[] = [];
  try {
    entries = await client.list('/');
    step('list(/)', true, `共 ${entries.length} 项：${entries.slice(0, 8).map((e: FileEntry) => e.name + (e.isDirectory ? '/' : '')).join(', ')}`);
  } catch (error) {
    step('list(/)', false, describe(error));
  }

  const file: FileEntry | undefined = entries.find((e: FileEntry) => !e.isDirectory);
  const dir: FileEntry | undefined = entries.find((e: FileEntry) => e.isDirectory);

  if (dir !== undefined) {
    try {
      const listed: FileEntry[] = await client.list(dir.path);
      step(`list(${dir.path})`, true, `${listed.length} 项`);
    } catch (error) {
      step(`list(${dir.path})`, false, describe(error));
    }
  }

  if (file !== undefined) {
    try {
      const info: FileEntry = await client.stat(file.path);
      step(`stat(${file.path})`, true, `size=${info.size} dir=${info.isDirectory}`);
    } catch (error) {
      step(`stat(${file.path})`, false, describe(error));
    }
    try {
      const bytes: ArrayBuffer = await client.readRange(file.path, 0, 64);
      const preview: string = Buffer.from(bytes).toString('utf8').replace(/[^\x20-\x7e]/g, '.');
      step(`readRange(${file.path}, 0, 64)`, bytes.byteLength > 0, `len=${bytes.byteLength} text="${preview.slice(0, 40)}"`);
    } catch (error) {
      step(`readRange(${file.path})`, false, describe(error));
    }
  } else {
    console.log('（共享里没有普通文件，跳过 stat/readRange）');
  }
} catch (error) {
  step('connect', false, describe(error));
} finally {
  await client.close();
}

console.log(failed === 0 ? '\nSMOKE_RESULT: PASS' : `\nSMOKE_RESULT: FAIL (${failed})`);
if (failed > 0) {
  process.exitCode = 1;
}
