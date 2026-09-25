#import "DataPaths.h"

#if PRIMEDIT_DEBUG

NSString *const kPDDataPathOperation = @"op";
NSString *const kPDDataPathExpected = @"expected";
NSString *const kPDDataPathHits = @"hits";
NSString *const kPDDataPathMisses = @"misses";
NSString *const kPDDataPathDiscovered = @"discovered";
NSString *const kPDDataPathLastResolved = @"lastResolved";
NSString *const kPDDataPathSeen = @"seen";
NSString *const kPDDataPathFailedJSON = @"failedJSON";

// Bounds that keep the search cheap even on a large response.
static const NSInteger kPDMaxVisited = 6000; // total nodes inspected
static const NSInteger kPDMaxDepth = 9;      // key-path depth
static const NSUInteger kPDMaxArrayElements = 6; // array elements descended into

@implementation PDDataPathTracker {
    dispatch_queue_t _queue;             // serializes all access to the stores
    NSMutableArray<NSString *> *_order;  // operation names, in display order
    NSMutableDictionary<NSString *, NSMutableDictionary *> *_records;
}

+ (instancetype)shared {
    static PDDataPathTracker *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[PDDataPathTracker alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.primetweak.primedit.datapaths", DISPATCH_QUEUE_SERIAL);
        _order = [NSMutableArray array];
        _records = [NSMutableDictionary dictionary];

        // Every known address is listed before any traffic; keep in sync with Tweak.xm.
        [self seedOperation:@"HomeFeedSdui" expected:@"data.homeV3.elements.edges"];
        [self seedOperation:@"PopularFeedSdui" expected:@"data.popularV3.elements.edges"];
        [self seedOperation:@"FeedPostDetailsByIds" expected:@"data.postsInfoByIds"];
        [self seedOperation:@"PostInfoById" expected:@"data.postInfoById.commentForest.trees"];
        [self seedOperation:@"PdpCommentsAds" expected:@"data.*.pdpCommentsAds"];
    }
    return self;
}

// Runs on _queue, or from init before the tracker is shared.
- (void)seedOperation:(NSString *)op expected:(NSString *)expected {
    if (_records[op]) {
        _records[op][kPDDataPathExpected] = expected;
        return;
    }
    [_order addObject:op];
    _records[op] = [@{
        kPDDataPathOperation : op,
        kPDDataPathExpected : expected,
        kPDDataPathHits : @0,
        kPDDataPathMisses : @0,
        kPDDataPathLastResolved : @NO,
        kPDDataPathSeen : @NO,
    } mutableCopy];
}

- (void)recordOperation:(NSString *)operation
           expectedPath:(NSString *)expectedPath
               resolved:(BOOL)resolved
                   json:(id)json
              shape:(PDDataShape)shape {
    if (operation.length == 0) return;

    __block BOOL needsDiscovery = NO;
    dispatch_sync(_queue, ^{
        NSMutableDictionary *record = _records[operation];
        if (record) {
            // Stats first, so the address no longer reads "not seen".
            record[kPDDataPathSeen] = @YES;
            record[kPDDataPathLastResolved] = @(resolved);

            if (resolved) {
                record[kPDDataPathHits] = @([record[kPDDataPathHits] integerValue] + 1);
            } else {
                record[kPDDataPathMisses] = @([record[kPDDataPathMisses] integerValue] + 1);
                // A miss without a known new address triggers the search.
                if (!record[kPDDataPathDiscovered]) {
                    needsDiscovery = YES;
                }
            }
        }
    });

    if (!needsDiscovery) return;

    // The search runs outside the queue.
    NSString *discovered = [[self class] discoverPathForShape:shape in:json];

    dispatch_sync(_queue, ^{
        NSMutableDictionary *record = _records[operation];
        // Re-check: another thread may have filled it in the meantime.
        if (record && !record[kPDDataPathDiscovered]) {
            if (discovered.length) {
                record[kPDDataPathDiscovered] = discovered;
            } else {
                // Nothing found: the response is kept so it can be copied from the report.
                NSData *jsonData = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:nil];
                if (jsonData) {
                    record[kPDDataPathFailedJSON] = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
                }
            }
        }
    });
}

- (NSArray<NSDictionary *> *)snapshot {
    __block NSArray *result;
    dispatch_sync(_queue, ^{
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:_order.count];
        for (NSString *op in _order) {
            // Values are immutable, so copying each record gives a stable view.
            [out addObject:[_records[op] copy]];
        }
        result = out;
    });
    return result;
}

- (void)reset {
    dispatch_sync(_queue, ^{
        for (NSString *op in _order) {
            NSMutableDictionary *record = _records[op];
            record[kPDDataPathHits] = @0;
            record[kPDDataPathMisses] = @0;
            record[kPDDataPathLastResolved] = @NO;
            record[kPDDataPathSeen] = @NO;
            [record removeObjectForKey:kPDDataPathDiscovered];
            [record removeObjectForKey:kPDDataPathFailedJSON];
        }
    });
}

