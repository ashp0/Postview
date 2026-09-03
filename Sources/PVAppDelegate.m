#import "PVAppDelegate.h"
#import "PVWindowController.h"
#import "PVStateStore.h"
#import "PVWelcomeWindowController.h"

@implementation PVAppDelegate

#pragma mark - Menu construction

static NSMenuItem *PVAdd(NSMenu *menu, NSString *title, SEL action,
                         NSString *key, NSUInteger mask)
{
    NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:title
                                                   action:action
                                            keyEquivalent:key ? key : @""] autorelease];
    if (key && mask) [item setKeyEquivalentModifierMask:mask];
    [menu addItem:item];
    return item;
}

static NSString *PVFnKey(unichar c)
{
    return [NSString stringWithCharacters:&c length:1];
}

- (void)buildMenuBar
{
    NSMenu *mainMenu = [[[NSMenu alloc] initWithTitle:@""] autorelease];

    // Application menu
    NSMenuItem *appItem = [[[NSMenuItem alloc] initWithTitle:@"" action:NULL keyEquivalent:@""] autorelease];
    NSMenu *appMenu = [[[NSMenu alloc] initWithTitle:@"Postview"] autorelease];
    PVAdd(appMenu, @"About Postview", @selector(orderFrontStandardAboutPanel:), nil, 0);
    [appMenu addItem:[NSMenuItem separatorItem]];
    PVAdd(appMenu, @"Hide Postview", @selector(hide:), @"h", NSCommandKeyMask);
    PVAdd(appMenu, @"Hide Others", @selector(hideOtherApplications:), @"h",
          NSCommandKeyMask | NSAlternateKeyMask);
    PVAdd(appMenu, @"Show All", @selector(unhideAllApplications:), nil, 0);
    [appMenu addItem:[NSMenuItem separatorItem]];
    PVAdd(appMenu, @"Quit Postview", @selector(terminate:), @"q", NSCommandKeyMask);
    [appItem setSubmenu:appMenu];
    [mainMenu addItem:appItem];

    // File
    NSMenuItem *fileItem = [[[NSMenuItem alloc] initWithTitle:@"File" action:NULL keyEquivalent:@""] autorelease];
    NSMenu *fileMenu = [[[NSMenu alloc] initWithTitle:@"File"] autorelease];
    PVAdd(fileMenu, @"Open…", @selector(openDocument:), @"o", NSCommandKeyMask);

    NSMenuItem *recentItem = PVAdd(fileMenu, @"Open Recent", NULL, nil, 0);
    NSMenu *recentMenu = [[[NSMenu alloc] initWithTitle:@"Open Recent"] autorelease];
    // AppKit populates any menu that contains a -clearRecentDocuments: item.
    PVAdd(recentMenu, @"Clear Menu", @selector(clearRecentDocuments:), nil, 0);
    [recentItem setSubmenu:recentMenu];

    [fileMenu addItem:[NSMenuItem separatorItem]];
    PVAdd(fileMenu, @"Close", @selector(performClose:), @"w", NSCommandKeyMask);
    [fileItem setSubmenu:fileMenu];
    [mainMenu addItem:fileItem];

    // Edit — present so the Go to Page field supports the usual shortcuts.
    NSMenuItem *editItem = [[[NSMenuItem alloc] initWithTitle:@"Edit" action:NULL keyEquivalent:@""] autorelease];
    NSMenu *editMenu = [[[NSMenu alloc] initWithTitle:@"Edit"] autorelease];
    PVAdd(editMenu, @"Cut", @selector(cut:), @"x", NSCommandKeyMask);
    PVAdd(editMenu, @"Copy", @selector(copy:), @"c", NSCommandKeyMask);
    PVAdd(editMenu, @"Paste", @selector(paste:), @"v", NSCommandKeyMask);
    PVAdd(editMenu, @"Select All", @selector(selectAll:), @"a", NSCommandKeyMask);
    [editItem setSubmenu:editMenu];
    [mainMenu addItem:editItem];

    // View
    NSMenuItem *viewItem = [[[NSMenuItem alloc] initWithTitle:@"View" action:NULL keyEquivalent:@""] autorelease];
    NSMenu *viewMenu = [[[NSMenu alloc] initWithTitle:@"View"] autorelease];
    PVAdd(viewMenu, @"Show Thumbnails", @selector(toggleSidebar:), @"2",
          NSCommandKeyMask | NSAlternateKeyMask);
    // Two pages side by side. Cmd-3 continues the row Cmd-0/1/2 already
    // occupy, and is the one key in it that nothing had claimed; the item is
    // checked rather than retitled, and -validateMenuItem: sets that.
    PVAdd(viewMenu, @"Two Pages", @selector(toggleTwoPageView:), @"3",
          NSCommandKeyMask);
    // The same spread with the first page held back, the way a book opens on a
    // title page. Cmd-4 because it is the next key in the row and it sits
    // beside the layout it is a variant of; the two items are mutually
    // exclusive and at most one of them is ever ticked.
    PVAdd(viewMenu, @"Two Pages with Cover Page", @selector(toggleCoverPageView:),
          @"4", NSCommandKeyMask);
    [viewMenu addItem:[NSMenuItem separatorItem]];
    PVAdd(viewMenu, @"Zoom In", @selector(zoomIn:), @"+", NSCommandKeyMask);
    PVAdd(viewMenu, @"Zoom Out", @selector(zoomOut:), @"-", NSCommandKeyMask);
    PVAdd(viewMenu, @"Actual Size", @selector(zoomActualSize:), @"0", NSCommandKeyMask);
    PVAdd(viewMenu, @"Fit Width", @selector(zoomFitWidth:), @"1", NSCommandKeyMask);
    PVAdd(viewMenu, @"Fit Page", @selector(zoomFitPage:), @"2", NSCommandKeyMask);
    [viewMenu addItem:[NSMenuItem separatorItem]];
    PVAdd(viewMenu, @"Enter Full Screen", @selector(toggleFullScreen:), @"f",
          NSCommandKeyMask | NSControlKeyMask);
    [viewItem setSubmenu:viewMenu];
    [mainMenu addItem:viewItem];

    // Go
    NSMenuItem *goItem = [[[NSMenuItem alloc] initWithTitle:@"Go" action:NULL keyEquivalent:@""] autorelease];
    NSMenu *goMenu = [[[NSMenu alloc] initWithTitle:@"Go"] autorelease];
    PVAdd(goMenu, @"Next Page", @selector(goToNextPage:),
          PVFnKey(NSDownArrowFunctionKey), NSCommandKeyMask);
    PVAdd(goMenu, @"Previous Page", @selector(goToPreviousPage:),
          PVFnKey(NSUpArrowFunctionKey), NSCommandKeyMask);
    [goMenu addItem:[NSMenuItem separatorItem]];
    PVAdd(goMenu, @"First Page", @selector(goToFirstPage:),
          PVFnKey(NSHomeFunctionKey), NSCommandKeyMask);
    PVAdd(goMenu, @"Last Page", @selector(goToLastPage:),
          PVFnKey(NSEndFunctionKey), NSCommandKeyMask);
    [goMenu addItem:[NSMenuItem separatorItem]];
    PVAdd(goMenu, @"Go to Page…", @selector(goToPageDialog:), @"g",
          NSCommandKeyMask | NSAlternateKeyMask);
    [goItem setSubmenu:goMenu];
    [mainMenu addItem:goItem];

    // Window
    NSMenuItem *windowItem = [[[NSMenuItem alloc] initWithTitle:@"Window" action:NULL keyEquivalent:@""] autorelease];
    NSMenu *windowMenu = [[[NSMenu alloc] initWithTitle:@"Window"] autorelease];
    PVAdd(windowMenu, @"Minimize", @selector(performMiniaturize:), @"m", NSCommandKeyMask);
    PVAdd(windowMenu, @"Zoom", @selector(performZoom:), nil, 0);
    [windowMenu addItem:[NSMenuItem separatorItem]];
    PVAdd(windowMenu, @"Bring All to Front", @selector(arrangeInFront:), nil, 0);
    [windowItem setSubmenu:windowMenu];
    [mainMenu addItem:windowItem];

    [NSApp setMainMenu:mainMenu];
    [NSApp setWindowsMenu:windowMenu];
}

