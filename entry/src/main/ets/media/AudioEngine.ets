import { media } from '@kit.MediaKit';
import { avSession as avSessionKit } from '@kit.AVSessionKit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { FsErrorText, PlayableMedia } from '../data/fs/FileSystemClient';
import { MediaDefaults, AudioState, PlaylistItem } from './MediaTypes';
import { Logger } from '../utils/Logger';

type AudioListener = (state: AudioState) => void;

export interface AudioMetadata {
  title: string;
  artist: string;
  album: string;
  albumArt: image.PixelMap | null;
}

/** 音频播放引擎：AVPlayer + AVSession 后台播放（规范 §9.6） */
export class AudioEngine {
  private player: media.AVPlayer | null = null;
  private state: AudioState = MediaDefaults.audioState();
  private listener: AudioListener = () => {
  };
  private session: avSessionKit.AVSession | null = null;
  private onNextRequest: () => void = () => {
  };
  private onPreviousRequest: () => void = () => {
  };

  onChange(listener: AudioListener): void {
    this.listener = listener;
  }

  bindSessionCommands(onNext: () => void, onPrevious: () => void): void {
    this.onNextRequest = onNext;
    this.onPreviousRequest = onPrevious;
  }

  setPlaylistState(playlist: PlaylistItem[], index: number): void {
    this.state.playlist = playlist;
    this.state.playlistIndex = index;
    this.emit();
  }

  private snapshot(): AudioState {
    return {
      loading: this.state.loading,
      title: this.state.title,
      artist: this.state.artist,
      album: this.state.album,
      playing: this.state.playing,
      durationMs: this.state.durationMs,
      positionMs: this.state.positionMs,
      speed: this.state.speed,
      albumArt: this.state.albumArt,
      playlist: this.state.playlist,
      playlistIndex: this.state.playlistIndex,
      lyrics: this.state.lyrics,
      lyricsLoading: this.state.lyricsLoading,
      lyricsError: this.state.lyricsError
    };
  }

  private emit(): void {
    this.listener(this.snapshot());
  }

  /** 切换曲目时清空旧信息（规范 §9.5：旧任务不得覆盖新曲） */
  resetForTrack(index: number): void {
    const playlist = this.state.playlist;
    this.state = MediaDefaults.audioState();
    this.state.playlist = playlist;
    this.state.playlistIndex = index;
    this.emit();
  }

  setMetadata(meta: AudioMetadata): void {
    this.state.title = meta.title;
    this.state.artist = meta.artist;
    this.state.album = meta.album;
    this.state.albumArt = meta.albumArt;
    this.emit();
    this.publishSessionMetadata();
  }

  setLyrics(lyric: string | null, error: string | null): void {
    this.state.lyrics = lyric;
    this.state.lyricsError = error;
    this.state.lyricsLoading = false;
    this.emit();
  }

  setLyricsLoading(): void {
    this.state.lyricsLoading = true;
    this.emit();
  }

