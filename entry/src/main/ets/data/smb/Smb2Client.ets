import { socket } from '@kit.NetworkKit';
import { FileEntry, FileEntryFactory } from '../../model/FileEntry';
import { FileSource } from '../../model/FileSource';
import { FsError, FsErrorKind } from '../fs/FileSystemClient';
import { Ntlm, NtlmCredentials, NtlmMicParams, NtlmV2Result } from './Ntlm';
import { SmbCrypto } from './SmbCrypto';
import { Smb2Codec, Smb2Command, Smb2FileId, Smb2FileInfo, Smb2Header, Smb2Status } from './Smb2Codec';
import { Logger } from '../../utils/Logger';

class PendingResponse {
  private resolveFn: (value: Smb2Header) => void;
  private rejectFn: (reason?: Object) => void;

  constructor(resolve: (value: Smb2Header) => void, reject: (reason?: Object) => void) {
    this.resolveFn = resolve;
    this.rejectFn = reject;
  }

  resolve(header: Smb2Header): void {
    this.resolveFn(header);
  }

  reject(reason: Object): void {
    this.rejectFn(reason);
  }
}

export interface Smb2Options {
  host: string;
  port: number;
  user: string;
  password: string;
  domain: string;
  share: string;
  rootPath: string;
}

const READ_CHUNK: number = 1024 * 1024;
const DIR_OUTPUT_LENGTH: number = 64 * 1024;

/**
 * 纯 ArkTS 的 SMB2 客户端（SMB 2.0.2 / 2.1，NTLMv2，支持报文签名）。
 *
 * 为什么不用原生库：官方 SDK 没有 SMB 能力，自研 NAPI 需要交叉编译 libsmb2 + OpenSSL。
 * 这里直接在 TCPSocket 上实现 SMB2 子集：NEGOTIATE / SESSION_SETUP(NTLMv2) /
 * TREE_CONNECT / CREATE / QUERY_DIRECTORY / QUERY_INFO / READ / CLOSE。
 *
 * 未实现：SMB 3.x 加密与 AES-CMAC 签名、DFS、写操作、compound 请求。
 */
export class Smb2Client {
  private options: Smb2Options;
  private tcp: socket.TCPSocket | null = null;
  private buffer: Uint8Array = new Uint8Array(0);
  private pending: Map<number, PendingResponse> = new Map<number, PendingResponse>();
  // SMB2 要求首个报文的 MessageId 为 0（Windows 服务端会重置 MessageId 非 0 的首包连接）
  private nextMessageId: number = 0;
  private sessionId: number = 0;
  private treeId: number = 0;
  private signingKey: Uint8Array = new Uint8Array(0);
  private requireSigning: boolean = false;
  private closed: boolean = false;
  private dialect: number = 0;

  constructor(options: Smb2Options) {
    this.options = options;
  }

  // ---------------- 连接与会话 ----------------
  async connect(): Promise<void> {
    const tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
    this.tcp = tcp;
    tcp.on('message', (info: socket.SocketMessageInfo) => {
      this.onData(new Uint8Array(info.message));
    });
    tcp.on('close', () => {
      this.failAllPending('连接已关闭');
    });
    const address: socket.NetAddress = { address: this.options.host, port: this.options.port, family: 1 };
    const connectOptions: socket.TCPConnectOptions = { address: address, timeout: 15000 };
    try {
      await tcp.connect(connectOptions);
    } catch (err) {
      throw new FsError(FsErrorKind.NETWORK, `无法连接 ${this.options.host}:${this.options.port}`);
    }
    await this.negotiate();
    await this.authenticate();
    await this.treeConnect();
  }

  private async negotiate(): Promise<void> {
    const guid: Uint8Array = new Uint8Array(16);
    for (let i = 0; i < 16; i++) {
      guid[i] = Math.floor(Math.random() * 256);
    }
    const response: Smb2Header = await this.request(Smb2Codec.buildNegotiate(this.allocMessageId(), guid));
    this.requireSigning = Smb2Codec.serverRequiresSigning(response.raw);
    this.dialect = Smb2Codec.dialectOf(response.raw);
    if (this.dialect !== 0x0202 && this.dialect !== 0x0210) {
      Logger.warn('Smb2Client', `服务器协商到方言 ${this.dialect.toString(16)}，仅完整支持 2.1`);
    }
    Logger.info('Smb2Client', `NEGOTIATE ok, dialect=0x${this.dialect.toString(16)}, signingRequired=${this.requireSigning}`);
  }

