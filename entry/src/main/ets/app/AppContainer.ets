import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { FileSource } from '../model/FileSource';
import { AppSettings } from '../model/AppSettings';
import { SettingsStore } from '../data/store/SettingsStore';
import { SourceStore } from '../data/store/SourceStore';
import { RemoteCache } from '../data/cache/RemoteCache';
import { FileRepository } from '../data/repo/FileRepository';
import { Logger } from '../utils/Logger';

/**
 * 应用级容器：持有 sourceStore / settingsStore / repository / cache（规范 §4 约定）。
 * 单例，由 EntryAbility 初始化。
 */
export class AppContainer {
  private static instance: AppContainer | null = null;

  private ctx: common.UIAbilityContext | null = null;
  private stage: window.WindowStage | null = null;

  settingsStore: SettingsStore = new SettingsStore();
  sourceStore: SourceStore = new SourceStore();
  cache: RemoteCache | null = null;
  repository: FileRepository | null = null;
  private ready: boolean = false;

  static get(): AppContainer {
    if (AppContainer.instance === null) {
      AppContainer.instance = new AppContainer();
    }
    return AppContainer.instance;
  }

  attach(context: common.UIAbilityContext): void {
    if (this.ready) {
      return;
    }
    this.ctx = context;
    try {
      const filesDir: string = context.filesDir;
      const cacheDir: string = context.cacheDir;
      this.cache = new RemoteCache(cacheDir);
      this.repository = new FileRepository(this.sourceStore, this.cache);
      this.settingsStore.init(context);
      this.sourceStore.init(context, filesDir);
      this.ready = true;
      Logger.info('AppContainer', '初始化完成');
    } catch (err) {
      Logger.error('AppContainer', '初始化失败', err as Error);
    }
  }

  isReady(): boolean {
    return this.ready;
  }

  context(): common.UIAbilityContext | null {
    return this.ctx;
  }

  requireContext(): common.UIAbilityContext {
    if (this.ctx === null) {
      throw new Error('AppContainer 尚未初始化');
    }
    return this.ctx;
  }

  attachWindowStage(stage: window.WindowStage): void {
    this.stage = stage;
  }

  detachWindowStage(): void {
    this.stage = null;
  }

  windowStage(): window.WindowStage | null {
    return this.stage;
  }

  settings(): AppSettings {
    return this.settingsStore.settings();
  }

  sources(): FileSource[] {
    return this.sourceStore.list();
  }

  findSource(id: string): FileSource | null {
    return this.sourceStore.find(id);
  }

  /** 来源变更后失效对应连接 */
  async invalidateSource(id: string): Promise<void> {
    if (this.repository !== null) {
      await this.repository.invalidate(id);
    }
  }

  async shutdown(): Promise<void> {
    if (this.repository !== null) {
      await this.repository.closeAll();
    }
  }
}
