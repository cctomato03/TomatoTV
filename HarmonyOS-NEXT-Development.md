# TomatoTV HarmonyOS NEXT 开发文档

> 本文档是新工作区实现 TomatoTV 的唯一产品与技术要求。UI、交互、实现方式全部采用 HarmonyOS NEXT 原生设计与系统能力，不沿用其他平台的视觉语言或组件模式。
>
> - 应用名：TomatoTV
> - Bundle Name：`com.cctomato.tv`
> - 系统：HarmonyOS NEXT（Stage 模型）
> - 语言：ArkTS / ArkUI，必要时使用 C/C++ + NAPI
> - 设备：手机、平板、PC / 2in1、智慧屏
> - 设计体系：HarmonyOS Design，使用系统组件、系统色彩、系统图标、系统动效与系统能力
>
> 说明：文中 Kit/API 名称以 DevEco Studio 当前 SDK 的 d.ts 为准。若某能力在当前 SDK 不可用，应选择 HarmonyOS 原生的等价能力，并在交付说明中记录，不得引入其他平台的 UI 框架或设计模式。

---

## 1. 产品定位

TomatoTV 是 HarmonyOS 上的本地与网络文件管理器，强调：

- 原生 HarmonyOS 视觉与交互；
- 多设备一致但形态自适应；
- 本地/远程文件统一浏览；
- 图片、文本、PDF、Office 预览；
- 全格式视频与本地音乐播放；
- 智慧屏遥控器友好；
- 手机扫码辅助智慧屏完成存储配置。

核心功能：

1. 存储来源：本机目录、WebDAV、SMB、FTP/FTPS。
2. 分层目录浏览、面包屑、排序、列表/网格、刷新。
3. 目录历史与滚动位置恢复。
4. 图片查看器：滑动、双指缩放、双击、元数据、作者链接。
5. 视频播放：常见与桌面容器、4K、手势、音轨/字幕、倍速。
6. 音频播放：当前目录播放列表、上一首/下一首、封面、歌词、后台播放。
7. 远程缓存与清理。
8. 设置、缓存管理、智慧屏大屏布局。
9. 智慧屏手机扫码填写存储参数。

---

## 2. HarmonyOS 原生设计原则

### 2.1 总体风格

采用 HarmonyOS Design 的“轻盈、层次、留白、圆润、自然”方向：

- 大面积留白，避免拥挤列表。
- 卡片化信息分组，但使用 ArkUI 原生容器与系统背景色，不模拟其他平台卡片。
- 统一圆角：小控件 12vp，卡片 20vp，弹层 24vp。
- 使用系统语义色与系统字体层级，自动适配浅色/深色模式。
- 动效克制：页面转场、弹层、焦点变化使用系统动效或 `animateTo`，时长 180–280ms。
- 主要操作使用系统 `Button`、`TextInput`、`Select`、`Toggle`、`Slider`、`Menu`、`Dialog`、`Sheet` 等原生组件。
- 图标优先使用 `SymbolGlyph` 与系统符号资源；不使用位图图标堆叠。
- 不使用非 HarmonyOS 原生的悬浮按钮、重阴影卡片、固定底部操作栏等视觉模式。

### 2.2 必须使用的 ArkUI 组件

| 场景 | 组件 |
|---|---|
| 页面导航 | `Navigation` + `NavDestination` + `NavPathStack` |
| 大屏分栏 | `Navigation` 分栏模式或 `SideBarContainer` |
| 列表 | `List` + `ListItem` |
| 网格 | `Grid` + `GridItem` |
| 图片浏览 | `Swiper` + `Image` |
| 下拉刷新 | `Refresh` |
| 加载 | `LoadingProgress` |
| 进度 | `Progress` / `Slider` |
| 输入 | `TextInput`、`TextArea`、`Search` |
| 选择 | `Select`、`Radio`、`Checkbox`、`Toggle` |
| 标签页 | `Tabs` + `TabContent` |
| 菜单 | `Menu` / `bindMenu` |
| 弹层 | `bindSheet`、`bindContentCover`、`CustomDialogController` |
| 提示 | `promptAction.showToast` |
| 图标 | `SymbolGlyph` |
| 视频画面 | `XComponent` |
| 响应式 | `GridRow` / `GridCol`、断点监听 |
| 焦点 | `focusable`、`defaultFocus`、`onKeyEvent`、`FocusControl` |

### 2.3 视觉 Token

在 `resources/base/element/color.json` 与 `float.json` 中定义，禁止散落硬编码：

```json
{
  "color": [
    { "name": "brand", "value": "#E54835" },
    { "name": "brand_soft", "value": "#FBE9E5" },
    { "name": "surface", "value": "#FFFBF8" },
    { "name": "surface_dark", "value": "#1C1512" },
    { "name": "text_primary", "value": "#241B18" },
    { "name": "text_secondary", "value": "#7A6A63" },
    { "name": "divider", "value": "#EFE1DA" }
  ]
}
```

