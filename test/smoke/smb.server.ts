/**
 * 严格按 MS-SMB2 报文布局实现的"最小 SMB2 测试服务端"（仅本地测试用）。
 *
 * 目的：本机 Windows 服务端拒绝 NTLM（第三方参考客户端同样被拒），无法验证认证链路，
 * 因此这里按规范独立实现一套服务端：它会严格校验客户端报文的 StructureSize / 偏移，
 * 布局不对就直接报错，从而在不依赖真机的情况下验证 Smb2Client 的报文正确性。
 *
 * 支持：NEGOTIATE(2.1) / SESSION_SETUP(NTLM Type1+Type3) / TREE_CONNECT /
 *      CREATE / QUERY_DIRECTORY / QUERY_INFO(FileAllInformation) / READ / CLOSE / LOGOFF
 */
import { createServer, Server, Socket } from 'node:net';

const FILE_CONTENT: Buffer = Buffer.from(Array.from({ length: 8192 }, (_v, i) => i % 251));
const FILE_NAME = 'sample.bin';
const DIR_NAME = 'sub';

function u16(value: number): Buffer {
  const b = Buffer.alloc(2);
  b.writeUInt16LE(value, 0);
  return b;
}

function u32(value: number): Buffer {
  const b = Buffer.alloc(4);
  b.writeUInt32LE(value, 0);
  return b;
}

function u64(value: number): Buffer {
  const b = Buffer.alloc(8);
  b.writeBigUInt64LE(BigInt(value), 0);
  return b;
}

function utf16(text: string): Buffer {
  return Buffer.from(text, 'utf16le');
}

function frame(message: Buffer): Buffer {
  const out = Buffer.alloc(4 + message.length);
  out.writeUInt8(0, 0);
  out.writeUInt8((message.length >> 16) & 0xff, 1);
  out.writeUInt16BE(message.length & 0xffff, 2);
  message.copy(out, 4);
  return out;
}

function fileTime(ms: number): number {
  return Math.round(ms * 10000) + 116444736000000000;
}

interface HeaderInfo {
  command: number;
  messageIdLow: number;
  messageIdHigh: number;
  treeId: number;
  sessionIdLow: number;
  sessionIdHigh: number;
  messageId: bigint;
  sessionId: bigint;
}

export class Smb2TestServer {
  private server: Server | null = null;
  private port: number = 0;
  readonly problems: string[] = [];
  readonly seen: string[] = [];
  private sessionId: bigint = BigInt('0x100000001');

  async start(): Promise<number> {
    this.server = createServer((socket: Socket) => this.handleSocket(socket));
    await new Promise<void>((resolve) => {
      this.server!.listen(0, '127.0.0.1', () => resolve());
    });
    const address = this.server.address();
    this.port = typeof address === 'object' && address !== null ? address.port : 0;
    return this.port;
  }

  async stop(): Promise<void> {
    if (this.server !== null) {
      await new Promise<void>((resolve) => this.server!.close(() => resolve()));
      this.server = null;
    }
  }

  private fail(reason: string): void {
    this.problems.push(reason);
    console.log(`  [srv][校验失败] ${reason}`);
  }

  private handleSocket(socket: Socket): void {
    let buffer: Buffer = Buffer.alloc(0);
    socket.on('data', (chunk: Buffer) => {
      buffer = Buffer.concat([buffer, chunk]);
      while (buffer.length >= 4) {
        const length = (buffer[1] << 16) | (buffer[2] << 8) | buffer[3];
        if (buffer.length < 4 + length) {
          return;
        }
        const message = buffer.subarray(4, 4 + length);
        buffer = buffer.subarray(4 + length);
        try {
          const response = this.dispatch(message);
          if (response !== null) {
            socket.write(frame(response));
          }
        } catch (error) {
          this.fail(`dispatch 异常: ${error instanceof Error ? error.message : String(error)}`);
        }
      }
    });
    socket.on('error', () => {
    });
  }

