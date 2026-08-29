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

    NSSplitView      *_splitView;

    PVZoomMode        _zoomMode;
    CGFloat           _zoom;
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

    // Pages CoreGraphics has refused to rasterise, and how many times. A page
    // that fails never reaches the cache, so the wanted-set names it again on
    // the next scroll event and the queue tries it again -- one bad page in a
    // document left open overnight is a background thread rasterising nothing,
    // forever. After a few attempts the page is left alone until something
    // happens that could plausibly change the answer. Bounded, and empty in
    // every normal session.
    NSMutableDictionary *_renderFailures;   // NSNumber(page) -> NSNumber(count)

    // How many times the kernel has reported memory pressure since the user
    // last did anything. Zero in every normal session.
    //
    // One report is another application spiking: drop the full-resolution
    // bitmaps, stop prefetching them, and let the pages actually on screen go
    // sharp again -- the user is still reading them.
    //
    // A second report with no user action in between means that re-rendering
    // is itself what put the machine back under pressure. Continuing to answer
    // it the same way is a loop: drop, re-render, drop, re-render, for as long
    // as the machine stays tight, which on a 2 GB Mavericks machine can be
    // hours. From the second report on, only the cheap previews are kept and
    // no full-resolution page is asked for at all. The pages on screen stay
    // legible, slightly soft, and the machine is left alone.
    //
    // Any real action -- a scroll, a zoom, a page jump, the window coming back
    // into view -- resets this to zero through -noteUserActivity, so the
    // moment the user is actually reading again they get sharp pages back.
    NSUInteger        _pressureReports;
}
- (id)initWithSource:(PVPDFSource *)source url:(NSURL *)url;
- (void)saveState;
- (void)goToPageNumber:(NSInteger)oneBasedPage;

- (IBAction)toggleSidebar:(id)sender;
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
