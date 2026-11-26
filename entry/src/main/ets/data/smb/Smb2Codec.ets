import { FileEntry, FileEntryFactory } from '../../model/FileEntry';
import { FsError, FsErrorKind } from '../fs/FileSystemClient';
import { Ntlm } from './Ntlm';
import { SmbCrypto } from './SmbCrypto';

/** SMB2 命令码（MS-SMB2 2.2.1.2） */
export class Smb2Command {
  static readonly NEGOTIATE: number = 0x0000;
  static readonly SESSION_SETUP: number = 0x0001;
  static readonly LOGOFF: number = 0x0002;
  static readonly TREE_CONNECT: number = 0x0003;
  static readonly TREE_DISCONNECT: number = 0x0004;
  static readonly CREATE: number = 0x0005;
  static readonly CLOSE: number = 0x0006;
  static readonly READ: number = 0x0008;
  static readonly QUERY_DIRECTORY: number = 0x000E;
  static readonly QUERY_INFO: number = 0x0010;
}

export class Smb2Status {
  static readonly SUCCESS: number = 0x00000000;
  static readonly PENDING: number = 0x00000103;
  static readonly BUFFER_OVERFLOW: number = 0x80000005;
  static readonly NO_MORE_FILES: number = 0x80000006;
  static readonly MORE_PROCESSING_REQUIRED: number = 0xC0000016;
  static readonly LOGON_FAILURE: number = 0xC000006D;
  static readonly ACCESS_DENIED: number = 0xC0000022;
  static readonly OBJECT_NAME_NOT_FOUND: number = 0xC0000034;
  static readonly OBJECT_PATH_NOT_FOUND: number = 0xC000003A;
  static readonly BAD_NETWORK_NAME: number = 0xC00000CC;
  static readonly FILE_IS_A_DIRECTORY: number = 0xC00000BA;
  static readonly NOT_A_DIRECTORY: number = 0xC0000103;
}

export class Smb2Header {
  command: number = 0;
  status: number = 0;
  flags: number = 0;
  messageId: number = 0;
  treeId: number = 0;
  sessionId: number = 0;
  credits: number = 0;
  signature: Uint8Array = new Uint8Array(16);
  bodyOffset: number = 64;
  raw: Uint8Array = new Uint8Array(0);
}

export interface Smb2FileId {
  persistent: number;
  volatileId: number;
}

export interface Smb2FileInfo {
  size: number;
  isDirectory: boolean;
  modified: number;
}

export interface Smb2ConnectionHandle {
  treeId: number;
  fileId: Smb2FileId;
}

const HEADER_SIZE: number = 64;

/** SMB2 报文编解码（纯逻辑，便于单元测试） */
export class Smb2Codec {
  // ---------------- 基础写入 ----------------
  static u8(value: number): Uint8Array {
    return new Uint8Array([value & 0xFF]);
  }

  static u16(value: number): Uint8Array {
    const out: Uint8Array = new Uint8Array(2);
    Ntlm.writeUint16(out, 0, value);
    return out;
  }

  static u32(value: number): Uint8Array {
    const out: Uint8Array = new Uint8Array(4);
    Ntlm.writeUint32(out, 0, value);
    return out;
  }

  static u64(value: number): Uint8Array {
    const out: Uint8Array = new Uint8Array(8);
    const low: number = value % 4294967296;
    const high: number = Math.floor(value / 4294967296);
    Ntlm.writeUint32(out, 0, low);
    Ntlm.writeUint32(out, 4, high);
    return out;
  }

  static readU64(bytes: Uint8Array, offset: number): number {
    const low: number = Ntlm.readUint32(bytes, offset);
    const high: number = Ntlm.readUint32(bytes, offset + 4);
    return high * 4294967296 + low;
  }

