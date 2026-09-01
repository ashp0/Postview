#import "PVWindowController.h"
#import "PVStateStore.h"
#import "PVWelcomeWindowController.h"
#import "PVDropView.h"

static NSString * const PVToolbarSidebar = @"PVToolbarSidebar";
static NSString * const PVToolbarZoom    = @"PVToolbarZoom";

// One height for every toolbar control, and one padding around the icon inside
// it. Stating them once is what keeps the items looking like a set: the
// sidebar button and the zoom control used to be built from unrelated numbers
// and sat at visibly different heights, with their contents on different
// baselines.
//
// No widths here on purpose. The zoom control used to be pinned to 74 points
// for two 36-point segments, which left nothing for the bezel and clipped the
// outer edge of both magnifiers -- visible in the shipped build on Mavericks.
// Widths now come from -sizeToFit, so the control is whatever it needs to be
// on the system that is actually drawing it, at whatever display scale.
#define PV_TOOLBAR_ITEM_H     25.0
#define PV_TOOLBAR_ICON       18.0   // the artwork's own size, in points

static const CGFloat kZoomSteps[] = {
    0.25, 0.33, 0.50, 0.67, 0.75, 1.00, 1.25, 1.50, 2.00, 3.00, 4.00
};
static const int kZoomStepCount = (int)(sizeof(kZoomSteps) / sizeof(kZoomSteps[0]));

// Declared up front rather than relied on being defined earlier in the file:
// -teardownReferences cancels the settle timer and sits well above where these
// are implemented, and a private method resolved by position is a method that
// breaks when someone reorders the file.
@interface PVWindowController ()
- (void)cancelSettle;
- (void)scheduleSettle;
- (void)settleFired:(NSTimer *)timer;
- (void)scrollClipTo:(NSPoint)p;
@end

// +[PVRenderRequest page:...] can return nil -- +alloc can fail -- and
// -[NSMutableArray addObject:] raises on nil rather than ignoring it. Five call
// sites build these; saying it once is what keeps the fifth from being the one
// that forgets.
static void PVAddRequest(NSMutableArray *reqs, PVRenderRequest *request)
{
    if (request) [reqs addObject:request];
}

@implementation PVWindowController

#pragma mark - Setup

- (id)initWithSource:(PVPDFSource *)source url:(NSURL *)url
{
    // The superclass initialiser runs FIRST, before anything that can fail.
    //
    // It used to run last, after the window was built, which forced every
    // earlier failure to be a bare `return nil` -- there was no initialised
    // object to release, because -dealloc on an NSWindowController that never
    // ran its own initialiser is not something to attempt. The comment that
    // used to be here argued the leak was the smaller of the two evils, and it
    // was right about that; it was answering the wrong question. Neither is
    // necessary: -initWithWindow: accepts nil, so the superclass can be
    // initialised up front and -setWindow: can supply the window once it
    // exists. Every failure below is then an ordinary [self release].
    self = [super initWithWindow:nil];
    if (!self) return nil;
    PVLiveAdjust("PVWindowController", +1);

    if (!source) { [self release]; return nil; }
    NSRect frame = NSMakeRect(0, 0, 900, 760);
    NSUInteger style = (NSTitledWindowMask | NSClosableWindowMask |
                        NSMiniaturizableWindowMask | NSResizableWindowMask);
    NSWindow *window = [[[NSWindow alloc] initWithContentRect:frame
                                                    styleMask:style
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO] autorelease];
    // Everything below configures the window by message, which is nil-safe. A
    // controller with no window can never present anything and would fail
    // later and somewhere else, so it is refused here.
    if (!window) { [self release]; return nil; }
    [window setContentMinSize:NSMakeSize(380, 320)];
    [window setReleasedWhenClosed:NO];
    // No window animation. This is the same rule the rest of the app follows --
    // no timers, no polling, no animation loops -- applied to the one animation
    // Postview never asked for and AppKit supplies anyway.
    //
    // It is not cosmetic. AppKit runs the default document-window fade as an
    // NSAnimation in blocking mode: a nested run loop on a GCD worker thread,
    // held for the length of the animation. Driving many closes in a row leaves
    // those threads parked in -[NSAnimation _runBlocking] indefinitely, and
    // because they are the global concurrent queue's threads, the background
    // render queue then never gets scheduled at all -- rendering simply stops,
    // permanently, with no error anywhere. Sampled directly: a dozen worker
    // threads inside _runBlocking and not one inside a page render.
    //
    // The window also opens and closes instantly, which on the hardware this is
    // built for is the better half of the trade anyway.
    [window setAnimationBehavior:NSWindowAnimationBehaviorNone];
    // Postview restores your reading position itself, keyed by file path, when
    // you choose to open a document. It deliberately does not participate in
    // AppKit's window restoration, which would reopen the last session's
    // documents on a plain launch from the icon.
    [window setRestorable:NO];

    [self setWindow:window];

    _url       = [url copy];
    _source    = [source retain];
    _pageCache = [[PVImageCache alloc] initWithBudget:PVPageCacheBudget()];
    _pageQueue = [[PVRenderQueue alloc] initWithSource:_source label:"com.postview.render.pages"];
    if (!_pageCache || !_pageQueue) { [self release]; return nil; }
    [_pageQueue setDelegate:self];
    // Sized once, from a page count PVPDFSource has already bounded. Not a
    // hard failure: -allocateFailureTablesForPages: leaves the tables NULL if
    // it cannot get them, and every read of a NULL table answers "renderable".
    [self allocateFailureTablesForPages:[_source pageCount]];

    _zoomMode        = PVZoomModeFitWidth;
    _zoom            = 1.0;
    _restorePage     = 0;
    _restoreFraction = 0.0;
    _restoreSidebar  = NO;
    _displayedPage   = NSNotFound;
    _expressPage     = NSNotFound;
    _lastDirection   = 1;

    [self loadSavedStateIntoWindow:window];
    // A window with no interface in it is not a degraded viewer, it is an empty
    // grey rectangle with a toolbar. -buildInterface allocates a split view, a
    // scroll view and a page view, and it used to return void, so a failure in
    // any of them produced exactly that -- silently, and only for the user
    // whose machine was already out of memory.
    if (![self buildInterface]) { [self release]; return nil; }

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(clipBoundsChanged:)
               name:NSViewBoundsDidChangeNotification object:[_scrollView contentView]];
    [nc addObserver:self selector:@selector(scrollViewFrameChanged:)
               name:NSViewFrameDidChangeNotification object:_scrollView];
    [nc addObserver:self selector:@selector(willStartLiveScroll:)
               name:NSScrollViewWillStartLiveScrollNotification object:_scrollView];
    [nc addObserver:self selector:@selector(didEndLiveScroll:)
               name:NSScrollViewDidEndLiveScrollNotification object:_scrollView];
    [nc addObserver:self selector:@selector(windowOcclusionChanged:)
               name:NSWindowDidChangeOcclusionStateNotification object:window];
    [nc addObserver:self selector:@selector(backingPropertiesChanged:)
               name:NSWindowDidChangeBackingPropertiesNotification object:window];
    [nc addObserver:self selector:@selector(memoryPressure:)
               name:PVMemoryPressureNotification object:nil];

    return self;
}

- (void)loadSavedStateIntoWindow:(NSWindow *)window
{
    NSUInteger page = 0;
    CGFloat fraction = 0, zoom = 1.0;
    PVZoomMode mode = PVZoomModeFitWidth;
    BOOL sidebar = NO;
    NSString *frameString = nil;

    if ([[PVStateStore sharedStore] stateForURL:_url page:&page fraction:&fraction
                                       zoomMode:&mode zoom:&zoom sidebar:&sidebar
                                    windowFrame:&frameString]) {
        NSUInteger pc = [_source pageCount];
        if (pc == 0) return;
        if (page >= pc) page = pc - 1;
        _restorePage     = page;
        _restoreFraction = fraction;
        _restoreSidebar  = sidebar;
        _zoomMode        = mode;
        if (zoom >= PV_MIN_ZOOM && zoom <= PV_MAX_ZOOM) _zoom = zoom;
        if ([frameString length] > 0) {
            [window setFrameFromString:frameString];
        } else {
            [self setShouldCascadeWindows:YES];
        }
    } else {
        [self setShouldCascadeWindows:YES];
        [window center];
    }
}

