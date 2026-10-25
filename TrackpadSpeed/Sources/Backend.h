#import <Foundation/Foundation.h>
@interface TSBackend : NSObject
@property(readonly) NSString *deviceName;
@property(readonly) BOOL hasRecovery;
@property(readonly) BOOL active;
- (BOOL)inspect:(NSError **)error;
- (BOOL)apply:(double)scale error:(NSError **)error;
- (BOOL)apply:(double)scale strength:(double)strength error:(NSError **)error;
- (NSDictionary *)previewBaseline:(NSError **)error;
- (BOOL)restore:(NSError **)error;
@end