  /** 构造 SMB2 头（不含签名） */
  static buildHeader(command: number, messageId: number, treeId: number, sessionId: number,
    credits: number, flags: number): Uint8Array {
    const header: Uint8Array = new Uint8Array(HEADER_SIZE);
    header[0] = 0xFE;
    header[1] = 0x53; // 'S'
    header[2] = 0x4D; // 'M'
    header[3] = 0x42; // 'B'
    Ntlm.writeUint16(header, 4, HEADER_SIZE);
    Ntlm.writeUint16(header, 6, 1); // CreditCharge
    Ntlm.writeUint16(header, 12, command);
    Ntlm.writeUint16(header, 14, credits);
    Ntlm.writeUint32(header, 16, flags);
    Ntlm.writeUint32(header, 20, 0); // NextCommand
    Ntlm.writeUint32(header, 24, messageId % 4294967296);
    Ntlm.writeUint32(header, 28, Math.floor(messageId / 4294967296));
    Ntlm.writeUint32(header, 36, treeId);
    Ntlm.writeUint32(header, 40, sessionId % 4294967296);
    Ntlm.writeUint32(header, 44, Math.floor(sessionId / 4294967296));
    return header;
  }

  /** NETBIOS 会话服务帧：4 字节长度前缀 + SMB2 报文 */
  static frame(packet: Uint8Array): Uint8Array {
    const out: Uint8Array = new Uint8Array(4 + packet.length);
    out[0] = 0x00;
    out[1] = (packet.length >> 16) & 0xFF;
    out[2] = (packet.length >> 8) & 0xFF;
    out[3] = packet.length & 0xFF;
    out.set(packet, 4);
    return out;
  }

  static parseHeader(packet: Uint8Array): Smb2Header {
    if (packet.length < HEADER_SIZE) {
      throw new FsError(FsErrorKind.NETWORK, 'SMB2 报文过短');
    }
    const header: Smb2Header = new Smb2Header();
    header.command = Ntlm.readUint16(packet, 12);
    header.status = Ntlm.readUint32(packet, 8);
    header.flags = Ntlm.readUint32(packet, 16);
    header.credits = Ntlm.readUint16(packet, 14);
    header.messageId = Smb2Codec.readU64(packet, 24);
    header.treeId = Ntlm.readUint32(packet, 36);
    header.sessionId = Smb2Codec.readU64(packet, 40);
    header.signature = packet.slice(48, 64);
    header.bodyOffset = HEADER_SIZE;
    header.raw = packet;
    return header;
  }

  static isResponse(packet: Uint8Array): boolean {
    return (Ntlm.readUint32(packet, 16) & 0x00000001) !== 0;
  }

  // ---------------- NEGOTIATE ----------------
  static buildNegotiate(messageId: number, clientGuid: Uint8Array): Uint8Array {
    const body: Uint8Array = SmbCrypto.concat(
      Smb2Codec.u16(36), // StructureSize
      Smb2Codec.u16(2), // DialectCount
      Smb2Codec.u16(1), // SecurityMode: signing enabled
      Smb2Codec.u16(0), // Reserved
      Smb2Codec.u32(0), // Capabilities
      clientGuid, // 16 bytes
      Smb2Codec.u64(0), // ClientStartTime
      Smb2Codec.u16(0x0202), // SMB 2.0.2
      Smb2Codec.u16(0x0210) // SMB 2.1
    );
    const header: Uint8Array = Smb2Codec.buildHeader(Smb2Command.NEGOTIATE, messageId, 0, 0, 32, 0);
    return SmbCrypto.concat(header, body);
  }

  static dialectOf(packet: Uint8Array): number {
    return Ntlm.readUint16(packet, HEADER_SIZE + 4);
  }

  static securityBlobOf(packet: Uint8Array): Uint8Array {
    if (packet.length <= HEADER_SIZE + 64) {
      return new Uint8Array(0);
    }
    const offset: number = Ntlm.readUint16(packet, HEADER_SIZE + 56);
    const length: number = Ntlm.readUint16(packet, HEADER_SIZE + 58);
    if (length === 0 || offset + length > packet.length) {
      return new Uint8Array(0);
    }
    return packet.slice(offset, offset + length);
  }

  static serverRequiresSigning(packet: Uint8Array): boolean {
    const mode: number = Ntlm.readUint16(packet, HEADER_SIZE + 2);
    return (mode & 0x0002) !== 0;
  }

