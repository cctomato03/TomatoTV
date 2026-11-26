import { FileSystemClient } from '../data/fs/FileSystemClient';
import { ByteReader } from './MpegTsDuration';

/** 把统一文件系统客户端适配成 M2TS PCR 探测需要的随机读接口 */
export class ClientByteReader implements ByteReader {
  private client: FileSystemClient;
  private path: string;
  private total: number;

  constructor(client: FileSystemClient, path: string, total: number) {
    this.client = client;
    this.path = path;
    this.total = total;
  }

  size(): number {
    return this.total;
  }

  async read(position: number, length: number): Promise<ArrayBuffer> {
    return this.client.readRange(this.path, position, length);
  }
}