#pragma mark - Where the application is running from

// The one crash this program has produced was not a bug in it.
//
// A 10.9 report showed SIGBUS -- EXC_BAD_ACCESS with KERN_MEMORY_ERROR -- at
// an address 70,639 bytes into an 80 KB r-x COW mapping, which is exactly this
// binary's __TEXT segment and, at that offset, exactly its ObjC class-name
// strings. The faulting instruction was _mapStrIsEqual, the runtime comparing
// a registered class name during objc_lookUpClass. Nothing of Postview's was
// on the stack above main. The executable was at /Volumes/..., and the crash
// reporter could not read it either -- it printed the image as
// "0 - 0xffffffffffffffff +Postview (???)" where every other image had a real
// range and UUID.
//
// That is one event, not two: OS X maps an application's code from its
// executable file and pages it in on demand for the whole life of the process.
// The file stopped being readable -- ejected, unplugged, or overwritten by a
// newer build of itself -- and the next page that had to be faulted in could
// not be. Which instruction hit it first is arbitrary, and here it happened to
// be one reached through a SIMBL plug-in that swizzles -[NSWindow update];
// AppKit's own -updateWindows would have arrived at the same page moments
// later. The class-name table is simply the busiest read-only data in any
// Cocoa process.
//
// There is no defensive code for this. By the time the fault is taken there is
// no instruction left to execute, and mlock() on __TEXT is refused to an
// unprivileged process (verified: EPERM, with RLIMIT_MEMLOCK unlimited). What
// can be removed is the precondition, which is running from a disk that can
// leave. So: say so at launch, and offer the one-click way out.
- (void)offerToCopyBundleFrom:(NSURL *)bundleURL kind:(PVVolumeKind)kind
{
    NSString *sourcePath = [[bundleURL path] stringByStandardizingPath];
    NSString *name       = [sourcePath lastPathComponent];
    NSString *destPath   = [@"/Applications" stringByAppendingPathComponent:name];
    NSFileManager *fm    = [NSFileManager defaultManager];

    // /Applications is itself on the removable volume, so there is nowhere
    // better to offer. Warn and leave it there.
    BOOL canOffer  = ![destPath isEqualToString:sourcePath];
    BOOL replacing = canOffer && [fm fileExistsAtPath:destPath];

    NSString *where = (kind == PVVolumeNetwork)
        ? @"a network volume"
        : @"a disk that can be disconnected";

    NSMutableString *why = [NSMutableString stringWithFormat:
        @"Postview is running from %@.\n\n"
        @"OS X reads an application's code from its file for as long as the "
        @"application is open, not just while it starts. If this disk is "
        @"ejected, disconnected, or this copy is replaced by a new build while "
        @"Postview is running, the system stops Postview immediately and no "
        @"program can prevent that.", where];

    if (canOffer) {
        [why appendString:@"\n\nRunning it from your Applications folder removes the possibility."];
        if (replacing) {
            [why appendString:@" This copy will replace the one already in "
                              @"Applications, which is then moved to the Trash."];
        }
    }

    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert setMessageText:@"Postview is not running from a permanent disk"];
    [alert setInformativeText:why];
    if (canOffer) {
        [alert addButtonWithTitle:(replacing ? @"Replace Copy in Applications"
                                             : @"Copy to Applications")];
    }
    [alert addButtonWithTitle:@"Run From Here"];

    [NSApp activateIgnoringOtherApps:YES];
    // Run it first and test the answer afterwards. Folding the two together as
    // `!canOffer || [alert runModal] != ...` short-circuits the modal away in
    // exactly the case where the warning is the whole point, and the one thing
    // this must never do is stay quiet.
    NSInteger choice = [alert runModal];
    if (!canOffer || choice != NSAlertFirstButtonReturn) return;

    // Stage first, replace second. This used to move the installed copy to the
    // Trash and only then start copying -- from a removable or network volume,
    // across a link that by construction might be about to disappear. Between
    // those two steps there is no working Postview in /Applications, and if the
    // copy failed halfway there was a half-written bundle sitting where the
    // working one had been. Both of those are worse than not installing.
    //
    // So: copy the whole thing to a hidden name on the DESTINATION filesystem,
    // where a failure costs nothing and can be cleaned up, and only once it is
    // complete swap it in. -replaceItemAtURL:... does the swap through
    // exchangedata/renamex where it can, so there is no instant at which the
    // destination is missing or partial. All of this is present on Mavericks.
    NSError *error = nil;
    NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];
    NSURL *destURL = [NSURL fileURLWithPath:destPath];
    NSURL *applicationsURL = [destURL URLByDeletingLastPathComponent];
    NSString *token = [[NSProcessInfo processInfo] globallyUniqueString];

    NSURL *stageURL = [applicationsURL URLByAppendingPathComponent:
        [NSString stringWithFormat:@".%@.install-%@", name, token]];

    if (![fm copyItemAtURL:sourceURL toURL:stageURL error:&error]) {
        [fm removeItemAtURL:stageURL error:NULL];
        [self reportCopyFailure:error
                           verb:@"stage a complete copy in your Applications folder"];
        return;
    }

    if (replacing) {
        NSString *backupName =
            [NSString stringWithFormat:@".%@.backup-%@", name, token];
        NSURL *resultURL = nil;

        // WithoutDeletingBackupItem: the previous copy is kept until the swap
        // has definitely succeeded, and only then moved to the Trash. The Trash
        // rather than a delete, for the same reason as before -- replacing an
        // installed application is a decision the user may want to undo.
        if (![fm replaceItemAtURL:destURL
                    withItemAtURL:stageURL
                   backupItemName:backupName
                          options:NSFileManagerItemReplacementWithoutDeletingBackupItem
                 resultingItemURL:&resultURL
                            error:&error]) {
            [fm removeItemAtURL:stageURL error:NULL];
            [self reportCopyFailure:error
                               verb:@"replace the copy in your Applications folder"];
            return;
        }

        NSURL *backupURL =
            [applicationsURL URLByAppendingPathComponent:backupName];
        if ([fm fileExistsAtPath:[backupURL path]])
            [fm trashItemAtURL:backupURL resultingItemURL:NULL error:NULL];
    } else if (![fm moveItemAtURL:stageURL toURL:destURL error:&error]) {
        [fm removeItemAtURL:stageURL error:NULL];
        [self reportCopyFailure:error
                           verb:@"copy itself to your Applications folder"];
        return;
    }

    // A new instance explicitly: the copy shares this bundle identifier, and
    // without it LaunchServices would activate the process that is already
    // running -- the one on the removable disk -- and nothing would change.
    if (![[NSWorkspace sharedWorkspace] launchApplicationAtURL:[NSURL fileURLWithPath:destPath]
                                                       options:NSWorkspaceLaunchNewInstance
                                                 configuration:[NSDictionary dictionary]
                                                         error:&error]) {
        [self reportCopyFailure:error
                           verb:@"open the copy in your Applications folder"];
        return;
    }
    [NSApp terminate:nil];
}

