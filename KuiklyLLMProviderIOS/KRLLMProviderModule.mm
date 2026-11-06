#import "KRLLMProviderModule.h"
#include "provider_c_api.h"
#include <CommonCrypto/CommonDigest.h>

#pragma mark - Contract constants
// 与 KuiklyLLMProvider/.../LLMProviderContract.kt、AndroidProviderContract.kt 保持一致。
// Module 名 KRLLMProviderModule 与 5 个 method 名由 KRBaseModule 按 "<method>:" 映射为 selector：
// startServer / stopServer / serverStatus / models / modelAction，勿改。

static NSString * const kLPMKeyPort = @"port";
static NSString * const kLPMKeyModelId = @"modelId";
static NSString * const kLPMKeyAction = @"action";
static NSString * const kLPMKeyData = @"data";
static NSString * const kLPMKeyOk = @"ok";
static NSString * const kLPMKeyRunning = @"running";
static NSString * const kLPMKeyBaseUrl = @"baseUrl";
static NSString * const kLPMKeyApiKey = @"apiKey";
static NSString * const kLPMKeyMessage = @"message";
static NSString * const kLPMKeyError = @"error";
static NSString * const kLPMKeyModels = @"models";
static NSString * const kLPMKeyId = @"id";
static NSString * const kLPMKeyName = @"name";
static NSString * const kLPMKeyBytes = @"bytes";
static NSString * const kLPMKeyState = @"state";
static NSString * const kLPMKeyDownloaded = @"downloaded";
static NSString * const kLPMKeyTotal = @"total";
static NSString * const kLPMKeyActive = @"active";
static NSString * const kLPMKeyBundled = @"bundled";
static NSString * const kLPMKeyActions = @"actions";

static NSString * const kLPMActionDownload = @"download";
static NSString * const kLPMActionPause = @"pause";
static NSString * const kLPMActionResume = @"resume";
static NSString * const kLPMActionCancel = @"cancel";
static NSString * const kLPMActionSelect = @"select";
static NSString * const kLPMActionDelete = @"delete";

static NSString * const kLPMStateDownloading = @"downloading";
static NSString * const kLPMStatePaused = @"paused";
static NSString * const kLPMStateReady = @"ready";
static NSString * const kLPMStateActive = @"active";
static NSString * const kLPMStateNotAvailable = @"not_available";

static NSString * const kLPMDownloadedBytesKey = @"KuiklyLLMProviderDownloadedBytes";

#pragma mark - Model store

@interface LPMModel : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *fileName;
@property (nonatomic, assign) long long bytes;
@property (nonatomic, copy) NSString *sha256;
@property (nonatomic, copy) NSString *url;
/** 备用下载源；主源不可用时切一次，未配置为空串。 */
@property (nonatomic, copy) NSString *urlBackup;
@property (nonatomic, assign) BOOL bundled;
@end
@implementation LPMModel
@end

// 所有可变状态（tasks/resumeData/downloadedBytes/epochs/activeId/lastError）
// 一律经 @synchronized(self) 访问；昂贵文件 IO（hash/copy/move）在锁外执行，避免阻塞其它队列。
@interface LPMStore : NSObject
@property (nonatomic, strong) NSMutableArray<LPMModel *> *catalog;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSURLSessionDownloadTask *> *tasks;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSData *> *resumeData;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *downloadedBytes;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *epochs;
@property (nonatomic, strong) NSMutableSet<NSString *> *pausedIds;
/** 已切到备用源的在途模型 id，保证每个模型只切一次。 */
@property (nonatomic, strong) NSMutableSet<NSString *> *backupIds;
@property (nonatomic, copy) NSString *dir;
/** 签名包内的内置模型真实路径（KuiklyLLMProviderModels.bundle）；download 变体为 nil。 */
@property (nonatomic, copy) NSString *bundledModelPath;
@property (nonatomic, copy) NSString *activeId;
@property (nonatomic, copy) NSString *lastError;
- (instancetype)initWithBundle:(NSBundle *)podBundle;
- (NSString *)downloadPathFor:(LPMModel *)m;
- (NSString *)pathFor:(LPMModel *)m;
- (NSString *)partFor:(LPMModel *)m;
- (NSString *)resumeFileFor:(LPMModel *)m;
- (void)persistProgress;
- (LPMModel *)firstReady;
- (NSString *)snapshot;
- (void)download:(LPMModel *)m resume:(BOOL)resume;
- (void)finishDownload:(LPMModel *)m epoch:(NSUInteger)epoch location:(NSURL *)location response:(NSURLResponse *)response error:(NSError *)error;
/** 主源不可用时切备用源重试一次；已切过或没有备源返回 NO，由调用方记录错误。 */
- (BOOL)retryWithBackup:(LPMModel *)m;
- (void)clearProgressFor:(LPMModel *)m;
- (void)setLastError:(NSString *)message;
- (void)markActive:(NSString *)identifier;
- (void)pause:(LPMModel *)m;
- (void)cancel:(LPMModel *)m;
- (BOOL)select:(LPMModel *)m;
- (void)deleteModel:(LPMModel *)m;
@end

