/**
 * 文件类型判定。后缀优先，MIME 仅作辅助（规范 §6）。
 */

export enum PreviewKind {
  IMAGE = 'IMAGE',
  VIDEO = 'VIDEO',
  AUDIO = 'AUDIO',
  TEXT = 'TEXT',
  PDF = 'PDF',
  DOCX = 'DOCX',
  XLSX = 'XLSX',
  PPTX = 'PPTX',
  ARCHIVE = 'ARCHIVE',
  OTHER = 'OTHER'
}

const VIDEO_EXT: string[] = [
  'mp4', 'mkv', 'webm', 'avi', 'mov', '3gp', '3g2', 'm4v', 'ts', 'm2ts', 'mts', 'wmv', 'rmvb', 'rm',
  'flv', 'mpg', 'mpeg', 'm2v', 'm1v', 'vob', 'asf', 'ogv', 'divx', 'f4v', 'mxf'
];

const AUDIO_EXT: string[] = [
  'mp3', 'wav', 'flac', 'aac', 'ogg', 'oga', 'm4a', 'm4b', 'opus', 'wma', 'ape', 'alac', 'aiff', 'aif',
  'amr', 'mid', 'midi', 'mka', 'wv'
];

const IMAGE_EXT: string[] = [
  'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'avif', 'ico', 'jfif'
];

const TEXT_EXT: string[] = [
  'txt', 'text', 'log', 'md', 'markdown', 'json', 'json5', 'xml', 'html', 'htm', 'xhtml', 'css', 'scss',
  'sass', 'less', 'js', 'mjs', 'cjs', 'ts', 'tsx', 'jsx', 'kt', 'kts', 'java', 'py', 'rb', 'go', 'rs', 'c',
  'h', 'cpp', 'cc', 'hpp', 'cs', 'php', 'sh', 'bash', 'zsh', 'bat', 'cmd', 'ps1', 'yml', 'yaml', 'toml',
  'ini', 'cfg', 'conf', 'properties', 'groovy', 'sql', 'csv', 'tsv', 'srt', 'vtt', 'tex', 'diff', 'patch',
  'gitignore', 'editorconfig', 'dockerfile', 'makefile', 'pro', 'env', 'lock', 'rtf'
];

const ARCHIVE_EXT: string[] = ['zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'zst', 'tgz', 'iso'];

const VIDEO_SET: Set<string> = new Set<string>(VIDEO_EXT);
const AUDIO_SET: Set<string> = new Set<string>(AUDIO_EXT);
const IMAGE_SET: Set<string> = new Set<string>(IMAGE_EXT);
const TEXT_SET: Set<string> = new Set<string>(TEXT_EXT);
const ARCHIVE_SET: Set<string> = new Set<string>(ARCHIVE_EXT);

export class FileKinds {
  /** 取小写后缀，没有后缀时返回空串 */
  static extensionOf(name: string): string {
    const dot: number = name.lastIndexOf('.');
    if (dot <= 0 || dot === name.length - 1) {
      return '';
    }
    return name.substring(dot + 1).toLowerCase();
  }

  static kindOf(name: string): PreviewKind {
    const ext: string = FileKinds.extensionOf(name);
    if (ext.length === 0) {
      const lower: string = name.toLowerCase();
      if (lower === 'dockerfile' || lower === 'makefile' || lower === '.gitignore' || lower === '.env') {
        return PreviewKind.TEXT;
      }
      return PreviewKind.OTHER;
    }
    if (VIDEO_SET.has(ext)) {
      return PreviewKind.VIDEO;
    }
    if (AUDIO_SET.has(ext)) {
      return PreviewKind.AUDIO;
    }
    if (IMAGE_SET.has(ext)) {
      return PreviewKind.IMAGE;
    }
    if (ext === 'pdf') {
      return PreviewKind.PDF;
    }
    if (ext === 'docx' || ext === 'doc') {
      return PreviewKind.DOCX;
    }
    if (ext === 'xlsx' || ext === 'xls' || ext === 'csvx') {
      return PreviewKind.XLSX;
    }
    if (ext === 'pptx' || ext === 'ppt') {
      return PreviewKind.PPTX;
    }
    if (ARCHIVE_SET.has(ext)) {
      return PreviewKind.ARCHIVE;
    }
    if (TEXT_SET.has(ext)) {
      return PreviewKind.TEXT;
    }
    return PreviewKind.OTHER;
  }

  static mimeOfKind(kind: PreviewKind, name: string): string {
    const ext: string = FileKinds.extensionOf(name);
    switch (kind) {
      case PreviewKind.IMAGE:
        if (ext === 'png') {
          return 'image/png';
        }
        if (ext === 'gif') {
          return 'image/gif';
        }
        if (ext === 'webp') {
          return 'image/webp';
        }
        if (ext === 'bmp') {
          return 'image/bmp';
        }
        return 'image/jpeg';
      case PreviewKind.VIDEO:
        if (ext === 'mkv') {
          return 'video/x-matroska';
        }
        if (ext === 'webm') {
          return 'video/webm';
        }
        if (ext === 'ts' || ext === 'm2ts' || ext === 'mts') {
          return 'video/mp2t';
        }
        return 'video/mp4';
      case PreviewKind.AUDIO:
        if (ext === 'flac') {
          return 'audio/flac';
        }
        if (ext === 'wav') {
          return 'audio/wav';
        }
        if (ext === 'ogg' || ext === 'oga') {
          return 'audio/ogg';
        }
        return 'audio/mpeg';
      case PreviewKind.PDF:
        return 'application/pdf';
      case PreviewKind.TEXT:
        return 'text/plain';
      case PreviewKind.DOCX:
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case PreviewKind.XLSX:
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case PreviewKind.PPTX:
        return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
      case PreviewKind.ARCHIVE:
        return 'application/zip';
      default:
        return 'application/octet-stream';
    }
  }

  /** 是否为需要进入独立播放页的媒体类型 */
  static isMedia(kind: PreviewKind): boolean {
    return kind === PreviewKind.VIDEO || kind === PreviewKind.AUDIO;
  }

  /** 是否按前缀而不是后缀判定的特殊文件名 */
  static isSpecialTextFile(name: string): boolean {
    return TEXT_SET.has(name.toLowerCase());
  }
}
