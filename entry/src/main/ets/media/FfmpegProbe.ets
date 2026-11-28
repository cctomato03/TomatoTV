import { probeTracksAsync } from 'libffprobe.so';
import { PlayableMedia } from '../data/fs/FileSystemClient';
import { TrackOption } from './MediaTypes';
import { Logger } from '../utils/Logger';

interface RawStream {
  index: number;
  type: string;
  codec: string;
  language: string;
  title: string;
  width?: number;
  height?: number;
  hdr?: boolean;
  colorTrc?: number;
}

interface RawProbeResult {
  durationMs: number;
  streams: RawStream[];
}

export interface FfmpegProbeResult {
  audioTracks: TrackOption[];
  subtitleTracks: TrackOption[];
  selectedAudioId: number;
  durationMs: number;
  videoWidth: number;
  videoHeight: number;
  hdr: boolean;
  /** 0=非 HDR，1=HLG，2=HDR10(PQ) */
  hdrType: number;
}

/**
 * 用 FFmpeg(libavformat) 枚举容器内所有流。
 * 返回的 index 就是 FFmpeg 流索引，可直接传给 IjkMediaPlayer.selectTrack()。
 */
export class FfmpegProbe {
  private static label(prefix: string, order: number, codec: string, language: string, title: string): string {
    let detail: string = '';
    if (title.length > 0) {
      detail = title;
    } else if (codec.length > 0) {
      detail = codec;
    }
    if (language.length > 0 && language !== 'und') {
      detail = detail.length > 0 ? `${detail} · ${language}` : language;
    }
    return detail.length > 0 ? `${prefix} ${order} · ${detail}` : `${prefix} ${order}`;
  }

  static async probe(source: PlayableMedia): Promise<FfmpegProbeResult | null> {
    const url: string = source.url.length > 0 ? source.url : source.path;
    if (url.length === 0) {
      return null;
    }
    let raw: string = '';
    try {
      raw = await probeTracksAsync(url);
    } catch (err) {
      Logger.error('FfmpegProbe', 'native 探测调用失败', err as Error);
      return null;
    }
    if (raw.length === 0) {
      Logger.warn('FfmpegProbe', 'native 探测未返回数据');
      return null;
    }
    let parsed: RawProbeResult;
    try {
      parsed = JSON.parse(raw) as RawProbeResult;
    } catch (err) {
      Logger.warn('FfmpegProbe', '解析探测结果失败');
      return null;
    }
    if (parsed.streams === undefined || parsed.streams === null) {
      return null;
    }
    const audio: TrackOption[] = [];
    const subtitle: TrackOption[] = [];
    let audioOrder: number = 0;
    let subtitleOrder: number = 0;
    for (const stream of parsed.streams) {
      if (stream.type === 'audio') {
        audioOrder++;
        audio.push({
          index: stream.index,
          label: FfmpegProbe.label('音轨', audioOrder, stream.codec, stream.language, stream.title),
          isSubtitle: false,
          codec: stream.codec,
          supported: true
        });
      } else if (stream.type === 'subtitle') {
        subtitleOrder++;
        subtitle.push({
          index: stream.index,
          label: FfmpegProbe.label('字幕', subtitleOrder, stream.codec, stream.language, stream.title),
          isSubtitle: true,
          codec: stream.codec,
          supported: true
        });
      }
    }
    const result: FfmpegProbeResult = {
      audioTracks: audio,
      subtitleTracks: subtitle,
      selectedAudioId: audio.length > 0 ? audio[0].index : -1,
      durationMs: parsed.durationMs > 0 ? parsed.durationMs : 0,
      videoWidth: 0,
      videoHeight: 0,
      hdr: false,
      hdrType: 0
    };
    for (const stream of parsed.streams) {
      if (stream.type === 'video') {
        if (stream.width !== undefined && stream.height !== undefined) {
          result.videoWidth = stream.width;
          result.videoHeight = stream.height;
        }
        result.hdr = stream.hdr === true;
        const trc: number = stream.colorTrc === undefined ? -1 : stream.colorTrc;
        if (trc === 16) {
          result.hdrType = 2; // SMPTE2084 / HDR10
        } else if (trc === 18) {
          result.hdrType = 1; // ARIB STD-B67 / HLG
        } else {
          result.hdrType = 0;
        }
        break;
      }
    }
    Logger.info('FfmpegProbe',
      `探测完成 音轨=${audio.length} 字幕=${subtitle.length} 时长=${result.durationMs} 尺寸=${result.videoWidth}x${result.videoHeight} HDR=${result.hdr} hdrType=${result.hdrType}`);
    return result;
  }
}