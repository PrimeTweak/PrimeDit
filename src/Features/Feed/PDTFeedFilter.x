#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#import "PDTPreferences.h"
#import "PDTDataPaths.h"
#import "PDTCompatibility.h"
#import "PDTFilterPrefs.h"
#import "PDTTabs.h"

// GraphQL operations that never carry feed content.
static NSSet<NSString *> *ignoredOperationsSet;

// Feed-unit type matching (recommendation carousels, discovery/trending cards,
// AI answer boxes), with type names as of Reddit 2026.38.
static BOOL PDTTypeNameContainsAny(NSString *typeName, NSArray<NSString *> *needles) {
    for (NSString *needle in needles)
        if ([typeName containsString:needle]) return YES;
    return NO;
}

static PDTCompatOption PDTFeedUnitDropReason(id nodeObj, PrimeDitPrefs prefs) {
    if (![nodeObj isKindOfClass:NSDictionary.class]) return PDTCompatOptionNone;
    NSString *typeName = ((NSDictionary *)nodeObj)[@"__typename"];
    if (![typeName isKindOfClass:NSString.class]) return PDTCompatOptionNone;

    if (prefs.recommendationCarousels &&
            PDTTypeNameContainsAny(typeName, @[ @"CommunityRecommendation", @"RecommendationCarousel",
                                               @"RelatedCommunit", @"CarouselCommunityRecommendations" ]))
        return PDTCompatCommunityRecs;
    if (prefs.extraFeedCards &&
            PDTTypeNameContainsAny(typeName, @[ @"RelatedPostsFeedUnit", @"SearchTrendingFeedUnit",
                                               @"PostCarouselDiscoveryElement", @"OnboardingEntrypointFeedUnit",
                                               @"CommunityInspirationPromptFeedUnit", @"ChatChannelsFeedUnit",
                                               @"AmaCarouselFeedUnit", @"FeaturedCommunitiesFeedUnit" ]))
        return PDTCompatSuggestionCards;
    if (prefs.aiBoxes &&
            PDTTypeNameContainsAny(typeName, @[ @"RelatedAnswersFeedUnit", @"AnswerClustersPDPComponent" ]))
        return PDTCompatAIAnswers;
    return PDTCompatOptionNone;
}

