import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { AppContainer } from '../../app/AppContainer';
import { FileEntry } from '../../model/FileEntry';
import { FileSource, SourceFactory, SourceUrl, SourceType } from '../../model/FileSource';
import { MediaParam, NavDefaults } from '../../navigation/AppNav';
import { SafeLink } from '../../utils/SafeLink';
import { Fmt } from '../../utils/Format';
import { Symbols } from '../../components/Symbols';
import { ImageSlide } from '../../components/ImageSlide';
import { ImageLoader } from '../../utils/ImageLoader';
import { ImageMemoryCache } from '../../utils/ImageMemoryCache';
import { Logger } from '../../utils/Logger';

const DECODE_MAX_EDGE: number = 2400;
const MAX_IMAGE_BYTES: number = 64 * 1024 * 1024;
const PREFETCH_RADIUS: number = 1;

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
 * 图片查看器（规范 §7.9）：滑动切换、双指缩放、双击、元数据、打开链接。
 *
 * 结构说明：
 *  - 每一页是独立的 `ImageSlide` 组件，自己持有 @State PixelMap，
 *    因此首张图解码完成后会立即局部刷新（不再出现"一直转圈，滑一下才出来"）；
 *  - 像素走 `ImageMemoryCache`（LRU 6 张 + 并发去重），并预解码左右相邻图，滑动即出图；
 *  - Swiper 的 index 只作为初始页，之后完全由 onChange 驱动，页码数字才与当前图一致；
 *  - 不显示底部圆点指示器，只用"当前 / 总数"数字；
 *  - 右下角"链接"按钮：优先打开 EXIF 里的链接，否则打开该图片在来源上的 URL，
 *    两种都直接交给系统分发（不限制 scheme）。
 */
@Component
export struct ImageViewerPage {
  stack: NavPathStack = new NavPathStack();
  param: MediaParam = NavDefaults.media();

  @State paths: string[] = [];
  @State index: number = 0;
  @State initialIndex: number = 0;
  @State ready: boolean = false;
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
  private sourceRef: FileSource = SourceFactory.blank(SourceType.LOCAL);
  private baseScale: number = 1;
  private baseX: number = 0;
  private baseY: number = 0;

  aboutToAppear(): void {
    ImageMemoryCache.get().setLimit(6);
    this.loadSiblings();
  }

  aboutToDisappear(): void {
    ImageMemoryCache.get().clearAll();
  }

