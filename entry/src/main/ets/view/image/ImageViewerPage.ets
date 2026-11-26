import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { AppContainer } from '../../app/AppContainer';
import { FileEntry } from '../../model/FileEntry';
import { FileSource, SourceType } from '../../model/FileSource';
import { MediaParam, NavDefaults } from '../../navigation/AppNav';
import { SafeLink } from '../../utils/SafeLink';
import { Fmt } from '../../utils/Format';
import { Symbols } from '../../components/Symbols';
import { ImageLoader, LoadedImage } from '../../utils/ImageLoader';
import { Logger } from '../../utils/Logger';

/** 单张图片读取上限与解码尺寸 */
const MAX_IMAGE_BYTES: number = 64 * 1024 * 1024;
const DECODE_MAX_EDGE: number = 2400;
/** 轮播时预解码的相邻图数量（左右各 1）与像素缓存上限 */
const PREFETCH_RADIUS: number = 1;
const PIXEL_CACHE_LIMIT: number = 5;

interface ImageInfo {
  width: number;
  height: number;
  format: string;
  takenAt: string;
  author: string;
  copyright: string;
  link: string;
}

/**
 * 图片查看器（规范 §7.9）：滑动切换、双指缩放、双击、元数据、作者链接。
 *
 * 切换体验要点：
 *  - 像素按路径缓存在内存里（LRU 5 张），左右滑动时命中缓存直接显示，不再"图不变"；
 *  - 未命中时先在当前页显示加载态，加载完成再替换，绝不会错位显示上一张；
 *  - Swiper 的 index 只作为初始页，之后完全由 onChange 驱动，页码指示器才准确；
 *  - 预解码左右相邻图，滑动即出图。
 */
@Component
export struct ImageViewerPage {
  stack: NavPathStack = new NavPathStack();
  param: MediaParam = NavDefaults.media();

  @State paths: string[] = [];
  @State index: number = 0;
  @State initialIndex: number = 0;
  @State ready: boolean = false;
  @State loading: boolean = true;
  @State errorText: string = '';
  @State cacheTick: number = 0;
  @State zoomScale: number = 1;
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  @State showInfo: boolean = false;
  @State info: ImageInfo = {
    width: 0,
    height: 0,
    format: '',
    takenAt: '',
    author: '',
    copyright: '',
    link: ''
  };

  private container: AppContainer = AppContainer.get();
  private pixelCache: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  private pixelOrder: string[] = [];
  private baseScale: number = 1;
  private baseX: number = 0;
  private baseY: number = 0;
  private loadToken: number = 0;

  aboutToAppear(): void {
    this.loadSiblings();
  }

  aboutToDisappear(): void {
    this.releaseCache();
  }

  private releaseCache(): void {
    const pixels: image.PixelMap[] = [];
    this.pixelCache.forEach((value: image.PixelMap) => {
      pixels.push(value);
    });
    this.pixelCache.clear();
    this.pixelOrder = [];
    for (const pixel of pixels) {
      ImageLoader.release(pixel);
    }
  }

  private pixelFor(path: string): image.PixelMap | null {
    const hit: image.PixelMap | undefined = this.pixelCache.get(path);
    return hit === undefined ? null : hit;
  }

  private putPixel(path: string, pixelMap: image.PixelMap): void {
    this.pixelCache.set(path, pixelMap);
    this.pixelOrder.push(path);
    while (this.pixelOrder.length > PIXEL_CACHE_LIMIT) {
      const evict: string = this.pixelOrder.shift() as string;
      if (evict === this.paths[this.index]) {
        this.pixelOrder.push(evict);
        continue;
      }
      const old: image.PixelMap | undefined = this.pixelCache.get(evict);
      this.pixelCache.delete(evict);
      if (old !== undefined) {
        ImageLoader.release(old);
      }
    }
    this.cacheTick++;
  }

  private async loadSiblings(): Promise<void> {
    const source: FileSource | null = this.container.findSource(this.param.sourceId);
    if (source === null) {
      this.ready = true;
      this.loading = false;
      this.errorText = '来源不存在';
      return;
    }
    let images: string[] = [];
    let current: number = 0;
    try {
      const parent: string = ImageViewerPage.parentOf(this.param.path);
      const entries: FileEntry[] = await this.container.repository!.list(source, parent);
      for (const entry of entries) {
        if (!entry.isDirectory && entry.kind === this.param.kind) {
          if (entry.path === this.param.path) {
            current = images.length;
          }
          images.push(entry.path);
        }
      }
    } catch (err) {
      Logger.error('ImageViewerPage', '读取同目录图片失败', err as Error);
    }
    if (images.length === 0) {
      images = [this.param.path];
      current = 0;
    }
    this.paths = images;
    this.index = current;
    this.initialIndex = current;
    this.ready = true;
    await this.showCurrent();
    this.prefetchNeighbors();
  }

