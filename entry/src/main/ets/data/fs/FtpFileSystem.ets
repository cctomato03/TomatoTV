import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { FileEntry, FileEntryFactory } from '../../model/FileEntry';
import { SourceUrl } from '../../model/FileSource';
import { FsError, FsErrorKind, FileSystemClient, InputStreamLike } from './FileSystemClient';
import { PathJoin } from './WebDavFileSystem';
import { Logger } from '../../utils/Logger';

class FtpReply {
  code: number;
  text: string;

  constructor(code: number, text: string) {
    this.code = code;
    this.text = text;
  }
}

interface ReplyWaiter {
  resolve: (reply: FtpReply) => void;
}

class ByteSink implements InputStreamLike {
  private data: ArrayBuffer;
  private cursor: number = 0;

  constructor(data: ArrayBuffer) {
    this.data = data;
  }

  async read(target: ArrayBuffer): Promise<number> {
    const remaining: number = this.data.byteLength - this.cursor;
    if (remaining <= 0) {
      return 0;
    }
    const length: number = Math.min(remaining, target.byteLength);
    new Uint8Array(target, 0, length).set(new Uint8Array(this.data, this.cursor, length));
    this.cursor += length;
    return length;
  }

  async close(): Promise<void> {
    this.cursor = this.data.byteLength;
  }
}

/** FTP 控制/数据通道抽象：明文走 TCPSocket，隐式 FTPS 走 TLSSocket */
interface FtpChannel {
  send(data: string | ArrayBuffer): Promise<void>;
  close(): Promise<void>;
  onMessage(callback: (message: ArrayBuffer) => void): void;
  onClose(callback: () => void): void;
}

class TcpChannel implements FtpChannel {
  private socketInstance: socket.TCPSocket;

  constructor(instance: socket.TCPSocket) {
    this.socketInstance = instance;
  }

  async send(data: string | ArrayBuffer): Promise<void> {
    await this.socketInstance.send({ data: data });
  }

  async close(): Promise<void> {
    await this.socketInstance.close();
  }

  onMessage(callback: (message: ArrayBuffer) => void): void {
    this.socketInstance.on('message', (info: socket.SocketMessageInfo) => {
      callback(info.message);
    });
  }

  onClose(callback: () => void): void {
    this.socketInstance.on('close', () => {
      callback();
    });
  }
}

class TlsChannel implements FtpChannel {
  private socketInstance: socket.TLSSocket;

  constructor(instance: socket.TLSSocket) {
    this.socketInstance = instance;
  }

  async send(data: string | ArrayBuffer): Promise<void> {
    await this.socketInstance.send(data);
  }

  async close(): Promise<void> {
    await this.socketInstance.close();
  }

  onMessage(callback: (message: ArrayBuffer) => void): void {
    this.socketInstance.on('message', (info: socket.SocketMessageInfo) => {
      callback(info.message);
    });
  }

  onClose(callback: () => void): void {
    this.socketInstance.on('close', () => {
      callback();
    });
  }
}

async function openChannel(host: string, port: number, secure: boolean): Promise<FtpChannel> {
  const address: socket.NetAddress = { address: host, port: port, family: 1 };
  if (secure) {
    const tls: socket.TLSSocket = socket.constructTLSSocketInstance();
    const secureOptions: socket.TLSSecureOptions = { protocols: socket.Protocol.TLSv12 };
    const options: socket.TLSConnectOptions = {
      address: address,
      secureOptions: secureOptions,
      timeout: 15000
    };
    await tls.connect(options);
    return new TlsChannel(tls);
  }
  const tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
  const tcpOptions: socket.TCPConnectOptions = { address: address, timeout: 15000 };
  await tcp.connect(tcpOptions);
  return new TcpChannel(tcp);
}

/** 极简 FTP 客户端：支持 PASV / USER / PASS / MLSD / LIST / SIZE / MDTM / REST / RETR，支持隐式 FTPS */
class FtpClient {
  private control: FtpChannel | null = null;
  private secure: boolean = false;
  private raw: string = '';
  private multiCode: string = '';
  private multiText: string = '';
  private waiters: ReplyWaiter[] = [];
  private queue: FtpReply[] = [];
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  private joined: boolean = false;