/**
 * resource_bundles 生成的是独立 .bundle；bundleForClass 对应的 framework bundle
 * 直接 pathForResource 不会进入子 bundle，必须先取子 bundle。
 * 静态库集成时 bundle 可能落在 mainBundle，故补一次 mainBundle 查找。
 */
static NSBundle *LPMResourceBundle(NSBundle *podBundle, NSString *name) {
    NSURL *url = [podBundle URLForResource:name withExtension:@"bundle"];
    if (!url) url = [[NSBundle mainBundle] URLForResource:name withExtension:@"bundle"];
    return url ? [NSBundle bundleWithURL:url] : nil;
}

static NSDictionary *LPMLoadCatalog(NSBundle *podBundle) {
    NSBundle *legal = LPMResourceBundle(podBundle, @"KuiklyLLMProviderLegal");
    NSString *p = [legal pathForResource:@"catalog" ofType:@"json"] ?: [[NSBundle mainBundle] pathForResource:@"catalog" ofType:@"json"];
    if (!p) return nil;
    NSData *d = [NSData dataWithContentsOfFile:p];
    return [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
}

/** 流式 SHA-256：分块读取，不把整文件载入内存。 */
static NSString *LPMSha256(NSString *path) {
    CC_SHA256_CTX ctx; CC_SHA256_Init(&ctx);
    NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!h) return @"";
    @try {
        BOOL more = YES;
        while (more) {
            // 每块单独的 autorelease pool：否则数百 MB 的块要等外层 GCD block 结束才释放。
            @autoreleasepool {
                NSData *chunk = [h readDataOfLength:64 * 1024];
                more = chunk.length > 0;
                if (more) CC_SHA256_Update(&ctx, chunk.bytes, (CC_LONG)chunk.length);
            }
        }
    } @finally { [h closeFile]; }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *out = [NSMutableString stringWithCapacity:64];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [out appendFormat:@"%02x", digest[i]];
    return out;
}

/** 常量时间比对摘要，hex 定长，长度不属机密。 */
static BOOL LPMSha256Matches(NSString *path, NSString *expected) {
    if (expected.length == 0) return NO;   // catalog 无摘要一律视为不可信
    NSString *actual = LPMSha256(path);
    if (actual.length != expected.length) return NO;
    const char *a = actual.UTF8String, *b = expected.UTF8String;
    unsigned char diff = 0;
    for (NSUInteger i = 0; i < actual.length; i++) diff |= (unsigned char)(a[i] ^ b[i]);
    return diff == 0;
}

/** 引擎当前实际加载的模型 id（未加载为空串）；activeId 一律以此回填，不由平台层推断。 */
static NSString *LPMEngineModelId(void) {
    return [NSString stringWithUTF8String:llmprovider_model_id()] ?: @"";
}

static BOOL LPMSizeMatches(NSString *path, LPMModel *m) {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    return attrs && [attrs[NSFileSize] longLongValue] == m.bytes;
}

/** size + 流式 SHA-256 严格校验：仅在下载完成、落到最终路径之前执行一次。 */
static BOOL LPMVerify(NSString *path, LPMModel *m) {
    return LPMSizeMatches(path, m) && LPMSha256Matches(path, m.sha256);
}

/**
 * start / select 的轻量判定：size + GGUF 魔数。
 * 最终路径要么位于签名包内（内置模型），要么只经「严格校验后 rename」写入（下载），
 * 且在应用私有目录，无需每次重新计算整文件哈希。
 */
