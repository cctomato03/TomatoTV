export class Fmt {
  private static pad(value: number, width: number): string {
    let text: string = Math.floor(Math.abs(value)).toString();
    while (text.length < width) {
      text = `0${text}`;
    }
    return text;
  }

  static size(bytes: number): string {
    if (!Number.isFinite(bytes) || bytes <= 0) {
      return '0 B';
    }
    const units: string[] = ['B', 'KB', 'MB', 'GB', 'TB'];
    let value: number = bytes;
    let unit: number = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value = value / 1024;
      unit++;
    }
    const digits: number = value >= 100 || unit === 0 ? 0 : 1;
    return `${value.toFixed(digits)} ${units[unit]}`;
  }

  static dateTime(ms: number): string {
    if (!Number.isFinite(ms) || ms <= 0) {
      return '--';
    }
    const date: Date = new Date(ms);
    return `${date.getFullYear()}-${Fmt.pad(date.getMonth() + 1, 2)}-${Fmt.pad(date.getDate(), 2)} ` +
      `${Fmt.pad(date.getHours(), 2)}:${Fmt.pad(date.getMinutes(), 2)}`;
  }

  static dateOnly(ms: number): string {
    if (!Number.isFinite(ms) || ms <= 0) {
      return '--';
    }
    const date: Date = new Date(ms);
    return `${date.getFullYear()}-${Fmt.pad(date.getMonth() + 1, 2)}-${Fmt.pad(date.getDate(), 2)}`;
  }

  /** 毫秒 -> mm:ss 或 h:mm:ss */
  static duration(ms: number): string {
    if (!Number.isFinite(ms) || ms < 0) {
      return '00:00';
    }
    const totalSeconds: number = Math.floor(ms / 1000);
    const hours: number = Math.floor(totalSeconds / 3600);
    const minutes: number = Math.floor((totalSeconds % 3600) / 60);
    const seconds: number = totalSeconds % 60;
    if (hours > 0) {
      return `${hours}:${Fmt.pad(minutes, 2)}:${Fmt.pad(seconds, 2)}`;
    }
    return `${Fmt.pad(minutes, 2)}:${Fmt.pad(seconds, 2)}`;
  }

  static percent(position: number, total: number): number {
    if (!Number.isFinite(total) || total <= 0) {
      return 0;
    }
    const value: number = (position / total) * 100;
    if (value < 0) {
      return 0;
    }
    if (value > 100) {
      return 100;
    }
    return value;
  }
}
