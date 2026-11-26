import { promptAction } from '@kit.ArkUI';
import { AppContainer } from '../../app/AppContainer';
import { FileEntry, FileEntryFactory, FileSorter, SortMode } from '../../model/FileEntry';
import { PreviewKind } from '../../model/FileKinds';
import { FileSource, SourceFactory, SourceType } from '../../model/FileSource';
import { ThumbnailService } from '../../utils/ThumbnailService';
import { SettingsValidation, ViewMode } from '../../model/AppSettings';
import { FsError, FsErrorKind, FsErrorText } from '../../data/fs/FileSystemClient';
import { Breakpoint, Layout } from '../../utils/Breakpoint';
import { BusKeys, EventBus } from '../../utils/EventBus';
import { BrowseParam, DocParam, MediaParam, NavDefaults, Routes, SourceEditParam } from '../../navigation/AppNav';
import { EmptyState } from '../../components/EmptyState';
import { FileRow, FileTile } from '../../components/FileRow';
import { Symbols } from '../../components/Symbols';
import { Logger } from '../../utils/Logger';

interface TrailItem {
  name: string;
  path: string;
}

interface Snap {
  path: string;
  entries: FileEntry[];
  scrollIndex: number;
  trail: TrailItem[];
}

const MAX_SNAPSHOTS: number = 32;

/** 浏览页（规范 §7.3）：面包屑、排序、列表/网格、刷新、三级状态、目录历史与滚动恢复 */
@Component
export struct BrowsePage {
  stack: NavPathStack = new NavPathStack();
  param: BrowseParam = NavDefaults.browse();
  @Prop breakpoint: Breakpoint = Breakpoint.SM;

  @State entries: FileEntry[] = [];
  @State loading: boolean = true;
  @State refreshing: boolean = false;
  @State errorText: string = '';
  @State errorDetail: string = '';
  @State permissionRequired: boolean = false;
  @State currentPath: string = '';
  @State viewMode: ViewMode = 'list';
  @State sortMode: SortMode = 'nameAsc';
  @State trail: TrailItem[] = [];
  @State tvMode: boolean = false;

  private container: AppContainer = AppContainer.get();
  private sourceRef: FileSource = SourceFactory.blank(SourceType.LOCAL);
  private scroller: Scroller = new Scroller();
  private snapshots: Snap[] = [];
  private firstVisible: number = 0;
  private onSettingsChanged: () => void = () => {
    this.applySettings();
  };

  aboutToAppear(): void {
    this.applySettings();
    const source: FileSource | null = this.container.findSource(this.param.sourceId);
    if (source !== null) {
      this.sourceRef = source;
    }
    const rootPath: string = source === null ? '' : BrowsePage.rootPathOf(source);
    this.currentPath = this.param.path.length > 0 ? this.param.path : rootPath;
    this.trail = [{ name: source === null ? this.param.title : source.name, path: rootPath }];
    this.load(this.currentPath, false);
    EventBus.on(BusKeys.SETTINGS_CHANGED, this.onSettingsChanged);
  }

  aboutToDisappear(): void {
    EventBus.off(BusKeys.SETTINGS_CHANGED, this.onSettingsChanged);
    this.snapshots = [];
    ThumbnailService.get().clear();
  }

  private static rootPathOf(source: FileSource): string {
    if (source.type === SourceType.LOCAL) {
      return source.localUri;
    }
    return '/';
  }

  private applySettings(): void {
    const settings = this.container.settings();
    this.viewMode = settings.viewMode;
    this.sortMode = settings.sortMode;
    this.tvMode = settings.forceTvLayout;
  }

  private async load(path: string, keepOld: boolean): Promise<void> {
    const source: FileSource | null = this.container.findSource(this.param.sourceId);
    if (source === null) {
      this.loading = false;
      this.errorText = FsErrorText.NOT_FOUND;
      return;
    }
    if (keepOld) {
      this.refreshing = true;
    } else {
      this.loading = true;
      this.entries = [];
    }
    this.errorText = '';
    this.errorDetail = '';
    this.permissionRequired = false;
    try {
      const list: FileEntry[] = await this.container.repository!.list(source, path);
      this.entries = FileSorter.sort(list, this.sortMode);
      this.currentPath = path;
      if (keepOld) {
        promptAction.showToast({ message: '已刷新' });
      }
    } catch (err) {
      this.handleError(err as Error);
    } finally {
      this.loading = false;
      this.refreshing = false;
    }
  }

