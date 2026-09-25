#import <Comment.h>
#import <Post.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#import "Preferences.h"
#import "DataPaths.h"
#import "Compatibility.h"

// Icons already looked up, and GraphQL operations that never carry feed content.
static NSCache *imageCache;
static NSSet<NSString *> *ignoredOperationsSet;

typedef struct {
    BOOL promoted;
    BOOL recommended;
    BOOL nsfw;
    BOOL awards;
    BOOL scores;
    BOOL automod;
    BOOL recommendationCarousels;
    BOOL extraFeedCards;
    BOOL aiBoxes;
    BOOL spoilers;
    BOOL hideVisitedPosts;
    BOOL removedComments;
    BOOL keywordsEnabled;
    BOOL subredditsEnabled;
    BOOL mutedUsers;
} PrimeDitPrefs;

// Filter options, reloaded on every settings change notification.
static PrimeDitPrefs globalPrefs;

static void loadPreferences() {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    globalPrefs.promoted = PDPrefBool(kPrimeDitPromoted, YES);
    globalPrefs.recommended = [defaults boolForKey:kPrimeDitRecommended];
    globalPrefs.nsfw = [defaults boolForKey:kPrimeDitNSFW];
    globalPrefs.awards = [defaults boolForKey:kPrimeDitAwards];
    globalPrefs.scores = [defaults boolForKey:kPrimeDitScores];
    globalPrefs.automod = [defaults boolForKey:kPrimeDitAutoCollapseAutoMod];
    globalPrefs.recommendationCarousels = [defaults boolForKey:kPrimeDitRecommendationCarousels];
    globalPrefs.extraFeedCards = [defaults boolForKey:kPrimeDitExtraFeedCards];
    globalPrefs.aiBoxes = [defaults boolForKey:kPrimeDitAIBoxes];
    globalPrefs.spoilers = [defaults boolForKey:kPrimeDitSpoilers];
    globalPrefs.hideVisitedPosts = [defaults boolForKey:kPrimeDitHideVisitedPosts];
    globalPrefs.removedComments = [defaults boolForKey:kPrimeDitRemovedComments];
    globalPrefs.keywordsEnabled = [defaults boolForKey:kPrimeDitKeywordsEnabled];
    globalPrefs.subredditsEnabled = [defaults boolForKey:kPrimeDitSubredditsEnabled];
    globalPrefs.mutedUsers = [defaults boolForKey:kPrimeDitMutedUsersEnabled];
}

static void prefsNotificationCallback(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                      const void *object, CFDictionaryRef userInfo) {
    loadPreferences();
}

@interface CUICatalog : NSObject {
  NSBundle *_bundle;
}
- (NSArray<NSString *> *)allImageNames;
- (instancetype)initWithName:(NSString *)name fromBundle:(NSBundle *)bundle error:(NSError **)error;
@end

static NSMutableArray<NSBundle *> *assetBundles;
// Reddit's icons share one catalog, tried first; it is also the bundle that provided the last icon.
static NSBundle *gIconBundle;
static NSMutableArray<CUICatalog *> *assetCatalogs;

// Looks an icon up in Reddit's asset catalogs.
static UIImage *PDFindIcon(NSString *iconName) {
    // The icon bundle first: walking all of Reddit's bundles cost up to 90 ms per icon (measured).
    NSBundle *preferred;
    @synchronized(assetBundles) {
        preferred = gIconBundle;
    }
    if (preferred) {
        UIImage *image = [UIImage imageNamed:iconName inBundle:preferred compatibleWithTraitCollection:nil];
        if (image) return image;
    }
    // Then every asset catalog through UIKit; scanning each catalog is the last resort.
    for (NSBundle *bundle in assetBundles) {
        if (bundle == preferred) continue;
        UIImage *image = [UIImage imageNamed:iconName inBundle:bundle compatibleWithTraitCollection:nil];
        if (image) {
            @synchronized(assetBundles) {
                gIconBundle = bundle;
            }
            return image;
        }
    }

    // Catalog names may carry a three-character size suffix.
    for (CUICatalog *catalog in assetCatalogs) {
        for (NSString *imageName in [catalog allImageNames]) {
            if ([imageName hasPrefix:iconName] &&
                (imageName.length == iconName.length || imageName.length == iconName.length + 3)) {
                // The catalog keeps its bundle in the private _bundle ivar.
                Ivar bundleIvar = class_getInstanceVariable(object_getClass(catalog), "_bundle");
                if (!bundleIvar) continue;
                NSBundle *bundle = object_getIvar(catalog, bundleIvar);
                if (!bundle) continue;
                UIImage *image = [UIImage imageNamed:imageName
                                            inBundle:bundle
                       compatibleWithTraitCollection:nil];
                if (image) return image;
            }
        }
    }
    return nil;
}