  private static parentOf(path: string): string {
    const trimmed: string = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    const slash: number = trimmed.lastIndexOf('/');
    return slash > 0 ? trimmed.substring(0, slash) : '/';
  }

  private static nameOf(path: string): string {
    const trimmed: string = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    const slash: number = trimmed.lastIndexOf('/');
    return slash >= 0 ? trimmed.substring(slash + 1) : trimmed;
  }

  /** 切换或首次进入时调用：命中缓存即刻显示，否则加载 */
  private async showCurrent(): Promise<void> {
    if (this.paths.length === 0) {
      return;
    }
    const path: string = this.paths[this.index];
    this.resetZoom();
    if (this.pixelFor(path) !== null) {
      this.loading = false;
      this.errorText = '';
      this.updateInfo(path);
      this.cacheTick++;
      this.prefetchNeighbors();
      return;
    }
    this.loading = true;
    this.errorText = '';
    const token: number = this.loadToken + 1;
    this.loadToken = token;
    try {
      const pixelMap: image.PixelMap | null = await this.decode(path);
      if (token !== this.loadToken) {
        if (pixelMap !== null) {
          ImageLoader.release(pixelMap);
        }
        return;
      }
      if (pixelMap === null) {
        this.errorText = '这个图片无法读取或无法解码';
        return;
      }
      this.putPixel(path, pixelMap);
      this.updateInfo(path);
    } catch (err) {
      Logger.error('ImageViewerPage', '加载图片失败', err as Error);
      if (token === this.loadToken) {
        this.errorText = '连接失败或图片无法读取，请重试';
      }
    } finally {
      if (token === this.loadToken) {
        this.loading = false;
      }
    }
    this.prefetchNeighbors();
  }

  private async decode(path: string): Promise<image.PixelMap | null> {
    const source: FileSource | null = this.container.findSource(this.param.sourceId);
    if (source === null) {
      return null;
    }
    const entry: FileEntry = {
      name: ImageViewerPage.nameOf(path),
      path: path,
      isDirectory: false,
      size: this.param.size,
      lastModified: 0,
      mimeType: '',
      kind: this.param.kind
    };
    let localTarget: string = path;
    if (source.type !== SourceType.LOCAL) {
      localTarget = await this.container.repository!.materializeToPath(source, entry);
    }
    let loaded: LoadedImage = await ImageLoader.fromPath(localTarget, DECODE_MAX_EDGE);
    if (loaded.pixelMap === null) {
      const bytes: ArrayBuffer = await this.container.repository!.readDocument(source, entry, MAX_IMAGE_BYTES);
      if (bytes.byteLength === 0) {
        return null;
      }
      loaded = await ImageLoader.fromBytes(bytes, DECODE_MAX_EDGE);
    }
    return loaded.pixelMap;
  }

  private prefetchNeighbors(): void {
    for (let delta = 1; delta <= PREFETCH_RADIUS; delta++) {
      for (const target of [this.index - delta, this.index + delta]) {
        if (target < 0 || target >= this.paths.length) {
          continue;
        }
        const path: string = this.paths[target];
        if (this.pixelFor(path) !== null) {
          continue;
        }
        this.decode(path).then((pixelMap: image.PixelMap | null) => {
          if (pixelMap === null) {
            return;
          }
          if (this.pixelFor(path) !== null) {
            ImageLoader.release(pixelMap);
            return;
          }
          this.putPixel(path, pixelMap);
        }).catch((err: Error) => {
          Logger.warn('ImageViewerPage', '预加载相邻图片失败');
        });
      }
    }
  }

