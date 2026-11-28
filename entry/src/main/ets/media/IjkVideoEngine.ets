import {
  IjkMediaPlayer,
  VideoCodecMode,
  OnPreparedListener,
  OnCompletionListener,
  OnBufferingUpdateListener,
  OnErrorListener,
  OnSeekCompleteListener,
  OnInfoListener,
  OnVideoSizeChangedListener,
  OnTimedTextListener
} from '@ohos/ijkplayer';
import { configureHdrWindow } from 'libffprobe.so';
import { FsErrorText, PlayableMedia } from '../data/fs/FileSystemClient';
import { MediaDefaults, TrackOption, VideoState } from './MediaTypes';
import { SubtitleCue } from './SubtitleParser';
import { Logger } from '../utils/Logger';

type IjkListener = (state: VideoState) => void;

const INFO_BUFFERING_START: number = 701;
const INFO_BUFFERING_END: number = 702;

/**
 * ijkplayer（FFmpeg）播放引擎：音视频单流解码，天然同步，也不重复占用网络。
 * 需要带 libraryname: 'ijkplayer_napi' 的 XComponent 提供 native context。
 */
export class IjkVideoEngine {
  static readonly EXTERNAL_SUBTITLE_INDEX: number = -2;

  private player: IjkMediaPlayer | null = null;
  private state: VideoState = MediaDefaults.videoState('');
  private listener: IjkListener = () => {
  };
  private context: object | undefined = undefined;
  private readonly id: string;
  private source: PlayableMedia | null = null;
  private startMs: number = 0;
  private surfaceId: string = '';
  private hdrType: number = 0;
  private hdrFallbackTried: boolean = false;
  private prepared: boolean = false;
  private speed: number = 1;
  private positionTimer: number = -1;
  private seekResumeTimer: number = -1;
  private noticeTimer: number = -1;
  private wantPlaying: boolean = true;
  private lastProgressMs: number = 0;
  private lastProgressAt: number = 0;
  private lastRecoverAt: number = 0;
  private stallReloads: number = 0;
  private tracks: TrackOption[] = [];
  private subtitleTracks: TrackOption[] = [];
  private selectedAudioId: number = -1;
  private externalCues: SubtitleCue[] = [];
  private externalLabel: string = '';
  private externalEnabled: boolean = false;
  private internalSubtitleId: number = -1;

  constructor(id: string = 'tomato_video_ijk') {
    this.id = id;
  }

  onChange(listener: IjkListener): void {
    this.listener = listener;
  }

  private emit(): void {
    this.listener(this.snapshot());
  }

  private snapshot(): VideoState {
    return {
      loading: this.state.loading,
      title: this.state.title,
      playing: this.state.playing,
      buffering: this.state.buffering,
      durationMs: this.state.durationMs,
      positionMs: this.state.positionMs,
      speed: this.state.speed,
      videoWidth: this.state.videoWidth,
      videoHeight: this.state.videoHeight,
      audioTracks: this.state.audioTracks,
      subtitleTracks: this.state.subtitleTracks,
      selectedAudioId: this.state.selectedAudioId,
      selectedSubtitleId: this.state.selectedSubtitleId,
      subtitleText: this.state.subtitleText,
      notice: this.state.notice,
      ffmpegAudioActive: false,
      needsIjk: true,
      error: this.state.error
    };
  }

  isActive(): boolean {
    return this.player !== null;
  }

