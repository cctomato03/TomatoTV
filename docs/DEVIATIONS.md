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

## 3. PDF / Office 预览：应用内离线渲染（含 PPTX）

- 文档 §7.7 / §7.8 要求优先系统 Kit，其次 `Web` + 应用内离线渲染库。
- 当前 SDK（API 12 公开版）没有系统 PDF / Office 预览 Kit，因此采用第二种方案，已实现：
  - `resources/rawfile/viewer/pdf`：pdf.js 3.11（UMD 版本）+ 独立 worker，逐页渲染到 canvas；
  - `resources/rawfile/viewer/docx`：docx-preview 0.3 + JSZip，按页渲染 Word；
  - `resources/rawfile/viewer/sheet`：SheetJS(xlsx) 0.18，多工作表切换；
  - `resources/rawfile/viewer/pptx`：pptx-preview 1.0.7（内置 JSZip/echarts），幻灯片列表渲染；
  - `components/DocumentWebView.ets`：`Web` 组件加载 rawfile 内页面，文档字节由
    `onInterceptRequest` 注入虚拟同源地址 `https://tomato.doc.local/doc`。
- 安全（§10.7）：
  - 页面与渲染库全部内置 rawfile，不引用 CDN，不注册 `javaScriptProxy`（无 JSBridge 暴露）；
  - `onInterceptRequest` 只放行 `tomato.doc.local` 的文档/worker 字节，其余 http(s) 一律 403；
  - `domStorageAccess` / `fileAccess` / `onlineImageAccess` 关闭，`mixedMode` 关闭。
- 限制：
  - 单文件上限 64MB；PDF 最多渲染 120 页、表格最多显示 2000 行，超出会明确提示；
  - 已用无头 Chrome 对 pdf/docx/xlsx/pptx 四个页面做过真实渲染集成测试（`npm run test:viewer`）；
  - `resource://rawfile` 页面 + fetch 拦截组合的行为需真机验证（见 §11）。

## 4. SMB：已用纯 ArkTS 实现 SMB2.1（NTLMv2）

- 文档 §8.4 优先使用 SDK 官方 SMB 能力；当前 SDK 没有，因此自研了协议栈而不是引 NAPI：
  - `data/smb/SmbCrypto.ets`：MD4 / MD5 / SHA-256 / HMAC-MD5 / HMAC-SHA256（RFC 1320/1321/6234/2202/4231 向量全部通过单测）；
  - `data/smb/Ntlm.ets`：NTLMv2（含 MIC）、SPNEGO NegTokenInit/NegTokenResp 的 DER 编解码；
    NTProofStr / SessionBaseKey 与 **MS-NLMP 4.2.4 官方示例逐字节一致**；
  - `data/smb/Smb2Codec.ets`：SMB2 头、NEGOTIATE / SESSION_SETUP / TREE_CONNECT / CREATE /
    QUERY_DIRECTORY / QUERY_INFO / READ / CLOSE 的编解码；
  - `data/smb/Smb2Client.ets`：NetBIOS 分帧、MessageId 管理、报文签名（HMAC-SHA256）、会话/树管理；
  - `data/fs/SmbFileSystem.ets`：接入统一 FileSystemClient（list / stat / readRange）。
- 已验证（v1.4.1 起）：
  - 单元测试覆盖全部密码学与 NTLM 报文（含 MS-NLMP 4.2.4 官方示例）；
  - **协议一致性测试** `npm run test:smb`：仓库内自带一个按 MS-SMB2 严格实现的最小服务端，
    它会校验客户端每个报文的 StructureSize / 偏移是否合法，已跑通
    `NEGOTIATE → SESSION_SETUP(NTLMv2) → TREE_CONNECT → CREATE → QUERY_DIRECTORY →
    QUERY_INFO → READ → CLOSE → LOGOFF`，并逐字节校验 READ 返回内容；
  - 对着真实 Windows SMB 服务端（`npm run test:smb:live`）已协商到 0x0210。
