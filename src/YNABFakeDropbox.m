// Simulator-only test harness: serves a local folder as the app's Dropbox, so budgets (.ynab4
// folders) can be loaded and synced without signing in to a real account.
//
// Enabled only when the YNAB_FAKE_DROPBOX_ROOT environment variable points at a directory, e.g.
//   SIMCTL_CHILD_YNAB_FAKE_DROPBOX_ROOT=/path/to/root xcrun simctl launch <device> <bundle id>
// with the budget at <root>/YNAB/Some~1234ABCD.ynab4. Compiled into the simulator build only.

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *sFakeRoot;

#pragma mark - Paths and metadata

// Dropbox paths are case-insensitive; resolve each component against what's on disk.
static NSString *YBFakeResolve(NSString *dropboxPath, BOOL createParents) {
    NSString *current = sFakeRoot;
    NSArray<NSString *> *parts = [dropboxPath.stringByStandardizingPath pathComponents];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSString *part = parts[i];
        if ([part isEqualToString:@"/"] || part.length == 0) continue;
        NSString *match = nil;
        for (NSString *name in [fm contentsOfDirectoryAtPath:current error:nil]) {
            if ([name caseInsensitiveCompare:part] == NSOrderedSame) { match = name; break; }
        }
        if (!match) {
            if (!createParents) return nil;
            match = part;
            if (i + 1 < parts.count) {
                [fm createDirectoryAtPath:[current stringByAppendingPathComponent:match]
              withIntermediateDirectories:YES attributes:nil error:nil];
            }
        }
        current = [current stringByAppendingPathComponent:match];
    }
    return current;
}

static NSString *YBFakeDropboxPathFor(NSString *localPath) {
    NSString *rel = [localPath substringFromIndex:sFakeRoot.length];
    return rel.length ? rel : @"";
}

static NSString *YBFakeHex(NSString *s, NSUInteger length) {
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(d.bytes, (CC_LONG)d.length, digest);
    NSMutableString *hex = [NSMutableString string];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return [hex substringToIndex:length];
}

static id YBFakeMetadata(NSString *localPath) {
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:localPath error:nil];
    if (!attrs) return nil;
    NSString *display = YBFakeDropboxPathFor(localPath);
    NSString *lower = display.lowercaseString;
    NSString *name = localPath.lastPathComponent;
    NSString *ident = [@"id:" stringByAppendingString:YBFakeHex(lower, 16)];
    if ([attrs.fileType isEqualToString:NSFileTypeDirectory]) {
        id m = [objc_getClass("DBFILESFolderMetadata") alloc];
        return ((id (*)(id, SEL, id, id, id, id, id, id, id, id))objc_msgSend)(m,
            sel_registerName("initWithName:id_:pathLower:pathDisplay:parentSharedFolderId:sharedFolderId:sharingInfo:propertyGroups:"),
            name, ident, lower, display, nil, nil, nil, nil);
    }
    NSDate *modified = attrs.fileModificationDate ?: [NSDate date];
    NSString *rev = YBFakeHex([NSString stringWithFormat:@"%@|%f|%@", lower, modified.timeIntervalSince1970, attrs[NSFileSize]], 16);
    id m = [objc_getClass("DBFILESFileMetadata") alloc];
    return ((id (*)(id, SEL, id, id, id, id, id, id, id, id, id, id, id, id, id, id))objc_msgSend)(m,
        sel_registerName("initWithName:id_:clientModified:serverModified:rev:size:pathLower:pathDisplay:parentSharedFolderId:mediaInfo:sharingInfo:propertyGroups:hasExplicitSharedMembers:contentHash:"),
        name, ident, modified, modified, rev, attrs[NSFileSize] ?: @0, lower, display, nil, nil, nil, nil, nil, nil);
}

static id YBFakeNotFound(const char *errorClass) {
    id lookup = ((id (*)(id, SEL))objc_msgSend)([objc_getClass("DBFILESLookupError") alloc], sel_registerName("initWithNotFound"));
    return ((id (*)(id, SEL, id))objc_msgSend)([objc_getClass(errorClass) alloc], sel_registerName("initWithPath:"), lookup);
}

#pragma mark - Tasks

typedef NS_ENUM(NSInteger, YBFakeTaskKind) { YBFakeTaskRpc, YBFakeTaskData, YBFakeTaskUrl };

@interface YBFakeDropboxTask : NSObject
@property (nonatomic) YBFakeTaskKind kind;
@property (nonatomic, strong) id result, routeError, extra;
@end