  private parseHeader(message: Buffer): HeaderInfo {
    if (message.length < 64) {
      this.fail('报文长度 < 64');
    }
    if (message[0] !== 0xfe || message[1] !== 0x53 || message[2] !== 0x4d || message[3] !== 0x42) {
      this.fail('协议签名不是 FE SMB');
    }
    if (message.readUInt16LE(4) !== 64) {
      this.fail(`StructureSize != 64 (${message.readUInt16LE(4)})`);
    }
    const command = message.readUInt16LE(12);
    const header: HeaderInfo = {
      command: command,
      messageIdLow: message.readUInt32LE(24),
      messageIdHigh: message.readUInt32LE(28),
      treeId: message.readUInt32LE(36),
      sessionIdLow: message.readUInt32LE(40),
      sessionIdHigh: message.readUInt32LE(44),
      messageId: BigInt(0),
      sessionId: BigInt(0)
    };
    header.messageId = (BigInt(header.messageIdHigh) << BigInt(32)) | BigInt(header.messageIdLow);
    header.sessionId = (BigInt(header.sessionIdHigh) << BigInt(32)) | BigInt(header.sessionIdLow);
    this.seen.push(`${this.commandName(command)}#${header.messageId.toString()}`);
    console.log(`  [srv] ${this.commandName(command)} msgId=${header.messageId.toString()} len=${message.length}`);
    return header;
  }

  private commandName(command: number): string {
    const names: Record<number, string> = {
      0: 'NEGOTIATE', 1: 'SESSION_SETUP', 2: 'LOGOFF', 3: 'TREE_CONNECT', 4: 'TREE_DISCONNECT',
      5: 'CREATE', 6: 'CLOSE', 8: 'READ', 14: 'QUERY_DIRECTORY', 16: 'QUERY_INFO'
    };
    return names[command] === undefined ? `CMD_${command}` : names[command];
  }

  /** 构造响应头（64 字节） */
  private responseHeader(header: HeaderInfo, status: number, bodyLength: number,
    options?: { treeId?: number, sessionId?: bigint, credits?: number }): Buffer {
    const out = Buffer.alloc(64);
    out.writeUInt8(0xfe, 0);
    out.writeUInt8(0x53, 1);
    out.writeUInt8(0x4d, 2);
    out.writeUInt8(0x42, 3);
    out.writeUInt16LE(64, 4);
    out.writeUInt16LE(1, 6);
    out.writeUInt32LE(status, 8);
    out.writeUInt16LE(header.command, 12);
    out.writeUInt16LE(options?.credits === undefined ? 32 : options.credits, 14);
    out.writeUInt32LE(0x00000001, 16); // SERVER_TO_REDIR
    out.writeUInt32LE(0, 20);
    out.writeBigUInt64LE(header.messageId, 24);
    out.writeUInt32LE(options?.treeId === undefined ? header.treeId : options.treeId, 36);
    const sessionId = options?.sessionId === undefined ? header.sessionId : options.sessionId;
    out.writeBigUInt64LE(sessionId, 40);
    void bodyLength;
    return out;
  }

  private dispatch(message: Buffer): Buffer | null {
    const header = this.parseHeader(message);
    const body = message.subarray(64);
    switch (header.command) {
      case 0:
        return this.onNegotiate(header, body);
      case 1:
        return this.onSessionSetup(header, body);
      case 2:
        return this.onLogoff(header);
      case 3:
        return this.onTreeConnect(header, body);
      case 5:
        return this.onCreate(header, body);
      case 6:
        return this.onClose(header, body);
      case 8:
        return this.onRead(header, body);
      case 14:
        return this.onQueryDirectory(header, body);
      case 16:
        return this.onQueryInfo(header, body);
      default:
        this.fail(`未实现的命令 ${header.command}`);
        return this.simpleResponse(header, 0xc00000bb, u16(9));
    }
  }

  private simpleResponse(header: HeaderInfo, status: number, body: Buffer,
    options?: { treeId?: number, sessionId?: bigint }): Buffer {
    return Buffer.concat([this.responseHeader(header, status, body.length, options), body]);
  }

