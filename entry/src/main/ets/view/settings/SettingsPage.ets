import { promptAction } from '@kit.ArkUI';
import { AppContainer } from '../../app/AppContainer';
import { SettingsValidation, ViewMode } from '../../model/AppSettings';
import { SortMode } from '../../model/FileEntry';
import { BusKeys, EventBus } from '../../utils/EventBus';
import { Routes } from '../../navigation/AppNav';
import { Symbols } from '../../components/Symbols';
import { Layout } from '../../utils/Breakpoint';
import { WindowTheme } from '../../utils/WindowTheme';

const APP_VERSION: string = '1.0.0';

/** 设置（规范 §7.13） */
@Component
export struct SettingsPage {
  stack: NavPathStack = new NavPathStack();
  @State viewMode: ViewMode = 'list';
  @State sortMode: SortMode = 'nameAsc';
  @State forceTvLayout: boolean = false;
  @State cacheLimitMb: number = 512;
  private container: AppContainer = AppContainer.get();

  aboutToAppear(): void {
    WindowTheme.light();
    const settings = this.container.settings();
    this.viewMode = settings.viewMode;
    this.sortMode = settings.sortMode;
    this.forceTvLayout = settings.forceTvLayout;
    this.cacheLimitMb = settings.cacheLimitMb;
  }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: 20 }) {
          this.section('浏览')
          this.rowText('默认视图', this.viewMode === 'list' ? '列表' : '网格')
          Row({ space: 8 }) {
            Text('视图模式')
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
            Row({ space: 8 }) {
              Text('列表')
                .fontSize(13)
                .fontColor(this.viewMode === 'list' ? Color.White : $r('app.color.text_primary'))
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .backgroundColor(this.viewMode === 'list' ? $r('app.color.brand') : $r('app.color.surface'))
                .borderRadius(14)
                .focusable(true)
                .onClick(() => {
                  this.viewMode = 'list';
                  this.container.settingsStore.setViewMode('list');
                  EventBus.emit(BusKeys.SETTINGS_CHANGED);
                })
              Text('网格')
                .fontSize(13)
                .fontColor(this.viewMode === 'grid' ? Color.White : $r('app.color.text_primary'))
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .backgroundColor(this.viewMode === 'grid' ? $r('app.color.brand') : $r('app.color.surface'))
                .borderRadius(14)
                .focusable(true)
                .onClick(() => {
                  this.viewMode = 'grid';
                  this.container.settingsStore.setViewMode('grid');
                  EventBus.emit(BusKeys.SETTINGS_CHANGED);
                })
            }
          }
          .width('100%')
          .padding(12)
          .backgroundColor($r('app.color.surface_card'))
          .borderRadius($r('app.float.radius_small'))

          Select([{ value: '名称升序' }, { value: '名称降序' }, { value: '大小升序' }, { value: '大小降序' },
            { value: '时间升序' }, { value: '时间降序' }])
            .selected(this.sortIndex())
            .value(SettingsValidation.sortLabel(this.sortMode))
            .width('100%')
            .onSelect((index: number) => {
              const mode: SortMode = SettingsPage.sortAt(index);
              this.sortMode = mode;
              this.container.settingsStore.setSortMode(mode);
              EventBus.emit(BusKeys.SETTINGS_CHANGED);
            })

          this.section('大屏与智慧屏')
          Row({ space: 12 }) {
            Column({ space: 2 }) {
              Text('强制大屏布局')
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
              Text('按智慧屏形态显示：大卡片、焦点导航')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.forceTvLayout })
              .selectedColor($r('app.color.brand'))
              .onChange((isOn: boolean) => {
                this.forceTvLayout = isOn;
                this.container.settingsStore.setForceTvLayout(isOn);
                EventBus.emit(BusKeys.SETTINGS_CHANGED);
              })
          }
          .width('100%')
          .padding(12)
          .backgroundColor($r('app.color.surface_card'))
          .borderRadius($r('app.float.radius_small'))

          this.section('缓存')
          Row({ space: 12 }) {
            Column({ space: 2 }) {
              Text(`缓存上限 ${this.cacheLimitMb} MB`)
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
              Text('超出后按最近使用时间清理')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Button('管理')
              .type(ButtonType.Capsule)
              .height(36)
              .backgroundColor($r('app.color.brand_soft'))
              .fontColor($r('app.color.brand'))
              .focusable(true)
              .onClick(() => {
                this.stack.pushPathByName(Routes.CACHE, '');
              })
          }
          .width('100%')
          .padding(12)
          .backgroundColor($r('app.color.surface_card'))
          .borderRadius($r('app.float.radius_small'))

          Slider({ value: this.cacheLimitMb, min: 64, max: 4096, step: 64 })
            .width('100%')
            .selectedColor($r('app.color.brand'))
            .onChange((value: number, mode: SliderChangeMode) => {
              this.cacheLimitMb = Math.round(value);
              if (mode === SliderChangeMode.End) {
                this.container.settingsStore.setCacheLimitMb(value);
                this.container.cache?.pruneToLimit(value);
                promptAction.showToast({ message: `缓存上限已设为 ${Math.round(value)} MB` });
              }
            })

          this.section('关于')
          Column({ space: 6 }) {
            Row() {
              Text('TomatoTV')
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
              Text(`版本 ${APP_VERSION}`)
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            Text('HarmonyOS NEXT 原生实现的本地与网络文件管理器。开源许可：Apache-2.0')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          }
          .width('100%')
          .padding(12)
          .backgroundColor($r('app.color.surface_card'))
          .borderRadius($r('app.float.radius_small'))
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
    }
    .title('设置')
    .backgroundColor($r('app.color.surface'))
  }

  @Builder
  section(title: string) {
    Text(title)
      .fontSize(13)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
  }

  @Builder
  rowText(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      Text(value)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.surface_card'))
    .borderRadius($r('app.float.radius_small'))
  }

  private sortIndex(): number {
    const modes: SortMode[] = ['nameAsc', 'nameDesc', 'sizeAsc', 'sizeDesc', 'dateAsc', 'dateDesc'];
    for (let i = 0; i < modes.length; i++) {
      if (modes[i] === this.sortMode) {
        return i;
      }
    }
    return 0;
  }

  private static sortAt(index: number): SortMode {
    const modes: SortMode[] = ['nameAsc', 'nameDesc', 'sizeAsc', 'sizeDesc', 'dateAsc', 'dateDesc'];
    if (index < 0 || index >= modes.length) {
      return 'nameAsc';
    }
    return modes[index];
  }
}
