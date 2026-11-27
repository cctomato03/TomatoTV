import { webview } from '@kit.ArkWeb';
import { Logger } from '../utils/Logger';

/** 文档预览的虚拟同源地址：由 onInterceptRequest 提供文件字节，不产生任何真实网络请求 */
const DOC_ORIGIN: string = 'https://tomato.doc.local';

/**
 * PDF / Office 离线预览容器。
 *
 * 安全策略（规范 §7.8、§10.7）：
 *  - 页面与渲染库全部来自应用内 rawfile，不使用 CDN；
 *  - 不注册 javaScriptProxy（无 JSBridge 暴露）；
 *  - 拦截所有 http(s) 请求：只放行 `tomato.doc.local` 的文档字节，其余一律 403；
 *  - domStorage / fileAccess / onlineImageAccess 全部关闭。
 */
@Component
export struct DocumentWebView {
  src: Resource = $rawfile('viewer/pdf/index.html');
  docBytes: ArrayBuffer = new ArrayBuffer(0);
  workerBytes: ArrayBuffer = new ArrayBuffer(0);
  docMime: string = 'application/octet-stream';
  onFail: () => void = () => {
  };
  onPageEnd: () => void = () => {
  };

  private controller: webview.WebviewController = new webview.WebviewController();

  private static okResponse(data: ArrayBuffer, mime: string): WebResourceResponse {
    const response: WebResourceResponse = new WebResourceResponse();
    response.setResponseCode(200);
    response.setReasonMessage('OK');
    response.setResponseMimeType(mime);
    response.setResponseEncoding('utf-8');
    response.setResponseHeader([
      { headerKey: 'Access-Control-Allow-Origin', headerValue: '*' },
      { headerKey: 'Cache-Control', headerValue: 'no-store' }
    ]);
    response.setResponseData(data);
    return response;
  }

  private static blockedResponse(code: number): WebResourceResponse {
    const response: WebResourceResponse = new WebResourceResponse();
    response.setResponseCode(code);
    response.setReasonMessage('Blocked');
    response.setResponseMimeType('text/plain');
    response.setResponseEncoding('utf-8');
    response.setResponseData('');
    return response;
  }

  private intercept(url: string): WebResourceResponse {
    if (url.startsWith(`${DOC_ORIGIN}/doc`)) {
      return DocumentWebView.okResponse(this.docBytes, this.docMime);
    }
    if (url.startsWith(`${DOC_ORIGIN}/worker`)) {
      return DocumentWebView.okResponse(this.workerBytes, 'text/javascript');
    }
    if (url.startsWith('http://') || url.startsWith('https://')) {
      Logger.warn('DocumentWebView', '已阻断外部请求');
      return DocumentWebView.blockedResponse(403);
    }
    const pass: WebResourceResponse = new WebResourceResponse();
    pass.setResponseIsReady(false);
    return pass;
  }

  build() {
    Web({ src: this.src, controller: this.controller })
      .javaScriptAccess(true)
      .domStorageAccess(false)
      .fileAccess(false)
      .onlineImageAccess(false)
      .mixedMode(MixedMode.None)
      .zoomAccess(true)
      .verticalScrollBarAccess(true)
      .horizontalScrollBarAccess(true)
      .width('100%')
      .height('100%')
      .onPageEnd(() => {
        this.onPageEnd();
      })
      .onInterceptRequest((event) => {
        if (event === undefined) {
          return DocumentWebView.blockedResponse(404);
        }
        return this.intercept(event.request.getRequestUrl());
      })
  }
}
