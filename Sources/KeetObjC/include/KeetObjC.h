#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the Objective-C exception it raised as an NSError, or nil.
/// AVAudioEngine reports a graph it can't build (a microphone whose format changed while
/// the graph was being connected) by raising an exception, which Swift cannot catch and
/// which would otherwise end the process.
NSError *_Nullable KTCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
