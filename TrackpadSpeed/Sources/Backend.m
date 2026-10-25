#import "Backend.h"
#import "Curve.h"
#import "Log.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/hidsystem/IOHIDEventSystemClient.h>
#import <IOKit/hidsystem/IOHIDServiceClient.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <dlfcn.h>
static NSString *const CurveKey=@"HIDAccelCurves";
static NSString *const OverrideKey=@"UserPointerAccelCurvesKey";
static NSString *const TypeKey=@"HIDPointerAccelerationType";
static NSString *const TrackpadType=@"HIDTrackpadAcceleration";
static NSError *Failure(NSString *s) { return [NSError errorWithDomain:@"TrackpadSpeed" code:2 userInfo:@{NSLocalizedDescriptionKey:s}]; }
static NSString *Boot(void) {
    char b[128]={0};size_t n=sizeof(b);if(sysctlbyname("kern.bootsessionuuid",b,&n,NULL,0)!=0)return nil;return [NSString stringWithUTF8String:b];
}
static NSDictionary *Diff(NSArray *wanted,NSArray *actual) {
    NSMutableArray *fields=[NSMutableArray array];NSUInteger count=0;
    if(![actual isKindOfClass:NSArray.class])return @{@"actualMissingOrInvalid":@YES};
    for(NSUInteger i=0;i<MIN(wanted.count,actual.count);i++) {
        NSDictionary *a=wanted[i],*b=actual[i];
        if(![b isKindOfClass:NSDictionary.class]){count++;continue;}
        NSMutableSet *keys=[NSMutableSet setWithArray:a.allKeys];[keys addObjectsFromArray:b.allKeys];
        for(NSString *key in [keys.allObjects sortedArrayUsingSelector:@selector(compare:)]) if(![a[key] isEqual:b[key]]) {
            count++;if(fields.count<12)[fields addObject:@{@"curve":@(i),@"key":key,@"wanted":a[key]?:NSNull.null,@"actual":b[key]?:NSNull.null}];
        }
    }
    return @{@"wantedCount":@(wanted.count),@"actualCount":@(actual.count),@"differentFieldCount":@(count),@"firstDifferences":fields};
}
static id PointerFilter(id object) {
    if([object isKindOfClass:NSDictionary.class]) {
        if([object[@"Class"] isEqual:@"IOHIDPointerScrollFilter"])return object;
        for(id value in [object allValues]){id found=PointerFilter(value);if(found)return found;}
    }else if([object isKindOfClass:NSArray.class]) for(id value in object){id found=PointerFilter(value);if(found)return found;}
    return nil;
}
@interface TSBackend ()
@property NSString *deviceName;
@property BOOL active;
@property NSDictionary *record;
@property NSURL *recordURL;
@property id service;
@property uint64_t registryID;
@property NSString *registryClass;
@property BOOL staleRecovery;
@property NSURL *archivedRecoveryURL;
@end
@implementation TSBackend { IOHIDEventSystemClientRef _client; }
- (instancetype)init {
    if((self=[super init])) {
        TSBeginOperation(@"client.create");
        NSURL *base=[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        _recordURL=[[base URLByAppendingPathComponent:@"TrackpadSpeed" isDirectory:YES] URLByAppendingPathComponent:@"recovery.plist"];
        // Private SPI, deliberately isolated and dynamically resolved. No admin/monitor client,
        // privileged helper, entitlement spoofing, global property write, or event subscription.
        typedef IOHIDEventSystemClientRef(*Create)(CFAllocatorRef,int,CFDictionaryRef);
        Create create=(Create)dlsym(RTLD_DEFAULT,"IOHIDEventSystemClientCreateWithType");
        TSLog(@"client.symbol",@{@"symbol":@"IOHIDEventSystemClientCreateWithType",@"available":@(create!=NULL),@"interface":@"private SPI"});
        _client=create?create(NULL,2,NULL):NULL;
        TSLog(@"client.create.result",@{@"type":@"Passive",@"typeValue":@2,@"created":@(_client!=NULL),@"interface":@"private SPI",@"entitlementsRequested":@NO});
        TSEndOperation(_client!=NULL,_client?nil:Failure(@"Passive HID 客户端不可用；没有切换到权限更高的客户端。"));
    }return self;
}
- (void)dealloc {if(_client)CFRelease(_client);}
- (BOOL)hasRecovery {return self.record!=nil || [[NSFileManager defaultManager]fileExistsAtPath:self.recordURL.path];}
- (io_service_t)entry {return IOServiceGetMatchingService(kIOMainPortDefault,IORegistryEntryIDMatching(self.registryID));}
- (id)serviceProperty:(NSString *)key {
    id value=self.service?CFBridgingRelease(IOHIDServiceClientCopyProperty((__bridge IOHIDServiceClientRef)self.service,(__bridge CFStringRef)key)):nil;
    TSLog(@"property.read",@{@"source":@"HID property getter; can expose driver defaults",@"registryID":@(self.registryID),@"registryClass":self.registryClass?:@"unknown",@"key":key,@"present":@(value!=nil),@"hash":TSHash(value),@"value":value?:NSNull.null});return value;
}
- (BOOL)setServiceProperty:(id)value key:(NSString *)key {
    return self.service && IOHIDServiceClientSetProperty((__bridge IOHIDServiceClientRef)self.service,(__bridge CFStringRef)key,(__bridge CFTypeRef)value);
}
- (NSArray *)registryCurves {
    io_service_t e=[self entry];id c=e?CFBridgingRelease(IORegistryEntryCreateCFProperty(e,(__bridge CFStringRef)CurveKey,NULL,0)):nil;if(e)IOObjectRelease(e);
    TSLog(@"registry.reference.read",@{@"registryID":@(self.registryID),@"registryClass":self.registryClass?:@"unknown",@"key":CurveKey,@"present":@(c!=nil),@"hash":TSHash(c),@"role":@"driver registry reference only; not write target"});return [c isKindOfClass:NSArray.class]?c:nil;
}
- (NSArray *)curves:(NSError **)error {
    id c=[self serviceProperty:CurveKey];return TSScaleCurves(c,1,error)?c:nil;
}
- (id)systemRecords {
    return _client?CFBridgingRelease(IOHIDEventSystemClientCopyProperty(_client,CFSTR("ServiceRecords"))):nil;
}
- (NSDictionary *)snapshot:(NSError **)error {
    id records=[self systemRecords];NSMutableArray *matches=[NSMutableArray array];
    if([records isKindOfClass:NSArray.class])for(id r in records)if([r isKindOfClass:NSDictionary.class] && [r[@"IORegistryEntryID"]unsignedLongLongValue]==self.registryID)[matches addObject:r];
    TSLog(@"state.records.read",@{@"source":@"ServiceRecords",@"totalRecords":@([records isKindOfClass:NSArray.class]?[records count]:0),@"targetMatches":@(matches.count),@"registryID":@(self.registryID)});
    if(matches.count!=1){if(error)*error=Failure(@"无法取得唯一的完整 HID 服务状态；不会仅凭属性读回判成功。");return nil;}
    NSDictionary *r=matches.firstObject;id filter=PointerFilter(r[@"ServiceFilterDebug"]);
    NSDictionary *active=filter[@"Pointer Accelerator"][@"Accelerator"];
    id index=filter[@"PointerAccelerationValue"];
    NSArray *driver=[self curves:error];
    if(!filter || !driver || ![active isKindOfClass:NSDictionary.class] || ![index isKindOfClass:NSNumber.class] || [index doubleValue]<0) {
        if(error)*error=Failure(@"没有可验证的参数式指针加速过滤器，已停止操作。");return nil;
    }
    id user=filter[@"Property"][OverrideKey];
    if(user && (![user isKindOfClass:NSArray.class] || ([user count] && !TSScaleCurves(user,1,error))))return nil;
    id cache=r[@"ServicePluginDebug"][@"CachedProperties"][CurveKey];
    NSDictionary *state=@{@"driverCurves":driver,@"overridePresent":@(user!=nil),@"override":user?:@[],@"active":active,@"index":index,@"pluginCache":cache?:NSNull.null,@"filter":filter};
    TSLog(@"state.snapshot",@{@"registryID":@(self.registryID),@"registryClass":r[@"IOClass"]?:@"unknown",@"driverCurveHash":TSHash(driver),@"pluginCacheHash":TSHash(cache),@"pluginCacheMatchesDriver":@(!cache || [cache isEqual:driver]),@"overridePresent":@(user!=nil),@"overrideHash":TSHash(user),@"overrideCurves":user?:@[],@"active":active,@"index":index,@"pointerFilterObservable":@YES,@"physicalEffectVerified":@NO});
    return state;
}
- (NSArray *)effectiveCurves:(NSDictionary *)state {
    return [state[@"override"]count]?state[@"override"]:state[@"driverCurves"];
}
- (BOOL)loadRecovery:(NSError **)error {
    if(!self.hasRecovery){TSLog(@"recovery.absent",@{});return YES;}
    if([[NSFileManager defaultManager]fileExistsAtPath:self.recordURL.path])self.archivedRecoveryURL=nil;
    NSURL *source=self.archivedRecoveryURL?:self.recordURL;
    NSData *data=[NSData dataWithContentsOfURL:source options:0 error:error];
    TSLog(@"recovery.read",@{@"present":@(data!=nil),@"backupHash":TSHash(data)});if(!data)return NO;
    id r=[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:error];
    if(![r isKindOfClass:NSDictionary.class] || ![@[@1,@2,@3]containsObject:r[@"version"]] || ![r[@"boot"]isKindOfClass:NSString.class] || ![r[@"registryID"]isKindOfClass:NSNumber.class] || ![r[@"product"]isKindOfClass:NSString.class] || !TSScaleCurves(r[@"curves"],1,error)) {
        if(error)*error=Failure(@"恢复记录损坏；已保留文件并禁止覆盖。");return NO;
    }
    if([r[@"version"]intValue]>=2 && ![r[@"accelerationType"]isEqual:TrackpadType]){if(error)*error=Failure(@"恢复记录的加速度类型无效，文件已保留。");return NO;}
    if([r[@"version"]isEqual:@3]) {
        id user=r[@"override"],driver=r[@"driverCurves"],index=r[@"originalIndex"];
        BOOL valid=[user isKindOfClass:NSArray.class] && (![(NSArray *)user count] || TSScaleCurves(user,1,NULL)) && TSScaleCurves(driver,1,NULL) && [index isKindOfClass:NSNumber.class];
        NSArray *effective=[user isKindOfClass:NSArray.class] && [user count]?user:driver;
        if(!valid || ![effective isEqual:r[@"curves"]] || !TSActiveCurveMatches(effective,[index doubleValue],r[@"originalActive"],NULL)) {
            if(error)*error=Failure(@"覆盖曲线备份及原始过滤器不一致，文件已保留。");return NO;
        }
    }
    self.record=r;self.staleRecovery=![r[@"boot"]isEqual:Boot()];
    TSLog(@"recovery.validated",@{@"version":r[@"version"],@"originalCurveHash":TSHash(r[@"curves"]),@"sameBoot":@(!self.staleRecovery),@"retained":@YES});
    if(!self.staleRecovery && ([r[@"registryID"]unsignedLongLongValue]!=self.registryID || ![r[@"product"]isEqual:self.deviceName])) {
        if(error)*error=Failure(@"恢复记录对应设备已变化。保留记录并禁止修改。");return NO;
    }return YES;
}
- (BOOL)discoverArchivedLegacy:(NSDictionary *)state error:(NSError **)error {
    if(self.record || !state || state[@"pluginCache"]==NSNull.null || [state[@"pluginCache"]isEqual:state[@"driverCurves"]] || [state[@"override"]count])return YES;
    NSURL *dir=self.recordURL.URLByDeletingLastPathComponent;
    NSArray *files=[[NSFileManager defaultManager]contentsOfDirectoryAtURL:dir includingPropertiesForKeys:nil options:0 error:NULL];
    for(NSURL *file in files) {
        if(![file.lastPathComponent hasPrefix:@"recovery-restored-"] || ![file.pathExtension isEqual:@"plist"])continue;
        NSData *data=[NSData dataWithContentsOfURL:file];
        id r=data?[NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL]:nil;
        if(![r isKindOfClass:NSDictionary.class] || ![@[@1,@2]containsObject:r[@"version"]] || ![r[@"boot"]isEqual:Boot()] || [r[@"registryID"]unsignedLongLongValue]!=self.registryID || ![r[@"product"]isEqual:self.deviceName] || ![r[@"curves"]isEqual:state[@"driverCurves"]])continue;
        self.record=r;self.archivedRecoveryURL=file;self.staleRecovery=NO;
        TSLog(@"recovery.legacy.residue.detected",@{@"archiveName":file.lastPathComponent,@"backupHash":TSHash(data),@"originalCurveHash":TSHash(r[@"curves"]),@"pluginCacheHash":TSHash(state[@"pluginCache"]),@"sourceArchiveUnchanged":@YES,@"automaticWrite":@NO});return YES;
    }
    TSLog(@"recovery.legacy.residue.unmatched",@{@"pluginCacheHash":TSHash(state[@"pluginCache"]),@"automaticWrite":@NO});return YES;
}
- (BOOL)inspectBody:(NSError **)error {
    if(!_client){if(error)*error=Failure(@"Passive HID 客户端不可用，不能操作运行时曲线。");return NO;}
    NSArray *services=CFBridgingRelease(IOHIDEventSystemClientCopyServices(_client));NSMutableArray *matches=[NSMutableArray array];NSUInteger rejected=0;
    for(id s in services) {
        IOHIDServiceClientRef ref=(__bridge IOHIDServiceClientRef)s;
        id type=CFBridgingRelease(IOHIDServiceClientCopyProperty(ref,(__bridge CFStringRef)TypeKey));
        if(![type isEqual:TrackpadType]){rejected++;continue;}
        id built=CFBridgingRelease(IOHIDServiceClientCopyProperty(ref,CFSTR("Built-In")));
        BOOL eligible=[built respondsToSelector:@selector(boolValue)] && [built boolValue];
        TSLog(@"device.candidate",@{@"registryID":(__bridge id)IOHIDServiceClientGetRegistryID(ref),@"accelerationType":type,@"builtIn":@(eligible),@"selectedCandidate":@(eligible)});
        if(eligible)[matches addObject:s];
    }
    TSLog(@"device.enumeration",@{@"total":@(services.count),@"rejectedOtherType":@(rejected),@"eligible":@(matches.count),@"clientType":@"Passive"});
    if(matches.count!=1){if(error)*error=Failure(@"未找到唯一内置触控板；不会操作其他输入设备。");return NO;}
    self.service=matches.firstObject;IOHIDServiceClientRef ref=(__bridge IOHIDServiceClientRef)self.service;
    self.registryID=[(__bridge NSNumber *)IOHIDServiceClientGetRegistryID(ref)unsignedLongLongValue];
    io_service_t entry=[self entry];io_name_t cls={0};if(entry){IOObjectGetClass(entry,cls);IOObjectRelease(entry);}self.registryClass=[NSString stringWithUTF8String:cls];
    id product=[self serviceProperty:@"Product"];self.deviceName=[product isKindOfClass:NSString.class]?product:@"内置触控板";
    TSLog(@"device.identify",@{@"registryID":@(self.registryID),@"registryClass":self.registryClass?:@"unknown",@"product":self.deviceName,@"builtIn":@YES,@"clientType":@"Passive"});
    if(!Boot()){if(error)*error=Failure(@"无法确定系统启动会话，禁止修改。");return NO;}
    if(![self loadRecovery:error])return NO;
    NSDictionary *state=[self snapshot:error];[self discoverArchivedLegacy:state error:error];[self registryCurves];
    if(state){NSDictionary *diff=nil;BOOL matches=TSActiveCurveMatches([self effectiveCurves:state],[state[@"index"]doubleValue],state[@"active"],&diff);TSLog(@"baseline.active.check",@{@"matches":@(matches),@"active":state[@"active"],@"diff":diff?:@{},@"physicalEffectVerified":@NO});}
    return state!=nil;
}
- (BOOL)inspect:(NSError **)error {
    TSBeginOperation(@"inspect");NSError *local=nil;BOOL ok=[self inspectBody:&local];if(error)*error=local;TSEndOperation(ok,local);TSFlushLog();return ok;
}
- (BOOL)saveOriginal:(NSArray *)curves state:(NSDictionary *)state error:(NSError **)error {
    NSDictionary *r=@{@"version":@3,@"boot":Boot(),@"registryID":@(self.registryID),@"product":self.deviceName,@"curves":curves,@"accelerationType":TrackpadType,@"source":@"complete ServiceRecords / pointer filter",@"created":NSDate.date,@"override":state[@"override"],@"overridePresent":state[@"overridePresent"],@"driverCurves":state[@"driverCurves"],@"originalActive":state[@"active"],@"originalIndex":state[@"index"]};
    NSURL *dir=self.recordURL.URLByDeletingLastPathComponent;
    TSLog(@"backup.prepare",@{@"curveHash":TSHash(curves),@"originalCurves":curves,@"originalOverride":state[@"override"],@"version":@3});
    if(![[NSFileManager defaultManager]createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error])return NO;
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:r format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];if(!data || ![data writeToURL:self.recordURL options:NSDataWritingAtomic error:error])return NO;
    chmod(self.recordURL.fileSystemRepresentation,0600);int fd=open(self.recordURL.fileSystemRepresentation,O_RDONLY);BOOL synced=fd>=0 && fsync(fd)==0;if(fd>=0)close(fd);
    int dd=open(dir.fileSystemRepresentation,O_RDONLY);synced=synced && dd>=0 && fsync(dd)==0;if(dd>=0)close(dd);
    NSData *check=[NSData dataWithContentsOfURL:self.recordURL];BOOL matches=[check isEqual:data];
    TSLog(@"backup.verify",@{@"diskSynchronized":@(synced),@"matches":@(matches),@"backupHash":TSHash(check)});
    if(!synced || !matches){if(error)*error=Failure(@"备份未能可靠落盘，未修改输入设备。");return NO;}
    self.record=r;TSLog(@"backup.durable",@{@"originalCurves":curves,@"curveHash":TSHash(curves),@"backupHash":TSHash(data)});return YES;
}
- (BOOL)writeProperty:(id)value key:(NSString *)key stage:(NSString *)stage error:(NSError **)error {
    TSLog(@"property.write.request",@{@"stage":stage,@"api":@"IOHIDServiceClientSetProperty",@"clientType":@"Passive (SPI)",@"registryID":@(self.registryID),@"registryClass":self.registryClass?:@"unknown",@"key":key,@"valueHash":TSHash(value),@"value":value});
    if(!TSFlushLog()){if(error)*error=Failure(@"日志无法落盘，已停止设备写入。");return NO;}
    BOOL accepted=[self setServiceProperty:value key:key];
    TSLog(@"property.write.result",@{@"stage":stage,@"key":key,@"accepted":@(accepted),@"returnType":@"Boolean",@"underlyingIOReturnAvailable":@NO});
    if(!accepted && error)*error=Failure([NSString stringWithFormat:@"HID 服务拒绝 %@；接口未提供底层错误码。",key]);return accepted;
}
- (BOOL)verifyOverride:(NSArray *)target expected:(NSArray *)expected error:(NSError **)error {
    for(int attempt=0;attempt<10;attempt++) {
        NSDictionary *state=[self snapshot:error];if(!state)return NO;
        BOOL matches=[state[@"override"]isEqual:target];NSDictionary *diff=nil;
        BOOL active=TSActiveCurveMatches(expected,[state[@"index"]doubleValue],state[@"active"],&diff);
        TSLog(@"override.readback",@{@"attempt":@(attempt),@"key":OverrideKey,@"source":@"ServiceRecords → IOHIDPointerScrollFilter.Property",@"matches":@(matches),@"wantedHash":TSHash(target),@"actualHash":TSHash(state[@"override"]),@"diff":Diff(target,state[@"override"])});
        TSLog(@"filter.active.verify",@{@"attempt":@(attempt),@"matches":@(active),@"expected":TSExpectedActiveCurve(expected,[state[@"index"]doubleValue])?:@{},@"actual":state[@"active"],@"diff":diff?:@{},@"physicalEffectVerified":@NO});
        if(matches && active)return YES;
        if(attempt<9)usleep(20000);
    }
    if(error)*error=Failure(@"用户覆盖曲线或实际过滤器系数不匹配，不能确认应用。已保留备份并尝试回滚。");return NO;
}
- (BOOL)writeOverride:(NSArray *)target expected:(NSArray *)expected error:(NSError **)error {
    if(![target isKindOfClass:NSArray.class] || (target.count && !TSScaleCurves(target,1,error)))return NO;
    // This exact key is in Apple's filter cache list and createPointerParametricAlgorithm().
    // Setting it rebuilds the curve itself; no index, resolution, multiplier or global setter.
    if(![self writeProperty:target key:OverrideKey stage:@"override / automatic filter rebuild" error:error])return NO;
    return [self verifyOverride:target expected:expected error:error];
}
- (BOOL)restoreLegacy:(NSError **)error {
    NSDictionary *state=[self snapshot:error];if(!state)return NO;
    if([state[@"override"]count]){if(error)*error=Failure(@"旧版备份不包含当前用户覆盖曲线，无法安全推断原始状态。");return NO;}
    NSArray *original=self.record[@"curves"];
    // v0.2 left the plugin cache changed even when the normal getter returned defaults.
    // Force the old key back; never skip this based on the normal getter.
    if(![self writeProperty:original key:CurveKey stage:@"legacy plugin-cache restore" error:error])return NO;
    BOOL cacheOK=NO;
    for(int n=0;n<10;n++) {
        state=[self snapshot:error];if(!state)return NO;cacheOK=[state[@"pluginCache"]isEqual:original];
        TSLog(@"legacy.cache.verify",@{@"attempt":@(n),@"matches":@(cacheOK),@"expectedHash":TSHash(original),@"actualHash":TSHash(state[@"pluginCache"]),@"source":@"ServicePluginDebug.CachedProperties.HIDAccelCurves"});
        if(cacheOK)break;if(n<9)usleep(20000);
    }
    if(!cacheOK){if(error)*error=Failure(@"旧版插件缓存尚未恢复，保留原始记录。");return NO;}
    if(![self writeProperty:TrackpadType key:TypeKey stage:@"legacy filter refresh" error:error])return NO;
    return [self verifyOverride:state[@"override"] expected:original error:error];
}
- (BOOL)applyBody:(double)scale strength:(double)strength error:(NSError **)error {
    TSLog(@"apply.request",@{@"targetScale":@(scale),@"curveStrength":@(strength)});if(![self inspect:error])return NO;
    if(self.staleRecovery || (self.record && [self.record[@"version"]intValue]<3)) {
        if(error)*error=Failure(@"请先点击恢复原始值：旧版记录需清理插件内部缓存，不能直接套用新倍率。");return NO;
    }
    NSDictionary *state=[self snapshot:error];if(!state)return NO;
    NSArray *original=self.record[@"curves"]?:[self effectiveCurves:state];
    NSDictionary *baseDiff=nil;
    if(!self.record && (!TSActiveCurveMatches(original,[state[@"index"]doubleValue],state[@"active"],&baseDiff) || (state[@"pluginCache"]!=NSNull.null && ![state[@"pluginCache"]isEqual:state[@"driverCurves"]]))) {
        TSLog(@"baseline.unverified",@{@"diff":baseDiff?:@{},@"pluginCacheHash":TSHash(state[@"pluginCache"])});
        if(error)*error=Failure(@"当前实际过滤器或插件缓存存在未记录覆盖，不能建立可靠基准。");return NO;
    }
    NSDictionary *anchorInfo=nil;
    NSArray *scaled=TSAnchoredCurves(original,scale,strength,[state[@"index"]doubleValue],&anchorInfo,error);if(!scaled)return NO;
    TSLog(@"curves.scale",@{@"targetScale":@(scale),@"curveStrength":@(strength),@"inputHash":TSHash(original),@"outputHash":TSHash(scaled),@"inputCurves":original,@"outputCurves":scaled,@"anchor":anchorInfo});
    if(!self.record && ![self saveOriginal:original state:state error:error])return NO;
    if(![self writeOverride:scaled expected:scaled error:error]) {
        TSLog(@"apply.failed.stage",@{@"error":error&&*error?(*error).localizedDescription:@"unknown",@"backupRetained":@YES});
        TSBeginOperation(@"rollback");NSError *rollbackError=nil;
        BOOL rolled=[self writeOverride:self.record[@"override"] expected:original error:&rollbackError];
        TSLog(@"apply.rollback",@{@"filterParametersRestored":@(rolled),@"error":rollbackError.localizedDescription?:NSNull.null,@"backupRetained":@YES});TSEndOperation(rolled,rollbackError);
        self.active=NO;return NO;
    }
    self.active=YES;TSLog(@"apply.filter.completed",@{@"targetScale":@(scale),@"curveStrength":@(strength),@"activeFilterVerified":@YES,@"physicalEffectVerified":@NO});return YES;
}
- (BOOL)apply:(double)scale error:(NSError **)error {return [self apply:scale strength:1 error:error];}
- (BOOL)apply:(double)scale strength:(double)strength error:(NSError **)error {
    TSBeginOperation(@"apply");NSError *local=nil;BOOL ok=[self applyBody:scale strength:strength error:&local];if(error)*error=local;TSEndOperation(ok,local);TSFlushLog();return ok;
}
- (NSDictionary *)previewBaseline:(NSError **)error {
    NSDictionary *state=[self snapshot:error];if(!state)return nil;
    NSArray *curves=self.record[@"curves"]?:[self effectiveCurves:state];
    return @{@"curves":curves,@"index":state[@"index"]};
}
- (BOOL)archiveRecovery:(NSString *)reason error:(NSError **)error {
    if(self.archivedRecoveryURL) {
        NSData *data=[NSData dataWithContentsOfURL:self.archivedRecoveryURL options:0 error:error];if(!data)return NO;
        TSLog(@"recovery.archive",@{@"reason":reason,@"archived":@YES,@"alreadyArchived":@YES,@"archiveName":self.archivedRecoveryURL.lastPathComponent,@"backupHash":TSHash(data),@"deleted":@NO});
        self.record=nil;self.archivedRecoveryURL=nil;self.staleRecovery=NO;return YES;
    }
    NSURL *archive=[self.recordURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:[NSString stringWithFormat:@"recovery-%@-%@.plist",reason,NSUUID.UUID.UUIDString]];
    NSData *original=[NSData dataWithContentsOfURL:self.recordURL options:0 error:error];if(!original)return NO;
    BOOL ok=[[NSFileManager defaultManager]moveItemAtURL:self.recordURL toURL:archive error:error];
    TSLog(@"recovery.archive",@{@"reason":reason,@"archived":@(ok),@"backupHash":TSHash(original),@"archiveName":archive.lastPathComponent,@"deleted":@NO});
    if(ok){self.record=nil;self.staleRecovery=NO;}return ok;
}
- (BOOL)restoreBody:(NSError **)error {
    TSLog(@"restore.request",@{});if(![self inspect:error])return NO;
    if(!self.record){self.active=NO;TSLog(@"restore.no.record",@{});return YES;}
    if(self.staleRecovery){BOOL ok=[self archiveRecovery:@"previous-boot" error:error];if(ok)self.active=NO;return ok;}
    BOOL restored=[self.record[@"version"]intValue]<3?[self restoreLegacy:error]:[self writeOverride:self.record[@"override"] expected:self.record[@"curves"] error:error];
    if(!restored){TSLog(@"recovery.retained",@{@"reason":@"restore failed"});return NO;}
    if(![self archiveRecovery:@"restored" error:error])return NO;
    self.active=NO;TSLog(@"restore.filter.completed",@{@"activeFilterVerified":@YES,@"physicalEffectVerified":@NO});return YES;
}
- (BOOL)restore:(NSError **)error {
    TSBeginOperation(@"restore");NSError *local=nil;BOOL ok=[self restoreBody:&local];if(error)*error=local;TSEndOperation(ok,local);TSFlushLog();return ok;
}
@end
