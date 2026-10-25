#import <Foundation/Foundation.h>
// Logs are local JSONL; event producer PID is NOT a physical-device identifier.
void TSLog(NSString *event, NSDictionary *fields);
BOOL TSFlushLog(void);
NSString *TSLogDirectory(void);
void TSBeginOperation(NSString *name);
void TSEndOperation(BOOL success, NSError *error);
NSString *TSHash(id value);

NSUInteger TSLogFileLimit(void);
NSUInteger TSLogTotalLimit(void);
