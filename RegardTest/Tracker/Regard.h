//
//  Regard.h
//

#import <Foundation/Foundation.h>

//
// Core implementation of the Regard event tracker
//
@interface Regard : NSObject {
    // Location of the event tracker (generally https://api.withregard.io)
    NSURL* _eventTrackerBaseUrl;
    
    // Event times are reported in 8601 format
    NSDateFormatter* _iso8601formatter;
    
    // Name of the product and organization that's being tracked
    NSString* _product, *_organization;
    
    // User ID (nil if it hasn't been generated/retrieved)
    NSString* _uid;
    
    // Session ID (nil if it hasn't been generated)
    NSString* _sessionId;
    
    // YES if the user is opted in
    BOOL _optIn;
    
    // Queue used for sending events
    dispatch_queue_t _sendQueue;
    
    // Queue used for recording events
    dispatch_queue_t _recordQueue;
    
    // Events that have been cached but not yet stored permanently
    NSMutableArray* _recentEvents;
    
    // Set the YES if _recentEvents will be 'frozen' to disk
    BOOL _willFreeze;
}

//
// Application-global event tracking
//

// The default tracker using the settings in the application info file
+ (Regard*) withRegard;

// Tracks an event using the default tracker
+ (void) track: (NSString*) event withProperties: (NSDictionary*) properties;

+ (void) optIn;
+ (void) optOut;
+ (void) optInByDefault;

//
// Recording events
//

//
// Either: [[regard track: @"eventName"] someProperty: @"property-value"]
// or [regard track: @"eventName" properties: @{ @"someProperty": @"property-value" }]
//

- (void) track: (NSString*) event withProperties: (NSDictionary*) properties;

//
// Setup and configuration
//

// Create a new event tracker for a particular product
- (id) initWithProduct: (NSString*) product organization: (NSString*) organization;

// Clears the current user ID so that acquireUserId will generate a new one
- (void) forgetUserId;

// Opts the current user in to data collection (data will be sent)
- (void) optIn;

// Opts the current user out of data collection (data will be ignored)
- (void) optOut;

// The first time this is called, the user is opted in. Future calls are ignored.
// Regards default behaviour is that users are opted-out until they opt in.
// Calling this during startup produces the reverse behaviour.
- (void) optInByDefault;

//
// Direct drive
//

- (void) cacheEvent: (NSDictionary*) eventData;
- (void) sendEvent: (NSDictionary*) eventData;
- (void) sendBatch: (NSArray*) events;
- (void) flushCachedEvents;
- (void) flushCachedEventsIfOldEnough;

@end
