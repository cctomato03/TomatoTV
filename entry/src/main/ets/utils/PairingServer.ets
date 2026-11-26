import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { LanAddress } from './LanAddress';
import { Logger } from './Logger';

/** 手机端表单提交的内容（字段与规范 §7.5 一致） */
export interface PairingForm {
  type: string;
  name: string;
  localPath: string;
  url: string;
  host: string;
  port: string;
  share: string;
  rootPath: string;
  domain: string;
  username: string;
  password: string;
  secure: string;
}

export interface PairingSession {
  url: string;
  port: number;
  token: string;
}

export type PairingSubmitHandler = (form: PairingForm) => void;

class PendingRequest {
  buffer: string = '';
  bodyLength: number = -1;
  headerLength: number = -1;
  handled: boolean = false;
}

/**
 * 智慧屏扫码填写参数的极简 HTTP/1.1 服务（规范 §7.5）。
 *
 * - 使用 @kit.NetworkKit 的 TCPSocketServer，不引入任何第三方 HTTP 服务；
 * - GET `/` 返回手机端表单，POST `/submit` 解析 application/x-www-form-urlencoded；
 * - token 校验失败返回 403；提交成功后 token 立即失效；
 * - 关闭弹层调用 stop() 立即停止监听（一次性的局域网服务）。
 */
export class PairingServer {
  private server: socket.TCPSocketServer | null = null;
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  private encoder: util.TextEncoder = new util.TextEncoder('utf-8');
  private token: string = '';
  private port: number = 0;
  private handler: PairingSubmitHandler;
  private onSubmitted: () => void = () => {
  };

  constructor(handler: PairingSubmitHandler, onSubmitted?: () => void) {
    this.handler = handler;
    if (onSubmitted !== undefined) {
      this.onSubmitted = onSubmitted;
    }
  }

  async start(): Promise<PairingSession> {
    await this.stop();
    this.token = PairingServer.randomToken();
    for (let candidate = 8765; candidate <= 8785; candidate++) {
      const server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
      try {
        await server.listen({ address: '0.0.0.0', port: candidate, family: 1 });
        this.server = server;
        this.port = candidate;
        break;
      } catch (err) {
        try {
          await server.close();
        } catch (closeErr) {
          Logger.warn('PairingServer', '关闭候选端口失败');
        }
      }
    }
    if (this.server === null) {
      throw new Error('无法在 8765-8785 范围内监听端口');
    }
    const server: socket.TCPSocketServer = this.server;
    server.on('connect', (conn: socket.TCPSocketConnection) => {
      this.handleConnection(conn);
    });
    const ip: string = await LanAddress.firstIpv4();
    const url: string = `http://${ip}:${this.port}/?t=${this.token}`;
    Logger.info('PairingServer', `已启动局域网服务 ${url}`);
    return { url: url, port: this.port, token: this.token };
  }

  async stop(): Promise<void> {
    const server: socket.TCPSocketServer | null = this.server;
    this.server = null;
    this.token = '';
    if (server !== null) {
      try {
        await server.close();
      } catch (err) {
        Logger.warn('PairingServer', `停止服务失败 ${(err as BusinessError).code}`);
      }
    }
  }

  isRunning(): boolean {
    return this.server !== null;
  }

  private handleConnection(conn: socket.TCPSocketConnection): void {
    const pending: PendingRequest = new PendingRequest();
    conn.on('message', (info: socket.SocketMessageInfo) => {
      pending.buffer += this.decoder.decodeWithStream(new Uint8Array(info.message));
      this.tryServe(conn, pending);
    });
    conn.on('close', () => {
      Logger.debug('PairingServer', '连接关闭');
    });
  }

  private tryServe(conn: socket.TCPSocketConnection, pending: PendingRequest): void {
    if (pending.handled) {
      return;
    }
    if (pending.headerLength < 0) {
      const index: number = pending.buffer.indexOf('\r\n\r\n');
      if (index < 0) {
        return;
      }
      pending.headerLength = index + 4;
      pending.bodyLength = PairingServer.contentLength(pending.buffer.substring(0, index));
    }
    if (pending.buffer.length < pending.headerLength + pending.bodyLength) {
      return;
    }
    pending.handled = true;
    const head: string = pending.buffer.substring(0, pending.headerLength);
    const body: string = pending.buffer.substring(pending.headerLength);
    this.route(conn, head, body);
  }

  private static contentLength(head: string): number {
    const lines: string[] = head.split('\r\n');
    for (const line of lines) {
      const lower: string = line.toLowerCase();
      if (lower.startsWith('content-length:')) {
        const value: number = Number(line.substring(line.indexOf(':') + 1).trim());
        return Number.isFinite(value) && value > 0 ? value : 0;
      }
    }
    return 0;
  }

