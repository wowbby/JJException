//
//  NSObject+KVOCrash.m
//  JJException
//
//  Created by Jezz on 2018/8/29.
//  Copyright © 2018年 Jezz. All rights reserved.
//

#import "NSObject+KVOCrash.h"
#import "NSObject+SwizzleHook.h"
#import <objc/runtime.h>
#import "JJExceptionProxy.h"

static const char DeallocKVOKey;

// Only protects bookkeeping. Never hold it while calling native KVO or client code.
static NSRecursiveLock *JJKVOLock(void) {
    static NSRecursiveLock *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSRecursiveLock new]; });
    return lock;
}

@interface KVOObjectItem : NSObject
@property(nonatomic, retain) NSMapTable *endpoints;
@property(nonatomic, copy) NSString *keyPath;
@property(nonatomic, assign) void *observerIdentity;
@property(nonatomic, assign) void *objectIdentity;
@property(nonatomic, assign) void *context;
@property(nonatomic, assign) NSKeyValueObservingOptions options;
@property(nonatomic, assign) BOOL requested;
@property(nonatomic, assign) BOOL registered;
@property(nonatomic, assign) BOOL transitioning;
@property(nonatomic, assign) BOOL refreshAfterAdd;
@end

@implementation KVOObjectItem
- (instancetype)init {
    if ((self = [super init])) {
        _endpoints = [[NSMapTable strongToWeakObjectsMapTable] retain];
    }
    return self;
}
- (void)dealloc {
    [_endpoints release];
    [_keyPath release];
    [super dealloc];
}
@end

@interface KVOObjectContainer : NSObject
@property(nonatomic, retain) NSMutableArray *items;
@property(nonatomic, assign) BOOL cleaning;
@end

@implementation KVOObjectContainer
- (instancetype)init {
    if ((self = [super init])) {
        _items = [NSMutableArray new];
    }
    return self;
}
- (void)dealloc {
    [_items release];
    [super dealloc];
}
@end

