# 第三方组件与许可

TomatoTV 自身以 Apache-2.0 发布。应用内以 `rawfile` 形式随包分发以下开源库（均为运行时离线渲染资源，
不参与网络加载），版本与许可证如下：

| 组件 | 版本 | 用途 | 许可证 | 仓库 |
|---|---|---|---|---|
| pdf.js (pdfjs-dist) | 3.11.174 | PDF 页面渲染（`rawfile/viewer/pdf`） | Apache-2.0 | https://github.com/mozilla/pdf.js |
| docx-preview | 0.3.2 | Word 文档渲染（`rawfile/viewer/docx`） | Apache-2.0 | https://github.com/VolodymyrBaydalka/docxjs |
| JSZip | 3.10.1 | docx（OOXML zip）解包 | MIT 或 GPLv3（本项目按 MIT 使用） | https://github.com/Stuk/jszip |
| SheetJS (xlsx) | 0.18.5 | Excel 表格渲染（`rawfile/viewer/sheet`） | Apache-2.0 | https://github.com/SheetJS/sheetjs |
| pptx-preview | 1.0.7 | PPTX 幻灯片渲染（`rawfile/viewer/pptx`，UMD 内已打包 JSZip/lodash/echarts/uuid/tslib） | ISC | https://github.com/Chhit757/pptx-preview |

## 仅用于构建/测试的工具链（不随应用分发）

| 组件 | 版本 | 用途 | 许可证 |
|---|---|---|---|
| esbuild | 0.24.0 | 单元测试打包 | MIT |
| jsqr | 1.4.0 | 单元测试中反向解码校验二维码 | Apache-2.0 |
| puppeteer-core | 23.11.1 | 文档预览页的无头浏览器集成测试（不随应用分发） | Apache-2.0 |
| @ohos/hvigor、@ohos/hvigor-ohos-plugin | 5.7.0 | HarmonyOS 构建 | Apache-2.0 |
| OpenHarmony SDK | 5.0.0 Release (API 12) | 编译 SDK | Apache-2.0 |

## 说明

- 上述前端库均以**未修改**的官方发布构建（minified UMD）随包分发，符合各自许可证要求；
- 应用运行时不访问任何 CDN，也不加载外部脚本（见 `docs/DEVIATIONS.md` §3 的安全策略）。