// Builds the view tree, or returns NO having built none of it.
//
// Each of these allocations can fail, and the ones that matter are the three
// this controller keeps: without them there is nothing to draw a page into and
// nothing that scrolls. They are checked together rather than one at a time
// because the answer is the same for all three -- the caller releases the
// controller and the document does not open -- and because a partially built
// window is worse than no window.
- (BOOL)buildInterface
{
    NSWindow *window = [self window];

    // The window's whole surface accepts a dropped PDF: the page, the sidebar,
    // the grey margin, the lot. Done by making the content view the drop
    // target rather than by registering some control inside it -- AppKit finds
    // a destination by hit-testing and then walking up the view hierarchy, so
    // everything that does not claim a drag of its own ends up here.
    PVDropView *drop = [[[PVDropView alloc] initWithFrame:
                            [[window contentView] frame]] autorelease];
    if (!drop) return NO;
    [drop setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [window setContentView:drop];

    NSRect content = [[window contentView] bounds];

    _splitView = [[NSSplitView alloc] initWithFrame:content];
    if (!_splitView) return NO;
    [_splitView setVertical:YES];
    [_splitView setDividerStyle:NSSplitViewDividerStyleThin];
    [_splitView setDelegate:self];
    [_splitView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

    _scrollView = [[NSScrollView alloc] initWithFrame:content];
    if (!_scrollView) return NO;
    [_scrollView setHasVerticalScroller:YES];
    [_scrollView setHasHorizontalScroller:YES];
    [_scrollView setAutohidesScrollers:YES];
    [_scrollView setBorderType:NSNoBorder];
    [_scrollView setDrawsBackground:YES];
    [_scrollView setBackgroundColor:[NSColor colorWithCalibratedWhite:0.42 alpha:1.0]];
    [_scrollView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [_scrollView setPostsFrameChangedNotifications:YES];

    _pageView = [[PVPageView alloc] initWithSource:_source cache:_pageCache];
    if (!_pageView) return NO;
    [_pageView setDelegate:self];
    [_scrollView setDocumentView:_pageView];

    NSClipView *clip = [_scrollView contentView];
    [clip setPostsBoundsChangedNotifications:YES];
    // Copy-on-scroll means AppKit blits the already-drawn pixels and only asks
    // us to draw the newly exposed strip.
    [clip setCopiesOnScroll:YES];

    [_splitView addSubview:_scrollView];
    [[window contentView] addSubview:_splitView];

    NSToolbar *toolbar = [[[NSToolbar alloc] initWithIdentifier:@"PVToolbar"] autorelease];
    [toolbar setDelegate:self];
    [toolbar setAllowsUserCustomization:NO];
    [toolbar setDisplayMode:NSToolbarDisplayModeIconOnly];
    [toolbar setSizeMode:NSToolbarSizeModeSmall];
    [window setToolbar:toolbar];

    // The proxy icon, and the document's own name in the title bar. Both come
    // free with the represented URL and are what make the window read as a
    // document window rather than a panel that happens to show a PDF.
    [window setRepresentedURL:_url];
    [self updateWindowTitle];

    // Created programmatically, so the delegate must be set explicitly for
    // -windowWillClose: (where the reading position is saved) to fire.
    [window setDelegate:self];
    [window setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];
    [window makeFirstResponder:_pageView];
    return YES;
}

// Everything that holds an unretained pointer back to this controller is
// cleared here as well as in -windowWillClose:. The close path is the normal
// one, but a controller can be released without its window ever closing (an
// open that fails after the window is built, a document torn down before it is
// shown), and in that case each of these was left pointing at freed memory.
- (void)teardownReferences
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    // Before anything else they could still fire into. An NSTimer retains its
    // target, so a live one here is both a use-after-teardown and a leak of
    // the whole controller graph behind it. Both timers, for one reason.
    [self cancelSettle];
    [self cancelRetry];

    [_pageQueue  setDelegate:nil];
    [_thumbQueue setDelegate:nil];
    [_pageQueue  shutdown];
    [_thumbQueue shutdown];

    [_splitView setDelegate:nil];
    [_thumbView setDelegate:nil];
    [_pageView  setDelegate:nil];

    NSWindow *w = [self window];
    if (w) {
        NSToolbar *tb = [w toolbar];
        if ([tb delegate] == (id <NSToolbarDelegate>)self) [tb setDelegate:nil];
        if ([w delegate] == (id <NSWindowDelegate>)self)   [w setDelegate:nil];

        // Detach the whole view tree from the window, and take the toolbar
        // with it. This is not tidiness.
        //
        // AppKit does not release a window that has ever been ordered on
        // screen. It holds it for the life of the process, whether or not the
        // window has been closed, ordered out, or told not to release itself on
        // close -- checked against a bare NSWindow with none of this code
        // anywhere near it, on every style mask, with tabbing disallowed, and
        // after forty seconds of run loop. A window Postview cannot get rid of
        // is a window that goes on owning its content view, and through it the
        // page view, the bitmap cache, and the CGPDFDocument behind them. Left
        // attached, every document ever opened keeps its parsed PDF resident
        // until the app quits: tens of megabytes per file, accumulating for as
        // long as the session lasts, on exactly the machine with least to spare.
        //
        // Safe because the controller retains _splitView in its own right. The
        // view tree stays alive until -dealloc; it simply stops being the
        // window's, so -dealloc is what finally frees it.
        [_splitView removeFromSuperview];
        [w setToolbar:nil];

        // Same argument as the toolbar, for the same reason: a window AppKit
        // will not let go of should not go on holding a document icon for a
        // file that is closed, or advertising itself as somewhere to drop one.
        [w setRepresentedURL:nil];
        [[w contentView] unregisterDraggedTypes];
    }
}

- (void)dealloc
{
    PVLiveAdjust("PVWindowController", -1);
    [self teardownReferences];
    [self freeFailureTables];
    [_url release];
    [_thumbScrollView release];
    [_thumbView release];
    [_thumbQueue release];
    [_thumbCache release];
    [_thumbSource release];
    [_splitView release];
    [_pageView release];
    [_scrollView release];
    [_pageQueue release];
    [_pageCache release];
    [_source release];
    [super dealloc];
}

#pragma mark - First display

// Layout and the first render requests are issued BEFORE -[super showWindow:]
// orders the window on screen. Previously the window appeared first and was
// laid out afterwards, so the first frame the user saw was an unlaid-out page
// view: a full-window flat rectangle with no page in it. Doing the work first
// costs nothing extra and means the window's very first frame already has the
// page rectangle in the right place, with its render in flight.
- (void)showWindow:(id)sender
{
    if (!_didInitialLayout) {
        _didInitialLayout = YES;
        if (_restoreSidebar) [self showSidebar];
        // Opening a document is the definition of "the user is waiting on a
        // blank rectangle", so the page being opened at gets the express lane.
        _expressPage = _restorePage;
        [self relayoutKeepingPage:_restorePage fraction:_restoreFraction];
        [self updateVisibleContent];
    }
    // Put the empty state away here rather than on a window notification: the
    // notification ordering relative to NSDocumentController registering the
    // document is not guaranteed, and the empty state's own window posts the
    // same notification when it appears.
    [PVWelcomeWindowController hideWelcomeIfShowing];

    [super showWindow:sender];
    [[self window] makeFirstResponder:_pageView];
}

#pragma mark - Geometry helpers

- (CGFloat)backingScale
{
    NSWindow *w = [self window];
    CGFloat s = w ? [w backingScaleFactor] : 1.0;
    return (s < 1.0) ? 1.0 : s;
}

- (NSSize)viewportSize
{
    NSSize s = [[_scrollView contentView] bounds].size;
    if (s.width  < 60) s.width  = 60;
    if (s.height < 60) s.height = 60;
    return s;
}

- (CGFloat)zoomForCurrentMode
{
    CGSize maxPage = [_source maxPointSize];
    NSSize vp = [self viewportSize];
    // A couple of points of slack stops fit-width from oscillating with the
    // appearance of the vertical scroller on legacy-scroller systems.
    CGFloat availW = vp.width  - 2 * PV_EDGE_GAP - 3;
    CGFloat availH = vp.height - 2 * PV_EDGE_GAP;
    if (availW < 20) availW = 20;
    if (availH < 20) availH = 20;

    switch (_zoomMode) {
        case PVZoomModeFitWidth: return availW / maxPage.width;
        case PVZoomModeFitPage:  return fmin(availW / maxPage.width, availH / maxPage.height);
        case PVZoomModeActual:   return 1.0;
        case PVZoomModeCustom:
        default:                 return _zoom;
    }
}

- (NSUInteger)currentPageWithFraction:(CGFloat *)outFraction
{
    NSRect vis = [[_scrollView contentView] documentVisibleRect];
    return [_pageView pageAtTopOfRect:vis fraction:outFraction];
}

- (void)relayoutKeepingPage:(NSUInteger)page fraction:(CGFloat)fraction
{
    CGFloat z = [self zoomForCurrentMode];
    if (z < PV_MIN_ZOOM) z = PV_MIN_ZOOM;
    if (z > PV_MAX_ZOOM) z = PV_MAX_ZOOM;
    _zoom = z;
    [_pageView setZoom:z
          backingScale:[self backingScale]
        containerWidth:[self viewportSize].width];
    [self scrollToPage:page fraction:fraction];
    [self updatePageIndicator];
}

// Move the viewport, and record where it actually ended up.
//
// The recording is the point of this existing. Every programmatic scroll rounds
// its target to a whole point, and AppKit constrains the result again to the
// document's own bounds -- so the place the clip lands is not in general the
// place it was asked for. Both callers used to store the number they had asked
// for, and -clipBoundsChanged: then compared it against the number the clip
// reported, which is a different one.
//
// That difference is small and it is not harmless. The direction test is
// `y > _lastScrollY + 0.5`, so half a point of disagreement sits exactly on the
// threshold and can flip _lastDirection -- which decides which way prefetch
// looks and which side of the visible range an arriving bitmap is kept on. The
// speed sample is worse: -clipBoundsChanged: divides that phantom travel by an
// interval as short as 2 ms, so up to half a point of rounding can be reported
// as ~250 pt/s of scrolling that never happened, seeding _scrollSpeed (which is
// seeded from its first sample, deliberately) with a measurement of arithmetic.
//
// Reading the clip back makes the recorded position true by construction rather
// than by both sides agreeing about rounding. A programmatic scroll now produces
// a delta of exactly zero on the notification it causes, which is what it is.
- (void)scrollClipTo:(NSPoint)p
{
    NSClipView *clip = [_scrollView contentView];
    if (!clip) return;
    [clip scrollToPoint:NSMakePoint(floor(p.x + 0.5), floor(p.y + 0.5))];
    [_scrollView reflectScrolledClipView:clip];
    _lastScrollY = NSMinY([clip documentVisibleRect]);
}

- (void)scrollToPage:(NSUInteger)page fraction:(CGFloat)fraction
{
    NSUInteger pageCount = [_source pageCount];
    if (pageCount == 0) return;
    if (page >= pageCount) page = pageCount - 1;
    if (!isfinite(fraction)) fraction = 0;
    NSClipView *clip = [_scrollView contentView];
    NSRect r  = [_pageView rectForPage:page];
    NSRect cb = [clip bounds];

    CGFloat y = NSMinY(r) + fraction * NSHeight(r);
    if (fraction < 0.001) y -= PV_PAGE_GAP / 2.0;      // show the gap above the page
    CGFloat maxY = NSHeight([_pageView frame]) - NSHeight(cb);
    if (y > maxY) y = maxY;
    if (y < 0)    y = 0;

    CGFloat x = (NSWidth([_pageView frame]) - NSWidth(cb)) / 2.0;
    if (x < 0) x = 0;

    [self scrollClipTo:NSMakePoint(x, y)];
}

#pragma mark - Unrenderable pages

// Three attempts, then that bitmap is left alone. One is too few -- a bitmap
// context that could not be allocated under a momentary spike deserves another
// go -- and an unbounded number is the bug this exists to close.
#define PV_MAX_RENDER_ATTEMPTS 3

// Attempts for a failure that was about the machine rather than the page, and
// the first delay between them.
//
// Six, doubling from a quarter of a second, is a little over eight seconds of
// patience spread across increasing gaps. That covers the whole span of what
// transient means here -- another application's memory spike, a helper killed
// for missing its deadline, shared memory momentarily exhausted -- without ever
// becoming a spin. Past it the slot goes quiet until something resets it, which
// is not the same as the page being declared unrenderable: see
// -pageIsUnrenderable:preview:.
#define PV_MAX_TRANSIENT_RETRIES   6
#define PV_TRANSIENT_BACKOFF_BASE  0.25

// Allocate the two failure tables for a document of `pages` pages. Called once,
// from -initWithSource:url:. A failure to allocate is survivable: every read
// below treats a NULL table as "nothing has failed".
- (void)allocateFailureTablesForPages:(NSUInteger)pages
{
    _failureSlots = 0;
    if (pages == 0 || pages > SIZE_MAX / 2) return;
    if (pages > SIZE_MAX / (2 * sizeof(CGSize))) return;
    _pageFailures     = (uint8_t *)calloc(pages * 2, sizeof(uint8_t));
    _thumbFailures    = (uint8_t *)calloc(pages, sizeof(uint8_t));
    _pageTransient    = (uint8_t *)calloc(pages * 2, sizeof(uint8_t));
    _thumbTransient   = (uint8_t *)calloc(pages, sizeof(uint8_t));
    _pageRetryAt      = (double  *)calloc(pages * 2, sizeof(double));
    _thumbRetryAt     = (double  *)calloc(pages, sizeof(double));
    _pageFailureSize  = (CGSize  *)calloc(pages * 2, sizeof(CGSize));
    _thumbFailureSize = (CGSize  *)calloc(pages, sizeof(CGSize));
    if (!_pageFailures || !_thumbFailures || !_pageTransient ||
        !_thumbTransient || !_pageRetryAt || !_thumbRetryAt ||
        !_pageFailureSize || !_thumbFailureSize) {
        [self freeFailureTables];
        return;
    }
    _failureSlots = pages;
}

// All or nothing. Every read below treats a NULL table as "nothing has failed",
// which is only a safe reading if the tables cannot disagree with each other
// about whether they exist.
- (void)freeFailureTables
{
    free(_pageFailures);     _pageFailures     = NULL;
    free(_thumbFailures);    _thumbFailures    = NULL;
    free(_pageTransient);    _pageTransient    = NULL;
    free(_thumbTransient);   _thumbTransient   = NULL;
    free(_pageRetryAt);      _pageRetryAt      = NULL;
    free(_thumbRetryAt);     _thumbRetryAt     = NULL;
    free(_pageFailureSize);  _pageFailureSize  = NULL;
    free(_thumbFailureSize); _thumbFailureSize = NULL;
    _failureSlots = 0;
}

// The slot for one page bitmap: full and preview are counted apart.
- (NSUInteger)failureSlotForPage:(NSUInteger)page preview:(BOOL)preview
{
    return page * 2 + (preview ? 1 : 0);
}

// A slot whose counters describe a different bitmap than the one now being
// asked about is a slot with nothing to say. Clears it and records the new size.
//
// Called only when a failure is being RECORDED, which is the moment the size is
// known for certain. The queries below cannot do this -- most of them have a
// page number and nothing else -- and they do not need to: a size change that
// arrives through zoom or a window resize already resets every slot, and this
// catches whatever reaches a counter by another route.
- (void)prepareFailureSlot:(NSUInteger)slot
                     sizes:(CGSize *)sizes
                counters:(uint8_t *)counters
                 transient:(uint8_t *)transient
                   retryAt:(double *)retryAt
                 pixelSize:(CGSize)px
{
    CGSize use = PVClampPixelSize(px);
    CGSize had = sizes[slot];
    // Exact equality, deliberately. These are the clamped integral sizes the
    // renderer was actually given, not the floating-point request, so two
    // bitmaps of the same size compare equal and a tolerance would only let a
    // genuinely different bitmap inherit another's history.
    if (had.width == use.width && had.height == use.height) return;
    sizes[slot]     = use;
    counters[slot]  = 0;
    transient[slot] = 0;
    retryAt[slot]   = 0;
}

// How long to wait before trying this slot again, having failed `attempts`
// times transiently. Doubling from a quarter of a second: the first retry is
// fast enough to be invisible when the pressure was momentary, and the last is
// long enough that a machine genuinely out of memory is not being asked sixty
// times a second to prove it.
static double PVTransientBackoff(unsigned attempts)
{
    double delay = PV_TRANSIENT_BACKOFF_BASE;
    unsigned i;
    for (i = 1; i < attempts && delay < 8.0; i++) delay *= 2.0;
    return delay;
}

- (BOOL)pageIsUnrenderable:(NSUInteger)page preview:(BOOL)preview
{
    // Nothing in this document can be drawn, so there is no point naming any of
    // it. Asked before the tables, because this is not a fact the tables record.
    if (_reportedRendererMissing) return YES;
    if (!_pageFailures || page >= _failureSlots) return NO;
    NSUInteger slot = [self failureSlotForPage:page preview:preview];
    if (_pageFailures[slot] >= PV_MAX_RENDER_ATTEMPTS) return YES;
    // Out of transient retries counts as unrenderable FOR NOW. It is not
    // written into the permanent counter, so -resetRenderFailures -- a zoom, an
    // emptied cache, the machine calming down -- brings the page back, which is
    // the whole difference between this and a page Quartz will not draw.
    if (_pageTransient[slot] >= PV_MAX_TRANSIENT_RETRIES) return YES;
    // A backoff still outstanding: there is no point naming this page yet, and
    // -notePageFailed:... has armed a timer to ask again when there is.
    if (_pageRetryAt[slot] > 0 && PVMonotonicSeconds() < _pageRetryAt[slot])
        return YES;
    return NO;
}

// Nothing can be drawn for this page at all: both the full bitmap and the cheap
// preview have run out of attempts. This is the question the wanted-set and the
// express lane ask -- "is there any point naming this page" -- and it is NOT
// the same as either slot on its own.
- (BOOL)pageIsUnrenderable:(NSUInteger)page
{
    return ([self pageIsUnrenderable:page preview:NO] &&
            [self pageIsUnrenderable:page preview:YES]);
}

- (BOOL)thumbIsUnrenderable:(NSUInteger)page
{
    if (_reportedRendererMissing) return YES;
    if (!_thumbFailures || page >= _failureSlots) return NO;
    if (_thumbFailures[page] >= PV_MAX_RENDER_ATTEMPTS) return YES;
    if (_thumbTransient[page] >= PV_MAX_TRANSIENT_RETRIES) return YES;
    if (_thumbRetryAt[page] > 0 && PVMonotonicSeconds() < _thumbRetryAt[page])
        return YES;
    return NO;
}

// Record one failure against one bitmap, and say whether it is worth asking
// again -- which is the entire reason the renderer now reports a reason.
//
// Only a deterministic refusal spends a permanent attempt. A page CoreGraphics
// will not draw is a fact about the document that three tries confirm; a page
// that lost a race for shared memory, or whose helper was killed for missing a
// deadline, is a fact about the machine at one instant, and treating the two
// alike is what put valid pages permanently blank on a busy Mac.
- (BOOL)noteFailureInSlot:(NSUInteger)slot
                 counters:(uint8_t *)counters
                transient:(uint8_t *)transient
                  retryAt:(double *)retryAt
                  failure:(PVRenderFailure)failure
{
    switch (failure) {
        case PVRenderFailureInvalidPage:
            if (counters[slot] < PV_MAX_RENDER_ATTEMPTS) counters[slot]++;
            retryAt[slot] = 0;
            return (counters[slot] < PV_MAX_RENDER_ATTEMPTS);

        case PVRenderFailureHelperUnavailable:
            // Not a property of this page and not worth counting against it:
            // every page will fail the same way until the installation is
            // repaired. Reported once, at the document level.
            [self presentRendererUnavailable];
            return NO;

        case PVRenderFailureTransientResource:
        case PVRenderFailureTimeout:
        case PVRenderFailureProtocol:
        default:
            if (transient[slot] < PV_MAX_TRANSIENT_RETRIES) transient[slot]++;
            if (transient[slot] >= PV_MAX_TRANSIENT_RETRIES) {
                retryAt[slot] = 0;
                return NO;
            }
            retryAt[slot] = PVMonotonicSeconds() +
                            PVTransientBackoff(transient[slot]);
            [self scheduleRetryAt:retryAt[slot]];
            return YES;
    }
}

- (BOOL)notePageFailed:(NSUInteger)page
               preview:(BOOL)preview
             pixelSize:(CGSize)px
               failure:(PVRenderFailure)failure
{
    if (!_pageFailures || page >= _failureSlots) return NO;
    NSUInteger slot = [self failureSlotForPage:page preview:preview];
    [self prepareFailureSlot:slot sizes:_pageFailureSize counters:_pageFailures
                   transient:_pageTransient retryAt:_pageRetryAt pixelSize:px];
    return [self noteFailureInSlot:slot counters:_pageFailures
                         transient:_pageTransient retryAt:_pageRetryAt
                           failure:failure];
}

- (BOOL)noteThumbFailed:(NSUInteger)page
              pixelSize:(CGSize)px
                failure:(PVRenderFailure)failure
{
    if (!_thumbFailures || page >= _failureSlots) return NO;
    [self prepareFailureSlot:page sizes:_thumbFailureSize counters:_thumbFailures
                   transient:_thumbTransient retryAt:_thumbRetryAt pixelSize:px];
    return [self noteFailureInSlot:page counters:_thumbFailures
                         transient:_thumbTransient retryAt:_thumbRetryAt
                           failure:failure];
}

// Ask again once the earliest outstanding backoff has expired.
//
// Its own timer rather than -scheduleSettle's. The settle timer is the end of a
// movement and is cancelled and re-armed by every scroll event; a retry pinned
// to it would be pushed forward indefinitely by a reader who keeps scrolling,
// which is exactly the reader whose pages are missing.
- (void)scheduleRetryAt:(double)deadline
{
    if (_closing) return;
    double now = PVMonotonicSeconds();
    double delay = deadline - now;
    if (delay < 0.01) delay = 0.01;
    // An earlier deadline supersedes a later one; a later one is already
    // covered, because the fire re-examines every slot.
    if (_retryTimer && _retryTimerAt > 0 && _retryTimerAt <= deadline) return;
    [_retryTimer invalidate];
    _retryTimerAt = deadline;
    _retryTimer = [NSTimer timerWithTimeInterval:delay
                                          target:self
                                        selector:@selector(retryFired:)
                                        userInfo:nil
                                         repeats:NO];
    [[NSRunLoop currentRunLoop] addTimer:_retryTimer forMode:NSRunLoopCommonModes];
}

- (void)cancelRetry
{
    [_retryTimer invalidate];
    _retryTimer = nil;           // never retained by us; the run loop held it
    _retryTimerAt = 0;
}

- (void)retryFired:(NSTimer *)timer
{
    _retryTimer = nil;
    _retryTimerAt = 0;
    if (_closing || !_pageView) return;
    // The expired backoffs are not cleared here. -pageIsUnrenderable: compares
    // the deadline against the clock, so a slot whose wait is over is simply
    // eligible again; clearing them would be a second place that has to agree
    // about which slots those are.
    _haveRequestState = NO;
    _haveThumbState = NO;
    [self updateVisibleContent];
}

// The renderer is missing from the bundle. Said once per document, because it
// is one fact about the installation and not one per page.
- (void)presentRendererUnavailable
{
    if (_closing || _reportedRendererMissing) return;
    _reportedRendererMissing = YES;
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert setMessageText:@"Postview cannot render this document."];
    [alert setInformativeText:
        @"Its renderer is missing from the application bundle. "
        @"Reinstall Postview from the original archive."];
    [alert addButtonWithTitle:@"OK"];
    [alert beginSheetModalForWindow:[self window]
                      modalDelegate:nil
                     didEndSelector:NULL
                        contextInfo:NULL];
}

// Called for anything that changes the question being asked of the renderer --
// a different pixel size, an emptied cache, a window that has come back into
// view after the machine calmed down. Retrying then is worth it; retrying on
// every scroll event is what had to stop.
- (void)resetRenderFailures
{
    if (!_pageFailures) return;
    memset(_pageFailures,     0, _failureSlots * 2);
    memset(_thumbFailures,    0, _failureSlots);
    memset(_pageTransient,    0, _failureSlots * 2);
    memset(_thumbTransient,   0, _failureSlots);
    memset(_pageRetryAt,      0, _failureSlots * 2 * sizeof(double));
    memset(_thumbRetryAt,     0, _failureSlots * sizeof(double));
    memset(_pageFailureSize,  0, _failureSlots * 2 * sizeof(CGSize));
    memset(_thumbFailureSize, 0, _failureSlots * sizeof(CGSize));
    // _reportedRendererMissing is deliberately NOT cleared. A zoom or an
    // emptied cache changes the question being asked of the renderer; it does
    // not put a renderer back in the bundle.
    [self cancelRetry];
}

// The user has done something. That used to clear the pressure state, on the
// theory that a fresh action deserves fresh full-resolution pages -- but the
// user scrolling says nothing whatsoever about whether the kernel is still
// short of memory, and clearing it here meant a single scroll re-enabled
// full-resolution rendering and prefetching on a machine the kernel had just
// called critical. Scrolling is exactly what a user does while waiting for a
// machine under pressure to recover, so the reset fired constantly at the
// worst possible time.
//
// Only DISPATCH_MEMORYPRESSURE_NORMAL clears it now: the kernel is the only
// thing that knows, and it does say so. Kept as a named no-op because the call
// sites read correctly -- they are the places that would have to change if
// anything else ever becomes activity-scoped.
- (void)noteUserActivity
{
}

// Prefetching full-resolution bitmaps is the first thing to give up under
// memory pressure: those are the very bitmaps that were just dropped.
- (BOOL)wantsFullPrefetch  { return (_pressureReports == 0); }

// Full-resolution rendering of the pages actually on screen survives a warning
// and stops at critical. See _pressureReports.
- (BOOL)wantsFullRenders   { return (_pressureReports < 2); }

#pragma mark - Deciding what to render

// How long this page will actually be on screen, at the speed the document is
// currently moving. Infinite when nothing is moving.
- (double)secondsPageStaysVisible:(NSUInteger)page
{
    if (!(_scrollSpeed > 1.0)) return HUGE_VAL;
    NSRect vis = [[_scrollView contentView] documentVisibleRect];
    NSRect r   = [_pageView rectForPage:page];

    // Travelling down, a page is gone once the top of the viewport passes its
    // bottom edge; travelling up, once the bottom of the viewport passes its
    // top edge.
    double leaving = (_lastDirection >= 0) ? (double)(NSMaxY(r) - NSMinY(vis))
                                           : (double)(NSMaxY(vis) - NSMinY(r));
    if (!(leaving > 0)) return 0;

    // For a page still ahead of the viewport most of that distance is spent
    // before it appears at all, and time a page spends off screen is not time
    // it can be looked at. However far ahead it is, no page is ever visible
    // for longer than its own height plus the viewport's, at this speed.
    double whole = (double)(NSHeight(r) + NSHeight(vis));
    double on    = (whole < leaving) ? whole : leaving;
    return on / _scrollSpeed;
}

// Is a bitmap for this page worth asking for right now?
//
// Only ever false during a live scroll fast enough that the page will be gone
// before the bitmap could arrive. Standing still, reading, or scrolling at any
// pace where the pages can actually be seen, this is true and nothing changes.
//
// This is what separates a quarter of a core from well over a whole one during
// a flick. Cancelling queued work does not cover it: the queue is never idle
// while scrolling, so every page it picks up is genuinely wanted at the moment
// it starts and stale one render later. What had to stop was the asking.
- (BOOL)worthRenderingDuringScroll:(NSUInteger)page
{
    // Every input handed over explicitly; the decision itself lives in
    // PVShouldRenderWhileMoving so it can be tested without any of this.
    //
    // This used to begin `if (!_liveScrolling) return YES;`, which tied the
    // whole policy to the live-scroll notifications. AppKit posts those for
    // trackpad and wheel gestures only, so holding Page Down -- the same
    // motion, at a speed only the key repeat rate limits -- took the
    // unthrottled path and asked for a full-resolution bitmap, plus three
    // full-resolution prefetches, for every page it flew past. Which device
    // moved the document says nothing about whether the pages can be seen.
    BOOL render = [self pageSurvivesMotion:page];
    if (!render) PVStatAdd(PVStatRequestsSuppressed, 1);
    return render;
}

// How old the current speed measurement is. Infinite when nothing has been
// measured, which every consumer treats as "no evidence" and therefore renders.
- (double)scrollSpeedAge
{
    // Same clock the samples are taken on, or the age is a difference between
    // two different clocks.
    return (_lastScrollTime > 0)
         ? (PVMonotonicSeconds() - _lastScrollTime)
         : HUGE_VAL;
}

// The decision, without the accounting.
//
// -worthRenderingDuringScroll: keeps the counter, because a caller that asks
// that question is about to withhold exactly one bitmap. The wanted-set
// rebuild wants the answer once per page and then withholds either one bitmap
// or two, so it counts for itself and asks this instead. Splitting them is
// what keeps `requests_suppressed` a count of bitmaps rather than of pages.
- (BOOL)pageSurvivesMotion:(NSUInteger)page
{
    // Every input handed over explicitly; the decision itself lives in
    // PVShouldRenderWhileMoving so it can be tested without any of this.
    return PVShouldRenderWhileMoving(_scrollSpeed, [self scrollSpeedAge],
                                     [self secondsPageStaysVisible:page]);
}

// The whole of the machine-and-power-dependent behaviour, fetched once.
//
// Everything a "High Performance" or "Low Memory" menu would have contained is
// here instead, decided from three things the program can read and a user
// cannot reliably state: what the machine has, what it is plugged into, and
// whether the kernel is complaining. ENGINEERING.md §4.4 has the argument
// for why that is better than the menu; the short form is that every position
// of such a menu is worse than the automatic answer, so the control would only
// move blame.
//
// Cheap enough to ask per pass. PVCurrentPowerSource caches for five seconds and
// PVRamTierOfThisMachine resolves once, so this is a handful of comparisons.
- (PVRenderPolicy)currentRenderPolicy
{
    return PVRenderPolicyFor(PVCurrentPowerSource(),
                             PVRamTierOfThisMachine(),
                             _pressureReports);
}

// Is this specific bitmap worth asking for, given how the viewport is moving
// and what this document has been measured to cost?
//
// Takes the dwell and the speed age rather than reading them, because one pass
// of the wanted-set builder asks about several bitmaps and they must all be
// decided against the same instant. Two reads either side of a clock tick would
// let a page's preview and its full-resolution bitmap disagree about whether
// the document is moving, which is a wanted set that contradicts itself.
//
// The prediction is per bitmap and that is the point. A preview is a ninth the
// pixels of a full page but re-walks the whole content stream, so on text it is
// nothing like a ninth of the cost -- and the two are estimated separately for
// exactly that reason (PVCostModel.h, failure 2). Asking one question for both
// is what the old single dwell constant was doing.
- (BOOL)bitmapSurvivesMotion:(CGSize)px
                     preview:(BOOL)preview
                       dwell:(double)dwell
                         age:(double)age
                      policy:(PVRenderPolicy)policy
{
    double predicted = [_pageQueue predictedSecondsForPixels:px preview:preview];
    return PVShouldRenderWhileMovingCost(_scrollSpeed, age, dwell, predicted,
                                         policy.dwellSafetyFactor,
                                         policy.minDwellSeconds);
}

// Is the viewport in motion right now? The `Scrolling` half of the scheduler's
// two states; `Settled` is simply its negation.
//
// The point of stating it once is that it is device-independent. A gesture
// announces itself through AppKit, and that is the only motion the live-scroll
// flags know about -- but holding Page Down, or an arrow key repeating at 50/s,
// moves the document exactly as fast and posts no such notification. Anything
// that keys off _liveScrolling alone is therefore correct for the trackpad and
// wrong for the keyboard, which is precisely the shape of the bug this fixes:
// the preview path had already been made device-independent (see
// -worthRenderingDuringScroll:) while the full-resolution path, which costs
// about six times as much, was still gated on the gesture flags alone.
//
// Fresh evidence of real speed only. A stale measurement is not motion: see
// PV_SPEED_FRESH_SECONDS, which is what stops a document that has stopped
// moving from being treated as moving forever.
- (BOOL)viewportIsMoving
{
    if (_liveScrolling || _liveZooming) return YES;
    double age = [self scrollSpeedAge];
    return (_scrollSpeed > PV_MIN_SCROLL_SPEED) &&
           (age >= 0) && (age < PV_SPEED_FRESH_SECONDS);
}

#pragma mark - Settling after movement that has no end event

- (void)cancelSettle
{
    [_settleTimer invalidate];
    _settleTimer = nil;          // never retained by us; the run loop held it
}

- (void)scheduleSettle
{
    [self cancelSettle];
    if (_closing) return;
    // Common modes so a settle still lands while a menu is tracking or a
    // scrollbar is held; the default mode alone would defer it indefinitely.
    _settleTimer = [NSTimer timerWithTimeInterval:PV_SETTLE_SECONDS
                                           target:self
                                         selector:@selector(settleFired:)
                                         userInfo:nil
                                          repeats:NO];
    [[NSRunLoop currentRunLoop] addTimer:_settleTimer forMode:NSRunLoopCommonModes];
}

// The document has stopped moving. This is the keyboard's equivalent of
// -didEndLiveScroll: and does the same three things.
- (void)settleFired:(NSTimer *)timer
{
    _settleTimer = nil;                // one-shot: the run loop is done with it
    if (_closing || !_pageView) return;
    if (_liveScrolling) return;        // a gesture took over; it will settle itself

    _scrollSpeed      = 0;
    _lastScrollTime   = 0;
    _haveRequestState = NO;            // force one exact pass, as at the end of a scroll
    [self updateVisibleContent];
}

// Builds the complete set of bitmaps we want right now and hands it to the
// render queue, which replaces its pending set wholesale. Anything scrolled
// past simply stops being wanted, so it is never rendered at all.
- (void)updateVisibleContent
{
    if (!_pageView || _closing) return;

    NSRect vis = [[_scrollView contentView] documentVisibleRect];
    NSRange range = [_pageView pageRangeInRect:vis];
    NSUInteger pageCount = [_source pageCount];
    if (range.length == 0 || pageCount == 0) {
        // Nothing is visible -- the view is not laid out yet, or the window has
        // been resized down to nothing. Returning without saying so left the
        // previous set pending, so the queue went on rasterising pages for a
        // geometry that no longer exists.
        [_pageCache setPinnedPages:NSMakeRange(0, 0)];
        [_pageQueue setDesiredRequests:nil];
        // And say that the recorded set no longer describes anything.
        //
        // _lastRequestRange / _haveRequestState are the record of what was last
        // asked for, and -clipBoundsChanged: skips the rebuild whenever the
        // range it computes matches them. Leaving them describing the set that
        // was just discarded means a viewport that becomes empty and then comes
        // back to the SAME page range is recognised as unchanged -- so no
        // rebuild happens, and the queue is left with nothing pending and the
        // cache with nothing pinned for pages that are on screen.
        //
        // Every other path that invalidates the request set already clears this
        // flag; this one cleared the two things the flag is a record OF and left
        // the flag alone, which is the one combination that cannot be right.
        _haveRequestState = NO;
        return;
    }

    // The cache is told what is on screen before anything is asked for, so a
    // bitmap this pass requests cannot be evicted by another bitmap the same
    // pass requests. Those two statements have to agree or neither settles:
    // this is the only place that decides which pages are visible, so it is
    // the only place that gets to say.
    [_pageCache setPinnedPages:range];

    _lastRequestRange = range;
    _haveRequestState = YES;

    NSMutableArray *reqs = [NSMutableArray array];
    NSUInteger i;

    // Express-lane accounting. At most one page is ever promoted: the one the
    // user is looking at while it is still blank. Promoting a page costs
    // roughly eight times the energy of rendering it in the background, so it
    // is armed only by a cold event (open, jump, display change), disarmed the
    // moment that page goes sharp or the user starts scrolling, and is never
    // spent on prefetch.
    // Visible pages: a cheap preview first so nothing is ever blank, then the
    // sharp bitmap. While a live scroll (or momentum) is in flight we ask only
    // for previews: rasterising full-resolution pages the user is flying past
    // is the single most wasteful thing a viewer can do to a battery.
    // The scheduler's state, decided once for the whole pass so that the
    // previews and the full-resolution bitmaps below cannot disagree about
    // whether the document is moving.
    BOOL moving = [self viewportIsMoving];

    // The rest of the pass's constants, likewise read exactly once.
    //
    // `age` in particular: -scrollSpeedAge reads the clock, and reading it per
    // page would let the first page of a pass be decided against a fresh
    // measurement and the last against a stale one, in the same wanted set,
    // from one event.
    PVRenderPolicy policy = [self currentRenderPolicy];
    double age = [self scrollSpeedAge];

    // May a full-resolution bitmap be asked for at all this pass?
    //
    // On battery this is the motion gate exactly as it was: nothing sharp while
    // the document moves, because the common case is a flick past pages nobody
    // will read. On mains power the blanket refusal is replaced by the per-page
    // cost test below -- a page that takes 11 ms is not worth withholding from
    // a scroll that will last half a second, and on a desktop there is no
    // battery for withholding it to save.
    BOOL fullsAllowed = (!moving || policy.fullRendersWhileMoving) && [self wantsFullRenders];

    for (i = range.location; i < NSMaxRange(range) && i < pageCount; i++) {
        if ([self pageIsUnrenderable:i]) continue;
        BOOL cold = (i == _expressPage);

        // Read once per page and shared by both bitmaps below, for the same
        // reason `age` is read once per pass: the geometry call is not free and,
        // more importantly, two reads could straddle a clock tick.
        double dwell  = [self secondsPageStaysVisible:i];
        CGSize fullPx = [_pageView pixelSizeForPage:i];
        CGSize prevPx = CGSizeMake(ceil(fullPx.width  / PV_PREVIEW_DIVISOR),
                                   ceil(fullPx.height / PV_PREVIEW_DIVISOR));

        if (![_pageCache hasPreviewForPage:i] &&
            ![self pageIsUnrenderable:i preview:YES]) {
            if ([self bitmapSurvivesMotion:prevPx preview:YES
                                     dwell:dwell age:age policy:policy]) {
                PVAddRequest(reqs, [PVRenderRequest page:i
                    pixels:prevPx
                    priority:PVPriorityVisiblePreview preview:YES express:cold]);
            } else {
                PVStatAdd(PVStatRequestsSuppressed, 1);
            }
        }

        // Full resolution is the expensive half: ~6x a preview, and ~28 MB of
        // pixels in the profiling window. It is asked for only when the
        // document is at rest.
        //
        // This gate used to be `!_liveScrolling && !_liveZooming`, which is a
        // question about the input device rather than about the motion. Every
        // keyboard-driven scroll therefore took the unthrottled path: the
        // profile shows 90 full renders during an 80-press Page Down flick,
        // and 126 during a 200-press arrow scroll, while the preview path
        // beside it correctly suppressed 323 and 47 requests respectively. The
        // throttle was working and reporting a healthy suppression rate for
        // the cheap half of the work while the expensive half walked past it.
        if (fullsAllowed && ![self pageIsUnrenderable:i preview:NO]) {
            if (![_pageCache fullImageForPage:i pixelSize:fullPx]) {
                if ([self bitmapSurvivesMotion:fullPx preview:NO
                                         dwell:dwell age:age policy:policy]) {
                    // A promoted full render shares the top priority band with the
                    // previews so it sorts immediately behind its own page's
                    // preview, rather than behind every other page's preview.
                    // Without this the page being read went sharp last.
                    PVAddRequest(reqs, [PVRenderRequest page:i pixels:fullPx
                                                 priority:(cold ? PVPriorityVisiblePreview
                                                                : PVPriorityVisibleFull)
                                                  preview:NO express:cold]);
                    // A sharp page asked for while the document is still moving
                    // is the cost model's other direction, and it only happens
                    // on mains power. Counted separately from the renders that
                    // were going to happen anyway, because a model that only
                    // ever suppressed would be indistinguishable in the totals
                    // from a tighter constant.
                    if (moving) PVStatAdd(PVStatCostAdmitted, 1);
                } else {
                    // Which counter this is depends on what actually refused it.
                    // A page with plenty of dwell that is withheld anyway was
                    // withheld because this document is expensive -- that is the
                    // cost model, and folding it into the dwell counter would
                    // hide the mechanism inside a number that predates it.
                    if (dwell > policy.minDwellSeconds) PVStatAdd(PVStatCostSuppressed, 1);
                    else                                PVStatAdd(PVStatRequestsSuppressed, 1);
                }
            }
        } else if (moving && PVStatsEnabled() && [self wantsFullRenders]) {
            // The motion gate above is an outer branch, so when it is closed the
            // whole full-resolution arm -- including the PVStatAdd inside it --
            // is skipped, and the gate gets no credit for the bitmaps it stopped.
            // That is why `scroll` reported zero suppressed requests while the
            // gate was doing all of the suppressing: at 3000 pt/s a page is on
            // screen for ~0.76 s, well above PV_MIN_VISIBLE_SECONDS, so the dwell
            // test that owns the other counter correctly withheld nothing.
            //
            // Counted through the non-mutating query on purpose. -fullImageForPage:
            // bumps the entry's LRU stamp, and a counter that reorders eviction
            // during every scroll would be measuring a program that only exists
            // while it is being measured.
            //
            // Behind PVStatsEnabled() so the geometry call costs nothing in the
            // shipping default, where the census is off.
            if (![_pageCache hasFullImageForPage:i pixelSize:[_pageView pixelSizeForPage:i]])
                PVStatAdd(PVStatMotionSuppressed, 1);
        }
    }

    // Prefetch a short way in the direction of travel so the next page is
    // already drawn by the time it scrolls into view. Deliberately shallow:
    // deeper prefetch buys nothing perceptible and costs battery.
    NSMutableArray *near = [NSMutableArray array];
    NSInteger first = (NSInteger)range.location;
    NSInteger last  = (NSInteger)NSMaxRange(range) - 1;
    NSInteger cand[4];
    NSInteger candCount = 0;
    if (_lastDirection >= 0) {
        cand[candCount++] = last + 1;
        cand[candCount++] = last + 2;
        cand[candCount++] = first - 1;
    } else {
        cand[candCount++] = first - 1;
        cand[candCount++] = first - 2;
        cand[candCount++] = last + 1;
    }
    NSInteger c;
    for (c = 0; c < candCount; c++) {
        if (cand[c] >= 0 && cand[c] < (NSInteger)pageCount &&
            ![self pageIsUnrenderable:(NSUInteger)cand[c]])
            [near addObject:[NSNumber numberWithInteger:cand[c]]];
    }

    NSUInteger k;
    for (k = 0; k < [near count]; k++) {
        NSUInteger p = (NSUInteger)[[near objectAtIndex:k] integerValue];
        if ([_pageCache hasPreviewForPage:p]) continue;
        if ([self pageIsUnrenderable:p preview:YES]) continue;
        CGSize px     = [_pageView pixelSizeForPage:p];
        CGSize prevPx = CGSizeMake(ceil(px.width  / PV_PREVIEW_DIVISOR),
                                   ceil(px.height / PV_PREVIEW_DIVISOR));
        // The preview's own predicted cost, not the page's. This used to go
        // through -worthRenderingDuringScroll:, which asks the device-independent
        // dwell question and knows nothing about what the bitmap costs -- fine
        // when the answer was a constant, and wrong now that a preview of a text
        // page and a preview of a vector page differ by an order of magnitude.
        if ([self bitmapSurvivesMotion:prevPx preview:YES
                                 dwell:[self secondsPageStaysVisible:p]
                                   age:age policy:policy]) {
            PVAddRequest(reqs, [PVRenderRequest page:p
                pixels:prevPx
                priority:PVPriorityNearPreview preview:YES]);
        } else {
            PVStatAdd(PVStatRequestsSuppressed, 1);
        }
    }
    // Prefetching full-resolution bitmaps is the first thing to give up when
    // the kernel says memory is short: those are the very bitmaps that were
    // just dropped, and re-rendering them is how the drop gets undone within
    // milliseconds of happening. The pages actually on screen still go sharp.
    //
    // Two further limits, both about the size of a full page bitmap rather
    // than about prefetching as an idea. `near` is ordered with the direction
    // of travel first, so taking a prefix of it takes the pages most likely to
    // be wanted next.
    //
    // Depth: PV_FULL_PREFETCH_PAGES. Three full-resolution neighbours plus the
    // pages pinned on screen did not fit the cache budget, so each one stored
    // evicted a page that was still wanted, which was then asked for again --
    // the loop -setPinnedPages: exists to prevent, reintroduced one level out
    // by prefetch rather than by the visible set.
    //
    // Motion: the same gate as the visible pages. Prefetching at full
    // resolution in the direction of a scroll is the single most expensive
    // thing to be wrong about, because the pages being guessed at are exactly
    // the ones moving fastest.
    // Depth now comes from the policy rather than straight from the constant.
    // On battery it *is* the constant; on mains power it is
    // PV_AC_FULL_PREFETCH_PAGES, and PVRenderPolicyFor has already clamped it
    // to what this machine's cache can actually hold, so a tier whose budget
    // cannot take a second prefetched page never asks for one.
    NSUInteger fullPrefetchLimit = [near count];
    if (fullPrefetchLimit > policy.fullPrefetchPages) fullPrefetchLimit = policy.fullPrefetchPages;

    if ((!moving || policy.fullRendersWhileMoving) && _hasMovedViewport &&
        [self wantsFullPrefetch]) {
        for (k = 0; k < fullPrefetchLimit; k++) {
            NSUInteger p = (NSUInteger)[[near objectAtIndex:k] integerValue];
            if ([self pageIsUnrenderable:p preview:NO]) continue;
            CGSize px = [_pageView pixelSizeForPage:p];
            if (![_pageCache fullImageForPage:p pixelSize:px]) {
                // The per-page test is not optional here the way it was while
                // this branch required `!moving`. Prefetching full-resolution
                // pages in the direction of a fast scroll is the single most
                // expensive thing in this program to be wrong about -- the pages
                // being guessed at are the ones moving fastest -- so opening the
                // branch to a moving viewport on AC has to bring the cost test
                // in with it. During a genuine flick the dwell collapses and
                // this refuses every one of them, on any power source.
                if (moving && ![self bitmapSurvivesMotion:px preview:NO
                                                    dwell:[self secondsPageStaysVisible:p]
                                                      age:age policy:policy]) {
                    PVStatAdd(PVStatCostSuppressed, 1);
                    continue;
                }
                PVAddRequest(reqs, [PVRenderRequest page:p pixels:px
                                             priority:PVPriorityNearFull preview:NO]);
                if (moving) PVStatAdd(PVStatCostAdmitted, 1);
            }
        }
    } else if (moving && PVStatsEnabled() && _hasMovedViewport && [self wantsFullPrefetch]) {
        // The same blind spot as the visible arm, on the more expensive half:
        // prefetching full-resolution pages in the direction of a fast scroll is
        // the single costliest thing to be wrong about, and until now the gate
        // that stops it appeared in no column of the profile at all.
        //
        // Only when `moving` is the condition that closed the branch. A prefetch
        // skipped because the viewport has never moved, or because the kernel
        // reported memory pressure, is a different mechanism and belongs to a
        // different number.
        for (k = 0; k < fullPrefetchLimit; k++) {
            NSUInteger p = (NSUInteger)[[near objectAtIndex:k] integerValue];
            if (![_pageCache hasFullImageForPage:p pixelSize:[_pageView pixelSizeForPage:p]])
                PVStatAdd(PVStatMotionSuppressed, 1);
        }
    }

    [_pageQueue setDesiredRequests:reqs];
    [self updatePageIndicator];
    [self updateThumbnailContent];
}

// The document's name, with the page you are on after it -- the same place
// Preview puts it, and the reason the toolbar no longer needs a text field.
//
// The name comes from the NSDocument when there is one so that it matches what
// the rest of the system calls the file, and falls back to the URL otherwise:
// the controller is also used on its own, by the tests and by any caller that
// has a source and a URL but no document.
- (NSString *)documentDisplayName
{
    NSDocument *doc = [self document];
    NSString *name = doc ? [doc displayName] : nil;
    if ([name length] == 0) name = [[_url path] lastPathComponent];
    if ([name length] == 0) name = @"Untitled";
    return name;
}

- (NSString *)titleForDisplayName:(NSString *)name
{
    NSUInteger pages = [_source pageCount];
    NSUInteger shown = (_displayedPage == NSNotFound) ? _restorePage : _displayedPage;
    if (pages == 0) return name;
    if (shown >= pages) shown = pages - 1;
    return [NSString stringWithFormat:@"%@ (page %lu of %lu)",
            name, (unsigned long)(shown + 1), (unsigned long)pages];
}

// AppKit's own hook, so that a title it decides to rebuild -- on a rename, or
// when the document is first attached -- comes out the same as one written
// here, instead of dropping the page number until the next scroll.
- (NSString *)windowTitleForDocumentDisplayName:(NSString *)displayName
{
    return [self titleForDisplayName:displayName];
}

- (void)updateWindowTitle
{
    NSWindow *w = [self window];
    if (!w || _closing) return;
    [w setTitle:[self titleForDisplayName:[self documentDisplayName]]];
}

- (void)updatePageIndicator
{
    NSUInteger page = [self currentPageWithFraction:NULL];
    if (page == _displayedPage) return;      // never rewrite the title at 60Hz
    _displayedPage = page;

    [self updateWindowTitle];
    if (_thumbView) {
        [_thumbView setCurrentPage:page];
        [self revealThumbnailForPage:page];
    }
}

#pragma mark - Render results

// The protocol's required delivery, kept so the controller still satisfies it,
// and forwarding so there is exactly one implementation of the logic. Nothing
// reaches this in the running app -- PVRenderQueue prefers the cost-carrying
// method below whenever the delegate implements it -- but a delegate that
// silently had two divergent delivery paths would be a bug waiting for whichever
// call site was changed first.
- (void)renderQueue:(PVRenderQueue *)queue
      didRenderPage:(NSUInteger)page
              image:(CGImageRef)image
          pixelSize:(CGSize)px
            preview:(BOOL)preview
{
    [self renderQueue:queue didRenderPage:page image:image pixelSize:px
              preview:preview renderSeconds:0];
}

- (void)renderQueue:(PVRenderQueue *)queue
      didRenderPage:(NSUInteger)page
              image:(CGImageRef)image
          pixelSize:(CGSize)px
            preview:(BOOL)preview
      renderSeconds:(double)renderSeconds
{
    if (_closing || !image) return;
    if (queue == _pageQueue) {
        // A full bitmap that arrives after the kernel called the machine
        // critical is exactly the bitmap the pressure handler just dropped.
        //
        // -memoryPressure: empties the full images out of the cache and stops
        // the wanted-set asking for more, but it cannot stop a rasterisation
        // that is already running: that work is inside a helper process and the
        // result is on its way. Storing it undid the release completely -- two
        // lanes could put ~56 MB straight back into a cache that had been
        // emptied one instant earlier, on a machine the kernel had just said
        // was out of memory, and nothing would remove it again until the next
        // pressure event.
        //
        // Dropped before ANY cache mutation, so the eviction pass below never
        // runs for a bitmap that is not going to be kept.
        if (!preview && ![self wantsFullRenders]) {
            // The promotion is spent either way; see the trailing-page case
            // below for the same reasoning.
            if (page == _expressPage) _expressPage = NSNotFound;
            return;
        }
        // A full bitmap for a page the viewport has already left is ~27 MB
        // that will never be drawn. Storing it is not free: it spends the
        // cache's byte budget, and paying it out evicts something that is
        // still wanted -- so the arriving bitmap for a page nobody can see
        // costs a re-render of a page somebody is looking at.
        //
        // This is the other half of cancellation. Rasterisation itself cannot
        // be interrupted: the work is one CoreGraphics call and it either
        // completes or the process dies inside it. What can be stopped is
        // starting it (the wanted set is replaced wholesale, so a page scrolled
        // past is simply never picked up) and keeping the result once it turns
        // out to be for somewhere the user no longer is.
        //
        // The window is the visible range widened by the prefetch depth on the
        // side the viewport is travelling towards, and by nothing at all behind
        // it.
        //
        // It used to be widened symmetrically, which did not match what had been
        // asked for. Prefetch only ever looks forward along _lastDirection, so
        // the page one *behind* a moving viewport was never requested at full
        // resolution -- yet an arriving bitmap for it was kept, and a full page
        // bitmap is ~28 MB against a 96 MB budget. Paying that for a page nobody
        // asked about is not a neutral choice: the bytes come out of the same
        // budget the pages on screen are competing for.
        //
        // What the trailing page keeps is its preview, which is ~1/9 the pixels
        // and is what makes scrolling back feel instant; preview retention stays
        // symmetric for exactly that reason. Reversing direction re-renders one
        // page at full resolution, which is the intended and measured cost.
        //
        // Zero on both sides until the viewport has actually moved. Before then
        // there is no direction of travel to widen along, and -updateVisibleContent
        // makes no full-resolution prefetch either, so the window is the visible
        // range and nothing outside it was ever requested.
        if (!preview && _haveRequestState) {
            // The same depth the wanted set was built with, not the constant.
            // These two numbers describe one window from opposite ends -- what
            // was asked for, and what is kept when it arrives -- so a policy
            // that prefetches two pages ahead while this kept only one would
            // rasterise the second page, drop it on the doorstep, and be asked
            // for it again on the next event. That is the most expensive
            // possible way to be inconsistent.
            NSInteger ahead = _hasMovedViewport
                ? (NSInteger)[self currentRenderPolicy].fullPrefetchPages : 0;
            NSInteger lo = (NSInteger)_lastRequestRange.location
                         - ((_lastDirection >= 0) ? 0 : ahead);
            NSInteger hi = (NSInteger)NSMaxRange(_lastRequestRange) - 1
                         + ((_lastDirection >= 0) ? ahead : 0);
            if (lo < 0) lo = 0;
            // Not counted as a suppressed request. This bitmap was asked for
            // and was rasterised; the cost has already been paid. Counting it
            // beside the requests the throttle genuinely prevented would
            // inflate the one number the profile uses to judge the throttle.
            if ((NSInteger)page < lo || (NSInteger)page > hi) {
                // The promotion is spent either way. Leaving it armed for a
                // page the viewport has left means paying raised-QoS energy
                // again the next time that page happens to come back, for a
                // user who navigated to it normally rather than one waiting on
                // it cold. The sharp-delivery path below disarms it for the
                // same reason; this is the other way that story can end.
                if (page == _expressPage) _expressPage = NSNotFound;
                return;
            }
        }
        // The measured cost goes into the cache with the bitmap, which is what
        // lets eviction prefer the page that would be expensive to rebuild over
        // the one that would be cheap, at identical bytes. See -evictExcept:.
        if (preview) [_pageCache setPreviewImage:image pixelSize:px forPage:page
                                   renderSeconds:renderSeconds];
        else         [_pageCache setFullImage:image pixelSize:px forPage:page
                                renderSeconds:renderSeconds];
        // The promotion has done its job the moment this page is sharp.
        if (!preview && page == _expressPage) _expressPage = NSNotFound;
        [_pageView setNeedsDisplayForPage:page];
    } else if (queue == _thumbQueue) {
        // The sidebar can be closed between a thumbnail being rasterised and
        // its bitmap arriving here. Storing it then quietly re-filled a cache
        // -hideSidebar had emptied one instant earlier, and it stayed filled
        // until the sidebar was next opened -- which breaks the one promise
        // the on-demand sidebar makes, that it costs nothing when put away.
        if (!_sidebarVisible) return;
        [_thumbCache setPreviewImage:image pixelSize:px forPage:page
                       renderSeconds:renderSeconds];
        [_thumbView setNeedsDisplayForPage:page];
    }
}

// CoreGraphics could not produce this bitmap. Record it so the page stops
// being asked for; without this the wanted-set names it again on the next
// scroll event and nothing ever breaks the cycle, because only a bitmap
// landing in the cache does that and none ever will.
- (void)renderQueue:(PVRenderQueue *)queue
        didFailPage:(NSUInteger)page
          pixelSize:(CGSize)px
            preview:(BOOL)preview
{
    // The queue prefers the reason-carrying method below wherever the delegate
    // implements it, so nothing in the running app arrives here. Forwarded as
    // the most conservative reading -- a page that will not draw -- because a
    // caller that could not say why is a caller with no evidence that trying
    // again would help.
    [self renderQueue:queue didFailPage:page pixelSize:px preview:preview
              failure:PVRenderFailureInvalidPage];
}

- (void)renderQueue:(PVRenderQueue *)queue
        didFailPage:(NSUInteger)page
          pixelSize:(CGSize)px
            preview:(BOOL)preview
            failure:(PVRenderFailure)failure
{
    if (_closing) return;

    // A retry has to be arranged here rather than left to the next scroll
    // event. A page that fails once while the document is stationary was
    // otherwise never asked for again -- the wanted-set is rebuilt from the
    // viewport, and a viewport that is not moving produces the same set, which
    // the early-out then declines to re-request. One transient allocation
    // failure on a page nobody scrolled past retired it for the session.
    //
    // And thumbnail failures were dropped entirely, on the grounds that a
    // missing thumbnail is cosmetic. It is, once; permanently blank because
    // nothing ever asked again is not.
    //
    // What is arranged depends on WHY. A transient failure books its own timer
    // inside -notePageFailed:..., because its backoff is longer than a settle
    // and must not be pushed forward by scrolling; a deterministic one gets the
    // settle it always got, up to the third attempt. Both end with the wanted
    // set rebuilt, which is what actually re-asks.
    if (queue == _pageQueue) {
        BOOL again = [self notePageFailed:page preview:preview
                                pixelSize:px failure:failure];
        // Nothing is going to make this page sharp, so stop paying raised-QoS
        // energy for it. Left armed, it re-promoted a doomed render every time
        // the wanted-set was rebuilt.
        if (page == _expressPage) _expressPage = NSNotFound;
        _haveRequestState = NO;

        if (again && failure == PVRenderFailureInvalidPage) [self scheduleSettle];
        else if (!again)                                    [self updateVisibleContent];
    } else if (queue == _thumbQueue) {
        BOOL again = [self noteThumbFailed:page pixelSize:px failure:failure];
        _haveThumbState = NO;
        if (again && failure == PVRenderFailureInvalidPage) [self scheduleSettle];
    }
}

#pragma mark - Notifications

- (void)clipBoundsChanged:(NSNotification *)note
{
    if (_closing || !_pageView) return;

    NSRect vis = [[_scrollView contentView] documentVisibleRect];
    CGFloat y  = NSMinY(vis);
    int dir    = _lastDirection;
    if (y > _lastScrollY + 0.5)      { dir = 1;  _hasMovedViewport = YES; }
    else if (y < _lastScrollY - 0.5) { dir = -1; _hasMovedViewport = YES; }

    // Speed, from the same two numbers that already gave direction. A gap
    // longer than half a second is not a scroll, it is two separate ones, and
    // averaging across it would report a speed that never happened.
    //
    // Monotonic, not wall clock. This used to read
    // -[NSDate timeIntervalSinceReferenceDate], which NTP steps, the user steps
    // by changing the time zone, and the system steps on waking from sleep. A
    // backward step made `dt` negative, which matched none of the branches
    // below -- so the stale speed from before the step survived untouched and
    // was then stamped with a fresh timestamp, making it look freshly measured.
    // A reading session judged as a flick suppresses every sharp page, and
    // nothing clears it until the next real scroll.
    double now = PVMonotonicSeconds();
    double dt  = now - _lastScrollTime;

    // A negative or non-finite interval means the clock, not the user. Treat
    // the previous sample as unusable rather than keeping it: no evidence is a
    // state every consumer already handles, and it is the truthful one here.
    if (_lastScrollTime > 0 && (!isfinite(dt) || dt < 0.0)) {
        _scrollSpeed = 0;
    } else if (_lastScrollTime > 0 && dt >= 0.002 && dt < 0.5) {
        double v = fabs((double)(y - _lastScrollY)) / dt;
        // A jump is not a speed; see PV_MAX_SCROLL_SPEED.
        // Seeded with the first sample rather than ramped up from zero: a
        // smoothed average starting at rest needs four or five samples to
        // reach the truth, and those are exactly the first four or five pages
        // of a flick -- the ones the throttle exists to skip.
        if (isfinite(v) && v <= PV_MAX_SCROLL_SPEED)
            _scrollSpeed = (_scrollSpeed > 0) ? (_scrollSpeed * 0.7 + v * 0.3) : v;
    } else if (_lastScrollTime > 0 && dt >= 0.5) {
        // Half a second of stillness ends a scroll. Skipping the update here
        // was not enough: the old speed stayed in the ivar, so the first move
        // after a pause was judged against how fast the *previous* scroll had
        // been going. Reading one page every few seconds after a fast flick
        // was measured as a flick. Say the resting state outright.
        _scrollSpeed = 0;
    }
    _lastScrollTime = now;
    _lastScrollY = y;

    // Movement outside a gesture scroll has nothing to announce its end, so
    // arrange for the settle pass here. Rescheduled on each movement, so it
    // fires once the movement stops. A live scroll gets -didEndLiveScroll:
    // instead and must not have a second mechanism racing it.
    if (!_liveScrolling) [self scheduleSettle];

    // This notification only arrives when the view genuinely moved, which is
    // the definition of "the user has done something since the machine last
    // said it was short of memory".
    [self noteUserActivity];

    NSRange range = [_pageView pageRangeInRect:vis];
    BOOL movingNow = [self viewportIsMoving];
    BOOL unchanged = (_haveRequestState &&
                      NSEqualRanges(range, _lastRequestRange) &&
                      dir == _lastDirection &&
                      movingNow == _lastMovingState);
    _lastDirection   = dir;
    _lastMovingState = movingNow;

    [self updatePageIndicator];

    // The desired set genuinely only changes when the visible page range, the
    // direction of travel, or the motion state changes. Rebuilding it on every
    // bounds notification meant allocating a fresh request set and taking the
    // render queue's lock 60-120 times a second to arrive at an identical
    // answer. Skipping that is invisible on screen and is pure main-thread and
    // battery savings during the app's most common interaction.
    //
    // This used to require _liveScrolling, which meant it only ever helped
    // gestures: a keyboard scroll rebuilt on all two hundred of its events.
    // The motion state had to join the comparison before that could be
    // dropped. Without it, the transition from at-rest to moving -- which
    // happens with the page range unchanged, because speed needs two samples
    // before it registers -- would be skipped, leaving the full-resolution
    // requests made while at rest sitting in the queue to be rendered during
    // the scroll. Two whole-page rasterisations cost far more than the two
    // hundred rebuilds this saves.
    if (unchanged) return;
    [self updateVisibleContent];
}

- (void)willStartLiveScroll:(NSNotification *)note
{
    _liveScrolling = YES;
    // A gesture announces its own end, so the timer would be a second
    // mechanism settling the same movement. One of them, never both.
    [self cancelSettle];
    // A new gesture starts from rest as far as this is concerned; the speed of
    // the previous one says nothing about this one.
    _scrollSpeed    = 0;
    _lastScrollTime = 0;
    // Scrolling means the user is no longer waiting on one particular page,
    // and promoting renders for pages that are flying past is exactly the
    // waste the background queue exists to avoid.
    _expressPage = NSNotFound;
}

- (void)didEndLiveScroll:(NSNotification *)note
{
    _liveScrolling = NO;
    // This method is the settle. Anything scheduled from movement that
    // preceded the gesture would only repeat it.
    [self cancelSettle];
    // Nothing is moving, so nothing is too late to be worth rendering. This
    // also means a flick that skipped everything on the way past gets a
    // complete, exact pass the instant it settles.
    _scrollSpeed      = 0;
    _lastScrollTime   = 0;
    _haveRequestState = NO;           // force one exact pass now the scroll is over
    [self updateVisibleContent];      // now fetch the sharp bitmaps
}

// The viewport changed shape: entering or leaving full screen, a window
// resize, the sidebar appearing or going away.
//
// Every zoom mode has to be laid out again here, including the two that do not
// change their zoom because of it. The page column is centred inside a
// document view that is at least as wide as the viewport, so the width is an
// input to where the pages sit even when their size is settled -- and this used
// to return early in custom and actual-size mode, leaving the document view at
// the old, narrower width. A narrower document view is placed at the left of
// its clip view, which is exactly what full screen looked like: a page hard
// against the left edge with the whole gained width empty beside it. Zooming
// in and then going full screen was enough to see it.
//
// -relayoutKeepingPage: is already correct for all four modes: -zoomForCurrentMode
// returns the unchanged zoom for custom and 1.0 for actual size, so nothing is
// recomputed that should not be, and the page and fraction the user was
// looking at are preserved either way.
// Nothing at all happens per frame of a live resize.
//
// This used to skip only -updateVisibleContent mid-drag and still run
// -currentPageWithFraction: and -relayoutKeepingPage: on every frame. Both are
// O(page count): the relayout walks every page to recompute its frame, and the
// intermediate geometry it computes is thrown away by the next frame a
// sixtieth of a second later. On a 100,000-page document that is two full
// passes over the page table per frame, on the main thread, for the entire
// duration of the drag -- so the window itself stops tracking the mouse.
//
// The frames that matter are the last one, which -windowDidEndLiveResize:
// handles, and every frame outside a drag, which still runs the pass in full.
// Mid-drag the cached bitmaps are simply stretched, which is what they were
// already doing.
- (void)scrollViewFrameChanged:(NSNotification *)note
{
    if (!_didInitialLayout || _closing) return;
    _haveRequestState = NO;
    if ([_pageView inLiveResize]) return;

    CGFloat fraction = 0;
    NSUInteger page = [self currentPageWithFraction:&fraction];
    [self relayoutKeepingPage:page fraction:fraction];
    [self updateVisibleContent];
}

// The one pass that -scrollViewFrameChanged: skipped for every step of the
// drag. Without it the geometry the user settled on was never asked for at
// full resolution, and the document stayed stretched until they scrolled.
//
// No -addObserver: for this one. It is an NSWindowDelegate method name, and
// NSWindow registers its delegate for every delegate notification the delegate
// implements. Adding a manual observer as well -- which is what the other
// window notifications here need, because their selectors deliberately differ
// from the delegate names -- registered this handler twice, so every resize
// ran the whole exact pass two times over.
- (void)windowDidEndLiveResize:(NSNotification *)note
{
    if (_closing || !_didInitialLayout) return;

    // The relayout now happens HERE rather than per frame, because
    // -scrollViewFrameChanged: no longer does it mid-drag. This is the geometry
    // the user settled on, and the only one worth computing.
    CGFloat fraction = 0;
    NSUInteger page = [self currentPageWithFraction:&fraction];
    // A page that would not rasterise at the old size is a different question
    // at the new one, so retired pages get another chance -- exactly as they do
    // after a zoom.
    [self resetRenderFailures];
    [self relayoutKeepingPage:page fraction:fraction];
    _haveRequestState = NO;
    [self updateVisibleContent];
}

// The toolbar belongs to ordinary window chrome, not to the reading surface.
// AppKit detaches it in full screen and keeps it out of the way; moving to the
// top edge is the system-standard, temporary reveal affordance.  This hook and
// AutoHideToolbar were both introduced in 10.7, so Mavericks uses the native
// path instead of a brittle manual hide/show sequence around its animation.
- (NSApplicationPresentationOptions)window:(NSWindow *)window
     willUseFullScreenPresentationOptions:(NSApplicationPresentationOptions)proposedOptions
{
    (void)window;
    return proposedOptions | NSApplicationPresentationAutoHideToolbar;
}

- (void)windowOcclusionChanged:(NSNotification *)note
{
    if (_closing) return;
    BOOL visible = ([[self window] occlusionState] & NSWindowOcclusionStateVisible) != 0;

    // Fully covered or minimised: stop rendering entirely until it comes back.
    if (!visible) {
        [_pageQueue  setSuspended:YES];
        [_thumbQueue setSuspended:YES];
        return;
    }

    // Coming back into view is a fresh start: whatever made a page fail was
    // minutes ago and is worth testing again.
    //
    // Order matters here, and used to be the other way round. -setSuspended:NO
    // pumps the queue, and the queue's pending set is still the one from before
    // the window was covered -- so unsuspending first started an obsolete
    // render, at whatever zoom and page the window had minutes ago, and
    // CGContextDrawPDFPage cannot be cancelled once it is inside a page. The
    // work the user actually wants then waits behind a full Haswell core spent
    // on a bitmap that is thrown away on arrival.
    //
    // Rebuilding the desired sets while the queues are still suspended means
    // the first thing either of them runs is already the right thing.
    _haveRequestState = NO;
    _haveThumbState   = NO;
    [self resetRenderFailures];

    [self updateVisibleContent];

    [_pageQueue  setSuspended:NO];
    [_thumbQueue setSuspended:NO];
}

- (void)backingPropertiesChanged:(NSNotification *)note
{
    if (_closing) return;
    // Dragged between a Retina and a non-Retina display: every cached bitmap is
    // now the wrong pixel size. That empties the cache, so the user is once
    // again looking at blank pages and the express lane is warranted.
    _expressPage      = [self currentPageWithFraction:NULL];
    _haveRequestState = NO;
    [self noteUserActivity];
    [self resetRenderFailures];      // every bitmap is a different size now
    [_pageCache removeAll];
    [_thumbCache removeAll];
    _haveThumbState = NO;            // and every thumbnail is a different size
    [_thumbView setBackingScale:[self backingScale]];
    CGFloat f = 0;
    NSUInteger p = [self currentPageWithFraction:&f];
    [self relayoutKeepingPage:p fraction:f];
    [_pageView setNeedsDisplay:YES];
    [_thumbView setNeedsDisplay:YES];
    [self updateVisibleContent];
}

// The kernel's pressure level, not a count of how many times it has spoken.
//
// This used to increment a counter per notification and derive the response
// from that. Two things break under it. Events coalesce, so a machine that
// goes straight to critical while this process is idle delivers ONE callback:
// the counter reads 1, which is the first-warning response, and the
// first-warning response re-renders every visible page at full resolution --
// the largest allocation the app can make, made in answer to the kernel saying
// it is nearly out of memory. And the level was never read at all, so a
// critical event and a mild warning were indistinguishable no matter how many
// arrived.
//
// The state is now the level itself. CRITICAL goes directly to the strictest
// response without having to be told twice; WARN raises the state to the first
// tier but never lowers it, so a WARN arriving after a CRITICAL does not
// promote the machine back to a state the kernel has not reported; and only a
// NORMAL event -- the kernel saying it is over -- clears it.
- (void)memoryPressure:(NSNotification *)note
{
    if (_closing) return;

    // A notification with no level is treated as a warning. That is the
    // conservative reading: it never under-reacts, and the only way to get one
    // is a poster that predates the userInfo.
    NSNumber *encoded = [[note userInfo] objectForKey:@"PVMemoryPressureFlags"];
    unsigned long flags = encoded ? [encoded unsignedLongValue]
                                  : DISPATCH_MEMORYPRESSURE_WARN;

    if (flags & DISPATCH_MEMORYPRESSURE_CRITICAL) {
        _pressureReports = 2;
    } else if (flags & DISPATCH_MEMORYPRESSURE_WARN) {
        if (_pressureReports < 1) _pressureReports = 1;
    } else if (flags & DISPATCH_MEMORYPRESSURE_NORMAL) {
        _pressureReports = 0;
    }

    // Previews survive this, so there is something to draw immediately and the
    // pages on screen do not blank. Only drop on an actual pressure event: a
    // NORMAL event is the all-clear and there is nothing to release for it.
    if (flags & (DISPATCH_MEMORYPRESSURE_WARN |
                 DISPATCH_MEMORYPRESSURE_CRITICAL)) {
        [_pageCache dropFullImages];
        [_thumbCache dropFullImages];
    }

    // Thumbnails are stored as previews and so survive the drop, but the cache
    // is free to change what it drops and the early-out must not be the thing
    // that notices last. Pressure is rare; a rebuilt wanted set costs nothing
    // here.
    _haveRequestState = NO;
    _haveThumbState = NO;

    [_pageView  setNeedsDisplay:YES];
    [_thumbView setNeedsDisplay:YES];
    [self updateVisibleContent];
}

#pragma mark - Thumbnail sidebar (built only on demand)

- (void)showSidebar
{
    if (_sidebarVisible) return;

    if (!_thumbSource) {
        NSError *err = nil;
        _thumbSource = [[PVPDFSource alloc] initWithURL:_url geometryFrom:_source error:&err];
        if (!_thumbSource) return;
        _thumbCache = [[PVImageCache alloc] initWithBudget:PVThumbCacheBudget()];
        // One lane, explicitly. A thumbnail is ~1/100 the pixels of a page, so
        // the strip has never been what a reader waits on; a second lane here
        // would spend a second PVPDFSource and a second helper process
        // parallelising the cheap half of the work.
        _thumbQueue = [[PVRenderQueue alloc] initWithSource:_thumbSource
                                                      label:"com.postview.render.thumbs"
                                                   maxLanes:1];
        if (!_thumbCache || !_thumbQueue) {
            [_thumbQueue release]; _thumbQueue = nil;
            [_thumbCache release]; _thumbCache = nil;
            [_thumbSource release]; _thumbSource = nil;
            return;
        }
        [_thumbQueue setDelegate:self];
        _thumbView = [[PVThumbStripView alloc] initWithSource:_thumbSource cache:_thumbCache];
        if (!_thumbView) {
            [_thumbQueue setDelegate:nil]; [_thumbQueue shutdown];
            [_thumbQueue release]; _thumbQueue = nil;
            [_thumbCache release]; _thumbCache = nil;
            [_thumbSource release]; _thumbSource = nil;
            return;
        }
        [_thumbView setDelegate:self];
        [_thumbView setBackingScale:[self backingScale]];

        _thumbScrollView = [[NSScrollView alloc] initWithFrame:
            NSMakeRect(0, 0, [_thumbView requiredWidth] + 16, NSHeight([_splitView bounds]))];
        if (!_thumbScrollView) {
            [_thumbView setDelegate:nil]; [_thumbView release]; _thumbView = nil;
            [_thumbQueue setDelegate:nil]; [_thumbQueue shutdown];
            [_thumbQueue release]; _thumbQueue = nil;
            [_thumbCache release]; _thumbCache = nil;
            [_thumbSource release]; _thumbSource = nil;
            return;
        }
        [_thumbScrollView setHasVerticalScroller:YES];
        [_thumbScrollView setHasHorizontalScroller:NO];
        [_thumbScrollView setAutohidesScrollers:YES];
        [_thumbScrollView setBorderType:NSNoBorder];
        [_thumbScrollView setDrawsBackground:YES];
        [_thumbScrollView setBackgroundColor:[NSColor colorWithCalibratedWhite:0.90 alpha:1.0]];
        [_thumbScrollView setDocumentView:_thumbView];
        [[_thumbScrollView contentView] setPostsBoundsChangedNotifications:YES];
        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(thumbBoundsChanged:)
                name:NSViewBoundsDidChangeNotification
              object:[_thumbScrollView contentView]];
    }

    [_splitView addSubview:_thumbScrollView positioned:NSWindowBelow relativeTo:_scrollView];
    [_splitView setPosition:[_thumbView requiredWidth] + 16 ofDividerAtIndex:0];
    _sidebarVisible = YES;

    NSUInteger p = [self currentPageWithFraction:NULL];
    [_thumbView setCurrentPage:p];
    [self revealThumbnailForPage:p];
    [self updateThumbnailContent];
}

