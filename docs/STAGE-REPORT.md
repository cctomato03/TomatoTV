# 阶段交付说明（v1.0.0）

对应 `HarmonyOS-NEXT-Development.md` §19.7 的"每阶段交付：实现说明、验证设备/API、未完成项、风险"。

## 1. 本次交付范围

按产品文档的阶段划分，本次交付覆盖 **阶段 1–4 的完整闭环 + 阶段 5 的 AVPlayer 通用格式 + 阶段 7 的工程化/发布**：

| 阶段 | 内容 | 状态 |
|---|---|---|
| 阶段 1 工程骨架 | Stage 工程、`com.cctomato.tv`、四设备类型、`Navigation`、主题 Token、断点布局、首页/设置空壳 | ✅ 完成 |
| 阶段 2 本机与浏览 | Picker + 持久化 URI、FileKinds/FileEntry/LocalFileSystem、来源卡片、浏览列表/网格、排序、面包屑、加载/空/错误、目录历史与滚动恢复 | ✅ 完成 |
| 阶段 3 远程来源 | WebDAV 完整、FTP + 隐式 FTPS、SMB2.1（纯 ArkTS + NTLMv2）、加密凭据、测试连接、编辑/删除、远程缓存与清理 | ✅ 完成（仅显式 FTPS 除外） |
| 阶段 4 预览 | 文本、图片（元数据与作者链接规则）、文件信息/系统打开方式；PDF/DOCX/XLSX/PPTX 应用内离线渲染（pdf.js / docx-preview / SheetJS / pptx-preview） | ✅ 完成 |
| 阶段 5 媒体 | 媒体类型路由分离、AVPlayer 通用格式、视频手势/倍速/音轨字幕菜单、音频播放列表/封面/歌词/后台、M2TS PCR 时长已接入播放器、遥控器按键 | ⚠️ 部分（全格式原生引擎与真正轨道切换受 SDK 限制） |
| 阶段 6 多设备 | 断点布局、大屏分栏、焦点可达、TV 强制布局开关、智慧屏手机扫码填写参数（局域网 HTTP 服务 + Canvas 二维码 + 字段回显） | ✅ 完成 |
| 阶段 7 稳定性与发布 | 生命周期释放、CI 构建、Release 分发、文档 | ✅ 完成 |

## 2. 实现说明要点

### 2.1 工程与外壳

- `pages/Index.ets`：唯一入口页面，`Navigation` + `NavPathStack`，按断点切换 `Stack` / `Split`；
  `@Builder pageMap` 作为路由表，页面均以 `NavDestination` 为根。
- 断点：`<600vp` 单栏、`600–840vp` 三列、`>840vp` 四列分栏、`≥960vp` 或"强制大屏布局"按智慧屏 5 列。
- 视觉 Token 全部在 `resources/base/element/{color,float}.json` 与 `resources/dark/.../color.json`，
  代码里只引用 `$r('app.color.*')` / `$r('app.float.*')`。

### 2.2 数据层

- `FileSystemClient`（list/stat/openStream/readRange/testConnection/close）统一四种来源。
- `FileRepository` 按来源 id 缓存 client，来源保存/删除时 `invalidate`。
- `RemoteCache`：`cacheDir/remote/<sourceId>/<sha256(path)>/{data,meta.json}` + `index.json`，
  支持统计、清理全部、LRU 上限清理、分块下载。
- 密码走 `SecretStore`（Asset Store Kit），配置 JSON 里不落明文；日志经 `Logger.redact` 脱敏。

### 2.3 浏览体验

- 进入目录先清空并显示 `LoadingProgress` + "正在读取目录…"；下拉刷新保留旧内容并显示顶部进度条。
- 目录历史最多 32 层快照（path + entries + 首可见索引 + 面包屑），返回时用 `Scroller.scrollToIndex` 恢复。
- 空目录 / 错误 / 权限不足三种状态分别有独立 UI；错误文案统一走 `FsErrorText`（对应文档 §13）。

### 2.4 媒体

- 按扩展名在进入页面前就确定 `mediaType` 并路由到视频/音频/图片/文本/文档页，不存在"先开通用播放器再切换"。
- 视频：`XComponent(SURFACE)` + `AVPlayer`，4 秒无操作淡出控制栏，左右滑动按比例 seek，倍速 0.5–3x。
- 音频：当前目录音频构成播放列表，切歌立即清空旧标题/封面/歌词；异步元数据与歌词任务用 token 校验，
  旧任务不会覆盖新曲；`AVSession` + `audioPlayback` 后台模式支持锁屏控制。
- M2TS/TS：`MpegTsDuration` 实现 188/192 包检测与 PCR 首尾差值算法，只读头尾（最多 64MB）。

## 3. 验证情况

| 项 | 情况 |
|---|---|
| 编译验证 | ✅ 使用 **OpenHarmony SDK 5.0.0 Release（API 12）** 完整编译通过，产出 `entry-default-unsigned.hap`（约 3.9MB，含离线文档渲染资源） |
| 单元测试 | ✅ 37 项断言（25 逻辑 + 12 SMB/NTLM）与 4 个文档预览页的无头浏览器渲染测试全部通过 |
| 真机 / 模拟器验证 | ❌ 本次开发环境没有 DevEco Studio 与 HarmonyOS 设备，未做真机运行验证 |
| CI 验证 | ✅ GitHub Actions 使用同一套脚本复现编译 |