  private async authenticate(): Promise<void> {
    const type1: Uint8Array = Ntlm.buildType1();
    let blob: Uint8Array = Ntlm.wrapSpnegoInit(type1);
    const negotiateBlob: Uint8Array = blob;
    let challengeBlob: Uint8Array = new Uint8Array(0);

    let response: Smb2Header = await this.request(
      Smb2Codec.buildSessionSetup(this.allocMessageId(), blob, 0));
    if (response.status !== Smb2Status.MORE_PROCESSING_REQUIRED && response.status !== Smb2Status.SUCCESS) {
      throw Smb2Client.mapStatus(response.status);
    }
    this.sessionId = response.sessionId;
    const serverBlob: Uint8Array = Smb2Codec.securityBlobOf(response.raw);
    if (serverBlob.length === 0) {
      throw new FsError(FsErrorKind.AUTH, '服务器未返回 NTLM 挑战');
    }
    challengeBlob = serverBlob;
    const ntlmChallenge = Ntlm.extractNtlmMessage(serverBlob);
    const challenge = Ntlm.parseType2(ntlmChallenge);

    const clientChallenge: Uint8Array = new Uint8Array(8);
    for (let i = 0; i < 8; i++) {
      clientChallenge[i] = Math.floor(Math.random() * 256);
    }
    const credentials: NtlmCredentials = {
      user: this.options.user,
      domain: this.options.domain,
      password: this.options.password
    };
    const mic: NtlmMicParams = { negotiateBlob: negotiateBlob, challengeBlob: challengeBlob };
    const type3: Uint8Array = Ntlm.buildType3(credentials, challenge.serverChallenge, clientChallenge,
      Ntlm.nowFileTime(), challenge.targetInfo, mic);
    blob = Ntlm.wrapSpnegoResp(type3);

    response = await this.request(Smb2Codec.buildSessionSetup(this.allocMessageId(), blob, this.sessionId));
    if (response.status !== Smb2Status.SUCCESS) {
      throw Smb2Client.mapStatus(response.status);
    }
    this.sessionId = response.sessionId;
    // 会话密钥：无密钥交换时等于 SessionBaseKey
    const computed: NtlmV2Result = Ntlm.computeV2({
      user: this.options.user,
      domain: this.options.domain,
      password: this.options.password,
      serverChallenge: challenge.serverChallenge,
      clientChallenge: clientChallenge,
      fileTime: 0,
      targetInfo: challenge.targetInfo
    });
    this.signingKey = computed.sessionBaseKey;
    Logger.info('Smb2Client', `SESSION_SETUP ok, sessionId=${this.sessionId}`);
  }

  private async treeConnect(): Promise<void> {
    const unc: string = `\\\\${this.options.host}\\${this.options.share}`;
    const response: Smb2Header = await this.request(
      Smb2Codec.buildTreeConnect(this.allocMessageId(), this.sessionId, unc));
    this.treeId = response.treeId;
    Logger.info('Smb2Client', `TREE_CONNECT ok, treeId=${this.treeId}`);
  }

  // ---------------- 传输与签名 ----------------
  private allocMessageId(): number {
    const id: number = this.nextMessageId;
    this.nextMessageId += 1;
    return id;
  }

  private sign(packet: Uint8Array): Uint8Array {
    if (this.signingKey.length === 0) {
      return packet;
    }
    const copy: Uint8Array = new Uint8Array(packet);
    for (let i = 48; i < 64; i++) {
      copy[i] = 0;
    }
    const mac: Uint8Array = SmbCrypto.hmacSha256(this.signingKey, copy);
    copy.set(mac.slice(0, 16), 48);
    Ntlm.writeUint32(copy, 16, Ntlm.readUint32(copy, 16) | 0x00000008);
    return copy;
  }

  private async request(packet: Uint8Array): Promise<Smb2Header> {
    if (this.tcp === null || this.closed) {
      throw new FsError(FsErrorKind.NETWORK, 'SMB 连接已关闭');
    }
    const messageId: number = Smb2Codec.parseHeader(packet).messageId;
    const signed: Uint8Array = this.sign(packet);
    const framed: Uint8Array = Smb2Codec.frame(signed);
    const promise: Promise<Smb2Header> = new Promise<Smb2Header>(
      (resolve: (value: Smb2Header) => void, reject: (reason?: Object) => void) => {
        this.pending.set(messageId, new PendingResponse(resolve, reject));
      });
    try {
      await this.tcp.send({ data: framed.buffer as ArrayBuffer });
    } catch (err) {
      this.pending.delete(messageId);
      throw new FsError(FsErrorKind.NETWORK, 'SMB 发送失败');
    }
    const response: Smb2Header = await promise;
    if (response.status !== Smb2Status.SUCCESS && response.status !== Smb2Status.BUFFER_OVERFLOW &&
      response.status !== Smb2Status.NO_MORE_FILES && response.status !== Smb2Status.MORE_PROCESSING_REQUIRED) {
      throw Smb2Client.mapStatus(response.status);
    }
    return response;
  }

