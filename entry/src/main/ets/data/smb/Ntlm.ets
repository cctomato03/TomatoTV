import { FsError, FsErrorKind } from '../fs/FileSystemClient';
import { SmbCrypto } from './SmbCrypto';

/**
 * NTLM 协商标志：UNICODE | REQUEST_TARGET | NTLM | ALWAYS_SIGN |
 * EXTENDED_SESSIONSECURITY | TARGET_INFO | 128 | 56。
 * 不声明 SIGN/SEAL/KEY_EXCH——我们不实现密钥交换，声明了会让服务端期待
 * EncryptedRandomSessionKey，进而导致会话密钥与签名校验对不上。
 */
const NEGOTIATE_FLAGS: number = 0xA0888205;

export interface MavPair {
  id: number;
  value: Uint8Array;
}

export interface NtlmChallenge {
  serverChallenge: Uint8Array;
  targetInfo: Uint8Array;
  flags: number;
}

export interface NtlmCredentials {
  user: string;
  domain: string;
  password: string;
}

export interface NtlmV2Params {
  user: string;
  domain: string;
  password: string;
  serverChallenge: Uint8Array;
  clientChallenge: Uint8Array;
  /** FILETIME（100ns since 1601），用 Ntlm.unixMsToFileTime() 转换 */
  fileTime: number;
  targetInfo: Uint8Array;
}

export interface NtlmV2Result {
  ntProofStr: Uint8Array;
  ntResponse: Uint8Array;
  sessionBaseKey: Uint8Array;
}

export interface NtlmMicParams {
  negotiateBlob: Uint8Array;
  challengeBlob: Uint8Array;
}

/**
 * NTLM 报文构造/解析（MS-NLMP）。
 * 只实现 NTLMv2 + SPNEGO 包装，够 SMB2 使用；不含 LM/NTLMv1 与密钥交换。
 */
export class Ntlm {
  static readonly AV_ID_EOL: number = 0x0000;
  static readonly AV_ID_NB_COMPUTER: number = 0x0001;
  static readonly AV_ID_NB_DOMAIN: number = 0x0002;
  static readonly AV_ID_DNS_COMPUTER: number = 0x0003;
  static readonly AV_ID_DNS_DOMAIN: number = 0x0004;
  static readonly AV_ID_TIMESTAMP: number = 0x0007;

  static ascii(text: string): Uint8Array {
    const out: Uint8Array = new Uint8Array(text.length);
    for (let i = 0; i < text.length; i++) {
      out[i] = text.charCodeAt(i) & 0xFF;
    }
    return out;
  }

  static readUint16(bytes: Uint8Array, offset: number): number {
    return (bytes[offset] | (bytes[offset + 1] << 8)) & 0xFFFF;
  }

