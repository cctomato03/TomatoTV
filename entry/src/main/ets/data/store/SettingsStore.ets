import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppSettings, SettingsDefaults, SettingsValidation, ViewMode } from '../../model/AppSettings';
import { SortMode } from '../../model/FileEntry';
import { Logger } from '../../utils/Logger';

const STORE_NAME: string = 'tomato_settings';
const KEY_SETTINGS: string = 'settings_json';

export class SettingsStore {
  private prefs: preferences.Preferences | null = null;
  private current: AppSettings = SettingsDefaults.create();

  init(context: common.Context): void {
    try {
      this.prefs = preferences.getPreferencesSync(context, { name: STORE_NAME });
      this.reload();
    } catch (err) {
      Logger.error('SettingsStore', '初始化设置存储失败', err as Error);
      this.current = SettingsDefaults.create();
    }
  }

  reload(): void {
    if (this.prefs === null) {
      return;
    }
    try {
      const raw: preferences.ValueType = this.prefs.getSync(KEY_SETTINGS, '');
      if (typeof raw === 'string' && raw.length > 0) {
        const parsed: AppSettings = JSON.parse(raw) as AppSettings;
        this.current = SettingsValidation.normalize(parsed);
      }
    } catch (err) {
      Logger.error('SettingsStore', '读取设置失败', err as Error);
      this.current = SettingsDefaults.create();
    }
  }

  settings(): AppSettings {
    return this.current;
  }

  setViewMode(mode: ViewMode): void {
    this.current.viewMode = mode;
    this.persist();
  }

  setSortMode(mode: SortMode): void {
    this.current.sortMode = SettingsValidation.validSort(mode);
    this.persist();
  }

  setForceTvLayout(enabled: boolean): void {
    this.current.forceTvLayout = enabled;
    this.persist();
  }

  setCacheLimitMb(limitMb: number): void {
    const value: number = Math.floor(limitMb);
    this.current.cacheLimitMb = value < 64 ? 64 : value;
    this.persist();
  }

  private persist(): void {
    if (this.prefs === null) {
      return;
    }
    try {
      this.prefs.putSync(KEY_SETTINGS, JSON.stringify(this.current));
      this.prefs.flush().catch((err: BusinessError) => {
        Logger.error('SettingsStore', '写盘设置失败', err as Error);
      });
    } catch (err) {
      Logger.error('SettingsStore', '保存设置失败', err as Error);
    }
  }
}