  // ---------------- SESSION_SETUP ----------------
  /**
   * SESSION_SETUP 请求（MS-SMB2 2.2.5）。
   *
   * sessionId：首个请求必须为 0；携带 NTLM Type3 的后续请求必须填服务端在上一响应里
   * 分配到的 SessionId（填 0 会被 Windows / Samba 判为 STATUS_INVALID_PARAMETER）。
   * previousSessionId：重连已有会话时才填，新会话必须为 0。
   */
  static buildSessionSetup(messageId: number, sessionId: number, securityBlob: Uint8Array,
    previousSessionId: number): Uint8Array {
    const bodySize: number = 24;
    const blobOffset: number = HEADER_SIZE + bodySize;
    const body: Uint8Array = SmbCrypto.concat(
      Smb2Codec.u16(25), // StructureSize
      Smb2Codec.u8(0), // Flags
      Smb2Codec.u8(1), // SecurityMode: signing enabled
      Smb2Codec.u32(0), // Capabilities（须与 NEGOTIATE 一致）
      Smb2Codec.u32(0), // Channel
      Smb2Codec.u16(blobOffset),
      Smb2Codec.u16(securityBlob.length),
      Smb2Codec.u64(previousSessionId)
    );
    const header: Uint8Array = Smb2Codec.buildHeader(Smb2Command.SESSION_SETUP, messageId, 0, sessionId, 32, 0);
    return SmbCrypto.concat(header, body, securityBlob);
  }

  /**
   * SESSION_SETUP 响应里的安全上下文 blob。
   * 注意偏移与 NEGOTIATE 不同：StructureSize(64) / SessionFlags(66) /
   * SecurityBufferOffset(68) / SecurityBufferLength(70)。
   */
  static sessionSetupBlob(packet: Uint8Array): Uint8Array {
    const base: number = HEADER_SIZE;
    if (packet.length < base + 8) {
      return new Uint8Array(0);
    }
    const offset: number = Ntlm.readUint16(packet, base + 4);
    const length: number = Ntlm.readUint16(packet, base + 6);
    if (length === 0 || offset === 0 || offset + length > packet.length) {
      return new Uint8Array(0);
    }
    return packet.slice(offset, offset + length);
  }

  // ---------------- TREE_CONNECT ----------------
  static buildTreeConnect(messageId: number, sessionId: number, uncPath: string): Uint8Array {
    const pathBytes: Uint8Array = SmbCrypto.utf16le(uncPath);
    const bodySize: number = 8;
    const pathOffset: number = HEADER_SIZE + bodySize;
    const body: Uint8Array = SmbCrypto.concat(
      Smb2Codec.u16(9), // StructureSize
      Smb2Codec.u16(0), // Reserved
      Smb2Codec.u16(pathOffset),
      Smb2Codec.u16(pathBytes.length),
      pathBytes
    );
    const header: Uint8Array = Smb2Codec.buildHeader(Smb2Command.TREE_CONNECT, messageId, 0, sessionId, 32, 0);
    return SmbCrypto.concat(header, body);
  }

  // ---------------- CREATE / CLOSE ----------------
  static buildCreate(messageId: number, sessionId: number, treeId: number, name: string,
    isDirectory: boolean): Uint8Array {
    const nameBytes: Uint8Array = SmbCrypto.utf16le(name);
    const bodySize: number = 56;
    const nameOffset: number = HEADER_SIZE + bodySize;
    const desiredAccess: number = isDirectory ? 0x00100081 : 0x00120089;
    const createOptions: number = isDirectory ? 0x00000001 : 0x00000040;
    const body: Uint8Array = SmbCrypto.concat(
      Smb2Codec.u16(57), // StructureSize
      Smb2Codec.u8(0), // SecurityFlags
      Smb2Codec.u8(0), // RequestedOplockLevel: none
      Smb2Codec.u32(2), // ImpersonationLevel: Impersonation
      Smb2Codec.u64(0), // SmbCreateFlags
      Smb2Codec.u64(0), // Reserved
      Smb2Codec.u32(desiredAccess),
      Smb2Codec.u32(0x80), // FileAttributes: normal
      Smb2Codec.u32(0x07), // ShareAccess: read|write|delete
      Smb2Codec.u32(1), // CreateDisposition: FILE_OPEN
      Smb2Codec.u32(createOptions),
      Smb2Codec.u16(nameOffset),
      Smb2Codec.u16(nameBytes.length),
      Smb2Codec.u32(0), // CreateContextsOffset
      Smb2Codec.u32(0), // CreateContextsLength
      nameBytes
    );
    const header: Uint8Array = Smb2Codec.buildHeader(Smb2Command.CREATE, messageId, treeId, sessionId, 32, 0);
    return SmbCrypto.concat(header, body);
  }

