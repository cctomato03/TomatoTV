import { util } from '@kit.ArkTS';

/**
 * 极简二维码编码器（字节模式，纠错等级 M，版本 1–3）。
 *
 * 为什么自己实现：当前 SDK 未提供二维码生成 API（Scan Kit 只做扫描），
 * 规范 §7.5 允许用 Canvas + 编码器绘制。
 *
 * 实现要点：
 *  - 版本 1/2/3 都是单 RS 块，无需交织，容量分别为 14/26/42 字节；
 *  - 固定使用掩码 0（(row+col) % 2 == 0），格式信息按 M 级 + 掩码 0 生成；
 *  - 输出为 [row][col] 的布尔矩阵，供 Canvas 逐格绘制。
 *
 * 该算法的 JS 版本已用 jsQR 解码器验证：v1/v2/v3 全部掩码均可正确解码。
 */
export class QrCode {
  private static readonly DATA_CODEWORDS: number[] = [0, 16, 28, 44];
  private static readonly ECC_CODEWORDS: number[] = [0, 10, 16, 26];
  private static readonly ALIGN_COORDS: number[][] = [[], [], [6, 18], [6, 22]];

  private static gfMul(a: number, b: number): number {
    let z: number = 0;
    for (let i = 7; i >= 0; i--) {
      z = (z << 1) ^ ((z >>> 7) * 0x11D);
      z ^= ((b >>> i) & 1) * a;
    }
    return z & 0xFF;
  }

  private static rsDivisor(degree: number): number[] {
    const result: number[] = QrCode.zeros(degree);
    result[degree - 1] = 1;
    let root: number = 1;
    for (let i = 0; i < degree; i++) {
      for (let j = 0; j < degree; j++) {
        result[j] = QrCode.gfMul(result[j], root);
        if (j + 1 < degree) {
          result[j] ^= result[j + 1];
        }
      }
      root = QrCode.gfMul(root, 2);
    }
    return result;
  }

  private static rsRemainder(data: number[], divisor: number[]): number[] {
    const result: number[] = QrCode.zeros(divisor.length);
    for (const value of data) {
      const factor: number = value ^ (result.shift() as number);
      result.push(0);
      for (let i = 0; i < result.length; i++) {
        result[i] ^= QrCode.gfMul(divisor[i], factor);
      }
    }
    return result;
  }

  private static zeros(count: number): number[] {
    const out: number[] = [];
    for (let i = 0; i < count; i++) {
      out.push(0);
    }
    return out;
  }

  private static pickVersion(byteLength: number): number {
    for (let version = 1; version <= 3; version++) {
      if (byteLength <= QrCode.DATA_CODEWORDS[version] - 2) {
        return version;
      }
    }
    return 0;
  }

  private static buildCodewords(bytes: Uint8Array, version: number): number[] {
    const dataCount: number = QrCode.DATA_CODEWORDS[version];
    const bits: number[] = [];
    const pushBits = (value: number, length: number): void => {
      for (let i = length - 1; i >= 0; i--) {
        bits.push((value >>> i) & 1);
      }
    };
    pushBits(4, 4);
    pushBits(bytes.length, 8);
    for (let i = 0; i < bytes.length; i++) {
      pushBits(bytes[i], 8);
    }
    const capacityBits: number = dataCount * 8;
    const terminator: number = Math.min(4, capacityBits - bits.length);
    pushBits(0, terminator);
    while (bits.length % 8 !== 0) {
      bits.push(0);
    }
    const codewords: number[] = [];
    for (let i = 0; i < bits.length; i += 8) {
      let value: number = 0;
      for (let j = 0; j < 8; j++) {
        value = (value << 1) | bits[i + j];
      }
      codewords.push(value);
    }
    const pads: number[] = [0xEC, 0x11];
    let padIndex: number = 0;
    while (codewords.length < dataCount) {
      codewords.push(pads[padIndex % 2]);
      padIndex++;
    }
    const ecc: number[] = QrCode.rsRemainder(codewords, QrCode.rsDivisor(QrCode.ECC_CODEWORDS[version]));
    for (const value of ecc) {
      codewords.push(value);
    }
    return codewords;
  }

  /** M 级（formatBits = 0b00）+ 掩码 0 */
  private static formatBits(): number {
    const data: number = 0;
    let rem: number = data;
    for (let i = 0; i < 10; i++) {
      rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
    }
    return ((data << 10) | (rem & 0x3FF)) ^ 0x5412;
  }