  private async loadSiblings(): Promise<void> {
    const source: FileSource | null = this.container.findSource(this.param.sourceId);
    if (source === null) {
      this.ready = true;
      return;
    }
    this.sourceRef = source;
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
    this.syncInfo(this.paths[current]);
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

  private static extensionOf(path: string): string {
    const dot: number = path.lastIndexOf('.');
    if (dot < 0) {
      return '';
    }
    return path.substring(dot + 1).toUpperCase();
  }

  /** 预解码左右相邻图，滑动时直接命中缓存 */
  private prefetchNeighbors(): void {
    const cache: ImageMemoryCache = ImageMemoryCache.get();
    for (let delta = 1; delta <= PREFETCH_RADIUS; delta++) {
      const candidates: number[] = [this.index - delta, this.index + delta];
      for (const target of candidates) {
        if (target < 0 || target >= this.paths.length) {
          continue;
        }
        const path: string = this.paths[target];
        if (cache.peek(path) !== null) {
          continue;
        }
        cache.ensure(path, () => this.decodeAt(path)).then((pixelMap: image.PixelMap | null) => {
          void pixelMap;
        }).catch((err: Error) => {
          Logger.warn('ImageViewerPage', '预加载相邻图片失败');
        });
      }
    }
  }

  private decodeAt(path: string): Promise<image.PixelMap | null> {
    const repository = this.container.repository;
    if (repository === null) {
      return Promise.resolve(null);
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
    return ImageLoader.loadEntry(repository, this.sourceRef, entry, DECODE_MAX_EDGE, MAX_IMAGE_BYTES);
  }

  private onSlideLoaded(path: string): void {
    if (path === this.paths[this.index]) {
      this.syncInfo(path);
    }
  }

  /** 切换后同步元数据（尺寸/格式/拍摄信息/链接） */
  private syncInfo(path: string): void {
    this.info = {
      width: 0,
      height: 0,
      format: ImageViewerPage.extensionOf(path),
      takenAt: '',
      author: '',
      copyright: '',
      link: ''
    };
    this.readMetadata(path);
  }

  private readMetadata(path: string): void {
    const repository = this.container.repository;
    if (repository === null) {
      return;
    }
    const source: FileSource = this.sourceRef;
    const entry: FileEntry = {
      name: ImageViewerPage.nameOf(path),
      path: path,
      isDirectory: false,
      size: this.param.size,
      lastModified: 0,
      mimeType: '',
      kind: this.param.kind
    };
    let target: Promise<string>;
    if (source.type === SourceType.LOCAL) {
      target = Promise.resolve(path);
    } else {
      target = repository.materializeToPath(source, entry);
    }
    target.then((localPath: string) => {
      let imageSource: image.ImageSource | null = null;
      try {
        imageSource = image.createImageSource(localPath);
        const pending: image.ImageSource = imageSource;
        pending.getImageInfo().then((pixelInfo: image.ImageInfo) => {
          this.info = {
            width: pixelInfo.size.width,
            height: pixelInfo.size.height,
            format: this.info.format,
            takenAt: this.info.takenAt,
            author: this.info.author,
            copyright: this.info.copyright,
            link: this.info.link
          };
        }).catch((err: Error) => {
          Logger.warn('ImageViewerPage', '读取图片尺寸失败');
        });
        const properties: Promise<string>[] = [
          pending.getImageProperty(image.PropertyKey.DATE_TIME_ORIGINAL),
          pending.getImageProperty(image.PropertyKey.ARTIST),
          pending.getImageProperty(image.PropertyKey.COPYRIGHT)
        ];
        Promise.all(properties).then((values: string[]) => {
          const exifText: string = `${values[1] === undefined ? '' : values[1]} ` +
            `${values[2] === undefined ? '' : values[2]}`;
          this.info = {
            width: this.info.width,
            height: this.info.height,
            format: this.info.format,
            takenAt: values[0] === undefined ? '' : values[0],
            author: values[1] === undefined ? '' : values[1],
            copyright: values[2] === undefined ? '' : values[2],
            link: SafeLink.firstUrlAnyScheme(exifText)
          };
          try {
            pending.release();
          } catch (releaseErr) {
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
    }).catch((err: Error) => {
      Logger.warn('ImageViewerPage', '读取图片元数据失败');
    });
  }

  /** 右下角"链接"按钮的目标：EXIF 链接优先，否则是图片在来源上的 URL */
  private linkTarget(): string {
    if (this.info.link.length > 0) {
      return this.info.link;
    }
    const source: FileSource | null = this.container.findSource(this.param.sourceId);
    if (source === null) {
      return '';
    }
    const path: string = this.paths.length > 0 ? this.paths[this.index] : this.param.path;
    const suffix: string = path.startsWith('/') ? path : `/${path}`;
    switch (source.type) {
      case SourceType.WEBDAV: {
        let base: string = source.url;
        while (base.endsWith('/')) {
          base = base.substring(0, base.length - 1);
        }
        const encoded: string = SourceUrl.encodePath(path);
        return encoded.length === 0 ? base : `${base}/${encoded}`;
      }
      case SourceType.FTP: {
        const scheme: string = source.secure ? 'ftps' : 'ftp';
        return `${scheme}://${source.host}:${source.port}${suffix}`;
      }
      case SourceType.SMB: {
        return `smb://${source.host}/${source.share}${suffix}`;
      }
      default:
        return '';
    }
  }

  private async openLink(): Promise<void> {
    const target: string = this.linkTarget();
    if (target.length === 0) {
      return;
    }
    const context: common.UIAbilityContext = this.container.requireContext();
    const opened: boolean = await SafeLink.openUnrestricted(context, target);
    if (!opened) {
      promptAction.showToast({ message: '没有应用可以响应此链接' });
    }
  }

  private resetZoom(): void {
    this.zoomScale = 1;
    this.baseScale = 1;
    this.offsetX = 0;
    this.offsetY = 0;
    this.baseX = 0;
    this.baseY = 0;
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Bottom }) {
        if (this.ready) {
          Swiper() {
            ForEach(this.paths, (item: string, itemIndex: number) => {
              ImageSlide({
                path: item,
                source: this.sourceRef,
                kind: this.param.kind,
                fileSize: this.param.size,
                active: itemIndex === this.index,
                zoomScale: this.zoomScale,
                offsetX: this.offsetX,
                offsetY: this.offsetY,
                onLoaded: (path: string) => this.onSlideLoaded(path)
              })
            }, (item: string, itemIndex: number) => `${item}_${itemIndex}`)
          }
          .index(this.initialIndex)
          .indicator(false)
          .loop(false)
          .disableSwipe(this.zoomScale > 1.01)
          .width('100%')
          .height('100%')
          .onChange((newIndex: number) => {
            if (newIndex === this.index) {
              return;
            }
            this.index = newIndex;
            this.resetZoom();
            this.syncInfo(this.paths[newIndex]);
            this.prefetchNeighbors();
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
            .width(44)
            .height(44)
            .color(Color.White)
        }

        // 顶部：返回 / 页码 / 信息
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
        .position({ x: 0, y: 0 })

        // 右下角：链接
        if (this.linkTarget().length > 0) {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph(Symbols.link())
              .fontSize(20)
              .fontColor([Color.White])
          }
          .width(44)
          .height(44)
          .backgroundColor($r('app.color.brand'))
          .margin({ right: 16, bottom: 24 })
          .align(Alignment.BottomEnd)
          .onClick(() => {
            this.openLink();
          })
          .accessibilityText('打开图片链接')
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Black)
    }
    .hideTitleBar(true)
    .backgroundColor(Color.Black)
    .bindSheet($$this.showInfo, this.infoSheet(), {
      height: 460,
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
        Text('大小')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
        Text(Fmt.size(this.param.size))
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
      if (this.linkTarget().length > 0) {
        Column({ space: 6 }) {
          Text('链接')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          Text(this.linkTarget())
            .fontSize(13)
            .fontColor($r('app.color.brand'))
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .copyOption(CopyOptions.LocalDevice)
            .width('100%')
          Button('打开链接')
            .type(ButtonType.Capsule)
            .height(36)
            .backgroundColor($r('app.color.brand'))
            .fontColor(Color.White)
            .fontSize(13)
            .onClick(() => {
              this.openLink();
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .padding(20)
    .alignItems(HorizontalAlign.Start)
  }
}
