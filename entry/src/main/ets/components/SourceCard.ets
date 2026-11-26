import { FileSource, SourceFactory, SourceType } from '../model/FileSource';
import { Symbols } from './Symbols';

/** 来源卡片（规范 §7.2）：类型图标 + 名称 + 类型标签 + 地址 + 编辑入口 */
@Component
export struct SourceCard {
  source: FileSource = SourceFactory.blank(SourceType.LOCAL);
  tvMode: boolean = false;
  onOpen: (source: FileSource) => void = () => {
  };
  onEdit: (source: FileSource) => void = () => {
  };
  onDelete: (source: FileSource) => void = () => {
  };
  @State focused: boolean = false;

  build() {
    Row({ space: 12 }) {
      Column() {
        SymbolGlyph(Symbols.forSource(this.source.type))
          .fontSize(24)
          .fontColor([$r('app.color.brand')])
      }
      .width(48)
      .height(48)
      .borderRadius($r('app.float.radius_small'))
      .backgroundColor($r('app.color.brand_soft'))
      .justifyContent(FlexAlign.Center)

      Column({ space: 4 }) {
        Row({ space: 8 }) {
          Text(this.source.name.length > 0 ? this.source.name : '未命名存储')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(SourceFactory.typeLabel(this.source.type))
            .fontSize(11)
            .fontColor($r('app.color.brand'))
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor($r('app.color.brand_soft'))
            .borderRadius(8)
        }
        .width('100%')

        Text(SourceFactory.displayAddress(this.source))
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.source.builtIn) {
        Text('内置')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
      } else {
        Button('编辑')
          .type(ButtonType.Capsule)
          .height(30)
          .padding({ left: 14, right: 14 })
          .fontSize(12)
          .backgroundColor($r('app.color.brand_soft'))
          .fontColor($r('app.color.brand'))
          .focusable(true)
          .onClick(() => this.onEdit(this.source))
          .accessibilityText(`编辑存储 ${this.source.name}`)
      }

      SymbolGlyph(Symbols.forward())
        .fontSize(18)
        .fontColor([$r('app.color.text_tertiary')])
    }
    .width('100%')
    .padding(16)
    .borderRadius($r('app.float.radius_card'))
    .backgroundColor($r('app.color.surface_card'))
    .border({
      width: this.focused ? 2 : 1,
      color: this.focused ? $r('app.color.focus_stroke') : $r('app.color.divider')
    })
    .focusable(true)
    .focusOnTouch(false)
    .onFocus(() => {
      this.focused = true;
    })
    .onBlur(() => {
      this.focused = false;
    })
    .onClick(() => this.onOpen(this.source))
    .bindContextMenu(this.menuBuilder(), ResponseType.LongPress)
  }

  @Builder
  menuBuilder() {
    Menu() {
      MenuItem({ content: '编辑' })
        .onClick(() => this.onEdit(this.source))
      if (!this.source.builtIn) {
        MenuItem({ content: '删除' })
          .onClick(() => this.onDelete(this.source))
      }
    }
  }
}
