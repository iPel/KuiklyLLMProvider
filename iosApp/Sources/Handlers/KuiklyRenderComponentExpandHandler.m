#import "KuiklyRenderComponentExpandHandler.h"
#import <SDWebImage/UIImageView+WebCache.h>
#import <SDWebImage/SDWebImageManager.h>

@implementation KuiklyRenderComponentExpandHandler

+ (void)load {
    [KuiklyRenderBridge registerComponentExpandHandler:[self new]];
}

- (UIColor *)hr_colorWithValue:(NSString *)value {
    return nil;
}

- (BOOL)hr_setImageWithUrl:(NSString *)url forImageView:(UIImageView *)imageView {
    [imageView sd_setImageWithURL:[NSURL URLWithString:url]];
    return YES;
}

- (BOOL)hr_setImageWithUrl:(NSString *)url forImageView:(UIImageView *)imageView complete:(ImageCompletionBlock)completeBlock {
    [imageView sd_setImageWithURL:[NSURL URLWithString:url]
                        completed:^(UIImage * _Nullable image, NSError * _Nullable error, SDImageCacheType cacheType, NSURL * _Nullable imageURL) {
        if (completeBlock) {
            completeBlock(image, error, [NSURL URLWithString:url]);
        }
    }];
    return YES;
}

- (BOOL)hr_setImageWithUrl:(nonnull NSString *)loadURL imageParams:(NSDictionary* _Nullable)imageParams complete:(ImageCompletionBlock)completeBlock {
    [[SDWebImageManager sharedManager] loadImageWithURL:[NSURL URLWithString:loadURL]
                                                options:SDWebImageAvoidAutoSetImage
                                               progress:nil
                                              completed:^(UIImage * _Nullable image, NSData * _Nullable data, NSError * _Nullable error, SDImageCacheType cacheType, BOOL finished, NSURL * _Nullable imageURL) {
        if (completeBlock) {
            completeBlock(image, error, [NSURL URLWithString:loadURL]);
        }
    }];
    return YES;
}

@end
