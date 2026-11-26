import { FileEntry } from '../../model/FileEntry';
import { FileSource } from '../../model/FileSource';
import { FsError, FsErrorKind, FileSystemClient, InputStreamLike } from './FileSystemClient';
import { Smb2Client, Smb2Options } from '../smb/Smb2Client';
import { Logger } from '../../utils/Logger';

class SmbStream implements InputStreamLike {
  private client: Smb2Client;
  private path: string;
  private cursor: number;
  private ended: boolean = false;

  constructor(client: Smb2Client, path: string, start: number) {
    this.client = client;
    this.path = path;
    this.cursor = start;
  }

  async read(buffer: ArrayBuffer): Promise<number> {
    if (this.ended) {
      return 0;
    }
    const data: ArrayBuffer = await this.client.readRange(this.path, this.cursor, buffer.byteLength);
    if (data.byteLength === 0) {
      this.ended = true;
      return 0;
    }
    const view: Uint8Array = new Uint8Array(data);
    new Uint8Array(buffer, 0, Math.min(view.length, buffer.byteLength)).set(view.subarray(0, buffer.byteLength));
    this.cursor += view.length;
    return view.length;
  }

  async close(): Promise<void> {
    this.ended = true;
  }
}

/**
 * SMB 2.0.2 / 2.1 来源（纯 ArkTS 实现，见 data/smb/Smb2Client.ets）。
 * 支持 NTLMv2 域名认证、报文签名、目录枚举、按需随机读。
 * 未实现：SMB 3.x 加密、DFS、写操作。
 */
export class SmbFileSystem implements FileSystemClient {
  private source: FileSource;
  private password: string;
  private client: Smb2Client | null = null;
  private connecting: boolean = false;

  constructor(source: FileSource, password: string) {
    this.source = source;
    this.password = password;
  }

  private async ensure(): Promise<Smb2Client> {
    if (this.client !== null) {
      return this.client;
    }
    if (this.connecting) {
      throw new FsError(FsErrorKind.NETWORK, 'SMB 正在连接中');
    }
    this.connecting = true;
    const options: Smb2Options = Smb2Client.optionsFromSource(this.source, this.password);
    if (options.share.length === 0) {
      throw new FsError(FsErrorKind.UNSUPPORTED, 'SMB 来源缺少共享名');
    }
    const client: Smb2Client = new Smb2Client(options);
    try {
      await client.connect();
      this.client = client;
      return client;
    } catch (err) {
      await client.close();
      Logger.error('SmbFileSystem', 'SMB 连接失败', err as Error);
      throw err instanceof FsError ? err : new FsError(FsErrorKind.NETWORK,
        err instanceof Error ? err.message : '');
    } finally {
      this.connecting = false;
    }
  }

  async list(path: string): Promise<FileEntry[]> {
    const client: Smb2Client = await this.ensure();
    return client.list(path);
  }

  async stat(path: string): Promise<FileEntry> {
    const client: Smb2Client = await this.ensure();
    return client.stat(path);
  }

  async openStream(path: string, position?: number): Promise<InputStreamLike> {
    const client: Smb2Client = await this.ensure();
    return new SmbStream(client, path, position === undefined ? 0 : position);
  }

  async readRange(path: string, position: number, length: number): Promise<ArrayBuffer> {
    const client: Smb2Client = await this.ensure();
    return client.readRange(path, position, length);
  }

  async testConnection(): Promise<void> {
    const client: Smb2Client = await this.ensure();
    await client.test();
  }

  async close(): Promise<void> {
    const client: Smb2Client | null = this.client;
    this.client = null;
    if (client !== null) {
      await client.close();
    }
  }
}
