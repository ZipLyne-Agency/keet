#import "KeetObjC.h"

NSError *_Nullable KTCatchException(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSString *reason = exception.reason ?: exception.name;
        return [NSError errorWithDomain:exception.name
                                   code:-1
                               userInfo:@{NSLocalizedDescriptionKey: reason}];
    }
}
