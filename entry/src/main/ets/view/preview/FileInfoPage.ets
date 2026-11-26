import { promptAction } from '@kit.ArkUI';
import { common, Want } from '@kit.AbilityKit';
import { fileUri } from '@kit.CoreFileKit';
import { AppContainer } from '../../app/AppContainer';
import { FileSource } from '../../model/FileSource';
import { FileKinds } from '../../model/FileKinds';
import { DocParam, NavDefaults } from '../../navigation/AppNav';
import { Fmt } from '../../utils/Format';
import { Symbols } from '../../components/Symbols';
import { Logger } from '../../utils/Logger';

/** 文件信息 + 系统“打开方式”（规范 §6 其他类型路由） */
@Component
export struct FileInfoPage {
  stack: NavPathStack = new NavPathStack();
  param: DocParam = NavDefaults.doc();
  private container: AppContainer = AppContainer.get();

  private async openWithSystem(): Promise<void> {
    const context: common.UIAbilityContext = this.container.requireContext();
    const source: FileSource | null = this.container.findSource(this.param.sourceId);
    if (source === null) {
      promptAction.showToast({ message: '来源不存在' });
      return;
    }
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
      const want: Want = { action: 'ohos.want.action.viewData', uri: uri };
      await context.startAbility(want);
    } catch (err) {
      Logger.error('FileInfoPage', '打开文件失败', err as Error);
      promptAction.showToast({ message: '没有应用可以打开这个文件' });
    }
  }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: 12 }) {
          Column({ space: 8 }) {
            SymbolGlyph(Symbols.forKind(this.param.kind))
              .fontSize(28)
              .fontColor([$r('app.color.brand')])
            Text(this.param.name)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .padding(24)
          .backgroundColor($r('app.color.surface_card'))
          .borderRadius($r('app.float.radius_card'))

          this.infoRow('类型', FileKinds.kindOf(this.param.name))
          this.infoRow('大小', Fmt.size(this.param.size))
          this.infoRow('路径', this.param.path)

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
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
    }
    .title('文件信息')
    .backgroundColor($r('app.color.surface'))
  }

  @Builder
  infoRow(label: string, value: string) {
    Column({ space: 4 }) {
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
      Text(value)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .copyOption(CopyOptions.LocalDevice)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor($r('app.color.surface_card'))
    .borderRadius($r('app.float.radius_small'))
  }
}
