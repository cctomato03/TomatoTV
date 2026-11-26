import { FileEntry } from '../../model/FileEntry';

/** 流式读取句柄 */
export interface InputStreamLike {
  read(buffer: ArrayBuffer): Promise<number>;
  close(): Promise<void>;
}

/** 可播放媒体句柄：fd >= 0 时用 fdSrc，否则用 path/url */
export interface PlayableMedia {
  fd: number;
  path: string;
  url: string;
  mimeType: string;
}

/** 统一文件系统接口（规范 §8.1） */
export interface FileSystemClient {
  list(path: string): Promise<FileEntry[]>;
  stat(path: string): Promise<FileEntry>;
  openStream(path: string, position?: number): Promise<InputStreamLike>;
  readRange(path: string, position: number, length: number): Promise<ArrayBuffer>;
  testConnection(): Promise<void>;
  close(): Promise<void>;
}

export enum FsErrorKind {
  NOT_FOUND = 'NOT_FOUND',
  PERMISSION = 'PERMISSION',
  AUTH = 'AUTH',
  TIMEOUT = 'TIMEOUT',
  NETWORK = 'NETWORK',
  SERVER = 'SERVER',
  UNSUPPORTED = 'UNSUPPORTED',
  CACHE = 'CACHE',
  UNKNOWN = 'UNKNOWN'
}

export class FsError extends Error {
  kind: FsErrorKind;

  constructor(kind: FsErrorKind, detail: string) {
    super(detail);
    this.kind = kind;
  }
}

/** 统一中文文案（规范 §13），UI 直接使用 */
export class FsErrorText {
  static readonly NOT_FOUND: string = '目录不存在或已被移动';
  static readonly PERMISSION: string = '没有访问该目录的权限，请重新选择目录';
  static readonly NETWORK: string = '连接失败，请检查地址和网络';
  static readonly AUTH: string = '用户名或密码不正确';
  static readonly TIMEOUT: string = '连接超时';
  static readonly DECODE: string = '这个媒体无法解码或格式不受支持';
  static readonly CACHE: string = '缓存读写失败';
  static readonly EMPTY: string = '这个目录是空的';
  static readonly NO_MATCH: string = '没有找到匹配的文件';
  static readonly UNSUPPORTED: string = '当前版本暂不支持该来源类型';
  static readonly SERVER: string = '服务端返回异常，请稍后重试';

  static of(kind: FsErrorKind): string {
    switch (kind) {
      case FsErrorKind.NOT_FOUND:
        return FsErrorText.NOT_FOUND;
      case FsErrorKind.PERMISSION:
        return FsErrorText.PERMISSION;
      case FsErrorKind.AUTH:
        return FsErrorText.AUTH;
      case FsErrorKind.TIMEOUT:
        return FsErrorText.TIMEOUT;
      case FsErrorKind.NETWORK:
        return FsErrorText.NETWORK;
      case FsErrorKind.UNSUPPORTED:
        return FsErrorText.UNSUPPORTED;
      case FsErrorKind.CACHE:
        return FsErrorText.CACHE;
      case FsErrorKind.SERVER:
        return FsErrorText.SERVER;
      default:
        return FsErrorText.NETWORK;
    }
  }
}

/** 把任意异常转换成带 kind 的 FsError，便于 UI 展示统一文案 */
export function toFsError(err: Error | null, fallback: FsErrorKind): FsError {
  if (err === null) {
    return new FsError(fallback, '');
  }
  if (err instanceof FsError) {
    return err;
  }
  return new FsError(fallback, err.message);
}
