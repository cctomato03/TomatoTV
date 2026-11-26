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

/** 图片预览读取上限与解码尺寸 */
const MAX_IMAGE_BYTES: number = 64 * 1024 * 1024;
const DECODE_MAX_EDGE: number = 2400;

interface ImageInfo {
  width: number;
  height: number;
  format: string;
  takenAt: string;
  author: string;
  copyright: string;
  link: string;
}

/** 图片查看器（规范 §7.9）：滑动切换、双指缩放、双击、元数据、作者链接 */
@Component
export struct ImageViewerPage {
  stack: NavPathStack = new NavPathStack();
  param: MediaParam = NavDefaults.media();

  @State paths: string[] = [];
  @State index: number = 0;
  @State pixel: image.PixelMap | null = null;
  @State zoomScale: number = 1;
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  @State showInfo: boolean = false;
  @State loading: boolean = true;
  @State errorText: string = '';
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
  private baseScale: number = 1;
  private baseX: number = 0;
  private baseY: number = 0;
  private loadToken: number = 0;

  aboutToAppear(): void {
    this.loadSiblings();
  }

  aboutToDisappear(): void {
    ImageLoader.release(this.pixel);
    this.pixel = null;
  }

  private async loadSiblings(): Promise<void> {
    const source: FileSource | null = this.container.findSource(this.param.sourceId);
    if (source === null) {
      this.loading = false;
      this.errorText = '来源不存在';
      return;
    }
    try {
      const parent: string = ImageViewerPage.parentOf(this.param.path);
      const entries: FileEntry[] = await this.container.repository!.list(source, parent);
      const images: string[] = [];
      let current: number = 0;
      for (const entry of entries) {
        if (!entry.isDirectory && entry.kind === this.param.kind) {
          if (entry.path === this.param.path) {
            current = images.length;
          }
          images.push(entry.path);
        }
      }
      if (images.length === 0) {
        images.push(this.param.path);
      }
      this.paths = images;
      this.index = current;
      await this.showCurrent();
    } catch (err) {
      Logger.error('ImageViewerPage', '读取同目录图片失败', err as Error);
      this.paths = [this.param.path];
      this.index = 0;
      await this.showCurrent();
    }
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

  /**
   * 加载当前图片：统一"读字节 -> 解码成 PixelMap"，
   * 这样本机（含 Picker URI）、WebDAV、SMB、FTP 走同一条链路，不依赖 Image 对裸路径的解析。
   */
  private async showCurrent(): Promise<void> {
    const source: FileSource | null = this.container.findSource(this.param.sourceId);
    if (source === null || this.paths.length === 0) {
      this.loading = false;
      return;
    }
    const token: number = this.loadToken + 1;
    this.loadToken = token;
    const path: string = this.paths[this.index];
    this.loading = true;
    this.errorText = '';
    this.resetZoom();
    try {
      const entry: FileEntry = {
        name: ImageViewerPage.nameOf(path),
        path: path,
        isDirectory: false,
        size: this.param.size,
        lastModified: 0,
        mimeType: '',
        kind: this.param.kind
      };
      // 远程来源先落到本地缓存（带完整性校验），再按本地文件解码；本机来源直接用 uri
      let localTarget: string = path;
      if (source.type !== SourceType.LOCAL) {
        localTarget = await this.container.repository!.materializeToPath(source, entry);
      }
      if (token !== this.loadToken) {
        return;
      }
      let loaded: LoadedImage = await ImageLoader.fromPath(localTarget, DECODE_MAX_EDGE);
      if (loaded.pixelMap === null) {
        // 路径解码失败时退回"读字节再解码"，兼容 Picker URI 等特殊路径
        const bytes: ArrayBuffer = await this.container.repository!.readDocument(source, entry, MAX_IMAGE_BYTES);
        if (token !== this.loadToken) {
          return;
        }
        if (bytes.byteLength === 0) {
          this.errorText = '图片内容读取失败，请重试';
          return;
        }
        loaded = await ImageLoader.fromBytes(bytes, DECODE_MAX_EDGE);
      }
      if (token !== this.loadToken) {
        return;
      }
      if (loaded.pixelMap === null) {
        this.errorText = '这个图片无法解码或格式不受支持';
        return;
      }
      const previous: image.PixelMap | null = this.pixel;
      this.pixel = loaded.pixelMap;
      ImageLoader.release(previous);
      this.info = {
        width: loaded.width,
        height: loaded.height,
        format: ImageViewerPage.extensionOf(path),
        takenAt: '',
        author: '',
        copyright: '',
        link: ''
      };
      this.readExifMetadata(localTarget, path);
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
  }

  /** EXIF 元数据（作者 / 拍摄时间 / 版权 / 作者链接） */
  private readExifMetadata(localPath: string, path: string): void {
    let source: image.ImageSource | null = null;
    try {
      source = image.createImageSource(localPath);
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
          format: ImageViewerPage.extensionOf(path),
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
        Swiper() {
          ForEach(this.paths, (item: string, itemIndex: number) => {
            Stack({ alignContent: Alignment.Center }) {
              if (itemIndex === this.index && this.pixel !== null) {
                Image(this.pixel)
                  .objectFit(ImageFit.Contain)
                  .width('100%')
                  .height('100%')
                  .scale({ x: this.zoomScale, y: this.zoomScale })
                  .translate({ x: this.offsetX, y: this.offsetY })
              } else if (itemIndex === this.index && this.loading) {
                LoadingProgress()
                  .width(48)
                  .height(48)
                  .color(Color.White)
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
              }
            }
            .width('100%')
            .height('100%')
          }, (item: string, itemIndex: number) => `${item}_${itemIndex}`)
        }
        .index(this.index)
        .indicator(this.paths.length > 1)
        .loop(false)
        .disableSwipe(this.zoomScale > 1.01)
        .width('100%')
        .height('100%')
        .onChange((newIndex: number) => {
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
            Text(`${this.index + 1} / ${this.paths.length}`)
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
