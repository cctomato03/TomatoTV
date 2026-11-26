import { promptAction } from '@kit.ArkUI';
import { common, Want } from '@kit.AbilityKit';
import { fileUri } from '@kit.CoreFileKit';
import { AppContainer } from '../../app/AppContainer';
import { FileSource, SourceType } from '../../model/FileSource';
import { PreviewKind } from '../../model/FileKinds';
import { DocParam, NavDefaults } from '../../navigation/AppNav';
import { Fmt } from '../../utils/Format';
import { Symbols } from '../../components/Symbols';
import { Logger } from '../../utils/Logger';

/**
 * PDF / Office 预览（规范 §7.7、§7.8）。
 *
 * 当前 SDK（API 12 公开版）没有可用的系统 PDF / Office 预览 Kit，
 * 首版提供：文件信息 + 系统“打开方式”，并在交付说明中记录该限制。
 */
@Component
export struct DocPreviewPage {
  stack: NavPathStack = new NavPathStack();
  param: DocParam = NavDefaults.doc();
  @State resolving: boolean = false;
  private container: AppContainer = AppContainer.get();

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

  private async openWithSystem(): Promise<void> {
    const context: common.UIAbilityContext = this.container.requireContext();
    const source: FileSource | null = this.container.findSource(this.param.sourceId);
    if (source === null) {
      promptAction.showToast({ message: '来源不存在' });
      return;
    }
    this.resolving = true;
    try {
      const localPath: string = await this.container.repository!.materializeToPath(source,
        {
          name: this.param.name,
          path: this.param.path,
          isDirectory: false,
          size: this.param.size,
          lastModified: 0,
          mimeType: '',
          kind: this.param.kind
        });
      const uri: string = localPath.startsWith('file://') ? localPath : fileUri.getUriFromPath(localPath);
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: uri
      };
      await context.startAbility(want);
    } catch (err) {
      Logger.error('DocPreviewPage', '打开文档失败', err as Error);
      promptAction.showToast({ message: '没有应用可以打开这个文件' });
    } finally {
      this.resolving = false;
    }
  }

  build() {
    NavDestination() {
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
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .textAlign(TextAlign.Center)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Text(`${this.kindLabel()} · ${Fmt.size(this.param.size)}`)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))

          Button(this.resolving ? '准备中…' : '用其他应用打开')
            .type(ButtonType.Capsule)
            .height(46)
            .width('100%')
            .backgroundColor($r('app.color.brand'))
            .fontColor(Color.White)
            .enabled(!this.resolving)
            .focusable(true)
            .onClick(() => {
              this.openWithSystem();
            })

          Column({ space: 6 }) {
            Text('关于应用内预览')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            Text('当前 SDK 未提供系统 PDF / Office 渲染能力。首版通过系统“打开方式”交给已安装的办公应用处理；' +
              '后续版本计划在应用内离线渲染（Web + 本地渲染库）。')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.surface_card'))
          .borderRadius($r('app.float.radius_card'))
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
    }
    .title('文档预览')
    .backgroundColor($r('app.color.surface'))
  }
}
