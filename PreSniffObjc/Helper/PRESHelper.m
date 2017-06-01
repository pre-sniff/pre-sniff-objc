/*
 * Author: Andreas Linde <mail@andreaslinde.de>
 *
 * Copyright (c) 2012-2014 HockeyApp, Bit Stadium GmbH.
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated documentation
 * files (the "Software"), to deal in the Software without
 * restriction, including without limitation the rights to use,
 * copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following
 * conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 * OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 */


#import "PRESHelper.h"
#import "PRESKeychainUtils.h"
#import "PreSniffObjc.h"
#import "PRESPrivate.h"
#import "PRESVersion.h"
#import <QuartzCore/QuartzCore.h>
#import <sys/sysctl.h>

static NSString *const kPRESUtcDateFormatter = @"utcDateFormatter";
NSString *const kPRESExcludeApplicationSupportFromBackup = @"kPRESExcludeApplicationSupportFromBackup";

@implementation PRESHelper

+ (BOOL)isURLSessionSupported {
    id nsurlsessionClass = NSClassFromString(@"NSURLSessionUploadTask");
    BOOL isUrlSessionSupported = (nsurlsessionClass && !pres_isRunningInAppExtension());
    return isUrlSessionSupported;
}

+ (BOOL)isPhotoAccessPossible {
    if(pres_isPreiOS10Environment()) {
        return YES;
    }
    else {
        NSString *privacyDescription = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSPhotoLibraryUsageDescription"];
        BOOL privacyStringSet = (privacyDescription != nil) && (privacyDescription.length > 0);
        
        return privacyStringSet;
    }
}

@end

#if __IPHONE_OS_VERSION_MAX_ALLOWED < 70000
@interface NSData (PRESSDKiOS7)
- (NSString *)base64Encoding;
@end
#endif

typedef struct {
    uint8_t       info_version;
    const char    pres_version[16];
    const char    pres_build[16];
} pres_info_t;

#pragma mark - Helpers

NSString *pres_settingsDir(void) {
    static NSString *settingsDir = nil;
    static dispatch_once_t predSettingsDir;
    
    dispatch_once(&predSettingsDir, ^{
        NSFileManager *fileManager = [[NSFileManager alloc] init];
        
        // temporary directory for crashes grabbed from PLCrashReporter
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        settingsDir = [[paths objectAtIndex:0] stringByAppendingPathComponent:PRES_IDENTIFIER];
        
        if (![fileManager fileExistsAtPath:settingsDir]) {
            NSDictionary *attributes = [NSDictionary dictionaryWithObject: [NSNumber numberWithUnsignedLong: 0755] forKey: NSFilePosixPermissions];
            NSError *theError = NULL;
            
            [fileManager createDirectoryAtPath:settingsDir withIntermediateDirectories: YES attributes: attributes error: &theError];
        }
    });
    
    return settingsDir;
}

BOOL pres_validateEmail(NSString *email) {
    NSString *emailRegex =
    @"(?:[a-z0-9!#$%\\&'*+/=?\\^_`{|}~-]+(?:\\.[a-z0-9!#$%\\&'*+/=?\\^_`{|}"
    @"~-]+)*|\"(?:[\\x01-\\x08\\x0b\\x0c\\x0e-\\x1f\\x21\\x23-\\x5b\\x5d-\\"
    @"x7f]|\\\\[\\x01-\\x09\\x0b\\x0c\\x0e-\\x7f])*\")@(?:(?:[a-z0-9](?:[a-"
    @"z0-9-]*[a-z0-9])?\\.)+[a-z0-9](?:[a-z0-9-]*[a-z0-9])?|\\[(?:(?:25[0-5"
    @"]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-"
    @"9][0-9]?|[a-z0-9-]*[a-z0-9]:(?:[\\x01-\\x08\\x0b\\x0c\\x0e-\\x1f\\x21"
    @"-\\x5a\\x53-\\x7f]|\\\\[\\x01-\\x09\\x0b\\x0c\\x0e-\\x7f])+)\\])";
    NSPredicate *emailTest = [NSPredicate predicateWithFormat:@"SELF MATCHES[c] %@", emailRegex];
    
    return [emailTest evaluateWithObject:email];
}

NSString *pres_keychainPreSniffObjcServiceName(void) {
    static NSString *serviceName = nil;
    static dispatch_once_t predServiceName;
    
    dispatch_once(&predServiceName, ^{
        serviceName = [NSString stringWithFormat:@"%@.PreSniffObjc", pres_mainBundleIdentifier()];
    });
    
    return serviceName;
}

NSComparisonResult pres_versionCompare(NSString *stringA, NSString *stringB) {
    // Extract plain version number from self
    NSString *plainSelf = stringA;
    NSRange letterRange = [plainSelf rangeOfCharacterFromSet: [NSCharacterSet letterCharacterSet]];
    if (letterRange.length)
        plainSelf = [plainSelf substringToIndex: letterRange.location];
    
    // Extract plain version number from other
    NSString *plainOther = stringB;
    letterRange = [plainOther rangeOfCharacterFromSet: [NSCharacterSet letterCharacterSet]];
    if (letterRange.length)
        plainOther = [plainOther substringToIndex: letterRange.location];
    
    // Compare plain versions
    NSComparisonResult result = [plainSelf compare:plainOther options:NSNumericSearch];
    
    // If plain versions are equal, compare full versions
    if (result == NSOrderedSame)
        result = [stringA compare:stringB options:NSNumericSearch];
    
    // Done
    return result;
}

#pragma mark Exclude from backup fix

