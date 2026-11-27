import { common } from '@kit.AbilityKit';
import { KeyCode } from '@kit.InputKit';
import { AppContainer } from '../../app/AppContainer';
import { FileEntry } from '../../model/FileEntry';
import { PreviewKind } from '../../model/FileKinds';
import { FileSource } from '../../model/FileSource';
import { MediaParam, NavDefaults } from '../../navigation/AppNav';
import { AudioEngine, AudioMetadata } from '../../media/AudioEngine';
import { MediaDefaults, AudioState, PlaybackSpeeds, PlaylistItem } from '../../media/MediaTypes';
import { LyricsRepository } from '../../media/LyricsRepository';
import { PlayableMedia } from '../../data/fs/FileSystemClient';
import { Fmt } from '../../utils/Format';
import { Symbols } from '../../components/Symbols';
import { Logger } from '../../utils/Logger';
import { WindowTheme } from '../../utils/WindowTheme';

/** 音频播放页（规范 §7.11）：当前目录播放列表、封面、歌词、后台播放 */
@Component
export struct AudioPlayerPage {
  stack: NavPathStack = new NavPathStack();
  param: MediaParam = NavDefaults.media();

  @State audioState: AudioState = MediaDefaults.audioState();
  @State showInfo: boolean = false;
  @State sheetMode: string = 'none';
  @State speedLabel: string = '1x';
  @State infoFormat: string = '';
  @State infoSize: number = 0;

  private engine: AudioEngine = new AudioEngine();
  private container: AppContainer = AppContainer.get();
  private loadToken: number = 0;
  private usedStream: boolean = false;
  private retriedCache: boolean = false;
  private playlistEntries: FileEntry[] = [];

  aboutToAppear(): void {
    WindowTheme.light();
    this.engine.onChange((state: AudioState) => {
      this.audioState = state;
      this.speedLabel = PlaybackSpeeds.label(state.speed);
      // 只有播放器本身失败才回退到整文件缓存；歌词缺失/查询失败不触发回退
      if (state.playbackError !== null && this.usedStream && !this.retriedCache) {
        this.retriedCache = true;
        Logger.warn('AudioPlayerPage', '流式播放失败，回退为本地缓存播放');
        this.playIndex(this.audioState.playlistIndex);
      }
    });
    this.engine.bindSessionCommands(() => {
      this.playIndex(this.audioState.playlistIndex + 1);
    }, () => {
      this.playIndex(this.audioState.playlistIndex - 1);
    });
    const context: common.UIAbilityContext | null = this.container.context();
    if (context !== null) {
      this.engine.ensureSession(context);
    }
    this.bootstrap();
  }

  aboutToDisappear(): void {
    WindowTheme.light();
    this.engine.release();
  }

  private async bootstrap(): Promise<void> {
    const source: FileSource | null = this.container.findSource(this.param.sourceId);
    if (source === null) {
      return;
    }
    try {
      const parent: string = AudioPlayerPage.parentOf(this.param.path);
      const entries: FileEntry[] = await this.container.repository!.list(source, parent);
      const playlist: PlaylistItem[] = [];
      let index: number = 0;
      this.playlistEntries = [];
      for (const entry of entries) {
        if (!entry.isDirectory && entry.kind === PreviewKind.AUDIO) {
          if (entry.path === this.param.path) {
            index = playlist.length;
          }
          playlist.push({ path: entry.path, name: entry.name, size: entry.size });
          this.playlistEntries.push(entry);
        }
      }
      if (playlist.length === 0) {
        playlist.push({ path: this.param.path, name: this.param.name, size: this.param.size });
      }
      this.engine.setPlaylistState(playlist, index);
      await this.playIndex(index);
    } catch (err) {
      Logger.error('AudioPlayerPage', '构建播放列表失败', err as Error);
      this.engine.setPlaylistState([{ path: this.param.path, name: this.param.name, size: this.param.size }], 0);
      await this.playIndex(0);
    }
  }

  private static extensionOf(name: string): string {
    const dot: number = name.lastIndexOf('.');
    return dot > 0 && dot < name.length - 1 ? name.substring(dot + 1).toUpperCase() : '';
  }

  private static parentOf(path: string): string {
    const trimmed: string = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    const slash: number = trimmed.lastIndexOf('/');
    return slash > 0 ? trimmed.substring(0, slash) : '/';
  }

