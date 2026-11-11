#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// Reddit 2026.42+ inserts ads client-side via FeedElementTransformer classes,
// after the GraphQL response is parsed into native objects. PrimeDit's JSON
// filter can't catch these. This file neuters the client-side ad pipeline.

static BOOL PDTPromotedFilterEnabled(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    return [d objectForKey:@"kPrimeDitPromoted"] ? [d boolForKey:@"kPrimeDitPromoted"] : YES;
}

static void PDTNullifyMethodsMatching(Class cls, NSArray<NSString *> *keywords) {
    if (!cls) return;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *name = NSStringFromSelector(sel);
        BOOL match = NO;
        for (NSString *kw in keywords) {
            if ([name containsString:kw]) { match = YES; break; }
        }
        if (!match) continue;
        IMP origImp = method_getImplementation(methods[i]);
        method_setImplementation(methods[i], imp_implementationWithBlock(^id(id self) {
            if (PDTPromotedFilterEnabled()) return nil;
            return ((id(*)(id,SEL))origImp)(self, sel);
        }));
    }
    free(methods);
}

__attribute__((constructor(200))) static void PDTAdKillInit(void) {
    @autoreleasepool {
        // Feed-level ad element converter → ad posts never become feed items
        PDTNullifyMethodsMatching(
            objc_getClass("_TtC29RedditAds_FeedComponents_Impl22AdFeedElementConverter"),
            @[@"convert", @"transform", @"element"]);

        // Ad cell group converter → prevents ad cell groups
        PDTNullifyMethodsMatching(
            objc_getClass("_TtC29RedditAds_FeedComponents_Impl24AdCellGroupConverterImpl"),
            @[@"convert", @"cellGroup"]);

        // Ad data provider → prevents ad data fetching
        PDTNullifyMethodsMatching(
            objc_getClass("_TtC12PDP_Ads_Impl22AdLoadDataProviderImpl"),
            @[@"load", @"fetch", @"request", @"provide"]);

        // Conversation ad converter → comment/PDP page ads
        Class convoAd = objc_getClass("_TtC12PDP_Ads_Impl27ConvoAdElementConverterImpl");
        if (!convoAd) convoAd = objc_getClass("_TtC12PDP_Ads_Impl30ConversationAdElementConverter");
        PDTNullifyMethodsMatching(convoAd, @[@"convert", @"element", @"transform"]);

        // Ad feed element service factory → prevents ad service creation
        PDTNullifyMethodsMatching(
            objc_getClass("_TtC29RedditAds_FeedComponents_Impl31AdFeedElementServiceFactoryImpl"),
            @[@"make", @"create", @"service"]);

        // PDP ads factory → prevents post detail page ads
        PDTNullifyMethodsMatching(
            objc_getClass("_TtC12PDP_Ads_Impl21PDPFeedAdsFactoryImpl"),
            @[@"make", @"create", @"ads"]);

        // Ad element converter factory → prevents converter creation
        PDTNullifyMethodsMatching(
            objc_getClass("_TtC29RedditAds_FeedComponents_Impl33AdFeedElementConverterFactoryImpl"),
            @[@"make", @"create", @"converter"]);

        // ConversationAdElementTransformer → another path for comment ads
        PDTNullifyMethodsMatching(
            objc_getClass("_TtC12PDP_Ads_Impl32ConversationAdElementTransformer"),
            @[@"transform", @"convert", @"element"]);
    }
}