void pres_fixBackupAttributeForURL(NSURL *directoryURL) {
    
    BOOL shouldExcludeAppSupportDirFromBackup = [[NSUserDefaults standardUserDefaults] boolForKey:kPRESExcludeApplicationSupportFromBackup];
    if (shouldExcludeAppSupportDirFromBackup) {
        return;
    }
    
    if (directoryURL) {
        NSError *getResourceError = nil;
        NSNumber *appSupportDirExcludedValue;
        
        if ([directoryURL getResourceValue:&appSupportDirExcludedValue forKey:NSURLIsExcludedFromBackupKey error:&getResourceError] && appSupportDirExcludedValue) {
            NSError *setResourceError = nil;
            [directoryURL setResourceValue:@NO forKey:NSURLIsExcludedFromBackupKey error:&setResourceError];
        }
    }
}

#pragma mark Identifiers

NSString *pres_mainBundleIdentifier(void) {
    return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleIdentifier"];
}

NSString *pres_encodeAppIdentifier(NSString *inputString) {
    return (inputString ? pres_URLEncodedString(inputString) : pres_URLEncodedString(pres_mainBundleIdentifier()));
}

NSString *pres_appName(NSString *placeHolderString) {
    NSString *appName = [[[NSBundle mainBundle] localizedInfoDictionary] objectForKey:@"CFBundleDisplayName"];
    if (!appName)
        appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"];
    if (!appName)
        appName = [[[NSBundle mainBundle] localizedInfoDictionary] objectForKey:@"CFBundleName"];
    if (!appName)
        appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"] ?: placeHolderString;
    
    return appName;
}

NSString *pres_UUIDPreiOS6(void) {
    // Create a new UUID
    CFUUIDRef uuidObj = CFUUIDCreate(nil);
    
    // Get the string representation of the UUID
    NSString *resultUUID = (NSString*)CFBridgingRelease(CFUUIDCreateString(nil, uuidObj));
    CFRelease(uuidObj);
    
    return resultUUID;
}

NSString *pres_UUID(void) {
    NSString *resultUUID = nil;
    
    if ([NSUUID class]) {
        resultUUID = [[NSUUID UUID] UUIDString];
    } else {
        resultUUID = pres_UUIDPreiOS6();
    }
    
    return resultUUID;
}

NSString *pres_appAnonID(BOOL forceNewAnonID) {
    static NSString *appAnonID = nil;
    static dispatch_once_t predAppAnonID;
    __block NSError *error = nil;
    NSString *appAnonIDKey = @"appAnonID";
    
    if (forceNewAnonID) {
        appAnonID = pres_UUID();
        // store this UUID in the keychain (on this device only) so we can be sure to always have the same ID upon app startups
        if (appAnonID) {
            // add to keychain in a background thread, since we got reports that storing to the keychain may take several seconds sometimes and cause the app to be killed
            // and we don't care about the result anyway
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                [PRESKeychainUtils storeUsername:appAnonIDKey
                                     andPassword:appAnonID
                                  forServiceName:pres_keychainPreSniffObjcServiceName()
                                  updateExisting:YES
                                   accessibility:kSecAttrAccessibleAlwaysThisDeviceOnly
                                           error:&error];
            });
        }
    } else {
        dispatch_once(&predAppAnonID, ^{
            // first check if we already have an install string in the keychain
            appAnonID = [PRESKeychainUtils getPasswordForUsername:appAnonIDKey andServiceName:pres_keychainPreSniffObjcServiceName() error:&error];
            
            if (!appAnonID) {
                appAnonID = pres_UUID();
                // store this UUID in the keychain (on this device only) so we can be sure to always have the same ID upon app startups
                if (appAnonID) {
                    // add to keychain in a background thread, since we got reports that storing to the keychain may take several seconds sometimes and cause the app to be killed
                    // and we don't care about the result anyway
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                        [PRESKeychainUtils storeUsername:appAnonIDKey
                                             andPassword:appAnonID
                                          forServiceName:pres_keychainPreSniffObjcServiceName()
                                          updateExisting:YES
                                           accessibility:kSecAttrAccessibleAlwaysThisDeviceOnly
                                                   error:&error];
                    });
                }
            }
        });
    }
    
    return appAnonID;
}

#pragma mark Environment detection

BOOL pres_isPreiOS7Environment(void) {
    static BOOL isPreiOS7Environment = YES;
    static dispatch_once_t checkOS;
    
    dispatch_once(&checkOS, ^{
        // NSFoundationVersionNumber_iOS_6_1 = 993.00
        // We hardcode this, so compiling with iOS 6 is possible while still being able to detect the correct environment
        
        // runtime check according to
        // https://developer.apple.com/library/prerelease/ios/documentation/UserExperience/Conceptual/TransitionGuide/SupportingEarlieriOS.html
        if (floor(NSFoundationVersionNumber) <= 993.00) {
            isPreiOS7Environment = YES;
        } else {
            isPreiOS7Environment = NO;
        }
    });
    
    return isPreiOS7Environment;
}

BOOL pres_isPreiOS8Environment(void) {
    static BOOL isPreiOS8Environment = YES;
    static dispatch_once_t checkOS8;
    
    dispatch_once(&checkOS8, ^{
        // NSFoundationVersionNumber_iOS_7_1 = 1047.25
        // We hardcode this, so compiling with iOS 7 is possible while still being able to detect the correct environment
        
        // runtime check according to
        // https://developer.apple.com/library/prerelease/ios/documentation/UserExperience/Conceptual/TransitionGuide/SupportingEarlieriOS.html
        if (floor(NSFoundationVersionNumber) <= 1047.25) {
            isPreiOS8Environment = YES;
        } else {
            isPreiOS8Environment = NO;
        }
    });
    
    return isPreiOS8Environment;
}

