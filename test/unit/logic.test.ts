/**
 * 纯逻辑单元测试（不依赖设备与 ArkUI 运行时）。
 *
 * 覆盖：文件类型判定、路径规范化与越界防护、排序、格式化、
 * WebDAV XML 解析、M2TS PCR 时长探测、二维码编码（用 jsQR 反向解码验证）。
 *
 * 运行：node scripts/test/run-unit.mjs
 */
import assert from 'node:assert/strict';
import jsQR from 'jsqr';
import { FileKinds, PreviewKind } from '../../entry/src/main/ets/model/FileKinds';
import { PathGuard, hasScheme } from '../../entry/src/main/ets/data/fs/PathGuard';
import { FileEntry, FileEntryFactory, FileSorter } from '../../entry/src/main/ets/model/FileEntry';
import { Fmt } from '../../entry/src/main/ets/utils/Format';
import { WebDavXml } from '../../entry/src/main/ets/data/fs/WebDavXml';
import { ByteReader, MpegTsDuration } from '../../entry/src/main/ets/media/MpegTsDuration';
import { QrCode } from '../../entry/src/main/ets/utils/QrCode';
import { SourceFactory, SourceType, SourceUrl } from '../../entry/src/main/ets/model/FileSource';

let passed: number = 0;
const failures: string[] = [];

function check(name: string, run: () => void): void {
  try {
    run();
    passed++;
  } catch (error) {
    failures.push(`${name} → ${(error as Error).message}`);
  }
}

async function checkAsync(name: string, run: () => Promise<void>): Promise<void> {
  try {
    await run();
    passed++;
  } catch (error) {
    failures.push(`${name} → ${(error as Error).message}`);
  }
}

// ---------------- 文件类型判定 ----------------
check('FileKinds.extensionOf', () => {
  assert.equal(FileKinds.extensionOf('Movie.MP4'), 'mp4');
  assert.equal(FileKinds.extensionOf('no-extension'), '');
  assert.equal(FileKinds.extensionOf('trailing.'), '');
});

check('FileKinds.kindOf 视频', () => {
  for (const name of ['a.mp4', 'b.mkv', 'c.m2ts', 'd.ts', 'e.wmv', 'f.rmvb', 'g.flv', 'h.avi']) {
    assert.equal(FileKinds.kindOf(name), PreviewKind.VIDEO, name);
  }
});

check('FileKinds.kindOf 音频/图片/文本', () => {
  assert.equal(FileKinds.kindOf('a.flac'), PreviewKind.AUDIO);
  assert.equal(FileKinds.kindOf('a.opus'), PreviewKind.AUDIO);
  assert.equal(FileKinds.kindOf('a.heic'), PreviewKind.IMAGE);
  assert.equal(FileKinds.kindOf('a.markdown'), PreviewKind.TEXT);
  assert.equal(FileKinds.kindOf('.gitignore'), PreviewKind.TEXT);
  assert.equal(FileKinds.kindOf('Dockerfile'), PreviewKind.TEXT);
});

check('FileKinds.kindOf 文档与其他', () => {
  assert.equal(FileKinds.kindOf('a.pdf'), PreviewKind.PDF);
  assert.equal(FileKinds.kindOf('a.docx'), PreviewKind.DOCX);
  assert.equal(FileKinds.kindOf('a.xlsx'), PreviewKind.XLSX);
  assert.equal(FileKinds.kindOf('a.pptx'), PreviewKind.PPTX);
  assert.equal(FileKinds.kindOf('a.zip'), PreviewKind.ARCHIVE);
  assert.equal(FileKinds.kindOf('a.bin'), PreviewKind.OTHER);
});

check('FileKinds.mimeOfKind', () => {
  assert.equal(FileKinds.mimeOfKind(PreviewKind.IMAGE, 'a.png'), 'image/png');
  assert.equal(FileKinds.mimeOfKind(PreviewKind.IMAGE, 'a.jpg'), 'image/jpeg');
  assert.equal(FileKinds.mimeOfKind(PreviewKind.VIDEO, 'a.mkv'), 'video/x-matroska');
  assert.equal(FileKinds.mimeOfKind(PreviewKind.AUDIO, 'a.flac'), 'audio/flac');
  assert.equal(FileKinds.mimeOfKind(PreviewKind.PDF, 'a.pdf'), 'application/pdf');
  assert.equal(FileKinds.mimeOfKind(PreviewKind.OTHER, 'a.bin'), 'application/octet-stream');
});

