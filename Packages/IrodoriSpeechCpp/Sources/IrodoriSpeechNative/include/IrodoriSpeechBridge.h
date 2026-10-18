#import <Foundation/Foundation.h>
#import "ReazonSpeechBridge.h"
NS_ASSUME_NONNULL_BEGIN
/// Confine all methods except cancel to one inference queue. Always release before switching engines.
@interface IrodoriSpeechBridge : NSObject
- (nullable NSDictionary<NSString *, id> *)prepareModel:(NSString *)path metal4:(BOOL)metal4 error:(NSError **)error;
- (BOOL)registerReference:(nullable NSString *)path error:(NSError **)error;
- (nullable NSDictionary<NSString *, id> *)synthesize:(NSString *)text caption:(NSString *)caption seed:(uint32_t)seed onPcm:(void (^ _Nullable)(NSData *))onPcm error:(NSError **)error;
- (void)resetCancellation;
- (void)cancel;
- (void)releaseModel;
@end
NS_ASSUME_NONNULL_END
