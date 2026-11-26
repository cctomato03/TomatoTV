import { promptAction } from '@kit.ArkUI';
import { fileShare, picker as pickerView } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { AppContainer } from '../../app/AppContainer';
import { FileSource, SourceFactory, SourceType } from '../../model/FileSource';
import { FsError, FsErrorKind, FsErrorText } from '../../data/fs/FileSystemClient';
import { BusKeys, EventBus } from '../../utils/EventBus';
import { NavDefaults, SourceEditParam } from '../../navigation/AppNav';
import { Symbols } from '../../components/Symbols';
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

  private container: AppContainer = AppContainer.get();

  aboutToAppear(): void {
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
      const message: string = err instanceof FsError ? FsErrorText.of(err.kind) : FsErrorText.NETWORK;
      promptAction.showToast({ message: err instanceof FsError && err.kind === FsErrorKind.UNSUPPORTED ?
        err.message : message });
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
            Row() {
              Text('使用 FTPS（显式 TLS）')
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.secure })
                .selectedColor($r('app.color.brand'))
                .onChange((isOn: boolean) => {
                  this.secure = isOn;
                })
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

          if (this.type === SourceType.SMB) {
            Text('当前版本暂不支持 SMB：需要 libsmb2 的 NAPI 封装，将在后续版本提供')
              .fontSize(12)
              .fontColor($r('app.color.brand'))
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
