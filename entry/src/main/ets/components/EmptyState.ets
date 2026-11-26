/** 空状态：系统符号 + 说明 + 可选主操作（规范 §2.2 原生组件） */
@Component
export struct EmptyState {
  icon: Resource = $r('sys.symbol.folder');
  title: string = '';
  description: string = '';
  actionLabel: string = '';
  onAction: () => void = () => {
  };

  build() {
    Column({ space: 12 }) {
      SymbolGlyph(this.icon)
        .fontSize(48)
        .fontColor([$r('app.color.text_tertiary')])
      Text(this.title)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      if (this.description.length > 0) {
        Text(this.description)
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)
          .padding({ left: 24, right: 24 })
      }
      if (this.actionLabel.length > 0) {
        Button(this.actionLabel)
          .type(ButtonType.Capsule)
          .backgroundColor($r('app.color.brand'))
          .fontColor(Color.White)
          .height(40)
          .margin({ top: 8 })
          .onClick(() => this.onAction())
      }
    }
    .width('100%')
    .padding({ top: 48, bottom: 48 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