static NSString *PDTTrimmedLowercase(NSString *s) {
    return [[s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
}

// Truthiness helpers: numbers use boolValue; strings are
// trimmed and lower-cased, with a small set of falsey literals.
static BOOL PDTDictTruthy(id v) {
    if (!v || v == NSNull.null) return NO;
    if ([v isKindOfClass:NSNumber.class]) return [(NSNumber *)v boolValue];
    if ([v isKindOfClass:NSString.class]) {
        NSString *s = PDTTrimmedLowercase(v);
        if (s.length == 0) return NO;
        if ([s isEqualToString:@"0"] || [s isEqualToString:@"false"] ||
                [s isEqualToString:@"no"] || [s isEqualToString:@"null"]) return NO;
        return YES;
    }
    return NO;
}

// removedByCategory carries a reason string; only false/null/none/empty mean "not removed".
static BOOL PDTRemovalValueTruthy(id v) {
    if ([v isKindOfClass:NSNumber.class]) return [(NSNumber *)v boolValue];
    if ([v isKindOfClass:NSString.class]) {
        NSString *s = PDTTrimmedLowercase(v);
        if (s.length == 0) return NO;
        if ([s isEqualToString:@"false"] || [s isEqualToString:@"null"] || [s isEqualToString:@"none"]) return NO;
        return YES;
    }
    return NO;
}

static NSString *PDTNormalizedUsername(id v) {
    if (![v isKindOfClass:NSString.class]) return nil;
    NSString *s = PDTTrimmedLowercase(v);
    if ([s hasPrefix:@"/"]) s = [s substringFromIndex:1];
    if ([s hasPrefix:@"@"]) s = [s substringFromIndex:1];
    if ([s hasPrefix:@"u/"]) s = [s substringFromIndex:2];
    s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return s.length ? s : nil;
}

static NSString *PDTNormalizedSubredditName(id v) {
    if (![v isKindOfClass:NSString.class]) return nil;
    NSString *s = PDTTrimmedLowercase(v);
    if ([s hasPrefix:@"/"]) s = [s substringFromIndex:1];
    if ([s hasPrefix:@"r/"]) s = [s substringFromIndex:2];
    s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return s.length ? s : nil;
}

static BOOL PDTStringMatchesKeyword(id v) {
    if (![v isKindOfClass:NSString.class] || [(NSString *)v length] == 0) return NO;
    NSArray *words = [NSUserDefaults.standardUserDefaults arrayForKey:kPrimeDitKeywords];
    if (![words isKindOfClass:NSArray.class]) return NO;
    NSString *hay = [(NSString *)v lowercaseString];
    for (id w in words) {
        if (![w isKindOfClass:NSString.class] || [(NSString *)w length] == 0) continue;
        if ([hay containsString:[(NSString *)w lowercaseString]]) return YES;
    }
    return NO;
}

static BOOL PDTValueMatchesKeyword(id v, int depth) {
    if (depth > 6 || v == nil) return NO;
    if ([v isKindOfClass:NSString.class]) return PDTStringMatchesKeyword(v);
    if ([v isKindOfClass:NSArray.class]) {
        for (id e in (NSArray *)v) if (PDTValueMatchesKeyword(e, depth + 1)) return YES;
        return NO;
    }
    if ([v isKindOfClass:NSDictionary.class]) {
        for (id e in ((NSDictionary *)v).allValues) if (PDTValueMatchesKeyword(e, depth + 1)) return YES;
        return NO;
    }
    return NO;
}

static BOOL PDTKeywordNodeShouldDrop(NSDictionary *node) {
    NSString *t = node[@"__typename"];
    if (![t isKindOfClass:NSString.class]) return NO;
    BOOL isPost = [t hasSuffix:@"Post"] || [t isEqualToString:@"PostInfo"];
    BOOL isComment = [t hasSuffix:@"Comment"] || [t isEqualToString:@"CommentInfo"];
    if (!isPost && !isComment) return NO;
    NSArray *fields = @[ @"content", @"authorInfo", @"subreddit", @"title", @"body",
                         @"selftext", @"selfText", @"domain", @"markdown", @"richtext",
                         @"displayName", @"name", @"prefixedName" ];
    for (NSString *k in fields)
        if (PDTValueMatchesKeyword(node[k], 0)) return YES;
    return NO;
}

static BOOL PDTSubredditNameIsBlocked(id name) {
    NSString *n = PDTNormalizedSubredditName(name);
    if (!n) return NO;
    NSArray *list = [NSUserDefaults.standardUserDefaults arrayForKey:kPrimeDitSubreddits];
    if (![list isKindOfClass:NSArray.class]) return NO;
    for (id e in list) {
        NSString *b = PDTNormalizedSubredditName(e);
        if (b && [n isEqualToString:b]) return YES;
    }
    return NO;
}

static BOOL PDTNodeMatchesBlockedSubreddit(NSDictionary *node) {
    if (PDTSubredditNameIsBlocked(node[@"prefixedName"])) return YES;
    id sr = node[@"subreddit"];
    if ([sr isKindOfClass:NSDictionary.class]) {
        if (PDTSubredditNameIsBlocked(((NSDictionary *)sr)[@"name"])) return YES;
        if (PDTSubredditNameIsBlocked(((NSDictionary *)sr)[@"prefixedName"])) return YES;
    }
    return NO;
}

static BOOL PDTUsernameIsMuted(id name) {
    NSString *n = PDTNormalizedUsername(name);
    if (!n) return NO;
    NSArray *list = [NSUserDefaults.standardUserDefaults arrayForKey:kPrimeDitMutedUsers];
    if (![list isKindOfClass:NSArray.class]) return NO;
    for (id e in list) {
        NSString *m = PDTNormalizedUsername(e);
        if (m && [n isEqualToString:m]) return YES;
    }
    return NO;
}

static BOOL PDTJSONNodeAuthorIsMuted(NSDictionary *node) {
    NSString *t = node[@"__typename"];
    if (![t isKindOfClass:NSString.class]) return NO;
    if (!([t hasSuffix:@"Post"] || [t hasSuffix:@"Comment"] || [t isEqualToString:@"CommentInfo"])) return NO;
    id ai = node[@"authorInfo"];
    if ([ai isKindOfClass:NSDictionary.class]) {
        if (PDTUsernameIsMuted(((NSDictionary *)ai)[@"displayName"])) return YES;
        if (PDTUsernameIsMuted(((NSDictionary *)ai)[@"prefixedName"])) return YES;
    }
    return NO;
}

static BOOL PDTJSONNodeIsNSFW(NSDictionary *node) {
    static NSString *const keys[] = { @"isNsfw", @"over18", @"over_18", @"isAdultContent", @"isNSFW" };
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++)
        if (PDTDictTruthy(node[keys[i]])) return YES;
    return NO;
}

// Option that removes one JSON object, or PDTCompatOptionNone (Reddit 2026.38); visited
// posts only apply to Home feed requests.
static PDTCompatOption PDTDropReasonForNode(NSDictionary *node, PrimeDitPrefs prefs, BOOL homeFeed) {
    NSString *t = node[@"__typename"];
    if (![t isKindOfClass:NSString.class]) t = @"";

    if (prefs.promoted) {
        if ([t containsString:@"AdPost"] || [t containsString:@"ConversationAd"]) return PDTCompatPromoted;
        if (PDTDictTruthy(node[@"isAdPost"]) || PDTDictTruthy(node[@"isCommercial"]) ||
                PDTDictTruthy(node[@"isPromoted"]) || PDTDictTruthy(node[@"isCreatedFromAdsUi"]))
            return PDTCompatPromoted;
        if ([node[@"adPayload"] isKindOfClass:NSDictionary.class] ||
                [node[@"promotedCommunityPost"] isKindOfClass:NSDictionary.class] ||
                [node[@"promotedUserPost"] isKindOfClass:NSDictionary.class])
            return PDTCompatPromoted;
    }
    if (prefs.nsfw && PDTJSONNodeIsNSFW(node)) return PDTCompatNSFW;
    PDTCompatOption unit = PDTFeedUnitDropReason(node, prefs);
    if (unit != PDTCompatOptionNone) return unit;
    if (prefs.spoilers && PDTDictTruthy(node[@"isSpoiler"])) return PDTCompatSpoilers;

    if (homeFeed && prefs.hideVisitedPosts &&
            ([t isEqualToString:@"SubredditPost"] || [t isEqualToString:@"ProfilePost"]) &&
            PDTDictTruthy(node[@"isVisited"]))
        return PDTCompatVisitedPosts;

    if (prefs.removedComments && ([t hasSuffix:@"Comment"] || [t isEqualToString:@"CommentInfo"])) {
        if ([t isEqualToString:@"DeletedComment"] ||
                PDTDictTruthy(node[@"isRemoved"]) || PDTDictTruthy(node[@"isDeleted"]) ||
                PDTDictTruthy(node[@"isAdminTakedown"]) || PDTRemovalValueTruthy(node[@"removedByCategory"]))
            return PDTCompatRemovedComments;
    }

    if (prefs.keywordsEnabled && PDTKeywordNodeShouldDrop(node)) return PDTCompatKeywords;
    if (prefs.subredditsEnabled && PDTNodeMatchesBlockedSubreddit(node)) return PDTCompatSubreddits;
    if (prefs.mutedUsers && PDTJSONNodeAuthorIsMuted(node)) return PDTCompatMutedUsers;
    return PDTCompatOptionNone;
}

// A filtered post or comment nested under one of these keys removes its container.
static NSString *const kPDTPropagationKeys[] = { @"node", @"comment", @"post", @"postInfo", @"commentInfo" };
static NSString *const kPDTAdArrayKeys[] = { @"commentsPageAds", @"commentTreeAds", @"pdpCommentsAds",
                                            @"PdpCommentsAds", @"blankAdPosts" };

static PDTCompatOption PDTSubtreeDropReason(id obj, PrimeDitPrefs prefs, BOOL homeFeed, int depth) {
    if (depth > 3 || ![obj isKindOfClass:NSDictionary.class]) return PDTCompatOptionNone;
    NSDictionary *dict = obj;
    PDTCompatOption reason = PDTDropReasonForNode(dict, prefs, homeFeed);
    size_t count = sizeof(kPDTPropagationKeys) / sizeof(kPDTPropagationKeys[0]);
    for (size_t i = 0; reason == PDTCompatOptionNone && i < count; i++)
        reason = PDTSubtreeDropReason(dict[kPDTPropagationKeys[i]], prefs, homeFeed, depth + 1);
    return reason;
}

static NSString *PDTNormalizedCommentID(id v) {
    if (![v isKindOfClass:NSString.class]) return nil;
    NSString *s = [(NSString *)v lowercaseString];
    if ([s hasPrefix:@"t1_"]) s = [s substringFromIndex:3];
    return s.length ? s : nil;
}

static BOOL PDTAnyDropEnabled(PrimeDitPrefs prefs) {
    return prefs.promoted || prefs.nsfw || prefs.recommendationCarousels || prefs.extraFeedCards ||
           prefs.aiBoxes || prefs.spoilers || prefs.hideVisitedPosts || prefs.removedComments ||
           prefs.keywordsEnabled || prefs.subredditsEnabled || prefs.mutedUsers;
}

static BOOL PDTIsHomeFeedRequest(NSString *operationName, NSString *body) {
    static NSString *const names[] = { @"HomeFeedElements", @"HomeFeedSdui", @"HomeFeedSduiQuery",
                                       @"HomeFeedSduiBgQuery", @"HomeFeedWithDefer",
                                       @"HomeFeedWithDeferQuery", @"ios_home_feed_defer_query" };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        if ([operationName isEqualToString:names[i]]) return YES;
        if (body && [body containsString:names[i]]) return YES;
    }
    return NO;
}

