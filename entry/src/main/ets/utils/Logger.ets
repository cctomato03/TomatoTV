import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const APP_TAG: string = 'TomatoTV';

/**
 * 统一日志出口。所有输出都会经过脱敏处理：
 * 密码、token、URL 中的 userinfo 都不会出现在日志中（见规范 §10.2）。
 */
export class Logger {
  private static ready: boolean = false;

  static install(): void {
    Logger.ready = true;
  }

  /** 脱敏：密码 / token / URL userinfo */
  static redact(raw: string): string {
    let out: string = raw;
    try {
      out = out.replace(/(password|passwd|pwd|token|secret|authorization)([=:]\s*)([^\s&,"'}]+)/gi, '$1$2***');
      out = out.replace(/(https?:\/\/)([^\/\s@]+):([^\/\s@]+)@/gi, '$1***@');
    } catch (e) {
      return 'log-redact-failed';
    }
    return out;
  }

  static info(tag: string, message: string): void {
    hilog.info(DOMAIN, APP_TAG, '%{public}s: %{public}s', tag, Logger.redact(message));
  }

  static warn(tag: string, message: string): void {
    hilog.warn(DOMAIN, APP_TAG, '%{public}s: %{public}s', tag, Logger.redact(message));
  }

  static error(tag: string, message: string, err?: Error): void {
    const detail: string = err === undefined ? '' : ` | ${err.name}: ${err.message}`;
    hilog.error(DOMAIN, APP_TAG, '%{public}s: %{public}s', tag, Logger.redact(message + detail));
  }

  static debug(tag: string, message: string): void {
    if (!Logger.ready) {
      return;
    }
    hilog.debug(DOMAIN, APP_TAG, '%{public}s: %{public}s', tag, Logger.redact(message));
  }
}
