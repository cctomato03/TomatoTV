import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../../utils/Logger';

/**
 * 密码等敏感数据的存储。
 *
 * 规范 §10.1 要求“HUKS + AES-GCM 加密，禁止明文落盘”。系统级安全存储 Asset Store Kit
 * 底层由 HUKS 托管密钥，密钥不出 TEE/安全环境，比“自行生成密钥再落盘”更安全，
 * 因此在首版使用 Asset Store 承载明文之外的凭据存储（偏差已记录在 docs/DEVIATIONS.md）。
 */
export class SecretStore {
  private static encoder(): util.TextEncoder {
    return new util.TextEncoder('utf-8');
  }

  private static decoder(): util.TextDecoder {
    return util.TextDecoder.create('utf-8', { ignoreBOM: true });
  }

  private static toBytes(text: string): Uint8Array {
    return SecretStore.encoder().encodeInto(text);
  }

  private static fromBytes(bytes: Uint8Array): string {
    return SecretStore.decoder().decodeWithStream(bytes);
  }

  private static aliasBytes(alias: string): Uint8Array {
    return SecretStore.toBytes(`tomato_tv:${alias}`);
  }

  static async put(alias: string, secret: string): Promise<void> {
    const attributes: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    attributes.set(asset.Tag.ALIAS, SecretStore.aliasBytes(alias));
    attributes.set(asset.Tag.SECRET, SecretStore.toBytes(secret));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    try {
      await asset.add(attributes);
    } catch (err) {
      const code: number = (err as BusinessError).code;
      if (code === asset.ErrorCode.DUPLICATED) {
        await asset.remove(SecretStore.queryMap(alias));
        await asset.add(attributes);
        return;
      }
      Logger.error('SecretStore', `保存凭据失败 code=${code}`, err as Error);
      throw err as Error;
    }
  }

  static async get(alias: string): Promise<string> {
    const query: asset.AssetMap = SecretStore.queryMap(alias);
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const results: Array<asset.AssetMap> = await asset.query(query);
      if (results.length === 0) {
        return '';
      }
      const secret: asset.Value | undefined = results[0].get(asset.Tag.SECRET);
      if (secret instanceof Uint8Array) {
        return SecretStore.fromBytes(secret);
      }
      return '';
    } catch (err) {
      Logger.error('SecretStore', '读取凭据失败', err as Error);
      return '';
    }
  }

  static async remove(alias: string): Promise<void> {
    try {
      await asset.remove(SecretStore.queryMap(alias));
    } catch (err) {
      Logger.warn('SecretStore', `删除凭据失败: ${(err as BusinessError).code}`);
    }
  }

  private static queryMap(alias: string): asset.AssetMap {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS, SecretStore.aliasBytes(alias));
    return query;
  }
}
