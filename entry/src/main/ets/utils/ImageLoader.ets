import { image } from '@kit.ImageKit';
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
  /** 从字节解码，按 maxDimension 限制最长边，避免大图 OOM */
  static async fromBytes(bytes: ArrayBuffer, maxDimension: number): Promise<LoadedImage> {
    const empty: LoadedImage = { pixelMap: null, width: 0, height: 0 };
    if (bytes.byteLength === 0) {
      return empty;
    }
    let source: image.ImageSource | null = null;
    try {
      source = image.createImageSource(bytes);
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
      const info: image.ImageInfo = await source.getImageInfo();
      const width: number = info.size.width;
      const height: number = info.size.height;
      const longest: number = Math.max(width, height);
      let targetWidth: number = width;
      let targetHeight: number = height;
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
      Logger.error('ImageLoader', '按路径解码图片失败', err as Error);
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