// ---------------- 路径守卫 ----------------
check('PathGuard.normalize', () => {
  assert.equal(PathGuard.normalize('/a/../b//./c'), '/b/c');
  assert.equal(PathGuard.normalize('/../../x'), '/x');
  assert.equal(PathGuard.normalize('a\\b/c'), '/a/b/c');
  assert.equal(PathGuard.normalize('/'), '/');
});

check('PathGuard.isUnder 越界防护', () => {
  assert.equal(PathGuard.isUnder('/root', '/root/a/b'), true);
  assert.equal(PathGuard.isUnder('/root', '/root'), true);
  assert.equal(PathGuard.isUnder('/root', '/rootx'), false);
  assert.equal(PathGuard.isUnder('/root', '/etc/passwd'), false);
  assert.equal(PathGuard.isUnder('/', '/anything'), true);
});

check('PathGuard 层级换算', () => {
  assert.deepEqual(PathGuard.segments('/a/b/c'), ['a', 'b', 'c']);
  assert.deepEqual(PathGuard.relativeSegments('/root', '/root/a/b'), ['a', 'b']);
  assert.equal(PathGuard.fromSegments('/root', ['a', 'b']), '/root/a/b');
  assert.equal(PathGuard.join('/root', 'a'), '/root/a');
  assert.equal(PathGuard.join('/', 'a'), '/a');
});

check('hasScheme', () => {
  assert.equal(hasScheme('file://docs/x'), true);
  assert.equal(hasScheme('https://a/b'), true);
  assert.equal(hasScheme('/a/b'), false);
});

// ---------------- 排序 ----------------
check('FileSorter 目录优先与各排序规则', () => {
  const dir: FileEntry = FileEntryFactory.directory('zdir', '/zdir', 5000);
  const small: FileEntry = FileEntryFactory.file('a.txt', '/a.txt', 100, 1000, '');
  const large: FileEntry = FileEntryFactory.file('c.bin', '/c.bin', 900, 9000, '');
  const list: FileEntry[] = [small, large, dir];

  assert.deepEqual(FileSorter.sort(list, 'nameAsc').map((item: FileEntry) => item.name), ['zdir', 'a.txt', 'c.bin']);
  assert.deepEqual(FileSorter.sort(list, 'nameDesc').map((item: FileEntry) => item.name), ['zdir', 'c.bin', 'a.txt']);
  assert.deepEqual(FileSorter.sort(list, 'sizeDesc').map((item: FileEntry) => item.name), ['zdir', 'c.bin', 'a.txt']);
  assert.deepEqual(FileSorter.sort(list, 'sizeAsc').map((item: FileEntry) => item.name), ['zdir', 'a.txt', 'c.bin']);
  assert.deepEqual(FileSorter.sort(list, 'dateDesc').map((item: FileEntry) => item.name), ['zdir', 'c.bin', 'a.txt']);
  assert.deepEqual(FileSorter.sort(list, 'dateAsc').map((item: FileEntry) => item.name), ['zdir', 'a.txt', 'c.bin']);
  // 不修改入参
  assert.equal(list[0].name, 'a.txt');
});

// ---------------- 格式化 ----------------
check('Fmt.size', () => {
  assert.equal(Fmt.size(0), '0 B');
  assert.equal(Fmt.size(-1), '0 B');
  assert.equal(Fmt.size(512), '512 B');
  assert.equal(Fmt.size(1536), '1.5 KB');
  assert.equal(Fmt.size(1024 * 1024), '1.0 MB');
  assert.equal(Fmt.size(3 * 1024 * 1024 * 1024), '3.0 GB');
});

check('Fmt.duration', () => {
  assert.equal(Fmt.duration(0), '00:00');
  assert.equal(Fmt.duration(65000), '01:05');
  assert.equal(Fmt.duration(3725000), '1:02:05');
  assert.equal(Fmt.duration(-5), '00:00');
});

check('Fmt.percent 与 dateTime', () => {
  assert.equal(Fmt.percent(50, 200), 25);
  assert.equal(Fmt.percent(0, 0), 0);
  assert.equal(Fmt.percent(500, 100), 100);
  const stamp: string = Fmt.dateTime(Date.UTC(2024, 0, 2, 3, 4));
  assert.match(stamp, /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/);
});