- 背景：优先 `$r('sys.color.background_primary')` / `background_secondary`。
- 文本：优先 `$r('sys.color.font_primary')` / `font_secondary`。
- 强调色：品牌番茄红 `#E54835`，只用于主按钮、选中态、进度、焦点框。
- 深色模式：使用系统语义色自动切换；品牌色保持可读对比度。
- 字体：使用系统字体与 `Text` 的字号/字重层级，不引入外部字体。
- 间距：4 / 8 / 12 / 16 / 24 / 32vp。
- 阴影：低透明度、短距离；深色模式减弱阴影，使用背景层级区分。

### 2.4 动效

- 页面进入/退出：系统 `Navigation` 转场。
- 弹层：`bindSheet` 系统动效。
- 列表项点击：`animateTo` 轻微缩放/透明度，禁止夸张弹跳。
- 焦点变化：系统 focus 动画或 120ms 边框过渡。
- 播放器控制栏：淡入淡出 200ms。

---

## 3. 多设备适配

### 3.1 设备声明

`module.json5`：

```json5
{
  "module": {
    "name": "entry",
    "type": "entry",
    "deviceTypes": ["phone", "tablet", "2in1", "tv"]
  }
}
```

### 3.2 断点

| 形态 | 宽度 | 导航 | 内容 |
|---|---|---|---|
| 手机 | < 600vp | 单栏 Navigation | 列表/网格可切换 |
| 平板/折叠屏 | 600–840vp | 单栏或双栏 | 2–3 列网格 |
| PC/2in1 | > 840vp | 左侧来源栏 + 右侧内容 | 3–5 列网格 |
| 智慧屏 | 横屏大屏 | 顶部/左侧大卡片 | 大卡片、焦点导航 |

实现：
- 使用 `GridRow`/`GridCol` 或 `display`/窗口尺寸监听计算断点。
- 使用 `Navigation` 的 `mode(NavigationMode.Auto)` 或按断点设置 `Split/Stack`。
- 窗口尺寸变化时重新计算列数，不重建页面状态。
- PC 支持窗口缩放、鼠标 hover、右键菜单（`bindContextMenu`）。
- 智慧屏使用 16:9 安全区，控件不小于 48vp 可点击区域。

### 3.3 输入

- 触摸：点击、长按、滑动、双指缩放、双击。
- 鼠标：hover、点击、滚轮、右键。
- 键盘：Esc 返回、空格播放/暂停、左右键快进/快退。
- 遥控器：方向键移动焦点、确认键打开、返回键回退。

### 3.4 智慧屏焦点

- 所有可交互组件 `.focusable(true)`。
- 页面首屏设置 `.defaultFocus(true)` 到首个主操作。
- 使用 `.onKeyEvent` 处理方向键与确认键。
- 使用系统焦点框或自定义 `focusBox`：2vp 品牌色描边 + 轻微外扩。
- 列表滚动时保持焦点项可见。
- 弹层打开后焦点进入弹层，关闭后回到触发控件。
- 不使用触摸专用的悬浮操作；主操作放在页面固定位置并可通过遥控器到达。

---

## 4. 工程结构

```text
TomatoTVHarmony/
├── AppScope/
│   ├── app.json5
│   └── resources/
├── entry/
│   ├── src/main/
│   │   ├── ets/
│   │   │   ├── entryability/
│   │   │   │   └── EntryAbility.ets
│   │   │   ├── pages/
│   │   │   │   └── Index.ets
│   │   │   ├── navigation/
│   │   │   │   └── AppNav.ets
│   │   │   ├── model/
│   │   │   │   ├── FileSource.ets
│   │   │   │   ├── FileEntry.ets
│   │   │   │   ├── FileKinds.ets
│   │   │   │   └── AppSettings.ets
│   │   │   ├── data/
│   │   │   │   ├── fs/
│   │   │   │   │   ├── FileSystemClient.ets
│   │   │   │   │   ├── LocalFileSystem.ets
│   │   │   │   │   ├── WebDavFileSystem.ets
│   │   │   │   │   ├── SmbFileSystem.ets
│   │   │   │   │   └── FtpFileSystem.ets
│   │   │   │   ├── repo/FileRepository.ets
│   │   │   │   ├── cache/RemoteCache.ets
│   │   │   │   ├── store/SourceStore.ets
│   │   │   │   ├── store/SettingsStore.ets
│   │   │   │   └── crypto/SecretStore.ets
│   │   │   ├── media/
│   │   │   │   ├── MediaTypes.ets
│   │   │   │   ├── VideoEngine.ets
│   │   │   │   ├── AudioEngine.ets
│   │   │   │   ├── MpegTsDuration.ets
│   │   │   │   └── LyricsRepository.ets
│   │   │   ├── view/
│   │   │   │   ├── home/
│   │   │   │   ├── browse/
│   │   │   │   ├── source/
│   │   │   │   ├── preview/
│   │   │   │   ├── image/
│   │   │   │   ├── video/
│   │   │   │   ├── audio/
│   │   │   │   ├── cache/
│   │   │   │   └── settings/
│   │   │   ├── components/
│   │   │   └── utils/
│   │   ├── resources/
│   │   └── module.json5
│   └── build-profile.json5
├── build-profile.json5
├── hvigorfile.ts
└── oh-package.json5
```

