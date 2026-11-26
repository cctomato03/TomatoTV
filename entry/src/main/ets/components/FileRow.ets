import { FileEntry, FileEntryFactory } from '../model/FileEntry';
import { Fmt } from '../utils/Format';
import { Symbols } from './Symbols';

/** 列表行（规范 §7.3）：图标 / 名称 / 大小 / 修改时间 */
@Component
export struct FileRow {
  entry: FileEntry = FileEntryFactory.empty();
  tvMode: boolean = false;
  autoFocus: boolean = false;
  @State focused: boolean = false;

  build() {
    Row({ space: 12 }) {
      SymbolGlyph(this.entry.isDirectory ? Symbols.folder() : Symbols.forKind(this.entry.kind))
        .fontSize(22)
        .fontColor([this.entry.isDirectory ? $r('app.color.brand') : $r('app.color.text_secondary')])
        .width(32)

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

/** 网格单元（规范 §7.3） */
@Component
export struct FileTile {
  entry: FileEntry = FileEntryFactory.empty();
  tvMode: boolean = false;
  autoFocus: boolean = false;
  @State focused: boolean = false;

  build() {
    Column({ space: 8 }) {
      Column() {
        SymbolGlyph(this.entry.isDirectory ? Symbols.folder() : Symbols.forKind(this.entry.kind))
          .fontSize(32)
          .fontColor([this.entry.isDirectory ? $r('app.color.brand') : $r('app.color.text_secondary')])
      }
      .width('100%')
      .height(72)
      .borderRadius($r('app.float.radius_small'))
      .backgroundColor($r('app.color.brand_soft'))
      .justifyContent(FlexAlign.Center)

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