// Putting the sidebar away tears it down completely.
//
// It used to release the thumbnail BITMAPS and keep everything that made them:
// a second PVPDFSource -- its own snapshot handle, its own helper process, its
// own geometry table, one CGSize per page -- plus a render queue with a
// dispatch queue and a worker, a cache, the strip view with a label per page,
// the scroll view, and a bounds observer. All of it stayed until the document
// closed, for a sidebar the user has explicitly dismissed. On a large document
// the geometry table alone is megabytes, and the helper process is a whole
// second process sitting idle.
//
// -showSidebar already rebuilds every one of those from nothing when
// _thumbSource is nil, which is the state this leaves behind, so reopening
// costs one construction rather than being free -- and that is the right trade
// for something that is closed far more often than it is reopened.
//
// Safe with a render in flight: -shutdown makes the queue drop its results, and
// the worker block retains the queue, so the object outlives whatever it
// started. The delegate is cleared first so nothing is delivered to a
// controller that has already let go of the cache the result would go into.
- (void)hideSidebar
{
    if (!_sidebarVisible) return;
    _sidebarVisible = NO;

    // Before the scroll view goes: the observer is registered against its clip
    // view, and an observer left registered against a released object is the
    // one thing here that would not merely waste memory.
    NSClipView *clip = [_thumbScrollView contentView];
    if (clip) {
        [[NSNotificationCenter defaultCenter]
            removeObserver:self
                      name:NSViewBoundsDidChangeNotification
                    object:clip];
    }

    [_thumbScrollView removeFromSuperview];
    [_splitView adjustSubviews];

    [_thumbQueue setDelegate:nil];
    [_thumbQueue shutdown];
    [_thumbView setDelegate:nil];
    [_thumbCache removeAll];
    [_thumbScrollView setDocumentView:nil];

    [_thumbScrollView release]; _thumbScrollView = nil;
    [_thumbView release];       _thumbView = nil;
    [_thumbQueue release];      _thumbQueue = nil;
    [_thumbCache release];      _thumbCache = nil;
    [_thumbSource release];     _thumbSource = nil;

    // Reopening at the page it was closed on gives the identical visible range,
    // and without this the early-out in -updateThumbnailContent would recognise
    // it and decline to ask for bitmaps that no longer exist -- a sidebar of
    // empty boxes until something else moved it.
    _haveThumbState = NO;
}