  private async playIndex(index: number): Promise<void> {
    const playlist: PlaylistItem[] = this.audioState.playlist;
    if (playlist.length === 0) {
      return;
    }
    let target: number = index;
    if (target < 0) {
      target = playlist.length - 1;
    }
    if (target >= playlist.length) {
      target = 0;
    }
    const source: FileSource | null = this.container.findSource(this.param.sourceId);
    if (source === null) {
      return;
    }
    const token: number = this.loadToken + 1;
    this.loadToken = token;
    this.engine.resetForTrack(target);
    const item: PlaylistItem = playlist[target];
    this.infoSize = item.size;
    this.infoFormat = AudioPlayerPage.extensionOf(item.name);
    const allowStream: boolean = !this.retriedCache;
    // 只有"这一次重试"走缓存；后续切歌重新尝试流式播放
    this.retriedCache = false;
    try {
      const playable: PlayableMedia = await this.container.repository!.playable(source, {
        name: item.name,
        path: item.path,
        isDirectory: false,
        size: item.size,
        lastModified: 0,
        mimeType: '',
        kind: PreviewKind.AUDIO
      }, allowStream);
      this.usedStream = playable.url.length > 0;
      Logger.info('AudioPlayerPage', `播放来源: ${this.usedStream ? 'stream ' + playable.url : 'fd ' + playable.fd}`);
      if (token !== this.loadToken) {
        return;
      }
      await this.engine.open(playable);
      if (token !== this.loadToken) {
        return;
      }
      // 先落到当前曲目的文件名，元数据解析完成后再覆盖
      this.engine.setMetadata({ title: item.name, artist: '', album: '', albumArt: null });
      const metadata: AudioMetadata = this.usedStream
        ? await this.readStreamMetadata(source, item, playable)
        : await AudioEngine.readMetadata(playable, item.name);
      if (token !== this.loadToken) {
        return;
      }
      this.engine.setMetadata(metadata);
      this.engine.setLyricsLoading();
      const lyric: string | null = await LyricsRepository.search(metadata.title, metadata.artist);
      if (token !== this.loadToken) {
        return;
      }
      this.engine.setLyrics(lyric, lyric === null ? '暂无歌词' : null);
    } catch (err) {
      Logger.error('AudioPlayerPage', '播放失败', err as Error);
      if (token === this.loadToken) {
        this.engine.setLyrics(null, '这个媒体无法解码或格式不受支持');
      }
    }
  }

