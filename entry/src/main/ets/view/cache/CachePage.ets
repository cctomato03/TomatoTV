import { promptAction } from '@kit.ArkUI';
import { AppContainer } from '../../app/AppContainer';
import { CacheStats } from '../../data/cache/RemoteCache';
import { Fmt } from '../../utils/Format';
import { BusKeys, EventBus } from '../../utils/EventBus';
import { Symbols } from '../../components/Symbols';
import { EmptyState } from '../../components/EmptyState';
import { ImageMemoryCache } from '../../utils/ImageMemoryCache';
import { ThumbnailService } from '../../utils/ThumbnailService';
import { WindowTheme } from '../../utils/WindowTheme';

/** 缓存管理（规范 §7.12）：文件数、总大小、清理全部 */
@Component
export struct CachePage {
  @State fileCount: number = 0;
  @State totalBytes: number = 0;
  @State busy: boolean = false;
  private container: AppContainer = AppContainer.get();

  aboutToAppear(): void {
    WindowTheme.light();
    this.refresh();
  }

  private refresh(): void {
    const cache = this.container.cache;
    if (cache === null) {
      return;
    }
    const stats: CacheStats = cache.stats();
    this.fileCount = stats.fileCount;
    this.totalBytes = stats.totalBytes;
  }

  private clearAll(): void {
    AlertDialog.show({
      title: '清理缓存',
      message: '将删除全部远程文件缓存，不会影响存储配置。',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清理',
        fontColor: $r('app.color.brand'),
        action: () => {
          this.busy = true;
          const cache = this.container.cache;
          if (cache !== null) {
            cache.clearAll();
          }
          ImageMemoryCache.get().clearAll();
          ThumbnailService.get().clear();
          this.refresh();
          this.busy = false;
          EventBus.emit(BusKeys.CACHE_CHANGED);
          promptAction.showToast({ message: '缓存已清理' });
        }
      }
    });
  }

  build() {
    NavDestination() {
      Column({ space: 16 }) {
        Column({ space: 6 }) {
          Text(`${this.fileCount}`)
            .fontSize(40)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text('个缓存文件')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
          Text(`占用 ${Fmt.size(this.totalBytes)}`)
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .padding(24)
        .backgroundColor($r('app.color.surface_card'))
        .borderRadius($r('app.float.radius_card'))

        Button(this.busy ? '清理中…' : '清理全部缓存')
          .type(ButtonType.Capsule)
          .height(46)
          .width('100%')
          .backgroundColor($r('app.color.brand'))
          .fontColor(Color.White)
          .enabled(!this.busy)
          .focusable(true)
          .onClick(() => this.clearAll())

        Text('缓存只写入应用私有目录，清理后远程文件会在下次打开时重新加载。')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
      .width('100%')
      .height('100%')
      .padding(16)
      .alignItems(HorizontalAlign.Start)
    }
    .title('缓存')
    .backgroundColor($r('app.color.surface'))
  }
}
