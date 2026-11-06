#import "KRFontHandler.h"
#import "KRFontModule.h"
#import "KuiklyContextParam.h"
#import <CoreText/CoreText.h>

@implementation KRFontHandler

+ (void)load {
    [KuiklyRenderBridge registerFontHandler:[KRFontHandler new]];
}

- (CGFloat)scaleFitWithFontSize:(CGFloat)fontSize {
    return fontSize * 2;
}

- (BOOL)hr_loadCustomFont:(NSString *)fontFamily
            contextParams:(KuiklyContextParam *)contextParam {
    if ([[UIFont familyNames] containsObject:fontFamily]) {
        return YES;
    }

    NSString *fontPath = [NSString stringWithFormat:@"%@/%@", contextParam.resourceFolderUrl, fontFamily];
    NSURL *fontPathURL = [NSURL fileURLWithPath:fontPath];

    if ([fontPathURL.scheme hasPrefix:@"http"]) {
        return NO;
    } else {
        return [self registerFontAtLocalURL:fontPathURL];
    }
}

- (BOOL)registerFontAtLocalURL:(NSURL *)fontURL {
    CGDataProviderRef fontDataProvider = CGDataProviderCreateWithURL((__bridge CFURLRef)fontURL);
    if (!fontDataProvider) {
        return NO;
    }

    CGFontRef newFont = CGFontCreateWithDataProvider(fontDataProvider);
    CGDataProviderRelease(fontDataProvider);

    if (!newFont) {
        return NO;
    }

    CFErrorRef error = NULL;
    BOOL success = CTFontManagerRegisterFontsForURL((__bridge CFURLRef)fontURL,
                                                    kCTFontManagerScopeProcess,
                                                    &error);
    CGFontRelease(newFont);
    if (!success) {
        if (error) {
            CFRelease(error);
        }
        return NO;
    }
    return YES;
}

@end
