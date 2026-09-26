#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import "fishhook/fishhook.h"

// Fixes for a re-signed Reddit (sideloaded IPA, or a .deb injected into one): identity,
// keychain and app groups under the new signature, reCAPTCHA, and App Attest reported as
// unsupported. An App Store install, as on a jailbroken device, is left untouched.

static NSString *const kPDTRedditBundleID = @"com.reddit.Reddit";
static NSString *const kPDTRedditTeamID = @"2TDUX39LX8";

static NSString *gSignedBundleID;
static NSString *gKeychainGroup;
static NSString *gRedditKeychainGroup;
static Class gRecaptchaMessageClass;

#pragma mark - Identity and app groups

%group SideloadHooks

// Code inside the app bundle reads Reddit's own identifier; system code reads the real one.
%hook NSBundle
- (NSString *)bundleIdentifier {
    NSArray<NSNumber *> *callers = NSThread.callStackReturnAddresses;
    Dl_info info;
    if (callers.count < 3 || !dladdr((void *)callers[2].unsignedLongValue, &info) || !info.dli_fname) return %orig;
    return [@(info.dli_fname) hasPrefix:NSBundle.mainBundle.bundlePath] ? kPDTRedditBundleID : %orig;
}

- (id)objectForInfoDictionaryKey:(NSString *)key {
    if ([key isEqualToString:@"CFBundleIdentifier"]) return kPDTRedditBundleID;
    if ([key isEqualToString:@"CFBundleDisplayName"] || [key isEqualToString:@"CFBundleName"]) return @"Reddit";
    return %orig;
}
%end

// Reddit's app group containers are out of reach; each one lives under Documents instead.
%hook NSFileManager
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    if (!groupIdentifier.length) return %orig;
    NSString *root = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/FakeGroupContainers"];
    NSURL *container = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:groupIdentifier] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:[container URLByAppendingPathComponent:@"Library/Caches"
                                                                                  isDirectory:YES]
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
    return container;
}
%end

%end

#pragma mark - Keychain

// A placeholder keychain item reveals the access group the new signature grants; the app
// still expects that group under Reddit's team identifier.
static void PDTLoadKeychainGroups(void) {
    NSDictionary *probe = @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount : @"dummyItem",
        (__bridge id)kSecAttrService : @"dummyService",
        (__bridge id)kSecReturnAttributes : @YES,
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)probe, &result);
    if (status == errSecItemNotFound) status = SecItemAdd((__bridge CFDictionaryRef)probe, &result);
    if (status == errSecSuccess && result && CFGetTypeID(result) == CFDictionaryGetTypeID()) {
        NSString *group = ((__bridge NSDictionary *)result)[(__bridge id)kSecAttrAccessGroup];
        if (group.length > kPDTRedditTeamID.length) {
            gKeychainGroup = group;
            gRedditKeychainGroup = [group stringByReplacingCharactersInRange:NSMakeRange(0, kPDTRedditTeamID.length)
                                                                  withString:kPDTRedditTeamID];
        }
    }
    if (result) CFRelease(result);
}

// A copy of `dictionary` whose access group is `group`, or NULL when nothing changes.
static CFDictionaryRef PDTCopyWithAccessGroup(CFDictionaryRef dictionary, NSString *group) {
    if (!dictionary || !group || !CFDictionaryContainsKey(dictionary, kSecAttrAccessGroup)) return NULL;
    CFMutableDictionaryRef copy = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, dictionary);
    CFDictionarySetValue(copy, kSecAttrAccessGroup, (__bridge CFStringRef)group);
    return copy;
}

// A successful result goes back to the app with Reddit's group, as the app wrote it.
static void PDTRestoreAccessGroup(OSStatus status, CFTypeRef *result) {
    if (status != errSecSuccess || !result || !*result || CFGetTypeID(*result) != CFDictionaryGetTypeID()) return;
    CFDictionaryRef restored = PDTCopyWithAccessGroup((CFDictionaryRef)*result, gRedditKeychainGroup);
    if (!restored) return;
    CFRelease(*result);
    *result = restored;
}

static OSStatus (*orig_SecItemAdd)(CFDictionaryRef, CFTypeRef *);
static OSStatus PDTSecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    CFDictionaryRef translated = PDTCopyWithAccessGroup(attributes, gKeychainGroup);
    OSStatus status = orig_SecItemAdd(translated ?: attributes, result);
    if (translated) CFRelease(translated);
    PDTRestoreAccessGroup(status, result);
    return status;
}

static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef, CFTypeRef *);
static OSStatus PDTSecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    CFDictionaryRef translated = PDTCopyWithAccessGroup(query, gKeychainGroup);
    OSStatus status = orig_SecItemCopyMatching(translated ?: query, result);
    if (translated) CFRelease(translated);
    PDTRestoreAccessGroup(status, result);
    return status;
}

static OSStatus (*orig_SecItemDelete)(CFDictionaryRef);
static OSStatus PDTSecItemDelete(CFDictionaryRef query) {
    CFDictionaryRef translated = PDTCopyWithAccessGroup(query, gKeychainGroup);
    OSStatus status = orig_SecItemDelete(translated ?: query);
    if (translated) CFRelease(translated);
    return status;
}

static OSStatus (*orig_SecItemUpdate)(CFDictionaryRef, CFDictionaryRef);
static OSStatus PDTSecItemUpdate(CFDictionaryRef query, CFDictionaryRef changes) {
    CFDictionaryRef translated = PDTCopyWithAccessGroup(query, gKeychainGroup);
    OSStatus status = orig_SecItemUpdate(translated ?: query, changes);
    if (translated) CFRelease(translated);
    return status;
}