约定：
- 页面只负责 UI 与交互，文件/网络/媒体逻辑放到 `data`/`media`。
- `AppContainer` 持有 `sourceStore`、`settingsStore`、`repository`、`cache`、`secretStore`。
- 状态类使用 `@ObservedV2`/`@Trace`；页面通过 `@State`/`@Prop`/`@Link` 绑定。
- 异步使用 `async/await` + `TaskPool`；UI 线程不做 IO。

---

## 5. 数据模型

```ts
export enum SourceType {
  LOCAL = 'LOCAL',
  WEBDAV = 'WEBDAV',
  SMB = 'SMB',
  FTP = 'FTP'
}

export interface FileSource {
  id: string;
  type: SourceType;
  name: string;
  localUri: string;
  url: string;
  host: string;
  port: number;
  share: string;
  rootPath: string;
  domain: string;
  username: string;
  password: string;
  secure: boolean;
  builtIn: boolean;
}
```

```ts
export enum PreviewKind {
  IMAGE, VIDEO, AUDIO, TEXT, PDF, DOCX, XLSX, PPTX, ARCHIVE, OTHER
}

export interface FileEntry {
  name: string;
  path: string;
  isDirectory: boolean;
  size: number;
  lastModified: number;
  mimeType: string;
  kind: PreviewKind;
}
```

```ts
export interface DirectorySnapshot {
  path: string;
  entries: FileEntry[];
  scrollIndex: number;
  scrollOffset: number;
}

export interface BrowseState {
  loading: boolean;
  refreshing: boolean;
  source: FileSource | null;
  path: string;
  entries: FileEntry[];
  error: string | null;
  permissionRequired: boolean;
}
```

```ts
export interface AppSettings {
  viewMode: 'list' | 'grid';
  sortMode: 'nameAsc' | 'nameDesc' | 'sizeAsc' | 'sizeDesc' | 'dateAsc' | 'dateDesc';
  forceTvLayout: boolean;
  cacheLimitMb: number;
}
```

存储：
- 来源配置：`preferences` 保存 JSON。
- 密码：HUKS + `cryptoFramework` 加密后保存，内存中解密使用。
- 设置：`preferences`。
- 远程缓存索引：应用私有目录 JSON。

---

## 6. 文件类型判定

按后缀优先，MIME 仅辅助。HarmonyOS 与服务端 MIME 可能缺失，`m2ts/ts/wmv` 常被标为 `application/octet-stream`。

视频：

```text
mp4, mkv, webm, avi, mov, 3gp, 3g2, m4v, ts, m2ts, mts, wmv, rmvb, rm,
flv, mpg, mpeg, m2v, m1v, vob, asf, ogv, divx, f4v, mxf
```

音频：

```text
mp3, wav, flac, aac, ogg, oga, m4a, m4b, opus, wma, ape, alac, aiff, aif,
amr, mid, midi, mka, wv
```

图片：

```text
jpg, jpeg, png, gif, webp, bmp, heic, heif, avif, ico, jfif
```

文本：

```text
txt, text, log, md, markdown, json, json5, xml, html, htm, xhtml, css, scss,
sass, less, js, mjs, cjs, ts, tsx, jsx, kt, kts, java, py, rb, go, rs, c, h,
cpp, cc, hpp, cs, php, sh, bash, zsh, bat, cmd, ps1, yml, yaml, toml, ini,
cfg, conf, properties, groovy, sql, csv, tsv, srt, vtt, tex, diff, patch,
gitignore, editorconfig, dockerfile, makefile, pro, env, lock, rtf
```

路由：
- 音频 → 音频播放页。
- 视频 → 视频播放页。
- 图片 → 图片查看器。
- PDF/Office/文本 → 预览页。
- 其他 → 文件信息页 + 系统“打开方式”。

进入页面前必须确定 `mediaType`，禁止先显示统一播放器再切换。

---

## 7. 页面与组件规范

### 7.1 应用外壳

