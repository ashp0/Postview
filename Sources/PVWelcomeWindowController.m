#import "PVWelcomeWindowController.h"
#import "PVDropView.h"

#pragma mark - Empty state

// The welcome window's content view: a drop target for the whole window, with
// the hint text drawn on it. The recent-documents list is a real table view
// sitting on top; everywhere the table is not, this is.
@interface PVWelcomeView : PVDropView {
    BOOL _compact;    // hint sits centred when there is no list to sit above
}
- (void)setCompact:(BOOL)flag;
@end

@implementation PVWelcomeView

- (void)setCompact:(BOOL)flag { _compact = flag; [self setNeedsDisplay:YES]; }

- (void)drawRect:(NSRect)dirty
{
    NSRect b = [self bounds];
    [[NSColor colorWithCalibratedWhite:0.96 alpha:1.0] set];
    NSRectFill(dirty);

    NSMutableParagraphStyle *ps = [[[NSMutableParagraphStyle alloc] init] autorelease];
    [ps setAlignment:NSCenterTextAlignment];

    NSDictionary *title = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSFont systemFontOfSize:15], NSFontAttributeName,
        [NSColor colorWithCalibratedWhite:0.32 alpha:1.0], NSForegroundColorAttributeName,
        ps, NSParagraphStyleAttributeName, nil];
    NSDictionary *hint = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSFont systemFontOfSize:11], NSFontAttributeName,
        [NSColor colorWithCalibratedWhite:0.55 alpha:1.0], NSForegroundColorAttributeName,
        ps, NSParagraphStyleAttributeName, nil];

    if (_compact) {
        // Nothing has been opened yet: the invitation is the whole window.
        NSRect tr = NSMakeRect(0, NSMidY(b) + 4, NSWidth(b), 22);
        NSRect hr = NSMakeRect(0, NSMidY(b) - 22, NSWidth(b), 18);
        [@"Drop a PDF here" drawInRect:tr withAttributes:title];
        [@"or press ⌘O to open one" drawInRect:hr withAttributes:hint];
    } else {
        // With a list below it, the invitation becomes a caption above.
        NSRect tr = NSMakeRect(0, NSMaxY(b) - 34, NSWidth(b), 22);
        NSRect hr = NSMakeRect(0, NSMaxY(b) - 54, NSWidth(b), 18);
        [@"Drop a PDF anywhere in this window" drawInRect:tr withAttributes:title];
        [@"or press ⌘O to open one" drawInRect:hr withAttributes:hint];
    }

    [self drawDropHighlight];
}

@end

#pragma mark - One row of the recent list

// A row: the file's own Finder icon, its name, and the folder it is in. Built
// in code rather than loaded from a nib, like everything else here.
@interface PVRecentRowView : NSTableCellView {
    NSTextField *_where;     // the containing folder, under the name
}
- (void)setFileURL:(NSURL *)url;
@end

@implementation PVRecentRowView

- (id)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (!self) return nil;

    NSImageView *iv = [[[NSImageView alloc] initWithFrame:NSMakeRect(6, 6, 24, 24)] autorelease];
    [iv setImageScaling:NSImageScaleProportionallyUpOrDown];
    [self addSubview:iv];
    [self setImageView:iv];

    NSTextField *name = [[[NSTextField alloc] initWithFrame:NSMakeRect(38, 18, 300, 16)] autorelease];
    [name setEditable:NO]; [name setSelectable:NO]; [name setBordered:NO];
    [name setDrawsBackground:NO];
    [name setFont:[NSFont systemFontOfSize:12]];
    [name setAutoresizingMask:NSViewWidthSizable];
    [[name cell] setLineBreakMode:NSLineBreakByTruncatingMiddle];
    [self addSubview:name];
    [self setTextField:name];

    NSTextField *where = [[[NSTextField alloc] initWithFrame:NSMakeRect(38, 3, 300, 14)] autorelease];
    [where setEditable:NO]; [where setSelectable:NO]; [where setBordered:NO];
    [where setDrawsBackground:NO];
    [where setFont:[NSFont systemFontOfSize:10]];
    [where setTextColor:[NSColor colorWithCalibratedWhite:0.55 alpha:1.0]];
    [where setAutoresizingMask:NSViewWidthSizable];
    [[where cell] setLineBreakMode:NSLineBreakByTruncatingHead];
    [self addSubview:where];
    _where = where;

    return self;
}

