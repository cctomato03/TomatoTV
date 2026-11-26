import { promptAction } from '@kit.ArkUI';
import { common, Want } from '@kit.AbilityKit';
import { fileUri } from '@kit.CoreFileKit';
import { AppContainer } from '../../app/AppContainer';
import { FileSource } from '../../model/FileSource';
import { PreviewKind } from '../../model/FileKinds';
import { FileEntry } from '../../model/FileEntry';
import { DocParam, NavDefaults } from '../../navigation/AppNav';
import { Fmt } from '../../utils/Format';
import { Symbols } from '../../components/Symbols';
import { DocumentWebView } from '../../components/DocumentWebView';
import { Logger } from '../../utils/Logger';

/** 单文件预览上限：超过后只提示用其他应用打开，避免大文件占用内存 */
const MAX_DOC_BYTES: number = 64 * 1024 * 1024;

enum DocStage {
  READING = 'READING',
  READY = 'READY',
  FAILED = 'FAILED'
}

/**
 * PDF / Office 预览（规范 §7.7、§7.8）。
 *
 * 渲染方式：应用内离线渲染（rawfile 内置 pdf.js / docx-preview+JSZip / SheetJS），
 * 通过 Web 组件加载本地页面，文档字节由 onInterceptRequest 注入，全程无外发请求。
 * PPTX 目前没有可离线集成的渲染库，降级为「用其他应用打开」并保留文件信息。
 */
@Component
export struct DocPreviewPage {
  stack: NavPathStack = new NavPathStack();
  param: DocParam = NavDefaults.doc();

  @State stage: DocStage = DocStage.READING;
  @State failure: string = '';
  @State docBytes: ArrayBuffer = new ArrayBuffer(0);
  @State workerBytes: ArrayBuffer = new ArrayBuffer(0);
  @State viewerSrc: Resource = $rawfile('viewer/pdf/index.html');
  @State docMime: string = 'application/octet-stream';
  @State openable: boolean = false;

  private container: AppContainer = AppContainer.get();

  aboutToAppear(): void {
    this.prepare();
  }

  private supportsInApp(): boolean {
    return this.param.kind === PreviewKind.PDF || this.param.kind === PreviewKind.DOCX ||
      this.param.kind === PreviewKind.XLSX;
  }

  private kindLabel(): string {
    switch (this.param.kind) {
      case PreviewKind.PDF:
        return 'PDF 文档';
      case PreviewKind.DOCX:
        return 'Word 文档';
      case PreviewKind.XLSX:
        return 'Excel 表格';
      case PreviewKind.PPTX:
        return 'PowerPoint 演示';
      default:
        return '文档';
    }
  }

  private async prepare(): Promise<void> {
    this.stage = DocStage.READING;
    this.failure = '';
    const source: FileSource | null = this.container.findSource(this.param.sourceId);
    if (source === null) {
      this.failWith('来源不存在');
      return;
    }
    this.openable = true;
    if (!this.supportsInApp()) {
      this.stage = DocStage.FAILED;
      this.failure = '当前版本暂不支持应用内预览该格式，可用系统应用打开';
      return;
    }
    if (this.param.size > MAX_DOC_BYTES) {
      this.stage = DocStage.FAILED;
      this.failure = `文件超过 ${Fmt.size(MAX_DOC_BYTES)}，请用其他应用打开`;
      return;
    }
    try {
      const entry: FileEntry = {
        name: this.param.name,
        path: this.param.path,
        isDirectory: false,
        size: this.param.size,
        lastModified: 0,
        mimeType: '',
        kind: this.param.kind
      };
      const bytes: ArrayBuffer = await this.container.repository!.readDocument(source, entry, MAX_DOC_BYTES);
      if (bytes.byteLength === 0) {
        this.failWith('文件为空或无法读取');
        return;
      }
      this.docBytes = bytes;
      if (this.param.kind === PreviewKind.PDF) {
        this.viewerSrc = $rawfile('viewer/pdf/index.html');
        this.docMime = 'application/pdf';
        this.workerBytes = this.loadRawfile('viewer/pdf/pdf.worker.min.js');
      } else if (this.param.kind === PreviewKind.DOCX) {
        this.viewerSrc = $rawfile('viewer/docx/index.html');
        this.docMime = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      } else {
        this.viewerSrc = $rawfile('viewer/sheet/index.html');
        this.docMime = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      }
      this.stage = DocStage.READY;
    } catch (err) {
      Logger.error('DocPreviewPage', '读取文档失败', err as Error);
      this.failWith('缓存读写失败，或文件无法读取');
    }
  }

