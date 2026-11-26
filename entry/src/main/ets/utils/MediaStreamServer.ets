import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { FileSystemClient } from '../data/fs/FileSystemClient';
import { RangeHeader, RangeSpec } from './RangeHeader';
import { Logger } from './Logger';

interface StreamEntry {
  token: string;
  sourceId: string;
  path: string;
  size: number;
  mimeType: string;
}

class RequestState {
  buffer: string = '';
  headerLength: number = -1;
  handled: boolean = false;
}

/**
 * 本机回环 HTTP 流式代理（只为 AVPlayer 服务，规范 §8.6 / §12 的 Range 播放）。
 *
 * 为什么不直接用 AVPlayer.url 播放远程地址：`AVPlayer.url` 无法携带
 * `Authorization` 等自定义请求头，WebDAV Basic Auth / FTP 都需要鉴权。
 * 因此在本机 127.0.0.1 起一个只读 HTTP 服务：
 *   - 只要播放器发 `Range: bytes=start-end`，就从 FileSystemClient 按需读一段，
 *     不会整文件下载（真正的大文件流式播放）；
 *   - 端口从 8901 起自动选空闲，仅监听回环地址，不对外暴露；
 *   - URL 里带一次性随机 token，只有拿到 token 的连接才被服务；
 *   - 页面/播放器销毁时通过 release()/stop() 注销条目并关闭服务。
 */
export class MediaStreamServer {
  private static instance: MediaStreamServer | null = null;

  private server: socket.TCPSocketServer | null = null;
  private port: number = 0;
  private entries: Map<string, StreamEntry> = new Map<string, StreamEntry>();
  private clients: Map<string, FileSystemClient> = new Map<string, FileSystemClient>();
  private encoder: util.TextEncoder = new util.TextEncoder('utf-8');
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8');

  static get(): MediaStreamServer {
    if (MediaStreamServer.instance === null) {
      MediaStreamServer.instance = new MediaStreamServer();
    }
    return MediaStreamServer.instance;
  }

  private async ensureStarted(): Promise<number> {
    if (this.server !== null) {
      return this.port;
    }
    for (let candidate = 8901; candidate <= 8920; candidate++) {
      const server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
      try {
        await server.listen({ address: '127.0.0.1', port: candidate, family: 1 });
        this.server = server;
        this.port = candidate;
        server.on('connect', (conn: socket.TCPSocketConnection) => {
          this.handleConnection(conn);
        });
        Logger.info('MediaStreamServer', `本地流式代理已启动 127.0.0.1:${candidate}`);
        return this.port;
      } catch (err) {
        try {
          await server.close();
        } catch (closeErr) {
          Logger.warn('MediaStreamServer', '关闭候选端口失败');
        }
      }
    }
    Logger.warn('MediaStreamServer', '无法在 8901-8920 监听端口');
    return 0;
  }

  /** 注册一个可流式播放的远程文件，返回播放器可直接使用的 URL（失败返回空串） */
  async register(client: FileSystemClient, sourceId: string, path: string, size: number,
    mimeType: string): Promise<string> {
    try {
      const port: number = await this.ensureStarted();
      if (port === 0) {
        return '';
      }
      const token: string = MediaStreamServer.randomToken();
      const entry: StreamEntry = {
        token: token,
        sourceId: sourceId,
        path: path,
        size: size,
        mimeType: mimeType
      };
      this.entries.set(token, entry);
      this.clients.set(sourceId, client);
      const encodedPath: string = encodeURIComponent(path);
      return `http://127.0.0.1:${port}/stream/${token}/${encodedPath}`;
    } catch (err) {
      Logger.error('MediaStreamServer', '注册流式播放失败', err as Error);
      return '';
    }
  }

  /** 释放某来源的全部流条目（来源被编辑/删除时调用） */
  release(sourceId: string): void {
    const drop: string[] = [];
    this.entries.forEach((entry: StreamEntry, token: string) => {
      if (entry.sourceId === sourceId) {
        drop.push(token);
      }
    });
    for (const token of drop) {
      this.entries.delete(token);
    }
    this.clients.delete(sourceId);
  }

  async stop(): Promise<void> {
    const server: socket.TCPSocketServer | null = this.server;
    this.server = null;
    this.port = 0;
    this.entries.clear();
    this.clients.clear();
    if (server !== null) {
      try {
        await server.close();
      } catch (err) {
        Logger.warn('MediaStreamServer', `停止代理失败 ${(err as BusinessError).code}`);
      }
    }
  }

  isRunning(): boolean {
    return this.server !== null;
  }

  private static randomToken(): string {
    const alphabet: string = 'abcdefghijkmnpqrstuvwxyz23456789';
    let token: string = '';
    for (let i = 0; i < 20; i++) {
      token += alphabet.charAt(Math.floor(Math.random() * alphabet.length));
    }
    return token;
  }

