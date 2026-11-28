import { image } from '@kit.ImageKit';

/** 外挂字幕候选：同目录下与视频同名的 .srt/.vtt/.ass 文件 */
export interface ExternalSubtitle {
  path: string;
  name: string;
  label: string;
  fd: number;
  size: number;
}

export interface TrackOption {
  index: number;
  label: string;
  isSubtitle: boolean;
  /** 轨道编码 MIME（如 audio/eac3）；字幕轨为空 */
  codec: string;
  /** 音频轨是否受系统解码器支持；字幕轨恒为 true */
  supported: boolean;
}

export interface VideoState {
  loading: boolean;
  title: string;
  playing: boolean;
  buffering: boolean;
  durationMs: number;
  positionMs: number;
  speed: number;
  /** 视频画面尺寸（0 表示未知），用于按原始比例显示，避免拉伸铺满 */
  videoWidth: number;
  videoHeight: number;
  audioTracks: TrackOption[];
  subtitleTracks: TrackOption[];
  selectedAudioId: number;
  selectedSubtitleId: number;
  subtitleText: string;
  /** 非致命提示（如音轨编码不受支持），显示若干秒后自动消失 */
  notice: string;
  /** 是否正在使用 FFmpeg(ijkplayer) 兜底解码音轨 */
  ffmpegAudioActive: boolean;
  /** 需要切换为 ijkplayer 单流播放（系统无法解码该片源的音轨） */
  needsIjk: boolean;
  error: string | null;
}

export interface PlaylistItem {
  path: string;
  name: string;
  size: number;
}

export interface AudioState {
  loading: boolean;
  title: string;
  artist: string;
  album: string;
  playing: boolean;
  durationMs: number;
  positionMs: number;
  speed: number;
  albumArt: image.PixelMap | null;
  playlist: PlaylistItem[];
  playlistIndex: number;
  lyrics: string | null;
  lyricsLoading: boolean;
  lyricsError: string | null;
  playbackError: string | null;
}

export class MediaDefaults {
  static videoState(title: string): VideoState {
    return {
      loading: true,
      title: title,
      playing: false,
      buffering: false,
      durationMs: 0,
      positionMs: 0,
      speed: 1,
      videoWidth: 0,
      videoHeight: 0,
      audioTracks: [],
      subtitleTracks: [],
      selectedAudioId: -1,
      selectedSubtitleId: -1,
      subtitleText: '',
      notice: '',
      ffmpegAudioActive: false,
      needsIjk: false,
      error: null
    };
  }

  static audioState(): AudioState {
    return {
      loading: true,
      title: '',
      artist: '',
      album: '',
      playing: false,
      durationMs: 0,
      positionMs: 0,
      speed: 1,
      albumArt: null,
      playlist: [],
      playlistIndex: 0,
      lyrics: null,
      lyricsLoading: false,
      lyricsError: null,
      playbackError: null
    };
  }
}

export class PlaybackSpeeds {
  static readonly LIST: number[] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3];

  static label(speed: number): string {
    return `${speed}x`;
  }
}