- (void)thumbBoundsChanged:(NSNotification *)note
{
    if (_closing) return;
    [self updateThumbnailContent];
}

- (void)updateThumbnailContent
{
    if (!_sidebarVisible || !_thumbView || _closing) return;
    NSRect vis = [[_thumbScrollView contentView] documentVisibleRect];
    NSRange range = [_thumbView pageRangeInRect:NSInsetRect(vis, 0, -PV_THUMB_BOX_H)];

    // The wanted set for the strip is a pure function of which thumbnails are
    // visible, so an identical range gives an identical answer. Dragging the
    // strip posts a bounds notification per frame; without this each one walks
    // the visible thumbnails, allocates a request array and takes the thumbnail
    // queue's lock to arrive at the set already pending. This is the same
    // early-out -clipBoundsChanged: has for the page view, and it is a smaller
    // saving only because a thumbnail request is smaller -- the frequency is
    // the same.
    //
    // No motion or direction term here, unlike the page view's. The strip asks
    // for previews and nothing else, so there is no expensive arm for a motion
    // state to gate, and nothing that a change of direction would reorder.
    //
    // Same rule as the page cache: a thumbnail on screen is one that will be
    // asked for again the moment it is thrown away. Stated before the early-out
    // and on every path through here, because it is a struct assignment and
    // because a pin that is only refreshed when the wanted set changes is a pin
    // that goes stale exactly when the strip is sitting still.
    [_thumbCache setPinnedPages:range];

    if (_haveThumbState && NSEqualRanges(range, _lastThumbRange)) return;
    _lastThumbRange = range;
    _haveThumbState = YES;
    NSMutableArray *reqs = [NSMutableArray array];
    NSUInteger i;
    for (i = range.location; i < NSMaxRange(range) && i < [_source pageCount]; i++) {
        if ([_thumbCache hasPreviewForPage:i]) continue;
        if ([self thumbIsUnrenderable:i]) continue;
        PVAddRequest(reqs, [PVRenderRequest page:i
                                       pixels:[_thumbView pixelSizeForPage:i]
                                     priority:PVPriorityVisiblePreview preview:YES]);
    }
    [_thumbQueue setDesiredRequests:reqs];
}

