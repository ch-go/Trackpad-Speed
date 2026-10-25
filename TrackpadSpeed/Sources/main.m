#import <Cocoa/Cocoa.h>
#import "Backend.h"
#import "Log.h"
#import "PointerTrace.h"
#import "CurvePreview.h"
#import "Curve.h"
#import "PresetStore.h"
@interface TSRateLabel : NSTextField
@end
@implementation TSRateLabel
- (void)mouseDown:(NSEvent *)event {
    if(event.clickCount==2 && self.enabled)[NSApp sendAction:self.action to:self.target from:self];else[super mouseDown:event];
}
@end
@interface AppDelegate : NSObject <NSApplicationDelegate>
@property TSBackend *backend;
@property TSPointerTrace *trace;
@property NSStatusItem *item;
@property NSPopover *popover;
@property NSSlider *slider;
@property NSTextField *value;
@property NSSlider *strengthSlider;
@property NSTextField *strengthValue;
@property TSCurvePreview *curvePreview;
@property NSDictionary *previewBaseline;
@property TSPresetStore *presets;
@property NSPopUpButton *presetPopup;
@property NSButton *deletePresetButton;
@property NSStackView *contentStack;
@property NSTextField *status;
@property NSButton *restoreButton;
@end
@implementation AppDelegate
- (NSTextField *)label:(NSString *)text size:(CGFloat)size color:(NSColor *)color {
    NSTextField *v=[NSTextField wrappingLabelWithString:text]; v.font=[NSFont systemFontOfSize:size];v.textColor=color;return v;
}
- (NSButton *)button:(NSString *)title action:(SEL)selector {
    return [NSButton buttonWithTitle:title target:self action:selector];
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    TSBeginOperation(@"app.start");
    self.backend=[TSBackend new];self.trace=[TSPointerTrace new];self.presets=[TSPresetStore new];TSLog(@"log.retention.policy",@{@"maxFileBytes":@(TSLogFileLimit()),@"maxFiles":@3,@"maxTotalBytes":@(TSLogTotalLimit()),@"legacyFilesIncluded":@YES});TSLog(@"app.start",@{@"system":NSProcessInfo.processInfo.operatingSystemVersionString,@"version":@"0.8.0"});
    self.item=[[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.item.button.image=[NSImage imageWithSystemSymbolName:@"cursorarrow.motionlines" accessibilityDescription:@"Trackpad Speed"];
    self.item.button.target=self;self.item.button.action=@selector(toggle:);
    [self buildPopover];
    NSNotificationCenter *nc=NSWorkspace.sharedWorkspace.notificationCenter;
    [nc addObserver:self selector:@selector(sleep:) name:NSWorkspaceWillSleepNotification object:nil];
    [nc addObserver:self selector:@selector(wake:) name:NSWorkspaceDidWakeNotification object:nil];
    [self refresh];TSEndOperation(YES,nil);
}
- (void)buildPopover {
    self.popover=[NSPopover new];self.popover.behavior=NSPopoverBehaviorTransient;
    NSViewController *vc=[NSViewController new];vc.view=[[NSView alloc]initWithFrame:NSMakeRect(0,0,360,670)];
    NSStackView *stack=[NSStackView new];self.contentStack=stack; stack.orientation=NSUserInterfaceLayoutOrientationVertical;stack.alignment=NSLayoutAttributeLeading;stack.spacing=10;stack.translatesAutoresizingMaskIntoConstraints=NO;
    [vc.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:24],[stack.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-24],[stack.topAnchor constraintEqualToAnchor:vc.view.topAnchor constant:22],[stack.bottomAnchor constraintLessThanOrEqualToAnchor:vc.view.bottomAnchor constant:-20]]];
    NSTextField *title=[self label:@"Trackpad Speed" size:21 color:NSColor.labelColor];title.font=[NSFont systemFontOfSize:21 weight:NSFontWeightSemibold];[stack addArrangedSubview:title];
    [stack addArrangedSubview:[self label:@"内置触控板 · 速度与加速度" size:12 color:NSColor.secondaryLabelColor]];
    self.value=[TSRateLabel labelWithString:@"1.25×"];self.value.textColor=NSColor.controlAccentColor;self.value.target=self;self.value.action=@selector(editRate:);self.value.toolTip=@"双击输入精确倍率（1–4，最多3位小数）";self.value.font=[NSFont monospacedDigitSystemFontOfSize:34 weight:NSFontWeightMedium];[stack addArrangedSubview:self.value];
    self.slider=[NSSlider sliderWithValue:1.25 minValue:1 maxValue:4 target:self action:@selector(slide:)]; self.slider.continuous=NO; [self.slider setAccessibilityLabel:@"目标曲线倍率"];[stack addArrangedSubview:self.slider];[self.slider.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active=YES;
    NSStackView *speedRange=[NSStackView stackViewWithViews:@[[self label:@"1× 基准倍率" size:11 color:NSColor.secondaryLabelColor],[self label:@"4×" size:11 color:NSColor.secondaryLabelColor]]];speedRange.distribution=NSStackViewDistributionEqualSpacing;[stack addArrangedSubview:speedRange];
    self.strengthValue=[self label:@"加速对比  1.00 · 原始曲线" size:13 color:NSColor.labelColor];[stack addArrangedSubview:self.strengthValue];
    self.strengthSlider=[NSSlider sliderWithValue:1 minValue:TSMinimumContrast() maxValue:TSMaximumContrast() target:self action:@selector(strengthChanged:)];self.strengthSlider.continuous=NO;
    [self.strengthSlider setAccessibilityLabel:@"加速对比，1保持原曲线，调低更柔和，调高更明显"];
    self.strengthSlider.toolTip=@"围绕固定参考点调节慢快差距。调高后慢移更慢、快移更快；不是额外速度倍数。";[stack addArrangedSubview:self.strengthSlider];
    [stack addArrangedSubview:[self label:@"差距小 0.10       原曲线 1.00       差距大 3.00" size:11 color:NSColor.secondaryLabelColor]];
    self.curvePreview=[[TSCurvePreview alloc]initWithFrame:NSMakeRect(0,0,312,84)];[stack addArrangedSubview:self.curvePreview];[self.curvePreview.heightAnchor constraintEqualToConstant:84].active=YES;
    [stack addArrangedSubview:[self label:@"灰：同倍率原曲线  蓝：目标  ·  圆点：固定参考点" size:11 color:NSColor.secondaryLabelColor]];
    NSStackView *actions=[NSStackView new];actions.orientation=NSUserInterfaceLayoutOrientationHorizontal;actions.spacing=10;
    self.restoreButton=[self button:@"恢复原始值" action:@selector(restore:)];self.restoreButton.bezelStyle=NSBezelStyleRounded;
    [actions addArrangedSubview:self.restoreButton];[stack addArrangedSubview:actions];
    NSStackView *presetRow=[NSStackView new];presetRow.orientation=NSUserInterfaceLayoutOrientationHorizontal;presetRow.spacing=8;
    self.presetPopup=[[NSPopUpButton alloc]initWithFrame:NSZeroRect pullsDown:NO];[(NSPopUpButtonCell *)self.presetPopup.cell setLineBreakMode:NSLineBreakByTruncatingTail];[self.presetPopup setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];self.presetPopup.target=self;self.presetPopup.action=@selector(presetSelected:);[self.presetPopup setAccessibilityLabel:@"选择已存设置组并立即应用"];
    [presetRow addArrangedSubview:self.presetPopup];[presetRow addArrangedSubview:[self button:@"保存当前" action:@selector(savePreset:)]];self.deletePresetButton=[self button:@"删除" action:@selector(deletePreset:)];self.deletePresetButton.toolTip=@"删除所选设置组，不改变当前触控板参数";[presetRow addArrangedSubview:self.deletePresetButton];[stack addArrangedSubview:presetRow];
    self.status=[self label:@"" size:12 color:NSColor.secondaryLabelColor];self.status.maximumNumberOfLines=4;self.status.hidden=YES;[stack addArrangedSubview:self.status];[self reloadPresets:nil];
    NSButton *trace=[NSButton checkboxWithTitle:@"记录指针轨迹（调试）" target:self action:@selector(traceChanged:)];[stack addArrangedSubview:trace];
    [stack addArrangedSubview:[self button:@"打开日志文件夹" action:@selector(openLogs:)]];
    for(NSView *v in stack.arrangedSubviews) [v.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active=YES;
    [stack addArrangedSubview:[self button:@"恢复并退出" action:@selector(quit:)]];
    self.popover.contentViewController=vc;self.popover.contentSize=NSMakeSize(360,670);[self fitPopover];
}
- (void)fitPopover {
    [self.popover.contentViewController.view layoutSubtreeIfNeeded];
    CGFloat height=self.contentStack.fittingSize.height+44;
    self.popover.contentSize=NSMakeSize(360,height);
}
- (void)showStatus:(NSString *)text {
    self.status.stringValue=text?:@"";self.status.hidden=text.length==0;[self fitPopover];
}
- (void)reloadPresets:(NSString *)selectedID {
    NSError *error=nil;NSArray *items=[self.presets load:&error];[self.presetPopup removeAllItems];[self.presetPopup addItemWithTitle:@"已存设置…"];self.presetPopup.lastItem.enabled=NO;
    for(NSDictionary *item in items){[self.presetPopup addItemWithTitle:item[@"name"]];self.presetPopup.lastItem.representedObject=item;if([item[@"id"]isEqual:selectedID])[self.presetPopup selectItem:self.presetPopup.lastItem];}
    self.deletePresetButton.enabled=self.presetPopup.selectedItem.representedObject!=nil;
    if(error){TSLog(@"presets.load.failed",@{@"error":error.localizedDescription});[self showStatus:error.localizedDescription];}
}
- (void)savePreset:(id)sender {
    NSAlert *alert=[NSAlert new];alert.messageText=@"保存当前设置组";alert.informativeText=@"保存面板中的整体倍率和加速对比。同名设置会更新；保存不会额外应用参数。";
    NSTextField *name=[[NSTextField alloc]initWithFrame:NSMakeRect(0,0,280,24)];name.placeholderString=@"例如：精细工作 / 快速跨屏";alert.accessoryView=name;alert.window.initialFirstResponder=name;[alert addButtonWithTitle:@"保存"];[alert addButtonWithTitle:@"取消"];
    if([alert runModal]!=NSAlertFirstButtonReturn)return;
    NSError *error=nil;NSDictionary *item=[self.presets saveName:name.stringValue scale:self.slider.doubleValue contrast:self.strengthSlider.doubleValue error:&error];
    if(item){[self reloadPresets:item[@"id"]];[self showStatus:nil];}else [self showStatus:error.localizedDescription?:@"保存失败。"];
}
- (void)presetSelected:(id)sender {
    NSDictionary *item=self.presetPopup.selectedItem.representedObject;if(![TSPresetStore validPreset:item])return;
    self.deletePresetButton.enabled=YES;
    TSLog(@"presets.select",@{@"id":item[@"id"],@"scale":item[@"scale"],@"contrast":item[@"contrast"]});
    self.slider.doubleValue=[item[@"scale"]doubleValue];self.strengthSlider.doubleValue=[item[@"contrast"]doubleValue];[self slide:nil];[self strengthChanged:nil];[self apply:self.presetPopup];
}
- (void)deletePreset:(id)sender {
    NSDictionary *item=self.presetPopup.selectedItem.representedObject;if(![TSPresetStore validPreset:item])return;
    NSError *error=nil;if([self.presets deleteID:item[@"id"] error:&error]){[self reloadPresets:nil];[self showStatus:nil];}
    else [self showStatus:error.localizedDescription?:@"删除设置组失败。"];
}
- (BOOL)commitRateText:(NSString *)text {
    NSString *clean=[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSRegularExpression *pattern=[NSRegularExpression regularExpressionWithPattern:@"^[0-9]+(?:\\.[0-9]{1,3})?$" options:0 error:NULL];
    BOOL valid=clean.length && [pattern numberOfMatchesInString:clean options:0 range:NSMakeRange(0,clean.length)]==1;
    double rate=clean.doubleValue;
    if(!valid || !isfinite(rate) || rate<1 || rate>4){TSLog(@"ui.numeric.rejected",@{@"reason":@"expected 1–4 with up to 3 decimal places"});[self showStatus:@"请输入1–4之间的倍率，最多3位小数，例如2.375。"];return NO;}
    self.slider.doubleValue=rate;[self slide:nil];[self apply:self.value];return YES;
}
- (void)editRate:(id)sender {
    NSAlert *alert=[NSAlert new];alert.messageText=@"输入速度倍率";alert.informativeText=@"范围1–4，最多3位小数。确认后立即应用。";
    NSTextField *input=[[NSTextField alloc]initWithFrame:NSMakeRect(0,0,240,24)];input.stringValue=[NSString stringWithFormat:@"%.3f",self.slider.doubleValue];alert.accessoryView=input;alert.window.initialFirstResponder=input;[input selectText:nil];[alert addButtonWithTitle:@"确定"];[alert addButtonWithTitle:@"取消"];
    if([alert runModal]==NSAlertFirstButtonReturn)[self commitRateText:input.stringValue];
}
- (void)traceChanged:(NSButton *)sender {
    if(sender.state==NSControlStateValueOn) {NSError *e=nil;if(![self.trace start:&e]){sender.state=NSControlStateValueOff;[self showStatus:e.localizedDescription?:@"无法启动指针日志。"];}}else [self.trace stop];
}
- (void)openLogs:(id)sender { TSFlushLog();[NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:TSLogDirectory() isDirectory:YES]]; }
- (void)refresh {
    NSError *error=nil;BOOL ok=[self.backend inspect:&error];
    self.slider.enabled=ok;self.strengthSlider.enabled=ok;self.restoreButton.enabled=self.backend.hasRecovery;
    if(ok){self.previewBaseline=[self.backend previewBaseline:NULL];[self updatePreview];}
    if(!ok)[self showStatus:error.localizedDescription?:@"无法读取设备状态。"];
    else if(self.backend.hasRecovery && !self.backend.active)[self showStatus:@"有待恢复记录，请先恢复原始值。"];
    else [self showStatus:nil];
}
- (void)toggle:(id)sender {
    if(self.popover.shown)[self.popover close];
    else { [self refresh];[self.popover showRelativeToRect:self.item.button.bounds ofView:self.item.button preferredEdge:NSRectEdgeMinY]; }
}
- (void)slide:(id)sender {
    double n=sender==self.slider?round(self.slider.doubleValue*20)/20:self.slider.doubleValue;self.slider.doubleValue=n;
    NSNumberFormatter *format=[NSNumberFormatter new];format.locale=[[NSLocale alloc]initWithLocaleIdentifier:@"en_US_POSIX"];format.minimumFractionDigits=2;format.maximumFractionDigits=3;
    self.value.stringValue=[[format stringFromNumber:@(n)]stringByAppendingString:@"×"];[self updatePreview];
    if(sender==self.slider && self.backend)[self apply:sender];
}
- (void)strengthChanged:(id)sender {
    double n=sender==self.strengthSlider?round(self.strengthSlider.doubleValue*20)/20:self.strengthSlider.doubleValue;self.strengthSlider.doubleValue=n;
    NSString *note=fabs(n-1)<0.001?@"原始曲线":(n<1?@"慢快差距更小":@"慢移更稳 · 快移更快");
    self.strengthValue.stringValue=[NSString stringWithFormat:@"加速对比  %.2f · %@",n,note];[self updatePreview];
    if(sender==self.strengthSlider && self.backend)[self apply:sender];
}
- (void)updatePreview {
    if(self.previewBaseline)[self.curvePreview updateCurves:self.previewBaseline[@"curves"] index:[self.previewBaseline[@"index"]doubleValue] scale:self.slider.doubleValue strength:self.strengthSlider.doubleValue];
}
- (void)apply:(id)sender {
    TSBeginOperation(@"ui.settings.commit");
    NSString *source=sender==self.slider?@"speedSlider":sender==self.strengthSlider?@"contrastSlider":sender==self.value?@"numericInput":@"preset";
    TSLog(@"ui.settings.commit",@{@"control":source,@"targetScale":@(self.slider.doubleValue),@"curveStrength":@(self.strengthSlider.doubleValue),@"trigger":source});
    NSError *error=nil;
    BOOL applied=[self.backend apply:self.slider.doubleValue strength:self.strengthSlider.doubleValue error:&error];
    if(applied) {
        [self showStatus:nil];
        self.item.button.toolTip=[NSString stringWithFormat:@"目标 %.2f× · 加速对比 %.2f",self.slider.doubleValue,self.strengthSlider.doubleValue];
    } else {TSLog(@"apply.failed",@{@"error":error.localizedDescription?:@"unknown"});[self showStatus:[NSString stringWithFormat:@"应用失败：%@",error.localizedDescription]];}
    self.restoreButton.enabled=self.backend.hasRecovery;TSEndOperation(applied,error);TSFlushLog();
}
- (BOOL)doRestore {
    NSError *error=nil;
    if(![self.backend restore:&error]) { TSLog(@"restore.failed",@{@"error":error.localizedDescription?:@"unknown"});[self showStatus:[NSString stringWithFormat:@"恢复失败：%@",error.localizedDescription]];return NO; }
    [self.presetPopup selectItemAtIndex:0];self.deletePresetButton.enabled=NO;self.slider.doubleValue=1;self.strengthSlider.doubleValue=1;[self strengthChanged:nil];[self slide:nil];self.item.button.toolTip=@"原始曲线";
    [self showStatus:nil];self.restoreButton.enabled=NO;return YES;
}
- (void)restore:(id)sender { [self doRestore]; }
- (void)quit:(id)sender { [NSApp terminate:nil]; }
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    TSBeginOperation(@"app.quit");
    TSLog(@"app.quit.request",@{@"recoveryPending":@(self.backend.hasRecovery)});
    if(self.backend.hasRecovery && ![self doRestore]) {
        NSAlert *alert=[NSAlert new];alert.messageText=@"未能恢复原始曲线";alert.informativeText=[self.status.stringValue stringByAppendingString:@"\n恢复记录已保留，可继续运行重试或退出后稍后恢复。"];
        [alert addButtonWithTitle:@"继续运行"];[alert addButtonWithTitle:@"退出并保留恢复记录"];
        if([alert runModal]==NSAlertFirstButtonReturn){TSLog(@"app.quit.cancelled",@{});TSEndOperation(NO,nil);return NSTerminateCancel;}
        TSLog(@"app.quit.with.recovery",@{@"backupRetained":@YES});
    }
    [self.trace stop];TSLog(@"app.quit",@{});TSEndOperation(YES,nil);TSFlushLog();return NSTerminateNow;
}
- (void)sleep:(NSNotification *)notification {
    TSBeginOperation(@"system.sleep");TSLog(@"system.sleep",@{@"recoveryPending":@(self.backend.hasRecovery)});
    BOOL ok=!self.backend.hasRecovery || [self doRestore];TSEndOperation(ok,nil);TSFlushLog();
}
- (void)wake:(NSNotification *)notification {
    TSBeginOperation(@"system.wake");TSLog(@"system.wake",@{@"autoApply":@NO});[self refresh];
    if(!self.backend.hasRecovery)[self showStatus:nil];TSEndOperation(YES,nil);
}

@end
int main(int argc,const char *argv[]) {
    @autoreleasepool {
        // Read-only diagnostic mode never creates UI or invokes apply/restore.
        if(argc==2 && strcmp(argv[1],"--diagnose-only")==0) {
            TSBackend *b=[TSBackend new];NSError *e=nil;BOOL ok=[b inspect:&e];
            printf("%s\n",[(ok?[NSString stringWithFormat:@"Compatible curve format found: %@; no settings changed.",b.deviceName]:e.localizedDescription) UTF8String]);TSFlushLog();return ok?0:1;
        }
        NSString *bid=NSBundle.mainBundle.bundleIdentifier;
        for(NSRunningApplication *a in [NSRunningApplication runningApplicationsWithBundleIdentifier:bid]) if(a.processIdentifier!=getpid()) { [a activateWithOptions:0];return 0; }
        NSApplication *app=NSApplication.sharedApplication;[app setActivationPolicy:NSApplicationActivationPolicyAccessory];AppDelegate *d=[AppDelegate new];app.delegate=d;[app run];
    }return 0;
}
