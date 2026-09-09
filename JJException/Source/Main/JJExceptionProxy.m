//
//  JJExceptionProxy.m
//  JJException
//
//  Created by Jezz on 2018/7/22.
//  Copyright © 2018年 Jezz. All rights reserved.
//

#import "JJExceptionProxy.h"
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <pthread.h>

__attribute__((overloadable)) void handleCrashException(NSString* exceptionMessage){
    [[JJExceptionProxy shareExceptionProxy] handleCrashException:exceptionMessage extraInfo:@{}];
}

__attribute__((overloadable)) void handleCrashException(NSString* exceptionMessage,NSDictionary* extraInfo){
    [[JJExceptionProxy shareExceptionProxy] handleCrashException:exceptionMessage extraInfo:extraInfo];
}

__attribute__((overloadable)) void handleCrashException(JJExceptionGuardCategory exceptionCategory, NSString* exceptionMessage,NSDictionary* extraInfo){
    [[JJExceptionProxy shareExceptionProxy] handleCrashException:exceptionMessage exceptionCategory:exceptionCategory extraInfo:extraInfo];
}

__attribute__((overloadable)) void handleCrashException(JJExceptionGuardCategory exceptionCategory, NSString* exceptionMessage){
    [[JJExceptionProxy shareExceptionProxy] handleCrashException:exceptionMessage exceptionCategory:exceptionCategory extraInfo:nil];
}

/**
 Get application base address,the application different base address after started
 
 @return base address
 */
uintptr_t get_load_address(void) {
    const struct mach_header *exe_header = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header *header = _dyld_get_image_header(i);
        if (header->filetype == MH_EXECUTE) {
            exe_header = header;
            break;
        }
    }
    return (uintptr_t)exe_header;
}

/**
 Address Offset

 @return slide address
 */
uintptr_t get_slide_address(void) {
    uintptr_t vmaddr_slide = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header *header = _dyld_get_image_header(i);
        if (header->filetype == MH_EXECUTE) {
            vmaddr_slide = _dyld_get_image_vmaddr_slide(i);
            break;
        }
    }
    
    return (uintptr_t)vmaddr_slide;
}

typedef struct JJZombieRecord {
    void *pointer;
    size_t size;
    struct JJZombieRecord *next;
} JJZombieRecord;
static const size_t JJZombieCacheLimit = 5 * 1024 * 1024;

@interface JJExceptionProxy(){
    NSHashTable* _blackClassesSet;
    JJZombieRecord *_zombieHead;
    JJZombieRecord *_zombieTail;
    NSUInteger _zombieCount;
    NSUInteger _zombieSize;
    dispatch_semaphore_t _classArrayLock;// Protect blacklist and zombie cache
    dispatch_semaphore_t _swizzleLock;//Protect swizzle atomic
}

@end

@implementation JJExceptionProxy

+(instancetype)shareExceptionProxy{
    static dispatch_once_t onceToken;
    static id exceptionProxy;
    dispatch_once(&onceToken, ^{
        exceptionProxy = [[self alloc] init];
    });
    return exceptionProxy;
}

- (instancetype)init{
    self = [super init];
    if (self) {
        _blackClassesSet = [NSHashTable hashTableWithOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality];
        _classArrayLock = dispatch_semaphore_create(1);
        _swizzleLock = dispatch_semaphore_create(1);
    }
    return self;
}

- (void)handleCrashException:(NSString *)exceptionMessage exceptionCategory:(JJExceptionGuardCategory)exceptionCategory extraInfo:(NSDictionary *)info{
    if (!exceptionMessage) return;
    static pthread_key_t reportingKey;
    static dispatch_once_t onceToken;
    static int keyError;
    dispatch_once(&onceToken, ^{ keyError = pthread_key_create(&reportingKey, NULL); });
    if (keyError || pthread_getspecific(reportingKey)) return;
    if (pthread_setspecific(reportingKey, (void *)1) != 0) return;
    @try {
        NSArray *callStack = [NSThread callStackSymbols];
        NSString *exceptionResult = [NSString stringWithFormat:@"%lu\n%lu\n%@\n%@",
                                     (unsigned long)get_load_address(), (unsigned long)get_slide_address(),
                                     exceptionMessage, callStack];
        id<JJExceptionHandle> delegate = self.delegate;
        // Prefer the category-aware callback; deliver each event only once.
        if ([delegate respondsToSelector:@selector(handleCrashException:exceptionCategory:extraInfo:)]) {
            [delegate handleCrashException:exceptionResult exceptionCategory:exceptionCategory extraInfo:info];
        } else if ([delegate respondsToSelector:@selector(handleCrashException:extraInfo:)]) {
            [delegate handleCrashException:exceptionResult extraInfo:info];
        }
#ifdef DEBUG
        NSLog(@"JJException category:%ld message:%@ extra:%@ stack:%@",
              (long)exceptionCategory, exceptionMessage, info, callStack);
#endif
    } @catch (NSException *reportingException) {
        // Reporting must not escape into the operation it was meant to protect.
        // Do not report this exception through the same delegate.
    } @finally {
        pthread_setspecific(reportingKey, NULL);
    }
#ifdef DEBUG
    if (self.exceptionWhenTerminate) NSAssert(NO, @"JJException detected an invalid operation");
#endif
}

