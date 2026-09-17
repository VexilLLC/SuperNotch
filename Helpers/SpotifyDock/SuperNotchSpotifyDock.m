#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static BOOL SuperNotchDockHidden = YES;
static IMP OriginalSetActivationPolicy = NULL;

static BOOL SuperNotchSetActivationPolicy(id self, SEL command, NSApplicationActivationPolicy policy) {
    if (SuperNotchDockHidden && policy == NSApplicationActivationPolicyRegular) {
        return NO;
    }
    return ((BOOL (*)(id, SEL, NSApplicationActivationPolicy))OriginalSetActivationPolicy)(self, command, policy);
}

static void SuperNotchApplyDockState(BOOL hidden) {
    SuperNotchDockHidden = hidden;
    if (OriginalSetActivationPolicy != NULL) {
        ((BOOL (*)(id, SEL, NSApplicationActivationPolicy))OriginalSetActivationPolicy)(
            NSApp,
            @selector(setActivationPolicy:),
            hidden ? NSApplicationActivationPolicyAccessory : NSApplicationActivationPolicyRegular
        );
    }
}

static void SuperNotchFocusSpotify(void) {
    SuperNotchApplyDockState(YES);
    [NSApp unhide:nil];
    for (NSWindow *window in NSApp.windows) {
        if (window.canBecomeKeyWindow) {
            [window makeKeyAndOrderFront:nil];
        } else {
            [window orderFront:nil];
        }
    }
    [[NSRunningApplication currentApplication] activateWithOptions:NSApplicationActivateAllWindows];
}

static BOOL SuperNotchHasVisibleSpotifyWindow(void) {
    for (NSWindow *window in NSApp.windows) {
        // isVisible stays YES for windows on another Space or fully covered by
        // other windows; occlusion state reflects what the user can see.
        if (window.isVisible && !window.isMiniaturized && window.canBecomeKeyWindow &&
            (window.occlusionState & NSWindowOcclusionStateVisible)) return YES;
    }
    return NO;
}

static void SuperNotchToggleSpotify(void) {
    if (NSRunningApplication.currentApplication.isHidden || !NSApp.isActive || !SuperNotchHasVisibleSpotifyWindow()) {
        SuperNotchFocusSpotify();
        return;
    }
    for (NSWindow *window in NSApp.windows) {
        if (window.canBecomeKeyWindow) [window orderOut:nil];
    }
    [NSApp hide:nil];
    SuperNotchApplyDockState(YES);
}

__attribute__((constructor))
static void SuperNotchSpotifyDockLoad(void) {
    // Install the guard before Spotify gets a chance to promote itself to a
    // regular application. AppKit setup and notification delivery stay on the
    // main queue below.
    Method method = class_getInstanceMethod(NSApplication.class, @selector(setActivationPolicy:));
    if (method != NULL) {
        OriginalSetActivationPolicy = method_getImplementation(method);
        method_setImplementation(method, (IMP)SuperNotchSetActivationPolicy);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        NSDistributedNotificationCenter *center = NSDistributedNotificationCenter.defaultCenter;
        [center addObserverForName:@"com.spotify.client.supernotch.hide"
                           object:nil
                            queue:NSOperationQueue.mainQueue
                       usingBlock:^(__unused NSNotification *note) { SuperNotchApplyDockState(YES); }];
        [center addObserverForName:@"com.spotify.client.supernotch.show"
                           object:nil
                            queue:NSOperationQueue.mainQueue
                       usingBlock:^(__unused NSNotification *note) { SuperNotchApplyDockState(NO); }];
        [center addObserverForName:@"com.spotify.client.supernotch.focus"
                           object:nil
                            queue:NSOperationQueue.mainQueue
                       usingBlock:^(__unused NSNotification *note) { SuperNotchFocusSpotify(); }];
        [center addObserverForName:@"com.spotify.client.supernotch.toggle"
                           object:nil
                            queue:NSOperationQueue.mainQueue
                       usingBlock:^(__unused NSNotification *note) { SuperNotchToggleSpotify(); }];

        SuperNotchApplyDockState(YES);
        [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidBecomeActiveNotification
                                                         object:NSApp
                                                          queue:NSOperationQueue.mainQueue
                                                     usingBlock:^(__unused NSNotification *note) {
            if (SuperNotchDockHidden && NSRunningApplication.currentApplication.activationPolicy != NSApplicationActivationPolicyAccessory) {
                SuperNotchApplyDockState(YES);
            }
        }];
        [NSTimer scheduledTimerWithTimeInterval:0.75
                                        repeats:YES
                                          block:^(__unused NSTimer *timer) {
            if (SuperNotchDockHidden && NSRunningApplication.currentApplication.activationPolicy != NSApplicationActivationPolicyAccessory) {
                SuperNotchApplyDockState(YES);
            }
        }];
    });
}