  static parseCreate(packet: Uint8Array): Smb2FileId {
    const base: number = HEADER_SIZE;
    const endOfFile: number = Smb2Codec.readU64(packet, base + 48);
    const fileId: Smb2FileId = {
      persistent: Smb2Codec.readU64(packet, base + 64),
      volatileId: Smb2Codec.readU64(packet, base + 72)
    };
    if (endOfFile < 0) {
      throw new FsError(FsErrorKind.NOT_FOUND, 'SMB2 CREATE 返回无效的文件大小');
    }
    return fileId;
  }

  static fileSizeOfCreate(packet: Uint8Array): number {
    return Smb2Codec.readU64(packet, HEADER_SIZE + 48);
  }

  static isDirectoryOfCreate(packet: Uint8Array): boolean {
    const attributes: number = Ntlm.readUint32(packet, HEADER_SIZE + 56);
    return (attributes & 0x10) !== 0;
  }

  static buildClose(messageId: number, sessionId: number, treeId: number, fileId: Smb2FileId): Uint8Array {
    const body: Uint8Array = SmbCrypto.concat(
      Smb2Codec.u16(24), // StructureSize
      Smb2Codec.u16(0), // Flags
      Smb2Codec.u32(0), // Reserved
      Smb2Codec.u64(fileId.persistent),
      Smb2Codec.u64(fileId.volatileId)
    );
    const header: Uint8Array = Smb2Codec.buildHeader(Smb2Command.CLOSE, messageId, treeId, sessionId, 32, 0);
    return SmbCrypto.concat(header, body);
  }

  // ---------------- READ ----------------
  static buildRead(messageId: number, sessionId: number, treeId: number, fileId: Smb2FileId, offset: number,
    length: number): Uint8Array {
    const body: Uint8Array = SmbCrypto.concat(
      Smb2Codec.u16(49), // StructureSize
      Smb2Codec.u8(0), // Padding
      Smb2Codec.u8(0), // Flags
      Smb2Codec.u32(Math.min(length, 0x00100000)), // Length
      Smb2Codec.u64(offset),
      Smb2Codec.u64(fileId.persistent),
      Smb2Codec.u64(fileId.volatileId),
      Smb2Codec.u32(0), // MinimumCount
      Smb2Codec.u32(0), // Channel
      Smb2Codec.u32(0), // RemainingBytes
      Smb2Codec.u16(0), // ReadChannelInfoOffset
      Smb2Codec.u16(0), // ReadChannelInfoLength
      Smb2Codec.u8(0) // Buffer
    );
    const header: Uint8Array = Smb2Codec.buildHeader(Smb2Command.READ, messageId, treeId, sessionId, 32, 0);
    return SmbCrypto.concat(header, body);
  }

  static parseReadData(packet: Uint8Array): Uint8Array {
    const base: number = HEADER_SIZE;
    // READ Response：StructureSize(2) / DataOffset(1) / Reserved(1) / DataLength(4) ...
    const dataOffset: number = packet[base + 2];
    const dataLength: number = Ntlm.readUint32(packet, base + 4);
    if (dataLength === 0) {
      return new Uint8Array(0);
    }
    const start: number = dataOffset;
    if (start + dataLength > packet.length) {
      return packet.slice(start);
    }
    return packet.slice(start, start + dataLength);
  }

