#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "PDTIcons.h"

@interface CUICatalog : NSObject {
    NSBundle *_bundle;
}
- (NSArray<NSString *> *)allImageNames;
- (instancetype)initWithName:(NSString *)name fromBundle:(NSBundle *)bundle error:(NSError **)error;
@end

// Icons already looked up.
static NSCache *imageCache;
static NSMutableArray<NSBundle *> *assetBundles;
// Reddit's icons share one catalog, tried first; it is also the bundle that provided the last icon.
static NSBundle *gIconBundle;
static NSMutableArray<CUICatalog *> *assetCatalogs;

// Looks an icon up in Reddit's asset catalogs.
static UIImage *PDTFindIcon(NSString *iconName) {
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

UIImage *PDTIconWithName(NSString *iconName) {
    if (!iconName) return nil;
    UIImage *cachedImage = [imageCache objectForKey:iconName];
    if (cachedImage) return cachedImage;
    UIImage *image = PDTFindIcon(iconName);
    if (image) [imageCache setObject:image forKey:iconName];
    return image;
}

void PDTLoadIconCatalogs(void) {
    imageCache = [[NSCache alloc] init];
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
}
