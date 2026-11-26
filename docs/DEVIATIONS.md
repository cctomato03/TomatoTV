# 实现偏差与已知限制

本文件记录相对 `HarmonyOS-NEXT-Development.md` 的实现偏差、降级方案与待验证项。
每一处均给出"为什么"和"后续怎么做"。

## 1. 状态管理：使用 V1 而非 @ObservedV2/@Trace

- 文档 §4 约定状态类使用 `@ObservedV2`/`@Trace`。
- 实际实现使用 `@State` / `@Prop` / 显式刷新（`EventBus` 事件）的 V1 模式。
- 原因：V1 与 V2 不能在同一组件树混用。V2 需要 `@ComponentV2` + `@Local` 全套改写，
  首版以"稳定可编译、行为可预测"为先；页面状态均为浅层对象/数组，V1 已能覆盖。
- 后续：可整体迁移到 V2（`@ObservedV2` + `@Trace` + `@ComponentV2`），接口层无需改动。

## 2. 密码存储：Asset Store Kit 而非直接 HUKS + AES-GCM

- 文档 §10.1 要求 HUKS + AES-GCM 加密落盘。
- 实际使用 `@kit.AssetStoreKit`（系统级安全存储，底层由 HUKS 托管密钥，密钥不出安全环境）。
- 原因：自行生成密钥再落盘会引入"密钥自身如何保护"的新问题；Asset Store 是系统推荐做法，
  满足"禁止明文落盘 / 日志脱敏"的实质要求。
- 位置：`entry/src/main/ets/data/crypto/SecretStore.ets`。

## 3. PDF / Office 预览：首版降级为系统"打开方式"

- 文档 §7.7 / §7.8 要求应用内预览，优先系统 Kit，其次 Web + 离线渲染库。
- 当前公开 SDK（API 12）未提供系统 PDF / Office 预览 Kit，也未在仓库内置 pdf.js / docx-preview 等离线资源
  （体积与校验成本较高，且需要真机验证 Web 组件的本地资源加载与 JS 沙箱策略）。
- 现状：`DocPreviewPage` 提供文件信息 + "用其他应用打开"（远程文件会先落缓存再交给系统）。
- 后续：在 `rawfile` 内置离线渲染库，用 `Web` 组件加载应用内资源渲染；需补充安全策略（禁用 JSBridge、不执行外部脚本）。

## 4. SMB：明确不支持，不静默失败

- 文档 §8.4 允许"若首版无法稳定支持，UI 保留类型但明确提示"。
- 实现：`SmbFileSystem` 所有操作抛出 `UNSUPPORTED`，浏览页与编辑页都会显示
  "当前版本暂不支持 SMB：需要 libsmb2 的 NAPI 封装"。
- 后续：交叉编译 libsmb2 + OpenSSL，通过 NAPI 暴露 connect/list/stat/open/read/seek/close，
  并保证大文件随机读。

## 5. FTPS（显式 TLS）：明确不支持

- 文档 §8.5 要求 FTPS 显式 TLS。
- 当前 `TCPSocket`/`TLSSocket` 能力无法在已连接的明文控制连接上执行 STARTTLS，
  因此 `secure = true` 时直接抛出 `UNSUPPORTED` 并在表单提示，而不是静默降级为明文。
- 纯 FTP（PASV/MLSD/REST/RETR）已实现。后续可用 C 库 + NAPI 补齐 FTPS。

## 6. 远程媒体播放：先整文件落缓存再播放

- 文档 §8.6 / §12 期望视频按 Range 片段流式播放。
- 现状：远程音视频通过 `RemoteCache.download()` 完整缓存后再用 `AVPlayer.fdSrc` 播放。
  本机文件直接 `fd` 播放，零拷贝。
- 原因：`AVPlayer.url` 不支持自定义 `Authorization` 头，WebDAV Basic Auth 需要鉴权；
  自定义 Range 数据源（`dataSrc`）需要实现完整的回调式读写，工作量大且易出错。
- 影响：首次播放远程大文件需要等待下载；缓存命中后起播很快。缓存页可查看/清理。
- 后续：实现 `AVPlayer.dataSrc` 回调式随机读，直接对接 `FileSystemClient.readRange`。

## 7. M2TS / TS 时长：算法已实现，未用真实样本回归

- `media/MpegTsDuration.ets` 按文档 §9.3 实现：188/192 包同步评分、adaptation field 解析、
  PCR 首尾差值、`2^33 * 300` 回绕处理、1s–24h 有效区间、只读头尾最多 64MB。
- 尚未接入播放页（当前由 AVPlayer 自身时长驱动进度条），也未用 5.78GB 级 BDAV 样本验证。
- 后续：当 `player.duration === 0` 时回退到 PCR 探测结果；并补充真实样本回归。

## 8. 智慧屏扫码填写：已实现，二维码为自研编码器

