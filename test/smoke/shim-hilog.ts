/** 仅供本地冒烟测试使用：@kit.PerformanceAnalysisKit 的 hilog 简化实现 */
export const hilog = {
  info(_domain: number, _tag: string, format: string, ...args: unknown[]): void {
    console.log('[info]', format, ...args);
  },
  warn(_domain: number, _tag: string, format: string, ...args: unknown[]): void {
    console.log('[warn]', format, ...args);
  },
  error(_domain: number, _tag: string, format: string, ...args: unknown[]): void {
    console.log('[error]', format, ...args);
  },
  debug(_domain: number, _tag: string, format: string, ...args: unknown[]): void {
    console.log('[debug]', format, ...args);
  }
};