extern "C" UIImage *iconWithName(NSString *iconName) {
    if (!iconName) return nil;
    UIImage *cachedImage = [imageCache objectForKey:iconName];
    if (cachedImage) return cachedImage;
    UIImage *image = PDFindIcon(iconName);
    if (image) [imageCache setObject:image forKey:iconName];
    return image;
}

extern "C" void PDApplySplitTabBadges(id indicators);

extern "C" Class CoreClass(NSString *name) {
  Class cls = NSClassFromString(name);
  NSArray *prefixes = @[
    @"Reddit.",
    @"RedditCore.",
    @"RedditCoreModels.",
    @"RedditCore_RedditCoreModels.",
    @"RedditUI.",
  ];
  for (NSString *prefix in prefixes) {
    if (cls) break;
    cls = NSClassFromString([prefix stringByAppendingString:name]);
  }
  return cls;
}

// Feed-unit type matching (recommendation carousels, discovery/trending cards,
// AI answer boxes), with type names as of Reddit 2026.38.
static BOOL PDTypeNameContainsAny(NSString *typeName, NSArray<NSString *> *needles) {
  for (NSString *needle in needles)
    if ([typeName containsString:needle]) return YES;
  return NO;
}

static PDCompatOption PDFeedUnitDropReason(id nodeObj, PrimeDitPrefs prefs) {
  if (![nodeObj isKindOfClass:NSDictionary.class]) return PDCompatOptionNone;
  NSString *typeName = ((NSDictionary *)nodeObj)[@"__typename"];
  if (![typeName isKindOfClass:NSString.class]) return PDCompatOptionNone;

  if (prefs.recommendationCarousels &&
      PDTypeNameContainsAny(typeName, @[ @"CommunityRecommendation", @"RecommendationCarousel",
                                         @"RelatedCommunit", @"CarouselCommunityRecommendations" ]))
    return PDCompatCommunityRecs;
  if (prefs.extraFeedCards &&
      PDTypeNameContainsAny(typeName, @[ @"RelatedPostsFeedUnit", @"SearchTrendingFeedUnit",
                                         @"PostCarouselDiscoveryElement", @"OnboardingEntrypointFeedUnit",
                                         @"CommunityInspirationPromptFeedUnit", @"ChatChannelsFeedUnit",
                                         @"AmaCarouselFeedUnit", @"FeaturedCommunitiesFeedUnit" ]))
    return PDCompatSuggestionCards;
  if (prefs.aiBoxes &&
      PDTypeNameContainsAny(typeName, @[ @"RelatedAnswersFeedUnit", @"AnswerClustersPDPComponent" ]))
    return PDCompatAIAnswers;
  return PDCompatOptionNone;
}