  private onData(chunk: Uint8Array): void {
    this.buffer = SmbCrypto.concat(this.buffer, chunk);
    while (this.buffer.length >= 4) {
      const length: number = (this.buffer[1] << 16) | (this.buffer[2] << 8) | this.buffer[3];
      if (this.buffer.length < 4 + length) {
        return;
      }
      const message: Uint8Array = this.buffer.slice(4, 4 + length);
      this.buffer = this.buffer.slice(4 + length);
      try {
        const header: Smb2Header = Smb2Codec.parseHeader(message);
        const waiter: PendingResponse | undefined = this.pending.get(header.messageId);
        if (waiter !== undefined) {
          this.pending.delete(header.messageId);
          waiter.resolve(header);
        } else {
          Logger.debug('Smb2Client', `收到未匹配的 SMB2 报文 messageId=${header.messageId}`);
        }
      } catch (err) {
        Logger.error('Smb2Client', '解析 SMB2 报文失败', err as Error);
      }
    }
  }

  private failAllPending(reason: string): void {
    const waiters: PendingResponse[] = [];
    this.pending.forEach((waiter: PendingResponse) => {
      waiters.push(waiter);
    });
    this.pending.clear();
    for (const waiter of waiters) {
      waiter.reject(new FsError(FsErrorKind.NETWORK, reason));
    }
  }

  private static mapStatus(status: number): FsError {
    if (status === Smb2Status.LOGON_FAILURE) {
      return new FsError(FsErrorKind.AUTH, `STATUS_LOGON_FAILURE(0x${status.toString(16)})`);
    }
    if (status === Smb2Status.ACCESS_DENIED) {
      return new FsError(FsErrorKind.PERMISSION, `STATUS_ACCESS_DENIED(0x${status.toString(16)})`);
    }
    if (status === Smb2Status.OBJECT_NAME_NOT_FOUND || status === Smb2Status.OBJECT_PATH_NOT_FOUND) {
      return new FsError(FsErrorKind.NOT_FOUND, `STATUS_OBJECT_NOT_FOUND(0x${status.toString(16)})`);
    }
    if (status === Smb2Status.BAD_NETWORK_NAME) {
      return new FsError(FsErrorKind.UNSUPPORTED, '共享名不存在或不可访问');
    }
    return new FsError(FsErrorKind.SERVER, `SMB2 状态 0x${status.toString(16)}`);
  }

  // ---------------- 文件操作 ----------------
  /** 逻辑路径 -> SMB 相对路径（反斜杠分隔，无前导分隔符） */
  private toSmbPath(logicalPath: string): string {
    const trimmedRoot: string = this.options.rootPath.length > 0
      ? this.options.rootPath.replace(/^\/+|\/+$/g, '')
      : '';
    let path: string = logicalPath;
    while (path.startsWith('/')) {
      path = path.substring(1);
    }
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    const combined: string = trimmedRoot.length === 0
      ? path
      : (path.length === 0 ? trimmedRoot : `${trimmedRoot}/${path}`);
    return combined.split('/').filter((part: string) => part.length > 0).join('\\');
  }

  private async open(logicalPath: string, isDirectory: boolean): Promise<Smb2FileId> {
    const response: Smb2Header = await this.request(
      Smb2Codec.buildCreate(this.allocMessageId(), this.sessionId, this.treeId,
        this.toSmbPath(logicalPath), isDirectory));
    return Smb2Codec.parseCreate(response.raw);
  }

  private async closeHandle(fileId: Smb2FileId): Promise<void> {
    try {
      await this.request(Smb2Codec.buildClose(this.allocMessageId(), this.sessionId, this.treeId, fileId));
    } catch (err) {
      Logger.warn('Smb2Client', '关闭 SMB 句柄失败');
    }
  }