  private updateInfo(path: string): void {
    // 切图时先重置元数据，再用 PixelMap 尺寸 + EXIF 补齐，避免残留上一张的信息
    this.info = {
      width: 0,
      height: 0,
      format: ImageViewerPage.extensionOf(path),
      takenAt: '',
      author: '',
      copyright: '',
      link: ''
    };
    const pixelMap: image.PixelMap | null = this.pixelFor(path);
    if (pixelMap !== null) {
      pixelMap.getImageInfo().then((pixelInfo: image.ImageInfo) => {
        this.info = {
          width: pixelInfo.size.width,
          height: pixelInfo.size.height,
          format: ImageViewerPage.extensionOf(path),
          takenAt: this.info.takenAt,
          author: this.info.author,
          copyright: this.info.copyright,
          link: this.info.link
        };
      }).catch((err: Error) => {
        Logger.warn('ImageViewerPage', '读取图片尺寸失败');
      });
    }
    this.readExifMetadata(path);
  }

  /** EXIF 元数据（作者 / 拍摄时间 / 版权 / 作者链接） */
  private readExifMetadata(path: string): void {
    let source: image.ImageSource | null = null;
    try {
      source = image.createImageSource(path);
      const pending: image.ImageSource = source;
      const properties: Promise<string>[] = [
        pending.getImageProperty(image.PropertyKey.DATE_TIME_ORIGINAL),
        pending.getImageProperty(image.PropertyKey.ARTIST),
        pending.getImageProperty(image.PropertyKey.COPYRIGHT)
      ];
      Promise.all(properties).then((values: string[]) => {
        const info: ImageInfo = {
          width: this.info.width,
          height: this.info.height,
          format: this.info.format,
          takenAt: values[0] === undefined ? '' : values[0],
          author: values[1] === undefined ? '' : values[1],
          copyright: values[2] === undefined ? '' : values[2],
          link: ''
        };
        info.link = SafeLink.firstSafeUrl(`${info.author} ${info.copyright}`);
        this.info = info;
        try {
          pending.release();
        } catch (err) {
          Logger.warn('ImageViewerPage', '释放 ImageSource 失败');
        }
      }).catch((err: Error) => {
        Logger.warn('ImageViewerPage', '读取图片元数据失败');
        try {
          pending.release();
        } catch (releaseErr) {
          Logger.warn('ImageViewerPage', '释放 ImageSource 失败');
        }
      });
    } catch (err) {
      Logger.warn('ImageViewerPage', '创建 ImageSource 失败');
    }
  }

  private static extensionOf(path: string): string {
    const dot: number = path.lastIndexOf('.');
    if (dot < 0) {
      return '';
    }
    return path.substring(dot + 1).toUpperCase();
  }

  private resetZoom(): void {
    this.zoomScale = 1;
    this.baseScale = 1;
    this.offsetX = 0;
    this.offsetY = 0;
    this.baseX = 0;
    this.baseY = 0;
  }

  private async openAuthorLink(): Promise<void> {
    if (this.info.link.length === 0) {
      return;
    }
    const context: common.UIAbilityContext = this.container.requireContext();
    const opened: boolean = await SafeLink.open(context, this.info.link);
    if (!opened) {
      promptAction.showToast({ message: '没有应用可以响应此链接' });
    }
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.ready) {
          Swiper() {
            ForEach(this.paths, (item: string, itemIndex: number) => {
              Stack({ alignContent: Alignment.Center }) {
                if (this.pixelFor(item) !== null) {
                  Image(this.pixelFor(item))
                    .objectFit(ImageFit.Contain)
                    .width('100%')
                    .height('100%')
                    .scale({
                      x: itemIndex === this.index ? this.zoomScale : 1,
                      y: itemIndex === this.index ? this.zoomScale : 1
                    })
                    .translate({
                      x: itemIndex === this.index ? this.offsetX : 0,
                      y: itemIndex === this.index ? this.offsetY : 0
                    })
                } else if (itemIndex === this.index && this.errorText.length > 0) {
                  Column({ space: 12 }) {
                    Text(this.errorText)
                      .fontSize(14)
                      .fontColor(Color.White)
                      .textAlign(TextAlign.Center)
                      .padding({ left: 32, right: 32 })
                    Button('重试')
                      .type(ButtonType.Capsule)
                      .height(38)
                      .backgroundColor($r('app.color.brand'))
                      .fontColor(Color.White)
                      .onClick(() => {
                        this.showCurrent();
                      })
                  }
                } else if (itemIndex === this.index) {
                  LoadingProgress()
                    .width(48)
                    .height(48)
                    .color(Color.White)
                }
              }
              .width('100%')
              .height('100%')
            }, (item: string, itemIndex: number) => `${item}_${itemIndex}`)
          }
          .index(this.initialIndex)
          .indicator(this.paths.length > 1)
          .loop(false)
          .disableSwipe(this.zoomScale > 1.01)
          .width('100%')
          .height('100%')
          .onChange((newIndex: number) => {
            if (newIndex === this.index) {
              return;
            }
            this.index = newIndex;
            this.showCurrent();
          })
          .gesture(
            GestureGroup(GestureMode.Parallel,
              PinchGesture({ fingers: 2 })
                .onActionUpdate((event: GestureEvent) => {
                  const next: number = this.baseScale * event.scale;
                  this.zoomScale = next < 1 ? 1 : (next > 5 ? 5 : next);
                })
                .onActionEnd(() => {
                  if (this.zoomScale <= 1.01) {
                    this.resetZoom();
                  } else {
                    this.baseScale = this.zoomScale;
                  }
                }),
              PanGesture()
                .onActionUpdate((event: GestureEvent) => {
                  if (this.zoomScale > 1.01) {
                    this.offsetX = this.baseX + event.offsetX;
                    this.offsetY = this.baseY + event.offsetY;
                  }
                })
                .onActionEnd(() => {
                  this.baseX = this.offsetX;
                  this.baseY = this.offsetY;
                }),
              TapGesture({ count: 2 })
                .onAction(() => {
                  if (this.zoomScale > 1.01) {
                    this.resetZoom();
                  } else {
                    this.zoomScale = 2.5;
                    this.baseScale = 2.5;
                  }
                })
            )
          )
        } else {
          LoadingProgress()
            .width(48)
            .height(48)
            .color(Color.White)
        }