// There is no longer a `trashed` case to report. The install stages a complete
// copy first and only trashes the previous one after the swap has succeeded, so
// every failure this can be called for leaves the installed copy exactly where
// the user left it -- which is the whole point of the staging.
- (void)reportCopyFailure:(NSError *)error verb:(NSString *)verb
{
    NSMutableString *detail = [NSMutableString stringWithString:
        error ? [error localizedDescription] : @"The reason was not reported."];
    [detail appendString:@"\n\nThe copy in your Applications folder, if there was one, "
                         @"has not been touched."];
    [detail appendString:@"\n\nPostview will keep running from where it is. Moving it "
                         @"yourself in the Finder does the same job."];

    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert setMessageText:[NSString stringWithFormat:@"Postview could not %@.", verb]];
    [alert setInformativeText:detail];
    [alert addButtonWithTitle:@"Continue"];
    [alert runModal];
}

- (void)checkRunningLocation
{
    NSURL *bundleURL = [[NSBundle mainBundle] bundleURL];
    PVVolumeKind kind = PVVolumeKindForURL(bundleURL);
    if (kind == PVVolumeFixed) return;
    [self offerToCopyBundleFrom:bundleURL kind:kind];
}

#pragma mark - Lifecycle

- (void)applicationWillFinishLaunching:(NSNotification *)note
{
    [self buildMenuBar];
    // Instantiate early so Open Recent works.
    (void)[NSDocumentController sharedDocumentController];

    // One process-wide memory pressure source. It is a dispatch source, not a
    // timer: it costs nothing until the kernel actually reports pressure, which
    // matters on a machine with only a few GB of RAM.
    //
    // The level the kernel reported has to travel with the notification. The
    // handler used to post a bare notification and drop
    // dispatch_source_get_data() on the floor, which loses the one piece of
    // information in the event: whether this is WARN or CRITICAL. Events also
    // coalesce, so a process that was idle when the machine went straight to
    // critical receives exactly one undifferentiated callback -- and the
    // controller, counting notifications rather than reading levels, treated
    // that as a first warning and immediately re-rendered every visible page at
    // full resolution. That is the worst possible response to a critical event.
    //
    // NORMAL is subscribed to as well, because it is the only authority that
    // says the pressure is over.
    _memoryPressureSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
        DISPATCH_MEMORYPRESSURE_NORMAL |
        DISPATCH_MEMORYPRESSURE_WARN |
        DISPATCH_MEMORYPRESSURE_CRITICAL,
        dispatch_get_main_queue());
    if (_memoryPressureSource) {
        // Captured in a local: the block must read the source it belongs to,
        // and reading the ivar would be a second dereference of self at a
        // moment when self may be going away.
        dispatch_source_t source = _memoryPressureSource;
        dispatch_source_set_event_handler(source, ^{
            unsigned long flags = dispatch_source_get_data(source);
            NSDictionary *info = [NSDictionary dictionaryWithObject:
                [NSNumber numberWithUnsignedLong:flags]
                                                             forKey:@"PVMemoryPressureFlags"];
            [[NSNotificationCenter defaultCenter]
                postNotificationName:PVMemoryPressureNotification
                              object:nil
                            userInfo:info];
        });
        dispatch_resume(_memoryPressureSource);
    }

    // The reading position, committed before the machine sleeps.
    //
    // This is not a guess about when the user might like a save. It is the one
    // warning this process reliably gets before a class of death it cannot
    // prevent and did not cause: on the target machine, waking is when the
    // window server reconfigures the displays, and the GPU driver can respond
    // to that by calling abort() on its own client from inside AppKit's redraw
    // -- no Postview frame on the stack, no signal worth catching, and no
    // -applicationWillTerminate:. See ENGINEERING.md section 10.
    //
    // Without this the state file is written on document close, on deactivate
    // and at quit, and none of those happen to a reader who is looking at the
    // page when the lid closes: the app is frontmost, so it never resigns
    // active, and it never terminates -- it is killed. That reader loses the
    // position for the whole session.
    //
    // The cost is one notification and one write per sleep, which is a handful
    // of times a day. Nothing polls and no timer is armed, so the file's own
    // rule -- writes are rare and no timer ever runs -- is kept exactly.
    //
    // NSWorkspace posts on its OWN notification centre, not the default one.
    // Registering on the default centre is silent: no error, no warning, and a
    // notification that simply never arrives.
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self
           selector:@selector(systemWillSleep:)
               name:NSWorkspaceWillSleepNotification
             object:nil];
}