  async connect(host: string, port: number, secure: boolean): Promise<void> {
    this.secure = secure;
    const control: FtpChannel = await openChannel(host, port, secure);
    this.control = control;
    control.onMessage((message: ArrayBuffer) => {
      this.feed(this.decoder.decodeWithStream(new Uint8Array(message)));
    });
    control.onClose(() => {
      this.flushWaiters();
    });
    const banner: FtpReply = await this.read();
    if (banner.code !== 220) {
      if (secure) {
        throw new FsError(FsErrorKind.UNSUPPORTED,
          '服务器未在 TLS 上返回 FTP 欢迎信息，可能只支持显式 FTPS（AUTH TLS），当前版本暂不支持');
      }
      throw new FsError(FsErrorKind.NETWORK, `ftp banner ${banner.code}`);
    }
  }

  private flushWaiters(): void {
    const pending: ReplyWaiter[] = this.waiters;
    this.waiters = [];
    for (const waiter of pending) {
      waiter.resolve(new FtpReply(421, 'connection closed'));
    }
  }

  private feed(chunk: string): void {
    this.raw += chunk;
    let index: number = this.raw.indexOf('\n');
    while (index >= 0) {
      const line: string = this.raw.substring(0, index).replace(/\r$/, '');
      this.raw = this.raw.substring(index + 1);
      this.onLine(line);
      index = this.raw.indexOf('\n');
    }
  }

  private onLine(line: string): void {
    if (this.multiCode.length === 0) {
      const match: RegExpExecArray | null = /^(\d{3})([ -])(.*)$/.exec(line);
      if (match === null) {
        return;
      }
      const code: string = match[1];
      if (match[2] === '-') {
        this.multiCode = code;
        this.multiText = `${line}\n`;
        return;
      }
      this.pushReply(new FtpReply(Number(code), line));
      return;
    }
    this.multiText += `${line}\n`;
    if (line.startsWith(`${this.multiCode} `)) {
      const code: number = Number(this.multiCode);
      const text: string = this.multiText;
      this.multiCode = '';
      this.multiText = '';
      this.pushReply(new FtpReply(code, text));
    }
  }

  private pushReply(reply: FtpReply): void {
    const waiter: ReplyWaiter | undefined = this.waiters.shift();
    if (waiter !== undefined) {
      waiter.resolve(reply);
      return;
    }
    this.queue.push(reply);
  }

  private read(): Promise<FtpReply> {
    if (this.queue.length > 0) {
      const reply: FtpReply = this.queue.shift() as FtpReply;
      return Promise.resolve(reply);
    }
    return new Promise<FtpReply>((resolve: (reply: FtpReply) => void) => {
      this.waiters.push({ resolve: resolve });
    });
  }

  async send(line: string): Promise<void> {
    if (this.control === null) {
      throw new FsError(FsErrorKind.NETWORK, 'control socket closed');
    }
    await this.control.send(`${line}\r\n`);
  }

  async command(line: string): Promise<FtpReply> {
    await this.send(line);
    return this.read();
  }

  async login(username: string, password: string): Promise<void> {
    const user: string = username.length > 0 ? username : 'anonymous';
    const userReply: FtpReply = await this.command(`USER ${user}`);
    if (userReply.code === 230) {
      this.joined = true;
      return;
    }
    if (userReply.code !== 331 && userReply.code !== 332) {
      throw new FsError(FsErrorKind.AUTH, `USER ${userReply.code}`);
    }
    const passReply: FtpReply = await this.command(`PASS ${password}`);
    if (passReply.code !== 230 && passReply.code !== 202) {
      throw new FsError(FsErrorKind.AUTH, `PASS ${passReply.code}`);
    }
    this.joined = true;
  }

