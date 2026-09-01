//  PVRenderQueue.h — prioritised, cancellable, background-priority page renderer.
//
//  The main thread never rasterises a page. Instead the view layer computes the
//  complete set of bitmaps it currently wants and hands it over with
//  -setDesiredRequests:, which atomically REPLACES the pending set. Anything the
//  user has scrolled past simply stops being wanted and is never rendered, which
//  is both the cancellation mechanism and the main battery saving: we do not
//  burn CPU rasterising pages that flew by.
//
//  Everything runs on one serial queue targeting the BACKGROUND global queue.
//  That is a deliberate and measured choice, not an oversight: on this hardware
//  the same page render costs ~84 mJ there against ~684 mJ at default priority,
//  because background QoS is confined to the efficiency cores. It is ~3.8x
//  slower in wall time and ~8x cheaper in energy.
//
//  A request may set `express`, which raises the QoS for that work via
//  dispatch_block_create_with_qos_class (10.10+, resolved dynamically so 10.9
//  simply keeps the background behaviour). The promoted block renders only the
//  express requests and then hands back, so the raised QoS cannot leak into
//  prefetch. It is reserved for the one page the user is visibly waiting on
//  with nothing cached to show.

#import "PVCommon.h"
#import "PVPDFSource.h"
#import "PVCostModel.h"

// Values taken from <dispatch/block.h> and <sys/qos.h>. They are spelled out
// rather than referenced so this file still compiles against the 10.9 headers.
// Getting one wrong is silent -- the express lane just stops promoting -- so
// pvtest pins them against the real SDK enums.
#define PV_BLOCK_ENFORCE_QOS_CLASS  ((uintptr_t)0x20)     // DISPATCH_BLOCK_ENFORCE_QOS_CLASS
#define PV_QOS_CLASS_UTILITY        ((unsigned int)0x11)  // QOS_CLASS_UTILITY

@class PVRenderQueue;

@protocol PVRenderQueueDelegate <NSObject>
- (void)renderQueue:(PVRenderQueue *)queue
       didRenderPage:(NSUInteger)page
               image:(CGImageRef)image
           pixelSize:(CGSize)px
             preview:(BOOL)preview;
@optional
// The same delivery, carrying what the rasterisation actually cost.
//
// Preferred over the method above when the delegate implements it; exactly one
// of the two is called per bitmap. Added rather than folded into the required
// method because the seconds are useful to precisely one caller -- the cache,
// which evicts by cost -- and every other implementor of this protocol is a
// test collector that would have had to grow a parameter it ignores.
//
// `renderSeconds` is wall-clock time inside -createImageForPage:pixelSize:, so
// it includes the bitmap allocation and the white fill as well as
// CGContextDrawPDFPage. That is the right quantity for both consumers: it is
// what a re-render would cost, which is what the cache is deciding about, and
// it is what the page has to be on screen long enough to absorb.
- (void)renderQueue:(PVRenderQueue *)queue
       didRenderPage:(NSUInteger)page
               image:(CGImageRef)image
           pixelSize:(CGSize)px
             preview:(BOOL)preview
       renderSeconds:(double)renderSeconds;
// CoreGraphics declined to produce a bitmap: a page object the document could
// not hand back, or a bitmap context that could not be allocated. Reported so
// the layer above can stop asking. Without it a page that cannot be rasterised
// never lands in the cache, so the wanted-set names it again on the very next
// scroll event and the queue rasterises it, fails, and is asked again -- for
// the rest of the session. Delivered on the main thread like a success.
- (void)renderQueue:(PVRenderQueue *)queue
        didFailPage:(NSUInteger)page
          pixelSize:(CGSize)px
            preview:(BOOL)preview;
// The same failure, carrying WHY.
//
// Preferred over the method above when the delegate implements it; exactly one
// of the two is called per failure. Added rather than folded in for the same
// reason -renderSeconds: was: the collectors in the test suites do not have a
// retry policy to inform, and would have grown a parameter they ignore.
//
// The distinction is not cosmetic. Every failure used to arrive as NULL, so a
// page briefly starved of shared memory was indistinguishable from a page
// CoreGraphics will never draw, and three of the former retired a perfectly
// good page for the rest of the session.
- (void)renderQueue:(PVRenderQueue *)queue
        didFailPage:(NSUInteger)page
          pixelSize:(CGSize)px
            preview:(BOOL)preview
            failure:(PVRenderFailure)failure;
@end

// At most two render lanes, and only on mains power. See -initWithSource:label:.
#define PV_MAX_RENDER_LANES 2

