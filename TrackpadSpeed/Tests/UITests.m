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
// Simulates ServiceManagement without changing this user's real login items.
@interface FakeLoginService : NSObject
@property SMAppServiceStatus status;
@property SMAppServiceStatus registrationStatus;
@property NSUInteger registrations;
@property NSUInteger unregistrations;
@property BOOL fail;
@end
@implementation FakeLoginService
- (BOOL)registerAndReturnError:(NSError **)error {
    self.registrations++;
    if(self.fail){if(error)*error=[NSError errorWithDomain:@"UITest" code:2 userInfo:@{NSLocalizedDescriptionKey:@"模拟登录项失败"}];return NO;}
    self.status=self.registrationStatus;return YES;
}
- (BOOL)unregisterAndReturnError:(NSError **)error {
    self.unregistrations++;
    if(self.fail){if(error)*error=[NSError errorWithDomain:@"UITest" code:2 userInfo:@{NSLocalizedDescriptionKey:@"模拟登录项失败"}];return NO;}
    self.status=SMAppServiceStatusNotRegistered;return YES;
}
@end
static BOOL HasApplyButton(NSView *v) {
    if([v isKindOfClass:NSButton.class] && [[(NSButton *)v title]isEqual:@"应用设置"])return YES;
    for(NSView *child in v.subviews)if(HasApplyButton(child))return YES;return NO;
}
int main(void){@autoreleasepool {
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSString *dir=[NSTemporaryDirectory()stringByAppendingPathComponent:NSUUID.UUID.UUIDString];setenv("TS_TEST_LOG_DIR",dir.UTF8String,1);
    TestDelegate *d=[TestDelegate new];FakeUIBackend *fake=[FakeUIBackend new];d.backend=(id)fake;
    FakeLoginService *login=[FakeLoginService new];login.registrationStatus=SMAppServiceStatusEnabled;d.loginService=(id)login;[d buildPopover];
    CHECK(d.loginButton.state==NSControlStateValueOff && d.loginSettingsButton.hidden);
    CHECK(login.registrations==0 && login.unregistrations==0);
    [d.loginButton performClick:nil];CHECK(login.registrations==1 && d.loginButton.state==NSControlStateValueOn);
    [d.loginButton performClick:nil];CHECK(login.unregistrations==1 && d.loginButton.state==NSControlStateValueOff);
    login.registrationStatus=SMAppServiceStatusRequiresApproval;
    [d.loginButton performClick:nil];CHECK(d.loginButton.state==NSControlStateValueOn && !d.loginSettingsButton.hidden);
    CHECK([d.status.stringValue containsString:@"尚未获准"]);
    [d.loginButton performClick:nil];CHECK(login.unregistrations==2 && d.loginSettingsButton.hidden);
    login.fail=YES;[d.loginButton performClick:nil];CHECK(d.loginButton.state==NSControlStateValueOff);
    CHECK([d.status.stringValue containsString:@"模拟登录项失败"]);
    login.fail=NO;login.status=SMAppServiceStatusEnabled;[d applicationDidBecomeActive:[NSNotification notificationWithName:NSApplicationDidBecomeActiveNotification object:NSApp]];CHECK(d.loginButton.state==NSControlStateValueOn);
    login.fail=YES;[d.loginButton performClick:nil];CHECK(d.loginButton.state==NSControlStateValueOn);
    login.fail=NO;login.status=SMAppServiceStatusNotRegistered;[d refresh];CHECK(d.loginButton.state==NSControlStateValueOff);
    login.status=SMAppServiceStatusNotFound;[d refreshLoginItem];CHECK(d.loginButton.state==NSControlStateValueOff);
    CHECK(fake.applies==0 && fake.restores==0);
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
    // Sleep/wake uses a fake device; invoke timer callbacks directly, without waiting.
    [d sleep:nil];[d wake:nil];CHECK(!d.resumePending && !d.wakeTimer);
    CHECK([d commitRateText:@"2.375"]);d.strengthSlider.doubleValue=2.45;[d strengthChanged:d.strengthSlider];
    NSUInteger sleepApplies=fake.applies,sleepRestores=fake.restores;
    [d sleep:nil];CHECK(d.resumePending && fake.restores==sleepRestores+1);
    CHECK(d.slider.doubleValue==2.375 && fabs(d.strengthSlider.doubleValue-2.45)<1e-12);
    [d sleep:nil];[d wake:nil];CHECK(d.wakeTimer && fake.applies==sleepApplies);
    [d wake:nil];[d resumeAfterWake:nil];CHECK(fake.applies==sleepApplies+1 && !d.resumePending && !d.wakeTimer);
    CHECK(fake.scale==2.375 && fabs(fake.strength-2.45)<1e-12);
    // Failed edits must not become the settings used after wake.
    fake.failApply=YES;[d commitRateText:@"3.5"];fake.failApply=NO;
    [d sleep:nil];[d wake:nil];[d resumeAfterWake:nil];CHECK(fake.scale==2.375 && d.slider.doubleValue==2.375);
    [d sleep:nil];[d wake:nil];fake.failApply=YES;
    [d resumeAfterWake:nil];CHECK(d.resumePending && d.wakeTimer && d.wakeAttempts==1);
    fake.failApply=NO;[d resumeAfterWake:nil];CHECK(!d.resumePending && !d.wakeTimer && d.wakeAttempts==2);
    [d sleep:nil];[d wake:nil];fake.failApply=YES;
    for(int attempt=0;attempt<5;attempt++)[d resumeAfterWake:nil];
    CHECK(!d.resumePending && !d.wakeTimer && d.wakeAttempts==5);
    CHECK([d.status.stringValue containsString:@"唤醒后自动应用失败"]);
    NSUInteger exhausted=fake.applies;[d resumeAfterWake:nil];CHECK(fake.applies==exhausted);
    fake.failApply=NO;CHECK([d commitRateText:@"2"]);
    [d sleep:nil];[d wake:nil];CHECK([d doRestore]);NSUInteger cancelled=fake.applies;
    [d resumeAfterWake:nil];[d wake:nil];CHECK(fake.applies==cancelled && !d.wakeTimer && !d.lastAppliedSettings);
    CHECK([d commitRateText:@"2"]);[d sleep:nil];[d wake:nil];CHECK([d commitRateText:@"3"]);
    cancelled=fake.applies;[d resumeAfterWake:nil];CHECK(fake.applies==cancelled && !d.wakeTimer && fake.scale==3);
    CHECK([d doRestore]);
    puts("PASS sleep/wake: preserve successful settings, delayed reapply, repeated notifications, retry then success, five-attempt limit, restore/manual-edit cancellation, failed edit exclusion. No device writes.");
    CHECK(TSFlushLog());[[NSFileManager defaultManager]removeItemAtPath:dir error:NULL];
    puts("PASS UI: login item enable/disable, pending approval cancellation, error rollback, external status sync without real registration or device writes; release-only actions, both sliders auto-apply once, no Apply button, startup/refresh/programmatic reset do not apply, restore does not re-enable, failure feedback, precise numeric input, invalid input rejection, preset load applies once, delete does not apply or reset current parameters, 0.10–3.00 range. No input backend or listener started.");
}return 0;}
