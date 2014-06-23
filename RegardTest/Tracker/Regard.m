//
//  Regard.m
//

#import "Regard.h"

// User defaults key where the Regard user ID is stored
static NSString* _uidUserDefaultsKey = @"io.WithRegard.UserId";

// User defaults key where the opt-in settings is stored
static NSString* _optInDefaultsKey = @"io.WithRegard.OptIn";

//
// Category defining internal functions used by the Regard object
//
@interface Regard(Private)

// The Regard settings provided in the application bundle
+ (NSDictionary*) appSettings;

// Generates or retrieves the current session ID
- (NSString*) sessionId;

// Generates or loads the user ID. This will persist between sessions.
- (void) acquireUserId;

// 'Freezes' the list of cached events to disk so we can send them later.
- (void) freezeCache;

// Callback when the application is no longer active
- (void) appWillResignActive: (id) obj;

@end

@implementation Regard

+ (NSDictionary*) appSettings {
    static NSDictionary* appSettings = nil;
    
    if (!appSettings) {
        NSString* settingsPath = [[NSBundle mainBundle] pathForResource: @"Regard-Settings" ofType: @"plist"];
        
        if (!settingsPath || ![[NSFileManager defaultManager] fileExistsAtPath: settingsPath isDirectory: nil]) {
            NSLog(@"Regard: Regard-Settings.plist is missing from the app bundle");
            return nil;
        }
        
        appSettings = [NSDictionary dictionaryWithContentsOfFile: settingsPath];
    }
    
    return appSettings;
}

+ (Regard*) withRegard {
    static Regard* sharedRegard = nil;
    
    if (!sharedRegard) {
        sharedRegard = [[Regard alloc] init];
    }
    
    return sharedRegard;
}

+ (void) track: (NSString*) event withProperties: (NSDictionary*) properties {
    [[Regard withRegard] track: event withProperties: properties];
}

- (id) init {
    // There should be a Regard-Settings plist in any
    NSDictionary* settings = [Regard appSettings];
    if (!settings) {
        return nil;
    }
    
    // Get the default settings
    NSString* product = [settings objectForKey: @"Product"];
    NSString* organization = [settings objectForKey: @"Organization"];
    
    if (product == nil || organization == nil) {
        NSLog(@"Regard: product/organization not configured - events will not be tracked");
        return nil;
    }
    
    // Initialise using these settings
    return [self initWithProduct: product organization: organization];
}

- (id) initWithProduct: (NSString*) product
          organization: (NSString*) organization {
    self = [super init];
    
    if (self) {
        _product                = product;
        _organization           = organization;
        _recentEvents           = [[NSMutableArray alloc] init];
        _willFreeze             = NO;
        
        // Work out if we're opted in or not
        _optIn                  = [[NSUserDefaults standardUserDefaults] boolForKey: _optInDefaultsKey];
        
        // Work out where the events should be sent
        NSString* trackerUrl = [[Regard appSettings] objectForKey: @"EventTrackerURL"];
        if (!trackerUrl) {
            trackerUrl = @"https://api.withregard.io";
        }
        
        _eventTrackerBaseUrl = [[[[[NSURL URLWithString: trackerUrl]
                                    URLByAppendingPathComponent: @"track/v1" ]
                                    URLByAppendingPathComponent: product]
                                    URLByAppendingPathComponent: organization]
                                    URLByAppendingPathComponent: @"event"];
        
        // Events are processed on a queue
        _sendQueue      = dispatch_queue_create("Send Regard events", NULL);
        _recordQueue    = dispatch_queue_create("Record Regard events", NULL);
        
        
        // We'll format dates as ISO 8601
        _iso8601formatter = [[NSDateFormatter alloc] init];
        NSLocale* enUSPOSIXLocale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        [_iso8601formatter setLocale:enUSPOSIXLocale];
        [_iso8601formatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ssZZZZZ"];
        
        // Freeze the cache every time the application is terminated
        [[NSNotificationCenter defaultCenter] addObserver: self
                                                 selector: @selector(appWillResignActive:)
                                                     name: UIApplicationWillResignActiveNotification
                                                   object: nil];
    }
    
    return self;
}

- (void) dealloc {
    // Ensure that the cache is always frozen before the object is deallocated
    dispatch_sync(_recordQueue, ^{ [self freezeCache]; });
    
    [[NSNotificationCenter defaultCenter] removeObserver: self];
}

- (void) acquireUserId {
    if (_uid) {
        // Already know the user ID
        return;
    }
    
    // Try to retrieve the stored user ID
    NSString* storedUid = [[NSUserDefaults standardUserDefaults] stringForKey: _uidUserDefaultsKey];
    
    // Nothing more to do if it already exists
    if (storedUid) {
        _uid = storedUid;
        return;
    }
    
    // Generate a UUID
    // (Requires iOS 6.0 or later)
    NSString* generatedUid = [[NSUUID UUID] UUIDString];
    
    // Store in the settings
    [[NSUserDefaults standardUserDefaults] setObject: generatedUid forKey: _uidUserDefaultsKey];
    
    // Use this as our user ID
    _uid = generatedUid;
}

- (NSString*) sessionId {
    if (!_sessionId) {
        _sessionId = [[NSUUID UUID] UUIDString];
    }
    
    return _sessionId;
}

- (void) track: (NSString*) event withProperties: (NSDictionary*) properties {
    NSDate* now = [NSDate date];

    dispatch_async(_recordQueue, ^{
        // Nothing to do if there's nothing to track
        if (!event || !properties) {
            return;
        }
        
        // Do nothing if we're not opted in
        if (!_optIn) {
            return;
        }
        
        [self acquireUserId];
        
        // Standard event data
        NSString*   nowIso8601  = [_iso8601formatter stringFromDate: now];
        NSString*   uid         = _uid;
        NSString*   sessionId   = [self sessionId];
        NSString*   eventType   = event;
        
        NSDictionary* rawEventData = @{ @"time":        nowIso8601,
                                        @"session-id":  sessionId,
                                        @"user-id":     uid,
                                        @"event-type":  eventType,
                                        @"data":        properties
                                     };
        
        // Send to the cache
        [self cacheEvent: rawEventData];
    });
}

- (void) cacheEvent: (NSDictionary*) eventData {
    dispatch_async(_recordQueue, ^{
        // Record this event in the recent events log
        [_recentEvents addObject: eventData];
        
        // After a short delay, cache the event to disk for sending later on
        if (!_willFreeze) {
            _willFreeze = true;
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * 1000 * 1000 /* == 10ms */), _recordQueue, ^{
                _willFreeze = false;
                [self freezeCache];
            });
        }
    });
}