#pragma mark - Discovery

// Whether `value` has the given shape.
+ (BOOL)value:(id)value matchesShape:(PDDataShape)shape {
    switch (shape) {
        case PDDataShapeEdges:
        case PDDataShapeTrees: {
            if (![value isKindOfClass:NSArray.class]) return NO;
            for (id element in (NSArray *)value) {
                if (![element isKindOfClass:NSDictionary.class]) continue;
                if (((NSDictionary *)element)[@"node"]) return YES;
            }
            return NO;
        }
        case PDDataShapeNodeArray: {
            if (![value isKindOfClass:NSArray.class]) return NO;
            for (id element in (NSArray *)value) {
                if (![element isKindOfClass:NSDictionary.class]) continue;
                if (((NSDictionary *)element)[@"__typename"]) return YES;
            }
            return NO;
        }
        case PDDataShapeCommentsAds:
            return [value isKindOfClass:NSArray.class];
    }
    return NO;
}

// The key a Reddit rename usually keeps (its parents change); matching it first
// gives an address that can replace the old one as is.
+ (NSString *)preferredKeyForShape:(PDDataShape)shape {
    switch (shape) {
        case PDDataShapeEdges:       return @"edges";
        case PDDataShapeTrees:       return @"trees";
        case PDDataShapeNodeArray:   return @"postsInfoByIds";
        case PDDataShapeCommentsAds: return @"pdpCommentsAds";
    }
    return nil;
}

+ (NSString *)discoverPathForShape:(PDDataShape)shape in:(id)json {
    if (![json isKindOfClass:NSDictionary.class] && ![json isKindOfClass:NSArray.class]) {
        return nil;
    }
    NSString *preferredKey = [self preferredKeyForShape:shape];

    // By key first, the value checked against the expected shape.
    if (preferredKey) {
        NSString *byKey = [self breadthFirstPathIn:json
                                           testing:^BOOL(NSString *key, id value) {
                                               return [key isEqualToString:preferredKey] &&
                                                      [self value:value matchesShape:shape];
                                           }];
        if (byKey) return byKey;
    }

    // Then by shape alone, for when the key itself was renamed.
    return [self breadthFirstPathIn:json
                            testing:^BOOL(NSString *key, id value) {
                                return [self value:value matchesShape:shape];
                            }];
}

// Breadth-first search for the shallowest key path whose (key, value) passes
// `test`; dictionary children read `.key` and array elements `[i]`.
+ (NSString *)breadthFirstPathIn:(id)root testing:(BOOL (^)(NSString *key, id value))test {
    // Each queue entry: @[ key-or-NSNull, value, pathString ].
    NSMutableArray *queue = [NSMutableArray array];
    [queue addObject:@[ [NSNull null], root, @"" ]];
    NSInteger visited = 0;

    while (queue.count) {
        NSArray *entry = queue.firstObject;
        [queue removeObjectAtIndex:0];
        id key = entry[0];
        id value = entry[1];
        NSString *path = entry[2];

        if (++visited > kPDMaxVisited) break;

        // Skip the synthetic root entry; only test real (key, value) pairs.
        if (path.length && test([key isKindOfClass:NSString.class] ? key : @"", value)) {
            return path;
        }

        if (path.length && [self depthOfPath:path] >= kPDMaxDepth) continue;

        if ([value isKindOfClass:NSDictionary.class]) {
            [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id childKey, id childValue, BOOL *stop) {
                if (![childKey isKindOfClass:NSString.class]) return;
                NSString *childPath = path.length
                                          ? [NSString stringWithFormat:@"%@.%@", path, childKey]
                                          : (NSString *)childKey;
                [queue addObject:@[ childKey, childValue ?: [NSNull null], childPath ]];
            }];
        } else if ([value isKindOfClass:NSArray.class]) {
            NSArray *array = (NSArray *)value;
            NSUInteger limit = MIN(array.count, kPDMaxArrayElements);
            for (NSUInteger i = 0; i < limit; i++) {
                NSString *childPath = [NSString stringWithFormat:@"%@[%lu]", path, (unsigned long)i];
                [queue addObject:@[ [NSNull null], array[i] ?: [NSNull null], childPath ]];
            }
        }
    }
    return nil;
}

+ (NSInteger)depthOfPath:(NSString *)path {
    if (path.length == 0) return 0;
    NSInteger depth = 1;
    NSUInteger length = path.length;
    for (NSUInteger i = 0; i < length; i++) {
        unichar c = [path characterAtIndex:i];
        if (c == '.' || c == '[') depth++;
    }
    return depth;
}

@end

#endif // PRIMEDIT_DEBUG