  // ---------------- NEGOTIATE ----------------
  private onNegotiate(header: HeaderInfo, body: Buffer): Buffer {
    if (body.readUInt16LE(0) !== 36) {
      this.fail(`NEGOTIATE 请求 StructureSize != 36 (${body.readUInt16LE(0)})`);
    }
    const dialectCount = body.readUInt16LE(2);
    const dialects: number[] = [];
    for (let i = 0; i < dialectCount; i++) {
      dialects.push(body.readUInt16LE(36 + i * 2));
    }
    if (!dialects.includes(0x0210)) {
      this.fail(`客户端方言列表里没有 2.1：${dialects.map((d) => d.toString(16)).join(',')}`);
    }
    const securityMode = body.readUInt16LE(4);
    if ((securityMode & 0x01) === 0) {
      this.fail('NEGOTIATE 请求未开启 signing');
    }
    const spnego = this.ntlmType2();
    const fixed = Buffer.alloc(64);
    fixed.writeUInt16LE(65, 0);
    fixed.writeUInt16LE(1, 2); // SecurityMode: signing enabled
    fixed.writeUInt16LE(0x0210, 4);
    fixed.writeUInt16LE(0, 6);
    Buffer.from('00112233445566778899aabbccddeeff', 'hex').copy(fixed, 8); // ServerGuid
    fixed.writeUInt32LE(0, 24); // Capabilities
    fixed.writeUInt32LE(1048576, 28); // MaxTransactSize
    fixed.writeUInt32LE(1048576, 32); // MaxReadSize
    fixed.writeUInt32LE(1048576, 36); // MaxWriteSize
    fixed.writeBigUInt64LE(BigInt(fileTime(Date.now())), 40);
    fixed.writeBigUInt64LE(BigInt(0), 48);
    fixed.writeUInt16LE(128, 56); // SecurityBufferOffset = 64 + 64
    fixed.writeUInt16LE(spnego.length, 58);
    return this.simpleResponse(header, 0, Buffer.concat([fixed, spnego]));
  }

  /** NTLM Type2（CHALLENGE）：手动按 MS-NLMP 构造，避免使用被测代码 */
  private ntlmType2(): Buffer {
    const targetName = utf16('TESTSRV');
    const domain = utf16('TEST');
    const computer = utf16('TESTSRV');
    const targetInfo = Buffer.concat([
      u16(2), u16(domain.length), domain,
      u16(1), u16(computer.length), computer,
      u16(0), u16(0)
    ]);
    const fixed = Buffer.alloc(48);
    Buffer.from('NTLMSSP\0', 'ascii').copy(fixed, 0);
    fixed.writeUInt32LE(2, 8);
    fixed.writeUInt16LE(targetName.length, 12);
    fixed.writeUInt16LE(targetName.length, 14);
    fixed.writeUInt32LE(48 + targetInfo.length, 16);
    fixed.writeUInt32LE(0xe28a8235, 20);
    Buffer.from('aabbccddeeff0011', 'hex').copy(fixed, 24); // ServerChallenge
    fixed.writeUInt16LE(targetInfo.length, 40);
    fixed.writeUInt16LE(targetInfo.length, 42);
    fixed.writeUInt32LE(48, 44);
    const type2 = Buffer.concat([fixed, targetInfo, targetName]);
    // SPNEGO NegTokenResp（[1] SEQUENCE { [2] OCTET STRING })
    const octet = Buffer.concat([Buffer.from([0x04]), derLength(type2.length), type2]);
    const responseToken = Buffer.concat([Buffer.from([0xa2]), derLength(octet.length), octet]);
    const sequence = Buffer.concat([Buffer.from([0x30]), derLength(responseToken.length), responseToken]);
    return Buffer.concat([Buffer.from([0xa1]), derLength(sequence.length), sequence]);
  }

  // ---------------- SESSION_SETUP ----------------
  private sessionCount: number = 0;
  private dirQueries: number = 0;