  /** 打开被动模式数据连接 */
  private async openPassive(): Promise<FtpChannel> {
    const reply: FtpReply = await this.command('PASV');
    if (reply.code !== 227) {
      throw new FsError(FsErrorKind.NETWORK, `PASV ${reply.code}`);
    }
    const numbers: RegExpMatchArray | null = reply.text.match(/(\d+),(\d+),(\d+),(\d+),(\d+),(\d+)/);
    if (numbers === null) {
      throw new FsError(FsErrorKind.NETWORK, 'PASV 响应解析失败');
    }
    const host: string = `${numbers[1]}.${numbers[2]}.${numbers[3]}.${numbers[4]}`;
    const port: number = Number(numbers[5]) * 256 + Number(numbers[6]);
    return openChannel(host, port, this.secure);
  }

  /** 拉取一次数据传输的完整内容 */
  private async fetch(passive: FtpChannel): Promise<ArrayBuffer> {
    const chunks: ArrayBuffer[] = [];
    let received: number = 0;
    let done: boolean = false;
    let resolver: (() => void) | null = null;
    const completion: Promise<void> = new Promise<void>((resolve: () => void) => {
      resolver = resolve;
    });
    passive.onMessage((message: ArrayBuffer) => {
      chunks.push(message);
      received += message.byteLength;
    });
    passive.onClose(() => {
      if (!done) {
        done = true;
        if (resolver !== null) {
          resolver();
        }
      }
    });
    await completion;
    const merged: ArrayBuffer = new ArrayBuffer(received);
    const view: Uint8Array = new Uint8Array(merged);
    let offset: number = 0;
    for (const chunk of chunks) {
      view.set(new Uint8Array(chunk), offset);
      offset += chunk.byteLength;
    }
    return merged;
  }

  async listRaw(path: string): Promise<string> {
    const passive: FtpChannel = await this.openPassive();
    const reply: FtpReply = await this.command(`MLSD ${path}`);
    if (reply.code !== 150 && reply.code !== 125) {
      await passive.close();
      throw new FsError(FsErrorKind.NOT_FOUND, `MLSD ${reply.code}`);
    }
    const data: ArrayBuffer = await this.fetch(passive);
    await passive.close();
    await this.read();
    return this.decoder.decodeWithStream(new Uint8Array(data));
  }

  async listFallback(path: string): Promise<string> {
    const passive: FtpChannel = await this.openPassive();
    const reply: FtpReply = await this.command(`LIST ${path}`);
    if (reply.code !== 150 && reply.code !== 125) {
      await passive.close();
      throw new FsError(FsErrorKind.NOT_FOUND, `LIST ${reply.code}`);
    }
    const data: ArrayBuffer = await this.fetch(passive);
    await passive.close();
    await this.read();
    return this.decoder.decodeWithStream(new Uint8Array(data));
  }

  async retrieve(path: string, position: number, length: number): Promise<ArrayBuffer> {
    const passive: FtpChannel = await this.openPassive();
    if (position > 0) {
      const restReply: FtpReply = await this.command(`REST ${position}`);
      if (restReply.code !== 350) {
        await passive.close();
        throw new FsError(FsErrorKind.SERVER, `REST ${restReply.code}`);
      }
    }
    const reply: FtpReply = await this.command(`RETR ${path}`);
    if (reply.code !== 150 && reply.code !== 125) {
      await passive.close();
      throw new FsError(FsErrorKind.NOT_FOUND, `RETR ${reply.code}`);
    }
    const chunks: ArrayBuffer[] = [];
    let received: number = 0;
    let resolveDone: (() => void) | null = null;
    const completion: Promise<void> = new Promise<void>((resolve: () => void) => {
      resolveDone = resolve;
    });
    const finish = (): void => {
      if (resolveDone !== null) {
        const fn: () => void = resolveDone;
        resolveDone = null;
        fn();
      }
    };
    passive.onMessage((message: ArrayBuffer) => {
      chunks.push(message);
      received += message.byteLength;
      if (received >= length) {
        finish();
      }
    });
    passive.onClose(() => {
      finish();
    });
    await completion;
    try {
      await passive.close();
    } catch (err) {
      Logger.warn('Ftp', '关闭数据连接失败');
    }
    try {
      await this.send('ABOR');
      await this.read();
    } catch (err) {
      Logger.warn('Ftp', 'ABOR 失败');
    }
    const merged: ArrayBuffer = new ArrayBuffer(received);
    new Uint8Array(merged).set(new Uint8Array(chunks[0] === undefined ? new ArrayBuffer(0) : chunks[0]), 0);
    if (chunks.length > 1) {
      let offset: number = chunks[0].byteLength;
      for (let i = 1; i < chunks.length; i++) {
        new Uint8Array(merged).set(new Uint8Array(chunks[i]), offset);
        offset += chunks[i].byteLength;
      }
    }
    return merged;
  }

