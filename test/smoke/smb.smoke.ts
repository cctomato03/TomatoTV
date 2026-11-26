/**
 * SMB2 冒烟测试（本地，需要一台可访问的 SMB 服务端，例如 Windows 本机的 445 端口）。
 *
 * 目的：在没有 HarmonyOS 设备的情况下，用同一份 ArkTS 代码（把 socket 换成 Node 的 net.Socket）
 * 验证 NEGOTIATE / SESSION_SETUP 的报文布局与 NTLM 流程能被真实服务端接受：
 *   - 若返回 STATUS_LOGON_FAILURE，说明服务端成功解析了我们的 NEGOTIATE 与 NTLMv2 Type3（凭据是假的）
 *   - 若返回其它状态或超时，说明报文布局有问题
 */
import { FsError, FsErrorKind } from '../../entry/src/main/ets/data/fs/FileSystemClient';
import { Smb2Client } from '../../entry/src/main/ets/data/smb/Smb2Client';

const host: string = process.env.SMB_SMOKE_HOST || '127.0.0.1';
const port: number = Number(process.env.SMB_SMOKE_PORT || '445');
const user: string = process.env.SMB_SMOKE_USER || 'tomato_probe';
const password: string = process.env.SMB_SMOKE_PASSWORD || 'definitely-wrong-password';
const domain: string = process.env.SMB_SMOKE_DOMAIN || '';
const share: string = process.env.SMB_SMOKE_SHARE || 'IPC$';

console.log(`SMB 冒烟目标: ${host}:${port} share=${share} user=${user}`);

const client: Smb2Client = new Smb2Client({
  host: host,
  port: port,
  user: user,
  password: password,
  domain: domain,
  share: share,
  rootPath: ''
});

let verdict: string = 'FAIL';
try {
  await client.connect();
  console.log('SMOKE: 连接与认证成功');
  verdict = 'PASS';
} catch (error) {
  const kind: string = error instanceof FsError ? `${(error as FsError).kind}` : 'UNKNOWN';
  const message: string = error instanceof Error ? error.message : String(error);
  console.log(`SMOKE: 连接失败 kind=${kind} message=${message}`);
  if (error instanceof FsError && (error as FsError).kind === FsErrorKind.AUTH) {
    console.log('SMOKE: 服务端返回认证失败 → 说明 NEGOTIATE/NTLM 报文被正确解析');
    verdict = 'PASS';
  }
} finally {
  await client.close();
}

console.log(`SMOKE_RESULT: ${verdict}`);
if (verdict !== 'PASS') {
  process.exitCode = 1;
}
