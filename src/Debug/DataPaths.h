#import <Foundation/Foundation.h>

// Tracks the filter's fixed JSON addresses in Reddit's GraphQL responses and,
// when one misses, finds where the data moved, for the Compatibility report.

// Shape of the data expected at an address, which guides the search on a miss.
typedef NS_ENUM(NSInteger, PDDataShape) {
    PDDataShapeEdges = 0,   // array of `{ node: {...} }` (Home and Popular feeds)
    PDDataShapeTrees,       // array of comment-forest trees `{ node: {...} }`
    PDDataShapeNodeArray,   // array of post nodes, each with a `__typename`
    PDDataShapeCommentsAds, // array of comment ads, often empty
};

#if PRIMEDIT_DEBUG

// Keys of the dictionaries returned by -snapshot.
extern NSString *const kPDDataPathOperation;     // NSString, operation name
extern NSString *const kPDDataPathExpected;      // NSString, fixed address
extern NSString *const kPDDataPathHits;          // NSNumber, times it resolved
extern NSString *const kPDDataPathMisses;        // NSNumber, times it missed
extern NSString *const kPDDataPathDiscovered;    // NSString, address found after a miss
extern NSString *const kPDDataPathLastResolved;  // NSNumber (BOOL), last result
extern NSString *const kPDDataPathSeen;          // NSNumber (BOOL), response received
extern NSString *const kPDDataPathFailedJSON;    // NSString, response kept when nothing was found

@interface PDDataPathTracker : NSObject

+ (instancetype)shared;

// Records whether `expectedPath` resolved in `json`; on the first miss, searches
// `json` for data of the given shape. Thread-safe.
- (void)recordOperation:(NSString *)operation
           expectedPath:(NSString *)expectedPath
               resolved:(BOOL)resolved
                   json:(id)json
                  shape:(PDDataShape)shape;

// Stats per operation, known operations first. Thread-safe.
- (NSArray<NSDictionary *> *)snapshot;

// Clears the counters and the addresses found.
- (void)reset;

@end

#define PD_RECORD_DATA_PATH(operationName, path, didResolve, response, dataShape) \
  [[PDDataPathTracker shared] recordOperation:(operationName)                      \
                                 expectedPath:(path)                               \
                                     resolved:(didResolve)                         \
                                         json:(response)                           \
                                        shape:(dataShape)]

#else

// Release builds drop the call and its arguments entirely.
#define PD_RECORD_DATA_PATH(operationName, path, didResolve, response, dataShape) ((void)0)

#endif
