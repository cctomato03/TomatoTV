import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { FileEntry } from '../../model/FileEntry';
import { FileKinds } from '../../model/FileKinds';
import { FileSource, SourceType } from '../../model/FileSource';
import { FileSystemClient, FsError, FsErrorKind, PlayableMedia } from '../fs/FileSystemClient';
import { LocalFileSystem } from '../fs/LocalFileSystem';
import { WebDavFileSystem } from '../fs/WebDavFileSystem';
import { FtpFileSystem } from '../fs/FtpFileSystem';
import { SmbFileSystem } from '../fs/SmbFileSystem';
import { RemoteCache } from '../cache/RemoteCache';
import { SecretResolver } from './SecretResolver';
import { MediaStreamServer } from '../../utils/MediaStreamServer';
import { Logger } from '../../utils/Logger';

/**
 * 来源 -> FileSystemClient 的统一入口（规范 §8.1）。
 * 按来源 id 缓存 client；来源变更时由调用方 invalidate。
 */
export class FileRepository {
  private clients: Map<string, FileSystemClient> = new Map<string, FileSystemClient>();
  private resolver: SecretResolver;
  private cache: RemoteCache;

  constructor(resolver: SecretResolver, cache: RemoteCache) {
    this.resolver = resolver;
    this.cache = cache;
  }

  async clientFor(source: FileSource): Promise<FileSystemClient> {
    const existing: FileSystemClient | undefined = this.clients.get(source.id);
    if (existing !== undefined) {
      return existing;
    }
    let client: FileSystemClient;
    switch (source.type) {
      case SourceType.LOCAL:
        client = new LocalFileSystem(source.localUri);
        break;
      case SourceType.WEBDAV: {
        const password: string = await this.resolver.passwordOf(source);
        client = new WebDavFileSystem(source.url, source.username, password);
        break;
      }
      case SourceType.FTP: {
        const password: string = await this.resolver.passwordOf(source);
        client = new FtpFileSystem(source.host, source.port, source.username, password, source.rootPath, source.secure);
        break;
      }
      case SourceType.SMB: {
        const password: string = await this.resolver.passwordOf(source);
        client = new SmbFileSystem(source, password);
        break;
      }
      default:
        client = new SmbFileSystem(source, '');
        break;
    }
    this.clients.set(source.id, client);
    return client;
  }

  async invalidate(sourceId: string): Promise<void> {
    MediaStreamServer.get().release(sourceId);
    const client: FileSystemClient | undefined = this.clients.get(sourceId);
    this.clients.delete(sourceId);
    if (client !== undefined) {
      try {
        await client.close();
      } catch (err) {
        Logger.warn('FileRepository', '关闭来源连接失败');
      }
    }
  }

  async list(source: FileSource, path: string): Promise<FileEntry[]> {
    const client: FileSystemClient = await this.clientFor(source);
    return client.list(path);
  }

  async stat(source: FileSource, path: string): Promise<FileEntry> {
    const client: FileSystemClient = await this.clientFor(source);
    return client.stat(path);
  }

  async test(source: FileSource): Promise<void> {
    const client: FileSystemClient = await this.clientFor(source);
    await client.testConnection();
  }

  /** 就地物化：本机返回原路径（uri），远程先落缓存再返回本地路径 */
  async materializeToPath(source: FileSource, entry: FileEntry): Promise<string> {
    if (source.type === SourceType.LOCAL) {
      return entry.path;
    }
    const client: FileSystemClient = await this.clientFor(source);
    return this.cache.download(client, source.id, entry.path, entry.size);
  }

  /**
   * 媒体播放句柄：
   *  - 本机文件直接用 fd（零拷贝）；
   *  - 远程文件（音频与视频）都优先走本机回环 HTTP 代理，按 Range 边播边读，
   *    不整文件下载，起播快；
   *  - allowStream = false 或代理不可用时，才退回"整文件缓存 + fd"。
   */
  async playable(source: FileSource, entry: FileEntry, allowStream: boolean = true): Promise<PlayableMedia> {
    const mimeType: string = FileKinds.mimeOfKind(entry.kind, entry.name);
    if (source.type === SourceType.LOCAL) {
      const client: FileSystemClient = await this.clientFor(source);
      const local: LocalFileSystem = client as LocalFileSystem;
      return local.playable(entry.path, mimeType);
    }
    if (allowStream) {
      const client: FileSystemClient = await this.clientFor(source);
      const url: string = await MediaStreamServer.get().register(client, source.id, entry.path, entry.size, mimeType);
      if (url.length > 0) {
        return { fd: -1, path: '', url: url, mimeType: mimeType };
      }
    }
    const localPath: string = await this.materializeToPath(source, entry);
    const file: fs.File = fs.openSync(localPath, fs.OpenMode.READ_ONLY);
    return {
      fd: file.fd,
      path: localPath,
      url: '',
      mimeType: mimeType
    };
  }