@implementation YBFakeDropboxTask

+ (instancetype)kind:(YBFakeTaskKind)kind result:(id)result error:(id)error extra:(id)extra {
    YBFakeDropboxTask *t = [self new];
    t.kind = kind; t.result = result; t.routeError = error; t.extra = extra;
    return t;
}

- (id)setResponseBlock:(id)responseBlock queue:(NSOperationQueue *)queue {
    // Callers may hand over a stack block; typed as id, ARC would only retain it, so copy it.
    id block = [responseBlock copy];
    void (^deliver)(void) = ^{
        if (self.kind == YBFakeTaskRpc) {
            ((void (^)(id, id, id))block)(self.result, self.routeError, nil);
        } else {
            ((void (^)(id, id, id, id))block)(self.result, self.routeError, nil, self.extra);
        }
    };
    // YNAB_FAKE_DROPBOX_DELAY=<seconds> holds every response back, to keep a sync (and its
    // "Syncing..." banner) going long enough to test the UI during it.
    const char *delay = getenv("YNAB_FAKE_DROPBOX_DELAY");
    void (^send)(void) = ^{
        if (queue) [queue addOperationWithBlock:deliver];
        else dispatch_async(dispatch_get_main_queue(), deliver);
    };
    if (delay && atof(delay) > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(atof(delay) * NSEC_PER_SEC)), dispatch_get_main_queue(), send);
    } else {
        send();
    }
    return self;
}

- (id)setResponseBlock:(id)block { return [self setResponseBlock:block queue:nil]; }
- (id)setProgressBlock:(id)block { return self; }
- (id)setProgressBlock:(id)block queue:(id)queue { return self; }
- (void)cancel {}
- (void)resume {}
- (void)start {}
- (void)suspend {}

@end

#pragma mark - Routes

@interface YBFakeDropboxRoutes : NSObject
@end

@implementation YBFakeDropboxRoutes

- (id)listFolder:(NSString *)path {
    NSString *local = YBFakeResolve(path, NO);
    BOOL isDir = NO;
    if (!local || ![NSFileManager.defaultManager fileExistsAtPath:local isDirectory:&isDir] || !isDir) {
        return [YBFakeDropboxTask kind:YBFakeTaskRpc result:nil error:YBFakeNotFound("DBFILESListFolderError") extra:nil];
    }
    NSMutableArray *entries = [NSMutableArray array];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:local error:nil]) {
        if ([name hasPrefix:@"."]) continue;
        id m = YBFakeMetadata([local stringByAppendingPathComponent:name]);
        if (m) [entries addObject:m];
    }
    id result = ((id (*)(id, SEL, id, id, id))objc_msgSend)([objc_getClass("DBFILESListFolderResult") alloc],
        sel_registerName("initWithEntries:cursor:hasMore:"), entries, @"fake-cursor", @NO);
    NSLog(@"[FakeDropbox] listFolder %@ -> %lu entries", path, (unsigned long)entries.count);
    return [YBFakeDropboxTask kind:YBFakeTaskRpc result:result error:nil extra:nil];
}

- (id)listFolderContinue:(NSString *)cursor {
    id result = ((id (*)(id, SEL, id, id, id))objc_msgSend)([objc_getClass("DBFILESListFolderResult") alloc],
        sel_registerName("initWithEntries:cursor:hasMore:"), @[], @"fake-cursor", @NO);
    return [YBFakeDropboxTask kind:YBFakeTaskRpc result:result error:nil extra:nil];
}

- (id)getMetadata:(NSString *)path {
    NSString *local = YBFakeResolve(path, NO);
    id m = local ? YBFakeMetadata(local) : nil;
    NSLog(@"[FakeDropbox] getMetadata %@ -> %@", path, m ? @"ok" : @"not found");
    return [YBFakeDropboxTask kind:YBFakeTaskRpc result:m error:m ? nil : YBFakeNotFound("DBFILESGetMetadataError") extra:nil];
}

- (id)downloadData:(NSString *)path {
    NSString *local = YBFakeResolve(path, NO);
    NSData *data = local ? [NSData dataWithContentsOfFile:local] : nil;
    NSLog(@"[FakeDropbox] downloadData %@ -> %lu bytes", path, (unsigned long)data.length);
    if (!data) return [YBFakeDropboxTask kind:YBFakeTaskData result:nil error:YBFakeNotFound("DBFILESDownloadError") extra:nil];
    return [YBFakeDropboxTask kind:YBFakeTaskData result:YBFakeMetadata(local) error:nil extra:data];
}