  private onSessionSetup(header: HeaderInfo, body: Buffer): Buffer {
    if (body.readUInt16LE(0) !== 25) {
      this.fail(`SESSION_SETUP 请求 StructureSize != 25 (${body.readUInt16LE(0)})`);
    }
    const offset = body.readUInt16LE(12);
    const length = body.readUInt16LE(14);
    if (offset !== 64 + 24) {
      this.fail(`SESSION_SETUP SecurityBufferOffset 期望 ${64 + 24}，实际 ${offset}`);
    }
    if (offset + length > body.length + 64) {
      this.fail(`SESSION_SETUP 安全 blob 越界 offset=${offset} length=${length}`);
    }
    const blob = Buffer.concat([body.subarray(0, 0), Buffer.alloc(0)]);
    void blob;
    const start = offset - 64;
    const token = body.subarray(start, start + length);
    const signature = token.indexOf(Buffer.from('NTLMSSP\0', 'ascii'));
    if (signature < 0) {
      this.fail('SESSION_SETUP 的 blob 里没有 NTLMSSP 令牌');
      return this.simpleResponse(header, 0xc000000d, u16(9));
    }
    const type = token.readUInt32LE(signature + 8);
    const headerSession: bigint = header.sessionId;
    if (type === 1) {
      if (headerSession !== BigInt(0)) {
        this.fail(`首个 SESSION_SETUP 的 header SessionId 应为 0，实际 ${headerSession.toString()}`);
      }
      if (body.readBigUInt64LE(16) !== BigInt(0)) {
        this.fail('首个 SESSION_SETUP 的 PreviousSessionId 应为 0');
      }
      this.sessionCount = 1;
      const challenge = this.ntlmType2();
      const fixed = Buffer.alloc(8);
      fixed.writeUInt16LE(9, 0);
      fixed.writeUInt16LE(0x0001, 2); // SessionFlags: IS_GUEST? use 0
      fixed.writeUInt16LE(64 + 8, 4);
      fixed.writeUInt16LE(challenge.length, 6);
      return this.simpleResponse(header, 0xc0000016 /* MORE_PROCESSING_REQUIRED */,
        Buffer.concat([fixed, challenge]), { sessionId: this.sessionId });
    }
    if (type === 3) {
      if (headerSession !== this.sessionId) {
        this.fail(`Type3 的 header SessionId 应为 ${this.sessionId.toString()}，实际 ${headerSession.toString()}`);
      }
      if (body.readBigUInt64LE(16) !== BigInt(0)) {
        this.fail('Type3 的 PreviousSessionId 应为 0（新会话不允许重连语义）');
      }
      // 校验 Type3 的关键字段布局
      const ntResponseLen = token.readUInt16LE(signature + 20);
      const ntResponseOffset = token.readUInt32LE(signature + 24);
      const domainLen = token.readUInt16LE(signature + 28);
      const domainOffset = token.readUInt32LE(signature + 32);
      const userLen = token.readUInt16LE(signature + 36);
      const userOffset = token.readUInt32LE(signature + 40);
      if (ntResponseLen <= 16) {
        this.fail(`Type3 NtChallengeResponse 长度异常 ${ntResponseLen}`);
      }
      if (userLen === 0 || domainLen === 0) {
        this.fail(`Type3 用户名/域为空 user=${userLen} domain=${domainLen}`);
      }
      if (signature + userOffset + userLen > token.length) {
        this.fail('Type3 UserName 偏移越界');
      }
      if (signature + ntResponseOffset + ntResponseLen > token.length) {
        this.fail('Type3 NtChallengeResponse 偏移越界');
      }
      const fixed = Buffer.concat([u16(9), u16(0), u16(0), u16(0)]);
      return this.simpleResponse(header, 0, fixed, { sessionId: this.sessionId });
    }
    this.fail(`未知 NTLM 类型 ${type}`);
    return this.simpleResponse(header, 0xc000000d, u16(9));
  }

  private onLogoff(header: HeaderInfo): Buffer {
    return this.simpleResponse(header, 0, Buffer.concat([u16(4), u16(0)]));
  }

  // ---------------- TREE_CONNECT ----------------
  private onTreeConnect(header: HeaderInfo, body: Buffer): Buffer {
    if (body.readUInt16LE(0) !== 9) {
      this.fail(`TREE_CONNECT 请求 StructureSize != 9 (${body.readUInt16LE(0)})`);
    }
    const offset = body.readUInt16LE(4);
    const length = body.readUInt16LE(6);
    const start = offset - 64;
    if (start < 0 || start + length > body.length) {
      this.fail(`TREE_CONNECT 路径越界 offset=${offset} length=${length}`);
    } else {
      const path = body.subarray(start, start + length).toString('utf16le');
      if (!path.startsWith('\\\\')) {
        this.fail(`TREE_CONNECT 路径格式异常: ${path}`);
      }
    }
    const fixed = Buffer.alloc(16);
    fixed.writeUInt16LE(16, 0);
    fixed.writeUInt8(1, 2); // ShareType: DISK
    fixed.writeUInt32LE(0, 4);
    fixed.writeUInt32LE(0, 8);
    fixed.writeUInt32LE(0x001f01ff, 12);
    return this.simpleResponse(header, 0, fixed, { treeId: 0x00000007 });
  }