- (void)setFileURL:(NSURL *)url
{
    NSString *path = [url path];
    if ([path length] == 0) {
        [[self textField] setStringValue:@""];
        [[self imageView] setImage:nil];
        [_where setStringValue:@""];
        return;
    }
    [[self textField] setStringValue:[path lastPathComponent]];
    [[self imageView] setImage:[[NSWorkspace sharedWorkspace] iconForFile:path]];

    NSString *folder = [[path stringByDeletingLastPathComponent]
                            stringByAbbreviatingWithTildeInPath];
    [_where setStringValue:folder ? folder : @""];
}

@end

#pragma mark - Checking the history against the disk

// How many recents are offered, and how many history entries are checked to
// find them. The second bound exists because the checking is done for entries
// that turn out to be missing too, and a history is the system's to size.
#define PV_RECENTS_SHOWN    12
#define PV_RECENTS_SCANNED  64

// How long the main thread waits for the check before showing the window
// without its answer. A local disk answers a dozen stats in well under a
// millisecond, so this is only ever reached when something is not answering.
#define PV_RECENTS_WAIT_SECONDS  0.15

// One check of the history against the disk, run off the main thread. See
// -reloadRecents for why.
//
// `candidates` is filled in before the check starts and `found` is read only
// after it has finished -- across a semaphore or a main-queue dispatch, both of
// which order the two -- so neither needs a lock.
@interface PVRecentScan : NSObject {
@public
    NSArray        *candidates;    // file URLs with a path, newest first
    NSMutableArray *found;         // the ones that still exist, newest first
    unsigned long   generation;
}
- (void)run;
@end

@implementation PVRecentScan

- (void)dealloc
{
    [candidates release];
    [found release];
    [super dealloc];
}

- (void)run
{
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSUInteger i, n = [candidates count];
        for (i = 0; i < n && [found count] < PV_RECENTS_SHOWN; i++) {
            NSURL *u = [candidates objectAtIndex:i];
            // A file that has been moved or deleted since is still in the
            // history. Offering it would open a panel of apology on click; it
            // is dropped.
            if ([fm fileExistsAtPath:[u path]]) [found addObject:u];
        }
    }
}

@end

#pragma mark - Controller

@interface PVWelcomeWindowController ()
- (void)applyRecentScan:(PVRecentScan *)scan;
@end

@implementation PVWelcomeWindowController

static PVWelcomeWindowController *sShared = nil;

+ (PVWelcomeWindowController *)sharedController
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sShared = [[PVWelcomeWindowController alloc] init]; });
    return sShared;
}

+ (void)showWelcome
{
    // Never on top of real content: if a document is already open the empty
    // state has nothing to say.
    if ([[[NSDocumentController sharedDocumentController] documents] count] > 0) return;
    PVWelcomeWindowController *wc = [self sharedController];
    [wc reloadRecents];
    [wc showWindow:nil];
    [[wc window] makeKeyAndOrderFront:nil];
}

+ (void)hideWelcomeIfShowing
{
    if (!sShared) return;
    [[sShared window] orderOut:nil];
}