  /** 读取文本预览内容（限制上限，自动处理 BOM 与常见编码） */
  async readText(source: FileSource, path: string, maxBytes: number): Promise<string> {
    const client: FileSystemClient = await this.clientFor(source);
    let bytes: ArrayBuffer;
    if (source.type === SourceType.LOCAL) {
      const local: LocalFileSystem = client as LocalFileSystem;
      bytes = local.readAll(path, maxBytes);
    } else {
      bytes = await client.readRange(path, 0, maxBytes);
    }
    return TextDecoderUtil.decode(bytes);
  }

  /** 读取文档原始字节（PDF / Office 离线预览用），分块读取避免整文件驻留 */
  async readDocument(source: FileSource, entry: FileEntry, maxBytes: number): Promise<ArrayBuffer> {
    const client: FileSystemClient = await this.clientFor(source);
    if (source.type === SourceType.LOCAL) {
      const local: LocalFileSystem = client as LocalFileSystem;
      return local.readAll(entry.path, maxBytes);
    }
    const size: number = entry.size > 0 ? Math.min(entry.size, maxBytes) : maxBytes;
    const chunkSize: number = 512 * 1024;
    const chunks: ArrayBuffer[] = [];
    let offset: number = 0;
    while (offset < size) {
      const want: number = Math.min(chunkSize, size - offset);
      const buffer: ArrayBuffer = await client.readRange(entry.path, offset, want);
      if (buffer.byteLength === 0) {
        break;
      }
      chunks.push(buffer);
      offset += buffer.byteLength;
      if (buffer.byteLength < want) {
        break;
      }
    }
    const merged: ArrayBuffer = new ArrayBuffer(offset);
    const view: Uint8Array = new Uint8Array(merged);
    let cursor: number = 0;
    for (const chunk of chunks) {
      view.set(new Uint8Array(chunk), cursor);
      cursor += chunk.byteLength;
    }
    return merged;
  }

  async closeAll(): Promise<void> {
    const ids: string[] = [];
    this.clients.forEach((value: FileSystemClient, key: string) => {
      ids.push(key);
    });
    for (const id of ids) {
      await this.invalidate(id);
    }
  }
}

export class TextDecoderUtil {
  /** 编码探测：UTF-8 BOM / UTF-16 BOM / GBK 回退（规范 §7.6） */
  static decode(buffer: ArrayBuffer): string {
    const bytes: Uint8Array = new Uint8Array(buffer);
    if (bytes.length >= 3 && bytes[0] === 0xEF && bytes[1] === 0xBB && bytes[2] === 0xBF) {
      return TextDecoderUtil.decodeWith(buffer.slice(3) as ArrayBuffer, 'utf-8');
    }
    if (bytes.length >= 2 && bytes[0] === 0xFF && bytes[1] === 0xFE) {
      return TextDecoderUtil.decodeWith(buffer.slice(2) as ArrayBuffer, 'utf-16le');
    }
    if (bytes.length >= 2 && bytes[0] === 0xFE && bytes[1] === 0xFF) {
      return TextDecoderUtil.decodeWith(buffer.slice(2) as ArrayBuffer, 'utf-16be');
    }
    const utf8: string = TextDecoderUtil.decodeWith(buffer, 'utf-8');
    if (utf8.indexOf('\uFFFD') < 0) {
      return utf8;
    }
    const gbk: string = TextDecoderUtil.decodeWith(buffer, 'gbk');
    if (gbk.indexOf('\uFFFD') < 0) {
      return gbk;
    }
    return utf8;
  }

  static decodeWith(buffer: ArrayBuffer, encoding: string): string {
    try {
      const decoder: util.TextDecoder = util.TextDecoder.create(encoding, { ignoreBOM: true });
      return decoder.decodeWithStream(new Uint8Array(buffer));
    } catch (err) {
      Logger.warn('TextDecoderUtil', `不支持的编码 ${encoding}`);
      return '';
    }
  }
}