// Sleep is a save point, not a shutdown: the process is expected to still be
// here afterwards, so only the reading position is written and the census is
// left to termination. Deliberately does the same work whether or not the wake
// that follows goes wrong, because nothing here can tell in advance.
- (void)systemWillSleep:(NSNotification *)note
{
    (void)note;
    [self saveOpenDocumentState];
}

// Not -applicationWillFinishLaunching:. The alert does run there -- sampling
// the process showed the modal loop entered and the panel placed on screen --
// but it runs nested inside -[NSApplication finishLaunching], before the app
// has an activation policy or a published accessibility tree: it was not
// frontmost, and nothing outside the process could see it had a window. A
// warning that arrives behind whatever the user was looking at, attached to an
// app that appears hung, is not a warning. Called from here the same modal
// loop runs under -[NSApplication run] instead, with launching finished.
- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    [self checkRunningLocation];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return NO; }

// Launching from the icon opens the empty state and nothing else. Previously
// this put an Open panel on screen unprompted; combined with AppKit's window
// restoration, a launch could also silently reopen whatever document happened
// to be open when the app was last quit. Both are gone: -setRestorable:NO on
// every window suppresses the restoration path, and this opens no document.
- (BOOL)applicationOpenUntitledFile:(NSApplication *)app
{
    [PVWelcomeWindowController showWelcome];
    return YES;
}

