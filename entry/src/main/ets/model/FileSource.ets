export enum SourceType {
  LOCAL = 'LOCAL',
  WEBDAV = 'WEBDAV',
  SMB = 'SMB',
  FTP = 'FTP'
}

export interface FileSource {
  id: string;
  type: SourceType;
  name: string;
  localUri: string;
  url: string;
  host: string;
  port: number;
  share: string;
  rootPath: string;
  domain: string;
  username: string;
  password: string;
  secure: boolean;
  builtIn: boolean;
}

export class SourceFactory {
  static blank(type: SourceType): FileSource {
    return {
      id: '',
      type: type,
      name: '',
      localUri: '',
      url: '',
      host: '',
      port: SourceFactory.defaultPort(type),
      share: '',
      rootPath: '',
      domain: '',
      username: '',
      password: '',
      secure: type === SourceType.FTP ? false : true,
      builtIn: false
    };
  }

  static defaultPort(type: SourceType): number {
    if (type === SourceType.SMB) {
      return 445;
    }
    if (type === SourceType.FTP) {
      return 21;
    }
    return 0;
  }

  static newId(): string {
    const now: number = Date.now();
    const rand: number = Math.floor(Math.random() * 1000000);
    return `src_${now}_${rand}`;
  }

  static displayAddress(source: FileSource): string {
    switch (source.type) {
      case SourceType.LOCAL:
        return source.localUri.length > 0 ? SourceUrl.tailOfUri(source.localUri) : '未选择目录';
      case SourceType.WEBDAV:
        return source.url;
      case SourceType.SMB: {
        const share: string = source.share.length > 0 ? `/${source.share}` : '';
        const root: string = source.rootPath.length > 0 ? `/${SourceUrl.trimSlashes(source.rootPath)}` : '';
        return `smb://${source.host}:${source.port}${share}${root}`;
      }
      case SourceType.FTP: {
        const scheme: string = source.secure ? 'ftps' : 'ftp';
        const root: string = source.rootPath.length > 0 ? `/${SourceUrl.trimSlashes(source.rootPath)}` : '';
        return `${scheme}://${source.host}:${source.port}${root}`;
      }
      default:
        return '';
    }
  }

  static typeLabel(type: SourceType): string {
    switch (type) {
      case SourceType.LOCAL:
        return '本机';
      case SourceType.WEBDAV:
        return 'WebDAV';
      case SourceType.SMB:
        return 'SMB';
      case SourceType.FTP:
        return 'FTP';
      default:
        return '';
    }
  }

  static copy(source: FileSource): FileSource {
    return {
      id: source.id,
      type: source.type,
      name: source.name,
      localUri: source.localUri,
      url: source.url,
      host: source.host,
      port: source.port,
      share: source.share,
      rootPath: source.rootPath,
      domain: source.domain,
      username: source.username,
      password: source.password,
      secure: source.secure,
      builtIn: source.builtIn
    };
  }
}

export class SourceUrl {
  static trimSlashes(path: string): string {
    let out: string = path;
    while (out.startsWith('/')) {
      out = out.substring(1);
    }
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  /** 只用于展示：取 URI 最后一段作为可读名称 */
  static tailOfUri(uri: string): string {
    let clean: string = uri;
    const query: number = clean.indexOf('?');
    if (query > 0) {
      clean = clean.substring(0, query);
    }
    const slash: number = clean.lastIndexOf('/');
    if (slash < 0 || slash === clean.length - 1) {
      return clean;
    }
    return decodeURIComponent(clean.substring(slash + 1));
  }

  /** 逐段编码路径，保留分隔符 */
  static encodePath(path: string): string {
    const parts: string[] = path.split('/');
    const encoded: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const part: string = parts[i];
      if (part.length === 0) {
        continue;
      }
      encoded.push(encodeURIComponent(part));
    }
    return encoded.join('/');
  }

  static joinPath(base: string, name: string): string {
    const trimmed: string = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    return `${trimmed}/${name}`;
  }

  static parentOf(path: string): string {
    const trimmed: string = path.endsWith('/') && path.length > 1 ? path.substring(0, path.length - 1) : path;
    const slash: number = trimmed.lastIndexOf('/');
    if (slash <= 0) {
      return '/';
    }
    return trimmed.substring(0, slash);
  }
}