- 根组件 `Navigation`，使用 `NavPathStack` 管理页面。
- 手机：Stack 单栏。
- 平板：按断点 Auto/Split。
- PC/2in1：左侧来源栏 + 右侧内容。
- 智慧屏：大卡片 + 焦点。

顶部标题使用系统大标题层级，不自定义仿制导航栏。

### 7.2 首页

结构：
1. 顶部：`TomatoTV` 标题 + 设置 `SymbolGlyph` 按钮。
2. 来源卡片列表：
   - 类型图标（`SymbolGlyph`）
   - 来源名
   - 类型标签
   - 地址/路径
   - 编辑按钮
3. 右下或底部固定“添加存储”主按钮（系统 `Button`，胶囊形，品牌色）。
4. 空状态：插图/系统符号 + “还没有存储” + 添加按钮。

禁止：
- 统计卡片。
- 缓存卡片。
- 促销文案。
- 列表末尾“添加新存储”卡片。
- 非 HarmonyOS 原生的悬浮按钮。

交互：
- 点击卡片进入浏览。
- 编辑按钮打开编辑页。
- 长按/右键显示菜单（重命名、删除、清缓存）视功能范围。
- 智慧屏焦点：卡片按行列移动，主按钮可聚焦。

### 7.3 浏览页

顶部：
- 返回按钮。
- 来源名 + 当前路径面包屑。
- 视图切换、排序、刷新。

内容：
- `List` 或 `Grid`，`ListItem`/`GridItem` 原生组件。
- 文件图标/缩略图、名称、大小、修改时间。
- 目录优先排序。
- 空目录、错误、权限不足三种状态。

刷新：
- `Refresh` 下拉刷新。
- 进入目录立即清空旧列表并显示 `LoadingProgress` + “正在读取目录…”。
- 刷新时保留旧内容并显示顶部进度条。

目录历史：
- 最多 32 层快照。
- 进入子目录前保存 `path + entries + scrollIndex + scrollOffset`。
- 返回/面包屑命中快照时恢复列表和滚动位置，不重新请求。
- 根目录返回交给系统。
- 使用 `Scroller.scrollToIndex` 恢复，不重建滚动对象。

### 7.4 添加/编辑存储

使用 `Navigation` 新页面或 `bindSheet`（手机用页面，大屏可用居中弹层）。

字段：
- 类型：`Tabs` 或 `Select`。
- 名称：`TextInput`。
- WebDAV：URL。
- SMB/FTP：host、port。
- SMB：share、rootPath、domain。
- FTP：rootPath、`Toggle` FTPS。
- LOCAL：目录选择按钮（`DocumentViewPicker`）。
- 用户名、密码（`TextInput.type(InputType.Password)` + 显示/隐藏）。
- 测试连接、保存、删除。

校验：
- 名称非空。
- WebDAV URL 非空且协议为 http/https。
- SMB/FTP host 非空。
- LOCAL 已选择目录。
- 错误通过字段下方 `Text` 提示，不使用弹窗堆叠。

### 7.5 智慧屏手机扫码填写

仅在智慧屏/强制大屏布局且新增模式下显示“手机扫码填写参数”。

流程：
1. 智慧屏启动局域网 TCP HTTP 服务（端口 8765 起自动选空闲）。
2. 获取本机局域网 IPv4。
3. 生成一次性 token。
4. 生成二维码：优先使用 HarmonyOS `Scan Kit` 的二维码生成能力；若当前 SDK 无生成 API，使用 ArkUI `Canvas` + 二维码编码器绘制。
5. 使用 `bindSheet` 或 `CustomDialog` 展示：
   - 二维码（220–280vp）
   - URL 文本
   - 提示：手机与智慧屏需在同一局域网；关闭后链接失效。
6. 手机浏览器填写表单，POST 提交。
7. 智慧屏表单自动回显，提示“已收到手机提交，请核对后保存”。
8. 关闭弹层立即停止服务。

HTTP 服务：
- 使用 `@kit.NetworkKit` 的 `TCPSocketServer`/`TCPSocket` 原生能力，不引入第三方 HTTP 服务器。
- 极简 HTTP/1.1：
  - GET `/` 返回 HTML 表单。
  - POST `/submit` 解析 `application/x-www-form-urlencoded`。
  - token 错误返回 403。
- 表单字段：type/name/localPath/url/host/port/share/rootPath/domain/username/password/secure。
- 返回 UTF-8 HTML；成功后提示回智慧屏保存。
- 只监听局域网；关闭即停止。

### 7.6 文本预览

- `Scroll` + `Text`，等宽字体。
- 读取上限 2–5MB。
- 编码检测：UTF-8/UTF-8 BOM/GBK/UTF-16。
- 大文件提示；TV/PC 支持方向键/滚轮滚动。
- 顶部显示文件名、大小、编码。

