# 构建与发布说明

## 1. 两种构建方式

| 方式 | SDK | 产物 | 用途 |
|---|---|---|---|
| DevEco Studio（本地） | HarmonyOS SDK（登录华为账号下载） | 已签名 `.hap` / `.app` | 真机安装、上架 AppGallery |
| GitHub Actions（CI） | 公开 OpenHarmony SDK 5.0.0 Release（API 12） | 未签名 `.hap` | 编译校验、产物分发、源码可复现验证 |

CI 无法使用 HarmonyOS SDK：它需要登录华为开发者账号下载，GitHub 托管 Runner 无法满足。
因此 CI 使用可匿名下载的 OpenHarmony 公共 SDK 完成 **ArkTS 编译 + HAP 打包**，
产物用于验证代码可编译、可打包，并作为每次 Release 的可下载产物。

## 2. CI 工作原理

### 2.1 准备 SDK

`repo.huaweicloud.com` 提供公开的 OpenHarmony SDK 压缩包：

```
https://repo.huaweicloud.com/openharmony/os/5.0.0-Release/ohos-sdk-windows_linux-public.tar.gz
```

解压后目录形如 `linux/`、`windows/`，内部每个组件仍是 zip。CI 里把它整理为 hvigor 期望的布局：

```
$SDK_ROOT/
└── 12/
    ├── ets/        (ArkTS API、kits、build-tools)
    ├── js/
    ├── native/
    └── toolchains/ (restool、app packing 工具等)
```

`local.properties` 写入 `sdk.dir=$SDK_ROOT`，环境变量 `DEVECO_SDK_HOME` / `OHOS_BASE_SDK_HOME` 指向同一路径。

### 2.2 安装 hvigor

hvigor 及其插件发布在华为 npm 镜像（公开可读）：

```bash
npm install --registry https://repo.harmonyos.com/npm/ \
  @ohos/hvigor@5.7.0 @ohos/hvigor-ohos-plugin@5.7.0
```

### 2.3 接受 SDK 许可

hvigor 在构建前会调用华为许可服务校验"是否已接受 OpenHarmony SDK 许可"，并把结果缓存在
`$SDK_ROOT/licenses/*.sha256`。CI 里没有交互式 DevEco，因此工作流在安装插件后对该校验调用打一个
**幂等补丁**（等价于在 DevEco 里勾选"同意许可"）：

```bash
node scripts/ci/accept-sdk-license.mjs
```

该脚本只把 `findUnacceptedLicenses()` 的实现替换为返回空数组，不改动任何其他逻辑，
并且重复执行不会叠加修改。

### 2.4 工程配置转换

仓库里的 `build-profile.json5` / `module.json5` 面向 HarmonyOS NEXT
（`runtimeOS: HarmonyOS`，`deviceTypes: phone/tablet/2in1/tv`）。
OpenHarmony SDK 只带 `default` / `tablet` 两种 device-define，且要求整数 `compileSdkVersion`。

CI 在构建前执行：

```bash
node scripts/ci/prepare-openharmony.mjs
```

将产品配置临时改写为 `runtimeOS: OpenHarmony`、`compileSdkVersion: 12`、
`deviceTypes: [default, tablet]`；本地如需还原：`node scripts/ci/prepare-openharmony.mjs --restore`。

### 2.5 构建命令

```bash
node node_modules/@ohos/hvigor/bin/hvigor.js \
  --mode module -p product=default -p buildMode=debug \
  --no-daemon assembleHap
```

产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`

## 3. 工作流

### `.github/workflows/ci.yml`

- 触发：push 到 `main`、任意 PR、手动 `workflow_dispatch`
- 步骤：检出 → 缓存 SDK → 解压 SDK → 安装 hvigor → 接受许可 → 转换配置 → 编译 → 上传 artifact

### `.github/workflows/release.yml`

- 触发：push `v*` 标签（或手动触发并指定 tag）
- 步骤：同上，外加
  - 生成源码压缩包 `TomatoTV-<tag>-source.zip`
  - 生成构建信息 `build-info.json`（commit、SDK 版本、产物 SHA256）
  - 用 `softprops/action-gh-release` 创建/更新 Release 并上传全部产物

发布新版本：

```bash
git tag v1.0.0
git push origin v1.0.0
```

## 4. HarmonyOS 签名（本地 / 真机）

1. AppGallery Connect 创建应用 `com.cctomato.tv`。
2. DevEco Studio `File > Project Structure > Signing Configs` 勾选自动签名（调试）或上传自己的
   `.cer` / `.p7b` / `.p12`。
3. 签名材料**不要提交到仓库**；如需在自建 Runner 上构建，放 GitHub Secrets：
   `SIGNING_CERT`（p12 base64）、`SIGNING_CERT_PASSWORD`、`SIGNING_PROFILE`（p7b base64）。

## 5. 产物说明

| 文件 | 说明 |
|---|---|
| `TomatoTV-<tag>-openharmony-unsigned.hap` | CI 构建的未签名 HAP（OpenHarmony SDK / API 12） |
| `TomatoTV-<tag>-source.zip` | 对应 tag 的完整源码快照 |
| `build-info.json` | 构建元数据与校验和 |
