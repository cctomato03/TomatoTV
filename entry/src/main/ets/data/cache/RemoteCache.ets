import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { FsError, FsErrorKind, FileSystemClient } from '../fs/FileSystemClient';
import { Logger } from '../../utils/Logger';

export interface CacheEntryMeta {
  sourceId: string;
  path: string;
  size: number;
  complete: boolean;
  updatedAt: number;
}

export interface CacheStats {
  fileCount: number;
  totalBytes: number;
}

interface IndexRecord {
  key: string;
  sourceId: string;
  path: string;
  size: number;
  updatedAt: number;
}

/**
 * 远程缓存（规范 §8.6）。
 * 目录结构：cacheDir/remote/<sourceId>/<sha256(path)>/data + meta.json，索引 cacheDir/remote/index.json。
 * 只写应用私有缓存目录；LRU 清理；视频按 Range 片段复用由播放器/下载器决定。
 */
export class RemoteCache {
  private root: string;
  private index: IndexRecord[] = [];
  private encoder: util.TextEncoder = new util.TextEncoder('utf-8');
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8');

  constructor(cacheDir: string) {
    this.root = `${cacheDir}/remote`;
    this.ensureDir(this.root);
    this.loadIndex();
  }

  private ensureDir(path: string): void {
    try {
      if (!fs.accessSync(path)) {
        fs.mkdirSync(path, true);
      }
    } catch (err) {
      Logger.error('RemoteCache', `创建缓存目录失败 ${path}`, err as Error);
    }
  }

  private indexFile(): string {
    return `${this.root}/index.json`;
  }

  private loadIndex(): void {
    this.index = [];
    try {
      if (!fs.accessSync(this.indexFile())) {
        return;
      }
      const text: string = fs.readTextSync(this.indexFile());
      if (text.length === 0) {
        return;
      }
      const parsed: IndexRecord[] = JSON.parse(text) as IndexRecord[];
      for (const item of parsed) {
        this.index.push(item);
      }
    } catch (err) {
      Logger.warn('RemoteCache', '读取缓存索引失败');
      this.index = [];
    }
  }

  private saveIndex(): void {
    try {
      RemoteCache.writeTextFile(this.indexFile(), JSON.stringify(this.index));
    } catch (err) {
      Logger.error('RemoteCache', '写入缓存索引失败', err as Error);
    }
  }

