#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Unarchives a Messages `attributedBody` blob (an NSArchiver typedstream) with
/// Apple's own unarchiver and returns its plain string.
///
/// NSUnarchiver raises Objective-C exceptions on data it can't decode (for
/// example an attribute whose class isn't loaded), which Swift cannot catch.
/// This wrapper catches them and returns nil instead.
NSString *_Nullable TLRStringFromAttributedBody(NSData *data);

NS_ASSUME_NONNULL_END
