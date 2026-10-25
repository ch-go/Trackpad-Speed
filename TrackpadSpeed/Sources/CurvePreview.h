#import <Cocoa/Cocoa.h>
@interface TSCurvePreview : NSView
- (void)updateCurves:(NSArray *)curves index:(double)index scale:(double)scale strength:(double)strength;
@end
