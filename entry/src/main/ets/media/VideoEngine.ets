import { media } from '@kit.MediaKit';
import { FsErrorText, PlayableMedia } from '../data/fs/FileSystemClient';
import { MediaDefaults, TrackOption, VideoState } from './MediaTypes';
import { Logger } from '../utils/Logger';

type VideoListener = (state: VideoState) => void;

/** 视频播放引擎：AVPlayer + XComponent Surface（规范 §9.1 通用格式路径） */
export class VideoEngine {
  private player: media.AVPlayer | null = null;
  private state: VideoState = MediaDefaults.videoState('');
  private listener: VideoListener = () => {
  };

  onChange(listener: VideoListener): void {
    this.listener = listener;
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
      audioTracks: this.state.audioTracks,
      subtitleTracks: this.state.subtitleTracks,
      selectedAudioId: this.state.selectedAudioId,
      selectedSubtitleId: this.state.selectedSubtitleId,
      error: this.state.error
    };
  }

  private emit(): void {
    this.listener(this.snapshot());
  }

  async open(source: PlayableMedia, title: string, surfaceId: string): Promise<void> {
    await this.release();
    this.state = MediaDefaults.videoState(title);
    this.emit();
    try {
      const player: media.AVPlayer = await media.createAVPlayer();
      this.player = player;
      player.on('stateChange', (next: media.AVPlayerState) => {
        this.handleState(next);
      });
      player.on('timeUpdate', (time: number) => {
        this.state.positionMs = time;
        this.emit();
      });
      player.on('durationUpdate', (time: number) => {
        if (time > 0) {
          this.state.durationMs = time;
          this.emit();
        }
      });
      player.on('error', (err: Error) => {
        Logger.error('VideoEngine', '播放器错误', err);
        this.state.error = FsErrorText.DECODE;
        this.state.loading = false;
        this.emit();
      });
      if (surfaceId.length > 0) {
        player.surfaceId = surfaceId;
      }
      if (source.fd >= 0) {
        const descriptor: media.AVFileDescriptor = { fd: source.fd, offset: 0, length: -1 };
        player.fdSrc = descriptor;
      } else if (source.url.length > 0) {
        player.url = source.url;
      } else {
        player.url = source.path;
      }
    } catch (err) {
      Logger.error('VideoEngine', '创建播放器失败', err as Error);
      this.state.error = FsErrorText.DECODE;
      this.state.loading = false;
      this.emit();
    }
  }

  private handleState(next: media.AVPlayerState): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    if (next === 'initialized') {
      player.prepare().catch((err: Error) => {
        Logger.error('VideoEngine', 'prepare 失败', err);
        this.state.error = FsErrorText.DECODE;
        this.state.loading = false;
        this.emit();
      });
      return;
    }
    if (next === 'prepared') {
      this.state.loading = false;
      this.state.durationMs = player.duration;
      this.emit();
      player.play().catch((err: Error) => {
        Logger.error('VideoEngine', 'play 失败', err);
      });
      return;
    }
    if (next === 'playing') {
      this.state.playing = true;
      this.state.loading = false;
      this.emit();
      return;
    }
    if (next === 'paused' || next === 'completed' || next === 'stopped') {
      this.state.playing = false;
      this.emit();
      return;
    }
    if (next === 'error') {
      this.state.error = FsErrorText.DECODE;
      this.state.loading = false;
      this.emit();
    }
  }

  async toggle(): Promise<void> {
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    try {
      if (this.state.playing) {
        await player.pause();
      } else {
        await player.play();
      }
    } catch (err) {
      Logger.error('VideoEngine', '切换播放状态失败', err as Error);
    }
  }

  seekTo(positionMs: number): void {
    const player: media.AVPlayer | null = this.player;
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
    try {
      player.seek(target);
      this.state.positionMs = target;
      this.emit();
    } catch (err) {
      Logger.warn('VideoEngine', 'seek 失败');
    }
  }

  setSpeed(speed: number): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    try {
      player.setSpeed(speed);
      this.state.speed = speed;
      this.emit();
    } catch (err) {
      Logger.warn('VideoEngine', '设置倍速失败');
    }
  }

  async loadTracks(): Promise<TrackOption[]> {
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return [];
    }
    const options: TrackOption[] = [];
    try {
      const tracks: Array<media.MediaDescription> = await player.getTrackDescription();
      for (const track of tracks) {
        const index: number = track.trackIndex === undefined ? -1 : Number(track.trackIndex);
        const isSubtitle: boolean = track.trackType === 'TEXT';
        const label: string = isSubtitle ? `字幕 ${index + 1}` : `音轨 ${index + 1}`;
        options.push({ index: index, label: label, isSubtitle: isSubtitle });
      }
      for (const option of options) {
        if (option.isSubtitle) {
          this.state.subtitleTracks.push(option);
        } else {
          this.state.audioTracks.push(option);
        }
      }
      this.emit();
    } catch (err) {
      Logger.warn('VideoEngine', '读取轨道信息失败');
    }
    return options;
  }

  /**
   * 选择轨道。当前 SDK 的 AVPlayer 未开放 selectTrack，这里仅记录选择状态；
   * 真正的轨道切换在后续版本通过原生引擎实现（见 docs/DEVIATIONS.md）。
   */
  selectTrack(index: number): void {
    if (index < 0) {
      this.state.selectedSubtitleId = -1;
      this.emit();
      return;
    }
    for (const track of this.state.audioTracks) {
      if (track.index === index) {
        this.state.selectedAudioId = index;
      }
    }
    for (const track of this.state.subtitleTracks) {
      if (track.index === index) {
        this.state.selectedSubtitleId = index;
      }
    }
    this.emit();
  }

  positionMs(): number {
    return this.state.positionMs;
  }

  durationMs(): number {
    return this.state.durationMs;
  }

  async release(): Promise<void> {
    const player: media.AVPlayer | null = this.player;
    this.player = null;
    if (player === null) {
      return;
    }
    try {
      await player.release();
    } catch (err) {
      Logger.warn('VideoEngine', '释放播放器失败');
    }
  }
}
