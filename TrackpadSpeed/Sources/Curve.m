#import "Curve.h"
#import <math.h>
double TSMinimumContrast(void){return 0.10;}
double TSMaximumContrast(void){return 3.00;}
static NSError *Bad(NSString *s) { return [NSError errorWithDomain:@"TrackpadSpeed" code:1 userInfo:@{NSLocalizedDescriptionKey:s}]; }
NSArray *TSScaleCurves(NSArray *curves, double scale, NSError **error) {
    if (![curves isKindOfClass:NSArray.class] || !curves.count || !isfinite(scale) || scale < 1 || scale > 4) {
        if(error) *error=Bad(@"曲线不可用或倍率超出 1–4×。"); return nil;
    }
    NSArray *keys=@[@"HIDAccelGainLinear",@"HIDAccelGainParabolic",@"HIDAccelGainCubic",@"HIDAccelGainQuartic"];
    NSSet *allowed=[NSSet setWithArray:[keys arrayByAddingObjectsFromArray:@[@"HIDAccelIndex",@"HIDAccelTangentSpeedLinear",@"HIDAccelTangentSpeedParabolicRoot"]]];
    NSMutableArray *result=[NSMutableArray array];
    double last=-1;
    for(id item in curves) {
        if(![item isKindOfClass:NSDictionary.class] || !item[@"HIDAccelIndex"] || !item[@"HIDAccelGainLinear"]) { if(error)*error=Bad(@"不支持此设备曲线格式。"); return nil; }
        for(NSString *k in item) {
            id v=item[k];
            if(![allowed containsObject:k] || ![v isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)v)==CFBooleanGetTypeID() || !isfinite([v doubleValue]) || [v doubleValue]<0 || [v doubleValue]>INT32_MAX || floor([v doubleValue])!=[v doubleValue]) {
                if(error)*error=Bad(@"曲线包含未知字段或无效定点数，已停止。"); return nil;
            }
        }
        double index=[item[@"HIDAccelIndex"] doubleValue];
        if(index<=last) { if(error)*error=Bad(@"曲线索引顺序无效。"); return nil; } last=index;
        NSMutableDictionary *c=[item mutableCopy];
        for(NSUInteger i=0;i<keys.count;i++) {
            NSString *k=keys[i]; if(!c[k]) continue;
            double value=[c[k] doubleValue]*pow(scale,1.0/(i+1));
            if(value>INT32_MAX) { if(error)*error=Bad(@"曲线数值溢出。"); return nil; }
            c[k]=@(llround(value));
        }
        [result addObject:c];
    }
    return result;
}
// Mirrors Apple's three-segment parametric function (without device/cursor units).
double TSEvaluateCurve(NSDictionary *c, double x) {
    double a=[c[@"HIDAccelGainLinear"] doubleValue]/65536.0;
    double b=[c[@"HIDAccelGainParabolic"] doubleValue]/65536.0;
    double d=[c[@"HIDAccelGainCubic"] doubleValue]/65536.0;
    double e=[c[@"HIDAccelGainQuartic"] doubleValue]/65536.0;
    double t=[c[@"HIDAccelTangentSpeedLinear"] doubleValue]/65536.0;
    double u=[c[@"HIDAccelTangentSpeedParabolicRoot"] doubleValue]/65536.0;
    double p=t>0?t:INFINITY, q=u>0?u:INFINITY;
    if(x<=MIN(p,q)) return a*x+pow(b*x,2)+pow(d*x,3)+pow(e*x,4);
    double m=0,z=0;
    if(t>0) {
        double y=a*t+pow(b*t,2)+pow(d*t,3)+pow(e*t,4);
        m=a+2*t*b*b+3*t*t*d*d*d+4*t*t*t*pow(e,4); z=y-m*t;
    }
    if(x<=q && t>0) return m*x+z;
    if(u>0) {
        double y=t>0?m*u+z:a*u+pow(b*u,2)+pow(d*u,3)+pow(e*u,4);
        double deriv=t>0?m:a+2*u*b*b+3*u*u*d*d*d+4*u*u*u*pow(e,4);
        return sqrt(MAX(0,2*y*deriv*x+y*y-2*y*deriv*u));
    }
    return m*x+z;
}
NSDictionary *TSExpectedActiveCurve(NSArray *curves, double fixedIndex) {
    if(!TSScaleCurves(curves,1,NULL) || !isfinite(fixedIndex) || fixedIndex<0)return nil;
    NSDictionary *lo=curves.firstObject,*hi=nil;
    for(NSDictionary *c in curves) {
        if([c[@"HIDAccelIndex"]doubleValue]<=fixedIndex)lo=c;
        else {hi=c;break;}
    }
    double a=[lo[@"HIDAccelIndex"]doubleValue],b=[hi[@"HIDAccelIndex"]doubleValue];
    double t=hi && b>a && fixedIndex>a?(fixedIndex-a)/(b-a):0;
    NSArray *keys=@[@"GainLinear",@"GainParabolic",@"GainCubic",@"GainQuartic",@"TangentSpeedLinear",@"TangentSpeedParabolicRoot"];
    NSMutableDictionary *expected=[@{@"Class":@"IOHIDParametricAcceleration",@"AccelIndex":@(a+t*(b-a))} mutableCopy];
    for(NSString *key in keys) {
        NSString *hid=[@"HIDAccel" stringByAppendingString:key];
        double low=[lo[hid]doubleValue],high=[hi[hid]doubleValue];
        expected[key]=@(low+t*(high-low));
    }return expected;
}
BOOL TSActiveCurveMatches(NSArray *curves, double fixedIndex, NSDictionary *active, NSDictionary **diff) {
    NSDictionary *expected=TSExpectedActiveCurve(curves,fixedIndex);NSMutableDictionary *different=[NSMutableDictionary dictionary];
    if(!expected || ![active isKindOfClass:NSDictionary.class]) {if(diff)*diff=@{@"missingOrInvalid":@YES};return NO;}
    for(NSString *key in expected) {
        if([key isEqual:@"Class"]) {if(![active[key]isEqual:expected[key]])different[key]=@{@"expected":expected[key],@"actual":active[key]?:NSNull.null};continue;}
        id value=active[key];
        // Apple's serializer may omit an exactly-zero coefficient; fixed point conversion truncates.
        BOOL missingZero=!value && [expected[key]doubleValue]==0;
        if(!missingZero && (![value isKindOfClass:NSNumber.class] || !isfinite([value doubleValue]) || fabs([value doubleValue]-[expected[key]doubleValue])>2.0))different[key]=@{@"expected":expected[key],@"actual":value?:NSNull.null};
    }
    if(diff)*diff=different;return different.count==0;
}
static NSDictionary *HIDCurveFromActive(NSDictionary *active) {
    NSMutableDictionary *curve=[NSMutableDictionary dictionary];
    for(NSString *key in @[@"GainLinear",@"GainParabolic",@"GainCubic",@"GainQuartic",@"TangentSpeedLinear",@"TangentSpeedParabolicRoot"])
        curve[[@"HIDAccel"stringByAppendingString:key]]=active[key]?:@0;
    return curve;
}
NSArray *TSAdjustCurves(NSArray *curves, double scale, double strength, NSError **error) {
    if(!TSScaleCurves(curves,1,error))return nil;
    double index=[curves.lastObject[@"HIDAccelIndex"]doubleValue];
    return TSAnchoredCurves(curves,scale,strength,index,NULL,error);
}
NSArray *TSAnchoredCurves(NSArray *curves, double scale, double strength, double fixedIndex, NSDictionary **info, NSError **error) {
    if(!isfinite(scale) || scale<1 || scale>4 || !isfinite(strength) || strength<TSMinimumContrast() || strength>TSMaximumContrast() || !isfinite(fixedIndex) || fixedIndex<0) {
        if(error)*error=Bad(@"速度倍率、加速对比或系统曲线索引无效。");return nil;
    }
    NSDictionary *selected=TSExpectedActiveCurve(curves,fixedIndex);
    if(!selected){if(error)*error=Bad(@"无法读取参考曲线。");return nil;}
    NSDictionary *base=HIDCurveFromActive(selected);
    NSMutableDictionary *shaped=[base mutableCopy];
    NSArray *keys=@[@"HIDAccelGainLinear",@"HIDAccelGainParabolic",@"HIDAccelGainCubic",@"HIDAccelGainQuartic"];
    for(NSUInteger i=1;i<keys.count;i++)shaped[keys[i]]=@([base[keys[i]]doubleValue]*pow(strength,1.0/(i+1)));
    double t=[base[@"HIDAccelTangentSpeedLinear"]doubleValue]/65536.0;
    double u=[base[@"HIDAccelTangentSpeedParabolicRoot"]doubleValue]/65536.0;
    double transition=INFINITY;if(t>0)transition=MIN(transition,t);if(u>0)transition=MIN(transition,u);
    double reference=isfinite(transition)?transition/2:1;
    NSString *referenceRule=@"half-first-transition";
    double linearGain=[base[@"HIDAccelGainLinear"]doubleValue]/65536.0;
    if(isfinite(transition) && linearGain>0 && TSEvaluateCurve(base,transition)>=2*linearGain*transition) {
        // Use the point where linear movement and nonlinear acceleration contribute equally.
        // Anchoring after nonlinear terms dominate would almost cancel the contrast adjustment.
        double low=0,high=transition;
        for(int i=0;i<64;i++){double mid=(low+high)/2;if(TSEvaluateCurve(base,mid)<2*linearGain*mid)low=mid;else high=mid;}
        reference=(low+high)/2;referenceRule=@"balanced-linear-nonlinear";
    }
    double originalOutput=TSEvaluateCurve(base,reference),shapedOutput=TSEvaluateCurve(shaped,reference);
    if(!isfinite(originalOutput) || !isfinite(shapedOutput) || originalOutput<=0 || shapedOutput<=0) {
        if(error)*error=Bad(@"参考点输出无效，不能可靠固定中速。");return nil;
    }
    double normalization=strength==1?1:originalOutput/shapedOutput;
    double gain=scale*normalization;
    NSArray *factors=@[@(gain),@(sqrt(gain*strength)),@(cbrt(gain*strength)),@(pow(gain*strength,0.25))];
    NSMutableArray *result=[NSMutableArray arrayWithCapacity:curves.count];
    for(NSDictionary *original in curves) {
        NSMutableDictionary *curve=[original mutableCopy];
        for(NSUInteger i=0;i<keys.count;i++) {
            NSString *key=keys[i];if(!original[key])continue;
            double value=[original[key]doubleValue]*[factors[i]doubleValue];
            if(!isfinite(value) || value>INT32_MAX){if(error)*error=Bad(@"曲线参数溢出，未应用。");return nil;}
            curve[key]=@(llround(value));
        }[result addObject:curve];
    }
    NSDictionary *quantized=TSExpectedActiveCurve(result,fixedIndex);
    double output=TSEvaluateCurve(HIDCurveFromActive(quantized),reference);
    double relativeError=fabs(output-scale*originalOutput)/(scale*originalOutput);
    if(!quantized || !isfinite(relativeError) || relativeError>0.002){if(error)*error=Bad(@"定点取整使参考点偏差过大，未应用。");return nil;}
    if(info)*info=@{@"algorithm":@"anchored-contrast-v1",@"referenceRule":referenceRule,@"referenceInput":@(reference),@"referenceIndex":@(fixedIndex),@"referenceOutputBeforeScale":@(originalOutput),@"targetReferenceOutput":@(scale*originalOutput),@"quantizedReferenceOutput":@(output),@"referenceRelativeError":@(relativeError),@"normalization":@(normalization),@"coefficientFactors":factors};
    return result;
}