static NSString *PDTrimmedLowercase(NSString *s) {
  return [[s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
}

// Truthiness helpers: numbers use boolValue; strings are
// trimmed and lower-cased, with a small set of falsey literals.
static BOOL PDDictTruthy(id v) {
  if (!v || v == NSNull.null) return NO;
  if ([v isKindOfClass:NSNumber.class]) return [(NSNumber *)v boolValue];
  if ([v isKindOfClass:NSString.class]) {
    NSString *s = PDTrimmedLowercase(v);
    if (s.length == 0) return NO;
    if ([s isEqualToString:@"0"] || [s isEqualToString:@"false"] ||
        [s isEqualToString:@"no"] || [s isEqualToString:@"null"]) return NO;
    return YES;
  }
  return NO;
}

// removedByCategory carries a reason string; only false/null/none/empty mean "not removed".
static BOOL PDRemovalValueTruthy(id v) {
  if ([v isKindOfClass:NSNumber.class]) return [(NSNumber *)v boolValue];
  if ([v isKindOfClass:NSString.class]) {
    NSString *s = PDTrimmedLowercase(v);
    if (s.length == 0) return NO;
    if ([s isEqualToString:@"false"] || [s isEqualToString:@"null"] || [s isEqualToString:@"none"]) return NO;
    return YES;
  }
  return NO;
}

static NSString *PDNormalizedUsername(id v) {
  if (![v isKindOfClass:NSString.class]) return nil;
  NSString *s = PDTrimmedLowercase(v);
  if ([s hasPrefix:@"/"]) s = [s substringFromIndex:1];
  if ([s hasPrefix:@"@"]) s = [s substringFromIndex:1];
  if ([s hasPrefix:@"u/"]) s = [s substringFromIndex:2];
  s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  return s.length ? s : nil;
}

static NSString *PDNormalizedSubredditName(id v) {
  if (![v isKindOfClass:NSString.class]) return nil;
  NSString *s = PDTrimmedLowercase(v);
  if ([s hasPrefix:@"/"]) s = [s substringFromIndex:1];
  if ([s hasPrefix:@"r/"]) s = [s substringFromIndex:2];
  s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  return s.length ? s : nil;
}

static BOOL PDStringMatchesKeyword(id v) {
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

static BOOL PDValueMatchesKeyword(id v, int depth) {
  if (depth > 6 || v == nil) return NO;
  if ([v isKindOfClass:NSString.class]) return PDStringMatchesKeyword(v);
  if ([v isKindOfClass:NSArray.class]) {
    for (id e in (NSArray *)v) if (PDValueMatchesKeyword(e, depth + 1)) return YES;
    return NO;
  }
  if ([v isKindOfClass:NSDictionary.class]) {
    for (id e in ((NSDictionary *)v).allValues) if (PDValueMatchesKeyword(e, depth + 1)) return YES;
    return NO;
  }
  return NO;
}

static BOOL PDKeywordNodeShouldDrop(NSDictionary *node) {
  NSString *t = node[@"__typename"];
  if (![t isKindOfClass:NSString.class]) return NO;
  BOOL isPost = [t hasSuffix:@"Post"] || [t isEqualToString:@"PostInfo"];
  BOOL isComment = [t hasSuffix:@"Comment"] || [t isEqualToString:@"CommentInfo"];
  if (!isPost && !isComment) return NO;
  NSArray *fields = @[ @"content", @"authorInfo", @"subreddit", @"title", @"body",
                       @"selftext", @"selfText", @"domain", @"markdown", @"richtext",
                       @"displayName", @"name", @"prefixedName" ];
  for (NSString *k in fields)
    if (PDValueMatchesKeyword(node[k], 0)) return YES;
  return NO;
}

static BOOL PDSubredditNameIsBlocked(id name) {
  NSString *n = PDNormalizedSubredditName(name);
  if (!n) return NO;
  NSArray *list = [NSUserDefaults.standardUserDefaults arrayForKey:kPrimeDitSubreddits];
  if (![list isKindOfClass:NSArray.class]) return NO;
  for (id e in list) {
    NSString *b = PDNormalizedSubredditName(e);
    if (b && [n isEqualToString:b]) return YES;
  }
  return NO;
}

static BOOL PDNodeMatchesBlockedSubreddit(NSDictionary *node) {
  if (PDSubredditNameIsBlocked(node[@"prefixedName"])) return YES;
  id sr = node[@"subreddit"];
  if ([sr isKindOfClass:NSDictionary.class]) {
    if (PDSubredditNameIsBlocked(((NSDictionary *)sr)[@"name"])) return YES;
    if (PDSubredditNameIsBlocked(((NSDictionary *)sr)[@"prefixedName"])) return YES;
  }
  return NO;
}

static BOOL PDUsernameIsMuted(id name) {
  NSString *n = PDNormalizedUsername(name);
  if (!n) return NO;
  NSArray *list = [NSUserDefaults.standardUserDefaults arrayForKey:kPrimeDitMutedUsers];
  if (![list isKindOfClass:NSArray.class]) return NO;
  for (id e in list) {
    NSString *m = PDNormalizedUsername(e);
    if (m && [n isEqualToString:m]) return YES;
  }
  return NO;
}

static BOOL PDJSONNodeAuthorIsMuted(NSDictionary *node) {
  NSString *t = node[@"__typename"];
  if (![t isKindOfClass:NSString.class]) return NO;
  if (!([t hasSuffix:@"Post"] || [t hasSuffix:@"Comment"] || [t isEqualToString:@"CommentInfo"])) return NO;
  id ai = node[@"authorInfo"];
  if ([ai isKindOfClass:NSDictionary.class]) {
    if (PDUsernameIsMuted(((NSDictionary *)ai)[@"displayName"])) return YES;
    if (PDUsernameIsMuted(((NSDictionary *)ai)[@"prefixedName"])) return YES;
  }
  return NO;
}

static BOOL PDJSONNodeIsNSFW(NSDictionary *node) {
  static NSString *const keys[] = { @"isNsfw", @"over18", @"over_18", @"isAdultContent", @"isNSFW" };
  for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++)
    if (PDDictTruthy(node[keys[i]])) return YES;
  return NO;
}

// Option that removes one JSON object, or PDCompatOptionNone (Reddit 2026.38); visited
// posts only apply to Home feed requests.
static PDCompatOption PDDropReasonForNode(NSDictionary *node, PrimeDitPrefs prefs, BOOL homeFeed) {
  NSString *t = node[@"__typename"];
  if (![t isKindOfClass:NSString.class]) t = @"";

  if (prefs.promoted) {
    if ([t containsString:@"AdPost"] || [t containsString:@"ConversationAd"]) return PDCompatPromoted;
    if (PDDictTruthy(node[@"isAdPost"]) || PDDictTruthy(node[@"isCommercial"]) ||
        PDDictTruthy(node[@"isPromoted"]) || PDDictTruthy(node[@"isCreatedFromAdsUi"]))
      return PDCompatPromoted;
    if ([node[@"adPayload"] isKindOfClass:NSDictionary.class] ||
        [node[@"promotedCommunityPost"] isKindOfClass:NSDictionary.class] ||
        [node[@"promotedUserPost"] isKindOfClass:NSDictionary.class])
      return PDCompatPromoted;
  }
  if (prefs.nsfw && PDJSONNodeIsNSFW(node)) return PDCompatNSFW;
  PDCompatOption unit = PDFeedUnitDropReason(node, prefs);
  if (unit != PDCompatOptionNone) return unit;
  if (prefs.spoilers && PDDictTruthy(node[@"isSpoiler"])) return PDCompatSpoilers;

  if (homeFeed && prefs.hideVisitedPosts &&
      ([t isEqualToString:@"SubredditPost"] || [t isEqualToString:@"ProfilePost"]) &&
      PDDictTruthy(node[@"isVisited"]))
    return PDCompatVisitedPosts;

  if (prefs.removedComments && ([t hasSuffix:@"Comment"] || [t isEqualToString:@"CommentInfo"])) {
    if ([t isEqualToString:@"DeletedComment"] ||
        PDDictTruthy(node[@"isRemoved"]) || PDDictTruthy(node[@"isDeleted"]) ||
        PDDictTruthy(node[@"isAdminTakedown"]) || PDRemovalValueTruthy(node[@"removedByCategory"]))
      return PDCompatRemovedComments;
  }

  if (prefs.keywordsEnabled && PDKeywordNodeShouldDrop(node)) return PDCompatKeywords;
  if (prefs.subredditsEnabled && PDNodeMatchesBlockedSubreddit(node)) return PDCompatSubreddits;
  if (prefs.mutedUsers && PDJSONNodeAuthorIsMuted(node)) return PDCompatMutedUsers;
  return PDCompatOptionNone;
}

// A filtered post or comment nested under one of these keys removes its container.
static NSString *const kPDPropagationKeys[] = { @"node", @"comment", @"post", @"postInfo", @"commentInfo" };
static NSString *const kPDAdArrayKeys[] = { @"commentsPageAds", @"commentTreeAds", @"pdpCommentsAds",
                                            @"PdpCommentsAds", @"blankAdPosts" };

static PDCompatOption PDSubtreeDropReason(id obj, PrimeDitPrefs prefs, BOOL homeFeed, int depth) {
  if (depth > 3 || ![obj isKindOfClass:NSDictionary.class]) return PDCompatOptionNone;
  NSDictionary *dict = obj;
  PDCompatOption reason = PDDropReasonForNode(dict, prefs, homeFeed);
  size_t count = sizeof(kPDPropagationKeys) / sizeof(kPDPropagationKeys[0]);
  for (size_t i = 0; reason == PDCompatOptionNone && i < count; i++)
    reason = PDSubtreeDropReason(dict[kPDPropagationKeys[i]], prefs, homeFeed, depth + 1);
  return reason;
}

static NSString *PDNormalizedCommentID(id v) {
  if (![v isKindOfClass:NSString.class]) return nil;
  NSString *s = [(NSString *)v lowercaseString];
  if ([s hasPrefix:@"t1_"]) s = [s substringFromIndex:3];
  return s.length ? s : nil;
}

static BOOL PDAnyDropEnabled(PrimeDitPrefs prefs) {
  return prefs.promoted || prefs.nsfw || prefs.recommendationCarousels || prefs.extraFeedCards ||
         prefs.aiBoxes || prefs.spoilers || prefs.hideVisitedPosts || prefs.removedComments ||
         prefs.keywordsEnabled || prefs.subredditsEnabled || prefs.mutedUsers;
}

static BOOL PDIsHomeFeedRequest(NSString *operationName, NSString *body) {
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
static NSString *PDCompatItemType(NSDictionary *item) {
  id node = item[@"node"];
  NSDictionary *inner = [node isKindOfClass:NSDictionary.class] ? node : item;
  NSString *type = inner[@"__typename"];
  return [type isKindOfClass:NSString.class] ? type : @"item";
}
#endif

// Recursive walk over the whole response: filtered array
// elements are removed in place (containers are mutable), ad arrays emptied,
// and direct replies to muted users' comments dropped with them.
static void PDWalkJSON(id value, PrimeDitPrefs prefs, BOOL homeFeed, int depth) {
  if (depth > 48) return;

  if ([value isKindOfClass:NSMutableDictionary.class]) {
    NSMutableDictionary *dict = value;
    if (prefs.promoted) {
      for (size_t i = 0; i < sizeof(kPDAdArrayKeys) / sizeof(kPDAdArrayKeys[0]); i++) {
        NSArray *ads = dict[kPDAdArrayKeys[i]];
        if (![ads isKindOfClass:NSArray.class]) continue;
        PDCOMPAT_ACTION_IF(ads.count, PDCompatPromoted, @"%@ cleared", kPDAdArrayKeys[i]);
        dict[kPDAdArrayKeys[i]] = [NSMutableArray array];
      }
    }
    for (id child in dict.allValues) PDWalkJSON(child, prefs, homeFeed, depth + 1);
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
      if (!PDJSONNodeAuthorIsMuted(comment)) continue;
      NSString *cid = PDNormalizedCommentID(comment[@"id"]);
      if (!cid) continue;
      if (!mutedIDs) mutedIDs = [NSMutableSet set];
      [mutedIDs addObject:cid];
    }
  }

  [array filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id el, NSDictionary *bindings) {
    if (![el isKindOfClass:NSDictionary.class]) return YES;
    PDCompatOption reason = PDSubtreeDropReason(el, prefs, homeFeed, 0);
    if (reason != PDCompatOptionNone) {
      PDCOMPAT_ACTION(reason, @"%@", PDCompatItemType(el));
      return NO;
    }
    if (mutedIDs.count) {
      NSDictionary *entry = el;
      id node = entry[@"node"];
      NSDictionary *comment = [node isKindOfClass:NSDictionary.class] ? node : entry;
      NSString *parent = PDNormalizedCommentID(entry[@"parentId"]) ?: PDNormalizedCommentID(comment[@"parentId"]);
      if (parent && [mutedIDs containsObject:parent]) {
        PDCOMPAT_ACTION(PDCompatMutedUsers, @"Reply to a muted user");
        return NO;
      }
    }
    return YES;
  }]];

  for (id child in array) PDWalkJSON(child, prefs, homeFeed, depth + 1);
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
            PDCOMPAT_ACTION(PDCompatAwards, @"%@", typeName);
        }
        if (prefs.scores) {
            node[@"isScoreHidden"] = @YES;
            PDCOMPAT_ACTION(PDCompatVoteCounts, @"%@", typeName);
        }
        if (prefs.nsfw && [node[@"isNsfw"] boolValue]) node[@"isHidden"] = @YES;
    }
    else if ([typeName isEqualToString:@"Comment"]) {
        if (prefs.awards) {
            node[@"awardings"] = @[];
            node[@"isGildable"] = @NO;
            PDCOMPAT_ACTION(PDCompatAwards, @"%@", typeName);
        }
        if (prefs.scores) {
            node[@"isScoreHidden"] = @YES;
            PDCOMPAT_ACTION(PDCompatVoteCounts, @"%@", typeName);
        }
        if (prefs.automod) {
            NSDictionary *authorInfo = node[@"authorInfo"];
            if ([authorInfo isKindOfClass:NSDictionary.class]) {
                id authorId = authorInfo[@"id"];
                if ([authorId isKindOfClass:NSString.class] && [authorId isEqualToString:@"t2_6l4z3"]) {
                    node[@"isInitiallyCollapsed"] = @YES;
                    PDCOMPAT_ACTION(PDCompatAutoMod, @"AutoMod comment collapsed");
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
                    PDCOMPAT_ACTION(PDCompatRecommended, @"%@ hidden=%@", recTypeName,
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
                            PDCOMPAT_ACTION(PDCompatAwards, @"ActionCell");
                            id goldenInfo = cell[@"goldenUpvoteInfo"];
                            if ([goldenInfo isKindOfClass:NSMutableDictionary.class]) {
                                ((NSMutableDictionary *)goldenInfo)[@"isGildable"] = @NO;
                            }
                        }
                        if (prefs.scores) {
                            cell[@"isScoreHidden"] = @YES;
                            PDCOMPAT_ACTION(PDCompatVoteCounts, @"ActionCell");
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
      PDCOMPAT_ACTION(PDCompatRecommended, @"Recommendations list cleared");
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
static void PDCompatInspectNode(NSDictionary *node, NSString *type, BOOL homeFeed) {
  if ([type hasSuffix:@"FeedUnit"]) {
    PrimeDitPrefs all = {0};
    all.recommendationCarousels = YES;
    all.extraFeedCards = YES;
    all.aiBoxes = YES;
    PDCompatRecordFeedUnit(type, PDFeedUnitDropReason(node, all) != PDCompatOptionNone);
    return;
  }
  BOOL isPost = [type isEqualToString:@"SubredditPost"] || [type isEqualToString:@"ProfilePost"];
  BOOL isComment = [type isEqualToString:@"Comment"];
  if (!isPost && !isComment) return;
  NSDictionary *author = [node[@"authorInfo"] isKindOfClass:NSDictionary.class] ? node[@"authorInfo"] : nil;
  PDCompatRecordSentinel(PDCompatMutedUsers, author[@"displayName"] != nil || author[@"prefixedName"] != nil);
  if (isComment) {
    PDCompatRecordSentinel(PDCompatAutoMod, author[@"id"] != nil);
    return;
  }
  PDCompatRecordSentinel(PDCompatNSFW, node[@"isNsfw"] != nil || node[@"over18"] != nil || node[@"over_18"] != nil ||
                                   node[@"isAdultContent"] != nil || node[@"isNSFW"] != nil);
  PDCompatRecordSentinel(PDCompatSpoilers, node[@"isSpoiler"] != nil);
  NSDictionary *subreddit = [node[@"subreddit"] isKindOfClass:NSDictionary.class] ? node[@"subreddit"] : nil;
  PDCompatRecordSentinel(PDCompatSubreddits, node[@"prefixedName"] != nil || subreddit[@"name"] != nil ||
                                         subreddit[@"prefixedName"] != nil);
  if (homeFeed) PDCompatRecordSentinel(PDCompatVisitedPosts, node[@"isVisited"] != nil);
}

static void PDCompatInspectJSON(id value, PrimeDitPrefs prefs, BOOL homeFeed, int depth) {
  if (depth > 48) return;
  if ([value isKindOfClass:NSArray.class]) {
    for (id child in (NSArray *)value) {
      if ([child isKindOfClass:NSDictionary.class]) {
        PDCompatOption missed = PDSubtreeDropReason(child, prefs, homeFeed, 0);
        if (missed != PDCompatOptionNone) PDCompatRecordAnomaly(missed, @"An item it should remove reached the app");
      }
      PDCompatInspectJSON(child, prefs, homeFeed, depth + 1);
    }
    return;
  }
  if (![value isKindOfClass:NSDictionary.class]) return;
  NSDictionary *node = value;
  NSString *type = node[@"__typename"];
  if ([type isKindOfClass:NSString.class]) PDCompatInspectNode(node, type, homeFeed);
  for (id child in node.allValues) PDCompatInspectJSON(child, prefs, homeFeed, depth + 1);
}

#define PDCOMPAT_INSPECT(json, prefs, homeFeed)                          \
  do {                                                               \
    if (PDCompatActive) PDCompatInspectJSON((json), (prefs), (homeFeed), 0); \
  } while (0)
#else
#define PDCOMPAT_INSPECT(json, prefs, homeFeed) \
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
            PDApplySplitTabBadges([json valueForKeyPath:@"data.badgeIndicators"]);

        PrimeDitPrefs prefs = globalPrefs;
        BOOL homeFeed = PDIsHomeFeedRequest(operationName, bodyString);
        PDCOMPAT_RESPONSE(operationName);

        // Fast path based on known schemas.
        if ([operationName isEqualToString:@"HomeFeedSdui"]) {
            id edges = [json valueForKeyPath:@"data.homeV3.elements.edges"];
            BOOL resolved = [edges isKindOfClass:NSArray.class];
            PD_RECORD_DATA_PATH(@"HomeFeedSdui", @"data.homeV3.elements.edges", resolved, json, PDDataShapeEdges);

            if (resolved) {
                for (NSMutableDictionary *edge in (NSArray *)edges)
                    filterNode(edge[@"node"], prefs);
            } else {
                filterGenericResponse(json, prefs);
            }
        } else if ([operationName isEqualToString:@"PopularFeedSdui"]) {
            id edges = [json valueForKeyPath:@"data.popularV3.elements.edges"];
            BOOL resolved = [edges isKindOfClass:NSArray.class];
            PD_RECORD_DATA_PATH(@"PopularFeedSdui", @"data.popularV3.elements.edges", resolved, json, PDDataShapeEdges);

            if (resolved) {
                for (NSMutableDictionary *edge in (NSArray *)edges)
                    filterNode(edge[@"node"], prefs);
            } else {
                filterGenericResponse(json, prefs);
            }
        } else if ([operationName isEqualToString:@"FeedPostDetailsByIds"]) {
            id nodes = [json valueForKeyPath:@"data.postsInfoByIds"];
            BOOL resolved = [nodes isKindOfClass:NSArray.class];
            PD_RECORD_DATA_PATH(@"FeedPostDetailsByIds", @"data.postsInfoByIds", resolved, json, PDDataShapeNodeArray);

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
            PD_RECORD_DATA_PATH(@"PostInfoById", @"data.postInfoById.commentForest.trees", resolved, json,
                                PDDataShapeTrees);

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
            PD_RECORD_DATA_PATH(@"PdpCommentsAds", @"data.*.pdpCommentsAds", resolved, json, PDDataShapeCommentsAds);

            if (prefs.promoted) {
                if (resolved) {
                    PDCOMPAT_ACTION_IF([adContainer[@"pdpCommentsAds"] isKindOfClass:NSArray.class] &&
                                       [(NSArray *)adContainer[@"pdpCommentsAds"] count] > 0,
                                   PDCompatPromoted, @"Comment ads cleared");
                    adContainer[@"pdpCommentsAds"] = @[];
                } else {
                    filterGenericResponse(json, prefs);
                }
            }
        } else {
            // Unknown operation (e.g. ProfileFeedSdui): use the generic filter.
            filterGenericResponse(json, prefs);
        }

        if (PDAnyDropEnabled(prefs))
            PDWalkJSON(json, prefs, homeFeed, 0);
        PDCOMPAT_INSPECT(json, prefs, homeFeed);

        NSData *modifiedData = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
        completionHandler(modifiedData ?: data, response, error);
      };
  return %orig(request, newCompletionHandler);
}
%end

// Reddit's post and comment models: awards, vote counts and AutoMod collapse.
%group Models

%hook Post
- (NSArray *)awardingTotals {
  return globalPrefs.awards ? nil : %orig;
}
- (NSUInteger)totalAwardsReceived {
  return globalPrefs.awards ? 0 : %orig;
}
- (BOOL)canAward {
  return globalPrefs.awards ? NO : %orig;
}
- (BOOL)isScoreHidden {
  return globalPrefs.scores ? YES : %orig;
}
%end

%hook Comment
- (NSArray *)awardingTotals {
  return globalPrefs.awards ? nil : %orig;
}
- (NSUInteger)totalAwardsReceived {
  return globalPrefs.awards ? 0 : %orig;
}
- (BOOL)canAward {
  return globalPrefs.awards ? NO : %orig;
}
- (BOOL)isScoreHidden {
  return globalPrefs.scores ? YES : %orig;
}
- (BOOL)shouldAutoCollapse {
  return globalPrefs.automod &&
                 [((Comment *)self).authorPk isEqualToString:@"t2_6l4z3"]
             ? YES
             : %orig;
}
%end

%end

%ctor {
  imageCache = [[NSCache alloc] init];
  ignoredOperationsSet = [[NSSet alloc] initWithObjects:
      @"GetAccount", @"FetchIdentityPreferences", @"DynamicConfigsByNames", @"GetAllExperimentVariants",
      @"UserLocation", @"CookiePreferences", @"FetchSubscribedSubreddits", @"AdsOffRedditPreferences", @"Age",
      @"RecommendedPrompts", @"EnrollInGamification", @"GetEligibleUXExperiences", @"GetUserAdEligibility",
      @"GoldBalances", @"PaymentSubscriptions", @"FeaturedDevvitGame", @"ModQueueNewItemCount",
      @"LastModeratedSubredditName", @"AwardProductOffers", @"BlockedRedditors", @"GamesPreferences",
      @"GetRedditUsersByIds", @"SubredditsForNames", @"SubredditsForIds", @"ExposeExperimentBatch",
      @"GetProfilePostFlairTemplates", @"GetRedditorByNameApollo", @"GetActiveSubreddits",
      @"UserPublicTrophies", @"BrandToolsStatus", nil];

  assetBundles = [NSMutableArray array];
  assetCatalogs = [NSMutableArray array];
  [assetBundles addObject:NSBundle.mainBundle];

  // Reddit's asset catalogs: the app, its bundles, its frameworks and their bundles.
  NSFileManager *files = NSFileManager.defaultManager;
  NSString *appPath = NSBundle.mainBundle.bundlePath;
  for (NSString *file in [files contentsOfDirectoryAtPath:appPath error:nil]) {
    if (![file hasSuffix:@"bundle"]) continue;
    NSBundle *bundle = [NSBundle bundleWithPath:[appPath stringByAppendingPathComponent:file]];
    if (bundle) [assetBundles addObject:bundle];
  }
  NSString *frameworksPath = [appPath stringByAppendingPathComponent:@"Frameworks"];
  for (NSString *file in [files contentsOfDirectoryAtPath:frameworksPath error:nil]) {
    if (![file hasSuffix:@"framework"]) continue;
    NSString *frameworkPath = [frameworksPath stringByAppendingPathComponent:file];
    NSBundle *framework = [NSBundle bundleWithPath:frameworkPath];
    if (framework) [assetBundles addObject:framework];
    for (NSString *inner in [files contentsOfDirectoryAtPath:frameworkPath error:nil]) {
      if (![inner hasSuffix:@"bundle"]) continue;
      NSBundle *bundle = [NSBundle bundleWithPath:[frameworkPath stringByAppendingPathComponent:inner]];
      if (bundle) [assetBundles addObject:bundle];
    }
  }
  // Reddit 2026.38 keeps its icons in RPLIcons_AssetsBundle (measured).
  for (NSBundle *bundle in assetBundles)
    if ([bundle.bundlePath.lastPathComponent isEqualToString:@"RPLIcons_AssetsBundle.bundle"]) gIconBundle = bundle;
  for (NSBundle *bundle in assetBundles) {
    NSError *error;
    CUICatalog *catalog = [[%c(CUICatalog) alloc] initWithName:@"Assets" fromBundle:bundle error:&error];
    if (catalog && !error) [assetCatalogs addObject:catalog];
  }

  loadPreferences();
  CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsNotificationCallback,
                                  CFSTR(kPrimeDitPrefsNotification), NULL,
                                  CFNotificationSuspensionBehaviorCoalesce);
  %init;
  %init(Models, Comment = CoreClass(@"Comment"), Post = CoreClass(@"Post"));
}
