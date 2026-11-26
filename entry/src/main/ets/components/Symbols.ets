import { PreviewKind } from '../model/FileKinds';
import { SourceType } from '../model/FileSource';

/**
 * 图标集中定义：统一使用系统 Symbol（HarmonyOS Symbol Library）。
 * 这里的符号名均取自当前 SDK 的 sysResource 符号表，若目标 SDK 更换，
 * 只需在此文件集中替换，不影响其他页面代码。
 */
export class Symbols {
  static folder(): Resource {
    return $r('sys.symbol.folder');
  }

  static doc(): Resource {
    return $r('sys.symbol.doc_text');
  }

  static photo(): Resource {
    return $r('sys.symbol.picture');
  }

  static music(): Resource {
    return $r('sys.symbol.music');
  }

  static video(): Resource {
    return $r('sys.symbol.play_circle');
  }

  static archive(): Resource {
    return $r('sys.symbol.doc_zipper');
  }

  static settings(): Resource {
    return $r('sys.symbol.gearshape');
  }

  static plus(): Resource {
    return $r('sys.symbol.plus');
  }

  static back(): Resource {
    return $r('sys.symbol.chevron_left');
  }

  static forward(): Resource {
    return $r('sys.symbol.chevron_right');
  }

  static more(): Resource {
    return $r('sys.symbol.ellipsis_bubble');
  }

  static trash(): Resource {
    return $r('sys.symbol.trash');
  }

  static refresh(): Resource {
    return $r('sys.symbol.arrow_clockwise');
  }

  static close(): Resource {
    return $r('sys.symbol.xmark');
  }

  static info(): Resource {
    return $r('sys.symbol.info_circle');
  }

  static grid(): Resource {
    return $r('sys.symbol.square_grid_2x2');
  }

  static list(): Resource {
    return $r('sys.symbol.list_bullet');
  }

  static sort(): Resource {
    return $r('sys.symbol.arrow_up_and_down_square_portrait');
  }

  static link(): Resource {
    return $r('sys.symbol.link');
  }

  static cloud(): Resource {
    return $r('sys.symbol.icloud');
  }

  static local(): Resource {
    return $r('sys.symbol.externaldrive');
  }

  static checkmark(): Resource {
    return $r('sys.symbol.checkmark_circle');
  }

  static play(): Resource {
    return $r('sys.symbol.play_fill');
  }

  static pause(): Resource {
    return $r('sys.symbol.pause_circle_fill');
  }

  static next(): Resource {
    return $r('sys.symbol.chevron_right_circle');
  }

  static previous(): Resource {
    return $r('sys.symbol.chevron_left_circle');
  }

  static listPlay(): Resource {
    return $r('sys.symbol.list_square');
  }

  static lyrics(): Resource {
    return $r('sys.symbol.music_note_list');
  }

  static speed(): Resource {
    return $r('sys.symbol.video_speed');
  }

  static forKind(kind: PreviewKind): Resource {
    switch (kind) {
      case PreviewKind.IMAGE:
        return Symbols.photo();
      case PreviewKind.VIDEO:
        return Symbols.video();
      case PreviewKind.AUDIO:
        return Symbols.music();
      case PreviewKind.TEXT:
      case PreviewKind.PDF:
      case PreviewKind.DOCX:
      case PreviewKind.XLSX:
      case PreviewKind.PPTX:
        return Symbols.doc();
      case PreviewKind.ARCHIVE:
        return Symbols.archive();
      default:
        return Symbols.doc();
    }
  }

  static forSource(type: SourceType): Resource {
    switch (type) {
      case SourceType.LOCAL:
        return Symbols.local();
      case SourceType.SMB:
        return Symbols.folder();
      default:
        return Symbols.cloud();
    }
  }
}