  private route(conn: socket.TCPSocketConnection, head: string, body: string): void {
    const firstLine: string = head.split('\r\n')[0];
    const parts: string[] = firstLine.split(' ');
    const method: string = parts.length > 0 ? parts[0] : '';
    const target: string = parts.length > 1 ? parts[1] : '/';
    const token: string = PairingServer.queryToken(target);
    if (!this.tokenValid(token)) {
      this.respond(conn, 403, PairingServer.htmlMessage('链接已失效', '请在智慧屏上重新打开二维码后重试。'));
      return;
    }
    if (method === 'GET') {
      this.respond(conn, 200, PairingServer.formHtml(target));
      return;
    }
    if (method === 'POST') {
      const form: PairingForm = PairingServer.parseBody(body);
      if (!this.tokenValid(PairingServer.queryToken(target)) && form.name.length === 0) {
        this.respond(conn, 403, PairingServer.htmlMessage('链接已失效', '请在智慧屏上重新打开二维码后重试。'));
        return;
      }
      this.token = '';
      this.handler(form);
      this.respond(conn, 200, PairingServer.htmlMessage('已提交', '请回到智慧屏核对参数并点击保存，本链接已失效。'));
      this.onSubmitted();
      return;
    }
    this.respond(conn, 405, PairingServer.htmlMessage('不支持的请求', '只支持 GET 和 POST。'));
  }

  private tokenValid(candidate: string): boolean {
    return this.token.length > 0 && candidate === this.token;
  }

  private static queryToken(target: string): string {
    const index: number = target.indexOf('?');
    if (index < 0) {
      return '';
    }
    const query: string = target.substring(index + 1);
    for (const pair of query.split('&')) {
      const eq: number = pair.indexOf('=');
      if (eq > 0 && pair.substring(0, eq) === 't') {
        return decodeURIComponent(pair.substring(eq + 1));
      }
    }
    return '';
  }

  private static parseBody(body: string): PairingForm {
    const form: PairingForm = {
      type: 'LOCAL',
      name: '',
      localPath: '',
      url: '',
      host: '',
      port: '',
      share: '',
      rootPath: '',
      domain: '',
      username: '',
      password: '',
      secure: ''
    };
    for (const pair of body.split('&')) {
      const eq: number = pair.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const key: string = decodeURIComponent(pair.substring(0, eq).replace(/\+/g, ' '));
      const rawValue: string = pair.substring(eq + 1).replace(/\+/g, ' ');
      let value: string = rawValue;
      try {
        value = decodeURIComponent(rawValue);
      } catch (err) {
        value = rawValue;
      }
      if (key === 'type') {
        form.type = value;
      } else if (key === 'name') {
        form.name = value;
      } else if (key === 'localPath') {
        form.localPath = value;
      } else if (key === 'url') {
        form.url = value;
      } else if (key === 'host') {
        form.host = value;
      } else if (key === 'port') {
        form.port = value;
      } else if (key === 'share') {
        form.share = value;
      } else if (key === 'rootPath') {
        form.rootPath = value;
      } else if (key === 'domain') {
        form.domain = value;
      } else if (key === 'username') {
        form.username = value;
      } else if (key === 'password') {
        form.password = value;
      } else if (key === 'secure') {
        form.secure = value;
      }
    }
    return form;
  }

  private respond(conn: socket.TCPSocketConnection, status: number, body: string): void {
    const payload: Uint8Array = this.encoder.encodeInto(body);
    const header: string = `HTTP/1.1 ${status} ${PairingServer.statusText(status)}\r\n` +
      'Content-Type: text/html; charset=utf-8\r\n' +
      `Content-Length: ${payload.byteLength}\r\n` +
      'Connection: close\r\n' +
      'Cache-Control: no-store\r\n\r\n';
    const merged: Uint8Array = new Uint8Array(header.length + payload.byteLength);
    merged.set(this.encoder.encodeInto(header), 0);
    merged.set(payload, header.length);
    conn.send({ data: merged.buffer as ArrayBuffer }).then(() => {
      conn.close().catch((err: Error) => {
        Logger.debug('PairingServer', '关闭连接失败');
      });
    }).catch((err: Error) => {
      Logger.warn('PairingServer', '发送响应失败');
    });
  }

  private static statusText(status: number): string {
    if (status === 200) {
      return 'OK';
    }
    if (status === 403) {
      return 'Forbidden';
    }
    if (status === 405) {
      return 'Method Not Allowed';
    }
    return 'OK';
  }