  async size(path: string): Promise<number> {
    const reply: FtpReply = await this.command(`SIZE ${path}`);
    if (reply.code !== 213) {
      return -1;
    }
    const value: number = Number(reply.text.replace(/^213\s*/, '').trim());
    return Number.isFinite(value) ? value : -1;
  }

  async modified(path: string): Promise<number> {
    const reply: FtpReply = await this.command(`MDTM ${path}`);
    if (reply.code !== 213) {
      return 0;
    }
    const stamp: string = reply.text.replace(/^213\s*/, '').trim();
    const match: RegExpExecArray | null = /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})/.exec(stamp);
    if (match === null) {
      return 0;
    }
    const year: number = Number(match[1]);
    const month: number = Number(match[2]) - 1;
    const day: number = Number(match[3]);
    const hour: number = Number(match[4]);
    const minute: number = Number(match[5]);
    const second: number = Number(match[6]);
    return Date.UTC(year, month, day, hour, minute, second);
  }

  async changeDirectory(path: string): Promise<boolean> {
    const reply: FtpReply = await this.command(`CWD ${path}`);
    return reply.code === 250 || reply.code === 200;
  }

  isReady(): boolean {
    return this.joined;
  }

  async close(): Promise<void> {
    if (this.control === null) {
      return;
    }
    try {
      await this.send('QUIT');
    } catch (err) {
      Logger.warn('Ftp', 'QUIT 失败');
    }
    try {
      await this.control.close();
    } catch (err) {
      Logger.warn('Ftp', `关闭控制连接失败 ${(err as BusinessError).code}`);
    }
    this.control = null;
  }
}

/**
 * FTP / FTPS 来源（规范 §8.5）。
 * 已实现：PASV、USER/PASS、MLSD（回退 LIST）、SIZE、MDTM、REST+RETR 随机读；
 * 隐式 FTPS（Implicit TLS，默认端口 990）通过 TLSSocket 建立控制与数据通道。
 * 未实现：显式 FTPS（AUTH TLS / STARTTLS）——当前 SDK 无法在已连接的明文 socket 上升级 TLS，
 * 若服务器只支持显式 FTPS 会返回明确提示而不是静默失败（见 docs/DEVIATIONS.md）。
 */
export class FtpFileSystem implements FileSystemClient {
  private host: string;
  private port: number;
  private username: string;
  private password: string;
  private rootPath: string;
  private secure: boolean;
  private client: FtpClient | null = null;

  constructor(host: string, port: number, username: string, password: string, rootPath: string, secure: boolean) {
    this.host = host;
    this.secure = secure;
    this.port = port > 0 ? port : (secure ? 990 : 21);
    this.username = username;
    this.password = password;
    this.rootPath = SourceUrl.trimSlashes(rootPath);
  }

  private async ensure(): Promise<FtpClient> {
    if (this.client !== null) {
      return this.client;
    }
    const client: FtpClient = new FtpClient();
    try {
      await client.connect(this.host, this.port, this.secure);
      await client.login(this.username, this.password);
      await client.command('TYPE I');
    } catch (err) {
      await client.close();
      throw err instanceof FsError ? err : new FsError(FsErrorKind.NETWORK,
        err instanceof Error ? err.message : '');
    }
    this.client = client;
    return client;
  }

  private remotePath(path: string): string {
    const clean: string = PathJoin.trimTrailingSlash(path.length === 0 ? '/' : path);
    const relative: string = clean === '/' ? '' : clean.substring(1);
    const joined: string = this.rootPath.length === 0
      ? relative
      : (relative.length === 0 ? this.rootPath : `${this.rootPath}/${relative}`);
    return joined.length === 0 ? '/' : `/${joined}`;
  }

