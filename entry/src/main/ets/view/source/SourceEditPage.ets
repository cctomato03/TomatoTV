import { promptAction } from '@kit.ArkUI';
import { fileShare, picker as pickerView } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { AppContainer } from '../../app/AppContainer';
import { FileSource, SourceFactory, SourceType } from '../../model/FileSource';
import { FsError, FsErrorKind, FsErrorText } from '../../data/fs/FileSystemClient';
import { BusKeys, EventBus } from '../../utils/EventBus';
import { NavDefaults, SourceEditParam } from '../../navigation/AppNav';
import { Symbols } from '../../components/Symbols';
import { QrView } from '../../components/QrView';
import { PairingForm, PairingServer, PairingSession } from '../../utils/PairingServer';
import { QrCode } from '../../utils/QrCode';
import { Logger } from '../../utils/Logger';

interface FormErrors {
  name: string;
  address: string;
  local: string;
  host: string;
}

/** 添加/编辑存储（规范 §7.4） */
@Component
export struct SourceEditPage {
  stack: NavPathStack = new NavPathStack();
  param: SourceEditParam = NavDefaults.sourceEdit();

  @State type: SourceType = SourceType.LOCAL;
  @State name: string = '';
  @State url: string = '';
  @State host: string = '';
  @State portText: string = '';
  @State share: string = '';
  @State rootPath: string = '';
  @State domain: string = '';
  @State username: string = '';
  @State password: string = '';
  @State localUri: string = '';
  @State secure: boolean = false;
  @State errors: FormErrors = { name: '', address: '', local: '', host: '' };
  @State testing: boolean = false;
  @State saving: boolean = false;
  @State isTvLayout: boolean = false;
  @State pairingVisible: boolean = false;
  @State pairingUrl: string = '';
  @State pairingError: string = '';
  @State qrMatrix: boolean[][] = [];

  private container: AppContainer = AppContainer.get();
  private pairingServer: PairingServer | null = null;

  private openPairing(): void {
    this.pairingError = '';
    this.qrMatrix = [];
    this.pairingVisible = true;
    const server: PairingServer = new PairingServer((form: PairingForm) => {
      this.applyPairingForm(form);
    }, () => {
      promptAction.showToast({ message: '已收到手机提交，请核对后保存' });
    });
    this.pairingServer = server;
    server.start().then((session: PairingSession) => {
      this.pairingUrl = session.url;
      this.qrMatrix = QrCode.encode(session.url) ?? [];
      if (this.qrMatrix.length === 0) {
        this.pairingError = '地址过长，无法生成二维码，请手动输入下面的地址';
      }
    }).catch((err: Error) => {
      Logger.error('SourceEditPage', '启动局域网服务失败', err);
      this.pairingError = '无法启动局域网服务，请检查网络后重试';
    });
  }

  private stopPairing(): void {
    const server: PairingServer | null = this.pairingServer;
    this.pairingServer = null;
    this.pairingUrl = '';
    this.qrMatrix = [];
    if (server !== null) {
      server.stop();
    }
  }

  private applyPairingForm(form: PairingForm): void {
    this.type = SourceEditPage.parseType(form.type);
    this.name = form.name;
    this.url = form.url;
    this.host = form.host;
    this.portText = form.port.length > 0 ? form.port : `${SourceFactory.defaultPort(this.type)}`;
    this.share = form.share;
    this.rootPath = form.rootPath;
    this.domain = form.domain;
    this.username = form.username;
    this.password = form.password;
    this.secure = form.secure === 'true';
    if (form.localPath.length > 0 && form.localPath.startsWith('file://')) {
      this.localUri = form.localPath;
    }
    this.errors = { name: '', address: '', local: '', host: '' };
  }

  private static parseType(value: string): SourceType {
    const upper: string = value.toUpperCase();
    if (upper === 'WEBDAV') {
      return SourceType.WEBDAV;
    }
    if (upper === 'SMB') {
      return SourceType.SMB;
    }
    if (upper === 'FTP') {
      return SourceType.FTP;
    }
    return SourceType.LOCAL;
  }