- 本次一致性测试抓出并修复的三个真 bug：
  1. SESSION_SETUP 响应里安全 blob 的偏移用错了（用了 NEGOTIATE 的 56/58，应为 4/6）——
     这会导致认证永远拿不到挑战；
  2. READ 响应里 `DataOffset` 读成了 body 偏移 0（应为 2）——这会让远程文件读到错位数据
     （图片/文本/视频全花）；
  3. NTLM 标志里声明了 SIGN/SEAL 却没做密钥交换——服务端会期待
     EncryptedRandomSessionKey，可能导致会话密钥与签名不匹配；已改为
     `UNICODE|REQUEST_TARGET|NTLM|ALWAYS_SIGN|EXTENDED_SESSIONSECURITY|TARGET_INFO|128|56`。
  另外还补了：请求 20s 超时、目录枚举防死循环、错误信息带上"命令名 + 状态码"。
- 仍未验证 / 限制：
  - 本机 Windows 服务端在 SESSION_SETUP 阶段返回 `STATUS_INVALID_PARAMETER`，
    第三方参考客户端（`@marsaud/smb2`）在该机器上同样被拒，判断是 Windows 的 NTLM
    加固策略；因此**真实服务器的认证链路**仍需在你的 NAS/Samba 上验证一次
    （`npm run test:smb:live`）。失败时界面会显示 `命令 @状态码`，便于定位。
  - 只实现 SMB 2.0.2 / 2.1：不支持 3.x 的 AES-CMAC 签名与加密，也不支持 Kerberos。
  - 不支持 DFS、写操作、compound 请求；大文件按 1MB 分块 READ，已满足随机读需求。
- 调试建议：`Logger` 已输出 NEGOTIATE / 会话建立结果；失败时先看 `kind`（AUTH/SERVER/NETWORK）。

## 5. FTPS：支持隐式 TLS，不支持显式（AUTH TLS）

- 已实现：**隐式 FTPS**（Implicit TLS，默认端口 990）通过 `TLSSocket` 直接建连，
  控制通道与 PASV 数据通道都走 TLS（`data/fs/FtpFileSystem.ets` 的 `openChannel()`）。
- 不支持：**显式 FTPS**（21 端口 `AUTH TLS` / STARTTLS）——当前 SDK 的 TLS Socket
  无法在已连接的明文 socket 上升级 TLS。若服务器只支持显式 FTPS，会返回明确提示
  "服务器未在 TLS 上返回 FTP 欢迎信息…"，而不是静默失败。
- UI：来源编辑页的开关文案已改为"使用 FTPS（隐式 TLS）"，并与端口联动（21 ↔ 990）。

## 6. 远程媒体播放：本机回环 HTTP 代理实现 Range 流式播放

- 文档 §8.6 / §12 期望远程视频按 Range 流式播放，不做整文件下载。
- 已实现（v1.3.0）：
  - `utils/MediaStreamServer.ets`：在 `127.0.0.1`（8901 起自动选端口）起一个只读 HTTP/1.1 服务，
    实现 `Accept-Ranges`、`206 Partial Content`、`Content-Range`、`416`；
    播放器每次 `Range: bytes=a-b` 都通过 `FileSystemClient.readRange` 按需读取，
    **不会整文件下载**；256KB 分块顺序发送，支持多路并发连接。
  - URL 含 20 字符随机 token，且只监听回环地址，不对外暴露；
    来源被编辑/删除或应用退出时注销条目并关闭服务（`release()` / `stop()`）。
  - 为什么不直接把远程 URL 交给 `AVPlayer.url`：`AVPlayer.url` 无法携带
    `Authorization` 等自定义头，WebDAV Basic Auth / FTP 都需要鉴权，因此中间加一层本机代理。
- 回退策略：
  - 视频：若流式播放触发播放器错误，自动改用"整文件缓存 + `fd`"重试一次（`allowStream = false`）；
  - 音频：本来就直接走缓存（文件小、起播稳定，同时预热缓存）；
  - 本机文件始终走 `fd`，零拷贝。
