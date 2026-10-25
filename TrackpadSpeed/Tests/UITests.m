// Offline control-action tests. No TSBackend instance, device writes or event taps.
#define main TSApplicationMain
#import "../Sources/main.m"
#undef main
#define CHECK(c) do {if(!(c)){fprintf(stderr,"FAIL UI line %d: %s\n",__LINE__,#c);exit(1);}}while(0)
@interface TestDelegate : AppDelegate
@property NSUInteger editRequests;
@end
@implementation TestDelegate
- (void)editRate:(id)sender {self.editRequests++;}
@end
@interface FakeUIBackend : NSObject
@property NSUInteger applies;
@property NSUInteger restores;
@property double scale;
@property double strength;
@property BOOL failApply;
@end
@implementation FakeUIBackend
- (BOOL)hasRecovery {return YES;}
- (BOOL)active {return YES;}
- (BOOL)inspect:(NSError **)error {return YES;}
- (NSDictionary *)previewBaseline:(NSError **)error {return nil;}
- (BOOL)apply:(double)scale strength:(double)strength error:(NSError **)error {
    self.applies++;self.scale=scale;self.strength=strength;
    if(self.failApply && error)*error=[NSError errorWithDomain:@"UITest" code:1 userInfo:@{NSLocalizedDescriptionKey:@"模拟验证失败"}];
    return !self.failApply;
}
- (BOOL)restore:(NSError **)error {self.restores++;return YES;}
@end
static BOOL HasApplyButton(NSView *v) {
    if([v isKindOfClass:NSButton.class] && [[(NSButton *)v title]isEqual:@"应用设置"])return YES;
    for(NSView *child in v.subviews)if(HasApplyButton(child))return YES;return NO;
}
int main(void){@autoreleasepool {
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSString *dir=[NSTemporaryDirectory()stringByAppendingPathComponent:NSUUID.UUID.UUIDString];setenv("TS_TEST_LOG_DIR",dir.UTF8String,1);
    TestDelegate *d=[TestDelegate new];FakeUIBackend *fake=[FakeUIBackend new];d.backend=(id)fake;[d buildPopover];
    CHECK([d.value isKindOfClass:TSRateLabel.class]);
    NSEvent *doubleClick=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil eventNumber:1 clickCount:2 pressure:0];[d.value mouseDown:doubleClick];CHECK(d.editRequests==1);
    CHECK(!d.slider.continuous && !d.strengthSlider.continuous);CHECK(fake.applies==0);
    CHECK(!HasApplyButton(d.popover.contentViewController.view));
    d.slider.doubleValue=2.5;CHECK(fake.applies==0);
    [d.slider sendAction:d.slider.action to:d.slider.target];CHECK(fake.applies==1);CHECK(fake.scale==2.5 && fake.strength==1);CHECK(d.status.hidden);
    d.strengthSlider.doubleValue=1.35;[d.strengthSlider sendAction:d.strengthSlider.action to:d.strengthSlider.target];
    CHECK(fake.applies==2 && fake.scale==2.5 && fabs(fake.strength-1.35)<0.001);
    CHECK([d doRestore]);CHECK(fake.restores==1 && fake.applies==2);CHECK(d.slider.doubleValue==1 && d.strengthSlider.doubleValue==1);
    [d refresh];CHECK(fake.applies==2);
    fake.failApply=YES;d.slider.doubleValue=2;[d.slider sendAction:d.slider.action to:d.slider.target];
    CHECK(fake.applies==3);CHECK([d.status.stringValue containsString:@"模拟验证失败"]);CHECK(!d.status.hidden);
    fake.failApply=NO;NSUInteger before=fake.applies;
    CHECK([d commitRateText:@"2.375"]);CHECK(fake.applies==before+1 && fabs(fake.scale-2.375)<1e-12);CHECK([d.value.stringValue isEqual:@"2.375×"]);
    CHECK(![d commitRateText:@"2.3759"]);CHECK(![d commitRateText:@"nan"]);CHECK(![d commitRateText:@"5"]);CHECK(![d commitRateText:@"2.5oops"]);CHECK(fake.applies==before+1);
    CHECK(d.strengthSlider.minValue==0.1 && d.strengthSlider.maxValue==3);
    NSURL *presetURL=[NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"presets.json"]];d.presets=[[TSPresetStore alloc]initWithURL:presetURL];
    NSError *error=nil;NSDictionary *saved=[d.presets saveName:@"精细工作" scale:2.375 contrast:3 error:&error];CHECK(saved);
    [d reloadPresets:saved[@"id"]];CHECK(fake.applies==before+1);
    [d presetSelected:d.presetPopup];CHECK(fake.applies==before+2 && fabs(fake.scale-2.375)<1e-12 && fake.strength==3);
    CHECK(d.deletePresetButton.enabled);[d deletePreset:nil];CHECK([d.presets load:&error].count==0);CHECK(!d.deletePresetButton.enabled);
    CHECK(fake.applies==before+2 && fabs(fake.scale-2.375)<1e-12 && fake.strength==3);CHECK(d.slider.doubleValue==2.375 && d.strengthSlider.doubleValue==3);
    CHECK([d doRestore]);CHECK(fake.applies==before+2);
    CHECK(TSFlushLog());[[NSFileManager defaultManager]removeItemAtPath:dir error:NULL];
    puts("PASS UI: release-only actions, both sliders auto-apply once, no Apply button, startup/refresh/programmatic reset do not apply, restore does not re-enable, failure feedback, precise numeric input, invalid input rejection, preset load applies once, delete does not apply or reset current parameters, 0.10–3.00 range. No input backend or listener started.");
}return 0;}
