#import "Log.h"
#import <sys/stat.h>
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <CommonCrypto/CommonDigest.h>
static dispatch_queue_t Queue(void) { static dispatch_queue_t q;static dispatch_once_t once;dispatch_once(&once,^{q=dispatch_queue_create("local.trackpadspeed.log",DISPATCH_QUEUE_SERIAL);});return q; }
NSString *TSLogDirectory(void) {
#if TS_TESTING
    if(getenv("TS_TEST_LOG_DIR"))return [NSString stringWithUTF8String:getenv("TS_TEST_LOG_DIR")];
#endif
    NSURL *base=[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [[base URLByAppendingPathComponent:@"TrackpadSpeed/Logs" isDirectory:YES] path];
}
NSUInteger TSLogFileLimit(void){return 2*1024*1024;}
NSUInteger TSLogTotalLimit(void){return 3*TSLogFileLimit();}
static NSArray *LogNames(void){return @[@"trace.jsonl",@"trace.1.jsonl",@"trace.2.jsonl",@"trace-v2.jsonl",@"trace-v2.1.jsonl",@"trace-v2.2.jsonl"];}
// Called only under the cross-process lock; recognizes this app's own log names only.
static BOOL BoundExistingLogs(NSString *dir) {
    NSFileManager *fm=NSFileManager.defaultManager;
    for(NSString *name in LogNames()) {
        NSString *path=[dir stringByAppendingPathComponent:name];NSDictionary *attrs=[fm attributesOfItemAtPath:path error:NULL];unsigned long long size=[attrs fileSize];
        if(size<=TSLogFileLimit())continue;
        NSFileHandle *h=[NSFileHandle fileHandleForReadingAtPath:path];if(!h)return NO;
        [h seekToFileOffset:size-TSLogFileLimit()];NSData *tail=[h readDataToEndOfFile];[h closeFile];
        const uint8_t *bytes=tail.bytes;NSUInteger start=0;while(start<tail.length && bytes[start]!='\n')start++;if(start<tail.length)start++;
        NSData *complete=[tail subdataWithRange:NSMakeRange(start,tail.length-start)];
        if(![complete writeToFile:path options:NSDataWritingAtomic error:NULL])return NO;
        [fm setAttributes:@{NSFileModificationDate:attrs[NSFileModificationDate],NSFilePosixPermissions:@0600} ofItemAtPath:path error:NULL];
        TSLog(@"log.retention.trim",@{@"operationID":@"log.retention",@"file":name,@"oldBytes":@(size),@"newBytes":@(complete.length)});
    }return YES;
}
static BOOL PruneLogs(NSString *dir) {
    NSFileManager *fm=NSFileManager.defaultManager;NSMutableArray *files=[NSMutableArray array];unsigned long long total=0;
    for(NSString *name in LogNames()) {
        NSDictionary *a=[fm attributesOfItemAtPath:[dir stringByAppendingPathComponent:name] error:NULL];if(!a)continue;
        total+=[a fileSize];[files addObject:@{@"name":name,@"size":@([a fileSize]),@"date":a[NSFileModificationDate]?:NSDate.distantPast}];
    }
    [files sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"date"]compare:b[@"date"]];}];
    while(files.count>3 || total>TSLogTotalLimit()) {
        NSUInteger n=[files indexOfObjectPassingTest:^BOOL(NSDictionary *f,NSUInteger idx,BOOL *stop){return ![f[@"name"]isEqual:@"trace-v2.jsonl"]; }];if(n==NSNotFound)return NO;
        NSDictionary *old=files[n];if(![fm removeItemAtPath:[dir stringByAppendingPathComponent:old[@"name"]] error:NULL])return NO;
        total-=[old[@"size"]unsignedLongLongValue];[files removeObjectAtIndex:n];
        TSLog(@"log.retention.remove",@{@"operationID":@"log.retention",@"file":old[@"name"],@"bytes":old[@"size"]});
    }return YES;
}
static BOOL logFailed;
static BOOL boundedExisting;
// A separate generation avoids collision with v0.1's non-append file handle.
// All v0.2 processes cooperate via a stable lock file, including during rotation.
static BOOL WriteOrSync(NSData *line) {
    NSString *dir=TSLogDirectory();NSFileManager *fm=NSFileManager.defaultManager;
    if(![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL])return NO;
    NSString *lockPath=[dir stringByAppendingPathComponent:@".trace-v2.lock"];
    int lockfd=open(lockPath.fileSystemRepresentation,O_CREAT|O_RDWR,0600);if(lockfd<0)return NO;
    if(flock(lockfd,LOCK_EX)!=0){close(lockfd);return NO;}
    if(!boundedExisting){BOOL ready=BoundExistingLogs(dir);if(!ready){flock(lockfd,LOCK_UN);close(lockfd);return NO;}boundedExisting=YES;}
    NSString *path=[dir stringByAppendingPathComponent:@"trace-v2.jsonl"];
    int fd=open(path.fileSystemRepresentation,O_CREAT|O_WRONLY|O_APPEND,0600);BOOL ok=fd>=0 && PruneLogs(dir);
    if(ok && line) {
        struct stat st;ok=fstat(fd,&st)==0;
        if(ok && st.st_size+(off_t)line.length>(off_t)TSLogFileLimit()) {
            ok=fsync(fd)==0;close(fd);fd=-1;
            if(ok) {
                NSString *one=[dir stringByAppendingPathComponent:@"trace-v2.1.jsonl"],*two=[dir stringByAppendingPathComponent:@"trace-v2.2.jsonl"];
                if([fm fileExistsAtPath:two])ok=[fm removeItemAtPath:two error:NULL];
                if(ok && [fm fileExistsAtPath:one])ok=[fm moveItemAtPath:one toPath:two error:NULL];
                if(ok)ok=[fm moveItemAtPath:path toPath:one error:NULL];
                if(ok){fd=open(path.fileSystemRepresentation,O_CREAT|O_WRONLY|O_APPEND,0600);ok=fd>=0 && BoundExistingLogs(dir) && PruneLogs(dir);}
            }
        }
        if(ok) {
            const uint8_t *bytes=line.bytes;NSUInteger offset=0;
            while(offset<line.length) {
                ssize_t n=write(fd,bytes+offset,line.length-offset);
                if(n<0 && errno==EINTR)continue;
                if(n<=0){ok=NO;break;}offset+=(NSUInteger)n;
            }
        }
    }else if(ok)ok=fsync(fd)==0;
    if(fd>=0)close(fd);flock(lockfd,LOCK_UN);close(lockfd);return ok;
}
void TSLog(NSString *event, NSDictionary *fields) {
    NSMutableDictionary *record=[fields mutableCopy]?:[NSMutableDictionary dictionary];
    if(!record[@"operationID"])record[@"operationID"]=NSThread.currentThread.threadDictionary[@"TSOperationID"]?:@"session";
    record[@"event"]=event;record[@"unixTime"]=@([NSDate.date timeIntervalSince1970]);record[@"uptime"]=@(NSProcessInfo.processInfo.systemUptime);record[@"pid"]=@(NSProcessInfo.processInfo.processIdentifier);
    NSData *data=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:NULL];
    if(!data){NSLog(@"TrackpadSpeed: log serialization failed for %@",event);dispatch_async(Queue(),^{logFailed=YES;});return;}
    NSMutableData *line=[data mutableCopy];[line appendBytes:"\n" length:1];
    if(line.length>TSLogFileLimit()){NSLog(@"TrackpadSpeed: one log record exceeds size cap");dispatch_async(Queue(),^{logFailed=YES;});return;}
    dispatch_async(Queue(),^{ @autoreleasepool {
        if(!WriteOrSync(line)){logFailed=YES;NSLog(@"TrackpadSpeed: log write failed (errno=%d)",errno);}
    } });
}
BOOL TSFlushLog(void) {
    __block BOOL ok=NO;dispatch_sync(Queue(),^{ok=WriteOrSync(nil) && !logFailed;});return ok;
}