- (void)revealThumbnailForPage:(NSUInteger)page
{
    if (!_sidebarVisible || !_thumbView) return;
    NSRect r   = [_thumbView rectForPage:page];
    NSRect vis = [[_thumbScrollView contentView] documentVisibleRect];
    if (NSMinY(r) >= NSMinY(vis) && NSMaxY(r) <= NSMaxY(vis)) return;   // already shown
    [_thumbView scrollRectToVisible:NSInsetRect(r, 0, -PV_THUMB_GAP)];
}

- (void)thumbStrip:(PVThumbStripView *)strip didChoosePage:(NSUInteger)page
{
    if (![_pageCache hasAnyImageForPage:page] && ![self pageIsUnrenderable:page])
        _expressPage = page;
    _haveRequestState = NO;
    [self noteUserActivity];
    [self scrollToPage:page fraction:0];
    [self updateVisibleContent];
}

#pragma mark - Pinch to zoom

// Hold one point of the document under one point of the viewport across a
// change of zoom.
//
// Expressed as a page plus a fraction into it rather than as a scroll offset,
// because the offset is not a pure multiple of the zoom: the gaps between
// pages are a constant number of points whatever the zoom is, so scaling the
// old offset drifts by one gap per page and the document creeps under the
// fingers on a long pinch.
- (void)restoreMagnifyAnchor
{
    NSClipView *clip = [_scrollView contentView];
    NSRect r = [_pageView rectForPage:_magnifyPage];
    if (NSIsEmptyRect(r)) return;

    CGFloat y = NSMinY(r) + _magnifyFractionY * NSHeight(r) - _magnifyViewportOffset.y;
    CGFloat x = NSMinX(r) + _magnifyFractionX * NSWidth(r)  - _magnifyViewportOffset.x;

    NSRect cb = [clip bounds];
    CGFloat maxY = NSHeight([_pageView frame]) - NSHeight(cb);
    CGFloat maxX = NSWidth([_pageView frame])  - NSWidth(cb);
    if (y > maxY) y = maxY;
    if (y < 0)    y = 0;
    // Narrower than the viewport: the column is centred, so there is nothing
    // to choose and following the fingers sideways would only jitter.
    if (maxX <= 0) x = 0;
    else {
        if (x > maxX) x = maxX;
        if (x < 0)    x = 0;
    }

    [self scrollClipTo:NSMakePoint(x, y)];
}