static BOOL LPMPlausible(NSString *path, LPMModel *m) {
    if (!LPMSizeMatches(path, m)) return NO;
    NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!h) return NO;
    NSData *head = nil;
    @try { head = [h readDataOfLength:4]; } @finally { [h closeFile]; }
    return head.length == 4 && memcmp(head.bytes, "GGUF", 4) == 0;
}

@implementation LPMStore

- (instancetype)initWithBundle:(NSBundle *)podBundle {
    if (self = [super init]) {
        _catalog = [NSMutableArray array];
        _tasks = [NSMutableDictionary dictionary];
        _resumeData = [NSMutableDictionary dictionary];
        _downloadedBytes = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:kLPMDownloadedBytesKey] mutableCopy]
                           ?: [NSMutableDictionary dictionary];
        _epochs = [NSMutableDictionary dictionary];
        _pausedIds = [NSMutableSet set];
        _backupIds = [NSMutableSet set];
        _activeId = @"";
        _lastError = @"";
        // Application Support 对用户不可见（宿主开启文件共享时 Documents 可被 Finder 替换）；
        // 加库名子目录，避免与宿主自身的 models 目录冲突。
        NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        _dir = [support stringByAppendingPathComponent:@"KuiklyLLMProvider/models"];
        // 内置模型位于 KuiklyLLMProviderModels.bundle 内，必须显式进入子 bundle；
        // 签名包内即为可 mmap 的真实文件，直接使用，不拷贝。
        NSBundle *modelsBundle = LPMResourceBundle(podBundle, @"KuiklyLLMProviderModels");
        _bundledModelPath = [modelsBundle pathForResource:@"model" ofType:@"gguf"]
                            ?: [[NSBundle mainBundle] pathForResource:@"model" ofType:@"gguf"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:_dir withIntermediateDirectories:YES attributes:nil error:nil];
        // 模型体积大且可重建，排除 iCloud / iTunes 备份。
        NSURL *dirURL = [NSURL fileURLWithPath:_dir isDirectory:YES];
        [dirURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
        NSDictionary *cat = LPMLoadCatalog(podBundle);
        for (NSDictionary *o in (cat[kLPMKeyModels] ?: @[])) {
            LPMModel *m = [LPMModel new];
            m.identifier = o[@"id"] ?: @""; m.name = o[@"name"] ?: @"";
            m.fileName = o[@"file"] ?: @""; m.bytes = [o[@"bytes"] longLongValue];
            m.sha256 = o[@"sha256"] ?: @""; m.url = o[@"url_primary"] ?: @"";
            m.urlBackup = o[@"url_backup"] ?: @"";
            m.bundled = [o[@"bundled"] boolValue];
            [_catalog addObject:m];
        }
        for (LPMModel *m in _catalog) {
            NSData *saved = [NSData dataWithContentsOfFile:[self resumeFileFor:m]];
            if (saved) _resumeData[m.identifier] = saved;
        }
    }
    return self;
}

/** 可写目录中的模型路径：下载落盘、.part / .resume 均以此为基准。 */
- (NSString *)downloadPathFor:(LPMModel *)m { return [_dir stringByAppendingPathComponent:m.fileName]; }
/** 模型实际使用的路径：内置模型取签名包内资源；资源缺失时退回可写目录（可下载）。 */
- (NSString *)pathFor:(LPMModel *)m {
    return (m.bundled && _bundledModelPath) ? _bundledModelPath : [self downloadPathFor:m];
}
- (NSString *)partFor:(LPMModel *)m { return [[self downloadPathFor:m] stringByAppendingString:@".part"]; }
- (NSString *)resumeFileFor:(LPMModel *)m { return [[self downloadPathFor:m] stringByAppendingString:@".resume"]; }

- (void)persistProgress {
    NSDictionary *progress;
    @synchronized(self) { progress = [_downloadedBytes copy]; }
    [[NSUserDefaults standardUserDefaults] setObject:progress forKey:kLPMDownloadedBytesKey];
}

- (void)setLastError:(NSString *)message {
    @synchronized(self) { _lastError = [message copy] ?: @""; }
}

- (void)markActive:(NSString *)identifier {
    @synchronized(self) { _activeId = [identifier copy] ?: @""; }
}