#if PRIMEDIT_DEBUG
// Compatibility check: type name of a list item, looking through its "node" wrapper.
static NSString *PDTCompatItemType(NSDictionary *item) {
    id node = item[@"node"];
    NSDictionary *inner = [node isKindOfClass:NSDictionary.class] ? node : item;
    NSString *type = inner[@"__typename"];
    return [type isKindOfClass:NSString.class] ? type : @"item";
}
#endif

// Recursive walk over the whole response: filtered array
// elements are removed in place (containers are mutable), ad arrays emptied,
// and direct replies to muted users' comments dropped with them.
static void PDTWalkJSON(id value, PrimeDitPrefs prefs, BOOL homeFeed, int depth) {
    if (depth > 48) return;

    if ([value isKindOfClass:NSMutableDictionary.class]) {
        NSMutableDictionary *dict = value;
        if (prefs.promoted) {
            for (size_t i = 0; i < sizeof(kPDTAdArrayKeys) / sizeof(kPDTAdArrayKeys[0]); i++) {
                NSArray *ads = dict[kPDTAdArrayKeys[i]];
                if (![ads isKindOfClass:NSArray.class]) continue;
                PDTCOMPAT_ACTION_IF(ads.count, PDTCompatPromoted, @"%@ cleared", kPDTAdArrayKeys[i]);
                dict[kPDTAdArrayKeys[i]] = [NSMutableArray array];
            }
        }
        for (id child in dict.allValues) PDTWalkJSON(child, prefs, homeFeed, depth + 1);
        return;
    }
    if (![value isKindOfClass:NSMutableArray.class]) return;
    NSMutableArray *array = value;

    NSMutableSet *mutedIDs = nil;
    if (prefs.mutedUsers) {
        for (id el in array) {
            if (![el isKindOfClass:NSDictionary.class]) continue;
            id node = ((NSDictionary *)el)[@"node"];
            NSDictionary *comment = [node isKindOfClass:NSDictionary.class] ? node : el;
            if (!PDTJSONNodeAuthorIsMuted(comment)) continue;
            NSString *cid = PDTNormalizedCommentID(comment[@"id"]);
            if (!cid) continue;
            if (!mutedIDs) mutedIDs = [NSMutableSet set];
            [mutedIDs addObject:cid];
        }
    }

    [array filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id el, NSDictionary *bindings) {
        if (![el isKindOfClass:NSDictionary.class]) return YES;
        PDTCompatOption reason = PDTSubtreeDropReason(el, prefs, homeFeed, 0);
        if (reason != PDTCompatOptionNone) {
            PDTCOMPAT_ACTION(reason, @"%@", PDTCompatItemType(el));
            return NO;
        }
        if (mutedIDs.count) {
            NSDictionary *entry = el;
            id node = entry[@"node"];
            NSDictionary *comment = [node isKindOfClass:NSDictionary.class] ? node : entry;
            NSString *parent = PDTNormalizedCommentID(entry[@"parentId"]) ?: PDTNormalizedCommentID(comment[@"parentId"]);
            if (parent && [mutedIDs containsObject:parent]) {
                PDTCOMPAT_ACTION(PDTCompatMutedUsers, @"Reply to a muted user");
                return NO;
            }
        }
        return YES;
    }]];

    for (id child in array) PDTWalkJSON(child, prefs, homeFeed, depth + 1);
}

