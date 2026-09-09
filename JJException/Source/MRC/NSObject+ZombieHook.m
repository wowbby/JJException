//
//  NSObject+Zombie.m
//  JJException
//
//  Created by Jezz on 2018/7/26.
//  Copyright © 2018年 Jezz. All rights reserved.
//

#import "NSObject+ZombieHook.h"
#import "NSObject+SwizzleHook.h"
#import <objc/runtime.h>
#import "JJExceptionProxy.h"
#import <malloc/malloc.h>


@interface ZombieSelectorHandle : NSObject

@property(nonatomic,readwrite,assign)id fromObject;

@end


@implementation ZombieSelectorHandle

void unrecognizedSelectorZombie(ZombieSelectorHandle* self, SEL _cmd){
    
}

@end

@interface JJZombieSub : NSObject

@end

@implementation JJZombieSub

// Cached instances are owned by the raw-pointer queue, never by ARC/MRC clients.
- (id)retain { return self; }
- (oneway void)release {}
- (id)autorelease { return self; }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-missing-super-calls"
- (void)dealloc {} // Only the cache may free this already-destructed allocation.
#pragma clang diagnostic pop

- (id)forwardingTargetForSelector:(SEL)selector{
    NSMethodSignature* sign = [self methodSignatureForSelector:selector];
    if (!sign) {
        id stub = [[ZombieSelectorHandle new] autorelease];
        [stub setFromObject:self];
        class_addMethod([stub class], selector, (IMP)unrecognizedSelectorZombie, "v@:");
        return stub;
    }
    return [super forwardingTargetForSelector:selector];
}

@end

@implementation NSObject (ZombieHook)

+ (void)jj_swizzleZombie{
    [self jj_swizzleInstanceMethod:@selector(dealloc) withSwizzleMethod:@selector(hookDealloc)];
}

- (void)hookDealloc{
    Class currentClass = object_getClass(self);
    JJExceptionProxy *proxy = [JJExceptionProxy shareExceptionProxy];
    if (![proxy isZombieClass:currentClass]) {
        [self hookDealloc];
        return;
    }
    size_t size = malloc_size(self);
    objc_destructInstance(self);
    object_setClass(self, [JJZombieSub class]);
    [proxy cacheZombie:self size:size];
}

@end
