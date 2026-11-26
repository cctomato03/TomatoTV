/**
 * SMB / NTLM 相关纯逻辑单元测试：
 *  - 哈希与 HMAC 对照 RFC 1320 / 1321 / 2202 / 4231 测试向量
 *  - NTLMv2 对照 MS-NLMP 4.2.4 官方示例
 *  - UTF-16LE、FILETIME 转换
 */
import assert from 'node:assert/strict';
import { SmbCrypto } from '../../entry/src/main/ets/data/smb/SmbCrypto';
import { Ntlm } from '../../entry/src/main/ets/data/smb/Ntlm';

let passed = 0;
const failures: string[] = [];

function check(name: string, run: () => void): void {
  try {
    run();
    passed++;
  } catch (error) {
    failures.push(`${name} → ${(error as Error).message}`);
  }
}

function bytes(text: string): Uint8Array {
  return new Uint8Array(Array.from(text).map((ch) => ch.charCodeAt(0)));
}

function hmacKey(length: number, value: number): Uint8Array {
  const out = new Uint8Array(length);
  out.fill(value);
  return out;
}

/** 仅测试用：构造一个 NTLM Type2（CHALLENGE）报文 */
function buildType2(challenge: Uint8Array, targetInfo: Uint8Array): Uint8Array {
  const headerSize = 48;
  const targetName = SmbCrypto.utf16le('SERVER');
  const total = headerSize + targetName.length + targetInfo.length;
  const out = new Uint8Array(total);
  out.set(Ntlm.ascii('NTLMSSP\0'), 0);
  Ntlm.writeUint32(out, 8, 2);
  Ntlm.writeUint16(out, 12, targetName.length);
  Ntlm.writeUint16(out, 14, targetName.length);
  Ntlm.writeUint32(out, 16, headerSize);
  Ntlm.writeUint32(out, 20, 0xe28a8235);
  out.set(challenge, 24);
  Ntlm.writeUint16(out, 40, targetInfo.length);
  Ntlm.writeUint16(out, 42, targetInfo.length);
  Ntlm.writeUint32(out, 44, headerSize + targetName.length);
  out.set(targetName, headerSize);
  out.set(targetInfo, headerSize + targetName.length);
  return out;
}

/** 仅测试用：微软文档示例里的 TargetInfo（Domain + Server） */
function sampleTargetInfo(): Uint8Array {
  return Ntlm.mavPairs([
    { id: Ntlm.AV_ID_NB_DOMAIN, value: SmbCrypto.utf16le('Domain') },
    { id: Ntlm.AV_ID_NB_COMPUTER, value: SmbCrypto.utf16le('Server') }
  ]);
}

// ---------------- 哈希 ----------------
check('MD4 测试向量（RFC 1320）', () => {
  assert.equal(SmbCrypto.toHex(SmbCrypto.md4(bytes(''))), '31d6cfe0d16ae931b73c59d7e0c089c0');
  assert.equal(SmbCrypto.toHex(SmbCrypto.md4(bytes('abc'))), 'a448017aaf21d8525fc10ae87aa6729d');
  assert.equal(SmbCrypto.toHex(SmbCrypto.md4(bytes('message digest'))), 'd9130a8164549fe818874806e1c7014b');
  assert.equal(SmbCrypto.toHex(SmbCrypto.md4(SmbCrypto.utf16le('Password'))), 'a4f49c406510bdcab6824ee7c30fd852');
});

check('MD5 测试向量（RFC 1321）', () => {
  assert.equal(SmbCrypto.toHex(SmbCrypto.md5(bytes(''))), 'd41d8cd98f00b204e9800998ecf8427e');
  assert.equal(SmbCrypto.toHex(SmbCrypto.md5(bytes('abc'))), '900150983cd24fb0d6963f7d28e17f72');
  assert.equal(SmbCrypto.toHex(SmbCrypto.md5(bytes('message digest'))), 'f96b697d7cb7938d525a2f31aaf161d0');
});

