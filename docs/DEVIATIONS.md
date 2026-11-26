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
- v1.5.1 修复（真机反馈 `STATUS_INVALID_PARAMETER @SESSION_SETUP`）：
  4. 携带 NTLM Type3 的**第二个 SESSION_SETUP 请求，header 里的 SessionId 必须用服务端
     在上一响应中分配的会话 id**（之前一直发 0），PreviousSessionId 必须是 0。
     Windows / Samba 对 SessionId=0 的 Type3 一律返回 STATUS_INVALID_PARAMETER。
     修复后本机 Windows 服务端的返回从 `STATUS_INVALID_PARAMETER(0xc000000d)`
     变为 `STATUS_LOGON_FAILURE(0xc000006d)`（凭据是假的），证明 NEGOTIATE/NTLM 全链路已被服务端接受。
     一致性测试服务端也加了对应断言（首个请求 SessionId 必须 0、Type3 必须等于会话 id）。
  另外增加：SPNEGO 形式被拒时自动改用裸 NTLMSSP 重试一次。
- v1.6.0 修复（真机反馈 `STATUS_INVALID_PARAMETER @CREATE`）：
  5. **SMB2 请求体最小长度**：`StructureSize` 的含义是"固定部分 + 至少 1 字节 Buffer"。
     CREATE 固定 56 字节，打开**共享根**时文件名为空，请求体正好 56 字节，
     Samba 在 `smbd_smb2_request_verify_sizes(smb2req, 0x39)`（0x39=57）处直接判
     STATUS_INVALID_PARAMETER；QUERY_INFO 固定 40 字节、StructureSize=41 同理。
     修复：这两个请求体不足声明长度时补齐 padding。
     验证：用 Docker 起真实 **Samba 4.12** 容器（`-u alice -s media`）后，
     NEGOTIATE → NTLMv2 → TREE_CONNECT → list(/) → list(/sub) → stat → readRange
     全流程通过（读出真实文件内容），带 rootPath 的情况也通过。
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
  - **音频与视频都走流式**（v1.7.0 起音频不再整文件缓存下载）；
  - 视频若流式播放触发播放器错误，自动改用"整文件缓存 + `fd`"重试一次；
  - 本机文件始终走 `fd`，零拷贝。

v1.7.0 针对 SMB 播放的优化（真机反馈"视频放不出来、音频要等很久"）：
- **读句柄复用**：`Smb2Client` 按路径缓存读句柄（最多 6 个、空闲 60s 回收）。
  之前每次 `readRange` 都 CREATE + READ + CLOSE，边播边读时每 512KB 就要 3 个往返；
- **512KB 分块 + 按长度计算 CreditCharge**；
- **MessageId 是序列号**：每发一个报文要前进 CreditCharge 步，否则服务端
  `smb2_validate_sequence_number` 会直接断开连接（读大块时 charge > 1 必踩）；
- **STATUS_END_OF_FILE 视为正常结束**（读到末尾时服务端会返回 0xC0000011，
  之前被当成错误，播放到结尾前会中断）；
- HTTP 代理单次响应最多 8MB：播放器请求 `bytes=0-` 时也只回一段，由它续请求，
  避免把整部影片一次性推过去。
- 实测（Docker 内真实 Samba 4.12，20MB 文件）：顺序读 **64–69 MB/s**，
  4 次随机 seek 共 15ms，单块 512KB 读约 7ms —— 足够 4K 直读。

v1.7.1 针对"只有声音没有画面"的修复与诊断：
- Surface 绑定改为**用到时现取**：把 XComponentController 传给引擎，在设置 `surfaceId`
  时（含 `initialized`/`prepared` 两个时机）各取一次，避免 onLoad 时机拿不到 id；
- XComponent 被重建（尺寸变化/页面重排）时 onLoad 会再次触发，新增 `reattachSurface()`
  把新的 SurfaceId 重新交给播放器，否则旧 id 失效就只剩声音；
- 在 `prepared` 时打印 `duration / width×height / surface 是否已绑定`；
  若报告 0×0 说明没有视频轨或编码不受支持，日志会明确提示；
- 音频：流式播放若出错自动回退整文件缓存重播一次，并打印实际使用的来源（stream/fd）。

