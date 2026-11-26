import { common } from '@kit.AbilityKit';
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

/** 音频播放页（规范 §7.11）：当前目录播放列表、封面、歌词、后台播放 */
@Component
export struct AudioPlayerPage {
  stack: NavPathStack = new NavPathStack();
  param: MediaParam = NavDefaults.media();

  @State audioState: AudioState = MediaDefaults.audioState();
  @State showPlaylist: boolean = false;
  @State showLyrics: boolean = false;
  @State speedLabel: string = '1x';

  private engine: AudioEngine = new AudioEngine();
  private container: AppContainer = AppContainer.get();
  private loadToken: number = 0;
  private playlistEntries: FileEntry[] = [];

  aboutToAppear(): void {
    this.engine.onChange((state: AudioState) => {
      this.audioState = state;
      this.speedLabel = PlaybackSpeeds.label(state.speed);
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
          playlist.push({ path: entry.path, name: entry.name });
          this.playlistEntries.push(entry);
        }
      }
      if (playlist.length === 0) {
        playlist.push({ path: this.param.path, name: this.param.name });
      }
      this.engine.setPlaylistState(playlist, index);
      await this.playIndex(index);
    } catch (err) {
      Logger.error('AudioPlayerPage', '构建播放列表失败', err as Error);
      this.engine.setPlaylistState([{ path: this.param.path, name: this.param.name }], 0);
      await this.playIndex(0);
    }
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
    try {
      const playable: PlayableMedia = await this.container.repository!.playable(source, {
        name: item.name,
        path: item.path,
        isDirectory: false,
        size: 0,
        lastModified: 0,
        mimeType: '',
        kind: PreviewKind.AUDIO
      });
      if (token !== this.loadToken) {
        return;
      }
      await this.engine.open(playable);
      this.engine.setMetadata({ title: item.name, artist: '', album: '', albumArt: null });
      const metadata: AudioMetadata = await AudioEngine.readMetadata(playable, item.name);
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

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Bottom }) {
        Column() {
          Row({ space: 8 }) {
            Button({ type: ButtonType.Circle }) {
              SymbolGlyph(Symbols.back()).fontSize(20).fontColor([Color.White])
            }
            .width(40)
            .height(40)
            .backgroundColor($r('app.color.player_scrim'))
            .onClick(() => this.stack.pop())
            Blank()
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
              Text(this.audioState.title.length > 0 ? this.audioState.title : this.param.name)
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor(Color.White)
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
                SymbolGlyph(Symbols.previous()).fontSize(26).fontColor([Color.White])
              }
              .width(56)
              .height(56)
              .backgroundColor($r('app.color.player_scrim'))
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
                SymbolGlyph(Symbols.next()).fontSize(26).fontColor([Color.White])
              }
              .width(56)
              .height(56)
              .backgroundColor($r('app.color.player_scrim'))
              .onClick(() => this.playIndex(this.audioState.playlistIndex + 1))
              .accessibilityText('下一首')
            }
            .justifyContent(FlexAlign.Center)
            .width('100%')

            Row({ space: 12 }) {
              Button(this.speedLabel)
                .height(34)
                .backgroundColor($r('app.color.player_scrim'))
                .fontColor(Color.White)
                .fontSize(13)
                .bindMenu(this.speedMenu())
              Button('列表')
                .height(34)
                .backgroundColor($r('app.color.player_scrim'))
                .fontColor(Color.White)
                .fontSize(13)
                .onClick(() => {
                  this.showPlaylist = true;
                })
              Button('歌词')
                .height(34)
                .backgroundColor($r('app.color.player_scrim'))
                .fontColor(Color.White)
                .fontSize(13)
                .onClick(() => {
                  this.showLyrics = true;
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
      .backgroundColor($r('app.color.player_backdrop'))
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.player_backdrop'))
    .bindSheet($$this.showPlaylist, this.playlistSheet(), {
      height: 420,
      dragBar: true,
      backgroundColor: $r('app.color.surface')
    })
    .bindSheet($$this.showLyrics, this.lyricsSheet(), {
      height: 420,
      dragBar: true,
      backgroundColor: $r('app.color.surface')
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
              this.showPlaylist = false;
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
