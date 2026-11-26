export enum Breakpoint {
  SM = 'sm',
  MD = 'md',
  LG = 'lg',
  TV = 'tv'
}

/**
 * 断点与布局计算（规范 §3.2）。
 * 手机 < 600vp；平板/折叠 600–840vp；PC/2in1 > 840vp；智慧屏按强制大屏开关处理。
 */
export class Layout {
  static staticTvWidth: number = 960;

  static ofWidth(widthVp: number, forceTv: boolean): Breakpoint {
    if (forceTv || widthVp >= Layout.staticTvWidth) {
      return Breakpoint.TV;
    }
    if (widthVp >= 840) {
      return Breakpoint.LG;
    }
    if (widthVp >= 600) {
      return Breakpoint.MD;
    }
    return Breakpoint.SM;
  }

  /** 网格列数 */
  static gridColumns(bp: Breakpoint): number {
    switch (bp) {
      case Breakpoint.TV:
        return 5;
      case Breakpoint.LG:
        return 4;
      case Breakpoint.MD:
        return 3;
      default:
        return 2;
    }
  }

  static isWide(bp: Breakpoint): boolean {
    return bp === Breakpoint.LG || bp === Breakpoint.TV;
  }

  /** 大屏使用分栏 Navigation，小屏使用单栏 */
  static useSplit(bp: Breakpoint): boolean {
    return Layout.isWide(bp);
  }

  /** 智慧屏/大屏焦点导航 */
  static focusDriven(bp: Breakpoint, forceTv: boolean): boolean {
    return forceTv || bp === Breakpoint.TV;
  }
}