### 7.7 PDF 预览

- 优先系统 PDF 能力（若 SDK 提供 `PDF Kit` 或等价组件）。
- 否则使用 `Web` 组件 + 应用内离线 PDF.js 资源。
- 支持翻页、缩放、滚动。
- 大文件显示加载进度；失败提供“用其他应用打开”。

### 7.8 Office 预览

- docx/xlsx/pptx 只读预览。
- 优先系统 Office 预览能力（若 SDK 提供）。
- 否则 `Web` + 应用内离线渲染库（docx-preview / SheetJS / pptxjs 等），资源放 `rawfile`。
- 关闭不必要的 JSBridge；不执行外部脚本。
- 失败提供系统打开方式。

### 7.9 图片查看器

- 全屏黑/深色背景，沉浸式。
- `Swiper` 左右切换同目录图片。
- `Image` + `PinchGesture` 缩放（1×–5×）+ `PanGesture` 平移。
- 双击放大/还原。
- 缩放 > 1 时滑动只平移，不切图。
- 右下角“链接”按钮：仅当元数据中存在带协议作者/来源链接时显示。
- `bindSheet` 显示图片信息：尺寸、格式、大小、拍摄时间、作者、版权。
- 移除底部手势提示文案。
- 链接规则：
  - 仅允许 http/https/mailto 等安全协议；
  - 拒绝 file/content/javascript/data 等；
  - 普通作者名、域名、邮箱不当作 URL；
  - 使用系统 `openLink` 或 `startAbility` 打开；成功不提示，失败提示“没有应用可以响应此链接”。
- 智慧屏方向键翻页。

### 7.10 视频播放页

布局：
- 全屏 `XComponent` 画面。
- 顶部返回、标题、来源。
- 中部播放/暂停 + 快退 10 秒/快进 10 秒。
- 底部进度条、当前/总时长。
- 顶部/底部工具栏：倍速、音轨、字幕。
- 控件 4 秒无操作淡出；点击/按键恢复。

交互：
- 左右滑动 seek：按滑动比例计算目标时间，松手跳转；拖动时显示快进/快退提示。
- 进度条 `Slider` 拖动。
- 倍速：0.5/0.75/1/1.25/1.5/2/3。
- 音轨菜单、字幕菜单。
- 手机自动横屏；退出恢复。
- 屏幕常亮；离开页面释放。
- 智慧屏遥控器焦点、方向键 seek、确认播放。

### 7.11 音频播放页

布局：
- 背景：深色渐变或系统背景 + 封面模糊层。
- 大封面：`Image`，圆角 24vp；无封面显示 `SymbolGlyph` 音乐符号。
- 标题、艺术家 · 专辑。
- 进度条 + 当前/总时长。
- 底部：上一首 / 播放暂停 / 下一首。
- 底部工具栏：`倍速`、`列表`、`歌词`。
- `bindSheet` 播放列表/歌词。

逻辑：
- 当前目录全部音频组成播放列表。
- 上一首/下一首循环；播放结束自动下一首。
- 切歌立即清空旧标题/艺术家/专辑/封面/歌词。
- 异步元数据完成后校验当前曲目路径，旧任务不得覆盖新曲。
- 读取内置封面/标签；失败用文件名。
- 在线歌词：LRCLIB 搜索，同步歌词优先；失败显示“暂无歌词”。
- 后台播放：AVSession + 后台任务，锁屏/控制中心显示封面与播放控制。

### 7.12 缓存管理

- 文件数、总大小。
- 清理全部缓存。
- 清理后刷新。
- 不影响来源配置。
- 只清理应用缓存目录。

### 7.13 设置

- 默认视图（列表/网格）。
- 默认排序。
- 智慧屏大屏布局开关。
- 缓存上限。
- 关于、版本、开源许可。
- 可增加“跟随系统深浅色”。

---

## 8. 文件与网络数据层

### 8.1 统一接口

```ts
export interface FileSystemClient {
  list(path: string): Promise<FileEntry[]>;
  stat(path: string): Promise<FileEntry>;
  openStream(path: string, position?: number): Promise<InputStreamLike>;
  readRange(path: string, position: number, length: number): Promise<ArrayBuffer>;
  close(): Promise<void>;
}
```

`FileRepository` 按来源缓存 client；来源变更时失效。所有 IO 异步，UI 线程不阻塞。

### 8.2 本机目录

- `DocumentViewPicker` 选择目录。
- 持久化 URI 授权，应用重启后仍可访问。
- `@kit.CoreFileKit` 的 `fileIo` 读取目录/文件。
- 规范化路径，拒绝 `..` 越界。
- 权限失败提示重新选择目录。
- 智慧屏/PC 无文件选择器时，提供应用沙箱目录与已授权目录列表。