- (LPMModel *)firstReady {
    NSArray *catalog;
    @synchronized(self) { catalog = [_catalog copy]; }
    for (LPMModel *m in catalog) {
        if (LPMPlausible([self pathFor:m], m)) return m;
    }
    return nil;
}

- (NSString *)snapshot {
    NSArray *catalog;
    NSDictionary *tasks, *downloadedBytes, *resumeData;
    NSSet *pausedIds;
    NSString *activeId, *lastError;
    // 一次性在锁内拷贝全部可变状态；锁外做文件 IO 与 JSON 构建，避免长时间持锁。
    @synchronized(self) {
        catalog = [_catalog copy];
        tasks = [_tasks copy];
        downloadedBytes = [_downloadedBytes copy];
        resumeData = [_resumeData copy];
        pausedIds = [_pausedIds copy];
        activeId = [_activeId copy] ?: @"";
        lastError = [_lastError copy] ?: @"";
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *arr = [NSMutableArray array];
    for (LPMModel *m in catalog) {
        NSString *p = [self pathFor:m], *part = [self partFor:m];
        BOOL exists = [fm fileExistsAtPath:p];
        BOOL partial = [fm fileExistsAtPath:part];
        NSURLSessionDownloadTask *task = tasks[m.identifier];
        BOOL running = task != nil;
        long long size = exists ? [[[fm attributesOfItemAtPath:p error:nil] objectForKey:NSFileSize] longLongValue]
                                : (partial ? [[[fm attributesOfItemAtPath:part error:nil] objectForKey:NSFileSize] longLongValue] : 0);
        long long base = [downloadedBytes[m.identifier] longLongValue];
        long long downloaded = MAX(size, base);
        if (task) downloaded = MAX(downloaded, base + (long long)task.countOfBytesReceived);
        // pause: 先摘除 task，但 resumeData 由 cancelByProducingResumeData 异步回写；
        // 用同步的 pausedIds 标记覆盖这个窗口，避免 snapshot 误判 not_available（UI 闪「未下载」）。
        BOOL pausedFlag = [pausedIds containsObject:m.identifier];
        NSString *state = pausedFlag ? kLPMStatePaused
                        : running ? kLPMStateDownloading
                        : (exists && size == m.bytes) ? ([m.identifier isEqualToString:activeId] ? kLPMStateActive : kLPMStateReady)
                        : (partial || resumeData[m.identifier]) ? kLPMStatePaused : kLPMStateNotAvailable;
        NSMutableArray *actions = [NSMutableArray array];
        if ([state isEqualToString:kLPMStateDownloading]) {
            [actions addObjectsFromArray:@[kLPMActionPause, kLPMActionCancel]];
        } else if ([state isEqualToString:kLPMStatePaused]) {
            [actions addObjectsFromArray:@[kLPMActionResume, kLPMActionCancel]];
        } else if ([state isEqualToString:kLPMStateReady]) {
            [actions addObject:kLPMActionSelect];
            if (!m.bundled) [actions addObject:kLPMActionDelete];
        } else if ([state isEqualToString:kLPMStateActive]) {
            if (!m.bundled) [actions addObject:kLPMActionDelete];
        } else {
            [actions addObject:kLPMActionDownload];
        }
        [arr addObject:@{kLPMKeyId: m.identifier, kLPMKeyName: m.name, kLPMKeyBytes: @(m.bytes),
                         kLPMKeyState: state, kLPMKeyDownloaded: @(downloaded), kLPMKeyTotal: @(m.bytes),
                         kLPMKeyActive: @([m.identifier isEqualToString:activeId]),
                         kLPMKeyBundled: @(m.bundled), kLPMKeyActions: actions}];
    }
    NSData *d = [NSJSONSerialization dataWithJSONObject:@{kLPMKeyModels: arr, kLPMKeyError: lastError} options:0 error:nil];
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

- (void)download:(LPMModel *)m resume:(BOOL)resume {
    NSURLSession *session = nil;
    NSURLSessionDownloadTask *t = nil;
    @synchronized(self) {
        // 状态检查、epoch 递增、task 登记在同一把锁内，避免并发 download 抢占。
        if (_tasks[m.identifier]) return;
        [_pausedIds removeObject:m.identifier];
        _lastError = @"";
        NSUInteger epoch = [_epochs[m.identifier] unsignedIntegerValue] + 1;
        _epochs[m.identifier] = @(epoch);
        session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
        __weak LPMStore *weakSelf = self;
        void (^done)(NSURL *, NSURLResponse *, NSError *) = ^(NSURL *location, NSURLResponse *response, NSError *error) {
            [weakSelf finishDownload:m epoch:epoch location:location response:response error:error];
        };
        NSData *rd = resume ? _resumeData[m.identifier] : nil;
        if (rd) {
            t = [session downloadTaskWithResumeData:rd completionHandler:done];
            [_resumeData removeObjectForKey:m.identifier];
            [[NSFileManager defaultManager] removeItemAtPath:[self resumeFileFor:m] error:nil];
        } else {
            // 用户续传但无续传数据：没有可沿用的进度，按新一轮从主源开始。
            // 有续传数据时它绑定原 URL，只能沿用当时的源。retryWithBackup 走 resume:NO，不受影响。
            if (resume) [_backupIds removeObject:m.identifier];
            NSString *url = [_backupIds containsObject:m.identifier] ? m.urlBackup : m.url;
            t = [session downloadTaskWithURL:[NSURL URLWithString:url] completionHandler:done];
            [_downloadedBytes removeObjectForKey:m.identifier];
            [self persistProgress];   // 递归 @synchronized 安全
        }
        [_tasks setObject:t forKey:m.identifier];
    }
    [t resume];
    // 任务完成（成功/失败/取消）后由系统 invalidate，避免 NSURLSession 泄漏；
    // 后续 resume 会新建 session，旧 completion 由 epoch 拦截。
    [session finishTasksAndInvalidate];
}

- (BOOL)retryWithBackup:(LPMModel *)m {
    if (m.urlBackup.length == 0 || [m.urlBackup isEqualToString:m.url]) return NO;
    @synchronized(self) {
        if ([_backupIds containsObject:m.identifier]) return NO;
        [_backupIds addObject:m.identifier];
    }
    // 此时续传数据已被消费或不可用，没有可沿用的进度，从头重新下载。
    [self download:m resume:NO];
    return YES;
}

- (void)finishDownload:(LPMModel *)m epoch:(NSUInteger)epoch location:(NSURL *)location response:(NSURLResponse *)response error:(NSError *)error {
    long long received = 0;
    @synchronized(self) {
        // 丢弃陈旧回调（已被 cancel/pause/新下载替换），避免误写 lastError 或状态。
        if ([_epochs[m.identifier] unsignedIntegerValue] != epoch) return;
        received = (long long)_tasks[m.identifier].countOfBytesReceived;
        [_tasks removeObjectForKey:m.identifier];
    }
    // 网络中断（断网、超时等）时系统可能附带续传数据：保留并转为暂停，
    // 用户点「续传」即可接着下载，而不是丢掉全部进度从头开始。
    NSData *resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData];
    if (resumeData) {
        @synchronized(self) {
            long long base = [_downloadedBytes[m.identifier] longLongValue];
            _downloadedBytes[m.identifier] = @(base + received);
            _resumeData[m.identifier] = resumeData;
            [_pausedIds addObject:m.identifier];
            [self persistProgress];
        }
        [resumeData writeToFile:[self resumeFileFor:m] atomically:YES];
        [self setLastError:error.localizedDescription ?: @"download interrupted"];
        return;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL wasResume = NO;
    long long expectedLength = -1;
    // 校验 HTTP statusCode / expectedContentLength。
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSInteger code = http.statusCode;
        wasResume = (code == 206);
        if (code != 200 && code != 206) {
            if ([self retryWithBackup:m]) return;
            [self setLastError:[NSString stringWithFormat:@"HTTP status %ld", (long)code]];
            [self clearProgressFor:m];
            return;
        }
        expectedLength = http.expectedContentLength;   // NSURLResponseUnknownLength(-1) 时跳过长度断言
    }
    if (error || !location) {
        // 主动取消已在 cancel: 递增 epoch，不会走到这里；此处仅真实网络错误。
        if ([self retryWithBackup:m]) return;
        [self setLastError:error.localizedDescription ?: @"download failed"];
        [self clearProgressFor:m];
        return;
    }
    // 非续传时校验 Content-Length 与 catalog 期望一致（chunked 时为 -1，跳过）。
    if (expectedLength > 0 && !wasResume && expectedLength != m.bytes) {
        // 长度不符（被劫持/返回错误页）时也切备源，镜像之间大小应一致。
        if ([self retryWithBackup:m]) return;
        [self setLastError:@"content-length mismatch"];
        [self clearProgressFor:m];
        return;
    }
    // 先落到同目录暂存文件并完成 size + SHA-256 严格校验，再 rename(2) 原子替换：
    // 最终路径上只会出现已校验的文件，start / select 因此只需轻量判定。
    NSString *dest = [self downloadPathFor:m];
    NSString *staging = [dest stringByAppendingString:@".verifying"];
    NSURL *stagingURL = [NSURL fileURLWithPath:staging];
    [fm removeItemAtPath:staging error:nil];
    NSError *moveError = nil;
    // 零拷贝落盘；跨卷 move 失败时退回 NSFileManager 流式 copy（不整文件读入内存）。
    BOOL moved = [fm moveItemAtURL:location toURL:stagingURL error:&moveError];
    if (!moved) moved = [fm copyItemAtURL:location toURL:stagingURL error:&moveError];
    if (!moved) {
        [self setLastError:moveError.localizedDescription ?: @"move failed"];
        [self clearProgressFor:m];
        return;
    }
    if (!LPMVerify(staging, m)) {
        [fm removeItemAtPath:staging error:nil];
        // 全新下载内容与 catalog 不符（镜像返回错误页）时切备源重试一次；
        // 续传结果不符不切源，直接报错。
        if (!wasResume && [self retryWithBackup:m]) return;
        [self setLastError:@"model verification failed"];
        [self clearProgressFor:m];
        return;
    }
    if (rename(staging.fileSystemRepresentation, dest.fileSystemRepresentation) != 0) {
        [fm removeItemAtPath:staging error:nil];
        [self setLastError:@"model install failed"];
        [self clearProgressFor:m];
        return;
    }
    [self clearProgressFor:m];
}

- (void)clearProgressFor:(LPMModel *)m {
    @synchronized(self) {
        [_downloadedBytes removeObjectForKey:m.identifier];
        [_resumeData removeObjectForKey:m.identifier];
        [_pausedIds removeObject:m.identifier];
        // 本轮结束（成功或彻底失败）：下次下载重新从主源开始。
        [_backupIds removeObject:m.identifier];
    }
    [[NSFileManager defaultManager] removeItemAtPath:[self resumeFileFor:m] error:nil];
    [self persistProgress];
}

- (void)pause:(LPMModel *)m {
    NSURLSessionDownloadTask *t;
    @synchronized(self) {
        t = _tasks[m.identifier];
        if (!t) return;
        long long base = [_downloadedBytes[m.identifier] longLongValue];
        _downloadedBytes[m.identifier] = @(base + (long long)t.countOfBytesReceived);
        // 递增 epoch 作废在途 completion，摘除任务；进度保留供续传。
        _epochs[m.identifier] = @([_epochs[m.identifier] unsignedIntegerValue] + 1);
        [_tasks removeObjectForKey:m.identifier];
        // 同步标记 paused：resumeData 尚未异步回写时也能稳定返回 paused。
        [_pausedIds addObject:m.identifier];
        [self persistProgress];
    }
    __weak LPMStore *weakSelf = self;
    [t cancelByProducingResumeData:^(NSData *resumeData) {
        LPMStore *strongSelf = weakSelf;
        if (!strongSelf || !resumeData) return;
        @synchronized(strongSelf) { strongSelf->_resumeData[m.identifier] = resumeData; }
        [resumeData writeToFile:[strongSelf resumeFileFor:m] atomically:YES];
    }];
}

- (void)cancel:(LPMModel *)m {
    NSURLSessionDownloadTask *t;
    @synchronized(self) {
        t = _tasks[m.identifier];
        // 递增 epoch 作废在途 completion，取消不计为错误。
        _epochs[m.identifier] = @([_epochs[m.identifier] unsignedIntegerValue] + 1);
        [_tasks removeObjectForKey:m.identifier];
        [_pausedIds removeObject:m.identifier];
        [_resumeData removeObjectForKey:m.identifier];
        [_downloadedBytes removeObjectForKey:m.identifier];
        [_backupIds removeObject:m.identifier];   // 取消即结束本轮，下次下载重新从主源开始
        [self persistProgress];
    }
    [t cancel];   // 完成回调因 epoch 不匹配被丢弃，不写 lastError
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:[self partFor:m] error:nil];
    [fm removeItemAtPath:[self resumeFileFor:m] error:nil];
}

