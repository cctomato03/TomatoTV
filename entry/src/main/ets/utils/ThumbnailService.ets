import { image } from '@kit.ImageKit';
import { AppContainer } from '../app/AppContainer';
import { FileEntry } from '../model/FileEntry';
import { FileSource, SourceType } from '../model/FileSource';
import { PreviewKind } from '../model/FileKinds';
import { ImageLoader } from './ImageLoader';
import { Logger } from './Logger';

/** 缩略图解码尺寸（列表 32vp / 网格 72vp，解码到 192px 足够清晰且省内存） */
const THUMB_EDGE: number = 192;
/** 内存缓存条数与并发上限 */
const CACHE_LIMIT: number = 60;
const MAX_CONCURRENCY: number = 2;
/** 过大的图片不做缩略图，避免拖慢列表 */
const MAX_SOURCE_BYTES: number = 24 * 1024 * 1024;

interface ThumbRequest {
  key: string;
  source: FileSource;
  entry: FileEntry;
  callback: (pixelMap: image.PixelMap) => void;
}

/**
 * 目录缩略图服务：给浏览页的列表/网格按需异步加载图片缩略图。
 *
 * - 内存缓存 + LRU 释放（最多 CACHE_LIMIT 张，约 60 × 147KB ≈ 9MB）；
 * - 并发上限 2，先进先出排队，避免快速滚动时把解码线程打满；
 * - 同一路径正在解码时不重复排队（inflight 去重）；
 * - 远程来源复用 RemoteCache（首次落缓存，之后秒开）。
 */
export class ThumbnailService {
  private static instance: ThumbnailService | null = null;

  private cache: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  private order: string[] = [];
  private inflight: Set<string> = new Set<string>();
  private queue: ThumbRequest[] = [];
  private active: number = 0;

  static get(): ThumbnailService {
    if (ThumbnailService.instance === null) {
      ThumbnailService.instance = new ThumbnailService();
    }
    return ThumbnailService.instance;
  }

  static keyOf(sourceId: string, path: string): string {
    return `${sourceId}|${path}`;
  }

  /** 同步取缓存（列表项复用时立刻显示，避免闪一下） */
  cached(sourceId: string, path: string): image.PixelMap | null {
    const hit: image.PixelMap | undefined = this.cache.get(ThumbnailService.keyOf(sourceId, path));
    return hit === undefined ? null : hit;
  }

  /** 请求缩略图；命中缓存时同步回调 */
  request(source: FileSource, entry: FileEntry, callback: (pixelMap: image.PixelMap) => void): void {
    if (entry.isDirectory || entry.kind !== PreviewKind.IMAGE) {
      return;
    }
    if (entry.size > MAX_SOURCE_BYTES) {
      return;
    }
    const key: string = ThumbnailService.keyOf(source.id, entry.path);
    const hit: image.PixelMap | undefined = this.cache.get(key);
    if (hit !== undefined) {
      callback(hit);
      return;
    }
    if (this.inflight.has(key)) {
      return;
    }
    this.inflight.add(key);
    this.queue.push({ key: key, source: source, entry: entry, callback: callback });
    this.pump();
  }

  private pump(): void {
    while (this.active < MAX_CONCURRENCY && this.queue.length > 0) {
      const next: ThumbRequest = this.queue.shift() as ThumbRequest;
      this.active++;
      this.decode(next).finally(() => {
        this.active--;
        this.pump();
      });
    }
  }

  private async decode(request: ThumbRequest): Promise<void> {
    try {
      const container: AppContainer = AppContainer.get();
      const repository = container.repository;
      if (repository === null) {
        return;
      }
      let localPath: string = request.entry.path;
      if (request.source.type !== SourceType.LOCAL) {
        localPath = await repository.materializeToPath(request.source, request.entry);
      }
      let loaded = await ImageLoader.fromPath(localPath, THUMB_EDGE);
      if (loaded.pixelMap === null) {
        const bytes: ArrayBuffer = await repository.readDocument(request.source, request.entry, MAX_SOURCE_BYTES);
        if (bytes.byteLength === 0) {
          return;
        }
        loaded = await ImageLoader.fromBytes(bytes, THUMB_EDGE);
      }
      if (loaded.pixelMap === null) {
        return;
      }
      this.put(request.key, loaded.pixelMap);
      request.callback(loaded.pixelMap);
    } catch (err) {
      Logger.warn('ThumbnailService', `缩略图加载失败 ${request.entry.name}`);
    } finally {
      this.inflight.delete(request.key);
    }
  }

  private put(key: string, pixelMap: image.PixelMap): void {
    this.cache.set(key, pixelMap);
    this.order.push(key);
    while (this.order.length > CACHE_LIMIT) {
      const evict: string = this.order.shift() as string;
      const old: image.PixelMap | undefined = this.cache.get(evict);
      this.cache.delete(evict);
      if (old !== undefined) {
        ImageLoader.release(old);
      }
    }
  }

  /** 清空缓存（离开浏览页或来源变化时调用，释放内存） */
  clear(): void {
    this.queue = [];
    const pixels: image.PixelMap[] = [];
    this.cache.forEach((value: image.PixelMap) => {
      pixels.push(value);
    });
    this.cache.clear();
    this.order = [];
    for (const pixel of pixels) {
      ImageLoader.release(pixel);
    }
  }
}
