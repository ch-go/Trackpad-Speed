#import "PointerTrace.h"
#import "Log.h"
#import <ApplicationServices/ApplicationServices.h>
@interface TSPointerTrace ()
@property BOOL running;
@property uint64_t sequence;
@property NSString *traceID;
@end
@implementation TSPointerTrace {
    CFMachPortRef _tap;
    CFRunLoopSourceRef _source;
}
static CGEventRef TraceCallback(CGEventTapProxy proxy,CGEventType type,CGEventRef event,void *context) {
    TSPointerTrace *t=(__bridge TSPointerTrace *)context;
    if(type==kCGEventTapDisabledByTimeout || type==kCGEventTapDisabledByUserInput) {
        TSLog(@"pointer.trace.interrupted",@{@"operationID":t.traceID?:@"session",@"reason":type==kCGEventTapDisabledByTimeout?@"timeout":@"userInput",@"note":@"gap in observations; attempting re-enable"});
        if(t->_tap)CGEventTapEnable(t->_tap,true);return event;
    }
    CGPoint p=CGEventGetLocation(event);
    NSMutableDictionary *fields=[@{@"sequence":@(++t.sequence),@"eventTimestampNS":@(CGEventGetTimestamp(event)),@"type":@(type),@"x":@(p.x),@"y":@(p.y),@"producerPID":@(CGEventGetIntegerValueField(event,kCGEventSourceUnixProcessID)),@"stage":@"sessionEventTap.listenOnly",@"physicalDevice":@"unknown",@"operationID":t.traceID?:@"session"} mutableCopy];
    NSString *name=@"pointer.output";
    if(type==kCGEventScrollWheel) {
        name=@"mouse.scroll";
        fields[@"pointDeltaX"]=@(CGEventGetIntegerValueField(event,kCGScrollWheelEventPointDeltaAxis2));
        fields[@"pointDeltaY"]=@(CGEventGetIntegerValueField(event,kCGScrollWheelEventPointDeltaAxis1));
        fields[@"continuous"]=@(CGEventGetIntegerValueField(event,kCGScrollWheelEventIsContinuous));
    } else if(type==kCGEventLeftMouseDown || type==kCGEventLeftMouseUp || type==kCGEventRightMouseDown || type==kCGEventRightMouseUp || type==kCGEventOtherMouseDown || type==kCGEventOtherMouseUp) {
        name=@"mouse.button";fields[@"button"]=@(CGEventGetIntegerValueField(event,kCGMouseEventButtonNumber));
    } else {
        fields[@"deltaX"]=@(CGEventGetIntegerValueField(event,kCGMouseEventDeltaX));
        fields[@"deltaY"]=@(CGEventGetIntegerValueField(event,kCGMouseEventDeltaY));
    }
    TSLog(name,fields);
    return event;
}
- (BOOL)start:(NSError **)error {
    TSBeginOperation(@"pointer.trace.start");NSError *local=nil;BOOL ok=[self startBody:&local];if(error)*error=local;TSEndOperation(ok,local);return ok;
}
- (BOOL)startBody:(NSError **)error {
    if(self.running)return YES;
    self.traceID=NSThread.currentThread.threadDictionary[@"TSOperationID"];
    TSLog(@"pointer.permission.preflight",@{@"listenEventAccess":@(CGPreflightListenEventAccess()),@"readOnlyCheck":@YES});
    CGEventMask mask=CGEventMaskBit(kCGEventMouseMoved)|CGEventMaskBit(kCGEventLeftMouseDragged)|CGEventMaskBit(kCGEventRightMouseDragged)|CGEventMaskBit(kCGEventOtherMouseDragged)|CGEventMaskBit(kCGEventLeftMouseDown)|CGEventMaskBit(kCGEventLeftMouseUp)|CGEventMaskBit(kCGEventRightMouseDown)|CGEventMaskBit(kCGEventRightMouseUp)|CGEventMaskBit(kCGEventOtherMouseDown)|CGEventMaskBit(kCGEventOtherMouseUp)|CGEventMaskBit(kCGEventScrollWheel);
    _tap=CGEventTapCreate(kCGSessionEventTap,kCGTailAppendEventTap,kCGEventTapOptionListenOnly,mask,TraceCallback,(__bridge void *)self);
    if(!_tap) {
        TSLog(@"pointer.trace.start.failed",@{@"cause":@"event tap unavailable; permission or system restriction",@"listenEventAccess":@(CGPreflightListenEventAccess())});
        if(error)*error=[NSError errorWithDomain:@"TrackpadSpeed" code:3 userInfo:@{NSLocalizedDescriptionKey:@"无法监听指针。请在系统设置 → 隐私与安全性 → 输入监控中允许此应用，然后重新打开。系统也可能限制事件监听。"}];return NO;
    }
    _source=CFMachPortCreateRunLoopSource(NULL,_tap,0);
    if(!_source) {CFRelease(_tap);_tap=NULL;if(error)*error=[NSError errorWithDomain:@"TrackpadSpeed" code:4 userInfo:@{NSLocalizedDescriptionKey:@"无法创建指针监听运行源。"}];return NO;}
    CFRunLoopAddSource(CFRunLoopGetMain(),_source,kCFRunLoopCommonModes);CGEventTapEnable(_tap,true);self.running=YES;self.sequence=0;
    TSLog(@"pointer.trace.start",@{@"stage":@"post-system session mouse events",@"rawHIDAvailable":@NO,@"deviceAttributionAvailable":@NO,@"keyboardLogged":@NO,@"clicksLogged":@YES,@"scrollLogged":@YES});return YES;
}
- (void)stop {
    if(!self.running && !_tap && !_source)return;
    TSBeginOperation(@"pointer.trace.stop");
    TSLog(@"pointer.trace.stop.request",@{@"traceOperationID":self.traceID?:@"unknown"});
    if(_tap){CGEventTapEnable(_tap,false);CFMachPortInvalidate(_tap);}
    if(_source){CFRunLoopRemoveSource(CFRunLoopGetMain(),_source,kCFRunLoopCommonModes);CFRelease(_source);_source=NULL;}
    if(_tap){CFRelease(_tap);_tap=NULL;}
    if(self.running){self.running=NO;TSLog(@"pointer.trace.stop",@{@"events":@(self.sequence)});TSFlushLog();}
    TSEndOperation(YES,nil);
}
- (void)dealloc { [self stop]; }
@end
