import { Breakpoint, Layout } from '../utils/Breakpoint';
import { BusKeys, EventBus } from '../utils/EventBus';
import { AppContainer } from '../app/AppContainer';
import { BrowseParam, DocParam, MediaParam, Routes, SourceEditParam } from '../navigation/AppNav';
import { HomePage } from '../view/home/HomePage';
import { BrowsePage } from '../view/browse/BrowsePage';
import { SourceEditPage } from '../view/source/SourceEditPage';
import { SettingsPage } from '../view/settings/SettingsPage';
import { CachePage } from '../view/cache/CachePage';
import { TextPreviewPage } from '../view/preview/TextPreviewPage';
import { DocPreviewPage } from '../view/preview/DocPreviewPage';
import { FileInfoPage } from '../view/preview/FileInfoPage';
import { ImageViewerPage } from '../view/image/ImageViewerPage';
import { VideoPlayerPage } from '../view/video/VideoPlayerPage';
import { AudioPlayerPage } from '../view/audio/AudioPlayerPage';
import { Logger } from '../utils/Logger';

@Entry
@Component
struct Index {
  private stack: NavPathStack = new NavPathStack();
  @State breakpoint: Breakpoint = Breakpoint.SM;
  @State forceTv: boolean = false;
  private onSettingsChanged: () => void = () => {
    this.applySettings();
  };

  aboutToAppear(): void {
    this.applySettings();
    EventBus.on(BusKeys.SETTINGS_CHANGED, this.onSettingsChanged);
  }

  aboutToDisappear(): void {
    EventBus.off(BusKeys.SETTINGS_CHANGED, this.onSettingsChanged);
    AppContainer.get().shutdown();
  }

  private applySettings(): void {
    try {
      this.forceTv = AppContainer.get().settings().forceTvLayout;
    } catch (err) {
      Logger.warn('Index', '读取设置失败');
    }
  }

  build() {
    Navigation(this.stack) {
      HomePage({ stack: this.stack, breakpoint: this.breakpoint })
    }
    .navDestination(this.pageMap)
    .mode(Layout.useSplit(this.breakpoint) ? NavigationMode.Split : NavigationMode.Stack)
    .hideTitleBar(true)
    .navBarWidth(this.breakpoint === Breakpoint.TV ? 320 : 300)
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.surface'))
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const width: number = Number(newValue.width);
      if (Number.isFinite(width) && width > 0) {
        this.breakpoint = Layout.ofWidth(width, this.forceTv);
      }
    })
  }

  @Builder
  pageMap(name: string, param: object) {
    if (name === Routes.BROWSE) {
      BrowsePage({ stack: this.stack, param: param as BrowseParam, breakpoint: this.breakpoint })
    } else if (name === Routes.SOURCE_EDIT) {
      SourceEditPage({ stack: this.stack, param: param as SourceEditParam })
    } else if (name === Routes.SETTINGS) {
      SettingsPage({ stack: this.stack })
    } else if (name === Routes.CACHE) {
      CachePage()
    } else if (name === Routes.TEXT_PREVIEW) {
      TextPreviewPage({ stack: this.stack, param: param as DocParam })
    } else if (name === Routes.DOC_PREVIEW) {
      DocPreviewPage({ stack: this.stack, param: param as DocParam })
    } else if (name === Routes.FILE_INFO) {
      FileInfoPage({ stack: this.stack, param: param as DocParam })
    } else if (name === Routes.IMAGE_VIEWER) {
      ImageViewerPage({ stack: this.stack, param: param as MediaParam })
    } else if (name === Routes.VIDEO) {
      VideoPlayerPage({ stack: this.stack, param: param as MediaParam })
    } else if (name === Routes.AUDIO) {
      AudioPlayerPage({ stack: this.stack, param: param as MediaParam })
    }
  }
}
