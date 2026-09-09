#import <Foundation/Foundation.h>
#import "JJException.h"
#import "JJExceptionProxy.h"
#import "NSObject+SwizzleHook.h"
#include <pthread.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#define CHECK(...) do { if (!(__VA_ARGS__)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #__VA_ARGS__); abort(); } } while (0)

@interface NSNotificationCenter (GuardTestLegacy)
- (void)jj_registerLegacyObserverCleanup:(id)observer;
@end
@interface GuardCenter : NSNotificationCenter
@property NSUInteger removals;
@end
@implementation GuardCenter
- (void)removeObserver:(id)observer { self.removals++; [super removeObserver:observer]; }
@end
@interface GuardObserver : NSObject
@property NSUInteger count;
- (void)receive:(NSNotification *)note;
- (NSInteger)number;
- (void)tick:(NSTimer *)timer;
@end
@implementation GuardObserver
- (void)receive:(NSNotification *)note { self.count++; }
- (NSInteger)number { return 7; }
- (void)tick:(NSTimer *)timer { self.count++; }
@end
@interface GuardChild : GuardObserver
@end
@implementation GuardChild
@end

@interface GuardZombie : NSObject { char _payload[4096]; }
@end
@implementation GuardZombie
@end

@interface GuardReporter : NSObject <JJExceptionHandle>
@property NSUInteger legacyCount;
@property NSUInteger count;
@property BOOL reenter;
@property BOOL throwsException;
@end
@implementation GuardReporter
- (void)handleCrashException:(NSString *)message extraInfo:(NSDictionary *)info { self.legacyCount++; }
- (void)handleCrashException:(NSString *)message exceptionCategory:(JJExceptionGuardCategory)category extraInfo:(NSDictionary *)info {
    self.count++;
    CHECK(self.count < 10);
    if (self.reenter) [[NSArray array] objectAtIndex:0];
    if (self.throwsException) [NSException raise:@"ReporterFailure" format:@"test"];
}
@end

