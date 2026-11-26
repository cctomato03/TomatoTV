import { FileSource } from '../../model/FileSource';

/** 凭据解析：由 SourceStore 实现（nominal 类型，避免 ArkTS 结构化类型限制） */
export interface SecretResolver {
  passwordOf(source: FileSource): Promise<string>;
}
