import { connection } from '@kit.NetworkKit';
import { Logger } from './Logger';

/** 获取本机局域网 IPv4，供智慧屏扫码填写服务使用（规范 §7.5） */
export class LanAddress {
  static async firstIpv4(): Promise<string> {
    try {
      const netHandle: connection.NetHandle = await connection.getDefaultNet();
      const properties: connection.ConnectionProperties = await connection.getConnectionProperties(netHandle);
      for (const link of properties.linkAddresses) {
        const address: connection.NetAddress = link.address;
        if (address.family === 1 && LanAddress.isPrivateIpv4(address.address)) {
          return address.address;
        }
      }
      for (const link of properties.linkAddresses) {
        if (link.address.family === 1) {
          return link.address.address;
        }
      }
    } catch (err) {
      Logger.warn('LanAddress', '获取局域网地址失败');
    }
    return '127.0.0.1';
  }

  private static isPrivateIpv4(value: string): boolean {
    if (value.startsWith('192.168.')) {
      return true;
    }
    if (value.startsWith('10.')) {
      return true;
    }
    if (value.startsWith('172.')) {
      const parts: string[] = value.split('.');
      if (parts.length > 1) {
        const second: number = Number(parts[1]);
        return second >= 16 && second <= 31;
      }
    }
    return false;
  }
}
