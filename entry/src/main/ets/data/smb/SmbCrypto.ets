/**
 * SMB2 / NTLM 需要的哈希与 HMAC 实现（纯 ArkTS，无平台依赖，便于单元测试）。
 *
 * 为什么自己实现：系统 cryptoFramework 没有 MD4（NTLM 的 NT Hash），
 * 而 HMAC-MD5 在部分版本不可用；这里给出 RFC 1320/1321/6234 的标准实现，
 * 全部同步执行，方便在 SMB2 报文的签名/校验里直接使用。
 */
export class SmbCrypto {
  // ---------------- 工具 ----------------
  static concat(...parts: Uint8Array[]): Uint8Array {
    let total: number = 0;
    for (const part of parts) {
      total += part.length;
    }
    const out: Uint8Array = new Uint8Array(total);
    let cursor: number = 0;
    for (const part of parts) {
      out.set(part, cursor);
      cursor += part.length;
    }
    return out;
  }

  static utf16le(text: string): Uint8Array {
    const out: Uint8Array = new Uint8Array(text.length * 2);
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      out[i * 2] = code & 0xFF;
      out[i * 2 + 1] = (code >> 8) & 0xFF;
    }
    return out;
  }

  static fromUtf16le(bytes: Uint8Array, offset: number, length: number): string {
    let text: string = '';
    const end: number = Math.min(bytes.length, offset + length);
    for (let i = offset; i + 1 < end; i += 2) {
      text += String.fromCharCode(bytes[i] | (bytes[i + 1] << 8));
    }
    return text;
  }

  static toHex(bytes: Uint8Array): string {
    let out: string = '';
    for (let i = 0; i < bytes.length; i++) {
      const part: string = bytes[i].toString(16);
      out += part.length === 1 ? `0${part}` : part;
    }
    return out;
  }

  // ---------------- MD4（RFC 1320） ----------------
  static md4(input: Uint8Array): Uint8Array {
    const length: number = input.length;
    const bitLength: number = length * 8;
    const withPad: number = (((length + 8) >> 6) + 1) << 6;
    const buffer: Uint8Array = new Uint8Array(withPad);
    buffer.set(input, 0);
    buffer[length] = 0x80;
    const view: DataView = new DataView(buffer.buffer);
    view.setUint32(withPad - 8, bitLength >>> 0, true);
    view.setUint32(withPad - 4, Math.floor(bitLength / 4294967296), true);

    let a: number = 0x67452301;
    let b: number = 0xEFCDAB89;
    let c: number = 0x98BADCFE;
    let d: number = 0x10325476;

    const x: number[] = new Array<number>(16);
    for (let block = 0; block < withPad; block += 64) {
      for (let i = 0; i < 16; i++) {
        x[i] = view.getUint32(block + i * 4, true);
      }
      const aa: number = a;
      const bb: number = b;
      const cc: number = c;
      const dd: number = d;

      // Round 1
      for (let i = 0; i < 16; i++) {
        const s: number = [3, 7, 11, 19][i % 4];
        const k: number = i;
        const f: number = (b & c) | (~b & d);
        const sum: number = (a + f + x[k]) | 0;
        a = d;
        d = c;
        c = b;
        b = SmbCrypto.rotl(sum, s);
      }
      // Round 2
      const order2: number[] = [0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15];
      for (let i = 0; i < 16; i++) {
        const s: number = [3, 5, 9, 13][i % 4];
        const k: number = order2[i];
        const g: number = (b & c) | (b & d) | (c & d);
        const sum: number = (a + g + x[k] + 0x5A827999) | 0;
        a = d;
        d = c;
        c = b;
        b = SmbCrypto.rotl(sum, s);
      }
      // Round 3
      const order3: number[] = [0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15];
      for (let i = 0; i < 16; i++) {
        const s: number = [3, 9, 11, 15][i % 4];
        const k: number = order3[i];
        const h: number = b ^ c ^ d;
        const sum: number = (a + h + x[k] + 0x6ED9EBA1) | 0;
        a = d;
        d = c;
        c = b;
        b = SmbCrypto.rotl(sum, s);
      }

      a = (a + aa) | 0;
      b = (b + bb) | 0;
      c = (c + cc) | 0;
      d = (d + dd) | 0;
    }

    return SmbCrypto.wordsToBytes([a, b, c, d]);
  }

  private static rotl(value: number, shift: number): number {
    return ((value << shift) | (value >>> (32 - shift))) | 0;
  }

  private static wordsToBytes(words: number[]): Uint8Array {
    const out: Uint8Array = new Uint8Array(words.length * 4);
    for (let i = 0; i < words.length; i++) {
      out[i * 4] = words[i] & 0xFF;
      out[i * 4 + 1] = (words[i] >>> 8) & 0xFF;
      out[i * 4 + 2] = (words[i] >>> 16) & 0xFF;
      out[i * 4 + 3] = (words[i] >>> 24) & 0xFF;
    }
    return out;
  }

  // ---------------- MD5（RFC 1321） ----------------
  private static readonly MD5_S: number[] = [
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21
  ];

  private static readonly MD5_K: number[] = [
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
    0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
    0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
    0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
    0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
    0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391
  ];

  static md5(input: Uint8Array): Uint8Array {
    const length: number = input.length;
    const bitLength: number = length * 8;
    const withPad: number = (((length + 8) >> 6) + 1) << 6;
    const buffer: Uint8Array = new Uint8Array(withPad);
    buffer.set(input, 0);
    buffer[length] = 0x80;
    const view: DataView = new DataView(buffer.buffer);
    view.setUint32(withPad - 8, bitLength >>> 0, true);
    view.setUint32(withPad - 4, Math.floor(bitLength / 4294967296), true);

    let a0: number = 0x67452301;
    let b0: number = 0xefcdab89;
    let c0: number = 0x98badcfe;
    let d0: number = 0x10325476;
    const m: number[] = new Array<number>(16);

    for (let block = 0; block < withPad; block += 64) {
      for (let i = 0; i < 16; i++) {
        m[i] = view.getUint32(block + i * 4, true);
      }
      let a: number = a0;
      let b: number = b0;
      let c: number = c0;
      let d: number = d0;
      for (let i = 0; i < 64; i++) {
        let f: number;
        let g: number;
        if (i < 16) {
          f = (b & c) | (~b & d);
          g = i;
        } else if (i < 32) {
          f = (d & b) | (~d & c);
          g = (5 * i + 1) % 16;
        } else if (i < 48) {
          f = b ^ c ^ d;
          g = (3 * i + 5) % 16;
        } else {
          f = c ^ (b | ~d);
          g = (7 * i) % 16;
        }
        const temp: number = d;
        d = c;
        c = b;
        const sum: number = (a + f + SmbCrypto.MD5_K[i] + m[g]) | 0;
        b = (b + SmbCrypto.rotl(sum, SmbCrypto.MD5_S[i])) | 0;
        a = temp;
      }
      a0 = (a0 + a) | 0;
      b0 = (b0 + b) | 0;
      c0 = (c0 + c) | 0;
      d0 = (d0 + d) | 0;
    }
    return SmbCrypto.wordsToBytes([a0, b0, c0, d0]);
  }

  // ---------------- SHA-256（RFC 6234） ----------------
  private static readonly SHA256_K: number[] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
  ];

  static sha256(input: Uint8Array): Uint8Array {
    const length: number = input.length;
    const bitLength: number = length * 8;
    const withPad: number = (((length + 8) >> 6) + 1) << 6;
    const buffer: Uint8Array = new Uint8Array(withPad);
    buffer.set(input, 0);
    buffer[length] = 0x80;
    const view: DataView = new DataView(buffer.buffer);
    view.setUint32(withPad - 8, Math.floor(bitLength / 4294967296), false);
    view.setUint32(withPad - 4, bitLength >>> 0, false);

    const h: number[] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c,
      0x1f83d9ab, 0x5be0cd19];
    const w: number[] = new Array<number>(64);

    for (let block = 0; block < withPad; block += 64) {
      for (let i = 0; i < 16; i++) {
        w[i] = view.getUint32(block + i * 4, false);
      }
      for (let i = 16; i < 64; i++) {
        const s0: number = SmbCrypto.rotr(w[i - 15], 7) ^ SmbCrypto.rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
        const s1: number = SmbCrypto.rotr(w[i - 2], 17) ^ SmbCrypto.rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0;
      }
      let a: number = h[0];
      let b: number = h[1];
      let c: number = h[2];
      let d: number = h[3];
      let e: number = h[4];
      let f: number = h[5];
      let g: number = h[6];
      let hh: number = h[7];
      for (let i = 0; i < 64; i++) {
        const s1: number = SmbCrypto.rotr(e, 6) ^ SmbCrypto.rotr(e, 11) ^ SmbCrypto.rotr(e, 25);
        const ch: number = (e & f) ^ (~e & g);
        const temp1: number = (hh + s1 + ch + SmbCrypto.SHA256_K[i] + w[i]) | 0;
        const s0: number = SmbCrypto.rotr(a, 2) ^ SmbCrypto.rotr(a, 13) ^ SmbCrypto.rotr(a, 22);
        const maj: number = (a & b) ^ (a & c) ^ (b & c);
        const temp2: number = (s0 + maj) | 0;
        hh = g;
        g = f;
        f = e;
        e = (d + temp1) | 0;
        d = c;
        c = b;
        b = a;
        a = (temp1 + temp2) | 0;
      }
      h[0] = (h[0] + a) | 0;
      h[1] = (h[1] + b) | 0;
      h[2] = (h[2] + c) | 0;
      h[3] = (h[3] + d) | 0;
      h[4] = (h[4] + e) | 0;
      h[5] = (h[5] + f) | 0;
      h[6] = (h[6] + g) | 0;
      h[7] = (h[7] + hh) | 0;
    }
    const out: Uint8Array = new Uint8Array(32);
    const outView: DataView = new DataView(out.buffer);
    for (let i = 0; i < 8; i++) {
      outView.setUint32(i * 4, h[i], false);
    }
    return out;
  }

  private static rotr(value: number, shift: number): number {
    return ((value >>> shift) | (value << (32 - shift))) | 0;
  }

  // ---------------- HMAC ----------------
  static hmacMd5(key: Uint8Array, message: Uint8Array): Uint8Array {
    return SmbCrypto.hmac(key, message, 64, true);
  }

  static hmacSha256(key: Uint8Array, message: Uint8Array): Uint8Array {
    return SmbCrypto.hmac(key, message, 64, false);
  }

  private static hmac(key: Uint8Array, message: Uint8Array, blockSize: number, useMd5: boolean): Uint8Array {
    let normalKey: Uint8Array = key;
    if (key.length > blockSize) {
      normalKey = useMd5 ? SmbCrypto.md5(key) : SmbCrypto.sha256(key);
    }
    const padded: Uint8Array = new Uint8Array(blockSize);
    padded.set(normalKey, 0);
    const inner: Uint8Array = new Uint8Array(blockSize);
    const outer: Uint8Array = new Uint8Array(blockSize);
    for (let i = 0; i < blockSize; i++) {
      inner[i] = padded[i] ^ 0x36;
      outer[i] = padded[i] ^ 0x5C;
    }
    const innerHash: Uint8Array = useMd5
      ? SmbCrypto.md5(SmbCrypto.concat(inner, message))
      : SmbCrypto.sha256(SmbCrypto.concat(inner, message));
    return useMd5
      ? SmbCrypto.md5(SmbCrypto.concat(outer, innerHash))
      : SmbCrypto.sha256(SmbCrypto.concat(outer, innerHash));
  }

  /** NTLM 用的 NT 单向函数：MD4(UNICODE(password)) */
  static ntHash(password: string): Uint8Array {
    return SmbCrypto.md4(SmbCrypto.utf16le(password));
  }
}