static void *collections(void *unused) {
    @autoreleasepool {
        NSUInteger count = 100000;
        id __unsafe_unretained *objects = (id __unsafe_unretained *)calloc(count, sizeof(id));
        CHECK(objects);
        for (NSUInteger i = 0; i < count; i++) objects[i] = @"value";
        CHECK([NSArray arrayWithObjects:objects count:count].count == count);
        CHECK([NSDictionary dictionaryWithObjects:objects forKeys:objects count:count].count == 1);
        objects[count / 2] = nil;
        CHECK([NSArray arrayWithObjects:objects count:count].count == count - 1);
        CHECK([NSDictionary dictionaryWithObjects:objects forKeys:objects count:count].count == 1);
        free(objects);
        id values[] = {@"a", nil, @"c"};
        id keys[] = {@"one", @"two", nil};
        CHECK([[NSArray arrayWithObjects:values count:3] isEqual:@[@"a", @"c"]]);
        CHECK([[NSDictionary dictionaryWithObjects:values forKeys:keys count:3] isEqual:@{@"one": @"a"}]);
        CHECK([NSArray arrayWithObjects:NULL count:0].count == 0);
        CHECK([NSArray arrayWithObjects:NULL count:1] == nil);
        CHECK([NSDictionary dictionaryWithObjects:NULL forKeys:NULL count:1] == nil);
    }
    return NULL;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        CHECK(argc == 2);
        NSString *which = @(argv[1]);
        [JJException configExceptionCategory:JJExceptionGuardArrayContainer | JJExceptionGuardDictionaryContainer | JJExceptionGuardNSStringContainer];
        if ([which isEqual:@"zombie-cache"]) [JJException configExceptionCategory:JJExceptionGuardZombie];
        if ([which isEqual:@"notifications"]) [JJException configExceptionCategory:JJExceptionGuardNSNotificationCenter];
        if ([which isEqual:@"timers"]) [JJException configExceptionCategory:JJExceptionGuardNSTimer];
        [JJException startGuardException];
        if ([which isEqual:@"collections"]) {
            pthread_attr_t attr;
            CHECK(pthread_attr_init(&attr) == 0);
            CHECK(pthread_attr_setstacksize(&attr, 512 * 1024) == 0);
            pthread_t thread;
            CHECK(pthread_create(&thread, &attr, collections, NULL) == 0);
            CHECK(pthread_join(thread, NULL) == 0);
            pthread_attr_destroy(&attr);
        } else if ([which isEqual:@"ranges"]) {
            NSRange overflow = NSMakeRange(NSUIntegerMax, 2);
            NSArray *values = [NSArray arrayWithObjects:@1, @2, nil];
            CHECK([values subarrayWithRange:overflow] == nil);
            CHECK([@"abc" substringWithRange:overflow] == nil);
            NSMutableString *string = [@"abc" mutableCopy];
            [string deleteCharactersInRange:overflow];
            CHECK([string isEqual:@"abc"]);
            NSMutableArray *array = [@[@1, @2] mutableCopy];
            [array removeObjectsInRange:overflow];
            CHECK(array.count == 2);
            CHECK([[array subarrayWithRange:NSMakeRange(2, 0)] isEqual:@[]]);
            CHECK([[@"abc" substringWithRange:NSMakeRange(1, 2)] isEqual:@"bc"]);
            NSAttributedString *attr = [[NSAttributedString alloc] initWithString:@"abc"];
            CHECK([attr attributedSubstringFromRange:overflow] == nil);
        } else if ([which isEqual:@"nil-block"]) {
            NSAttributedString *attr = [[NSAttributedString alloc] initWithString:@"abc"];
            [attr enumerateAttributesInRange:NSMakeRange(0, 3) options:0 usingBlock:nil];
            [attr enumerateAttribute:@"key" inRange:NSMakeRange(0, 3) options:0 usingBlock:nil];
            __block NSUInteger visited = 0;
            [attr enumerateAttributesInRange:NSMakeRange(0, 3) options:0 usingBlock:^(NSDictionary *d, NSRange r, BOOL *stop) { visited += r.length; }];
            CHECK(visited == 3);
        } else if ([which isEqual:@"reporting"]) {
            GuardReporter *reporter = [GuardReporter new];
            [JJException registerExceptionHandle:reporter];
            reporter.reenter = YES;
            CHECK([[NSArray array] objectAtIndex:0] == nil);
            CHECK(reporter.count == 1 && reporter.legacyCount == 0);
            reporter.reenter = NO;
            reporter.throwsException = YES;
            CHECK([[NSArray array] objectAtIndex:0] == nil);
            CHECK(reporter.count == 2);
            reporter.throwsException = NO;
            CHECK([[NSArray array] objectAtIndex:0] == nil);
            CHECK(reporter.count == 3);
        } else if ([which isEqual:@"zombie-cache"]) {
            [JJException addZombieObjectArray:@[[GuardZombie class]]];
            @autoreleasepool {
                __attribute__((objc_precise_lifetime)) id a = [GuardZombie new];
                __attribute__((objc_precise_lifetime)) id b = [GuardZombie new];
                CHECK(a != b);
            }
            CHECK([JJExceptionProxy shareExceptionProxy].currentZombieCount == 2);
            for (NSUInteger i = 0; i < 3000; i++) {
                @autoreleasepool { __attribute__((objc_precise_lifetime)) id object = [GuardZombie new]; CHECK(object != nil); }
            }
            CHECK([JJExceptionProxy shareExceptionProxy].currentZombieCount > 2);
            CHECK([JJExceptionProxy shareExceptionProxy].currentZombieCount < 3002);
            CHECK([JJExceptionProxy shareExceptionProxy].currentZombieSize <= 5 * 1024 * 1024);
        } else if ([which isEqual:@"notifications"]) {
            GuardCenter *center = [GuardCenter new];
            GuardCenter *other = [GuardCenter new];
            @autoreleasepool {
                GuardObserver *observer = [GuardObserver new];
                for (NSUInteger i = 0; i < 100; i++) {
                    [center addObserver:observer selector:@selector(receive:) name:@"test" object:nil];
                    [center postNotificationName:@"test" object:nil];
                    [center removeObserver:observer];
                }
                CHECK(observer.count == 100);
                for (NSUInteger i = 0; i < 100; i++) [center jj_registerLegacyObserverCleanup:observer];
                [other jj_registerLegacyObserverCleanup:observer];
                [center addObserver:observer selector:@selector(receive:) name:@"test" object:nil];
                CHECK(center.removals == 100 && other.removals == 0);
            }
            CHECK(center.removals == 101 && other.removals == 1);
            [center postNotificationName:@"test" object:nil];
        } else if ([which isEqual:@"swizzle"]) {
            [GuardChild jj_swizzleInstanceMethod:@selector(number) withSwizzledBlock:^id(JJSwizzleObject *info) {
                NSInteger (*original)(id, SEL) = (void *)[info getOriginalImplementation];
                // A factory can access the original even before the replacement is installed.
                CHECK(original([GuardChild new], @selector(number)) == 7);
                return ^NSInteger(id object) { return original(object, @selector(number)) + 1; };
            }];
            CHECK([[GuardChild new] number] == 8);
            CHECK([[GuardObserver new] number] == 7);
            __block BOOL called = NO;
            [GuardChild jj_swizzleInstanceMethod:NSSelectorFromString(@"absent") withSwizzledBlock:^id(JJSwizzleObject *info) { called = YES; return nil; }];
            CHECK(!called);
        } else if ([which isEqual:@"timers"]) {
            GuardObserver *target = [GuardObserver new];
            NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:60 target:target selector:@selector(tick:) userInfo:nil repeats:YES];
            [timer fire];
            CHECK(target.count == 1 && timer.isValid);
            [timer invalidate];
            timer = [NSTimer scheduledTimerWithTimeInterval:60 target:target selector:NSSelectorFromString(@"absent:") userInfo:nil repeats:YES];
            [timer fire];
            CHECK(!timer.isValid);
            @autoreleasepool {
                GuardObserver *temporary = [GuardObserver new];
                timer = [NSTimer scheduledTimerWithTimeInterval:60 target:temporary selector:@selector(tick:) userInfo:nil repeats:YES];
            }
            [timer fire];
            CHECK(!timer.isValid);
        } else { CHECK(NO); }
        printf("PASS %s\n", argv[1]);
    }
}
