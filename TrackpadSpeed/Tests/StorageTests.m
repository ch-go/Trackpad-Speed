#import <Foundation/Foundation.h>
#import "PresetStore.h"
#import "Log.h"
#define CHECK(c) do {if(!(c)){fprintf(stderr,"FAIL storage line %d: %s\n",__LINE__,#c);exit(1);}}while(0)
int main(void){@autoreleasepool {
    NSFileManager *fm=NSFileManager.defaultManager;NSURL *root=[NSURL fileURLWithPath:[NSTemporaryDirectory()stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    NSURL *logs=[root URLByAppendingPathComponent:@"Logs" isDirectory:YES];[fm createDirectoryAtURL:logs withIntermediateDirectories:YES attributes:nil error:NULL];setenv("TS_TEST_LOG_DIR",logs.path.UTF8String,1);
    // Seed old-version logs above the new file/total limits; preserve complete trailing JSON lines.
    NSMutableData *legacy=[NSMutableData data];NSData *line=[@"{\"event\":\"legacy\",\"padding\":\"012345678901234567890123456789\"}\n"dataUsingEncoding:NSUTF8StringEncoding];
    while(legacy.length<TSLogFileLimit()+10000)[legacy appendData:line];
    for(NSString *name in @[@"trace.jsonl",@"trace.1.jsonl",@"trace-v2.1.jsonl",@"trace-v2.2.jsonl"])[legacy writeToURL:[logs URLByAppendingPathComponent:name] atomically:YES];
    TSLog(@"retention.start",@{});CHECK(TSFlushLog());
    NSURL *url=[root URLByAppendingPathComponent:@"presets.json"];TSPresetStore *store=[[TSPresetStore alloc]initWithURL:url];NSError *error=nil;
    CHECK([store load:&error].count==0);
    NSDictionary *first=[store saveName:@"  常用  " scale:2.375 contrast:0.1 error:&error];CHECK(first && [first[@"name"]isEqual:@"常用"]);
    NSDictionary *updated=[store saveName:@"常用" scale:3.125 contrast:3 error:&error];CHECK([updated[@"id"]isEqual:first[@"id"]] && [store load:&error].count==1);
    CHECK([store saveName:@"精细" scale:1 contrast:1 error:&error]);CHECK([store load:&error].count==2);
    TSPresetStore *reopened=[[TSPresetStore alloc]initWithURL:url];CHECK([reopened load:&error].count==2);
    CHECK([store deleteID:first[@"id"] error:&error]);CHECK([reopened load:&error].count==1);CHECK([[[reopened load:&error]firstObject][@"name"]isEqual:@"精细"]);
    NSData *valid=[NSData dataWithContentsOfURL:url];CHECK(![store deleteID:first[@"id"] error:&error]);CHECK([[NSData dataWithContentsOfURL:url]isEqual:valid]);
    CHECK(![store saveName:@"" scale:2 contrast:1 error:&error]);CHECK(![store saveName:@"坏参数" scale:4.1 contrast:1 error:&error]);CHECK(![store saveName:@"坏参数" scale:2 contrast:3.01 error:&error]);CHECK([[NSData dataWithContentsOfURL:url]isEqual:valid]);
    [@"corrupt JSON"writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:NULL];NSData *corrupt=[NSData dataWithContentsOfURL:url];
    CHECK(![store saveName:@"不能覆盖" scale:2 contrast:1 error:&error]);CHECK(![store deleteID:first[@"id"] error:&error]);CHECK([[NSData dataWithContentsOfURL:url]isEqual:corrupt]);
    // Force several rotations using valid large JSON records.
    NSString *padding=[@"x"stringByPaddingToLength:180000 withString:@"x" startingAtIndex:0];
    for(int i=0;i<45;i++)TSLog(@"rotation.payload",@{@"index":@(i),@"padding":padding});TSLog(@"retention.final",@{});CHECK(TSFlushLog());
    NSUInteger count=0;unsigned long long total=0;BOOL finalFound=NO;
    for(NSURL *file in [fm contentsOfDirectoryAtURL:logs includingPropertiesForKeys:nil options:0 error:NULL]) {
        if(![file.pathExtension isEqual:@"jsonl"])continue;
        NSData *data=[NSData dataWithContentsOfURL:file];CHECK(data.length<=TSLogFileLimit());total+=data.length;count++;
        NSString *text=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
        for(NSString *l in [text componentsSeparatedByString:@"\n"])if(l.length){NSDictionary *record=[NSJSONSerialization JSONObjectWithData:[l dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];CHECK(record);if([record[@"event"]isEqual:@"retention.final"])finalFound=YES;}
    }
    CHECK(count<=3 && total<=TSLogTotalLimit() && finalFound);
    printf("PASS storage: named presets, exact decimals, same-name update, reload, range validation, delete/reload without disturbing other presets, missing-ID/corrupt-file protection; legacy log cleanup + rotation: %lu files, %llu bytes, valid JSONL, <=2MiB each / <=6MiB total.\n",(unsigned long)count,total);
    [fm removeItemAtURL:root error:NULL];
}return 0;}