  private static writeTextFile(path: string, text: string): void {
    const file: fs.File = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, text);
    } finally {
      fs.closeSync(file);
    }
  }

  private async keyOf(path: string): Promise<string> {
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    await md.update({ data: this.encoder.encodeInto(path) });
    const digest: cryptoFramework.DataBlob = await md.digest();
    let hex: string = '';
    const bytes: Uint8Array = digest.data;
    for (let i = 0; i < bytes.length; i++) {
      const part: string = bytes[i].toString(16);
      hex += part.length === 1 ? `0${part}` : part;
    }
    return hex;
  }

  private entryDir(sourceId: string, key: string): string {
    return `${this.root}/${sourceId}/${key}`;
  }

  dataPath(sourceId: string, key: string): string {
    return `${this.entryDir(sourceId, key)}/data`;
  }

  /** 命中且完整的缓存文件路径 */
  async find(sourceId: string, path: string): Promise<string> {
    const key: string = await this.keyOf(path);
    const data: string = this.dataPath(sourceId, key);
    try {
      if (!fs.accessSync(data)) {
        return '';
      }
      const metaPath: string = `${this.entryDir(sourceId, key)}/meta.json`;
      if (fs.accessSync(metaPath)) {
        const meta: CacheEntryMeta = JSON.parse(fs.readTextSync(metaPath)) as CacheEntryMeta;
        if (meta.complete !== true) {
          return '';
        }
      }
      this.touch(key);
      return data;
    } catch (err) {
      return '';
    }
  }

  /** 打开一个可写入的缓存文件（供流式下载使用），返回本地路径与 fd */
  async beginWrite(sourceId: string, path: string): Promise<string> {
    const key: string = await this.keyOf(path);
    this.ensureDir(`${this.root}/${sourceId}`);
    this.ensureDir(this.entryDir(sourceId, key));
    const data: string = this.dataPath(sourceId, key);
    const file: fs.File = fs.openSync(data, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    fs.closeSync(file);
    this.upsert(key, sourceId, path, 0);
    return data;
  }

  async finishWrite(sourceId: string, path: string, size: number, complete: boolean): Promise<void> {
    const key: string = await this.keyOf(path);
    const meta: CacheEntryMeta = {
      sourceId: sourceId,
      path: path,
      size: size,
      complete: complete,
      updatedAt: Date.now()
    };
    try {
      RemoteCache.writeTextFile(`${this.entryDir(sourceId, key)}/meta.json`, JSON.stringify(meta));
    } catch (err) {
      throw new FsError(FsErrorKind.CACHE, (err as Error).message);
    }
    this.upsert(key, sourceId, path, size);
    this.saveIndex();
  }

  private upsert(key: string, sourceId: string, path: string, size: number): void {
    for (let i = 0; i < this.index.length; i++) {
      if (this.index[i].key === key) {
        this.index[i].size = size;
        this.index[i].updatedAt = Date.now();
        return;
      }
    }
    this.index.push({ key: key, sourceId: sourceId, path: path, size: size, updatedAt: Date.now() });
  }

  private touch(key: string): void {
    for (let i = 0; i < this.index.length; i++) {
      if (this.index[i].key === key) {
        this.index[i].updatedAt = Date.now();
        return;
      }
    }
  }

  /** 统计缓存文件数与总大小 */
  stats(): CacheStats {
    let count: number = 0;
    let bytes: number = 0;
    for (const item of this.index) {
      const size: number = this.sizeOf(item.sourceId, item.key);
      if (size > 0) {
        count++;
        bytes += size;
      }
    }
    return { fileCount: count, totalBytes: bytes };
  }

  private sizeOf(sourceId: string, key: string): number {
    try {
      const stat: fs.Stat = fs.statSync(this.dataPath(sourceId, key));
      return stat.size;
    } catch (err) {
      return 0;
    }
  }

  /** 清理全部缓存（不影响来源配置） */
  clearAll(): void {
    try {
      fs.rmdirSync(this.root);
    } catch (err) {
      Logger.warn('RemoteCache', '删除缓存目录失败');
    }
    this.index = [];
    this.ensureDir(this.root);
    this.saveIndex();
  }

  /** 按上限做 LRU 清理 */
  pruneToLimit(limitMb: number): void {
    const limitBytes: number = limitMb * 1024 * 1024;
    const ordered: IndexRecord[] = this.index.slice();
    ordered.sort((a: IndexRecord, b: IndexRecord): number => a.updatedAt - b.updatedAt);
    let total: number = 0;
    for (const item of ordered) {
      total += this.sizeOf(item.sourceId, item.key);
    }
    const survivors: IndexRecord[] = [];
    for (const item of ordered) {
      if (total > limitBytes) {
        total -= this.sizeOf(item.sourceId, item.key);
        this.removeEntry(item);
      } else {
        survivors.push(item);
      }
    }
    this.index = survivors;
    this.saveIndex();
  }

  private removeEntry(item: IndexRecord): void {
    try {
      fs.rmdirSync(this.entryDir(item.sourceId, item.key));
    } catch (err) {
      Logger.warn('RemoteCache', 'LRU 删除失败');
    }
  }

  /**
   * 把远程文件完整下载到缓存，返回本地数据文件路径。
   * 使用 readRange 分块读取，避免整文件驻留内存（规范 §12）。
   */
  async download(client: FileSystemClient, sourceId: string, path: string, size: number,
    onProgress?: (received: number, total: number) => void): Promise<string> {
    const cached: string = await this.find(sourceId, path);
    if (cached.length > 0) {
      return cached;
    }
    const target: string = await this.beginWrite(sourceId, path);
    const file: fs.File = fs.openSync(target, fs.OpenMode.WRITE_ONLY);
    const chunkSize: number = 1024 * 1024;
    let offset: number = 0;
    let received: number = 0;
    try {
      while (true) {
        let buffer: ArrayBuffer;
        try {
          buffer = await client.readRange(path, offset, chunkSize);
        } catch (err) {
          throw new FsError(FsErrorKind.CACHE, (err as Error).message);
        }
        if (buffer.byteLength === 0) {
          break;
        }
        const written: number = fs.writeSync(file.fd, buffer);
        received += written;
        offset += buffer.byteLength;
        if (onProgress !== undefined) {
          onProgress(received, size);
        }
        if (buffer.byteLength < chunkSize) {
          break;
        }
      }
    } finally {
      try {
        fs.closeSync(file);
      } catch (err) {
        Logger.warn('RemoteCache', '关闭缓存文件失败');
      }
    }
    await this.finishWrite(sourceId, path, received, true);
    return target;
  }

  decode(bytes: Uint8Array): string {
    return this.decoder.decodeWithStream(bytes);
  }
}