BOOL pres_isPreiOS10Environment(void) {
    static BOOL isPreOS10Environment = YES;
    static dispatch_once_t checkOS10;
    
    dispatch_once(&checkOS10, ^{
        // NSFoundationVersionNumber_iOS_9_MAX = 1299
        // We hardcode this, so compiling with iOS 7 is possible while still being able to detect the correct environment
        
        // runtime check according to
        // https://developer.apple.com/library/prerelease/ios/documentation/UserExperience/Conceptual/TransitionGuide/SupportingEarlieriOS.html
        if (floor(NSFoundationVersionNumber) <= 1299.00) {
            isPreOS10Environment = YES;
        } else {
            isPreOS10Environment = NO;
        }
    });
    
    return isPreOS10Environment;
}


BOOL pres_isAppStoreReceiptSandbox(void) {
#if TARGET_OS_SIMULATOR
    return NO;
#else
    if (![NSBundle.mainBundle respondsToSelector:@selector(appStoreReceiptURL)]) {
        return NO;
    }
    NSURL *appStoreReceiptURL = NSBundle.mainBundle.appStoreReceiptURL;
    NSString *appStoreReceiptLastComponent = appStoreReceiptURL.lastPathComponent;
    
    BOOL isSandboxReceipt = [appStoreReceiptLastComponent isEqualToString:@"sandboxReceipt"];
    return isSandboxReceipt;
#endif
}

BOOL pres_hasEmbeddedMobileProvision(void) {
    BOOL hasEmbeddedMobileProvision = !![[NSBundle mainBundle] pathForResource:@"embedded" ofType:@"mobileprovision"];
    return hasEmbeddedMobileProvision;
}

PRESEnvironment pres_currentAppEnvironment(void) {
#if TARGET_OS_SIMULATOR
    return PRESEnvironmentOther;
#else
    
    // MobilePovision profiles are a clear indicator for Ad-Hoc distribution
    if (pres_hasEmbeddedMobileProvision()) {
        return PRESEnvironmentOther;
    }
    
    // TestFlight is only supported from iOS 8 onwards, so at this point we have to be in the AppStore
    if (floor(NSFoundationVersionNumber) <= NSFoundationVersionNumber_iOS_6_1) {
        return PRESEnvironmentAppStore;
    }
    
    if (pres_isAppStoreReceiptSandbox()) {
        return PRESEnvironmentTestFlight;
    }
    
    return PRESEnvironmentAppStore;
#endif
}

BOOL pres_isRunningInAppExtension(void) {
    static BOOL isRunningInAppExtension = NO;
    static dispatch_once_t checkAppExtension;
    
    dispatch_once(&checkAppExtension, ^{
        isRunningInAppExtension = ([[[NSBundle mainBundle] executablePath] rangeOfString:@".appex/"].location != NSNotFound);
    });
    
    return isRunningInAppExtension;
}

BOOL pres_isDebuggerAttached(void) {
    static BOOL debuggerIsAttached = NO;
    
    static dispatch_once_t debuggerPredicate;
    dispatch_once(&debuggerPredicate, ^{
        struct kinfo_proc info;
        size_t info_size = sizeof(info);
        int name[4];
        
        name[0] = CTL_KERN;
        name[1] = KERN_PROC;
        name[2] = KERN_PROC_PID;
        name[3] = getpid();
        
        if (sysctl(name, 4, &info, &info_size, NULL, 0) == -1) {
            PRESLogError(@"[PreSniffObjc] ERROR: Checking for a running debugger via sysctl() failed.");
            debuggerIsAttached = false;
        }
        
        if (!debuggerIsAttached && (info.kp_proc.p_flag & P_TRACED) != 0)
            debuggerIsAttached = true;
    });
    
    return debuggerIsAttached;
}

#pragma mark NSString helpers

NSString *pres_URLEncodedString(NSString *inputString) {
    
    // Requires iOS 7
    if ([inputString respondsToSelector:@selector(stringByAddingPercentEncodingWithAllowedCharacters:)]) {
        return [inputString stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet characterSetWithCharactersInString:@"!*'();:@&=+$,/?%#[] {}"].invertedSet];
        
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        return CFBridgingRelease(CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault,
                                                                         (__bridge CFStringRef)inputString,
                                                                         NULL,
                                                                         CFSTR("!*'();:@&=+$,/?%#[] {}"),
                                                                         kCFStringEncodingUTF8)
                                 );
#pragma clang diagnostic pop
    }
}

NSString *pres_base64String(NSData * data, unsigned long length) {
    SEL base64EncodingSelector = NSSelectorFromString(@"base64EncodedStringWithOptions:");
    if ([data respondsToSelector:base64EncodingSelector]) {
        return [data base64EncodedStringWithOptions:0];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        return [data base64Encoding];
#pragma clang diagnostic pop
    }
}

#pragma mark Context helpers

