import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { FileEntry, FileEntryFactory } from '../../model/FileEntry';
import { FileKinds } from '../../model/FileKinds';
import { SourceUrl } from '../../model/FileSource';
import { FsError, FsErrorKind, FileSystemClient, InputStreamLike } from './FileSystemClient';
import { DavItem, WebDavXml } from './WebDavXml';
import { Logger } from '../../utils/Logger';

const PROPFIND_BODY: string = '<?xml version="1.0" encoding="utf-8"?>' +
  '<d:propfind xmlns:d="DAV:"><d:prop>' +
  '<d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getcontenttype/>' +
  '</d:prop></d:propfind>';

class DavStream implements InputStreamLike {
  private buffer: ArrayBuffer;
  private cursor: number = 0;

  constructor(buffer: ArrayBuffer) {
    this.buffer = buffer;
  }

  async read(target: ArrayBuffer): Promise<number> {
    const remaining: number = this.buffer.byteLength - this.cursor;
    if (remaining <= 0) {
      return 0;
    }
    const length: number = Math.min(remaining, target.byteLength);
    const source: Uint8Array = new Uint8Array(this.buffer, this.cursor, length);
    new Uint8Array(target, 0, length).set(source);
    this.cursor += length;
    return length;
  }

  async close(): Promise<void> {
    this.cursor = this.buffer.byteLength;
  }
}

/**
 * WebDAV（规范 §8.3）：PROPFIND Depth 1 列表、Basic Auth、Range 读取、错误码映射。
 */
export class WebDavFileSystem implements FileSystemClient {
  private baseUrl: string;
  private authHeader: string;

  constructor(baseUrl: string, username: string, password: string) {
    let base: string = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    this.baseUrl = base;
    this.authHeader = WebDavFileSystem.basicAuth(username, password);
  }

  private static basicAuth(username: string, password: string): string {
    if (username.length === 0 && password.length === 0) {
      return '';
    }
    const encoder: util.TextEncoder = new util.TextEncoder('utf-8');
    const bytes: Uint8Array = encoder.encodeInto(`${username}:${password}`);
    const helper: util.Base64Helper = new util.Base64Helper();
    try {
      return `Basic ${helper.encodeToStringSync(bytes)}`;
    } catch (err) {
      Logger.warn('WebDav', '凭据编码失败');
      return '';
    }
  }

  /** 逻辑路径 -> 绝对 URL，逐段编码 */
  urlFor(path: string): string {
    const encoded: string = SourceUrl.encodePath(path);
    if (encoded.length === 0) {
      return this.baseUrl;
    }
    return `${this.baseUrl}/${encoded}`;
  }

  private davOptions(depth: string): http.HttpRequestOptions {
    if (this.authHeader.length === 0) {
      const plain: http.HttpRequestOptions = {
        method: 'PROPFIND' as http.RequestMethod,
        header: {
          'Depth': depth,
          'Content-Type': 'application/xml; charset=utf-8',
          'Accept': 'application/xml, text/xml'
        },
        extraData: PROPFIND_BODY,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 30000
      };
      return plain;
    }
    const signed: http.HttpRequestOptions = {
      method: 'PROPFIND' as http.RequestMethod,
      header: {
        'Depth': depth,
        'Content-Type': 'application/xml; charset=utf-8',
        'Accept': 'application/xml, text/xml',
        'Authorization': this.authHeader
      },
      extraData: PROPFIND_BODY,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 15000,
      readTimeout: 30000
    };
    return signed;
  }

