import { SortMode } from './FileEntry';

export type ViewMode = 'list' | 'grid';

export interface AppSettings {
  viewMode: ViewMode;
  sortMode: SortMode;
  forceTvLayout: boolean;
  cacheLimitMb: number;
}

export class SettingsDefaults {
  static create(): AppSettings {
    return {
      viewMode: 'list',
      sortMode: 'nameAsc',
      forceTvLayout: false,
      cacheLimitMb: 512
    };
  }
}

export class SettingsValidation {
  static normalize(value: AppSettings): AppSettings {
    const out: AppSettings = SettingsDefaults.create();
    out.viewMode = value.viewMode === 'grid' ? 'grid' : 'list';
    out.sortMode = SettingsValidation.validSort(value.sortMode);
    out.forceTvLayout = value.forceTvLayout === true;
    const limit: number = Number(value.cacheLimitMb);
    out.cacheLimitMb = Number.isFinite(limit) && limit >= 64 ? Math.floor(limit) : 512;
    return out;
  }

  static validSort(mode: SortMode): SortMode {
    if (mode === 'nameDesc' || mode === 'sizeAsc' || mode === 'sizeDesc' || mode === 'dateAsc' ||
      mode === 'dateDesc') {
      return mode;
    }
    return 'nameAsc';
  }

  static sortLabel(mode: SortMode): string {
    switch (mode) {
      case 'nameDesc':
        return '名称降序';
      case 'sizeAsc':
        return '大小升序';
      case 'sizeDesc':
        return '大小降序';
      case 'dateAsc':
        return '时间升序';
      case 'dateDesc':
        return '时间降序';
      default:
        return '名称升序';
    }
  }
}
