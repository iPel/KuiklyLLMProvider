import { KRNativeRenderController, KRRecord, Kuikly } from '@kuikly-open/render';
import globalNativeManager from '../kuikly/MyNativeManager';
import { KuiklyViewDelegate } from '../kuikly/KuiklyViewDelegate';
import router from '@ohos.router';

// 路由参数白名单。Kuikly 端只注册了 LLMChat（@Page("LLMChat")），
// 其它 pageName 一律回退默认页，pageData 只接受普通对象，避免外部经 router 参数
// 加载非预期页面或注入畸形数据到渲染层。
const DEFAULT_PAGE: string = 'LLMChat';
const ALLOWED_PAGES: string[] = ['LLMChat'];
const KEY_PAGE_NAME: string = 'pageName';
const KEY_PAGE_DATA: string = 'pageData';

@Entry
@Component
struct Index {
  private kuiklyViewDelegate = new KuiklyViewDelegate();
  private kuiklyController: KRNativeRenderController | null = null;
  private pageName: string = DEFAULT_PAGE;
  private pageData: KRRecord = {};
  @State showKuikly: boolean = true;

  onBackPress(): boolean | void {
    if (this.kuiklyController) {
      return this.kuiklyController.onBackPress();
    }
  }

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object> | null;
    if (params === null || typeof params !== 'object') return;
    const name = params[KEY_PAGE_NAME];
    if (typeof name === 'string' && ALLOWED_PAGES.indexOf(name as string) >= 0) {
      this.pageName = name as string;
    }
    const data = params[KEY_PAGE_DATA];
    if (data !== null && typeof data === 'object' && !Array.isArray(data)) {
      this.pageData = data as KRRecord;
    }
  }

  onPageShow(): void {
    this.kuiklyViewDelegate.pageDidAppear();
  }

  onPageHide(): void {
    this.kuiklyViewDelegate.pageDidDisappear();
  }

  build() {
    Stack() {
      if (this.showKuikly) {
        Kuikly({
          pageName: this.pageName,
          pageData: this.pageData,
          delegate: this.kuiklyViewDelegate,
          onControllerReadyCallback: (controller) => {
            this.kuiklyController = controller;
          },
          nativeManager: globalNativeManager,
        });
      }
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.KEYBOARD]);
  }
}
