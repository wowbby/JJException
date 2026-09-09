#import <Foundation/Foundation.h>
#import "JJException.h"
#include <stdio.h>
#include <pthread.h>

#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); exit(2); } } while (0)

@interface KVOProbe : NSObject
@property(nonatomic, strong) KVOProbe *child;
@property(nonatomic) NSInteger value;
@property(nonatomic) NSInteger notifications;
@property(nonatomic) BOOL removeOnInitial;
@property(nonatomic, strong) NSMutableArray *contexts;
@property(nonatomic, copy) void (^onChange)(id, NSString *);
@end
@implementation KVOProbe
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    self.notifications++;
    if (self.onChange) self.onChange(object, keyPath);
    [self.contexts addObject:[NSValue valueWithPointer:context]];
    if (self.removeOnInitial) {
        self.removeOnInitial = NO;
        [object removeObserver:self forKeyPath:keyPath];
    }
}
@end

static void nested(void) {
    KVOProbe *node = [KVOProbe new], *observer = [KVOProbe new];
    node.child = node;
    [node addObserver:observer forKeyPath:@"child.value" options:0 context:NULL];
    node.value = 1;
    CHECK(observer.notifications == 1);
    [node removeObserver:observer forKeyPath:@"child.value"];
    node.value = 2;
    CHECK(observer.notifications == 1);
    node.child = nil;
}

static void contexts(void) {
    KVOProbe *node = [KVOProbe new], *observer = [KVOProbe new];
    observer.contexts = [NSMutableArray new];
    static char first, second;
    [node addObserver:observer forKeyPath:@"value" options:0 context:&first];
    [node addObserver:observer forKeyPath:@"value" options:0 context:&second];
    node.value = 1;
    CHECK(observer.notifications == 2);
    [node removeObserver:observer forKeyPath:@"value" context:&first];
    [observer.contexts removeAllObjects];
    node.value = 2;
    CHECK(observer.notifications == 3);
    CHECK([[observer.contexts lastObject] pointerValue] == &second);
    [node removeObserver:observer forKeyPath:@"value" context:&second];
}

static dispatch_semaphore_t registrationEntered, registrationAllowed;
static BOOL pauseRegistration;
@interface SlowProbe : KVOProbe
@end
@implementation SlowProbe
+ (BOOL)automaticallyNotifiesObserversForKey:(NSString *)key {
    if (pauseRegistration && [key isEqualToString:@"value"]) {
        pauseRegistration = NO;
        dispatch_semaphore_signal(registrationEntered);
        dispatch_semaphore_wait(registrationAllowed, DISPATCH_TIME_FOREVER);
    }
    return [super automaticallyNotifiesObserversForKey:key];
}
@end

