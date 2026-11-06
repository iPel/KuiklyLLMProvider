#import "KuiklyRenderViewController.h"
#import "KuiklyRenderViewControllerBaseDelegator.h"
#import "KuiklyRenderContextProtocol.h"

@interface KuiklyRenderViewController () <KuiklyRenderViewControllerBaseDelegatorDelegate>
@property (nonatomic, strong) KuiklyRenderViewControllerBaseDelegator *delegator;
@end

@implementation KuiklyRenderViewController {
    NSString *_pageName;
    NSDictionary *_pageData;
}

- (instancetype)initWithPageName:(NSString *)pageName pageData:(NSDictionary *)pageData {
    if (self = [super init]) {
        _pageName = pageName;
        _pageData = pageData ?: @{};
        _delegator = [[KuiklyRenderViewControllerBaseDelegator alloc] initWithPageName:pageName pageData:_pageData];
        _delegator.delegate = self;
    }
    return self;
}

- (instancetype)init {
    return [self initWithPageName:@"LLMChat" pageData:@{}];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // 宿主视图使用白色背景：Kuikly 页面未自绘背景时，页面文字为深色，浅色背景保证可读。
    // 加载态另见 createLoadingView（使用深色头图，避免浅色状态栏与白底叠加）。
    self.view.backgroundColor = [UIColor whiteColor];
    [_delegator viewDidLoadWithView:self.view];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [_delegator viewDidLayoutSubviews];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [_delegator viewWillAppear];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [_delegator viewDidAppear];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_delegator viewWillDisappear];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [_delegator viewDidDisappear];
}

#pragma mark - 状态栏 / 安全区

// 跨端页面是全屏绘制的，顶部用白色导航栏占满状态栏区域
// （见 shared/.../LLMChatPage.kt 的「状态栏避让」）。
// 因此状态栏内容必须是深色，否则白底白字看不见。
// Info.plist 未设 UIViewControllerBasedStatusBarAppearance，默认为 YES，
// 即由本 VC 的 preferredStatusBarStyle 决定。
- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleDarkContent;
}

#pragma mark - KuiklyRenderViewControllerBaseDelegatorDelegate

- (UIView *)createLoadingView {
    UIView *loadingView = [[UIView alloc] init];
    // 与浅色顶部导航栏同色，使加载态与首屏背景一致（对应鸿蒙 start_window_background）。
    loadingView.backgroundColor = [UIColor colorWithRed:0xF7 / 255.0
                                                  green:0xF8 / 255.0
                                                   blue:0xFA / 255.0
                                                  alpha:1.0];
    return loadingView;
}

- (UIView *)createErrorView {
    UIView *errorView = [[UIView alloc] init];
    errorView.backgroundColor = [UIColor colorWithRed:0xF7 / 255.0
                                                green:0xF8 / 255.0
                                                 blue:0xFA / 255.0
                                                alpha:1.0];
    return errorView;
}

- (void)fetchContextCodeWithPageName:(NSString *)pageName resultCallback:(KuiklyContextCodeCallback)callback {
    if (callback) {
        callback(@"shared", nil);
    }
}

- (NSDictionary<NSString *, NSObject *> *)contextPageData {
    NSMutableDictionary *pageData = [NSMutableDictionary dictionary];
    pageData[@"appId"] = @"1";
    pageData[@"sysLang"] = [[NSLocale currentLocale] languageCode] ?: @"en";
    return pageData;
}

- (void)dealloc {
}

@end