  open(source: PlayableMedia, title: string, context: object | undefined, startMs: number,
    audioTracks: TrackOption[], selectedAudioId: number, subtitleTracks: TrackOption[] = [],
    externalLabel: string = '', externalCues: SubtitleCue[] = [], surfaceId: string = '',
    hdrType: number = 0): void {
    this.release();
    this.source = source;
    this.context = context;
    this.startMs = startMs > 0 ? startMs : 0;
    this.surfaceId = surfaceId;
    this.hdrType = hdrType;
    this.speed = 1;
    this.tracks = audioTracks.slice();
    this.subtitleTracks = subtitleTracks.slice();
    this.selectedAudioId = selectedAudioId;
    this.externalCues = externalCues;
    this.externalLabel = externalLabel;
    this.externalEnabled = externalCues.length > 0;
    this.internalSubtitleId = -1;
    this.state = MediaDefaults.videoState(title);
    this.state.audioTracks = this.tracks.slice();
    this.state.selectedAudioId = this.selectedAudioId;
    const subtitles: TrackOption[] = this.subtitleTracks.slice();
    if (externalLabel.length > 0) {
      subtitles.push({
        index: IjkVideoEngine.EXTERNAL_SUBTITLE_INDEX,
        label: externalLabel,
        isSubtitle: true,
        codec: '',
        supported: true
      });
    }
    this.state.subtitleTracks = subtitles;
    if (this.externalEnabled) {
      this.state.selectedSubtitleId = IjkVideoEngine.EXTERNAL_SUBTITLE_INDEX;
    } else if (subtitles.length > 0) {
      this.state.selectedSubtitleId = subtitles[0].index;
      this.internalSubtitleId = subtitles[0].index;
    } else {
      this.state.selectedSubtitleId = -1;
    }
    this.wantPlaying = true;
    this.emit();
    if (context === undefined) {
      Logger.warn('IjkVideoEngine', '尚未拿到 XComponent context');
      return;
    }
    const url: string = source.url.length > 0 ? source.url : source.path;
    if (url.length === 0) {
      this.state.error = FsErrorText.DECODE;
      this.state.loading = false;
      this.emit();
      return;
    }
    try {
      const player: IjkMediaPlayer = new IjkMediaPlayer(this.id);
      this.player = player;
      player.setContext(context, this.id);
      // HDR 片源必须用 Surface 解码 + 硬件解码；BUFFER 模式会经 GL 转成 SDR
      const useSurface: boolean = hdrType > 0 && surfaceId.length > 0;
      player.native_setup(useSurface ? VideoCodecMode.SURFACE : VideoCodecMode.BUFFER);
      if (useSurface) {
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, 'mediacodec-all-videos', '1');
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, 'auto-mediacodec', '1');
      }

      const preparedListener: OnPreparedListener = {
        onPrepared: () => {
          this.handlePrepared();
        }
      };
      const completionListener: OnCompletionListener = {
        onCompletion: () => {
          this.state.playing = false;
          this.state.positionMs = this.state.durationMs;
          this.emit();
        }
      };
      const bufferingListener: OnBufferingUpdateListener = {
        onBufferingUpdate: (percent: number) => {
          Logger.debug('IjkVideoEngine', `缓冲 ${percent}%`);
        }
      };
      const errorListener: OnErrorListener = {
        onError: (what: number, extra: number) => {
          Logger.error('IjkVideoEngine', `播放错误 what=${what} extra=${extra}`);
          // HDR/Surface 硬解失败时回退到 BUFFER 软解，保证视频至少能播（SDR）
          if (this.hdrType > 0 && !this.hdrFallbackTried && this.source !== null) {
            this.hdrFallbackTried = true;
            this.hdrType = 0;
            const pos: number = this.state.positionMs;
            Logger.warn('IjkVideoEngine', 'HDR 硬解失败，回退 SDR 缓冲模式');
            this.showNotice('HDR 播放不可用，已回退 SDR');
            setTimeout(() => {
              this.reloadAt(pos);
            }, 600);
            return;
          }
          if (this.stallReloads < 3 && this.source !== null) {
            this.stallReloads++;
            const pos: number = this.state.positionMs;
            setTimeout(() => {
              this.reloadAt(pos);
            }, 600);
            return;
          }
          this.state.error = FsErrorText.DECODE;
          this.state.loading = false;
          this.state.playing = false;
          this.emit();
        }
      };
      const seekListener: OnSeekCompleteListener = {
        onSeekComplete: () => {
          this.state.buffering = false;
          if (this.wantPlaying && this.player !== null) {
            try {
              if (!this.player.isPlaying()) {
                this.player.start();
              }
              this.state.playing = true;
            } catch (err) {
              Logger.warn('IjkVideoEngine', 'seek 完成后续播失败');
            }
          }
          this.emit();
        }
      };
      const infoListener: OnInfoListener = {
        onInfo: (what: number, extra: number) => {
          if (what === INFO_BUFFERING_START) {
            this.state.buffering = true;
            this.emit();
          } else if (what === INFO_BUFFERING_END) {
            this.state.buffering = false;
            this.emit();
          }
        }
      };
      const sizeListener: OnVideoSizeChangedListener = {
        onVideoSizeChanged: (width: number, height: number, sarNum: number, sarDen: number) => {
          if (width > 0 && height > 0) {
            this.state.videoWidth = width;
            this.state.videoHeight = height;
            this.emit();
          }
        }
      };
      const timedTextListener: OnTimedTextListener = {
        onTimedText: (text: string) => {
          if (this.externalEnabled) {
            return;
          }
          const cleaned: string = IjkVideoEngine.cleanTimedText(text);
          if (this.state.subtitleText !== cleaned) {
            this.state.subtitleText = cleaned;
            this.emit();
          }
        }
      };
      player.setOnPreparedListener(preparedListener);
      player.setOnCompletionListener(completionListener);
      player.setOnBufferingUpdateListener(bufferingListener);
      player.setOnErrorListener(errorListener);
      player.setOnSeekCompleteListener(seekListener);
      player.setOnInfoListener(infoListener);
      player.setOnVideoSizeChangedListener(sizeListener);
      player.setOnTimedTextListener(timedTextListener);
      player.setMessageListener();

