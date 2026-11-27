import { common } from '@kit.AbilityKit';
import { fileShare } from '@kit.CoreFileKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { FileSource, SourceFactory, SourceType } from '../../model/FileSource';
import { SecretStore } from '../crypto/SecretStore';
import { SecretResolver } from '../repo/SecretResolver';
import { Logger } from '../../utils/Logger';

const STORE_NAME: string = 'tomato_sources';
const KEY_SOURCES: string = 'sources_json';
export const BUILTIN_LOCAL_ID: string = 'builtin_local';

function safeString(value: string | undefined, fallback: string): string {
  return value === undefined || value === null ? fallback : value;
}

function safeNumber(value: number | undefined, fallback: number): number {
  const numeric: number = value === undefined || value === null ? NaN : Number(value);
  return Number.isFinite(numeric) ? numeric : fallback;
}

function safeBool(value: boolean | undefined, fallback: boolean): boolean {
  return value === undefined || value === null ? fallback : value === true;
}

function safeType(value: SourceType | undefined): SourceType {
  if (value === SourceType.WEBDAV || value === SourceType.SMB || value === SourceType.FTP ||
    value === SourceType.LOCAL) {
    return value;
  }
  return SourceType.LOCAL;
}

/**
 * 存储来源配置。来源元数据存 preferences(JSON)，密码存 SecretStore（系统安全存储）。
 */
export class SourceStore implements SecretResolver {
  private prefs: preferences.Preferences | null = null;
  private items: FileSource[] = [];
  private sandboxDir: string = '';

  init(context: common.Context, sandboxDir: string): void {
    this.sandboxDir = sandboxDir;
    try {
      this.prefs = preferences.getPreferencesSync(context, { name: STORE_NAME });
      this.reload();
      this.dropBuiltin();
      this.activateLocalPermissions();
    } catch (err) {
      Logger.error('SourceStore', '初始化来源存储失败', err as Error);
    }
  }

  reload(): void {
    this.items = [];
    if (this.prefs === null) {
      return;
    }
    try {
      const raw: preferences.ValueType = this.prefs.getSync(KEY_SOURCES, '');
      if (typeof raw === 'string' && raw.length > 0) {
        const parsed: FileSource[] = JSON.parse(raw) as FileSource[];
        for (const item of parsed) {
          this.items.push(SourceStore.normalize(item));
        }
      }
    } catch (err) {
      Logger.error('SourceStore', '读取来源失败', err as Error);
      this.items = [];
    }
  }

  /**
   * 重新激活"持久化目录授权"。
   *
   * HarmonyOS 的 Picker 授权需要 persistPermission 持久化，重启应用后还要
   * activatePermission 才能继续访问；否则读目录会直接报没有权限
   * （用户看到的就是"本地存储没有权限"）。这里对每个本机来源逐个激活，失败只记日志。
   */
  private activateLocalPermissions(): void {
    for (const item of this.items) {
      if (item.type !== SourceType.LOCAL) {
        continue;
      }
      const uri: string = item.localUri;
      if (!uri.startsWith('file://')) {
        continue;
      }
      const policy: fileShare.PolicyInfo = { uri: uri, operationMode: fileShare.OperationMode.READ_MODE };
      fileShare.activatePermission([policy]).then(() => {
        Logger.info('SourceStore', `已激活目录授权: ${item.name}`);
      }).catch((err: Error) => {
        Logger.warn('SourceStore', `激活目录授权失败（需要重新选择目录）: ${item.name}`);
      });
    }
  }

  private static normalize(item: FileSource): FileSource {
    const type: SourceType = safeType(item.type);
    const base: FileSource = SourceFactory.blank(type);
    base.id = safeString(item.id, SourceFactory.newId());
    base.name = safeString(item.name, '');
    base.localUri = safeString(item.localUri, '');
    base.url = safeString(item.url, '');
    base.host = safeString(item.host, '');
    base.port = safeNumber(item.port, SourceFactory.defaultPort(type));
    base.share = safeString(item.share, '');
    base.rootPath = safeString(item.rootPath, '');
    base.domain = safeString(item.domain, '');
    base.username = safeString(item.username, '');
    base.password = '';
    base.secure = safeBool(item.secure, type !== SourceType.FTP);
    base.builtIn = safeBool(item.builtIn, false);
    return base;
  }

  /** 不再默认内置应用目录：旧版本写入的内置来源在启动时移除 */
  private dropBuiltin(): void {
    const next: FileSource[] = [];
    let removed: boolean = false;
    for (const item of this.items) {
      if (item.builtIn || item.id === BUILTIN_LOCAL_ID) {
        removed = true;
        continue;
      }
      next.push(item);
    }
    if (removed) {
      this.items = next;
      this.persist();
      Logger.info('SourceStore', '已移除内置应用目录来源');
    }
  }

  list(): FileSource[] {
    return this.items.slice();
  }

  find(id: string): FileSource | null {
    for (const item of this.items) {
      if (item.id === id) {
        return item;
      }
    }
    return null;
  }

  async save(source: FileSource): Promise<FileSource> {
    const stored: FileSource = SourceFactory.copy(source);
    const password: string = stored.password;
    stored.password = '';
    let replaced: boolean = false;
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].id === stored.id) {
        if (this.items[i].builtIn) {
          stored.builtIn = true;
        }
        this.items[i] = stored;
        replaced = true;
        break;
      }
    }
    if (!replaced) {
      if (stored.id.length === 0) {
        stored.id = SourceFactory.newId();
      }
      this.items.push(stored);
    }
    if (password.length > 0) {
      await SecretStore.put(SourceStore.secretAlias(stored.id), password);
    } else {
      await SecretStore.remove(SourceStore.secretAlias(stored.id));
    }
    this.persist();
    return stored;
  }

  async remove(id: string): Promise<void> {
    const next: FileSource[] = [];
    for (const item of this.items) {
      if (item.id !== id) {
        next.push(item);
      }
    }
    this.items = next;
    await SecretStore.remove(SourceStore.secretAlias(id));
    this.persist();
  }

  async passwordOf(source: FileSource): Promise<string> {
    if (source.password.length > 0) {
      return source.password;
    }
    return SecretStore.get(SourceStore.secretAlias(source.id));
  }

  private persist(): void {
    if (this.prefs === null) {
      return;
    }
    try {
      this.prefs.putSync(KEY_SOURCES, JSON.stringify(this.items));
      this.prefs.flush().catch((err: BusinessError) => {
        Logger.error('SourceStore', '写盘来源失败', err as Error);
      });
    } catch (err) {
      Logger.error('SourceStore', '保存来源失败', err as Error);
    }
  }

  private static secretAlias(id: string): string {
    return `source_password_${id}`;
  }
}