#pragma mark - reCAPTCHA

// reCAPTCHA's protobuf messages (RCAx_GPBMessage subclasses) take the bundle identifier
// through one-object setters added at runtime; those setters receive Reddit's instead.
static void PDTRecaptchaSetter(id self, SEL _cmd, id value) {
    SEL original = NSSelectorFromString([@"orig_" stringByAppendingString:NSStringFromSelector(_cmd)]);
    Class cls = object_getClass(self);
    Method method = class_getInstanceMethod(cls, original);
    if (!method) {
        Method classMethod = class_getClassMethod(cls, original);
        if (classMethod) ((void (*)(id, SEL, id))method_getImplementation(classMethod))(self, original, value);
        return;
    }
    if ([value isKindOfClass:NSString.class] && [(NSString *)value isEqualToString:gSignedBundleID])
        value = kPDTRedditBundleID;
    ((void (*)(id, SEL, id))method_getImplementation(method))(self, original, value);
}

static BOOL (*orig_class_addMethod)(Class, SEL, IMP, const char *);
static BOOL PDTClassAddMethod(Class cls, SEL name, IMP imp, const char *types) {
    if (gRecaptchaMessageClass && types && class_getSuperclass(cls) == gRecaptchaMessageClass) {
        NSString *encoding = [@(types) stringByReplacingOccurrencesOfString:@"[0-9]+"
                                                                  withString:@""
                                                                     options:NSRegularExpressionSearch
                                                                       range:NSMakeRange(0, strlen(types))];
        if ([encoding isEqualToString:@"v@:@"]) {
            SEL original = NSSelectorFromString([@"orig_" stringByAppendingString:NSStringFromSelector(name)]);
            if (!orig_class_addMethod(cls, original, imp, types)) return orig_class_addMethod(cls, name, imp, types);
            imp = (IMP)PDTRecaptchaSetter;
        }
    }
    return orig_class_addMethod(cls, name, imp, types);
}

#pragma mark - App Attest

static NSError *PDTUnsupportedError(NSString *message) {
    return [NSError errorWithDomain:@"DCErrorDomain" code:1 userInfo:@{NSLocalizedDescriptionKey : message}];
}

static void PDTReplaceMethod(Class cls, SEL selector, id block) {
    Method method = class_getInstanceMethod(cls, selector);
    if (method) method_setImplementation(method, imp_implementationWithBlock(block));
}

// Without App Attest and DeviceCheck, Reddit falls back to its regular password sign-in.
static void PDTInstallAppAttestFix(void) {
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0);
    Class appAttest = objc_getClass("DCAppAttestService");
    if (appAttest) {
        PDTReplaceMethod(appAttest, @selector(isSupported), ^BOOL(id _self) { return NO; });
        PDTReplaceMethod(appAttest, @selector(generateKeyWithCompletionHandler:),
                         ^(id _self, void (^handler)(NSString *, NSError *)) {
            dispatch_async(queue, ^{
                handler(nil, PDTUnsupportedError(@"App Attest not supported"));
            });
        });
        PDTReplaceMethod(appAttest, @selector(attestKey:clientDataHash:completionHandler:),
                         ^(id _self, NSString *keyId, NSData *hash, void (^handler)(NSData *, NSError *)) {
            dispatch_async(queue, ^{
                handler(nil, PDTUnsupportedError(@"App Attest not supported"));
            });
        });
        PDTReplaceMethod(appAttest, @selector(generateAssertion:clientDataHash:completionHandler:),
                         ^(id _self, NSString *keyId, NSData *hash, void (^handler)(NSData *, NSError *)) {
            dispatch_async(queue, ^{
                handler(nil, PDTUnsupportedError(@"App Attest not supported"));
            });
        });
    }
    Class device = objc_getClass("DCDevice");
    if (device) {
        PDTReplaceMethod(device, @selector(isSupported), ^BOOL(id _self) { return NO; });
        PDTReplaceMethod(device, @selector(generateTokenWithCompletionHandler:),
                         ^(id _self, void (^handler)(NSData *, NSError *)) {
            dispatch_async(queue, ^{
                handler(nil, PDTUnsupportedError(@"DeviceCheck not supported"));
            });
        });
    }
}

#pragma mark - Setup

// A re-signed app always carries a provisioning profile; an App Store install never does.
static BOOL PDTAppIsResigned(void) {
    return [NSBundle.mainBundle pathForResource:@"embedded" ofType:@"mobileprovision"] != nil;
}

// Runs before PrimeDit's other constructors, so every fix is in place first.
__attribute__((constructor(101))) static void PDTSideloadInit(void) {
    if (!PDTAppIsResigned()) return;
    gSignedBundleID = NSBundle.mainBundle.bundleIdentifier;
    gRecaptchaMessageClass = objc_getClass("RCAx_GPBMessage");
    %init(SideloadHooks);
    PDTLoadKeychainGroups();
    rebind_symbols((struct rebinding[]){
                       {"SecItemAdd", (void *)PDTSecItemAdd, (void **)&orig_SecItemAdd},
                       {"SecItemCopyMatching", (void *)PDTSecItemCopyMatching, (void **)&orig_SecItemCopyMatching},
                       {"SecItemDelete", (void *)PDTSecItemDelete, (void **)&orig_SecItemDelete},
                       {"SecItemUpdate", (void *)PDTSecItemUpdate, (void **)&orig_SecItemUpdate},
                       {"class_addMethod", (void *)PDTClassAddMethod, (void **)&orig_class_addMethod},
                   },
                   5);
    PDTInstallAppAttestFix();
}