  // ---------------- CREATE ----------------
  private onCreate(header: HeaderInfo, body: Buffer): Buffer {
    if (body.readUInt16LE(0) !== 57) {
      this.fail(`CREATE 请求 StructureSize != 57 (${body.readUInt16LE(0)})`);
    }
    // StructureSize 语义是"固定 56 字节 + 至少 1 字节 Buffer"：
    // 打开共享根时名字为空，请求体若只有 56 字节，Samba/Windows 会直接返回
    // STATUS_INVALID_PARAMETER。这里对齐真实服务端行为。
    if (body.length < 57) {
      this.fail(`CREATE 请求体只有 ${body.length} 字节，真实服务端要求 >= 57`);
      return this.simpleResponse(header, 0xc000000d, u16(9));
    }
    const nameOffset = body.readUInt16LE(44);
    const nameLength = body.readUInt16LE(46);
    const start = nameOffset - 64;
    let name = '';
    if (nameLength > 0) {
      if (start < 0 || start + nameLength > body.length) {
        this.fail(`CREATE 名字越界 offset=${nameOffset} length=${nameLength}`);
      } else {
        name = body.subarray(start, start + nameLength).toString('utf16le');
      }
    }
    const isDirectory = name.length === 0 || name === DIR_NAME;
    if (isDirectory) {
      this.dirQueries = 0;
    }
    const size = isDirectory ? 0 : FILE_CONTENT.length;
    const fixed = Buffer.alloc(88);
    fixed.writeUInt16LE(89, 0);
    fixed.writeUInt8(1, 2);
    fixed.writeUInt32LE(isDirectory ? 2 : 1, 4);
    fixed.writeBigUInt64LE(BigInt(fileTime(Date.now() - 100000)), 8);
    fixed.writeBigUInt64LE(BigInt(fileTime(Date.now() - 50000)), 16);
    fixed.writeBigUInt64LE(BigInt(fileTime(Date.now())), 24);
    fixed.writeBigUInt64LE(BigInt(fileTime(Date.now())), 32);
    fixed.writeBigUInt64LE(BigInt(0), 40);
    fixed.writeBigUInt64LE(BigInt(size), 48);
    fixed.writeUInt32LE(isDirectory ? 0x10 : 0x80, 56);
    fixed.writeBigUInt64LE(BigInt(isDirectory ? 0x2000 : 0x2001), 64);
    fixed.writeBigUInt64LE(BigInt(0x3000), 72);
    return this.simpleResponse(header, 0, fixed);
  }

  private onClose(header: HeaderInfo, body: Buffer): Buffer {
    if (body.readUInt16LE(0) !== 24) {
      this.fail(`CLOSE 请求 StructureSize != 24 (${body.readUInt16LE(0)})`);
    }
    const fixed = Buffer.alloc(60);
    fixed.writeUInt16LE(60, 0);
    return this.simpleResponse(header, 0, fixed);
  }

  // ---------------- QUERY_DIRECTORY ----------------
  private onQueryDirectory(header: HeaderInfo, body: Buffer): Buffer {
    if (body.readUInt16LE(0) !== 33) {
      this.fail(`QUERY_DIRECTORY 请求 StructureSize != 33 (${body.readUInt16LE(0)})`);
    }
    const patternOffset = body.readUInt16LE(24);
    const patternLength = body.readUInt16LE(26);
    const start = patternOffset - 64;
    if (start < 0 || start + patternLength > body.length) {
      this.fail(`QUERY_DIRECTORY pattern 越界 offset=${patternOffset} length=${patternLength}`);
    }
    if (this.dirQueries > 0) {
      // 枚举结束：规范允许直接返回 STATUS_NO_MORE_FILES
      const empty = Buffer.alloc(8);
      empty.writeUInt16LE(9, 0);
      empty.writeUInt16LE(0, 2);
      empty.writeUInt32LE(0, 4);
      return this.simpleResponse(header, 0x80000006, empty);
    }
    this.dirQueries++;
    const first = this.dirEntry(FILE_NAME, FILE_CONTENT.length, false);
    const second = this.dirEntry(DIR_NAME, 0, true);
    first.writeUInt32LE(first.length, 0); // NextEntryOffset 指向第二项
    const entries = Buffer.concat([first, second]);
    const fixed = Buffer.alloc(8);
    fixed.writeUInt16LE(9, 0);
    fixed.writeUInt16LE(64 + 8, 2); // OutputBufferOffset
    fixed.writeUInt32LE(entries.length, 4);
    return this.simpleResponse(header, 0, Buffer.concat([fixed, entries]));
  }

