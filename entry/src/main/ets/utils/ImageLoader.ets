import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { FileEntry } from '../model/FileEntry';
import { FileSource, SourceType } from '../model/FileSource';
import { FileRepository } from '../data/repo/FileRepository';
import { Logger } from './Logger';

export interface LoadedImage {
  pixelMap: image.PixelMap | null;
  width: number;
  height: number;
}

/**
 * 图片解码工具。
 *
 * 为什么统一走"字节 -> PixelMap"：远程来源（WebDAV/SMB/FTP）的图片先落到缓存文件，
 * 再把裸路径交给 `Image()` 在部分设备上无法解析（需要 file:// 或 PixelMap）。
 * 统一解码成 PixelMap 后，本地/远程/任何来源的行为一致，也便于按屏宽降采样省内存。
 */
export class ImageLoader {
  private static async decodeSource(source: image.ImageSource, maxDimension: number): Promise<LoadedImage> {
    const empty: LoadedImage = { pixelMap: null, width: 0, height: 0 };
    try {
      const info: image.ImageInfo = await source.getImageInfo();
      const width: number = info.size.width;
      const height: number = info.size.height;
      let targetWidth: number = width;
      let targetHeight: number = height;
      const longest: number = Math.max(width, height);
      if (longest > maxDimension && longest > 0) {
        const ratio: number = maxDimension / longest;
        targetWidth = Math.max(1, Math.round(width * ratio));
        targetHeight = Math.max(1, Math.round(height * ratio));
      }
      const size: image.Size = { width: targetWidth, height: targetHeight };
      const options: image.DecodingOptions = { desiredSize: size, editable: false };
      const pixelMap: image.PixelMap = await source.createPixelMap(options);
      return { pixelMap: pixelMap, width: width, height: height };
    } catch (err) {
      Logger.error('ImageLoader', '图片解码失败', err as Error);
      return empty;
    }
  }

  /** 从字节解码，按 maxDimension 限制最长边，避免大图 OOM */
  static async fromBytes(bytes: ArrayBuffer, maxDimension: number): Promise<LoadedImage> {
    const empty: LoadedImage = { pixelMap: null, width: 0, height: 0 };
    if (bytes.byteLength === 0) {
      return empty;
    }
    let source: image.ImageSource | null = null;
    try {
      source = image.createImageSource(bytes);
      return await ImageLoader.decodeSource(source, maxDimension);
    } catch (err) {
      Logger.error('ImageLoader', '图片解码失败', err as Error);
      return empty;
    } finally {
      if (source !== null) {
        try {
          await source.release();
        } catch (err) {
          Logger.warn('ImageLoader', '释放 ImageSource 失败');
        }
      }
    }
  }

  /** 从本地路径/URI 解码（本机来源直接用文件） */
  static async fromPath(path: string, maxDimension: number): Promise<LoadedImage> {
    const empty: LoadedImage = { pixelMap: null, width: 0, height: 0 };
    let source: image.ImageSource | null = null;
    try {
      source = image.createImageSource(path);
      if (source === null) {
        return empty;
      }
      return await ImageLoader.decodeSource(source, maxDimension);
    } catch (err) {
      Logger.debug('ImageLoader', '按路径解码图片失败，尝试 fd/字节');
      return empty;
    } finally {
      if (source !== null) {
        try {
          await source.release();
        } catch (err) {
          Logger.warn('ImageLoader', '释放 ImageSource 失败');
        }
      }
    }
  }

  /**
   * 从文件 fd 解码。
   * 远程图片落在缓存目录时文件名是 sha256（没有扩展名），按路径解码可能失败，
   * 但 fd 解码不依赖扩展名，因此作为第二选择。
   */
  static async fromFd(fd: number, maxDimension: number): Promise<LoadedImage> {
    const empty: LoadedImage = { pixelMap: null, width: 0, height: 0 };
    let source: image.ImageSource | null = null;
    try {
      source = image.createImageSource(fd);
      if (source === null) {
        return empty;
      }
      return await ImageLoader.decodeSource(source, maxDimension);
    } catch (err) {
      Logger.warn('ImageLoader', '按 fd 解码图片失败');
      return empty;
    } finally {
      if (source !== null) {
        try {
          await source.release();
        } catch (err) {
          Logger.warn('ImageLoader', '释放 ImageSource 失败');
        }
      }
    }
  }

  /** 读取本地文件前 maxBytes 字节（远程图片只读缓存文件，不再回源） */
  private static readLocalBytes(path: string, maxBytes: number): ArrayBuffer {
    const stat: fs.Stat = fs.statSync(path);
    const length: number = stat.size > maxBytes ? maxBytes : stat.size;
    if (length <= 0) {
      return new ArrayBuffer(0);
    }
    const buffer: ArrayBuffer = new ArrayBuffer(length);
    const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      fs.readSync(file.fd, buffer);
    } finally {
      fs.closeSync(file);
    }
    return buffer;
  }

  /**
   * 统一入口：把"某个来源里的某个文件"解码成 PixelMap。
   * 远程来源先落本地缓存（复用 RemoteCache），优先按缓存文件解码；
   * 解码失败时读本地缓存文件字节，绝不为解码再次访问远端。
   */
  static async loadEntry(repository: FileRepository, source: FileSource, entry: FileEntry,
    maxEdge: number, maxBytes: number): Promise<image.PixelMap | null> {
    try {
      let localPath: string = entry.path;
      if (source.type !== SourceType.LOCAL) {
        localPath = await repository.materializeToPath(source, entry);
      }
      const byPath: LoadedImage = await ImageLoader.fromPath(localPath, maxEdge);
      if (byPath.pixelMap !== null) {
        return byPath.pixelMap;
      }
      let fd: number = -1;
      try {
        const file: fs.File = fs.openSync(localPath, fs.OpenMode.READ_ONLY);
        fd = file.fd;
        const byFd: LoadedImage = await ImageLoader.fromFd(fd, maxEdge);
        if (byFd.pixelMap !== null) {
          return byFd.pixelMap;
        }
      } catch (err) {
        Logger.warn('ImageLoader', '打开缓存图片失败');
      } finally {
        if (fd >= 0) {
          try {
            fs.closeSync(fd);
          } catch (closeErr) {
            Logger.warn('ImageLoader', '关闭缓存图片失败');
          }
        }
      }
      let bytes: ArrayBuffer;
      if (source.type === SourceType.LOCAL) {
        bytes = await repository.readDocument(source, entry, maxBytes);
      } else {
        bytes = ImageLoader.readLocalBytes(localPath, maxBytes);
      }
      if (bytes.byteLength === 0) {
        return null;
      }
      const byBytes: LoadedImage = await ImageLoader.fromBytes(bytes, maxEdge);
      return byBytes.pixelMap;
    } catch (err) {
      Logger.error('ImageLoader', '解码图片失败', err as Error);
      return null;
    }
  }

  /** 释放 PixelMap（页面销毁/切图时调用，避免内存堆积） */
  static release(pixelMap: image.PixelMap | null): void {
    if (pixelMap === null) {
      return;
    }
    try {
      pixelMap.release();
    } catch (err) {
      Logger.warn('ImageLoader', '释放 PixelMap 失败');
    }
  }
}
