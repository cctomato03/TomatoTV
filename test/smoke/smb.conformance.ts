/**
 * SMB2 客户端协议一致性测试：用"严格按规范实现的最小服务端"（smb.server.ts）
 * 跑通 NEGOTIATE -> SESSION_SETUP(NTLMv2) -> TREE_CONNECT -> CREATE ->
 * QUERY_DIRECTORY / QUERY_INFO / READ -> CLOSE，并断言客户端报文布局正确。
 */
import { FileEntry } from '../../entry/src/main/ets/model/FileEntry';
import { Smb2Client } from '../../entry/src/main/ets/data/smb/Smb2Client';
import { Smb2TestServer } from './smb.server';

const server: Smb2TestServer = new Smb2TestServer();
const port: number = await server.start();
console.log(`SMB2 一致性测试服务端: 127.0.0.1:${port}`);

let failed = 0;
function check(name: string, ok: boolean, detail?: string): void {
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${detail === undefined ? '' : ' — ' + detail}`);
  if (!ok) {
    failed++;
  }
}

const client: Smb2Client = new Smb2Client({
  host: '127.0.0.1',
  port: port,
  user: 'alice',
  password: 'secreT!23',
  domain: 'TEST',
  share: 'media',
  rootPath: ''
});

try {
  await client.connect();
  check('NEGOTIATE + NTLMv2 会话 + TREE_CONNECT', true);

  const entries: FileEntry[] = await client.list('/');
  const names: string[] = entries.map((entry: FileEntry) => `${entry.name}${entry.isDirectory ? '/' : ''}`).sort();
  const expectedNames: string = [`${server.dirName}/`, server.fileName].sort().join(',');
  check('QUERY_DIRECTORY 解析', names.join(',') === expectedNames,
    `actual=${names.join(',')} expected=${expectedNames}`);
  const file: FileEntry | undefined = entries.find((entry: FileEntry) => entry.name === server.fileName);
  check('目录项大小解析', file !== undefined && file.size === server.fileContent.length,
    `size=${file === undefined ? 'n/a' : file.size}`);

  const stat: FileEntry = await client.stat(`/${server.fileName}`);
  check('QUERY_INFO 大小解析', stat.size === server.fileContent.length, `size=${stat.size}`);
  check('QUERY_INFO 目录标志', stat.isDirectory === false);

  const head: ArrayBuffer = await client.readRange(`/${server.fileName}`, 0, 1024);
  check('READ 首块长度', head.byteLength === 1024, `len=${head.byteLength}`);
  check('READ 首块内容正确',
    Buffer.from(head).equals(server.fileContent.subarray(0, 1024)));

  const tail: ArrayBuffer = await client.readRange(`/${server.fileName}`, 7000, 2048);
  const expectedTail: Buffer = server.fileContent.subarray(7000, 8192);
  check('READ 跨越文件末尾', Buffer.from(tail).equals(expectedTail), `len=${tail.byteLength}`);
} catch (error) {
  check('整体流程', false, error instanceof Error ? error.message : String(error));
} finally {
  await client.close();
  await server.stop();
}

for (const problem of server.problems) {
  console.log(`服务端校验失败: ${problem}`);
  failed++;
}
console.log(`命令序列: ${server.seen.join(' -> ')}`);
console.log(failed === 0 ? '\nSMOKE_RESULT: PASS' : `\nSMOKE_RESULT: FAIL (${failed})`);
if (failed > 0) {
  process.exitCode = 1;
}
