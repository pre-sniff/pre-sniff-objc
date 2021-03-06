//
//  PREDEvent.h
//  PreDemCocoa
//
//  Created by Troy on 2017/9/26.
//

#ifndef PREDEvent_h
#define PREDEvent_h

#import "PREDBaseModel.h"
#import <Foundation/Foundation.h>

/**
 * 自定义事件数据对象
 */
@interface PREDCustomEvent : PREDBaseModel <PREDSerializeData>

/**
 * 自定义事件的内容，仅支持键值对类型的内容
 */
@property(nonatomic, strong, readonly) NSString *content;

/**
 * 生成自定义事件的对象
 *
 * @param name 自定义事件的名称
 * @param contentDic 自定义事件的内容，仅支持键值对类型的内容，需要传入能够被
 * json 化的 NSDictionary 对象
 */
+ (instancetype)eventWithName:(NSString *)name
                   contentDic:(NSDictionary *)contentDic;

@end

@interface PREDEventQueue : NSObject

@property NSUInteger sizeThreshhold;
@property NSUInteger sendInterval;

- (void)trackCustomEvent:(PREDCustomEvent *_Nonnull)event;

@end

#endif /* PREDEvent_h */