  private handleError(err: Error): void {
    this.entries = [];
    if (err instanceof FsError) {
      if (err.kind === FsErrorKind.UNSUPPORTED) {
        this.errorText = err.message;
        this.errorDetail = '';
        return;
      }
      this.permissionRequired = err.kind === FsErrorKind.PERMISSION;
      this.errorText = FsErrorText.of(err.kind);
      // 保留协议层细节（状态码 / 出错命令），便于用户反馈与真机定位
      this.errorDetail = err.message;
      Logger.error('BrowsePage', err.message, err as Error);
      return;
    }
    this.errorText = FsErrorText.NETWORK;
    this.errorDetail = err.message;
    Logger.error('BrowsePage', '列目录异常', err);
  }

  private pushSnapshot(): void {
    if (this.snapshots.length >= MAX_SNAPSHOTS) {
      this.snapshots.shift();
    }
    const trailCopy: TrailItem[] = [];
    for (const item of this.trail) {
      trailCopy.push({ name: item.name, path: item.path });
    }
    this.snapshots.push({
      path: this.currentPath,
      entries: this.entries.slice(),
      scrollIndex: this.firstVisible,
      trail: trailCopy
    });
  }

  private restoreSnapshot(): boolean {
    if (this.snapshots.length === 0) {
      return false;
    }
    const snap: Snap = this.snapshots.pop() as Snap;
    this.currentPath = snap.path;
    this.entries = snap.entries;
    this.trail = snap.trail;
    this.errorText = '';
    this.loading = false;
    const index: number = snap.scrollIndex;
    setTimeout(() => {
      try {
        if (index > 0) {
          this.scroller.scrollToIndex(index);
        } else {
          this.scroller.scrollEdge(Edge.Top);
        }
      } catch (err) {
        Logger.warn('BrowsePage', '恢复滚动位置失败');
      }
    }, 30);
    return true;
  }

  private openEntry(entry: FileEntry): void {
    if (entry.isDirectory) {
      this.pushSnapshot();
      this.trail = this.trail.concat([{ name: entry.name, path: entry.path }]);
      this.load(entry.path, false);
      return;
    }
    if (entry.kind === PreviewKind.VIDEO || entry.kind === PreviewKind.AUDIO) {
      const param: MediaParam = {
        sourceId: this.param.sourceId,
        path: entry.path,
        name: entry.name,
        kind: entry.kind,
        size: entry.size
      };
      this.stack.pushPathByName(entry.kind === PreviewKind.VIDEO ? Routes.VIDEO : Routes.AUDIO, param);
      return;
    }
    if (entry.kind === PreviewKind.IMAGE) {
      const param: MediaParam = {
        sourceId: this.param.sourceId,
        path: entry.path,
        name: entry.name,
        kind: entry.kind,
        size: entry.size
      };
      this.stack.pushPathByName(Routes.IMAGE_VIEWER, param);
      return;
    }
    if (entry.kind === PreviewKind.TEXT) {
      const param: DocParam = {
        sourceId: this.param.sourceId,
        path: entry.path,
        name: entry.name,
        kind: entry.kind,
        size: entry.size
      };
      this.stack.pushPathByName(Routes.TEXT_PREVIEW, param);
      return;
    }
    if (entry.kind === PreviewKind.PDF || entry.kind === PreviewKind.DOCX || entry.kind === PreviewKind.XLSX ||
      entry.kind === PreviewKind.PPTX) {
      const param: DocParam = {
        sourceId: this.param.sourceId,
        path: entry.path,
        name: entry.name,
        kind: entry.kind,
        size: entry.size
      };
      this.stack.pushPathByName(Routes.DOC_PREVIEW, param);
      return;
    }
    const info: DocParam = {
      sourceId: this.param.sourceId,
      path: entry.path,
      name: entry.name,
      kind: entry.kind,
      size: entry.size
    };
    this.stack.pushPathByName(Routes.FILE_INFO, info);
  }

