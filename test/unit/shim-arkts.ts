/**
 * 单元测试用的 @kit.ArkTS shim：
 * 只提供被测模块用到的 util.TextEncoder / util.TextDecoder 子集，
 * 底层复用 Node 自带的 TextEncoder / TextDecoder。
 */
class ShimTextEncoder {
  private inner: TextEncoder = new TextEncoder();

  encodeInto(input?: string): Uint8Array {
    return this.inner.encode(input === undefined ? '' : input);
  }

  encodeIntoUint8Array(input: string, dest: Uint8Array): number {
    const encoded: Uint8Array = this.inner.encode(input);
    const length: number = Math.min(encoded.length, dest.length);
    dest.set(encoded.subarray(0, length), 0);
    return length;
  }
}

class ShimTextDecoder {
  private inner: TextDecoder;

  constructor(encoding: string) {
    this.inner = new TextDecoder(encoding);
  }

  decodeWithStream(input: Uint8Array): string {
    return this.inner.decode(input);
  }
}

const ShimTextDecoderFactory = {
  create(encoding: string): ShimTextDecoder {
    return new ShimTextDecoder(encoding);
  }
};

export const util = {
  TextEncoder: ShimTextEncoder,
  TextDecoder: ShimTextDecoderFactory
};