- 单元测试：`RangeHeader` 的 `bytes=a-b` / `a-` / `-n` / 越界 / 非法头全部有断言（见 §13）。
- 仍待真机验证：`AVPlayer` 对 `http://127.0.0.1` 明文回环地址的支持度、大文件长时间播放的
  连接复用行为，以及 206 分段长度对 seek 的影响。

## 7. M2TS / TS 时长：已接入播放器，缺真实样本回归

- `media/MpegTsDuration.ets` 按文档 §9.3 实现：
  - 188/192 字节包检测（连续同步字节命中率评分）；
  - 尾窗读取起点通常不在包边界，因此先做同步相位对齐再扫描；
  - adaptation field 解析（control 2/3、length ≥ 7、PCR flag 0x10、33bit base + 9bit ext）；
  - `durationMs = (last - first) / 27000`，负数按 `2^33 * 300` 回绕处理，有效区间 1s–24h；
  - 只读头部 8MB + 尾部 8/16/32/64MB，5.78GB 级文件不做全文件扫描。
- 播放器接入：`VideoPlayerPage` 在 `AVPlayer.duration <= 0` 且扩展名为 ts/m2ts/mts/m2v 时，
  异步探测 PCR 时长，用它驱动进度条与总时长显示（跳转仍用 `seek()`）。
- 单元测试覆盖 188/192 两种包结构的时长计算（见 §13）。
- 仍缺：5.78GB 级真实 BDAV 样本的回归验证，以及部分机型上 PCR 与容器时长不一致时的实测表现。

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

- 所有可交互控件 `.focusable(true)`；来源卡片、文件行、网格单元有 2vp 品牌色焦点描边。
- 已实现：
  - 首页"添加存储"主按钮在无来源时 `defaultFocus(true)`；浏览页列表/网格首项默认聚焦；
  - 视频播放页 `onKeyEvent`：空格/回车/确认键播放暂停，左右方向键快退/快进 10 秒；
  - 音频播放页 `onKeyEvent`：空格/回车播放暂停，左右 10 秒 seek，上下切换上/下一首。
- 未实现：逐页自定义 D-Pad 焦点映射（`FocusControl.requestFocus`），当前依赖系统默认焦点顺序，
  需在智慧屏真机上逐页走查。

## 11. 其他待真机验证项

1. `DocumentViewPicker` 返回的 `file://docs/...` URI 与 `fileIo.listFileSync` 的兼容性
   （目录列举、子路径拼接、重启后持久化授权是否仍可读）。
2. `fileShare.persistPermission` 在智慧屏 / PC 上的实际行为。
3. 4K 硬解表现、`XComponent` Surface 在 2in1 窗口缩放时的重建。
4. `AVSession` 在锁屏 / 控制中心的展示（标题、封面、上一首/下一首）。
5. 系统 Symbol 图标名在更老的 API 版本上是否仍然存在（集中在 `components/Symbols.ets`）。
6. 文档预览：`Web` 加载 `resource://rawfile` 页面 + `onInterceptRequest` 注入字节的组合行为，
   以及 pdf.js worker（blob URL）、docx-preview 图片 base64 转换在真机 WebView 上的表现。

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
| §7.7 / §7.8 PDF、Office | `view/preview/DocPreviewPage.ets` + `components/DocumentWebView.ets` + `rawfile/viewer/*` | ✅ |
| §7.9 图片查看器 | `view/image/ImageViewerPage.ets` | ✅ |
| §7.10 视频播放 | `view/video/VideoPlayerPage.ets` | ✅ |
| §7.11 音频播放 | `view/audio/AudioPlayerPage.ets` | ✅ |
| §7.12 缓存管理 | `view/cache/CachePage.ets` | ✅ |
| §7.13 设置 | `view/settings/SettingsPage.ets` | ✅ |
| §8 数据层 | `data/**`（含 `data/smb/`）+ `utils/MediaStreamServer.ets` | ✅（仅显式 FTPS 除外） |
| §9 媒体 | `media/**` | ⚠️ 见 §6/§7/§9（轨道切换受 SDK 限制） |
| §10 安全 | `SecretStore`、`SafeLink`、`PathGuard`、`Logger.redact` | ✅ |
| §11 权限 | `entry/src/main/module.json5` | ✅ |