  private jumpTo(item: TrailItem, index: number): void {
    if (index === this.trail.length - 1) {
      return;
    }
    this.snapshots = [];
    this.trail = this.trail.slice(0, index + 1);
    this.load(item.path, false);
  }

  private changeSort(mode: SortMode): void {
    this.sortMode = mode;
    this.container.settingsStore.setSortMode(mode);
    this.entries = FileSorter.sort(this.entries, mode);
    this.scroller.scrollEdge(Edge.Top);
  }

  private toggleView(): void {
    const next: ViewMode = this.viewMode === 'list' ? 'grid' : 'list';
    this.viewMode = next;
    this.container.settingsStore.setViewMode(next);
  }

  build() {
    NavDestination() {
      Column() {
        this.header()

        if (this.refreshing) {
          Progress({ value: 100, total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(2)
            .color($r('app.color.brand'))
        }

        if (this.loading) {
          this.loadingView()
        } else if (this.errorText.length > 0) {
          this.errorView()
        } else if (this.entries.length === 0) {
          EmptyState({
            icon: Symbols.folder(),
            title: FsErrorText.EMPTY,
            description: '这个目录下没有可显示的内容'
          })
        } else if (this.viewMode === 'grid') {
          this.gridView()
        } else {
          this.listView()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.surface'))
    }
    .hideTitleBar(true)
    .onBackPressed((): boolean => {
      if (this.restoreSnapshot()) {
        return true;
      }
      return false;
    })
  }

  @Builder
  header() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph(Symbols.back())
            .fontSize(20)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(40)
        .height(40)
        .backgroundColor($r('app.color.surface_card'))
        .focusable(true)
        .onClick((): void => {
          if (!this.restoreSnapshot()) {
            this.stack.pop();
          }
        })

        Text(this.trail.length > 0 ? this.trail[this.trail.length - 1].name : this.param.title)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Button({ type: ButtonType.Circle }) {
          SymbolGlyph(this.viewMode === 'list' ? Symbols.grid() : Symbols.list())
            .fontSize(18)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(40)
        .height(40)
        .backgroundColor($r('app.color.surface_card'))
        .focusable(true)
        .onClick(() => this.toggleView())
        .accessibilityText('切换视图')

        Button({ type: ButtonType.Circle }) {
          SymbolGlyph(Symbols.refresh())
            .fontSize(18)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(40)
        .height(40)
        .backgroundColor($r('app.color.surface_card'))
        .focusable(true)
        .onClick(() => {
          this.load(this.currentPath, true);
        })
        .accessibilityText('刷新')
      }
      .width('100%')

      Scroll() {
        Row({ space: 4 }) {
          ForEach(this.trail, (item: TrailItem, index: number) => {
            Row({ space: 2 }) {
              Text(item.name)
                .fontSize(13)
                .fontColor(index === this.trail.length - 1 ? $r('app.color.brand') :
                  $r('app.color.text_secondary'))
                .maxLines(1)
                .padding({ left: 4, right: 4, top: 2, bottom: 2 })
                .onClick(() => this.jumpTo(item, index))
              if (index < this.trail.length - 1) {
                SymbolGlyph(Symbols.forward())
                  .fontSize(10)
                  .fontColor([$r('app.color.text_tertiary')])
              }
            }
          }, (item: TrailItem, index: number) => `${item.path}_${index}`)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')

      Row({ space: 8 }) {
        Text(`${this.entries.length} 项`)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
        Blank()
        Text(SettingsValidation.sortLabel(this.sortMode))
          .fontSize(12)
          .fontColor($r('app.color.brand'))
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor($r('app.color.brand_soft'))
          .borderRadius(10)
          .focusable(true)
          .bindMenu(this.sortMenu())
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
  }

  @Builder
  sortMenu() {
    Menu() {
      MenuItem({ content: '名称升序' }).onClick(() => this.changeSort('nameAsc'))
      MenuItem({ content: '名称降序' }).onClick(() => this.changeSort('nameDesc'))
      MenuItem({ content: '大小升序' }).onClick(() => this.changeSort('sizeAsc'))
      MenuItem({ content: '大小降序' }).onClick(() => this.changeSort('sizeDesc'))
      MenuItem({ content: '时间升序' }).onClick(() => this.changeSort('dateAsc'))
      MenuItem({ content: '时间降序' }).onClick(() => this.changeSort('dateDesc'))
    }
  }

  @Builder
  loadingView() {
    Column({ space: 12 }) {
      LoadingProgress()
        .width(48)
        .height(48)
        .color($r('app.color.brand'))
      Text('正在读取目录…')
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  errorView() {
    Column({ space: 12 }) {
      SymbolGlyph(Symbols.info())
        .fontSize(40)
        .fontColor([$r('app.color.text_tertiary')])
      Text(this.errorText)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .textAlign(TextAlign.Center)
        .padding({ left: 32, right: 32 })
      if (this.permissionRequired && this.sourceRef.type === SourceType.LOCAL) {
        Text('HarmonyOS 不允许应用直接读取全部存储，目录访问需要在"选择目录"时授权；' +
          '如果授权失效（重装、清除数据或目录被移动），请重新选择一次目录。')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)
          .padding({ left: 32, right: 32 })
      }
      if (this.errorDetail.length > 0) {
        Text(this.errorDetail)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .textAlign(TextAlign.Center)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: 32, right: 32 })
      }
      Row({ space: 12 }) {
        Button('重试')
          .type(ButtonType.Capsule)
          .height(40)
          .backgroundColor($r('app.color.brand'))
          .fontColor(Color.White)
          .focusable(true)
          .onClick(() => {
            this.load(this.currentPath, false);
          })
        if (this.permissionRequired && this.sourceRef.type === SourceType.LOCAL) {
          Button('重新选择目录')
            .type(ButtonType.Capsule)
            .height(40)
            .backgroundColor($r('app.color.brand'))
            .fontColor(Color.White)
            .focusable(true)
            .onClick(() => {
              const param: SourceEditParam = {
                sourceId: this.param.sourceId,
                initialType: SourceType.LOCAL,
                isNew: false
              };
              this.stack.pushPathByName(Routes.SOURCE_EDIT, param);
            })
        }
        if (!this.restoreSnapshotAllowed()) {
          Button('返回')
            .type(ButtonType.Capsule)
            .height(40)
            .backgroundColor($r('app.color.surface_card'))
            .fontColor($r('app.color.text_primary'))
            .focusable(true)
            .onClick(() => {
              this.stack.pop();
            })
        }
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  private restoreSnapshotAllowed(): boolean {
    return this.snapshots.length > 0;
  }

  @Builder
  listView() {
    Refresh({ refreshing: $$this.refreshing }) {
      List({ space: 2, scroller: this.scroller }) {
        ForEach(this.entries, (item: FileEntry, index: number) => {
          ListItem() {
            FileRow({
              entry: item,
              source: this.sourceRef,
              tvMode: Layout.focusDriven(this.breakpoint, this.tvMode),
              autoFocus: index === 0
            })
          }
          .onClick(() => this.openEntry(item))
        }, (item: FileEntry) => item.path)
      }
      .width('100%')
      .height('100%')
      .cachedCount(12)
      .scrollBar(BarState.Auto)
      .onScrollIndex((start: number) => {
        this.firstVisible = start;
      })
    }
    .layoutWeight(1)
    .onRefreshing(() => {
      this.load(this.currentPath, true);
    })
  }

  @Builder
  gridView() {
    Grid() {
      ForEach(this.entries, (item: FileEntry, index: number) => {
        GridItem() {
          FileTile({
            entry: item,
            source: this.sourceRef,
            tvMode: Layout.focusDriven(this.breakpoint, this.tvMode),
            autoFocus: index === 0
          })
        }
        .onClick(() => this.openEntry(item))
      }, (item: FileEntry) => item.path)
    }
    .columnsTemplate(this.gridTemplate())
    .columnsGap(12)
    .rowsGap(12)
    .padding({ left: 12, right: 12 })
    .layoutWeight(1)
    .scrollBar(BarState.Auto)
  }

  private gridTemplate(): string {
    const columns: number = Layout.gridColumns(this.breakpoint);
    let template: string = '';
    for (let i = 0; i < columns; i++) {
      template += i === 0 ? '1fr' : ' 1fr';
    }
    return template;
  }
}
