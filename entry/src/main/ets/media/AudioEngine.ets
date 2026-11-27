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
  private openGeneration: number = 0;
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
      lyricsError: this.state.lyricsError,
      playbackError: this.state.playbackError
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
    // 先展示新曲的文件名，避免加载期间回退到"最初打开的那首歌"的名字
    if (index >= 0 && index < playlist.length) {
      this.state.title = playlist[index].name;
    }
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
    // 代际号：快速切歌时，旧 track 的异步 open 不得覆盖新 track 的 state/player
    const generation: number = this.openGeneration + 1;
    this.openGeneration = generation;
    await this.releasePlayer();
    if (generation !== this.openGeneration) {
      return;
    }
    this.state.loading = true;
    this.emit();
    try {
      const player: media.AVPlayer = await media.createAVPlayer();
      if (generation !== this.openGeneration) {
        player.release().catch((err: Error) => {
          Logger.warn('AudioEngine', '释放过期的音频播放器失败');
        });
        return;
      }
      this.player = player;
      player.on('stateChange', (next: media.AVPlayerState) => {
        this.handleState(player, next);
      });
      player.on('timeUpdate', (time: number) => {
        if (this.player !== player) {
          return;
        }
        this.state.positionMs = time;
        this.emit();
        this.publishSessionState();
      });
      player.on('error', (err: Error) => {
        if (this.player !== player) {
          return;
        }
        const code: number = err === undefined || err === null ? -1 : (err as BusinessError).code;
        const detail: string = err === undefined || err === null ? 'unknown' : `${code} ${err.message}`;
        Logger.error('AudioEngine',
          `播放器错误 state=${player.state} src=${source.url.length > 0 ? 'stream' : 'fd'} detail=${detail}`, err);
        this.state.loading = false;
        this.state.playbackError = FsErrorText.DECODE;
        this.emit();
      });
      if (source.fd >= 0) {
        const descriptor: media.AVFileDescriptor = { fd: source.fd, offset: 0, length: -1 };
        player.fdSrc = descriptor;
        Logger.info('AudioEngine', `使用本地 fd 播放 fd=${source.fd}`);
      } else if (source.url.length > 0) {
        player.url = source.url;
        Logger.info('AudioEngine', `使用流式地址播放 ${source.url}`);
      } else {
        player.url = source.path;
        Logger.info('AudioEngine', `使用本地路径播放 ${source.path}`);
      }
    } catch (err) {
      Logger.error('AudioEngine', '创建音频播放器失败', err as Error);
      if (generation !== this.openGeneration) {
        return;
      }
      this.state.loading = false;
      this.state.playbackError = FsErrorText.DECODE;
      this.emit();
    }
  }

  private handleState(player: media.AVPlayer, next: media.AVPlayerState): void {
    if (this.player !== player) {
      // 已被新 track 替换的旧播放器：迟到的状态回调直接丢弃
      return;
    }
    if (next === 'initialized') {
      player.prepare().catch((err: Error) => {
        Logger.error('AudioEngine', 'prepare 失败', err);
        if (this.player !== player) {
          return;
        }
        this.state.loading = false;
        this.emit();
      });
      return;
    }
    if (next === 'prepared') {
      this.state.loading = false;
      this.state.durationMs = player.duration;
      Logger.info('AudioEngine', `已就绪 duration=${player.duration}`);
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

  /**
   * 远程流式播放的元数据：把文件头部/尾部片段作为 dataSrc 交给解析器，
   * 既不整文件下载，又能读取 ID3/FLAC/MP4 头部的标题、艺术家和封面。
   * 头部/尾部片段之外的读取返回 -1（解析失败时退回文件名，不影响播放）。
   */
  static async readMetadataFromParts(head: ArrayBuffer, tail: ArrayBuffer, fileSize: number,
    fallbackName: string): Promise<AudioMetadata> {
    const result: AudioMetadata = { title: fallbackName, artist: '', album: '', albumArt: null };
    if (head.byteLength === 0) {
      return result;
    }
    const headBytes: Uint8Array = new Uint8Array(head);
    const tailBytes: Uint8Array = tail.byteLength > 0 ? new Uint8Array(tail) : new Uint8Array(0);
    const total: number = fileSize > 0 ? fileSize : headBytes.length;
    const tailStart: number = total - tailBytes.length;
    const callback = (buffer: ArrayBuffer, length: number, pos?: number): number => {
      const start: number = pos === undefined || pos < 0 ? 0 : pos;
      let data: Uint8Array;
      let base: number;
      if (start < headBytes.length) {
        data = headBytes;
        base = start;
      } else if (tailBytes.length > 0 && start >= tailStart) {
        data = tailBytes;
        base = start - tailStart;
      } else {
        return -1;
      }
      const available: number = data.length - base;
      if (available <= 0) {
        return -1;
      }
      const count: number = Math.min(length, available);
      new Uint8Array(buffer, 0, count).set(data.subarray(base, base + count));
      return count;
    };
    let extractor: media.AVMetadataExtractor | null = null;
    try {
      extractor = await media.createAVMetadataExtractor();
      const descriptor: media.AVDataSrcDescriptor = { fileSize: total, callback: callback };
      extractor.dataSrc = descriptor;
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
      Logger.info('AudioEngine',
        `流式元数据 title=${result.title} artist=${result.artist} cover=${result.albumArt !== null}`);
    } catch (err) {
      Logger.warn('AudioEngine', '流式元数据读取失败，使用文件名');
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

  /** 读取元数据（标题/艺术家/专辑/封面） */
  static async readMetadata(source: PlayableMedia, fallbackName: string): Promise<AudioMetadata> {
    const result: AudioMetadata = { title: fallbackName, artist: '', album: '', albumArt: null };
    // 远程流式播放时元数据解析器只能读 fd/dataSrc，读 URL 会失败；
    // 为了不把整个音频文件下载下来，流式播放先用文件名，元数据留空。
    if (source.fd < 0 && source.url.length > 0) {
      Logger.info('AudioEngine', '流式播放跳过元数据读取');
      return result;
    }
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
    // 让所有在途的 open 失效，避免页面退出后旧播放器继续写状态
    this.openGeneration++;
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