- (BOOL)select:(LPMModel *)m {
    NSString *p = [self pathFor:m];
    if (!LPMPlausible(p, m)) return NO;
    BOOL ok = llmprovider_load_model(p.UTF8String, m.identifier.UTF8String) == 1;
    // 先卸后载：失败时引擎已无模型，以引擎实际状态为准（为空串）。
    [self markActive:LPMEngineModelId()];
    if (!ok) [self setLastError:@"engine failed to load model"];
    return ok;
}

- (void)deleteModel:(LPMModel *)m {
    // 内置模型属于发布产物，不提供删除入口。
    if (m.bundled) return;
    NSURLSessionDownloadTask *t;
    BOOL wasActive = NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    @synchronized(self) {
        t = _tasks[m.identifier];
        wasActive = [m.identifier isEqualToString:_activeId];
        _epochs[m.identifier] = @([_epochs[m.identifier] unsignedIntegerValue] + 1);
        [_tasks removeObjectForKey:m.identifier];
        [_resumeData removeObjectForKey:m.identifier];
        [_downloadedBytes removeObjectForKey:m.identifier];
        [_pausedIds removeObject:m.identifier];
        if (wasActive) _activeId = @"";
        [self persistProgress];
    }
    [t cancel];
    // 删除当前权重前先卸载引擎，服务回到「无可用模型」状态（C ABI 签名不变）。
    if (wasActive) llmprovider_load_model("", "");
    [fm removeItemAtPath:[self pathFor:m] error:nil];
    [fm removeItemAtPath:[self partFor:m] error:nil];
    [fm removeItemAtPath:[self resumeFileFor:m] error:nil];
}
@end

