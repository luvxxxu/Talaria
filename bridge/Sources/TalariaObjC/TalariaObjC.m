#import "TalariaObjC.h"

NSString *_Nullable TLRStringFromAttributedBody(NSData *data) {
    @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        // Messages still writes this format, so the deprecated reader is the exact one.
        id object = [NSUnarchiver unarchiveObjectWithData:data];
#pragma clang diagnostic pop
        if ([object isKindOfClass:[NSAttributedString class]]) {
            return [(NSAttributedString *)object string];
        }
        if ([object isKindOfClass:[NSString class]]) {
            return (NSString *)object;
        }
    } @catch (NSException *exception) {
        // Fall through: the caller has a byte-level fallback.
    }
    return nil;
}