static void concurrentRemoveDuringAdd(BOOL readd) {
    SlowProbe *node = [SlowProbe new];
    KVOProbe *observer = [KVOProbe new];
    registrationEntered = dispatch_semaphore_create(0);
    registrationAllowed = dispatch_semaphore_create(0);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    pauseRegistration = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        @autoreleasepool {
            [node addObserver:observer forKeyPath:@"value" options:0 context:NULL];
            dispatch_semaphore_signal(done);
        }
    });
    CHECK(dispatch_semaphore_wait(registrationEntered, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
    [node removeObserver:observer forKeyPath:@"value"];
    if (readd) [node addObserver:observer forKeyPath:@"value" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew context:NULL];
    dispatch_semaphore_signal(registrationAllowed);
    CHECK(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
    CHECK(observer.notifications == (readd ? 1 : 0));
    node.value = 1;
    CHECK(observer.notifications == (readd ? 2 : 0));
    [node removeObserver:observer forKeyPath:@"value"];
}

static void invalidRemoval(void) {
    KVOProbe *node = [KVOProbe new], *observer = [KVOProbe new];
    [node removeObserver:observer forKeyPath:@"value"];
    [node addObserver:observer forKeyPath:@"value" options:0 context:NULL];
    [node addObserver:observer forKeyPath:@"value" options:0 context:NULL];
    node.value = 1;
    CHECK(observer.notifications == 1);
    [node removeObserver:observer forKeyPath:@"value"];
    [node removeObserver:observer forKeyPath:@"value"];
    node.value = 2;
    CHECK(observer.notifications == 1);
}

static void initialRemoval(void) {
    KVOProbe *node = [KVOProbe new], *observer = [KVOProbe new];
    observer.removeOnInitial = YES;
    [node addObserver:observer forKeyPath:@"value" options:NSKeyValueObservingOptionInitial context:NULL];
    CHECK(observer.notifications == 1);
    node.value = 1;
    CHECK(observer.notifications == 1);
    [node addObserver:observer forKeyPath:@"value" options:0 context:NULL];
    node.value = 2;
    CHECK(observer.notifications == 2);
    [node removeObserver:observer forKeyPath:@"value"];
}

@interface RemovingObserver : KVOProbe
@property(nonatomic, strong) KVOProbe *observed;
@end
@implementation RemovingObserver
- (void)dealloc {
    [_observed removeObserver:self forKeyPath:@"value"];
}
@end

static void deallocation(void) {
    KVOProbe *node = [KVOProbe new];
    __weak KVOProbe *weakObserver;
    @autoreleasepool {
        RemovingObserver *observer = [RemovingObserver new];
        observer.observed = node;
        weakObserver = observer;
        [node addObserver:observer forKeyPath:@"value" options:0 context:NULL];
    }
    CHECK(weakObserver == nil);
    node.value = 1;
    KVOProbe *observer = [KVOProbe new];
    __weak KVOProbe *weakNode;
    @autoreleasepool {
        KVOProbe *temporary = [KVOProbe new];
        weakNode = temporary;
        [temporary addObserver:observer forKeyPath:@"value" options:0 context:NULL];
    }
    CHECK(weakNode == nil);
}

static void contextlessRemoval(void) {
    KVOProbe *node = [KVOProbe new], *observer = [KVOProbe new];
    static char first, second, wrong;
    observer.contexts = [NSMutableArray new];
    [node addObserver:observer forKeyPath:@"value" options:0 context:&first];
    [node addObserver:observer forKeyPath:@"value" options:0 context:&second];
    [node removeObserver:observer forKeyPath:@"value" context:&wrong];
    [node removeObserver:observer forKeyPath:@"value"];
    node.value = 1;
    CHECK(observer.notifications == 1);
    CHECK([[observer.contexts lastObject] pointerValue] == &first);
    [node removeObserver:observer forKeyPath:@"value"];
    node.value = 2;
    CHECK(observer.notifications == 1);
}

@interface ThrowingProbe : KVOProbe
@property(nonatomic) BOOL failLookup;
@property(nonatomic) NSInteger failedLookups;
@property(nonatomic, copy) void (^onLookupFailure)(id);
@end
@implementation ThrowingProbe
- (id)valueForKey:(NSString *)key {
    if (self.failLookup && [key isEqualToString:@"value"]) {
        self.failedLookups++;
        if (self.onLookupFailure) self.onLookupFailure(self);
        [NSException raise:NSInvalidArgumentException format:@"Intentional Initial lookup failure"];
    }
    return [super valueForKey:key];
}
@end
static void registrationRollback(void) {
    ThrowingProbe *node = [ThrowingProbe new];
    KVOProbe *observer = [KVOProbe new];
    node.failLookup = YES;
    [node addObserver:observer forKeyPath:@"value" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew context:NULL];
    CHECK(node.failedLookups == 1);
    CHECK(observer.notifications == 0);
    node.failLookup = NO;
    [node addObserver:observer forKeyPath:@"value" options:0 context:NULL];
    node.value = 1;
    CHECK(observer.notifications == 1);
    [node removeObserver:observer forKeyPath:@"value"];
    node.value = 2;
    CHECK(observer.notifications == 1);
}

static void initialWorkerRemoval(void) {
    KVOProbe *node = [KVOProbe new], *observer = [KVOProbe new];
    __weak KVOProbe *weakObserver = observer;
    observer.onChange = ^(id object, NSString *key) {
        dispatch_sync(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            [object removeObserver:weakObserver forKeyPath:key];
        });
    };
    [node addObserver:observer forKeyPath:@"value" options:NSKeyValueObservingOptionInitial context:NULL];
    node.value = 1;
    CHECK(observer.notifications == 1);
}

@interface EqualProbe : KVOProbe
@end
@implementation EqualProbe
- (BOOL)isEqual:(id)object { return [object isKindOfClass:[EqualProbe class]]; }
- (NSUInteger)hash { return 1; }
@end
static void pointerIdentity(void) {
    KVOProbe *node = [KVOProbe new];
    EqualProbe *first = [EqualProbe new], *second = [EqualProbe new];
    [node addObserver:first forKeyPath:@"value" options:0 context:NULL];
    [node addObserver:second forKeyPath:@"value" options:0 context:NULL];
    node.value = 1;
    CHECK(first.notifications == 1 && second.notifications == 1);
    [node removeObserver:first forKeyPath:@"value"];
    node.value = 2;
    CHECK(first.notifications == 1 && second.notifications == 2);
    [node removeObserver:second forKeyPath:@"value"];
}

typedef struct {
    __unsafe_unretained KVOProbe *node;
    __unsafe_unretained KVOProbe *observer;
} ChurnContext;

static void *churnWorker(void *argument) {
    ChurnContext *context = argument;
    @autoreleasepool {
        for (int j = 0; j < 200; j++) {
            [context->node addObserver:context->observer forKeyPath:@"value" options:0 context:NULL];
            [context->node removeObserver:context->observer forKeyPath:@"value"];
        }
    }
    return NULL;
}

static void concurrentChurn(void) {
    KVOProbe *node = [KVOProbe new];
    NSMutableArray *observers = [NSMutableArray new];
    pthread_t threads[8];
    ChurnContext contexts[8];
    for (int i = 0; i < 8; i++) [observers addObject:[KVOProbe new]];
    // Explicit pthread handoff avoids a TSan/dispatch_apply block-copy report in
    // the current macOS runtime, while preserving concurrent native KVO calls.
    for (int i = 0; i < 8; i++) {
        contexts[i] = (ChurnContext){node, observers[i]};
        CHECK(pthread_create(&threads[i], NULL, churnWorker, &contexts[i]) == 0);
    }
    for (int i = 0; i < 8; i++) CHECK(pthread_join(threads[i], NULL) == 0);
    node.value = 1;
    for (KVOProbe *observer in observers) CHECK(observer.notifications == 0);
}

static void selfObservation(void) {
    __weak KVOProbe *weakNode;
    @autoreleasepool {
        KVOProbe *node = [KVOProbe new];
        weakNode = node;
        [node addObserver:node forKeyPath:@"value" options:0 context:NULL];
        node.value = 1;
        CHECK(node.notifications == 1);
    }
    CHECK(weakNode == nil);
}

@interface ScalarProbe : NSObject
@property(nonatomic) NSInteger value;
@end
@implementation ScalarProbe
@end
static void inheritedDealloc(void) {
    KVOProbe *observer = [KVOProbe new];
    __weak ScalarProbe *weakNode;
    @autoreleasepool {
        ScalarProbe *node = [ScalarProbe new];
        weakNode = node;
        [node addObserver:observer forKeyPath:@"value" options:0 context:NULL];
        node.value = 1;
        CHECK(observer.notifications == 1);
    }
    CHECK(weakNode == nil);
}

static void failedAddWithReadd(void) {
    ThrowingProbe *node = [ThrowingProbe new];
    KVOProbe *observer = [KVOProbe new];
    __weak KVOProbe *weakObserver = observer;
    node.failLookup = YES;
    node.onLookupFailure = ^(id object) {
        dispatch_sync(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            [object removeObserver:weakObserver forKeyPath:@"value"];
            [object addObserver:weakObserver forKeyPath:@"value" options:0 context:NULL];
        });
    };
    [node addObserver:observer forKeyPath:@"value" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew context:NULL];
    CHECK(node.failedLookups == 1);
    node.failLookup = NO;
    node.value = 1;
    CHECK(observer.notifications == 1);
    [node removeObserver:observer forKeyPath:@"value"];
    node.value = 2;
    CHECK(observer.notifications == 1);
}