  private loadRawfile(path: string): ArrayBuffer {
    try {
      const context: common.UIAbilityContext = this.container.requireContext();
      const bytes: Uint8Array = context.resourceManager.getRawFileContentSync(path);
      return bytes.buffer as ArrayBuffer;
    } catch (err) {
      Logger.error('DocPreviewPage', `读取 rawfile 失败 ${path}`, err as Error);
      return new ArrayBuffer(0);
    }
  }

  private failWith(message: string): void {
    this.stage = DocStage.FAILED;
    this.failure = message;
  }

  private async openWithSystem(): Promise<void> {
    const context: common.UIAbilityContext = this.container.requireContext();
    const source: FileSource | null = this.container.findSource(this.param.sourceId);
    if (source === null) {
      promptAction.showToast({ message: '来源不存在' });
      return;
    }
    try {
      const localPath: string = await this.container.repository!.materializeToPath(source, {
        name: this.param.name,
        path: this.param.path,
        isDirectory: false,
        size: this.param.size,
        lastModified: 0,
        mimeType: '',
        kind: this.param.kind
      });
      const uri: string = localPath.startsWith('file://') ? localPath : fileUri.getUriFromPath(localPath);
      const want: Want = { action: 'ohos.want.action.viewData', uri: uri };
      await context.startAbility(want);
    } catch (err) {
      Logger.error('DocPreviewPage', '打开文档失败', err as Error);
      promptAction.showToast({ message: '没有应用可以打开这个文件' });
    }
  }

  build() {
    NavDestination() {
      Column() {
        if (this.stage === DocStage.READY) {
          DocumentWebView({
            src: this.viewerSrc,
            docBytes: this.docBytes,
            workerBytes: this.workerBytes,
            docMime: this.docMime,
            onFail: () => {
              this.failWith('无法渲染该文档，请用其他应用打开');
            }
          })
            .layoutWeight(1)
            .width('100%')
        } else if (this.stage === DocStage.READING) {
          Column({ space: 12 }) {
            LoadingProgress()
              .width(44)
              .height(44)
              .color($r('app.color.brand'))
            Text('正在准备文档…')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          this.fallbackView()
        }

        if (this.stage === DocStage.READY) {
          Row({ space: 8 }) {
            Text(`${this.kindLabel()} · ${Fmt.size(this.param.size)}`)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .layoutWeight(1)
            Button('用其他应用打开')
              .type(ButtonType.Capsule)
              .height(34)
              .backgroundColor($r('app.color.brand_soft'))
              .fontColor($r('app.color.brand'))
              .fontSize(12)
              .focusable(true)
              .onClick(() => {
                this.openWithSystem();
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.surface'))
    }
    .title('文档预览')
    .backgroundColor($r('app.color.surface'))
  }

  @Builder
  fallbackView() {
    Scroll() {
      Column({ space: 16 }) {
        Column() {
          SymbolGlyph(Symbols.forKind(this.param.kind))
            .fontSize(56)
            .fontColor([$r('app.color.brand')])
        }
        .width(96)
        .height(96)
        .borderRadius($r('app.float.radius_card'))
        .backgroundColor($r('app.color.brand_soft'))
        .justifyContent(FlexAlign.Center)

        Text(this.param.name)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .textAlign(TextAlign.Center)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(`${this.kindLabel()} · ${Fmt.size(this.param.size)}`)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))

        if (this.failure.length > 0) {
          Text(this.failure)
            .fontSize(13)
            .fontColor($r('app.color.brand'))
            .textAlign(TextAlign.Center)
            .padding({ left: 24, right: 24 })
        }

        Button('用其他应用打开')
          .type(ButtonType.Capsule)
          .height(46)
          .width('100%')
          .backgroundColor($r('app.color.brand'))
          .fontColor(Color.White)
          .focusable(true)
          .onClick(() => {
            this.openWithSystem();
          })

        Button('重试应用内预览')
          .type(ButtonType.Capsule)
          .height(40)
          .width('100%')
          .backgroundColor($r('app.color.surface_card'))
          .fontColor($r('app.color.text_primary'))
          .focusable(true)
          .onClick(() => {
            this.prepare();
          })
      }
      .width('100%')
      .padding(24)
      .alignItems(HorizontalAlign.Center)
    }
    .layoutWeight(1)
    .width('100%')
    .align(Alignment.Top)
  }
}
