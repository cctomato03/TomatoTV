import { PreviewKind } from '../model/FileKinds';
import { SourceType } from '../model/FileSource';

/** 路由名 */
export class Routes {
  static readonly HOME: string = 'home';
  static readonly BROWSE: string = 'browse';
  static readonly SOURCE_EDIT: string = 'sourceEdit';
  static readonly SETTINGS: string = 'settings';
  static readonly CACHE: string = 'cache';
  static readonly TEXT_PREVIEW: string = 'textPreview';
  static readonly DOC_PREVIEW: string = 'docPreview';
  static readonly IMAGE_VIEWER: string = 'imageViewer';
  static readonly VIDEO: string = 'video';
  static readonly AUDIO: string = 'audio';
  static readonly FILE_INFO: string = 'fileInfo';
}

export interface BrowseParam {
  sourceId: string;
  path: string;
  title: string;
}

export interface SourceEditParam {
  sourceId: string;
  initialType: SourceType;
  isNew: boolean;
}

export interface MediaParam {
  sourceId: string;
  path: string;
  name: string;
  kind: PreviewKind;
  size: number;
}

export interface DocParam {
  sourceId: string;
  path: string;
  name: string;
  kind: PreviewKind;
  size: number;
}

/** 页面参数的默认值（ArkUI 自定义组件要求成员必须有初值） */
export class NavDefaults {
  static browse(): BrowseParam {
    return { sourceId: '', path: '', title: '' };
  }

  static sourceEdit(): SourceEditParam {
    return { sourceId: '', initialType: SourceType.LOCAL, isNew: true };
  }

  static media(): MediaParam {
    return { sourceId: '', path: '', name: '', kind: PreviewKind.OTHER, size: 0 };
  }

  static doc(): DocParam {
    return { sourceId: '', path: '', name: '', kind: PreviewKind.OTHER, size: 0 };
  }
}
