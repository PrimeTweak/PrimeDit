#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import "fishhook/fishhook.h"

// Fixes for a re-signed Reddit (sideloaded IPA, or a .deb injected into one): identity,
// keychain and app groups under the new signature, reCAPTCHA, and App Attest reported as
// unsupported. An App Store install, as on a jailbroken device, is left untouched.

static NSString *const kPDRedditBundleID = @"com.reddit.Reddit";
static NSString *const kPDRedditTeamID = @"2TDUX39LX8";

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
    return [@(info.dli_fname) hasPrefix:NSBundle.mainBundle.bundlePath] ? kPDRedditBundleID : %orig;
}

- (id)objectForInfoDictionaryKey:(NSString *)key {
    if ([key isEqualToString:@"CFBundleIdentifier"]) return kPDRedditBundleID;
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
static void PDLoadKeychainGroups(void) {
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
        if (group.length > kPDRedditTeamID.length) {
            gKeychainGroup = group;
            gRedditKeychainGroup = [group stringByReplacingCharactersInRange:NSMakeRange(0, kPDRedditTeamID.length)
                                                                  withString:kPDRedditTeamID];
        }
    }
    if (result) CFRelease(result);
}

// A copy of `dictionary` whose access group is `group`, or NULL when nothing changes.
static CFDictionaryRef PDCopyWithAccessGroup(CFDictionaryRef dictionary, NSString *group) {
    if (!dictionary || !group || !CFDictionaryContainsKey(dictionary, kSecAttrAccessGroup)) return NULL;
    CFMutableDictionaryRef copy = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, dictionary);
    CFDictionarySetValue(copy, kSecAttrAccessGroup, (__bridge CFStringRef)group);
    return copy;
}

// A successful result goes back to the app with Reddit's group, as the app wrote it.
static void PDRestoreAccessGroup(OSStatus status, CFTypeRef *result) {
    if (status != errSecSuccess || !result || !*result || CFGetTypeID(*result) != CFDictionaryGetTypeID()) return;
    CFDictionaryRef restored = PDCopyWithAccessGroup((CFDictionaryRef)*result, gRedditKeychainGroup);
    if (!restored) return;
    CFRelease(*result);
    *result = restored;
}

static OSStatus (*orig_SecItemAdd)(CFDictionaryRef, CFTypeRef *);
static OSStatus PDSecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    CFDictionaryRef translated = PDCopyWithAccessGroup(attributes, gKeychainGroup);
    OSStatus status = orig_SecItemAdd(translated ?: attributes, result);
    if (translated) CFRelease(translated);
    PDRestoreAccessGroup(status, result);
    return status;
}

static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef, CFTypeRef *);
static OSStatus PDSecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    CFDictionaryRef translated = PDCopyWithAccessGroup(query, gKeychainGroup);
    OSStatus status = orig_SecItemCopyMatching(translated ?: query, result);
    if (translated) CFRelease(translated);
    PDRestoreAccessGroup(status, result);
    return status;
}

static OSStatus (*orig_SecItemDelete)(CFDictionaryRef);
static OSStatus PDSecItemDelete(CFDictionaryRef query) {
    CFDictionaryRef translated = PDCopyWithAccessGroup(query, gKeychainGroup);
    OSStatus status = orig_SecItemDelete(translated ?: query);
    if (translated) CFRelease(translated);
    return status;
}

static OSStatus (*orig_SecItemUpdate)(CFDictionaryRef, CFDictionaryRef);
static OSStatus PDSecItemUpdate(CFDictionaryRef query, CFDictionaryRef changes) {
    CFDictionaryRef translated = PDCopyWithAccessGroup(query, gKeychainGroup);
    OSStatus status = orig_SecItemUpdate(translated ?: query, changes);
    if (translated) CFRelease(translated);
    return status;
}

#pragma mark - reCAPTCHA

// reCAPTCHA's protobuf messages (RCAx_GPBMessage subclasses) take the bundle identifier
// through one-object setters added at runtime; those setters receive Reddit's instead.
static void PDRecaptchaSetter(id self, SEL _cmd, id value) {
    SEL original = NSSelectorFromString([@"orig_" stringByAppendingString:NSStringFromSelector(_cmd)]);
    Class cls = object_getClass(self);
    Method method = class_getInstanceMethod(cls, original);
    if (!method) {
        Method classMethod = class_getClassMethod(cls, original);
        if (classMethod) ((void (*)(id, SEL, id))method_getImplementation(classMethod))(self, original, value);
        return;
    }
    if ([value isKindOfClass:NSString.class] && [(NSString *)value isEqualToString:gSignedBundleID])
        value = kPDRedditBundleID;
    ((void (*)(id, SEL, id))method_getImplementation(method))(self, original, value);
}