#pragma mark - Module

/**
 * 进程级串行队列：所有改变 native 服务状态的操作（start / stop / select / delete）
 * 按调用顺序执行，且不占用主线程。
 * stop 可能要等在途生成或模型加载释放 native 锁，同步执行会阻塞主线程触发 watchdog。
 */
static dispatch_queue_t LPMServiceQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.kuikly.llmprovider.service", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

@implementation KRLLMProviderModule

// 扩展 Module 由 Kuikly 按类名创建，启动服务与查询状态可能落在不同实例上。
// 进程内共用一个 store，保证 active 标记与下载进度对每次查询一致。
- (LPMStore *)modelStore {
    static LPMStore *sharedStore = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedStore = [[LPMStore alloc] initWithBundle:[NSBundle bundleForClass:[KRLLMProviderModule class]]];
    });
    return sharedStore;
}

- (NSDictionary *)params:(NSDictionary *)args {
    id v = args[KR_PARAM_KEY];
    if ([v isKindOfClass:[NSDictionary class]]) return v;
    if ([v isKindOfClass:[NSString class]]) {
        NSData *d = [(NSString *)v dataUsingEncoding:NSUTF8StringEncoding];
        id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if ([j isKindOfClass:[NSDictionary class]]) return j;
    }
    return @{};
}