// Call only with JJKVOLock held. Creation and publication must be one operation.
static KVOObjectContainer *JJContainer(NSObject *object, BOOL create) {
    KVOObjectContainer *container = objc_getAssociatedObject(object, &DeallocKVOKey);
    if (!container && create) {
        container = [[[KVOObjectContainer alloc] init] autorelease];
        objc_setAssociatedObject(object, &DeallocKVOKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return container;
}

static void JJUnlinkItem(KVOObjectItem *item, NSObject *object, NSObject *observer) {
    [JJContainer(object, NO).items removeObjectIdenticalTo:item];
    [JJContainer(observer, NO).items removeObjectIdenticalTo:item];
}

static KVOObjectItem *JJFindItem(NSObject *object, NSObject *observer, NSString *keyPath,
                                void *context, BOOL matchContext) {
    // The context-less API removes one registration, most recently added first.
    for (KVOObjectItem *item in [JJContainer(object, NO).items reverseObjectEnumerator]) {
        if (item.objectIdentity == object && item.observerIdentity == observer &&
            [item.keyPath isEqualToString:keyPath] && (!matchContext || item.context == context) &&
            (matchContext || item.requested)) {
            return item;
        }
    }
    return nil;
}

@interface NSObject (JJKVOPrivate)
- (BOOL)ignoreKVOInstanceClass:(id)object;
- (void)hookAddObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath
               options:(NSKeyValueObservingOptions)options context:(void *)context;
- (void)hookRemoveObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath;
- (void)hookRemoveObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath context:(void *)context;
@end

// Foundation's context-aware removal can call the context-less API internally.
// Bypass bookkeeping only for that exact synchronous call, not other KVO operations.
typedef struct JJNativeRemoval {
    NSObject *object;
    NSObject *observer;
    NSString *keyPath;
    struct JJNativeRemoval *previous;
} JJNativeRemoval;
static __thread JJNativeRemoval *jj_nativeRemoval;

static void JJRemoveNative(KVOObjectItem *item, NSObject *object, NSObject *observer) {
    JJNativeRemoval removal = {object, observer, item.keyPath, jj_nativeRemoval};
    jj_nativeRemoval = &removal;
    @try {
        [object hookRemoveObserver:observer forKeyPath:item.keyPath context:item.context];
    } @finally {
        jj_nativeRemoval = removal.previous;
    }
}

// Exactly one caller drives a relation. Reentrant/concurrent callers change requested
// without waiting; the driver reconciles it after native KVO returns. In particular,
// an Initial callback may cancel a registration before addObserver has finished.
// The caller keeps the endpoints alive, except the endpoint currently in dealloc.
static void JJReconcileItem(KVOObjectItem *item, NSObject *object, NSObject *observer) {
    NSException *registrationError = nil;
    while (YES) {
        BOOL adding;
        NSKeyValueObservingOptions options;
        [JJKVOLock() lock];
        @try {
            if (item.requested == item.registered && !(item.registered && item.refreshAfterAdd)) {
                item.transitioning = NO;
                if (!item.requested) {
                    JJUnlinkItem(item, object, observer);
                }
                break;
            }
            adding = !item.registered;
            if (adding) {
                // Re-add changes registration order. Publish before native add, since
                // its Initial callback can synchronously register another context.
                NSMutableArray *items = JJContainer(object, NO).items;
                [items removeObjectIdenticalTo:item];
                [items addObject:item];
            } else {
                item.refreshAfterAdd = NO;
            }
            options = item.options;
        } @finally {
            [JJKVOLock() unlock];
        }

        BOOL succeeded = YES;
        @try {
            if (adding) {
                [object hookAddObserver:observer forKeyPath:item.keyPath options:options context:item.context];
            } else {
                JJRemoveNative(item, object, observer);
            }
        } @catch (NSException *exception) {
            succeeded = NO;
            if (adding) {
                [registrationError release];
                registrationError = [exception retain];
                // An Initial value lookup can throw after Foundation has registered.
                @try { JJRemoveNative(item, object, observer); }
                @catch (__unused NSException *cleanupException) {}
            }
        }

        [JJKVOLock() lock];
        @try {
            item.registered = adding && succeeded;
            if (adding && !succeeded) {
                // A newer remove/add request may have arrived during the failed add.
                // Retry only that newer request, never the failed registration itself.
                item.requested = item.requested && item.refreshAfterAdd;
                item.refreshAfterAdd = NO;
            }
        } @finally {
            [JJKVOLock() unlock];
        }
    }
    if (registrationError) {
        @try {
            handleCrashException(JJExceptionGuardKVOCrash, registrationError.description);
        } @finally {
            [registrationError release];
        }
    }
}

static void JJRequestRemoval(NSObject *object, NSObject *observer, NSString *keyPath,
                             void *context, BOOL matchContext) {
    if (!observer || keyPath.length == 0) return;
    // Keep weak endpoints valid until this operation has completed.
    [object retain];
    [observer retain];
    KVOObjectItem *item = nil;
    BOOL drive = NO;
    @try {
        [JJKVOLock() lock];
        @try {
            item = [JJFindItem(object, observer, keyPath, context, matchContext) retain];
            item.requested = NO;
            if (item && !item.transitioning) {
                item.transitioning = YES;
                drive = YES;
            }
        } @finally {
            [JJKVOLock() unlock];
        }
        if (drive) JJReconcileItem(item, object, observer);
    } @finally {
        [item release];
        [observer release];
        [object release];
    }
}

@implementation NSObject (KVOCrash)

+ (void)jj_swizzleKVOCrash {
    swizzleInstanceMethod(self, @selector(addObserver:forKeyPath:options:context:), @selector(hookAddObserver:forKeyPath:options:context:));
    swizzleInstanceMethod(self, @selector(removeObserver:forKeyPath:), @selector(hookRemoveObserver:forKeyPath:));
    swizzleInstanceMethod(self, @selector(removeObserver:forKeyPath:context:), @selector(hookRemoveObserver:forKeyPath:context:));
    swizzleInstanceMethod(self, @selector(observeValueForKeyPath:ofObject:change:context:), @selector(hookObserveValueForKeyPath:ofObject:change:context:));
}

- (void)hookAddObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath options:(NSKeyValueObservingOptions)options context:(void *)context {
    if ([self ignoreKVOInstanceClass:observer]) {
        [self hookAddObserver:observer forKeyPath:keyPath options:options context:context];
        return;
    }
    if (!observer || keyPath.length == 0) return;

    [self retain];
    [observer retain];
    KVOObjectItem *item = nil;
    BOOL drive = NO;
    @try {
        [JJKVOLock() lock];
        @try {
            KVOObjectContainer *objectContainer = JJContainer(self, YES);
            KVOObjectContainer *observerContainer = JJContainer(observer, YES);
            if (!objectContainer.cleaning && !observerContainer.cleaning) {
                item = [JJFindItem(self, observer, keyPath, context, YES) retain];
                if (!item) {
                    item = [KVOObjectItem new];
                    item.objectIdentity = self;
                    item.observerIdentity = observer;
                    item.keyPath = keyPath;
                    item.context = context;
                    [item.endpoints setObject:self forKey:@"object"];
                    [item.endpoints setObject:observer forKey:@"observer"];
                    [objectContainer.items addObject:item];
                    if (objectContainer != observerContainer) [observerContainer.items addObject:item];
                    // Install on the logical class before Foundation creates its KVO subclass.
                    jj_swizzleDeallocIfNeeded(self.class);
                    jj_swizzleDeallocIfNeeded(observer.class);
                }
                if (!item.requested) {
                    // A canceled in-flight add still uses its original options. Finish it,
                    // then remove/add again so a new Initial request is not silently lost.
                    if (item.transitioning && !item.registered) item.refreshAfterAdd = YES;
                    item.options = options;
                }
                item.requested = YES;
                if (!item.transitioning) {
                    item.transitioning = YES;
                    drive = YES;
                }
            }
        } @finally {
            [JJKVOLock() unlock];
        }
        if (drive) JJReconcileItem(item, self, observer);
    } @finally {
        [item release];
        [observer release];
        [self release];
    }
}

- (void)hookRemoveObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath context:(void *)context {
    if ([self ignoreKVOInstanceClass:observer]) {
        [self hookRemoveObserver:observer forKeyPath:keyPath context:context];
        return;
    }
    JJRequestRemoval(self, observer, keyPath, context, YES);
}

- (void)hookRemoveObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath {
    JJNativeRemoval *removal = jj_nativeRemoval;
    if ((removal && removal->object == self && removal->observer == observer &&
         [removal->keyPath isEqualToString:keyPath]) || [self ignoreKVOInstanceClass:observer]) {
        [self hookRemoveObserver:observer forKeyPath:keyPath];
        return;
    }
    JJRequestRemoval(self, observer, keyPath, NULL, NO);
}

- (void)hookObserveValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if ([self ignoreKVOInstanceClass:object]) {
        [self hookObserveValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    @try {
        [self hookObserveValueForKeyPath:keyPath ofObject:object change:change context:context];
    } @catch (NSException *exception) {
        handleCrashException(JJExceptionGuardKVOCrash, exception.description);
    }
}

- (BOOL)ignoreKVOInstanceClass:(id)object{

    if (!object) {
        return NO;
    }
    if ([NSStringFromClass(object_getClass(object)) isEqualToString:@"AVProxyKVOObserver"]) {
        return YES;
    }
    if ([NSStringFromClass(object_getClass(object)) isEqualToString:@"RACKVOProxy"]) {
        return YES;
    }
    if ([NSStringFromClass(object_getClass(object)) isEqualToString:@"WebAVPlayerController"]) {
        return YES;
    }
    
    if ([NSStringFromClass(object_getClass(object)) isEqualToString:@"NSKVONotifying_WebAVPlayerController"]) {
        return YES;
    }
    //Ignore AMAP
    NSString* className = NSStringFromClass(object_getClass(object));
    if ([className hasPrefix:@"AMap"]) {
        return YES;
    }

    return NO;
}


- (void)jj_cleanKVO {
    NSArray *items;
    [JJKVOLock() lock];
    @try {
        KVOObjectContainer *container = JJContainer(self, NO);
        if (!container || container.cleaning) return;
        container.cleaning = YES;
        items = [container.items copy];
    } @finally {
        [JJKVOLock() unlock];
    }
    @try {
        for (KVOObjectItem *item in items) {
            // Zeroing weak references are already nil for self during deallocation.
            NSObject *object = nil, *observer = nil;
            BOOL drive = NO;
            [JJKVOLock() lock];
            @try {
                object = item.objectIdentity == self ? self : [[item.endpoints objectForKey:@"object"] retain];
                observer = item.observerIdentity == self ? self : [[item.endpoints objectForKey:@"observer"] retain];
                item.requested = NO;
                if (object && observer && !item.transitioning) {
                    item.transitioning = YES;
                    drive = YES;
                } else if (!object || !observer) {
                    JJUnlinkItem(item, object, observer);
                }
            } @finally {
                [JJKVOLock() unlock];
            }
            @try {
                if (drive) JJReconcileItem(item, object, observer);
            } @finally {
                if (observer != self) [observer release];
                if (object != self) [object release];
            }
        }
    } @finally {
        [JJKVOLock() lock];
        @try { [JJContainer(self, NO).items removeAllObjects]; }
        @finally { [JJKVOLock() unlock]; }
        [items release];
    }
}

@end