  async open(source: PlayableMedia): Promise<void> {
    await this.releasePlayer();
    this.state.loading = true;
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
        this.publishSessionState();
      });
      player.on('error', (err: Error) => {
        Logger.error('AudioEngine', '播放器错误', err);
        this.state.loading = false;
        this.state.lyricsError = FsErrorText.DECODE;
        this.emit();
      });
      if (source.fd >= 0) {
        const descriptor: media.AVFileDescriptor = { fd: source.fd, offset: 0, length: -1 };
        player.fdSrc = descriptor;
      } else if (source.url.length > 0) {
        player.url = source.url;
      } else {
        player.url = source.path;
      }
    } catch (err) {
      Logger.error('AudioEngine', '创建音频播放器失败', err as Error);
      this.state.loading = false;
      this.state.lyricsError = FsErrorText.DECODE;
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
        Logger.error('AudioEngine', 'prepare 失败', err);
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
        Logger.error('AudioEngine', 'play 失败', err);
      });
      return;
    }
    if (next === 'playing') {
      this.state.playing = true;
      this.state.loading = false;
      this.emit();
      this.publishSessionState();
      return;
    }
    if (next === 'paused') {
      this.state.playing = false;
      this.emit();
      this.publishSessionState();
      return;
    }
    if (next === 'completed') {
      this.state.playing = false;
      this.emit();
      this.onNextRequest();
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
      Logger.error('AudioEngine', '切换播放失败', err as Error);
    }
  }

  seekTo(positionMs: number): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    let target: number = positionMs < 0 ? 0 : positionMs;
    if (this.state.durationMs > 0 && target > this.state.durationMs) {
      target = this.state.durationMs;
    }
    try {
      player.seek(target);
      this.state.positionMs = target;
      this.emit();
    } catch (err) {
      Logger.warn('AudioEngine', 'seek 失败');
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
      Logger.warn('AudioEngine', '设置倍速失败');
    }
  }

  /** 读取元数据（标题/艺术家/专辑/封面） */
  static async readMetadata(source: PlayableMedia, fallbackName: string): Promise<AudioMetadata> {
    const result: AudioMetadata = { title: fallbackName, artist: '', album: '', albumArt: null };
    let extractor: media.AVMetadataExtractor | null = null;
    try {
      extractor = await media.createAVMetadataExtractor();
      if (source.fd >= 0) {
        extractor.fdSrc = { fd: source.fd, offset: 0, length: -1 };
      }
      const meta: media.AVMetadata = await extractor.fetchMetadata();
      if (meta.title !== undefined && meta.title.length > 0) {
        result.title = meta.title;
      }
      if (meta.artist !== undefined) {
        result.artist = meta.artist;
      }
      if (meta.album !== undefined) {
        result.album = meta.album;
      }
      try {
        result.albumArt = await extractor.fetchAlbumCover();
      } catch (err) {
        result.albumArt = null;
      }
    } catch (err) {
      Logger.warn('AudioEngine', '读取音频元数据失败');
    } finally {
      if (extractor !== null) {
        try {
          await extractor.release();
        } catch (err) {
          Logger.warn('AudioEngine', '释放元数据解析器失败');
        }
      }
    }
    return result;
  }

  async ensureSession(context: common.UIAbilityContext): Promise<void> {
    if (this.session !== null) {
      return;
    }
    try {
      const session: avSessionKit.AVSession = await avSessionKit.createAVSession(context, 'TomatoTV', 'audio');
      this.session = session;
      session.on('play', () => {
        this.toggle();
      });
      session.on('pause', () => {
        this.toggle();
      });
      session.on('playNext', () => {
        this.onNextRequest();
      });
      session.on('playPrevious', () => {
        this.onPreviousRequest();
      });
      await session.activate();
    } catch (err) {
      Logger.warn('AudioEngine', '创建 AVSession 失败，后台控制不可用');
      this.session = null;
    }
  }

  private publishSessionMetadata(): void {
    const session: avSessionKit.AVSession | null = this.session;
    if (session === null) {
      return;
    }
    const metadata: avSessionKit.AVMetadata = {
      assetId: 'tomato_tv_audio',
      title: this.state.title,
      artist: this.state.artist,
      album: this.state.album
    };
    if (this.state.albumArt !== null) {
      metadata.mediaImage = this.state.albumArt;
    }
    session.setAVMetadata(metadata).catch((err: Error) => {
      Logger.warn('AudioEngine', '更新会话元数据失败');
    });
  }

  private publishSessionState(): void {
    const session: avSessionKit.AVSession | null = this.session;
    if (session === null) {
      return;
    }
    const state: avSessionKit.AVPlaybackState = {
      state: this.state.playing ? avSessionKit.PlaybackState.PLAYBACK_STATE_PLAY :
        avSessionKit.PlaybackState.PLAYBACK_STATE_PAUSE,
      speed: this.state.speed,
      position: { elapsedTime: this.state.positionMs, updateTime: Date.now() }
    };
    session.setAVPlaybackState(state).catch((err: Error) => {
      Logger.warn('AudioEngine', '更新会话播放状态失败');
    });
  }

  async releasePlayer(): Promise<void> {
    const player: media.AVPlayer | null = this.player;
    this.player = null;
    if (player === null) {
      return;
    }
    try {
      await player.release();
    } catch (err) {
      Logger.warn('AudioEngine', '释放音频播放器失败');
    }
  }

  async release(): Promise<void> {
    await this.releasePlayer();
    const session: avSessionKit.AVSession | null = this.session;
    this.session = null;
    if (session !== null) {
      try {
        await session.destroy();
      } catch (err) {
        Logger.warn('AudioEngine', '销毁会话失败');
      }
    }
  }
}