- (id)downloadUrl:(NSString *)path overwrite:(BOOL)overwrite destination:(NSURL *)destination {
    NSString *local = YBFakeResolve(path, NO);
    NSLog(@"[FakeDropbox] downloadUrl %@ -> %@", path, destination.path);
    if (!local) return [YBFakeDropboxTask kind:YBFakeTaskUrl result:nil error:YBFakeNotFound("DBFILESDownloadError") extra:nil];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtURL:destination.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    if (overwrite) [fm removeItemAtURL:destination error:nil];
    [fm copyItemAtPath:local toPath:destination.path error:nil];
    return [YBFakeDropboxTask kind:YBFakeTaskUrl result:YBFakeMetadata(local) error:nil extra:destination];
}

- (id)writeData:(NSData *)data toPath:(NSString *)path {
    NSString *local = YBFakeResolve(path, YES);
    [data writeToFile:local atomically:YES];
    NSLog(@"[FakeDropbox] upload %@ (%lu bytes)", path, (unsigned long)data.length);
    return [YBFakeDropboxTask kind:YBFakeTaskRpc result:YBFakeMetadata(local) error:nil extra:nil];
}

- (id)uploadData:(NSString *)path mode:(id)mode autorename:(id)autorename clientModified:(id)clientModified
            mute:(id)mute inputData:(NSData *)inputData {
    return [self writeData:inputData toPath:path];
}

- (id)uploadUrl:(NSString *)path mode:(id)mode autorename:(id)autorename clientModified:(id)clientModified
           mute:(id)mute inputUrl:(id)inputUrl {
    NSString *src = [inputUrl isKindOfClass:NSURL.class] ? [inputUrl path] : inputUrl;
    return [self writeData:[NSData dataWithContentsOfFile:src] toPath:path];
}

- (id)delete_:(NSString *)path {
    NSString *local = YBFakeResolve(path, NO);
    id m = local ? YBFakeMetadata(local) : nil;
    if (local) [NSFileManager.defaultManager removeItemAtPath:local error:nil];
    NSLog(@"[FakeDropbox] delete %@", path);
    return [YBFakeDropboxTask kind:YBFakeTaskRpc result:m error:m ? nil : YBFakeNotFound("DBFILESDeleteError") extra:nil];
}

// Anything else the app might ask for: log it and answer nil instead of crashing.
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [super methodSignatureForSelector:sel] ?: [NSMethodSignature signatureWithObjCTypes:"@@:"];
}
- (void)forwardInvocation:(NSInvocation *)inv {
    NSLog(@"[FakeDropbox] unhandled route %@", NSStringFromSelector(inv.selector));
    id nilResult = nil;
    if (inv.methodSignature.methodReturnLength == sizeof(id)) [inv setReturnValue:&nilResult];
}

@end

#pragma mark - Client

@interface YBFakeDropboxClient : NSObject
@end

@implementation YBFakeDropboxClient
- (id)filesRoutes {
    static YBFakeDropboxRoutes *routes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ routes = [YBFakeDropboxRoutes new]; });
    return routes;
}
- (BOOL)isAuthorized { return YES; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [super methodSignatureForSelector:sel] ?: [NSMethodSignature signatureWithObjCTypes:"@@:"];
}
- (void)forwardInvocation:(NSInvocation *)inv {
    NSLog(@"[FakeDropbox] unhandled client call %@", NSStringFromSelector(inv.selector));
    id nilResult = nil;
    if (inv.methodSignature.methodReturnLength == sizeof(id)) [inv setReturnValue:&nilResult];
}
@end

__attribute__((constructor))
static void YNABFakeDropboxInit(void) {
    const char *root = getenv("YNAB_FAKE_DROPBOX_ROOT");
    if (!root || !*root) return;
    sFakeRoot = [@(root) stringByStandardizingPath];
    NSLog(@"[FakeDropbox] serving %@", sFakeRoot);

    static YBFakeDropboxClient *client;
    client = [YBFakeDropboxClient new];
    Class manager = objc_getMetaClass("DBClientsManager");
    Method m = class_getInstanceMethod(manager, sel_registerName("authorizedClient"));
    if (m) method_setImplementation(m, imp_implementationWithBlock(^id(id cls) { return client; }));
}


