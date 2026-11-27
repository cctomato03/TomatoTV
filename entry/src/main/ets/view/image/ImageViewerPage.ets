import { image } from '@kit.ImageKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { promptAction } from '@kit.ArkUI';
import { AppContainer } from '../../app/AppContainer';
import { FileEntry, FileSorter } from '../../model/FileEntry';
import { FileSource, SourceFactory, SourceType } from '../../model/FileSource';
import { MediaParam, NavDefaults } from '../../navigation/AppNav';
import { SafeLink } from '../../utils/SafeLink';
import { Fmt } from '../../utils/Format';
import { Symbols } from '../../components/Symbols';
import { ImageSlide } from '../../components/ImageSlide';
import { ImageLoader } from '../../utils/ImageLoader';
import { ImageMemoryCache } from '../../utils/ImageMemoryCache';
import { Logger } from '../../utils/Logger';
import { WindowTheme } from '../../utils/WindowTheme';

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
  private sizes: Map<string, number> = new Map<string, number>();
  private metaToken: number = 0;

  aboutToAppear(): void {
    WindowTheme.light();
    // 像素缓存由 ImageMemoryCache 统一按 LRU 管理，退出查看器不清空，
    // 这样再次打开同一张图/相邻图时不会重新解码和请求。
    ImageMemoryCache.get().setLimit(6);
    this.loadSiblings();
  }

  aboutToDisappear(): void {
    WindowTheme.light();
  }

  private sizeOf(path: string): number {
    const known: number | undefined = this.sizes.get(path);
    return known === undefined ? this.param.size : known;
  }

  private currentSize(): number {
    const path: string = this.paths.length > 0 ? this.paths[this.index] : this.param.path;
    return this.sizeOf(path);
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
    this.sizes = new Map<string, number>();
    try {
      const parent: string = ImageViewerPage.parentOf(this.param.path);
      const entries: FileEntry[] = await this.container.repository!.list(source, parent);
      // 与浏览页使用同样的排序，保证左右滑动的顺序与列表一致
      const sorted: FileEntry[] = FileSorter.sort(entries, this.container.settings().sortMode);
      for (const entry of sorted) {
        if (!entry.isDirectory && entry.kind === this.param.kind) {
          if (entry.path === this.param.path) {
            current = images.length;
          }
          this.sizes.set(entry.path, entry.size);
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
        const key: string = ImageMemoryCache.keyOf(this.sourceRef.id, path);
        if (cache.peek(key) !== null) {
          continue;
        }
        cache.ensure(key, () => this.decodeAt(path)).then((pixelMap: image.PixelMap | null) => {
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
      size: this.sizeOf(path),
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

  private static readProperty(source: image.ImageSource, key: image.PropertyKey): Promise<string> {
    return source.getImageProperty(key)
      .then((value: string) => value.length > 0 ? value.trim() : '')
      .catch((): string => '');
  }

  /**
   * 读取元数据（尺寸 / 拍摄时间 / 作者 / 版权 / 作者链接）。
   *
   * 远程图片由 RemoteCache 物化成缓存文件后按 fd 读取，不再为元数据重新走网络；
   * 每个属性单独 catch，避免某一个字段缺失导致整组信息都拿不到。
   */
  private async readMetadata(path: string): Promise<void> {
    const repository = this.container.repository;
    if (repository === null) {
      return;
    }
    const token: number = this.metaToken + 1;
    this.metaToken = token;
    const entry: FileEntry = {
      name: ImageViewerPage.nameOf(path),
      path: path,
      isDirectory: false,
      size: this.sizeOf(path),
      lastModified: 0,
      mimeType: '',
      kind: this.param.kind
    };
    let localPath: string = '';
    try {
      localPath = await repository.materializeToPath(this.sourceRef, entry);
    } catch (err) {
      Logger.warn('ImageViewerPage', '图片缓存/读取失败，跳过元数据');
      return;
    }
    let imageSource: image.ImageSource | null = null;
    let file: fs.File | null = null;
    try {
      file = fs.openSync(localPath, fs.OpenMode.READ_ONLY);
      imageSource = image.createImageSource(file.fd);
      const pending: image.ImageSource = imageSource;
      const info: image.ImageInfo = await pending.getImageInfo();
      const takenAt: string = await ImageViewerPage.readProperty(pending, image.PropertyKey.DATE_TIME_ORIGINAL);
      const author: string = await ImageViewerPage.readProperty(pending, image.PropertyKey.ARTIST);
      const copyright: string = await ImageViewerPage.readProperty(pending, image.PropertyKey.COPYRIGHT);
      const description: string = await ImageViewerPage.readProperty(pending, image.PropertyKey.IMAGE_DESCRIPTION);
      const comment: string = await ImageViewerPage.readProperty(pending, image.PropertyKey.USER_COMMENT);
      if (token !== this.metaToken) {
        return;
      }
      // 链接按"作者 → 版权 → 图片描述 → 用户备注"的顺序找
      let link: string = SafeLink.firstUrlAnyScheme(author);
      if (link.length === 0) {
        link = SafeLink.firstUrlAnyScheme(copyright);
      }
      if (link.length === 0) {
        link = SafeLink.firstUrlAnyScheme(description);
      }
      if (link.length === 0) {
        link = SafeLink.firstUrlAnyScheme(comment);
      }
      this.info = {
        width: info.size.width,
        height: info.size.height,
        format: ImageViewerPage.extensionOf(path),
        takenAt: takenAt,
        author: author,
        copyright: copyright,
        link: link
      };
      Logger.info('ImageViewerPage',
        `元数据 ${info.size.width}x${info.size.height} author=${author} copyright=${copyright} link=${link}`);
    } catch (err) {
      Logger.warn('ImageViewerPage', '读取图片元数据失败');
    } finally {
      if (imageSource !== null) {
        try {
          await imageSource.release();
        } catch (releaseErr) {
          Logger.warn('ImageViewerPage', '释放 ImageSource 失败');
        }
      }
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (closeErr) {
          Logger.warn('ImageViewerPage', '关闭图片文件失败');
        }
      }
    }
  }

  /**
   * 右下角"链接"按钮的目标：优先取元数据里"作者"字段中的链接
   * （通常是打开某个 App 的 URL），其次回退到版权字段里的链接。
   */
  private linkTarget(): string {
    if (this.info.author.length > 0) {
      return this.info.author;
    }
    return SafeLink.firstUrlAnyScheme(this.info.copyright);
  }

  /** 复制链接到系统剪贴板，不唤起外部应用 */
  private async copyLink(): Promise<void> {
    let target: string = this.linkTarget();
    if (target.length === 0) {
      // 元数据可能还没读回来：再取一次
      await this.reloadMetadataIfNeeded();
      target = this.linkTarget();
    }
    if (target.length === 0) {
      promptAction.showToast({ message: '这张图片没有作者链接' });
      return;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, target);
      await pasteboard.getSystemPasteboard().setData(data);
      promptAction.showToast({ message: '链接已复制' });
    } catch (err) {
      Logger.warn('ImageViewerPage', '复制链接失败');
      promptAction.showToast({ message: '复制失败' });
    }
  }

  /** 作者链接为空时，重新读一次元数据（切图后元数据是异步到达的） */
  private async reloadMetadataIfNeeded(): Promise<void> {
    const path: string = this.paths.length > 0 ? this.paths[this.index] : this.param.path;
    await this.readMetadata(path);
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
                fileSize: this.sizeOf(item),
                active: itemIndex === this.index,
                zoomScale: this.zoomScale,
                offsetX: this.offsetX,
                offsetY: this.offsetY,
                onLoaded: (path: string) => this.onSlideLoaded(path)
              })
            }, (item: string, itemIndex: number) => `${item}_${itemIndex}`)
          }
          .index($$this.index)
          .indicator(false)
          .loop(false)
          .disableSwipe(this.zoomScale > 1.01)
          .width('100%')
          .height('100%')
          .onChange((newIndex: number) => {
            if (newIndex < 0 || newIndex >= this.paths.length) {
              return;
            }
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
          Stack({ alignContent: Alignment.Center }) {
            LoadingProgress()
              .width(44)
              .height(44)
              .color($r('app.color.brand'))
          }
          .width('100%')
          .height('100%')
          .hitTestBehavior(HitTestMode.None)
        }

        // 顶部：返回 / 居中文件名 / 信息
        Row({ space: 8 }) {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph(Symbols.back())
              .fontSize(20)
              .fontColor([$r('app.color.text_primary')])
          }
          .width(40)
          .height(40)
          .padding(0)
          .backgroundColor($r('app.color.surface_card'))
          .onClick(() => this.stack.pop())

          Blank()

          Text(this.paths.length > 0 ? ImageViewerPage.nameOf(this.paths[this.index]) : this.param.name)
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textAlign(TextAlign.Center)
            .layoutWeight(1)

          Button({ type: ButtonType.Circle }) {
            SymbolGlyph(Symbols.info())
              .fontSize(18)
              .fontColor([$r('app.color.text_primary')])
          }
          .width(40)
          .height(40)
          .padding(0)
          .backgroundColor($r('app.color.surface_card'))
          .onClick(() => {
            this.showInfo = true;
          })
          .accessibilityText('图片信息')
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 12 })
        .position({ x: 0, y: 0 })

        // 底部居中：图片序号 / 总数
        Stack({ alignContent: Alignment.Bottom }) {
          if (this.paths.length > 1) {
            Text(`${Math.min(this.index + 1, this.paths.length)} / ${this.paths.length}`)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .padding({ left: 12, right: 12, top: 5, bottom: 5 })
              .backgroundColor($r('app.color.surface_card'))
              .borderRadius(14)
              .margin({ bottom: 28 })
          }
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)

        // 右下角：链接（常显，点击时再判断有没有作者链接）
        Stack({ alignContent: Alignment.BottomEnd }) {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph(Symbols.link())
              .fontSize(20)
              .fontColor([Color.White])
          }
          .width(44)
          .height(44)
          .padding(0)
          .backgroundColor($r('app.color.brand'))
          .margin({ right: 16, bottom: 24 })
          .onClick(() => {
            this.copyLink();
          })
          .accessibilityText('复制图片链接')
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.surface'))
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.surface'))
    .bindSheet($$this.showInfo, this.infoSheet(), {
      height: 460,
      dragBar: true,
      showClose: false,
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
        Text(Fmt.size(this.currentSize()))
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
          Button('复制链接')
            .type(ButtonType.Capsule)
            .height(36)
            .backgroundColor($r('app.color.brand'))
            .fontColor(Color.White)
            .fontSize(13)
            .onClick(() => {
              this.copyLink();
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
