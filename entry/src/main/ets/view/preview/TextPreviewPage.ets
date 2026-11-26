import { AppContainer } from '../../app/AppContainer';
import { FileSource } from '../../model/FileSource';
import { DocParam, NavDefaults } from '../../navigation/AppNav';
import { FsError, FsErrorKind, FsErrorText } from '../../data/fs/FileSystemClient';
import { Fmt } from '../../utils/Format';
import { Logger } from '../../utils/Logger';
import { EmptyState } from '../../components/EmptyState';
import { Symbols } from '../../components/Symbols';

const MAX_TEXT_BYTES: number = 4 * 1024 * 1024;

/** 文本预览（规范 §7.6）：等宽字体、编码探测、大文件提示 */
@Component
export struct TextPreviewPage {
  stack: NavPathStack = new NavPathStack();
  param: DocParam = NavDefaults.doc();

  @State content: string = '';
  @State loading: boolean = true;
  @State errorText: string = '';
  @State truncated: boolean = false;
  private container: AppContainer = AppContainer.get();

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    const source: FileSource | null = this.container.findSource(this.param.sourceId);
    if (source === null) {
      this.loading = false;
      this.errorText = FsErrorText.NOT_FOUND;
      return;
    }
    this.loading = true;
    this.errorText = '';
    try {
      this.content = await this.container.repository!.readText(source, this.param.path, MAX_TEXT_BYTES);
      this.truncated = this.param.size > MAX_TEXT_BYTES;
    } catch (err) {
      if (err instanceof FsError) {
        this.errorText = FsErrorText.of(err.kind);
      } else {
        this.errorText = FsErrorText.NETWORK;
      }
      Logger.error('TextPreviewPage', '读取文本失败', err as Error);
    } finally {
      this.loading = false;
    }
  }

  build() {
    NavDestination() {
      Column() {
        Row({ space: 8 }) {
          Text(this.param.name)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(Fmt.size(this.param.size))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })

        if (this.truncated) {
          Text('文件较大，仅显示前 4MB 内容')
            .fontSize(12)
            .fontColor($r('app.color.brand'))
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 8 })
        }

        if (this.loading) {
          Column({ space: 12 }) {
            LoadingProgress().width(40).height(40).color($r('app.color.brand'))
            Text('正在读取文件…').fontSize(13).fontColor($r('app.color.text_secondary'))
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.errorText.length > 0) {
          EmptyState({ icon: Symbols.info(), title: this.errorText })
        } else {
          Scroll() {
            Text(this.content)
              .fontSize(13)
              .fontFamily('HarmonyOS Sans Mono')
              .fontColor($r('app.color.text_primary'))
              .textAlign(TextAlign.Start)
              .padding(16)
              .width('100%')
              .copyOption(CopyOptions.LocalDevice)
          }
          .layoutWeight(1)
          .width('100%')
          .align(Alignment.Top)
          .scrollBar(BarState.Auto)
        }
      }
      .width('100%')
      .height('100%')
    }
    .title('文本预览')
    .backgroundColor($r('app.color.surface'))
  }
}
