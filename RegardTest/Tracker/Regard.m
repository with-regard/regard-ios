//
//  Regard.m
//

#import "Regard.h"

// Approximate maximum number of events to send in a batch
const int c_MaxEventsPerBatch = 50;

// Time interval before events are always flushed
const NSTimeInterval c_MaxFlushTimeInterval = 1 /* Day */ * 24 /* Hours */ * 60 /* Minutes */ * 60 /* Seconds */;

// Maximum number of cache files before forcing a flush
const int c_MaxCacheFiles = 30;

// Data structure written as the header for a set of events to the cache file
struct CacheHeader {
    int _length;
};

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

// Chooses a new backing file name
- (NSString*) pickBackingFilename;

// Loads a set of events from a cache file into an array, to prepare to send them
- (void) readEventsInFile: (NSString*) filename toArray: (NSMutableArray*) eventArray;

// The directory that cached event data is stored in
- (NSString*) cacheDirectory;

// The list of cached event files waiting to be sent to the server (just the filenames, these are located in the cacheDirectory)
- (NSArray*) cacheFiles;

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

- (NSString*) pickBackingFilename {
    int index = 0;
    
    NSString* libraryDirectory = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) objectAtIndex: 0];
    
    [[NSFileManager defaultManager] createDirectoryAtPath: [libraryDirectory stringByAppendingPathComponent: @"Caches/Regard"]
                              withIntermediateDirectories: YES
                                               attributes: nil
                                                    error: nil];
    
    for (;;) {
        // Generate the filename for this index
        NSString* filename = [libraryDirectory stringByAppendingPathComponent: [NSString stringWithFormat: @"Caches/Regard/Regard-Events-%i.regard", index]];
        filename = [filename stringByExpandingTildeInPath];
        
        if (![[NSFileManager defaultManager] fileExistsAtPath: filename]) {
            // This file does not exist: use it as our backing file
            return filename;
        }
        
        // Try the next file
        ++index;
    }
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
        
        // Choose a location to store unsent events
        _backingFilename        = [self pickBackingFilename];
        _numFrozenEvents        = 0;
        
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
        
        // Flush the events from the last session
        [self flushCachedEventsIfOldEnough];
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
        ++_numFrozenEvents;
        
        // Force a freeze and cycle the cache file if we hit enough events
        if (_numFrozenEvents >= c_MaxEventsPerBatch) {
            // Ensure all the events are written out
            [self freezeCache];
            
            // Pick a new backing file
            _backingFilename = [self pickBackingFilename];
            _numFrozenEvents = 0;
        }
        
        // After a short delay, cache the event to disk for sending later on
        if (!_willFreeze) {
            _willFreeze = true;
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * 1000 * 1000 /* == 100ms */), _recordQueue, ^{
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
    
    // Serialize to a log file
    NSData* eventData = [NSJSONSerialization dataWithJSONObject: freezeEvents
                                                        options: 0
                                                          error: nil];
    
    // Append to the backing file
    NSFileHandle* updateBackingFile = [NSFileHandle fileHandleForUpdatingAtPath: _backingFilename];
    if (!updateBackingFile) {
        [[NSFileManager defaultManager] createFileAtPath: _backingFilename contents: [NSData data] attributes: nil];
        updateBackingFile = [NSFileHandle fileHandleForWritingAtPath: _backingFilename];
    }
    
    // Events get dropped on the floor if we can't get a file to write them to
    if (!updateBackingFile) {
        NSLog(@"Regard: could not create event log file");
        return;
    }
    
    // Append the events to the file
    [updateBackingFile seekToEndOfFile];
    
    // The header helps us detect partial writes, which may occur occasionally
    struct CacheHeader header;
    header._length = (int) [eventData length];
    
    NSData* headerData = [[NSData alloc] initWithBytes: &header length: sizeof(struct CacheHeader)];

    [updateBackingFile writeData: headerData];
    [updateBackingFile writeData: eventData];
    
    // Ensure that the file is synchronized and closed before continuing
    [updateBackingFile synchronizeFile];
    [updateBackingFile closeFile];
}

- (void) readEventsInFile: (NSString*) filename toArray: (NSMutableArray*) eventArray {
    NSFileHandle* file = [NSFileHandle fileHandleForReadingAtPath: filename];
    
    // Ignore files that cannot be read from
    if (!file) {
        NSLog(@"Regard: could not read from file %@", [filename lastPathComponent]);
        return;
    }
    
    for (;;) {
        // Read the next block from the file
        NSData* headerData = [file readDataOfLength: sizeof(struct CacheHeader)];
        if (!headerData || [headerData length] < sizeof(struct CacheHeader)) {
            // If we hit the end of the file, we won't get any/enough data here
            break;
        }
        
        const struct CacheHeader* header = (const struct CacheHeader*)[headerData bytes];
        
        // Read the JSON block from the file
        NSData* jsonData = [file readDataOfLength: header->_length];
        if (!jsonData || [jsonData length] < header->_length) {
            // A partial write will mean we get less data than expected here
            NSLog(@"Regard: file '%@' contains partial data (some events will be missed)", [filename lastPathComponent]);
            break;
        }
        
        NSError* jsonError = nil;
        NSArray* decodedBlock = (NSArray*) [NSJSONSerialization JSONObjectWithData: jsonData options: 0 error: &jsonError];
        
        if (jsonError || ![decodedBlock isKindOfClass: [NSArray class]]) {
            // The block didn't contain valid JSON: likely the rest of the file is corrupt
            NSLog(@"Regard: file '%@' contains corrupted data (some events will be missed)", [filename lastPathComponent]);
            break;
        }
        
        // Add the events to the array that we'll send to the server
        [eventArray addObjectsFromArray: decodedBlock];
    }
}