  async list(logicalPath: string): Promise<FileEntry[]> {
    const fileId: Smb2FileId = await this.open(logicalPath, true);
    const entries: FileEntry[] = [];
    try {
      while (true) {
        let response: Smb2Header;
        try {
          response = await this.request(Smb2Codec.buildQueryDirectory(this.allocMessageId(), this.sessionId,
            this.treeId, fileId, '*', DIR_OUTPUT_LENGTH));
        } catch (err) {
          if (err instanceof FsError && err.kind === FsErrorKind.SERVER && err.message.includes('80000006')) {
            break;
          }
          if (err instanceof Error) {
            throw err;
          }
          throw new FsError(FsErrorKind.SERVER, '列目录失败');
        }
        if (response.status === Smb2Status.NO_MORE_FILES) {
          break;
        }
        const batch: FileEntry[] = Smb2Codec.parseQueryDirectory(response.raw, logicalPath.length === 0 ? '/' : logicalPath);
        if (batch.length === 0) {
          break;
        }
        for (const entry of batch) {
          entries.push(entry);
        }
        if (response.status !== Smb2Status.BUFFER_OVERFLOW && batch.length < DIR_OUTPUT_LENGTH / 200) {
          break;
        }
      }
    } finally {
      await this.closeHandle(fileId);
    }
    return entries;
  }

  async stat(logicalPath: string): Promise<FileEntry> {
    const name: string = Smb2Client.baseNameOf(logicalPath);
    let fileId: Smb2FileId;
    let isDirectory: boolean = false;
    try {
      fileId = await this.open(logicalPath, false);
    } catch (err) {
      if (err instanceof FsError && err.kind === FsErrorKind.SERVER) {
        fileId = await this.open(logicalPath, true);
        isDirectory = true;
      } else if (err instanceof Error) {
        throw err;
      } else {
        throw new FsError(FsErrorKind.SERVER, '无法打开文件');
      }
    }
    try {
      const response: Smb2Header = await this.request(
        Smb2Codec.buildQueryInfo(this.allocMessageId(), this.sessionId, this.treeId, fileId, 4096));
      const info: Smb2FileInfo = Smb2Codec.parseQueryInfo(response.raw);
      if (info.isDirectory || isDirectory) {
        return FileEntryFactory.directory(name, logicalPath, info.modified);
      }
      return FileEntryFactory.file(name, logicalPath, info.size, info.modified, '');
    } finally {
      await this.closeHandle(fileId);
    }
  }

  async readRange(logicalPath: string, offset: number, length: number): Promise<ArrayBuffer> {
    const fileId: Smb2FileId = await this.open(logicalPath, false);
    const chunks: Uint8Array[] = [];
    let total: number = 0;
    try {
      let position: number = offset;
      const remainingWanted: number = length;
      while (total < remainingWanted) {
        const want: number = Math.min(READ_CHUNK, remainingWanted - total);
        const response: Smb2Header = await this.request(
          Smb2Codec.buildRead(this.allocMessageId(), this.sessionId, this.treeId, fileId, position, want));
        const data: Uint8Array = Smb2Codec.parseReadData(response.raw);
        if (data.length === 0) {
          break;
        }
        chunks.push(data);
        total += data.length;
        position += data.length;
        if (data.length < want) {
          break;
        }
      }
    } finally {
      await this.closeHandle(fileId);
    }
    const merged: Uint8Array = SmbCrypto.concat(...chunks);
    return merged.buffer as ArrayBuffer;
  }

  private static baseNameOf(path: string): string {
    const trimmed: string = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    const slash: number = trimmed.lastIndexOf('/');
    return slash >= 0 ? trimmed.substring(slash + 1) : trimmed;
  }

  async test(): Promise<void> {
    await this.list('/');
  }

  async close(): Promise<void> {
    if (this.closed) {
      return;
    }
    this.closed = true;
    if (this.tcp !== null && this.sessionId !== 0) {
      try {
        const packet: Uint8Array = Smb2Codec.buildHeader(Smb2Command.LOGOFF, this.allocMessageId(), 0,
          this.sessionId, 32, 0);
        const body: Uint8Array = SmbCrypto.concat(Smb2Codec.u16(4), Smb2Codec.u16(0));
        await this.tcp.send({ data: Smb2Codec.frame(SmbCrypto.concat(packet, body)).buffer as ArrayBuffer });
      } catch (err) {
        Logger.debug('Smb2Client', 'LOGOFF 失败');
      }
    }
    if (this.tcp !== null) {
      try {
        await this.tcp.close();
      } catch (err) {
        Logger.debug('Smb2Client', '关闭 socket 失败');
      }
      this.tcp = null;
    }
    this.failAllPending('客户端已关闭');
  }

  static optionsFromSource(source: FileSource, password: string): Smb2Options {
    return {
      host: source.host,
      port: source.port > 0 ? source.port : 445,
      user: source.username,
      password: password,
      domain: source.domain,
      share: source.share,
      rootPath: source.rootPath
    };
  }
}
