/** WebDAV 207 Multi-Status 解析器（不依赖 DOM，按命名空间前缀归一后正则解析） */
export interface DavItem {
  href: string;
  name: string;
  isDirectory: boolean;
  size: number;
  modified: number;
}

export class WebDavXml {
  private static stripPrefixes(text: string): string {
    return text.replace(/<(\/?)[A-Za-z0-9_.-]+:/g, '<$1');
  }

  private static pick(pattern: RegExp, text: string): string {
    const match: RegExpExecArray | null = pattern.exec(text);
    return match === null ? '' : match[1];
  }

  static parse(xmlText: string): DavItem[] {
    const clean: string = WebDavXml.stripPrefixes(xmlText);
    const items: DavItem[] = [];
    const responseRe: RegExp = new RegExp('<response[^>]*>([\\s\\S]*?)</response>', 'gi');
    let match: RegExpExecArray | null = responseRe.exec(clean);
    while (match !== null) {
      const block: string = match[1];
      const href: string = WebDavXml.pick(new RegExp('<href[^>]*>([\\s\\S]*?)</href>', 'i'), block).trim();
      if (href.length > 0) {
        const isDirectory: boolean = new RegExp('<collection\\s*/?>', 'i').test(block) ||
          href.endsWith('/');
        const sizeText: string = WebDavXml.pick(new RegExp('<getcontentlength>(\\d+)</getcontentlength>', 'i'), block);
        const modifiedText: string = WebDavXml.pick(new RegExp('<getlastmodified>([^<]+)</getlastmodified>', 'i'),
          block).trim();
        const size: number = sizeText.length > 0 ? Number(sizeText) : 0;
        const modified: number = modifiedText.length > 0 ? Date.parse(modifiedText) : 0;
        items.push({
          href: href,
          name: WebDavXml.nameOfHref(href),
          isDirectory: isDirectory,
          size: Number.isFinite(size) ? size : 0,
          modified: Number.isFinite(modified) ? modified : 0
        });
      }
      match = responseRe.exec(clean);
    }
    return items;
  }

  static nameOfHref(href: string): string {
    let clean: string = href;
    if (clean.endsWith('/')) {
      clean = clean.substring(0, clean.length - 1);
    }
    const slash: number = clean.lastIndexOf('/');
    const tail: string = slash >= 0 ? clean.substring(slash + 1) : clean;
    try {
      return decodeURIComponent(tail);
    } catch (err) {
      return tail;
    }
  }

  /** 取 href 的路径部分，用于和请求路径比对 */
  static pathOfHref(href: string): string {
    let clean: string = href;
    if (clean.endsWith('/')) {
      clean = clean.substring(0, clean.length - 1);
    }
    try {
      return decodeURIComponent(clean);
    } catch (err) {
      return clean;
    }
  }
}