- (void)handleCrashException:(NSString *)exceptionMessage extraInfo:(nullable NSDictionary *)info{
    [self handleCrashException:exceptionMessage exceptionCategory:JJExceptionGuardNone extraInfo:info];
}

- (void)setIsProtectException:(BOOL)isProtectException{
    dispatch_semaphore_wait(_swizzleLock, DISPATCH_TIME_FOREVER);
    if (_isProtectException != isProtectException) {
        _isProtectException = isProtectException;
        
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wundeclared-selector"
        
        if(self.exceptionGuardCategory & JJExceptionGuardArrayContainer){
            [NSArray performSelector:@selector(jj_swizzleNSArray)];
            [NSMutableArray performSelector:@selector(jj_swizzleNSMutableArray)];
            [NSSet performSelector:@selector(jj_swizzleNSSet)];
            [NSMutableSet performSelector:@selector(jj_swizzleNSMutableSet)];
        }
        if(self.exceptionGuardCategory & JJExceptionGuardDictionaryContainer){
            [NSDictionary performSelector:@selector(jj_swizzleNSDictionary)];
            [NSMutableDictionary performSelector:@selector(jj_swizzleNSMutableDictionary)];
        }
        if(self.exceptionGuardCategory & JJExceptionGuardUnrecognizedSelector){
            [NSObject performSelector:@selector(jj_swizzleUnrecognizedSelector)];
        }
        
        if (self.exceptionGuardCategory & JJExceptionGuardZombie) {
            [NSObject performSelector:@selector(jj_swizzleZombie)];
        }
        
        if (self.exceptionGuardCategory & JJExceptionGuardKVOCrash) {
            [NSObject performSelector:@selector(jj_swizzleKVOCrash)];
        }
        
        if (self.exceptionGuardCategory & JJExceptionGuardNSTimer) {
            [NSTimer performSelector:@selector(jj_swizzleNSTimer)];
        }
        
        if (self.exceptionGuardCategory & JJExceptionGuardNSNotificationCenter) {
            [NSNotificationCenter performSelector:@selector(jj_swizzleNSNotificationCenter)];
        }
        
        if (self.exceptionGuardCategory & JJExceptionGuardNSStringContainer) {
            [NSString performSelector:@selector(jj_swizzleNSString)];
            [NSMutableString performSelector:@selector(jj_swizzleNSMutableString)];
            [NSAttributedString performSelector:@selector(jj_swizzleNSAttributedString)];
            [NSMutableAttributedString performSelector:@selector(jj_swizzleNSMutableAttributedString)];
        }
        #pragma clang diagnostic pop
    }
    dispatch_semaphore_signal(_swizzleLock);
}

- (void)setExceptionGuardCategory:(JJExceptionGuardCategory)exceptionGuardCategory{
    if (_exceptionGuardCategory != exceptionGuardCategory) {
        _exceptionGuardCategory = exceptionGuardCategory;
    }
}



- (void)addZombieObjectArray:(NSArray*)objects {
    // Validate outside the lock. Opaque pointer identity avoids invoking
    // custom class hash/isEqual implementations from the dealloc hook.
    for (id object in objects) {
        if (!object_isClass(object)) continue;
        dispatch_semaphore_wait(_classArrayLock, DISPATCH_TIME_FOREVER);
        [_blackClassesSet addObject:object];
        dispatch_semaphore_signal(_classArrayLock);
    }
}

- (BOOL)isZombieClass:(Class)cls {
    dispatch_semaphore_wait(_classArrayLock, DISPATCH_TIME_FOREVER);
    BOOL contains = [_blackClassesSet containsObject:cls];
    dispatch_semaphore_signal(_classArrayLock);
    return contains;
}

- (void)cacheZombie:(void *)pointer size:(size_t)size {
    if (!pointer) return;
    JJZombieRecord *record = size <= JJZombieCacheLimit - sizeof(JJZombieRecord) ? malloc(sizeof(*record)) : NULL;
    if (!record) { free(pointer); return; }
    *record = (JJZombieRecord){pointer, size + sizeof(*record), NULL};
    dispatch_semaphore_wait(_classArrayLock, DISPATCH_TIME_FOREVER);
    while (_zombieHead && _zombieSize > JJZombieCacheLimit - record->size) {
        JJZombieRecord *old = _zombieHead;
        _zombieHead = old->next;
        _zombieSize -= old->size;
        --_zombieCount;
        free(old->pointer);
        free(old);
    }
    if (!_zombieHead) _zombieTail = NULL;
    if (_zombieTail) _zombieTail->next = record;
    else _zombieHead = record;
    _zombieTail = record;
    _zombieSize += record->size;
    ++_zombieCount;
    dispatch_semaphore_signal(_classArrayLock);
}

- (NSUInteger)currentZombieCount {
    dispatch_semaphore_wait(_classArrayLock, DISPATCH_TIME_FOREVER);
    NSUInteger count = _zombieCount;
    dispatch_semaphore_signal(_classArrayLock);
    return count;
}

- (NSUInteger)currentZombieSize {
    dispatch_semaphore_wait(_classArrayLock, DISPATCH_TIME_FOREVER);
    NSUInteger size = _zombieSize;
    dispatch_semaphore_signal(_classArrayLock);
    return size;
}

- (void)dealloc {
    while (_zombieHead) {
        JJZombieRecord *old = _zombieHead;
        _zombieHead = old->next;
        free(old->pointer);
        free(old);
    }
}

@end