check('SHA-256 测试向量（RFC 6234）', () => {
  assert.equal(SmbCrypto.toHex(SmbCrypto.sha256(bytes(''))),
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
  assert.equal(SmbCrypto.toHex(SmbCrypto.sha256(bytes('abc'))),
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
});

check('HMAC-MD5（RFC 2202 case 1）', () => {
  const mac = SmbCrypto.hmacMd5(hmacKey(16, 0x0b), bytes('Hi There'));
  assert.equal(SmbCrypto.toHex(mac), '9294727a3638bb1c13f48ef8158bfc9d');
});

check('HMAC-SHA256（RFC 4231 case 1）', () => {
  const mac = SmbCrypto.hmacSha256(hmacKey(20, 0x0b), bytes('Hi There'));
  assert.equal(SmbCrypto.toHex(mac), 'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7');
});

check('UTF-16LE 编解码往返', () => {
  const text = '中文abc';
  const encoded = SmbCrypto.utf16le(text);
  assert.equal(encoded.length, text.length * 2);
  assert.equal(SmbCrypto.fromUtf16le(encoded, 0, encoded.length), text);
});

// ---------------- NTLMv2 ----------------
check('NTLMv2 对照 MS-NLMP 4.2.4 示例', () => {
  // 官方示例：User=User, Domain=Domain, Password=Password
  // ServerChallenge=0123456789abcdef, ClientChallenge=aaaaaaaaaaaaaaaa, Time=0
  const serverChallenge = new Uint8Array([0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef]);
  const clientChallenge = new Uint8Array(8);
  clientChallenge.fill(0xaa);
  const targetInfo = sampleTargetInfo();
  const result = Ntlm.computeV2({
    user: 'User',
    domain: 'Domain',
    password: 'Password',
    serverChallenge: serverChallenge,
    clientChallenge: clientChallenge,
    fileTime: 0,
    targetInfo: targetInfo
  });
  assert.equal(SmbCrypto.toHex(result.ntProofStr), '68cd0ab851e51c96aabc927bebef6a1c');
  assert.equal(SmbCrypto.toHex(result.sessionBaseKey), '8de40ccadbc14a82f15cb0ad0de95ca3');
});

check('NTLMv2 相同输入可复现', () => {
  const serverChallenge = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]);
  const clientChallenge = new Uint8Array([9, 9, 9, 9, 9, 9, 9, 9]);
  const targetInfo = Ntlm.mavPairs([]);
  const first = Ntlm.computeV2({
    user: 'alice', domain: 'WORKGROUP', password: 'secret',
    serverChallenge: serverChallenge, clientChallenge: clientChallenge, fileTime: 132000000000000000,
    targetInfo: targetInfo
  });
  const second = Ntlm.computeV2({
    user: 'alice', domain: 'WORKGROUP', password: 'secret',
    serverChallenge: serverChallenge, clientChallenge: clientChallenge, fileTime: 132000000000000000,
    targetInfo: targetInfo
  });
  assert.equal(SmbCrypto.toHex(first.ntProofStr), SmbCrypto.toHex(second.ntProofStr));
  assert.equal(first.ntProofStr.length, 16);
  assert.ok(first.ntResponse.length > 16);
});

check('NTLM Type1/Type3 报文结构', () => {
  const type1 = Ntlm.buildType1();
  assert.equal(Ntlm.asciiText(type1, 0, 8), 'NTLMSSP\0');
  assert.equal(Ntlm.readUint32(type1, 8), 1);
  const type3 = Ntlm.buildType3(
    { user: 'alice', domain: 'WG', password: 'secret' },
    new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]),
    new Uint8Array([9, 9, 9, 9, 9, 9, 9, 9]),
    132000000000000000,
    Ntlm.mavPairs([])
  );
  assert.equal(Ntlm.asciiText(type3, 0, 8), 'NTLMSSP\0');
  assert.equal(Ntlm.readUint32(type3, 8), 3);
  // DomainName / UserName 字段应能在报文内被正确解析
  const domainLen = Ntlm.readUint16(type3, 28);
  const domainOffset = Ntlm.readUint32(type3, 32);
  assert.equal(SmbCrypto.fromUtf16le(type3, domainOffset, domainLen), 'WG');
  const userLen = Ntlm.readUint16(type3, 36);
  const userOffset = Ntlm.readUint32(type3, 40);
  assert.equal(SmbCrypto.fromUtf16le(type3, userOffset, userLen), 'alice');
});

check('SPNEGO 包装与解包', () => {
  const type1 = Ntlm.buildType1();
  const wrapped = Ntlm.wrapSpnegoInit(type1);
  assert.equal(wrapped[0], 0x60);
  const extracted = Ntlm.extractNtlmMessage(wrapped);
  assert.equal(SmbCrypto.toHex(extracted), SmbCrypto.toHex(type1));

  const type2 = buildType2(new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]), Ntlm.mavPairs([]));
  const wrapped2 = Ntlm.wrapSpnegoResp(type2);
  assert.equal(wrapped2[0], 0xa1);
  const extracted2 = Ntlm.extractNtlmMessage(wrapped2);
  assert.equal(SmbCrypto.toHex(extracted2), SmbCrypto.toHex(type2));
});

check('解析 Type2 challenge', () => {
  const challenge = new Uint8Array([0xde, 0xad, 0xbe, 0xef, 0x01, 0x02, 0x03, 0x04]);
  const targetInfo = Ntlm.mavPairs([]);
  const type2 = buildType2(challenge, targetInfo);
  const parsed = Ntlm.parseType2(type2);
  assert.equal(SmbCrypto.toHex(parsed.serverChallenge), SmbCrypto.toHex(challenge));
  assert.ok(parsed.targetInfo.length >= 4);
});

check('FILETIME 与 Unix 毫秒互转', () => {
  const unixMs = 1704164645000; // 2024-01-02T03:04:05Z
  const fileTime = Ntlm.unixMsToFileTime(unixMs);
  assert.equal(Ntlm.fileTimeToUnixMs(fileTime), unixMs);
  assert.equal(Ntlm.unixMsToFileTime(0), 116444736000000000);
});

// ---------------- 汇总 ----------------
if (failures.length > 0) {
  console.error(`\n❌ ${failures.length} 项失败 / ${passed} 项通过`);
  for (const failure of failures) {
    console.error(`   - ${failure}`);
  }
  throw new Error('SMB 单元测试未通过');
}
console.log(`✅ SMB/NTLM 单元测试全部通过：${passed} 项`);
