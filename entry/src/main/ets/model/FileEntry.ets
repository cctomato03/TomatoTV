import { FileKinds, PreviewKind } from './FileKinds';

export interface FileEntry {
  name: string;
  path: string;
  isDirectory: boolean;
  size: number;
  lastModified: number;
  mimeType: string;
  kind: PreviewKind;
}

export interface DirectorySnapshot {
  path: string;
  entries: FileEntry[];
  scrollIndex: number;
  scrollOffset: number;
}

export interface BrowseState {
  loading: boolean;
  refreshing: boolean;
  path: string;
  entries: FileEntry[];
  error: string | null;
  permissionRequired: boolean;
}

export class FileEntryFactory {
  static empty(): FileEntry {
    return {
      name: '',
      path: '',
      isDirectory: false,
      size: 0,
      lastModified: 0,
      mimeType: '',
      kind: PreviewKind.OTHER
    };
  }

  static directory(name: string, path: string, lastModified: number): FileEntry {
    return {
      name: name,
      path: path,
      isDirectory: true,
      size: 0,
      lastModified: lastModified,
      mimeType: 'inode/directory',
      kind: PreviewKind.OTHER
    };
  }

  static file(name: string, path: string, size: number, lastModified: number, mimeHint: string): FileEntry {
    const kind: PreviewKind = FileKinds.kindOf(name);
    const mime: string = mimeHint.length > 0 && mimeHint !== 'application/octet-stream'
      ? mimeHint
      : FileKinds.mimeOfKind(kind, name);
    return {
      name: name,
      path: path,
      isDirectory: false,
      size: size,
      lastModified: lastModified,
      mimeType: mime,
      kind: kind
    };
  }
}

export type SortMode = 'nameAsc' | 'nameDesc' | 'sizeAsc' | 'sizeDesc' | 'dateAsc' | 'dateDesc';

export class FileSorter {
  /** 目录优先，然后按指定规则排序；使用 localeCompare 让中文名按拼音顺序 */
  static sort(entries: FileEntry[], mode: SortMode): FileEntry[] {
    const copy: FileEntry[] = entries.slice();
    copy.sort((a: FileEntry, b: FileEntry): number => {
      if (a.isDirectory !== b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      switch (mode) {
        case 'nameDesc':
          return b.name.localeCompare(a.name);
        case 'sizeAsc':
          return a.size - b.size;
        case 'sizeDesc':
          return b.size - a.size;
        case 'dateAsc':
          return a.lastModified - b.lastModified;
        case 'dateDesc':
          return b.lastModified - a.lastModified;
        default:
          return a.name.localeCompare(b.name);
      }
    });
    return copy;
  }
}