- (void)reply:(NSDictionary *)args payload:(NSDictionary *)payload {
    KuiklyRenderCallback cb = args[KR_CALLBACK_KEY];
    if (!cb) return;
    dispatch_async(dispatch_get_main_queue(), ^{ cb(payload); });
}

/** 统一契约响应构造器，start / stop / status 结构一致。 */
- (NSDictionary *)statusPayloadWithOk:(BOOL)ok message:(NSString *)message {
    return @{kLPMKeyOk: @(ok),
             kLPMKeyRunning: @(llmprovider_is_running() == 1),
             kLPMKeyBaseUrl: [NSString stringWithUTF8String:llmprovider_base_url()] ?: @"",
             kLPMKeyApiKey: [NSString stringWithUTF8String:llmprovider_api_key()] ?: @"",
             kLPMKeyMessage: message ?: @""};
}

- (void)startServer:(NSDictionary *)args {
    NSDictionary *p = [self params:args];
    // 未传 port 时 intValue 得 0 = 不指定，由内核分配；实际地址从 llmprovider_base_url() 取。
    int port = [p[kLPMKeyPort] intValue];
    KuiklyRenderCallback cb = [args[KR_CALLBACK_KEY] copy];
    dispatch_async(LPMServiceQueue(), ^{
        LPMStore *s = [self modelStore];
        LPMModel *first = [s firstReady];
        NSString *path = first ? [s pathFor:first] : @"";
        NSString *mid = first ? first.identifier : @"";
        int ok = llmprovider_start(port, path.UTF8String, mid.UTF8String);
        // 服务已在运行时 start 幂等返回、不会加载 first，以引擎实际加载的模型为准。
        if (ok) [s markActive:LPMEngineModelId()];
        NSString *detail = [NSString stringWithUTF8String:llmprovider_last_error()];
        NSString *message = ok ? @"服务已启动" : (detail.length > 0 ? detail : @"启动失败");
        NSDictionary *out = [self statusPayloadWithOk:(ok == 1) message:message];
        if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(out); });
    });
}