- (void) forgetUserId {
    dispatch_async(_recordQueue, ^{
        // Forget the user ID
        _uid = nil;
        
        // Remove from the settings
        [[NSUserDefaults standardUserDefaults] removeObjectForKey: _uidUserDefaultsKey];
    });
}

- (void) optIn {
    dispatch_async(_recordQueue, ^{ _optIn = YES; });
    [[NSUserDefaults standardUserDefaults] setBool: YES forKey: _optInDefaultsKey];
}

- (void) optOut {
    dispatch_async(_recordQueue, ^{ _optIn = NO; });
    [[NSUserDefaults standardUserDefaults] setBool: NO forKey: _optInDefaultsKey];
}

- (void) optInByDefault {
    // Opt-in if the defaults key is not set to anything
    if (![[NSUserDefaults standardUserDefaults] objectForKey: _optInDefaultsKey]) {
        [self optIn];
    }
}

+ (void) optIn {
    [[Regard withRegard] optIn];
}

+ (void) optOut {
    [[Regard withRegard] optOut];
}

+ (void) optInByDefault {
    [[Regard withRegard] optInByDefault];
}

- (void) sendToEndpoint: (NSObject*) eventData {
    if (!eventData) {
        return;
    }
    
    // Return immediately, perform actual sending on the queue
    dispatch_async(_sendQueue, ^{
        // Do nothing if we're not opted in
        if (!_optIn) {
            return;
        }

        // Convert to JSON
        NSError*    encodingError   = nil;
        NSData*     encodedEvent    = [NSJSONSerialization dataWithJSONObject: eventData
                                                                      options: 0
                                                                        error: &encodingError];
        
        // Events that can't be encoded as JSON are dropped with a log message
        if (encodingError) {
            NSLog(@"Regard: could not encode event: %@", encodingError);
            return;
        }
       
        // Generate the request
        NSMutableURLRequest* eventRequest = [[NSMutableURLRequest alloc] initWithURL: _eventTrackerBaseUrl];
        
        eventRequest.HTTPMethod = @"POST";
        eventRequest.HTTPBody   = encodedEvent;
        
        // Send it and wait for the result
        NSError*        requestError    = nil;
        NSURLResponse*  response        = nil;
        [NSURLConnection sendSynchronousRequest: eventRequest
                              returningResponse: &response
                                          error: &requestError];
        
        if (requestError) {
            // If there's a network error, the event is lost
            // TODO: put the event back in the cache instead
            NSLog(@"Regard: could not send event: %@", requestError);
            return;
        }
        
        NSHTTPURLResponse* httpResponse = (NSHTTPURLResponse*) response;
        if (httpResponse.statusCode >= 400) {
            // If there's a server error, the event is lost
            NSLog(@"Regard: could not send event - server return status %i", httpResponse.statusCode);
            return;
        }
    });
}

- (void) sendEvent: (NSDictionary*) eventData {
    [self sendToEndpoint: eventData];
}

- (void) sendBatch: (NSArray*) events {
    [self sendToEndpoint: events];
}

- (void) freezeCache {
    // We assume that we're on the _recordQueue here
    
    // Nothing to do if the cache is empty
    if (_recentEvents.count <= 0) {
        return;
    }
    
    // Replace the freezeEvents array
    // (Caution: This code will need to be different if ARC is disabled)
    NSMutableArray* freezeEvents = _recentEvents;
    _recentEvents = [[NSMutableArray alloc] init];
    
    // TODO: Serialize to a log file
    
    // Temporary alternative: send as a batch of events
    [self sendBatch: freezeEvents];
}

- (void) flushCachedEvents {
    // TODO
}

- (void) flushCachedEventsIfOldEnough {
    // TODO
}

- (void) appWillResignActive: (id) obj {
    // Ensure that the cache is frozen before the app quits
    dispatch_sync(_recordQueue, ^{ [self freezeCache]; });
}

@end