// Inject a delay exactly at the native removal boundary, after the guard has
// reserved the relation, without blocking inside Foundation's own KVO locks.
@interface NSObject (NativeKVOBoundary)
- (void)hookRemoveObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath context:(void *)context;
@end
static BOOL pauseRemoval;
static dispatch_semaphore_t removalEntered, removalAllowed;
@interface RemovalGateProbe : KVOProbe
@end
@implementation RemovalGateProbe
- (void)hookRemoveObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath context:(void *)context {
    if (pauseRemoval) {
        pauseRemoval = NO;
        dispatch_semaphore_signal(removalEntered);
        dispatch_semaphore_wait(removalAllowed, DISPATCH_TIME_FOREVER);
    }
    [super hookRemoveObserver:observer forKeyPath:keyPath context:context];
}
@end

static void removalOrdering(BOOL readd) {
    RemovalGateProbe *node = [RemovalGateProbe new];
    KVOProbe *observer = [KVOProbe new];
    observer.contexts = [NSMutableArray new];
    static char first, second;
    [node addObserver:observer forKeyPath:@"value" options:0 context:&first];
    [node addObserver:observer forKeyPath:@"value" options:0 context:&second];
    removalEntered = dispatch_semaphore_create(0);
    removalAllowed = dispatch_semaphore_create(0);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    pauseRemoval = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        @autoreleasepool {
            if (readd) [node removeObserver:observer forKeyPath:@"value" context:&first];
            else [node removeObserver:observer forKeyPath:@"value"];
            dispatch_semaphore_signal(done);
        }
    });
    CHECK(dispatch_semaphore_wait(removalEntered, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
    if (readd) [node addObserver:observer forKeyPath:@"value" options:0 context:&first];
    else [node removeObserver:observer forKeyPath:@"value"];
    dispatch_semaphore_signal(removalAllowed);
    CHECK(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
    if (readd) [node removeObserver:observer forKeyPath:@"value"];
    node.value = 1;
    CHECK(observer.notifications == (readd ? 1 : 0));
    if (readd) CHECK([[observer.contexts lastObject] pointerValue] == &second);
    [node removeObserver:observer forKeyPath:@"value"];
}

static void initialContextOrdering(void) {
    KVOProbe *node = [KVOProbe new], *observer = [KVOProbe new];
    observer.contexts = [NSMutableArray new];
    static char first, second;
    __weak KVOProbe *weakObserver = observer;
    observer.onChange = ^(id object, NSString *key) {
        weakObserver.onChange = nil;
        [object addObserver:weakObserver forKeyPath:key options:0 context:&second];
    };
    [node addObserver:observer forKeyPath:@"value" options:NSKeyValueObservingOptionInitial context:&first];
    [observer.contexts removeAllObjects];
    [node removeObserver:observer forKeyPath:@"value"];
    node.value = 1;
    CHECK(observer.notifications == 2);
    CHECK([[observer.contexts lastObject] pointerValue] == &first);
    [node removeObserver:observer forKeyPath:@"value"];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        [JJException configExceptionCategory:getenv("JJ_TEST_ALL_GUARDS") ? JJExceptionGuardAll : JJExceptionGuardKVOCrash];
        [JJException startGuardException];
        CHECK(argc == 2);
        if (strcmp(argv[1], "nested") == 0) nested();
        else if (strcmp(argv[1], "contexts") == 0) contexts();
        else if (strcmp(argv[1], "concurrent-remove-during-add") == 0) concurrentRemoveDuringAdd(NO);
        else if (strcmp(argv[1], "invalid-removal") == 0) invalidRemoval();
        else if (strcmp(argv[1], "initial-removal") == 0) initialRemoval();
        else if (strcmp(argv[1], "deallocation") == 0) deallocation();
        else if (strcmp(argv[1], "contextless-removal") == 0) contextlessRemoval();
        else if (strcmp(argv[1], "registration-rollback") == 0) registrationRollback();
        else if (strcmp(argv[1], "initial-worker-removal") == 0) initialWorkerRemoval();
        else if (strcmp(argv[1], "pointer-identity") == 0) pointerIdentity();
        else if (strcmp(argv[1], "concurrent-churn") == 0) concurrentChurn();
        else if (strcmp(argv[1], "self-observation") == 0) selfObservation();
        else if (strcmp(argv[1], "pending-readd") == 0) concurrentRemoveDuringAdd(YES);
        else if (strcmp(argv[1], "inherited-dealloc") == 0) inheritedDealloc();
        else if (strcmp(argv[1], "failed-add-readd") == 0) failedAddWithReadd();
        else if (strcmp(argv[1], "readd-context-order") == 0) removalOrdering(YES);
        else if (strcmp(argv[1], "concurrent-contextless-removal") == 0) removalOrdering(NO);
        else if (strcmp(argv[1], "initial-context-order") == 0) initialContextOrdering();
        else return 3;
        printf("PASS %s\n", argv[1]);
    }
}