- (void)pageViewWillMagnify:(PVPageView *)view atPoint:(NSPoint)pointInView
{
    if (_closing) return;
    _liveZooming = YES;

    NSRect vis = [[_scrollView contentView] documentVisibleRect];
    NSRange range = [_pageView pageRangeInRect:NSMakeRect(pointInView.x, pointInView.y, 1, 1)];
    _magnifyPage = (range.length > 0) ? range.location : [self currentPageWithFraction:NULL];

    NSRect r = [_pageView rectForPage:_magnifyPage];
    _magnifyFractionY = (NSHeight(r) > 0) ? (pointInView.y - NSMinY(r)) / NSHeight(r) : 0;
    _magnifyFractionX = (NSWidth(r)  > 0) ? (pointInView.x - NSMinX(r)) / NSWidth(r)  : 0.5;
    if (!isfinite(_magnifyFractionY)) _magnifyFractionY = 0;
    if (!isfinite(_magnifyFractionX)) _magnifyFractionX = 0.5;
    _magnifyViewportOffset = NSMakePoint(pointInView.x - NSMinX(vis),
                                         pointInView.y - NSMinY(vis));

    // Whatever the queue is working on is for a size that is about to stop
    // existing. Saying so now is cheaper than letting it finish.
    [_pageQueue setDesiredRequests:nil];
}

