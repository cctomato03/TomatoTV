/**
 * WebDAV 冒烟测试（本地，无需真实 NAS）：起一个最小 WebDAV 服务端，
 * 用真实的 WebDavFileSystem 走 PROPFIND 列表与 Range 读取，验证图片字节链路。
 */
import { createServer, Server } from 'node:http';
import { InetAddress } from 'node:net';
import { WebDavFileSystem } from '../../entry/src/main/ets/data/fs/WebDavFileSystem';

const IMAGE_BYTES: Buffer = Buffer.from(Array.from({ length: 4096 }, (_v, i) => i % 256));
const TEXT_BYTES: Buffer = Buffer.from('hello tomato', 'utf8');

const PROPFIND_XML = `<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response><D:href>/dav/</D:href><D:propstat><D:prop>
    <D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
  <D:response><D:href>/dav/sub/</D:href><D:propstat><D:prop>
    <D:resourcetype><D:collection/></D:resourcetype>
    <D:getlastmodified>Tue, 02 Jan 2024 03:04:05 GMT</D:getlastmodified></D:prop></D:propstat></D:response>
  <D:response><D:href>/dav/photo.jpg</D:href><D:propstat><D:prop>
    <D:resourcetype/><D:getcontentlength>4096</D:getcontentlength>
    <D:getlastmodified>Wed, 03 Jan 2024 04:05:06 GMT</D:getlastmodified></D:prop></D:propstat></D:response>
  <D:response><D:href>/dav/note.txt</D:href><D:propstat><D:prop>
    <D:resourcetype/><D:getcontentlength>12</D:getcontentlength>
    <D:getlastmodified>Wed, 03 Jan 2024 04:05:06 GMT</D:getlastmodified></D:prop></D:propstat></D:response>
</D:multistatus>`;

function bodyOf(path: string): Buffer {
  if (path.endsWith('photo.jpg')) {
    return IMAGE_BYTES;
  }
  if (path.endsWith('note.txt')) {
    return TEXT_BYTES;
  }
  return Buffer.alloc(0);
}

const server: Server = createServer((req, res) => {
  const url = new URL(req.url === undefined ? '/' : req.url, 'http://127.0.0.1');
  if (req.method === 'PROPFIND') {
    res.writeHead(207, { 'Content-Type': 'application/xml; charset=utf-8' });
    res.end(PROPFIND_XML);
    return;
  }
  const body = bodyOf(url.pathname);
  const range = req.headers.range;
  if (typeof range === 'string') {
    const match = /bytes=(\d+)-(\d*)/.exec(range);
    if (match !== null) {
      const start = Number(match[1]);
      const end = match[2].length > 0 ? Math.min(Number(match[2]), body.length - 1) : body.length - 1;
      const slice = body.subarray(start, end + 1);
      res.writeHead(206, {
        'Content-Type': 'application/octet-stream',
        'Content-Length': slice.length,
        'Content-Range': `bytes ${start}-${end}/${body.length}`
      });
      res.end(slice);
      return;
    }
  }
  res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Length': body.length });
  res.end(body);
});

await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', () => resolve()));
const address = server.address();
const port = typeof address === 'object' && address !== null ? address.port : 0;
console.log(`本地 WebDAV 测试服务: http://127.0.0.1:${port}/dav`);

const client = new WebDavFileSystem(`http://127.0.0.1:${port}/dav`, 'user', 'pass');
let failed = 0;
function check(name: string, ok: boolean, detail?: string): void {
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${detail === undefined ? '' : ' — ' + detail}`);
  if (!ok) {
    failed++;
  }
}

try {
  const entries = await client.list('/');
  const names = entries.map((e) => `${e.name}${e.isDirectory ? '/' : ''}`).sort();
  check('PROPFIND 列表', names.join(',') === 'note.txt,photo.jpg,sub/', names.join(','));
  const photo = entries.find((e) => e.name === 'photo.jpg');
  check('文件大小解析', photo !== undefined && photo.size === 4096, `size=${photo === undefined ? 'n/a' : photo.size}`);

  const head = await client.readRange('/photo.jpg', 0, 1024);
  check('Range 首块 1024 字节', head.byteLength === 1024, `len=${head.byteLength}`);
  check('Range 首块内容正确', Buffer.from(head).equals(IMAGE_BYTES.subarray(0, 1024)));

  const middle = await client.readRange('/photo.jpg', 1024, 512);
  check('Range 中段内容正确', Buffer.from(middle).equals(IMAGE_BYTES.subarray(1024, 1536)));

  // 模拟 FileRepository.readDocument 的分块读取（图片/文档共用）
  const chunks: Buffer[] = [];
  let offset = 0;
  while (offset < photo!.size) {
    const want = Math.min(512 * 1024, photo!.size - offset);
    const buffer = await client.readRange('/photo.jpg', offset, want);
    if (buffer.byteLength === 0) {
      break;
    }
    chunks.push(Buffer.from(buffer));
    offset += buffer.byteLength;
    if (buffer.byteLength < want) {
      break;
    }
  }
  const merged = Buffer.concat(chunks);
  check('分块读取完整图片', merged.length === 4096 && merged.equals(IMAGE_BYTES), `len=${merged.length}`);
} catch (error) {
  console.log('FAIL 异常:', error instanceof Error ? error.message : String(error));
  failed++;
}

await client.close();
server.close();
console.log(failed === 0 ? '\nSMOKE_RESULT: PASS' : `\nSMOKE_RESULT: FAIL (${failed})`);
if (failed > 0) {
  process.exitCode = 1;
}