  aboutToAppear(): void {
    try {
      this.isTvLayout = this.container.settings().forceTvLayout;
    } catch (err) {
      this.isTvLayout = false;
    }
    if (this.param.isNew) {
      this.type = this.param.initialType;
      this.portText = `${SourceFactory.defaultPort(this.type)}`;
      this.secure = false;
      return;
    }
    const existing: FileSource | null = this.container.findSource(this.param.sourceId);
    if (existing === null) {
      promptAction.showToast({ message: '来源不存在' });
      return;
    }
    this.type = existing.type;
    this.name = existing.name;
    this.url = existing.url;
    this.host = existing.host;
    this.portText = existing.port > 0 ? `${existing.port}` : '';
    this.share = existing.share;
    this.rootPath = existing.rootPath;
    this.domain = existing.domain;
    this.username = existing.username;
    this.localUri = existing.localUri;
    this.secure = existing.secure;
    this.container.sourceStore.passwordOf(existing).then((value: string) => {
      this.password = value;
    });
  }

  private portValue(): number {
    const parsed: number = Number(this.portText);
    if (!Number.isFinite(parsed) || parsed <= 0) {
      return SourceFactory.defaultPort(this.type);
    }
    return Math.floor(parsed);
  }

  private validate(): boolean {
    const errors: FormErrors = { name: '', address: '', local: '', host: '' };
    if (this.name.trim().length === 0) {
      errors.name = '请填写名称';
    }
    if (this.type === SourceType.WEBDAV) {
      const lower: string = this.url.trim().toLowerCase();
      if (lower.length === 0) {
        errors.address = '请填写 WebDAV 地址';
      } else if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
        errors.address = '地址必须以 http:// 或 https:// 开头';
      }
    }
    if (this.type === SourceType.SMB || this.type === SourceType.FTP) {
      if (this.host.trim().length === 0) {
        errors.host = '请填写服务器地址';
      }
    }
    if (this.type === SourceType.LOCAL && this.localUri.trim().length === 0) {
      errors.local = '请选择目录';
    }
    this.errors = errors;
    return errors.name.length === 0 && errors.address.length === 0 && errors.host.length === 0 &&
      errors.local.length === 0;
  }

  private buildSource(): FileSource {
    const source: FileSource = SourceFactory.blank(this.type);
    source.id = this.param.isNew ? SourceFactory.newId() : this.param.sourceId;
    source.name = this.name.trim();
    source.url = this.url.trim();
    source.host = this.host.trim();
    source.port = this.portValue();
    source.share = this.share.trim();
    source.rootPath = this.rootPath.trim();
    source.domain = this.domain.trim();
    source.username = this.username;
    source.password = this.password;
    source.localUri = this.localUri;
    source.secure = this.secure;
    return source;
  }

  private async chooseDirectory(): Promise<void> {
    const context: common.UIAbilityContext = this.container.requireContext();
    try {
      const documentPicker: pickerView.DocumentViewPicker = new pickerView.DocumentViewPicker(context);
      const options: pickerView.DocumentSelectOptions = new pickerView.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.selectMode = pickerView.DocumentSelectMode.FOLDER;
      const uris: string[] = await documentPicker.select(options);
      if (uris.length === 0) {
        return;
      }
      const uri: string = uris[0];
      this.localUri = uri;
      this.errors = { name: this.errors.name, address: this.errors.address, local: '', host: this.errors.host };
      const policy: fileShare.PolicyInfo = { uri: uri, operationMode: fileShare.OperationMode.READ_MODE };
      try {
        await fileShare.persistPermission([policy]);
      } catch (err) {
        Logger.warn('SourceEditPage', '持久化目录授权失败，重启后可能需要重新选择');
      }
    } catch (err) {
      Logger.error('SourceEditPage', '选择目录失败', err as Error);
      promptAction.showToast({ message: '没有选择目录' });
    }
  }

  private async testConnection(): Promise<void> {
    if (!this.validate()) {
      return;
    }
    this.testing = true;
    const source: FileSource = this.buildSource();
    try {
      await this.container.repository!.test(source);
      promptAction.showToast({ message: '连接成功' });
    } catch (err) {
      const kind: FsErrorKind | null = err instanceof FsError ? (err as FsError).kind : null;
      let message: string = FsErrorText.NETWORK;
      if (kind !== null) {
        message = kind === FsErrorKind.UNSUPPORTED || kind === FsErrorKind.SERVER
          ? (err as FsError).message : FsErrorText.of(kind);
      }
      promptAction.showToast({ message: message });
      Logger.warn('SourceEditPage', `测试连接失败: ${message}`);
    } finally {
      this.testing = false;
      await this.container.repository!.invalidate(source.id);
    }
  }

  private async save(): Promise<void> {
    if (!this.validate()) {
      return;
    }
    this.saving = true;
    const source: FileSource = this.buildSource();
    try {
      const stored: FileSource = await this.container.sourceStore.save(source);
      await this.container.invalidateSource(stored.id);
      EventBus.emit(BusKeys.SOURCES_CHANGED);
      promptAction.showToast({ message: '已保存' });
      this.stack.pop();
    } catch (err) {
      Logger.error('SourceEditPage', '保存来源失败', err as Error);
      promptAction.showToast({ message: '保存失败，请稍后重试' });
    } finally {
      this.saving = false;
    }
  }

  private confirmDelete(): void {
    AlertDialog.show({
      title: '删除存储',
      message: '确定删除该存储配置？',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.brand'),
        action: () => {
          this.container.sourceStore.remove(this.param.sourceId).then(() => {
            this.container.invalidateSource(this.param.sourceId).then(() => {
              EventBus.emit(BusKeys.SOURCES_CHANGED);
              this.stack.pop();
            });
          });
        }
      }
    });
  }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: 16 }) {
          Text(this.param.isNew ? '添加存储' : '编辑存储')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .width('100%')

          Column({ space: 8 }) {
            Text('类型')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            Row({ space: 8 }) {
              ForEach(SourceEditPage.allTypes(), (item: SourceType) => {
                Text(SourceFactory.typeLabel(item))
                  .fontSize(14)
                  .fontColor(this.type === item ? Color.White : $r('app.color.text_primary'))
                  .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                  .backgroundColor(this.type === item ? $r('app.color.brand') : $r('app.color.surface_card'))
                  .borderRadius(16)
                  .focusable(true)
                  .onClick(() => {
                    this.type = item;
                    if (this.portText.length === 0 || Number(this.portText) === 0) {
                      this.portText = `${SourceFactory.defaultPort(item)}`;
                    }
                  })
              }, (item: SourceType) => item)
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)

          this.field('名称', '例如：家里的 NAS', this.name, (value: string) => {
            this.name = value;
          }, this.errors.name, false)

          if (this.type === SourceType.WEBDAV) {
            this.field('服务器地址', 'https://example.com/dav', this.url, (value: string) => {
              this.url = value;
            }, this.errors.address, false)
          }

          if (this.type === SourceType.SMB || this.type === SourceType.FTP) {
            this.field('服务器地址', '主机名或 IP', this.host, (value: string) => {
              this.host = value;
            }, this.errors.host, false)
            this.field('端口', `${SourceFactory.defaultPort(this.type)}`, this.portText, (value: string) => {
              this.portText = value;
            }, '', true)
          }

          if (this.type === SourceType.SMB) {
            this.field('共享名', 'share', this.share, (value: string) => {
              this.share = value;
            }, '', false)
            this.field('根路径', '可留空', this.rootPath, (value: string) => {
              this.rootPath = value;
            }, '', false)
            this.field('域', '可留空', this.domain, (value: string) => {
              this.domain = value;
            }, '', false)
          }

          if (this.type === SourceType.FTP) {
            this.field('根路径', '可留空', this.rootPath, (value: string) => {
              this.rootPath = value;
            }, '', false)
            Column({ space: 4 }) {
              Row() {
                Text('使用 FTPS（隐式 TLS）')
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.secure })
                  .selectedColor($r('app.color.brand'))
                  .onChange((isOn: boolean) => {
                    this.secure = isOn;
                    const current: number = Number(this.portText);
                    if (isOn && (current === 21 || this.portText.length === 0)) {
                      this.portText = '990';
                    } else if (!isOn && current === 990) {
                      this.portText = '21';
                    }
                  })
              }
              .width('100%')
              Text('隐式 FTPS 直接以 TLS 建连（默认端口 990）。若服务器只支持显式 FTPS（AUTH TLS / 21 端口），当前版本会提示暂不支持。')
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
            }
            .width('100%')
          }

          if (this.type === SourceType.LOCAL) {
            Column({ space: 8 }) {
              Button('选择目录')
                .type(ButtonType.Capsule)
                .height(44)
                .width('100%')
                .backgroundColor($r('app.color.brand_soft'))
                .fontColor($r('app.color.brand'))
                .focusable(true)
                .onClick(() => {
                  this.chooseDirectory();
                })
              Text(this.localUri.length > 0 ? SourceFactory.displayAddress(this.buildSource()) : '尚未选择目录')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .maxLines(2)
                .width('100%')
              if (this.errors.local.length > 0) {
                Text(this.errors.local)
                  .fontSize(12)
                  .fontColor($r('app.color.brand'))
                  .width('100%')
              }
            }
            .width('100%')
          }

          if (this.type !== SourceType.LOCAL) {
            this.field('用户名', '可留空', this.username, (value: string) => {
              this.username = value;
            }, '', false)
            this.field('密码', '可留空', this.password, (value: string) => {
              this.password = value;
            }, '', true)
          }

          if (this.isTvLayout && this.param.isNew) {
            Button('手机扫码填写参数')
              .type(ButtonType.Capsule)
              .height(44)
              .width('100%')
              .backgroundColor($r('app.color.brand_soft'))
              .fontColor($r('app.color.brand'))
              .focusable(true)
              .onClick(() => this.openPairing())
            Text('在智慧屏上打开二维码，用手机浏览器填写后自动回显到本页；关闭二维码后链接立即失效。')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          }

          Row({ space: 12 }) {
            Button(this.testing ? '测试中…' : '测试连接')
              .type(ButtonType.Capsule)
              .height(44)
              .layoutWeight(1)
              .backgroundColor($r('app.color.surface_card'))
              .fontColor($r('app.color.text_primary'))
              .enabled(!this.testing)
              .focusable(true)
              .onClick(() => {
                this.testConnection();
              })
            Button(this.saving ? '保存中…' : '保存')
              .type(ButtonType.Capsule)
              .height(44)
              .layoutWeight(1)
              .backgroundColor($r('app.color.brand'))
              .fontColor(Color.White)
              .enabled(!this.saving)
              .focusable(true)
              .onClick(() => {
                this.save();
              })
          }
          .width('100%')

          if (!this.param.isNew) {
            Button('删除此存储')
              .type(ButtonType.Capsule)
              .height(44)
              .width('100%')
              .backgroundColor($r('app.color.surface_card'))
              .fontColor($r('app.color.brand'))
              .focusable(true)
              .onClick(() => this.confirmDelete())
          }
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
    }
    .title('存储')
    .backgroundColor($r('app.color.surface'))
    .bindSheet($$this.pairingVisible, this.pairingSheet(), {
      height: 480,
      dragBar: true,
      backgroundColor: $r('app.color.surface'),
      onDisappear: () => {
        this.stopPairing();
      }
    })
  }

  aboutToDisappear(): void {
    this.stopPairing();
  }

  @Builder
  pairingSheet() {
    Column({ space: 12 }) {
      Text('手机扫码填写')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      if (this.qrMatrix.length > 0) {
        QrView({ matrix: this.qrMatrix, edge: 220 })
      } else if (this.pairingError.length > 0) {
        Text(this.pairingError)
          .fontSize(13)
          .fontColor($r('app.color.brand'))
          .width('100%')
      } else {
        LoadingProgress()
          .width(36)
          .height(36)
          .color($r('app.color.brand'))
      }

      if (this.pairingUrl.length > 0) {
        Text(this.pairingUrl)
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .copyOption(CopyOptions.LocalDevice)
          .textAlign(TextAlign.Center)
          .width('100%')
      }

      Text('手机与智慧屏需在同一局域网；提交后本链接立即失效，关闭此窗口会停止服务。')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .width('100%')

      Button('关闭')
        .type(ButtonType.Capsule)
        .height(40)
        .width('100%')
        .backgroundColor($r('app.color.surface_card'))
        .fontColor($r('app.color.text_primary'))
        .focusable(true)
        .onClick(() => {
          this.pairingVisible = false;
          this.stopPairing();
        })
    }
    .width('100%')
    .padding(20)
    .alignItems(HorizontalAlign.Center)
  }

  private static allTypes(): SourceType[] {
    return [SourceType.LOCAL, SourceType.WEBDAV, SourceType.SMB, SourceType.FTP];
  }

  @Builder
  field(label: string, placeholder: string, value: string, onChange: (value: string) => void, error: string,
    secret: boolean) {
    Column({ space: 6 }) {
      Text(label)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      TextInput({ text: value, placeholder: placeholder })
        .type(secret ? InputType.Password : InputType.Normal)
        .showPasswordIcon(secret)
        .height(44)
        .borderRadius($r('app.float.radius_small'))
        .backgroundColor($r('app.color.surface_card'))
        .focusable(true)
        .onChange((text: string) => onChange(text))
      if (error.length > 0) {
        Text(error)
          .fontSize(12)
          .fontColor($r('app.color.brand'))
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
