import { image } from '@kit.ImageKit';
import { FileEntry, FileEntryFactory } from '../model/FileEntry';
import { FileSource, SourceFactory, SourceType } from '../model/FileSource';
import { PreviewKind } from '../model/FileKinds';
import { Fmt } from '../utils/Format';
import { Symbols } from './Symbols';
import { ThumbnailService } from '../utils/ThumbnailService';

/** 列表行（规范 §7.3）：缩略图/图标 + 名称 + 大小 + 修改时间 */
@Component
export struct FileRow {
  entry: FileEntry = FileEntryFactory.empty();
  source: FileSource = SourceFactory.blank(SourceType.LOCAL);
  tvMode: boolean = false;
  autoFocus: boolean = false;
  @State focused: boolean = false;
  @State thumb: image.PixelMap | null = null;

  aboutToAppear(): void {
    this.loadThumbnail();
  }

  private loadThumbnail(): void {
    if (this.entry.isDirectory || this.entry.kind !== PreviewKind.IMAGE) {
      return;
    }
    const service: ThumbnailService = ThumbnailService.get();
    const cached: image.PixelMap | null = service.cached(this.source.id, this.entry.path);
    if (cached !== null) {
      this.thumb = cached;
      return;
    }
    service.request(this.source, this.entry, (pixelMap: image.PixelMap) => {
      this.thumb = pixelMap;
    });
  }

  build() {
    Row({ space: 12 }) {
      if (this.thumb !== null) {
        Image(this.thumb)
          .width(36)
          .height(36)
          .borderRadius(8)
          .objectFit(ImageFit.Cover)
          .backgroundColor($r('app.color.brand_soft'))
      } else {
        Column() {
          SymbolGlyph(this.entry.isDirectory ? Symbols.folder() : Symbols.forKind(this.entry.kind))
            .fontSize(22)
            .fontColor([this.entry.isDirectory ? $r('app.color.brand') : $r('app.color.text_secondary')])
        }
        .width(36)
        .height(36)
        .justifyContent(FlexAlign.Center)
      }

      Column({ space: 2 }) {
        Text(this.entry.name)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.entry.isDirectory ? '文件夹' :
          `${Fmt.size(this.entry.size)} · ${Fmt.dateTime(this.entry.lastModified)}`)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.entry.isDirectory) {
        SymbolGlyph(Symbols.forward())
          .fontSize(16)
          .fontColor([$r('app.color.text_tertiary')])
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .borderRadius($r('app.float.radius_small'))
    .backgroundColor(this.focused ? $r('app.color.brand_soft') : Color.Transparent)
    .focusable(true)
    .defaultFocus(this.autoFocus)
    .border({ width: this.focused && this.tvMode ? 2 : 0, color: $r('app.color.focus_stroke') })
    .onFocus(() => {
      this.focused = true;
    })
    .onBlur(() => {
      this.focused = false;
    })
  }
}

/** 网格单元（规范 §7.3）：缩略图铺满上部，名称在下 */
@Component
export struct FileTile {
  entry: FileEntry = FileEntryFactory.empty();
  source: FileSource = SourceFactory.blank(SourceType.LOCAL);
  tvMode: boolean = false;
  autoFocus: boolean = false;
  @State focused: boolean = false;
  @State thumb: image.PixelMap | null = null;

  aboutToAppear(): void {
    this.loadThumbnail();
  }

  private loadThumbnail(): void {
    if (this.entry.isDirectory || this.entry.kind !== PreviewKind.IMAGE) {
      return;
    }
    const service: ThumbnailService = ThumbnailService.get();
    const cached: image.PixelMap | null = service.cached(this.source.id, this.entry.path);
    if (cached !== null) {
      this.thumb = cached;
      return;
    }
    service.request(this.source, this.entry, (pixelMap: image.PixelMap) => {
      this.thumb = pixelMap;
    });
  }

  build() {
    Column({ space: 8 }) {
      Stack({ alignContent: Alignment.Center }) {
        if (this.thumb !== null) {
          Image(this.thumb)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .borderRadius($r('app.float.radius_small'))
        } else {
          SymbolGlyph(this.entry.isDirectory ? Symbols.folder() : Symbols.forKind(this.entry.kind))
            .fontSize(32)
            .fontColor([this.entry.isDirectory ? $r('app.color.brand') : $r('app.color.text_secondary')])
        }
      }
      .width('100%')
      .height(84)
      .borderRadius($r('app.float.radius_small'))
      .backgroundColor($r('app.color.brand_soft'))
      .clip(true)

      Text(this.entry.name)
        .fontSize(13)
        .fontColor($r('app.color.text_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('100%')
    }
    .padding(10)
    .borderRadius($r('app.float.radius_small'))
    .backgroundColor($r('app.color.surface_card'))
    .border({
      width: this.focused ? 2 : 1,
      color: this.focused ? $r('app.color.focus_stroke') : $r('app.color.divider')
    })
    .focusable(true)
    .defaultFocus(this.autoFocus)
    .onFocus(() => {
      this.focused = true;
    })
    .onBlur(() => {
      this.focused = false;
    })
  }
}