  private dirEntry(name: string, size: number, isDirectory: boolean): Buffer {
    const nameBytes = utf16(name);
    const fixed = Buffer.alloc(104);
    fixed.writeUInt32LE(0, 0); // NextEntryOffset：单项，最后一跳填 0
    fixed.writeUInt32LE(0, 4);
    fixed.writeBigUInt64LE(BigInt(fileTime(Date.now() - 20000)), 8);
    fixed.writeBigUInt64LE(BigInt(fileTime(Date.now() - 10000)), 16);
    fixed.writeBigUInt64LE(BigInt(fileTime(Date.now())), 24);
    fixed.writeBigUInt64LE(BigInt(fileTime(Date.now())), 32);
    fixed.writeBigUInt64LE(BigInt(size), 40);
    fixed.writeBigUInt64LE(BigInt(size), 48);
    fixed.writeUInt32LE(isDirectory ? 0x10 : 0x80, 56);
    fixed.writeUInt32LE(nameBytes.length, 60);
    fixed.writeUInt32LE(0, 64);
    fixed.writeUInt8(0, 68);
    fixed.writeUInt8(0, 69);
    fixed.writeBigUInt64LE(BigInt(0x4000), 96);
    return Buffer.concat([fixed, nameBytes]);
  }

  // ---------------- QUERY_INFO (FileAllInformation) ----------------
  private onQueryInfo(header: HeaderInfo, body: Buffer): Buffer {
    if (body.readUInt16LE(0) !== 41) {
      this.fail(`QUERY_INFO 请求 StructureSize != 41 (${body.readUInt16LE(0)})`);
    }
    if (body.length < 41) {
      this.fail(`QUERY_INFO 请求体只有 ${body.length} 字节，真实服务端要求 >= 41`);
      return this.simpleResponse(header, 0xc000000d, u16(9));
    }
    const infoClass = body.readUInt8(3);
    if (infoClass !== 18) {
      this.fail(`QUERY_INFO FileInformationClass 期望 18，实际 ${infoClass}`);
    }
    // BasicInformation(40) + StandardInformation(24) + Internal(8) + Ea(4) + Access(4) +
    // Position(8) + Mode(4) + Alignment(4)
    const data = Buffer.alloc(96);
    data.writeBigUInt64LE(BigInt(fileTime(Date.now() - 20000)), 0);
    data.writeBigUInt64LE(BigInt(fileTime(Date.now() - 10000)), 8);
    data.writeBigUInt64LE(BigInt(fileTime(Date.now())), 16);
    data.writeBigUInt64LE(BigInt(fileTime(Date.now())), 24);
    data.writeUInt32LE(0x80, 32);
    data.writeBigUInt64LE(BigInt(FILE_CONTENT.length), 40);
    data.writeBigUInt64LE(BigInt(FILE_CONTENT.length), 48);
    data.writeUInt32LE(1, 56);
    data.writeUInt8(0, 60);
    data.writeUInt8(0, 61); // Directory = false
    const fixed = Buffer.alloc(8);
    fixed.writeUInt16LE(9, 0);
    fixed.writeUInt16LE(64 + 8, 2);
    fixed.writeUInt32LE(data.length, 4);
    return this.simpleResponse(header, 0, Buffer.concat([fixed, data]));
  }

  // ---------------- READ ----------------
  private onRead(header: HeaderInfo, body: Buffer): Buffer {
    if (body.readUInt16LE(0) !== 49) {
      this.fail(`READ 请求 StructureSize != 49 (${body.readUInt16LE(0)})`);
    }
    const length = body.readUInt32LE(4);
    const offset = Number(body.readBigUInt64LE(8));
    const available = Math.max(0, FILE_CONTENT.length - offset);
    if (available === 0) {
      return this.simpleResponse(header, 0xc0000011, Buffer.alloc(0)); // STATUS_END_OF_FILE
    }
    const take = Math.min(length, available);
    const payload = FILE_CONTENT.subarray(offset, offset + take);
    const fixed = Buffer.alloc(16);
    fixed.writeUInt16LE(17, 0);
    fixed.writeUInt8(64 + 16, 2); // DataOffset（偏移 2）
    fixed.writeUInt32LE(take, 4);
    fixed.writeUInt32LE(0, 8);
    fixed.writeUInt32LE(0, 12);
    return this.simpleResponse(header, 0, Buffer.concat([fixed, payload]));
  }

  get fileContent(): Buffer {
    return FILE_CONTENT;
  }

  get fileName(): string {
    return FILE_NAME;
  }

  get dirName(): string {
    return DIR_NAME;
  }
}

function derLength(length: number): Buffer {
  if (length < 0x80) {
    return Buffer.from([length]);
  }
  if (length < 0x100) {
    return Buffer.from([0x81, length]);
  }
  return Buffer.from([0x82, (length >> 8) & 0xff, length & 0xff]);
}