### 8.3 WebDAV

- `@kit.NetworkKit` HTTP 请求，`PROPFIND` Depth 1。
- Basic Auth。
- 解析 207 XML。
- 逐段 URL 编码。
- `Range: bytes=start-` 读取；处理 206/200/416。
- 错误映射：401/403 认证失败，404 不存在，5xx 服务端错误。

### 8.4 SMB

- 优先使用当前 SDK 官方 SMB 文件能力（若存在）。
- 否则使用 C 的 SMB2/3 库（如 libsmb2）通过 NAPI 封装：
  - connect / list / stat / open / read / seek / close
  - SMB2/2.1/3.x
  - NTLMv2、域、445 端口
- 大文件必须随机读，不得整文件下载。
- 若首版无法稳定支持，UI 保留类型但明确提示“当前版本暂不支持”，不得静默失败。

### 8.5 FTP/FTPS

- 基于 `TCPSocket` 实现 FTP 客户端，或使用经过验证的 C 库 NAPI 封装。
- 支持 PASV、USER/PASS、LIST/MLSD、REST、RETR、SIZE、MDTM。
- FTPS 显式 TLS；证书策略与 WebDAV 一致。
- 默认端口 21；FTPS 通常 21。
- 大文件流式读取 + 远程缓存。

### 8.6 远程缓存

```text
cacheDir/remote/<sourceId>/<sha256(path)>/data
cacheDir/remote/<sourceId>/<sha256(path)>/meta.json
cacheDir/remote/index.json
```

- LRU 清理。
- 图片/音频/文档可完整缓存。
- 视频按 Range 片段/临时文件缓存，不强制整文件。
- 缓存清理与统计只在缓存页显示。

---

## 9. 媒体实现

### 9.1 引擎选择

1. 通用格式：HarmonyOS `AVPlayer`（`@kit.MediaKit`），支持 MP4/MKV/WebM/MP3/FLAC/M4A 等系统支持的格式。
2. 全格式：WMV/AVI/RMVB/TS/M2TS/FLV 及 RealVideo/WMV 编码，使用 OHOS 原生媒体引擎：
   - FFmpeg 编译为 OHOS 静态库；
   - NAPI 暴露 demux/decode/seek；
   - `XComponent` Surface 渲染视频；
   - `AudioRenderer` 输出音频；
   - 或使用可移植到 OHOS 的完整播放器内核。
3. 按扩展名选择引擎；不支持时给出明确错误，不崩溃。

### 9.2 视频状态

```ts
export interface VideoState {
  loading: boolean;
  title: string;
  playing: boolean;
  buffering: boolean;
  durationMs: number;
  positionMs: number;
  speed: number;
  audioTracks: TrackOption[];
  subtitleTracks: TrackOption[];
  selectedAudioId: number;
  selectedSubtitleId: number;
  error: string | null;
}
```

### 9.3 M2TS / TS 时长与 seek

BDAV 的 `.m2ts` 常见 192 字节包，系统媒体元数据可能返回 0；必须自实现 PCR 探测。

算法：
1. 读取头部约 8MB。
2. 检测 188/192 字节包：
   - 188：同步字节 `0x47` 位于包首。
   - 192：同步字节位于包首 +4。
   - 按连续同步命中评分。
3. 解析 adaptation field：
   - control 2/3；
   - length ≥ 7；
   - PCR flag `0x10`；
   - PCR = 33-bit base + 9-bit ext。
4. 头部找第一个 PCR；尾部读取 8MB，找不到扩大到 16/32/64MB，找最后一个 PCR。
5. `durationMs = (last - first) / 27000`；负数加 `2^33 * 300` 处理回绕。
6. 有效范围 1 秒–24 小时。
7. PCR 成功时跳过耗时元数据提取。
8. 播放器 length 为 0 时使用 PCR 时长驱动进度条。
9. seek：引擎支持直接 seek；不支持则用 `start-time` 重开当前媒体，保留播放列表/标题/封面，不重置 UI。
10. 5.78GB 级文件只读头尾，不得全文件扫描。

验收：
- 35 分钟 BDAV 显示 `35:13`。
- 进度条可拖动、快进/快退可用。
- 打开不阻塞 UI。

### 9.4 音频状态

```ts
export interface AudioState {
  loading: boolean;
  title: string;
  artist: string;
  album: string;
  playing: boolean;
  durationMs: number;
  positionMs: number;
  speed: number;
  albumArt: image.PixelMap | null;
  playlist: PlaylistItem[];
  playlistIndex: number;
  lyrics: string | null;
  lyricsLoading: boolean;
  lyricsError: string | null;
}
```

### 9.5 音频元数据

