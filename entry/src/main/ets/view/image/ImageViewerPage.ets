import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { AppContainer } from '../../app/AppContainer';
import { FileEntry } from '../../model/FileEntry';
import { FileSource } from '../../model/FileSource';
import { MediaParam, NavDefaults } from '../../navigation/AppNav';
import { SafeLink } from '../../utils/SafeLink';
import { Fmt } from '../../utils/Format';
import { Symbols } from '../../components/Symbols';
import { Logger } from '../../utils/Logger';

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
  @State srcText: string = '';
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
  @State loading: boolean = true;

  private container: AppContainer = AppContainer.get();
  private baseScale: number = 1;
  private baseX: number = 0;
  private baseY: number = 0;
  private resolved: Map<string, string> = new Map<string, string>();

  aboutToAppear(): void {
    this.loadSiblings();
  }

  private async loadSiblings(): Promise<void> {
    const source: FileSource | null = this.container.findSource(this.param.sourceId);
    if (source === null) {
      this.loading = false;
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

  private async showCurrent(): Promise<void> {
    const source: FileSource | null = this.container.findSource(this.param.sourceId);
    if (source === null || this.paths.length === 0) {
      this.loading = false;
      return;
    }
    const path: string = this.paths[this.index];
    this.loading = true;
    this.resetZoom();
    try {
      let local: string | undefined = this.resolved.get(path);
      if (local === undefined) {
        local = await this.container.repository!.materializeToPath(source,
          {
            name: ImageViewerPage.nameOf(path),
            path: path,
            isDirectory: false,
            size: this.param.size,
            lastModified: 0,
            mimeType: '',
            kind: this.param.kind
          });
        this.resolved.set(path, local);
      }
      this.srcText = local;
      this.readInfo(local, path);
    } catch (err) {
      Logger.error('ImageViewerPage', '加载图片失败', err as Error);
      promptAction.showToast({ message: '这个图片无法解码或格式不受支持' });
    } finally {
      this.loading = false;
    }
  }

  private static nameOf(path: string): string {
    const slash: number = path.lastIndexOf('/');
    return slash >= 0 ? path.substring(slash + 1) : path;
  }

  private readInfo(localPath: string, path: string): void {
    const info: ImageInfo = {
      width: 0,
      height: 0,
      format: '',
      takenAt: '',
      author: '',
      copyright: '',
      link: ''
    };
    let source: image.ImageSource | null = null;
    try {
      const created: image.ImageSource = image.createImageSource(localPath);
      source = created;
      const props: Promise<string>[] = [
        created.getImageProperty(image.PropertyKey.IMAGE_WIDTH),
        created.getImageProperty(image.PropertyKey.IMAGE_LENGTH),
        created.getImageProperty(image.PropertyKey.DATE_TIME_ORIGINAL),
        created.getImageProperty(image.PropertyKey.ARTIST),
        created.getImageProperty(image.PropertyKey.COPYRIGHT)
      ];
      Promise.all(props).then((values: string[]) => {
        const width: number = Number(values[0]);
        const height: number = Number(values[1]);
        info.width = Number.isFinite(width) ? width : 0;
        info.height = Number.isFinite(height) ? height : 0;
        info.takenAt = values[2] === undefined ? '' : values[2];
        info.author = values[3] === undefined ? '' : values[3];
        info.copyright = values[4] === undefined ? '' : values[4];
        info.link = SafeLink.firstSafeUrl(`${info.author} ${info.copyright}`);
        info.format = ImageViewerPage.extensionOf(path);
        this.info = info;
      }).catch((err: Error) => {
        Logger.warn('ImageViewerPage', '读取图片元数据失败');
      });
    } catch (err) {
      Logger.warn('ImageViewerPage', '创建 ImageSource 失败');
    } finally {
      if (source !== null) {
        // ImageSource 在异步属性读取完成后释放
        const pending: image.ImageSource = source;
        setTimeout(() => {
          try {
            pending.release();
          } catch (err) {
            Logger.warn('ImageViewerPage', '释放 ImageSource 失败');
          }
        }, 1200);
      }
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
        if (this.loading) {
          LoadingProgress()
            .width(48)
            .height(48)
            .color($r('app.color.brand'))
        } else {
          Swiper() {
            ForEach(this.paths, (item: string, itemIndex: number) => {
              Image(this.srcText.length > 0 && itemIndex === this.index ? this.srcText : $r('app.media.app_icon'))
                .objectFit(ImageFit.Contain)
                .width('100%')
                .height('100%')
                .scale({ x: itemIndex === this.index ? this.zoomScale : 1, y: itemIndex === this.index ? this.zoomScale : 1 })
                .translate({
                  x: itemIndex === this.index ? this.offsetX : 0,
                  y: itemIndex === this.index ? this.offsetY : 0
                })
            }, (item: string, itemIndex: number) => `${item}_${itemIndex}`)
          }
          .index(this.index)
          .indicator(false)
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
      height: 380,
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
    }
    .width('100%')
    .padding(20)
    .alignItems(HorizontalAlign.Start)
  }
}