void TSBeginOperation(NSString *name) {
    NSMutableDictionary *td=NSThread.currentThread.threadDictionary;
    NSMutableArray *stack=td[@"TSOperationStack"];
    if(!stack){stack=[NSMutableArray array];td[@"TSOperationStack"]=stack;}
    NSString *parent=td[@"TSOperationID"]?:@"session";
    [stack addObject:parent];td[@"TSOperationID"]=NSUUID.UUID.UUIDString;
    TSLog(@"operation.begin",@{@"name":name,@"parentOperationID":parent});
}
void TSEndOperation(BOOL success,NSError *error) {
    TSLog(@"operation.end",@{@"completed":@(success),@"error":error.localizedDescription?:NSNull.null,@"errorDomain":error.domain?:NSNull.null,@"errorCode":error?@(error.code):NSNull.null});
    NSMutableDictionary *td=NSThread.currentThread.threadDictionary;NSMutableArray *stack=td[@"TSOperationStack"];
    td[@"TSOperationID"]=stack.lastObject?:@"session";if(stack.count)[stack removeLastObject];
}
NSString *TSHash(id value) {
    if(!value)return @"missing";
    NSData *data=[value isKindOfClass:NSData.class]?value:[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys|NSJSONWritingFragmentsAllowed error:NULL];
    if(!data)return @"unserializable";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *hex=[NSMutableString string];for(int i=0;i<CC_SHA256_DIGEST_LENGTH;i++)[hex appendFormat:@"%02x",digest[i]];return hex;
}