  // ---------------- QUERY_DIRECTORY ----------------
  static buildQueryDirectory(messageId: number, sessionId: number, treeId: number, fileId: Smb2FileId,
    pattern: string, outputLength: number): Uint8Array {
    const patternBytes: Uint8Array = SmbCrypto.utf16le(pattern);
    const bodySize: number = 32;
    const patternOffset: number = HEADER_SIZE + bodySize;
    const body: Uint8Array = SmbCrypto.concat(
      Smb2Codec.u16(33), // StructureSize
      Smb2Codec.u8(37), // FileInformationClass: FileIdBothDirectoryInformation
      Smb2Codec.u8(0), // Flags
      Smb2Codec.u32(0), // FileIndex
      Smb2Codec.u64(fileId.persistent),
      Smb2Codec.u64(fileId.volatileId),
      Smb2Codec.u16(patternOffset),
      Smb2Codec.u16(patternBytes.length),
      Smb2Codec.u32(outputLength),
      patternBytes
    );
    const header: Uint8Array = Smb2Codec.buildHeader(Smb2Command.QUERY_DIRECTORY, messageId, treeId, sessionId,
      32, 0);
    return SmbCrypto.concat(header, body);
  }

  /** 解析 FileIdBothDirectoryInformation 列表 */
  static parseQueryDirectory(packet: Uint8Array, parentPath: string): FileEntry[] {
    const base: number = HEADER_SIZE;
    const outputOffset: number = Ntlm.readUint16(packet, base + 2);
    const outputLength: number = Ntlm.readUint32(packet, base + 4);
    const entries: FileEntry[] = [];
    if (outputLength === 0) {
      return entries;
    }
    let cursor: number = outputOffset;
    const end: number = Math.min(packet.length, outputOffset + outputLength);
    while (cursor + 104 <= end) {
      const next: number = Ntlm.readUint32(packet, cursor);
      const lastWrite: number = Smb2Codec.readU64(packet, cursor + 24);
      const endOfFile: number = Smb2Codec.readU64(packet, cursor + 40);
      const attributes: number = Ntlm.readUint32(packet, cursor + 56);
      const nameLength: number = Ntlm.readUint32(packet, cursor + 60);
      const name: string = SmbCrypto.fromUtf16le(packet, cursor + 104, nameLength);
      if (name.length > 0 && name !== '.' && name !== '..') {
        const isDirectory: boolean = (attributes & 0x10) !== 0;
        const childPath: string = parentPath.endsWith('/') ? `${parentPath}${name}` : `${parentPath}/${name}`;
        const modified: number = Ntlm.fileTimeToUnixMs(lastWrite);
        if (isDirectory) {
          entries.push(FileEntryFactory.directory(name, childPath, modified));
        } else {
          entries.push(FileEntryFactory.file(name, childPath, endOfFile, modified, ''));
        }
      }
      if (next === 0) {
        break;
      }
      cursor += next;
    }
    return entries;
  }

  // ---------------- QUERY_INFO ----------------
  static buildQueryInfo(messageId: number, sessionId: number, treeId: number, fileId: Smb2FileId,
    outputLength: number): Uint8Array {
    const body: Uint8Array = SmbCrypto.concat(
      Smb2Codec.u16(41), // StructureSize
      Smb2Codec.u8(1), // InfoType: File
      Smb2Codec.u8(18), // FileInformationClass: FileAllInformation
      Smb2Codec.u32(outputLength),
      Smb2Codec.u32(0), // InputBufferOffset
      Smb2Codec.u16(0), // Reserved
      Smb2Codec.u16(0), // InputBufferLength
      Smb2Codec.u32(0), // AdditionalInformation
      Smb2Codec.u32(0), // Flags
      Smb2Codec.u64(fileId.persistent),
      Smb2Codec.u64(fileId.volatileId)
    );
    const header: Uint8Array = Smb2Codec.buildHeader(Smb2Command.QUERY_INFO, messageId, treeId, sessionId, 32, 0);
    return SmbCrypto.concat(header, body);
  }

  /** FileAllInformation：EndOfFile 在 offset 48，Directory 标志在 offset 61 */
  static parseQueryInfo(packet: Uint8Array): Smb2FileInfo {
    const outputOffset: number = Ntlm.readUint16(packet, HEADER_SIZE + 2);
    const base: number = outputOffset;
    const lastWrite: number = Smb2Codec.readU64(packet, base + 16);
    const endOfFile: number = Smb2Codec.readU64(packet, base + 48);
    const directory: boolean = packet[base + 61] !== 0;
    const info: Smb2FileInfo = {
      size: endOfFile,
      isDirectory: directory,
      modified: Ntlm.fileTimeToUnixMs(lastWrite)
    };
    return info;
  }
}
