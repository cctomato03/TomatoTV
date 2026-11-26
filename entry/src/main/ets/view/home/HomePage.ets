import { promptAction } from '@kit.ArkUI';
import { AppContainer } from '../../app/AppContainer';
import { FileSource, SourceType } from '../../model/FileSource';
import { Breakpoint, Layout } from '../../utils/Breakpoint';
import { BusKeys, EventBus } from '../../utils/EventBus';
import { BrowseParam, Routes, SourceEditParam } from '../../navigation/AppNav';
import { EmptyState } from '../../components/EmptyState';
import { SourceCard } from '../../components/SourceCard';
import { Symbols } from '../../components/Symbols';
import { Logger } from '../../utils/Logger';

/** 首页（规范 §7.2）：标题 + 来源卡片 + 固定“添加存储”主按钮 */
@Component
export struct HomePage {
  stack: NavPathStack = new NavPathStack();
  @Prop breakpoint: Breakpoint = Breakpoint.SM;
  @State sources: FileSource[] = [];
  @State tvMode: boolean = false;
  private container: AppContainer = AppContainer.get();
  private onSourcesChanged: () => void = () => {
    this.reload();
  };

  aboutToAppear(): void {
    this.reload();
    EventBus.on(BusKeys.SOURCES_CHANGED, this.onSourcesChanged);
  }

  aboutToDisappear(): void {
    EventBus.off(BusKeys.SOURCES_CHANGED, this.onSourcesChanged);
  }

  private reload(): void {
    try {
      this.sources = this.container.sources();
      this.tvMode = this.container.settings().forceTvLayout;
    } catch (err) {
      Logger.error('HomePage', '读取来源失败', err as Error);
    }
  }

  private openSource(source: FileSource): void {
    const param: BrowseParam = { sourceId: source.id, path: '', title: source.name };
    this.stack.pushPathByName(Routes.BROWSE, param);
  }

  private editSource(source: FileSource): void {
    const param: SourceEditParam = { sourceId: source.id, initialType: source.type, isNew: false };
    this.stack.pushPathByName(Routes.SOURCE_EDIT, param);
  }

  private addSource(): void {
    const param: SourceEditParam = { sourceId: '', initialType: SourceType.LOCAL, isNew: true };
    this.stack.pushPathByName(Routes.SOURCE_EDIT, param);
  }

  private openSettings(): void {
    this.stack.pushPathByName(Routes.SETTINGS, '');
  }

  private confirmDelete(source: FileSource): void {
    AlertDialog.show({
      title: '删除存储',
      message: `确定删除「${source.name}」？该操作不会删除远端文件。`,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.brand'),
        action: () => {
          this.deleteSource(source);
        }
      }
    });
  }

  private deleteSource(source: FileSource): void {
    this.container.sourceStore.remove(source.id).then(() => {
      this.container.invalidateSource(source.id).then(() => {
        this.reload();
        EventBus.emit(BusKeys.SOURCES_CHANGED);
        promptAction.showToast({ message: '已删除' });
      });
    }).catch((err: Error) => {
      Logger.error('HomePage', '删除来源失败', err);
      promptAction.showToast({ message: '删除失败，请稍后重试' });
    });
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text('TomatoTV')
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text('本地与网络文件')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .alignItems(HorizontalAlign.Start)

        Blank()

        Button({ type: ButtonType.Circle }) {
          SymbolGlyph(Symbols.settings())
            .fontSize(20)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(44)
        .height(44)
        .backgroundColor($r('app.color.surface_card'))
        .focusable(true)
        .onClick(() => this.openSettings())
        .accessibilityText('设置')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      if (this.sources.length === 0) {
        EmptyState({
          icon: Symbols.folder(),
          title: '还没有存储',
          description: '添加本机目录或 WebDAV、SMB、FTP 网络存储后即可浏览文件',
          actionLabel: '添加存储',
          onAction: () => this.addSource()
        })
      } else {
        List({ space: 12 }) {
          ForEach(this.sources, (item: FileSource) => {
            ListItem() {
              SourceCard({
                source: item,
                tvMode: Layout.focusDriven(this.breakpoint, this.tvMode),
                onOpen: (source: FileSource) => this.openSource(source),
                onEdit: (source: FileSource) => this.editSource(source),
                onLongPressMenu: (source: FileSource) => this.confirmDelete(source)
              })
            }
            .padding({ left: 16, right: 16 })
          }, (item: FileSource) => item.id)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .cachedCount(6)
      }

      Row() {
        Button('添加存储')
          .type(ButtonType.Capsule)
          .height(48)
          .width('100%')
          .backgroundColor($r('app.color.brand'))
          .fontColor(Color.White)
          .focusable(true)
          .onClick(() => this.addSource())
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.surface'))
  }
}
