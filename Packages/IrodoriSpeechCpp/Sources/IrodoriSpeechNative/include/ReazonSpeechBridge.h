#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Confine prepare/transcribe/release to one queue. cancel is thread safe.
@interface ReazonSpeechBridge : NSObject
- (nullable NSDictionary<NSString *, id> *)prepareModel:(NSString *)path preferGpuGreedy:(BOOL)preferGpuGreedy error:(NSError **)error;
- (nullable NSDictionary<NSString *, id> *)transcribe:(NSData *)pcm16 decoding:(NSString *)decoding error:(NSError **)error;
- (void)resetCancellation;
- (void)cancel;
- (void)releaseModel;
@end
NS_ASSUME_NONNULL_END