  static readUint32(bytes: Uint8Array, offset: number): number {
    return (bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24)) >>> 0;
  }

  static writeUint16(target: Uint8Array, offset: number, value: number): void {
    target[offset] = value & 0xFF;
    target[offset + 1] = (value >>> 8) & 0xFF;
  }

  static writeUint32(target: Uint8Array, offset: number, value: number): void {
    target[offset] = value & 0xFF;
    target[offset + 1] = (value >>> 8) & 0xFF;
    target[offset + 2] = (value >>> 16) & 0xFF;
    target[offset + 3] = (value >>> 24) & 0xFF;
  }

  /** FILETIME（100ns since 1601）与 Unix 毫秒互转 */
  static unixMsToFileTime(unixMs: number): number {
    return Math.round(unixMs * 10000) + 116444736000000000;
  }

  static nowFileTime(): number {
    return Ntlm.unixMsToFileTime(Date.now());
  }

  static fileTimeToUnixMs(fileTime: number): number {
    if (fileTime <= 0) {
      return 0;
    }
    return Math.floor((fileTime - 116444736000000000) / 10000);
  }

  /** 构造 AV_PAIR 列表，并自动追加 EOL */
  static mavPairs(pairs: MavPair[]): Uint8Array {
    const chunks: Uint8Array[] = [];
    for (const pair of pairs) {
      const header: Uint8Array = new Uint8Array(4);
      Ntlm.writeUint16(header, 0, pair.id);
      Ntlm.writeUint16(header, 2, pair.value.length);
      chunks.push(header, pair.value);
    }
    const eol: Uint8Array = new Uint8Array(4);
    chunks.push(eol);
    return SmbCrypto.concat(...chunks);
  }

  static parseMavPairs(info: Uint8Array): MavPair[] {
    const pairs: MavPair[] = [];
    let cursor: number = 0;
    while (cursor + 4 <= info.length) {
      const id: number = Ntlm.readUint16(info, cursor);
      const length: number = Ntlm.readUint16(info, cursor + 2);
      cursor += 4;
      if (id === Ntlm.AV_ID_EOL || cursor + length > info.length) {
        break;
      }
      pairs.push({ id: id, value: info.slice(cursor, cursor + length) });
      cursor += length;
    }
    return pairs;
  }

  /** NTLM Type 1（NEGOTIATE） */
  static buildType1(): Uint8Array {
    const message: Uint8Array = new Uint8Array(32);
    message.set(Ntlm.ascii('NTLMSSP\0'), 0);
    Ntlm.writeUint32(message, 8, 1);
    Ntlm.writeUint32(message, 12, NEGOTIATE_FLAGS);
    return message;
  }

  /** 解析 NTLM Type 2（CHALLENGE） */
  static asciiText(bytes: Uint8Array, offset: number, length: number): string {
    let text: string = '';
    for (let i = offset; i < offset + length && i < bytes.length; i++) {
      text += String.fromCharCode(bytes[i]);
    }
    return text;
  }

  static parseType2(message: Uint8Array): NtlmChallenge {
    if (message.length < 48 || Ntlm.asciiText(message, 0, 8) !== 'NTLMSSP\0' ||
      Ntlm.readUint32(message, 8) !== 2) {
      throw new FsError(FsErrorKind.AUTH, '服务器返回的 NTLM CHALLENGE 无法解析');
    }
    const flags: number = Ntlm.readUint32(message, 20);
    const challenge: Uint8Array = message.slice(24, 32);
    const infoLength: number = Ntlm.readUint16(message, 40);
    const infoOffset: number = Ntlm.readUint32(message, 44);
    let targetInfo: Uint8Array = new Uint8Array(0);
    if (infoLength > 0 && infoOffset + infoLength <= message.length) {
      targetInfo = message.slice(infoOffset, infoOffset + infoLength);
    }
    return { serverChallenge: challenge, targetInfo: targetInfo, flags: flags };
  }

  /** 计算 NTLMv2 响应（NTProofStr / NTResponse / SessionBaseKey） */
  static computeV2(params: NtlmV2Params): NtlmV2Result {
    const userDom: string = `${params.user.toUpperCase()}${params.domain}`;
    const responseKeyNt: Uint8Array = SmbCrypto.hmacMd5(SmbCrypto.ntHash(params.password),
      SmbCrypto.utf16le(userDom));

    const blobChunks: Uint8Array[] = [];
    blobChunks.push(new Uint8Array([0x01, 0x01, 0x00, 0x00])); // RespVersion + HiRespType
    blobChunks.push(new Uint8Array(4)); // Reserved
    const timestamp: Uint8Array = new Uint8Array(8);
    const fileTime: number = params.fileTime;
    timestamp[0] = fileTime % 256;
    timestamp[1] = Math.floor(fileTime / 256) % 256;
    timestamp[2] = Math.floor(fileTime / 65536) % 256;
    timestamp[3] = Math.floor(fileTime / 16777216) % 256;
    timestamp[4] = Math.floor(fileTime / 4294967296) % 256;
    timestamp[5] = Math.floor(fileTime / 1099511627776) % 256;
    timestamp[6] = Math.floor(fileTime / 281474976710656) % 256;
    timestamp[7] = Math.floor(fileTime / 72057594037927936) % 256;
    blobChunks.push(timestamp);
    blobChunks.push(params.clientChallenge);
    blobChunks.push(new Uint8Array(4));
    blobChunks.push(params.targetInfo);
    blobChunks.push(new Uint8Array(4));
    const blob: Uint8Array = SmbCrypto.concat(...blobChunks);

    const ntProofStr: Uint8Array = SmbCrypto.hmacMd5(responseKeyNt,
      SmbCrypto.concat(params.serverChallenge, blob));
    const ntResponse: Uint8Array = SmbCrypto.concat(ntProofStr, blob);
    const sessionBaseKey: Uint8Array = SmbCrypto.hmacMd5(responseKeyNt, ntProofStr);
    return { ntProofStr: ntProofStr, ntResponse: ntResponse, sessionBaseKey: sessionBaseKey };
  }

  /** 构造 NTLM Type 3（AUTHENTICATE） */
  static buildType3(credentials: NtlmCredentials, serverChallenge: Uint8Array, clientChallenge: Uint8Array,
    fileTime: number, targetInfo: Uint8Array, mic?: NtlmMicParams): Uint8Array {
    const computed: NtlmV2Result = Ntlm.computeV2({
      user: credentials.user,
      domain: credentials.domain,
      password: credentials.password,
      serverChallenge: serverChallenge,
      clientChallenge: clientChallenge,
      fileTime: fileTime,
      targetInfo: targetInfo
    });

    const domainBytes: Uint8Array = SmbCrypto.utf16le(credentials.domain);
    const userBytes: Uint8Array = SmbCrypto.utf16le(credentials.user);
    const workstationBytes: Uint8Array = SmbCrypto.utf16le('');

    const fixedSize: number = 88; // 64 基础 + 8 Version + 16 MIC
    let cursor: number = fixedSize;
    const domainOffset: number = cursor;
    cursor += domainBytes.length;
    const userOffset: number = cursor;
    cursor += userBytes.length;
    const workstationOffset: number = cursor;
    cursor += workstationBytes.length;
    const ntOffset: number = cursor;
    cursor += computed.ntResponse.length;

    const message: Uint8Array = new Uint8Array(cursor);
    message.set(Ntlm.ascii('NTLMSSP\0'), 0);
    Ntlm.writeUint32(message, 8, 3);
    // LmChallengeResponse：留空
    Ntlm.writeUint16(message, 12, 0);
    Ntlm.writeUint16(message, 14, 0);
    Ntlm.writeUint32(message, 16, fixedSize);
    // NtChallengeResponse
    Ntlm.writeUint16(message, 20, computed.ntResponse.length);
    Ntlm.writeUint16(message, 22, computed.ntResponse.length);
    Ntlm.writeUint32(message, 24, ntOffset);
    // DomainName
    Ntlm.writeUint16(message, 28, domainBytes.length);
    Ntlm.writeUint16(message, 30, domainBytes.length);
    Ntlm.writeUint32(message, 32, domainOffset);
    // UserName
    Ntlm.writeUint16(message, 36, userBytes.length);
    Ntlm.writeUint16(message, 38, userBytes.length);
    Ntlm.writeUint32(message, 40, userOffset);
    // Workstation
    Ntlm.writeUint16(message, 44, workstationBytes.length);
    Ntlm.writeUint16(message, 46, workstationBytes.length);
    Ntlm.writeUint32(message, 48, workstationOffset);
    // EncryptedRandomSessionKey：无
    Ntlm.writeUint16(message, 52, 0);
    Ntlm.writeUint16(message, 54, 0);
    Ntlm.writeUint32(message, 56, fixedSize);
    Ntlm.writeUint32(message, 60, NEGOTIATE_FLAGS);
    // Version: 10.0.19041
    const version: Uint8Array = new Uint8Array([0x0A, 0x00, 0xB1, 0x1D, 0x00, 0x00, 0x00, 0x0F]);
    message.set(version, 64);

    message.set(domainBytes, domainOffset);
    message.set(userBytes, userOffset);
    message.set(workstationBytes, workstationOffset);
    message.set(computed.ntResponse, ntOffset);

    if (mic !== undefined) {
      const micValue: Uint8Array = SmbCrypto.hmacMd5(computed.sessionBaseKey,
        SmbCrypto.concat(mic.negotiateBlob, mic.challengeBlob, message));
      message.set(micValue, 72);
    }
    return message;
  }

  /** 从 SPNEGO / 原始报文里找出 NTLMSSP 消息（按魔数扫描，避免完整 DER 解析） */
  static extractNtlmMessage(blob: Uint8Array): Uint8Array {
    const magic: Uint8Array = Ntlm.ascii('NTLMSSP\0');
    const limit: number = blob.length - magic.length;
    for (let i = 0; i <= limit; i++) {
      let matched: boolean = true;
      for (let j = 0; j < magic.length; j++) {
        if (blob[i + j] !== magic[j]) {
          matched = false;
          break;
        }
      }
      if (matched) {
        return blob.slice(i);
      }
    }
    throw new FsError(FsErrorKind.AUTH, '服务器返回的认证报文不含 NTLMSSP 数据');
  }

  private static derLength(length: number): Uint8Array {
    if (length < 0x80) {
      return new Uint8Array([length]);
    }
    if (length < 0x100) {
      return new Uint8Array([0x81, length]);
    }
    return new Uint8Array([0x82, (length >> 8) & 0xFF, length & 0xFF]);
  }

  private static derWrap(tag: number, content: Uint8Array): Uint8Array {
    return SmbCrypto.concat(new Uint8Array([tag]), Ntlm.derLength(content.length), content);
  }

  /**
   * SPNEGO NegTokenInit（携带 NTLM Type1）。
   * ASN.1：NegotiationToken ::= [APPLICATION 0] { OID(spnego) NegTokenInit }
   *        NegTokenInit ::= SEQUENCE { mechTypes [0] SEQUENCE OF OID, mechToken [2] OCTET STRING }
   */
  static wrapSpnegoInit(token: Uint8Array): Uint8Array {
    const spnegoOid: Uint8Array = Ntlm.derWrap(0x06, new Uint8Array([0x2B, 0x06, 0x01, 0x05, 0x05, 0x02]));
    const ntlmOid: Uint8Array = Ntlm.derWrap(0x06, new Uint8Array([0x2B, 0x06, 0x01, 0x04, 0x01, 0x82,
      0x37, 0x02, 0x02, 0x0A]));
    const mechTypes: Uint8Array = Ntlm.derWrap(0xA0, Ntlm.derWrap(0x30, ntlmOid));
    const mechToken: Uint8Array = Ntlm.derWrap(0xA2, Ntlm.derWrap(0x04, token));
    const negTokenInit: Uint8Array = Ntlm.derWrap(0x30, SmbCrypto.concat(mechTypes, mechToken));
    const tagged: Uint8Array = Ntlm.derWrap(0xA0, negTokenInit);
    return Ntlm.derWrap(0x60, SmbCrypto.concat(spnegoOid, tagged));
  }

  /** SPNEGO NegTokenResp（携带 NTLM Type3） */
  static wrapSpnegoResp(token: Uint8Array): Uint8Array {
    const octet: Uint8Array = Ntlm.derWrap(0x04, token);
    const responseToken: Uint8Array = Ntlm.derWrap(0xA2, octet);
    const sequence: Uint8Array = Ntlm.derWrap(0x30, responseToken);
    return Ntlm.derWrap(0xA1, sequence);
  }

  /** 解析服务端 Type2 是否带 NTLM 的 mechListMIC（多数服务端需要 MIC） */
  static requiresMic(targetInfo: Uint8Array): boolean {
    const pairs: MavPair[] = Ntlm.parseMavPairs(targetInfo);
    for (const pair of pairs) {
      if (pair.id === Ntlm.AV_ID_TIMESTAMP) {
        return true;
      }
    }
    return false;
  }
}
