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
  private surfaceTimer: number = -1;
  private tracksLoaded: boolean = false;
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
    this.tracksLoaded = false;
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
      player.on('videoSizeChange', (width: number, height: number) => {
        Logger.info('VideoEngine', `视频尺寸变化 ${width}x${height}`);
      });
      player.on('startRenderFrame', () => {
        Logger.info('VideoEngine', '首帧画面已渲染');
      });
      player.on('trackChange', (index: number, isSelected: boolean) => {
        this.handleTrackChange(index, isSelected);
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
      // 注意：surfaceId 必须在设置 url 之后（initialized）、prepare 之前绑定，
      // 提前绑定会被播放器丢弃，表现为"只有声音没有画面"。
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

  private clearSurfaceTimer(): void {
    if (this.surfaceTimer !== -1) {
      clearTimeout(this.surfaceTimer);
      this.surfaceTimer = -1;
    }
  }

  /** 把当前 SurfaceId 交给播放器，成功返回 true。必须在 initialized 之后、prepare 之前调用 */
  private attachSurface(player: media.AVPlayer): boolean {
    const surfaceId: string = this.surfaceProvider();
    if (surfaceId.length === 0) {
      Logger.warn('VideoEngine', '尚未取到 SurfaceId，稍后重试');
      return false;
    }
    try {
      player.surfaceId = surfaceId;
      this.surfaceAttached = true;
      Logger.info('VideoEngine', `已绑定渲染 Surface: ${surfaceId}`);
      return true;
    } catch (err) {
      Logger.error('VideoEngine', '设置 surfaceId 失败', err as Error);
      return false;
    }
  }

  private preparePlayer(player: media.AVPlayer): void {
    player.prepare().catch((err: Error) => {
      Logger.error('VideoEngine', 'prepare 失败', err);
      this.state.error = FsErrorText.DECODE;
      this.state.loading = false;
      this.emit();
    });
  }

  /**
   * SurfaceId 取不到时按 100ms 重试（最多约 2s）：拿到后再 prepare，
   * 保证起播时 surface 一定已经绑定。
   */
  private retryAttachThenPrepare(player: media.AVPlayer, attempt: number): void {
    if (this.player !== player) {
      return;
    }
    if (this.surfaceTimer !== -1) {
      return;
    }
    if (attempt > 20) {
      Logger.warn('VideoEngine', 'SurfaceId 始终不可用，仍继续 prepare');
      this.preparePlayer(player);
      return;
    }
    this.surfaceTimer = setTimeout(() => {
      this.surfaceTimer = -1;
      if (this.player !== player) {
        return;
      }
      if (this.attachSurface(player)) {
        this.preparePlayer(player);
        return;
      }
      this.retryAttachThenPrepare(player, attempt + 1);
    }, 100);
  }

  /** 播放中重建 Surface：只重绑，不再触发 prepare */
  private retryAttachOnly(player: media.AVPlayer, attempt: number): void {
    if (this.player !== player || this.surfaceTimer !== -1) {
      return;
    }
    if (attempt > 20) {
      Logger.warn('VideoEngine', '播放中 SurfaceId 始终不可用');
      return;
    }
    this.surfaceTimer = setTimeout(() => {
      this.surfaceTimer = -1;
      if (this.player !== player) {
        return;
      }
      if (!this.attachSurface(player)) {
        this.retryAttachOnly(player, attempt + 1);
      }
    }, 100);
  }

  /**
   * 重新绑定 Surface：XComponent 被重建（尺寸变化、页面重排、旋转屏幕）后会触发 onLoad，
   * 此时旧的 surfaceId 已失效，必须重新设给播放器，否则表现为"只有声音没有画面"。
   */
  reattachSurface(): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    this.clearSurfaceTimer();
    if (!this.attachSurface(player)) {
      this.retryAttachOnly(player, 0);
    }
  }

  private handleState(next: media.AVPlayerState): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    Logger.info('VideoEngine', `播放器状态: ${next}`);
    if (next === 'initialized') {
      // 必须先绑定 Surface 再 prepare，否则视频轨没有渲染目标（有声无画）
      if (this.attachSurface(player)) {
        this.preparePlayer(player);
      } else {
        this.retryAttachThenPrepare(player, 0);
      }
      return;
    }
    if (next === 'prepared') {
      if (!this.surfaceAttached) {
        this.attachSurface(player);
      }
      try {
        // 默认 VIDEO_SCALE_TYPE_FIT 会把画面拉伸铺满窗口，导致比例失真；
        // SCALED_ASPECT 保持原始比例并留黑边（API 20+，低版本失败时忽略）。
        player.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_SCALED_ASPECT;
      } catch (err) {
        Logger.warn('VideoEngine', '设置视频缩放模式失败');
      }
      this.state.loading = false;
      this.state.durationMs = player.duration;
      Logger.info('VideoEngine',
        `已就绪 duration=${player.duration} size=${player.width}x${player.height} surface=${this.surfaceAttached}`);
      if (player.width === 0 || player.height === 0) {
        Logger.warn('VideoEngine', '播放器报告画面尺寸为 0：可能没有视频轨或编码不受支持');
      }
      this.emit();
      this.loadTracks();
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

  private static readNumber(track: media.MediaDescription, key: string): number {
    const value: Object = track[key];
    const parsed: number = Number(value);
    return Number.isFinite(parsed) ? parsed : -1;
  }

  private static readText(track: media.MediaDescription, key: string): string {
    const value: Object = track[key];
    return typeof value === 'string' ? value : '';
  }

  private static trackLabel(prefix: string, order: number, name: string, language: string,
    codec: string): string {
    let detail: string = '';
    if (name.length > 0 && name !== 'audio' && name !== 'video' && name !== 'subtitle') {
      detail = name;
    } else if (codec.length > 0) {
      const slash: number = codec.lastIndexOf('/');
      detail = slash >= 0 ? codec.substring(slash + 1) : codec;
    }
    if (language.length > 0) {
      detail = detail.length > 0 ? `${detail} · ${language}` : language;
    }
    return detail.length > 0 ? `${prefix} ${order} · ${detail}` : `${prefix} ${order}`;
  }

  /** 读取容器内的音轨 / 字幕轨（必须在 prepared 之后调用），结果写入状态并返回 */
  async loadTracks(force: boolean = false): Promise<TrackOption[]> {
    const player: media.AVPlayer | null = this.player;
    if (player === null || (this.tracksLoaded && !force)) {
      return this.state.audioTracks.concat(this.state.subtitleTracks);
    }
    const audio: TrackOption[] = [];
    const subtitle: TrackOption[] = [];
    try {
      const tracks: Array<media.MediaDescription> = await player.getTrackDescription();
      Logger.info('VideoEngine', `轨道总数: ${tracks.length}`);
      let audioOrder: number = 0;
      let subtitleOrder: number = 0;
      for (const track of tracks) {
        const index: number = VideoEngine.readNumber(track, media.MediaDescriptionKey.MD_KEY_TRACK_INDEX);
        if (index < 0) {
          continue;
        }
        const type: number = VideoEngine.readNumber(track, media.MediaDescriptionKey.MD_KEY_TRACK_TYPE);
        const name: string = VideoEngine.readText(track, media.MediaDescriptionKey.MD_KEY_TRACK_NAME);
        const language: string = VideoEngine.readText(track, media.MediaDescriptionKey.MD_KEY_LANGUAGE);
        const codec: string = VideoEngine.readText(track, media.MediaDescriptionKey.MD_KEY_CODEC_MIME);
        Logger.info('VideoEngine',
          `轨道 ${index}: type=${type} name=${name} lang=${language} codec=${codec}`);
        if (type === media.MediaType.MEDIA_TYPE_AUD) {
          audioOrder++;
          const option: TrackOption = {
            index: index,
            label: VideoEngine.trackLabel('音轨', audioOrder, name, language, codec),
            isSubtitle: false
          };
          audio.push(option);
        } else if (type === media.MediaType.MEDIA_TYPE_SUBTITLE) {
          subtitleOrder++;
          const option: TrackOption = {
            index: index,
            label: VideoEngine.trackLabel('字幕', subtitleOrder, name, language, codec),
            isSubtitle: true
          };
          subtitle.push(option);
        }
      }
      this.state.audioTracks = audio;
      this.state.subtitleTracks = subtitle;
      this.state.selectedAudioId = audio.length > 0 ? audio[0].index : -1;
      this.state.selectedSubtitleId = -1;
      try {
        const selected: number[] = await player.getSelectedTracks();
        for (const selectedIndex of selected) {
          for (const track of audio) {
            if (track.index === selectedIndex) {
              this.state.selectedAudioId = selectedIndex;
            }
          }
          for (const track of subtitle) {
            if (track.index === selectedIndex) {
              this.state.selectedSubtitleId = selectedIndex;
            }
          }
        }
      } catch (err) {
        Logger.warn('VideoEngine', '读取当前选中轨道失败');
      }
      this.tracksLoaded = true;
      this.emit();
      Logger.info('VideoEngine', `轨道信息: 音轨 ${audio.length} 条, 字幕 ${subtitle.length} 条`);
    } catch (err) {
      Logger.warn('VideoEngine', '读取轨道信息失败');
    }
    return audio.concat(subtitle);
  }

  private async selectSubtitle(index: number): Promise<void> {
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    const previous: number = this.state.selectedSubtitleId;
    if (previous >= 0 && previous !== index) {
      try {
        await player.deselectTrack(previous);
      } catch (err) {
        Logger.debug('VideoEngine', '取消旧字幕轨失败');
      }
    }
    if (index < 0) {
      this.state.selectedSubtitleId = -1;
      this.emit();
      return;
    }
    try {
      await player.selectTrack(index);
      this.state.selectedSubtitleId = index;
      this.emit();
      Logger.info('VideoEngine', `已切换字幕轨: ${index}`);
    } catch (err) {
      Logger.warn('VideoEngine', `切换字幕失败: ${index}`);
    }
  }

  /** 选择轨道：index < 0 表示关闭字幕；音轨/字幕均通过 AVPlayer.selectTrack 真正切换 */
  async selectTrack(index: number): Promise<void> {
    if (index < 0) {
      await this.selectSubtitle(-1);
      return;
    }
    let isAudio: boolean = false;
    let isSubtitle: boolean = false;
    for (const track of this.state.audioTracks) {
      if (track.index === index) {
        isAudio = true;
      }
    }
    for (const track of this.state.subtitleTracks) {
      if (track.index === index) {
        isSubtitle = true;
      }
    }
    if (isSubtitle) {
      await this.selectSubtitle(index);
      return;
    }
    const player: media.AVPlayer | null = this.player;
    if (player === null || !isAudio) {
      return;
    }
    try {
      await player.selectTrack(index);
      this.state.selectedAudioId = index;
      this.emit();
      Logger.info('VideoEngine', `已切换音轨: ${index}`);
    } catch (err) {
      Logger.warn('VideoEngine', `切换音轨失败: ${index}`);
    }
  }

  /** 播放器上报轨道变化时同步界面上的选中状态 */
  private handleTrackChange(index: number, isSelected: boolean): void {
    let changed: boolean = false;
    for (const track of this.state.audioTracks) {
      if (track.index === index) {
        if (isSelected && this.state.selectedAudioId !== index) {
          this.state.selectedAudioId = index;
          changed = true;
        } else if (!isSelected && this.state.selectedAudioId === index) {
          this.state.selectedAudioId = -1;
          changed = true;
        }
      }
    }
    for (const track of this.state.subtitleTracks) {
      if (track.index === index) {
        if (isSelected && this.state.selectedSubtitleId !== index) {
          this.state.selectedSubtitleId = index;
          changed = true;
        } else if (!isSelected && this.state.selectedSubtitleId === index) {
          this.state.selectedSubtitleId = -1;
          changed = true;
        }
      }
    }
    Logger.info('VideoEngine', `轨道变化: index=${index} selected=${isSelected}`);
    if (changed) {
      this.emit();
    }
  }

  positionMs(): number {
    return this.state.positionMs;
  }

  durationMs(): number {
    return this.state.durationMs;
  }

  async release(): Promise<void> {
    this.clearSurfaceTimer();
    this.surfaceAttached = false;
    this.tracksLoaded = false;
    this.startedPlayback = false;
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