  private handleConnection(conn: socket.TCPSocketConnection): void {
    const state: RequestState = new RequestState();
    conn.on('message', (info: socket.SocketMessageInfo) => {
      if (state.handled) {
        return;
      }
      state.buffer += this.decoder.decodeWithStream(new Uint8Array(info.message));
      const index: number = state.buffer.indexOf('\r\n\r\n');
      if (index < 0) {
        if (state.buffer.length > 16384) {
          state.handled = true;
          this.respondSimple(conn, 431, 'Request Header Fields Too Large');
        }
        return;
      }
      state.handled = true;
      state.buffer = state.buffer.substring(0, index);
      this.route(conn, state.buffer);
    });
  }

  private route(conn: socket.TCPSocketConnection, head: string): void {
    const lines: string[] = head.split('\r\n');
    const requestLine: string = lines.length > 0 ? lines[0] : '';
    const parts: string[] = requestLine.split(' ');
    if (parts.length < 2) {
      this.respondSimple(conn, 400, 'Bad Request');
      return;
    }
    const method: string = parts[0];
    const target: string = parts[1];
    const segments: string[] = target.split('/');
    // 路径形如 /stream/<token>/<encodedPath>
    if (segments.length < 4 || segments[1] !== 'stream') {
      this.respondSimple(conn, 404, 'Not Found');
      return;
    }
    const token: string = segments[2];
    const entry: StreamEntry | undefined = this.entries.get(token);
    const client: FileSystemClient | undefined = this.clients.get(entry === undefined ? '' : entry.sourceId);
    if (entry === undefined || client === undefined) {
      this.respondSimple(conn, 403, 'Forbidden');
      return;
    }
    if (method !== 'GET' && method !== 'HEAD') {
      this.respondSimple(conn, 405, 'Method Not Allowed');
      return;
    }
    const rangeHeader: string = MediaStreamServer.headerValue(lines, 'range');
    const range: RangeSpec = RangeHeader.parse(rangeHeader, entry.size);
    if (!range.valid || range.start < 0) {
      const header: string = 'HTTP/1.1 416 Range Not Satisfiable\r\n' +
        `Content-Range: bytes */${entry.size}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n`;
      conn.send({ data: header }).then(() => {
        conn.close().catch(() => {
        });
      }).catch((err: Error) => {
        Logger.warn('MediaStreamServer', '发送 416 失败');
      });
      return;
    }
    this.sendBody(conn, client, entry, range, method === 'HEAD');
  }

  private static headerValue(lines: string[], name: string): string {
    for (const line of lines) {
      const index: number = line.indexOf(':');
      if (index <= 0) {
        continue;
      }
      if (line.substring(0, index).trim().toLowerCase() === name) {
        return line.substring(index + 1).trim();
      }
    }
    return '';
  }

  private async sendBody(conn: socket.TCPSocketConnection, client: FileSystemClient, entry: StreamEntry,
    range: RangeSpec, headOnly: boolean): Promise<void> {
    // 单次响应最多 8MB：播放器 request bytes=0- 时也只回一段，再由它自己续请求，
    // 避免一次性把整部电影推过去（SMB/FTP 上尤其重要）。
    const MAX_SPAN: number = 8 * 1024 * 1024;
    let end: number = range.end;
    let isPartial: boolean = range.partial;
    if (end - range.start + 1 > MAX_SPAN) {
      end = range.start + MAX_SPAN - 1;
      isPartial = true;
    }
    const total: number = end - range.start + 1;
    const status: string = isPartial ? '206 Partial Content' : '200 OK';
    const header: string = `HTTP/1.1 ${status}\r\n` +
      `Content-Type: ${entry.mimeType.length > 0 ? entry.mimeType : 'application/octet-stream'}\r\n` +
      `Content-Length: ${total}\r\n` +
      'Accept-Ranges: bytes\r\n' +
      (isPartial ? `Content-Range: bytes ${range.start}-${end}/${entry.size}\r\n` : '') +
      'Cache-Control: no-store\r\nConnection: close\r\n\r\n';
    try {
      await conn.send({ data: header });
      if (headOnly) {
        await conn.close();
        return;
      }
      const chunkSize: number = 512 * 1024;
      let offset: number = range.start;
      while (offset <= end) {
        const want: number = Math.min(chunkSize, end - offset + 1);
        const buffer: ArrayBuffer = await client.readRange(entry.path, offset, want);
        if (buffer.byteLength === 0) {
          break;
        }
        await conn.send({ data: buffer });
        offset += buffer.byteLength;
      }
    } catch (err) {
      Logger.warn('MediaStreamServer', `读取/发送媒体数据失败: ${entry.mimeType}`);
    } finally {
      try {
        await conn.close();
      } catch (err) {
        Logger.debug('MediaStreamServer', '关闭连接失败');
      }
    }
  }

  private respondSimple(conn: socket.TCPSocketConnection, code: number, reason: string): void {
    const header: string = `HTTP/1.1 ${code} ${reason}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n`;
    conn.send({ data: header }).then(() => {
      conn.close().catch(() => {
      });
    }).catch((err: Error) => {
      Logger.warn('MediaStreamServer', '发送响应失败');
    });
  }
}
