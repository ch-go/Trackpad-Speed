#import "CurvePreview.h"
#import "Curve.h"
@interface TSCurvePreview ()
@property NSArray<NSNumber *> *baseline;
@property NSArray<NSNumber *> *proposed;
@property double referenceOutput;
@property BOOL hasReference;
@end
@implementation TSCurvePreview
static NSDictionary *AsHID(NSDictionary *active) {
    NSMutableDictionary *curve=[NSMutableDictionary dictionary];
    for(NSString *key in @[@"GainLinear",@"GainParabolic",@"GainCubic",@"GainQuartic",@"TangentSpeedLinear",@"TangentSpeedParabolicRoot"])
        curve[[@"HIDAccel"stringByAppendingString:key]]=active[key]?:@0;
    return curve;
}
- (void)updateCurves:(NSArray *)curves index:(double)index scale:(double)scale strength:(double)strength {
    NSDictionary *info=nil;NSArray *modified=TSAnchoredCurves(curves,scale,strength,index,&info,NULL);
    NSDictionary *base=TSExpectedActiveCurve(TSScaleCurves(curves,scale,NULL),index),*target=TSExpectedActiveCurve(modified,index);
    double reference=[info[@"referenceInput"]doubleValue];self.hasReference=info!=nil;
    NSMutableArray *a=[NSMutableArray array],*b=[NSMutableArray array];
    if(base && target)for(int i=0;i<=100;i++) {
        double x=4*reference*i/100.0;
        [a addObject:@(TSEvaluateCurve(AsHID(base),x))];[b addObject:@(TSEvaluateCurve(AsHID(target),x))];
    }
    self.referenceOutput=b.count>25?[b[25]doubleValue]:0;
    self.baseline=a;self.proposed=b;self.needsDisplay=YES;
    [self setAccessibilityLabel:@"目标加速度曲线预览，灰色为同倍率原曲线，蓝色为目标曲线；圆点为固定参考点，不是实测轨迹"];
}
- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor quaternaryLabelColor]setFill];[[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:8 yRadius:8]fill];
    NSRect area=NSInsetRect(self.bounds,10,9);
    [NSColor.separatorColor setStroke];NSBezierPath *grid=[NSBezierPath bezierPath];grid.lineWidth=0.5;
    for(int i=1;i<4;i++){CGFloat x=NSMinX(area)+area.size.width*i/4;[grid moveToPoint:NSMakePoint(x,NSMinY(area))];[grid lineToPoint:NSMakePoint(x,NSMaxY(area))];}
    [grid stroke];
    double maximum=1;for(NSNumber *n in self.baseline)maximum=MAX(maximum,n.doubleValue);for(NSNumber *n in self.proposed)maximum=MAX(maximum,n.doubleValue);
    if(self.hasReference) {
        NSBezierPath *referenceLine=[NSBezierPath bezierPath];referenceLine.lineWidth=1;CGFloat pattern[]={2,3};[referenceLine setLineDash:pattern count:2 phase:0];
        CGFloat x=NSMinX(area)+area.size.width/4;[referenceLine moveToPoint:NSMakePoint(x,NSMinY(area))];[referenceLine lineToPoint:NSMakePoint(x,NSMaxY(area))];
        [[NSColor.controlAccentColor colorWithAlphaComponent:0.45]setStroke];[referenceLine stroke];
        [NSColor.controlAccentColor setFill];[[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x-3,NSMinY(area)+area.size.height*self.referenceOutput/maximum-3,6,6)]fill];
    }
    NSArray *sets=@[self.baseline?:@[],self.proposed?:@[]];
    for(NSUInteger j=0;j<sets.count;j++) {
        NSArray *values=sets[j];if(values.count<2)continue;
        NSBezierPath *path=[NSBezierPath bezierPath];path.lineWidth=j?2.0:1.4;
        for(NSUInteger i=0;i<values.count;i++) {
            NSPoint point=NSMakePoint(NSMinX(area)+area.size.width*i/(values.count-1),NSMinY(area)+area.size.height*[values[i]doubleValue]/maximum);
            if(i==0)[path moveToPoint:point];else[path lineToPoint:point];
        }
        [(j?NSColor.controlAccentColor:NSColor.secondaryLabelColor)setStroke];[path stroke];
    }
}
@end