  /** 流式音频：只读文件头尾片段解析标题/艺术家/封面，不整文件下载 */
  private async readStreamMetadata(source: FileSource, item: PlaylistItem,
    playable: PlayableMedia): Promise<AudioMetadata> {
    const fallback: AudioMetadata = { title: item.name, artist: '', album: '', albumArt: null };
    const client = await this.container.repository!.clientFor(source);
    const fileSize: number = item.size > 0 ? item.size : 0;
    const headLength: number = fileSize > 0 ? Math.min(fileSize, 512 * 1024) : 512 * 1024;
    const tailLength: number = fileSize > 0 ? Math.min(fileSize, 256 * 1024) : 0;
    try {
      const head: ArrayBuffer = await client.readRange(item.path, 0, headLength);
      let tail: ArrayBuffer = new ArrayBuffer(0);
      if (tailLength > 0 && fileSize > headLength) {
        tail = await client.readRange(item.path, fileSize - tailLength, tailLength);
      }
      return await AudioEngine.readMetadataFromParts(head, tail, fileSize, item.name);
    } catch (err) {
      Logger.warn('AudioPlayerPage', '流式元数据读取失败');
      void playable;
      return fallback;
    }
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Bottom }) {
        Column() {
          Row({ space: 8 }) {
            Button({ type: ButtonType.Circle }) {
              SymbolGlyph(Symbols.back()).fontSize(20).fontColor([$r('app.color.text_primary')])
            }
            .width(40)
            .height(40)
            .backgroundColor($r('app.color.surface_card'))
            .onClick(() => this.stack.pop())
            Blank()
            Button({ type: ButtonType.Circle }) {
              SymbolGlyph(Symbols.info()).fontSize(20).fontColor([$r('app.color.text_primary')])
            }
            .width(40)
            .height(40)
            .padding(0)
            .backgroundColor($r('app.color.surface_card'))
            .onClick(() => {
              this.openSheet('info');
            })
            .accessibilityText('音频信息')
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 12 })

          Blank()

          Column({ space: 16 }) {
            if (this.audioState.albumArt !== null) {
              Image(this.audioState.albumArt)
                .width(240)
                .height(240)
                .borderRadius($r('app.float.radius_sheet'))
                .objectFit(ImageFit.Cover)
            } else {
              Column() {
                SymbolGlyph(Symbols.music())
                  .fontSize(72)
                  .fontColor([$r('app.color.brand')])
              }
              .width(240)
              .height(240)
              .borderRadius($r('app.float.radius_sheet'))
              .backgroundColor($r('app.color.brand_soft'))
              .justifyContent(FlexAlign.Center)
            }

            Column({ space: 4 }) {
              Text(this.audioState.title.length > 0 ? this.audioState.title : '加载中…')
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.audioState.artist.length > 0 ?
                `${this.audioState.artist} · ${this.audioState.album}` : '未知艺术家')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .alignItems(HorizontalAlign.Center)
            .width('100%')
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)

          Blank()

          Column({ space: 8 }) {
            Slider({
              value: this.audioState.positionMs,
              min: 0,
              max: this.audioState.durationMs > 0 ? this.audioState.durationMs : 1,
              step: 1
            })
              .width('100%')
              .selectedColor($r('app.color.brand'))
              .onChange((value: number, mode: SliderChangeMode) => {
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.engine.seekTo(value);
                }
              })
            Row() {
              Text(Fmt.duration(this.audioState.positionMs))
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
              Blank()
              Text(Fmt.duration(this.audioState.durationMs))
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')

            Row({ space: 32 }) {
              Button({ type: ButtonType.Circle }) {
                SymbolGlyph(Symbols.previous()).fontSize(26).fontColor([$r('app.color.text_primary')])
              }
              .width(56)
              .height(56)
              .backgroundColor($r('app.color.surface_card'))
              .onClick(() => this.playIndex(this.audioState.playlistIndex - 1))
              .accessibilityText('上一首')

              Button({ type: ButtonType.Circle }) {
                SymbolGlyph(this.audioState.playing ? Symbols.pause() : Symbols.play())
                  .fontSize(30)
                  .fontColor([Color.White])
              }
              .width(72)
              .height(72)
              .backgroundColor($r('app.color.brand'))
              .onClick(() => {
                this.engine.toggle();
              })

              Button({ type: ButtonType.Circle }) {
                SymbolGlyph(Symbols.next()).fontSize(26).fontColor([$r('app.color.text_primary')])
              }
              .width(56)
              .height(56)
              .backgroundColor($r('app.color.surface_card'))
              .onClick(() => this.playIndex(this.audioState.playlistIndex + 1))
              .accessibilityText('下一首')
            }
            .justifyContent(FlexAlign.Center)
            .width('100%')

            Row({ space: 12 }) {
              Button(this.speedLabel)
                .height(34)
                .backgroundColor($r('app.color.surface_card'))
                .fontColor($r('app.color.text_primary'))
                .fontSize(13)
                .bindMenu(this.speedMenu())
              Button('列表')
                .height(34)
                .backgroundColor($r('app.color.surface_card'))
                .fontColor($r('app.color.text_primary'))
                .fontSize(13)
                .onClick(() => {
                  this.openSheet('playlist');
                })
              Button('歌词')
                .height(34)
                .backgroundColor($r('app.color.surface_card'))
                .fontColor($r('app.color.text_primary'))
                .fontSize(13)
                .onClick(() => {
                  this.openSheet('lyrics');
                })
            }
            .justifyContent(FlexAlign.Center)
            .width('100%')
          }
          .width('100%')
          .padding({ left: 20, right: 20, bottom: 24 })
        }
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.surface'))
      .onKeyEvent((event: KeyEvent) => {
        if (event.type !== KeyType.Down) {
          return;
        }
        const code: number = event.keyCode;
        if (code === KeyCode.KEYCODE_SPACE || code === KeyCode.KEYCODE_MEDIA_PLAY_PAUSE ||
          code === KeyCode.KEYCODE_ENTER || code === KeyCode.KEYCODE_DPAD_CENTER) {
          this.engine.toggle();
          return;
        }
        if (code === KeyCode.KEYCODE_DPAD_LEFT || code === KeyCode.KEYCODE_DPAD_UP) {
          this.playIndex(this.audioState.playlistIndex - 1);
          return;
        }
        if (code === KeyCode.KEYCODE_DPAD_RIGHT || code === KeyCode.KEYCODE_DPAD_DOWN) {
          this.playIndex(this.audioState.playlistIndex + 1);
        }
      })
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.surface'))
    .bindSheet(this.sheetVisible(), this.audioSheet(), {
      height: 460,
      dragBar: true,
      showClose: false,
      backgroundColor: $r('app.color.surface'),
      onDisappear: () => {
        this.openSheet('none');
      }
    })
    .onBackPressed((): boolean => false)
  }

  @Builder
  speedMenu() {
    Menu() {
      ForEach(PlaybackSpeeds.LIST, (speed: number) => {
        MenuItem({ content: PlaybackSpeeds.label(speed) })
          .onClick(() => this.engine.setSpeed(speed))
      }, (speed: number) => `sp${speed}`)
    }
  }

  private sheetVisible(): boolean {
    return this.sheetMode !== 'none';
  }

  private openSheet(mode: string): void {
    this.sheetMode = mode;
  }

  @Builder
  audioSheet() {
    if (this.sheetMode === 'playlist') {
      this.playlistSheet()
    } else if (this.sheetMode === 'lyrics') {
      this.lyricsSheet()
    } else if (this.sheetMode === 'info') {
      this.infoSheet()
    } else {
      Column() {
        Text('')
      }
      .width('100%')
      .height(1)
    }
  }

  @Builder
  infoSheet() {
    Column({ space: 12 }) {
      Text('音频信息')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      this.infoRow('文件名', this.audioState.title.length > 0 ? this.audioState.title : this.param.name)
      this.infoRow('艺术家', this.audioState.artist.length > 0 ? this.audioState.artist : '未知')
      this.infoRow('专辑', this.audioState.album.length > 0 ? this.audioState.album : '未知')
      this.infoRow('时长', Fmt.duration(this.audioState.durationMs))
      this.infoRow('大小', Fmt.size(this.infoSize > 0 ? this.infoSize : this.param.size))
      this.infoRow('格式', this.infoFormat.length > 0 ? this.infoFormat : '未知')
      this.infoRow('路径', this.param.path)
    }
    .width('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  infoRow(label: string, value: string) {
    Column({ space: 4 }) {
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      Text(value)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .copyOption(CopyOptions.LocalDevice)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor($r('app.color.surface_card'))
    .borderRadius($r('app.float.radius_small'))
  }

  @Builder
  playlistSheet() {
    Column({ space: 8 }) {
      Text('播放列表')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      List({ space: 4 }) {
        ForEach(this.audioState.playlist, (item: PlaylistItem, index: number) => {
          ListItem() {
            Row({ space: 8 }) {
              Text(`${index + 1}`)
                .fontSize(12)
                .fontColor(index === this.audioState.playlistIndex ? $r('app.color.brand') :
                  $r('app.color.text_secondary'))
                .width(24)
              Text(item.name)
                .fontSize(14)
                .fontColor(index === this.audioState.playlistIndex ? $r('app.color.brand') :
                  $r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .width('100%')
            .padding(10)
            .borderRadius($r('app.float.radius_small'))
            .backgroundColor(index === this.audioState.playlistIndex ? $r('app.color.brand_soft') :
              Color.Transparent)
            .onClick(() => {
              this.openSheet('none');
              this.playIndex(index);
            })
          }
        }, (item: PlaylistItem, index: number) => `${item.path}_${index}`)
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  lyricsSheet() {
    Column({ space: 12 }) {
      Text('歌词')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      if (this.audioState.lyricsLoading) {
        LoadingProgress().width(32).height(32).color($r('app.color.brand'))
      } else if (this.audioState.lyrics !== null) {
        Scroll() {
          Text(LyricsRepository.plainText(this.audioState.lyrics))
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .lineHeight(24)
            .width('100%')
        }
        .layoutWeight(1)
        .align(Alignment.Top)
      } else {
        Text(this.audioState.lyricsError !== null ? this.audioState.lyricsError : '暂无歌词')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
      }
    }
    .width('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
  }
}
