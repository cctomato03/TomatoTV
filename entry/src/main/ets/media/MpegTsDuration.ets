/** 随机读接口，供 M2TS PCR 探测使用（只读头尾，不整文件扫描） */
export interface ByteReader {
  size(): number;
  read(position: number, length: number): Promise<ArrayBuffer>;
}

/**
 * M2TS / TS 时长探测（规范 §9.3）。
 *
 * BDAV 的 .m2ts 使用 192 字节包（4 字节时间戳 + 188 字节 TS），系统元数据常返回 0 时长。
 * 这里通过 PCR（Program Clock Reference）首尾差值计算时长：
 *   durationMs = (lastPcr - firstPcr) / 27000
 * 只读取头部与尾部若干 MB，5.78GB 级文件也不会全文件扫描。
 */
export class MpegTsDuration {
  private static readonly HEAD_BYTES: number = 8 * 1024 * 1024;
  private static readonly TAIL_WINDOWS: number[] = [
    8 * 1024 * 1024, 16 * 1024 * 1024, 32 * 1024 * 1024, 64 * 1024 * 1024
  ];
  private static readonly MIN_DURATION_MS: number = 1000;
  private static readonly MAX_DURATION_MS: number = 24 * 60 * 60 * 1000;

  /** 返回毫秒；0 表示无法判定 */
  static async probe(reader: ByteReader): Promise<number> {
    try {
      const size: number = reader.size();
      if (size <= 0) {
        return 0;
      }
      const headLength: number = Math.min(MpegTsDuration.HEAD_BYTES, size);
      const head: Uint8Array = new Uint8Array(await reader.read(0, headLength));
      const packetSize: number = MpegTsDuration.detectPacketSize(head);
      if (packetSize === 0) {
        return 0;
      }
      const firstPcr: number = MpegTsDuration.firstPcr(head, packetSize);
      if (firstPcr < 0) {
        return 0;
      }
      for (const window of MpegTsDuration.TAIL_WINDOWS) {
        if (window > size) {
          continue;
        }
        const start: number = size - window;
        const tail: Uint8Array = new Uint8Array(await reader.read(start, window));
        const lastPcr: number = MpegTsDuration.lastPcr(tail, packetSize);
        if (lastPcr < 0) {
          continue;
        }
        let delta: number = lastPcr - firstPcr;
        if (delta < 0) {
          delta = delta + 8589934592 * 300; // 2^33 * 300 回绕
        }
        const durationMs: number = Math.floor(delta / 27000);
        if (durationMs >= MpegTsDuration.MIN_DURATION_MS && durationMs <= MpegTsDuration.MAX_DURATION_MS) {
          return durationMs;
        }
      }
      return 0;
    } catch (err) {
      return 0;
    }
  }

  /** 188/192 字节包检测：按连续同步字节命中率评分 */
  static detectPacketSize(data: Uint8Array): number {
    const score188: number = MpegTsDuration.scoreSync(data, 188, 0);
    const score192: number = MpegTsDuration.scoreSync(data, 192, 4);
    if (score188 === 0 && score192 === 0) {
      return 0;
    }
    return score188 >= score192 ? 188 : 192;
  }

  private static scoreSync(data: Uint8Array, packetSize: number, syncOffset: number): number {
    let hits: number = 0;
    let checked: number = 0;
    const limit: number = Math.min(data.length, packetSize * 400);
    for (let pos = syncOffset; pos + packetSize < limit; pos += packetSize) {
      checked++;
      if (data[pos] === 0x47) {
        hits++;
      }
    }
    if (checked === 0) {
      return 0;
    }
    return hits * 100 / checked >= 90 ? hits : 0;
  }

  static firstPcr(data: Uint8Array, packetSize: number): number {
    const syncOffset: number = packetSize === 192 ? 4 : 0;
    for (let pos = syncOffset; pos + packetSize <= data.length; pos += packetSize) {
      if (data[pos] !== 0x47) {
        continue;
      }
      const pcr: number = MpegTsDuration.pcrAt(data, pos);
      if (pcr >= 0) {
        return pcr;
      }
    }
    return -1;
  }

  static lastPcr(data: Uint8Array, packetSize: number): number {
    const syncOffset: number = packetSize === 192 ? 4 : 0;
    let found: number = -1;
    for (let pos = syncOffset; pos + packetSize <= data.length; pos += packetSize) {
      if (data[pos] !== 0x47) {
        continue;
      }
      const pcr: number = MpegTsDuration.pcrAt(data, pos);
      if (pcr >= 0) {
        found = pcr;
      }
    }
    return found;
  }

  /** 解析单包中的 PCR（adaptation field, PCR flag 0x10） */
  private static pcrAt(data: Uint8Array, pos: number): number {
    const adaptationControl: number = (data[pos + 3] >> 4) & 0x03;
    if (adaptationControl !== 2 && adaptationControl !== 3) {
      return -1;
    }
    const length: number = data[pos + 4];
    if (length < 7) {
      return -1;
    }
    const flags: number = data[pos + 5];
    if ((flags & 0x10) === 0) {
      return -1;
    }
    const p: number = pos + 6;
    const base: number = data[p] * 33554432 + data[p + 1] * 131072 + data[p + 2] * 512 + data[p + 3] * 2 +
      (data[p + 4] >> 7);
    const ext: number = ((data[p + 4] & 0x01) * 256) + data[p + 5];
    return base * 300 + ext;
  }
}
