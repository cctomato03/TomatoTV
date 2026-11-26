import { image } from '@kit.ImageKit';
import { ImageLoader } from './ImageLoader';
import { Logger } from './Logger';

/** 像素工厂：由调用方提供"如何解码这张图" */
export type PixelFactory = () => Promise<image.PixelMap | null>;

/**
 * 图片像素内存缓存（查看器与缩略图共用）。
 *
 * - 以路径为 key，LRU 淘汰并主动 release，避免 PixelMap 堆积；
 * - `ensure()` 对同一路径做并发去重：预加载与展示同时请求时只解码一次。
 */
export class ImageMemoryCache {
  private static instance: ImageMemoryCache | null = null;

  private cache: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  private order: string[] = [];
  private inflight: Map<string, Promise<image.PixelMap | null>> = new Map<string, Promise<image.PixelMap | null>>();
  private limit: number = 6;

  static get(): ImageMemoryCache {
    if (ImageMemoryCache.instance === null) {
      ImageMemoryCache.instance = new ImageMemoryCache();
    }
    return ImageMemoryCache.instance;
  }

  setLimit(limit: number): void {
    this.limit = limit < 1 ? 1 : limit;
    this.trim();
  }

  peek(key: string): image.PixelMap | null {
    const hit: image.PixelMap | undefined = this.cache.get(key);
    return hit === undefined ? null : hit;
  }

  put(key: string, pixelMap: image.PixelMap): void {
    const existing: image.PixelMap | undefined = this.cache.get(key);
    if (existing !== undefined && existing !== pixelMap) {
      ImageLoader.release(existing);
    }
    this.cache.set(key, pixelMap);
    this.order.push(key);
    this.trim();
  }

  ensure(key: string, factory: PixelFactory): Promise<image.PixelMap | null> {
    const hit: image.PixelMap | null = this.peek(key);
    if (hit !== null) {
      return Promise.resolve(hit);
    }
    const pending: Promise<image.PixelMap | null> | undefined = this.inflight.get(key);
    if (pending !== undefined) {
      return pending;
    }
    const task: Promise<image.PixelMap | null> = factory().then((pixelMap: image.PixelMap | null) => {
      this.inflight.delete(key);
      if (pixelMap !== null) {
        this.put(key, pixelMap);
      }
      return pixelMap;
    }).catch((err: Error) => {
      this.inflight.delete(key);
      Logger.warn('ImageMemoryCache', '解码失败');
      return null;
    });
    this.inflight.set(key, task);
    return task;
  }

  private trim(): void {
    while (this.order.length > this.limit) {
      const evict: string = this.order.shift() as string;
      const old: image.PixelMap | undefined = this.cache.get(evict);
      if (old === undefined) {
        continue;
      }
      this.cache.delete(evict);
      ImageLoader.release(old);
    }
  }

  clearAll(): void {
    const pixels: image.PixelMap[] = [];
    this.cache.forEach((value: image.PixelMap) => {
      pixels.push(value);
    });
    this.cache.clear();
    this.order = [];
    this.inflight.clear();
    for (const pixel of pixels) {
      ImageLoader.release(pixel);
    }
  }
}
