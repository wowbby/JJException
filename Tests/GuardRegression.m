#import <Foundation/Foundation.h>
#import "JJException.h"
#include <pthread.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#define CHECK(...) do { if (!(__VA_ARGS__)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #__VA_ARGS__); abort(); } } while (0)

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
        } else { CHECK(NO); }
        printf("PASS %s\n", argv[1]);
    }
}
