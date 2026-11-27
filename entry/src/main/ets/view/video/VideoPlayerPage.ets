import { MediaParam, NavDefaults } from '../../navigation/AppNav';
import { AppContainer } from '../../app/AppContainer';
import { FileSource } from '../../model/FileSource';
import { FileEntry } from '../../model/FileEntry';
import { FileKinds } from '../../model/FileKinds';
import { PlayableMedia } from '../../data/fs/FileSystemClient';
import { MediaDefaults, PlaybackSpeeds, TrackOption, VideoState } from '../../media/MediaTypes';
import { VideoEngine, ExternalSubtitle } from '../../media/VideoEngine';
import { MpegTsDuration } from '../../media/MpegTsDuration';
import { ClientByteReader } from '../../media/ClientByteReader';
import { Fmt } from '../../utils/Format';
import { Symbols } from '../../components/Symbols';
import { KeyCode } from '@kit.InputKit';
import { deviceInfo, BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { window } from '@kit.ArkUI';
import { Logger } from '../../utils/Logger';
import { WindowTheme } from '../../utils/WindowTheme';

const HIDE_DELAY_MS: number = 4000;
const SEEK_STEP_MS: number = 10000;
const TOOL_WIDTH: number = 78;
const TOOL_HEIGHT: number = 38;
/** 可自动挂载的外挂字幕后缀 */
const SUBTITLE_EXTENSIONS: string[] = ['srt', 'vtt', 'ass', 'ssa'];

/** 视频播放页（规范 §7.10）：XComponent 全屏画面 + 手势 seek + 倍速/音轨/字幕 */
@Component
export struct VideoPlayerPage {
  stack: NavPathStack = new NavPathStack();
  param: MediaParam = NavDefaults.media();

  @State videoState: VideoState = MediaDefaults.videoState('');
  @State controlsVisible: boolean = true;
  @State dragging: boolean = false;
  @State dragValue: number = 0;
  @State seekHint: string = '';
  @State speedLabel: string = '1x';
  @State pcrDurationMs: number = 0;

  private engine: VideoEngine = new VideoEngine();
  private controller: XComponentController = new XComponentController();
  private container: AppContainer = AppContainer.get();
  private hideTimer: number = -1;
  private opened: boolean = false;
  private usedStream: boolean = false;
  private landscapeRequested: boolean = false;

  /** 系统时长不可用（常见于 BDAV .m2ts）时用 PCR 探测结果驱动进度条（规范 §9.3） */
  private effectiveDuration(): number {
    return this.videoState.durationMs > 0 ? this.videoState.durationMs : this.pcrDurationMs;
  }

  private async probePcrDuration(source: FileSource): Promise<void> {
    const extension: string = FileKinds.extensionOf(this.param.name);
    if (extension !== 'ts' && extension !== 'm2ts' && extension !== 'mts' && extension !== 'm2v') {
      return;
    }
    try {
      const client = await this.container.repository!.clientFor(source);
      const stat = await client.stat(this.param.path);
      const reader: ClientByteReader = new ClientByteReader(client, this.param.path, stat.size);
      const durationMs: number = await MpegTsDuration.probe(reader);
      if (durationMs > 0) {
        this.pcrDurationMs = durationMs;
        Logger.info('VideoPlayerPage', `PCR 时长探测成功 ${Fmt.duration(durationMs)}`);
      }
    } catch (err) {
      Logger.warn('VideoPlayerPage', 'PCR 时长探测失败');
    }
  }

  aboutToAppear(): void {
    this.engine.onChange((state: VideoState) => {
      this.videoState = state;
      this.speedLabel = PlaybackSpeeds.label(state.speed);
      if (state.error !== null) {
        Logger.warn('VideoPlayerPage', `播放失败: ${state.error}`);
      }
    });
    WindowTheme.immersive('#000000');
    this.enterLandscape();
  }


  aboutToDisappear(): void {
    this.clearHideTimer();
    this.engine.release();
    this.exitLandscape();
    WindowTheme.exitImmersive();
  }

  /** 进入视频页自动横屏（手机/平板）；智慧屏与 2in1 本身是宽屏，不做旋转 */
  private async enterLandscape(): Promise<void> {
    const type: string = deviceInfo.deviceType;
    if (type === 'tv' || type === '2in1') {
      return;
    }
    const stage: window.WindowStage | null = this.container.windowStage();
    if (stage === null) {
      return;
    }
    this.landscapeRequested = true;
    try {
      const win: window.Window = stage.getMainWindowSync();
      await win.setPreferredOrientation(window.Orientation.LANDSCAPE);
      Logger.info('VideoPlayerPage', '已切换为横屏');
    } catch (err) {
      Logger.warn('VideoPlayerPage', '切换横屏失败');
    }
  }

  /** 退出视频页恢复默认方向，避免上一页停留在横屏 */
  private async exitLandscape(): Promise<void> {
    if (!this.landscapeRequested) {
      return;
    }
    this.landscapeRequested = false;
    const stage: window.WindowStage | null = this.container.windowStage();
    if (stage === null) {
      return;
    }
    try {
      const win: window.Window = stage.getMainWindowSync();
      await win.setPreferredOrientation(window.Orientation.UNSPECIFIED);
      Logger.info('VideoPlayerPage', '已恢复默认屏幕方向');
    } catch (err) {
      Logger.warn('VideoPlayerPage', '恢复屏幕方向失败');
    }
  }

  private clearHideTimer(): void {
    if (this.hideTimer !== -1) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
  }

  private scheduleHide(): void {
    this.clearHideTimer();
    this.hideTimer = setTimeout(() => {
      this.controlsVisible = false;
    }, HIDE_DELAY_MS);
  }

  private toggleControls(): void {
    this.controlsVisible = !this.controlsVisible;
    if (this.controlsVisible) {
      this.scheduleHide();
    }
  }

  private async open(): Promise<void> {
    if (this.opened) {
      return;
    }
    this.opened = true;
    const source: FileSource | null = this.container.findSource(this.param.sourceId);
    if (source === null) {
      return;
    }
    try {
      const entry: FileEntry = {
        name: this.param.name,
        path: this.param.path,
        isDirectory: false,
        size: this.param.size,
        lastModified: 0,
        mimeType: '',
        kind: this.param.kind
      };
      const playable: PlayableMedia = await this.container.repository!.playable(source, entry);
      this.usedStream = playable.url.length > 0;
      Logger.info('VideoPlayerPage', `播放来源: ${this.usedStream ? 'stream ' + playable.url : 'fd ' + playable.fd}`);
      const subtitles: ExternalSubtitle[] = await this.findExternalSubtitles(source);
      await this.engine.open(playable, this.param.name, () => this.controller.getXComponentSurfaceId(), subtitles);
      this.scheduleHide();
      if (this.engine.durationMs() <= 0) {
        setTimeout(() => {
          if (this.engine.durationMs() <= 0) {
            this.probePcrDuration(source);
          }
        }, 1200);
      }
    } catch (err) {
      Logger.error('VideoPlayerPage', '打开视频失败', err as Error);
    }
  }

  /**
   * 查找同目录下的外挂字幕：与视频同名的 .srt/.vtt/.ass。
   * 远程来源先把字幕物化成缓存文件再打开 fd（AVPlayer 只接受 fd）。
   */
  private async findExternalSubtitles(source: FileSource): Promise<ExternalSubtitle[]> {
    const repository = this.container.repository;
    if (repository === null) {
      return [];
    }
    const parent: string = VideoPlayerPage.parentOf(this.param.path);
    const base: string = VideoPlayerPage.baseName(this.param.name);
    const result: ExternalSubtitle[] = [];
    let entries: FileEntry[] = [];
    try {
      entries = await repository.list(source, parent);
    } catch (err) {
      Logger.warn('VideoPlayerPage', '读取字幕目录失败');
      return [];
    }
    // 同名可能同时存在 srt/ass/vtt：按 SUBTITLE_EXTENSIONS 的优先级只挂载一条
    for (const wanted of SUBTITLE_EXTENSIONS) {
      const match: FileEntry | null = VideoPlayerPage.pickSubtitle(entries, base, wanted);
      if (match === null) {
        continue;
      }
      try {
        const localPath: string = await repository.materializeToPath(source, match);
        const file: fs.File = fs.openSync(localPath, fs.OpenMode.READ_ONLY);
        result.push({
          path: localPath,
          name: match.name,
          label: `外挂 · ${wanted.toUpperCase()}`,
          fd: file.fd,
          size: match.size
        });
        Logger.info('VideoPlayerPage', `找到外挂字幕 ${match.name}`);
      } catch (err) {
        Logger.warn('VideoPlayerPage', `准备外挂字幕失败 ${match.name}`);
      }
      break;
    }
    return result;
  }

  private static pickSubtitle(entries: FileEntry[], base: string, extension: string): FileEntry | null {
    for (const entry of entries) {
      if (entry.isDirectory) {
        continue;
      }
      const lower: string = entry.name.toLowerCase();
      const slash: number = lower.lastIndexOf('.');
      if (slash <= 0) {
        continue;
      }
      if (lower.substring(0, slash) !== base || lower.substring(slash + 1) !== extension) {
        continue;
      }
      return entry;
    }
    return null;
  }

  private static baseName(name: string): string {
    const dot: number = name.lastIndexOf('.');
    return (dot > 0 ? name.substring(0, dot) : name).toLowerCase();
  }

  private static parentOf(path: string): string {
    const trimmed: string = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    const slash: number = trimmed.lastIndexOf('/');
    return slash > 0 ? trimmed.substring(0, slash) : '/';
  }

  private seekBy(deltaMs: number): void {
    this.engine.seekTo(this.videoState.positionMs + deltaMs);
    this.showSeekHint(deltaMs > 0 ? '快进 10 秒' : '快退 10 秒');
    this.scheduleHide();
  }

  private showSeekHint(text: string): void {
    this.seekHint = text;
    setTimeout(() => {
      this.seekHint = '';
    }, 900);
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Bottom }) {
        XComponent({ id: 'tomato_video', type: XComponentType.SURFACE, controller: this.controller })
          .width('100%')
          .height('100%')
          .onLoad(() => {
            if (this.opened) {
              // 画面组件被重建：把新的 SurfaceId 重新交给播放器
              this.engine.reattachSurface();
              return;
            }
            this.open();
          })
          .onClick(() => this.toggleControls())

        Stack({ alignContent: Alignment.Center }) {
          if (this.seekHint.length > 0) {
            Text(this.seekHint)
              .fontSize(15)
              .fontColor(Color.White)
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .backgroundColor($r('app.color.player_scrim'))
              .borderRadius(16)
          }
          // 快进/切轨时的等待反馈：不仅首帧加载，缓冲中也会显示
          if (this.videoState.loading || this.videoState.buffering) {
            LoadingProgress()
              .width(48)
              .height(48)
              .color(Color.White)
          }
          if (this.videoState.error !== null && !this.videoState.playing && this.videoState.positionMs === 0) {
            Column({ space: 12 }) {
              Text(this.videoState.error)
                .fontSize(15)
                .fontColor(Color.White)
                .textAlign(TextAlign.Center)
              Button('返回')
                .type(ButtonType.Capsule)
                .backgroundColor($r('app.color.brand'))
                .onClick(() => this.stack.pop())
            }
            .padding(24)
          }
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)

        // 字幕层：贴近底部、避开工具栏，随 subtitleUpdate 实时更新
        if (this.videoState.subtitleText.length > 0) {
          Column() {
            Text(this.videoState.subtitleText)
              .fontSize(17)
              .fontColor(Color.White)
              .textAlign(TextAlign.Center)
              .maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .lineHeight(26)
              .padding({ left: 12, right: 12, top: 4, bottom: 4 })
              .backgroundColor($r('app.color.player_scrim'))
              .borderRadius(6)
              .width('88%')
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.End)
          .padding({ left: 24, right: 24, bottom: this.controlsVisible ? 104 : 40 })
          .hitTestBehavior(HitTestMode.None)
        }

        if (this.controlsVisible) {
          this.topBar()
          this.bottomBar()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Black)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .onKeyEvent((event: KeyEvent) => {
        if (event.type !== KeyType.Down) {
          return;
        }
        const code: number = event.keyCode;
        if (code === KeyCode.KEYCODE_SPACE || code === KeyCode.KEYCODE_MEDIA_PLAY_PAUSE ||
          code === KeyCode.KEYCODE_ENTER || code === KeyCode.KEYCODE_DPAD_CENTER) {
          this.engine.toggle();
          this.controlsVisible = true;
          this.scheduleHide();
          return;
        }
        if (code === KeyCode.KEYCODE_DPAD_LEFT) {
          this.seekBy(-SEEK_STEP_MS);
          return;
        }
        if (code === KeyCode.KEYCODE_DPAD_RIGHT) {
          this.seekBy(SEEK_STEP_MS);
        }
      })
      .gesture(
        PanGesture({ direction: PanDirection.Horizontal })
          .onActionStart(() => {
            this.dragging = true;
            this.dragValue = this.videoState.positionMs;
          })
          .onActionUpdate((event: GestureEvent) => {
            if (this.effectiveDuration() <= 0) {
              return;
            }
            const ratio: number = event.offsetX / 360;
            let target: number = this.dragValue + ratio * this.effectiveDuration();
            if (target < 0) {
              target = 0;
            }
            if (target > this.effectiveDuration()) {
              target = this.effectiveDuration();
            }
            this.seekHint = `${Fmt.duration(target)} / ${Fmt.duration(this.effectiveDuration())}`;
          })
          .onActionEnd((event: GestureEvent) => {
            this.dragging = false;
            if (this.effectiveDuration() > 0) {
              const ratio: number = event.offsetX / 360;
              const target: number = this.dragValue + ratio * this.effectiveDuration();
              this.engine.seekTo(target);
            }
            this.seekHint = '';
            this.scheduleHide();
          })
      )
    }
    .hideTitleBar(true)
    .backgroundColor(Color.Black)
    .onBackPressed((): boolean => false)
  }

  @Builder
  topBar() {
    Row({ space: 8 }) {
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph(Symbols.back()).fontSize(20).fontColor([Color.White])
      }
      .width(40)
      .height(40)
      .backgroundColor($r('app.color.player_scrim'))
      .onClick(() => this.stack.pop())

      Column({ space: 2 }) {
        Text(this.param.name)
          .fontSize(15)
          .fontColor(Color.White)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.videoState.buffering ? '缓冲中…' : '')
          .fontSize(11)
          .fontColor(Color.White)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(12)
    .position({ x: 0, y: 0 })
  }

  @Builder
  bottomBar() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(Fmt.duration(this.videoState.positionMs))
          .fontSize(12)
          .fontColor(Color.White)
          .width(56)
        Slider({
          value: this.videoState.positionMs,
          min: 0,
          max: this.effectiveDuration() > 0 ? this.effectiveDuration() : 1,
          step: 1
        })
          .layoutWeight(1)
          .height(32)
          .selectedColor($r('app.color.brand'))
          .onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              this.engine.seekTo(value);
              this.scheduleHide();
            }
          })
        Text(Fmt.duration(this.effectiveDuration()))
          .fontSize(12)
          .fontColor(Color.White)
          .width(64)
          .textAlign(TextAlign.End)
      }
      .width('100%')

      Row({ space: 8 }) {
        Button('快退')
          .type(ButtonType.Normal)
          .borderRadius(8)
          .width(TOOL_WIDTH)
          .height(TOOL_HEIGHT)
          .fontSize(13)
          .fontColor(Color.White)
          .backgroundColor($r('app.color.player_scrim'))
          .onClick(() => this.seekBy(-SEEK_STEP_MS))
          .accessibilityText('快退 10 秒')

        Button(this.videoState.playing ? '暂停' : '播放')
          .type(ButtonType.Normal)
          .borderRadius(8)
          .width(TOOL_WIDTH)
          .height(TOOL_HEIGHT)
          .fontSize(13)
          .fontColor(Color.White)
          .backgroundColor($r('app.color.brand'))
          .onClick(() => {
            this.engine.toggle();
            this.scheduleHide();
          })

        Button('快进')
          .type(ButtonType.Normal)
          .borderRadius(8)
          .width(TOOL_WIDTH)
          .height(TOOL_HEIGHT)
          .fontSize(13)
          .fontColor(Color.White)
          .backgroundColor($r('app.color.player_scrim'))
          .onClick(() => this.seekBy(SEEK_STEP_MS))
          .accessibilityText('快进 10 秒')

        Button(this.speedLabel)
          .type(ButtonType.Normal)
          .borderRadius(8)
          .width(TOOL_WIDTH)
          .height(TOOL_HEIGHT)
          .fontSize(13)
          .fontColor(Color.White)
          .backgroundColor($r('app.color.player_scrim'))
          .bindMenu(this.speedMenu(), {
            onAppear: () => this.clearHideTimer(),
            onDisappear: () => this.scheduleHide()
          })

        Button('音轨')
          .type(ButtonType.Normal)
          .borderRadius(8)
          .width(TOOL_WIDTH)
          .height(TOOL_HEIGHT)
          .fontSize(13)
          .fontColor(Color.White)
          .backgroundColor($r('app.color.player_scrim'))
          .bindMenu(this.audioMenu(), {
            onAppear: () => this.clearHideTimer(),
            onDisappear: () => this.scheduleHide()
          })

        Button('字幕')
          .type(ButtonType.Normal)
          .borderRadius(8)
          .width(TOOL_WIDTH)
          .height(TOOL_HEIGHT)
          .fontSize(13)
          .fontColor(Color.White)
          .backgroundColor($r('app.color.player_scrim'))
          .bindMenu(this.subtitleMenu(), {
            onAppear: () => this.clearHideTimer(),
            onDisappear: () => this.scheduleHide()
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceEvenly)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 12 })
    .backgroundColor($r('app.color.player_scrim'))
  }

  @Builder
  speedMenu() {
    Menu() {
      ForEach(PlaybackSpeeds.LIST, (speed: number) => {
        MenuItem({ content: speed === this.videoState.speed ? `✓ ${PlaybackSpeeds.label(speed)}` :
          PlaybackSpeeds.label(speed) })
          .onClick(() => {
            this.engine.setSpeed(speed);
            this.scheduleHide();
          })
      }, (speed: number) => `${speed}`)
    }
  }

  @Builder
  audioMenu() {
    Menu() {
      if (this.videoState.audioTracks.length === 0) {
        MenuItem({ content: '没有可切换的音轨' })
          .enabled(false)
      }
      ForEach(this.videoState.audioTracks, (track: TrackOption) => {
        MenuItem({
          content: track.index === this.videoState.selectedAudioId ? `✓ ${track.label}` : track.label
        })
          .onClick(() => {
            this.engine.selectTrack(track.index);
            this.scheduleHide();
          })
      }, (track: TrackOption) => `a${track.index}`)
    }
  }

  @Builder
  subtitleMenu() {
    Menu() {
      MenuItem({ content: this.videoState.selectedSubtitleId === -1 ? '✓ 关闭字幕' : '关闭字幕' })
        .onClick(() => {
          this.engine.selectTrack(-1);
          this.scheduleHide();
        })
      if (this.videoState.subtitleTracks.length === 0) {
        MenuItem({ content: '没有字幕轨' })
          .enabled(false)
      }
      ForEach(this.videoState.subtitleTracks, (track: TrackOption) => {
        MenuItem({
          content: track.index === this.videoState.selectedSubtitleId ? `✓ ${track.label}` : track.label
        })
          .onClick(() => {
            this.engine.selectTrack(track.index);
            this.scheduleHide();
          })
      }, (track: TrackOption) => `s${track.index}`)
    }
  }
}