// Return ISO 8601 string representation of the date
NSString *pres_utcDateString(NSDate *date){
    static NSDateFormatter *dateFormatter;
    
    // NSDateFormatter is not thread-safe prior to iOS 7
    if (pres_isPreiOS7Environment()) {
        NSMutableDictionary *threadDictionary = [NSThread currentThread].threadDictionary;
        dateFormatter = threadDictionary[kPRESUtcDateFormatter];
        
        if (!dateFormatter) {
            dateFormatter = [NSDateFormatter new];
            NSLocale *enUSPOSIXLocale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
            dateFormatter.locale = enUSPOSIXLocale;
            dateFormatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
            dateFormatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
            threadDictionary[kPRESUtcDateFormatter] = dateFormatter;
        }
        
        NSString *dateString = [dateFormatter stringFromDate:date];
        
        return dateString;
    }
    
    static dispatch_once_t dateFormatterToken;
    dispatch_once(&dateFormatterToken, ^{
        NSLocale *enUSPOSIXLocale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        dateFormatter = [NSDateFormatter new];
        dateFormatter.locale = enUSPOSIXLocale;
        dateFormatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
        dateFormatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    });
    
    NSString *dateString = [dateFormatter stringFromDate:date];
    
    return dateString;
}

NSString *pres_devicePlatform(void) {
    
    size_t size;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    char *answer = (char*)malloc(size);
    if (answer == NULL)
        return @"";
    sysctlbyname("hw.machine", answer, &size, NULL, 0);
    NSString *platform = [NSString stringWithCString:answer encoding: NSUTF8StringEncoding];
    free(answer);
    return platform;
}

NSString *pres_deviceType(void){
    
    UIUserInterfaceIdiom idiom = [UIDevice currentDevice].userInterfaceIdiom;
    
    switch (idiom) {
        case UIUserInterfaceIdiomPad:
            return @"Tablet";
        case UIUserInterfaceIdiomPhone:
            return @"Phone";
        default:
            return @"Unknown";
    }
}

NSString *pres_osVersionBuild(void) {
    void *result = NULL;
    size_t result_len = 0;
    int ret;
    
    /* If our buffer is too small after allocation, loop until it succeeds -- the requested destination size
     * may change after each iteration. */
    do {
        /* Fetch the expected length */
        if ((ret = sysctlbyname("kern.osversion", NULL, &result_len, NULL, 0)) == -1) {
            break;
        }
        
        /* Allocate the destination buffer */
        if (result != NULL) {
            free(result);
        }
        result = malloc(result_len);
        
        /* Fetch the value */
        ret = sysctlbyname("kern.osversion", result, &result_len, NULL, 0);
    } while (ret == -1 && errno == ENOMEM);
    
    /* Handle failure */
    if (ret == -1) {
        int saved_errno = errno;
        
        if (result != NULL) {
            free(result);
        }
        
        errno = saved_errno;
        return NULL;
    }
    
    NSString *osBuild = [NSString stringWithCString:result encoding:NSUTF8StringEncoding];
    free(result);
    
    NSString *osVersion = [[UIDevice currentDevice] systemVersion];
    
    return [NSString stringWithFormat:@"%@ (%@)", osVersion, osBuild];
}

NSString *pres_osName(void){
    return [[UIDevice currentDevice] systemName];
}

NSString *pres_deviceLocale(void) {
    NSLocale *locale = [NSLocale currentLocale];
    return [locale objectForKey:NSLocaleIdentifier];
}

NSString *pres_deviceLanguage(void) {
    return [[NSBundle mainBundle] preferredLocalizations][0];
}

NSString *pres_screenSize(void){
    CGFloat scale = [UIScreen mainScreen].scale;
    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    return [NSString stringWithFormat:@"%dx%d",(int)(screenSize.height * scale), (int)(screenSize.width * scale)];
}

NSString *pres_sdkVersion(void){
    return [NSString stringWithFormat:@"ios:%@", [PRESVersion getSDKVersion]];
}

NSString *pres_appVersion(void){
    NSString *build = [[NSBundle mainBundle] infoDictionary][@"CFBundleVersion"];
    NSString *version = [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"];
    
    if(version){
        return [NSString stringWithFormat:@"%@ (%@)", version, build];
    }else{
        return build;
    }
}

#pragma mark AppIcon helpers

/**
 Find a valid app icon filename that points to a proper app icon image
 
 @param icons NSArray with app icon filenames
 
 @return NSString with the valid app icon or nil if none found
 */
NSString *pres_validAppIconStringFromIcons(NSBundle *resourceBundle, NSArray *icons) {
    if (!icons) return nil;
    if (![icons isKindOfClass:[NSArray class]]) return nil;
    
    BOOL useHighResIcon = NO;
    BOOL useiPadIcon = NO;
    if ([UIScreen mainScreen].scale >= 2.0f) useHighResIcon = YES;
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) useiPadIcon = YES;
    
    NSString *currentBestMatch = nil;
    float currentBestMatchHeight = 0;
    float bestMatchHeight = 0;
    
    if (pres_isPreiOS7Environment()) {
        bestMatchHeight = useiPadIcon ? (useHighResIcon ? 144 : 72) : (useHighResIcon ? 114 : 57);
    } else {
        bestMatchHeight = useiPadIcon ? (useHighResIcon ? 152 : 76) : 120;
    }
    
    for(NSString *icon in icons) {
        // Don't use imageNamed, otherwise unit tests won't find the fixture icon
        // and using imageWithContentsOfFile doesn't load @2x files with absolut paths (required in tests)
        
        
        NSMutableArray *iconFilenameVariants = [NSMutableArray new];
        
        [iconFilenameVariants addObject:icon];
        [iconFilenameVariants addObject:[NSString stringWithFormat:@"%@@2x", icon]];
        [iconFilenameVariants addObject:[icon stringByDeletingPathExtension]];
        [iconFilenameVariants addObject:[NSString stringWithFormat:@"%@@2x", [icon stringByDeletingPathExtension]]];
        
        for (NSString *iconFilename in iconFilenameVariants) {
            // this call already covers "~ipad" files
            NSString *iconPath = [resourceBundle pathForResource:iconFilename ofType:@"png"];
            
            if (!iconPath && (icon.pathExtension.length > 0)) {
                iconPath = [resourceBundle pathForResource:iconFilename ofType:icon.pathExtension];
            }
            // We still haven't managed to get a path to the app icon, just using a placeholder now.
            if(!iconPath) {
                iconPath = [resourceBundle pathForResource:@"AppIconPlaceHolder" ofType:@"png"];
            }
            
            NSData *imgData = [[NSData alloc] initWithContentsOfFile:iconPath];
            
            UIImage *iconImage = [[UIImage alloc] initWithData:imgData];
            
            if (iconImage) {
                if (iconImage.size.height == bestMatchHeight) {
                    return iconFilename;
                } else if (iconImage.size.height < bestMatchHeight &&
                           iconImage.size.height > currentBestMatchHeight) {
                    currentBestMatchHeight = iconImage.size.height;
                    currentBestMatch = iconFilename;
                }
            }
        }
    }
    
    return currentBestMatch;
}