- (id)init
{
    NSRect frame = NSMakeRect(0, 0, 460, 420);
    NSUInteger style = (NSTitledWindowMask | NSClosableWindowMask |
                        NSMiniaturizableWindowMask);
    NSWindow *w = [[[NSWindow alloc] initWithContentRect:frame
                                              styleMask:style
                                                backing:NSBackingStoreBuffered
                                                  defer:NO] autorelease];
    [w setTitle:@"Postview"];
    [w setReleasedWhenClosed:NO];
    [w setAnimationBehavior:NSWindowAnimationBehaviorNone];   // see PVWindowController
    // Nothing here is worth restoring, and restoration is precisely what used
    // to bring a previous session's document back at launch.
    [w setRestorable:NO];
    [w center];

    self = [super initWithWindow:w];
    if (!self) return nil;

    _recents = [[NSMutableArray alloc] init];

    // The drop target is the content view, so every part of the window takes a
    // drop -- including the list, which claims no drag types of its own and so
    // lets AppKit walk up to this.
    _dropView = [[PVWelcomeView alloc] initWithFrame:[[w contentView] bounds]];
    [_dropView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [w setContentView:_dropView];

    [self buildRecentList];
    [w setDelegate:self];
    return self;
}

- (void)buildRecentList
{
    NSRect b = [_dropView bounds];
    // Below the caption, inset so the drop ring around the window stays visible.
    NSRect listFrame = NSMakeRect(16, 16, NSWidth(b) - 32, NSHeight(b) - 86);

    _recentScroll = [[NSScrollView alloc] initWithFrame:listFrame];
    [_recentScroll setHasVerticalScroller:YES];
    [_recentScroll setAutohidesScrollers:YES];
    [_recentScroll setBorderType:NSBezelBorder];
    [_recentScroll setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

    _recentTable = [[NSTableView alloc] initWithFrame:[[_recentScroll contentView] bounds]];
    NSTableColumn *col = [[[NSTableColumn alloc] initWithIdentifier:@"doc"] autorelease];
    [col setWidth:NSWidth(listFrame) - 4];
    [col setResizingMask:NSTableColumnAutoresizingMask];
    [_recentTable addTableColumn:col];
    [_recentTable setHeaderView:nil];
    [_recentTable setRowHeight:36];
    [_recentTable setUsesAlternatingRowBackgroundColors:NO];
    [_recentTable setBackgroundColor:[NSColor whiteColor]];
    [_recentTable setIntercellSpacing:NSMakeSize(0, 0)];
    [_recentTable setColumnAutoresizingStyle:NSTableViewUniformColumnAutoresizingStyle];
    [_recentTable setDataSource:self];
    [_recentTable setDelegate:self];
    [_recentTable setTarget:self];
    // Single click, the way a launcher list behaves: this is a list of things
    // to open, not a list of things to select.
    [_recentTable setAction:@selector(recentClicked:)];
    [_recentScroll setDocumentView:_recentTable];

    [_dropView addSubview:_recentScroll];
}

- (void)dealloc
{
    NSWindow *w = [self window];
    if ([w delegate] == (id <NSWindowDelegate>)self) [w setDelegate:nil];
    [_recentTable setDelegate:nil];
    [_recentTable setDataSource:nil];
    [_recentTable setTarget:nil];
    [_recentTable release];
    [_recentScroll release];
    [_dropView release];
    [_recents release];
    [super dealloc];
}

#pragma mark - Recents

// The list comes from NSDocumentController, which is already maintaining it:
// every open through the app, the Open Recent menu, and the system's own
// document history are the same list. Keeping a second one here would be a
// second thing to get out of step.
//
// Whether each entry still exists is asked OFF the main thread, and that is the
// one thing about this list that is not cosmetic. The history names files on
// whatever volume they were opened from, and a stat on a network share that has
// stopped answering does not fail, it blocks: for as long as the client takes
// to give up on the server, and on a hard NFS mount for good. This runs at
// launch and on every click of the Dock icon, so one recent PDF on a NAS that
// has gone to sleep was enough to beachball Postview before it had shown a
// window -- the very failure PVPDFSource moved the document copy into a child
// process to rule out (see PV_HELPER_MODE_COPY), arrived at from the one other
// place the app reads a path it did not choose.
//
// The main thread waits PV_RECENTS_WAIT_SECONDS for the answer, so in every
// ordinary case the window opens with the list exactly as it always did. Past
// that it opens without, and the list appears when the check comes back; a
// check that never comes back costs a parked background thread, not the app.
- (void)reloadRecents
{
    NSArray *urls = [[NSDocumentController sharedDocumentController] recentDocumentURLs];
    NSMutableArray *candidates = [NSMutableArray array];
    NSUInteger i, n = [urls count];
    for (i = 0; i < n && [candidates count] < PV_RECENTS_SCANNED; i++) {
        // The history is the system's, not this app's, and it can hold entries
        // this app never wrote: a URL with no path, a reference to a volume
        // that is gone. Every one of them is checked rather than assumed --
        // the shape here, the existence on the scan.
        NSURL *u = [urls objectAtIndex:i];
        if (![u isKindOfClass:[NSURL class]] || ![u isFileURL]) continue;
        if ([[u path] length] == 0) continue;
        [candidates addObject:u];
    }

    PVRecentScan *scan = [[[PVRecentScan alloc] init] autorelease];
    scan->candidates = [candidates copy];
    scan->found      = [[NSMutableArray alloc] init];
    scan->generation = ++_recentsGeneration;

    // Nothing to ask the disk about: settled here, with no thread involved.
    if ([candidates count] == 0) {
        [self applyRecentScan:scan];
        return;
    }

    // The block retains the scan and this controller, which lives for the
    // process, so the late delivery below always has both. The semaphore is
    // retained for the block explicitly: whether a dispatch object is an
    // Objective-C object a block retains depends on the SDK it is built with.
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    if (!done) {
        // Nowhere to wait with. Checked inline, which is what this always did.
        [scan run];
        [self applyRecentScan:scan];
        return;
    }
    dispatch_retain(done);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [scan run];
        dispatch_semaphore_signal(done);
        dispatch_release(done);
        dispatch_async(dispatch_get_main_queue(), ^{ [self applyRecentScan:scan]; });
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(PV_RECENTS_WAIT_SECONDS * (double)NSEC_PER_SEC))) == 0)
        [self applyRecentScan:scan];
    dispatch_release(done);
}