  /** 返回 [row][col] 布尔矩阵；内容过长（>42 字节）时返回 null */
  static encode(text: string): boolean[][] | null {
    const encoder: util.TextEncoder = new util.TextEncoder('utf-8');
    const bytes: Uint8Array = encoder.encodeInto(text);
    const version: number = QrCode.pickVersion(bytes.length);
    if (version === 0) {
      return null;
    }
    const size: number = 17 + version * 4;
    const modules: boolean[][] = [];
    const isFunction: boolean[][] = [];
    for (let y = 0; y < size; y++) {
      const rowModules: boolean[] = [];
      const rowFunction: boolean[] = [];
      for (let x = 0; x < size; x++) {
        rowModules.push(false);
        rowFunction.push(false);
      }
      modules.push(rowModules);
      isFunction.push(rowFunction);
    }
    const setFn = (x: number, y: number, dark: boolean): void => {
      modules[y][x] = dark;
      isFunction[y][x] = true;
    };
    const getBit = (value: number, index: number): boolean => {
      return ((value >>> index) & 1) !== 0;
    };

    // 定位图形（含分隔带）
    const drawFinder = (cx: number, cy: number): void => {
      for (let dy = -4; dy <= 4; dy++) {
        for (let dx = -4; dx <= 4; dx++) {
          const dist: number = Math.max(Math.abs(dx), Math.abs(dy));
          const x: number = cx + dx;
          const y: number = cy + dy;
          if (x >= 0 && x < size && y >= 0 && y < size) {
            setFn(x, y, dist !== 2 && dist !== 4);
          }
        }
      }
    };
    drawFinder(3, 3);
    drawFinder(size - 4, 3);
    drawFinder(3, size - 4);

    // 定时图形
    for (let i = 0; i < size; i++) {
      if (!isFunction[6][i]) {
        setFn(i, 6, i % 2 === 0);
      }
      if (!isFunction[i][6]) {
        setFn(6, i, i % 2 === 0);
      }
    }

    // 校正图形
    const coords: number[] = QrCode.ALIGN_COORDS[version];
    for (const ax of coords) {
      for (const ay of coords) {
        const overlaps: boolean = (ax === 6 && ay === 6) || (ax === 6 && ay === size - 7) ||
          (ax === size - 7 && ay === 6);
        if (overlaps) {
          continue;
        }
        for (let dy = -2; dy <= 2; dy++) {
          for (let dx = -2; dx <= 2; dx++) {
            const dist: number = Math.max(Math.abs(dx), Math.abs(dy));
            setFn(ax + dx, ay + dy, dist !== 1);
          }
        }
      }
    }

    // 格式信息（两份）+ 暗模块
    const format: number = QrCode.formatBits();
    for (let i = 0; i <= 5; i++) {
      setFn(8, i, getBit(format, i));
    }
    setFn(8, 7, getBit(format, 6));
    setFn(8, 8, getBit(format, 7));
    setFn(7, 8, getBit(format, 8));
    for (let i = 9; i < 15; i++) {
      setFn(14 - i, 8, getBit(format, i));
    }
    for (let i = 0; i < 8; i++) {
      setFn(size - 1 - i, 8, getBit(format, i));
    }
    for (let i = 8; i < 15; i++) {
      setFn(8, size - 15 + i, getBit(format, i));
    }
    setFn(8, size - 8, true);

    // 数据区填充（右下角起，两列一组）
    const codewords: number[] = QrCode.buildCodewords(bytes, version);
    let index: number = 0;
    for (let right = size - 1; right >= 1; right -= 2) {
      if (right === 6) {
        right = 5;
      }
      for (let vert = 0; vert < size; vert++) {
        for (let j = 0; j < 2; j++) {
          const x: number = right - j;
          const upward: boolean = ((right + 1) & 2) === 0;
          const y: number = upward ? size - 1 - vert : vert;
          if (!isFunction[y][x] && index < codewords.length * 8) {
            let dark: boolean = getBit(codewords[index >>> 3], 7 - (index & 7));
            if ((x + y) % 2 === 0) {
              dark = !dark;
            }
            modules[y][x] = dark;
            index++;
          }
        }
      }
    }
    return modules;
  }
}