NSString *pres_validAppIconFilename(NSBundle *bundle, NSBundle *resourceBundle) {
    NSString *iconFilename = nil;
    NSArray *icons = nil;
    
    icons = [bundle objectForInfoDictionaryKey:@"CFBundleIconFiles"];
    iconFilename = pres_validAppIconStringFromIcons(resourceBundle, icons);
    
    if (!iconFilename) {
        icons = [bundle objectForInfoDictionaryKey:@"CFBundleIcons"];
        if (icons && [icons isKindOfClass:[NSDictionary class]]) {
            icons = [icons valueForKeyPath:@"CFBundlePrimaryIcon.CFBundleIconFiles"];
        }
        iconFilename = pres_validAppIconStringFromIcons(resourceBundle, icons);
    }
    
    // we test iPad structure anyway and use it if we find a result and don't have another one yet
    if (!iconFilename && (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)) {
        icons = [bundle objectForInfoDictionaryKey:@"CFBundleIcons~ipad"];
        if (icons && [icons isKindOfClass:[NSDictionary class]]) {
            icons = [icons valueForKeyPath:@"CFBundlePrimaryIcon.CFBundleIconFiles"];
        }
        NSString *iPadIconFilename = pres_validAppIconStringFromIcons(resourceBundle, icons);
        iconFilename = iPadIconFilename;
    }
    
    if (!iconFilename) {
        NSString *tempFilename = [bundle objectForInfoDictionaryKey:@"CFBundleIconFile"];
        if (tempFilename) {
            iconFilename = pres_validAppIconStringFromIcons(resourceBundle, @[tempFilename]);
        }
    }
    
    if (!iconFilename) {
        iconFilename = pres_validAppIconStringFromIcons(resourceBundle, @[@"Icon.png"]);
    }
    
    return iconFilename;
}

#pragma mark UIImage private helpers

static void pres_addRoundedRectToPath(CGRect rect, CGContextRef context, CGFloat ovalWidth, CGFloat ovalHeight);
static CGContextRef pres_MyOpenBitmapContext(int pixelsWide, int pixelsHigh);
static CGImageRef pres_CreateGradientImage(int pixelsWide, int pixelsHigh, float fromAlpha, float toAlpha);
static BOOL pres_hasAlpha(UIImage *inputImage);
UIImage *pres_imageWithAlpha(UIImage *inputImage);
UIImage *pres_addGlossToImage(UIImage *inputImage);

// Adds a rectangular path to the given context and rounds its corners by the given extents
// Original author: Björn Sållarp. Used with permission. See: http://blog.sallarp.com/iphone-uiimage-round-corners/
void pres_addRoundedRectToPath(CGRect rect, CGContextRef context, CGFloat ovalWidth, CGFloat ovalHeight) {
    if (ovalWidth == 0 || ovalHeight == 0) {
        CGContextAddRect(context, rect);
        return;
    }
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, CGRectGetMinX(rect), CGRectGetMinY(rect));
    CGContextScaleCTM(context, ovalWidth, ovalHeight);
    CGFloat fw = CGRectGetWidth(rect) / ovalWidth;
    CGFloat fh = CGRectGetHeight(rect) / ovalHeight;
    CGContextMoveToPoint(context, fw, fh/2);
    CGContextAddArcToPoint(context, fw, fh, fw/2, fh, 1);
    CGContextAddArcToPoint(context, 0, fh, 0, fh/2, 1);
    CGContextAddArcToPoint(context, 0, 0, fw/2, 0, 1);
    CGContextAddArcToPoint(context, fw, 0, fw, fh/2, 1);
    CGContextClosePath(context);
    CGContextRestoreGState(context);
}

