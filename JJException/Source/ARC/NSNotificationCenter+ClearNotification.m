//
//  NSNotificationCenter+ClearNotification.m
//  JJException
//
//  Created by Jezz on 2018/9/6.
//  Copyright © 2018年 Jezz. All rights reserved.
//

#import "NSNotificationCenter+ClearNotification.h"
#import "NSObject+SwizzleHook.h"
#import "NSObject+DeallocBlock.h"
#import "JJExceptionMacros.h"
#import <objc/runtime.h>

JJSYNTH_DUMMY_CLASS(NSNotificationCenter_ClearNotification)

static char jjNotificationCentersKey;

@implementation NSNotificationCenter (ClearNotification)

+ (void)jj_swizzleNSNotificationCenter{
    [self jj_swizzleInstanceMethod:@selector(addObserver:selector:name:object:) withSwizzledBlock:^id(JJSwizzleObject *swizzleInfo) {
        return ^(__unsafe_unretained id self,id observer,SEL aSelector,NSString* aName,id anObject){
            [self processAddObserver:observer selector:aSelector name:aName object:anObject swizzleInfo:swizzleInfo];
        };
    }];
}

- (void)processAddObserver:(id)observer selector:(SEL)aSelector name:(NSNotificationName)aName object:(id)anObject swizzleInfo:(JJSwizzleObject*)swizzleInfo{
    
    if (!observer) {
        return;
    }
    
    // Selector observers are cleaned up by Foundation on these systems.
    if (@available(iOS 9.0, macOS 10.11, watchOS 2.0, tvOS 9.0, *)) {
    } else {
        [self jj_registerLegacyObserverCleanup:observer];
    }
    
    void(*originIMP)(__unsafe_unretained id,SEL,id,SEL,NSString*,id);
    originIMP = (__typeof(originIMP))[swizzleInfo getOriginalImplementation];
    if (originIMP != NULL) {
        originIMP(self,swizzleInfo.selector,observer,aSelector,aName,anObject);
    }
}

// Separate the legacy path so it can be regression-tested on a current runtime.
- (void)jj_registerLegacyObserverCleanup:(id)observer {
    if (![observer isKindOfClass:NSObject.class]) return;
    @synchronized (observer) {
        NSHashTable *centers = objc_getAssociatedObject(observer, &jjNotificationCentersKey);
        if (!centers) {
            centers = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
            objc_setAssociatedObject(observer, &jjNotificationCentersKey, centers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            __unsafe_unretained id unsafeObserver = observer;
            [observer jj_deallocBlock:^{
                for (NSNotificationCenter *center in centers.allObjects) {
                    [center removeObserver:unsafeObserver];
                }
            }];
        }
        [centers addObject:self];
    }
}

@end