        Row({ space: 8 }) {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph(Symbols.back())
              .fontSize(20)
              .fontColor([Color.White])
          }
          .width(40)
          .height(40)
          .backgroundColor($r('app.color.player_scrim'))
          .onClick(() => this.stack.pop())

          Blank()

          if (this.paths.length > 1) {
            Text(`${Math.min(this.index + 1, this.paths.length)} / ${this.paths.length}`)
              .fontSize(12)
              .fontColor(Color.White)
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .backgroundColor($r('app.color.player_scrim'))
              .borderRadius(12)
          }

          if (this.info.link.length > 0) {
            Button({ type: ButtonType.Circle }) {
              SymbolGlyph(Symbols.link())
                .fontSize(18)
                .fontColor([Color.White])
            }
            .width(40)
            .height(40)
            .backgroundColor($r('app.color.player_scrim'))
            .onClick(() => {
              this.openAuthorLink();
            })
            .accessibilityText('打开作者链接')
          }

          Button({ type: ButtonType.Circle }) {
            SymbolGlyph(Symbols.info())
              .fontSize(18)
              .fontColor([Color.White])
          }
          .width(40)
          .height(40)
          .backgroundColor($r('app.color.player_scrim'))
          .onClick(() => {
            this.showInfo = true;
          })
          .accessibilityText('图片信息')
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 12 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Black)
    }
    .hideTitleBar(true)
    .backgroundColor(Color.Black)
    .bindSheet($$this.showInfo, this.infoSheet(), {
      height: 420,
      dragBar: true,
      backgroundColor: $r('app.color.surface')
    })
    .onBackPressed((): boolean => false)
  }

  @Builder
  infoSheet() {
    Column({ space: 12 }) {
      Text(this.paths.length > 0 ? ImageViewerPage.nameOf(this.paths[this.index]) : this.param.name)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(2)
        .width('100%')
      Row() {
        Text('尺寸')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
        Text(this.info.width > 0 ? `${this.info.width} × ${this.info.height}` : '未知')
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
      }
      .width('100%')
      Row() {
        Text('格式')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
        Text(this.info.format.length > 0 ? this.info.format : '未知')
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
      }
      .width('100%')
      Row() {
        Text('拍摄时间')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
        Text(this.info.takenAt.length > 0 ? this.info.takenAt : '未知')
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
      }
      .width('100%')
      Row() {
        Text('作者')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
        Text(this.info.author.length > 0 ? this.info.author : '未知')
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      Row() {
        Text('版权')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
        Text(this.info.copyright.length > 0 ? this.info.copyright : '未知')
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      Row() {
        Text('大小')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
        Text(Fmt.size(this.param.size))
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
      }
      .width('100%')
    }
    .width('100%')
    .padding(20)
    .alignItems(HorizontalAlign.Start)
  }
}