  private static parseMlsd(text: string, parent: string): FileEntry[] {
    const entries: FileEntry[] = [];
    const lines: string[] = text.split('\n');
    for (const rawLine of lines) {
      const line: string = rawLine.replace(/\r$/, '').trim();
      if (line.length === 0) {
        continue;
      }
      const space: number = line.indexOf(' ');
      if (space <= 0) {
        continue;
      }
      const facts: string = line.substring(0, space);
      const name: string = line.substring(space + 1).trim();
      if (name === '.' || name === '..' || name.length === 0) {
        continue;
      }
      let isDirectory: boolean = false;
      let size: number = 0;
      let modified: number = 0;
      for (const fact of facts.split(';')) {
        const eq: number = fact.indexOf('=');
        if (eq < 0) {
          continue;
        }
        const key: string = fact.substring(0, eq).toLowerCase();
        const value: string = fact.substring(eq + 1);
        if (key === 'type') {
          isDirectory = value.toLowerCase() === 'dir';
        } else if (key === 'size') {
          const parsed: number = Number(value);
          size = Number.isFinite(parsed) ? parsed : 0;
        } else if (key === 'modify') {
          const match: RegExpExecArray | null = /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})/.exec(value);
          if (match !== null) {
            modified = Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3]),
              Number(match[4]), Number(match[5]), Number(match[6]));
          }
        }
      }
      const childPath: string = PathJoin.of(parent, name, isDirectory);
      if (isDirectory) {
        entries.push(FileEntryFactory.directory(name, childPath, modified));
      } else {
        entries.push(FileEntryFactory.file(name, childPath, size, modified, ''));
      }
    }
    return entries;
  }

  private static parseList(text: string, parent: string): FileEntry[] {
    const entries: FileEntry[] = [];
    const lines: string[] = text.split('\n');
    for (const rawLine of lines) {
      const line: string = rawLine.replace(/\r$/, '');
      if (line.length < 10) {
        continue;
      }
      const first: string = line.substring(0, 1);
      if (first !== '-' && first !== 'd' && first !== 'l') {
        continue;
      }
      const parts: string[] = line.split(/\s+/);
      if (parts.length < 9) {
        continue;
      }
      const isDirectory: boolean = first === 'd';
      const size: number = Number(parts[4]);
      const name: string = parts.slice(8).join(' ');
      if (name === '.' || name === '..') {
        continue;
      }
      const childPath: string = PathJoin.of(parent, name, isDirectory);
      if (isDirectory) {
        entries.push(FileEntryFactory.directory(name, childPath, 0));
      } else {
        entries.push(FileEntryFactory.file(name, childPath, Number.isFinite(size) ? size : 0, 0, ''));
      }
    }
    return entries;
  }

  async list(path: string): Promise<FileEntry[]> {
    const client: FtpClient = await this.ensure();
    const target: string = this.remotePath(path);
    try {
      const text: string = await client.listRaw(target);
      return FtpFileSystem.parseMlsd(text, path.length === 0 ? '/' : path);
    } catch (err) {
      const text: string = await client.listFallback(target);
      return FtpFileSystem.parseList(text, path.length === 0 ? '/' : path);
    }
  }

  async stat(path: string): Promise<FileEntry> {
    const client: FtpClient = await this.ensure();
    const target: string = this.remotePath(path);
    const size: number = await client.size(target);
    const modified: number = await client.modified(target);
    const name: string = SourceUrl.tailOfUri(path);
    if (size < 0) {
      return FileEntryFactory.directory(name, path, modified);
    }
    return FileEntryFactory.file(name, path, size, modified, '');
  }

  async readRange(path: string, position: number, length: number): Promise<ArrayBuffer> {
    const client: FtpClient = await this.ensure();
    return client.retrieve(this.remotePath(path), position, length);
  }

  async openStream(path: string, position?: number): Promise<InputStreamLike> {
    const start: number = position === undefined ? 0 : position;
    const data: ArrayBuffer = await this.readRange(path, start, 512 * 1024);
    return new ByteSink(data);
  }

  async testConnection(): Promise<void> {
    const client: FtpClient = await this.ensure();
    await client.command('PWD');
  }

  async close(): Promise<void> {
    if (this.client !== null) {
      await this.client.close();
      this.client = null;
    }
  }
}