static void filterNode(NSMutableDictionary *node, PrimeDitPrefs prefs) {
    if (![node isKindOfClass:NSMutableDictionary.class]) return;

    // Only dictionaries with a string __typename are handled.
    NSString *typeName = node[@"__typename"];
    if (![typeName isKindOfClass:NSString.class]) return;

    if ([typeName isEqualToString:@"SubredditPost"]) {
        if (prefs.awards) {
            node[@"awardings"] = @[];
            node[@"isGildable"] = @NO;
            PDTCOMPAT_ACTION(PDTCompatAwards, @"%@", typeName);
        }
        if (prefs.scores) {
            node[@"isScoreHidden"] = @YES;
            PDTCOMPAT_ACTION(PDTCompatVoteCounts, @"%@", typeName);
        }
        if (prefs.nsfw && [node[@"isNsfw"] boolValue]) node[@"isHidden"] = @YES;
    }
    else if ([typeName isEqualToString:@"Comment"]) {
        if (prefs.awards) {
            node[@"awardings"] = @[];
            node[@"isGildable"] = @NO;
            PDTCOMPAT_ACTION(PDTCompatAwards, @"%@", typeName);
        }
        if (prefs.scores) {
            node[@"isScoreHidden"] = @YES;
            PDTCOMPAT_ACTION(PDTCompatVoteCounts, @"%@", typeName);
        }
        if (prefs.automod) {
            NSDictionary *authorInfo = node[@"authorInfo"];
            if ([authorInfo isKindOfClass:NSDictionary.class]) {
                id authorId = authorInfo[@"id"];
                if ([authorId isKindOfClass:NSString.class] && [authorId isEqualToString:@"t2_6l4z3"]) {
                    node[@"isInitiallyCollapsed"] = @YES;
                    PDTCOMPAT_ACTION(PDTCompatAutoMod, @"AutoMod comment collapsed");
                }
            }
        }
    }
    else if ([typeName isEqualToString:@"CellGroup"]) {
        // Promoted: a cell group carrying an ad payload is emptied.
        if (prefs.promoted && [node[@"adPayload"] isKindOfClass:NSDictionary.class]) {
            node[@"cells"] = @[];
            return;
        }

        // Recommended: a group recommended outside the Popular feed is emptied.
        if (prefs.recommended && [node[@"recommendationContext"] isKindOfClass:NSDictionary.class]) {
            NSDictionary *recContext = node[@"recommendationContext"];
            id recTypeName = recContext[@"typeName"];
            id typeIdentifier = recContext[@"typeIdentifier"];
            if ([recTypeName isKindOfClass:NSString.class] && [typeIdentifier isKindOfClass:NSString.class]) {
                BOOL isPopularFeed = [recTypeName isEqualToString:@"PopularRecommendationContext"] ||
                                     [typeIdentifier hasPrefix:@"global_popular"];
                if (!isPopularFeed) {
                    node[@"cells"] = @[];
                    PDTCOMPAT_ACTION(PDTCompatRecommended, @"%@ hidden=%@", recTypeName,
                                     recContext[@"isContextHidden"] ?: @"none");
                    return;
                }
            }
        }

        // Awards and vote counts on the group's action cells.
        if (prefs.awards || prefs.scores) {
            NSMutableArray *cells = node[@"cells"];
            if ([cells isKindOfClass:NSMutableArray.class]) {
                for (NSMutableDictionary *cell in cells) {
                    if (![cell isKindOfClass:NSMutableDictionary.class]) continue;
                    if ([cell[@"__typename"] isEqualToString:@"ActionCell"]) {
                        if (prefs.awards) {
                            cell[@"isAwardHidden"] = @YES;
                            PDTCOMPAT_ACTION(PDTCompatAwards, @"ActionCell");
                            id goldenInfo = cell[@"goldenUpvoteInfo"];
                            if ([goldenInfo isKindOfClass:NSMutableDictionary.class]) {
                                ((NSMutableDictionary *)goldenInfo)[@"isGildable"] = @NO;
                            }
                        }
                        if (prefs.scores) {
                            cell[@"isScoreHidden"] = @YES;
                            PDTCOMPAT_ACTION(PDTCompatVoteCounts, @"ActionCell");
                        }
                    }
                }
            }
        }
    }
    else if ([typeName isEqualToString:@"AdPost"]) {
        if (prefs.promoted) node[@"isHidden"] = @YES;
    }
}

