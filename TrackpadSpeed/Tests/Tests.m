#import <Foundation/Foundation.h>
#import "Curve.h"
#import "Backend.h"
#import "Log.h"
#import <math.h>
#define CHECK(c) do { if(!(c)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#c);exit(1);} }while(0)
@interface TSBackend (TestHooks)
- (BOOL)loadRecovery:(NSError **)error;
- (BOOL)discoverArchivedLegacy:(NSDictionary *)state error:(NSError **)error;
@end
@interface MockBackend : TSBackend
@property NSArray *baseDriver;
@property NSArray *fakeOverride;
@property id fakePluginCache;
@property NSDictionary *fakeActive;
@property NSUInteger writes;
@property BOOL rejectWrite;
@property BOOL rejectAfterMutation;
@property BOOL rejectRefresh;
@property BOOL ignoreWrite;
@property BOOL staleActive;
@property BOOL backupExistedBeforeWrite;
@property NSURL *testURL;
- (NSArray *)fakeCurves;
@end
@implementation MockBackend
- (instancetype)init {
    if((self=[super init])){[self setValue:@1234 forKey:@"registryID"];[self setValue:@"Test internal trackpad" forKey:@"deviceName"];}return self;
}
- (BOOL)inspect:(NSError **)error {if(![self loadRecovery:error])return NO;return [self discoverArchivedLegacy:[self snapshot:error] error:error];}
- (NSArray *)fakeCurves {return self.fakeOverride.count?self.fakeOverride:self.baseDriver;}
- (NSDictionary *)snapshot:(NSError **)error {
    return @{@"driverCurves":self.baseDriver,@"overridePresent":@(self.fakeOverride.count>0),@"override":self.fakeOverride,@"pluginCache":self.fakePluginCache?:NSNull.null,@"active":self.fakeActive,@"index":@196608};
}
- (id)serviceProperty:(NSString *)key {
    if([key isEqual:@"HIDPointerAccelerationType"])return @"HIDTrackpadAcceleration";
    if([key isEqual:@"HIDAccelCurves"])return self.baseDriver; // Deliberately ignores internal cache.
    return nil;
}
- (BOOL)setServiceProperty:(id)value key:(NSString *)key {
    if([key isEqual:@"HIDPointerAccelerationType"]){if(self.rejectRefresh)return NO;self.fakeActive=TSExpectedActiveCurve(self.fakeCurves,196608);return YES;}
    self.writes++;self.backupExistedBeforeWrite=[[NSFileManager defaultManager]fileExistsAtPath:self.testURL.path];
    if(self.rejectWrite)return NO;
    if([key isEqual:@"HIDAccelCurves"]){self.fakePluginCache=value;return YES;}
    CHECK([key isEqual:@"UserPointerAccelCurvesKey"]);
    if(!self.ignoreWrite){self.fakeOverride=value;if(!self.staleActive)self.fakeActive=TSExpectedActiveCurve(self.fakeCurves,196608);}
    if(self.rejectAfterMutation){self.rejectAfterMutation=NO;return NO;}return YES;
}
@end
static MockBackend *Mock(NSURL *dir,NSArray *curves) {
    MockBackend *m=[MockBackend new];m.baseDriver=curves;m.fakeOverride=@[];m.fakeActive=TSExpectedActiveCurve(curves,196608);
    m.testURL=[dir URLByAppendingPathComponent:@"recovery.plist"];[m setValue:m.testURL forKey:@"recordURL"];return m;
}
static NSDictionary *Interpolate(NSArray *curves,double index) {
    NSDictionary *lo=curves.firstObject,*hi=curves.lastObject;
    for(NSDictionary *c in curves){if([c[@"HIDAccelIndex"]doubleValue]<=index)lo=c; if([c[@"HIDAccelIndex"]doubleValue]>=index){hi=c;break;}}
    double span=[hi[@"HIDAccelIndex"]doubleValue]-[lo[@"HIDAccelIndex"]doubleValue];
    double t=span>0?(index-[lo[@"HIDAccelIndex"]doubleValue])/span:0;
    NSMutableDictionary *r=[NSMutableDictionary dictionary];
    for(NSString *k in @[@"HIDAccelGainLinear",@"HIDAccelGainParabolic",@"HIDAccelGainCubic",@"HIDAccelGainQuartic",@"HIDAccelTangentSpeedLinear",@"HIDAccelTangentSpeedParabolicRoot"])
        r[k]=@([lo[k]doubleValue]+t*([hi[k]doubleValue]-[lo[k]doubleValue]));
    return r;
}
int main(int argc,const char *argv[]) { @autoreleasepool {
    if(argc==2 && strcmp(argv[1],"--emit-test-log")==0) {
        for(int i=0;i<100;i++)TSLog(@"test.concurrent",@{@"index":@(i)});
        return TSFlushLog()?0:1;
    }
    NSURL *root=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    [[NSFileManager defaultManager]createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:NULL];
    setenv("TS_TEST_LOG_DIR",[[root.path stringByAppendingPathComponent:@"Logs"] UTF8String],1);
    NSArray *original=@[
      @{@"HIDAccelIndex":@0,@"HIDAccelGainLinear":@65536,@"HIDAccelGainParabolic":@32768,@"HIDAccelGainCubic":@5243,@"HIDAccelGainQuartic":@655,@"HIDAccelTangentSpeedLinear":@458752,@"HIDAccelTangentSpeedParabolicRoot":@786432},
      @{@"HIDAccelIndex":@196608,@"HIDAccelGainLinear":@54395,@"HIDAccelGainParabolic":@108790,@"HIDAccelGainCubic":@18350,@"HIDAccelGainQuartic":@1311,@"HIDAccelTangentSpeedLinear":@484966,@"HIDAccelTangentSpeedParabolicRoot":@851968}];
    NSUInteger samples=0;
    for(NSNumber *scale in @[@1,@1.25,@2,@4]) {
        NSError *error=nil;NSArray *scaled=TSScaleCurves(original,scale.doubleValue,&error);CHECK(scaled && !error);
        CHECK([scaled.firstObject[@"HIDAccelTangentSpeedLinear"]isEqual:original.firstObject[@"HIDAccelTangentSpeedLinear"]]);
        for(NSNumber *index in @[@0,@65536,@131072,@196608]) {
            NSDictionary *base=Interpolate(original,index.doubleValue),*modified=Interpolate(scaled,index.doubleValue);
            for(double x=0.01;x<200;x*=1.12) {
                double wanted=TSEvaluateCurve(base,x)*scale.doubleValue;
                double got=TSEvaluateCurve(modified,x);
                CHECK(isfinite(got) && fabs(got-wanted)/MAX(1e-9,wanted)<0.001);samples++;
            }
        }
    }
    NSUInteger shapeSamples=0;
    for(NSNumber *strength in @[@0.1,@0.25,@0.5,@1,@1.5,@2,@2.5,@3]) {
        NSArray *shaped=TSAdjustCurves(original,1,strength.doubleValue,NULL);CHECK(shaped);
        if(strength.doubleValue==1)CHECK([shaped.firstObject[@"HIDAccelGainLinear"]isEqual:original.firstObject[@"HIDAccelGainLinear"]]);
        CHECK([shaped.lastObject[@"HIDAccelTangentSpeedParabolicRoot"]isEqual:original.lastObject[@"HIDAccelTangentSpeedParabolicRoot"]]);
        for(NSNumber *scale in @[@1,@1.25,@2,@4]) {
            NSArray *target=TSAdjustCurves(original,scale.doubleValue,strength.doubleValue,NULL);CHECK(target);
            if(strength.doubleValue==1)CHECK([target isEqual:TSScaleCurves(original,scale.doubleValue,NULL)]);
            for(NSNumber *index in @[@0,@65536,@131072,@196608]) {
                NSDictionary *base=Interpolate(shaped,index.doubleValue),*changed=Interpolate(target,index.doubleValue);
                for(double x=0.01;x<200;x*=1.12) {
                    double wanted=TSEvaluateCurve(base,x)*scale.doubleValue,actual=TSEvaluateCurve(changed,x);
                    CHECK(isfinite(actual) && fabs(actual-wanted)/MAX(1e-9,wanted)<0.002);shapeSamples++;
                }
            }
        }
    }
    CHECK(!TSAdjustCurves(original,2,NAN,NULL));CHECK(!TSAdjustCurves(original,2,0.09,NULL));CHECK(!TSAdjustCurves(original,2,3.01,NULL));
    NSUInteger anchoredSamples=0;
    for(NSNumber *index in @[@0,@65536,@131072,@196608])for(NSNumber *contrast in @[@0.1,@0.25,@0.5,@1,@1.5,@2,@2.5,@3])for(NSNumber *speed in @[@1,@2.5,@4]) {
        NSDictionary *info=nil;NSArray *anchored=TSAnchoredCurves(original,speed.doubleValue,contrast.doubleValue,index.doubleValue,&info,NULL);CHECK(anchored);
        NSDictionary *base=Interpolate(original,index.doubleValue),*target=Interpolate(anchored,index.doubleValue);
        double reference=[info[@"referenceInput"]doubleValue];CHECK(reference>0 && [info[@"referenceRelativeError"]doubleValue]<0.002);
        double wanted=TSEvaluateCurve(base,reference)*speed.doubleValue;
        CHECK(fabs(TSEvaluateCurve(target,reference)-wanted)/wanted<0.002);
        double previous=0;
        for(double x=reference*0.01;x<reference*50;x*=1.12) {
            double baseline=TSEvaluateCurve(base,x)*speed.doubleValue,modified=TSEvaluateCurve(target,x);
            CHECK(isfinite(modified) && modified>previous);previous=modified;
            double tolerance=baseline*0.002;
            if(contrast.doubleValue>1) {if(x<reference)CHECK(modified<=baseline+tolerance);else CHECK(modified>=baseline-tolerance);}
            if(contrast.doubleValue<1) {if(x<reference)CHECK(modified>=baseline-tolerance);else CHECK(modified<=baseline+tolerance);}
            anchoredSamples++;
        }
    }
    CHECK(!TSAnchoredCurves(original,2,1,NAN,NULL,NULL));
    CHECK([TSScaleCurves(original,1,NULL)isEqual:original]);
    CHECK(TSActiveCurveMatches(original,196608,TSExpectedActiveCurve(original,196608),NULL));
    CHECK(!TSActiveCurveMatches(TSScaleCurves(original,2,NULL),196608,TSExpectedActiveCurve(original,196608),NULL));
    CHECK([TSExpectedActiveCurve(original,300000)[@"AccelIndex"]doubleValue]==196608);
    CHECK(!TSScaleCurves(original,NAN,NULL));CHECK(!TSScaleCurves(original,4.1,NULL));CHECK(!TSScaleCurves(@[],2,NULL));
    CHECK(!TSScaleCurves(@[@{@"HIDAccelIndex":@0,@"HIDAccelGainLinear":@1,@"UnknownField":@1}],2,NULL));
    CHECK(!TSScaleCurves(@[@{@"HIDAccelIndex":@0,@"HIDAccelGainLinear":@(INT32_MAX)}],4,NULL));
    NSError *e=nil;MockBackend *m=Mock(root,original);
    CHECK([m apply:2 error:&e]);CHECK(m.backupExistedBeforeWrite);CHECK(m.hasRecovery);CHECK([m.fakeCurves isEqual:TSScaleCurves(original,2,NULL)]);
    CHECK([m apply:4 error:&e]);CHECK([m.fakeCurves isEqual:TSScaleCurves(original,4,NULL)]); // no compounding
    MockBackend *restarted=Mock(root,original);restarted.fakeOverride=m.fakeOverride;restarted.fakeActive=m.fakeActive;CHECK([restarted restore:&e]);CHECK([restarted.fakeCurves isEqual:original]);CHECK(!restarted.hasRecovery);
    m=Mock(root,original);m.rejectAfterMutation=YES;CHECK(![m apply:2 error:&e]);CHECK(m.hasRecovery);CHECK([m.fakeCurves isEqual:original]);CHECK(m.writes==2);CHECK([m restore:&e]);
    m=Mock(root,original);m.rejectWrite=YES;CHECK(![m apply:2 error:&e]);CHECK(m.hasRecovery);m.fakeOverride=TSScaleCurves(original,2,NULL);m.fakeActive=TSExpectedActiveCurve(m.fakeCurves,196608);CHECK(![m restore:&e]);CHECK(m.hasRecovery);
    [[NSFileManager defaultManager]removeItemAtURL:m.testURL error:NULL];
    [@"broken plist" writeToURL:m.testURL atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    m=Mock(root,original);CHECK(![m apply:2 error:&e]);CHECK(m.writes==0);
    [[NSFileManager defaultManager]removeItemAtURL:m.testURL error:NULL];
    // An unwritable backup destination must prevent any driver write.
    NSURL *invalid=[root URLByAppendingPathComponent:@"not-a-directory"];
    [NSData.data writeToURL:invalid atomically:YES];m=Mock(invalid,original);CHECK(![m apply:2 error:&e]);CHECK(m.writes==0);
    // Reproduce v0.1 failure: success return, but property readback unchanged.
    NSURL *ignoredDir=[root URLByAppendingPathComponent:@"ignored"];
    MockBackend *ignored=Mock(ignoredDir,original);ignored.ignoreWrite=YES;
    CHECK(![ignored apply:2 error:&e]);CHECK([ignored.fakeCurves isEqual:original]);CHECK(ignored.hasRecovery);CHECK(ignored.writes==2);
    CHECK([ignored restore:&e]);CHECK(ignored.writes==3);
    // A failed refresh must be distinguished from the successful curve write.
    MockBackend *refresh=Mock([root URLByAppendingPathComponent:@"refresh"],original);refresh.staleActive=YES;
    CHECK(![refresh apply:2 error:&e]);CHECK([refresh.fakeCurves isEqual:original]);CHECK(refresh.hasRecovery);
    refresh.staleActive=NO;CHECK([refresh restore:&e]);
    // Import an unchanged legacy v1 backup and archive only on an explicit restore.
    MockBackend *legacy=Mock([root URLByAppendingPathComponent:@"legacy"],original);
    CHECK([legacy apply:2 error:&e]);
    NSMutableDictionary *old=[[NSDictionary dictionaryWithContentsOfURL:legacy.testURL]mutableCopy];old[@"version"]=@1;[old removeObjectForKey:@"source"];[old removeObjectForKey:@"accelerationType"];
    NSData *legacyData=[NSPropertyListSerialization dataWithPropertyList:old format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];CHECK([legacyData writeToURL:legacy.testURL atomically:YES]);
    MockBackend *loaded=Mock(legacy.testURL.URLByDeletingLastPathComponent,original);loaded.fakePluginCache=TSScaleCurves(original,2,NULL);CHECK([loaded inspect:&e]);
    CHECK([[NSData dataWithContentsOfURL:loaded.testURL]isEqual:legacyData]);CHECK([loaded restore:&e]);CHECK([loaded.fakeCurves isEqual:original]);CHECK([loaded.fakePluginCache isEqual:original]);CHECK(loaded.writes==1);
    // v0.2 could archive the record while its plugin cache remained scaled.
    MockBackend *archivedResidue=Mock(loaded.testURL.URLByDeletingLastPathComponent,original);archivedResidue.fakePluginCache=TSScaleCurves(original,2,NULL);
    CHECK([archivedResidue inspect:&e]);CHECK(archivedResidue.hasRecovery);CHECK(![[NSFileManager defaultManager]fileExistsAtPath:archivedResidue.testURL.path]);
    CHECK([archivedResidue restore:&e]);CHECK([archivedResidue.fakePluginCache isEqual:original]);CHECK(!archivedResidue.hasRecovery);
    // Legacy refresh refusal must keep its recovery record, even when cache matches.
    MockBackend *legacyFailure=Mock([root URLByAppendingPathComponent:@"legacy-failure"],original);
    [[NSFileManager defaultManager]createDirectoryAtURL:legacyFailure.testURL.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    CHECK([legacyData writeToURL:legacyFailure.testURL atomically:YES]);legacyFailure.fakePluginCache=TSScaleCurves(original,2,NULL);legacyFailure.rejectRefresh=YES;
    CHECK(![legacyFailure restore:&e]);CHECK(legacyFailure.hasRecovery);CHECK([legacyFailure.fakePluginCache isEqual:original]);
    legacyFailure.rejectRefresh=NO;CHECK([legacyFailure restore:&e]);
    MockBackend *shape=Mock([root URLByAppendingPathComponent:@"shape"],original);
    CHECK([shape apply:2.5 strength:1.5 error:&e]);CHECK([shape.fakeCurves isEqual:TSAdjustCurves(original,2.5,1.5,NULL)]);
    CHECK([shape apply:2.5 strength:0.5 error:&e]);CHECK([shape.fakeCurves isEqual:TSAdjustCurves(original,2.5,0.5,NULL)]);
    CHECK([shape restore:&e]);CHECK([shape.fakeCurves isEqual:original]);
    NSUInteger writesBeforeInvalid=shape.writes;CHECK(![shape apply:2.5 strength:3.01 error:&e]);CHECK(shape.writes==writesBeforeInvalid);
    NSMutableArray *children=[NSMutableArray array];
    for(int i=0;i<2;i++) {
        NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[0]]];task.arguments=@[@"--emit-test-log"];
        NSMutableDictionary *env=[NSProcessInfo.processInfo.environment mutableCopy];env[@"TS_TEST_LOG_DIR"]=[root.path stringByAppendingPathComponent:@"Logs"];task.environment=env;
        CHECK([task launchAndReturnError:NULL]);[children addObject:task];
    }
    for(NSTask *task in children){[task waitUntilExit];CHECK(task.terminationStatus==0);}
    TSLog(@"test.marker",@{@"scale":@2,@"stage":@"test"});TSFlushLog();
    NSString *log=[NSString stringWithContentsOfFile:[TSLogDirectory()stringByAppendingPathComponent:@"trace-v2.jsonl"] encoding:NSUTF8StringEncoding error:NULL];
    CHECK([log containsString:@"test.marker"]);
    NSMutableSet *begins=[NSMutableSet set],*ends=[NSMutableSet set];BOOL diffFound=NO,refreshFailureFound=NO;NSUInteger concurrent=0;
    for(NSString *line in [log componentsSeparatedByString:@"\n"])if(line.length) {
        id record=[NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];CHECK([record isKindOfClass:NSDictionary.class] && record[@"uptime"] && record[@"event"] && record[@"operationID"]);
        if([record[@"event"]isEqual:@"test.concurrent"])concurrent++;
        if([record[@"event"]isEqual:@"operation.begin"])[begins addObject:record[@"operationID"]];
        if([record[@"event"]isEqual:@"operation.end"])[ends addObject:record[@"operationID"]];
        if([record[@"event"]isEqual:@"override.readback"] && ([record[@"diff"][@"differentFieldCount"]unsignedIntegerValue]>0 || ![record[@"diff"][@"actualCount"]isEqual:record[@"diff"][@"wantedCount"]]))diffFound=YES;
        if([record[@"event"]isEqual:@"property.write.result"] && [record[@"stage"]isEqual:@"legacy filter refresh"] && ![record[@"accepted"]boolValue])refreshFailureFound=YES;
    }
    CHECK(concurrent==200);CHECK([begins isEqual:ends]);CHECK(diffFound);CHECK(refreshFailureFound);
    printf("PASS: %lu anchored contrast samples; %lu contrast/scale samples. ", (unsigned long)anchoredSamples,(unsigned long)shapeSamples);
    printf("PASS: %lu curve samples (all 3 segments, interpolation, 1–4x); durable-before-write, recovery after relaunch, no compounding, rollback, failed restore retention, invalid backup, ignored write, refresh rejection, v1 hidden-cache recovery, active-filter verification, balanced operation logs, readback diffs, 200 concurrent-process log records. No real input settings changed.\n",(unsigned long)samples);
    [[NSFileManager defaultManager]removeItemAtURL:root error:NULL];
}return 0;}