CGImageRef pres_CreateGradientImage(int pixelsWide, int pixelsHigh, float fromAlpha, float toAlpha) {
    CGImageRef theCGImage = NULL;
    
    // gradient is always black-white and the mask must be in the gray colorspace
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
    
    // create the bitmap context
    CGContextRef gradientBitmapContext = CGBitmapContextCreate(NULL, pixelsWide, pixelsHigh,
                                                               8, 0, colorSpace, (CGBitmapInfo)kCGImageAlphaNone);
    
    // define the start and end grayscale values (with the alpha, even though
    // our bitmap context doesn't support alpha the gradient requires it)
    CGFloat colors[] = {toAlpha, 1.0, fromAlpha, 1.0};
    
    // create the CGGradient and then release the gray color space
    CGGradientRef grayScaleGradient = CGGradientCreateWithColorComponents(colorSpace, colors, NULL, 2);
    CGColorSpaceRelease(colorSpace);
    
    // create the start and end points for the gradient vector (straight down)
    CGPoint gradientEndPoint = CGPointZero;
    CGPoint gradientStartPoint = CGPointMake(0, pixelsHigh);
    
    // draw the gradient into the gray bitmap context
    CGContextDrawLinearGradient(gradientBitmapContext, grayScaleGradient, gradientStartPoint,
                                gradientEndPoint, kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(grayScaleGradient);
    
    // convert the context into a CGImageRef and release the context
    theCGImage = CGBitmapContextCreateImage(gradientBitmapContext);
    CGContextRelease(gradientBitmapContext);
    
    // return the imageref containing the gradient
    return theCGImage;
}

CGContextRef pres_MyOpenBitmapContext(int pixelsWide, int pixelsHigh) {
    CGSize size = CGSizeMake(pixelsWide, pixelsHigh);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    
    return UIGraphicsGetCurrentContext();
}


// Returns true if the image has an alpha layer
BOOL pres_hasAlpha(UIImage *inputImage) {
    CGImageAlphaInfo alpha = CGImageGetAlphaInfo(inputImage.CGImage);
    return (alpha == kCGImageAlphaFirst ||
            alpha == kCGImageAlphaLast ||
            alpha == kCGImageAlphaPremultipliedFirst ||
            alpha == kCGImageAlphaPremultipliedLast);
}

// Returns a copy of the given image, adding an alpha channel if it doesn't already have one
UIImage *pres_imageWithAlpha(UIImage *inputImage) {
    if (pres_hasAlpha(inputImage)) {
        return inputImage;
    }
    
    CGImageRef imageRef = inputImage.CGImage;
    size_t width = CGImageGetWidth(imageRef) * inputImage.scale;
    size_t height = CGImageGetHeight(imageRef) * inputImage.scale;
    
    // The bitsPerComponent and bitmapInfo values are hard-coded to prevent an "unsupported parameter combination" error
    CGContextRef offscreenContext = CGBitmapContextCreate(NULL,
                                                          width,
                                                          height,
                                                          8,
                                                          0,
                                                          CGImageGetColorSpace(imageRef),
                                                          kCGBitmapByteOrderDefault | kCGImageAlphaPremultipliedFirst);
    
    // Draw the image into the context and retrieve the new image, which will now have an alpha layer
    CGContextDrawImage(offscreenContext, CGRectMake(0, 0, width, height), imageRef);
    CGImageRef imageRefWithAlpha = CGBitmapContextCreateImage(offscreenContext);
    UIImage *imageWithAlpha = [UIImage imageWithCGImage:imageRefWithAlpha];
    
    // Clean up
    CGContextRelease(offscreenContext);
    CGImageRelease(imageRefWithAlpha);
    
    return imageWithAlpha;
}

UIImage *pres_addGlossToImage(UIImage *inputImage) {
    UIGraphicsBeginImageContextWithOptions(inputImage.size, NO, 0.0);
    
    [inputImage drawAtPoint:CGPointZero];
    UIImage *iconGradient = pres_imageNamed(@"IconGradient.png", PRES_BUNDLE);
    [iconGradient drawInRect:CGRectMake(0, 0, inputImage.size.width, inputImage.size.height) blendMode:kCGBlendModeNormal alpha:0.5];
    
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    return result;
}

#pragma mark UIImage helpers

UIImage *pres_imageToFitSize(UIImage *inputImage, CGSize fitSize, BOOL honorScaleFactor) {
    
    if (!inputImage){
        return nil;
    }
    
    float imageScaleFactor = 1.0;
    if (honorScaleFactor) {
        if ([inputImage respondsToSelector:@selector(scale)]) {
            imageScaleFactor = [inputImage scale];
        }
    }
    
    float sourceWidth = [inputImage size].width * imageScaleFactor;
    float sourceHeight = [inputImage size].height * imageScaleFactor;
    float targetWidth = fitSize.width;
    float targetHeight = fitSize.height;
    
    // Calculate aspect ratios
    float sourceRatio = sourceWidth / sourceHeight;
    float targetRatio = targetWidth / targetHeight;
    
    // Determine what side of the source image to use for proportional scaling
    BOOL scaleWidth = (sourceRatio <= targetRatio);
    // Deal with the case of just scaling proportionally to fit, without cropping
    scaleWidth = !scaleWidth;
    
    // Proportionally scale source image
    float scalingFactor, scaledWidth, scaledHeight;
    if (scaleWidth) {
        scalingFactor = 1.0 / sourceRatio;
        scaledWidth = targetWidth;
        scaledHeight = round(targetWidth * scalingFactor);
    } else {
        scalingFactor = sourceRatio;
        scaledWidth = round(targetHeight * scalingFactor);
        scaledHeight = targetHeight;
    }
    
    // Calculate compositing rectangles
    CGRect sourceRect, destRect;
    sourceRect = CGRectMake(0, 0, sourceWidth, sourceHeight);
    destRect = CGRectMake(0, 0, scaledWidth, scaledHeight);
    
    // Create appropriately modified image.
    UIImage *image = nil;
    UIGraphicsBeginImageContextWithOptions(destRect.size, NO, honorScaleFactor ? 0.0 : 1.0); // 0.0 for scale means "correct scale for device's main screen".
    CGImageRef sourceImg = CGImageCreateWithImageInRect([inputImage CGImage], sourceRect); // cropping happens here.
    image = [UIImage imageWithCGImage:sourceImg scale:0.0 orientation:inputImage.imageOrientation]; // create cropped UIImage.
    [image drawInRect:destRect]; // the actual scaling happens here, and orientation is taken care of automatically.
    CGImageRelease(sourceImg);
    image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    if (!image) {
        // Try older method.
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(NULL,  scaledWidth, scaledHeight, 8, (fitSize.width * 4),
                                                     colorSpace, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        sourceImg = CGImageCreateWithImageInRect([inputImage CGImage], sourceRect);
        CGContextDrawImage(context, destRect, sourceImg);
        CGImageRelease(sourceImg);
        CGImageRef finalImage = CGBitmapContextCreateImage(context);
        CGContextRelease(context);
        CGColorSpaceRelease(colorSpace);
        image = [UIImage imageWithCGImage:finalImage];
        CGImageRelease(finalImage);
    }
    
    return image;
}


UIImage *pres_reflectedImageWithHeight(UIImage *inputImage, NSUInteger height, float fromAlpha, float toAlpha) {
    if(height == 0)
        return nil;
    
    // create a bitmap graphics context the size of the image
    CGContextRef mainViewContentContext = pres_MyOpenBitmapContext(inputImage.size.width, (int)height);
    
    // create a 2 bit CGImage containing a gradient that will be used for masking the
    // main view content to create the 'fade' of the reflection.  The CGImageCreateWithMask
    // function will stretch the bitmap image as required, so we can create a 1 pixel wide gradient
    CGImageRef gradientMaskImage = pres_CreateGradientImage(1, (int)height, fromAlpha, toAlpha);
    
    // create an image by masking the bitmap of the mainView content with the gradient view
    // then release the  pre-masked content bitmap and the gradient bitmap
    CGContextClipToMask(mainViewContentContext, CGRectMake(0.0, 0.0, inputImage.size.width, height), gradientMaskImage);
    CGImageRelease(gradientMaskImage);
    
    // draw the image into the bitmap context
    CGContextDrawImage(mainViewContentContext, CGRectMake(0, 0, inputImage.size.width, inputImage.size.height), inputImage.CGImage);
    
    // convert the finished reflection image to a UIImage
    UIImage *theImage = UIGraphicsGetImageFromCurrentImageContext(); // returns autoreleased
    UIGraphicsEndImageContext();
    
    return theImage;
}


UIImage *pres_newWithContentsOfResolutionIndependentFile(NSString * path) {
    if ([UIScreen instancesRespondToSelector:@selector(scale)] && (int)[[UIScreen mainScreen] scale] == 2.0) {
        NSString *path2x = [[path stringByDeletingLastPathComponent]
                            stringByAppendingPathComponent:[NSString stringWithFormat:@"%@@2x.%@",
                                                            [[path lastPathComponent] stringByDeletingPathExtension],
                                                            [path pathExtension]]];
        
        if ([[NSFileManager defaultManager] fileExistsAtPath:path2x]) {
            return [[UIImage alloc] initWithContentsOfFile:path2x];
        }
    }
    
    return [[UIImage alloc] initWithContentsOfFile:path];
}


UIImage *pres_imageWithContentsOfResolutionIndependentFile(NSString *path) {
    return pres_newWithContentsOfResolutionIndependentFile(path);
}


UIImage *pres_imageNamed(NSString *imageName, NSString *bundleName) {
    NSString *resourcePath = [[NSBundle bundleForClass:[PRESManager class]] resourcePath];
    NSString *bundlePath = [resourcePath stringByAppendingPathComponent:bundleName];
    NSString *imagePath = [bundlePath stringByAppendingPathComponent:imageName];
    return pres_imageWithContentsOfResolutionIndependentFile(imagePath);
}



// Creates a copy of this image with rounded corners
// If borderSize is non-zero, a transparent border of the given size will also be added
// Original author: Björn Sållarp. Used with permission. See: http://blog.sallarp.com/iphone-uiimage-round-corners/
UIImage *pres_roundedCornerImage(UIImage *inputImage, NSInteger cornerSize, NSInteger borderSize) {
    // If the image does not have an alpha layer, add one
    
    UIImage *roundedImage = nil;
    UIGraphicsBeginImageContextWithOptions(inputImage.size, NO, 0.0); // 0.0 for scale means "correct scale for device's main screen".
    CGImageRef sourceImg = CGImageCreateWithImageInRect([inputImage CGImage], CGRectMake(0, 0, inputImage.size.width * inputImage.scale, inputImage.size.height * inputImage.scale)); // cropping happens here.
    
    // Create a clipping path with rounded corners
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextBeginPath(context);
    pres_addRoundedRectToPath(CGRectMake(borderSize, borderSize, inputImage.size.width - borderSize * 2, inputImage.size.height - borderSize * 2), context, cornerSize, cornerSize);
    CGContextClosePath(context);
    CGContextClip(context);
    
    roundedImage = [UIImage imageWithCGImage:sourceImg scale:0.0 orientation:inputImage.imageOrientation]; // create cropped UIImage.
    [roundedImage drawInRect:CGRectMake(0, 0, inputImage.size.width, inputImage.size.height)]; // the actual scaling happens here, and orientation is taken care of automatically.
    CGImageRelease(sourceImg);
    roundedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    if (!roundedImage) {
        // Try older method.
        UIImage *image = pres_imageWithAlpha(inputImage);
        
        // Build a context that's the same dimensions as the new size
        context = CGBitmapContextCreate(NULL,
                                        image.size.width,
                                        image.size.height,
                                        CGImageGetBitsPerComponent(image.CGImage),
                                        0,
                                        CGImageGetColorSpace(image.CGImage),
                                        CGImageGetBitmapInfo(image.CGImage));
        
        // Create a clipping path with rounded corners
        CGContextBeginPath(context);
        pres_addRoundedRectToPath(CGRectMake(borderSize, borderSize, image.size.width - borderSize * 2, image.size.height - borderSize * 2), context, cornerSize, cornerSize);
        CGContextClosePath(context);
        CGContextClip(context);
        
        // Draw the image to the context; the clipping path will make anything outside the rounded rect transparent
        CGContextDrawImage(context, CGRectMake(0, 0, image.size.width, image.size.height), image.CGImage);
        
        // Create a CGImage from the context
        CGImageRef clippedImage = CGBitmapContextCreateImage(context);
        CGContextRelease(context);
        
        // Create a UIImage from the CGImage
        roundedImage = [UIImage imageWithCGImage:clippedImage];
        CGImageRelease(clippedImage);
    }
    
    return roundedImage;
}

UIImage *pres_appIcon() {
    NSString *iconString = [NSString string];
    NSArray *icons = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleIconFiles"];
    if (!icons) {
        icons = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleIcons"];
        if ((icons) && ([icons isKindOfClass:[NSDictionary class]])) {
            icons = [icons valueForKeyPath:@"CFBundlePrimaryIcon.CFBundleIconFiles"];
        }
        
        if (!icons) {
            iconString = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleIconFile"];
            if (!iconString) {
                iconString = @"Icon.png";
            }
        }
    }
    
    if (icons) {
        BOOL useHighResIcon = NO;
        if ([UIScreen mainScreen].scale >= 2.0f) useHighResIcon = YES;
        
        for(NSString *icon in icons) {
            iconString = icon;
            UIImage *iconImage = [UIImage imageNamed:icon];
            
            if (iconImage.size.height == 57 && !useHighResIcon) {
                // found!
                break;
            }
            if (iconImage.size.height == 114 && useHighResIcon) {
                // found!
                break;
            }
        }
    }
    
    BOOL addGloss = YES;
    NSNumber *prerendered = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"UIPrerenderedIcon"];
    if (prerendered) {
        addGloss = ![prerendered boolValue];
    }
    
    if (addGloss) {
        return pres_addGlossToImage([UIImage imageNamed:iconString]);
    } else {
        return [UIImage imageNamed:iconString];
    }
}

UIImage *pres_screenshot(void) {
    // Create a graphics context with the target size
    CGSize imageSize = [[UIScreen mainScreen] bounds].size;
    BOOL isLandscapeLeft = [UIApplication sharedApplication].statusBarOrientation == UIInterfaceOrientationLandscapeLeft;
    BOOL isLandscapeRight = [UIApplication sharedApplication].statusBarOrientation == UIInterfaceOrientationLandscapeRight;
    BOOL isUpsideDown = [UIApplication sharedApplication].statusBarOrientation == UIInterfaceOrientationPortraitUpsideDown;
    
    BOOL needsRotation = NO;
    
    if ((isLandscapeLeft ||isLandscapeRight) && imageSize.height > imageSize.width) {
        needsRotation = YES;
        CGFloat temp = imageSize.width;
        imageSize.width = imageSize.height;
        imageSize.height = temp;
    }
    
    UIGraphicsBeginImageContextWithOptions(imageSize, YES, 0);
    
    CGContextRef context = UIGraphicsGetCurrentContext();
    
    // Iterate over every window from back to front
    //NSInteger count = 0;
    for (UIWindow *window in [[UIApplication sharedApplication] windows])  {
        if (![window respondsToSelector:@selector(screen)] || [window screen] == [UIScreen mainScreen]) {
            // -renderInContext: renders in the coordinate space of the layer,
            // so we must first apply the layer's geometry to the graphics context
            CGContextSaveGState(context);
            
            // Center the context around the window's anchor point
            CGContextTranslateCTM(context, [window center].x, [window center].y);
            
            // Apply the window's transform about the anchor point
            CGContextConcatCTM(context, [window transform]);
            
            // Offset by the portion of the bounds left of and above the anchor point
            CGContextTranslateCTM(context,
                                  -[window bounds].size.width * [[window layer] anchorPoint].x,
                                  -[window bounds].size.height * [[window layer] anchorPoint].y);
            
            if (needsRotation) {
                if (isLandscapeLeft) {
                    CGContextConcatCTM(context, CGAffineTransformRotate(CGAffineTransformMakeTranslation( imageSize.width, 0), M_PI / 2.0));
                } else if (isLandscapeRight) {
                    CGContextConcatCTM(context, CGAffineTransformRotate(CGAffineTransformMakeTranslation( 0, imageSize.height), 3 * M_PI / 2.0));
                }
            } else if (isUpsideDown) {
                CGContextConcatCTM(context, CGAffineTransformRotate(CGAffineTransformMakeTranslation( imageSize.width, imageSize.height), M_PI));
            }
            
            if ([window respondsToSelector:@selector(drawViewHierarchyInRect:afterScreenUpdates:)]) {
                [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
            } else {
                // Render the layer hierarchy to the current context
                [[window layer] renderInContext:context];
            }
            
            // Restore the context
            CGContextRestoreGState(context);
        }
    }
    
    // Retrieve the screenshot image
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    
    UIGraphicsEndImageContext();
    
    return image;
}