- 文档 §7.5 要求局域网 TCP HTTP 服务 + 一次性 token + 二维码。
- 已实现（v1.1.0 起）：
  - `utils/PairingServer.ets`：`TCPSocketServer` 从 8765 起自动选空闲端口（至 8785），
    监听 `0.0.0.0`；`GET /` 返回手机端表单 HTML，`POST /submit` 解析
    `application/x-www-form-urlencoded`；token 错误或已失效返回 403；
    提交成功后 token 立即置空，表单字段回显到智慧屏表单并提示"已收到手机提交，请核对后保存"；
    关闭弹层（`onDisappear`）或页面销毁时 `stop()` 立即停止监听。
  - `utils/LanAddress.ets`：通过 `connection.getConnectionProperties` 取本机局域网 IPv4（优先私有网段）。
  - `utils/QrCode.ets` + `components/QrView.ets`：当前 SDK 无二维码生成 API，因此自研字节模式编码器
    （纠错等级 M，版本 1–3，单 RS 块，固定掩码 0），用 ArkUI `Canvas` 逐格绘制。
    该算法的等价 JS 版本已用 `jsQR` 解码器验证：v1/v2/v3 × 全部 8 种掩码全部可正确解码。
- 限制：
  - token 长度 10 字符（约 50 bit），使 URL 稳定落在 42 字节以内（版本 3 容量）；
    若地址更长会退化为"仅显示 URL，请手动输入"。
  - 二维码生成属自研实现，尚未在智慧屏真机上用手机实扫验证。
  - 入口仅在"强制大屏布局/智慧屏 + 新增存储"时显示（符合文档限定）。

## 9. 播放器轨道切换

- 当前 SDK 的 `AVPlayer` 未开放 `selectTrack`，播放页的"音轨/字幕"菜单可以列出探测到的轨道，
  但选择仅更新界面状态，不会真正切换。
- 后续：随原生引擎（FFmpeg + XComponent）一起实现真正的轨道切换。

## 10. 焦点与遥控器

- 所有可交互控件 `.focusable(true)`，来源卡片/文件行/网格单元有焦点描边（2vp 品牌色）。
- 智慧屏方向键的**自定义**焦点映射（`.onKeyEvent` + `FocusControl`）尚未逐一编写，
  目前依赖系统默认的 D-Pad 焦点移动顺序；需要在真机上逐页走查。

## 11. 其他待真机验证项

1. `DocumentViewPicker` 返回的 `file://docs/...` URI 与 `fileIo.listFileSync` 的兼容性
   （目录列举、子路径拼接、重启后持久化授权是否仍可读）。
2. `fileShare.persistPermission` 在智慧屏 / PC 上的实际行为。
3. 4K 硬解表现、`XComponent` Surface 在 2in1 窗口缩放时的重建。
4. `AVSession` 在锁屏 / 控制中心的展示（标题、封面、上一首/下一首）。
5. 系统 Symbol 图标名在更老的 API 版本上是否仍然存在（集中在 `components/Symbols.ets`）。

## 12. 与文档条目对应的实现清单

| 文档章节 | 实现位置 | 状态 |
|---|---|---|
| §5 数据模型 | `model/*.ets` | ✅ |
| §6 文件类型判定 | `model/FileKinds.ets` | ✅ |
| §7.1 应用外壳 | `pages/Index.ets` + `Navigation` | ✅ |
| §7.2 首页 | `view/home/HomePage.ets` | ✅ |
| §7.3 浏览页 | `view/browse/BrowsePage.ets` | ✅ |
| §7.4 添加/编辑存储 | `view/source/SourceEditPage.ets` | ✅ |
| §7.5 智慧屏扫码 | `utils/PairingServer.ets` + `utils/QrCode.ets` + `components/QrView.ets` | ✅ |
| §7.6 文本预览 | `view/preview/TextPreviewPage.ets` | ✅ |
| §7.7 / §7.8 PDF、Office | `view/preview/DocPreviewPage.ets` | ⚠️ 降级 |
| §7.9 图片查看器 | `view/image/ImageViewerPage.ets` | ✅ |
| §7.10 视频播放 | `view/video/VideoPlayerPage.ets` | ✅ |
| §7.11 音频播放 | `view/audio/AudioPlayerPage.ets` | ✅ |
| §7.12 缓存管理 | `view/cache/CachePage.ets` | ✅ |
| §7.13 设置 | `view/settings/SettingsPage.ets` | ✅ |
| §8 数据层 | `data/**` | ✅（SMB/FTPS 除外） |
| §9 媒体 | `media/**` | ⚠️ 见 §6/§7/§9 |
| §10 安全 | `SecretStore`、`SafeLink`、`PathGuard`、`Logger.redact` | ✅ |
| §11 权限 | `entry/src/main/module.json5` | ✅ |
