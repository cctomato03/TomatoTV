import { fileIo as fs, ReadOptions } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { FileEntry, FileEntryFactory } from '../../model/FileEntry';
import { FsError, FsErrorKind, FileSystemClient, InputStreamLike, PlayableMedia } from './FileSystemClient';
import { Logger } from '../../utils/Logger';

class LocalStream implements InputStreamLike {
  private fd: number;
  private cursor: number;
  private closed: boolean = false;

  constructor(fd: number, start: number) {
    this.fd = fd;
    this.cursor = start;
  }

  async read(buffer: ArrayBuffer): Promise<number> {
    if (this.closed) {
      return 0;
    }
    try {
      const options: ReadOptions = { offset: this.cursor, length: buffer.byteLength };
      const bytes: number = fs.readSync(this.fd, buffer, options);
      this.cursor += bytes;
      return bytes;
    } catch (err) {
      throw new FsError(FsErrorKind.NOT_FOUND, err instanceof Error ? err.message : '');
    }
  }

  async close(): Promise<void> {
    if (this.closed) {
      return;
    }
    this.closed = true;
    try {
      fs.closeSync(this.fd);
    } catch (err) {
      Logger.warn('LocalFileSystem', `关闭句柄失败 ${(err as BusinessError).code}`);
    }
  }
}

/**
 * 本机目录（规范 §8.2）。
 * - 支持应用沙箱目录与应用私有目录；
 * - 支持 DocumentViewPicker 授权后的 file://docs/... URI；
 * - 统一使用 fileIo 异步/同步 API，避免 UI 线程阻塞（调用方在 TaskPool 中执行）。
 */
export class LocalFileSystem implements FileSystemClient {
  private rootPath: string;

  constructor(rootPath: string) {
    this.rootPath = rootPath.endsWith('/') && rootPath.length > 1
      ? rootPath.substring(0, rootPath.length - 1)
      : rootPath;
  }

  private resolve(path: string): string {
    const target: string = path.length === 0 ? this.rootPath : path;
    return target;
  }

  /** 越界防护：目标必须是来源根目录本身或其子路径 */
  private assertInside(target: string): void {
    if (target === this.rootPath) {
      return;
    }
    if (target.indexOf('..') >= 0) {
      throw new FsError(FsErrorKind.PERMISSION, 'path traversal rejected');
    }
    const prefix: string = this.rootPath.endsWith('/') ? this.rootPath : `${this.rootPath}/`;
    if (!target.startsWith(prefix)) {
      throw new FsError(FsErrorKind.PERMISSION, 'outside of source root');
    }
  }

  private static childPath(parent: string, name: string): string {
    if (parent.endsWith('/')) {
      return `${parent}${name}`;
    }
    return `${parent}/${name}`;
  }

  private static mapError(err: Error): FsError {
    const code: number = (err as BusinessError).code;
    if (code === 13900002) {
      return new FsError(FsErrorKind.NOT_FOUND, err.message);
    }
    if (code === 13900012 || code === 13900001 || code === 201) {
      return new FsError(FsErrorKind.PERMISSION, err.message);
    }
    if (code === 13900018) {
      return new FsError(FsErrorKind.PERMISSION, err.message);
    }
    return new FsError(FsErrorKind.UNKNOWN, err.message);
  }

  async list(path: string): Promise<FileEntry[]> {
    const target: string = this.resolve(path);
    this.assertInside(target);
    let names: string[] = [];
    try {
      names = fs.listFileSync(target);
    } catch (err) {
      throw LocalFileSystem.mapError(err as Error);
    }
    const entries: FileEntry[] = [];
    for (const name of names) {
      const child: string = LocalFileSystem.childPath(target, name);
      try {
        const st: fs.Stat = fs.statSync(child);
        if (st.isDirectory()) {
          entries.push(FileEntryFactory.directory(name, child, st.mtime * 1000));
        } else {
          entries.push(FileEntryFactory.file(name, child, st.size, st.mtime * 1000, ''));
        }
      } catch (err) {
        Logger.warn('LocalFileSystem', `跳过无法读取的条目 ${name}`);
      }
    }
    return entries;
  }

  async stat(path: string): Promise<FileEntry> {
    const target: string = this.resolve(path);
    this.assertInside(target);
    try {
      const st: fs.Stat = fs.statSync(target);
      const slash: number = target.lastIndexOf('/');
      const name: string = slash >= 0 ? target.substring(slash + 1) : target;
      if (st.isDirectory()) {
        return FileEntryFactory.directory(name, target, st.mtime * 1000);
      }
      return FileEntryFactory.file(name, target, st.size, st.mtime * 1000, '');
    } catch (err) {
      throw LocalFileSystem.mapError(err as Error);
    }
  }

  async openStream(path: string, position?: number): Promise<InputStreamLike> {
    const target: string = this.resolve(path);
    this.assertInside(target);
    try {
      const file: fs.File = fs.openSync(target, fs.OpenMode.READ_ONLY);
      const start: number = position === undefined ? 0 : position;
      return new LocalStream(file.fd, start);
    } catch (err) {
      throw LocalFileSystem.mapError(err as Error);
    }
  }

  async readRange(path: string, position: number, length: number): Promise<ArrayBuffer> {
    const target: string = this.resolve(path);
    this.assertInside(target);
    let file: fs.File | null = null;
    try {
      file = fs.openSync(target, fs.OpenMode.READ_ONLY);
      const buffer: ArrayBuffer = new ArrayBuffer(length);
      const options: ReadOptions = { offset: position, length: length };
      fs.readSync(file.fd, buffer, options);
      return buffer;
    } catch (err) {
      throw LocalFileSystem.mapError(err as Error);
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (err) {
          Logger.warn('LocalFileSystem', '关闭文件失败');
        }
      }
    }
  }

  async testConnection(): Promise<void> {
    try {
      fs.accessSync(this.rootPath);
    } catch (err) {
      throw LocalFileSystem.mapError(err as Error);
    }
  }

  async close(): Promise<void> {
  }

  /** AVPlayer 播放本机文件需要 fd */
  openFd(path: string): number {
    const target: string = this.resolve(path);
    this.assertInside(target);
    const file: fs.File = fs.openSync(target, fs.OpenMode.READ_ONLY);
    return file.fd;
  }

  playable(path: string, mimeType: string): PlayableMedia {
    return { fd: this.openFd(path), path: path, url: '', mimeType: mimeType };
  }

  /** 读取文件全部内容（限制上限，供文本预览使用） */
  readAll(path: string, maxBytes: number): ArrayBuffer {
    const target: string = this.resolve(path);
    this.assertInside(target);
    const st: fs.Stat = fs.statSync(target);
    const length: number = st.size > maxBytes ? maxBytes : st.size;
    const buffer: ArrayBuffer = new ArrayBuffer(length);
    const file: fs.File = fs.openSync(target, fs.OpenMode.READ_ONLY);
    try {
      fs.readSync(file.fd, buffer);
    } finally {
      fs.closeSync(file);
    }
    return buffer;
  }
}
