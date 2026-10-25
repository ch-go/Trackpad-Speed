#import "PresetStore.h"
#import "Curve.h"
#import "Log.h"
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
static NSError *PresetError(NSString *text){return [NSError errorWithDomain:@"TrackpadSpeed.Presets" code:1 userInfo:@{NSLocalizedDescriptionKey:text}];}
@interface TSPresetStore ()
@property NSURL *url;
@end
@implementation TSPresetStore
- (instancetype)init {
    NSURL *base=[[NSFileManager defaultManager]URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [self initWithURL:[base URLByAppendingPathComponent:@"TrackpadSpeed/presets.json"]];
}
- (instancetype)initWithURL:(NSURL *)url {if((self=[super init]))_url=url;return self;}
+ (BOOL)validPreset:(NSDictionary *)p {
    if(![p isKindOfClass:NSDictionary.class])return NO;
    id name=p[@"name"],identifier=p[@"id"],scale=p[@"scale"],contrast=p[@"contrast"];
    return [name isKindOfClass:NSString.class] && [name length]>0 && [name length]<=40 && [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound && [identifier isKindOfClass:NSString.class] && [[NSUUID alloc]initWithUUIDString:identifier]!=nil && [scale isKindOfClass:NSNumber.class] && [contrast isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)scale)!=CFBooleanGetTypeID() && CFGetTypeID((__bridge CFTypeRef)contrast)!=CFBooleanGetTypeID() && isfinite([scale doubleValue]) && [scale doubleValue]>=1 && [scale doubleValue]<=4 && isfinite([contrast doubleValue]) && [contrast doubleValue]>=TSMinimumContrast() && [contrast doubleValue]<=TSMaximumContrast();
}
- (NSArray<NSDictionary *> *)load:(NSError **)error {
    if(![[NSFileManager defaultManager]fileExistsAtPath:self.url.path])return @[];
    NSData *data=[NSData dataWithContentsOfURL:self.url options:0 error:error];if(!data)return nil;
    id root=[NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if(![root isKindOfClass:NSDictionary.class] || ![root[@"version"]isEqual:@1] || ![root[@"algorithm"]isEqual:@"anchored-contrast-v1"] || ![root[@"presets"]isKindOfClass:NSArray.class]) {if(error)*error=PresetError(@"设置组文件格式无效，已保留文件，不会覆盖。");return nil;}
    NSMutableSet *ids=[NSMutableSet set],*names=[NSMutableSet set];
    for(id p in root[@"presets"]) {
        if(![TSPresetStore validPreset:p] || [ids containsObject:p[@"id"]] || [names containsObject:p[@"name"]]){if(error)*error=PresetError(@"设置组包含无效或重复记录，未覆盖文件。");return nil;}
        [ids addObject:p[@"id"]];[names addObject:p[@"name"]];
    }
    TSLog(@"presets.read",@{@"count":@([root[@"presets"]count]),@"hash":TSHash(data)});return root[@"presets"];
}
- (NSDictionary *)saveBody:(NSString *)name scale:(double)scale contrast:(double)contrast error:(NSError **)error {
    NSString *clean=[name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSDictionary *item=@{@"id":NSUUID.UUID.UUIDString,@"name":clean?:@"",@"scale":@(scale),@"contrast":@(contrast)};
    if(![TSPresetStore validPreset:item]){if(error)*error=PresetError(@"名称需为1–40字；倍率1–4，加速对比0.10–3.00。");return nil;}
    NSArray *existing=[self load:error];if(!existing)return nil;
    NSMutableArray *items=[existing mutableCopy];NSUInteger match=[items indexOfObjectPassingTest:^BOOL(NSDictionary *p,NSUInteger idx,BOOL *stop){return [p[@"name"]isEqual:clean];}];
    if(match!=NSNotFound){NSMutableDictionary *updated=[item mutableCopy];updated[@"id"]=items[match][@"id"];item=updated;items[match]=item;}else[items addObject:item];
    TSLog(@"presets.save.request",@{@"id":item[@"id"],@"scale":@(scale),@"contrast":@(contrast),@"replacingSameName":@(match!=NSNotFound)});
    return [self writeItems:items stage:@"save" error:error]?item:nil;
}
- (BOOL)writeItems:(NSArray *)items stage:(NSString *)stage error:(NSError **)error {
    NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"algorithm":@"anchored-contrast-v1",@"presets":items} options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:error];if(!data)return NO;
    NSURL *dir=self.url.URLByDeletingLastPathComponent;
    if(![[NSFileManager defaultManager]createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error])return NO;
    if(![data writeToURL:self.url options:NSDataWritingAtomic error:error])return NO;chmod(self.url.fileSystemRepresentation,0600);
    int fd=open(self.url.fileSystemRepresentation,O_RDONLY);BOOL synced=fd>=0 && fsync(fd)==0;if(fd>=0)close(fd);
    int dd=open(dir.fileSystemRepresentation,O_RDONLY);synced=synced && dd>=0 && fsync(dd)==0;if(dd>=0)close(dd);
    NSData *read=[NSData dataWithContentsOfURL:self.url];BOOL same=[read isEqual:data];
    TSLog([NSString stringWithFormat:@"presets.%@.verify",stage],@{@"diskSynchronized":@(synced),@"matches":@(same),@"hash":TSHash(read),@"remainingCount":@(items.count)});
    if(!synced || !same){if(error)*error=PresetError(@"设置组文件未能可靠写入，请重试。");return NO;}return YES;
}
- (BOOL)deleteBody:(NSString *)identifier error:(NSError **)error {
    NSArray *existing=[self load:error];if(!existing)return NO;
    NSUInteger match=[existing indexOfObjectPassingTest:^BOOL(NSDictionary *p,NSUInteger idx,BOOL *stop){return [p[@"id"]isEqual:identifier];}];
    if(match==NSNotFound){if(error)*error=PresetError(@"所选设置组已不存在，请重新选择。");return NO;}
    NSMutableArray *items=[existing mutableCopy];[items removeObjectAtIndex:match];
    TSLog(@"presets.delete.request",@{@"id":identifier,@"remainingCount":@(items.count),@"inputSettingsChanged":@NO});
    return [self writeItems:items stage:@"delete" error:error];
}
- (BOOL)deleteID:(NSString *)identifier error:(NSError **)error {
    TSBeginOperation(@"presets.delete");NSError *local=nil;BOOL ok=[self deleteBody:identifier error:&local];if(error)*error=local;TSEndOperation(ok,local);TSFlushLog();return ok;
}
- (NSDictionary *)saveName:(NSString *)name scale:(double)scale contrast:(double)contrast error:(NSError **)error {
    TSBeginOperation(@"presets.save");NSError *local=nil;NSDictionary *item=[self saveBody:name scale:scale contrast:contrast error:&local];if(error)*error=local;TSEndOperation(item!=nil,local);TSFlushLog();return item;
}
@end