// Clicking the Dock icon with no document open shows the same empty state
// rather than an Open panel.
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible
{
    if (!visible) [PVWelcomeWindowController showWelcome];
    return YES;
}



// Every open document's reading position, on disk.
//
// Split out from -saveAllOpenDocuments so that the sleep hook below can reach
// it without also reaching the rasterisation census underneath. The census is
// instrumentation about a whole run: emitting it every time the machine is
// closed for the night would interleave several runs' counters in one log and
// rewrite PVStatsPath with a partial total, which is a measurement changed by
// the act of taking it. Saving the reading position has no such objection --
// it is idempotent and it is the whole point.
- (void)saveOpenDocumentState
{
    NSArray *docs = [[NSDocumentController sharedDocumentController] documents];
    NSUInteger i, j;
    for (i = 0; i < [docs count]; i++) {
        NSArray *controllers = [[docs objectAtIndex:i] windowControllers];
        for (j = 0; j < [controllers count]; j++) {
            id wc = [controllers objectAtIndex:j];
            if ([wc isKindOfClass:[PVWindowController class]]) [wc saveState];
        }
    }
    [[PVStateStore sharedStore] flush];
}

- (void)saveAllOpenDocuments
{
    [self saveOpenDocumentState];

    // Last thing before the process goes: the rasterisation census, when it
    // was asked for. stderr rather than a file so a benchmark can capture it
    // per run with no path to agree on and nothing left behind on disk.
    NSString *stats = PVStatsReport();
    if (stats) {
        fputs([stats UTF8String], stderr);
        // Launched through LaunchServices, stderr goes to the system log where
        // a benchmark cannot conveniently get at it. -PVStatsPath names a file
        // instead. Failure to write is ignored on purpose: this is
        // instrumentation, and it has no business affecting termination.
        NSString *path = [[NSUserDefaults standardUserDefaults] stringForKey:@"PVStatsPath"];
        if ([path length] > 0)
            [stats writeToFile:path atomically:YES
                      encoding:NSUTF8StringEncoding error:NULL];
    }
}

