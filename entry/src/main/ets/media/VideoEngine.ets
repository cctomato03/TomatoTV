import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { FsErrorText, PlayableMedia } from '../data/fs/FileSystemClient';
import { MediaDefaults, TrackOption, VideoState } from './MediaTypes';
import { Logger } from '../utils/Logger';

type VideoListener = (state: VideoState) => void;
/** 每次需要时取一次 SurfaceId（XComponent 刚创建时可能还拿不到，需要重试） */
type SurfaceProvider = () => string;

/** 视频播放引擎：AVPlayer + XComponent Surface（规范 §9.1 通用格式路径） */
export class VideoEngine {
  private player: media.AVPlayer | null = null;
  private state: VideoState = MediaDefaults.videoState('');
  private listener: VideoListener = () => {
  };
  private surfaceProvider: SurfaceProvider = () => '';
  private surfaceAttached: boolean = false;
  /** 是否已经开始出画面/出声：已经开始后出现的错误不再当作致命错误（常见于容器里的视频轨不支持） */
  private startedPlayback: boolean = false;

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

  async open(source: PlayableMedia, title: string, surfaceProvider: SurfaceProvider): Promise<void> {
    await this.release();
    this.state = MediaDefaults.videoState(title);
    this.surfaceProvider = surfaceProvider;
    this.surfaceAttached = false;
    this.startedPlayback = false;
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
        const detail: string = err === undefined || err === null ? 'unknown'
          : `${(err as BusinessError).code} ${err.message}`;
        const playerState: string = player.state;
        const alreadyRunning: boolean = this.startedPlayback || playerState === 'playing' ||
          playerState === 'prepared';
        if (alreadyRunning) {
          // 已经在播（有声/有画面）后报错：多为容器里的视频轨编码不受支持，
          // 这里只记录，不把界面切成"无法解码"
          Logger.warn('VideoEngine', `播放中收到错误（已忽略）: ${detail}`);
          this.state.buffering = false;
          this.emit();
          return;
        }
        Logger.error('VideoEngine', `播放器错误: ${detail}`, err);
        this.state.error = FsErrorText.DECODE;
        this.state.loading = false;
        this.emit();
      });
      this.attachSurface(player);
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

  /** 绑定渲染 Surface；XComponent 刚创建时 surfaceId 可能为空，这里会重试 */
  private attachSurface(player: media.AVPlayer): void {
    if (this.surfaceAttached) {
      return;
    }
    const surfaceId: string = this.surfaceProvider();
    if (surfaceId.length === 0) {
      Logger.warn('VideoEngine', '尚未取到 SurfaceId，稍后重试');
      return;
    }
    try {
      player.surfaceId = surfaceId;
      this.surfaceAttached = true;
      Logger.info('VideoEngine', `已绑定渲染 Surface: ${surfaceId}`);
    } catch (err) {
      Logger.error('VideoEngine', '设置 surfaceId 失败', err as Error);
    }
  }

  /**
   * 重新绑定 Surface：XComponent 被重建（尺寸变化、页面重排）后会触发 onLoad，
   * 此时旧的 surfaceId 已失效，必须重新设给播放器，否则表现为"只有声音没有画面"。
   */
  reattachSurface(): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    this.surfaceAttached = false;
    this.attachSurface(player);
  }

  private handleState(next: media.AVPlayerState): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    Logger.info('VideoEngine', `播放器状态: ${next}`);
    if (next === 'initialized') {
      // 视频只出声不出画面，通常就是这里 surfaceId 没绑上
      this.attachSurface(player);
      player.prepare().catch((err: Error) => {
        Logger.error('VideoEngine', 'prepare 失败', err);
        this.state.error = FsErrorText.DECODE;
        this.state.loading = false;
        this.emit();
      });
      return;
    }
    if (next === 'prepared') {
      // 兜底：initialized 阶段若还没拿到 SurfaceId，这里再试一次
      this.attachSurface(player);
      this.state.loading = false;
      this.state.durationMs = player.duration;
      Logger.info('VideoEngine',
        `已就绪 duration=${player.duration} size=${player.width}x${player.height} surface=${this.surfaceAttached}`);
      if (player.width === 0 || player.height === 0) {
        Logger.warn('VideoEngine', '播放器报告画面尺寸为 0：可能没有视频轨或编码不受支持');
      }
      this.emit();
      player.play().catch((err: Error) => {
        Logger.error('VideoEngine', 'play 失败', err);
      });
      return;
    }
    if (next === 'playing') {
      this.state.playing = true;
      this.state.loading = false;
      this.startedPlayback = true;
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
