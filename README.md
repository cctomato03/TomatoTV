# TomatoTV

HarmonyOS NEXT 原生的本地与网络文件管理器，附带通用媒体播放能力。

- 应用名：**TomatoTV**
- Bundle Name：`com.cctomato.tv`
- 系统：HarmonyOS NEXT（Stage 模型，ArkTS / ArkUI）
- 设备：手机、平板、PC / 2in1、智慧屏
- 设计：HarmonyOS Design，全部使用系统组件、系统语义色与系统 Symbol 图标

> 需求与技术约束的唯一来源是仓库根目录的 [`HarmonyOS-NEXT-Development.md`](./HarmonyOS-NEXT-Development.md)。

## 功能概览

| 领域 | 当前状态 |
|---|---|
| 工程骨架 / 四设备形态 / 断点自适应 | ✅ |
| 首页来源卡片、添加/编辑/删除来源 | ✅ |
| 本机目录（Picker + 持久化授权 + 应用私有目录） | ✅ |
| WebDAV（PROPFIND 列表 / Range 读取 / 错误码映射） | ✅ |
| FTP（PASV / USER-PASS / MLSD-LIST / SIZE / MDTM / REST+RETR） | ✅ |
| SMB | ⛔ 明确提示“当前版本暂不支持”（需 libsmb2 NAPI） |
| 目录浏览：面包屑、排序、列表/网格、刷新、空/错/权限三态 | ✅ |
| 目录历史快照 + 滚动位置恢复（最多 32 层） | ✅ |
| 文本预览（编码探测、4MB 上限） | ✅ |
| 图片查看器（滑动、双指缩放、双击、元数据、作者链接白名单） | ✅ |
| 视频播放（AVPlayer + XComponent、倍速、手势 seek） | ✅ |
| 音频播放（播放列表、封面、歌词、AVSession 后台） | ✅ |
| PDF / Office 预览（应用内离线渲染） | ✅ pdf.js / docx-preview / SheetJS；PPTX 降级为系统打开方式 |
| M2TS / TS PCR 时长探测 | ✅ 已接入播放器（系统时长缺失时回退 PCR 结果） |
| 缓存管理（统计、清理、LRU） | ✅ |
| 单元测试（纯逻辑，CI 每次运行） | ✅ 24 项 |
| 智慧屏手机扫码填写参数（局域网 HTTP 服务 + Canvas 二维码） | ✅ |

完整的能力清单、偏差与已知限制见 [`docs/DEVIATIONS.md`](./docs/DEVIATIONS.md)，
阶段交付说明见 [`docs/STAGE-REPORT.md`](./docs/STAGE-REPORT.md)。

## 目录结构

```text
TomatoTV/
├── AppScope/                     应用级配置与图标
├── entry/                        主 HAP 模块
│   └── src/main/
│       ├── ets/
│       │   ├── entryability/     UIAbility 入口
│       │   ├── pages/Index.ets   Navigation 外壳与路由表
│       │   ├── navigation/       路由名与页面参数
│       │   ├── model/            来源、条目、文件类型、设置
│       │   ├── data/fs/          FileSystemClient 与 4 种来源实现
│       │   ├── data/repo/        FileRepository
│       │   ├── data/cache/       RemoteCache
│       │   ├── data/store/       SourceStore / SettingsStore
│       │   ├── data/crypto/      SecretStore（系统安全存储）
│       │   ├── media/            播放引擎、M2TS 时长、歌词
│       │   ├── view/             home / browse / source / preview / image / video / audio / cache / settings
│       │   ├── components/       来源卡片、列表行、网格、空状态、Symbol
│       │   ├── utils/            断点、格式化、日志脱敏、安全链接、事件总线、二维码、局域网服务
│       │   └── components/       来源卡片、列表行、网格、空状态、Symbol、文档预览容器
│       ├── resources/
│       │   ├── base/             颜色/尺寸 Token、深色模式、图标
│       │   └── rawfile/viewer/   离线渲染资源：pdf.js / docx-preview+JSZip / SheetJS
│       └── module.json5          四设备类型与权限声明
├── scripts/ci/                   CI 辅助脚本（SDK 准备、hvigor 安装、配置转换）
├── scripts/test/                 单元测试执行器（esbuild 打包 .ets 后运行）
├── test/unit/                    纯逻辑单元测试用例
└── docs/                         开发与交付文档
```

## 单元测试

```bash
npm install --registry=https://registry.npmjs.org/   # 仅测试工具链（esbuild / jsqr）
npm test
```

覆盖文件类型判定、路径越界防护、排序、格式化、WebDAV XML 解析、M2TS PCR 时长、
二维码编码（用 jsQR 反向解码校验）等 24 项纯逻辑断言，CI 每次运行。

## 本地构建（DevEco Studio）

1. 使用 DevEco Studio 5.0 及以上打开仓库根目录。
2. 在 `File > Project Structure > Signing Configs` 中配置自己的签名（**证书不入库**）。
3. 同步工程后执行：

```bash
ohpm install
hvigorw assembleHap --mode module -p product=default -p buildMode=debug
```

产物：`entry/build/default/outputs/default/entry-default-signed.hap`

## CI 构建（GitHub Actions）

仓库自带两条工作流：

- `.github/workflows/ci.yml`：每次 push / PR 做工程校验与编译（使用公开 OpenHarmony SDK）。
- `.github/workflows/release.yml`：推送 `v*` 标签时触发，构建未签名 HAP、打包源码，并创建 GitHub Release 上传产物。

细节与原理见 [`docs/BUILD-AND-RELEASE.md`](./docs/BUILD-AND-RELEASE.md)。

## 许可证

Apache-2.0
