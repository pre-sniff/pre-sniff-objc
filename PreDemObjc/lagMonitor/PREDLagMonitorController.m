//
//  PREDLagMonitorController.m
//  Pods
//
//  Created by WangSiyu on 06/07/2017.
//  Copyright © 2017 pre-engineering. All rights reserved.
//

#import "PREDLagMonitorController.h"
#import <CrashReporter/CrashReporter.h>
#import "PREDCrashReportTextFormatter.h"
#import "PREDHelper.h"
#import <Qiniu/QiniuSDK.h>
#import "PREDLogger.h"

#define LagReportUploadRetryInterval        100
#define LagReportUploadMaxTimes             5

@implementation PREDLagMonitorController {
    CFRunLoopObserverRef _observer;
    dispatch_semaphore_t _semaphore;
    CFRunLoopActivity _activity;
    NSInteger _countTime;
    PREPLCrashReporter *_reporter;
    PREPLCrashReport *_lastReport;
    NSString *_appId;
    PREDNetworkClient *_networkClient;
    QNUploadManager *_uploadManager;
}

static void runLoopObserverCallBack(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info) {
    PREDLagMonitorController *instrance = (__bridge PREDLagMonitorController *)info;
    instrance->_activity = activity;
    // 发送信号
    dispatch_semaphore_t semaphore = instrance->_semaphore;
    dispatch_semaphore_signal(semaphore);
}

- (instancetype)initWithAppId:(NSString *)appId networkClient:(PREDNetworkClient *)networkClient {
    if (self = [super init]) {
        _reporter = [[PREPLCrashReporter alloc] initWithConfiguration:[PREPLCrashReporterConfig defaultConfiguration]];
        _appId = appId;
        _networkClient = networkClient;
        _uploadManager = [[QNUploadManager alloc] init];
    }
    return self;
}

- (void) startMonitor {
    if (_observer) {
        return;
    }
    [self registerObserver];
}

- (void) endMonitor {
    if (!_observer) {
        return;
    }
    CFRunLoopRemoveObserver(CFRunLoopGetMain(), _observer, kCFRunLoopCommonModes);
    CFRelease(_observer);
    _observer = NULL;
}

- (void)registerObserver {
    CFRunLoopObserverContext context = {0,(__bridge void*)self,NULL,NULL};
    _observer = CFRunLoopObserverCreate(kCFAllocatorDefault,
                                        kCFRunLoopAllActivities,
                                        YES,
                                        0,
                                        &runLoopObserverCallBack,
                                        &context);
    CFRunLoopAddObserver(CFRunLoopGetMain(), _observer, kCFRunLoopCommonModes);
    
    // 创建信号
    _semaphore = dispatch_semaphore_create(0);
    
    // 在子线程监控时长
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        while (YES) {
            // 假定连续5次超时50ms认为卡顿(当然也包含了单次超时250ms)
            long st = dispatch_semaphore_wait(_semaphore, dispatch_time(DISPATCH_TIME_NOW, 50*NSEC_PER_MSEC));
            if (st != 0) {
                if (_activity==kCFRunLoopBeforeSources || _activity==kCFRunLoopAfterWaiting) {
                    if (++_countTime < 5)
                        continue;
                    [self sendLagStack];
                }
            }
            _countTime = 0;
        }
    });
}

- (void)sendLagStack {
    NSError *err;
    NSData *data = [_reporter generateLiveReportAndReturnError:&err];
    if (err) {
        return;
    }
    
    PREPLCrashReport *report = [[PREPLCrashReport alloc] initWithData:data error:&err];
    if (err) {
        return;
    }
    if ([PREDCrashReportTextFormatter isReport:report euivalentWith:_lastReport]) {
        return;
    }
    _lastReport = report;
    [self uploadCrashLog:report retryTimes:0];
}

- (void)uploadCrashLog:(PREPLCrashReport *)report retryTimes:(NSUInteger)retryTimes {
    NSString *crashLog = [PREDCrashReportTextFormatter stringValueForCrashReport:report crashReporterKey:PREDHelper.appName];
    NSString *md5 = [PREDHelper MD5:crashLog];
    NSDictionary *param = @{@"md5": md5};
    [_networkClient getPath:@"lag-report-token/i" parameters:param completion:^(PREDHTTPOperation *operation, NSData *data, NSError *error) {
        if (!error) {
            NSDictionary *dic = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
            if (!error && dic && [dic respondsToSelector:@selector(valueForKey:)] && [dic valueForKey:@"token"]) {
                NSString *key = [NSString stringWithFormat:@"i/%@/%@", _appId, md5];
                [_uploadManager
                 putData:[crashLog dataUsingEncoding:NSUTF8StringEncoding]
                 key:key
                 token:[dic valueForKey:@"token"]
                 complete:^(QNResponseInfo *info, NSString *key, NSDictionary *resp) {
                     if (resp) {
                         [self sendMetaInfoWithKey:key crashUUID:(NSString *) CFBridgingRelease(CFUUIDCreateString(NULL, report.uuidRef)) retryTimes:0];
                     } else if (retryTimes < LagReportUploadMaxTimes) {
                         PREDLogWarning(@"upload log fail: %@, retry after: %d seconds", error, LagReportUploadMaxTimes);
                         dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(LagReportUploadRetryInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                             [self uploadCrashLog:report retryTimes:retryTimes+1];
                             return;
                         });
                     } else {
                         PREDLogError(@"upload log fail: %@, drop report", error);
                         return;
                     }
                 }
                 option:nil];
            } else {
                PREDLogError(@"get upload token fail: %@, drop report", error);
                return;
            }
        } else if (retryTimes < LagReportUploadMaxTimes) {
            PREDLogWarning(@"get upload token fail: %@, retry after: %d seconds", error, LagReportUploadMaxTimes);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(LagReportUploadRetryInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self uploadCrashLog:report retryTimes:retryTimes+1];
                return;
            });
        } else {
            PREDLogError(@"get upload token fail: %@, drop report", error);
            return;
        }
    }];
}

- (void)sendMetaInfoWithKey:(NSString *)key crashUUID:(NSString *)crashUUID retryTimes:(NSUInteger)retryTimes {
    NSDictionary *info = @{
                           @"app_bundle_id": PREDHelper.appBundleId,
                           @"app_name": PREDHelper.appName,
                           @"app_version": PREDHelper.appVersion,
                           @"device_model": PREDHelper.deviceModel,
                           @"os_platform": PREDHelper.osPlatform,
                           @"os_version": PREDHelper.osVersion,
                           @"sdk_version": PREDHelper.sdkVersion,
                           @"sdk_id": PREDHelper.UUID,
                           @"device_id": @"",
                           @"crash_uuid": crashUUID,
                           @"crash_log_key": key,
                           };
    [_networkClient postPath:@"lag-monitor/i" parameters:info completion:^(PREDHTTPOperation *operation, NSData *data, NSError *error) {
        if (!error) {
            PREDLogDebug(@"upload lag report succeed");
        } else if (retryTimes < LagReportUploadMaxTimes) {
            PREDLogWarning(@"upload lag metadata fail: %@, retry after: %d seconds", error, LagReportUploadMaxTimes);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(LagReportUploadRetryInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self sendMetaInfoWithKey:key crashUUID:crashUUID retryTimes:retryTimes+1];
                return;
            });
        } else {
            PREDLogError(@"upload lag metadata fail: %@, drop report", error);
            return;
        }
    }];
}

@end