- (NSString*) cacheDirectory {
    NSString* libraryDirectory = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) objectAtIndex: 0];
    NSString* cacheDirectory = [libraryDirectory stringByAppendingPathComponent: @"Caches/Regard"];

    return cacheDirectory;
}

- (NSArray*) cacheFiles {
    NSString* cacheDirectory = [self cacheDirectory];
    
    // Get a list of all of the cache files and filter to get the .regard files
    NSArray* cacheFiles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath: cacheDirectory
                                                                              error: nil];
    cacheFiles = [cacheFiles filteredArrayUsingPredicate: [NSPredicate predicateWithFormat: @"self ENDSWITH '.regard'"]];

    return cacheFiles;
}

- (void) flushCachedEvents {
    dispatch_async(_recordQueue, ^{
        // Stop using whatever backing file we were before
        _backingFilename = [self pickBackingFilename];

        // Look in the caches directory
        NSString* cacheDirectory = [self cacheDirectory];
        NSArray* cacheFiles = [self cacheFiles];
        
        // List of events waiting to be sent
        NSMutableArray* waitingEvents = [NSMutableArray array];
        
        // Go through the files
        for (NSString* eventFile in cacheFiles) {
            // Load the events from this file
            [self readEventsInFile: [cacheDirectory stringByAppendingPathComponent: eventFile] toArray: waitingEvents];
            
            // Send the cache if it gets big enough
            if ([waitingEvents count] >= c_MaxEventsPerBatch) {
                // Send as a batch to the server
                [self sendBatch: waitingEvents];
                
                // Synchronise the record queue with the send queue so we don't fill memory in the case where there
                // are vast quanities of events to get through
                // TODO: once the logs get big enough, just delete the oldest ones
                dispatch_sync(_sendQueue, ^{ });
                
                // Don't send these events again
                waitingEvents = [NSMutableArray array];
            }
            
            // Done with this file
            NSError* deleteError;
            [[NSFileManager defaultManager] removeItemAtPath: [cacheDirectory stringByAppendingPathComponent: eventFile] error: &deleteError];
            
            if (deleteError) {
                NSLog(@"Regard: error deleting file %@", eventFile);
            }
        }
        
        // Send the remaining cache
        if ([waitingEvents count] > 0) {
            [self sendBatch: waitingEvents];
            waitingEvents = [NSMutableArray array];
        }
    });
}

- (void) flushCachedEventsIfOldEnough {
    dispatch_async(_recordQueue, ^{
        // TODO: If we're connected using wifi, then the events are always old enough (or maybe only require an hour?)
        
        // If we're connected via mobile, then events must be at least a day old before we try sending them
        NSDate* oldestEvents = [NSDate date];
        
        NSString*       cacheDirectory  = [self cacheDirectory];
        NSArray*        cacheFiles      = [self cacheFiles];
        NSFileManager*  fileManager     = [NSFileManager defaultManager];
        
        for (NSString* eventFile in cacheFiles) {
            // Fetch the attributes of this file
            NSString* fullPath = [cacheDirectory stringByAppendingPathComponent: eventFile];
            NSDictionary* attributes = [fileManager attributesOfItemAtPath: fullPath
                                                                     error: nil];
            if (!attributes) {
                NSLog(@"Regard: could not get attributes of %@", eventFile);
                continue;
            }
            
            // We're interested in the creation date of this file
            NSDate* creationDate = [attributes objectForKey: NSFileCreationDate];
            if (!creationDate) {
                NSLog(@"Regard: could not get creation date of %@", eventFile);
                continue;
            }
            
            // Find the date of the oldest file
            if ([creationDate compare: oldestEvents] == NSOrderedAscending) {
                oldestEvents = creationDate;
            }
        }
        
        if ([oldestEvents timeIntervalSinceNow] < -c_MaxFlushTimeInterval) {
            // Flush the events if they are old enough
            [self flushCachedEvents];
        } else if ([cacheFiles count] > c_MaxCacheFiles) {
            // Flush the events if there are too many files
            [self flushCachedEvents];
        }
    });
}

- (void) appWillResignActive: (id) obj {
    // Ensure that the cache is frozen before the app quits
    dispatch_sync(_recordQueue, ^{ [self freezeCache]; });
}

@end