## 13. 单元测试

- `test/unit/logic.test.ts`：25 项纯逻辑断言
- `test/unit/smb.test.ts`：12 项 SMB/NTLM 断言（RFC 向量 + MS-NLMP 示例）
  - 文件类型判定（视频/音频/图片/文本/文档/压缩包）、MIME 推断
  - `PathGuard` 规范化与越界防护、层级换算
  - 目录优先排序（名称/大小/时间升降序，且不修改入参）
  - 格式化（大小、时长、百分比、时间）
  - WebDAV 207 Multi-Status 解析（含命名空间前缀、URL 编码中文名）
  - M2TS PCR 时长（188 / 192 字节包、非 TS 数据返回 0）
  - 二维码编码（尺寸/容量/定位图形结构 + 用 jsQR 反向解码验证 4 组载荷）
  - HTTP `Range` 解析（`bytes=a-b` / `a-` / `-n` / 越界 / 非法头）
- `scripts/test/run-unit.mjs`：用 esbuild 把 `.ets` 当 TypeScript 打包运行
  （相对导入自动补 `.ets`、`@kit.ArkTS` 映射到 Node 自带实现），所以测试不需要设备或 ArkUI 运行时。
- CI：`ci.yml` 与 `release.yml` 均包含"单元测试（纯逻辑）"job，Release 需测试通过才构建发布。
- `scripts/test/run-viewer.mjs`：无头 Chrome 真实渲染 pdf/docx/xlsx/pptx 四个页面（CI 每次运行）。
- `test/smoke/smb.server.ts` + `smb.conformance.ts`：按规范实现的 SMB2 测试服务端 + 一致性测试
  （`npm run test:smb`，CI 运行）；
- `test/smoke/webdav.smoke.ts`：本地起最小 WebDAV 服务端，验证 PROPFIND 与 Range 读取
  （`npm run test:webdav`，CI 运行）；
- `scripts/test/run-smb-smoke.mjs`：也可以指向真实 SMB 服务端做冒烟（`npm run test:smb:live`）。
- 不在单测范围内（必须真机）：播放器、TCP 局域网服务、Web 文档预览的真机行为、Picker、焦点走查。

## 14. 图片预览为什么改成"解码成 PixelMap"

v1.4.1 之前，远程图片是先把字节落到缓存文件，再把**裸沙箱路径**交给 `Image()`。
真机上对部分来源会出现"图片加载不出来"（`Image()` 对裸路径/URI 的解析不稳定），
而且旧实现里 `RemoteCache.download()` 无论收到多少字节都会把条目标记为"缓存完整"，
一旦某次读到 0 字节，这个坏缓存会被永久命中。

现在的链路：
1. 远程来源 `materializeToPath()` → 缓存文件（新增完整性校验：空数据或与 PROPFIND 声明大小
   不一致则丢弃并报"缓存读写失败"，不会再污染缓存）；
2. `ImageLoader.fromPath()` 用 `image.createImageSource(path).createPixelMap(desiredSize)` 解码，
   按最长边 2400px 降采样，控制内存；
3. 路径解码失败时退回 `readDocument()` 读字节 + `ImageSource.fromBytes()`；
4. `Image(pixelMap)` 渲染 —— 不再依赖 ArkUI 对裸路径的解析；
5. 页面销毁/切图时 `PixelMap.release()`。

WebDAV 侧同时加固：`readRange` 兼容服务端返回字符串而非 ArrayBuffer 的情况，
空数据会打日志而不是静默返回空缓冲。
