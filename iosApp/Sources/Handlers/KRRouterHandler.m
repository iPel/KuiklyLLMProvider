#import "KRRouterHandler.h"
#import "KuiklyRenderViewController.h"

@implementation KRRouterHandler

+ (void)load {
    [KRRouterModule registerRouterHandler:[self new]];
}

- (void)openPageWithName:(NSString *)pageName pageData:(NSDictionary *)pageData controller:(UIViewController *)controller {
    KuiklyRenderViewController *vc = [[KuiklyRenderViewController alloc] initWithPageName:pageName pageData:pageData];
    [controller.navigationController pushViewController:vc animated:YES];
}

- (void)closePage:(UIViewController *)controller {
    if (controller.navigationController.viewControllers.count == 1) {
        [controller.navigationController dismissViewControllerAnimated:NO completion:nil];
    } else {
        [controller.navigationController popViewControllerAnimated:YES];
    }
}

@end