// Put a finished check on screen, if it is the newest one and is not there yet.
// Reached twice for every check that finishes inside the wait -- once from the
// wait and once from its own delivery -- and the second is a no-op.
- (void)applyRecentScan:(PVRecentScan *)scan
{
    if (scan->generation != _recentsGeneration) return;   // superseded
    if (scan->generation == _appliedGeneration) return;   // already shown
    _appliedGeneration = scan->generation;

    [_recents setArray:scan->found];
    BOOL empty = ([_recents count] == 0);
    [_recentScroll setHidden:empty];
    [(PVWelcomeView *)_dropView setCompact:empty];
    [_recentTable reloadData];
    [_recentTable deselectAll:nil];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return (NSInteger)[_recents count]; }

- (NSView *)tableView:(NSTableView *)tv
   viewForTableColumn:(NSTableColumn *)col
                  row:(NSInteger)row
{
    if (row < 0 || row >= (NSInteger)[_recents count]) return nil;
    PVRecentRowView *v = [tv makeViewWithIdentifier:@"PVRecentRow" owner:self];
    if (!v) {
        v = [[[PVRecentRowView alloc] initWithFrame:
                NSMakeRect(0, 0, [col width], 36)] autorelease];
        [v setIdentifier:@"PVRecentRow"];
    }
    [v setFileURL:[_recents objectAtIndex:(NSUInteger)row]];
    return v;
}

- (IBAction)recentClicked:(id)sender
{
    NSInteger row = [_recentTable clickedRow];
    if (row < 0 || row >= (NSInteger)[_recents count]) return;
    NSURL *url = [[[_recents objectAtIndex:(NSUInteger)row] retain] autorelease];

    NSDocumentController *dc = [NSDocumentController sharedDocumentController];
    NSError *err = nil;
    id doc = [dc openDocumentWithContentsOfURL:url display:YES error:&err];
    if (!doc) {
        // Gone or unreadable since the list was built. Say so, then take it out
        // of the list rather than leaving a row that cannot work.
        if (err) [dc presentError:err];
        [self reloadRecents];
    }
    [_recentTable deselectAll:nil];
}

@end