- `AVMetadataExtractor` 读取标题、艺术家、专辑、封面。
- 无封面使用品牌占位图。
- 切换曲目必须重置旧信息。
- 异步任务完成后校验当前曲目路径，防止旧任务覆盖。
- 在线歌词：LRCLIB，按标题/艺术家查询；同步歌词优先。
- 歌词解析 LRC：`[mm:ss.xx]` 行；显示时高亮当前行（可选）。

### 9.6 后台音频

- `AVSession` 创建媒体会话。
- 申请 `ohos.permission.KEEP_BACKGROUND_RUNNING`。
- 配置 ContinuousTask（按 SDK 要求）。
- 锁屏/控制中心展示标题、封面、上一首/下一首/播放暂停。

---

## 10. 安全

1. 密码使用 HUKS + AES-GCM 加密，禁止明文落盘/日志。
2. 日志脱敏：不打印密码、token、完整敏感 URL。
3. 二维码 token 一次性；关闭弹层立即停服务。
4. 路径穿越防护：规范化后必须仍在来源根目录。
5. TLS 默认校验证书；不提供“忽略所有证书”开关。
6. 作者链接 scheme 白名单；拒绝 `javascript:`/`data:`/`file:` 等。
7. Web 预览关闭不必要 JSBridge，不执行外部脚本。
8. 缓存只写应用私有目录。

---

## 11. 权限

按需声明：

```json5
"requestPermissions": [
  { "name": "ohos.permission.INTERNET" },
  { "name": "ohos.permission.GET_NETWORK_INFO" },
  { "name": "ohos.permission.KEEP_BACKGROUND_RUNNING" }
]
```

- 文件访问优先 `DocumentViewPicker` + 持久化 URI，不申请全盘文件权限。
- 媒体库如使用 `photoAccessHelper`，按 SDK 要求申请媒体读权限；能用 Picker 则用 Picker。
- 二维码只展示，不申请相机权限。
- 后台音频按 SDK 配置 ContinuousTask/AVSession。
- 权限拒绝时展示可操作提示，不崩溃。

---

## 12. 性能与生命周期

- 目录首屏 < 1s（局域网正常）。
- 1000+ 项使用虚拟列表。
- 图片缩略图异步 + 内存/磁盘缓存。
- 4K 优先硬解；软解监控掉帧/温度。
- 远程视频 Range，不整文件下载。
- M2TS 只读头尾。
- 文件/网络/媒体 IO 使用 TaskPool。
- 页面销毁释放：播放器、PixelMap、HTTP 请求、TCP 服务、定时器。
- 后台音频保留 AVSession，视频默认暂停。

---

## 13. 错误文案

- `目录不存在或已被移动`
- `没有访问该目录的权限，请重新选择目录`
- `连接失败，请检查地址和网络`
- `用户名或密码不正确`
- `连接超时`
- `这个媒体无法解码或格式不受支持`
- `缓存读写失败`
- `这个目录是空的`
- `没有找到匹配的文件`

---

## 14. 工程与发布

### 14.1 应用配置

`AppScope/app.json5`：

```json5
{
  "app": {
    "bundleName": "com.cctomato.tv",
    "vendor": "cctomato",
    "versionCode": 1000000,
    "versionName": "1.0.0",
    "icon": "$media:app_icon",
    "label": "$string:app_name"
  }
}
```

### 14.2 构建

```bash
ohpm install
hvigorw assembleHap --mode module -p product=default
hvigorw assembleApp
```

实际任务名以 DevEco Studio 与 `hvigorfile.ts` 为准。

### 14.3 签名与上架

- 在 AppGallery Connect 创建应用 `com.cctomato.tv`。
- 配置签名证书/Profile，不提交证书到仓库。
- 产物 `.hap`/`.app` 上传 AppGallery Connect。
- 智慧屏需要横版 banner/大图标资源。
- 版本号从 `1.0.0` 开始，后续按发布递增。

### 14.4 CI

- 使用 DevEco Studio 命令行或华为云/AppGallery Connect 构建服务。
- 若自建 Runner，缓存 OHPM 与 HarmonyOS SDK。
- 签名材料放 Secret。
- 构建后校验 HAP/APP 签名与安装。

---

## 15. 测试矩阵

设备：
- 手机、折叠屏、平板、PC/2in1、智慧屏。
- 至少一台 API 12 设备/模拟器；按目标 SDK 补充。

来源：
- 本机目录（Picker 授权、重启后仍可访问）。
- WebDAV HTTP/HTTPS、中文/空格路径、错误密码。
- SMB2/3、域、错误密码。
- FTP/FTPS、PASV、REST、断线。

