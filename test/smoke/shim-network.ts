/**
 * 仅供本地 SMB 冒烟测试使用：把 @kit.NetworkKit 的 TCPSocket 映射到 Node 的 net.Socket。
 * 该文件不参与 HAP 构建，只在 scripts/test/run-smb-smoke.mjs 里作为 esbuild 别名使用。
 */
import { Socket } from 'node:net';
import { request as nodeHttpRequest } from 'node:http';
import { request as nodeHttpsRequest } from 'node:https';

type MessageCallback = (info: { message: ArrayBuffer }) => void;

class TcpSocketShim {
  private inner: Socket = new Socket();
  private messageCallback: MessageCallback | null = null;
  private closeCallback: (() => void) | null = null;

  async connect(options: { address: { address: string, port: number }, timeout?: number }): Promise<void> {
    const timeout: number = options.timeout === undefined ? 15000 : options.timeout;
    return new Promise<void>((resolve, reject) => {
      this.inner.setTimeout(timeout);
      this.inner.once('error', (error: Error) => reject(error));
      this.inner.once('timeout', () => reject(new Error('connect timeout')));
      this.inner.on('data', (chunk: Buffer) => {
        if (this.messageCallback !== null) {
          const copy: Uint8Array = new Uint8Array(chunk.length);
          copy.set(chunk);
          this.messageCallback({ message: copy.buffer as ArrayBuffer });
        }
      });
      this.inner.on('close', () => {
        if (this.closeCallback !== null) {
          this.closeCallback();
        }
      });
      this.inner.connect(options.address.port, options.address.address, () => resolve());
    });
  }

  async send(options: { data: string | ArrayBuffer }): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const data = options.data;
      const buffer = typeof data === 'string' ? Buffer.from(data, 'binary') : Buffer.from(new Uint8Array(data));
      this.inner.write(buffer, (error) => (error ? reject(error) : resolve()));
    });
  }

  async close(): Promise<void> {
    this.inner.destroy();
  }

  on(type: string, callback: unknown): void {
    if (type === 'message') {
      this.messageCallback = callback as MessageCallback;
    } else if (type === 'close') {
      this.closeCallback = callback as () => void;
    }
  }
}

export const socket = {
  constructTCPSocketInstance(): TcpSocketShim {
    return new TcpSocketShim();
  }
};

/**
 * @kit.NetworkKit 的 http 简化实现（仅冒烟测试用）：
 * 支持 PROPFIND 等自定义方法、header、Range、expectDataType(ARRAY_BUFFER/STRING)。
 */
function toArrayBuffer(buffer: Buffer): ArrayBuffer {
  const copy: Uint8Array = new Uint8Array(buffer.length);
  copy.set(buffer);
  return copy.buffer as ArrayBuffer;
}

export const http = {
  HttpDataType: { STRING: 0, OBJECT: 1, ARRAY_BUFFER: 2 },
  RequestMethod: {
    OPTIONS: 'OPTIONS', GET: 'GET', HEAD: 'HEAD', POST: 'POST',
    PUT: 'PUT', DELETE: 'DELETE', TRACE: 'TRACE', CONNECT: 'CONNECT'
  },
  createHttp(): { request: (url: string, options: Record<string, unknown>) => Promise<Record<string, unknown>>, destroy: () => void } {
    return {
      request(url: string, options: Record<string, unknown>): Promise<Record<string, unknown>> {
        return new Promise((resolve, reject) => {
          const target = new URL(url);
          const isHttps = target.protocol === 'https:';
          const lib = isHttps ? nodeHttpsRequest : nodeHttpRequest;
          const headers = (options.header as Record<string, string>) || {};
          const req = lib(target, { method: (options.method as string) || 'GET', headers: headers }, (res) => {
            const chunks: Buffer[] = [];
            res.on('data', (chunk: Buffer) => chunks.push(chunk));
            res.on('end', () => {
              const body = Buffer.concat(chunks);
              const wantBuffer = options.expectDataType === 2;
              resolve({
                responseCode: res.statusCode === undefined ? 0 : res.statusCode,
                result: wantBuffer ? toArrayBuffer(body) : body.toString('utf8'),
                header: res.headers
              });
            });
          });
          req.on('error', (error: Error) => reject(error));
          const extra = options.extraData;
          if (typeof extra === 'string' && extra.length > 0) {
            req.write(extra);
          }
          req.end();
        });
      },
      destroy(): void {
      }
    };
  }
};