@interface PVRenderQueue : NSObject {
    // One serial lane per entry, each with its own PVPDFSource over the same
    // immutable snapshot. Lane 0 always exists; lane 1 exists only when
    // -initWithSource:label: decided this machine should have it, and
    // _laneCount is the authority on that everywhere else.
    //
    // Sharded by page number, so a given page is always rendered by the same
    // lane. That is what keeps two lanes from being two answers to the same
    // question, and it is why the sharding is arithmetic rather than
    // whichever-lane-is-free.
    PVPDFSource      *_laneSource[PV_MAX_RENDER_LANES];
    dispatch_queue_t  _laneQueue[PV_MAX_RENDER_LANES];
    BOOL              _laneRunning[PV_MAX_RENDER_LANES];
    // Per lane, for the same reason _expressYielded was per queue: the
    // hand-back has to be bounded on the lane that performs it.
    BOOL              _laneExpressYielded[PV_MAX_RENDER_LANES];
    NSUInteger        _laneCount;
    NSLock           *_lock;
    NSMutableArray   *_pending;
    // Work that has been taken off _pending and not yet accounted for by the
    // layer above. A request stays here from the moment the worker picks it up
    // until its result has been handed to the delegate on the main thread --
    // NOT merely until the rasterisation finishes. Those are different
    // instants, separated by one main-queue hop, and in between the cache does
    // not yet hold the bitmap: a wanted-set rebuilt in that window asked for a
    // page that was already rendered and sitting in the delivery queue, so a
    // heavy page could be rasterised two or three times over. Bounded by the
    // size of the pending set, because only the main thread adds to it.
    NSMutableArray   *_inFlight;
    BOOL              _suspended;
    BOOL              _shutdown;
    // Full-resolution bitmaps rasterised and not yet handed to the delegate.
    //
    // The quantity PV_MAX_INFLIGHT_FULL bounds. A bitmap counted here is ~28 MB
    // that the page cache's byte budget cannot see, because it is not in the
    // cache yet -- so a worker free to start the next full render before the
    // previous result has landed can stack up several of them behind a busy
    // main thread with nothing anywhere in the program able to say no.
    //
    // Incremented on the render queue the moment a full bitmap exists and is
    // going to be delivered; decremented on the main queue in the delivery
    // block. Exactly one of those two paths runs for any one bitmap: a queue
    // that has shut down never increments, because its result is released on
    // the spot instead of being dispatched.
    NSUInteger        _undeliveredFull;
    // Full-resolution bitmaps a lane is rasterising RIGHT NOW.
    //
    // Guarded by _lock, and the other half of what PV_MAX_INFLIGHT_FULL is
    // supposed to bound. _undeliveredFull alone counted bitmaps that already
    // existed, which is a check with no reservation behind it: two lanes could
    // pass it in the same instant, and a lane that had just handed one bitmap
    // over could start a second before the first was delivered. Reproduced
    // deterministically at three concurrent-or-undelivered full bitmaps
    // against a declared limit of two -- ~84 MB where the design says ~56 MB,
    // on a machine chosen for having enough cores to do it twice as fast.
    //
    // Incremented under the same lock acquisition that takes the request off
    // _pending, so the slot is claimed and the work is taken in one indivisible
    // step; decremented when the rasterisation ends, at which point the bitmap
    // either becomes an undelivered one or nothing at all.
    NSUInteger        _fullInProgress;
    // Guarded by _lock. Read on the render queue and cleared under the lock by
    // -shutdown, so a delivery can never race a deallocating delegate.
    __unsafe_unretained id <PVRenderQueueDelegate> _delegate;
    // What this document's renders cost, measured. Owned here because the queue
    // is the only place that sees both ends of a rasterisation, and one per
    // queue because there is one queue per document and the whole point of the
    // model is that documents differ by up to 59x. The thumbnail queue keeps
    // its own for the same reason: a thumbnail is 1/100 the pixels of a page
    // and pays the same content-stream interpretation, so its rate is not the
    // page queue's rate and mixing them would be failure 2 in PVCostModel.h.
    PVCostModel      *_cost;
}
// `maxLanes` is a ceiling, not a request: the queue still decides from the
// power source and the core count whether a second lane is worth having, and
// clamps to PV_MAX_RENDER_LANES. Pass 1 for work where a second lane buys
// nothing -- thumbnails are 1/100 the pixels of a page, so a second thumbnail
// lane would cost a second PVPDFSource and a second helper process to
// parallelise something that was never the bottleneck.
- (id)initWithSource:(PVPDFSource *)source label:(const char *)label
            maxLanes:(NSUInteger)maxLanes;
// As above with maxLanes: PV_MAX_RENDER_LANES.
- (id)initWithSource:(PVPDFSource *)source label:(const char *)label;
- (void)setDelegate:(id <PVRenderQueueDelegate>)delegate;
- (void)setDesiredRequests:(NSArray *)requests;
- (void)setSuspended:(BOOL)suspended;
- (void)shutdown;                       // must be called before release
- (BOOL)isIdle;                         // for tests and soak instrumentation
- (NSUInteger)inFlightCount;            // ditto: must always return to zero
// Full bitmaps rasterised but not yet delivered. Returns to zero like the two
// above.
- (NSUInteger)undeliveredFullCount;

// Everything PV_MAX_INFLIGHT_FULL actually bounds: full bitmaps being
// rasterised right now, plus full bitmaps rasterised and not yet delivered.
//
// This, and not -undeliveredFullCount, is the quantity the cap is a cap on.
// A test that watched only the delivered half saw two and concluded the limit
// held, while three full-page bitmaps were alive at once on a two-lane machine.
// Never exceeds PV_MAX_INFLIGHT_FULL; returns to zero when the queue is idle.
- (NSUInteger)fullCapacityInUse;

// How many lanes this queue actually built. For tests: a forced two-lane
// configuration that quietly fell back to one would satisfy every assertion
// about the cap without having exercised it.
- (NSUInteger)laneCount;

// What this document's renders have been measured to cost. Never nil.
//
// Exposed rather than proxied because the scheduler asks it two different
// questions -- a prediction for a specific bitmap, and how many samples exist
// yet -- and wrapping each one here would put the model's interface in two
// files. Safe to call from any thread; see PVCostModel.h.
- (PVCostModel *)costModel;

// Predicted seconds for a bitmap of this size, or 0 when there is not yet
// enough evidence. A convenience over -costModel with one important addition:
// the size is clamped exactly as the renderer will clamp it, so a caller that
// asks about a bitmap larger than PVMaxRenderPixels() is told what the render
// it will actually get costs rather than what the one it asked for would have.
- (double)predictedSecondsForPixels:(CGSize)px preview:(BOOL)preview;

@end