// ---------------- WebDAV XML ----------------
check('WebDavXml 解析 207 Multi-Status', () => {
  const xml: string = `<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/</D:href>
    <D:propstat><D:prop>
      <D:resourcetype><D:collection/></D:resourcetype>
    </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/sub/</D:href>
    <D:propstat><D:prop>
      <D:resourcetype><D:collection/></D:resourcetype>
      <D:getlastmodified>Tue, 02 Jan 2024 03:04:05 GMT</D:getlastmodified>
    </D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/%E4%B8%AD%E6%96%87.txt</D:href>
    <D:propstat><D:prop>
      <D:resourcetype/>
      <D:getcontentlength>1234</D:getcontentlength>
      <D:getlastmodified>Wed, 03 Jan 2024 04:05:06 GMT</D:getlastmodified>
    </D:prop></D:propstat>
  </D:response>
</D:multistatus>`;
  const items = WebDavXml.parse(xml);
  assert.equal(items.length, 3);
  assert.equal(items[1].isDirectory, true);
  assert.equal(items[1].name, 'sub');
  assert.equal(items[2].isDirectory, false);
  assert.equal(items[2].name, '中文.txt');
  assert.equal(items[2].size, 1234);
  assert.ok(items[2].modified > 0);
});

// ---------------- M2TS / TS PCR ----------------
class BufferReader implements ByteReader {
  private data: Uint8Array;

  constructor(data: Uint8Array) {
    this.data = data;
  }

  size(): number {
    return this.data.length;
  }

  async read(position: number, length: number): Promise<ArrayBuffer> {
    const end: number = Math.min(this.data.length, position + length);
    return this.data.slice(position, end).buffer as ArrayBuffer;
  }
}

function buildTs(count: number, packetSize: number, pcrStart: number, step: number): Uint8Array {
  const data = new Uint8Array(count * packetSize);
  for (let index = 0; index < count; index++) {
    const off = index * packetSize + (packetSize === 192 ? 4 : 0);
    data[off] = 0x47;
    data[off + 1] = 0x00;
    data[off + 2] = 0x00;
    data[off + 3] = 0x20; // adaptation field only, no payload
    data[off + 4] = 183; // adaptation_field_length
    data[off + 5] = 0x10; // PCR flag
    const pcr = pcrStart + index * step;
    const base = Math.floor(pcr / 300);
    const ext = pcr % 300;
    data[off + 6] = Math.floor(base / 33554432) % 256;
    data[off + 7] = Math.floor(base / 131072) % 256;
    data[off + 8] = Math.floor(base / 512) % 256;
    data[off + 9] = Math.floor(base / 2) % 256;
    data[off + 10] = ((base % 2) << 7) | 0x7e | Math.floor(ext / 256);
    data[off + 11] = ext % 256;
  }
  return data;
}

check('MpegTsDuration.detectPacketSize', () => {
  assert.equal(MpegTsDuration.detectPacketSize(buildTs(40, 188, 0, 28500)), 188);
  assert.equal(MpegTsDuration.detectPacketSize(buildTs(40, 192, 0, 28500)), 192);
  assert.equal(MpegTsDuration.detectPacketSize(new Uint8Array(4000)), 0);
});

check('MpegTsDuration.firstPcr / lastPcr', () => {
  const data = buildTs(10, 188, 90000, 27000);
  assert.equal(MpegTsDuration.firstPcr(data, 188), 90000);
  assert.equal(MpegTsDuration.lastPcr(data, 188), 90000 + 9 * 27000);
});

await checkAsync('MpegTsDuration.probe 188 字节包时长', async () => {
  // 27MHz 时钟：210 秒对应 210 * 27000 * 1000 ticks
  const packets = 200;
  const step = Math.floor((210 * 27000 * 1000) / (packets - 1));
  const data = buildTs(packets, 188, 0, step);
  const durationMs = await MpegTsDuration.probe(new BufferReader(data));
  const expected = Math.floor(((packets - 1) * step) / 27000);
  assert.equal(durationMs, expected);
  assert.ok(durationMs >= 209000 && durationMs <= 211000, `实际 ${durationMs}`);
});

await checkAsync('MpegTsDuration.probe 192 字节包（BDAV）', async () => {
  const packets = 120;
  const step = Math.floor((132 * 27000 * 1000) / (packets - 1));
  const data = buildTs(packets, 192, 0, step);
  const durationMs = await MpegTsDuration.probe(new BufferReader(data));
  assert.ok(durationMs > 0, '应探测到时长');
  assert.equal(durationMs, Math.floor(((packets - 1) * step) / 27000));
  assert.ok(durationMs >= 131000 && durationMs <= 133000, `实际 ${durationMs}`);
});

await checkAsync('MpegTsDuration.probe 非 TS 数据返回 0', async () => {
  const durationMs = await MpegTsDuration.probe(new BufferReader(new Uint8Array(40000)));
  assert.equal(durationMs, 0);
});