- (void)pageView:(PVPageView *)view magnifyBy:(CGFloat)factor
{
    if (_closing || !_liveZooming) return;
    CGFloat z = _zoom * factor;
    if (!isfinite(z)) return;
    if (z < PV_MIN_ZOOM) z = PV_MIN_ZOOM;
    if (z > PV_MAX_ZOOM) z = PV_MAX_ZOOM;
    if (z == _zoom) return;

    _zoomMode = PVZoomModeCustom;
    _zoom     = z;
    [_pageView setZoom:z
          backingScale:[self backingScale]
        containerWidth:[self viewportSize].width];
    [self restoreMagnifyAnchor];
    [self updatePageIndicator];
}

- (void)pageViewDidMagnify:(PVPageView *)view
{
    if (!_liveZooming) return;
    _liveZooming = NO;
    if (_closing) return;
    _haveRequestState = NO;
    [self noteUserActivity];
    // Every bitmap is a different size now, which is a genuinely different
    // question to put to CoreGraphics.
    [self resetRenderFailures];
    [self updateVisibleContent];
}

// Two-finger double tap, the way Preview treats it: if the page is small, fill
// the width; if it is already filling it, put it back to actual size.
- (void)pageViewSmartMagnify:(PVPageView *)view atPoint:(NSPoint)pointInView
{
    if (_closing) return;
    if (_zoomMode == PVZoomModeFitWidth) [self zoomActualSize:nil];
    else                                 [self zoomFitWidth:nil];
}

