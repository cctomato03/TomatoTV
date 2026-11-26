/** 逻辑路径工具：规范化、越界防护（规范 §10.4） */
export class PathGuard {
  /** 规范化逻辑路径：统一为以 / 开头、无 . 与 .. 的形式 */
  static normalize(path: string): string {
    const cleaned: string = path.replace(/\\/g, '/');
    const parts: string[] = cleaned.split('/');
    const stack: string[] = [];
    for (const part of parts) {
      if (part.length === 0 || part === '.') {
        continue;
      }
      if (part === '..') {
        if (stack.length > 0) {
          stack.pop();
        }
        continue;
      }
      stack.push(part);
    }
    return `/${stack.join('/')}`;
  }

  /** 规范化后的 path 是否仍在 root 之下 */
  static isUnder(root: string, path: string): boolean {
    const normalizedRoot: string = PathGuard.normalize(root);
    const normalizedPath: string = PathGuard.normalize(path);
    if (normalizedRoot === '/' || normalizedRoot.length === 0) {
      return true;
    }
    if (normalizedPath === normalizedRoot) {
      return true;
    }
    return normalizedPath.startsWith(`${normalizedRoot}/`);
  }

  static join(base: string, name: string): string {
    const trimmed: string = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    if (trimmed.length === 0) {
      return `/${name}`;
    }
    return `${trimmed}/${name}`;
  }

  static segments(path: string): string[] {
    const normalized: string = PathGuard.normalize(path);
    if (normalized === '/') {
      return [];
    }
    return normalized.substring(1).split('/');
  }

  /** 面包屑：只保留相对 root 的部分 */
  static relativeSegments(root: string, path: string): string[] {
    const rootSegments: string[] = PathGuard.segments(root);
    const pathSegments: string[] = PathGuard.segments(path);
    const result: string[] = [];
    for (let i = rootSegments.length; i < pathSegments.length; i++) {
      result.push(pathSegments[i]);
    }
    return result;
  }

  /** 由相对 root 的层级还原绝对路径 */
  static fromSegments(root: string, segments: string[]): string {
    let current: string = PathGuard.normalize(root);
    for (const segment of segments) {
      current = PathGuard.join(current, segment);
    }
    return PathGuard.normalize(current);
  }
}

/** 判断 path 是否以某个 scheme 开头（file:// 等） */
export function hasScheme(path: string): boolean {
  const index: number = path.indexOf('://');
  return index > 0 && index < 12;
}
