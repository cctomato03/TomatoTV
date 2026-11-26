import { FileEntry } from '../../model/FileEntry';
import { FsError, FsErrorKind, FileSystemClient, InputStreamLike } from './FileSystemClient';

const MESSAGE: string = '当前版本暂不支持 SMB 来源：需要 libsmb2 的 NAPI 封装，计划在后续版本提供';

/**
 * SMB 占位实现（规范 §8.4）。
 * 官方 SDK 无 SMB 能力；自研 NAPI 需要交叉编译 libsmb2 及 OpenSSL，
 * 首版不静默失败，所有操作抛出明确的“暂不支持”错误，UI 会原样展示该提示。
 */
export class SmbFileSystem implements FileSystemClient {
  async list(path: string): Promise<FileEntry[]> {
    throw new FsError(FsErrorKind.UNSUPPORTED, MESSAGE);
  }

  async stat(path: string): Promise<FileEntry> {
    throw new FsError(FsErrorKind.UNSUPPORTED, MESSAGE);
  }

  async openStream(path: string, position?: number): Promise<InputStreamLike> {
    throw new FsError(FsErrorKind.UNSUPPORTED, MESSAGE);
  }

  async readRange(path: string, position: number, length: number): Promise<ArrayBuffer> {
    throw new FsError(FsErrorKind.UNSUPPORTED, MESSAGE);
  }

  async testConnection(): Promise<void> {
    throw new FsError(FsErrorKind.UNSUPPORTED, MESSAGE);
  }

  async close(): Promise<void> {
  }

  static readonly NOT_SUPPORTED_MESSAGE: string = MESSAGE;
}