v1.8.0 调整（真机反馈"所有视频都提示无法解码，但有声音"）：
- **视频只在线播放，不再回退整文件缓存**（按产品要求：视频文件不落本地缓存）；
- AVPlayer 的 `error` 事件不再一律当成致命错误：只要播放器已进入 `prepared` / `playing`
  （即已经在出声），错误只记日志、不切"无法解码"界面；页面上也只在"未开始播放且进度为 0"时
  才显示错误遮罩。容器里的视频轨编码不受支持时，会表现为"有声无画"而不是整段失败；
- 流式代理会打印注册信息与播放器的 Range 请求（`mime/size/range`），便于判断是取流问题还是解码问题。
- 单元测试：`RangeHeader` 的 `bytes=a-b` / `a-` / `-n` / 越界 / 非法头全部有断言（见 §13）。
- 仍待真机验证：`AVPlayer` 对 `http://127.0.0.1` 明文回环地址的支持度、大文件长时间播放的
  连接复用行为，以及 206 分段长度对 seek 的影响。

v1.8.1 再次修复"远程视频只有声音没有画面"：
- 根因：`surfaceId` 在设置 `url` **之前**（idle 状态）就绑定，并在 `initialized` 时因
  `surfaceAttached` 已为 true 而跳过重绑。官方流程要求 `create → 设置监听 → 设置 url →
  设置 surfaceId → prepare`；提前绑定的 SurfaceId 会被播放器丢弃，于是音频轨正常、视频轨没有渲染目标。
- 修复：改为在 `initialized` 状态绑定 Surface 后再 `prepare()`；取不到 SurfaceId 时每 100ms 重试
  （最多约 2s），确保起播那一刻 surface 一定已绑定。
- XComponent 因旋转/重排重建时仍通过 `onLoad → reattachSurface()` 重新绑定，但只重绑、
  不会重复 `prepare()`。
- 新增 `videoSizeChange` / `startRenderFrame` 日志：有画面时能看到首帧渲染与真实分辨率，
  若始终没有 `startRenderFrame`，即可判定为取流或视频轨解码问题而非 Surface 绑定问题。
- 视频页进入时自动横屏：`setPreferredOrientation(LANDSCAPE)`，退出恢复 `UNSPECIFIED`；
  智慧屏 / 2in1 不做旋转（本身是宽屏）。
- 视频与音频仍为两个独立页面、两个独立引擎（`VideoPlayerPage + VideoEngine` /
  `AudioPlayerPage + AudioEngine`）：视频页使用 XComponent Surface 渲染，音频页使用
  AVPlayer + AVSession 后台播放，互不复用播放器实例。

v1.8.2 播放页布局与轨道选择：
- 画面比例：`AVPlayer.videoScaleType = VIDEO_SCALE_TYPE_SCALED_ASPECT`（默认 FIT 会拉伸铺满）。
  真机截图 2760×1256、16:9 视频左右各 351px 黑边、有效画面 2058×1158。
- 去掉原来悬浮在底部的三个按钮（被进度条层遮挡，点击无效），底部改为唯一工具栏：
  进度条 → 时间 → [快退 / 播放暂停 / 快进 / 倍速 / 音轨 / 字幕]，按钮统一 78×38，
  工具栏顶部就是进度条，不再向上越过进度条。
- 音轨/字幕：prepared 后读取 `getTrackDescription()`，菜单显示 `音轨 N · 编码 · 语言`；
  选择调用 `selectTrack()`，关闭字幕调用 `deselectTrack()`，`trackChange` 同步选中态。
- 真机验证：Cold War MKV 4 条音轨（TrueHD/AC3/DTS/AC3）切换成功；Netflix MKV 2 条内嵌
  SRT 字幕切换/关闭成功。

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

- 已接入 `AVPlayer.getTrackDescription()` / `selectTrack()` / `deselectTrack()`：
  - 在 `prepared` 后读取容器轨道（`track_index` / `track_type` / `track_name` / `language` / `codec_mime`）；
  - 音轨与内嵌字幕轨都会出现在底部工具栏的「音轨」「字幕」菜单里，选择会真正切到对应轨道，
    并通过 `trackChange` 事件同步选中状态；
  - 「关闭字幕」调用 `deselectTrack()`。