文件：
- 图片 jpg/png/webp/heic、大图、EXIF 链接。
- 文本 UTF-8/GBK/UTF-16、大文件。
- PDF、docx、xlsx、pptx。
- 视频 MP4 4K、MKV、WebM、WMV、AVI、TS、M2TS（192 字节 BDAV、起始时间非 0）、RMVB、FLV。
- 音频 MP3/FLAC/M4A/OGG，带/不带封面与标签。
- 1000+ 文件、中文名、空格、特殊字符、越界路径。

关键验收：
1. 音视频进入各自页面，不闪错误界面。
2. 切歌后标题/封面/歌词立即更新，旧任务不覆盖。
3. 音频底部有上一首/播放/下一首 + 倍速/列表/歌词。
4. M2TS 显示时长、可拖动、可快进快退。
5. 智慧屏二维码提交后字段回显，关闭后链接失效。
6. 图片作者链接仅协议 URL 走系统打开，不搜索。
7. 目录返回恢复列表与滚动位置。
8. 缓存清理后远程文件可重新加载。
9. 后台音频锁屏控制正常。
10. 智慧屏遥控器焦点全程可达。

---

## 16. 实施阶段

### 阶段 1：工程骨架
- Stage 工程、`com.cctomato.tv`、四设备类型。
- `Navigation`、主题 Token、断点布局。
- 首页/设置空壳。

### 阶段 2：本机与浏览
- Picker + 持久化 URI。
- FileKinds/FileEntry/LocalFileSystem。
- 首页来源卡片、添加本机来源。
- 浏览列表/网格、排序、面包屑、加载/空/错误。
- 目录历史与滚动恢复。

### 阶段 3：远程来源
- WebDAV 完整。
- FTP/FTPS。
- SMB（按 SDK/原生库可行性）。
- 加密凭据、测试连接、编辑/删除。
- 远程缓存与清理。

### 阶段 4：预览
- 文本、图片、PDF、Office。
- 图片元数据与链接规则。
- 文件信息/系统打开方式。

### 阶段 5：媒体
- 媒体类型路由分离。
- AVPlayer 通用格式。
- 全格式原生引擎。
- M2TS PCR 时长/seek。
- 视频手势、音轨/字幕、倍速。
- 音频播放列表、封面、歌词、后台。
- 智慧屏播放器焦点。

### 阶段 6：多设备
- 智慧屏焦点、布局、banner。
- 手机扫码填写服务 + 二维码。
- PC 窗口/鼠标/键盘。
- 平板多列。

### 阶段 7：稳定性与发布
- 大文件/大目录/弱网/异常。
- 生命周期释放、内存。
- 签名、HAP/APP、上架材料。
- 回归测试矩阵。

---

## 17. 风险与决策点

1. 全格式媒体：AVPlayer 不覆盖全部容器/编码；需优先验证 OHOS 原生 FFmpeg + XComponent 的编译、渲染、音视频同步。
2. SMB：若 SDK 无官方 SMB 能力，需 NAPI + SMB2/3 库；评估包体积、许可证、线程模型。
3. FTP/FTPS：需自实现或原生库；PASV/TLS/超时需真机验证。
4. PDF/Office：优先系统 Kit；没有则 Web + 离线渲染库，注意内存与安全。
5. 文件访问：Picker + 持久化 URI 在智慧屏/PC 的体验需真机验证。
6. 后台音频：ContinuousTask/AVSession 配置按目标 SDK 确认。
7. PC/2in1：窗口缩放、鼠标/键盘、右键菜单需单独测试。
8. 智慧屏：焦点、遥控器键值、banner 尺寸、上架要求。
9. 二维码服务：部分系统可能限制局域网监听；失败时提供手动输入地址兜底。
10. API 版本差异：所有能力以 DevEco 当前 SDK 为准。

---

## 18. 交付物

- 可编译运行的 HarmonyOS NEXT 工程。
- `com.cctomato.tv` 配置。
- 手机/平板/PC/智慧屏四形态可运行。
- 本机/WebDAV 完整；SMB/FTP 按风险决策交付。
- 浏览、预览、图片、视频、音频、缓存、设置、扫码。
- 关键路径测试与已知限制。
- 构建、签名、上架说明。
- `.hap`/`.app` 或 AppGallery 构建产物。

---

## 19. 开发约定

1. 先检查 DevEco 当前 SDK 的实际 API，不调用不存在的 Kit。
2. 先做可运行闭环，再扩展；不要一次性搭完所有页面。
3. 用户文案中文，代码标识符英文。
4. 所有文件/网络操作异步，UI 线程不做 IO。
5. 播放器、图片、TCP 服务、HTTP 请求在页面销毁时释放。
6. 修改模型/路由/权限时同步更新本文档。
7. 每阶段交付：实现说明、验证设备/API、未完成项、风险。
8. 行为以本文档验收标准为准；视觉与组件必须保持 HarmonyOS 原生。
