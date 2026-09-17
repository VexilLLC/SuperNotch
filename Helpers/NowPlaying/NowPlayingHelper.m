// SuperNotch Now Playing helper.
//
// Since macOS 15.4 the private MediaRemote framework only answers processes with an Apple
// identity. SuperNotch therefore loads this library into the system perl interpreter
// (see now-playing.pl), which streams the system-wide Now Playing state as JSON lines on
// stdout and accepts playback commands as text lines on stdin. It exits when stdin closes.

#import <Foundation/Foundation.h>

extern void MRMediaRemoteRegisterForNowPlayingNotifications(dispatch_queue_t queue);
extern void MRMediaRemoteGetNowPlayingInfo(dispatch_queue_t queue, void (^handler)(NSDictionary *info));
extern void MRMediaRemoteGetNowPlayingApplicationIsPlaying(dispatch_queue_t queue, void (^handler)(BOOL playing));
extern Boolean MRMediaRemoteSendCommand(int command, NSDictionary *options);
extern void MRMediaRemoteSetElapsedTime(double seconds);
extern void MRMediaRemoteGetNowPlayingClient(dispatch_queue_t queue, void (^handler)(id client)) __attribute__((weak_import));
extern NSString *MRNowPlayingClientGetBundleIdentifier(id client) __attribute__((weak_import));
extern NSString *MRNowPlayingClientGetParentAppBundleIdentifier(id client) __attribute__((weak_import));

static const NSUInteger SNMaximumArtworkBytes = 4 * 1024 * 1024;
static dispatch_queue_t SNQueue;
static NSString *SNLastArtworkKey;
static NSString *SNLastLine;

static void SNWrite(NSDictionary *payload) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!data) return;
    NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    // Skip identical snapshots so heartbeats stay quiet.
    if ([line isEqualToString:SNLastLine] && payload[@"artwork"] == nil) return;
    SNLastLine = line;
    fprintf(stdout, "%s\n", line.UTF8String);
    fflush(stdout);
}

static id SNNumber(id value) {
    if ([value isKindOfClass:NSNumber.class]) return value;
    if ([value isKindOfClass:NSString.class]) return @([(NSString *)value doubleValue]);
    return nil;
}

static void SNPublish(NSDictionary *info, BOOL playing, NSString *bundle, NSString *parentBundle) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"playing"] = @(playing);
    NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
    if ([title isKindOfClass:NSString.class] && title.length > 0) {
        out[@"title"] = title;
        id artist = info[@"kMRMediaRemoteNowPlayingInfoArtist"];
        id album = info[@"kMRMediaRemoteNowPlayingInfoAlbum"];
        if ([artist isKindOfClass:NSString.class]) out[@"artist"] = artist;
        if ([album isKindOfClass:NSString.class]) out[@"album"] = album;
        id duration = SNNumber(info[@"kMRMediaRemoteNowPlayingInfoDuration"]);
        id elapsed = SNNumber(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]);
        id rate = SNNumber(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]);
        if (duration) out[@"duration"] = duration;
        if (elapsed) out[@"elapsed"] = elapsed;
        if (rate) out[@"rate"] = rate;
        NSDate *timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
        if ([timestamp isKindOfClass:NSDate.class]) out[@"timestamp"] = @(timestamp.timeIntervalSince1970);

        NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        if ([artwork isKindOfClass:NSData.class] && artwork.length > 0 && artwork.length <= SNMaximumArtworkBytes) {
            id identifier = info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"];
            NSString *key = [identifier isKindOfClass:NSString.class]
                ? identifier
                : [NSString stringWithFormat:@"%@|%lu|%lu", title, (unsigned long)artwork.length, (unsigned long)artwork.hash];
            out[@"artworkKey"] = key;
            if (![key isEqualToString:SNLastArtworkKey]) {
                SNLastArtworkKey = key;
                out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
            }
        }
    }
    if (bundle.length) out[@"bundle"] = bundle;
    if (parentBundle.length) out[@"parentBundle"] = parentBundle;
    SNWrite(out);
}

static void SNRefresh(void) {
    MRMediaRemoteGetNowPlayingInfo(SNQueue, ^(NSDictionary *info) {
        MRMediaRemoteGetNowPlayingApplicationIsPlaying(SNQueue, ^(BOOL playing) {
            if (MRMediaRemoteGetNowPlayingClient != NULL) {
                MRMediaRemoteGetNowPlayingClient(SNQueue, ^(id client) {
                    NSString *bundle = (client && MRNowPlayingClientGetBundleIdentifier) ? MRNowPlayingClientGetBundleIdentifier(client) : nil;
                    NSString *parent = (client && MRNowPlayingClientGetParentAppBundleIdentifier) ? MRNowPlayingClientGetParentAppBundleIdentifier(client) : nil;
                    SNPublish(info ?: @{}, playing, bundle, parent);
                });
            } else {
                SNPublish(info ?: @{}, playing, nil, nil);
            }
        });
    });
}

static void SNHandleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *verb = parts.firstObject;
    // MediaRemote command identifiers.
    NSDictionary<NSString *, NSNumber *> *commands = @{ @"play": @0, @"pause": @1, @"toggle": @2, @"next": @4, @"previous": @5 };
    if (commands[verb]) {
        MRMediaRemoteSendCommand(commands[verb].intValue, nil);
    } else if ([verb isEqualToString:@"seek"] && parts.count > 1) {
        MRMediaRemoteSetElapsedTime(MAX(0, parts[1].doubleValue));
    } else if ([verb isEqualToString:@"refresh"]) {
        SNLastLine = nil;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), SNQueue, ^{ SNRefresh(); });
}

void supernotch_now_playing_stream(void) {
    @autoreleasepool {
        SNQueue = dispatch_queue_create("app.supernotch.nowplaying", DISPATCH_QUEUE_SERIAL);
        MRMediaRemoteRegisterForNowPlayingNotifications(SNQueue);
        for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                                 @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                                 @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
                dispatch_async(SNQueue, ^{ SNRefresh(); });
            }];
        }
        dispatch_source_t heartbeat = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, SNQueue);
        dispatch_source_set_timer(heartbeat, dispatch_time(DISPATCH_TIME_NOW, 0), 3 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
        dispatch_source_set_event_handler(heartbeat, ^{ SNRefresh(); });
        dispatch_resume(heartbeat);

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            char *buffer = NULL;
            size_t capacity = 0;
            while (getline(&buffer, &capacity, stdin) > 0) {
                NSString *line = [[NSString stringWithUTF8String:buffer] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (line.length) dispatch_async(SNQueue, ^{ SNHandleCommand(line); });
            }
            exit(0); // The app went away.
        });
        CFRunLoopRun();
    }
}
