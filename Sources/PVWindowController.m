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
@end

@implementation PVWindowController

#pragma mark - Setup

- (id)initWithSource:(PVPDFSource *)source url:(NSURL *)url
{
    if (!source) return nil;
    NSRect frame = NSMakeRect(0, 0, 900, 760);
    NSUInteger style = (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                        NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable);
    NSWindow *window = [[[NSWindow alloc] initWithContentRect:frame
                                                    styleMask:style
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO] autorelease];
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

    self = [super initWithWindow:window];
    if (!self) return nil;

    PVLiveAdjust("PVWindowController", +1);
    _url       = [url copy];
    _source    = [source retain];
    _pageCache = [[PVImageCache alloc] initWithBudget:PVPageCacheBudget()];
    _pageQueue = [[PVRenderQueue alloc] initWithSource:_source label:"com.postview.render.pages"];
    if (!_pageCache || !_pageQueue) { [self release]; return nil; }
    [_pageQueue setDelegate:self];

    _zoomMode        = PVZoomModeFitWidth;
    _zoom            = 1.0;
    _restorePage     = 0;
    _restoreFraction = 0.0;
    _restoreSidebar  = NO;
    _displayedPage   = NSNotFound;
    _expressPage     = NSNotFound;
    _lastDirection   = 1;

    [self loadSavedStateIntoWindow:window];
    [self buildInterface];

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

- (void)buildInterface
{
    NSWindow *window = [self window];

    // The window's whole surface accepts a dropped PDF: the page, the sidebar,
    // the grey margin, the lot. Done by making the content view the drop
    // target rather than by registering some control inside it -- AppKit finds
    // a destination by hit-testing and then walking up the view hierarchy, so
    // everything that does not claim a drag of its own ends up here.
    PVDropView *drop = [[[PVDropView alloc] initWithFrame:
                            [[window contentView] frame]] autorelease];
    [drop setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [window setContentView:drop];

    NSRect content = [[window contentView] bounds];

    _splitView = [[NSSplitView alloc] initWithFrame:content];
    [_splitView setVertical:YES];
    [_splitView setDividerStyle:NSSplitViewDividerStyleThin];
    [_splitView setDelegate:self];
    [_splitView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

    _scrollView = [[NSScrollView alloc] initWithFrame:content];
    [_scrollView setHasVerticalScroller:YES];
    [_scrollView setHasHorizontalScroller:YES];
    [_scrollView setAutohidesScrollers:YES];
    [_scrollView setBorderType:NSNoBorder];
    [_scrollView setDrawsBackground:YES];
    [_scrollView setBackgroundColor:[NSColor colorWithCalibratedWhite:0.42 alpha:1.0]];
    [_scrollView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [_scrollView setPostsFrameChangedNotifications:YES];

    _pageView = [[PVPageView alloc] initWithSource:_source cache:_pageCache];
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
}

// Everything that holds an unretained pointer back to this controller is
// cleared here as well as in -windowWillClose:. The close path is the normal
// one, but a controller can be released without its window ever closing (an
// open that fails after the window is built, a document torn down before it is
// shown), and in that case each of these was left pointing at freed memory.
- (void)teardownReferences
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    // Before anything else it could still fire into. An NSTimer retains its
    // target, so a live one here is both a use-after-teardown and a leak of
    // the whole controller graph behind it.
    [self cancelSettle];

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
    [_renderFailures release];
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

    [clip scrollToPoint:NSMakePoint(floor(x + 0.5), floor(y + 0.5))];
    [_scrollView reflectScrolledClipView:clip];
    _lastScrollY = y;
}

#pragma mark - Unrenderable pages

// Three attempts, then the page is left alone. One is too few -- a bitmap
// context that could not be allocated under a momentary spike deserves another
// go -- and an unbounded number is the bug this exists to close.
#define PV_MAX_RENDER_ATTEMPTS 3
// A document broken enough to fill this table is broken enough that there is
// nothing useful left to remember about it, and the table must not become the
// unbounded thing it was added to prevent.
#define PV_MAX_FAILED_PAGES    512

- (BOOL)pageIsUnrenderable:(NSUInteger)page
{
    if (!_renderFailures) return NO;
    NSNumber *n = [_renderFailures objectForKey:
                      [NSNumber numberWithUnsignedLongLong:(unsigned long long)page]];
    return (n && [n intValue] >= PV_MAX_RENDER_ATTEMPTS);
}

- (void)notePageFailed:(NSUInteger)page
{
    if (!_renderFailures) _renderFailures = [[NSMutableDictionary alloc] init];
    NSNumber *key  = [NSNumber numberWithUnsignedLongLong:(unsigned long long)page];
    NSNumber *seen = [_renderFailures objectForKey:key];
    // The cap bounds the table without ever losing sight of a page already in
    // it, so no page can slip its attempt limit by failing late.
    if (!seen && [_renderFailures count] >= PV_MAX_FAILED_PAGES) return;
    [_renderFailures setObject:[NSNumber numberWithInt:[seen intValue] + 1] forKey:key];
}

// Called for anything that changes the question being asked of CoreGraphics --
// a different pixel size, an emptied cache, a window that has come back into
// view after the machine calmed down. Retrying then is worth it; retrying on
// every scroll event is what had to stop.
- (void)resetRenderFailures
{
    if ([_renderFailures count] > 0) [_renderFailures removeAllObjects];
}

// The user has done something, so whatever the machine was complaining about
// a moment ago is worth re-testing. Seven different events mean this and each
// used to say so in its own words; stating it once is what keeps the pressure
// backoff and the prefetch suppression from drifting apart.
- (void)noteUserActivity
{
    _pressureReports = 0;
}

// Prefetching full-resolution bitmaps is the first thing to give up under
// memory pressure: those are the very bitmaps that were just dropped.
- (BOOL)wantsFullPrefetch  { return (_pressureReports == 0); }

// Full-resolution rendering of the pages actually on screen survives one
// pressure report and stops at the second. See _pressureReports.
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
    return (_lastScrollTime > 0)
         ? ([NSDate timeIntervalSinceReferenceDate] - _lastScrollTime)
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

    for (i = range.location; i < NSMaxRange(range) && i < pageCount; i++) {
        if ([self pageIsUnrenderable:i]) continue;
        BOOL cold = (i == _expressPage);

        // Asked once per page and used for both bitmaps below. Two calls would
        // repeat the geometry and, more importantly, could answer differently
        // either side of a clock tick.
        BOOL survives = [self pageSurvivesMotion:i];

        if (![_pageCache hasPreviewForPage:i]) {
            if (survives) {
                CGSize px = [_pageView pixelSizeForPage:i];
                [reqs addObject:[PVRenderRequest page:i
                    pixels:CGSizeMake(ceil(px.width / PV_PREVIEW_DIVISOR),
                                      ceil(px.height / PV_PREVIEW_DIVISOR))
                    priority:PVPriorityVisiblePreview preview:YES express:cold]];
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
        if (!moving && [self wantsFullRenders]) {
            CGSize px = [_pageView pixelSizeForPage:i];
            if (![_pageCache fullImageForPage:i pixelSize:px]) {
                if (survives) {
                    // A promoted full render shares the top priority band with the
                    // previews so it sorts immediately behind its own page's
                    // preview, rather than behind every other page's preview.
                    // Without this the page being read went sharp last.
                    [reqs addObject:[PVRenderRequest page:i pixels:px
                                                 priority:(cold ? PVPriorityVisiblePreview
                                                                : PVPriorityVisibleFull)
                                                  preview:NO express:cold]];
                } else {
                    PVStatAdd(PVStatRequestsSuppressed, 1);
                }
            }
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
        if (![_pageCache hasPreviewForPage:p] && [self worthRenderingDuringScroll:p]) {
            CGSize px = [_pageView pixelSizeForPage:p];
            [reqs addObject:[PVRenderRequest page:p
                pixels:CGSizeMake(ceil(px.width / PV_PREVIEW_DIVISOR),
                                  ceil(px.height / PV_PREVIEW_DIVISOR))
                priority:PVPriorityNearPreview preview:YES]];
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
    if (!moving && _hasMovedViewport && [self wantsFullPrefetch]) {
        NSUInteger limit = [near count];
        if (limit > PV_FULL_PREFETCH_PAGES) limit = PV_FULL_PREFETCH_PAGES;
        for (k = 0; k < limit; k++) {
            NSUInteger p = (NSUInteger)[[near objectAtIndex:k] integerValue];
            CGSize px = [_pageView pixelSizeForPage:p];
            if (![_pageCache fullImageForPage:p pixelSize:px]) {
                [reqs addObject:[PVRenderRequest page:p pixels:px
                                             priority:PVPriorityNearFull preview:NO]];
            }
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

- (void)renderQueue:(PVRenderQueue *)queue
      didRenderPage:(NSUInteger)page
              image:(CGImageRef)image
          pixelSize:(CGSize)px
            preview:(BOOL)preview
{
    if (_closing || !image) return;
    if (queue == _pageQueue) {
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
        // The window is the visible range widened by the prefetch depth,
        // because the pages prefetched in the direction of travel are outside
        // the visible range by construction and are exactly the ones worth
        // keeping. Previews are exempt: at ~1/9 the pixels they are what makes
        // scrolling back instant, and dropping them would cost more renders
        // than it saves bytes.
        if (!preview && _haveRequestState) {
            NSInteger lo = (NSInteger)_lastRequestRange.location - PV_FULL_PREFETCH_PAGES;
            NSInteger hi = (NSInteger)NSMaxRange(_lastRequestRange) - 1 + PV_FULL_PREFETCH_PAGES;
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
        if (preview) [_pageCache setPreviewImage:image pixelSize:px forPage:page];
        else         [_pageCache setFullImage:image pixelSize:px forPage:page];
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
        [_thumbCache setPreviewImage:image pixelSize:px forPage:page];
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
    if (_closing) return;
    if (queue != _pageQueue) return;      // a missing thumbnail is not worth tracking
    [self notePageFailed:page];
    // Nothing is going to make this page sharp, so stop paying raised-QoS
    // energy for it. Left armed, it re-promoted a doomed render every time the
    // wanted-set was rebuilt.
    if (page == _expressPage) _expressPage = NSNotFound;
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
    double now = [NSDate timeIntervalSinceReferenceDate];
    double dt  = now - _lastScrollTime;
    if (_lastScrollTime > 0 && dt >= 0.002 && dt < 0.5) {
        double v = fabs((double)(y - _lastScrollY)) / dt;
        // A jump is not a speed; see PV_MAX_SCROLL_SPEED.
        // Seeded with the first sample rather than ramped up from zero: a
        // smoothed average starting at rest needs four or five samples to
        // reach the truth, and those are exactly the first four or five pages
        // of a flick -- the ones the throttle exists to skip.
        if (v <= PV_MAX_SCROLL_SPEED)
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
    BOOL unchanged = (_haveRequestState &&
                      NSEqualRanges(range, _lastRequestRange) &&
                      dir == _lastDirection);
    _lastDirection = dir;

    [self updatePageIndicator];

    // Within a live scroll the desired set genuinely only changes when the
    // visible page range or the direction of travel changes. Rebuilding it on
    // every bounds notification meant allocating a fresh request set and taking
    // the render queue's lock 60-120 times a second to arrive at an identical
    // answer. Skipping that is invisible on screen and is pure main-thread and
    // battery savings during the app's most common interaction.
    if (unchanged && _liveScrolling) return;
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
- (void)scrollViewFrameChanged:(NSNotification *)note
{
    if (!_didInitialLayout || _closing) return;
    _haveRequestState = NO;
    CGFloat f = 0;
    NSUInteger p = [self currentPageWithFraction:&f];
    [self relayoutKeepingPage:p fraction:f];
    // Mid-drag the cached bitmaps are simply stretched; the sharp re-render is
    // requested once the user lets go of the window edge.
    if (![_pageView inLiveResize]) [self updateVisibleContent];
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
    _haveRequestState = NO;
    [self noteUserActivity];
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
    [_pageQueue  setSuspended:!visible];
    [_thumbQueue setSuspended:!visible];
    if (visible) {
        // Coming back into view is a fresh start: whatever made a page fail, or
        // made memory tight, was minutes ago and is worth testing again.
        [self resetRenderFailures];
        [self noteUserActivity];
        [self updateVisibleContent];
    }
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
    [_thumbView setBackingScale:[self backingScale]];
    CGFloat f = 0;
    NSUInteger p = [self currentPageWithFraction:&f];
    [self relayoutKeepingPage:p fraction:f];
    [_pageView setNeedsDisplay:YES];
    [_thumbView setNeedsDisplay:YES];
    [self updateVisibleContent];
}

- (void)memoryPressure:(NSNotification *)note
{
    if (_closing) return;
    [_pageCache dropFullImages];
    [_thumbCache dropFullImages];

    // The previews survive the drop, so there is something to draw immediately
    // and the pages on screen do not blank.
    //
    // What must not happen is answering every report the same way. The first
    // one suppresses prefetch -- those are exactly the bitmaps just released,
    // and re-rendering them undoes the drop within milliseconds. But the pages
    // on screen were still re-requested at full resolution, and on a machine
    // that stays tight that is its own loop: drop, render, drop, render, with
    // a background thread busy the whole time and the visible pages flickering
    // between sharp and soft. The kernel reports pressure on every transition,
    // and re-filling the cache is what causes the next transition.
    //
    // So the second report with no user action in between stops asking for
    // full-resolution pages at all. Previews are a ninth the size and are kept,
    // so the document stays readable; it just stops being re-sharpened at the
    // machine's expense. -noteUserActivity puts it back the moment the user
    // touches anything.
    if (_pressureReports < NSUIntegerMax) _pressureReports++;

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
        _thumbQueue = [[PVRenderQueue alloc] initWithSource:_thumbSource
                                                      label:"com.postview.render.thumbs"];
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

- (void)hideSidebar
{
    if (!_sidebarVisible) return;
    _sidebarVisible = NO;
    [_thumbScrollView removeFromSuperview];
    [_splitView adjustSubviews];

    // Nothing about thumbnails should cost anything once they are put away:
    // stop the queue and release every rendered thumbnail bitmap.
    [_thumbQueue setDesiredRequests:[NSArray array]];
    [_thumbCache removeAll];
    [_thumbView setNeedsDisplay:YES];
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
    // Same rule as the page cache: a thumbnail on screen is one that will be
    // asked for again the moment it is thrown away.
    [_thumbCache setPinnedPages:range];
    NSMutableArray *reqs = [NSMutableArray array];
    NSUInteger i;
    for (i = range.location; i < NSMaxRange(range) && i < [_source pageCount]; i++) {
        if ([_thumbCache hasPreviewForPage:i]) continue;
        [reqs addObject:[PVRenderRequest page:i
                                       pixels:[_thumbView pixelSizeForPage:i]
                                     priority:PVPriorityVisiblePreview preview:YES]];
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

    [clip scrollToPoint:NSMakePoint(floor(x + 0.5), floor(y + 0.5))];
    [_scrollView reflectScrolledClipView:clip];
    _lastScrollY = y;
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
