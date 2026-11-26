/** HTTP Range 头解析结果 */
export interface RangeSpec {
  start: number;
  end: number;
  partial: boolean;
  valid: boolean;
}

/**
 * HTTP `Range: bytes=...` 解析（纯逻辑，便于单元测试）。
 * 支持 `bytes=a-b`、`bytes=a-`、`bytes=-n`；无法解析时退回整文件。
 */
export class RangeHeader {
  static whole(size: number): RangeSpec {
    return { start: 0, end: size > 0 ? size - 1 : 0, partial: false, valid: size >= 0 };
  }

  static parse(header: string, size: number): RangeSpec {
    if (size <= 0) {
      return { start: -1, end: -1, partial: false, valid: false };
    }
    if (header.length === 0) {
      return RangeHeader.whole(size);
    }
    const match: RegExpExecArray | null = /bytes=(\d*)-(\d*)/.exec(header.toLowerCase());
    if (match === null) {
      return RangeHeader.whole(size);
    }
    const startText: string = match[1];
    const endText: string = match[2];
    if (startText.length === 0 && endText.length === 0) {
      return RangeHeader.whole(size);
    }
    let start: number = 0;
    let end: number = size - 1;
    if (startText.length === 0) {
      const suffix: number = Number(endText);
      if (!Number.isFinite(suffix) || suffix <= 0) {
        return { start: -1, end: -1, partial: false, valid: false };
      }
      start = suffix >= size ? 0 : size - suffix;
    } else {
      start = Number(startText);
      if (!Number.isFinite(start) || start < 0) {
        return { start: -1, end: -1, partial: false, valid: false };
      }
      if (start >= size) {
        return { start: -1, end: -1, partial: false, valid: false };
      }
      if (endText.length > 0) {
        const parsedEnd: number = Number(endText);
        if (Number.isFinite(parsedEnd)) {
          end = Math.min(parsedEnd, size - 1);
        }
      }
    }
    if (end < start) {
      return { start: -1, end: -1, partial: false, valid: false };
    }
    const partial: boolean = !(start === 0 && end === size - 1);
    return { start: start, end: end, partial: partial, valid: true };
  }
}