- (void)stopServer:(NSDictionary *)args {
    KuiklyRenderCallback cb = [args[KR_CALLBACK_KEY] copy];
    dispatch_async(LPMServiceQueue(), ^{
        llmprovider_stop();
        [[self modelStore] markActive:LPMEngineModelId()];   // 停止后引擎无模型（空串）
        // 补齐 running / baseUrl / apiKey，结构与 start / status 一致。
        NSDictionary *out = [self statusPayloadWithOk:YES message:@"服务已停止"];
        if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(out); });
    });
}

- (void)serverStatus:(NSDictionary *)args {
    // ok 统一表示「调用是否成功」（本同步调用恒成功），运行状态由 running 单独表达。
    [self reply:args payload:[self statusPayloadWithOk:YES message:@""]];
}

- (void)models:(NSDictionary *)args {
    // snapshot 含文件 IO，挪到后台队列，回主线程 reply。
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *snap = [[self modelStore] snapshot] ?: @"{}";
        [self reply:args payload:@{kLPMKeyData: snap}];
    });
}

- (void)modelAction:(NSDictionary *)args {
    NSDictionary *p = [self params:args];
    NSString *action = p[kLPMKeyAction] ?: @"";
    NSString *mid = p[kLPMKeyModelId] ?: @"";
    // 全部动作（含 select 加载、snapshot 文件 IO）放后台队列，避免阻塞主线程。
    // select 加载模型、delete 可能卸载模型，进服务串行队列保证与 start / stop 按序生效；
    // 下载类动作不碰 native 服务，不应排在可能长时间等待的 stop 之后。
    BOOL touchesService = [action isEqualToString:kLPMActionSelect] ||
                          [action isEqualToString:kLPMActionDelete];
    dispatch_queue_t queue = touchesService ? LPMServiceQueue()
                                            : dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_async(queue, ^{
        LPMStore *s = [self modelStore];
        LPMModel *target = nil;
        @synchronized(s) {
            for (LPMModel *m in s.catalog) if ([m.identifier isEqualToString:mid]) { target = m; break; }
        }
        // 非法 modelId、未知 action、删除内置模型一律 ok=NO。
        BOOL ok = target != nil;
        BOOL bundledDelete = [action isEqualToString:kLPMActionDelete] && target.bundled;
        if (ok && !bundledDelete) {
            if ([action isEqualToString:kLPMActionDownload]) [s download:target resume:NO];
            else if ([action isEqualToString:kLPMActionResume]) [s download:target resume:YES];
            else if ([action isEqualToString:kLPMActionPause]) [s pause:target];
            else if ([action isEqualToString:kLPMActionCancel]) [s cancel:target];
            else if ([action isEqualToString:kLPMActionSelect]) ok = [s select:target];
            else if ([action isEqualToString:kLPMActionDelete]) [s deleteModel:target];
            else ok = NO;
        } else ok = NO;
        [self reply:args payload:@{kLPMKeyOk: @(ok),
                                   kLPMKeyMessage: ok ? @"" : @"invalid modelId or action",
                                   kLPMKeyData: [s snapshot] ?: @"{}"}];
    });
}

@end
