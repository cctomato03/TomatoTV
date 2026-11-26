/** 二维码渲染：ArkUI Canvas 逐格绘制（规范 §7.5） */
@Component
export struct QrView {
  matrix: boolean[][] = [];
  edge: number = 240;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  private draw(): void {
    const rows: number = this.matrix.length;
    if (rows === 0) {
      return;
    }
    const columns: number = this.matrix[0].length;
    const quiet: number = 4;
    const cell: number = this.edge / (columns + quiet * 2);
    this.context.fillStyle = '#FFFFFF';
    this.context.fillRect(0, 0, this.edge, this.edge);
    this.context.fillStyle = '#241B18';
    for (let y = 0; y < rows; y++) {
      for (let x = 0; x < columns; x++) {
        if (this.matrix[y][x]) {
          const px: number = (x + quiet) * cell;
          const py: number = (y + quiet) * cell;
          // 加 0.5px 消除缝隙，避免扫描时出现细白线
          this.context.fillRect(px, py, cell + 0.5, cell + 0.5);
        }
      }
    }
  }

  build() {
    Canvas(this.context)
      .width(this.edge)
      .height(this.edge)
      .backgroundColor(Color.White)
      .borderRadius($r('app.float.radius_small'))
      .onReady(() => {
        this.draw();
      })
  }
}