// ---------------- 二维码 ----------------
function toRgba(matrix: boolean[][], scale: number, quiet: number): { data: Uint8ClampedArray, width: number } {
  const size = matrix.length;
  const dim = (size + quiet * 2) * scale;
  const data = new Uint8ClampedArray(dim * dim * 4).fill(255);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      if (!matrix[y][x]) {
        continue;
      }
      for (let dy = 0; dy < scale; dy++) {
        for (let dx = 0; dx < scale; dx++) {
          const py = (y + quiet) * scale + dy;
          const px = (x + quiet) * scale + dx;
          const at = (py * dim + px) * 4;
          data[at] = 0;
          data[at + 1] = 0;
          data[at + 2] = 0;
          data[at + 3] = 255;
        }
      }
    }
  }
  return { data: data, width: dim };
}

check('QrCode 尺寸与容量', () => {
  const short = QrCode.encode('hello');
  assert.ok(short !== null);
  assert.equal(short!.length, 21);
  const medium = QrCode.encode('http://10.0.0.5');
  assert.equal(medium!.length, 25);
  const long = QrCode.encode('http://192.168.1.100:8765/?t=abcd2345ef');
  assert.equal(long!.length, 29);
  assert.equal(QrCode.encode('x'.repeat(60)), null);
});

check('QrCode 定位图形结构', () => {
  const matrix = QrCode.encode('http://192.168.1.100:8765/?t=abcd2345ef')!;
  // 左上定位图形 7x7 外圈
  for (let i = 0; i < 7; i++) {
    assert.equal(matrix[0][i], true);
    assert.equal(matrix[6][i], true);
    assert.equal(matrix[i][0], true);
    assert.equal(matrix[i][6], true);
  }
  // 定位图形内部 3x3 实心
  for (let y = 2; y <= 4; y++) {
    for (let x = 2; x <= 4; x++) {
      assert.equal(matrix[y][x], true);
    }
  }
  // 定时图形交替
  assert.equal(matrix[6][8], true);
  assert.equal(matrix[6][9], false);
});

check('QrCode 用 jsQR 反向解码验证', () => {
  const payloads: string[] = [
    'hello',
    'http://10.0.0.5:8765/?t=xyz98765ab',
    'http://192.168.1.100:8765/?t=abcd2345ef',
    'http://172.16.31.240:8790/?t=q1w2e3r4t5'
  ];
  for (const payload of payloads) {
    const matrix = QrCode.encode(payload);
    assert.ok(matrix !== null, `应为 ${payload} 生成二维码`);
    const image = toRgba(matrix!, 6, 4);
    const result = jsQR(image.data, image.width, image.width);
    assert.ok(result !== null, `${payload} 应可被解码`);
    assert.equal(result!.data, payload);
  }
});

// ---------------- 来源与 URL ----------------
check('SourceUrl 工具', () => {
  assert.equal(SourceUrl.trimSlashes('/a/b/'), 'a/b');
  assert.equal(SourceUrl.encodePath('/a b/中文.txt'), 'a%20b/%E4%B8%AD%E6%96%87.txt');
  assert.equal(SourceUrl.tailOfUri('file://docs/storage/Users/currentUser/Documents/movie.mkv'), 'movie.mkv');
  assert.equal(SourceUrl.joinPath('/a', 'b'), '/a/b');
  assert.equal(SourceUrl.parentOf('/a/b/c'), '/a/b');
  assert.equal(SourceUrl.parentOf('/a'), '/');
});

check('SourceFactory 地址展示', () => {
  const webdav = SourceFactory.blank(SourceType.WEBDAV);
  webdav.url = 'https://nas.local/dav';
  assert.equal(SourceFactory.displayAddress(webdav), 'https://nas.local/dav');

  const ftp = SourceFactory.blank(SourceType.FTP);
  ftp.host = '192.168.1.9';
  ftp.port = 21;
  ftp.secure = true;
  assert.equal(SourceFactory.displayAddress(ftp), 'ftps://192.168.1.9:21');

  const smb = SourceFactory.blank(SourceType.SMB);
  smb.host = 'nas';
  smb.port = 445;
  smb.share = 'media';
  smb.rootPath = '/movies/';
  assert.equal(SourceFactory.displayAddress(smb), 'smb://nas:445/media/movies');
  assert.equal(SourceFactory.typeLabel(SourceType.SMB), 'SMB');
});

// ---------------- 汇总 ----------------
if (failures.length > 0) {
  console.error(`\n❌ ${failures.length} 项失败 / ${passed} 项通过`);
  for (const failure of failures) {
    console.error(`   - ${failure}`);
  }
  throw new Error('单元测试未通过');
}
console.log(`✅ 单元测试全部通过：${passed} 项`);
