#import <Foundation/Foundation.h>
@interface TSPointerTrace : NSObject
@property(readonly) BOOL running;
- (BOOL)start:(NSError **)error;
- (void)stop;
@end
