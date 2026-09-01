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

#pragma mark - Controller

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
- (void)reloadRecents
{
    [_recents removeAllObjects];
    NSArray *urls = [[NSDocumentController sharedDocumentController] recentDocumentURLs];
    NSUInteger i, n = [urls count];
    for (i = 0; i < n && [_recents count] < 12; i++) {
        // The history is the system's, not this app's, and it can hold entries
        // this app never wrote: a URL with no path, a reference to a volume
        // that is gone. Every one of them is checked rather than assumed.
        NSURL *u = [urls objectAtIndex:i];
        if (![u isKindOfClass:[NSURL class]] || ![u isFileURL]) continue;
        NSString *path = [u path];
        if ([path length] == 0) continue;
        // A file that has been moved or deleted since is still in the history.
        // Offering it would open a panel of apology on click; it is dropped.
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
        [_recents addObject:u];
    }

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
