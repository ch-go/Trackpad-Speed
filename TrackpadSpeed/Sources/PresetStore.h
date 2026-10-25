#import <Foundation/Foundation.h>
@interface TSPresetStore : NSObject
- (instancetype)initWithURL:(NSURL *)url;
- (NSArray<NSDictionary *> *)load:(NSError **)error;
- (NSDictionary *)saveName:(NSString *)name scale:(double)scale contrast:(double)contrast error:(NSError **)error;
- (BOOL)deleteID:(NSString *)identifier error:(NSError **)error;
+ (BOOL)validPreset:(NSDictionary *)preset;
@end