// Schema-agnostic filtering for unknown operations, and the fallback when a known
// operation's fixed address no longer resolves after a Reddit update.
static void filterGenericResponse(NSMutableDictionary *json, PrimeDitPrefs prefs) {
    if (![json[@"data"] isKindOfClass:NSDictionary.class]) return;

    NSDictionary *dataDict = json[@"data"];
    id root = dataDict.allValues.firstObject;

    if ([root isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *rootDict = (NSMutableDictionary *)root;

        id firstChild = rootDict.allValues.firstObject;

        if ([firstChild isKindOfClass:NSDictionary.class]) {
            id edges = ((NSDictionary *)firstChild)[@"edges"];
            if ([edges isKindOfClass:NSArray.class]) {
                for (NSMutableDictionary *edge in (NSArray *)edges)
                    if ([edge isKindOfClass:NSDictionary.class])
                        filterNode(edge[@"node"], prefs);
            }
        }

        id commentForest = rootDict[@"commentForest"];
        if ([commentForest isKindOfClass:NSDictionary.class]) {
            id trees = ((NSDictionary *)commentForest)[@"trees"];
            if ([trees isKindOfClass:NSArray.class]) {
                for (NSMutableDictionary *tree in (NSArray *)trees)
                    if ([tree isKindOfClass:NSDictionary.class])
                        filterNode(tree[@"node"], prefs);
            }
        }

        if (prefs.promoted && rootDict[@"commentsPageAds"])
            rootDict[@"commentsPageAds"] = @[];

        if (prefs.promoted && rootDict[@"commentTreeAds"])
            rootDict[@"commentTreeAds"] = @[];

        if (prefs.promoted && rootDict[@"pdpCommentsAds"])
            rootDict[@"pdpCommentsAds"] = @[];

        if (rootDict[@"recommendations"] && prefs.recommended) {
            rootDict[@"recommendations"] = @[];
            PDTCOMPAT_ACTION(PDTCompatRecommended, @"Recommendations list cleared");
        }

    } else if ([root isKindOfClass:NSArray.class]) {
        for (NSMutableDictionary *node in (NSArray *)root)
            filterNode(node, prefs);
    }
}

#if PRIMEDIT_DEBUG
// Compatibility check, on what reaches the app: posts and comments carrying the fields
// each filter reads, list items a filter should have removed, and feed unit
// types no filter knows.
static void PDTCompatInspectNode(NSDictionary *node, NSString *type, BOOL homeFeed) {
    if ([type hasSuffix:@"FeedUnit"]) {
        PrimeDitPrefs all = {0};
        all.recommendationCarousels = YES;
        all.extraFeedCards = YES;
        all.aiBoxes = YES;
        PDTCompatRecordFeedUnit(type, PDTFeedUnitDropReason(node, all) != PDTCompatOptionNone);
        return;
    }
    BOOL isPost = [type isEqualToString:@"SubredditPost"] || [type isEqualToString:@"ProfilePost"];
    BOOL isComment = [type isEqualToString:@"Comment"];
    if (!isPost && !isComment) return;
    NSDictionary *author = [node[@"authorInfo"] isKindOfClass:NSDictionary.class] ? node[@"authorInfo"] : nil;
    PDTCompatRecordSentinel(PDTCompatMutedUsers, author[@"displayName"] != nil || author[@"prefixedName"] != nil);
    if (isComment) {
        PDTCompatRecordSentinel(PDTCompatAutoMod, author[@"id"] != nil);
        return;
    }
    PDTCompatRecordSentinel(PDTCompatNSFW, node[@"isNsfw"] != nil || node[@"over18"] != nil || node[@"over_18"] != nil ||
                                     node[@"isAdultContent"] != nil || node[@"isNSFW"] != nil);
    PDTCompatRecordSentinel(PDTCompatSpoilers, node[@"isSpoiler"] != nil);
    NSDictionary *subreddit = [node[@"subreddit"] isKindOfClass:NSDictionary.class] ? node[@"subreddit"] : nil;
    PDTCompatRecordSentinel(PDTCompatSubreddits, node[@"prefixedName"] != nil || subreddit[@"name"] != nil ||
                                           subreddit[@"prefixedName"] != nil);
    if (homeFeed) PDTCompatRecordSentinel(PDTCompatVisitedPosts, node[@"isVisited"] != nil);
}

static void PDTCompatInspectJSON(id value, PrimeDitPrefs prefs, BOOL homeFeed, int depth) {
    if (depth > 48) return;
    if ([value isKindOfClass:NSArray.class]) {
        for (id child in (NSArray *)value) {
            if ([child isKindOfClass:NSDictionary.class]) {
                PDTCompatOption missed = PDTSubtreeDropReason(child, prefs, homeFeed, 0);
                if (missed != PDTCompatOptionNone) PDTCompatRecordAnomaly(missed, @"An item it should remove reached the app");
            }
            PDTCompatInspectJSON(child, prefs, homeFeed, depth + 1);
        }
        return;
    }
    if (![value isKindOfClass:NSDictionary.class]) return;
    NSDictionary *node = value;
    NSString *type = node[@"__typename"];
    if ([type isKindOfClass:NSString.class]) PDTCompatInspectNode(node, type, homeFeed);
    for (id child in node.allValues) PDTCompatInspectJSON(child, prefs, homeFeed, depth + 1);
}

#define PDTCOMPAT_INSPECT(json, prefs, homeFeed)                          \
  do {                                                               \
    if (PDTCompatActive) PDTCompatInspectJSON((json), (prefs), (homeFeed), 0); \
  } while (0)
#else
#define PDTCOMPAT_INSPECT(json, prefs, homeFeed) \
  do {                                      \
  } while (0)
#endif

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *data, NSURLResponse *response,
                                                        NSError *error))completionHandler {
    if (![request.URL.host hasPrefix:@"gql"] &&
            ![request.URL.host hasPrefix:@"oauth"])
        return %orig;

    // Prevent crashes if the underlying method passed a nil completion handler
    if (!completionHandler) {
        return %orig;
    }

    void (^newCompletionHandler)(NSData *, NSURLResponse *, NSError *) =
            ^(NSData *data, NSURLResponse *response, NSError *error) {
                // Errors and empty payloads pass through untouched.
                if (error || !data || data.length == 0) return completionHandler(data, response, error);

                // Operation name, from the request body or the URL query.
                NSString *operationName = @"Unknown";

                NSString *bodyString = nil;
                if (request.HTTPBody) {
                    bodyString = [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding];
                    if (bodyString) {
                        // A regex reads the name without parsing the whole body.
                        NSRegularExpression *regex =
                            [NSRegularExpression regularExpressionWithPattern:@"\"(?:operationName|id)\"\\s*:\\s*\"([^\"]+)\""
                                                                      options:0
                                                                        error:nil];
                        NSTextCheckingResult *match = [regex firstMatchInString:bodyString
                                                                        options:0
                                                                          range:NSMakeRange(0, bodyString.length)];
                        if (match && match.numberOfRanges > 1) {
                            operationName = [bodyString substringWithRange:[match rangeAtIndex:1]];
                        }
                    }
                } else if ([request.URL.query containsString:@"operationName="]) {
                    NSArray *components = [request.URL.query componentsSeparatedByString:@"&"];
                    for (NSString *param in components) {
                        if ([param hasPrefix:@"operationName="]) {
                            operationName = [param substringFromIndex:14];
                            break;
                        }
                    }
                }

                // Operations that never carry feed content skip parsing.
                if ([ignoredOperationsSet containsObject:operationName]) {
                    return completionHandler(data, response, error);
                }

                NSError *jsonError = nil;
                id jsonObject = [NSJSONSerialization JSONObjectWithData:data
                                                                options:NSJSONReadingMutableContainers
                                                                  error:&jsonError];

                if (jsonError || !jsonObject || ![jsonObject isKindOfClass:NSDictionary.class]) {
                    return completionHandler(data, response, error);
                }

                NSMutableDictionary *json = (NSMutableDictionary *)jsonObject;
                if ([operationName isEqualToString:@"BadgeCountsV2"])
                        PDTApplySplitTabBadges([json valueForKeyPath:@"data.badgeIndicators"]);

                PrimeDitPrefs prefs = globalPrefs;
                BOOL homeFeed = PDTIsHomeFeedRequest(operationName, bodyString);
                PDTCOMPAT_RESPONSE(operationName);

                // Fast path based on known schemas.
                if ([operationName isEqualToString:@"HomeFeedSdui"]) {
                    id edges = [json valueForKeyPath:@"data.homeV3.elements.edges"];
                    BOOL resolved = [edges isKindOfClass:NSArray.class];
                    PDT_RECORD_DATA_PATH(@"HomeFeedSdui", @"data.homeV3.elements.edges", resolved, json, PDTDataShapeEdges);

                    if (resolved) {
                        for (NSMutableDictionary *edge in (NSArray *)edges)
                            filterNode(edge[@"node"], prefs);
                    } else {
                        filterGenericResponse(json, prefs);
                    }
                } else if ([operationName isEqualToString:@"PopularFeedSdui"]) {
                    id edges = [json valueForKeyPath:@"data.popularV3.elements.edges"];
                    BOOL resolved = [edges isKindOfClass:NSArray.class];
                    PDT_RECORD_DATA_PATH(@"PopularFeedSdui", @"data.popularV3.elements.edges", resolved, json,
                                         PDTDataShapeEdges);

                    if (resolved) {
                        for (NSMutableDictionary *edge in (NSArray *)edges)
                            filterNode(edge[@"node"], prefs);
                    } else {
                        filterGenericResponse(json, prefs);
                    }
                } else if ([operationName isEqualToString:@"FeedPostDetailsByIds"]) {
                    id nodes = [json valueForKeyPath:@"data.postsInfoByIds"];
                    BOOL resolved = [nodes isKindOfClass:NSArray.class];
                    PDT_RECORD_DATA_PATH(@"FeedPostDetailsByIds", @"data.postsInfoByIds", resolved, json,
                                         PDTDataShapeNodeArray);

                    if (resolved) {
                        for (NSMutableDictionary *node in (NSArray *)nodes)
                            filterNode(node, prefs);
                    } else {
                        filterGenericResponse(json, prefs);
                    }
                } else if ([operationName isEqualToString:@"PostInfoByIdComments"] ||
                           [operationName isEqualToString:@"PostInfoById"]) {
                    NSMutableDictionary *postInfo = [json valueForKeyPath:@"data.postInfoById"];
                    id trees = [postInfo valueForKeyPath:@"commentForest.trees"];
                    // A post without comments has no commentForest; that still counts as resolved.
                    BOOL resolved = [trees isKindOfClass:NSArray.class] ||
                                    ([postInfo isKindOfClass:NSDictionary.class] && postInfo[@"commentForest"] == nil);
                    PDT_RECORD_DATA_PATH(@"PostInfoById", @"data.postInfoById.commentForest.trees", resolved, json,
                                         PDTDataShapeTrees);

                    if (resolved) {
                        if ([trees isKindOfClass:NSArray.class]) {
                            for (NSMutableDictionary *tree in (NSArray *)trees)
                                filterNode(tree[@"node"], prefs);
                        }
                    } else {
                        filterGenericResponse(json, prefs);
                    }
                    if ([postInfo isKindOfClass:NSDictionary.class]) {
                        filterNode(postInfo, prefs);
                    }
                } else if ([operationName isEqualToString:@"PdpCommentsAds"]) {
                    // Locate the comment-ads container, then clear it if Promoted filtering is on.
                    NSMutableDictionary *adContainer = nil;
                    if ([json[@"data"] isKindOfClass:NSDictionary.class]) {
                        NSMutableDictionary *dataDict = json[@"data"];
                        id container = dataDict.allValues.firstObject;
                        if ([container isKindOfClass:NSMutableDictionary.class] &&
                            ((NSMutableDictionary *)container)[@"pdpCommentsAds"]) {
                            adContainer = (NSMutableDictionary *)container;
                        }
                    }
                    BOOL resolved = (adContainer != nil);
                    PDT_RECORD_DATA_PATH(@"PdpCommentsAds", @"data.*.pdpCommentsAds", resolved, json, PDTDataShapeCommentsAds);

                    if (prefs.promoted) {
                        if (resolved) {
                            PDTCOMPAT_ACTION_IF([adContainer[@"pdpCommentsAds"] isKindOfClass:NSArray.class] &&
                                                [(NSArray *)adContainer[@"pdpCommentsAds"] count] > 0,
                                           PDTCompatPromoted, @"Comment ads cleared");
                            adContainer[@"pdpCommentsAds"] = @[];
                        } else {
                            filterGenericResponse(json, prefs);
                        }
                    }
                } else {
                    // Unknown operation (e.g. ProfileFeedSdui): use the generic filter.
                    filterGenericResponse(json, prefs);
                }

                if (PDTAnyDropEnabled(prefs))
                        PDTWalkJSON(json, prefs, homeFeed, 0);
                PDTCOMPAT_INSPECT(json, prefs, homeFeed);

                NSData *modifiedData = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
                completionHandler(modifiedData ?: data, response, error);
            };
    return %orig(request, newCompletionHandler);
}
%end

%ctor {
    ignoredOperationsSet = [[NSSet alloc] initWithObjects:
            @"GetAccount", @"FetchIdentityPreferences", @"DynamicConfigsByNames", @"GetAllExperimentVariants",
            @"UserLocation", @"CookiePreferences", @"FetchSubscribedSubreddits", @"AdsOffRedditPreferences", @"Age",
            @"RecommendedPrompts", @"EnrollInGamification", @"GetEligibleUXExperiences", @"GetUserAdEligibility",
            @"GoldBalances", @"PaymentSubscriptions", @"FeaturedDevvitGame", @"ModQueueNewItemCount",
            @"LastModeratedSubredditName", @"AwardProductOffers", @"BlockedRedditors", @"GamesPreferences",
            @"GetRedditUsersByIds", @"SubredditsForNames", @"SubredditsForIds", @"ExposeExperimentBatch",
            @"GetProfilePostFlairTemplates", @"GetRedditorByNameApollo", @"GetActiveSubreddits",
            @"UserPublicTrophies", @"BrandToolsStatus", nil];
    %init;
}