// Every notification centre this object is registered with, in one place.
//
// Exactly the argument -releaseMemoryPressureSource makes below, and it earns
// its own method for a sharper reason: there are two centres, and the default
// one's -removeObserver: does not touch the workspace's. The terminate path
// and -dealloc both used to say only the default one, so adding a workspace
// observer to a class unregistered like that leaves the workspace holding an
// unsafe-unretained pointer to a freed delegate, and the next sleep sends a
// message to it. Naming both here means neither call site can forget one.
- (void)stopObservingNotifications
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
}

// Both the terminate path and -dealloc have to do this, and it has to happen
// exactly once. Stating it once means the two copies cannot drift apart into a
// double dispatch_release, which is not a leak but a crash.
- (void)releaseMemoryPressureSource
{
    if (!_memoryPressureSource) return;
    dispatch_source_cancel(_memoryPressureSource);
    dispatch_release(_memoryPressureSource);
    _memoryPressureSource = NULL;
}

- (void)dealloc
{
    [self stopObservingNotifications];
    [self releaseMemoryPressureSource];
    [super dealloc];
}

// Flushing on deactivate rather than on a timer means the reading position is
// safe on disk without any periodic disk writes while you read.
- (void)applicationDidResignActive:(NSNotification *)note { [self saveAllOpenDocuments]; }
- (void)applicationWillTerminate:(NSNotification *)note
{
    [self saveAllOpenDocuments];
    [self stopObservingNotifications];
    [self releaseMemoryPressureSource];
}

@end
