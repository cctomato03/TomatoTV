import { http } from '@kit.NetworkKit';
import { Logger } from '../utils/Logger';

interface LrcLibRecord {
  id: number;
  trackName: string;
  artistName: string;
  syncedLyrics?: string;
  plainLyrics?: string;
}

/**
 * 在线歌词（规范 §9.5）：LRCLIB 搜索，同步歌词优先。
 * 只发送标题与艺术家，不发送任何路径/凭据。
 */
export class LyricsRepository {
  private static readonly ENDPOINT: string = 'https://lrclib.net/api/search';

  static async search(title: string, artist: string): Promise<string | null> {
    if (title.length === 0) {
      return null;
    }
    const request: http.HttpRequest = http.createHttp();
    try {
      let url: string = `${LyricsRepository.ENDPOINT}?track_name=${encodeURIComponent(title)}`;
      if (artist.length > 0) {
        url += `&artist_name=${encodeURIComponent(artist)}`;
      }
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000,
        readTimeout: 15000
      });
      if (response.responseCode !== 200) {
        return null;
      }
      const body: string = typeof response.result === 'string' ? response.result as string : '';
      if (body.length === 0) {
        return null;
      }
      const records: LrcLibRecord[] = JSON.parse(body) as LrcLibRecord[];
      let plain: string | null = null;
      for (const record of records) {
        if (record.syncedLyrics !== undefined && record.syncedLyrics.length > 0) {
          return record.syncedLyrics;
        }
        if (plain === null && record.plainLyrics !== undefined && record.plainLyrics.length > 0) {
          plain = record.plainLyrics;
        }
      }
      return plain;
    } catch (err) {
      Logger.warn('LyricsRepository', '歌词查询失败');
      return null;
    } finally {
      request.destroy();
    }
  }

  /** 解析 LRC：返回 [时间戳文本] 行，供简单展示使用 */
  static plainText(lyrics: string): string {
    if (lyrics.length === 0) {
      return '';
    }
    const lines: string[] = lyrics.split('\n');
    const out: string[] = [];
    for (const line of lines) {
      const clean: string = line.replace(/\[\d{2}:\d{2}(\.\d{1,3})?\]/g, '').trim();
      if (clean.length > 0) {
        out.push(clean);
      }
    }
    return out.join('\n');
  }
}