- 真机验证（HUAWEI Pura 90 Pro）：
  - MKV 4 条音轨（TrueHD / AC3 / DTS / AC3）可切换，日志确认 `selectTrack` 成功；
  - Netflix WEB-DL MKV 的 2 条内嵌 SRT 字幕可切换 / 关闭，日志确认 `selectTrack` 成功。
- 限制：是否把内嵌字幕绘制到画面由系统播放器决定；外挂字幕仍按官方方案
  （`addSubtitleFromFd` + `subtitleUpdate`）另行实现。

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

v1.5.1 追加：
- **目录内缩略图**：新增 `utils/ThumbnailService.ets`（内存缓存 60 张 + LRU、并发 2、去重、
  远程复用 RemoteCache），列表行与网格单元在 `aboutToAppear` 就异步加载缩略图，
  解码尺寸 192px（约 9MB 上限），离开浏览页时清空。
- **查看器轮播**：像素改为按路径缓存 + 预解码左右相邻图，左右滑动命中缓存即刻出图；
  Swiper 的 index 只用于初始页，之后完全由 onChange 驱动，页码指示器才准确。

v1.6.0 追加（真机反馈"进查看器一直转圈，滑一下才出图"）：
- 根因：ArkUI 的 `ForEach` 子项**不会因为父组件里"非状态数据"（普通 Map）变化而重绘**，
  首张图解码完成只是改了父组件的普通 Map，页面没有刷新。
- 修复：每张图抽成独立组件 `components/ImageSlide.ets`，自己持有 `@State PixelMap`，
  解码完成即局部刷新；像素缓存抽成 `utils/ImageMemoryCache.ets`（LRU 6 张 + 并发去重），
  预加载与展示共用同一份缓存。
- 底部圆点指示器去掉，只保留"当前 / 总数"数字。
- 右下角"链接"按钮（v1.7.0 调整，按产品要求）：**只取图片元数据里"作者"字段中的链接**
  （这类字段通常存的是打开某个 App 的深链），作者为空时再看"版权"字段；
  **不再回退到图片自身 URL**。打开时不做 scheme 白名单，直接交给系统按 URL 分发
  （这一条按产品要求偏离了文档 §7.9 的白名单限制）。
- 图片顺序与浏览页一致（同样走 `FileSorter` + 用户当前排序方式），
  之前是直接按服务端返回顺序，导致列表与轮播顺序不一致。
- v1.7.1 修复（真机反馈"双击/缩放后图片跳到上一张"）：
  Swiper 的 `.index()` 之前绑定的是一个会随状态变化的变量，缩放引起重建时被重新应用，
  把页面拉回初始页；改成 `$$this.index` 双向绑定，缩放/双击都不再跳页。
- v1.8.0 调整（按产品要求）：**链接按钮常显**，点击时才判断当前图片的作者信息里有没有链接，
  没有则提示"这张图片没有作者链接"；同时会在点击时重新读一次元数据（切图后元数据是异步到达的）。
- v1.7.1 修复（真机反馈"链接按钮不显示"）：
  元数据改为**从文件字节**建 ImageSource（远程缓存文件没有扩展名、本机 Picker URI
  直接当路径都可能让 `createImageSource(path)` 失败，一旦失败就连作者字段都读不到）；
  读取字段扩展为 作者 → 版权 → 图片描述，并把结果打到日志便于核对。

## 15. 本机目录权限（v1.8.0 补充）

HarmonyOS NEXT **不提供"读取全部存储"权限**，官方路径是 `DocumentViewPicker` 选择目录 +
`fileShare.persistPermission()` 持久化授权。之前少了一步：

- 持久化授权在**应用重启后需要 `fileShare.activatePermission()` 重新激活**，
  否则读目录会直接报"没有访问该目录的权限"。现在 `SourceStore.init()` 会为每个本机来源
  （`file://` 开头的 URI）逐个激活，失败只记日志。
- 权限不足时，浏览页的错误页新增「重新选择目录」按钮（直接跳到该来源的编辑页），
  并提示"HarmonyOS 不允许应用直接读取全部存储…"；来源编辑页的本机目录区域也补充了同样的说明。
- 智慧屏 / PC 没有文件选择器时，可以直接使用内置的「应用目录」（应用沙箱），无需任何授权。
