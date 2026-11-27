import { image } from '@kit.ImageKit';
import { AppContainer } from '../app/AppContainer';
import { FileEntry } from '../model/FileEntry';
import { FileSource, SourceFactory, SourceType } from '../model/FileSource';
import { PreviewKind } from '../model/FileKinds';
import { ImageLoader } from '../utils/ImageLoader';
import { ImageMemoryCache } from '../utils/ImageMemoryCache';
import { Symbols } from './Symbols';

const DECODE_MAX_EDGE: number = 2400;
const MAX_IMAGE_BYTES: number = 64 * 1024 * 1024;

/**
 * 轮播中的单张图片。
 *
 * 为什么每个切片是独立组件：ArkUI 的 ForEach 子项不会因为父组件里"非状态数据"变化而重绘，
 * 之前把 PixelMap 放在父组件的普通 Map 里，首张图加载完成后页面不会刷新（表现为一直转圈，
 * 滑动一下才出现）。改成每个切片自己持有 @State pixel，加载完成即局部刷新。
 */
@Component
export struct ImageSlide {
  path: string = '';
  source: FileSource = SourceFactory.blank(SourceType.LOCAL);
  kind: PreviewKind = PreviewKind.IMAGE;
  fileSize: number = 0;
  @Prop active: boolean = false;
  @Prop zoomScale: number = 1;
  @Prop offsetX: number = 0;
  @Prop offsetY: number = 0;
  onLoaded: (path: string) => void = () => {
  };
  onFailed: (path: string) => void = () => {
  };

  @State pixel: image.PixelMap | null = null;
  @State failed: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  private load(): void {
    const cache: ImageMemoryCache = ImageMemoryCache.get();
    const key: string = ImageMemoryCache.keyOf(this.source.id, this.path);
    const hit: image.PixelMap | null = cache.peek(key);
    if (hit !== null) {
      this.pixel = hit;
      this.onLoaded(this.path);
      return;
    }
    this.failed = false;
    cache.ensure(key, () => this.decode()).then((pixelMap: image.PixelMap | null) => {
      if (pixelMap === null) {
        this.failed = true;
        this.onFailed(this.path);
        return;
      }
      this.pixel = pixelMap;
      this.onLoaded(this.path);
    }).catch((err: Error) => {
      this.failed = true;
      this.onFailed(this.path);
    });
  }

  private decode(): Promise<image.PixelMap | null> {
    const container: AppContainer = AppContainer.get();
    const repository = container.repository;
    if (repository === null) {
      return Promise.resolve(null);
    }
    const entry: FileEntry = {
      name: ImageSlide.nameOf(this.path),
      path: this.path,
      isDirectory: false,
      size: this.fileSize,
      lastModified: 0,
      mimeType: '',
      kind: this.kind
    };
    return ImageLoader.loadEntry(repository, this.source, entry, DECODE_MAX_EDGE, MAX_IMAGE_BYTES);
  }

  static nameOf(path: string): string {
    const trimmed: string = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    const slash: number = trimmed.lastIndexOf('/');
    return slash >= 0 ? trimmed.substring(slash + 1) : trimmed;
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.pixel !== null) {
        Image(this.pixel)
          .objectFit(ImageFit.Contain)
          .width('100%')
          .height('100%')
          .scale({ x: this.active ? this.zoomScale : 1, y: this.active ? this.zoomScale : 1 })
          .translate({ x: this.active ? this.offsetX : 0, y: this.active ? this.offsetY : 0 })
      } else if (this.failed) {
        Column({ space: 10 }) {
          SymbolGlyph(Symbols.photo())
            .fontSize(36)
            .fontColor([$r('app.color.text_tertiary')])
          Text('这个图片无法读取或无法解码')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
          Button('重试')
            .type(ButtonType.Capsule)
            .height(36)
            .backgroundColor($r('app.color.brand'))
            .fontColor(Color.White)
            .onClick(() => {
              ImageMemoryCache.get().clearAll();
              this.load();
            })
        }
      } else {
        LoadingProgress()
          .width(44)
          .height(44)
          .color($r('app.color.brand'))
      }
    }
    .width('100%')
    .height('100%')
  }
}