      player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, 'enable-accurate-seek', '1');
      player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, 'max-buffer-size', '8388608');
      player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, 'packet-buffering', '1');
      // 关键：打开字幕解码（默认关闭时 selectTrack 字幕轨不会启动解码线程）
      player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, 'subtitle', '1');
      // 由 onPrepared 统一 start
      player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, 'start-on-prepared', '0');

      player.setDataSource(url);
      if (useSurface) {
        try {
          const hdrResult: number = configureHdrWindow(surfaceId, hdrType);
          Logger.info('IjkVideoEngine', `HDR 窗口配置 hdrType=${hdrType} result=${hdrResult}`);
        } catch (err) {
          Logger.warn('IjkVideoEngine', 'HDR 窗口配置失败');
        }
      }
      player.prepareAsync();
      Logger.info('IjkVideoEngine', `启动 ${url} @${this.startMs}ms`);
    } catch (err) {
      Logger.error('IjkVideoEngine', '启动失败', err as Error);
      this.state.error = FsErrorText.DECODE;
      this.state.loading = false;
      this.emit();
    }
  }

  private handlePrepared(): void {
    const player: IjkMediaPlayer | null = this.player;
    if (player === null) {
      return;
    }
    this.prepared = true;
    this.state.loading = false;
    try {
      this.state.durationMs = player.getDuration();
      const width: number = player.getVideoWidth();
      const height: number = player.getVideoHeight();
      if (width > 0 && height > 0) {
        this.state.videoWidth = width;
        this.state.videoHeight = height;
      }
    } catch (err) {
      Logger.warn('IjkVideoEngine', '读取媒体信息失败');
    }
    if (this.startMs > 0) {
      try {
        player.seekTo(`${Math.floor(this.startMs)}`);
      } catch (err) {
        Logger.warn('IjkVideoEngine', '起播定位失败');
      }
    }
    try {
      player.start();
      this.state.playing = true;
      this.wantPlaying = true;
    } catch (err) {
      Logger.warn('IjkVideoEngine', '启动播放失败');
    }
    this.startPositionTimer();
    this.emit();
  }

  /** 以当前进度重新打开播放器 */
  private reloadAt(positionMs: number): void {
    const source: PlayableMedia | null = this.source;
    const context: object | undefined = this.context;
    if (source === null || context === undefined) {
      return;
    }
    const title: string = this.state.title;
    const savedReloads: number = this.stallReloads;
    this.open(source, title, context, positionMs, this.tracks, this.selectedAudioId,
      this.subtitleTracks, this.externalLabel, this.externalCues, this.surfaceId, this.hdrType);
    this.stallReloads = savedReloads;
  }

  private startPositionTimer(): void {
    this.clearPositionTimer();
    this.lastProgressMs = this.state.positionMs;
    this.lastProgressAt = Date.now();
    this.lastRecoverAt = 0;
    this.positionTimer = setInterval(() => {
      this.pollPosition();
    }, 500);
  }

  private clearPositionTimer(): void {
    if (this.positionTimer !== -1) {
      clearInterval(this.positionTimer);
      this.positionTimer = -1;
    }
  }

  private pollPosition(): void {
    const player: IjkMediaPlayer | null = this.player;
    if (player === null) {
      return;
    }
    const now: number = Date.now();
    try {
      const pos: number = player.getCurrentPosition();
      if (pos >= 0) {
        this.state.positionMs = pos;
      }
      const duration: number = player.getDuration();
      if (duration > 0) {
        this.state.durationMs = duration;
      }
      if (pos > this.lastProgressMs + 10) {
        this.lastProgressMs = pos;
        this.lastProgressAt = now;
        this.stallReloads = 0;
      }
      this.state.playing = player.isPlaying();
      if (this.wantPlaying && this.prepared && !this.state.playing &&
        now - this.lastProgressAt > 2500 && now - this.lastRecoverAt > 2500) {
        this.lastRecoverAt = now;
        this.state.buffering = false;
        if (this.stallReloads === 0) {
          this.stallReloads = 1;
          try {
            player.start();
            this.state.playing = true;
          } catch (err) {
            Logger.warn('IjkVideoEngine', '续播失败');
          }
        } else if (this.stallReloads < 3) {
          this.stallReloads++;
          this.reloadAt(this.state.positionMs);
          return;
        }
      }
      this.updateExternalSubtitle();
    } catch (err) {
      // 忽略瞬时读取失败
    }
    this.emit();
  }

  private updateExternalSubtitle(): void {
    if (!this.externalEnabled || this.externalCues.length === 0) {
      return;
    }
    const pos: number = this.state.positionMs;
    let text: string = '';
    for (const cue of this.externalCues) {
      if (pos >= cue.startMs && pos < cue.endMs) {
        text = cue.text;
        break;
      }
      if (cue.startMs > pos) {
        break;
      }
    }
    if (this.state.subtitleText !== text) {
      this.state.subtitleText = text;
    }
  }

  async toggle(): Promise<void> {
    const player: IjkMediaPlayer | null = this.player;
    if (player === null || !this.prepared) {
      return;
    }
    try {
      if (this.state.playing) {
        player.pause();
        this.state.playing = false;
        this.wantPlaying = false;
      } else {
        player.start();
        this.state.playing = true;
        this.wantPlaying = true;
      }
      this.emit();
    } catch (err) {
      Logger.error('IjkVideoEngine', '切换播放状态失败', err as Error);
    }
  }

  seekTo(positionMs: number): void {
    const player: IjkMediaPlayer | null = this.player;
    if (player === null) {
      return;
    }
    let target: number = positionMs;
    if (target < 0) {
      target = 0;
    }
    if (this.state.durationMs > 0 && target > this.state.durationMs) {
      target = this.state.durationMs;
    }
    this.state.positionMs = target;
    this.state.buffering = true;
    this.emit();
    try {
      player.seekTo(`${Math.floor(target)}`);
      this.armSeekResume();
    } catch (err) {
      this.state.buffering = false;
      this.emit();
      Logger.warn('IjkVideoEngine', 'seek 失败');
    }
  }

  private armSeekResume(): void {
    this.clearSeekResumeTimer();
    this.seekResumeTimer = setTimeout(() => {
      this.seekResumeTimer = -1;
      const player: IjkMediaPlayer | null = this.player;
      if (player === null) {
        return;
      }
      this.state.buffering = false;
      if (this.wantPlaying) {
        try {
          if (!player.isPlaying()) {
            player.start();
          }
          this.state.playing = true;
        } catch (err) {
          Logger.warn('IjkVideoEngine', 'seek 后续播失败');
        }
      }
      this.emit();
    }, 1200);
  }

  private clearSeekResumeTimer(): void {
    if (this.seekResumeTimer !== -1) {
      clearTimeout(this.seekResumeTimer);
      this.seekResumeTimer = -1;
    }
  }

  setSpeed(speed: number): void {
    this.speed = speed;
    const player: IjkMediaPlayer | null = this.player;
    if (player === null || !this.prepared) {
      return;
    }
    try {
      player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, 'soundtouch', '1');
      player.setSpeed(`${speed}f`);
      this.state.speed = speed;
      this.emit();
    } catch (err) {
      Logger.warn('IjkVideoEngine', '设置倍速失败');
    }
  }

  selectTrack(index: number): void {
    const player: IjkMediaPlayer | null = this.player;
    if (player === null) {
      return;
    }
    if (index < 0 && index !== IjkVideoEngine.EXTERNAL_SUBTITLE_INDEX) {
      this.deselectInternalSubtitle(player);
      this.externalEnabled = false;
      this.state.selectedSubtitleId = -1;
      this.state.subtitleText = '';
      this.emit();
      return;
    }
    if (index === IjkVideoEngine.EXTERNAL_SUBTITLE_INDEX) {
      this.deselectInternalSubtitle(player);
      this.externalEnabled = true;
      this.state.selectedSubtitleId = index;
      this.state.subtitleText = '';
      this.updateExternalSubtitle();
      this.emit();
      return;
    }
    for (const track of this.state.subtitleTracks) {
      if (track.index === index && track.isSubtitle) {
        this.externalEnabled = false;
        this.state.subtitleText = '';
        try {
          player.selectTrack(`${index}`);
          this.internalSubtitleId = index;
          this.state.selectedSubtitleId = index;
          this.emit();
        } catch (err) {
          Logger.warn('IjkVideoEngine', `切换字幕失败: ${index}`);
        }
        return;
      }
    }
    try {
      player.selectTrack(`${index}`);
      this.state.selectedAudioId = index;
      this.emit();
    } catch (err) {
      Logger.warn('IjkVideoEngine', `切换音轨失败: ${index}`);
    }
  }

  private deselectInternalSubtitle(player: IjkMediaPlayer): void {
    if (this.internalSubtitleId < 0) {
      return;
    }
    try {
      player.deselectTrack(`${this.internalSubtitleId}`);
    } catch (err) {
      Logger.debug('IjkVideoEngine', '取消字幕失败');
    }
    this.internalSubtitleId = -1;
  }

  private showNotice(text: string): void {
    this.state.notice = text;
    this.emit();
    if (this.noticeTimer !== -1) {
      clearTimeout(this.noticeTimer);
    }
    this.noticeTimer = setTimeout(() => {
      this.noticeTimer = -1;
      this.state.notice = '';
      this.emit();
    }, 6000);
  }

  static cleanTimedText(raw: string): string {
    if (raw === undefined || raw === null) {
      return '';
    }
    let out: string = '';
    for (let i = 0; i < raw.length; i++) {
      const code: number = raw.charCodeAt(i);
      if (code === 0) {
        break;
      }
      if (code >= 32 || code === 10 || code === 13 || code === 9) {
        out += raw.charAt(i);
      }
    }
    return out.trim();
  }

  durationMs(): number {
    return this.state.durationMs;
  }

  positionMs(): number {
    return this.state.positionMs;
  }

  release(): void {
    this.clearPositionTimer();
    this.clearSeekResumeTimer();
    if (this.noticeTimer !== -1) {
      clearTimeout(this.noticeTimer);
      this.noticeTimer = -1;
    }
    const player: IjkMediaPlayer | null = this.player;
    this.player = null;
    this.prepared = false;
    this.wantPlaying = true;
    this.stallReloads = 0;
    this.externalEnabled = false;
    this.internalSubtitleId = -1;
    this.surfaceId = '';
    this.hdrType = 0;
    this.state.subtitleText = '';
    if (player === null) {
      return;
    }
    try {
      player.stop();
    } catch (err) {
      Logger.warn('IjkVideoEngine', '停止失败');
    }
    try {
      player.release();
    } catch (err) {
      Logger.warn('IjkVideoEngine', '释放失败');
    }
  }
}