import { window } from '@kit.ArkUI';
import { AppContainer } from '../app/AppContainer';
import { Logger } from './Logger';

/**
 * 系统栏配色：让状态栏/导航栏颜色与当前页面背景一致。
 * 首页与普通页面用 surface（#FFFBF8），视频/图片页使用沉浸式黑底，音频页用播放器深色底。
 */
export class WindowTheme {
  private static mainWindow(): window.Window | null {
    const stage: window.WindowStage | null = AppContainer.get().windowStage();
    if (stage === null) {
      return null;
    }
    try {
      return stage.getMainWindowSync();
    } catch (err) {
      Logger.warn('WindowTheme', '获取主窗口失败');
      return null;
    }
  }

  private static apply(background: string, content: string): void {
    const win: window.Window | null = WindowTheme.mainWindow();
    if (win === null) {
      return;
    }
    const properties: window.SystemBarProperties = {
      statusBarColor: background,
      statusBarContentColor: content,
      navigationBarColor: background,
      navigationBarContentColor: content
    };
    win.setWindowSystemBarProperties(properties).catch((err: Error) => {
      Logger.warn('WindowTheme', '设置系统栏颜色失败');
    });
  }

  /** 普通页面：与 app.color.surface 一致 */
  static light(): void {
    WindowTheme.apply('#FFFBF8', '#241B18');
  }

  /** 深色页面：保留系统栏，颜色与页面背景一致 */
  static dark(background: string): void {
    WindowTheme.apply(background, '#FFFFFF');
  }

  /** 全屏播放/看图：隐藏状态栏和导航栏，内容铺满 */
  static immersive(background: string): void {
    const win: window.Window | null = WindowTheme.mainWindow();
    if (win === null) {
      return;
    }
    win.setWindowSystemBarEnable([]).catch((err: Error) => {
      Logger.warn('WindowTheme', '隐藏系统栏失败');
    });
    WindowTheme.apply(background, '#FFFFFF');
  }

  /** 退出全屏页面：恢复系统栏并回到普通页面配色 */
  static exitImmersive(): void {
    const win: window.Window | null = WindowTheme.mainWindow();
    if (win === null) {
      return;
    }
    win.setWindowSystemBarEnable(['status', 'navigation']).catch((err: Error) => {
      Logger.warn('WindowTheme', '恢复系统栏失败');
    });
    WindowTheme.light();
  }
}