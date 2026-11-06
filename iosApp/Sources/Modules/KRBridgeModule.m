#import "KRBridgeModule.h"
#import "KuiklyRenderViewController.h"
#import "KuiklyContextParam.h"
#import "KuiklyRenderView.h"
#import <SDWebImage/SDWebImageManager.h>
#import <SDWebImage/SDWebImageDownloader.h>
#import <SDWebImage/SDImageCache.h>

@implementation KRBridgeModule

@synthesize hr_rootView;

#pragma mark - Page Navigation

- (void)closePage:(NSDictionary *)args {
    UIViewController *vc = [self viewController];
    [vc.navigationController popViewControllerAnimated:YES];
}

- (void)openPage:(NSDictionary *)args {
    NSDictionary *params = [self parseParams:args];
    NSString *pageName = params[@"pageName"] ?: params[@"url"];
    NSMutableDictionary *pageData = [params[@"pageData"] mutableCopy] ?: [NSMutableDictionary new];
    KuiklyRenderViewController *vc = [[KuiklyRenderViewController alloc] initWithPageName:pageName pageData:pageData];
    [[self viewController].navigationController pushViewController:vc animated:YES];
}

#pragma mark - Clipboard

- (void)copyToPasteboard:(NSDictionary *)args {
    NSDictionary *params = [self parseParams:args];
    NSString *content = params[@"content"];
    [UIPasteboard generalPasteboard].string = content;
}

#pragma mark - Logging

- (void)log:(NSDictionary *)args {
    NSDictionary *params = [self parseParams:args];
    NSString *content = params[@"content"];
#ifdef DEBUG
    NSLog(@"KuiklyRender: %@", content);
#else
    // 发布版本不输出页面日志明文（可能含凭据或隐私），仅保留事件占位。
    (void)content;
    NSLog(@"KuiklyRender: <redacted>");
#endif
}

#pragma mark - Image Cache

- (void)getLocalImagePath:(NSDictionary *)args {
    NSDictionary *params = [self parseParams:args];
    NSString *urlStr = params[@"imageUrl"];
    NSURL *url = [NSURL URLWithString:urlStr];

    [[SDWebImageDownloader sharedDownloader] downloadImageWithURL:url
                                                          options:0
                                                         progress:nil
                                                        completed:^(UIImage * _Nullable image, NSData * _Nullable data, NSError * _Nullable error, BOOL finished) {
        if (image) {
            NSString *key = [[SDWebImageManager sharedManager] cacheKeyForURL:url];
            [[SDImageCache sharedImageCache] storeImage:image imageData:data forKey:key toDisk:YES completion:^{
                NSString *path = [[SDImageCache sharedImageCache] cachePathForKey:key];
                KuiklyRenderCallback callback = args[KR_CALLBACK_KEY];
                if (callback) {
                    callback(@{@"localPath": path ?: @""});
                }
            }];
        }
    }];
}

#pragma mark - Asset File

- (void)readAssetFile:(NSDictionary *)args {
    NSDictionary *params = [self parseParams:args];
    KuiklyRenderCallback callback = args[KR_CALLBACK_KEY];
    NSString *path = params[@"assetPath"];
    KuiklyContextParam *contextParam = ((KuiklyRenderView *)self.hr_rootView).contextParam;
    NSURL *pathUrl = [contextParam urlForFileName:[path stringByDeletingPathExtension] extension:[path pathExtension]];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSError *error;
        NSString *jsonStr = [NSString stringWithContentsOfURL:pathUrl encoding:NSUTF8StringEncoding error:&error];
        NSDictionary *result = @{
            @"result": jsonStr ?: @"",
            @"error": error.description ?: @""
        };
        if (callback) {
            callback(result);
        }
    });
}

#pragma mark - Helpers

- (NSDictionary *)parseParams:(NSDictionary *)args {
    id param = args[KR_PARAM_KEY];
    if ([param isKindOfClass:[NSDictionary class]]) {
        return param;
    }
    if ([param isKindOfClass:[NSString class]]) {
        NSData *data = [(NSString *)param dataUsingEncoding:NSUTF8StringEncoding];
        if (data) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) {
                return json;
            }
        }
    }
    return @{};
}

- (UIViewController *)viewController {
    UIView *view = self.hr_rootView;
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)responder;
        }
        responder = [responder nextResponder];
    }
    return nil;
}

@end