#pragma mark - Split view

- (CGFloat)splitView:(NSSplitView *)sv constrainMinCoordinate:(CGFloat)p ofSubviewAt:(NSInteger)i
{
    return 96;
}
- (CGFloat)splitView:(NSSplitView *)sv constrainMaxCoordinate:(CGFloat)p ofSubviewAt:(NSInteger)i
{
    return 260;
}
- (BOOL)splitView:(NSSplitView *)sv shouldAdjustSizeOfSubview:(NSView *)subview
{
    return (subview != _thumbScrollView);    // sidebar keeps its width on resize
}

#pragma mark - Actions

- (IBAction)toggleSidebar:(id)sender
{
    if (_sidebarVisible) [self hideSidebar]; else [self showSidebar];
}

- (void)applyZoomMode:(PVZoomMode)mode zoom:(CGFloat)zoom
{
    CGFloat f = 0;
    NSUInteger p = [self currentPageWithFraction:&f];
    _zoomMode = mode;
    if (mode == PVZoomModeCustom) _zoom = zoom;
    _haveRequestState = NO;
    [self noteUserActivity];
    // Every bitmap is about to be requested at a different pixel size, which is
    // a genuinely different question to put to CoreGraphics.
    [self resetRenderFailures];
    [self relayoutKeepingPage:p fraction:f];
    [self updateVisibleContent];
}

- (IBAction)zoomIn:(id)sender
{
    int i;
    for (i = 0; i < kZoomStepCount; i++)
        if (kZoomSteps[i] > _zoom + 0.001) { [self applyZoomMode:PVZoomModeCustom zoom:kZoomSteps[i]]; return; }
    [self applyZoomMode:PVZoomModeCustom zoom:PV_MAX_ZOOM];
}

- (IBAction)zoomOut:(id)sender
{
    int i;
    for (i = kZoomStepCount - 1; i >= 0; i--)
        if (kZoomSteps[i] < _zoom - 0.001) { [self applyZoomMode:PVZoomModeCustom zoom:kZoomSteps[i]]; return; }
    [self applyZoomMode:PVZoomModeCustom zoom:PV_MIN_ZOOM];
}

- (IBAction)zoomActualSize:(id)sender { [self applyZoomMode:PVZoomModeActual   zoom:1.0]; }
- (IBAction)zoomFitWidth:(id)sender   { [self applyZoomMode:PVZoomModeFitWidth zoom:_zoom]; }
- (IBAction)zoomFitPage:(id)sender    { [self applyZoomMode:PVZoomModeFitPage  zoom:_zoom]; }

- (void)goToPageNumber:(NSInteger)oneBased
{
    NSUInteger pageCount = [_source pageCount];
    if (pageCount == 0) return;
    if (oneBased < 1) oneBased = 1;
    if (oneBased > (NSInteger)pageCount) oneBased = (NSInteger)pageCount;
    NSUInteger target = (NSUInteger)(oneBased - 1);
    // A deliberate jump lands on a page that is usually not cached, and the
    // user is watching that exact spot: same justification as opening a file.
    if (![_pageCache hasAnyImageForPage:target] && ![self pageIsUnrenderable:target])
        _expressPage = target;
    _haveRequestState = NO;
    [self noteUserActivity];
    [self scrollToPage:target fraction:0];
    [self updateVisibleContent];
}

- (IBAction)goToPageDialog:(id)sender
{
    // A sheet needs something to hang from. -window is declared nullable and
    // -beginSheetModalForWindow: is not, so the one case where they disagree
    // is worth saying out loud rather than leaving to AppKit.
    NSWindow *host = [self window];
    if (!host || _closing) return;

    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert setMessageText:@"Go to Page"];
    [alert setInformativeText:[NSString stringWithFormat:@"Enter a page number between 1 and %lu.",
                               (unsigned long)[_source pageCount]]];
    [alert addButtonWithTitle:@"Go"];
    [alert addButtonWithTitle:@"Cancel"];

    NSTextField *input = [[[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)] autorelease];
    [input setStringValue:[NSString stringWithFormat:@"%lu",
                           (unsigned long)([self currentPageWithFraction:NULL] + 1)]];
    [alert setAccessoryView:input];
    [[alert window] setInitialFirstResponder:input];

    [alert beginSheetModalForWindow:host completionHandler:^(NSModalResponse response) {
        // The sheet can outlive the window it is attached to if the document is
        // closed underneath it; acting on a torn-down controller here would be
        // a use-after-free.
        if (_closing) return;
        if (response == NSAlertFirstButtonReturn) {
            // -stringValue rather than -integerValue so a still-editing field counts.
            [self goToPageNumber:[[input stringValue] integerValue]];
        }
        [[self window] makeFirstResponder:_pageView];
    }];
}

- (IBAction)goToNextPage:(id)sender
{
    [self goToPageNumber:(NSInteger)[self currentPageWithFraction:NULL] + 2];
}
- (IBAction)goToPreviousPage:(id)sender
{
    [self goToPageNumber:(NSInteger)[self currentPageWithFraction:NULL]];
}
- (IBAction)goToFirstPage:(id)sender { [self goToPageNumber:1]; }
- (IBAction)goToLastPage:(id)sender  { [self goToPageNumber:(NSInteger)[_source pageCount]]; }

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    SEL action = [item action];
    if (action == @selector(toggleSidebar:)) {
        [item setTitle:_sidebarVisible ? @"Hide Thumbnails" : @"Show Thumbnails"];
        return YES;
    }
    if (action == @selector(goToNextPage:))
        return [self currentPageWithFraction:NULL] + 1 < [_source pageCount];
    if (action == @selector(goToPreviousPage:))
        return [self currentPageWithFraction:NULL] > 0;
    if (action == @selector(zoomIn:))  return _zoom < PV_MAX_ZOOM - 0.001;
    if (action == @selector(zoomOut:)) return _zoom > PV_MIN_ZOOM + 0.001;
    return YES;
}

#pragma mark - Toolbar

// Two items, leading-aligned, and nothing else -- the same shape Preview has.
//
// This used to be five: the two controls, a page field, and a pair of flexible
// spaces with an inert counterweight to balance them, all of it there to hold
// the page field in the middle of the window across a decade of AppKit. The
// page number now lives in the window title, where the system centres it for
// free and it does not have to look like a control at all, so the entire
// apparatus went with it -- including -setCenteredItemIdentifier:, which
// existed only to keep that one item centred from Big Sur onwards.
- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar
{
    // Two items, and nothing to arrange them with.
    //
    // Where they end up is the system's decision and differs by release: 10.9
    // puts the title on its own row and packs the items from the left, while
    // macOS 11 and later share one row, give the leading region to the title
    // and lay the items out trailing. Both are that release's own convention,
    // and each looks right on the system that chose it.
    //
    // Measured rather than assumed, because this is where the old toolbar
    // spent most of its complexity. With the items alone AppKit places them at
    // x=788 in a 900-point window on macOS 26 and hard left on 10.9; a
    // trailing flexible space moves that to 780, which is to say it does
    // nothing except add an item. The only setting that forces them leading on
    // a current system is the preference-window toolbar style, which also
    // takes the document title out of the title bar -- a considerably worse
    // trade than letting each release place two buttons where it puts
    // everyone else's.
    return [NSArray arrayWithObjects:PVToolbarSidebar, PVToolbarZoom, nil];
}
- (NSArray *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar
{
    return [self toolbarDefaultItemIdentifiers:toolbar];
}

// Give a control its natural width and the one standard toolbar height.  The
// custom-item wrapper makes AppKit's layout deterministic across releases;
// explicitly applying the height to the child itself matters on Mavericks,
// where different control classes otherwise draw at different native heights
// even inside equal-sized wrappers.
static NSView *PVToolbarBox(NSControl *control)
{
    [control sizeToFit];
    NSRect f = [control frame];
    f.size.height = PV_TOOLBAR_ITEM_H;
    f.origin = NSZeroPoint;
    [control setFrame:f];

    NSView *box = [[[NSView alloc] initWithFrame:
        NSMakeRect(0, 0, f.size.width, PV_TOOLBAR_ITEM_H)] autorelease];
    [box addSubview:control];
    return box;
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar
     itemForItemIdentifier:(NSString *)identifier
 willBeInsertedIntoToolbar:(BOOL)flag
{
    NSToolbarItem *item = [[[NSToolbarItem alloc] initWithItemIdentifier:identifier] autorelease];

    if ([identifier isEqualToString:PVToolbarSidebar]) {
        // One segment of the same control class and style as the +/- item.
        // Besides making the two controls a visual set, this removes the
        // Mavericks-only mismatch where a textured NSButton bezel was taller
        // than a textured NSSegmentedControl bezel.
        NSSegmentedControl *b = [[[NSSegmentedControl alloc] initWithFrame:
            NSMakeRect(0, 0, PV_TOOLBAR_ICON + 16, PV_TOOLBAR_ITEM_H)] autorelease];
        [b setSegmentCount:1];
        [b setSegmentStyle:NSSegmentStyleTexturedRounded];
        // Through the cell, not the control: -[NSControl setControlSize:] was
        // only added in 10.10, and the deployment target is 10.9. The cell has
        // carried it since 10.0 and is what the newer control method forwards
        // to, so this is the same setting by its older name.
        [[b cell] setControlSize:NSSmallControlSize];
        [[b cell] setTrackingMode:NSSegmentSwitchTrackingMomentary];
        NSImage *icon = PVToolbarImageNamed(@"TB_contentAndThumbs");
        if (icon) {
            [b setImage:icon forSegment:0];
        } else {
            // A missing asset must not ship a blank button.
            [b setLabel:@"Pages" forSegment:0];
        }
        [b setWidth:(PV_TOOLBAR_ICON + 16) forSegment:0];
        [b setTarget:self];
        [b setAction:@selector(toggleSidebar:)];
        [item setView:PVToolbarBox(b)];
        [item setLabel:@"Thumbnails"];
        [item setPaletteLabel:@"Thumbnails"];
        [item setToolTip:@"Show or hide page thumbnails"];

    } else if ([identifier isEqualToString:PVToolbarZoom]) {
        NSSegmentedControl *seg =
            [[[NSSegmentedControl alloc] initWithFrame:
                NSMakeRect(0, 0, 2 * (PV_TOOLBAR_ICON + 14), PV_TOOLBAR_ITEM_H)] autorelease];
        [seg setSegmentCount:2];
        [seg setSegmentStyle:NSSegmentStyleTexturedRounded];
        [[seg cell] setControlSize:NSSmallControlSize];
        [[seg cell] setTrackingMode:NSSegmentSwitchTrackingMomentary];

        NSImage *out = PVToolbarImageNamed(@"TB_zoomOut");
        NSImage *in  = PVToolbarImageNamed(@"TB_zoomIn");
        if (out && in) {
            [seg setImage:out forSegment:0];
            [seg setImage:in  forSegment:1];
        } else {
            [seg setLabel:@"\u2212" forSegment:0];
            [seg setLabel:@"+"       forSegment:1];
        }
        // Width per segment stated, height left to the control: the bezel is
        // the part that was being clipped, and only the control knows how much
        // of it there is on the system in front of it.
        [seg setWidth:(PV_TOOLBAR_ICON + 14) forSegment:0];
        [seg setWidth:(PV_TOOLBAR_ICON + 14) forSegment:1];
        [seg setTarget:self];
        [seg setAction:@selector(zoomSegmentChanged:)];
        [item setView:PVToolbarBox(seg)];
        [item setLabel:@"Zoom"];
        [item setPaletteLabel:@"Zoom"];
        [item setToolTip:@"Zoom out or in"];
    }

    NSView *v = [item view];
    if (v) {
        // Pin the size explicitly. A custom-view NSToolbarItem with no
        // min/max size is laid out by rules that have changed several times
        // between 10.9 and 26; stating the size removes the variable.
        [item setMinSize:[v frame].size];
        [item setMaxSize:[v frame].size];
    }
    return item;
}

- (IBAction)zoomSegmentChanged:(id)sender
{
    if ([sender selectedSegment] == 0) [self zoomOut:sender];
    else                               [self zoomIn:sender];
}

#pragma mark - Saving position

- (void)saveState
{
    if (!_url || !_didInitialLayout) return;
    CGFloat f = 0;
    NSUInteger p = [self currentPageWithFraction:&f];
    [[PVStateStore sharedStore] recordForURL:_url
                                        page:p
                                    fraction:f
                                    zoomMode:_zoomMode
                                        zoom:_zoom
                                     sidebar:_sidebarVisible
                                 windowFrame:[[self window] stringWithSavedFrame]];
}

- (void)windowWillClose:(NSNotification *)note
{
    if (_closing) return;
    _closing = YES;

    [self saveState];
    [[PVStateStore sharedStore] flush];

    [self teardownReferences];
    // Bitmaps go now rather than at dealloc: a document can outlive its window
    // by a few runloop turns -- NSDocument retires its controllers on its own
    // schedule -- and there is no reason to hold tens of megabytes through it.
    [_pageCache  removeAll];
    [_thumbCache removeAll];
}

@end