static BOOL (*orig_class_addMethod)(Class, SEL, IMP, const char *);
static BOOL PDClassAddMethod(Class cls, SEL name, IMP imp, const char *types) {
    if (gRecaptchaMessageClass && types && class_getSuperclass(cls) == gRecaptchaMessageClass) {
        NSString *encoding = [@(types) stringByReplacingOccurrencesOfString:@"[0-9]+"
                                                                  withString:@""
                                                                     options:NSRegularExpressionSearch
                                                                       range:NSMakeRange(0, strlen(types))];
        if ([encoding isEqualToString:@"v@:@"]) {
            SEL original = NSSelectorFromString([@"orig_" stringByAppendingString:NSStringFromSelector(name)]);
            if (!orig_class_addMethod(cls, original, imp, types)) return orig_class_addMethod(cls, name, imp, types);
            imp = (IMP)PDRecaptchaSetter;
        }
    }
    return orig_class_addMethod(cls, name, imp, types);
}

#pragma mark - App Attest

static NSError *PDUnsupportedError(NSString *message) {
    return [NSError errorWithDomain:@"DCErrorDomain" code:1 userInfo:@{NSLocalizedDescriptionKey : message}];
}

static void PDReplaceMethod(Class cls, SEL selector, id block) {
    Method method = class_getInstanceMethod(cls, selector);
    if (method) method_setImplementation(method, imp_implementationWithBlock(block));
}

// Without App Attest and DeviceCheck, Reddit falls back to its regular password sign-in.
static void PDInstallAppAttestFix(void) {
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0);
    Class appAttest = objc_getClass("DCAppAttestService");
    if (appAttest) {
        PDReplaceMethod(appAttest, @selector(isSupported), ^BOOL(id _self) { return NO; });
        PDReplaceMethod(appAttest, @selector(generateKeyWithCompletionHandler:),
                        ^(id _self, void (^handler)(NSString *, NSError *)) {
            dispatch_async(queue, ^{
                handler(nil, PDUnsupportedError(@"App Attest not supported"));
            });
        });
        PDReplaceMethod(appAttest, @selector(attestKey:clientDataHash:completionHandler:),
                        ^(id _self, NSString *keyId, NSData *hash, void (^handler)(NSData *, NSError *)) {
            dispatch_async(queue, ^{
                handler(nil, PDUnsupportedError(@"App Attest not supported"));
            });
        });
        PDReplaceMethod(appAttest, @selector(generateAssertion:clientDataHash:completionHandler:),
                        ^(id _self, NSString *keyId, NSData *hash, void (^handler)(NSData *, NSError *)) {
            dispatch_async(queue, ^{
                handler(nil, PDUnsupportedError(@"App Attest not supported"));
            });
        });
    }
    Class device = objc_getClass("DCDevice");
    if (device) {
        PDReplaceMethod(device, @selector(isSupported), ^BOOL(id _self) { return NO; });
        PDReplaceMethod(device, @selector(generateTokenWithCompletionHandler:),
                        ^(id _self, void (^handler)(NSData *, NSError *)) {
            dispatch_async(queue, ^{
                handler(nil, PDUnsupportedError(@"DeviceCheck not supported"));
            });
        });
    }
}

#pragma mark - Setup

// A re-signed app always carries a provisioning profile; an App Store install never does.
static BOOL PDAppIsResigned(void) {
    return [NSBundle.mainBundle pathForResource:@"embedded" ofType:@"mobileprovision"] != nil;
}

// Runs before PrimeDit's other constructors, so every fix is in place first.
__attribute__((constructor(101))) static void PDSideloadInit(void) {
    if (!PDAppIsResigned()) return;
    gSignedBundleID = NSBundle.mainBundle.bundleIdentifier;
    gRecaptchaMessageClass = objc_getClass("RCAx_GPBMessage");
    %init(SideloadHooks);
    PDLoadKeychainGroups();
    rebind_symbols((struct rebinding[]){
                       {"SecItemAdd", (void *)PDSecItemAdd, (void **)&orig_SecItemAdd},
                       {"SecItemCopyMatching", (void *)PDSecItemCopyMatching, (void **)&orig_SecItemCopyMatching},
                       {"SecItemDelete", (void *)PDSecItemDelete, (void **)&orig_SecItemDelete},
                       {"SecItemUpdate", (void *)PDSecItemUpdate, (void **)&orig_SecItemUpdate},
                       {"class_addMethod", (void *)PDClassAddMethod, (void **)&orig_class_addMethod},
                   },
                   5);
    PDInstallAppAttestFix();
}
