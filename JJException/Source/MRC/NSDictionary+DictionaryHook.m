//
//  NSDictionary+DictionaryHook.m
//  JJException
//
//  Created by Jezz on 2018/7/15.
//  Copyright © 2018年 Jezz. All rights reserved.
//

#import "NSDictionary+DictionaryHook.h"
#import "NSObject+SwizzleHook.h"
#import "JJExceptionProxy.h"
#import "JJExceptionMacros.h"

JJSYNTH_DUMMY_CLASS(NSDictionary_DictionaryHook)

@implementation NSDictionary (DictionaryHook)

+ (void)jj_swizzleNSDictionary{
    [NSDictionary jj_swizzleClassMethod:@selector(dictionaryWithObject:forKey:) withSwizzleMethod:@selector(hookDictionaryWithObject:forKey:)];
    [NSDictionary jj_swizzleClassMethod:@selector(dictionaryWithObjects:forKeys:count:) withSwizzleMethod:@selector(hookDictionaryWithObjects:forKeys:count:)];
}

+ (instancetype) hookDictionaryWithObject:(id)object forKey:(id)key
{
    if (object && key) {
        return [self hookDictionaryWithObject:object forKey:key];
    }
    handleCrashException(JJExceptionGuardDictionaryContainer,[NSString stringWithFormat:@"NSDictionary dictionaryWithObject invalid object:%@ and key:%@",object,key]);
    return nil;
}
+ (instancetype) hookDictionaryWithObjects:(const id [])objects forKeys:(const id [])keys count:(NSUInteger)cnt
{
    if (cnt == 0) return [self hookDictionaryWithObjects:objects forKeys:keys count:cnt];
    if (!objects || !keys || cnt > SIZE_MAX / sizeof(id)) {
        handleCrashException(JJExceptionGuardDictionaryContainer, @"NSDictionary invalid buffers or count");
        return nil;
    }
    NSUInteger validCount = 0;
    for (NSUInteger i = 0; i < cnt; ++i) if (keys[i] && objects[i]) ++validCount;
    if (validCount == cnt) return [self hookDictionaryWithObjects:objects forKeys:keys count:cnt];

    id *filteredKeys = validCount ? malloc(validCount * sizeof(id)) : NULL;
    id *filteredObjects = validCount ? malloc(validCount * sizeof(id)) : NULL;
    if (validCount && (!filteredKeys || !filteredObjects)) {
        free(filteredKeys);
        free(filteredObjects);
        handleCrashException(JJExceptionGuardDictionaryContainer, @"NSDictionary could not allocate filtered buffers");
        return nil;
    }
    @try {
        NSUInteger index = 0;
        for (NSUInteger i = 0; i < cnt; ++i) {
            if (keys[i] && objects[i]) {
                filteredKeys[index] = keys[i];
                filteredObjects[index++] = objects[i];
            }
        }
        handleCrashException(JJExceptionGuardDictionaryContainer, @"NSDictionary ignored nil keys or objects");
        return [self hookDictionaryWithObjects:filteredObjects forKeys:filteredKeys count:validCount];
    } @finally {
        free(filteredKeys);
        free(filteredObjects);
    }
}

@end