  private rangeOptions(position: number, length: number): http.HttpRequestOptions {
    const range: string = `bytes=${position}-${position + length - 1}`;
    if (this.authHeader.length === 0) {
      const plain: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: { 'Range': range },
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000,
        readTimeout: 60000
      };
      return plain;
    }
    const signed: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: { 'Range': range, 'Authorization': this.authHeader },
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 15000,
      readTimeout: 60000
    };
    return signed;
  }

  private static mapStatus(code: number): FsError {
    if (code === 401 || code === 403) {
      return new FsError(FsErrorKind.AUTH, `http ${code}`);
    }
    if (code === 404) {
      return new FsError(FsErrorKind.NOT_FOUND, 'http 404');
    }
    if (code >= 500) {
      return new FsError(FsErrorKind.SERVER, `http ${code}`);
    }
    return new FsError(FsErrorKind.NETWORK, `http ${code}`);
  }

  private static mapException(err: Error): FsError {
    const code: number = (err as BusinessError).code;
    if (code === 2300028) {
      return new FsError(FsErrorKind.TIMEOUT, err.message);
    }
    if (code === 2300006 || code === 2300007 || code === 2300005) {
      return new FsError(FsErrorKind.NETWORK, err.message);
    }
    return new FsError(FsErrorKind.NETWORK, err.message);
  }

  private async propfind(path: string, depth: string): Promise<string> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(this.urlFor(path), this.davOptions(depth));
      const status: number = response.responseCode;
      if (status !== 207 && status !== 200) {
        throw WebDavFileSystem.mapStatus(status);
      }
      const body: string = typeof response.result === 'string' ? response.result as string : '';
      return body;
    } catch (err) {
      throw WebDavFileSystem.mapException(err as Error);
    } finally {
      request.destroy();
    }
  }

  /** 取 URL 的路径部分，用于过滤 PROPFIND 返回的自身条目 */
  private static pathPartOfUrl(url: string): string {
    const schemeIndex: number = url.indexOf('://');
    const rest: string = schemeIndex < 0 ? url : url.substring(schemeIndex + 3);
    const slash: number = rest.indexOf('/');
    return slash < 0 ? '/' : rest.substring(slash);
  }

  static trimTrailingSlash(path: string): string {
    let out: string = path;
    while (out.length > 1 && out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  async list(path: string): Promise<FileEntry[]> {
    const xml: string = await this.propfind(path, '1');
    const items: DavItem[] = WebDavXml.parse(xml);
    const selfPath: string = WebDavFileSystem.trimTrailingSlash(
      WebDavFileSystem.pathPartOfUrl(this.urlFor(path)));
    const entries: FileEntry[] = [];
    for (const item of items) {
      const itemPath: string = WebDavFileSystem.trimTrailingSlash(WebDavXml.pathOfHref(item.href));
      if (itemPath.length === 0 || itemPath === selfPath) {
        continue;
      }
      const childPath: string = PathJoin.of(path, item.name, item.isDirectory);
      if (item.isDirectory) {
        entries.push(FileEntryFactory.directory(item.name, childPath, item.modified));
      } else {
        entries.push(FileEntryFactory.file(item.name, childPath, item.size, item.modified, ''));
      }
    }
    return entries;
  }

  async stat(path: string): Promise<FileEntry> {
    const xml: string = await this.propfind(path, '0');
    const items: DavItem[] = WebDavXml.parse(xml);
    if (items.length === 0) {
      throw new FsError(FsErrorKind.NOT_FOUND, 'empty propfind');
    }
    const item: DavItem = items[0];
    const name: string = item.name.length > 0 ? item.name : SourceUrl.tailOfUri(path);
    if (item.isDirectory) {
      return FileEntryFactory.directory(name, path, item.modified);
    }
    return FileEntryFactory.file(name, path, item.size, item.modified, '');
  }

  async readRange(path: string, position: number, length: number): Promise<ArrayBuffer> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(this.urlFor(path),
        this.rangeOptions(position, length));
      const status: number = response.responseCode;
      if (status === 416) {
        return new ArrayBuffer(0);
      }
      if (status !== 200 && status !== 206) {
        throw WebDavFileSystem.mapStatus(status);
      }
      if (response.result instanceof ArrayBuffer) {
        return response.result as ArrayBuffer;
      }
      return new ArrayBuffer(0);
    } catch (err) {
      throw WebDavFileSystem.mapException(err as Error);
    } finally {
      request.destroy();
    }
  }

  async openStream(path: string, position?: number): Promise<InputStreamLike> {
    const start: number = position === undefined ? 0 : position;
    const buffer: ArrayBuffer = await this.readRange(path, start, 1024 * 1024);
    return new DavStream(buffer);
  }

  async testConnection(): Promise<void> {
    await this.propfind('/', '0');
  }

  async close(): Promise<void> {
  }

  static mimeFor(name: string): string {
    return FileKinds.mimeOfKind(FileKinds.kindOf(name), name);
  }
}

/** 远程逻辑路径拼接 */
export class PathJoin {
  static of(parent: string, name: string, isDirectory: boolean): string {
    const normalizedParent: string = parent.length === 0 ? '/' : parent;
    const full: string = normalizedParent.endsWith('/') ? `${normalizedParent}${name}` : `${normalizedParent}/${name}`;
    if (isDirectory && !full.endsWith('/')) {
      return `${full}/`;
    }
    if (!isDirectory && full.endsWith('/')) {
      return full.substring(0, full.length - 1);
    }
    return full;
  }

  static trimTrailingSlash(path: string): string {
    let out: string = path;
    while (out.length > 1 && out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }
}