> 需要注意的是：OpenHarmony SDK 与 HarmonyOS SDK 的 API 集合高度重叠（`@kit.*` 均可用），
> 编译通过说明 ArkTS 语法与 API 使用正确，但**不能替代真机行为验证**。

## 4. 未完成项（按优先级）

1. 显式 FTPS（AUTH TLS / STARTTLS）：SDK 无法在明文连接上升级 TLS。
2. SMB 端到端认证的真机/NAS 验证（本机 Windows 服务端因 NTLM 加固策略无法完成验证）。
3. SMB 3.x（AES-CMAC 签名与加密）与 Kerberos。
4. 远程音视频流式播放的真机验证（本机回环 HTTP 代理已实现，见 DEVIATIONS §6）。
5. 全格式原生播放引擎（FFmpeg + XComponent + AudioRenderer）与真正的音轨/字幕切换。
6. 智慧屏方向键自定义焦点映射的真机走查。
7. ArkTS 单元测试与 UI 测试工程。

## 4.1 v1.2.0 增量

| 项 | 说明 |
|---|---|
| 文档预览 | 新增 `rawfile/viewer/{pdf,docx,sheet}` 离线渲染资源与 `DocumentWebView` 容器；PDF/DOCX/XLSX 应用内预览，字节经 `onInterceptRequest` 注入，无外发请求 |
| M2TS 时长 | `MpegTsDuration` 修正尾窗同步相位对齐与末包边界；`VideoPlayerPage` 在系统时长缺失时回退 PCR 结果 |
| 遥控器 | 视频/音频页 `onKeyEvent`（播放暂停、±10s seek、上下切歌），首页与浏览页 `defaultFocus` |
| 测试 | 新增 `test/unit` + `scripts/test/run-unit.mjs`，24 项断言；CI 增加单元测试 job 并作为 Release 前置 |

## 4.2 v1.3.0 增量

| 项 | 说明 |
|---|---|
| 远程流式播放 | 新增 `MediaStreamServer`（127.0.0.1 只读 HTTP + Range/206/416），视频按需读远程片段，不整文件下载；播放失败自动回退缓存 |
| Range 逻辑 | 抽出 `RangeHeader` 纯逻辑并对齐 `a-b` / `a-` / `-n` / 越界 / 非法头，纳入单元测试 |
| 音频 | 保持缓存播放（体积小、起播稳定），等待真机验证后再切流式 |

## 4.3 v1.4.0 增量

| 项 | 说明 |
|---|---|
| PPTX 预览 | 新增 `rawfile/viewer/pptx`（pptx-preview UMD），`DocPreviewPage` 支持 PPTX；四个预览页均有无头浏览器集成测试 |
| SMB | 新增 `data/smb/`（SmbCrypto / Ntlm / Smb2Codec / Smb2Client），SMB2.1 + NTLMv2 + HMAC-SHA256 签名，接入 FileSystemClient；本机冒烟验证完成 NEGOTIATE |
| FTPS | 隐式 TLS（990）通过 TLSSocket 打通控制与数据通道；显式 AUTH TLS 仍不支持 |
| 测试 | 新增 `test/unit/smb.test.ts`（12 项，含 MS-NLMP 官方 NTLMv2 向量）、`scripts/test/run-viewer.mjs`（四页渲染）、`scripts/test/run-smb-smoke.mjs`（协议冒烟），CI 增加浏览器集成测试步骤 |

## 4.4 v1.4.1 增量（真机反馈修复）

| 问题 | 处理 |
|---|---|
| WebDAV 图片加载不出来 | 根因是"裸沙箱路径交给 `Image()`" + 缓存可能被 0 字节条目污染。改为：缓存文件 → `createPixelMap` 解码 → `Image(pixelMap)`；`RemoteCache.download` 增加完整性校验与失败清理；`readRange` 兼容字符串返回 |
| SMB 提示"服务端返回异常" | 一致性测试抓出三个协议 bug（SESSION_SETUP blob 偏移、READ DataOffset、NTLM 标志），并补了请求超时、枚举防死循环、错误信息带命令+状态码 |
| 已有存储缺少修改入口 | 来源卡片新增显式"编辑"按钮（长按仍出菜单）；移除了长按直接弹删除的旧行为；内置来源不可删除 |
| 测试 | 新增 `npm run test:smb`（SMB2 一致性，自带服务端）与 `npm run test:webdav`（WebDAV 一致性），均进 CI |

## 5. 风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| Picker URI 与 fileIo 的兼容性未真机验证 | 本机目录可能无法列举 | 已提供应用私有目录作为兜底来源；`LocalFileSystem` 内聚了路径处理，便于按真机结果调整 |
| 系统 Symbol 名称在更低 API 版本可能不存在 | 图标缺失 | 图标集中在 `components/Symbols.ets`，替换成本低 |
| 远程媒体需整文件缓存 | 大文件起播慢 | 缓存可复用；后续改 `dataSrc` 流式 |
| OpenHarmony SDK 构建产物的 deviceTypes 为 `default/tablet` | 产物不能直接装到 HarmonyOS NEXT 手机 | 交付说明中明确：安装请用 DevEco + 自己的签名重新构建 |
| SMB 端到端认证未在真实服务端验证 | 首次连接 NAS 可能需要调试（NTLM 加固、共享名、域） | 提供 `npm run test:smb` 冒烟脚本与详细日志；纯 ArkTS 协议栈便于按真机日志修正 |
| V1 状态管理与文档约定的 V2 不一致 | 后续迁移成本 | 已记录迁移方案，模型层与数据层不受影响 |
