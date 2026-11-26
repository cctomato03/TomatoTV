import { common, Want } from '@kit.AbilityKit';
import { Logger } from './Logger';

/**
 * 作者链接安全策略（规范 §7.9 / §10.6）：
 * 仅 http / https / mailto 走系统打开，其余（file/content/javascript/data 等）一律拒绝。
 */
export class SafeLink {
  private static readonly ALLOWED: string[] = ['http://', 'https://', 'mailto:'];

  static isSafeUrl(candidate: string): boolean {
    if (candidate.length === 0) {
      return false;
    }
    const lower: string = candidate.toLowerCase();
    for (const prefix of SafeLink.ALLOWED) {
      if (lower.startsWith(prefix) && lower.length > prefix.length) {
        return true;
      }
    }
    return false;
  }

  /** 从 EXIF/文本里提取首个安全链接，没有则返回空串 */
  static firstSafeUrl(text: string): string {
    if (text.length === 0) {
      return '';
    }
    const tokens: string[] = text.split(/[\s,;()[\]<>"']+/);
    for (const token of tokens) {
      if (SafeLink.isSafeUrl(token)) {
        return token;
      }
    }
    return '';
  }

  static async open(context: common.UIAbilityContext, url: string): Promise<boolean> {
    if (!SafeLink.isSafeUrl(url)) {
      return false;
    }
    try {
      const want: Want = {
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: url
      };
      await context.startAbility(want);
      return true;
    } catch (err) {
      Logger.error('SafeLink', `startAbility 失败 ${url}`, err as Error);
      return false;
    }
  }
}
