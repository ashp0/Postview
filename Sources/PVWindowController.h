//  PVWindowController.h — one viewer window.

#import "PVCommon.h"
#import "PVPDFSource.h"
#import "PVImageCache.h"
#import "PVRenderQueue.h"
#import "PVPageView.h"
#import "PVThumbStripView.h"

@interface PVWindowController : NSWindowController
    <PVRenderQueueDelegate, PVThumbStripDelegate, PVPageViewDelegate,
     NSToolbarDelegate, NSSplitViewDelegate, NSWindowDelegate>
{
    NSURL            *_url;

    PVPDFSource      *_source;
    PVImageCache     *_pageCache;
    PVRenderQueue    *_pageQueue;
    PVPageView       *_pageView;
    NSScrollView     *_scrollView;

    // Created only when the thumbnail sidebar is actually opened.
    PVPDFSource      *_thumbSource;
    PVImageCache     *_thumbCache;
    PVRenderQueue    *_thumbQueue;
    PVThumbStripView *_thumbView;
    NSScrollView     *_thumbScrollView;
    // The thumbnail range last handed to the thumbnail queue, and whether there
    // is one. The same early-out the page view has, for the same reason:
    // dragging the strip posts a bounds notification per frame, and rebuilding
    // an identical wanted set for each one allocates a request array and takes
    // the render queue's lock 60-120 times a second to reach the answer it
    // already had. See -updateThumbnailContent.
    NSRange           _lastThumbRange;
    BOOL              _haveThumbState;

    NSSplitView      *_splitView;

    PVZoomMode        _zoomMode;
    CGFloat           _zoom;
    // Pages side by side: 1 for the ordinary column, 2 for the spread. The
    // page view is told this number and works out the geometry; everything
    // else here -- the wanted set, the prefetch, the failure tables, the cache
    // -- is written in pages and is unaffected by how they are arranged.
    NSUInteger        _columns;
    // The cover layout: page one alone, the rest paired. Only meaningful
    // alongside a column count above one, and held as a separate flag rather
    // than as a third column count because it is not one: it does not change
    // how many pages fit across the window, it changes only which pages share
    // a row. Everything sized from the column count -- the fit-width zoom, the
    // wanted set, the prefetch -- is correct under it unchanged.
    BOOL              _cover;
    BOOL              _sidebarVisible;
    BOOL              _liveScrolling;
    // A pinch is in progress. Like a live scroll it holds off the exact render
    // pass: the cached bitmaps are stretched while the fingers are moving and
    // the sharp ones are asked for once, when they come off. Re-rendering at
    // every intermediate zoom would be many full-page rasterisations for
    // geometries that exist for one frame each.
    BOOL              _liveZooming;
    // What the pinch is anchored to: the page under the fingers, how far into
    // it they are, and where in the viewport they sit. Holding those fixed
    // across the zoom is what makes the document appear to scale around the
    // fingers instead of around the top-left corner.
    NSUInteger        _magnifyPage;
    CGFloat           _magnifyFractionY;
    CGFloat           _magnifyFractionX;
    NSPoint           _magnifyViewportOffset;
    BOOL              _didInitialLayout;
    BOOL              _closing;

    CGFloat           _lastScrollY;
    int               _lastDirection;

    // Has the viewport ever actually moved in this window?
    //
    // _lastDirection starts at 1 -- forwards -- because the prefetch has to
    // guess something before there is any evidence. That guess is free for
    // previews, which are a ninth the size, and expensive for full-resolution
    // bitmaps: at launch it meant rasterising a whole extra page nobody had
    // asked to see, at the one moment the machine is busiest. Until the user
    // moves, there is no direction of travel to prefetch along, so the
    // full-resolution half of the prefetch waits for evidence.
    BOOL              _hasMovedViewport;

    // The motion state at the last wanted-set rebuild.
    //
    // Part of deciding whether a rebuild would reach the same answer. The page
    // range and the direction of travel are not sufficient on their own: the
    // same two pages, in the same direction, produce a different request set
    // depending on whether the document is moving, because that is what
    // decides whether full-resolution bitmaps are asked for at all.
    BOOL              _lastMovingState;

    // How fast the document is moving under the viewport, in points per
    // second, smoothed over recent scroll events. Zero when not scrolling.
    //
    // This exists to stop the app rasterising pages nobody will ever see.
    // Cancelling queued work is not enough during a flick: the render queue is
    // never idle, so each page it picks up is genuinely wanted at the instant
    // it starts and is stale by the time it finishes one render later. Flat
    // out it manages about nine pages a second; a hard flick moves sixty. The
    // result was a fully saturated core producing bitmaps for pages that had
    // left the screen long before they arrived -- the whole of the difference
    // between a quarter of a core at reading pace and well over a full core
    // while flicking.
    //
    // Speed plus the queue's own measured render time answers the question
    // that actually matters: will this bitmap arrive while its page is still
    // on screen? If not, it is not asked for. What the user sees is unchanged,
    // because what is skipped is exactly what was arriving too late to be
    // seen; the moment the scroll stops, -didEndLiveScroll: asks for
    // everything properly.
    //
    // The clock is read in an event handler that was going to run anyway. One
    // timer is scheduled, and only while the document is actually moving
    // outside a gesture scroll: see _settleTimer.
    double            _scrollSpeed;
    double            _lastScrollTime;

    // Fires once, PV_SETTLE_SECONDS after the document stops moving, to ask
    // for the sharp pass.
    //
    // A gesture scroll announces its own end and does not need this; keyboard
    // paging has no end event, so without it a held Page Down would leave the
    // page it landed on soft until the user next did something. Rescheduled by
    // each movement, so it fires once when the movement stops rather than
    // repeatedly during it.
    //
    // Not load-bearing for correctness. PV_SPEED_FRESH_SECONDS already
    // guarantees that suppression expires on its own; this only decides
    // whether the sharp page arrives in 0.15 s or on the next event. Held
    // weakly in the sense that matters -- invalidated in -teardownReferences,
    // when a live scroll takes over, and before any reschedule -- so it can
    // never outlive the controller or run twice for one movement.
    NSTimer          *_settleTimer;
    // The pending transient-failure retry, and the monotonic instant it is set
    // for. Separate from _settleTimer because a settle is cancelled and re-armed
    // by every scroll event: a retry pinned to it would be pushed forward
    // indefinitely by the one reader who most needs it, the one still scrolling
    // through the pages that are missing. Invalidated in -teardownReferences
    // alongside the settle timer.
    NSTimer          *_retryTimer;
    double            _retryTimerAt;
    // The renderer has been reported missing. One document, one alert: it is a
    // fact about the installation, and every page would otherwise report it.
    //
    // It also stops every page being asked for again. Without that the failure
    // handler rebuilt the wanted set, the wanted set named the same pages, they
    // failed the same way, and nothing anywhere converged -- a missing helper
    // has no per-page counter to run out, because it is not a fact about any
    // page. See -pageIsUnrenderable:preview:.
    BOOL              _reportedRendererMissing;
    NSUInteger        _displayedPage;

    NSUInteger        _restorePage;
    CGFloat           _restoreFraction;
    BOOL              _restoreSidebar;

    // The one page, if any, whose render is currently worth paying raised-QoS
    // energy for: the page the user is looking at while it is still blank.
    // NSNotFound when no such page exists, which is almost always. Cleared as
    // soon as that page's full-resolution bitmap arrives, and by any scroll.
    NSUInteger        _expressPage;

    // Live-scroll coalescing state. The desired-request set is rebuilt only
    // when the visible page range changes or the view has travelled far
    // enough to matter, rather than on every bounds notification.
    NSRange           _lastRequestRange;
    BOOL              _haveRequestState;
    // Where the viewport was horizontally when that set was built.
    //
    // Only ever consulted in a two-page spread wide enough to scroll sideways,
    // which is the only configuration in which the wanted set depends on x at
    // all: in the single-page column a page always overlaps the viewport
    // horizontally whatever the scroll position, so this changes nothing
    // there. See -clipBoundsChanged: and PVPageOverlapsColumn().
    CGFloat           _lastRequestX;

    // Bitmaps CoreGraphics has refused to rasterise, and how many times. A
    // render that fails never reaches the cache, so the wanted-set names it
    // again on the next scroll event and the queue tries it again -- one bad
    // page in a document left open overnight is a background thread rasterising
    // nothing, forever. After a few attempts that bitmap is left alone until
    // something happens that could plausibly change the answer.
    //
    // One counter per BITMAP, not per page. The three bitmaps a page can have
    // are three different questions for CoreGraphics: a 28 MB full-resolution
    // render can fail for want of contiguous memory while the 3 MB preview of
    // the same page succeeds every time, and a thumbnail is smaller again.
    // Keyed by page alone, the failure of the expensive one retired the cheap
    // ones with it -- so a page that could have shown something showed nothing.
    //
    // Flat byte arrays sized from the page count, which -[PVPDFSource init]
    // has already bounded at 100,000: 200 KB and 100 KB at the very top of
    // that range, and no per-failure allocation. The dictionary this replaces
    // was capped at 512 entries and then stopped recording, which meant every
    // page after the 512th was retried without limit -- the exact behaviour
    // the table exists to prevent, reached by the mechanism meant to bound it.
    //
    // NULL if the allocation failed; every read treats that as "renderable",
    // so the worst case is the old unbounded retry rather than a crash.
    uint8_t          *_pageFailures;    // 2 per page: [p*2] full, [p*2+1] preview
    uint8_t          *_thumbFailures;   // 1 per page
    NSUInteger        _failureSlots;    // page count the arrays were sized for
    // Transient failures per page bitmap, counted apart from the permanent
    // ones above, and the monotonic time each slot may next be attempted.
    //
    // A page starved of shared memory for one instant and a page CoreGraphics
    // will never draw are different events with the same remedy applied to
    // them: three strikes and the page was blank for the session. These two
    // arrays are what let the second be retried with a backoff while only the
    // first spends an attempt.
    uint8_t          *_pageTransient;   // 2 per page, same slot layout
    uint8_t          *_thumbTransient;  // 1 per page
    double           *_pageRetryAt;     // 2 per page; 0 = no wait outstanding
    double           *_thumbRetryAt;    // 1 per page
    // The clamped pixel size each slot's counters were recorded at.
    //
    // Failures were keyed by page and preview alone, so a bitmap that could not
    // be allocated at one zoom retired the page at every other -- the counter
    // survived the very change of question that made it worth asking again. A
    // slot whose size has moved starts over.
    CGSize           *_pageFailureSize; // 2 per page
    CGSize           *_thumbFailureSize;// 1 per page

    // The memory pressure level the kernel last reported, as a tier. Zero in
    // every normal session.
    //
    // 0 -- DISPATCH_MEMORYPRESSURE_NORMAL. Nothing is wrong; render normally.
    //
    // 1 -- DISPATCH_MEMORYPRESSURE_WARN. Another application is spiking: drop
    // the full-resolution bitmaps and stop PREFETCHING them, but keep rendering
    // the pages actually on screen sharply, because the user is reading those.
    //
    // 2 -- DISPATCH_MEMORYPRESSURE_CRITICAL. Re-rendering is now itself part
    // of the problem:
    // continuing to answer it the same way is a loop -- drop, re-render, drop,
    // re-render -- which on a 2 GB Mavericks machine can run for hours. Only
    // the cheap previews are kept and no full-resolution page is asked for at
    // all. Pages stay legible, slightly soft, and the machine is left alone.
    //
    // This is a level, not a count. A count could not tell a critical event
    // from a mild one, and coalescing meant a machine that went straight to
    // critical delivered a single callback that read as tier 1 -- the tier
    // whose response is to allocate the largest bitmaps the app can make. One
    // CRITICAL therefore reaches tier 2 by itself, and repeated WARNs never do:
    // escalation follows what the kernel says, not how often it says it.
    //
    // Only a NORMAL event from the kernel clears it. User activity does NOT:
    // scrolling says nothing about whether the machine still has memory, and
    // scrolling is precisely what a user does while waiting for a stalled
    // machine, so clearing it there re-armed full-resolution rendering at the
    // worst possible moment.
    NSUInteger        _pressureReports;
}
- (id)initWithSource:(PVPDFSource *)source url:(NSURL *)url;
- (void)saveState;
- (void)goToPageNumber:(NSInteger)oneBasedPage;

- (IBAction)toggleSidebar:(id)sender;
- (IBAction)toggleTwoPageView:(id)sender;
- (IBAction)toggleCoverPageView:(id)sender;
- (IBAction)zoomIn:(id)sender;
- (IBAction)zoomOut:(id)sender;
- (IBAction)zoomActualSize:(id)sender;
- (IBAction)zoomFitWidth:(id)sender;
- (IBAction)zoomFitPage:(id)sender;
- (IBAction)goToPageDialog:(id)sender;
- (IBAction)goToNextPage:(id)sender;
- (IBAction)goToPreviousPage:(id)sender;
- (IBAction)goToFirstPage:(id)sender;
- (IBAction)goToLastPage:(id)sender;
@end