  private static randomToken(): string {
    const alphabet: string = 'abcdefghijkmnpqrstuvwxyz23456789';
    let token: string = '';
    for (let i = 0; i < 10; i++) {
      token += alphabet.charAt(Math.floor(Math.random() * alphabet.length));
    }
    return token;
  }

  private static htmlMessage(title: string, detail: string): string {
    return '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">' +
      '<meta name="viewport" content="width=device-width,initial-scale=1">' +
      `<title>${title}</title>` +
      '<style>body{font-family:-apple-system,"HarmonyOS Sans",sans-serif;background:#FFFBF8;color:#241B18;' +
      'margin:0;padding:32px 20px}h1{font-size:22px;margin:0 0 12px}p{color:#7A6A63;font-size:15px;line-height:1.6}' +
      '</style></head><body>' +
      `<h1>${title}</h1><p>${detail}</p></body></html>`;
  }

  private static formHtml(target: string): string {
    const token: string = PairingServer.queryToken(target);
    const action: string = `/submit?t=${token}`;
    return '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">' +
      '<meta name="viewport" content="width=device-width,initial-scale=1">' +
      '<title>TomatoTV 添加存储</title>' +
      '<style>' +
      'body{font-family:-apple-system,"HarmonyOS Sans",sans-serif;background:#FFFBF8;color:#241B18;' +
      'margin:0;padding:20px}header{padding:8px 0 16px}h1{font-size:20px;margin:0 0 4px}' +
      'p.hint{color:#7A6A63;font-size:13px;margin:0}label{display:block;font-size:13px;color:#7A6A63;margin:16px 0 6px}' +
      'input,select{width:100%;box-sizing:border-box;padding:12px;font-size:15px;border:1px solid #EFE1DA;' +
      'border-radius:12px;background:#fff;color:#241B18}' +
      'button{margin-top:24px;width:100%;padding:14px;font-size:16px;border:0;border-radius:999px;' +
      'background:#E54835;color:#fff;font-weight:600}' +
      '.row{display:none}.row.active{display:block}' +
      '</style></head><body>' +
      '<header><h1>TomatoTV</h1><p class="hint">在智慧屏上核对后点击保存，提交后本链接失效。</p></header>' +
      `<form method="post" action="${action}">` +
      '<label>类型</label><select name="type" id="type" onchange="switchType()">' +
      '<option value="LOCAL">本机目录</option><option value="WEBDAV">WebDAV</option>' +
      '<option value="SMB">SMB</option><option value="FTP">FTP</option></select>' +
      '<label>名称</label><input name="name" placeholder="例如：家里的 NAS" required>' +
      '<div class="row active" id="row-local"><label>目录路径</label>' +
      '<input name="localPath" placeholder="智慧屏可访问的目录路径"></div>' +
      '<div class="row" id="row-webdav"><label>服务器地址</label>' +
      '<input name="url" placeholder="https://example.com/dav"></div>' +
      '<div class="row" id="row-host"><label>服务器地址</label><input name="host" placeholder="主机名或 IP"></div>' +
      '<div class="row" id="row-host"><label>端口</label><input name="port" placeholder="445 / 21"></div>' +
      '<div class="row" id="row-smb"><label>共享名</label><input name="share" placeholder="share"></div>' +
      '<div class="row" id="row-root"><label>根路径</label><input name="rootPath" placeholder="可留空"></div>' +
      '<div class="row" id="row-smb"><label>域</label><input name="domain" placeholder="可留空"></div>' +
      '<div class="row" id="row-creds"><label>用户名</label><input name="username" placeholder="可留空"></div>' +
      '<div class="row" id="row-creds"><label>密码</label><input name="password" type="password"></div>' +
      '<div class="row" id="row-ftp"><label>使用 FTPS（显式 TLS）</label>' +
      '<select name="secure"><option value="false">否</option><option value="true">是</option></select></div>' +
      '<button type="submit">提交到智慧屏</button></form>' +
      '<script>' +
      'function switchType(){var t=document.getElementById("type").value;' +
      'var map={LOCAL:["row-local"],WEBDAV:["row-webdav","row-creds"],SMB:["row-host","row-smb","row-root","row-creds"],' +
      'FTP:["row-host","row-root","row-creds","row-ftp"]};' +
      'document.querySelectorAll(".row").forEach(function(el){el.classList.remove("active")});' +
      'map[t].forEach(function(id){document.querySelectorAll("#"+id).forEach(function(el)' +
      '{el.classList.add("active")})})}' +
      'window.addEventListener("load",switchType);' +
      '</script></body></html>';
  }
}
