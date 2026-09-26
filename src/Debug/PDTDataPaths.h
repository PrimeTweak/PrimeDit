#import <Foundation/Foundation.h>

// Tracks the filter's fixed JSON addresses in Reddit's GraphQL responses and,
// when one misses, finds where the data moved, for the Compatibility report.

// Shape of the data expected at an address, which guides the search on a miss.
typedef NS_ENUM(NSInteger, PDTDataShape) {
    PDTDataShapeEdges = 0,   // array of `{ node: {...} }` (Home and Popular feeds)
    PDTDataShapeTrees,       // array of comment-forest trees `{ node: {...} }`
    PDTDataShapeNodeArray,   // array of post nodes, each with a `__typename`
    PDTDataShapeCommentsAds, // array of comment ads, often empty
};

#if PRIMEDIT_DEBUG

// Keys of the dictionaries returned by -snapshot.
extern NSString *const kPDTDataPathOperation;     // NSString, operation name
extern NSString *const kPDTDataPathExpected;      // NSString, fixed address
extern NSString *const kPDTDataPathHits;          // NSNumber, times it resolved
extern NSString *const kPDTDataPathMisses;        // NSNumber, times it missed
extern NSString *const kPDTDataPathDiscovered;    // NSString, address found after a miss
extern NSString *const kPDTDataPathLastResolved;  // NSNumber (BOOL), last result
extern NSString *const kPDTDataPathSeen;          // NSNumber (BOOL), response received
extern NSString *const kPDTDataPathFailedJSON;    // NSString, response kept when nothing matched

@interface PDTDataPathTracker : NSObject

+ (instancetype)shared;

// Records whether `expectedPath` resolved in `json`; on the first miss, searches
// `json` for data of the given shape. Thread-safe.
- (void)recordOperation:(NSString *)operation
           expectedPath:(NSString *)expectedPath
               resolved:(BOOL)resolved
                   json:(id)json
                  shape:(PDTDataShape)shape;

// Stats per operation, known operations first. Thread-safe.
- (NSArray<NSDictionary *> *)snapshot;

// Clears the counters and the addresses found.
- (void)reset;

@end

#define PDT_RECORD_DATA_PATH(operationName, path, didResolve, response, dataShape) \
  [[PDTDataPathTracker shared] recordOperation:(operationName)                      \
                                  expectedPath:(path)                               \
                                     resolved:(didResolve)                         \
                                         json:(response)                           \
                                        shape:(dataShape)]

#else

// Release builds drop the call and its arguments entirely.
#define PDT_RECORD_DATA_PATH(operationName, path, didResolve, response, dataShape) ((void)0)

#endif
